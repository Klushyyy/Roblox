-- PetRenderer: client-side visuals for every player's equipped pets. The server only replicates
-- state (EquippedPets/<slot> StringValue = pet id, its Target ObjectValue = the grime part being
-- cleaned); this module is the only thing that actually builds and moves pet models. See
-- DESIGN.md section 6 ("PetRenderer") and section 4 ("Equipped pets for rendering").
--
--   * One local Folder, workspace.ClientPets, holds every model this client has built (for every
--     player, including the local one).
--   * A single RunService.RenderStepped connection drives every pet every frame; per-player /
--     per-slot state lives in `owners`, cleaned up on PlayerRemoving, folder/slot removal, or the
--     model failing to exist.
--   * Hovering over a live grime part takes priority; otherwise the pet holds a formation slot
--     behind its owner. Both cases are just a target CFrame that GetPivot() lerps toward.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PetModels = require(Shared:WaitForChild("PetModels"))

local PetRenderer = {}

----------------------------------------------------------------------------------------------------
-- Tuning
----------------------------------------------------------------------------------------------------

local HOVER_OFFSET = 2.5 -- studs off the grime part along its surface normal (XVector, per DESIGN)
local FORMATION_MIN_DIST = 5
local FORMATION_MAX_DIST = 7
local FORMATION_ARC = math.rad(70) -- total angular spread of the formation, centred behind the owner
local BOB_SPEED = 3
local BOB_HEIGHT = 0.4
local LERP_RATE = 10 -- pivot:Lerp(target, 1 - exp(-LERP_RATE * dt))
local HIDE_DISTANCE = 400
local TILT_STRENGTH = 0.05
local MAX_TILT = math.rad(20)

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

type Slot = {
	Value: StringValue,
	Number: number, -- tonumber(Value.Name); used only to order the formation consistently
	Model: Model?,
	Target: BasePart?,
	Hidden: boolean?,
	LastPos: Vector3?,
	Conns: { RBXScriptConnection },
}

type OwnerState = {
	Player: Player,
	Folder: Folder,
	Slots: { [StringValue]: Slot },
	Conns: { RBXScriptConnection },
}

local initialized = false
local clientPetsFolder: Folder? = nil
local owners: { [Player]: OwnerState } = {}
-- Connections on the Player instance itself (waiting for EquippedPets to appear/disappear), kept
-- separate from OwnerState so they survive the folder coming and going.
local playerConns: { [Player]: { RBXScriptConnection } } = {}
local elapsed = 0

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local function ensureClientPetsFolder(): Folder
	if clientPetsFolder and clientPetsFolder.Parent then
		return clientPetsFolder
	end
	local existing = workspace:FindFirstChild("ClientPets")
	if existing and existing:IsA("Folder") then
		clientPetsFolder = existing
	else
		local folder = Instance.new("Folder")
		folder.Name = "ClientPets"
		folder.Parent = workspace
		clientPetsFolder = folder
	end
	return clientPetsFolder :: Folder
end

