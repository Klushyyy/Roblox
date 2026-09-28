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
local Bubbles = require(Client:WaitForChild("Bubbles"))
local ShopUI = require(Client:WaitForChild("ShopUI"))

local Effects = {}

local LocalPlayer = Players.LocalPlayer
local initialized = false

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

local MAX_FLOATERS = 24 -- floating +N labels alive at once (local player's own numbers)
local FLOATER_RISE = 3 -- studs
local FLOATER_TIME = 0.7
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

-- A little cloud of soap bubbles that pops out of `position` and drifts up (see Bubbles).
local function popBubbles(position: Vector3, count: number, spread: number)
	Bubbles.Emit(position, {
		Count = count,
		Spread = spread * 0.5,
		Velocity = Vector3.new(0, 5, 0),
		Jitter = 2.5,
		Size = { 0.3, 0.85 },
		Life = { 0.9, 1.7 },
	})
end

----------------------------------------------------------------------------------------------------
-- RunFX handlers
----------------------------------------------------------------------------------------------------

local refreshDuck: (Instance) -> ()
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
		billboardNumber(data.Position, "+" .. UIKit.Short(data.Units), UIKit.Theme.Colors.Primary)
		if data.Golden and data.Bubbles > 0 then
			billboardNumber(data.Position, "+" .. UIKit.Short(data.Bubbles) .. " Bubbles", UIKit.Theme.Colors.Bubble, FLOATER_RISE + 1)
		end
	end
end

local function onDishDone(data: Types.FXDishDone)
	burst(data.Position, UIKit.Theme.Colors.Good, "rbxasset://textures/particles/sparkles_main.dds", 24, 0.8)
	popBubbles(data.Position, 6, 2)
	UIKit.PlaySound("Sparkle")
	billboardNumber(data.Position, "Sparkling!", UIKit.Theme.Colors.Text, FLOATER_RISE + 1)
	if data.By == LocalPlayer.UserId and data.Bonus > 0 then
		billboardNumber(data.Position + Vector3.new(0, 1.4, 0), "+" .. UIKit.Short(data.Bonus) .. " coins", UIKit.Theme.Colors.Coin, FLOATER_RISE + 1.6)
	end
end

-- Foam Cannon splat: a heap of foam blobs on the surface that slowly shrinks while it cleans,
-- fizzing bubbles the whole time.
local function onFoam(data: any)
	local pos = data and data.Position
	if typeof(pos) ~= "Vector3" then
		return
	end
	local normal: Vector3 = if typeof(data.Normal) == "Vector3" and data.Normal.Magnitude > 0.5 then data.Normal.Unit else Vector3.yAxis
	local radius = math.clamp(tonumber(data.Radius) or 3, 1, 12)
	local duration = math.clamp(tonumber(data.Duration) or 2.5, 0.5, 6)
	local u = normal:Cross(if math.abs(normal.Y) > 0.9 then Vector3.xAxis else Vector3.yAxis).Unit
	local v = normal:Cross(u)
	local folder = Instance.new("Folder")
	folder.Name = "FoamSplat"
	folder.Parent = workspace
	local blobs: { { Part: Part, Size: number, Base: Vector3 } } = {}
	local count = 9 + math.floor(radius * 2)
	for i = 1, count do
		local a = math.random() * math.pi * 2
		local d = math.sqrt(math.random()) * radius * 0.8
		local size = radius * (0.3 + math.random() * 0.35) * (if i == 1 then 1.4 else 1)
		local base = pos + (u * math.cos(a) + v * math.sin(a)) * (if i == 1 then 0 else d) + normal * size * 0.15
		local blob = Instance.new("Part")
		blob.Shape = Enum.PartType.Ball
		blob.Material = Enum.Material.SmoothPlastic
		blob.Color = Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(225, 205, 255), math.random() * 0.4)
		blob.Size = Vector3.one * 0.05
		blob.Anchored = true
		blob.CanCollide = false
		blob.CanQuery = false
		blob.CanTouch = false
		blob.CastShadow = false
		blob.CFrame = CFrame.new(base)
		blob.Parent = folder
		table.insert(blobs, { Part = blob, Size = size, Base = base })
	end
	Bubbles.Emit(pos + normal, { Count = 8, Spread = radius * 0.5, Velocity = normal * 4 + Vector3.new(0, 2, 0), Jitter = 3, Size = { 0.3, 0.9 }, Life = { 0.8, 1.6 } })
	task.spawn(function()
		local t = 0
		local fizz = 0
		while t < duration and folder.Parent do
			local dt = RunService.Heartbeat:Wait()
			t += dt
			fizz += dt
			local grow = math.min(t / 0.15, 1)
			local shrink = 1 - math.clamp((t - duration * 0.35) / (duration * 0.65), 0, 1)
			for i, b in blobs do
				local wobble = 1 + 0.06 * math.sin(t * 7 + i)
				b.Part.Size = Vector3.one * math.max(b.Size * grow * shrink * wobble, 0.05)
			end
			if fizz > 0.25 then
				fizz = 0
				Bubbles.Emit(pos + normal * 0.5, { Count = 2, Spread = radius * 0.6, Velocity = normal * 2, Jitter = 1.5, Size = { 0.25, 0.7 }, Life = { 0.6, 1.2 } })
			end
		end
		folder:Destroy()
	end)
	UIKit.PlaySound("Splash", 1.1 + math.random() * 0.2)
