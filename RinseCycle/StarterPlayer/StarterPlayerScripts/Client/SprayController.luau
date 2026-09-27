-- SprayController: aiming, spray input, spray visuals, and sending Scrub to the server.
--
-- Active only while ClientState.Run.Phase == "Playing" and the run's arena has replicated in.
-- Aim comes from the mouse on PC, or the screen centre (with a crosshair) on touch/gamepad, cast
-- as a ray Include-filtered to just the arena Model. One Heartbeat connection drives everything so
-- there is exactly one place that decides whether to send, one place that moves the visuals, and
-- one place that cleans up (run end, character death, respawn).
--
-- The server is the authority on whether a Scrub lands: this module only decides whether it is
-- worth SENDING one (aim exists, in reach, tool is enough, tank isn't full) so we don't spam
-- packets the server would reject anyway, and so the local visuals never lie about what's about
-- to happen.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))
local Bubbles = require(Client:WaitForChild("Bubbles"))

local SprayController = {}

local LocalPlayer = Players.LocalPlayer
local ScrubEvent = Remotes.Event("Scrub")

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

local MAX_AIM_DISTANCE = 250
local RING_TRANSPARENCY = 0.35
local RING_THICKNESS = 0.15
local TANK_FULL_TOAST_GAP = 1.5 -- don't spam the toast every frame while stuck at a full tank
local SPLASH_EMIT_COUNT = 6
local TOUCH_BUTTON_SIZE = 132
local TOUCH_BUTTON_MARGIN = 20
local JUMP_ZONE_CLEARANCE = 300 -- keep the SPRAY button above Roblox's bottom-right jump button

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

local initialized = false

local active = false -- Run exists, Phase == "Playing", arena replicated
local arenaModel: Model? = nil
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Include
raycastParams.IgnoreWater = true

local mouseHeld = false
local r2Held = false
local touchHeld = false

local clickCount = 0
local lastSendAt = 0
local lastTankFullToastAt = 0

-- Visuals, built lazily and reused for the whole session.
local ring: BasePart? = nil
local ringAttachment: Attachment? = nil
local beam: Beam? = nil
local handAttachment: Attachment? = nil
local handPart: BasePart? = nil
local splashEmitter: ParticleEmitter? = nil
local hintAnchor: BasePart? = nil
local hintBillboard: BillboardGui? = nil
local hintLabel: TextLabel? = nil
-- Health bar over the dirt spot under the aim (drains as the server's HP attribute drops).
local hpAnchor: BasePart? = nil
local hpBillboard: BillboardGui? = nil
local hpFill: Frame? = nil
-- Pressure Washer line: a thin glowing blade on the surface, with two beams fanning out to its ends.
local linePart: BasePart? = nil
local lineEnds: { Attachment } = {}
local lineBeams: { Beam } = {}
local lastSudsAt = 0
local lastFoamAt = 0

-- Touch-only UI.
local touchGui: ScreenGui? = nil
local touchRoot: Frame? = nil
local sprayButton: TextButton? = nil
local crosshair: Frame? = nil

local characterConns: { RBXScriptConnection } = {}

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

-- Fired when ClientState.Changed listens; kept local so combo/click bookkeeping resets per run.
local function resetPerRunState()
	clickCount = 0
	lastSendAt = 0
end

local function findHandPart(character: Model): BasePart?
	local hand = character:FindFirstChild("RightHand") -- R15
	if hand and hand:IsA("BasePart") then
		return hand
	end
	local arm = character:FindFirstChild("Right Arm") -- R6
	if arm and arm:IsA("BasePart") then
		return arm
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root :: BasePart
	end
	return nil
end

----------------------------------------------------------------------------------------------------
-- Visual builders (created once, reused and repositioned every frame)
----------------------------------------------------------------------------------------------------

local function ensureRing()
	if ring and ring.Parent then
		return
	end
	local part = Instance.new("Part")
	part.Name = "ScrubRing"
	part.Shape = Enum.PartType.Cylinder
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1 -- hidden until the first valid aim
	part.Size = Vector3.new(RING_THICKNESS, 1, 1)
	part.Color = Color3.new(1, 1, 1)

	local attach = Instance.new("Attachment")
	attach.Name = "BeamTarget"
	attach.Parent = part

	local splash = Instance.new("ParticleEmitter")
	splash.Name = "Splash"
	splash.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	splash.Lifetime = NumberRange.new(0.2, 0.4)
	splash.Speed = NumberRange.new(4, 9)
	splash.Rate = 0 -- emits only via :Emit()
	splash.SpreadAngle = Vector2.new(35, 35)
	splash.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 0) })
	splash.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	splash.LightEmission = 0.6
	splash.Parent = attach

	part.Parent = workspace
	ring = part
	ringAttachment = attach
	splashEmitter = splash
