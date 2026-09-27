-- BubbleJets: inside a run, hold jump while in the air to fly up on a jet of soap bubbles.
-- Fuel (a few seconds) refills while you stand on something. The HUD shows the fuel bar from the
-- LocalPlayer's "JetFuel" attribute (0..1), so this module owns no UI.
--
-- The character is network-owned by the client, so setting its velocity here is all it takes.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))

local FUEL_SECONDS = 2.6 -- full tank of flight
local REFILL_PER_SECOND = 1.3 -- seconds of flight regained per second on the ground
local RISE_SPEED = 34 -- studs/s upward while jetting
local HOLD_WINDOW = 0.2 -- JumpRequest repeats while jump is held; this bridges the gaps

local BubbleJets = {}
local initialized = false

local player = Players.LocalPlayer
local fuel = FUEL_SECONDS
local lastJumpRequest = -1
local emitter: ParticleEmitter? = nil

local function jumpHeld(): boolean
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA) then
		return true
	end
	-- Touch (and anything else): JumpRequest keeps firing while the jump button is held.
	return os.clock() - lastJumpRequest < HOLD_WINDOW
end

local function ensureEmitter(root: BasePart): ParticleEmitter
	local e = emitter
	if e and e.Parent == root then
		return e
	end
	local new = Instance.new("ParticleEmitter")
	new.Name = "BubbleJet"
	new.Texture = "rbxasset://textures/particles/forcefield_glow_main.dds"
	new.Color = ColorSequence.new(Color3.fromRGB(200, 240, 255), Color3.fromRGB(150, 210, 255))
	new.Transparency = NumberSequence.new(0.2, 1)
	new.Size = NumberSequence.new(1.2, 0.3)
	new.Lifetime = NumberRange.new(0.5, 0.9)
	new.Speed = NumberRange.new(10, 16)
	new.SpreadAngle = Vector2.new(25, 25)
	new.EmissionDirection = Enum.NormalId.Bottom
	new.Rate = 0
	new.LightEmission = 0.4
	new.Parent = root
	emitter = new
	return new
end

local function step(dt: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not ClientState.InRun() or not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		fuel = FUEL_SECONDS
		player:SetAttribute("JetFuel", nil)
		if emitter then
			emitter.Rate = 0
		end
		return
	end

	local airborne = humanoid.FloorMaterial == Enum.Material.Air
	local jetting = airborne and jumpHeld() and fuel > 0
	if jetting then
		fuel = math.max(0, fuel - dt)
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(v.X, math.max(v.Y, RISE_SPEED), v.Z)
	elseif not airborne then
		fuel = math.min(FUEL_SECONDS, fuel + REFILL_PER_SECOND * dt)
	end
	ensureEmitter(root).Rate = if jetting then 40 else 0
	player:SetAttribute("JetFuel", fuel / FUEL_SECONDS)
end

function BubbleJets.Init()
	if initialized then
		return
	end
	initialized = true
	UserInputService.JumpRequest:Connect(function()
		lastJumpRequest = os.clock()
	end)
	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[BubbleJets] " .. tostring(err))
		end
	end)
end

return BubbleJets