end

local function onSold(data: any)
	if data and data.Pet then
		-- A pet sold its bag: a small floater over you instead of a toast (pets sell often).
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			billboardNumber(root.Position + Vector3.new(0, 3, 0), "+" .. UIKit.Short(data.Coins) .. " coins", UIKit.Theme.Colors.Coin, FLOATER_RISE + 1)
		end
		UIKit.PlaySound("Coins", 1.2)
		return
	end
	UIKit.PlaySound("Coins")
	UIKit.Toast("+" .. UIKit.Commas(data.Coins) .. " coins", "Good")
end

local function onTankFull()
	UIKit.PlaySound("Error")
end

-- A lobby bubble popped (anyone's): a splash of little bubbles; the popper gets the number.
local function onLobbyPop(data: any)
	local pos = data and data.Position
	if typeof(pos) ~= "Vector3" then
		return
	end
	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - pos).Magnitude > 160 then
		return
	end
	local golden = data.Golden == true
	burst(pos, if golden then UIKit.Theme.Colors.Coin else Color3.fromRGB(170, 225, 255), "rbxasset://textures/particles/sparkles_main.dds", if golden then 22 else 10, 0.6)
	Bubbles.Emit(pos, { Count = if golden then 14 else 8, Spread = 1.2, Velocity = Vector3.new(0, 2, 0), Jitter = 4, Size = { 0.3, 0.8 }, Life = { 0.5, 1.1 } })
	if data.By == LocalPlayer.UserId then
		UIKit.PlaySound("Pop", if golden then 0.8 else 1 + math.random() * 0.25)
		if golden then
			UIKit.PlaySound("Sparkle")
		end
		local amount = tonumber(data.Amount) or 1
		billboardNumber(pos, "+" .. amount .. (if amount == 1 then " Bubble" else " Bubbles"), if golden then UIKit.Theme.Colors.Coin else UIKit.Theme.Colors.Bubble, FLOATER_RISE + 1)
	end
end

-- You found a rubber duck.
local function onDuck(data: any)
	local pos = data and data.Position
	if typeof(pos) ~= "Vector3" then
		return
	end
	burst(pos, Color3.fromRGB(255, 215, 60), "rbxasset://textures/particles/sparkles_main.dds", if data.All then 40 else 20, 0.9)
	Bubbles.Emit(pos, { Count = 12, Spread = 1.5, Velocity = Vector3.new(0, 3, 0), Jitter = 3, Size = { 0.3, 0.9 }, Life = { 0.8, 1.6 } })
	-- A squeaky "quack": the pop, pitched up, twice.
	UIKit.PlaySound("Pop", 1.9)
	task.delay(0.12, function()
		UIKit.PlaySound("Pop", 2.3)
	end)
	UIKit.PlaySound("Sparkle")
	billboardNumber(pos + Vector3.new(0, 1.5, 0), string.format("Quack! %d/%d", tonumber(data.Count) or 0, tonumber(data.Total) or 0), Color3.fromRGB(255, 215, 60), FLOATER_RISE + 2)
end

-- Hides a rubber duck (for this player only) once they've found it.
refreshDuck = function(inst: Instance)
	local id = inst:GetAttribute("DuckId")
	if type(id) ~= "string" then
		return
	end
	local found = false
	local list = LocalPlayer:GetAttribute("DucksFound")
	if type(list) == "string" then
		for piece in string.gmatch(list, "[^,]+") do
			if piece == id then
				found = true
				break
			end
		end
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = if found then 1 else 0
		elseif d:IsA("ClickDetector") then
			d.MaxActivationDistance = if found then 0 else 24
		end
	end
