--[[
	RunServers - each party plays its run in its own private server.

	  * Lobby side: when a party launches, Launch() freezes the party (their screens are already
	    black), saves each of them with a "handoff" lock (DataService.BeginHandoff) so the run server
	    can load their saves at once, and teleports the whole party into a freshly reserved server of
	    this same place, with { Mode = "Run", Level, Party = userIds } as teleport data.
	  * Run side (IsRunServer): the party's players arrive, their saves load, and once everyone is in
	    (or after ARRIVE_WAIT) RoundService.StartRound runs for them as usual. A party member who
	    arrives after that joins the run already going. When a player's run ends (results, Leave,
	    Back to Lobby), SendHome teleports them back to a lobby server.
	  * Every teleport is watched: a teleport Roblox couldn't start (TeleportInitFailed) is retried,
	    and if it still fails the player is unfrozen and told, instead of being left stuck.
	  * Studio, unpublished places, or a teleport that can't start: everything falls back to playing
	    the run in this server, exactly as before.

	The workspace attribute "RunServer" tells clients they're in a run server (they stay behind a
	loading cover until the run starts, and while heading home). The player attribute "Teleporting"
	keeps a player's screen black while a teleport is in progress.
]]

local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local DataService = require(script.Parent:WaitForChild("DataService"))
local RoundService = require(script.Parent:WaitForChild("RoundService"))
local Characters = require(script.Parent:WaitForChild("Characters"))

local RunServers = {}

local ARRIVE_WAIT = 12 -- seconds to wait for the rest of the party (anyone later joins the run already going)
local PROFILE_WAIT = 20 -- seconds to wait for an arriving player's save to load
local CHARACTER_WAIT = 15 -- seconds to wait for an arriving player's character
local HANDOFF_WAIT = 3 -- seconds the handoff saves may take before teleporting anyway
local TELEPORT_TIMEOUT = 45 -- a teleport still not done after this long counts as failed
local TELEPORT_RETRIES = 3 -- tries per teleport (the first one included)

-- A reserved server (made by TeleportOptions.ShouldReserveServer) has a PrivateServerId but no owner.
RunServers.IsRunServer = game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0

-- So the admin can teleport into a run server (a reserved server needs its access code): the lobby
-- that reserves one remembers "psid_<PrivateServerId>" = code, and the run server, once it starts,
-- files it under its own JobId ("job_<JobId>"). Kept for a few hours in a MemoryStore map.
local CODE_TTL = 4 * 3600
local codeMap: MemoryStoreHashMap? = nil
local function getCodeMap(): MemoryStoreHashMap?
	if not codeMap then
		pcall(function()
			codeMap = MemoryStoreService:GetHashMap("RinseCycle_RunServerCodes")
		end)
	end
	return codeMap
end
local function putCode(key: string, code: string)
	local map = getCodeMap()
	if map then
		pcall(function()
			(map :: MemoryStoreHashMap):SetAsync(key, code, CODE_TTL)
		end)
	end
end
local function getCode(key: string): string?
	local map = getCodeMap()
	if not map then
		return nil
	end
	local ok, value = pcall(function()
		return (map :: MemoryStoreHashMap):GetAsync(key)
	end)
	return if ok and type(value) == "string" and value ~= "" then value else nil
end

RunServers.AccessCode = nil :: string? -- this run server's own access code, once known

-- The access code of the run server with this JobId, or nil for a normal (public) server.
function RunServers.AccessCodeForJob(jobId: string): string?
	if jobId == game.JobId then
		return RunServers.AccessCode
	end
	return getCode("job_" .. jobId)
end

local function canTeleport(): boolean
	return game.PlaceId ~= 0 and not RunService:IsStudio()
end

local function isHere(player: Player): boolean
	return player.Parent == Players
end

local function notify(player: Player, text: string, kind: string)
	if isHere(player) then
		Remotes.Event("Notify"):FireClient(player, text, kind)
	end
end

-- Holds a player still (anchored in place) while they are being teleported.
local function setFrozen(player: Player, frozen: boolean)
	local root = Characters.GetRoot(player)
	if root then
		root.Anchored = frozen
	end
end

----------------------------------------------------------------------------------------------------
-- Watched teleports
----------------------------------------------------------------------------------------------------

type Pending = {
	Kind: "Run" | "Home",
	Tries: number,
	Token: number,
	AccessCode: string?, -- Run: the reserved server's code, so a retry goes to the same server
	Data: { [string]: any },
	OnFail: ((Player) -> ())?,
}
local pending: { [Player]: Pending } = {}
local nextToken = 0

