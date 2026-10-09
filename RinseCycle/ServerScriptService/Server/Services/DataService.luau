-- DataService: every player's permanent profile (Bubbles, perks, pets, unlocks, best times, stats).
--
-- Life of a profile:
--   join     -> a Session is created and loaded in the background. The load is one UpdateAsync that
--               takes a session lock ({ JobId, Time }) so two servers never own the same save. If
--               another server holds a fresh lock (a server hop in progress), we wait and retry, and
--               steal the lock after LOCK_RETRIES attempts (that server has probably crashed).
--   playing  -> services read and change the profile table directly (Get), or through the helpers
--               below. PushMeta sends the client a MetaState snapshot (coalesced to one per 0.1 s).
--   autosave -> every AUTOSAVE_INTERVAL seconds (plus a random offset per player), the profile is
--               written and the lock refreshed. A save only lands while we still own the lock.
--   leave    -> a final save that also clears the lock, so the next server can load straight away.
--
-- Data is NEVER wiped. If a save exists but can't be read (DataStore errors after every retry, or a
-- damaged record), the player plays on a temporary default profile that is never saved, and is told
-- so. Only profiles that loaded successfully (and whose lock we still hold) are ever written.
--
-- Offline mode (unpublished place, or Studio without API access): profiles live in memory only,
-- everything else works the same, and each player is told once that progress won't save.
--
-- Passes are runtime-only (MarketService fills them in) and never saved.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Format = require(Shared:WaitForChild("Format"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

local DataService = {}

----------------------------------------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------------------------------------

local STORE_NAME = "RinseCycle_Profiles_v1"
local KEY_PREFIX = "u_"
local PROFILE_VERSION = 1

local LOCK_TTL = 1800 -- seconds; an older lock belongs to a server that died without releasing it
local LOCK_RETRIES = 6 -- locked loads to wait through before stealing the lock
local LOCK_WAIT_MIN, LOCK_WAIT_MAX = 3, 5 -- seconds between locked load attempts
local HANDOFF_TTL = 120 -- seconds a handoff lock may be taken over straight away (see BeginHandoff)
local LOAD_ATTEMPTS = 6 -- DataStore errors tolerated while loading before falling back to a temp profile
local FINAL_SAVE_ATTEMPTS = 3
local RECEIPT_SAVE_ATTEMPTS = 2

local AUTOSAVE_INTERVAL = 120
local AUTOSAVE_JITTER = 30 -- random extra seconds before a player's first autosave, so saves spread out
local AUTOSAVE_TICK = 5 -- how often the autosave loop looks for due saves
local AUTOSAVE_RETRY = 30 -- a failed autosave tries again this soon
local SAVE_SOON_DELAY = 10 -- a level unlock is written within this many seconds
local SHUTDOWN_WAIT = 25

local PUSH_COALESCE = 0.1
local MAX_RECEIPTS = 50
local PROBE_WAIT = 5 -- max seconds IsOffline() waits for the Studio probe
local SAME_USER_WAIT = 30 -- max seconds a rejoin waits for this server to finish the previous session
local NOTICE_FALLBACK = 8 -- toasts go out this long after loading even if the client never asked for meta
local NOTICE_AFTER_READY = 1.5 -- ...or this long after the client's first GetMeta (its UI is up by then)
local META_REQUESTS_PER_SECOND = 3 -- GetMeta budget per player (burst of the same size)

local MSG_OFFLINE = "Progress won't save in this test (turn on Studio API access)."
local MSG_LOAD_FAILED = "We couldn't load your save - progress this session won't be saved. Rejoin to try again."
local MSG_LOCK_LOST = "Your save was opened on another server - progress here won't be saved. Rejoin to fix it."

----------------------------------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------------------------------

export type Profile = {
	Version: number,
	Bubbles: number,
	Gems: number, -- premium currency
	Rank: string, -- equipped rank id ("" = none)
	Ranks: { string }, -- owned rank ids
	Perks: { [string]: number }, -- Config.Perks[i].Id -> level
	Pets: { Types.PetEntry },
	Equipped: { string }, -- Uids, slot order
	NextUid: number,
	Unlocked: number, -- highest level index the player may pick
	BestTimes: { number }, -- one per Config.Levels entry, seconds, 0 = never cleared
	Rebirths: number, -- times the player has rebirthed (Config.Rebirth)
	DailyDay: number, -- (old saves) UTC day number of the last daily reward claimed
	DailyLast: number, -- os.time() of the last daily claim (0 = never); the next is 24 h later
	DailyStreak: number, -- 1..#Config.DailyRewards, the day of the streak last claimed
	RedeemedCodes: { string }, -- Config.Codes already used (upper case)
	Ducks: { string }, -- lobby rubber ducks found (Config.Ducks ids)
	Episodes: { number }, -- per level index: run-start cutscene chapters seen (picks the next one)
	GroupReward: boolean, -- the join-the-community reward has been claimed
	FollowReward: boolean, -- the follow-the-dev reward has been claimed
	LikeReward: boolean, -- the like-the-game reward has been claimed
	FollowPending: boolean, -- pressed "I followed!": checked on the next join (SocialService)
	LikePending: boolean, -- pressed "I liked it!": paid on the next join
	RebirthReady: boolean, -- the last level has been cleared since the last rebirth
	BoostUntil: number, -- os.time() until which cleaning is x2 (the "stay" boost); 0 = none
	StayBoostDay: string, -- UTC date ("2026-10-03") the stay boost was last claimed: once a day
	PremiumDay: string, -- UTC date the Roblox Premium daily gift was last paid (once a day)
	TutorialDone: boolean, -- the first-run tutorial has been finished or skipped (anyone with a run behind them counts as done)
	PetIndex: { [string]: number }, -- every pet id ever owned -> bits (1 normal, 2 Golden, 4 Rainbow)
	PetIndexPaid: { [string]: boolean }, -- collection sets already paid ("1".."3")
	PetsResting: boolean, -- the player switched their pets off: they follow but don't clean
	ReferredBy: number, -- UserId of the friend whose invite brought them in (0 = nobody)
	AdLuckStacks: number, -- rewarded ads watched for rank luck (each +PerAd), while AdLuckUntil lasts
	AdLuckUntil: number, -- os.time() the ad luck runs out
	ChestEventId: string, -- the Treasure Chest event ChestFreeUsed counts for (a new event resets it)
	ChestFreeUsed: number, -- free chests opened in that event
	ChestsOpened: number, -- every chest ever opened (free and bought)
	ClubId: string, -- the club they're in ("" = none); ClubService keeps the club's own record
	ClubTag: string, -- that club's tag, for the name tag (refreshed from the club on join)
	ClubMovedAt: number, -- os.time() they last LEFT a club (they can join / make another after Config.Clubs.LeaveCooldown)
	ClubBans: { [string]: number }, -- club id -> os.time() they were KICKED from it (they can rejoin it after Config.Clubs.KickBan)
	ClubNotice: string, -- a message waiting for them ("You were kicked from ..."); the client shows it once, then it's cleared
	ClubPrizeSeason: string, -- the club contest month (YYYYMM) whose prize they've been paid
	BadgesGot: { [string]: boolean }, -- Config.Badges keys already awarded (BadgeAwards)
	DailyNotifyAt: number, -- os.time() the "daily reward ready" notification is queued for (0 = none)
	Referrals: number, -- new players who joined through this player's invites (paid out)
	Stats: {
		Runs: number,
		DishesCleaned: number,
		GrimeCleaned: number,
		EggsHatched: number,
		BubblesEarned: number,
	},
	Receipts: { string }, -- recent developer-product PurchaseIds, newest last
	An: { -- Analytics.luau's bookkeeping (nothing here changes how the game plays)
		First: number, -- the day number (os.time() // 86400) they first played; 0 = not seen yet, -1 = played before analytics existed
		Last: number, -- os.time() they were last seen
		Visits: number, -- visits so far (a visit = joins less than Config.Analytics.VisitGap apart)
		VisitStart: number, -- os.time() the current visit began
		Mask: number, -- bit N set = they played N days after First (N = 1..30), for retention
		Runs: number, -- dishwashers they have arrived in
		DayNum: number, -- the day Day belongs to
		Day: { [string]: boolean }, -- moments already counted today (unique-per-day counts)
		Seen: { [string]: number }, -- moments ever reached -> the day first reached
	},
}

-- A Bubbles or stat change that arrived before the profile finished loading (replayed on load).
type PendingChange = { Stat: string?, Amount: number } -- Stat nil = Bubbles

-- A one-shot gate: threads that wait on it sleep until it opens (or their timeout passes).
type Latch = { Open: boolean, Threads: { thread } }

type Session = {
	Player: Player,
	UserId: number,
	Key: string,
	Profile: Profile?, -- nil while loading
	CanSave: boolean, -- true only for a profile loaded from the DataStore whose lock we still hold
	Left: boolean, -- PlayerRemoving has fired
	Finalizing: boolean, -- the final (lock-releasing) save has started; nothing is saved after it
	Released: boolean, -- the lock has been cleared
	Handoff: boolean, -- a teleport to another server is under way: that server may take the lock at once
	Busy: boolean, -- a save is in flight (saves for one session never overlap)
	SaveQueue: { thread },
	Loaded: Latch, -- opens when Profile is set, or the player leaves
	Done: Latch, -- opens when this session is completely finished (final save landed or given up)
	Previous: Session?, -- this user's previous session on this server, if it was still finishing
	NextAutosave: number, -- os.clock()
	Pending: { PendingChange }, -- Bubbles/stat changes that arrived while the profile was still loading
	Notices: { { string } }, -- { text, kind } toasts waiting for the client's UI
	ClientReady: boolean, -- the client has asked for its MetaState at least once
}

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

local TEMPLATE: Profile = {
	Version = PROFILE_VERSION,
	Bubbles = 0,
	Gems = 0,
	Rank = "",
	Ranks = {},
	Perks = {},
	Pets = {},
	Equipped = {},
	NextUid = 1,
	Unlocked = 1,
	BestTimes = {},
	Rebirths = 0,
	RebirthReady = false,
	DailyDay = 0,
	DailyLast = 0,
	DailyStreak = 0,
	RedeemedCodes = {},
	Ducks = {},
	Episodes = {},
	GroupReward = false,
	FollowReward = false,
	LikeReward = false,
	FollowPending = false,
	LikePending = false,
	BoostUntil = 0,
	StayBoostDay = "",
	PremiumDay = "",
	TutorialDone = false,
	PetIndex = {},
	PetIndexPaid = {},
	PetsResting = false,
	ReferredBy = 0,
	AdLuckStacks = 0,
	AdLuckUntil = 0,
	ChestEventId = "",
	ChestFreeUsed = 0,
	ChestsOpened = 0,
	ClubId = "",
	ClubTag = "",
	ClubMovedAt = 0,
	ClubBans = {},
	ClubNotice = "",
	ClubPrizeSeason = "",
	BadgesGot = {},
	DailyNotifyAt = 0,
	Referrals = 0,
	Stats = { Runs = 0, DishesCleaned = 0, GrimeCleaned = 0, EggsHatched = 0, BubblesEarned = 0 },
	Receipts = {},
	An = { First = 0, Last = 0, Visits = 0, VisitStart = 0, Mask = 0, Runs = 0, DayNum = 0, Day = {}, Seen = {} },
}
for _, perk in Config.Perks do
	TEMPLATE.Perks[perk.Id] = 0
end
for i = 1, #Config.Levels do
	TEMPLATE.BestTimes[i] = 0
end

local sessions: { [Player]: Session } = {}
local lastSessionOf: { [number]: Session } = {} -- userId -> newest session on this server (until Done)
local passesOf: { [Player]: { [string]: boolean } } = {}
local pushQueued: { [Player]: boolean } = {}
local metaBudget: { [Player]: { Tokens: number, At: number } } = {}

local detection: Latch = { Open = false, Threads = {} } -- opens once we know whether we're offline
local offline = false
local shuttingDown = false
local activeJobs = 0 -- loads and saves in flight (BindToClose waits for these)
local initialized = false
local started = false

local store: DataStore? = nil
local rng = Random.new()

local metaRemote: RemoteEvent
local notifyRemote: RemoteEvent

DataService.ProfileLoaded = Util.Signal.new() -- (player, profile), for loaded, temporary and offline profiles
DataService.PassesChanged = Util.Signal.new() -- (player), after a pass (or pass-limited Equipped) changes
-- (player, currency "Bubbles" | "Gems", amount (+ earned / - spent), balance after, reason), for Analytics.
DataService.EconomyChanged = Util.Signal.new()

-- Analytics hooks. Analytics.luau replaces these when it starts; until then (or if that script is
-- missing) they do nothing, so any service can call them without caring.
--   Track(player, "run.arrive", { Level = 1 }) records a moment (keys: Config.Analytics)
--   SetContext(player, "Run L1") says where the player is now (shown when they leave)
DataService.Track = function(_player: Player, _key: string, _fields: { [string]: any }?) end
DataService.SetContext = function(_player: Player, _context: string) end
DataService.AttemptId = function(_player: Player, _funnel: string): string?
	return nil
end

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

local function isFinite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- A finite, non-negative whole number, or `default`.
local function toCount(value: any, default: number): number
	if not isFinite(value) then
		return default
	end
	return math.max(0, math.floor(value))
end

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" and value:IsA("Player")
end

local function isHere(player: Player): boolean
	return player.Parent == Players
end

local function newLatch(): Latch
	return { Open = false, Threads = {} }
end

local function openLatch(latch: Latch)
	if latch.Open then
		return
	end
	latch.Open = true
	local threads = latch.Threads
	latch.Threads = {}
	for _, thread in threads do
		task.spawn(thread)
	end
end

-- Yields until the latch opens or `timeout` seconds pass. Returns true if it opened.
local function waitLatch(latch: Latch, timeout: number): boolean
	if latch.Open then
		return true
	end
	local thread = coroutine.running()
	table.insert(latch.Threads, thread)
	task.delay(timeout, function()
		-- Still waiting? Then the latch never opened for us: wake up empty-handed.
		local index = table.find(latch.Threads, thread)
		if index then
			table.remove(latch.Threads, index)
			task.spawn(thread)
		end
	end)
	coroutine.yield()
	return latch.Open
end

-- Runs fn(...) as a tracked job so BindToClose knows to wait for it. Never throws.
local function track(fn: (...any) -> ...any, ...: any)
	activeJobs += 1
	local ok, err = pcall(fn, ...)
	activeJobs -= 1
	if not ok then
		warn("[DataService] " .. tostring(err))
	end
end

local function getStore(): DataStore?
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	end
	return store
end

local function newProfile(): Profile
	local profile = Util.DeepCopy(TEMPLATE)
	profile.An.First = os.time() // 86400 -- brand new: Analytics counts them in today's sign-up group
	return profile
end

----------------------------------------------------------------------------------------------------
-- Offline detection
----------------------------------------------------------------------------------------------------

local function setOffline(value: boolean, reason: string?)
	offline = value
	if value then
		print("[DataService] Studio test: progress isn't saved (" .. tostring(reason) .. ")")
	end
	openLatch(detection)
end

-- A live server always has DataStores (an outage there is handled by retries and temp profiles, never
-- by turning saving off for the whole server). Only Studio can lack API access, so only Studio probes.
local function detectOffline()
	if game.PlaceId == 0 then
		setOffline(true, "the place isn't published")
		return
	end
	if not RunService:IsStudio() then
		setOffline(false)
		return
	end
	task.spawn(function()
		local ok, err = pcall(function()
			DataStoreService:GetDataStore(STORE_NAME):GetAsync("__probe")
		end)
		if ok then
			setOffline(false)
			return
		end
		local message = tostring(err)
		if
			string.find(message, "StudioAccessToApisNotAllowed", 1, true)
			or string.find(message, "API", 1, true)
			or string.find(string.lower(message), "publish", 1, true)
		then
			setOffline(true, message)
		else
			-- Some other hiccup: stay online. Loads retry and fall back to temp profiles if it persists.
			warn("[DataService] DataStore probe failed: " .. message)
			setOffline(false)
		end
	end)
end

----------------------------------------------------------------------------------------------------
-- Profile repair (runs after every load, outside the UpdateAsync transform)
----------------------------------------------------------------------------------------------------

-- Passes as far as pet slots are concerned. Until MarketService has checked the +2 Pet Slots pass
-- (it checks every pass one by one after the profile loads), an on-sale slot pass counts as owned,
-- so nobody who owns it is ever cut down to 3 pets while the checks are still running. Once the
-- answer is known, SetPass trims for real.
local function slotPasses(player: Player): { [string]: boolean }
	local passes = table.clone(passesOf[player] or {})
	local pass = Config.GetPass("PetSlots")
	if pass and type(pass.Id) == "number" and pass.Id > 0 and passes.PetSlots == nil then
		passes.PetSlots = true
	end
	return passes
end

local function loadSlotCap(player: Player, profile: Profile): number
	return Config.PetSlots(profile.Perks, slotPasses(player))
end

local function sanitizeProfile(profile: Profile, player: Player)
	local p = profile :: any
	p.Lock = nil
	-- Reconcile only fills missing keys; wrong types from damaged or ancient saves are repaired below.
	Util.Reconcile(p, TEMPLATE :: any)

	p.Version = if isFinite(p.Version) then math.max(p.Version, PROFILE_VERSION) else PROFILE_VERSION
	p.Bubbles = toCount(p.Bubbles, 0)
	p.Gems = toCount(p.Gems, 0)
	p.Rebirths = toCount(p.Rebirths, 0)
	p.BoostUntil = toCount(p.BoostUntil, 0)
	p.StayBoostDay = if type(p.StayBoostDay) == "string" then p.StayBoostDay else ""
	p.PremiumDay = if type(p.PremiumDay) == "string" and #p.PremiumDay <= 12 then p.PremiumDay else ""
	p.PetsResting = p.PetsResting == true
	local index, paid = {}, {}
	for id, bits in (if type(p.PetIndex) == "table" then p.PetIndex else {}) do
		if type(id) == "string" and #id <= 40 and isFinite(bits) then
			index[id] = math.clamp(math.floor(bits), 0, 7)
		end
	end
	for key, got in (if type(p.PetIndexPaid) == "table" then p.PetIndexPaid else {}) do
		if type(key) == "string" and got == true then
			paid[key] = true
		end
	end
	p.PetIndex, p.PetIndexPaid = index, paid
	p.ReferredBy = toCount(p.ReferredBy, 0)
	p.AdLuckStacks = toCount(p.AdLuckStacks, 0)
	p.AdLuckUntil = toCount(p.AdLuckUntil, 0)
	p.ChestEventId = if type(p.ChestEventId) == "string" then p.ChestEventId else ""
	p.ChestFreeUsed = toCount(p.ChestFreeUsed, 0)
	p.ChestsOpened = toCount(p.ChestsOpened, 0)
	p.ClubId = if type(p.ClubId) == "string" and #p.ClubId <= 40 then p.ClubId else ""
	p.ClubTag = if type(p.ClubTag) == "string" and #p.ClubTag <= 20 then p.ClubTag else ""
	p.ClubMovedAt = toCount(p.ClubMovedAt, 0)
	local bans: { [string]: number } = {}
	local banCount = 0
	for id, at in (if type(p.ClubBans) == "table" then p.ClubBans else {}) do
		-- (only the ones still running; a few at most)
		if type(id) == "string" and #id <= 40 and type(at) == "number" and at + Config.Clubs.KickBan > os.time() and banCount < 20 then
			bans[id] = at
			banCount += 1
		end
	end
	p.ClubBans = bans
	p.ClubNotice = if type(p.ClubNotice) == "string" and #p.ClubNotice <= 160 then p.ClubNotice else ""
	p.ClubPrizeSeason = if type(p.ClubPrizeSeason) == "string" and #p.ClubPrizeSeason <= 8 then p.ClubPrizeSeason else ""
	local badges = {}
	for key, got in (if type(p.BadgesGot) == "table" then p.BadgesGot else {}) do
		if type(key) == "string" and #key <= 30 and got == true then
			badges[key] = true
		end
	end
	p.BadgesGot = badges
	p.DailyNotifyAt = toCount(p.DailyNotifyAt, 0)
	p.Referrals = toCount(p.Referrals, 0)
	p.DailyDay = toCount(p.DailyDay, 0)
	p.DailyLast = toCount(p.DailyLast, 0)
	if p.DailyLast == 0 and p.DailyDay > 0 then
		p.DailyLast = p.DailyDay * 86400 -- saves from before the 24-hour timer
	end
	p.DailyStreak = math.clamp(toCount(p.DailyStreak, 0), 0, #Config.DailyRewards)
	local codes = {}
	for _, code in (if type(p.RedeemedCodes) == "table" then p.RedeemedCodes else {}) do
		if type(code) == "string" and #code <= 40 and #codes < 500 then
			table.insert(codes, code)
		end
	end
	p.RedeemedCodes = codes
	local ducks = {}
	for _, id in (if type(p.Ducks) == "table" then p.Ducks else {}) do
		if type(id) == "string" and #id <= 20 and #ducks < 50 and not table.find(ducks, id) then
			table.insert(ducks, id)
		end
	end
	p.Ducks = ducks
	local episodes = {}
	for i = 1, #Config.Levels do
		local n = if type(p.Episodes) == "table" then p.Episodes[i] else nil
		episodes[i] = math.min(toCount(n, 0), 1e6)
	end
	p.Episodes = episodes
	p.GroupReward = p.GroupReward == true
	p.FollowReward = p.FollowReward == true
	p.LikeReward = p.LikeReward == true
	p.FollowPending = p.FollowPending == true and not p.FollowReward
	p.LikePending = p.LikePending == true and not p.LikeReward
	p.RebirthReady = p.RebirthReady == true
	local ranks, seenRank = {}, {}
	for _, id in (if type(p.Ranks) == "table" then p.Ranks else {}) do
		if type(id) == "string" and Config.GetRank(id) and not seenRank[id] then
			seenRank[id] = true
			table.insert(ranks, id)
		end
	end
	p.Ranks = ranks
	if type(p.Rank) ~= "string" or not seenRank[p.Rank] then
		p.Rank = ""
	end

	if type(p.Perks) ~= "table" then
		p.Perks = Util.DeepCopy(TEMPLATE.Perks)
	end
	for _, perk in Config.Perks do
		p.Perks[perk.Id] = math.min(toCount(p.Perks[perk.Id], 0), perk.Max) -- perks were re-capped at 6 levels
	end

	-- Pets: keep every well-formed entry (extra fields included). Uids become strings, and duplicate
	-- or missing uids get fresh ones so every pet stays addressable.
	local rawPets = if type(p.Pets) == "table" then p.Pets else {}
	local pets, seen, needsUid = {}, {}, {}
	local maxUid = 0
	for _, entry in rawPets do
		if type(entry) == "table" and type(entry.Id) == "string" then
			local uid = entry.Uid
			if isFinite(uid) then
				uid = tostring(math.floor(uid))
			end
			if type(uid) ~= "string" or uid == "" or seen[uid] then
				table.insert(needsUid, entry)
			else
				seen[uid] = true
				entry.Uid = uid
				table.insert(pets, entry)
				local n = tonumber(uid)
				if n and isFinite(n) and n > maxUid and n < 1e12 then
					maxUid = math.floor(n)
				end
			end
		end
	end
	local nextUid = math.max(toCount(p.NextUid, 1), maxUid + 1, 1)
	for _, entry in needsUid do
		entry.Uid = tostring(nextUid)
		nextUid += 1
		table.insert(pets, entry)
	end
	p.Pets = pets
	p.NextUid = nextUid

	-- Equipped: only uids that exist (with a pet id the game knows), no repeats, at most the slots.
	local idOf = {}
	for _, pet in pets do
		idOf[pet.Uid] = pet.Id
	end
	local cap = loadSlotCap(player, p)
	local equipped, used = {}, {}
	for _, uid in (if type(p.Equipped) == "table" then p.Equipped else {}) do
		if isFinite(uid) then
			uid = tostring(math.floor(uid))
		end
		if type(uid) == "string" and not used[uid] and idOf[uid] and Config.Pets[idOf[uid]] and #equipped < cap then
			used[uid] = true
			table.insert(equipped, uid)
		end
	end
	p.Equipped = equipped

	-- BestTimes: exactly one entry per level.
	local rawTimes = if type(p.BestTimes) == "table" then p.BestTimes else {}
	local times = {}
	for i = 1, #Config.Levels do
		local t = rawTimes[i]
		times[i] = if isFinite(t) and t > 0 then t else 0
	end
	p.BestTimes = times

	-- Unlocked: a valid level. Before anyone has rebirthed it is never below "one past every level
	-- already cleared" (repairs old saves); after a rebirth, best times stay but levels re-lock.
	local unlocked = math.clamp(toCount(p.Unlocked, 1), 1, #Config.Levels)
	if p.Rebirths == 0 then
		for i, t in times do
			if t > 0 then
				unlocked = math.max(unlocked, math.min(i + 1, #Config.Levels))
			end
		end
		if (times[#Config.Levels] or 0) > 0 then
			p.RebirthReady = true
		end
	end
	p.Unlocked = unlocked

	if type(p.Stats) ~= "table" then
		p.Stats = Util.DeepCopy(TEMPLATE.Stats)
	end
	for key in TEMPLATE.Stats :: any do
		p.Stats[key] = toCount(p.Stats[key], 0)
	end
	-- (people who already finished a run don't need the first-run tutorial)
	p.TutorialDone = p.TutorialDone == true or (p.Stats.Runs :: number) > 0

	local receipts = {}
	if type(p.Receipts) == "table" then
		for _, id in p.Receipts do
			if type(id) == "string" then
				table.insert(receipts, id)
			end
		end
	end
	while #receipts > MAX_RECEIPTS do
		table.remove(receipts, 1)
	end
	p.Receipts = receipts

	-- Analytics bookkeeping: repaired, never trusted (and kept small).
	local an: any = if type(p.An) == "table" then p.An else {}
	an.First = if isFinite(an.First) then math.floor(an.First) else 0
	an.Last = toCount(an.Last, 0)
	an.Visits = toCount(an.Visits, 0)
	an.VisitStart = toCount(an.VisitStart, 0)
	an.Mask = math.clamp(toCount(an.Mask, 0), 0, 2 ^ 31 - 1)
	an.Runs = toCount(an.Runs, 0)
	an.DayNum = toCount(an.DayNum, 0)
	local dayMarks, seenDays, kept = {}, {}, 0
	for key, mark in (if type(an.Day) == "table" then an.Day else {}) do
		if type(key) == "string" and #key <= 48 and mark == true and kept < 160 then
			dayMarks[key] = true
			kept += 1
		end
	end
	kept = 0
	for key, day in (if type(an.Seen) == "table" then an.Seen else {}) do
		if type(key) == "string" and #key <= 48 and isFinite(day) and kept < 220 then
			seenDays[key] = math.floor(day)
			kept += 1
		end
	end
	an.Day, an.Seen = dayMarks, seenDays
	p.An = an
end

-- Copy of the profile that is safe to store: no runtime-only keys ("Lock", anything starting with
-- "_"), no Instances or functions, and no NaN/inf (which the DataStore refuses to encode).
local function cleanValue(value: any, depth: number): any
	local kind = type(value)
	if kind == "number" then
		return if isFinite(value) then value else 0
	elseif kind == "string" or kind == "boolean" then
		return value
	elseif kind == "table" and depth < 8 then
		local out = {}
		for k, v in value do
			if type(k) == "string" or type(k) == "number" then
				out[k] = cleanValue(v, depth + 1)
			end
		end
		return out
	end
	return nil
end

local function serialize(profile: Profile): { [string]: any }
	local out = {}
	for key, value in profile :: any do
		if type(key) == "string" and key ~= "Lock" and string.sub(key, 1, 1) ~= "_" then
			out[key] = cleanValue(value, 1)
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- Profile edits shared by the public API and the "arrived while loading" replay
----------------------------------------------------------------------------------------------------

local function applyBubbles(profile: Profile, amount: number)
	profile.Bubbles = math.max(0, profile.Bubbles + amount)
	if amount > 0 then
		profile.Stats.BubblesEarned += amount
	end
end

-- Tells Analytics about a currency change (never lets a listener's mistake touch the save).
local function economy(player: Player, currency: string, amount: number, balance: number, reason: string?)
	if amount ~= 0 then
		pcall(function()
			DataService.EconomyChanged:Fire(player, currency, amount, balance, reason or "Other")
		end)
	end
end

local function applyStat(profile: Profile, statName: string, amount: number)
	local stats = profile.Stats :: any
	stats[statName] = math.max(0, (stats[statName] or 0) + amount)
end

----------------------------------------------------------------------------------------------------
-- MetaState, leaderstats and toasts
----------------------------------------------------------------------------------------------------

-- Daily reward timing (Config.Daily): claimable 24 h after the last claim; the streak carries on if
-- you claim within the grace window after that, otherwise the next claim starts again at day 1
-- (unless the streak is restored with the RestoreStreak product).
local function dailyClaimable(profile: Profile): boolean
	return profile.DailyLast == 0 or os.time() >= profile.DailyLast + Config.Daily.Cooldown
end

local function dailyBroken(profile: Profile): boolean
	return profile.DailyStreak > 0 and profile.DailyLast > 0 and os.time() >= profile.DailyLast + Config.Daily.Cooldown + Config.Daily.Grace
end

local function buildMeta(player: Player, profile: Profile): Types.MetaState
	local passes = passesOf[player] or {}
	local passCopy = {}
	for _, pass in Config.GamePasses do
		passCopy[pass.Key] = passes[pass.Key] == true
	end
	passCopy.Premium = passes.Premium == true -- Roblox Premium (not a game pass; MarketService sets it)
	local perks = {}
	for _, perk in Config.Perks do
		perks[perk.Id] = profile.Perks[perk.Id] or 0
	end
	-- Pets whose id was removed from Config stay in the save but are hidden from the client, which
	-- could not draw them.
	local pets, known = {}, {}
	for _, pet in profile.Pets do
		if type(pet) == "table" and Config.Pets[pet.Id] then
			table.insert(pets, { Uid = pet.Uid, Id = pet.Id, Tier = if pet.Tier and pet.Tier > 1 then pet.Tier else nil })
			known[pet.Uid] = true
		end
	end
	local equipped = {}
	for _, uid in profile.Equipped do
		if known[uid] then
			table.insert(equipped, uid)
		end
	end
	local stats = profile.Stats
	local state: Types.MetaState = {
		Bubbles = profile.Bubbles,
		Gems = profile.Gems,
		Rank = profile.Rank,
		Ranks = table.clone(profile.Ranks),
		Perks = perks,
		Pets = pets,
		Equipped = equipped,
		PetSlots = Config.PetSlots(profile.Perks, slotPasses(player)),
		MaxPets = Config.PetRules.MaxInventory,
		Unlocked = profile.Unlocked,
		BestTimes = table.clone(profile.BestTimes),
		Rebirths = profile.Rebirths,
		RebirthReady = profile.RebirthReady,
		DailyStreak = profile.DailyStreak,
		DailyClaimedToday = not dailyClaimable(profile),
		DailyReadyAt = if profile.DailyLast > 0 then profile.DailyLast + Config.Daily.Cooldown else 0,
		DailyBroken = dailyBroken(profile),
		GroupReward = profile.GroupReward,
		FollowState = if profile.FollowReward then "Claimed" elseif profile.FollowPending then "Pending" else "",
		LikeState = if profile.LikeReward then "Claimed" elseif profile.LikePending then "Pending" else "",
		BoostUntil = profile.BoostUntil,
		StayBoostReady = profile.StayBoostDay ~= os.date("!%Y-%m-%d"),
		TutorialDone = profile.TutorialDone == true,
		RunsStarted = if type(profile.An) == "table" and type(profile.An.Runs) == "number" then profile.An.Runs else 0, -- dishwashers they have ever entered (the START CLEANING card only starts by itself for 0)
		PetsResting = profile.PetsResting,
		PetIndex = table.clone(profile.PetIndex),
		PetIndexPaid = table.clone(profile.PetIndexPaid),
		Referrals = profile.Referrals,
		AdLuckStacks = DataService.AdLuckStacks(profile),
		AdLuckUntil = profile.AdLuckUntil,
		ChestFreeLeft = DataService.FreeChestsLeft(profile),
		ChestsOpened = profile.ChestsOpened,
		ClubId = profile.ClubId,
		ClubNotice = if profile.ClubNotice ~= "" then profile.ClubNotice else nil,
		ClubFreeAt = if profile.ClubMovedAt + Config.Clubs.LeaveCooldown > os.time() then profile.ClubMovedAt + Config.Clubs.LeaveCooldown else nil,
		LevelsBeaten = DataService.LevelsBeaten(profile),
		Stats = {
			Runs = stats.Runs,
			DishesCleaned = stats.DishesCleaned,
			GrimeCleaned = stats.GrimeCleaned,
			EggsHatched = stats.EggsHatched,
			BubblesEarned = stats.BubblesEarned,
		},
		Passes = passCopy,
		Episodes = table.clone(profile.Episodes),
	}
	return state
end

local function setupLeaderstats(player: Player)
	if player:FindFirstChild("leaderstats") then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	-- Children are created in display order: Bubbles, then Dishes.
	for _, name in { "Bubbles", "Dishes" } do
		local value = Instance.new("IntValue")
		value.Name = name
		value.Value = 0
		value.Parent = folder
	end
	folder.Parent = player
end

local function setLeaderstat(player: Player, name: string, amount: number)
	local folder = player:FindFirstChild("leaderstats")
	local value = folder and folder:FindFirstChild(name)
	if value and value:IsA("IntValue") then
		value.Value = math.floor(amount)
	end
end

local queueNotice: (Session, string, string) -> ()

-- Remembers every pet species/tier the player holds, and pays the Gems for a finished set once.
local function updatePetIndex(session: Session, profile: Profile)
	for _, pet in profile.Pets do
		if Config.Pets[pet.Id] then
			local bit = bit32.lshift(1, math.clamp(math.floor(tonumber(pet.Tier) or 1), 1, #Config.PetTiers) - 1)
			profile.PetIndex[pet.Id] = bit32.bor(profile.PetIndex[pet.Id] or 0, bit)
		end
	end
	for _, set in Config.Collection.Sets do
		local key = tostring(set.Tier)
		if not profile.PetIndexPaid[key] and Config.CollectionSetDone(profile.PetIndex, set.Tier) then
			profile.PetIndexPaid[key] = true
			profile.Gems += set.Gems
			queueNotice(session, string.format("Collection complete: every %s pet! +%d Gems and a bigger coin bonus!", set.Name, set.Gems), "Good")
		end
	end
end

local function pushNow(player: Player)
	local session = sessions[player]
	local profile = session and session.Profile
	if not profile or not isHere(player) then
		return
	end
	updatePetIndex(session, profile)
	player:SetAttribute("Bubbles", profile.Bubbles)
	setLeaderstat(player, "Bubbles", profile.Bubbles)
	setLeaderstat(player, "Dishes", profile.Stats.DishesCleaned)
	metaRemote:FireClient(player, buildMeta(player, profile))
end

local function flushNotices(session: Session)
	local player = session.Player
	if #session.Notices == 0 or not isHere(player) then
		return
	end
	local list = session.Notices
	session.Notices = {}
	for _, notice in list do
		notifyRemote:FireClient(player, notice[1], notice[2])
	end
end

-- Toasts sent the instant a player joins can arrive before their UI exists, so they wait until the
-- client has asked for its MetaState (or a fallback delay passes).
queueNotice = function(session: Session, text: string, kind: string)
	table.insert(session.Notices, { text, kind })
	task.delay(if session.ClientReady then NOTICE_AFTER_READY else NOTICE_FALLBACK, flushNotices, session)
end

----------------------------------------------------------------------------------------------------
-- Saving
----------------------------------------------------------------------------------------------------

local function ownsLock(record: { [string]: any }): boolean
	local lock = record.Lock
	return type(lock) == "table" and lock.JobId == game.JobId
end

local function lockedElsewhere(record: { [string]: any }): boolean
	local lock = record.Lock
	if type(lock) ~= "table" or lock.JobId == game.JobId or not isFinite(lock.Time) then
		return false
	end
	-- The other server saved this player just before teleporting them here and said so: the save is
	-- up to date, so take it now instead of waiting for that server to notice they left.
	if lock.Handoff == true and os.time() - lock.Time < HANDOFF_TTL then
		return false
	end
	return os.time() - lock.Time < LOCK_TTL
end

-- Saves for one session run one at a time (an autosave and the final save must never race).
local function acquireSaveSlot(session: Session)
	while session.Busy do
		table.insert(session.SaveQueue, coroutine.running())
		coroutine.yield()
	end
	session.Busy = true
end

local function releaseSaveSlot(session: Session)
	session.Busy = false
	local nextThread = table.remove(session.SaveQueue, 1)
	if nextThread then
		task.spawn(nextThread)
	end
end

-- One UpdateAsync: writes the profile and refreshes the lock (or clears it when `release`).
-- It only writes while this server still owns the lock; otherwise saving stops for this session.
local function writeProfile(session: Session, release: boolean): boolean
	local profile = session.Profile
	local dataStore = getStore()
	if not profile or not dataStore then
		return false
	end
	-- Everything that could be slow happens before UpdateAsync: the transform itself must not yield.
	local payload = serialize(profile)
	local userIds = { session.UserId }
	local outcome = "Error"
	local ok, err = pcall(function()
		dataStore:UpdateAsync(session.Key, function(old)
			if old == nil then
				outcome = "Missing" -- the save was erased (e.g. a data-removal request); don't resurrect it
				return nil
			end
			if type(old) ~= "table" or not ownsLock(old) then
				outcome = "LockLost"
				return nil
			end
			payload.Lock = if release
				then nil
				else { JobId = game.JobId, Time = os.time(), Handoff = if session.Handoff then true else nil }
			outcome = "Ok"
			return payload, userIds
		end)
	end)
	if not ok then
		warn(string.format("[DataService] save failed for %s: %s", session.Key, tostring(err)))
		return false
	end
	if outcome == "Ok" then
		return true
	end
	-- Another server owns this save now (or it's gone). Writing from here would clobber it.
	session.CanSave = false
	warn(string.format("[DataService] stopped saving %s (%s)", session.Key, outcome))
	if outcome == "LockLost" and not session.Left and isHere(session.Player) then
		queueNotice(session, MSG_LOCK_LOST, "Bad")
	end
	return false
end

local function saveSession(session: Session, release: boolean, attempts: number): boolean
	if not session.CanSave or not session.Profile or session.Released then
		return false
	end
	acquireSaveSlot(session)
	local saved = false
	for attempt = 1, attempts do
		if not session.CanSave or session.Released then
			break
		end
		saved = writeProfile(session, release)
		if saved or not session.CanSave then
			break
		end
		if attempt < attempts then
			task.wait(attempt * 2)
		end
	end
	if saved and release then
		session.Released = true
	end
	releaseSaveSlot(session)
	return saved
end

local function autosave(session: Session)
	if not saveSession(session, false, 1) and session.CanSave and not session.Finalizing then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + AUTOSAVE_RETRY)
	end
end

-- Marks a session completely finished: wakes anyone waiting on it and forgets it.
local function finishSession(session: Session)
	openLatch(session.Loaded)
	openLatch(session.Done)
	if lastSessionOf[session.UserId] == session then
		lastSessionOf[session.UserId] = nil
	end
end

-- The last save of a session: writes the profile and releases the lock. Safe to call more than once.
local function finalize(session: Session)
	if session.Finalizing then
		return
	end
	session.Finalizing = true
	if session.CanSave and session.Profile then
		if not saveSession(session, true, FINAL_SAVE_ATTEMPTS) and session.CanSave then
			warn("[DataService] final save failed for " .. session.Key .. "; its lock expires on its own")
		end
	end
	finishSession(session)
end

----------------------------------------------------------------------------------------------------
-- Loading
----------------------------------------------------------------------------------------------------

-- Loads the record and takes the session lock. Returns:
--   "Ok", record   -> we own the lock and have the data (a brand-new player gets the template)
--   "Abort", nil   -> the player left or the server is closing; nothing was locked
--   "Failed", nil  -> DataStore errors on every attempt, or a record we can't read
local function loadFromStore(session: Session): (string, any)
	local lockedTries, errorTries = 0, 0
	while true do
		if session.Left or shuttingDown or not isHere(session.Player) then
			return "Abort", nil
		end
		local steal = lockedTries >= LOCK_RETRIES
		local status: string? = nil
		local record: any = nil
		local ok, err = false, "DataStoreService unavailable"
		local dataStore = getStore()
		if dataStore then
			local userIds = { session.UserId }
			ok, err = pcall(function()
				dataStore:UpdateAsync(session.Key, function(old)
					-- Must not yield. UpdateAsync may call this more than once; the last call wins.
					status, record = nil, nil
					if old ~= nil and type(old) ~= "table" then
						status = "Corrupt"
						return nil
					end
					if old ~= nil and not steal and lockedElsewhere(old) then
						status = "Locked"
						return nil
					end
					local data = if old ~= nil then old else newProfile() :: any
					data.Lock = { JobId = game.JobId, Time = os.time() }
					status, record = "Ok", data
					return data, userIds
				end)
			end)
		end

		if ok and status == "Ok" then
			if steal then
				warn("[DataService] took over a stale session lock for " .. session.Key)
			end
			return "Ok", record
		elseif ok and status == "Corrupt" then
			warn("[DataService] unreadable save for " .. session.Key .. "; it will not be touched")
			return "Failed", nil
		elseif ok and status == "Locked" then
			-- Another server is still saving this player (a server hop). Give it a moment.
			lockedTries += 1
			task.wait(rng:NextNumber(LOCK_WAIT_MIN, LOCK_WAIT_MAX))
		else
			errorTries += 1
			warn(string.format("[DataService] load attempt %d for %s failed: %s", errorTries, session.Key, tostring(err)))
			if errorTries >= LOAD_ATTEMPTS then
				return "Failed", nil
			end
			task.wait(math.min(1.5 * errorTries, 6) + rng:NextNumber(0, 1))
		end
	end
end


-- When a stay boost runs out, run stats drop back to normal (on whichever server they're on now).
local function watchBoostEnd(player: Player)
	local profile = DataService.Get(player)
	local untilTime = profile and profile.BoostUntil or 0
	if untilTime <= os.time() then
		return
	end
	task.delay(untilTime - os.time() + 1, function()
		local p = DataService.Get(player)
		if p and p.BoostUntil == untilTime then
			DataService.PushMeta(player)
			DataService.PassesChanged:Fire(player)
		end
	end)
end

local function loadSession(session: Session)
	local player = session.Player

	-- A quick rejoin to this same server: let the previous session's final save land first, or we
	-- could read the save from before it.
	local previous = session.Previous
	session.Previous = nil
	if previous then
		waitLatch(previous.Done, SAME_USER_WAIT)
	end
	if not detection.Open then
		waitLatch(detection, PROBE_WAIT * 3)
	end

	local profile: Profile
	local canSave = false
	local notice: string? = nil
	local noticeKind = "Info"
	if offline then
		profile = newProfile()
		notice = MSG_OFFLINE
	else
		local status, record = loadFromStore(session)
		if status == "Abort" then
			finishSession(session)
			return
		end
		if status == "Ok" then
			profile = record
			canSave = true
		else
			-- Never overwrite a save we couldn't read: play on a temporary profile that is never saved.
			profile = newProfile()
			notice, noticeKind = MSG_LOAD_FAILED, "Bad"
			warn("[DataService] using a temporary unsaved profile for " .. session.Key)
		end
	end

	sanitizeProfile(profile, player)
	-- Rewards that arrived while we were loading.
	for _, change in session.Pending do
		if change.Stat then
			applyStat(profile, change.Stat, change.Amount)
		else
			applyBubbles(profile, change.Amount)
		end
	end
	session.Pending = {}

	session.Profile = profile
	session.CanSave = canSave
	session.NextAutosave = os.clock() + AUTOSAVE_INTERVAL + rng:NextNumber(0, AUTOSAVE_JITTER)

	if session.Left or not isHere(player) then
		-- They left while we were loading: hand the lock straight back.
		finalize(session)
		return
	end

	openLatch(session.Loaded)
	if notice then
		queueNotice(session, notice, noticeKind)
	end
	player:SetAttribute("PetsResting", profile.PetsResting == true) -- PetService reads this
	player:SetAttribute("ClubTag", if profile.ClubTag ~= "" then profile.ClubTag else nil) -- NameTags
	DataService.ProfileLoaded:Fire(player, profile)
	pushNow(player)
	task.defer(watchBoostEnd, player)

	if shuttingDown then
		finalize(session)
	end
end

local function ensureSession(player: Player): Session?
	local existing = sessions[player]
	if existing then
		return existing
	end
	if not isHere(player) then
		return nil
	end
	local userId = player.UserId
	local previous = lastSessionOf[userId]
	local session: Session = {
		Player = player,
		UserId = userId,
		Key = KEY_PREFIX .. tostring(userId),
		Profile = nil,
		CanSave = false,
		Left = false,
		Finalizing = false,
		Handoff = false,
		Released = false,
		Busy = false,
		SaveQueue = {},
		Loaded = newLatch(),
		Done = newLatch(),
		Previous = if previous and not previous.Done.Open then previous else nil,
		NextAutosave = math.huge,
		Pending = {},
		Notices = {},
		ClientReady = false,
	}
	sessions[player] = session
	lastSessionOf[userId] = session
	if not passesOf[player] then
		passesOf[player] = {}
	end
	setupLeaderstats(player)
	task.spawn(track, loadSession, session)
	return session
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	sessions[player] = nil
	passesOf[player] = nil
	pushQueued[player] = nil
	metaBudget[player] = nil
	if not session then
		return
	end
	session.Left = true
	openLatch(session.Loaded) -- WaitFor callers wake up and get nil
	if session.Profile then
		task.spawn(track, finalize, session)
	end
	-- Still loading: loadSession notices Left and releases the lock itself.
end

----------------------------------------------------------------------------------------------------
-- GetMeta
----------------------------------------------------------------------------------------------------

local function allowMetaRequest(player: Player): boolean
	local now = os.clock()
	local budget = metaBudget[player]
	if not budget then
		budget = { Tokens = META_REQUESTS_PER_SECOND, At = now }
		metaBudget[player] = budget
	end
	budget.Tokens = math.min(META_REQUESTS_PER_SECOND, budget.Tokens + (now - budget.At) * META_REQUESTS_PER_SECOND)
	budget.At = now
	if budget.Tokens < 1 then
		return false
	end
	budget.Tokens -= 1
	return true
end

local function onGetMeta(player: Player): Types.MetaState?
	local session = sessions[player]
	if not session or not isHere(player) or not allowMetaRequest(player) then
		return nil
	end
	if not session.ClientReady then
		-- The client's remotes are hooked up now; anything waiting to be said can go out shortly.
		session.ClientReady = true
		task.delay(NOTICE_AFTER_READY, flushNotices, session)
	end
	local profile = session.Profile
	if not profile then
		return nil
	end
	return buildMeta(player, profile)
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

function DataService.Init()
	if initialized then
		return
	end
	initialized = true

	metaRemote = Remotes.Event("MetaState")
	notifyRemote = Remotes.Event("Notify")
	Remotes.Function("GetMeta").OnServerInvoke = onGetMeta

	detectOffline()

	Players.PlayerAdded:Connect(function(player)
		ensureSession(player)
	end)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		ensureSession(player)
	end

	game:BindToClose(function()
		shuttingDown = true
		if not detection.Open then
			waitLatch(detection, 3)
		end
		if offline then
			return
		end
		for _, session in sessions do
			if session.Profile then
				task.spawn(track, finalize, session)
			end
		end
		-- Sessions still loading abort (or release right after loading); PlayerRemoving saves run too.
		local deadline = os.clock() + SHUTDOWN_WAIT
		while activeJobs > 0 and os.clock() < deadline do
			task.wait(0.25)
		end
		if activeJobs > 0 then
			warn(string.format("[DataService] shutdown: %d save(s) still running after %ds", activeJobs, SHUTDOWN_WAIT))
		end
	end)
end

function DataService.Start()
	if started then
		return
	end
	started = true
	task.spawn(function()
		while true do
			task.wait(AUTOSAVE_TICK)
			if not shuttingDown and not offline then
				local now = os.clock()
				for _, session in sessions do
					if
						session.CanSave
						and session.Profile
						and not session.Finalizing
						and not session.Busy
						and now >= session.NextAutosave
					then
						session.NextAutosave = now + AUTOSAVE_INTERVAL
						task.spawn(track, autosave, session)
					end
				end
			end
		end
	end)
end

-- The player's profile, or nil while it's loading (or after they left).
function DataService.Get(player: Player): Profile?
	local session = sessions[player]
	return session and session.Profile
end

-- Yields until the profile is ready (or `timeout` seconds pass, default 60, or the player leaves).
function DataService.WaitFor(player: Player, timeout: number?): Profile?
	if not isPlayer(player) then
		return nil
	end
	local session = ensureSession(player)
	if not session then
		return nil
	end
	if not session.Profile then
		waitLatch(session.Loaded, if isFinite(timeout) then math.max(0, timeout :: number) else 60)
	end
	return DataService.Get(player)
end

-- Coalesces MetaState pushes: any number of calls within PUSH_COALESCE seconds send one snapshot.
function DataService.PushMeta(player: Player)
	if not isPlayer(player) or pushQueued[player] or not sessions[player] then
		return
	end
	pushQueued[player] = true
	task.delay(PUSH_COALESCE, function()
		if not pushQueued[player] then
			return -- the player left in the meantime
		end
		pushQueued[player] = nil
		pushNow(player)
	end)
end

-- Adds (or with a negative amount, removes) Bubbles. Positive amounts also count toward
-- Stats.BubblesEarned. `reason` is only used in warnings. Returns false if nothing was applied.
function DataService.AddBubbles(player: Player, amount: number, reason: string?): boolean
	if not isFinite(amount) then
		warn("[DataService] AddBubbles ignored a bad amount (" .. tostring(reason) .. ")")
		return false
	end
	local rounded = math.floor(amount + 0.5)
	local session = sessions[player]
	if not session then
		return false
	end
	if rounded == 0 then
		return true
	end
	local profile = session.Profile
	if not profile then
		table.insert(session.Pending, { Amount = rounded })
		return true
	end
	applyBubbles(profile, rounded)
	economy(player, "Bubbles", rounded, profile.Bubbles, reason)
	DataService.PushMeta(player)
	return true
end

-- Counts one run-start cutscene chapter as seen for a level (the next run plays the next one).
function DataService.SawEpisode(player: Player, levelIndex: number): boolean
	local profile = DataService.Get(player)
	if not profile or type(levelIndex) ~= "number" or levelIndex ~= levelIndex then
		return false
	end
	local i = math.floor(levelIndex)
	if i < 1 or i > #Config.Levels then
		return false
	end
	profile.Episodes[i] = math.min((profile.Episodes[i] or 0) + 1, 1e6)
	DataService.PushMeta(player)
	return true
end

-- Marks a lobby rubber duck as found. Returns (isNew, foundCount).
function DataService.FindDuck(player: Player, duckId: string): (boolean, number)
	local profile = DataService.Get(player)
	if not profile then
		return false, 0
	end
	if table.find(profile.Ducks, duckId) then
		return false, #profile.Ducks
	end
	table.insert(profile.Ducks, duckId)
	return true, #profile.Ducks
end

-- Takes Bubbles if the player has enough. Returns true when paid.
function DataService.SpendBubbles(player: Player, amount: number, reason: string?): boolean
	local profile = DataService.Get(player)
	if not profile or not isFinite(amount) or amount < 0 then
		return false
	end
	local cost = math.ceil(amount)
	if profile.Bubbles < cost then
		return false
	end
	profile.Bubbles -= cost
	economy(player, "Bubbles", -cost, profile.Bubbles, reason)
	DataService.PushMeta(player)
	return true
end

-- Gems (premium currency). Returns true when applied.
function DataService.AddGems(player: Player, amount: number, reason: string?): boolean
	local profile = DataService.Get(player)
	if not profile or not isFinite(amount) or amount <= 0 then
		return false
	end
	local rounded = math.floor(amount + 0.5)
	profile.Gems += rounded
	economy(player, "Gems", rounded, profile.Gems, reason)
	DataService.PushMeta(player)
	return true
end

function DataService.SpendGems(player: Player, amount: number, reason: string?): boolean
	local profile = DataService.Get(player)
	if not profile or not isFinite(amount) or amount < 0 then
		return false
	end
	local cost = math.ceil(amount)
	if profile.Gems < cost then
		return false
	end
	profile.Gems -= cost
	economy(player, "Gems", -cost, profile.Gems, reason)
	DataService.PushMeta(player)
	return true
end

-- Claims the daily reward if 24 hours have passed since the last claim. Returns the streak day
-- claimed (1..7) or nil and an error.
function DataService.ClaimDaily(player: Player): (number?, string?)
	local profile = DataService.Get(player)
	if not profile then
		return nil, "Your data is still loading."
	end
	if not dailyClaimable(profile) then
		return nil, "Come back when the timer runs out!"
	end
	local streak = if dailyBroken(profile) or profile.DailyLast == 0 then 1 else profile.DailyStreak % #Config.DailyRewards + 1
	local reward = Config.DailyRewards[streak]
	profile.DailyLast = os.time()
	profile.DailyStreak = streak
	if reward.Kind == "Gems" then
		profile.Gems += reward.Amount
		economy(player, "Gems", reward.Amount, profile.Gems, "Daily")
	else
		applyBubbles(profile, reward.Amount)
		economy(player, "Bubbles", reward.Amount, profile.Bubbles, "Daily")
	end
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
	end
	DataService.PushMeta(player)
	return streak, nil
end

-- The "stay" boost: offered when a player opens the Roblox menu (often on the way out). x2 cleaning
-- for STAY_BOOST_SECONDS, claimable once per UTC day. Returns (ok, message).
local STAY_BOOST_SECONDS = 15 * 60
function DataService.ClaimStayBoost(player: Player): (boolean, string)
	local profile = DataService.Get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local today = os.date("!%Y-%m-%d")
	if profile.StayBoostDay == today then
		return false, "You've had today's free boost already. Come back tomorrow!"
	end
	profile.StayBoostDay = today
	profile.BoostUntil = math.max(os.time(), profile.BoostUntil) + STAY_BOOST_SECONDS
	-- Saved within seconds, so leaving and rejoining can't claim it again.
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + 2)
	end
	DataService.PushMeta(player)
	DataService.PassesChanged:Fire(player) -- run stats pick up the x2 now
	watchBoostEnd(player)
	return true, "x2 Cleaning for 15 minutes! Enjoy!"
end

-- The Roblox Premium daily gift (Config.Premium.DailyReward): once per UTC day, only while the player
-- is a Premium member. Returns the reward text when it was just paid, nil otherwise.
function DataService.ClaimPremiumDaily(player: Player): string?
	local profile = DataService.Get(player)
	local passes = passesOf[player]
	if not profile or not passes or passes.Premium ~= true then
		return nil
	end
	local today = os.date("!%Y-%m-%d")
	if profile.PremiumDay == today then
		return nil
	end
	profile.PremiumDay = today
	local reward = Config.Premium.DailyReward
	if (reward.Bubbles or 0) > 0 then
		DataService.AddBubbles(player, reward.Bubbles :: number, "Premium")
	end
	if (reward.Gems or 0) > 0 then
		DataService.AddGems(player, reward.Gems :: number, "Premium")
	end
	-- Saved within seconds, so rejoining can't collect it twice.
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + 2)
	end
	DataService.PushMeta(player)
	return Config.RewardText(reward)
end

-- Adds `seconds` of x2 cleaning (the stay boost) on top of whatever's left. Admin events use this.
function DataService.AddBoost(player: Player, seconds: number): boolean
	local profile = DataService.Get(player)
	if not profile or not isFinite(seconds) or seconds <= 0 then
		return false
	end
	profile.BoostUntil = math.max(os.time(), profile.BoostUntil) + math.floor(seconds)
	DataService.PushMeta(player)
	DataService.PassesChanged:Fire(player) -- run stats pick up the x2 now
	watchBoostEnd(player)
	return true
end

-- Referrals (SocialService). The new player's side: only for someone who hasn't really played yet
-- (no runs, dishes or rebirths) and wasn't referred before. Returns true if it paid out.
function DataService.ClaimReferred(player: Player, inviterId: number): boolean
	local profile = DataService.Get(player)
	if not profile or profile.ReferredBy ~= 0 or inviterId == player.UserId or inviterId <= 0 then
		return false
	end
	if profile.Stats.Runs > 0 or profile.Stats.DishesCleaned > 0 or profile.Rebirths > 0 then
		return false
	end
	profile.ReferredBy = inviterId
	local reward = Config.Social.ReferredReward
	profile.Gems += reward.Gems or 0
	applyBubbles(profile, reward.Bubbles or 0)
	economy(player, "Gems", reward.Gems or 0, profile.Gems, "Referred")
	economy(player, "Bubbles", reward.Bubbles or 0, profile.Bubbles, "Referred")
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + 2)
	end
	DataService.PushMeta(player)
	return true
end

-- The inviter's side: `count` new friends joined through their invites. Returns how many paid out
-- (capped at Config.Social.MaxReferrals in total).
function DataService.AddReferrals(player: Player, count: number): number
	local profile = DataService.Get(player)
	if not profile or not isFinite(count) or count <= 0 then
		return 0
	end
	local paid = math.min(math.floor(count), math.max(0, Config.Social.MaxReferrals - profile.Referrals))
	if paid <= 0 then
		return 0
	end
	profile.Referrals += paid
	local reward = Config.Social.ReferralReward
	profile.Gems += (reward.Gems or 0) * paid
	applyBubbles(profile, (reward.Bubbles or 0) * paid)
	economy(player, "Gems", (reward.Gems or 0) * paid, profile.Gems, "Referral")
	economy(player, "Bubbles", (reward.Bubbles or 0) * paid, profile.Bubbles, "Referral")
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + 2)
	end
	DataService.PushMeta(player)
	return paid
end

-- Treasure Chest event: free chests still to open in the current event.
function DataService.FreeChestsLeft(profile: any): number
	local event = Config.ChestEvent
	if not profile or not Config.ChestEventLive() then
		return 0
	end
	local used = if profile.ChestEventId == event.Id then profile.ChestFreeUsed else 0
	return math.max(0, event.FreeOpens - used)
end

-- Uses one free chest. False when there are none left.
function DataService.UseFreeChest(player: Player): boolean
	local profile = DataService.Get(player)
	if not profile or DataService.FreeChestsLeft(profile) <= 0 then
		return false
	end
	if profile.ChestEventId ~= Config.ChestEvent.Id then
		profile.ChestEventId = Config.ChestEvent.Id
		profile.ChestFreeUsed = 0
	end
	profile.ChestFreeUsed += 1
	return true
end

-- Counts opened chests (after the rewards are given) and saves soon.
function DataService.CountChests(player: Player, count: number)
	local session = sessions[player]
	local profile = session and session.Profile
	if not profile then
		return
	end
	profile.ChestsOpened += math.max(0, math.floor(count))
	session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
	DataService.PushMeta(player)
end

-- The highest level this player has ever cleared (club requirements). Rebirthing means every level.
function DataService.LevelsBeaten(profile: any): number
	if not profile then
		return 0
	end
	if (profile.Rebirths or 0) > 0 then
		return #Config.Levels
	end
	local best = 0
	for i = 1, #Config.Levels do
		if (tonumber(profile.BestTimes and profile.BestTimes[i]) or 0) > 0 then
			best = i
		end
	end
	return best
end

-- Notes that this club-contest month's prize was dealt with (saved soon).
function DataService.MarkClubPrize(player: Player, season: string)
	local session = sessions[player]
	local profile = session and session.Profile
	if not profile then
		return
	end
	profile.ClubPrizeSeason = season
	session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
end

-- Club membership on the profile (ClubService owns the clubs themselves).
function DataService.SetClub(player: Player, clubId: string, tag: string, moved: boolean?)
	local session = sessions[player]
	local profile = session and session.Profile
	if not profile then
		return
	end
	profile.ClubId = clubId
	profile.ClubTag = tag
	if moved then
		profile.ClubMovedAt = os.time()
	end
	player:SetAttribute("ClubTag", if tag ~= "" then tag else nil)
	session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
	DataService.PushMeta(player)
end

-- Kicked from a club: the player can't rejoin that club for Config.Clubs.KickBan seconds from `at`.
function DataService.SetClubBan(player: Player, clubId: string, at: number)
	local session = sessions[player]
	local profile = session and session.Profile
	if not profile or clubId == "" then
		return
	end
	profile.ClubBans[clubId] = at
	session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
end

-- A message the client shows once the next time it can ("" clears it).
function DataService.SetClubNotice(player: Player, text: string)
	local session = sessions[player]
	local profile = session and session.Profile
	if not profile then
		return
	end
	profile.ClubNotice = string.sub(text, 1, 160)
	session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
	DataService.PushMeta(player)
end

-- A staff test tool: no wait after leaving a club, no kick bans, no pending notice.
function DataService.ResetClubCooldowns(player: Player): boolean
	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	profile.ClubMovedAt = 0
	profile.ClubBans = {}
	profile.ClubNotice = ""
	DataService.PushMeta(player)
	return true
end

-- Rewarded-ad luck was removed (friends' luck replaced it); kept as no-ops for old callers.
function DataService.AdLuckStacks(_profile: any): number
	return 0
end

function DataService.AddAdLuck(_player: Player): boolean
	return false
end

-- The pets on / off switch: resting pets follow you but don't clean. Saved, so it carries over
-- between the lobby and the dishwashers.
-- Back to a brand-new player's first run (a staff test tool): tutorial not done, no runs, level 1 cutscene unseen.
function DataService.ResetFirstRun(player: Player): boolean
	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	profile.TutorialDone = false
	profile.Stats.Runs = 0
	profile.Episodes = {}
	DataService.PushMeta(player)
	return true
end

-- The first-run tutorial was finished (`completed`) or skipped. Returns (ok, rewarded): finishing pays
-- Config.Tutorial.Reward once (and only to someone who really cleaned a few dishes); skipping pays nothing.
function DataService.SetTutorialDone(player: Player, completed: boolean?): (boolean, boolean)
	local profile = DataService.Get(player)
	if not profile then
		return false, false
	end
	local first = profile.TutorialDone ~= true
	profile.TutorialDone = true
	local rewarded = false
	if first and completed == true and (profile.Stats.DishesCleaned or 0) >= 3 then
		local reward = Config.Tutorial.Reward
		if (reward.Bubbles or 0) > 0 then
			DataService.AddBubbles(player, reward.Bubbles :: number, "Tutorial")
		end
		if (reward.Gems or 0) > 0 then
			DataService.AddGems(player, reward.Gems :: number, "Tutorial")
		end
		rewarded = true
	end
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + 5)
	end
	DataService.PushMeta(player)
	return true, rewarded
end

function DataService.SetPetsResting(player: Player, resting: boolean): boolean
	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	profile.PetsResting = resting == true
	player:SetAttribute("PetsResting", profile.PetsResting)
	DataService.PushMeta(player)
	return true
end

-- RestoreStreak product: a missed day is forgiven, so the next claim (available now) carries on
-- from the streak you had.
function DataService.RestoreStreak(player: Player): boolean
	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	if dailyBroken(profile) then
		-- As if the last claim was exactly 24 hours ago: claimable now, and the streak carries on.
		profile.DailyLast = os.time() - Config.Daily.Cooldown
	end
	DataService.PushMeta(player)
	return true
end

-- Redeems a code from Config.Codes (any capitalisation) once per player.
function DataService.RedeemCode(player: Player, text: string): (boolean, string)
	local profile = DataService.Get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	local code = string.upper((string.gsub(text, "%s", "")))
	local def = Config.Codes[code]
	if not def or (def.Expires and os.time() > def.Expires) then
		return false, "That code doesn't work."
	end
	if table.find(profile.RedeemedCodes, code) then
		return false, "You already used that code!"
	end
	table.insert(profile.RedeemedCodes, code)
	if def.Gems then
		profile.Gems += def.Gems
		economy(player, "Gems", def.Gems, profile.Gems, "Code")
	end
	if def.Bubbles then
		applyBubbles(profile, def.Bubbles)
		economy(player, "Bubbles", def.Bubbles, profile.Bubbles, "Code")
	end
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
	end
	DataService.PushMeta(player)
	return true, Config.RewardText(def)
end

-- A toast for this player that waits until their UI is up (safe to call right after joining).
function DataService.Notice(player: Player, text: string, kind: string)
	local session = sessions[player]
	if session then
		queueNotice(session, text, kind)
	end
end

-- Follow / Like rewards (Config.Social): "Follow" or "Like". Pending is set by the button and
-- settled by SocialService on the next join.
function DataService.SetSocialPending(player: Player, kind: string, pending: boolean): boolean
	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	if kind == "Follow" then
		profile.FollowPending = pending and not profile.FollowReward
	elseif kind == "Like" then
		profile.LikePending = pending and not profile.LikeReward
	else
		return false
	end
	DataService.PushMeta(player)
	return true
end

function DataService.GrantSocialReward(player: Player, kind: string): boolean
	local profile = DataService.Get(player)
	if not profile then
		return false
	end
	local reward
	if kind == "Follow" and not profile.FollowReward then
		profile.FollowReward = true
		profile.FollowPending = false
		reward = Config.Social.FollowReward
	elseif kind == "Like" and not profile.LikeReward and Config.Social.LikeReward then
		profile.LikeReward = true
		profile.LikePending = false
		reward = Config.Social.LikeReward :: any
	else
		return false
	end
	profile.Gems += reward.Gems or 0
	applyBubbles(profile, reward.Bubbles or 0)
	economy(player, "Gems", reward.Gems or 0, profile.Gems, kind)
	economy(player, "Bubbles", reward.Bubbles or 0, profile.Bubbles, kind)
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
	end
	DataService.PushMeta(player)
	return true
end

-- The one-time community reward (ShopService checks membership first).
function DataService.GrantGroupReward(player: Player): boolean
	local profile = DataService.Get(player)
	if not profile or profile.GroupReward then
		return false
	end
	profile.GroupReward = true
	local reward = Config.Social.GroupReward
	profile.Gems += reward.Gems or 0
	applyBubbles(profile, reward.Bubbles or 0)
	economy(player, "Gems", reward.Gems or 0, profile.Gems, "Group")
	economy(player, "Bubbles", reward.Bubbles or 0, profile.Bubbles, "Group")
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
	end
	DataService.PushMeta(player)
	return true
end

-- Rebirth: needs the last level cleared since the last rebirth and Config.RebirthCost Bubbles.
-- Resets Bubbles, unlocked levels and perks; keeps pets, gems, ranks, passes and best times; adds
-- one rebirth (permanent coin and Bubble bonuses, see Config.Rebirth) and some gems.
function DataService.Rebirth(player: Player): (boolean, string?)
	local profile = DataService.Get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	if not profile.RebirthReady then
		local last = Config.Levels[#Config.Levels]
		return false, string.format("Clean %s %s first!", last.Icon, last.Name)
	end
	local cost = Config.RebirthCost(profile.Rebirths)
	if profile.Bubbles < cost then
		return false, string.format("You need %s Bubbles to rebirth.", Format.Commas(cost))
	end
	profile.Rebirths += 1
	profile.RebirthReady = false
	profile.Bubbles = 0
	profile.Unlocked = 1
	for id in profile.Perks do
		profile.Perks[id] = 0
	end
	profile.Gems += Config.RebirthGems(profile.Rebirths)
	local session = sessions[player]
	if session then
		session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
	end
	DataService.PushMeta(player)
	DataService.PassesChanged:Fire(player) -- run stats depend on rebirths too
	return true, nil
end

-- Adds a rank to the collection (no-op if owned). Returns true if it was new.
function DataService.AddRank(player: Player, rankId: string): boolean
	local profile = DataService.Get(player)
	if not profile or not Config.GetRank(rankId) or table.find(profile.Ranks, rankId) then
		return false
	end
	table.insert(profile.Ranks, rankId)
	DataService.PushMeta(player)
	return true
end

function DataService.SetRank(player: Player, rankId: string): boolean
	local profile = DataService.Get(player)
	if not profile or (rankId ~= "" and not table.find(profile.Ranks, rankId)) then
		return false
	end
	profile.Rank = rankId
	DataService.PushMeta(player)
	DataService.PassesChanged:Fire(player) -- same effect as a pass change: run stats recompute
	return true
end

-- Adds to one of profile.Stats (Runs, DishesCleaned, GrimeCleaned, EggsHatched, BubblesEarned).
function DataService.AddStat(player: Player, statName: string, amount: number): boolean
	if type(statName) ~= "string" or (TEMPLATE.Stats :: any)[statName] == nil or not isFinite(amount) then
		return false
	end
	local rounded = math.floor(amount + 0.5)
	local session = sessions[player]
	if not session then
		return false
	end
	if rounded == 0 then
		return true
	end
	local profile = session.Profile
	if not profile then
		table.insert(session.Pending, { Stat = statName, Amount = rounded })
		return true
	end
	applyStat(profile, statName, rounded)
	DataService.PushMeta(player)
	return true
end

-- Runtime pass ownership ({ [Key] = true }). Read-only for callers.
function DataService.GetPasses(player: Player): { [string]: boolean }
	return passesOf[player] or {}
end

-- Records pass ownership for this session. When it changes, Equipped is trimmed to the (possibly
-- smaller) slot count, MetaState is pushed and PassesChanged fires so run stats and pets update.
function DataService.SetPass(player: Player, key: string, owned: boolean)
	if not isPlayer(player) or type(key) ~= "string" then
		return
	end
	local passes = passesOf[player]
	if not passes then
		if not isHere(player) then
			return
		end
		passes = {}
		passesOf[player] = passes
	end
	local value = owned == true
	local changed = (passes[key] == true) ~= value
	passes[key] = value

	-- Loading trims Equipped as if an on-sale slot pass were owned; now that we know, trim for real.
	local trimmed = false
	local profile = DataService.Get(player)
	if profile then
		local slots = Config.PetSlots(profile.Perks, slotPasses(player))
		while #profile.Equipped > slots do
			table.remove(profile.Equipped)
			trimmed = true
		end
	end

	if changed or trimmed then
		DataService.PushMeta(player)
		DataService.PassesChanged:Fire(player)
	end
end

function DataService.GetPetSlots(player: Player): number
	local profile = DataService.Get(player)
	return Config.PetSlots(profile and profile.Perks, slotPasses(player))
end

-- Records a finished run. Returns (firstClear, newBest, unlockedLevel?). A first clear also counts as
-- a new best. The next level unlocks if it exists and wasn't unlocked yet.
function DataService.RecordClear(player: Player, levelIndex: number, seconds: number): (boolean, boolean, number?)
	local session = sessions[player]
	local profile = session and session.Profile
	if
		not session
		or not profile
		or not isFinite(levelIndex)
		or levelIndex ~= math.floor(levelIndex)
		or not Config.Levels[levelIndex]
		or not isFinite(seconds)
		or seconds <= 0
	then
		return false, false, nil
	end

	local time = math.max(0.1, math.floor(seconds * 10 + 0.5) / 10) -- tenths, like the leaderboards
	local previous = profile.BestTimes[levelIndex] or 0
	local firstClear = previous <= 0
	local newBest = firstClear or time < previous
	if newBest then
		profile.BestTimes[levelIndex] = time
	end

	local unlocked: number? = nil
	local nextLevel = levelIndex + 1
	if Config.Levels[nextLevel] and profile.Unlocked < nextLevel then
		profile.Unlocked = nextLevel
		unlocked = nextLevel
	end
	profile.Stats.Runs += 1
	if levelIndex == #Config.Levels and not profile.RebirthReady then
		profile.RebirthReady = true
		-- A few seconds later, so it lands after the results screen.
		task.delay(6, queueNotice, session, "Every level is clean! Visit the Rebirth Fountain in the lobby to Rebirth.", "Good")
	end

	-- Unlocks and best times are the progress players care most about: write them soon.
	session.NextAutosave = math.min(session.NextAutosave, os.clock() + SAVE_SOON_DELAY)
	DataService.PushMeta(player)
	return firstClear, newBest, unlocked
end

function DataService.IsOffline(): boolean
	-- Resolves instantly except in a published place's Studio session, where the probe takes a moment.
	if not detection.Open then
		waitLatch(detection, PROBE_WAIT)
	end
	return offline
end

-- (Addition) Saves the player's profile right now and yields until done. True only if it was
-- written; always false offline and for temporary profiles. MarketService uses it for receipts.
function DataService.Save(player: Player): boolean
	local session = sessions[player]
	if not session or not session.Profile or not session.CanSave or session.Finalizing then
		return false
	end
	activeJobs += 1
	local ok, saved = pcall(saveSession, session, false, RECEIPT_SAVE_ATTEMPTS)
	activeJobs -= 1
	if not ok then
		warn("[DataService] " .. tostring(saved))
		return false
	end
	if saved then
		session.NextAutosave = os.clock() + AUTOSAVE_INTERVAL
	end
	return saved == true
end

-- (Addition) Server hops. Saves the player right now with a "handoff" lock, just before they are
-- teleported, so the server they arrive in can load them straight away (no waiting for this server
-- to notice they left). Yields until the save is done; false if it couldn't be written (the next
-- server then just waits for the normal release, as before).
function DataService.BeginHandoff(player: Player): boolean
	local session = sessions[player]
	if not session or not session.Profile or not session.CanSave or session.Finalizing then
		return false
	end
	session.Handoff = true
	activeJobs += 1
	local ok, saved = pcall(saveSession, session, false, 2)
	activeJobs -= 1
	return ok and saved == true
end

-- (Addition) The teleport failed and the player is staying: take the save back as a normal lock.
function DataService.CancelHandoff(player: Player)
	local session = sessions[player]
	if not session or not session.Handoff then
		return
	end
	session.Handoff = false
	if session.CanSave and not session.Finalizing then
		task.spawn(track, saveSession, session, false, 2)
	end
end

-- (Addition) True when this player's progress is being persisted: the profile loaded from the
-- DataStore and this server still owns its lock. False offline and for temporary profiles.
function DataService.CanSave(player: Player): boolean
	local session = sessions[player]
	return session ~= nil and session.Profile ~= nil and session.CanSave and not session.Finalizing
end

----------------------------------------------------------------------------------------------------
-- Roblox's policy for paid random items (PolicyService: ArePaidRandomItemsRestricted)
----------------------------------------------------------------------------------------------------
-- Some players (by country / age) may not use paid random item generators: anything random that costs Robux, or an
-- in-game currency that can be bought with Robux. Here that is the rank roll (Gems), egg hatching (Bubbles) and the
-- Treasure Chest packs (Robux). Each player is asked once when they join; DataService.PaidRandomRestricted(player) says
-- the answer (it waits a moment if Roblox has not answered yet; if Roblox cannot answer at all after four tries, paid
-- random items simply stay ON for that player, as you chose). The player
-- attribute PaidRandomRestricted tells the screens, which grey those buttons out. For testing, set the attribute
-- ForcePaidRandomRestricted on a player to true (it can only restrict more, and a player's own screen cannot set it).
do
	local restricted: { [Player]: boolean } = {}
	local function publish(player: Player)
		if player.Parent == Players then
			-- (only a known "restricted" is published: until Roblox answers the screens do not grey anything out)
			player:SetAttribute("PaidRandomRestricted", player:GetAttribute("ForcePaidRandomRestricted") == true or restricted[player] == true)
		end
	end
	local function fetch(player: Player)
		local answer: boolean? = nil
		for attempt = 1, 4 do
			local ok, info = pcall(function()
				return game:GetService("PolicyService"):GetPolicyInfoForPlayerAsync(player)
			end)
			if ok and type(info) == "table" then
				answer = info.ArePaidRandomItemsRestricted == true
				break
			end
			if player.Parent ~= Players then
				return
			end
			if attempt < 4 then
				task.wait(attempt)
			end
		end
		-- (how many of your players Roblox restricts, allows, or could not answer for: Studio Test > Analytics > Features)
		if answer == nil then
			-- Roblox could not say after four tries: paid random items stay on.
			restricted[player] = false
			DataService.Track(player, "policy.unknown")
		else
			restricted[player] = answer
			DataService.Track(player, if answer then "policy.restricted" else "policy.allowed")
		end
		publish(player)
	end
	function DataService.PaidRandomRestricted(player: Player): boolean
		if player:GetAttribute("ForcePaidRandomRestricted") == true then
			return true
		end
		local waited = 0
		while restricted[player] == nil and waited < 10 and player.Parent == Players do
			task.wait(0.1)
			waited += 0.1
		end
		return restricted[player] == true -- (no answer yet after 10 s: not restricted)
	end
	local function watch(player: Player)
		player:GetAttributeChangedSignal("ForcePaidRandomRestricted"):Connect(function()
			publish(player)
		end)
		task.spawn(fetch, player)
	end
	DataService._WatchPaidRandomPolicy = watch -- (for tests)
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		restricted[player] = nil
	end)
end

return DataService
