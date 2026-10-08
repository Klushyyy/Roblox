-- The client's copy of everything the server tells it: permanent data (Meta), the party it is
-- waiting in (Party) and the run it is playing (Run). UI modules read from here and listen to
-- Changed instead of each hooking the remotes themselves.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))
local Types = require(Shared:WaitForChild("Types"))

local ClientState = {}

ClientState.Meta = nil :: Types.MetaState?
ClientState.Party = nil :: Types.PartyState?
ClientState.Run = nil :: Types.RunState?
-- The first-run tutorial (Tutorial.luau): the step it is on while it is running (nil = not running). The HUD hides most of
-- itself while it is on, and shows the rest as the steps introduce it.
ClientState.TutorialStep = nil :: number?
-- True while the tutorial wants the player to open the Upgrade Book (the book's hotkeys only work then).
ClientState.TutorialAllowBook = false :: boolean

-- Analytics hook. Telemetry.luau replaces it when it starts; until then (or if that script is
-- missing) it does nothing, so any screen can call it.
--   Track("tut.s2") / Track("buy.prompt", "VIP") tells the server what the player just saw or did
ClientState.Track = function(_key: string, _detail: string?) end

-- Fired with "Meta", "Party", "Run" or "Tutorial" after that field is replaced / changes.
ClientState.Changed = Util.Signal.new()
-- Fired with (kind: string, data: table) for every RunFX message.
ClientState.FX = Util.Signal.new()
-- Fired with (text: string, kind: string) for every Notify message.
ClientState.Notified = Util.Signal.new()

local initialized = false

function ClientState.Init()
	if initialized then
		return
	end
	initialized = true

	Remotes.Event("MetaState").OnClientEvent:Connect(function(state)
		ClientState.Meta = state
		ClientState.Changed:Fire("Meta")
	end)
	Remotes.Event("PartyState").OnClientEvent:Connect(function(state)
		ClientState.Party = state
		ClientState.Changed:Fire("Party")
	end)
	Remotes.Event("RunState").OnClientEvent:Connect(function(state)
		ClientState.Run = state
		ClientState.Changed:Fire("Run")
	end)
	Remotes.Event("RunFX").OnClientEvent:Connect(function(kind, data)
		ClientState.FX:Fire(kind, data)
	end)
	Remotes.Event("Notify").OnClientEvent:Connect(function(text, kind)
		ClientState.Notified:Fire(text, kind or "Info")
	end)

	-- Ask for the first snapshot in case the server pushed it before we were listening.
	task.spawn(function()
		for _ = 1, 10 do
			local ok, state = pcall(function()
				return Remotes.Function("GetMeta"):InvokeServer()
			end)
			if ok and state then
				if not ClientState.Meta then
					ClientState.Meta = state
					ClientState.Changed:Fire("Meta")
				end
				return
			end
			task.wait(1)
		end
	end)
end

-- Wraps a RemoteFunction call so UI code never errors: always returns a RequestResult.
local function request(remoteName: string, action: string, value: any): Types.RequestResult
	local ok, result = pcall(function()
		return Remotes.Function(remoteName):InvokeServer(action, value)
	end)
	if not ok then
		return { Ok = false, Error = "Couldn't reach the server. Try again." }
	end
	if type(result) ~= "table" then
		return { Ok = false, Error = "Something went wrong." }
	end
	return result
end

-- In-run purchases and leaving: "BuyUpgrade" (id), "BuyTool" (index), "Leave", "ReturnToLobby".
function ClientState.RunRequest(action: string, value: any?): Types.RequestResult
	return request("RunRequest", action, value)
end

-- Permanent actions: "BuyPerk" (id), "Hatch" ({ Egg = id, Count = 1 | 3 }), "Equip" (uid),
-- "Unequip" (uid), "EquipBest", "Delete" (uid).
-- Slow ones get the "Working..." dots (UIKit.Busy: only shown if the wait is over a moment).
local BUSY_TEXT = {
	BuyPerk = "Buying",
	Rebirth = "Rebirthing",
	ClaimDaily = "Claiming your reward",
	ClaimStayBoost = "Claiming",
	RedeemCode = "Checking your code",
	ClaimGroup = "Checking the community",
	SocialDone = "Checking",
	Merge = "Merging",
	Delete = "Deleting",
	EquipBest = "Equipping",
}

function ClientState.MetaRequest(action: string, value: any?): Types.RequestResult
	local text = BUSY_TEXT[action]
	local done: (() -> ())? = nil
	if text then
		local ok, UIKit = pcall(function()
			return require(script.Parent:WaitForChild("UIKit")) :: any
		end)
		if ok then
			done = UIKit.Busy(text)
		end
	end
	local result = request("MetaRequest", action, value)
	if done then
		done()
	end
	return result
end

function ClientState.InRun(): boolean
	return ClientState.Run ~= nil
end

function ClientState.InParty(): boolean
	return ClientState.Party ~= nil
end

-- The dishwasher model the local player is playing in, if it has replicated.
function ClientState.GetArena(): Model?
	local run = ClientState.Run
	if not run then
		return nil
	end
	local arenas = workspace:FindFirstChild("Arenas")
	local arena = arenas and arenas:FindFirstChild(run.ArenaName)
	if arena and arena:IsA("Model") then
		return arena
	end
	return nil
end

function ClientState.LocalPlayer(): Player
	return Players.LocalPlayer
end

-- The lobby is built on every server, a long way above the arenas. The open-air levels (the Backyard)
-- would show its giant lawn hanging in the sky, so while the player is in a run the lobby's parts are
-- made invisible for them alone (LocalTransparencyModifier is never replicated).
task.spawn(function()
	local hidden = false
	while true do
		task.wait(1)
		local wantHidden = ClientState.Run ~= nil
		if wantHidden ~= hidden then
			local lobby = workspace:FindFirstChild("Lobby")
			if lobby then
				hidden = wantHidden
				local n = 0
				for _, d in lobby:GetDescendants() do
					if d:IsA("BasePart") then
						d.LocalTransparencyModifier = if wantHidden then 1 else 0
					end
					n += 1
					if n % 600 == 0 then
						task.wait()
					end
				end
			end
		end
	end
end)

return ClientState
