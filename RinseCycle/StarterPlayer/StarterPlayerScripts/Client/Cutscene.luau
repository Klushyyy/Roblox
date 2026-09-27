--[[
	Cutscene - plays the run-start cutscene (CutsceneScene) when your party's dishwasher starts.

	  * Fades to black, builds the scene far from everything (client-only parts, so each player sees
	    their own and nobody waits for anybody), and flies the camera through it with cinematic
	    letterbox bars. The HUD is hidden while it plays.
	  * SKIP (bottom-right; also Space / Enter / gamepad B) fades out early. Either way it fades to
	    black, the scene is removed, the camera comes back to your character and it fades in: you're
	    in the dishwasher, and the run is already going (skippers get a head start).
	  * Only plays when you join a run at its start, not when rejoining mid-run.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))
local Scene = require(Client:WaitForChild("CutsceneScene"))
local Bubbles = require(Client:WaitForChild("Bubbles"))

local Cutscene = {}

local LocalPlayer = Players.LocalPlayer
local SCENE_ORIGIN = CFrame.new(8000, 400, 0) -- far from the lobby and every arena
local FADE = 0.45
local MAX_START_AGE = 12 -- seconds into a run after which we don't start the cutscene

local initialized = false
local playing = false
local skipRequested = false
local lastRunKey: string? = nil

local gui: ScreenGui
local black: Frame
local topBar: Frame
local bottomBar: Frame
local skipButton: TextButton

local function tweenBlack(to: number, seconds: number)
	UIKit.Tween(black, { BackgroundTransparency = to }, seconds)
	task.wait(seconds)
end

-- Hide every other ScreenGui of ours while the cutscene plays; returns a restore function.
local function hideHud(): () -> ()
	local hidden: { ScreenGui } = {}
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		for _, g in playerGui:GetChildren() do
			if g:IsA("ScreenGui") and g ~= gui and g.Enabled and not string.find(g.Name, "Probe") then
				g.Enabled = false
				table.insert(hidden, g)
			end
		end
	end
	return function()
		for _, g in hidden do
			if g.Parent then
				g.Enabled = true
			end
		end
	end
end

local function setControls(enabled: boolean)
	pcall(function()
		local module = LocalPlayer:WaitForChild("PlayerScripts"):FindFirstChild("PlayerModule")
		if module then
			local controls = (require(module :: any) :: any):GetControls()
			if enabled then
				controls:Enable()
			else
				controls:Disable()
			end
		end
	end)
end

