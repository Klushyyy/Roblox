--[[
	Analytics - records what players do, so you can see where they get stuck and where they leave.

	Everything is a "moment" with a short key (the list lives in Config.Analytics: "pad.enter",
	"run.clear", "tut.s3", "meta.Hatch" ...). Any service records one with
	    DataService.Track(player, "run.arrive", { Level = 2 })
	(DataService.Track does nothing until this script is running, so no service depends on it).

	What a moment does:
	  * the in-game tally (the admin command :analytics): per UTC day how many times it happened (n:),
	    how many different players did it (u:), and, for brand-new players, how many of each sign-up
	    day's group ever reached it (f:). Retention (ret.N), where players left (left: / l1:), how long
	    visits lasted (len:), money in and out (eco:) and script errors (err:) are counted too. Each
	    server adds its counts to the DataStore Config.Analytics.StoreName every FlushSeconds, in one
	    document per day ("D20261008") and one per sign-up day ("C20261008").
	  * Roblox's own dashboards (Creator Hub > Analytics): the funnels in Config.Analytics.Funnels go
	    to Funnels (the Onboarding one is the once-per-player funnel), money in and out to Economy,
	    run starts / clears / failures to Progression, and everything else to Custom events. Roblox
	    ignores these from Studio, so they are only sent from a published game, and they are rate
	    limited here (Config.Analytics.RobloxPerMinute) so the game never goes over Roblox's limit.
	  * Players' screens send moments too (Telemetry.luau -> the Telemetry remote); only the keys in
	    Config.Analytics.ClientEvents / ClientFamilies are accepted, a few at a time.

	Nothing in here can break the game: every Roblox or DataStore call is wrapped, a moment that is
	not in the Config lists is dropped, and a player's counts are kept small (the profile's An block).
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Format = require(Shared:WaitForChild("Format"))

local DataService = require(script.Parent:WaitForChild("DataService"))

local Analytics = {}

local A = Config.Analytics
local DAY = 86400
local MAX_TELEMETRY_BATCH = 12
local TELEMETRY_PER_WINDOW = 40 -- moments a player's screen may send per 10 seconds
local MAX_COUNTERS_PER_DOC = 1600
local MAX_ERROR_KEYS_PER_DOC = 60
local MAX_DAY_MARKS = 150
local MAX_SEEN_MARKS = 200
local DOCS_PER_FLUSH = 12
local ECONOMY_FLUSH = 30 -- seconds of money changes are added up before they go to Roblox
local CACHE_SECONDS = 60

----------------------------------------------------------------------------------------------------
-- The key lists from Config, indexed
----------------------------------------------------------------------------------------------------

local labelOf: { [string]: string } = {}
for _, entry in A.Events do
	labelOf[entry[1]] = entry[2]
end
local familyLabel: { [string]: string } = {}
local familyList: { string } = {}
for _, entry in A.Families do
	familyLabel[entry[1]] = entry[2]
	table.insert(familyList, entry[1])
end
-- (longest prefix first, so "run.tool" wins over a shorter one)
table.sort(familyList, function(a, b)
	return #a > #b
end)
local clientExact: { [string]: boolean } = {}
for _, key in A.ClientEvents do
	clientExact[key] = true
end
local clientFamily: { [string]: boolean } = {}
for _, key in A.ClientFamilies do
	clientFamily[key] = true
end

type Step = { Funnel: any, Index: number, Name: string }
local stepsOf: { [string]: { Step } } = {}
for _, funnel in A.Funnels do
	for index, step in funnel.Steps do
		local list = stepsOf[step[1]]
		if not list then
			list = {}
			stepsOf[step[1]] = list
		end
		table.insert(list, { Funnel = funnel, Index = index, Name = step[2] })
	end
end

-- "ui.open.Shop" -> "ui.open.Shop", "ui.open"; an exact key -> key, nil; anything else -> nil.
local detailsSeen: { [string]: { [string]: boolean } } = {}
local detailCount: { [string]: number } = {}
local function resolve(key: string): (string?, string?)
	if labelOf[key] then
		return key, nil
	end
	for _, prefix in familyList do
		if string.sub(key, 1, #prefix + 1) == prefix .. "." then
			local detail = string.sub(key, #prefix + 2)
			detail = string.sub(string.gsub(detail, "[^%w_:%-]", "_"), 1, 24)
			if detail == "" then
				return prefix, nil
			end
			local seen = detailsSeen[prefix]
			if not seen then
				seen = {}
				detailsSeen[prefix] = seen
				detailCount[prefix] = 0
			end
			if not seen[detail] then
				if detailCount[prefix] >= A.MaxDetails then
					return prefix, nil -- too many different details: only the family itself is counted
				end
				seen[detail] = true
				detailCount[prefix] += 1
			end
			return prefix .. "." .. detail, prefix
		end
	end
	return nil, nil
end

local function labelFor(key: string): string
	if labelOf[key] then
		return labelOf[key]
	end
	for _, prefix in familyList do
		if string.sub(key, 1, #prefix + 1) == prefix .. "." then
			return string.format("%s: %s", familyLabel[prefix], string.sub(key, #prefix + 2))
		end
	end
	if familyLabel[key] then
		return familyLabel[key] .. " (all)"
	end
	return key
end

----------------------------------------------------------------------------------------------------
-- Settings that tests replace
----------------------------------------------------------------------------------------------------

local live = A.Enabled and not RunService:IsStudio()
local robloxService: any = nil
local storeOverride: any = nil
local nowFn: () -> number = os.time

-- For tests: { Live = bool, Roblox = fake AnalyticsService, Store = fake DataStore, Now = function }.
function Analytics.Configure(options: { [string]: any })
	if options.Live ~= nil then
		live = options.Live == true
	end
	if options.Roblox ~= nil then
		robloxService = options.Roblox
	end
	if options.Store ~= nil then
		storeOverride = options.Store
	end
	if options.Now ~= nil then
		nowFn = options.Now
	end
end

local function getRoblox(): any
	if robloxService == nil then
		local ok, service = pcall(function()
			return game:GetService("AnalyticsService")
		end)
		robloxService = if ok and service then service else false
	end
	return if robloxService then robloxService else nil
end

local store: any = nil
local function getStore(): any
	if storeOverride then
		return storeOverride
	end
	if store == nil then
		local ok, result = pcall(function()
			return DataStoreService:GetDataStore(A.StoreName)
		end)
		store = if ok and result then result else false
	end
	return if store then store else nil
end

local function today(): number
	return nowFn() // DAY
end

local function stamp(dayNumber: number): string
	return os.date("!%Y%m%d", dayNumber * DAY)
end

local function dailyDoc(dayNumber: number?): string
	return "D" .. stamp(dayNumber or today())
end

local function cohortDoc(dayNumber: number): string
	return "C" .. stamp(dayNumber)
end

----------------------------------------------------------------------------------------------------
-- Counters (added up here, written to the DataStore every FlushSeconds)
----------------------------------------------------------------------------------------------------

local pending: { [string]: { [string]: number } } = {}
local flushing = false

local function cleanCounter(name: string): string
	return string.sub(string.gsub(name, "[^%w%._:%-%s%%/<>+#]", "_"), 1, 64)
end

local function bump(doc: string, counter: string, amount: number?)
	local n = amount or 1
	if n == 0 or n ~= n then
		return
	end
	local counters = pending[doc]
	if not counters then
		counters = {}
		pending[doc] = counters
	end
	local name = cleanCounter(counter)
	counters[name] = (counters[name] or 0) + n
end

----------------------------------------------------------------------------------------------------
-- Roblox's own analytics (published games only, rate limited, every call wrapped)
----------------------------------------------------------------------------------------------------

local bucket = { Tokens = A.RobloxPerMinute, At = os.clock() } -- (starts full: a burst of joins is fine)
local robloxDropped = 0

local function allowRoblox(): boolean
	local capacity = A.RobloxPerMinute + A.RobloxPerPlayer * #Players:GetPlayers()
	local now = os.clock()
	bucket.Tokens = math.min(capacity, bucket.Tokens + (now - bucket.At) * capacity / 60)
	bucket.At = now
	if bucket.Tokens >= 1 then
		bucket.Tokens -= 1
		return true
	end
	robloxDropped += 1
	return false
end

local function robloxReady(): boolean
	return live and getRoblox() ~= nil
end

-- At most three fields, strings or numbers only (Roblox's limit).
local function customFields(fields: { [string]: any }?): { [string]: any }?
	if type(fields) ~= "table" then
		return nil
	end
	local out, count = {}, 0
	local names = {}
	for name in fields do
		if type(name) == "string" then
			table.insert(names, name)
		end
	end
	table.sort(names)
	for _, name in names do
		local value = fields[name]
		if count < 3 and (type(value) == "number" or type(value) == "string") then
			out[name] = if type(value) == "string" then string.sub(value, 1, 40) else value
			count += 1
		end
	end
	return if count > 0 then out else nil
end

local function callRoblox(method: string, ...: any)
	if not robloxReady() or not allowRoblox() then
		return
	end
	local service = getRoblox()
	local args = table.pack(...)
	local ok, err = pcall(function()
		service[method](service, table.unpack(args, 1, args.n))
	end)
	if not ok then
		warn(string.format("[Analytics] %s failed: %s", method, tostring(err)))
	end
end

local function enumItem(enumName: string, item: string): any
	local ok, value = pcall(function()
		return (Enum :: any)[enumName][item]
	end)
	return if ok then value else nil
end

----------------------------------------------------------------------------------------------------
-- Per-player state
----------------------------------------------------------------------------------------------------

type State = {
	Profile: any,
	An: any,
	IsNew: boolean, -- in a sign-up group (An.First > 0)
	Context: string,
	Sub: string?,
	Device: string?,
	Attempts: { [string]: string }, -- funnel -> the id of the attempt under way
	AttemptStep: { [string]: number },
	Logged: { [string]: boolean }, -- funnel steps already sent to Roblox
	SentCustom: { [string]: boolean },
	DayN: number,
	SeenN: number,
	Window: { Start: number, Count: number },
	Eco: { [string]: { Flow: any, Currency: string, Amount: number, Balance: number, Reason: string } },
	EcoAt: number,
	PadSeen: boolean,
	JoinedAt: number,
	Hop: boolean,
}

local states: { [Player]: State } = {}
local early: { [Player]: { { string | { [string]: any } } } } = {} -- moments that arrived before the profile did
local showStart: number? = nil
local showShown: { [number]: boolean } = {}

local function isRunServer(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

local function showMinute(): number?
	if ReplicatedStorage:GetAttribute("AbuseLive") == true and showStart then
		return math.max(0, (nowFn() - showStart) // 60)
	end
	return nil
end

local function whereText(player: Player, st: State): string
	local base = st.Context
	if base == "Lobby" then
		if player:GetAttribute("InParty") == true then
			base = "Pad"
		end
		local minute = showMinute()
		if minute then
			base = string.format("Show min %d", minute)
		end
	end
	if st.Sub and st.Sub ~= "" then
		base ..= " / " .. st.Sub
	end
	return string.sub(base, 1, 44)
end

local function lengthBucket(seconds: number): string
	for _, entry in A.LengthBuckets do
		if seconds < entry[1] then
			return entry[2]
		end
	end
	return A.LengthBuckets[#A.LengthBuckets][2]
end

-- A fresh id for a funnel attempt (a GUID; a random one if that isn't available).
local function newAttemptId(): string
	local ok, id = pcall(function()
		return HttpService:GenerateGUID(false)
	end)
	if ok and type(id) == "string" then
		return id
	end
	return string.format("%x-%x", nowFn(), math.random(1, 2 ^ 30))
end

-- The ordered list of funnel steps this moment belongs to, sent to Roblox.
local function sendFunnel(player: Player, st: State, key: string, first: boolean, fields: { [string]: any }?)
	local list = stepsOf[key]
	if not list then
		return
	end
	for _, step in list do
		local funnel = step.Funnel
		if funnel.Onboarding then
			if first and st.IsNew then
				callRoblox("LogOnboardingFunnelStepEvent", player, step.Index, step.Name)
			end
		else
			local name = funnel.Name
			local id = st.Attempts[name]
			-- (a new attempt starts when the first step happens again after the last one got further)
			if not id or (step.Index == 1 and (st.AttemptStep[name] or 0) > 1) then
				id = newAttemptId()
				st.Attempts[name] = id
				st.AttemptStep[name] = 0
			end
			local mark = name .. "|" .. id .. "|" .. step.Index
			if not st.Logged[mark] then
				st.Logged[mark] = true
				st.AttemptStep[name] = math.max(st.AttemptStep[name] or 0, step.Index)
				callRoblox("LogFunnelStepEvent", player, name, id, step.Index, step.Name, customFields(fields))
			end
			if step.Index == #funnel.Steps then
				st.Attempts[name] = nil
				st.AttemptStep[name] = nil
			end
		end
	end
end

-- Counts one key (daily, unique today, first ever). Returns true the first time ever.
local function count(st: State, key: string): boolean
	local an = st.An
	local day = today()
	local doc = dailyDoc(day)
	bump(doc, "n:" .. key)
	if an.DayNum ~= day then
		an.DayNum = day
		an.Day = {}
		st.DayN = 0
	end
	if not an.Day[key] and st.DayN < MAX_DAY_MARKS then
		an.Day[key] = true
		st.DayN += 1
		bump(doc, "u:" .. key)
	end
	if an.Seen[key] == nil and st.SeenN < MAX_SEEN_MARKS then
		an.Seen[key] = day
		st.SeenN += 1
		if an.First > 0 then
			bump(cohortDoc(an.First), "f:" .. key)
		end
		return true
	end
	return false
end

local function progression(player: Player, st: State, key: string, fields: { [string]: any }?)
	local level = if fields and type(fields.Level) == "number" then fields.Level else nil
	if key == "run.arrive" and level then
		callRoblox("LogProgressionEvent", player, "Dishwasher", enumItem("AnalyticsProgressionType", "Start"), level, "Level " .. level)
	elseif key == "run.clear" and level then
		callRoblox("LogProgressionEvent", player, "Dishwasher", enumItem("AnalyticsProgressionType", "Complete"), level, "Level " .. level)
	elseif (key == "run.leave" or key == "run.drop") and level then
		callRoblox("LogProgressionEvent", player, "Dishwasher", enumItem("AnalyticsProgressionType", "Fail"), level, "Level " .. level)
	elseif key == "meta.Rebirth" then
		local rebirths = st.Profile.Rebirths or 0
		callRoblox("LogProgressionEvent", player, "Rebirth", enumItem("AnalyticsProgressionType", "Complete"), rebirths, "Rebirth " .. rebirths)
	end
end

local record: (player: Player, st: State, key: string, fields: { [string]: any }?) -> ()
record = function(player: Player, st: State, key: string, fields: { [string]: any }?)
	local full, family = resolve(key)
	if not full then
		return
	end
	local first = count(st, full)
	local familyFirst = false
	if family then
		familyFirst = count(st, family)
	end
	sendFunnel(player, st, full, first, fields)
	if family then
		sendFunnel(player, st, family, familyFirst, fields)
	end
	progression(player, st, full, fields)
	if family == "buy.ok" and fields and type(fields.Robux) == "number" and fields.Robux > 0 then
		bump(dailyDoc(), "robux:" .. full, fields.Robux)
	end
	if string.sub(full, 1, 4) == "pad." then
		st.PadSeen = true
	end
	if full == "run.arrive" then
		-- (their 2nd, 5th and 10th run are moments of their own: do they come back for another?)
		st.An.Runs += 1
		local n = st.An.Runs
		if n == 2 or n == 5 or n == 10 then
			record(player, st, "run.n" .. n, nil)
		end
	end
	-- Everything that isn't a funnel step is a "Feature" custom event, once per player per server visit.
	if not stepsOf[full] and not (family and stepsOf[family]) and not st.SentCustom[full] and string.sub(full, 1, 7) ~= "client." then
		st.SentCustom[full] = true
		local area = string.match(full, "^([^%.]+)") or full
		callRoblox("LogCustomEvent", player, "Feature", 1, { Area = area, Name = string.sub(full, 1, 40) })
	end
end

----------------------------------------------------------------------------------------------------
-- Public: moments, context, funnel attempts
----------------------------------------------------------------------------------------------------

-- Records a moment. `fields` (optional, up to three strings or numbers) go to Roblox with it;
-- { Level = n } also drives the Progression events.
function Analytics.Event(player: Player, key: string, fields: { [string]: any }?)
	if not A.Enabled or type(key) ~= "string" or typeof(player) ~= "Instance" then
		return
	end
	local st = states[player]
	if not st then
		-- (the profile is still loading: keep a few and replay them when it arrives)
		local list = early[player]
		if not list then
			list = {}
			early[player] = list
		end
		if #list < 24 and player.Parent == Players then
			table.insert(list, { key, fields })
		end
		return
	end
	local ok, err = pcall(record, player, st, key, fields)
	if not ok then
		warn("[Analytics] " .. tostring(err))
	end
end

-- Where the player is now ("Lobby", "Run L2 25-50%"): what the "where did they leave" tally shows.
function Analytics.SetContext(player: Player, context: string)
	local st = states[player]
	if st and type(context) == "string" then
		st.Context = string.sub(context, 1, 30)
	end
end

function Analytics.SetSub(player: Player, sub: string?)
	local st = states[player]
	if st then
		st.Sub = if type(sub) == "string" and sub ~= "" then string.sub(string.gsub(sub, "[^%w_:%-]", "_"), 1, 20) else nil
	end
end

-- The id of the player's current attempt at a recurring funnel (so a run server can carry on logging it).
function Analytics.AttemptId(player: Player, funnel: string): string?
	local st = states[player]
	return if st then st.Attempts[funnel] else nil
end

function Analytics.SetAttemptId(player: Player, funnel: string, id: string)
	local st = states[player]
	if st and type(id) == "string" and #id <= 60 then
		st.Attempts[funnel] = id
		st.AttemptStep[funnel] = math.max(st.AttemptStep[funnel] or 0, 2)
	end
end

----------------------------------------------------------------------------------------------------
-- Money (DataService.EconomyChanged) -> Economy events + the eco: tally
----------------------------------------------------------------------------------------------------

local TRANSACTION = {
	Product = "IAP",
	Tutorial = "Onboarding",
	Referred = "Onboarding",
	Daily = "TimedReward",
	Premium = "TimedReward",
	StayBoost = "TimedReward",
	Perk = "Shop",
	Egg = "Shop",
	RankRoll = "Shop",
	ClubCreate = "Shop",
	ClubDonate = "Shop",
	Upgrade = "Shop",
	Tool = "Shop",
}

local function flushEconomy(player: Player, st: State)
	for key, item in st.Eco do
		st.Eco[key] = nil
		local base = string.match(item.Reason, "^([^:]+)") or item.Reason
		local transaction = TRANSACTION[base] or "Gameplay"
		callRoblox("LogEconomyEvent", player, item.Flow, item.Currency, item.Amount, item.Balance, transaction, string.sub(item.Reason, 1, 40))
	end
	st.EcoAt = os.clock()
end

local function onEconomy(player: Player, currency: string, amount: number, balance: number, reason: string)
	if not A.Enabled or type(amount) ~= "number" or amount == 0 then
		return
	end
	local kind = if amount > 0 then "src" else "snk"
	local why = string.sub(string.gsub(tostring(reason or "Other"), "[^%w_:%-]", "_"), 1, 24)
	local doc = dailyDoc()
	bump(doc, string.format("eco:%s:%s:%s", kind, currency, why), math.abs(amount))
	bump(doc, string.format("ecn:%s:%s:%s", kind, currency, why), 1)
	local st = states[player]
	if not st then
		return
	end
	-- (added up for ECONOMY_FLUSH seconds: a golden spot every few seconds would flood Roblox)
	local mark = kind .. currency .. why
	local item = st.Eco[mark]
	local flow = enumItem("AnalyticsEconomyFlowType", if amount > 0 then "Source" else "Sink")
	if item then
		item.Amount += math.abs(amount)
		item.Balance = balance
	else
		st.Eco[mark] = { Flow = flow, Currency = currency, Amount = math.abs(amount), Balance = balance, Reason = why }
	end
	if os.clock() - st.EcoAt > ECONOMY_FLUSH then
		flushEconomy(player, st)
	end
end

----------------------------------------------------------------------------------------------------
-- Joining and leaving
----------------------------------------------------------------------------------------------------

local function countMarks(table_: { [string]: any }): number
	local n = 0
	for _ in table_ do
		n += 1
	end
	return n
end

local function onProfileLoaded(player: Player, profile: any)
	if not A.Enabled or states[player] or type(profile) ~= "table" or type(profile.An) ~= "table" then
		return
	end
	-- A temporary profile (the save could not be read) says nothing true about this player.
	if not DataService.IsOffline() and not DataService.CanSave(player) then
		early[player] = nil
		return
	end
	local an = profile.An
	local now = nowFn()
	local day = now // DAY
	if an.First == 0 then
		an.First = -1 -- played before analytics existed
	end
	local st: State = {
		Profile = profile,
		An = an,
		IsNew = an.First > 0,
		Context = "Lobby",
		Sub = nil,
		Device = nil,
		Attempts = {},
		AttemptStep = {},
		Logged = {},
		SentCustom = {},
		DayN = if an.DayNum == day then countMarks(an.Day) else 0,
		SeenN = countMarks(an.Seen),
		Window = { Start = os.clock(), Count = 0 },
		Eco = {},
		EcoAt = os.clock(),
		PadSeen = false,
		JoinedAt = now,
		Hop = false,
	}
	states[player] = st

	-- Arrived from a lobby: carry on the run attempt that started there.
	local ok, data = pcall(function()
		return player:GetJoinData().TeleportData
	end)
	if ok and type(data) == "table" and type(data.Fids) == "table" then
		local id = data.Fids[tostring(player.UserId)]
		if type(id) == "string" then
			Analytics.SetAttemptId(player, "Run", id)
		end
	end

	local newVisit = an.Last == 0 or now - an.Last > A.VisitGap
	if newVisit then
		an.Visits += 1
		an.VisitStart = now
	end
	if an.First > 0 then
		local index = day - an.First
		if index >= 1 and index <= 30 and bit32.band(an.Mask, bit32.lshift(1, index)) == 0 then
			an.Mask = bit32.bor(an.Mask, bit32.lshift(1, index))
			bump(cohortDoc(an.First), "ret." .. index)
		end
	end
	an.Last = now

	record(player, st, "join", nil)
	if newVisit then
		record(player, st, "visit", nil)
		record(player, st, if an.First > 0 and an.Visits == 1 then "visit.new" else "visit.back", nil)
	end
	if player.MembershipType == Enum.MembershipType.Premium then
		record(player, st, "premium.here", nil)
	end
	if profile.DailyLast == 0 or now >= profile.DailyLast + Config.Daily.Cooldown then
		record(player, st, "daily.ready", nil)
	end
	if showMinute() then
		record(player, st, "show.join", nil)
	end

	-- Moments that were recorded before the profile loaded.
	local waiting = early[player]
	early[player] = nil
	if waiting then
		for _, item in waiting do
			pcall(record, player, st, item[1] :: string, item[2] :: any)
		end
	end

	-- New visit in a lobby, and no pad entered after a minute (three): they probably don't know what to do.
	if newVisit and not isRunServer() then
		for index, seconds in A.LostAfter do
			task.delay(seconds, function()
				local current = states[player]
				if current == st and not st.PadSeen and st.Context == "Lobby" and player:GetAttribute("InRun") ~= true then
					record(player, st, if index == 1 then "lobby.lost1" else "lobby.lost3", nil)
				end
			end)
		end
	end
end

local function onLeave(player: Player, st: State)
	local an = st.An
	local now = nowFn()
	local seconds = math.max(0, now - (if an.VisitStart > 0 then an.VisitStart else st.JoinedAt))
	local where = whereText(player, st)
	local length = lengthBucket(seconds)
	local doc = dailyDoc()
	bump(doc, "left:" .. where)
	bump(doc, "len:" .. length)
	bump(doc, "playsec", seconds)
	bump(doc, "visits_done")
	if an.First > 0 and an.Visits == 1 then
		local cohort = cohortDoc(an.First)
		bump(cohort, "l1:" .. where)
		bump(cohort, "l1len:" .. length)
		bump(cohort, "l1sec", seconds)
	end
	if an.First > 0 then
		bump(cohortDoc(an.First), "playsec", seconds)
	end
	flushEconomy(player, st)
	callRoblox("LogCustomEvent", player, "Leave", seconds, { Where = where, Length = length, Device = st.Device or "Unknown" })
end

local function onRemoving(player: Player)
	early[player] = nil
	local st = states[player]
	if not st then
		return
	end
	states[player] = nil
	st.An.Last = nowFn()
	local hop = st.Hop or player:GetAttribute("Teleporting") == true
	if hop then
		flushEconomy(player, st)
		return
	end
	local ok, err = pcall(onLeave, player, st)
	if not ok then
		warn("[Analytics] leave: " .. tostring(err))
	end
end

----------------------------------------------------------------------------------------------------
-- Screens (the Telemetry remote)
----------------------------------------------------------------------------------------------------

local DEVICES = { Phone = true, Tablet = true, Desktop = true, Console = true }
local clientErrors: { [Player]: number } = {}

local function normalizeError(message: string): string
	local text = string.gsub(message, "%d+", "#")
	text = string.gsub(text, "[%c]", " ")
	text = string.gsub(text, "^%s+", "")
	return string.sub(text, 1, 56)
end

local function countError(kind: string, message: string)
	local doc = dailyDoc()
	bump(doc, "n:err." .. kind)
	local counters = pending[doc]
	local keys = 0
	if counters then
		for name in counters do
			if string.sub(name, 1, 4) == "err:" then
				keys += 1
			end
		end
	end
	local name = "err:" .. kind .. " " .. normalizeError(message)
	if keys < MAX_ERROR_KEYS_PER_DOC or (counters and counters[cleanCounter(name)]) then
		bump(doc, name)
	end
end

local function handleItem(player: Player, st: State, item: any)
	if type(item) ~= "table" then
		return
	end
	local key, detail = item[1], item[2]
	if type(key) ~= "string" or #key > 32 or (detail ~= nil and (type(detail) ~= "string" or #detail > 160)) then
		return
	end
	if key == "ctx" then
		Analytics.SetSub(player, detail)
	elseif key == "dev" then
		if type(detail) == "string" and DEVICES[detail] and not st.Device then
			st.Device = detail
			record(player, st, "dev." .. detail, nil)
		end
	elseif key == "err" then
		local used = clientErrors[player] or 0
		if type(detail) == "string" and used < 6 then
			clientErrors[player] = used + 1
			countError("client", detail)
			record(player, st, "err.client", nil)
		end
	elseif clientExact[key] then
		local fields = nil
		if string.sub(key, 1, 5) == "perf." and detail ~= nil then
			local fps = tonumber(detail)
			if fps then
				fields = { Fps = math.floor(fps), Device = st.Device or "Unknown" }
				callRoblox("LogCustomEvent", player, "Perf", math.floor(fps), { Bucket = string.sub(key, 6), Device = st.Device or "Unknown" })
			end
		end
		record(player, st, key, fields)
	elseif clientFamily[key] and type(detail) == "string" then
		local clean = string.gsub(detail, "[^%w_:%-]", "_")
		if key == "buy.prompt" and not (Config.GetPass(clean) or Config.GetProduct and Config.GetProduct(clean)) then
			clean = "Other"
		end
		record(player, st, key .. "." .. clean, nil)
	end
end

function Analytics.Handle(player: Player, batch: any)
	local st = states[player]
	if type(batch) ~= "table" then
		return
	end
	local now = os.clock()
	local window = if st then st.Window else nil
	if window then
		if now - window.Start > 10 then
			window.Start, window.Count = now, 0
		end
		if window.Count >= TELEMETRY_PER_WINDOW then
			return
		end
	end
	for i = 1, math.min(#batch, MAX_TELEMETRY_BATCH) do
		if window then
			window.Count += 1
		end
		if st then
			pcall(handleItem, player, st, batch[i])
		else
			-- (the profile is still loading) only the plain moments are kept, and replayed when it arrives
			local item = batch[i]
			if type(item) == "table" and type(item[1]) == "string" and clientExact[item[1]] then
				Analytics.Event(player, item[1])
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- The Admin Abuse show: who is still here N minutes in
----------------------------------------------------------------------------------------------------

local function watchShow()
	local live_ = ReplicatedStorage:GetAttribute("AbuseLive") == true
	if live_ and not showStart then
		showStart = nowFn()
		showShown = {}
		for player, st in states do
			pcall(record, player, st, "show.join", nil)
		end
	elseif not live_ and showStart then
		for player, st in states do
			pcall(record, player, st, "show.end", nil)
		end
		showStart = nil
		showShown = {}
	end
	if showStart then
		local elapsed = (nowFn() - showStart) // 60
		for _, minutes in A.ShowMinutes do
			if elapsed >= minutes and not showShown[minutes] then
				showShown[minutes] = true
				for player, st in states do
					pcall(record, player, st, "show.m." .. minutes, nil)
				end
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Saving the tally
----------------------------------------------------------------------------------------------------

local function merge(old: any, delta: { [string]: number }): { [string]: number }
	local data: { [string]: number } = if type(old) == "table" then old else {}
	local total, errors = 0, 0
	for name in data do
		total += 1
		if string.sub(name, 1, 4) == "err:" then
			errors += 1
		end
	end
	for name, amount in delta do
		if data[name] ~= nil then
			data[name] += amount
		elseif total < MAX_COUNTERS_PER_DOC and (string.sub(name, 1, 4) ~= "err:" or errors < MAX_ERROR_KEYS_PER_DOC) then
			data[name] = amount
			total += 1
			if string.sub(name, 1, 4) == "err:" then
				errors += 1
			end
		end
	end
	return data
end

-- Writes what has been counted since the last time. Returns how many documents were written.
function Analytics.Flush(everything: boolean?): number
	if flushing then
		return 0
	end
	local target = getStore()
	if not live or not target then
		return 0
	end
	flushing = true
	local written = 0
	local snapshot = pending
	pending = {}
	local docs = {}
	for doc in snapshot do
		table.insert(docs, doc)
	end
	table.sort(docs)
	for index, doc in docs do
		local delta = snapshot[doc]
		if (not everything and index > DOCS_PER_FLUSH) then
			-- (the rest wait for the next round)
			local counters = pending[doc]
			if not counters then
				pending[doc] = delta
			else
				for name, amount in delta do
					counters[name] = (counters[name] or 0) + amount
				end
			end
			continue
		end
		local ok, err = pcall(function()
			target:UpdateAsync(doc, function(old)
				return merge(old, delta)
			end)
		end)
		if ok then
			written += 1
		else
			warn(string.format("[Analytics] could not save %s: %s", doc, tostring(err)))
			local counters = pending[doc]
			if not counters then
				pending[doc] = delta
			else
				for name, amount in delta do
					counters[name] = (counters[name] or 0) + amount
				end
			end
		end
		if everything ~= true then
			task.wait(0.5)
		end
	end
	flushing = false
	return written
end

----------------------------------------------------------------------------------------------------
-- Reports (the :analytics command)
----------------------------------------------------------------------------------------------------

type Row = { Line1: string, Line2: string }

Analytics.ReportNames = {
	"Overview",
	"Onboarding funnel",
	"Retention",
	"Where players leave",
	"Runs",
	"Features used",
	"Economy",
	"Devices and errors",
	"Admin Abuse show",
}

local docCache: { [string]: { At: number, Data: { [string]: number } } } = {}

local function readDoc(key: string): { [string]: number }
	local out: { [string]: number } = {}
	local cached = docCache[key]
	if cached and os.clock() - cached.At < CACHE_SECONDS then
		for name, amount in cached.Data do
			out[name] = amount
		end
	else
		local target = getStore()
		if target then
			local ok, data = pcall(function()
				return target:GetAsync(key)
			end)
			if ok and type(data) == "table" then
				for name, amount in data do
					if type(name) == "string" and type(amount) == "number" then
						out[name] = amount
					end
				end
			end
		end
		docCache[key] = { At = os.clock(), Data = table.clone(out) }
	end
	local waiting = pending[key]
	if waiting then
		for name, amount in waiting do
			out[name] = (out[name] or 0) + amount
		end
	end
	return out
end

local function commas(n: number): string
	return Format.Commas(math.floor(n + 0.5))
end

local function pct(part: number, whole: number): string
	if whole <= 0 then
		return "-"
	end
	return string.format("%d%%", math.floor(part / whole * 100 + 0.5))
end

local function dayLabel(dayNumber: number): string
	return os.date("!%b %d", dayNumber * DAY)
end

local function dailyDocs(days: number): ({ { [string]: number } }, { number })
	local docs, numbers = {}, {}
	local t = today()
	for i = 0, days - 1 do
		table.insert(docs, readDoc(dailyDoc(t - i)))
		table.insert(numbers, t - i)
	end
	return docs, numbers
end

local function cohortDocs(days: number): ({ { [string]: number } }, { number })
	local docs, numbers = {}, {}
	local t = today()
	for i = 0, days - 1 do
		table.insert(docs, readDoc(cohortDoc(t - i)))
		table.insert(numbers, t - i)
	end
	return docs, numbers
end

local function total(docs: { { [string]: number } }, counter: string): number
	local sum = 0
	for _, doc in docs do
		sum += doc[counter] or 0
	end
	return sum
end

-- Every counter with this prefix, added up over the documents, biggest first.
local function totalsWithPrefix(docs: { { [string]: number } }, prefix: string): { { Name: string, Value: number } }
	local sums: { [string]: number } = {}
	for _, doc in docs do
		for name, amount in doc do
			if string.sub(name, 1, #prefix) == prefix then
				sums[name] = (sums[name] or 0) + amount
			end
		end
	end
	local list = {}
	for name, value in sums do
		table.insert(list, { Name = string.sub(name, #prefix + 1), Value = value })
	end
	table.sort(list, function(a, b)
		if a.Value ~= b.Value then
			return a.Value > b.Value
		end
		return a.Name < b.Name
	end)
	return list
end

local function funnelRows(funnel: any, getCount: (string) -> number, header: string): { Row }
	local rows: { Row } = {}
	table.insert(rows, { Line1 = header, Line2 = "Each step: players who reached it, % of the first step, and the change from the step before." })
	local first = getCount(funnel.Steps[1][1])
	local worstIndex, worstRatio = 0, 2
	local previous = first
	local counts = {}
	for index, step in funnel.Steps do
		local n = getCount(step[1])
		counts[index] = n
		if index > 1 and previous >= 5 then
			local ratio = n / previous
			if ratio < worstRatio then
				worstRatio, worstIndex = ratio, index
			end
		end
		previous = n
	end
	previous = first
	for index, step in funnel.Steps do
		local n = counts[index]
		local change = ""
		if index > 1 and previous > 0 then
			change = string.format("  -  %s of the step before", pct(n, previous))
		end
		table.insert(rows, {
			Line1 = string.format("%d. %s  -  %s (%s)%s", index, step[2], commas(n), pct(n, first), if index == worstIndex then "   <== BIGGEST DROP" else ""),
			Line2 = string.format("%s  -  key %s%s", labelFor(step[1]), step[1], change),
		})
		previous = n
	end
	return rows
end

local function reportOverview(days: number): (string, { Row })
	local docs, numbers = dailyDocs(days)
	local rows: { Row } = {}
	local players, newPlayers, visits, seconds, done, starts, clears, errors = 0, 0, 0, 0, 0, 0, 0, 0
	for _, doc in docs do
		players += doc["u:join"] or 0
		newPlayers += doc["n:visit.new"] or 0
		visits += doc["n:visit"] or 0
		seconds += doc["playsec"] or 0
		done += doc["visits_done"] or 0
		starts += doc["n:run.arrive"] or 0
		clears += doc["n:run.clear"] or 0
		errors += (doc["n:err.server"] or 0) + (doc["n:err.client"] or 0)
	end
	table.insert(rows, {
		Line1 = string.format("Last %d day%s  -  %s player-days, %s new players", days, if days == 1 then "" else "s", commas(players), commas(newPlayers)),
		Line2 = string.format("%s visits  -  average visit %s  -  %s runs started, %s cleared  -  %s errors", commas(visits), if done > 0 then Format.Time(seconds / done) else "-", commas(starts), commas(clears), commas(errors)),
	})
	for index, doc in docs do
		local n = doc["visits_done"] or 0
		table.insert(rows, {
			Line1 = string.format("%s  -  %s players  -  %s new", dayLabel(numbers[index]), commas(doc["u:join"] or 0), commas(doc["n:visit.new"] or 0)),
			Line2 = string.format("%s visits  -  average visit %s  -  %s runs started, %s cleared  -  %s errors", commas(doc["n:visit"] or 0), if n > 0 then Format.Time((doc["playsec"] or 0) / n) else "-", commas(doc["n:run.arrive"] or 0), commas(doc["n:run.clear"] or 0), commas((doc["n:err.server"] or 0) + (doc["n:err.client"] or 0))),
		})
	end
	if not live then
		table.insert(rows, { Line1 = "Studio / unpublished: only this server's own counts are shown.", Line2 = "Publish the game for the real numbers (they are saved in the DataStore " .. A.StoreName .. ")." })
	end
	return "Analytics - overview", rows
end

local function reportOnboarding(days: number): (string, { Row })
	local docs = cohortDocs(days)
	local funnel = A.Funnels[1]
	local rows = funnelRows(funnel, function(key)
		return total(docs, "f:" .. key)
	end, string.format("New players who signed up in the last %d day%s", days, if days == 1 then "" else "s"))
	return "Analytics - what new players do", rows
end

local function reportRetention(days: number): (string, { Row })
	local docs, numbers = cohortDocs(days)
	local t = today()
	local rows: { Row } = {}
	local marks = { 1, 2, 3, 7, 14, 30 }
	local sums, bases = {}, {}
	for _, n in marks do
		sums[n], bases[n] = 0, 0
	end
	for index, doc in docs do
		local joined = doc["f:join"] or 0
		if joined > 0 then
			for _, n in marks do
				if t - numbers[index] >= n then
					sums[n] += doc["ret." .. n] or 0
					bases[n] += joined
				end
			end
		end
	end
	local summary = {}
	for _, n in marks do
		table.insert(summary, string.format("D%d %s", n, pct(sums[n], bases[n])))
	end
	table.insert(rows, { Line1 = "All sign-up days together", Line2 = table.concat(summary, "   ") .. "   (D1 = came back the next day)" })
	for index, doc in docs do
		local joined = doc["f:join"] or 0
		if joined > 0 then
			local parts = {}
			for _, n in marks do
				table.insert(parts, string.format("D%d %s", n, if t - numbers[index] >= n then pct(doc["ret." .. n] or 0, joined) else "-"))
			end
			table.insert(rows, {
				Line1 = string.format("%s  -  %s new players", dayLabel(numbers[index]), commas(joined)),
				Line2 = table.concat(parts, "   "),
			})
		end
	end
	return "Analytics - retention", rows
end

local function leaveRows(list: { { Name: string, Value: number } }, limit: number): { Row }
	local rows: { Row } = {}
	local sum = 0
	for _, item in list do
		sum += item.Value
	end
	for index, item in list do
		if index > limit then
			break
		end
		table.insert(rows, { Line1 = string.format("%s  -  %s (%s)", item.Name, commas(item.Value), pct(item.Value, sum)), Line2 = "" })
	end
	return rows
end

local function reportLeaving(days: number): (string, { Row })
	local cohorts = cohortDocs(days)
	local daily = dailyDocs(days)
	local rows: { Row } = {}
	table.insert(rows, { Line1 = "== NEW PLAYERS: where they were when they left their first visit ==", Line2 = "Run Lx = inside a dishwasher (with how far along), Pad = in a party pad, Lobby = walking about, Tut = tutorial step" })
	for _, row in leaveRows(totalsWithPrefix(cohorts, "l1:"), 14) do
		table.insert(rows, row)
	end
	table.insert(rows, { Line1 = "== NEW PLAYERS: how long their first visit lasted ==", Line2 = "" })
	for _, row in leaveRows(totalsWithPrefix(cohorts, "l1len:"), 6) do
		table.insert(rows, row)
	end
	table.insert(rows, { Line1 = "== EVERYONE: where they were when they left ==", Line2 = "" })
	for _, row in leaveRows(totalsWithPrefix(daily, "left:"), 14) do
		table.insert(rows, row)
	end
	table.insert(rows, { Line1 = "== EVERYONE: how long visits lasted ==", Line2 = "" })
	for _, row in leaveRows(totalsWithPrefix(daily, "len:"), 6) do
		table.insert(rows, row)
	end
	return "Analytics - where players leave", rows
end

local function reportRuns(days: number): (string, { Row })
	local docs = dailyDocs(days)
	local funnel = A.Funnels[2]
	local rows = funnelRows(funnel, function(key)
		return total(docs, "u:" .. key)
	end, string.format("Runs, last %d day%s (players per day, added up)", days, if days == 1 then "" else "s"))
	local extra = {
		{ "run.fail", "Runs that could not start" },
		{ "run.leave", "Left with the Leave button" },
		{ "run.drop", "Closed the game mid-run" },
		{ "run.dish1", "Finished a first dish" },
	}
	for _, item in extra do
		table.insert(rows, { Line1 = string.format("%s  -  %s", item[2], commas(total(docs, "n:" .. item[1]))), Line2 = "key " .. item[1] })
	end
	for level = 1, #Config.Levels do
		table.insert(rows, {
			Line1 = string.format("Dishwasher %d  -  %s started, %s cleared", level, commas(total(docs, "n:run.arrive." .. level)), commas(total(docs, "n:run.clear." .. level))),
			Line2 = "",
		})
	end
	return "Analytics - runs", rows
end

local function reportFeatures(days: number): (string, { Row })
	local docs = dailyDocs(days)
	local uniques = totalsWithPrefix(docs, "u:")
	local rows: { Row } = {}
	table.insert(rows, { Line1 = string.format("Everything players did, last %d day%s", days, if days == 1 then "" else "s"), Line2 = "Players (added up per day) and total uses; biggest first. Check the Filter box to search." })
	for index, item in uniques do
		if index > 90 then
			break
		end
		table.insert(rows, {
			Line1 = string.format("%s  -  %s players", labelFor(item.Name), commas(item.Value)),
			Line2 = string.format("%s uses  -  key %s", commas(total(docs, "n:" .. item.Name)), item.Name),
		})
	end
	return "Analytics - features used", rows
end

local function reportEconomy(days: number): (string, { Row })
	local docs = dailyDocs(days)
	local rows: { Row } = {}
	local currencies = { "Bubbles", "Gems", "Coins" }
	for _, currency in currencies do
		for _, kind in { "src", "snk" } do
			local list = totalsWithPrefix(docs, string.format("eco:%s:%s:", kind, currency))
			if #list > 0 then
				local sum = 0
				for _, item in list do
					sum += item.Value
				end
				table.insert(rows, {
					Line1 = string.format("== %s %s: %s ==", currency, if kind == "src" then "EARNED" else "SPENT", commas(sum)),
					Line2 = "Where it came from / went (add up how many times in brackets)",
				})
				for index, item in list do
					if index > 12 then
						break
					end
					table.insert(rows, {
						Line1 = string.format("%s  -  %s (%s)", item.Name, commas(item.Value), pct(item.Value, sum)),
						Line2 = string.format("%s times", commas(total(docs, string.format("ecn:%s:%s:%s", kind, currency, item.Name)))),
					})
				end
			end
		end
	end
	local robux = totalsWithPrefix(docs, "robux:buy.ok.")
	if #robux > 0 then
		local sum = 0
		for _, item in robux do
			sum += item.Value
		end
		table.insert(rows, { Line1 = string.format("== ROBUX SPENT BY PLAYERS: %s ==", commas(sum)), Line2 = "List prices, before Roblox's cut" })
		for index, item in robux do
			if index > 14 then
				break
			end
			table.insert(rows, { Line1 = string.format("%s  -  R$ %s (%s)", item.Name, commas(item.Value), pct(item.Value, sum)), Line2 = string.format("%s purchases", commas(total(docs, "n:buy.ok." .. item.Name))) })
		end
	end
	if #rows == 0 then
		table.insert(rows, { Line1 = "No money has moved yet.", Line2 = "" })
	end
	return "Analytics - economy", rows
end

local function reportHealth(days: number): (string, { Row })
	local docs = dailyDocs(days)
	local rows: { Row } = {}
	local joins = total(docs, "u:join")
	table.insert(rows, { Line1 = "== DEVICES (players per day, added up) ==", Line2 = "" })
	for _, device in { "Phone", "Tablet", "Desktop", "Console" } do
		local n = total(docs, "u:dev." .. device)
		table.insert(rows, { Line1 = string.format("%s  -  %s (%s)", device, commas(n), pct(n, joins)), Line2 = "" })
	end
	table.insert(rows, { Line1 = "== FRAME RATE ==", Line2 = "Measured about a minute after the screen loads" })
	for _, bucketName in { "low", "mid", "high" } do
		local n = total(docs, "u:perf." .. bucketName)
		table.insert(rows, { Line1 = string.format("%s  -  %s", labelOf["perf." .. bucketName], commas(n)), Line2 = "" })
	end
	table.insert(rows, { Line1 = "== LOST IN THE LOBBY ==", Line2 = "Players who joined for a new visit and walked into no pad" })
	table.insert(rows, { Line1 = string.format("After 1 minute  -  %s", commas(total(docs, "n:lobby.lost1"))), Line2 = "" })
	table.insert(rows, { Line1 = string.format("After 3 minutes  -  %s", commas(total(docs, "n:lobby.lost3"))), Line2 = "" })
	table.insert(rows, { Line1 = "== SCRIPT ERRORS ==", Line2 = string.format("%s on servers, %s on screens", commas(total(docs, "n:err.server")), commas(total(docs, "n:err.client"))) })
	for index, item in totalsWithPrefix(docs, "err:") do
		if index > 20 then
			break
		end
		table.insert(rows, { Line1 = string.format("%s  -  %s", item.Name, commas(item.Value)), Line2 = "" })
	end
	table.insert(rows, { Line1 = string.format("Events held back for Roblox's rate limit: %s", commas(total(docs, "rbx:dropped"))), Line2 = "" })
	return "Analytics - devices and errors", rows
end

local function reportShow(days: number): (string, { Row })
	local docs = dailyDocs(days)
	local rows: { Row } = {}
	local joined = total(docs, "u:show.join")
	table.insert(rows, { Line1 = string.format("Players who joined while Admin Abuse was live  -  %s", commas(joined)), Line2 = "The first row of the show funnel" })
	local funnel = A.Funnels[#A.Funnels]
	for _, row in funnelRows(funnel, function(key)
		return total(docs, "u:" .. key)
	end, "The show, step by step") do
		table.insert(rows, row)
	end
	for _, key in { "show.vote", "show.prize", "show.obby", "event.sign", "event.rsvp" } do
		table.insert(rows, { Line1 = string.format("%s  -  %s", labelOf[key] or key, commas(total(docs, "u:" .. key))), Line2 = "key " .. key })
	end
	return "Analytics - Admin Abuse show", rows
end

local REPORTS = { reportOverview, reportOnboarding, reportRetention, reportLeaving, reportRuns, reportFeatures, reportEconomy, reportHealth, reportShow }

-- Builds report number `index` over the last `days` days. Returns (title, rows, index, count).
function Analytics.BuildReport(index: number?, days: number?): (string, { Row }, number, number)
	local count = #REPORTS
	local i = ((math.floor(tonumber(index) or 1) - 1) % count) + 1
	local d = math.clamp(math.floor(tonumber(days) or A.ReportDays), 1, 30)
	local ok, title, rows = pcall(REPORTS[i], d)
	if not ok then
		return "Analytics - error", { { Line1 = "The report failed: " .. tostring(title), Line2 = "" } }, i, count
	end
	return string.format("%s  (last %d day%s)", title, d, if d == 1 then "" else "s"), rows, i, count
end

----------------------------------------------------------------------------------------------------
-- Start-up
----------------------------------------------------------------------------------------------------

local initialized = false

function Analytics.Init()
	if initialized then
		return
	end
	initialized = true

	DataService.Track = Analytics.Event
	DataService.SetContext = Analytics.SetContext
	DataService.AttemptId = Analytics.AttemptId

	local signal = (DataService :: any).ProfileLoaded
	signal:Connect(function(player: Player, profile: any)
		local ok, err = pcall(onProfileLoaded, player, profile)
		if not ok then
			warn("[Analytics] join: " .. tostring(err))
		end
	end)
	for _, player in Players:GetPlayers() do
		local profile = DataService.Get(player)
		if profile then
			task.spawn(onProfileLoaded, player, profile)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		clientErrors[player] = nil
		onRemoving(player)
	end)
	local economySignal = (DataService :: any).EconomyChanged
	economySignal:Connect(onEconomy)

	local ok, remote = pcall(function()
		return require(Shared:WaitForChild("Remotes")).Event("Telemetry")
	end)
	if ok and remote then
		(remote :: RemoteEvent).OnServerEvent:Connect(function(player, batch)
			Analytics.Handle(player, batch)
		end)
	end

	-- Script errors on this server.
	pcall(function()
		local scriptContext = game:GetService("ScriptContext")
		scriptContext.Error:Connect(function(message: string, _trace: string, _script: Instance?)
			if A.Enabled and type(message) == "string" then
				countError("server", message)
			end
		end)
	end)

	game:BindToClose(function()
		for player, st in states do
			pcall(flushEconomy, player, st)
		end
		if robloxDropped > 0 then
			bump(dailyDoc(), "rbx:dropped", robloxDropped)
			robloxDropped = 0
		end
		-- (a flush already under way finishes first, then everything left is written at once)
		local waited = 0
		while flushing and waited < 10 do
			task.wait(0.25)
			waited += 0.25
		end
		Analytics.Flush(true)
	end)
end

function Analytics.Start()
	task.spawn(function()
		while true do
			task.wait(A.FlushSeconds)
			if robloxDropped > 0 then
				bump(dailyDoc(), "rbx:dropped", robloxDropped)
				robloxDropped = 0
			end
			for player, st in states do
				st.An.Last = nowFn() -- (still here: a long visit isn't split in two)
				if os.clock() - st.EcoAt > ECONOMY_FLUSH then
					pcall(flushEconomy, player, st)
				end
			end
			Analytics.Flush(false)
		end
	end)
	task.spawn(function()
		while true do
			task.wait(5)
			pcall(watchShow)
		end
	end)
end

-- For tests: the counters not yet written, and ways to run a join, a leave, one show tick and one
-- money flush by hand.
function Analytics._Pending(): { [string]: { [string]: number } }
	return pending
end

function Analytics._Join(player: Player, profile: any)
	onProfileLoaded(player, profile)
end

function Analytics._Leave(player: Player)
	onRemoving(player)
end

function Analytics._FlushEconomy(player: Player)
	local st = states[player]
	if st then
		flushEconomy(player, st)
	end
end

function Analytics._State(player: Player): State?
	return states[player]
end

function Analytics._Tick()
	watchShow()
end

return Analytics
