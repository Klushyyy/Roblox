-- Effects: every world FX that isn't owned by another module. RunFX handlers (grime pops, floating
-- numbers, dish/sale celebrations), CollectionService-driven decoration (spinning arms, lift
-- pads), the drain guide beam, remaining-dirt sparkle markers, prompt routing (windows and the
-- in-arena tool shop), and a little lobby ambience.
--
-- Everything here is local: the only server calls are the tool shop's BuyTool requests (validated
-- by the server like any other purchase). Nothing here is authoritative, and every part/emitter this module creates is either pooled (reused) or handed to
-- Debris so a long session never accumulates instances.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Effects = {}

local LocalPlayer = Players.LocalPlayer
local initialized = false

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

local MAX_FLOATERS = 24 -- floating +N labels alive at once (local player's own numbers)
local FLOATER_RISE = 3 -- studs
local FLOATER_TIME = 0.7
local MAX_LOBBY_BUBBLES = 10
local DRAIN_FULL_FRACTION = 0.95

-- Floating "+N" labels currently alive, oldest first (capped, so a spam of Cleaned FX can't leak).
local floaters: { Instance } = {}

----------------------------------------------------------------------------------------------------
-- Small shared helpers
----------------------------------------------------------------------------------------------------

local function billboardNumber(position: Vector3, text: string, color: Color3, rise: number?)
	if #floaters >= MAX_FLOATERS then
		local oldest = table.remove(floaters, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace

	local gui = Instance.new("BillboardGui")
	gui.Name = "Floater"
	gui.Size = UDim2.fromOffset(220, 50)
	gui.StudsOffset = Vector3.new(0, 1, 0)
	gui.AlwaysOnTop = true
	gui.Parent = anchor

	local label = UIKit.Label({
		Text = text,
		Size = UDim2.fromScale(1, 1),
		TextSize = 28,
		TextColor3 = color,
		Parent = gui,
	})

	table.insert(floaters, anchor)
	local goalOffset = gui.StudsOffset + Vector3.new(0, rise or FLOATER_RISE, 0)
	UIKit.Tween(gui, { StudsOffset = goalOffset }, FLOATER_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	UIKit.Tween(label, { TextTransparency = 1 }, FLOATER_TIME * 0.8)
	task.delay(FLOATER_TIME + 0.05, function()
		local i = table.find(floaters, anchor)
		if i then
			table.remove(floaters, i)
		end
		anchor:Destroy()
	end)
end

-- One-shot sparkle/pop burst: an Attachment that emits once and is handed to Debris.
local function burst(position: Vector3, color: Color3, texture: string, count: number, lifetime: number)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(position)
	anchor.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = texture
	emitter.Color = ColorSequence.new(color)
	emitter.Lifetime = NumberRange.new(lifetime * 0.6, lifetime)
	emitter.Speed = NumberRange.new(3, 8)
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.LightEmission = 0.5
	emitter.Rate = 0
	emitter.Parent = anchor
	emitter:Emit(count)

	Debris:AddItem(anchor, lifetime + 1)
end

-- A few tiny transient bubble balls that pop upward and fade (used for "Cleaned" and lobby ambience).
local function popBubbles(position: Vector3, count: number, spread: number)
	for _ = 1, count do
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball
		ball.Material = Enum.Material.Glass
		ball.Color = Color3.new(1, 1, 1)
		ball.Transparency = 0.35
		ball.Size = Vector3.new(1, 1, 1) * (0.15 + math.random() * 0.2)
		ball.CanCollide = false
		ball.CanTouch = false
		ball.CanQuery = false
		ball.CastShadow = false
		ball.Anchored = false
		ball.CFrame = CFrame.new(position + Vector3.new((math.random() - 0.5) * spread, 0, (math.random() - 0.5) * spread))
		ball.Parent = workspace
		ball.AssemblyLinearVelocity = Vector3.new((math.random() - 0.5) * 4, 4 + math.random() * 4, (math.random() - 0.5) * 4)
		Debris:AddItem(ball, 1.2)
	end
end

----------------------------------------------------------------------------------------------------
-- RunFX handlers
----------------------------------------------------------------------------------------------------

local comboCount = 0
local lastCleanedAt = 0
local COMBO_RESET_GAP = 0.6
local lastCleanedFXAt = 0
local CLEANED_FX_MIN_GAP = 0.03 -- guards against a burst of simultaneous pet + player cleans

local function onCleaned(data: Types.FXCleaned)
	local now = os.clock()
	if now - lastCleanedFXAt < CLEANED_FX_MIN_GAP then
		-- Still play the sound (cheap, and combo feel matters most), but skip the heavier burst.
	else
		lastCleanedFXAt = now
		burst(data.Position, data.Color, "rbxasset://textures/particles/sparkles_main.dds", 10, 0.5)
		popBubbles(data.Position, 3, 1.2)
	end

	if now - lastCleanedAt > COMBO_RESET_GAP then
		comboCount = 0
	end
	comboCount = math.min(comboCount + 1, 12)
	lastCleanedAt = now
	UIKit.PlaySound("Pop", 0.95 + comboCount * 0.03)

	if data.By == LocalPlayer.UserId then
		billboardNumber(data.Position, "+" .. UIKit.Short(data.Units) .. " 💧", UIKit.Theme.Colors.Primary)
		if data.Golden and data.Bubbles > 0 then
			billboardNumber(data.Position, "+" .. UIKit.Short(data.Bubbles) .. " 🧼", UIKit.Theme.Colors.Bubble, FLOATER_RISE + 1)
		end
	end
end

local function onDishDone(data: Types.FXDishDone)
	burst(data.Position, UIKit.Theme.Colors.Good, "rbxasset://textures/particles/sparkles_main.dds", 24, 0.8)
	popBubbles(data.Position, 6, 2)
	UIKit.PlaySound("Sparkle")
	billboardNumber(data.Position, "✨ Sparkling!", UIKit.Theme.Colors.Text, FLOATER_RISE + 1)
	if data.By == LocalPlayer.UserId and data.Bonus > 0 then
		billboardNumber(data.Position + Vector3.new(0, 1.4, 0), "+" .. UIKit.Short(data.Bonus) .. " 💰", UIKit.Theme.Colors.Coin, FLOATER_RISE + 1.6)
	end
end

local function onSold(data: Types.FXSold)
	UIKit.PlaySound("Coins")
	UIKit.Toast("+" .. UIKit.Commas(data.Coins) .. " 💰", "Good")
end

local function onTankFull()
	UIKit.PlaySound("Error")
end

local function onRunFX(kind: string, data: any)
	if kind == "Cleaned" then
		onCleaned(data)
	elseif kind == "DishDone" then
		onDishDone(data)
	elseif kind == "Sold" then
		onSold(data)
	elseif kind == "TankFull" then
		onTankFull()
	end
end

----------------------------------------------------------------------------------------------------
-- SpinY (CollectionService): drain whirlpool rings, spray arms under each rack. Streaming-safe:
-- parts that stream out simply stop appearing in GetTagged / are skipped if their Parent goes away.
----------------------------------------------------------------------------------------------------

local spinParts: { [BasePart]: boolean } = {}

local function addSpinPart(inst: Instance)
	if inst:IsA("BasePart") then
		spinParts[inst] = true
	end
end

local function removeSpinPart(inst: Instance)
	spinParts[inst :: BasePart] = nil
end

local function stepSpin(dt: number)
	for part in spinParts do
		if not part.Parent or not part:IsDescendantOf(workspace) then
			spinParts[part] = nil
			continue
		end
		local speed = part:GetAttribute("SpinSpeed")
		if type(speed) ~= "number" or speed == 0 then
			continue
		end
		part.CFrame *= CFrame.Angles(0, speed * dt, 0)
	end
end

----------------------------------------------------------------------------------------------------
-- Lift pads (CollectionService tag "LiftPad", attribute LiftTo = world Vector3): step on one and
-- you're carried to LiftTo in a puff of bubbles. The local client owns its character, so moving it
-- here replicates. A short cooldown stops you bouncing straight back.
----------------------------------------------------------------------------------------------------

local LIFT_RADIUS = 4.2
local LIFT_COOLDOWN = 1.2

local liftPads: { [BasePart]: boolean } = {}
local lastLiftAt = 0

local function addLiftPart(inst: Instance)
	if inst:IsA("BasePart") then
		liftPads[inst] = true
	end
end

local function removeLiftPart(inst: Instance)
	liftPads[inst :: BasePart] = nil
end

local function stepLift(_dt: number)
	local now = os.clock()
	if now - lastLiftAt < LIFT_COOLDOWN then
		return
	end
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") then
		return
	end
	local rootPart = root :: BasePart
	local pos = rootPart.Position

	for pad in liftPads do
		if not pad.Parent then
			liftPads[pad] = nil
			continue
		end
		local target = pad:GetAttribute("LiftTo")
		if typeof(target) ~= "Vector3" then
			continue
		end
		local d = pos - pad.Position
		if Vector3.new(d.X, 0, d.Z).Magnitude <= LIFT_RADIUS and d.Y > -1 and d.Y < 7 then
			lastLiftAt = now
			popBubbles(pad.Position + Vector3.new(0, 2, 0), 8, 3)
			UIKit.PlaySound("Splash", 1.3)
			local facing = rootPart.CFrame.Rotation
			character:PivotTo(CFrame.new(target) * facing)
			rootPart.AssemblyLinearVelocity = Vector3.zero
			popBubbles(target, 8, 3)
			break
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Drain guide beam: shown while the local player's tank is at or above 95% full.
----------------------------------------------------------------------------------------------------

local drainAnchor: BasePart? = nil
local drainAttachment: Attachment? = nil
local drainRootAttachment: Attachment? = nil
local drainBeam: Beam? = nil
local drainRoot: BasePart? = nil

local function ensureDrainGuide()
	if drainAnchor and drainAnchor.Parent then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanTouch = false
	anchor.CanQuery = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Parent = workspace
	drainAnchor = anchor

	local a1 = Instance.new("Attachment")
	a1.Parent = anchor
	drainAttachment = a1
end

local function updateDrainGuide()
	local run = ClientState.Run :: Types.RunState?
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")

	local wantsGuide = run ~= nil and run.Phase == "Playing" and root ~= nil and run.TankMax > 0 and (run.Tank / run.TankMax) >= DRAIN_FULL_FRACTION

	if not wantsGuide then
		if drainBeam then
			drainBeam.Enabled = false
		end
		return
	end

	ensureDrainGuide()
	;(drainAnchor :: BasePart).CFrame = CFrame.new((run :: Types.RunState).DrainPosition)

	if drainRoot ~= root then
		drainRoot = root :: BasePart
		if drainRootAttachment then
			drainRootAttachment:Destroy()
		end
		local a0 = Instance.new("Attachment")
		a0.Parent = drainRoot
		drainRootAttachment = a0
		if drainBeam then
			drainBeam:Destroy()
		end
		local b = Instance.new("Beam")
		b.Name = "DrainGuide"
		b.Attachment0 = drainRootAttachment
		b.Attachment1 = drainAttachment
		b.Width0 = 0.4
		b.Width1 = 0.15
		b.Color = ColorSequence.new(UIKit.Theme.Colors.Primary)
		b.Transparency = NumberSequence.new(0.35)
		b.LightEmission = 0.7
		b.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		b.TextureMode = Enum.TextureMode.Wrap
		b.TextureLength = 2
		b.TextureSpeed = -3 -- flows toward the drain
		b.FaceCamera = true
		b.Parent = drainRootAttachment
		drainBeam = b
	end
	(drainBeam :: Beam).Enabled = true
end

----------------------------------------------------------------------------------------------------
-- Remaining-grime markers: ✨ on every grime part still left once few remain.
----------------------------------------------------------------------------------------------------

local markedParts: { [BasePart]: BillboardGui } = {}
local cachedGrimeFolder: Folder? = nil
local cachedGrimeArena: Model? = nil

-- ArenaBuilder doesn't publish the grime folder's exact path to clients (only the Model
-- replicates), so we look for a child folder holding grime-shaped parts (parts carrying the
-- MinTool attribute every grime spot has). This is deliberately defensive: see needsFromOthers.
local function findGrimeFolder(arena: Model): Folder?
	if cachedGrimeArena == arena and cachedGrimeFolder and cachedGrimeFolder.Parent then
		return cachedGrimeFolder
	end
	local direct = arena:FindFirstChild("Grime")
	if direct and direct:IsA("Folder") then
		cachedGrimeArena, cachedGrimeFolder = arena, direct
		return direct
	end
	for _, child in arena:GetChildren() do
		if child:IsA("Folder") then
			for _, grandchild in child:GetChildren() do
				if grandchild:IsA("BasePart") and grandchild:GetAttribute("MinTool") ~= nil then
					cachedGrimeArena, cachedGrimeFolder = arena, child
					return child
				end
			end
		end
	end
	return nil
end

local function clearMarker(part: BasePart)
	local gui = markedParts[part]
	if gui then
		gui:Destroy()
		markedParts[part] = nil
	end
end

local function clearAllMarkers()
	for part in markedParts do
		clearMarker(part)
	end
end

local function markPart(part: BasePart)
	if markedParts[part] then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "RemainingMarker"
	gui.Size = UDim2.fromOffset(40, 40)
	gui.StudsOffset = Vector3.new(0, 1, 0)
	gui.AlwaysOnTop = true
	gui.Parent = part
	UIKit.Label({
		Text = "✨",
		Size = UDim2.fromScale(1, 1),
		TextSize = 30,
		Stroke = false,
		Parent = gui,
	})
	markedParts[part] = gui
	part.AncestryChanged:Connect(function(_, parent)
		if not parent then
			clearMarker(part)
		end
	end)
end

local function updateRemainingMarkers()
	local run = ClientState.Run :: Types.RunState?
	local arena = ClientState.GetArena()
	if not run or run.Phase ~= "Playing" or not arena then
		clearAllMarkers()
		return
	end
	local remaining = run.Total - run.Cleaned
	if remaining > Config.Round.MarkerThreshold then
		clearAllMarkers()
		return
	end
	local folder = findGrimeFolder(arena)
	if not folder then
		return
	end
	local seen: { [BasePart]: boolean } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("BasePart") then
			seen[child] = true
			markPart(child)
		end
	end
	for part in markedParts do
		if not seen[part] then
			clearMarker(part)
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Prompts: route to UIKit windows using the attributes LobbyBuilder/ArenaBuilder set.
----------------------------------------------------------------------------------------------------

local buyingTool = false

local function buyTool(index: number)
	if buyingTool then
		return
	end
	buyingTool = true
	local result = ClientState.RunRequest("BuyTool", index)
	buyingTool = false
	local tool = Config.Tools[index]
	if result.Ok then
		UIKit.PlaySound("Coins")
		UIKit.Toast(string.format("%s %s bought!", tool and tool.Icon or "", tool and tool.Name or "Tool"), "Good")
	else
		UIKit.PlaySound("Error")
		UIKit.Toast(result.Error or "Can't buy that yet.", "Bad")
	end
end

----------------------------------------------------------------------------------------------------
-- Paged leaderboards: the arrows (tag "BoardArrow") and the "Next level" prompt flip this client's
-- view of the pages (Page1..PageN in the board's SurfaceGui). Nothing is sent to the server.
----------------------------------------------------------------------------------------------------

local function flipBoard(board: Instance, dir: number)
	local gui = board:FindFirstChildOfClass("SurfaceGui")
	if not gui then
		return
	end
	local pages = {}
	local current = 1
	for i = 1, 20 do
		local page = gui:FindFirstChild("Page" .. i)
		if not page or not page:IsA("GuiObject") then
			break
		end
		pages[i] = page
		if page.Visible then
			current = i
		end
	end
	if #pages < 2 then
		return
	end
	local nextIndex = (current - 1 + dir) % #pages + 1
	for i, page in pages do
		page.Visible = i == nextIndex
	end
	UIKit.PlaySound("Click")
end

local function addBoardArrow(inst: Instance)
	local detector = inst:FindFirstChildOfClass("ClickDetector") or inst:WaitForChild("ClickDetector", 10)
	if not detector or not detector:IsA("ClickDetector") then
		return
	end
	detector.MouseClick:Connect(function(player)
		if player == LocalPlayer and inst.Parent then
			flipBoard(inst.Parent, tonumber(inst:GetAttribute("Dir")) or 1)
		end
	end)
end

local function onPromptTriggered(prompt: ProximityPrompt, player: Player)
	if player ~= LocalPlayer then
		return
	end
	if prompt:GetAttribute("BoardNext") and prompt.Parent then
		flipBoard(prompt.Parent, 1)
		return
	end
	local windowName = prompt:GetAttribute("OpenWindow")
	if type(windowName) == "string" then
		UIKit.OpenWindow(windowName, prompt:GetAttribute("EggId"))
		return
	end
	local toolIndex = prompt:GetAttribute("BuyTool")
	if type(toolIndex) == "number" then
		task.spawn(buyTool, toolIndex)
	end
end

----------------------------------------------------------------------------------------------------
-- Tool shop displays in the arena: owned / next (buyable) / locked, refreshed on every RunState.
----------------------------------------------------------------------------------------------------

local function updateShopDisplays()
	local run = ClientState.Run :: Types.RunState?
	local arena = ClientState.GetArena()
	if not run or not arena then
		return
	end
	for _, inst in arena:GetChildren() do
		if not inst:IsA("BasePart") then
			continue
		end
		local display = string.match(inst.Name, "^ToolDisplay_(%d+)$")
		local tag = string.match(inst.Name, "^PriceTag_(%d+)$")
		local index = tonumber(display or tag)
		local tool = index and Config.Tools[index]
		if not index or not tool then
			continue
		end
		local owned = run.OwnedTools ~= nil and run.OwnedTools[index] == true
		if display then
			local prompt = inst:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Enabled = not owned
			end
		else
			local gui = inst:FindFirstChildWhichIsA("LayerCollector")
			local price = gui and gui:FindFirstChild("Price") :: TextLabel?
			if price then
				local cost = Config.ToolCost(index, run.Level) or 0
				if owned then
					price.Text = "✅ Owned"
					price.TextColor3 = UIKit.Theme.Colors.Good
				else
					price.Text = "💰 " .. UIKit.Short(cost)
					price.TextColor3 = if run.Coins >= cost then UIKit.Theme.Colors.Coin else UIKit.Theme.Colors.Bad
				end
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Lobby ambience: a handful of floating bubbles drifting near the camera.
----------------------------------------------------------------------------------------------------

local lobbyBubbles: { BasePart } = {}
local lastLobbyAmbienceAt = 0

local function stepLobbyAmbience()
	local run = ClientState.Run :: Types.RunState?
	if run ~= nil then
		-- In a run: let any leftover lobby bubbles finish naturally (Debris already scheduled).
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local now = os.clock()
	if now - lastLobbyAmbienceAt < 0.9 or #lobbyBubbles >= MAX_LOBBY_BUBBLES then
		return
	end
	lastLobbyAmbienceAt = now

	local offset = Vector3.new((math.random() - 0.5) * 30, math.random() * 6, (math.random() - 0.5) * 30 - 12)
	local position = camera.CFrame.Position + offset
	local ball = Instance.new("Part")
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.Glass
	ball.Color = Color3.new(1, 1, 1)
	ball.Transparency = 0.5
	ball.Size = Vector3.new(1, 1, 1) * (0.25 + math.random() * 0.35)
	ball.Anchored = false
	ball.CanCollide = false
	ball.CanTouch = false
	ball.CanQuery = false
	ball.CastShadow = false
	ball.CFrame = CFrame.new(position)
	ball.AssemblyLinearVelocity = Vector3.new((math.random() - 0.5) * 1.5, 2 + math.random() * 1.5, (math.random() - 0.5) * 1.5)
	ball.Parent = workspace
	table.insert(lobbyBubbles, ball)
	Debris:AddItem(ball, 6)
	task.delay(6, function()
		local i = table.find(lobbyBubbles, ball)
		if i then
			table.remove(lobbyBubbles, i)
		end
	end)
end

----------------------------------------------------------------------------------------------------
-- Run lifecycle (the run-start banner itself lives in the HUD).
----------------------------------------------------------------------------------------------------

local function onStateChanged(kind: string)
	if kind ~= "Run" then
		return
	end
	updateRemainingMarkers()
	updateShopDisplays()
end

----------------------------------------------------------------------------------------------------
-- Init
----------------------------------------------------------------------------------------------------

function Effects.Init()
	if initialized then
		return
	end
	initialized = true

	ClientState.FX:Connect(onRunFX)
	ClientState.Changed:Connect(onStateChanged)

	for _, inst in CollectionService:GetTagged("SpinY") do
		addSpinPart(inst)
	end
	CollectionService:GetInstanceAddedSignal("SpinY"):Connect(addSpinPart)
	CollectionService:GetInstanceRemovedSignal("SpinY"):Connect(removeSpinPart)

	for _, inst in CollectionService:GetTagged("LiftPad") do
		addLiftPart(inst)
	end
	CollectionService:GetInstanceAddedSignal("LiftPad"):Connect(addLiftPart)
	CollectionService:GetInstanceRemovedSignal("LiftPad"):Connect(removeLiftPart)

	ProximityPromptService.PromptTriggered:Connect(onPromptTriggered)

	for _, inst in CollectionService:GetTagged("BoardArrow") do
		task.spawn(addBoardArrow, inst)
	end
	CollectionService:GetInstanceAddedSignal("BoardArrow"):Connect(function(inst)
		task.spawn(addBoardArrow, inst)
	end)

	RunService.Heartbeat:Connect(function(dt)
		stepSpin(dt)
		stepLift(dt)
		updateDrainGuide()
		stepLobbyAmbience()
	end)

	-- Grime count changes on every Cleaned/Sold push; the marker set only needs to react to those
	-- and to Run replacing wholesale (onStateChanged already covers both via ClientState.Changed).
end

return Effects
