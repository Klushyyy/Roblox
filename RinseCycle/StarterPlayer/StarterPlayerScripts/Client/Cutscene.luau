--[[
	Cutscene - the fade into a run (there is no cutscene any more; the name is kept so the rest of
	the client, which covers the screen with Cutscene.Cover / Uncover, doesn't change).

	  * When your party launches, the screen goes black before the server teleports you, so the
	    teleport is never seen.
	  * When the run starts, the camera is put back on your character in the dishwasher and the
	    screen fades in. Reporting "Loaded" starts the run clock.
	  * Leaving / returning to the lobby uses the same cover.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Cutscene = {}

local LocalPlayer = Players.LocalPlayer
local FADE = 0.6
local MAX_START_AGE = 12 -- seconds into a run after which we just report in

local initialized = false
local playing = false
local lastRunKey: string? = nil

local gui: ScreenGui
local black: Frame
local loadingLabel: TextLabel

local covered = false
local coverToken = 0

-- Tells the server we're in: the run clock starts with the first player to get past the fade.
local function reportLoaded()
	task.spawn(function()
		pcall(ClientState.RunRequest, "Loaded")
	end)
end

local function tweenBlack(to: number, seconds: number)
	UIKit.Tween(black, { BackgroundTransparency = to }, seconds)
	task.wait(seconds)
end

-- The run has started: make sure the camera is on us in the dishwasher, then fade in.
local function play(_levelIndex: number)
	if playing then
		return
	end
	playing = true
	covered = false
	coverToken += 1
	gui.Enabled = true
	loadingLabel.Visible = false
	if black.BackgroundTransparency > 0.05 then
		tweenBlack(0, 0.2)
	end
	-- give the teleport and the room a moment to settle behind the black
	task.wait(0.5)
	local camera = Workspace.CurrentCamera
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if camera then
		if camera.CameraType == Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Custom
		end
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
	reportLoaded()
	tweenBlack(1, FADE)
	gui.Enabled = false
	playing = false
end

-- Fades to black (0.35 s) with an optional line of text, and lifts itself after `timeout` seconds
-- if nothing else does. Returns once the screen is fully black.
function Cutscene.Cover(text: string?, timeout: number?)
	if playing or not gui then
		return
	end
	coverToken += 1
	local token = coverToken
	local already = covered and black.BackgroundTransparency < 0.05
	covered = true
	gui.Enabled = true
	loadingLabel.Text = text or ""
	loadingLabel.Visible = text ~= nil
	if not already then
		tweenBlack(0, 0.35)
	end
	task.delay(timeout or 12, function()
		if token == coverToken and covered and not playing then
			Cutscene.Uncover()
		end
	end)
end

function Cutscene.Uncover()
	if not covered or playing or not gui then
		return
	end
	coverToken += 1
	local token = coverToken
	covered = false
	loadingLabel.Visible = false
	UIKit.Tween(black, { BackgroundTransparency = 1 }, 0.45)
	task.delay(0.5, function()
		if token == coverToken and not playing and not covered then
			gui.Enabled = false
		end
	end)
end

function Cutscene.IsCovered(): boolean
	return covered
end

function Cutscene.IsPlaying(): boolean
	return playing
end

function Cutscene.Init()
	if initialized then
		return
	end
	initialized = true

	local screen, root = UIKit.CreateScreen("Cutscene", 60)
	gui = screen
	gui.Enabled = false
	black = Instance.new("Frame")
	black.Name = "Fade"
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	black.BorderSizePixel = 0
	black.Size = UDim2.fromScale(1, 1)
	black.BackgroundTransparency = 1
	black.ZIndex = 20
	black.Parent = root
	loadingLabel = UIKit.Label({
		Name = "Loading",
		Text = "",
		TextSize = 34,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(700, 60),
		Visible = false,
		ZIndex = 21,
		Parent = root,
	})

	-- Our party is launching: go black now, before the server teleports us into the dishwasher. If
	-- no run follows (the start failed), the cover lifts again.
	ClientState.Changed:Connect(function(kind)
		if kind ~= "Party" then
			return
		end
		local party = ClientState.Party :: Types.PartyState?
		if party and party.Status == "Launching" and not ClientState.Run then
			task.spawn(Cutscene.Cover, nil, 20)
		elseif not party and covered and not playing then
			task.delay(2, function()
				if covered and not playing and not ClientState.Run then
					Cutscene.Uncover()
				end
			end)
		end
	end)

	-- A new run we're starting from the top: fade into it.
	ClientState.Changed:Connect(function(kind)
		if kind ~= "Run" then
			return
		end
		local run = ClientState.Run :: Types.RunState?
		if not run then
			lastRunKey = nil
			-- Back in the lobby: lift the cover the Leave / Back to Lobby buttons put up.
			if covered then
				task.delay(0.35, Cutscene.Uncover)
			end
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
		elseif run.Phase == "Playing" then
			reportLoaded() -- joined mid-run: we're in straight away
		end
	end)
end

return Cutscene