end

local function ensureBeam(character: Model)
	local hand = findHandPart(character)
	if not hand then
		return
	end
	if handPart ~= hand or not beam or not beam.Parent then
		if handAttachment then
			handAttachment:Destroy()
		end
		if beam then
			beam:Destroy()
		end
		handPart = hand

		local origin = Instance.new("Attachment")
		origin.Name = "SprayOrigin"
		origin.Position = Vector3.new(0, 0, -0.2)
		origin.Parent = hand
		handAttachment = origin

		ensureRing()
		local b = Instance.new("Beam")
		b.Name = "SprayBeam"
		b.Attachment0 = origin
		b.Attachment1 = ringAttachment
		b.Width0 = 0.25
		b.Width1 = 0.25
		b.LightEmission = 1
		b.LightInfluence = 0
		b.FaceCamera = true
		b.Texture = "rbxasset://textures/particles/smoke_main.dds"
		b.TextureMode = Enum.TextureMode.Wrap
		b.TextureLength = 0.6
		b.TextureSpeed = 2.5
		b.Enabled = false
		b.Parent = origin
		beam = b
	end
end

local function ensureLine()
	if linePart and linePart.Parent and handAttachment and #lineBeams == 2 and lineBeams[1].Attachment0 == handAttachment then
		return
	end
	if not linePart or not linePart.Parent then
		local part = Instance.new("Part")
		part.Name = "WasherLine"
		part.Material = Enum.Material.Neon
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Transparency = 1
		part.Size = Vector3.new(4, 0.12, 0.9)
		part.Parent = workspace
		linePart = part
		table.clear(lineEnds)
		for i = 1, 2 do
			local a = Instance.new("Attachment")
			a.Name = "LineEnd" .. i
			a.Parent = part
			lineEnds[i] = a
		end
	end
	for _, b in lineBeams do
		b:Destroy()
	end
	table.clear(lineBeams)
	if not handAttachment then
		return
	end
	for i = 1, 2 do
		local b = Instance.new("Beam")
		b.Attachment0 = handAttachment
		b.Attachment1 = lineEnds[i]
		b.Width0 = 0.15
		b.Width1 = 0.35
		b.LightEmission = 1
		b.LightInfluence = 0
		b.FaceCamera = true
		b.Transparency = NumberSequence.new(0.1, 0.5)
		b.Texture = "rbxasset://textures/particles/smoke_main.dds"
		b.TextureMode = Enum.TextureMode.Wrap
		b.TextureLength = 0.5
		b.TextureSpeed = 4
		b.Enabled = false
		b.Parent = handAttachment
		lineBeams[i] = b
	end
end

local function hideLine()
	if linePart then
		linePart.Transparency = 1
	end
	for _, b in lineBeams do
		b.Enabled = false
	end
end

-- A foam blob flying from the hand to the target in a short arc (the splat itself comes back from
-- the server as a "Foam" FX, so everyone in the party sees it).
local function launchFoam(from: Vector3, to: Vector3, color: Color3)
	local blob = Instance.new("Part")
	blob.Name = "FoamBlob"
	blob.Shape = Enum.PartType.Ball
	blob.Material = Enum.Material.SmoothPlastic
	blob.Color = Color3.new(1, 1, 1):Lerp(color, 0.15)
	blob.Size = Vector3.one * 1.3
	blob.Anchored = true
	blob.CanCollide = false
	blob.CanQuery = false
	blob.CanTouch = false
	blob.CastShadow = false
	blob.CFrame = CFrame.new(from)
	blob.Parent = workspace
	local flight = math.clamp((to - from).Magnitude / 90, 0.12, 0.35)
	local arc = math.min(4, (to - from).Magnitude * 0.08)
	task.spawn(function()
		local t = 0
		while t < flight and blob.Parent do
			t += RunService.Heartbeat:Wait()
			local k = math.min(t / flight, 1)
			local pos = from:Lerp(to, k) + Vector3.new(0, math.sin(k * math.pi) * arc, 0)
			blob.CFrame = CFrame.new(pos)
			if math.random() < 0.5 then
				Bubbles.Emit(pos, { Count = 1, Spread = 0.3, Velocity = Vector3.new(0, 1, 0), Jitter = 1, Size = { 0.25, 0.6 }, Life = { 0.4, 0.8 } })
			end
		end
		blob:Destroy()
	end)