end

local function onRunFX(kind: string, data: any)
	if kind == "LobbyPop" then
		onLobbyPop(data)
	elseif kind == "Duck" then
		onDuck(data)
	elseif kind == "Cleaned" then
		onCleaned(data)
	elseif kind == "Foam" then
		onFoam(data)
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
-- here replicates.
----------------------------------------------------------------------------------------------------

local LIFT_RADIUS = 4.2

local liftPads: { [BasePart]: boolean } = {}

local function addLiftPart(inst: Instance)
	if inst:IsA("BasePart") then
		liftPads[inst] = true
	end
end

local function removeLiftPart(inst: Instance)
	liftPads[inst :: BasePart] = nil
end

-- Bubble spouts (the Rebirth Fountain): a gentle stream of bubbles near the camera.
local spoutClock = 0
local function stepSpouts(dt: number)
	spoutClock += dt
	if spoutClock < 0.2 then
		return
	end
	spoutClock = 0
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	for _, spout in CollectionService:GetTagged("BubbleSpout") do
		if spout:IsA("BasePart") and (spout.Position - camera.CFrame.Position).Magnitude < 150 then
			Bubbles.Emit(spout.Position, { Count = 1, Spread = 0.6, Velocity = Vector3.new(0, 7, 0), Jitter = 1.2, Size = { 0.4, 1.1 }, Life = { 1.6, 2.6 }, Rise = 1.5 })
		end
	end
end

-- Bubbles streaming up every lift column near the camera.
local liftBubbleClock = 0
local function stepLiftBubbles(dt: number)
	liftBubbleClock += dt
	if liftBubbleClock < 0.12 then
		return
	end
	liftBubbleClock = 0
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	for pad in liftPads do
		if pad.Parent and (pad.Position - camera.CFrame.Position).Magnitude < 180 then
			local target = pad:GetAttribute("LiftTo")
			local height = if typeof(target) == "Vector3" then math.max(8, target.Y - pad.Position.Y) else 30
			Bubbles.Emit(pad.Position + Vector3.new(0, 0.8, 0), {
				Count = 1,
				Spread = 2.2,
				Velocity = Vector3.new(0, height * 1.4, 0),
				Jitter = 0.8,
				Size = { 0.4, 1.2 },
				Life = { 2.2, 3.2 },
				Rise = 3,
			})
		end
	end
end

