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
local Bubbles = require(Client:WaitForChild("Bubbles"))

local FUEL_SECONDS = 2.6 -- full tank of flight
local REFILL_PER_SECOND = 1.3 -- seconds of flight regained per second on the ground
local RISE_SPEED = 34 -- studs/s upward while jetting
local HOLD_WINDOW = 0.2 -- JumpRequest repeats while jump is held; this bridges the gaps
local BUBBLES_PER_SECOND = 38

local BubbleJets = {}
local initialized = false

local player = Players.LocalPlayer
local fuel = FUEL_SECONDS
local lastJumpRequest = -1
local emitAccumulator = 0
local lastFuelShown: number? = nil

local touchJumpHeld = false -- the on-screen jump button (phones / tablets) is being held

-- Watches Roblox's own touch jump button (PlayerGui.TouchGui...JumpButton) while it's held. On
-- phones JumpRequest only fires once per press, so it can't tell "held" on its own.
local function watchTouchJump()
	local gui = player:WaitForChild("PlayerGui")
	local function hook(button: Instance)
		if not button:IsA("GuiButton") or button:GetAttribute("JetHooked") then
			return
		end
		button:SetAttribute("JetHooked", true)
		button.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				touchJumpHeld = true
			end
		end)
		button.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.Touch then
				touchJumpHeld = false
			end
		end)
	end
	local function scan(root: Instance)
		for _, d in root:GetDescendants() do
			if d.Name == "JumpButton" then
				hook(d)
			end
		end
	end
	scan(gui)
	gui.DescendantAdded:Connect(function(d)
		if d.Name == "JumpButton" then
			hook(d)
		end
	end)
end

local function jumpHeld(humanoid: Humanoid): boolean
	if UserInputService:GetFocusedTextBox() then
		return false
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA) then
		return true
	end
	-- Phones: the jump button itself, or the Jump flag Roblox's controls keep on while it's held.
	if touchJumpHeld or humanoid.Jump then
		return true
	end
	-- Anything else: JumpRequest repeating while jump is held.
	return os.clock() - lastJumpRequest < HOLD_WINDOW
end

-- A stream of real 3D bubbles pouring out under the character (see Bubbles).
local function emitJet(root: BasePart, dt: number)
	emitAccumulator += dt * BUBBLES_PER_SECOND
	local n = math.floor(emitAccumulator)
	if n <= 0 then
		return
	end
	emitAccumulator -= n
	local v = root.AssemblyLinearVelocity
	Bubbles.Emit(root.Position - Vector3.new(0, 2.6, 0) - root.CFrame.LookVector * 0.6, {
		Count = n,
		Spread = 0.45,
		Velocity = Vector3.new(v.X * 0.25, -9, v.Z * 0.25),
		Jitter = 2.2,
		Size = { 0.35, 1.0 },
		Life = { 0.8, 1.5 },
		Rise = 4,
	})
end

local function setFuel(value: number?)
	-- Only write the attribute when the shown value changes (the HUD listens to it).
	if value == nil then
		if lastFuelShown ~= nil then
			lastFuelShown = nil
			player:SetAttribute("JetFuel", nil)
		end
		return
	end
	local rounded = math.floor(value * 50 + 0.5) / 50
	if rounded ~= lastFuelShown then
		lastFuelShown = rounded
		player:SetAttribute("JetFuel", rounded)
	end
end

local function step(dt: number)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not ClientState.InRun() or not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		fuel = FUEL_SECONDS
		emitAccumulator = 0
		setFuel(nil)
		return
	end

	local airborne = humanoid.FloorMaterial == Enum.Material.Air
	local jetting = airborne and jumpHeld(humanoid) and fuel > 0
	if jetting then
		fuel = math.max(0, fuel - dt)
		-- Ease up to the climb speed (a smooth lift-off rather than a snap).
		local v = root.AssemblyLinearVelocity
		local vy = if v.Y < RISE_SPEED then v.Y + (RISE_SPEED - v.Y) * math.min(1, 12 * dt) else v.Y
		root.AssemblyLinearVelocity = Vector3.new(v.X, vy, v.Z)
	elseif not airborne then
		fuel = math.min(FUEL_SECONDS, fuel + REFILL_PER_SECOND * dt)
	end
	if jetting then
		emitJet(root, dt)
	else
		emitAccumulator = 0
	end
	setFuel(fuel / FUEL_SECONDS)
end

function BubbleJets.Init()
	if initialized then
		return
	end
	initialized = true
	UserInputService.JumpRequest:Connect(function()
		lastJumpRequest = os.clock()
	end)
	task.spawn(watchTouchJump)
	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warn("[BubbleJets] " .. tostring(err))
		end
	end)
end

return BubbleJets