end

local function ensureHealthBar()
	if hpAnchor and hpAnchor.Parent then
		return
	end
	local part = Instance.new("Part")
	part.Name = "DirtHealthAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Parent = workspace
	hpAnchor = part

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DirtHealth"
	billboard.Size = UDim2.fromOffset(90, 14)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.Parent = part
	hpBillboard = billboard

	local back = Instance.new("Frame")
	back.Size = UDim2.fromScale(1, 1)
	back.BackgroundColor3 = UIKit.Theme.Colors.PanelDark
	back.BorderSizePixel = 0
	UIKit.Corner(back, 999)
	UIKit.Stroke(back, UIKit.Theme.Colors.Ink, 2)
	back.Parent = billboard
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = UIKit.Theme.Colors.Good
	fill.BorderSizePixel = 0
	UIKit.Corner(fill, 999)
	fill.Parent = back
	hpFill = fill
end

-- Shows the bar over `part` if it's a dirt spot (it carries HP/MaxHP attributes), else hides it.
local function updateHealthBar(part: BasePart?)
	if not hpBillboard or not hpAnchor or not hpFill then
		return
	end
	local hp = part and part:GetAttribute("HP")
	local maxHp = part and part:GetAttribute("MaxHP")
	if not part or not part.Parent or type(hp) ~= "number" or type(maxHp) ~= "number" or maxHp <= 0 then
		hpBillboard.Enabled = false
		return
	end
	local fraction = math.clamp(hp / maxHp, 0, 1)
	hpAnchor.CFrame = CFrame.new(part.Position)
	hpFill.Size = UDim2.fromScale(math.max(fraction, 0.04), 1)
	hpFill.BackgroundColor3 = UIKit.Theme.Colors.Bad:Lerp(UIKit.Theme.Colors.Good, fraction)
	hpBillboard.Enabled = true
end

local function ensureHint()
	if hintAnchor and hintAnchor.Parent then
		return
	end
	local part = Instance.new("Part")
	part.Name = "SprayHintAnchor"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(0.2, 0.2, 0.2)
	part.Parent = workspace
	hintAnchor = part

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "MinToolHint"
	billboard.Size = UDim2.fromOffset(220, 44)
	billboard.StudsOffset = Vector3.new(0, 1.2, 0)
	billboard.AlwaysOnTop = true
	billboard.Enabled = false
	billboard.Parent = part
	hintBillboard = billboard

	hintLabel = UIKit.Label({
		Size = UDim2.fromScale(1, 1),
		TextSize = 22,
		TextColor3 = UIKit.Theme.Colors.Text,
		Parent = billboard,
	})
end

-- Touch SPRAY button + PC/gamepad crosshair, placed just above Roblox's bottom-right jump button.
local function ensureTouchUI()
	if touchGui and touchGui.Parent then
		return
	end
	touchGui, touchRoot = UIKit.CreateScreen("Spray", 5)

	local cross = UIKit.New("Frame", {
		Name = "Crosshair",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.25,
		Visible = false,
		Parent = touchRoot,
	}) :: Frame
	UIKit.Corner(cross, 999)
	UIKit.Stroke(cross, UIKit.Theme.Colors.Stroke, 2, 0.3)
	crosshair = cross

	sprayButton = UIKit.IconButton({
		Name = "SprayButton",
		Icon = "💧",
		Label = "SPRAY",
		Color = UIKit.Theme.Colors.Primary,
		Size = UDim2.fromOffset(TOUCH_BUTTON_SIZE, TOUCH_BUTTON_SIZE),
		AnchorPoint = Vector2.new(1, 1),
		Visible = false,
		Sound = false, -- the scrub sound plays instead of a click
		Parent = touchRoot,
	})

	local function reposition()
		local insets = UIKit.SafeInsets()
		local pos = UDim2.new(
			1,
			-(TOUCH_BUTTON_MARGIN + insets.Right),
			1,
			-(JUMP_ZONE_CLEARANCE + TOUCH_BUTTON_MARGIN + insets.Bottom)
		)
		;(sprayButton :: TextButton).Position = pos
	end
	reposition()
	UIKit.LayoutChanged:Connect(reposition)

	local button = sprayButton :: TextButton
	button.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			touchHeld = true
		end
	end)
	button.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			touchHeld = false
		end
	end)
