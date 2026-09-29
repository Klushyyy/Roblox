--[[
	RunServers - each party plays its run in its own private server.

	  * Lobby side: when a party launches, Launch() teleports the whole party into a freshly reserved
	    server of this same place, with { Mode = "Run", Level, Party = userIds, Lobby = JobId } as
	    teleport data. The lobby server stays a lobby: no dishwashers get built there, so it never
	    carries anybody else's run.
	  * Run side (IsRunServer): the party's players arrive, their profiles load (DataService waits
	    for the lobby server to release each save), and once everyone is in (or after ARRIVE_WAIT)
	    RoundService.StartRound runs for them as usual. When a player's run ends (results, Leave, Back
	    to Lobby), SendHome teleports them back to the lobby server they came from (or any public
	    server if that one is full or gone).
	  * Studio, unpublished places, or a failed teleport: everything falls back to playing the run
	    in this server, exactly as before.

	The workspace attribute "RunServer" tells clients they're in a run server (they stay behind a
	loading cover until the run starts, and while heading home).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DataService = require(script.Parent:WaitForChild("DataService"))
local RoundService = require(script.Parent:WaitForChild("RoundService"))
local Characters = require(script.Parent:WaitForChild("Characters"))

local RunServers = {}

local ARRIVE_WAIT = 25 -- seconds to wait for the rest of the party before starting without them
local PROFILE_WAIT = 40 -- seconds to wait for an arriving player's save to load
local HOME_RETRIES = 2

-- A reserved server (made by TeleportOptions.ShouldReserveServer) has a PrivateServerId but no owner.
RunServers.IsRunServer = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0

local function canTeleport(): boolean
	return game.PlaceId ~= 0 and not RunService:IsStudio()
end

----------------------------------------------------------------------------------------------------
-- Lobby side
----------------------------------------------------------------------------------------------------

-- Sends `players` to a new private server for a run of `level`. Returns true if the teleport was
-- started; false means "play it here instead".
function RunServers.Launch(players: { Player }, level: number): boolean
	if RunServers.IsRunServer or not canTeleport() or #players == 0 then
		return false
	end
	local userIds = {}
	for _, p in players do
		table.insert(userIds, p.UserId)
	end
	local ok, err = pcall(function()
		local options = Instance.new("TeleportOptions")
		options.ShouldReserveServer = true
		options:SetTeleportData({ Mode = "Run", Level = level, Party = userIds, Lobby = game.JobId })
		TeleportService:TeleportAsync(game.PlaceId, players, options)
	end)
	if not ok then
		warn("[RunServers] couldn't reserve a run server, playing here: " .. tostring(err))
	end
	return ok
end

----------------------------------------------------------------------------------------------------
-- Run side
----------------------------------------------------------------------------------------------------

type Plan = { Level: number, Party: { number }, Lobby: string? }
local plan: Plan? = nil
local arrived: { [number]: Player } = {}
local started = false
local lobbyJobId: string? = nil

-- Teleports a player home to the lobby (their old server when possible).
function RunServers.SendHome(player: Player)
	if not player.Parent then
		return
	end
	for attempt = 1, HOME_RETRIES do
		local ok, err = pcall(function()
			local options = Instance.new("TeleportOptions")
			if lobbyJobId and attempt == 1 then
				options.ServerInstanceId = lobbyJobId
			end
			options:SetTeleportData({ Mode = "Lobby" })
			TeleportService:TeleportAsync(game.PlaceId, { player }, options)
		end)
		if ok then
			return
		end
		warn(string.format("[RunServers] home teleport %d for %s failed: %s", attempt, player.Name, tostring(err)))
	end
end

local function startRun()
	if started or not plan then
		return
	end
	started = true
	local players: { Player } = {}
	local best = 1
	for _, p in arrived do
		if p.Parent == Players then
			local profile = DataService.WaitFor(p, PROFILE_WAIT) :: any
			if profile then
				best = math.max(best, tonumber(profile.Unlocked) or 1)
			end
			table.insert(players, p)
		end
	end
	if #players == 0 then
		return
	end
	-- Never deeper than anyone in the party has unlocked.
	local level = math.clamp(plan.Level, 1, math.min(best, #Config.Levels))
	for _, p in players do
		local waited = 0
		while not Characters.IsAlive(p) and waited < 10 and p.Parent == Players do
			waited += task.wait(0.25)
		end
	end
	local ok, result, err = pcall(RoundService.StartRound, players, level)
	if not ok or result ~= true then
		warn("[RunServers] couldn't start the run: " .. tostring(if ok then err else result))
		for _, p in players do
			task.spawn(RunServers.SendHome, p)
		end
	end
end

local function onArrive(player: Player)
	local data: any = nil
	pcall(function()
		data = player:GetJoinData().TeleportData
	end)
	if started then
		-- Too late for this run (or not part of it): back to the lobby.
		task.spawn(RunServers.SendHome, player)
		return
	end
	if not plan and type(data) == "table" and data.Mode == "Run" then
		local party = {}
		if type(data.Party) == "table" then
			for _, id in data.Party do
				if type(id) == "number" then
					table.insert(party, id)
				end
			end
		end
		local newPlan: Plan = { Level = math.floor(tonumber(data.Level) or 1), Party = party, Lobby = if type(data.Lobby) == "string" then data.Lobby else nil }
		plan = newPlan
		lobbyJobId = newPlan.Lobby
		task.delay(ARRIVE_WAIT, startRun)
	end
	arrived[player.UserId] = player
	-- Everyone's here: start as soon as their saves are loaded.
	if plan then
		local all = true
		for _, id in plan.Party do
			if not arrived[id] then
				all = false
				break
			end
		end
		if all then
			task.spawn(startRun)
		end
	end
end

function RunServers.Init()
	if not RunServers.IsRunServer then
		return
	end
	Workspace:SetAttribute("RunServer", true)
	RoundService.SendHomeHook = RunServers.SendHome
end

function RunServers.Start()
	if not RunServers.IsRunServer then
		return
	end
	for _, p in Players:GetPlayers() do
		task.spawn(onArrive, p)
	end
	Players.PlayerAdded:Connect(onArrive)
end

return RunServers
