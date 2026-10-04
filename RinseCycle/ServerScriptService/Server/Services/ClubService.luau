--[[
	ClubService - player clubs (the Clubs button), like other Roblox games' clans.

	  * Make one for Config.Clubs.CreateCost Gems: a name and a prefix (the short [TAG] shown in
	    front of members' names; both through Roblox's text filter, names unique), public or private,
	    and requirements: a level beaten (0-3) and a number of rebirths. Up to MaxMembers.
	  * Public clubs: anyone who meets the requirements joins from the lists. Private clubs: only with
	    the club code (members see it; the owner can make a new one).
	  * Roles: Owner, Co-Leader (the owner promotes members; co-leaders can kick members) and
	    Member. The owner can kick anyone. Leaving as owner hands the club to a co-leader (else the
	    longest member); the last one out closes it.
	  * The owner can rename the club and change the prefix, each once every RenameDays days (each
	    has its own timer; a brand new club can change straight away).
	  * Points: members DONATE Bubbles to their club (Donate button). Every donated Bubble is a point
	    for the club and for that member (the club leaderboard). TOP CLUBS is the top 25 clubs this
	    month.
	  * Monthly contest: on the 1st of every month (00:00 UTC) every club's points start again from
	    zero. The top 3 clubs' members each get Gems (Config.Clubs.Season.PrizeGems) and the winning
	    club's members also get a limited pet (Config.Clubs.Season.Pet). Prizes are claimed the next
	    time each member is in the game (profile ClubPrizeSeason says which month they got).
	  * Club chat: members only, filtered by Roblox's text filter, the last ChatKeep messages kept.

	Storage (DataStores; in Studio without API access everything lives in memory):
	  RinseCycleClubs        "club_<id>"   the club record (members, settings, points)
	                         "name_<name>" -> id (names are unique, any case)
	                         "code_<CODE>" -> id (club codes)
	                         "dir_<c>"     { [id] = summary } every club whose name starts with c
	                                       (FIND lists them alphabetically)
	                         "chat_<id>"   the club's chat history
	  RinseCycleClubPoints_<YYYYMM>  OrderedDataStore id -> points (TOP CLUBS, one per month)
	                         "season_<YYYYMM>" the finished month's top 3 clubs and their members
	Other servers hear about kicks and chat over MessagingService ("RinseCycle_Club"); a player's club
	is also checked against the record every time they join.

	ClubRequest (C->S, action, value) -> { Ok, Error?, Club?, Clubs?, Messages? }:
	  "Mine"  "Top"  "Info" (club id)  "Donate" (bubbles)  "Find" (text)  "Create" ({Name, Tag, Public, ReqLevel, ReqRebirths})
	  "Join" (club id)  "JoinCode" (code)  "Leave"  "Kick" (userId)  "Promote" / "Demote" (userId)
	  "Settings" ({Public, ReqLevel, ReqRebirths})  "Rename" ({Name?, Tag?})  "NewCode"
	  "Chat" (text)  "ChatHistory"
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local DataService = require(script.Parent:WaitForChild("DataService"))

local ClubService = {}

local STORE = "RinseCycleClubs"
local POINTS_STORE = "RinseCycleClubPoints"
local TOPIC = "RinseCycle_Club"
local TOP_REFRESH = 120 -- seconds the TOP CLUBS list is cached
local DIR_REFRESH = 60 -- seconds a FIND directory shard is cached
local TOP_COUNT = 25
local FIND_COUNT = 30
local CHAT_GAP = 1.5 -- seconds between one player's chat messages
local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" -- no 0/O or 1/I

local initialized = false
local clubStore: DataStore? = nil
local pointsStores: { [string]: OrderedDataStore } = {}
local memory: { [string]: any } = {} -- Studio / no API access
local memoryPoints: { [string]: { [string]: number? } } = {} -- season -> club id -> points
local lastRequest: { [Player]: number } = {}
local lastChat: { [Player]: number } = {}
local topCache: { any } = {}
local topAt = -math.huge
local dirCache: { [string]: { At: number, Entries: any } } = {}
local donate: (Player, any) -> any
local info: (Player, string) -> any
local stateRemote: RemoteEvent
local chatRemote: RemoteEvent

----------------------------------------------------------------------------------------------------
-- Storage
----------------------------------------------------------------------------------------------------

local function useMemory(): boolean
	return clubStore == nil or DataService.IsOffline()
end

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local t = {}
	for k, x in v do
		t[k] = deepCopy(x)
	end
	return t
end

local function get(key: string): (boolean, any)
	if useMemory() then
		return true, deepCopy(memory[key])
	end
	local store = clubStore :: DataStore
	return pcall(function()
		return (store:GetAsync(key))
	end)
end

-- Atomic edit. `fn(old)` returns the new value, or nil to change nothing. Returns (ok, newValue).
local function update(key: string, fn: (any) -> any): (boolean, any)
	if useMemory() then
		local new = fn(deepCopy(memory[key]))
		if new ~= nil then
			memory[key] = deepCopy(new)
		end
		return true, new
	end
	local store = clubStore :: DataStore
	local result = nil
	local ok, err = pcall(function()
		store:UpdateAsync(key, function(old)
			result = fn(old)
			return result
		end)
	end)
	if not ok then
		warn("[ClubService] " .. key .. ": " .. tostring(err))
	end
	return ok, result
end

local function remove(key: string)
	if useMemory() then
		memory[key] = nil
		return
	end
	local store = clubStore :: DataStore
	pcall(function()
		store:RemoveAsync(key)
	end)
end

----------------------------------------------------------------------------------------------------
-- Seasons (one per calendar month, UTC)
----------------------------------------------------------------------------------------------------

local function now(): number
	local fn = (ClubService :: any).NowFn
	return if fn then fn() else os.time()
end

-- Days since 1970-01-01 for a civil date (no timezone involved).
local function daysFromCivil(y: number, m: number, d: number): number
	y -= if m <= 2 then 1 else 0
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local doy = (153 * (m + (if m > 2 then -3 else 9)) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function monthStart(y: number, m: number): number
	while m > 12 do
		m -= 12
		y += 1
	end
	while m < 1 do
		m += 12
		y -= 1
	end
	return daysFromCivil(y, m, 1) * 86400
end

local function seasonOf(t: number): string
	return os.date("!%Y%m", t)
end

local function currentSeason(): string
	return seasonOf(now())
end

local function previousSeason(): string
	local d = os.date("!*t", now())
	return seasonOf(monthStart(d.year, d.month - 1))
end

local function nextResetAt(): number
	local d = os.date("!*t", now())
	return monthStart(d.year, d.month + 1)
end

-- What the client shows about the contest: "October 2026", when it resets (unix, shown in the
-- player's own time), and the prizes.
local function seasonInfo(): any
	return { Label = os.date("!%B %Y", now()), ResetAt = nextResetAt(), Id = currentSeason() }
end

local function pointsStoreFor(season: string): OrderedDataStore?
	if pointsStores[season] then
		return pointsStores[season]
	end
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(POINTS_STORE .. "_" .. season)
	end)
	if ok then
		pointsStores[season] = store
		return store
	end
	return nil
end

local function setPoints(id: string, points: number?, season: string?)
	local key = season or currentSeason()
	if useMemory() then
		memoryPoints[key] = memoryPoints[key] or {}
		memoryPoints[key][id] = points
		return
	end
	local store = pointsStoreFor(key)
	if not store then
		return
	end
	local value = if points then math.floor(points) else nil
	pcall(function()
		if value then
			store:SetAsync(id, value)
		else
			store:RemoveAsync(id)
		end
	end)
end

local function topIds(season: string?, count: number?): { string }
	local key = season or currentSeason()
	local limit = count or TOP_COUNT
	local ids: { string } = {}
	if useMemory() then
		local pairsList: { { any } } = {}
		local bucket: { [string]: number? } = memoryPoints[key] or {}
		for id, points in bucket do
			table.insert(pairsList, { id :: any, points })
		end
		table.sort(pairsList, function(a, b)
			return a[2] > b[2]
		end)
		for i = 1, math.min(limit, #pairsList) do
			ids[i] = pairsList[i][1]
		end
		return ids
	end
	local store = pointsStoreFor(key)
	if not store then
		return ids
	end
	local ok, page = pcall(function()
		return store:GetSortedAsync(false, limit):GetCurrentPage()
	end)
	if ok and type(page) == "table" then
		for _, entry in page do
			if entry.value > 0 then
				table.insert(ids, entry.key)
			end
		end
	end
	return ids
end

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local function fail(message: string): any
	return { Ok = false, Error = message }
end

local function memberCount(club: any): number
	local n = 0
	for _ in club.Members do
		n += 1
	end
	return n
end

local function newCode(): string
	local chars = {}
	for i = 1, Config.Clubs.CodeLength do
		local k = math.random(1, #CODE_CHARS)
		chars[i] = string.sub(CODE_CHARS, k, k)
	end
	return table.concat(chars)
end

-- A club id: unique enough (time, the maker and a random part), short for DataStore keys.
local function newId(player: Player): string
	local ok, guid = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if ok and type(guid) == "string" then
		return string.sub((string.gsub(guid, "-", "")), 1, 16)
	end
	return string.format("%x%x%04x", os.time(), player.UserId % 65536, math.random(0, 65535))
end

local function nameKey(name: string): string
	return "name_" .. string.lower((string.gsub(name, "%s+", " ")))
end

-- The FIND directory shard a name lives in: its first letter / digit.
local function dirKey(name: string): string
	local c = string.lower(string.sub(name, 1, 1))
	return "dir_" .. (if string.match(c, "%w") then c else "_")
end

local function cleanName(text: any): string
	if type(text) ~= "string" then
		return ""
	end
	local name = string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")
	return (string.gsub(name, "%s+", " "))
end

local function cleanTag(text: any): string
	if type(text) ~= "string" then
		return ""
	end
	return string.upper((string.gsub(text, "%s+", "")))
end

local function checkName(name: string): string?
	local rules = Config.Clubs
	if utf8.len(name) == nil or #name < rules.NameLength[1] or #name > rules.NameLength[2] then
		return string.format("Club names are %d to %d letters.", rules.NameLength[1], rules.NameLength[2])
	end
	if not string.match(name, "^[%w ]+$") then
		return "Club names use letters, numbers and spaces only."
	end
	return nil
end

local function checkTag(tag: string): string?
	local rules = Config.Clubs
	if #tag < rules.TagLength[1] or #tag > rules.TagLength[2] or not string.match(tag, "^%w+$") then
		return string.format("Prefixes are %d to %d letters or numbers.", rules.TagLength[1], rules.TagLength[2])
	end
	return nil
end

-- Roblox's text filter. Anything it would hide (or a failed check outside Studio) is refused.
local function filterOk(player: Player, text: string): (boolean, string?)
	local ok, filtered = pcall(function()
		return TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat):GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		if RunService:IsStudio() then
			return true
		end
		return false, "Couldn't check that. Try again in a moment."
	end
	if filtered ~= text then
		return false, "That isn't allowed. Try something else."
	end
	return true
end

local function renameWait(club: any, field: string): number
	local at = tonumber(club[field]) or 0
	if at <= 0 then
		return 0
	end
	return math.max(0, at + Config.Clubs.RenameDays * 86400 - os.time())
end

local ROLE_ORDER = { Owner = 1, CoLeader = 2, Member = 3 }

-- What the client is shown. Members see the code, the member list and their own role.
local function view(club: any, forUserId: number?, withMembers: boolean?): any
	local members = {}
	local memberIds = {}
	local thisSeason = club.Season == currentSeason() -- last month's points count for nothing
	for uid, m in club.Members do
		local id = tonumber(uid) or 0
		table.insert(memberIds, id)
		table.insert(members, {
			UserId = id,
			Name = m.Name,
			Role = m.Role or "Member",
			Points = if thisSeason then math.floor(tonumber(m.Points) or 0) else 0,
			Online = Players:GetPlayerByUserId(id) ~= nil,
		})
	end
	table.sort(members, function(a, b)
		local ra, rb = ROLE_ORDER[a.Role] or 3, ROLE_ORDER[b.Role] or 3
		if ra ~= rb then
			return ra < rb
		end
		return string.lower(a.Name) < string.lower(b.Name)
	end)
	local me = forUserId and club.Members[tostring(forUserId)]
	return {
		Id = club.Id,
		Name = club.Name,
		Tag = club.Tag,
		Public = club.Public,
		ReqLevel = club.ReqLevel,
		ReqRebirths = club.ReqRebirths,
		Points = if thisSeason then math.floor(tonumber(club.Points) or 0) else 0,
		Season = seasonInfo(),
		Count = #members,
		Max = Config.Clubs.MaxMembers,
		Owner = club.Owner,
		OwnerName = club.OwnerName,
		MemberIds = memberIds,
		Code = if me then club.Code else nil,
		Members = if me or withMembers then members else nil,
		Mine = me ~= nil,
		MyRole = if me then me.Role or "Member" else nil,
		NameWait = if me then renameWait(club, "NameChangedAt") else nil,
		TagWait = if me then renameWait(club, "TagChangedAt") else nil,
	}
end

local function meets(player: Player, club: any): (boolean, string?)
	local profile = DataService.Get(player)
	if not profile then
		return false, "Your save is still loading."
	end
	if DataService.LevelsBeaten(profile) < (club.ReqLevel or 0) then
		return false, string.format("You need to beat level %d to join.", club.ReqLevel)
	end
	if (profile.Rebirths or 0) < (club.ReqRebirths or 0) then
		return false, string.format("You need %d rebirths to join.", club.ReqRebirths)
	end
	return true
end

local function publish(message: any)
	task.spawn(function()
		local ok = pcall(function()
			MessagingService:PublishAsync(TOPIC, message)
		end)
		if not ok and message.Kind == "Chat" then
			-- No MessagingService (Studio): deliver in this server only.
			local handler = (ClubService :: any).OnMessage
			if handler then
				handler(message)
			end
		end
	end)
end

local function pushState(player: Player, club: any?)
	if player.Parent == Players then
		stateRemote:FireClient(player, if club then view(club, player.UserId) else nil)
	end
end

-- Tells everyone in this server who's in the club that it changed.
local function pushToMembers(club: any)
	for uid in club.Members do
		local plr = Players:GetPlayerByUserId(tonumber(uid) or 0)
		if plr then
			pushState(plr, club)
		end
	end
end

-- Puts the membership on the player's profile (tag over their head) and tells their client.
local function setMembership(player: Player, club: any?, moved: boolean)
	DataService.SetClub(player, if club then club.Id else "", if club then club.Tag else "", moved)
	pushState(player, club)
end

local function clubOf(player: Player): (string?, any?)
	local profile = DataService.Get(player)
	local id = profile and profile.ClubId
	if not id or id == "" then
		return nil, nil
	end
	local ok, club = get("club_" .. id)
	if not ok then
		return id, nil
	end
	return id, club
end

local function cooldownLeft(player: Player): number
	local profile = DataService.Get(player)
	local at = profile and profile.ClubMovedAt or 0
	return math.max(0, at + Config.Clubs.JoinCooldown - os.time())
end

----------------------------------------------------------------------------------------------------
-- The FIND directory
----------------------------------------------------------------------------------------------------

local function summary(club: any): any
	return { Name = club.Name, Tag = club.Tag, Public = club.Public, ReqLevel = club.ReqLevel, ReqRebirths = club.ReqRebirths }
end

local function dirPut(club: any)
	local key = dirKey(club.Name)
	update(key, function(old)
		local t = if type(old) == "table" then old else {}
		t[club.Id] = summary(club)
		return t
	end)
	dirCache[key] = nil
end

local function dirRemove(name: string, id: string)
	local key = dirKey(name)
	update(key, function(old)
		if type(old) ~= "table" or old[id] == nil then
			return nil
		end
		old[id] = nil
		return old
	end)
	dirCache[key] = nil
end

local function dirRead(key: string): any
	local cached = dirCache[key]
	if cached and os.clock() - cached.At < DIR_REFRESH then
		return cached.Entries
	end
	local ok, entries = get(key)
	local t = if ok and type(entries) == "table" then entries else {}
	dirCache[key] = { At = os.clock(), Entries = t }
	return t
end

----------------------------------------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------------------------------------

local function join(player: Player, id: string, byCode: boolean)
	local profile = DataService.Get(player)
	if not profile then
		return fail("Your save is still loading.")
	end
	if profile.ClubId ~= "" then
		return fail("Leave your club first.")
	end
	local wait = cooldownLeft(player)
	if wait > 0 then
		return fail(string.format("You can join a club in %d seconds.", wait))
	end
	local reason: string? = nil
	local ok, club = update("club_" .. id, function(old)
		if type(old) ~= "table" then
			reason = "That club doesn't exist any more."
			return nil
		end
		if not old.Public and not byCode then
			reason = "That club is invite only. Ask for its club code!"
			return nil
		end
		if memberCount(old) >= Config.Clubs.MaxMembers then
			reason = "That club is full."
			return nil
		end
		local good, why = meets(player, old)
		if not good then
			reason = why
			return nil
		end
		old.Members[tostring(player.UserId)] = { Name = player.DisplayName, Role = "Member", Joined = os.time(), Points = 0 }
		return old
	end)
	if not ok then
		return fail("Clubs are busy. Try again in a moment.")
	end
	if not club then
		return fail(reason or "Couldn't join that club.")
	end
	setMembership(player, club, true)
	pushToMembers(club)
	return { Ok = true, Club = view(club, player.UserId), Message = "Welcome to " .. club.Name .. "!" }
end

local function create(player: Player, value: any)
	if type(value) ~= "table" then
		return fail("Bad request.")
	end
	local profile = DataService.Get(player)
	if not profile then
		return fail("Your save is still loading.")
	end
	if profile.ClubId ~= "" then
		return fail("Leave your club first.")
	end
	local rules = Config.Clubs
	local name, tag = cleanName(value.Name), cleanTag(value.Tag)
	local bad = checkName(name) or checkTag(tag)
	if bad then
		return fail(bad)
	end
	if (profile.Gems or 0) < rules.CreateCost then
		return fail(string.format("You need %d Gems to make a club.", rules.CreateCost))
	end
	local okName, whyName = filterOk(player, name)
	if not okName then
		return fail(whyName or "That name isn't allowed.")
	end
	local okTag, whyTag = filterOk(player, tag)
	if not okTag then
		return fail(whyTag or "That prefix isn't allowed.")
	end
	local reqLevel = math.clamp(math.floor(tonumber(value.ReqLevel) or 0), 0, rules.MaxLevelReq)
	local reqRebirths = math.clamp(math.floor(tonumber(value.ReqRebirths) or 0), 0, rules.MaxRebirthReq)
	local id = newId(player)

	-- Claim the name first (unique, any case).
	local taken = false
	local okClaim = update(nameKey(name), function(old)
		if type(old) == "string" and old ~= "" then
			taken = true
			return nil
		end
		return id
	end)
	if not okClaim then
		return fail("Clubs are busy. Try again in a moment.")
	end
	if taken then
		return fail("A club already has that name.")
	end
	-- Pay after the name is ours (nothing yields between the check and the spend).
	if not DataService.SpendGems(player, rules.CreateCost) then
		remove(nameKey(name))
		return fail(string.format("You need %d Gems to make a club.", rules.CreateCost))
	end
	local code = newCode()
	local club = {
		Id = id,
		Name = name,
		Tag = tag,
		Owner = player.UserId,
		OwnerName = player.DisplayName,
		Public = value.Public ~= false,
		ReqLevel = reqLevel,
		ReqRebirths = reqRebirths,
		Code = code,
		Points = 0,
		Season = currentSeason(),
		Created = os.time(),
		NameChangedAt = 0, -- 0: the first change is free straight away
		TagChangedAt = 0,
		Members = { [tostring(player.UserId)] = { Name = player.DisplayName, Role = "Owner", Joined = os.time(), Points = 0 } },
	}
	local okSave = update("club_" .. id, function()
		return club
	end)
	if not okSave then
		DataService.AddGems(player, rules.CreateCost) -- refund
		remove(nameKey(name))
		return fail("Couldn't save your club. Your Gems were given back.")
	end
	update("code_" .. code, function()
		return id
	end)
	dirPut(club)
	setPoints(id, 0)
	topAt = -math.huge
	setMembership(player, club, true)
	return { Ok = true, Club = view(club, player.UserId), Message = name .. " is open!" }
end

local function deleteClub(club: any)
	remove("club_" .. club.Id)
	remove(nameKey(club.Name))
	if club.Code then
		remove("code_" .. club.Code)
	end
	remove("chat_" .. club.Id)
	dirRemove(club.Name, club.Id)
	setPoints(club.Id, nil)
	topAt = -math.huge
end

local function leave(player: Player)
	local id = clubOf(player)
	if not id then
		return fail("You're not in a club.")
	end
	local emptied: any = nil
	local ok, club = update("club_" .. id, function(old)
		if type(old) ~= "table" then
			return nil
		end
		old.Members[tostring(player.UserId)] = nil
		if memberCount(old) == 0 then
			emptied = old
			return nil
		end
		if old.Owner == player.UserId then
			-- A co-leader takes over (the longest-standing one), else the longest member.
			local heir, heirRank, heirJoined = nil, math.huge, math.huge
			for uid, m in old.Members do
				local rank = if m.Role == "CoLeader" then 1 else 2
				local joined = m.Joined or 0
				if rank < heirRank or (rank == heirRank and joined < heirJoined) then
					heir, heirRank, heirJoined = uid, rank, joined
				end
			end
			old.Owner = tonumber(heir)
			old.OwnerName = old.Members[heir].Name
			old.Members[heir].Role = "Owner"
		end
		return old
	end)
	if not ok then
		return fail("Clubs are busy. Try again in a moment.")
	end
	if emptied then
		deleteClub(emptied)
	elseif club then
		pushToMembers(club)
	end
	setMembership(player, nil, true)
	return { Ok = true, Message = if emptied then "Your club was closed." else "You left the club." }
end

-- An edit by a club leader. `allowed(me)` says if this member may do it; `edit(club)` returns an
-- error message or nil.
local function leaderEdit(player: Player, allowed: (any) -> boolean, edit: (any) -> string?)
	local id = clubOf(player)
	if not id then
		return fail("You're not in a club.")
	end
	local reason: string? = nil
	local ok, club = update("club_" .. id, function(old)
		if type(old) ~= "table" then
			reason = "That club doesn't exist any more."
			return nil
		end
		local me = old.Members[tostring(player.UserId)]
		if not me or not allowed(me) then
			reason = "You can't do that in this club."
			return nil
		end
		reason = edit(old)
		if reason then
			return nil
		end
		return old
	end)
	if not ok then
		return fail("Clubs are busy. Try again in a moment.")
	end
	if not club then
		return fail(reason or "Couldn't do that.")
	end
	pushToMembers(club)
	return { Ok = true, Club = view(club, player.UserId) }
end

local function isOwner(me: any): boolean
	return me.Role == "Owner"
end

local function isLeader(me: any): boolean
	return me.Role == "Owner" or me.Role == "CoLeader"
end

local function kick(player: Player, userId: any)
	if type(userId) ~= "number" or userId == player.UserId then
		return fail("Pick a member to kick.")
	end
	local result = leaderEdit(player, isLeader, function(club)
		local target = club.Members[tostring(userId)]
		if not target then
			return "They're not in your club."
		end
		local me = club.Members[tostring(player.UserId)]
		-- The owner kicks anyone; co-leaders only kick members.
		if target.Role == "Owner" or (me.Role == "CoLeader" and target.Role ~= "Member") then
			return "You can't kick them."
		end
		club.Members[tostring(userId)] = nil
		return nil
	end)
	if result.Ok then
		local target = Players:GetPlayerByUserId(userId)
		if target then
			setMembership(target, nil, false)
			Remotes.Event("Notify"):FireClient(target, "You were removed from your club.", "Info")
		else
			publish({ Kind = "Kicked", UserId = userId, ClubId = result.Club.Id })
		end
	end
	return result
end

local function setRole(player: Player, userId: any, role: string)
	if type(userId) ~= "number" or userId == player.UserId then
		return fail("Pick a member.")
	end
	return leaderEdit(player, isOwner, function(club)
		local target = club.Members[tostring(userId)]
		if not target or target.Role == "Owner" then
			return "They're not a member you can change."
		end
		target.Role = role
		return nil
	end)
end

local function settings(player: Player, value: any)
	if type(value) ~= "table" then
		return fail("Bad request.")
	end
	local result = leaderEdit(player, isOwner, function(club)
		if value.Public ~= nil then
			club.Public = value.Public == true
		end
		if value.ReqLevel ~= nil then
			club.ReqLevel = math.clamp(math.floor(tonumber(value.ReqLevel) or 0), 0, Config.Clubs.MaxLevelReq)
		end
		if value.ReqRebirths ~= nil then
			club.ReqRebirths = math.clamp(math.floor(tonumber(value.ReqRebirths) or 0), 0, Config.Clubs.MaxRebirthReq)
		end
		return nil
	end)
	if result.Ok then
		local _, club = clubOf(player)
		if club then
			dirPut(club)
		end
	end
	return result
end

-- Name and prefix changes: owner only, each once every RenameDays (its own timer).
local function rename(player: Player, value: any)
	if type(value) ~= "table" then
		return fail("Bad request.")
	end
	local id, current = clubOf(player)
	if not id or not current then
		return fail("You're not in a club.")
	end
	local newName = if value.Name ~= nil then cleanName(value.Name) else nil
	local newTag = if value.Tag ~= nil then cleanTag(value.Tag) else nil
	if newName == current.Name then
		newName = nil
	end
	if newTag == current.Tag then
		newTag = nil
	end
	if not newName and not newTag then
		return fail("Nothing to change.")
	end
	if newName then
		local bad = checkName(newName)
		if bad then
			return fail(bad)
		end
		if renameWait(current, "NameChangedAt") > 0 then
			return fail("The club name can't be changed again yet.")
		end
		local okF, why = filterOk(player, newName)
		if not okF then
			return fail(why or "That name isn't allowed.")
		end
		-- Claim the new name (the old one is freed once the change is saved).
		local taken = false
		local okClaim = update(nameKey(newName), function(old)
			if type(old) == "string" and old ~= "" and old ~= id then
				taken = true
				return nil
			end
			return id
		end)
		if not okClaim then
			return fail("Clubs are busy. Try again in a moment.")
		end
		if taken then
			return fail("A club already has that name.")
		end
	end
	if newTag then
		local bad = checkTag(newTag)
		if bad then
			return fail(bad)
		end
		if renameWait(current, "TagChangedAt") > 0 then
			return fail("The prefix can't be changed again yet.")
		end
		local okF, why = filterOk(player, newTag)
		if not okF then
			return fail(why or "That prefix isn't allowed.")
		end
	end
	local oldName = current.Name
	local result = leaderEdit(player, isOwner, function(club)
		if newName then
			if renameWait(club, "NameChangedAt") > 0 then
				return "The club name can't be changed again yet."
			end
			club.Name = newName
			club.NameChangedAt = os.time()
		end
		if newTag then
			if renameWait(club, "TagChangedAt") > 0 then
				return "The prefix can't be changed again yet."
			end
			club.Tag = newTag
			club.TagChangedAt = os.time()
		end
		return nil
	end)
	if not result.Ok then
		if newName then
			remove(nameKey(newName))
		end
		return result
	end
	if newName then
		remove(nameKey(oldName))
		dirRemove(oldName, id)
	end
	local _, club = clubOf(player)
	if club then
		dirPut(club)
		if newTag then
			-- Everyone here in the club gets the new prefix over their head now; others on join.
			for uid in club.Members do
				local plr = Players:GetPlayerByUserId(tonumber(uid) or 0)
				if plr then
					DataService.SetClub(plr, club.Id, club.Tag, false)
				end
			end
		end
	end
	topAt = -math.huge
	result.Message = "Saved!"
	return result
end

local function regenerateCode(player: Player)
	local oldCode: string? = nil
	local result = leaderEdit(player, isOwner, function(club)
		oldCode = club.Code
		club.Code = newCode()
		return nil
	end)
	if result.Ok then
		if oldCode then
			remove("code_" .. oldCode)
		end
		local id = result.Club.Id
		update("code_" .. result.Club.Code, function()
			return id
		end)
	end
	return result
end

-- FIND: a club code, or clubs whose name starts with the text (alphabetical).
local function find(player: Player, text: any)
	if type(text) ~= "string" then
		return fail("Type a club name or code.")
	end
	local query = string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")
	if #query < 1 or #query > 30 then
		return fail("Type a club name or code.")
	end
	local clubs = {}
	local seen = {}
	local function add(id: any, byCode: boolean)
		if type(id) ~= "string" or seen[id] or #clubs >= FIND_COUNT then
			return
		end
		seen[id] = true
		local ok, club = get("club_" .. id)
		if ok and type(club) == "table" then
			local v = view(club, player.UserId)
			v.ByCode = byCode
			table.insert(clubs, v)
		end
	end
	if #query == Config.Clubs.CodeLength then
		local okCode, byCode = get("code_" .. string.upper(query))
		if okCode then
			add(byCode, true)
		end
	end
	local lower = string.lower(query)
	local matches = {}
	for id, entry in dirRead(dirKey(query)) do
		if type(entry) == "table" and type(entry.Name) == "string" and string.sub(string.lower(entry.Name), 1, #lower) == lower then
			table.insert(matches, { Id = id, Name = entry.Name })
		end
	end
	table.sort(matches, function(a, b)
		return string.lower(a.Name) < string.lower(b.Name)
	end)
	for _, m in matches do
		add(m.Id, false)
	end
	return { Ok = true, Clubs = clubs }
end

local function refreshTop()
	local list = {}
	for _, id in topIds() do
		local ok, club = get("club_" .. id)
		if ok and type(club) == "table" then
			table.insert(list, view(club, nil))
		end
	end
	table.sort(list, function(a, b)
		return a.Points > b.Points
	end)
	topCache = list
	topAt = os.clock()
end

local function top(player: Player)
	if os.clock() - topAt > TOP_REFRESH then
		refreshTop()
	end
	local list = {}
	local profile = DataService.Get(player)
	for i, c in topCache do
		local v = table.clone(c)
		v.Rank = i
		v.Mine = profile ~= nil and profile.ClubId == c.Id
		table.insert(list, v)
	end
	return { Ok = true, Clubs = list, Season = seasonInfo() }
end

----------------------------------------------------------------------------------------------------
-- Chat
----------------------------------------------------------------------------------------------------

local function chatHistory(player: Player)
	local id = clubOf(player)
	if not id then
		return fail("You're not in a club.")
	end
	local ok, list = get("chat_" .. id)
	return { Ok = true, Messages = if ok and type(list) == "table" then list else {} }
end

local function chat(player: Player, text: any)
	if type(text) ~= "string" then
		return fail("Type a message.")
	end
	local message = string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")
	if #message == 0 or #message > Config.Clubs.ChatLength then
		return fail(string.format("Messages are 1 to %d letters.", Config.Clubs.ChatLength))
	end
	if os.clock() - (lastChat[player] or 0) < CHAT_GAP then
		return fail("Slow down a little!")
	end
	lastChat[player] = os.clock()
	local id = clubOf(player)
	if not id then
		return fail("You're not in a club.")
	end
	-- Roblox's text filter (members see it in every server, so filter for broadcast).
	local ok, filtered = pcall(function()
		return TextService:FilterStringAsync(message, player.UserId, Enum.TextFilterContext.PublicChat):GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		if not RunService:IsStudio() then
			return fail("Couldn't send that. Try again in a moment.")
		end
		filtered = message
	end
	local entry = { U = player.UserId, N = player.DisplayName, T = filtered, At = os.time() }
	update("chat_" .. id, function(old)
		local list = if type(old) == "table" then old else {}
		table.insert(list, entry)
		while #list > Config.Clubs.ChatKeep do
			table.remove(list, 1)
		end
		return list
	end)
	publish({ Kind = "Chat", ClubId = id, Msg = entry })
	return { Ok = true }
end

local function onRequest(player: Player, action: any, value: any): any
	local now = os.clock()
	if now - (lastRequest[player] or 0) < 0.3 then
		return fail("Slow down a little!")
	end
	lastRequest[player] = now
	if not DataService.Get(player) then
		return fail("Your save is still loading.")
	end
	local ok, result = pcall(function(): any
		if action == "Mine" then
			local id, club = clubOf(player)
			if id and club == nil then
				-- Gone (deleted, or we were kicked elsewhere): tidy the profile up.
				local okGet, again = get("club_" .. id)
				if okGet and again == nil then
					setMembership(player, nil, false)
				end
			elseif club and not club.Members[tostring(player.UserId)] then
				setMembership(player, nil, false)
				club = nil
			end
			return { Ok = true, Club = if club and club.Members[tostring(player.UserId)] then view(club, player.UserId) else nil }
		elseif action == "Top" then
			return top(player)
		elseif action == "Info" and type(value) == "string" and #value <= 40 then
			return info(player, value)
		elseif action == "Donate" then
			return donate(player, value)
		elseif action == "Find" then
			return find(player, value)
		elseif action == "Create" then
			return create(player, value)
		elseif action == "Join" and type(value) == "string" and #value <= 40 then
			return join(player, value, false)
		elseif action == "JoinCode" and type(value) == "string" and #value <= 12 then
			local okCode, id = get("code_" .. string.upper(value))
			if not okCode then
				return fail("Clubs are busy. Try again in a moment.")
			end
			if type(id) ~= "string" then
				return fail("No club has that code.")
			end
			return join(player, id, true)
		elseif action == "Leave" then
			return leave(player)
		elseif action == "Kick" then
			return kick(player, value)
		elseif action == "Promote" then
			return setRole(player, value, "CoLeader")
		elseif action == "Demote" then
			return setRole(player, value, "Member")
		elseif action == "Settings" then
			return settings(player, value)
		elseif action == "Rename" then
			return rename(player, value)
		elseif action == "NewCode" then
			return regenerateCode(player)
		elseif action == "Chat" then
			return chat(player, value)
		elseif action == "ChatHistory" then
			return chatHistory(player)
		end
		return fail("Unknown request.")
	end)
	if not ok then
		warn("[ClubService] " .. tostring(action) .. " failed: " .. tostring(result))
		return fail("Something went wrong. Try again.")
	end
	return result
end

----------------------------------------------------------------------------------------------------
-- Points and membership checks
----------------------------------------------------------------------------------------------------

-- Donate Bubbles to your club: each one is a point for the club and for you this month.
function donate(player: Player, value: any): any
	local amount = math.floor(tonumber(value) or 0)
	if amount < 1 or amount > 1e9 then
		return fail("Pick an amount to donate.")
	end
	local id = clubOf(player)
	if not id then
		return fail("You're not in a club.")
	end
	if not DataService.SpendBubbles(player, amount) then
		return fail("You don't have that many Bubbles.")
	end
	local season = currentSeason()
	local uid = tostring(player.UserId)
	local ok, club = update("club_" .. id, function(old)
		if type(old) ~= "table" or not old.Members[uid] then
			return nil
		end
		if old.Season ~= season then -- a new month: everyone starts again from zero
			old.Season = season
			old.Points = 0
			for _, m in old.Members do
				m.Points = 0
			end
		end
		old.Points = (old.Points or 0) + amount
		old.Members[uid].Points = (tonumber(old.Members[uid].Points) or 0) + amount
		return old
	end)
	if not ok or not club then
		DataService.AddBubbles(player, amount, "ClubRefund")
		return fail("Couldn't donate right now. Your Bubbles were given back.")
	end
	setPoints(id, club.Points, season)
	topAt = -math.huge
	pushToMembers(club)
	return { Ok = true, Club = view(club, player.UserId), Message = string.format("Donated %d Bubbles!", amount) }
end

-- Any club's details and members (TOP CLUBS / FIND rows open it). Only members see the code.
function info(player: Player, id: string): any
	local ok, club = get("club_" .. id)
	if not ok then
		return fail("Clubs are busy. Try again in a moment.")
	end
	if type(club) ~= "table" then
		return fail("That club doesn't exist any more.")
	end
	return { Ok = true, Club = view(club, player.UserId, true) }
end

----------------------------------------------------------------------------------------------------
-- The monthly contest: closing a month and paying the winners
----------------------------------------------------------------------------------------------------

local closedSeasons: { [string]: boolean } = {}

-- Once per month (whichever server notices first): record the finished month's top 3 clubs and who
-- was in them.
local function ensureSeasonClosed()
	local prev = previousSeason()
	if closedSeasons[prev] then
		return
	end
	local ok, existing = get("season_" .. prev)
	if not ok then
		return
	end
	if existing then
		closedSeasons[prev] = true
		return
	end
	local clubs = {}
	for _, id in topIds(prev, 3) do
		local okClub, club = get("club_" .. id)
		if okClub and type(club) == "table" then
			local members = {}
			for uid in club.Members do
				table.insert(members, tonumber(uid))
			end
			table.insert(clubs, { Id = id, Name = club.Name, Tag = club.Tag, Rank = #clubs + 1, Members = members })
		end
	end
	update("season_" .. prev, function(old)
		if old then
			return nil
		end
		return { Season = prev, Clubs = clubs }
	end)
	closedSeasons[prev] = true
end

local function seasonName(season: string): string
	local y, m = tonumber(string.sub(season, 1, 4)) or 1970, tonumber(string.sub(season, 5, 6)) or 1
	return os.date("!%B %Y", daysFromCivil(y, m, 1) * 86400)
end

-- Pays last month's prize to a member of one of the top 3 clubs (once).
local function claimPrize(player: Player)
	local profile = DataService.Get(player)
	local prev = previousSeason()
	if not profile or profile.ClubPrizeSeason == prev then
		return
	end
	local ok, doc = get("season_" .. prev)
	if not ok or type(doc) ~= "table" then
		return
	end
	DataService.MarkClubPrize(player, prev)
	local rules = Config.Clubs.Season
	for _, c in doc.Clubs or {} do
		if table.find(c.Members or {}, player.UserId) then
			local gems = rules.PrizeGems[c.Rank] or 0
			local text = string.format("%s finished #%d in %s: +%d Gems", tostring(c.Name), c.Rank, seasonName(prev), gems)
			DataService.AddGems(player, gems)
			if c.Rank == 1 and rules.Pet then
				local okPet = (require(script.Parent:WaitForChild("PetService")) :: any).GivePet(player, rules.Pet)
				if okPet then
					text ..= " and the limited " .. Config.Pets[rules.Pet].Name .. " pet!"
				else
					DataService.AddGems(player, 150)
					text ..= " (pet bag full: +150 Gems instead of the pet)"
				end
			end
			;(require(script.Parent:WaitForChild("GiftService")) :: any).Celebrate(player, "Club contest prize!", text, "Gem")
			return
		end
	end
end

-- On join: is the club still there, and are they still in it? The prefix is refreshed from it, and
-- the client is told (so the Clubs window never has to guess). Then last month's prize, if any.
local function checkOnJoin(player: Player)
	local profile = DataService.Get(player)
	if not profile then
		return
	end
	if profile.ClubId ~= "" then
		local okGet, club = get("club_" .. profile.ClubId)
		if okGet then
			if type(club) ~= "table" or not club.Members[tostring(player.UserId)] then
				setMembership(player, nil, false)
			else
				if club.Tag ~= profile.ClubTag then
					DataService.SetClub(player, club.Id, club.Tag, false)
				end
				pushState(player, club)
			end
		end
	end
	pcall(ensureSeasonClosed)
	pcall(claimPrize, player)
end

-- MessagingService messages (and the Studio fallback).
function ClubService.OnMessage(data: any)
	if type(data) ~= "table" then
		return
	end
	if data.Kind == "Kicked" then
		local target = Players:GetPlayerByUserId(tonumber(data.UserId) or 0)
		local profile = target and DataService.Get(target)
		if target and profile and profile.ClubId == data.ClubId then
			setMembership(target, nil, false)
			Remotes.Event("Notify"):FireClient(target, "You were removed from your club.", "Info")
		end
	elseif data.Kind == "Chat" and type(data.Msg) == "table" then
		for _, plr in Players:GetPlayers() do
			local profile = DataService.Get(plr)
			if profile and profile.ClubId == data.ClubId then
				chatRemote:FireClient(plr, data.Msg)
			end
		end
	end
end

function ClubService.Init()
	if initialized then
		return
	end
	initialized = true
	pcall(function()
		clubStore = DataStoreService:GetDataStore(STORE)
		pointsStoreFor(currentSeason())
	end)
	stateRemote = Remotes.Event("ClubState")
	chatRemote = Remotes.Event("ClubChat")
	Remotes.Function("ClubRequest").OnServerInvoke = onRequest
	DataService.ProfileLoaded:Connect(function(player)
		task.spawn(checkOnJoin, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
		lastChat[player] = nil
	end)
	pcall(function()
		MessagingService:SubscribeAsync(TOPIC, function(message)
			ClubService.OnMessage(message.Data)
		end)
	end)
end

function ClubService.Start()
	task.spawn(function()
		while true do
			task.wait(600)
			pcall(ensureSeasonClosed)
		end
	end)
end

-- For tests.
ClubService.EnsureSeasonClosed = ensureSeasonClosed
ClubService.ClaimPrize = claimPrize
function ClubService.FlushPoints() end

return ClubService