local function play(levelIndex: number)
	if playing then
		return
	end
	playing = true
	skipRequested = false
	local camera = Workspace.CurrentCamera

	gui.Enabled = true
	black.BackgroundTransparency = 1
	topBar.Size = UDim2.new(1, 0, 0, 0)
	bottomBar.Size = UDim2.new(1, 0, 0, 0)
	skipButton.Visible = false
	tweenBlack(0, 0.25)

	local restoreHud = hideHud()
	setControls(false)
	local scene
	local ok = pcall(function()
		scene = Scene.Build(levelIndex, SCENE_ORIGIN, Workspace)
	end)
	if not ok or not scene or not camera then
		restoreHud()
		setControls(true)
		tweenBlack(1, FADE)
		gui.Enabled = false
		playing = false
		return
	end
	local oldType, oldFov = camera.CameraType, camera.FieldOfView
	camera.CameraType = Enum.CameraType.Scriptable
	scene:Update(0)
	local cf, fov = scene:Camera(0)
	camera.CFrame, camera.FieldOfView = cf, fov

	-- Letterbox in, fade up, SKIP appears.
	UIKit.Tween(topBar, { Size = UDim2.new(1, 0, 0.1, 0) }, 0.5)
	UIKit.Tween(bottomBar, { Size = UDim2.new(1, 0, 0.1, 0) }, 0.5)
	tweenBlack(1, FADE)
	skipButton.Visible = true

	local t = 0
	local bubbleClock = 0
	local inside = scene:InsidePoints()
	local conn = RunService.RenderStepped:Connect(function(dt)
		t += dt
		-- Once the dishwasher starts, it fills with bubbles.
		if t > 16.2 then
			bubbleClock += dt
			if bubbleClock > 0.08 then
				bubbleClock = 0
				local at = inside[math.random(1, #inside)]
				pcall(Bubbles.Emit, at, { Count = 2, Spread = 0.5, Velocity = Vector3.new(0, 1, 0), Jitter = 0.8, Size = { 0.08, 0.25 }, Life = { 0.8, 1.6 }, Rise = 1 })
			end
		end
		local okStep = pcall(function()
			scene:Update(t)
			local c, f = scene:Camera(t)
			camera.CFrame, camera.FieldOfView = c, f
		end)
		if not okStep then
			skipRequested = true
		end
	end)
	while t < Scene.Duration - FADE and not skipRequested do
		task.wait()
	end
	skipButton.Visible = false
	tweenBlack(0, FADE)
	conn:Disconnect()
	pcall(function()
		scene:Destroy()
	end)
	camera.CameraType = if oldType == Enum.CameraType.Scriptable then Enum.CameraType.Custom else oldType
	camera.FieldOfView = oldFov
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
	restoreHud()
	setControls(true)
	UIKit.Tween(topBar, { Size = UDim2.new(1, 0, 0, 0) }, 0.4)
	UIKit.Tween(bottomBar, { Size = UDim2.new(1, 0, 0, 0) }, 0.4)
	tweenBlack(1, FADE + 0.15)
	gui.Enabled = false
	playing = false
end

function Cutscene.IsPlaying(): boolean
	return playing
end

function Cutscene.Skip()
	if playing then
		skipRequested = true
	end
end

function Cutscene.Init()
	if initialized then
		return
	end
	initialized = true

	local screen, root = UIKit.CreateScreen("Cutscene", 60)
	gui = screen
	gui.Enabled = false
	local function bar(name: string, anchorY: number): Frame
		local f = Instance.new("Frame")
		f.Name = name
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0, anchorY)
		f.Position = UDim2.fromScale(0, anchorY)
		f.Size = UDim2.new(1, 0, 0, 0)
		f.ZIndex = 5
		f.Parent = root
		return f
	end
	topBar = bar("TopBar", 0)
	bottomBar = bar("BottomBar", 1)
	black = Instance.new("Frame")
	black.Name = "Fade"
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	black.BorderSizePixel = 0
	black.Size = UDim2.fromScale(1, 1)
	black.BackgroundTransparency = 1
	black.ZIndex = 20
	black.Parent = root
	skipButton = UIKit.Button({
		Name = "Skip",
		Text = "Skip  ⏭",
		Size = UDim2.fromOffset(170, 56),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -24, 1, -24),
		Color = Color3.fromRGB(60, 66, 80),
		TextSize = 24,
		Visible = false,
		Parent = root,
		OnClick = Cutscene.Skip,
	})
	skipButton.ZIndex = 10
	UIKit.LayoutChanged:Connect(function()
		local safe = UIKit.SafeInsets()
		skipButton.Position = UDim2.new(1, -(24 + safe.Right), 1, -(24 + safe.Bottom))
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if not playing or processed then
			return
		end
		local k = input.KeyCode
		if k == Enum.KeyCode.Space or k == Enum.KeyCode.Return or k == Enum.KeyCode.ButtonB or k == Enum.KeyCode.ButtonA then
			Cutscene.Skip()
		end
	end)

	-- A new run we're starting from the top: play the cutscene for its level.
	ClientState.Changed:Connect(function(kind)
		if kind ~= "Run" then
			return
		end
		local run = ClientState.Run :: Types.RunState?
		if not run then
			lastRunKey = nil
			return
		end
		local key = tostring(run.ArenaName) .. ":" .. tostring(run.StartedAt)
		if key == lastRunKey then
			return
		end
		lastRunKey = key
		local age = Workspace:GetServerTimeNow() - (tonumber(run.StartedAt) or 0)
		if run.Phase == "Playing" and age < MAX_START_AGE then
			task.spawn(play, run.Level)
		end
	end)
end

return Cutscene
