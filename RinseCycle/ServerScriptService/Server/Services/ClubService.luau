--[[
	ClubService - player clubs (the Clubs button), like other Roblox games' clans.

	  * Make one for Config.Clubs.CreateCost Gems: a name and a short tag (both run through Roblox's
	    text filter and unique), public or private, and requirements: a level beaten (0-3) and a
	    number of rebirths. Up to Config.Clubs.MaxMembers members.
	  * Public clubs: anyone who meets the requirements joins straight from the list or a search.
	    Private clubs: only with the club code (the owner sees it and can make a new one).
	  * Points: every Bubble a member earns while in the club (Stats.BubblesEarned going up) is a
	    point for the club. TOP CLUBS is the top 25 by points.
	  * Members wear the club tag after their name (player attribute ClubTag, NameTags).

	Storage (DataStores; in Studio without API access everything lives in memory):
	  RinseCycleClubs        "club_<id>"   the club record (members, settings, points)
	                         "name_<name>" -> id (names are unique, any case)
	                         "code_<CODE>" -> id (private club codes)
	  RinseCycleClubPoints   OrderedDataStore id -> points (TOP CLUBS)
	Other servers hear about kicks and deletes over MessagingService ("RinseCycle_Club"); a player's
	club is also checked against the record every time they join, so nothing can go stale for long.

	ClubRequest (C->S, action, value) -> { Ok, Error?, Club?, Clubs? }:
	  "Mine"  "Top"  "Find" (text: code or name)  "Create" ({Name, Tag, Public, ReqLevel, ReqRebirths})
	  "Join" (club id, public only)  "JoinCode" (code)  "Leave"  "Kick" (userId, owner only)
	  "Settings" ({Public, ReqLevel, ReqRebirths}, owner only)  "NewCode" (owner only)
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
local POINTS_FLUSH = 60 -- seconds between writing earned points
local TOP_REFRESH = 120 -- seconds the TOP CLUBS list is cached
local TOP_COUNT = 25
local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" -- no 0/O or 1/I

local initialized = false
local clubStore: DataStore? = nil
local pointsStore: OrderedDataStore? = nil
local memory: { [string]: any } = {} -- Studio / no API access
local memoryPoints: { [string]: number? } = {}
local lastRequest: { [Player]: number } = {}
local seenBubbles: { [Player]: number } = {}
local pendingPoints: { [string]: number } = {}
local topCache: { any } = {}
local topAt = -math.huge
local stateRemote: RemoteEvent

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

local function setPoints(id: string, points: number?)
	if useMemory() then
		memoryPoints[id] = points
		return
	end
	local store = pointsStore
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

local function topIds(): { string }
	local ids: { string } = {}
	if useMemory() then
		local pairsList: { { any } } = {}
		for id, points in memoryPoints do
			table.insert(pairsList, { id :: any, points })
		end
		table.sort(pairsList, function(a, b)
			return a[2] > b[2]
		end)
		for i = 1, math.min(TOP_COUNT, #pairsList) do
			ids[i] = pairsList[i][1]
		end
		return ids
	end
	local store = pointsStore
	if not store then
		return ids
	end
	local ok, page = pcall(function()
		return store:GetSortedAsync(false, TOP_COUNT):GetCurrentPage()
	end)
	if ok and type(page) == "table" then
		for _, entry in page do
			table.insert(ids, entry.key)
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

-- Roblox's text filter. Anything it would hide (or a failed check outside Studio) is refused.
local function filterOk(player: Player, text: string): (boolean, string?)
	local ok, filtered = pcall(function()
		return TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat):GetNonChatStringForBroadcastAsync()
	end)
	if not ok then
		if RunService:IsStudio() then
			return true
		end
		return false, "Couldn't check that name. Try again in a moment."
	end
	if filtered ~= text then
		return false, "That isn't allowed. Try something else."
	end
	return true
end

-- What the client is shown. Members (and only members) see a private club's code.
local function view(club: any, forUserId: number?): any
	local members = {}
	for uid, m in club.Members do
		local id = tonumber(uid) or 0
		table.insert(members, {
			UserId = id,
			Name = m.Name,
			Role = m.Role,
			Online = Players:GetPlayerByUserId(id) ~= nil,
		})
	end
	table.sort(members, function(a, b)
		if (a.Role == "Owner") ~= (b.Role == "Owner") then
			return a.Role == "Owner"
		end
		return a.Name < b.Name
	end)
	local isMember = forUserId ~= nil and club.Members[tostring(forUserId)] ~= nil
	return {
		Id = club.Id,
		Name = club.Name,
		Tag = club.Tag,
		Public = club.Public,
		ReqLevel = club.ReqLevel,
		ReqRebirths = club.ReqRebirths,
		Points = club.Points,
		Count = #members,
		Max = Config.Clubs.MaxMembers,
		Owner = club.Owner,
		OwnerName = club.OwnerName,
		Code = if isMember then club.Code else nil,
		Members = if isMember then members else nil,
		Mine = isMember,
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
		pcall(function()
			MessagingService:PublishAsync(TOPIC, message)
		end)
	end)
end

local function pushState(player: Player, club: any?)
	if player.Parent == Players then
		stateRemote:FireClient(player, if club then view(club, player.UserId) else nil)
	end
end

-- Puts the membership on the player's profile (tag over their head) and tells their client.
local function setMembership(player: Player, club: any?, moved: boolean)
	DataService.SetClub(player, if club then club.Id else "", if club then club.Tag else "", moved)
	seenBubbles[player] = nil
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
		old.Members[tostring(player.UserId)] = { Name = player.DisplayName, Role = "Member", Joined = os.time() }
		return old
	end)
	if not ok then
		return fail("Clubs are busy. Try again in a moment.")
	end
	if not club then
		return fail(reason or "Couldn't join that club.")
	end
	setMembership(player, club, true)
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
	local name = if type(value.Name) == "string" then string.gsub(string.gsub(value.Name, "^%s+", ""), "%s+$", "") else ""
	name = string.gsub(name, "%s+", " ")
	local tag = if type(value.Tag) == "string" then string.upper((string.gsub(value.Tag, "%s+", ""))) else ""
	if utf8.len(name) == nil or #name < rules.NameLength[1] or #name > rules.NameLength[2] then
		return fail(string.format("Club names are %d to %d letters.", rules.NameLength[1], rules.NameLength[2]))
	end
	if not string.match(name, "^[%w ]+$") then
		return fail("Use letters, numbers and spaces only.")
	end
	if #tag < rules.TagLength[1] or #tag > rules.TagLength[2] or not string.match(tag, "^%w+$") then
		return fail(string.format("Tags are %d to %d letters or numbers.", rules.TagLength[1], rules.TagLength[2]))
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
		return fail(whyTag or "That tag isn't allowed.")
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
		Created = os.time(),
		Members = { [tostring(player.UserId)] = { Name = player.DisplayName, Role = "Owner", Joined = os.time() } },
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
	setPoints(club.Id, nil)
	topAt = -math.huge
end

local function leave(player: Player)
	local id = clubOf(player)
	if not id then
		return fail("You're not in a club.")
	end
	local emptied: any = nil
	local ok = update("club_" .. id, function(old)
		if type(old) ~= "table" then
			return nil
		end
		old.Members[tostring(player.UserId)] = nil
		if memberCount(old) == 0 then
			emptied = old
			return nil
		end
		if old.Owner == player.UserId then
			-- The longest-standing member takes over.
			local heir, heirJoined = nil, math.huge
			for uid, m in old.Members do
				if (m.Joined or 0) < heirJoined then
					heir, heirJoined = uid, m.Joined or 0
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
	end
	setMembership(player, nil, true)
	return { Ok = true, Message = "You left the club." }
end

local function ownerEdit(player: Player, edit: (any) -> string?)
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
		if old.Owner ~= player.UserId then
			reason = "Only the club owner can do that."
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
	pushState(player, club)
	return { Ok = true, Club = view(club, player.UserId) }
end

local function kick(player: Player, userId: any)
	if type(userId) ~= "number" or userId == player.UserId then
		return fail("Pick a member to kick.")
	end
	local result = ownerEdit(player, function(club)
		if not club.Members[tostring(userId)] then
			return "They're not in your club."
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

local function settings(player: Player, value: any)
	if type(value) ~= "table" then
		return fail("Bad request.")
	end
	return ownerEdit(player, function(club)
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
end

local function regenerateCode(player: Player)
	local oldCode: string? = nil
	local result = ownerEdit(player, function(club)
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

local function find(player: Player, text: any)
	if type(text) ~= "string" then
		return fail("Type a club name or code.")
	end
	local query = string.gsub(string.gsub(text, "^%s+", ""), "%s+$", "")
	if #query < 2 or #query > 30 then
		return fail("Type a club name or code.")
	end
	local clubs = {}
	local seen = {}
	local function add(id: any)
		if type(id) ~= "string" or seen[id] then
			return
		end
		seen[id] = true
		local ok, club = get("club_" .. id)
		if ok and type(club) == "table" then
			local v = view(club, player.UserId)
			v.ByCode = string.upper(query) == club.Code
			table.insert(clubs, v)
		end
	end
	local okCode, byCode = get("code_" .. string.upper(query))
	if okCode then
		add(byCode)
	end
	local okName, byName = get(nameKey(query))
	if okName then
		add(byName)
	end
	-- Also any club in TOP CLUBS whose name contains the text.
	local lower = string.lower(query)
	for _, c in topCache do
		if string.find(string.lower(c.Name), lower, 1, true) then
			add(c.Id)
		end
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
	return { Ok = true, Clubs = list }
end

local function onRequest(player: Player, action: any, value: any): any
	local now = os.clock()
	if now - (lastRequest[player] or 0) < 0.4 then
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
		elseif action == "Settings" then
			return settings(player, value)
		elseif action == "NewCode" then
			return regenerateCode(player)
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

-- Bubbles members earned since the last look become club points (written every POINTS_FLUSH).
local function collectPoints()
	for _, player in Players:GetPlayers() do
		local profile = DataService.Get(player)
		if profile and profile.ClubId ~= "" then
			local earned = tonumber(profile.Stats and profile.Stats.BubblesEarned) or 0
			local last = seenBubbles[player]
			seenBubbles[player] = earned
			if last and earned > last then
				pendingPoints[profile.ClubId] = (pendingPoints[profile.ClubId] or 0) + (earned - last)
			end
		end
	end
end

local function flushPoints()
	collectPoints()
	local batch = pendingPoints
	pendingPoints = {}
	for id, add in batch do
		local ok, club = update("club_" .. id, function(old)
			if type(old) ~= "table" then
				return nil
			end
			old.Points = (old.Points or 0) + add
			return old
		end)
		if ok and club then
			setPoints(id, club.Points)
		end
	end
end

-- On join: is the club still there, and are they still in it? The tag is refreshed from it.
local function checkOnJoin(player: Player)
	local profile = DataService.Get(player)
	if not profile or profile.ClubId == "" then
		return
	end
	local okGet, club = get("club_" .. profile.ClubId)
	if not okGet then
		return -- can't tell right now; keep it
	end
	if type(club) ~= "table" or not club.Members[tostring(player.UserId)] then
		setMembership(player, nil, false)
	elseif club.Tag ~= profile.ClubTag then
		DataService.SetClub(player, club.Id, club.Tag, false)
	end
end

function ClubService.Init()
	if initialized then
		return
	end
	initialized = true
	pcall(function()
		clubStore = DataStoreService:GetDataStore(STORE)
		pointsStore = DataStoreService:GetOrderedDataStore(POINTS_STORE)
	end)
	stateRemote = Remotes.Event("ClubState")
	Remotes.Function("ClubRequest").OnServerInvoke = onRequest
	DataService.ProfileLoaded:Connect(function(player)
		task.spawn(checkOnJoin, player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		local profile = DataService.Get(player)
		local earned = profile and tonumber(profile.Stats and profile.Stats.BubblesEarned)
		local last = seenBubbles[player]
		if profile and profile.ClubId ~= "" and earned and last and earned > last then
			pendingPoints[profile.ClubId] = (pendingPoints[profile.ClubId] or 0) + (earned - last)
		end
		lastRequest[player] = nil
		seenBubbles[player] = nil
	end)
	pcall(function()
		MessagingService:SubscribeAsync(TOPIC, function(message)
			local data = message.Data
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
			end
		end)
	end)
end

function ClubService.Start()
	task.spawn(function()
		while true do
			task.wait(POINTS_FLUSH)
			pcall(flushPoints)
		end
	end)
	game:BindToClose(function()
		pcall(flushPoints)
	end)
end

-- For tests: write pending points now.
ClubService.FlushPoints = flushPoints

return ClubService
