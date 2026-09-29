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

local DataStoreService = game:GetService("DataStoreService")
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

local REFRESH_INTERVAL = 120
local OFFLINE_REFRESH_INTERVAL = 10 -- offline boards are free to rebuild, so keep them fresh
local FIRST_REFRESH_DELAY = 8 -- give the first players' profiles a moment to load
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
type Stat = { Store: string, Title: string, Empty: string, Get: (any) -> number, Top: { Row }, DS: OrderedDataStore?, Written: { [number]: number } }
local STATS: { Stat } = {
	{ Store = "RinseCycle_Dishes", Title = "Most Dishes Cleaned", Empty = "No dishes cleaned yet!", Get = function(p)
		return p.Stats.DishesCleaned or 0
	end, Top = {}, Written = {} },
	{ Store = "RinseCycle_Rebirths", Title = "Most Rebirths", Empty = "No rebirths yet!", Get = function(p)
		return p.Rebirths or 0
	end, Top = {}, Written = {} },
	{ Store = "RinseCycle_Bubbles", Title = "Most Bubbles Collected", Empty = "No Bubbles yet!", Get = function(p)
		return p.Stats.BubblesEarned or 0
	end, Top = {}, Written = {} },
}

-- What this server last wrote per user, so unchanged values aren't rewritten every refresh.
local writtenTimes: { [number]: { [number]: number } } = {}
local nameCache: { [number]: string } = {}

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
			if best and best > 0 then
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
			local value = if profile then math.floor(stat.Get(profile)) else 0
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
			local value = math.floor(stat.Get(profile))
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
	local rows: { Row } = {}
	for _, entry in entries do
		local userId = tonumber((string.match(tostring(entry.key), "^" .. KEY_PREFIX .. "(%d+)$")))
		local value = tonumber(entry.value)
		if userId and value and value > 0 then
			table.insert(rows, { Name = nameFor(userId), Value = value })
		end
	end
	return rows
end

local function refreshOnline()
	writeOnline()
	for i = 1, levelCount do
		local store = timeStores[i]
		local rows = store and readTop(store, true)
		if rows then
			timesTop[i] = rows
		end
	end
	for _, stat in STATS do
		local rows = stat.DS and readTop(stat.DS, false)
		if rows then
			stat.Top = rows
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------------------------------

function LeaderboardService.Init()
	for i = 1, levelCount do
		timesTop[i] = {}
	end
end

function LeaderboardService.Start()
	if not LobbyBuilder.GetLobby() then
		warn(string.format("[%s] LeaderboardService: no lobby, boards disabled", Config.GameName))
		return
	end
	drawTimes()
	drawDishes()

	task.spawn(function()
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