end

local function updateTouchUIVisibility()
	if not sprayButton or not crosshair then
		return
	end
	local touch = UIKit.IsTouch()
	local gamepad = UIKit.IsGamepad()
	sprayButton.Visible = active and touch
	crosshair.Visible = active and (touch or gamepad)
	if not sprayButton.Visible then
		touchHeld = false
	end
end

----------------------------------------------------------------------------------------------------
-- Hiding / showing
----------------------------------------------------------------------------------------------------

local function hideVisuals()
	if ring then
		ring.Transparency = 1
	end
	if beam then
		beam.Enabled = false
	end
	if hintBillboard then
		hintBillboard.Enabled = false
	end
	if hpBillboard then
		hpBillboard.Enabled = false
	end
	hideLine()
end

local function cleanupForRunEnd()
	hideVisuals()
	mouseHeld = false
	r2Held = false
	touchHeld = false
end

----------------------------------------------------------------------------------------------------
-- Aiming
----------------------------------------------------------------------------------------------------

-- Only dishes and dirt can be aimed at, so walls, rack floors and invisible safety walls never
-- swallow the aim ray. Falls back to the whole arena for arenas built without those folders.
local function aimTargets(arena: Model): { Instance }
	local targets: { Instance } = {}
	for _, name in { "Dishes", "Grime" } do
		local folder = arena:FindFirstChild(name)
		if folder then
			table.insert(targets, folder)
		end
	end
	if #targets == 0 then
		table.insert(targets, arena)
	end
	return targets
end

local function aimRay(camera: Camera): Ray
	local touchOrGamepad = UIKit.IsTouch() or UIKit.IsGamepad()
	if touchOrGamepad then
		local size = camera.ViewportSize
		return camera:ViewportPointToRay(size.X * 0.5, size.Y * 0.5)
	end
	local loc = UserInputService:GetMouseLocation()
	return camera:ViewportPointToRay(loc.X, loc.Y)
end

----------------------------------------------------------------------------------------------------
-- Sending
----------------------------------------------------------------------------------------------------

-- The cheapest tool that can clean dirt needing `tier`.
local function toolName(tier: number): string
	for _, tool in Config.Tools do
		if (tool.Tier or 1) >= tier then
			return tool.Name
		end
	end
	return "a bigger tool"
end

local function sendScrub(hitPosition: Vector3, holding: boolean, pitchJitter: number, extra: { [string]: any }?)
	ScrubEvent:FireServer(hitPosition, holding, extra)
	UIKit.PlaySound("Scrub", 0.9 + pitchJitter * 0.25)
	if splashEmitter then
		splashEmitter:Emit(SPLASH_EMIT_COUNT)
	end
end

----------------------------------------------------------------------------------------------------
-- Per-frame update
----------------------------------------------------------------------------------------------------

