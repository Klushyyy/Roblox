-- Lobby leaderboards: "Fastest Clean" (one page per level) and "Top Players" (pages: Most Dishes
-- Cleaned, Most Rebirths, Most Bubbles Collected). Players flip pages with the arrows.
--
--   * OrderedDataStores: RinseCycle_Fastest_L<n> holds best times in tenths of a second (ascending,
--     lower is better); RinseCycle_Dishes / _Rebirths / _Bubbles hold lifetime DishesCleaned,
--     Rebirths and Stats.BubblesEarned (descending). Keys are
--     "u_" .. userId, the same as the profile store.
--   * Every REFRESH_INTERVAL seconds: write the online players' values (times only when they
--     improved, and only values that changed since this server last wrote them), read the top 10
--     of every store, and redraw.
--   * Offline (Studio without API access) the boards rank the players in this server instead.
--   * The Times board draws every level's page; each client shows the page it picked (Effects).
--   * Admin resets (the admin panel's Leaderboards view): a reset takes a player off one board
--     without touching their real stats. For Dishes / Rebirths / Bubbles it stores an offset
--     (RinseCycle_LbResets), so the board only counts what they earn after the reset (2,000 dishes
--     reset, then 2,000 more = 4,000 dishes but 2,000 on the board). For a Fastest board they come
--     back once they beat the time they had when they were reset. Other servers hear about a
--     reset through MessagingService.

local DataStoreService = game:GetService("DataStoreService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Format = require(Shared:WaitForChild("Format"))

local LobbyBuilder = require(script.Parent:WaitForChild("LobbyBuilder"))
local DataService = require(script.Parent:WaitForChild("DataService"))

local LeaderboardService = {}

----------------------------------------------------------------------------------------------------
-- Tunables
----------------------------------------------------------------------------------------------------

local REFRESH_INTERVAL = 60
local OFFLINE_REFRESH_INTERVAL = 10 -- offline boards are free to rebuild, so keep them fresh
local FIRST_REFRESH_DELAY = 6 -- the first WRITE waits for the first players' profiles to load
local TOP_N = 10
local KEY_PREFIX = "u_"
local ROW_HEIGHT = 34

local MEDALS = { "🥇", "🥈", "🥉" }
local ROW_COLORS = {
	Color3.fromRGB(255, 215, 90),
	Color3.fromRGB(220, 230, 240),
	Color3.fromRGB(240, 170, 110),
}

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

type Row = { Name: string, Value: number }

local levelCount = #Config.Levels
local timesTop: { [number]: { Row } } = {}
local timeStores: { [number]: OrderedDataStore } = {}

-- The "Top Players" pages, in page order: what each ranks and how it reads from a profile.
type Stat = { Key: string, Store: string, Title: string, Empty: string, Get: (any) -> number, Top: { Row }, DS: OrderedDataStore?, Written: { [number]: number } }
local STATS: { Stat } = {
	{ Key = "Dishes", Store = "RinseCycle_Dishes", Title = "Most Dishes Cleaned", Empty = "No dishes cleaned yet!", Get = function(p)
		return p.Stats.DishesCleaned or 0
	end, Top = {}, Written = {} },
	{ Key = "Rebirths", Store = "RinseCycle_Rebirths", Title = "Most Rebirths", Empty = "No rebirths yet!", Get = function(p)
		return p.Rebirths or 0
	end, Top = {}, Written = {} },
	{ Key = "Bubbles", Store = "RinseCycle_Bubbles", Title = "Most Bubbles Collected", Empty = "No Bubbles yet!", Get = function(p)
		return p.Stats.BubblesEarned or 0
	end, Top = {}, Written = {} },
}

-- What this server last wrote per user, so unchanged values aren't rewritten every refresh.
local writtenTimes: { [number]: { [number]: number } } = {}
local nameCache: { [number]: string } = {}

-- Admin resets, per user: Stats[statKey] = amount taken off, Times[tostring(level)] = the time
-- (tenths) they have to beat to be listed again.
type Resets = { Stats: { [string]: number }, Times: { [string]: number } }
local RESET_STORE = "RinseCycle_LbResets"
local RESET_TOPIC = "RinseCycle_LbReset"
local resets: { [number]: Resets } = {}
local resetsLoaded: { [number]: boolean } = {}
local resetStore: DataStore? = nil

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local function toTenths(seconds: number): number
	return math.max(1, math.floor(seconds * 10 + 0.5))
end

-- 753 tenths -> "1:15.3"
local function formatTenths(tenths: number): string
	return string.format("%s.%d", Format.Time(tenths // 10), tenths % 10)
end

local function nameFor(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		nameCache[userId] = player.Name
		return player.Name
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	if ok and type(name) == "string" then
		nameCache[userId] = name
		return name
	end
	return "Player " .. tostring(userId)
end

local function emptyResets(): Resets
	return { Stats = {}, Times = {} }
end

local function resetsOf(userId: number): Resets
	local r = resets[userId]
	if not r then
		r = emptyResets()
		resets[userId] = r
	end
	return r
end

local function getResetStore(): DataStore?
	if not resetStore then
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore(RESET_STORE)
		end)
		if ok then
			resetStore = store
		end
	end
	return resetStore
end

local function cleanResets(value: any): Resets
	local r = emptyResets()
	if type(value) == "table" then
		for k, v in (if type(value.Stats) == "table" then value.Stats else {}) do
			if type(k) == "string" and type(v) == "number" then
				r.Stats[k] = v
			end
		end
		for k, v in (if type(value.Times) == "table" then value.Times else {}) do
			if type(v) == "number" then
				r.Times[tostring(k)] = v
			end
		end
	end
	return r
end

-- Reads a player's resets (on join, and when another server reset them). Until this has worked,
-- their values aren't written, so a reset can't be undone by a server that doesn't know about it.
local function loadResets(userId: number)
	if DataService.IsOffline() then
		resetsLoaded[userId] = true
		return
	end
	local store = getResetStore()
	if not store then
		return
	end
	local ok, value = pcall(function()
		return store:GetAsync(KEY_PREFIX .. userId)
	end)
	if ok then
		resets[userId] = cleanResets(value)
		resetsLoaded[userId] = true
	end
end

-- The value a player shows on a stat board: their real total minus any admin reset.
local function boardValue(stat: Stat, profile: any, userId: number): number
	local taken = resetsOf(userId).Stats[stat.Key] or 0
	return math.max(0, math.floor(stat.Get(profile)) - taken)
end

-- May this best time go on the board? (After a reset, only a better time than back then.)
local function timeAllowed(userId: number, level: number, tenths: number): boolean
	local floor = resetsOf(userId).Times[tostring(level)]
	return floor == nil or tenths < floor
end

local function openStores(): boolean
	if STATS[#STATS].DS then
		return true
	end
	local ok = pcall(function()
		for i = 1, levelCount do
			timeStores[i] = DataStoreService:GetOrderedDataStore("RinseCycle_Fastest_L" .. i)
		end
		for _, stat in STATS do
			stat.DS = DataStoreService:GetOrderedDataStore(stat.Store)
		end
	end)
	return ok and STATS[#STATS].DS ~= nil
end

----------------------------------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------------------------------

local function clearList(list: Frame)
	for _, child in list:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
end

local function label(props: { [string]: any }, parent: Instance): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.FredokaOne
	lbl.TextScaled = true
	lbl.TextColor3 = Color3.new(1, 1, 1)
	for k, v in props do
		(lbl :: any)[k] = v
	end
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(10, 30, 60)
	stroke.Parent = lbl
	lbl.Parent = parent
	return lbl
end

local function drawRows(list: Frame, rows: { Row }, valueText: (number) -> string, emptyText: string)
	clearList(list)
	if #rows == 0 then
		label({
			Name = "Empty",
			Size = UDim2.new(1, 0, 0, ROW_HEIGHT * 1.5),
			Text = emptyText,
			TextColor3 = Color3.fromRGB(190, 220, 245),
		}, list)
		return
	end
	for rank, row in rows do
		local frame = Instance.new("Frame")
		frame.Name = "Row" .. rank
		frame.LayoutOrder = rank
		frame.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
		frame.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		frame.BackgroundTransparency = rank % 2 == 1 and 0.9 or 0.95
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = frame

		local color = ROW_COLORS[rank] or Color3.new(1, 1, 1)
		label({
			Name = "Rank",
			Size = UDim2.new(0, 60, 1, -4),
			Position = UDim2.new(0, 4, 0, 2),
			Text = MEDALS[rank] or ("#" .. rank),
			TextColor3 = color,
		}, frame)
		label({
			Name = "Player",
			Size = UDim2.new(1, -230, 1, -4),
			Position = UDim2.new(0, 72, 0, 2),
			Text = row.Name,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, frame)
		label({
			Name = "Value",
			Size = UDim2.new(0, 150, 1, -4),
			Position = UDim2.new(1, -154, 0, 2),
			Text = valueText(row.Value),
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Right,
		}, frame)
		frame.Parent = list
	end
end

local function drawTimes()
	local lobby = LobbyBuilder.GetLobby()
	if not lobby then
		return
	end
	local board = lobby.Boards.Times
	local pages = board.Pages or { { Title = board.Title, List = board.List } }
	for i, page in pages do
		local level = Config.Levels[i]
		if level then
			page.Title.Text = string.format("Fastest: %s", level.Name)
			drawRows(page.List, timesTop[i] or {}, formatTenths, "No clears yet!")
		end
	end
end

local function drawDishes()
	local lobby = LobbyBuilder.GetLobby()
	if not lobby then
		return
	end
	local board = lobby.Boards.Dishes
	local pages = board.Pages or { { Title = board.Title, List = board.List } }
	for i, page in pages do
		local stat = STATS[i]
		if stat then
			page.Title.Text = stat.Title
			drawRows(page.List, stat.Top, Format.Commas, stat.Empty)
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Refresh
----------------------------------------------------------------------------------------------------

-- Offline: rank the players in this server from their in-memory profiles.
local function refreshOffline()
	for i = 1, levelCount do
		local rows: { Row } = {}
		for _, player in Players:GetPlayers() do
			local profile = DataService.Get(player)
			local best = profile and profile.BestTimes[i]
			if best and best > 0 and timeAllowed(player.UserId, i, toTenths(best)) then
				table.insert(rows, { Name = player.Name, Value = toTenths(best) })
			end
		end
		table.sort(rows, function(a, b)
			return a.Value < b.Value
		end)
		timesTop[i] = { table.unpack(rows, 1, math.min(#rows, TOP_N)) }
	end

	for _, stat in STATS do
		local rows: { Row } = {}
		for _, player in Players:GetPlayers() do
			local profile = DataService.Get(player)
			local value = if profile then boardValue(stat, profile, player.UserId) else 0
			if value > 0 then
				table.insert(rows, { Name = player.Name, Value = value })
			end
		end
		table.sort(rows, function(a, b)
			return a.Value > b.Value
		end)
		stat.Top = { table.unpack(rows, 1, math.min(#rows, TOP_N)) }
	end
end

local function writeOnline()
	for _, player in Players:GetPlayers() do
		local profile = DataService.Get(player)
		if not profile then
			continue
		end
		local userId = player.UserId
		local key = KEY_PREFIX .. userId
		if not resetsLoaded[userId] then
			task.spawn(loadResets, userId)
			continue
		end

		local written = writtenTimes[userId] or {}
		writtenTimes[userId] = written
		for i = 1, levelCount do
			local best = profile.BestTimes[i]
			local store = timeStores[i]
			if not best or best <= 0 or not store then
				continue
			end
			local tenths = toTenths(best)
			if written[i] and written[i] <= tenths then
				continue
			end
			if not timeAllowed(userId, i, tenths) then
				continue
			end
			local ok = pcall(function()
				(store :: any):UpdateAsync(key, function(old: any): number?
					if type(old) == "number" and old <= tenths then
						return nil -- the stored time is already as good or better
					end
					return tenths
				end)
			end)
			if ok then
				written[i] = tenths
			end
		end

		for _, stat in STATS do
			local value = boardValue(stat, profile, userId)
			local store = stat.DS
			if value > 0 and stat.Written[userId] ~= value and store then
				local ok = pcall(function()
					store:SetAsync(key, value)
				end)
				if ok then
					stat.Written[userId] = value
				end
			end
		end
	end
end

-- Returns nil if the read failed, so the board keeps its last good rows.
local function readTop(store: OrderedDataStore, ascending: boolean): { Row }?
	local ok, entries = pcall(function()
		local pages = store:GetSortedAsync(ascending, TOP_N)
		return pages:GetCurrentPage()
	end)
	if not ok or type(entries) ~= "table" then
		return nil
	end
	local found: { { UserId: number, Value: number } } = {}
	for _, entry in entries do
		local userId = tonumber((string.match(tostring(entry.key), "^" .. KEY_PREFIX .. "(%d+)$")))
		local value = tonumber(entry.value)
		if userId and value and value > 0 then
			table.insert(found, { UserId = userId, Value = value })
		end
	end
	-- Look every name up at once (each is a web call), not one after another.
	local names: { [number]: string } = {}
	local left = #found
	for i, f in found do
		task.spawn(function()
			names[i] = nameFor(f.UserId)
			left -= 1
		end)
	end
	local deadline = os.clock() + 10
	while left > 0 and os.clock() < deadline do
		task.wait()
	end
	local rows: { Row } = {}
	for i, f in found do
		table.insert(rows, { Name = names[i] or ("Player " .. f.UserId), Value = f.Value })
	end
	return rows
end

-- Reads every board's top 10 (no writes), all boards at once. Also run the moment the server
-- starts, so the boards are filled before anyone looks at them.
local function readAll()
	local left = 0
	local function read(store: OrderedDataStore?, ascending: boolean, apply: ({ Row }) -> ())
		if not store then
			return
		end
		left += 1
		task.spawn(function()
			local rows = readTop(store, ascending)
			if rows then
				apply(rows)
			end
			left -= 1
		end)
	end
	for i = 1, levelCount do
		read(timeStores[i], true, function(rows)
			timesTop[i] = rows
		end)
	end
	for _, stat in STATS do
		read(stat.DS, false, function(rows)
			stat.Top = rows
		end)
	end
	local deadline = os.clock() + 20
	while left > 0 and os.clock() < deadline do
		task.wait()
	end
end

local function refreshOnline()
	writeOnline()
	readAll()
end

----------------------------------------------------------------------------------------------------
-- Admin: view every board, reset a player on one
----------------------------------------------------------------------------------------------------

export type BoardRow = { UserId: number, Name: string, Value: number, Text: string }

-- Board n: 1..#STATS are the Top Players pages, then one Fastest page per level.
function LeaderboardService.BoardCount(): number
	return #STATS + levelCount
end

function LeaderboardService.BoardTitle(index: number): string
	local stat = STATS[index]
	if stat then
		return stat.Title
	end
	local level = Config.Levels[index - #STATS]
	return if level then "Fastest: " .. level.Name else "?"
end

-- Up to `limit` entries of board `index`, best first. Yields (DataStore reads).
function LeaderboardService.ListBoard(index: number, limit: number?): { BoardRow }
	local count = math.clamp(math.floor(limit or 100), 1, 100)
	local stat = STATS[index]
	local level = if stat then nil else index - #STATS
	local rows: { BoardRow } = {}
	local offline = DataService.IsOffline() or not openStores()
	if offline then
		for _, player in Players:GetPlayers() do
			local profile = DataService.Get(player)
			if not profile then
				continue
			end
			if stat then
				local v = boardValue(stat, profile, player.UserId)
				if v > 0 then
					table.insert(rows, { UserId = player.UserId, Name = player.Name, Value = v, Text = Format.Commas(v) })
				end
			elseif level then
				local best = profile.BestTimes[level]
				local tenths = if best and best > 0 then toTenths(best) else nil
				if tenths and timeAllowed(player.UserId, level, tenths) then
					table.insert(rows, { UserId = player.UserId, Name = player.Name, Value = tenths, Text = formatTenths(tenths) })
				end
			end
		end
		table.sort(rows, function(a, b)
			return if stat then a.Value > b.Value else a.Value < b.Value
		end)
		return { table.unpack(rows, 1, math.min(#rows, count)) }
	end
	local store: OrderedDataStore? = if stat then stat.DS elseif level then timeStores[level] else nil
	if not store then
		return rows
	end
	local ok, entries = pcall(function()
		return (store :: OrderedDataStore):GetSortedAsync(stat == nil, count):GetCurrentPage()
	end)
	if not ok or type(entries) ~= "table" then
		return rows
	end
	for _, entry in entries do
		local userId = tonumber((string.match(tostring(entry.key), "^" .. KEY_PREFIX .. "(%d+)$")))
		local value = tonumber(entry.value)
		if userId and value and value > 0 then
			table.insert(rows, {
				UserId = userId,
				Name = nameFor(userId),
				Value = value,
				Text = if stat then Format.Commas(value) else formatTenths(value),
			})
		end
	end
	return rows
end

-- Takes a player off board `index` (they keep their real stats). Yields. Returns (ok, message).
function LeaderboardService.ResetEntry(index: number, userId: number): (boolean, string)
	local stat = STATS[index]
	local level = if stat then nil else index - #STATS
	if not stat and not (level and Config.Levels[level]) then
		return false, "Unknown leaderboard."
	end
	local key = KEY_PREFIX .. userId
	local player = Players:GetPlayerByUserId(userId)
	local profile = player and DataService.Get(player)
	local offline = DataService.IsOffline() or not openStores()
	local store: OrderedDataStore? = if offline then nil elseif stat then stat.DS else timeStores[level :: number]

	-- What they show on the board right now.
	local shown: number? = nil
	if profile then
		if stat then
			shown = boardValue(stat, profile, userId)
		else
			local best = profile.BestTimes[level :: number]
			shown = if best and best > 0 then toTenths(best) else nil
		end
	end
	if store then
		local ok, value = pcall(function()
			return (store :: OrderedDataStore):GetAsync(key)
		end)
		if ok and tonumber(value) then
			local v = tonumber(value) :: number
			shown = if shown == nil then v elseif stat then math.max(shown, v) else math.min(shown, v)
		end
	end

	-- The new reset record: stats move the offset up by what's shown; times remember the time to beat.
	local function apply(r: Resets): Resets
		if stat then
			if profile then
				r.Stats[stat.Key] = math.floor(stat.Get(profile))
			else
				r.Stats[stat.Key] = (r.Stats[stat.Key] or 0) + (shown or 0)
			end
		elseif shown then
			local floor = r.Times[tostring(level)]
			r.Times[tostring(level)] = if floor then math.min(floor, shown) else shown
		end
		return r
	end

	if offline then
		resets[userId] = apply(resetsOf(userId))
		resetsLoaded[userId] = true
	else
		local rs = getResetStore()
		if not rs then
			return false, "Couldn't reach the leaderboard save."
		end
		local newResets: Resets? = nil
		local ok, err = pcall(function()
			(rs :: DataStore):UpdateAsync(key, function(old)
				newResets = apply(cleanResets(old))
				return newResets
			end)
		end)
		if not ok or not newResets then
			return false, "Couldn't save the reset: " .. tostring(err)
		end
		resets[userId] = newResets :: Resets
		resetsLoaded[userId] = true
		if store then
			pcall(function()
				(store :: OrderedDataStore):RemoveAsync(key)
			end)
		end
		task.spawn(function()
			pcall(function()
				MessagingService:PublishAsync(RESET_TOPIC, { UserId = userId })
			end)
		end)
	end

	-- Forget what this server wrote for them, and take them off the boards on screen now.
	if stat then
		stat.Written[userId] = nil
		local name = nameFor(userId)
		for i = #stat.Top, 1, -1 do
			if stat.Top[i].Name == name then
				table.remove(stat.Top, i)
			end
		end
	else
		local w = writtenTimes[userId]
		if w then
			w[level :: number] = nil
		end
		local top = timesTop[level :: number] or {}
		local name = nameFor(userId)
		for i = #top, 1, -1 do
			if top[i].Name == name then
				table.remove(top, i)
			end
		end
	end
	pcall(drawTimes)
	pcall(drawDishes)
	return true, string.format("Reset %s on %s", nameFor(userId), LeaderboardService.BoardTitle(index))
end

----------------------------------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------------------------------

function LeaderboardService.Init()
	for i = 1, levelCount do
		timesTop[i] = {}
	end
	Players.PlayerAdded:Connect(function(player)
		loadResets(player.UserId)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(loadResets, player.UserId)
	end
	Players.PlayerRemoving:Connect(function(player)
		resets[player.UserId] = nil
		resetsLoaded[player.UserId] = nil
	end)
	-- Another server reset someone: re-read their resets and forget what we wrote for them.
	task.spawn(function()
		pcall(function()
			MessagingService:SubscribeAsync(RESET_TOPIC, function(message)
				local data = message.Data
				local userId = type(data) == "table" and tonumber(data.UserId)
				if not userId then
					return
				end
				for _, stat in STATS do
					stat.Written[userId] = nil
				end
				writtenTimes[userId] = nil
				if Players:GetPlayerByUserId(userId) then
					resetsLoaded[userId] = nil
					loadResets(userId)
				end
			end)
		end)
	end)
end

function LeaderboardService.Start()
	if not LobbyBuilder.GetLobby() then
		warn(string.format("[%s] LeaderboardService: no lobby, boards disabled", Config.GameName))
		return
	end
	drawTimes()
	drawDishes()

	task.spawn(function()
		-- Straight away: show what's already on the boards (reads only, in parallel per board).
		if not DataService.IsOffline() and openStores() then
			pcall(readAll)
			drawTimes()
			drawDishes()
		end
		task.wait(FIRST_REFRESH_DELAY)
		while true do
			local offline = DataService.IsOffline() or not openStores()
			local ok, err = pcall(if offline then refreshOffline else refreshOnline)
			if not ok then
				warn(string.format("[%s] LeaderboardService refresh failed: %s", Config.GameName, tostring(err)))
			end
			drawTimes()
			drawDishes()
			task.wait(if offline then OFFLINE_REFRESH_INTERVAL else REFRESH_INTERVAL)
		end
	end)
end

return LeaderboardService