local function giveUp(player: Player, p: Pending)
	if pending[player] ~= p then
		return
	end
	pending[player] = nil
	if not isHere(player) then
		return
	end
	player:SetAttribute("Teleporting", false)
	setFrozen(player, false)
	DataService.CancelHandoff(player)
	if p.Kind == "Run" then
		notify(player, "Couldn't reach the dishwasher. Please try again!", "Bad")
	else
		notify(player, "Couldn't get back to the lobby. Please rejoin the game.", "Bad")
	end
	if p.OnFail then
		task.spawn(p.OnFail, player)
	end
end

-- One teleport attempt for one player (retries go one player at a time).
local function sendOne(player: Player, p: Pending): boolean
	local ok, err = pcall(function()
		local options = Instance.new("TeleportOptions")
		if p.AccessCode then
			options.ReservedServerAccessCode = p.AccessCode
		end
		options:SetTeleportData(p.Data)
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if not ok then
		warn(string.format("[RunServers] teleport for %s failed: %s", player.Name, tostring(err)))
	end
	return ok
end

-- Tries again (up to TELEPORT_RETRIES in all), or gives up.
local function retry(player: Player, p: Pending)
	while pending[player] == p and isHere(player) do
		if p.Tries >= TELEPORT_RETRIES then
			giveUp(player, p)
			return
		end
		p.Tries += 1
		task.wait(1.5 * p.Tries)
		if pending[player] ~= p or not isHere(player) then
			return
		end
		if sendOne(player, p) then
			return
		end
	end
end

-- Starts watching a teleport that was just started for `player`.
local function watch(player: Player, p: Pending)
	nextToken += 1
	p.Token = nextToken
	pending[player] = p
	local token = p.Token
	task.delay(TELEPORT_TIMEOUT, function()
		local current = pending[player]
		if current and current.Token == token and isHere(player) then
			giveUp(player, current)
		end
	end)
end

local function onTeleportInitFailed(player: Player, result: Enum.TeleportResult, message: string)
	local p = pending[player]
	if not p then
		return
	end
	warn(string.format("[RunServers] teleport for %s didn't start (%s): %s", player.Name, tostring(result), tostring(message)))
	task.spawn(retry, player, p)
end

----------------------------------------------------------------------------------------------------
-- Lobby side
----------------------------------------------------------------------------------------------------

-- Sends `players` to a new private server for a run of `level`. Returns true if the teleport was
-- started; false means "play it here instead". `onFail` runs for anyone whose teleport later fails.
function RunServers.Launch(players: { Player }, level: number, onFail: ((Player) -> ())?): boolean
	if RunServers.IsRunServer or not canTeleport() or #players == 0 then
		return false
	end
	local userIds = {}
	for _, p in players do
		table.insert(userIds, p.UserId)
		p:SetAttribute("Teleporting", true)
		setFrozen(p, true)
	end

	-- Save everyone with a handoff lock (all at once), so the run server can load them straight away.
	local left = #players
	for _, p in players do
		task.spawn(function()
			pcall(DataService.BeginHandoff, p)
			left -= 1
		end)
	end
	local deadline = os.clock() + HANDOFF_WAIT
	while left > 0 and os.clock() < deadline do
		task.wait(0.1)
	end

	local going: { Player } = {}
	for _, p in players do
		if isHere(p) then
			table.insert(going, p)
		end
	end
	local data: { [string]: any } = { Mode = "Run", Level = level, Party = userIds, AdminInvis = RunServers.InvisList(players) }
	local ok, result = pcall(function()
		local options = Instance.new("TeleportOptions")
		options.ShouldReserveServer = true
		options:SetTeleportData(data)
		return TeleportService:TeleportAsync(game.PlaceId, going, options)
	end)
	if not ok or #going == 0 then
		if not ok then
			warn("[RunServers] couldn't reserve a run server, playing here: " .. tostring(result))
		end
		for _, p in players do
			if isHere(p) then
				p:SetAttribute("Teleporting", false)
				setFrozen(p, false)
				DataService.CancelHandoff(p)
			end
		end
		return false
	end
	local accessCode, privateId = nil, nil
	pcall(function()
		accessCode = (result :: any).ReservedServerAccessCode
		privateId = (result :: any).PrivateServerId
	end)
	if type(accessCode) == "string" and type(privateId) == "string" and privateId ~= "" then
		task.spawn(putCode, "psid_" .. privateId, accessCode)
	end
	for _, p in going do
		watch(p, {
			Kind = "Run",
			Tries = 1,
			Token = 0,
			AccessCode = if type(accessCode) == "string" and accessCode ~= "" then accessCode else nil,
			Data = data,
			OnFail = onFail,
		})
	end
	return true
end

----------------------------------------------------------------------------------------------------
-- Run side
----------------------------------------------------------------------------------------------------

type Plan = { Level: number, Party: { number } }
local plan: Plan? = nil
local arrived: { [number]: Player } = {}
local started = false

-- Teleports a player home to a lobby server. Safe to call more than once.
function RunServers.SendHome(player: Player)
	if not isHere(player) or pending[player] then
		return
	end
	player:SetAttribute("Teleporting", true)
	setFrozen(player, true)
	pcall(DataService.BeginHandoff, player)
	if not isHere(player) then
		return
	end
	local p: Pending = { Kind = "Home", Tries = 1, Token = 0, Data = { Mode = "Lobby", AdminInvis = RunServers.InvisList({ player }) } }
	watch(player, p)
	if not sendOne(player, p) then
		task.spawn(retry, player, p)
	end
end

local function waitUntilReady(player: Player)
	DataService.WaitFor(player, PROFILE_WAIT)
	local waited = 0
	while not Characters.IsAlive(player) and waited < CHARACTER_WAIT and isHere(player) do
		waited += task.wait(0.25)
	end
end

local function startRun()
	if started or not plan then
		return
	end
	started = true
	local players: { Player } = {}
	for _, p in arrived do
		if isHere(p) then
			table.insert(players, p)
		end
	end
	if #players == 0 then
		started = false -- nobody left to play: the next arrival starts it
		return
	end
	-- Everyone's save and character at once, not one after another.
	local left = #players
	for _, p in players do
		task.spawn(function()
			waitUntilReady(p)
			left -= 1
		end)
	end
	while left > 0 do
		task.wait(0.1)
	end

	local best = 1
	local ready: { Player } = {}
	for _, p in players do
		if isHere(p) then
			local profile = DataService.Get(p) :: any
			if profile then
				best = math.max(best, tonumber(profile.Unlocked) or 1)
			end
			table.insert(ready, p)
		end
	end
	if #ready == 0 then
		started = false
		return
	end
	-- Never deeper than anyone in the party has unlocked.
	local level = math.clamp((plan :: Plan).Level, 1, math.min(best, #Config.Levels))
	local ok, result, err = pcall(RoundService.StartRound, ready, level)
	if not ok or result ~= true then
		warn("[RunServers] couldn't start the run: " .. tostring(if ok then err else result))
		for _, p in ready do
			task.spawn(RunServers.SendHome, p)
		end
	end
end

-- A party member who got here after the run started: into the run with the others.
local function joinLate(player: Player)
	waitUntilReady(player)
	if not isHere(player) then
		return
	end
	local ok, joined = pcall(RoundService.JoinLate, player)
	if not (ok and joined) then
		RunServers.SendHome(player) -- the run is already over
	end
end

local function onArrive(player: Player)
	local data: any = nil
	pcall(function()
		data = player:GetJoinData().TeleportData
	end)
	-- An admin (or someone they pulled over) dropping in: not part of the run, leave them be.
	if type(data) == "table" and (data.Mode == "AdminJoin" or data.Mode == "AdminBring") then
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
		local newPlan: Plan = { Level = math.floor(tonumber(data.Level) or 1), Party = party }
		plan = newPlan
		task.delay(ARRIVE_WAIT, startRun)
	end
	local current = plan
	if not current then
		RunServers.SendHome(player) -- no run was ever set up here
		return
	end
	arrived[player.UserId] = player
	if started then
		joinLate(player)
		return
	end
	-- Everyone's here: start as soon as their saves are loaded.
	for _, id in current.Party do
		if not arrived[id] then
			return
		end
	end
	task.spawn(startRun)
end

-- UserIds of these players who are invisible by the admin :invis command, so the server they
-- arrive in makes them invisible again (AdminServer reads TeleportData.AdminInvis).
function RunServers.InvisList(players: { Player }): { number }
	local list = {}
	for _, p in players do
		if p:GetAttribute("AdminInvis") == true then
			table.insert(list, p.UserId)
		end
	end
	return list
end

function RunServers.Init()
	TeleportService.TeleportInitFailed:Connect(onTeleportInitFailed)
	Players.PlayerRemoving:Connect(function(player)
		pending[player] = nil
		arrived[player.UserId] = nil
	end)
	if not RunServers.IsRunServer then
		return
	end
	Workspace:SetAttribute("RunServer", true)
	RoundService.SendHomeHook = RunServers.SendHome
	-- Look up our own access code (the lobby stored it) and file it under our JobId.
	task.spawn(function()
		for _ = 1, 5 do
			local code = getCode("psid_" .. game.PrivateServerId)
			if code then
				RunServers.AccessCode = code
				putCode("job_" .. game.JobId, code)
				return
			end
			task.wait(3)
		end
	end)
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