-- Local-only visibility toggle: cheap to call every frame, so instead we only touch parts when the
-- hidden state actually flips (LocalTransparencyModifier never replicates, so this doesn't affect
-- anyone else's view).
local function setHidden(slot: Slot, hidden: boolean)
	if slot.Hidden == hidden or not slot.Model then
		return
	end
	slot.Hidden = hidden
	for _, part in slot.Model:GetDescendants() do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = if hidden then 1 else 0
		end
	end
end

-- A little pitch/roll based on how the pet is currently moving, so it doesn't glide like a robot.
local function applyTilt(pivot: CFrame, velocity: Vector3): CFrame
	local localVel = pivot:VectorToObjectSpace(velocity)
	local pitch = math.clamp(localVel.Z * TILT_STRENGTH, -MAX_TILT, MAX_TILT) -- moving forward (-Z) noses down
	local roll = math.clamp(-localVel.X * TILT_STRENGTH, -MAX_TILT, MAX_TILT)
	return pivot * CFrame.Angles(pitch, 0, roll)
end

----------------------------------------------------------------------------------------------------
-- Slot lifecycle
----------------------------------------------------------------------------------------------------

local function destroySlot(slot: Slot)
	for _, conn in slot.Conns do
		conn:Disconnect()
	end
	table.clear(slot.Conns)
	if slot.Model then
		slot.Model:Destroy()
		slot.Model = nil
	end
end

local function buildModel(slot: Slot, petId: string)
	if slot.Model then
		slot.Model:Destroy()
		slot.Model = nil
	end
	local ok, model = pcall(PetModels.Build, petId)
	if not ok or not model then
		return
	end
	-- Defensive: PetModels already builds with these off, but a client-only render model must never
	-- interact with anything physically, whatever the shared builder does.
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
		end
	end
	model.Parent = ensureClientPetsFolder()
	slot.Model = model
	slot.Hidden = nil -- force the next setHidden call to actually apply
	slot.LastPos = nil
end

local function hookTargetValue(slot: Slot, stringValue: StringValue)
	local targetValue = stringValue:FindFirstChild("Target")
	if not targetValue or not targetValue:IsA("ObjectValue") then
		-- The server may parent Target a moment after the slot itself; keep watching for it.
		local conn
		conn = stringValue.ChildAdded:Connect(function(child)
			if child.Name == "Target" and child:IsA("ObjectValue") then
				conn:Disconnect()
				local i = table.find(slot.Conns, conn)
				if i then
					table.remove(slot.Conns, i)
				end
				hookTargetValue(slot, stringValue)
			end
		end)
		table.insert(slot.Conns, conn)
		return
	end
	local target = targetValue.Value
	slot.Target = if typeof(target) == "Instance" and target:IsA("BasePart") then target else nil
	table.insert(
		slot.Conns,
		targetValue.Changed:Connect(function(value)
			slot.Target = if typeof(value) == "Instance" and value:IsA("BasePart") then value else nil
		end)
	)
end

local function addSlot(ownerState: OwnerState, stringValue: StringValue)
	if ownerState.Slots[stringValue] then
		return
	end
	local slot: Slot = {
		Value = stringValue,
		Number = tonumber(stringValue.Name) or 0,
		Model = nil,
		Target = nil,
		Hidden = nil,
		LastPos = nil,
		Conns = {},
	}
	ownerState.Slots[stringValue] = slot
	buildModel(slot, stringValue.Value)
	hookTargetValue(slot, stringValue)
	table.insert(
		slot.Conns,
		stringValue.Changed:Connect(function(newId)
			-- The pet in this slot was swapped in place (unequip + equip without the slot itself
			-- being removed). Rebuild the model; the Target watcher stays valid (same StringValue).
			buildModel(slot, newId)
		end)
	)
end

local function removeSlot(ownerState: OwnerState, stringValue: StringValue)
	local slot = ownerState.Slots[stringValue]
	if not slot then
		return
	end
	ownerState.Slots[stringValue] = nil
	destroySlot(slot)
end

----------------------------------------------------------------------------------------------------
-- Owner (player) lifecycle
----------------------------------------------------------------------------------------------------

local function cleanupOwner(player: Player)
	local ownerState = owners[player]
	if not ownerState then
		return
	end
	owners[player] = nil
	for _, conn in ownerState.Conns do
		conn:Disconnect()
	end
	for stringValue, slot in ownerState.Slots do
		destroySlot(slot)
	end
	table.clear(ownerState.Slots)
end

local function trackFolder(player: Player, folder: Folder)
	if owners[player] then
		return
	end
	local ownerState: OwnerState = {
		Player = player,
		Folder = folder,
		Slots = {},
		Conns = {},
	}
	owners[player] = ownerState

	for _, child in folder:GetChildren() do
		if child:IsA("StringValue") then
			addSlot(ownerState, child)
		end
	end
	table.insert(
		ownerState.Conns,
		folder.ChildAdded:Connect(function(child)
			if child:IsA("StringValue") then
				addSlot(ownerState, child)
			end
		end)
	)
	table.insert(
		ownerState.Conns,
		folder.ChildRemoved:Connect(function(child)
			if child:IsA("StringValue") then
				removeSlot(ownerState, child)
			end
		end)
	)
	table.insert(
		ownerState.Conns,
		folder.Destroying:Connect(function()
			cleanupOwner(player)
		end)
	)
end

local function trackPlayer(player: Player)
	if playerConns[player] then
		return
	end
	local conns: { RBXScriptConnection } = {}
	playerConns[player] = conns

	local existing = player:FindFirstChild("EquippedPets")
	if existing and existing:IsA("Folder") then
		trackFolder(player, existing)
	end
	table.insert(
		conns,
		player.ChildAdded:Connect(function(child)
			if child.Name == "EquippedPets" and child:IsA("Folder") then
				trackFolder(player, child)
			end
		end)
	)
	table.insert(
		conns,
		player.ChildRemoved:Connect(function(child)
			if child.Name == "EquippedPets" then
				cleanupOwner(player)
			end
		end)
	)
end

local function untrackPlayer(player: Player)
	cleanupOwner(player)
	local conns = playerConns[player]
	if conns then
		playerConns[player] = nil
		for _, conn in conns do
			conn:Disconnect()
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Per-frame movement
----------------------------------------------------------------------------------------------------

-- Slots ordered by their StringValue name ("1", "2", ...) so the formation is stable frame to frame
-- even though `Slots` itself is a dictionary. Reused per owner per frame; small (<= a handful).
local orderScratch: { Slot } = {}

local function updateOwner(ownerState: OwnerState, dt: number, camPos: Vector3)
	local player = ownerState.Player
	local character = player.Character
	local ownerRoot = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local ownerAlive = ownerRoot ~= nil and ownerRoot:IsA("BasePart") and humanoid ~= nil and humanoid.Health > 0

	local farAway = false
	if ownerAlive then
		farAway = (camPos - (ownerRoot :: BasePart).Position).Magnitude > HIDE_DISTANCE
	end
	local hideAll = (not ownerAlive) or farAway

	table.clear(orderScratch)
	for _, slot in ownerState.Slots do
		table.insert(orderScratch, slot)
	end
	table.sort(orderScratch, function(a, b)
		return a.Number < b.Number
	end)
	local count = #orderScratch

	for i, slot in orderScratch do
		local model = slot.Model
		if not model or not model.Parent or not model.PrimaryPart then
			continue
		end
		setHidden(slot, hideAll)
		if hideAll then
			continue
		end

		local targetCFrame: CFrame? = nil
		local grime = slot.Target
		if grime and grime.Parent and grime:IsA("BasePart") then
			local ok, pos, cf = pcall(function()
				return grime.Position, grime.CFrame
			end)
			if ok then
				local hoverPos = pos + cf.XVector * HOVER_OFFSET
				targetCFrame = CFrame.lookAt(hoverPos, pos)
			end
		end

		if not targetCFrame then
			local root = ownerRoot :: BasePart
			local frac = if count > 1 then (i - 1) / (count - 1) else 0.5
			local dist = FORMATION_MIN_DIST + (FORMATION_MAX_DIST - FORMATION_MIN_DIST) * frac
			local angle = (frac - 0.5) * FORMATION_ARC
			local bob = math.sin(elapsed * BOB_SPEED + i) * BOB_HEIGHT
			local localOffset = CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, dist)
			local worldPos = (root.CFrame * localOffset).Position + Vector3.new(0, bob, 0)
			-- Face the same way as the owner (a sidekick formation), not rotated by the arc angle.
			targetCFrame = CFrame.new(worldPos) * (root.CFrame - root.CFrame.Position)
		end

		local current = model:GetPivot()
		local alpha = 1 - math.exp(-LERP_RATE * dt)
		local newPivot = current:Lerp(targetCFrame :: CFrame, alpha)

		if slot.LastPos and dt > 1e-4 then
			local velocity = (newPivot.Position - slot.LastPos) / dt
			newPivot = applyTilt(newPivot, velocity)
		end
		slot.LastPos = newPivot.Position

		model:PivotTo(newPivot)
	end
end

local function onRenderStepped(dt: number)
	elapsed += dt
	local camera = workspace.CurrentCamera
	local camPos = if camera then camera.CFrame.Position else Vector3.zero
	for _, ownerState in owners do
		local ok, err = pcall(updateOwner, ownerState, dt, camPos)
		if not ok then
			warn("[PetRenderer] update failed: " .. tostring(err))
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Init
----------------------------------------------------------------------------------------------------

function PetRenderer.Init()
	if initialized then
		return
	end
	initialized = true

	ensureClientPetsFolder()

	for _, player in Players:GetPlayers() do
		trackPlayer(player)
	end
	Players.PlayerAdded:Connect(trackPlayer)
	Players.PlayerRemoving:Connect(untrackPlayer)

	RunService.RenderStepped:Connect(onRenderStepped)
end

return PetRenderer