local function onHeartbeat(dt: number)
	if not active then
		return
	end
	local run = ClientState.Run :: Types.RunState?
	if not run or run.Phase ~= "Playing" then
		return
	end
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local camera = workspace.CurrentCamera
	if not character or not root or not root:IsA("BasePart") or not camera or not arenaModel or not arenaModel.Parent then
		hideVisuals()
		return
	end
	ensureBeam(character)
	ensureRing()
	ensureHint()
	ensureHealthBar()

	raycastParams.FilterDescendantsInstances = aimTargets(arenaModel :: Model)
	local ray = aimRay(camera)
	local result = workspace:Raycast(ray.Origin, ray.Direction.Unit * MAX_AIM_DISTANCE, raycastParams)

	local pressed = mouseHeld or r2Held or touchHeld
	local stats = run.Stats

	if not result then
		hideVisuals()
		return
	end

	local hitPart = result.Instance
	local hitPos = result.Position
	local distance = (hitPos - (root :: BasePart).Position).Magnitude
	local inReach = distance <= stats.Reach
	local toolColor = (Config.Tools[stats.ToolIndex] or Config.Tools[1]).Color

	local mode = stats.Mode or "Scrub"
	local toolIndex = stats.ToolIndex
	local normal = result.Normal
	local r = ring :: BasePart

	-- Aim marker. Scrub / Spray: a ring the size of the cleaning circle. Foam: a fainter ring the
	-- size of the splat. Line: the washer's blade, turned with the camera, lying on the surface.
	local lineDir: Vector3? = nil
	if mode == "Line" then
		r.Transparency = 1
		r.CFrame = CFrame.new(hitPos, hitPos + normal) * CFrame.Angles(0, math.rad(90), 0) -- splash source
		ensureLine()
		local right = camera.CFrame.RightVector
		local dir = right - normal * right:Dot(normal)
		dir = if dir.Magnitude > 1e-3 then dir.Unit else normal:Cross(Vector3.xAxis).Unit
		lineDir = dir
		local len = stats.LineLength or 5
		local lp = linePart :: BasePart
		lp.Size = Vector3.new(len, 0.12, stats.LineWidth or 0.9)
		lp.CFrame = CFrame.fromMatrix(hitPos + normal * 0.08, dir, normal)
		lp.Color = if inReach then toolColor else UIKit.Theme.Colors.Bad
		lp.Transparency = if inReach then 0.3 else 0.6
		lineEnds[1].Position = Vector3.new(-len / 2, 0, 0)
		lineEnds[2].Position = Vector3.new(len / 2, 0, 0)
	else
		hideLine()
		r.CFrame = CFrame.new(hitPos, hitPos + normal) * CFrame.Angles(0, math.rad(90), 0)
		r.Size = Vector3.new(RING_THICKNESS, stats.Radius * 2, stats.Radius * 2)
		if inReach then
			r.Color = toolColor
			r.Transparency = if mode == "Foam" then 0.6 else RING_TRANSPARENCY
		else
			r.Color = UIKit.Theme.Colors.Bad
			r.Transparency = 0.5
		end
	end

	updateHealthBar(hitPart)

	-- MinTool lock hint: shown whenever the aimed part needs a tool we don't have yet.
	local minTool = hitPart:GetAttribute("MinTool")
	local needsTool = type(minTool) == "number" and minTool > (stats.Tier or stats.ToolIndex)
	if needsTool and hintAnchor and hintBillboard and hintLabel then
		hintAnchor.CFrame = CFrame.new(hitPos)
		hintLabel.Text = "🐢 A " .. toolName(minTool :: number) .. " cleans this much faster"
		hintBillboard.Enabled = true
	elseif hintBillboard then
		hintBillboard.Enabled = false
	end

	local tankFull = run.Tank >= run.TankMax
	local canSend = pressed and inReach and not tankFull

	local now = os.clock()
	local sending = false

	if canSend then
		if mode == "Foam" then
			-- One blob per FoamInterval while held.
			if now - lastFoamAt >= (stats.FoamInterval or 0.4) then
				lastFoamAt = now
				local from = if handAttachment then handAttachment.WorldPosition else (root :: BasePart).Position
				launchFoam(from, hitPos, toolColor)
				sendScrub(hitPos, true, math.random(), { Normal = normal })
			end
		elseif now - lastSendAt >= Config.Round.ScrubSendInterval then
			lastSendAt = now
			sendScrub(hitPos, true, math.random(), if lineDir then { Dir = lineDir, Normal = normal } else nil)
			sending = true
		else
			sending = true
		end
		-- Scrubbing tools froth up suds right on the dish.
		if sending and mode == "Scrub" and now - lastSudsAt > 0.12 then
			lastSudsAt = now
			Bubbles.Emit(hitPos + normal * 0.3, { Count = 2, Spread = stats.Radius * 0.6, Velocity = normal * 2 + Vector3.new(0, 1, 0), Jitter = 1.2, Size = { 0.2, 0.55 }, Life = { 0.5, 1.0 }, Rise = 2 })
		end
	elseif tankFull and pressed then
		if now - lastTankFullToastAt > TANK_FULL_TOAST_GAP then
			lastTankFullToastAt = now
			UIKit.Toast("TANK FULL! Go sell at the drain!", "Bad")
		end
	end

	-- Water stream: only the Spray nozzle has one; the washer fans out to its line; scrubbing tools
	-- work right on the dish.
	if beam then
		local b = beam :: Beam
		b.Enabled = sending and mode == "Spray"
		b.Width0 = 0.2 + (toolIndex - 1) * 0.08
		b.Width1 = b.Width0 * 1.6
		b.Color = ColorSequence.new(toolColor)
	end
	for _, lb in lineBeams do
		lb.Enabled = sending and mode == "Line"
		lb.Color = ColorSequence.new(toolColor:Lerp(Color3.new(1, 1, 1), 0.4))
	end
