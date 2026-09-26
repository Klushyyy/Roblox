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

local SprayController = {}

local LocalPlayer = Players.LocalPlayer
local ScrubEvent = Remotes.Event("Scrub")

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

local MAX_AIM_DISTANCE = 250
local RING_TRANSPARENCY = 0.35
local RING_THICKNESS = 0.15
local HOLD_TIP_AFTER_CLICKS = 10
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
local holdTipShown = false
local lastSendAt = 0
local lastClickPulseUntil = 0 -- visuals stay on this long after a single (non-Hold) click
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
	lastClickPulseUntil = 0
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

local function toolName(index: number): string
	local tool = Config.Tools[index]
	return if tool then tool.Name else "a bigger tool"
end

local function sendScrub(hitPosition: Vector3, holding: boolean, pitchJitter: number)
	ScrubEvent:FireServer(hitPosition, holding)
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

	raycastParams.FilterDescendantsInstances = { arenaModel }
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

	-- Scrub ring: tool colour in reach, red and dimmer out of reach.
	local r = ring :: BasePart
	r.CFrame = CFrame.new(hitPos, hitPos + result.Normal) * CFrame.Angles(0, math.rad(90), 0)
	r.Size = Vector3.new(RING_THICKNESS, stats.Radius * 2, stats.Radius * 2)
	if inReach then
		r.Color = toolColor
		r.Transparency = RING_TRANSPARENCY
	else
		r.Color = UIKit.Theme.Colors.Bad
		r.Transparency = 0.5
	end

	-- MinTool lock hint: shown whenever the aimed part needs a tool we don't have yet.
	local minTool = hitPart:GetAttribute("MinTool")
	local needsTool = type(minTool) == "number" and minTool > stats.ToolIndex
	if needsTool and hintAnchor and hintBillboard and hintLabel then
		hintAnchor.CFrame = CFrame.new(hitPos)
		hintLabel.Text = "🔒 Needs " .. toolName(minTool :: number)
		hintBillboard.Enabled = true
	elseif hintBillboard then
		hintBillboard.Enabled = false
	end

	local tankFull = run.Tank >= run.TankMax
	local canSend = pressed and inReach and not needsTool and not tankFull

	local now = os.clock()
	local sending = false

	if canSend then
		if stats.Hold then
			if now - lastSendAt >= Config.Round.ScrubSendInterval then
				lastSendAt = now
				sendScrub(hitPos, true, math.random())
			end
			sending = true
		else
			-- Single pulse: the actual send happens on the input's rising edge (onPressBegan), so
			-- here we only decide whether the visuals (beam/splash) should still be showing.
			sending = now < lastClickPulseUntil
		end
	elseif tankFull and pressed then
		if now - lastTankFullToastAt > TANK_FULL_TOAST_GAP then
			lastTankFullToastAt = now
			UIKit.Toast("TANK FULL — go to the drain!", "Bad")
		end
	end

	if beam then
		local b = beam :: Beam
		b.Enabled = sending
		b.Width0 = 0.2 + (stats.ToolIndex - 1) * 0.12
		b.Width1 = b.Width0
		b.Color = ColorSequence.new(toolColor)
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
	raycastParams.FilterDescendantsInstances = { arenaModel }
	local ray = aimRay(camera)
	local result = workspace:Raycast(ray.Origin, ray.Direction.Unit * MAX_AIM_DISTANCE, raycastParams)
	if not result then
		return
	end
	local distance = (result.Position - (root :: BasePart).Position).Magnitude
	local minTool = result.Instance:GetAttribute("MinTool")
	local needsTool = type(minTool) == "number" and (minTool :: number) > run.Stats.ToolIndex
	if distance > run.Stats.Reach or needsTool or run.Tank >= run.TankMax then
		return
	end

	lastSendAt = os.clock()
	lastClickPulseUntil = os.clock() + Config.Round.ClickPulseSeconds
	sendScrub(result.Position, false, math.random())

	clickCount += 1
	if not holdTipShown and clickCount >= HOLD_TIP_AFTER_CLICKS then
		holdTipShown = true
		UIKit.Toast("Tip: buy ✊ Hold to Scrub!", "Info")
	end
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