-- Bubble columns (like Minecraft's bubble elevators). Anywhere inside a lift's column (walking in,
-- jumping in, or flying in with the bubble jets) the bubbles push you up; you keep full control
-- of your movement the whole way, so you can steer around or out. At the top you bob just above
-- the rack's height and, if you're not steering, drift gently onto the rack.
local LIFT_RISE_SPEED = 22 -- studs per second upward inside the column
local LIFT_OVERSHOOT = 4 -- the column's top is this far above the landing height
local LIFT_DRIFT_SPEED = 8 -- drift toward the landing at the top when you're not steering
local LIFT_TOP_EXTRA = 3 -- the column keeps you hovering this far above its top before letting go

local inColumn: BasePart? = nil

local function stepLift(_dt: number)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		inColumn = nil
		return
	end
	local rootPart = root :: BasePart
	local pos = rootPart.Position

	-- Which column (if any) are we in?
	local column: BasePart? = nil
	local target: Vector3? = nil
	for pad in liftPads do
		if not pad.Parent then
			liftPads[pad] = nil
			continue
		end
		local to = pad:GetAttribute("LiftTo")
		if typeof(to) ~= "Vector3" then
			continue
		end
		local d = pos - pad.Position
		local topY = to.Y + LIFT_OVERSHOOT
		if Vector3.new(d.X, 0, d.Z).Magnitude <= LIFT_RADIUS and d.Y > -1 and pos.Y < topY + LIFT_TOP_EXTRA then
			column, target = pad, to
			break
		end
	end

	if not column or not target then
		inColumn = nil
		return
	end
	if inColumn ~= column then
		-- Just entered: a splash of bubbles, and off the ground if we were standing.
		inColumn = column
		popBubbles(pos, 8, 2.5)
		UIKit.PlaySound("Splash", 1.3)
		if humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end

	local topY = target.Y + LIFT_OVERSHOOT
	local v = rootPart.AssemblyLinearVelocity
	local vy: number
	if pos.Y < topY - 1 then
		vy = math.max(v.Y, LIFT_RISE_SPEED) -- never slows down the bubble jets
	else
		vy = (topY - pos.Y) * 4 + math.sin(os.clock() * 4) * 1.5 -- bob at the top
	end
	-- Horizontal movement is the player's own (air control); at the top, drift onto the rack
	-- unless they're steering somewhere else.
	local horizontal = Vector3.new(v.X, 0, v.Z)
	if pos.Y >= topY - 2 and humanoid.MoveDirection.Magnitude < 0.1 then
		local to = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
		if to.Magnitude > 0.5 then
			horizontal = to.Unit * math.min(LIFT_DRIFT_SPEED, to.Magnitude * 3)
		end
	end
	rootPart.AssemblyLinearVelocity = Vector3.new(horizontal.X, vy, horizontal.Z)
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
	local result = ShopUI.GetTool(index)
	buyingTool = false
	local tool = Config.Tools[index]
	if not result then
		return -- the tool's pass was offered instead
	end
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
	-- The drawn button this click target sits over (in the board's SurfaceGui).
	local function button(): GuiObject?
		local board = inst.Parent
		local gui = board and board:FindFirstChildOfClass("SurfaceGui")
		local name = inst:GetAttribute("Button")
		local b = gui and type(name) == "string" and gui:FindFirstChild(name)
		return if b and b:IsA("GuiObject") then b else nil
	end
	local function setLook(size: number, color: Color3)
		local b = button()
		if b then
			UIKit.Tween(b, { Size = UDim2.fromOffset(size, size), BackgroundColor3 = color }, 0.12)
		end
	end
	local IDLE, HOVER = Color3.fromRGB(255, 205, 70), Color3.fromRGB(255, 228, 130)
	detector.MouseHoverEnter:Connect(function(player)
		if player == LocalPlayer then
			setLook(66, HOVER)
		end
	end)
	detector.MouseHoverLeave:Connect(function(player)
		if player == LocalPlayer then
			setLook(60, IDLE)
		end
	end)
	detector.MouseClick:Connect(function(player)
		if player == LocalPlayer and inst.Parent then
			flipBoard(inst.Parent, tonumber(inst:GetAttribute("Dir")) or 1)
			setLook(54, HOVER)
			task.delay(0.12, function()
				setLook(60, IDLE)
			end)
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
		UIKit.OpenWindow(windowName, prompt:GetAttribute("WindowArg") or prompt:GetAttribute("EggId"))
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
					price.Text = "Owned"
					price.TextColor3 = UIKit.Theme.Colors.Good
				else
					price.Text = UIKit.Short(cost) .. " coins"
					price.TextColor3 = if run.Coins >= cost then UIKit.Theme.Colors.Coin else UIKit.Theme.Colors.Bad
				end
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Lobby ambience: a handful of floating bubbles drifting near the camera.
----------------------------------------------------------------------------------------------------

local lastLobbyAmbienceAt = 0

-- The lobby's big floating bubbles (tag "FloatBubble", placed by the server): bobbed here, locally,
-- each with a glowing glint on its camera-facing side.
type FloatBubble = { Part: BasePart, Glint: Part, Base: Vector3, Phase: number, Speed: number, Amp: number }
local floatBubbles: { [BasePart]: FloatBubble } = {}

local function addFloatBubble(inst: Instance)
	if not inst:IsA("BasePart") or floatBubbles[inst] then
		return
	end
	local glint = Instance.new("Part")
	glint.Name = "BubbleGlint"
	glint.Shape = Enum.PartType.Ball
	glint.Material = Enum.Material.Neon
	glint.Color = Color3.new(1, 1, 1)
	glint.Transparency = 0.15
	glint.Size = Vector3.one * math.max(inst.Size.X * 0.18, 0.1)
	glint.Anchored = true
	glint.CanCollide = false
	glint.CanQuery = false
	glint.CanTouch = false
	glint.CastShadow = false
	glint.Parent = workspace.CurrentCamera
	-- Poppable lobby bubbles (tag "PopBubble") bob less so they stay where the server thinks they are.
	local amp = if CollectionService:HasTag(inst, "PopBubble") then 0.3 else 1
	local speed = 0.35 + math.random() * 0.25
	floatBubbles[inst] = { Part = inst, Glint = glint, Base = inst.Position, Phase = math.random() * math.pi * 2, Speed = speed * (if amp < 1 then 2.2 else 1), Amp = amp }
end

local function removeFloatBubble(inst: Instance)
	local fb = floatBubbles[inst :: BasePart]
	if fb then
		fb.Glint:Destroy()
		floatBubbles[inst :: BasePart] = nil
	end
end

local floatParts: { BasePart } = {}
local floatCFrames: { CFrame } = {}
local floatClock = 0
local function stepFloatBubbles(dt: number)
	floatClock += dt
	local camera = workspace.CurrentCamera
	if not camera or next(floatBubbles) == nil then
		return
	end
	local camCF = camera.CFrame
	table.clear(floatParts)
	table.clear(floatCFrames)
	for inst, fb in floatBubbles do
		if not inst.Parent then
			removeFloatBubble(inst)
			continue
		end
		local t = floatClock * fb.Speed + fb.Phase
		local pos = fb.Base + Vector3.new(math.sin(t) * 2.2, math.sin(t * 1.3) * 1.8, math.cos(t * 0.9) * 2.2) * fb.Amp
		local size = inst.Size.X
		local toCam = camCF.Position - pos
		toCam = if toCam.Magnitude > 1e-3 then toCam.Unit else Vector3.zAxis
		table.insert(floatParts, inst)
		table.insert(floatCFrames, CFrame.new(pos))
		table.insert(floatParts, fb.Glint)
		table.insert(floatCFrames, CFrame.new(pos + (toCam * 0.3 + camCF.UpVector * 0.25 - camCF.RightVector * 0.22) * size))
	end
	workspace:BulkMoveTo(floatParts, floatCFrames, Enum.BulkMoveMode.FireCFrameChanged)
end

-- Big, slow soap bubbles drifting up around the camera while you're in the lobby.
local function stepLobbyAmbience()
	if ClientState.Run ~= nil then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local now = os.clock()
	if now - lastLobbyAmbienceAt < 0.45 then
		return
	end
	lastLobbyAmbienceAt = now
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	-- Mostly ahead of the camera, spread left/right, starting near the floor.
	local right = Vector3.new(-flat.Z, 0, flat.X)
	local ahead = 10 + math.random() * 35
	local side = (math.random() - 0.5) * 50
	local position = camera.CFrame.Position + flat * ahead + right * side
	position = Vector3.new(position.X, math.max(1, camera.CFrame.Position.Y - 8 + math.random() * 6), position.Z)
	Bubbles.Emit(position, {
		Count = 1,
		Spread = 0,
		Velocity = Vector3.new(0, 1.5, 0),
		Jitter = 0.6,
		Size = { 0.8, 2.2 },
		Life = { 6, 9 },
		Rise = 0.6,
	})
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
		stepLiftBubbles(dt)
		stepSpouts(dt)
		updateDrainGuide()
		stepLobbyAmbience()
	end)
	RunService.RenderStepped:Connect(function(dt)
		stepFloatBubbles(dt)
	end)

	for _, inst in CollectionService:GetTagged("FloatBubble") do
		addFloatBubble(inst)
	end
	CollectionService:GetInstanceAddedSignal("FloatBubble"):Connect(addFloatBubble)
	CollectionService:GetInstanceRemovedSignal("FloatBubble"):Connect(removeFloatBubble)
	for _, inst in CollectionService:GetTagged("PopBubble") do
		addFloatBubble(inst)
	end
	CollectionService:GetInstanceAddedSignal("PopBubble"):Connect(addFloatBubble)
	CollectionService:GetInstanceRemovedSignal("PopBubble"):Connect(removeFloatBubble)

	-- Rubber ducks this player already found are hidden (for them only).
	for _, inst in CollectionService:GetTagged("RubberDuck") do
		refreshDuck(inst)
	end
	CollectionService:GetInstanceAddedSignal("RubberDuck"):Connect(function(inst)
		task.defer(refreshDuck, inst)
	end)
	LocalPlayer:GetAttributeChangedSignal("DucksFound"):Connect(function()
		for _, inst in CollectionService:GetTagged("RubberDuck") do
			refreshDuck(inst)
		end
	end)

	-- Grime count changes on every Cleaned/Sold push; the marker set only needs to react to those
	-- and to Run replacing wholesale (onStateChanged already covers both via ClientState.Changed).
end

return Effects