end

-- The single-click (non-Hold) rising edge is handled on input, not in the Heartbeat, so a very
-- short tap always registers even if the render thread is briefly behind.
local function onPressBegan()
	if not active then
		return
	end
	local run = ClientState.Run :: Types.RunState?
	if not run or run.Phase ~= "Playing" or run.Stats.Hold then
		return
	end
	-- Re-validate against the last known aim by re-raycasting right now, so a tap while moving the
	-- mouse doesn't scrub whatever was under the crosshair a frame ago.
	local camera = workspace.CurrentCamera
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not camera or not root or not root:IsA("BasePart") or not arenaModel or not arenaModel.Parent then
		return
	end
	raycastParams.FilterDescendantsInstances = aimTargets(arenaModel :: Model)
	local ray = aimRay(camera)
	local result = workspace:Raycast(ray.Origin, ray.Direction.Unit * MAX_AIM_DISTANCE, raycastParams)
	if not result then
		return
	end
	local distance = (result.Position - (root :: BasePart).Position).Magnitude
	if distance > run.Stats.Reach or run.Tank >= run.TankMax then
		return
	end

	lastSendAt = os.clock()
	sendScrub(result.Position, false, math.random())

	clickCount += 1
end

----------------------------------------------------------------------------------------------------
-- Input wiring
----------------------------------------------------------------------------------------------------

local function onInputBegan(input: InputObject, processed: boolean)
	if processed then
		return
	end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseHeld = true
		onPressBegan()
	elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
		r2Held = true
		onPressBegan()
	end
end

local function onInputEnded(input: InputObject, _processed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		mouseHeld = false
	elseif input.KeyCode == Enum.KeyCode.ButtonR2 then
		r2Held = false
	end
end

----------------------------------------------------------------------------------------------------
-- Run / character lifecycle
----------------------------------------------------------------------------------------------------

local function disconnectCharacterConns()
	for _, c in characterConns do
		c:Disconnect()
	end
	table.clear(characterConns)
end

local function onCharacterAdded(character: Model)
	disconnectCharacterConns()
	handPart = nil -- force ensureBeam to rebuild for the new character
	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		table.insert(
			characterConns,
			humanoid.Died:Connect(function()
				cleanupForRunEnd()
			end)
		)
	end
end

local function refreshActive()
	local run = ClientState.Run :: Types.RunState?
	local wasActive = active
	if run and run.Phase == "Playing" then
		arenaModel = ClientState.GetArena()
		active = arenaModel ~= nil
	else
		arenaModel = nil
		active = false
	end
	if not wasActive and active then
		resetPerRunState()
	end
	if not active then
		cleanupForRunEnd()
	end
	updateTouchUIVisibility()
end

----------------------------------------------------------------------------------------------------
-- Init
----------------------------------------------------------------------------------------------------

function SprayController.Init()
	if initialized then
		return
	end
	initialized = true

	ensureTouchUI()
	ensureRing()
	ensureHint()

	ClientState.Changed:Connect(function(kind)
		if kind == "Run" then
			refreshActive()
		end
	end)
	refreshActive()

	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputEnded:Connect(onInputEnded)
	UIKit.LayoutChanged:Connect(updateTouchUIVisibility)

	if LocalPlayer.Character then
		onCharacterAdded(LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(onCharacterAdded)
	LocalPlayer.CharacterRemoving:Connect(function()
		disconnectCharacterConns()
		cleanupForRunEnd()
	end)

	RunService.Heartbeat:Connect(onHeartbeat)
end

return SprayController
