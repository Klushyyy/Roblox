--[[
	Telemetry - tells the server what this player's screen saw, for Analytics.luau (server).

	  * ClientState.Track(key, detail) is how any screen records a moment ("tut.s2", "buy.prompt").
	  * Windows opening are recorded here (UIKit.WindowChanged), and what the player is looking at
	    right now ("Win:Shop", "Tut3", "Cutscene") is sent as a small context, so when somebody
	    leaves the server knows what was on their screen.
	  * Once: the device (phone, tablet, computer, console), that the screen finished loading, the
	    first time they touch a control, and the frame rate about a minute in.
	  * Script errors on this screen are counted (a few per player, so a loop of errors can't flood).

	Moments go out in small batches every few seconds on the Telemetry remote; the server throws
	away anything that isn't in Config.Analytics.ClientEvents / ClientFamilies. If this script is
	missing the game plays exactly the same (ClientState.Track just does nothing).
]]

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))

local Telemetry = {}

local A = Config.Analytics
local SEND_EVERY = 4 -- seconds between batches
local BATCH = 10 -- moments per batch (the server reads at most 12)
local MAX_QUEUE = 40
local CONTEXT_EVERY = 2

local queue: { { string | boolean } } = {}
local remote: RemoteEvent? = nil
local lastContext = ""
local currentWindow: string? = nil
local started = false

local function push(key: string, detail: string?)
	if #queue >= MAX_QUEUE then
		return
	end
	local last = queue[#queue]
	if last and last[1] == key and last[2] == detail then
		return -- the same thing twice in a row
	end
	table.insert(queue, { key, detail or false })
end

function Telemetry.Event(key: string, detail: string?)
	if type(key) == "string" then
		push(key, if type(detail) == "string" then string.sub(detail, 1, 120) else nil)
	end
end

local function flush()
	if not remote or #queue == 0 then
		return
	end
	local batch = {}
	for i = 1, math.min(BATCH, #queue) do
		local item = table.remove(queue, 1) :: any
		table.insert(batch, { item[1], if item[2] == false then nil else item[2] })
	end
	pcall(function()
		(remote :: RemoteEvent):FireServer(batch)
	end)
end

-- What kind of device this is.
local function deviceKind(): string
	local okTen, tenFoot = pcall(function()
		return GuiService:IsTenFootInterface()
	end)
	if okTen and tenFoot == true then
		return "Console"
	end
	local touch = UserInputService.TouchEnabled
	local keyboard = UserInputService.KeyboardEnabled
	if touch and not keyboard then
		local camera = workspace.CurrentCamera
		local size = if camera then camera.ViewportSize else Vector2.new(1000, 700)
		return if math.min(size.X, size.Y) < 600 then "Phone" else "Tablet"
	end
	if UserInputService.GamepadEnabled and not keyboard and not touch then
		return "Console"
	end
	return "Desktop"
end

-- What the player is looking at: an open window, the tutorial, the intro cutscene, or nothing special.
local function contextNow(): string
	if currentWindow and currentWindow ~= "" then
		return "Win:" .. currentWindow
	end
	local tutorial = ClientState.TutorialStep :: any
	if tutorial ~= nil and ClientState.Run ~= nil then
		return "Tut" .. tostring(tutorial)
	end
	local ok, playing = pcall(function()
		return (require(Client:WaitForChild("Cutscene", 2)) :: any).IsPlaying()
	end)
	if ok and playing == true then
		return "Cutscene"
	end
	return ""
end

local function measureFrameRate()
	local frames, elapsed = 0, 0
	local connection
	connection = RunService.RenderStepped:Connect(function(dt)
		frames += 1
		elapsed += dt
		if elapsed >= 10 then
			connection:Disconnect()
			local fps = frames / elapsed
			local bucket = if fps < A.PerfLow then "perf.low" elseif fps < A.PerfMid then "perf.mid" else "perf.high"
			push(bucket, tostring(math.floor(fps + 0.5)))
		end
	end)
end

function Telemetry.Init()
	if started then
		return
	end
	started = true

	ClientState.Track = Telemetry.Event

	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("Remotes", 30)
		local found = folder and folder:WaitForChild("Telemetry", 30)
		if found and found:IsA("RemoteEvent") then
			remote = found
		end
		if not remote then
			return
		end
		while true do
			task.wait(SEND_EVERY)
			flush()
		end
	end)

	push("dev", deviceKind())
	push("client.ready")

	-- The first control they touch (or the first step they take).
	local touched = false
	UserInputService.InputBegan:Connect(function(input)
		if touched or input.UserInputType == Enum.UserInputType.MouseMovement then
			return
		end
		touched = true
		push("client.move")
	end)

	UIKit.WindowChanged:Connect(function(name)
		currentWindow = name
		if type(name) == "string" then
			push("ui.open", name)
		end
	end)

	task.spawn(function()
		while true do
			task.wait(CONTEXT_EVERY)
			local context = contextNow()
			if context ~= lastContext then
				lastContext = context
				push("ctx", context)
			end
		end
	end)

	task.delay(A.PerfAfter, measureFrameRate)

	pcall(function()
		ScriptContext.Error:Connect(function(message: string)
			if type(message) == "string" then
				push("err", message)
			end
		end)
	end)

	-- (the first batch goes straight away, so a player who leaves quickly still counts as loaded)
	task.delay(1.5, flush)
end

return Telemetry
