--[[
	DailyNotify - "Your daily reward is ready!" Roblox notifications.

	When a player claims their daily reward, they're queued (MemoryStore sorted map, ordered by when
	the next reward is ready). Every server checks the front of the queue each minute; whichever takes
	a due entry first sends it through Open Cloud's user notifications API and removes it. Roblox
	only delivers it to players who turned notifications on (RewardsUI / DailyUI ask them), and
	tapping it joins the game.

	Needs (StoreIds > Notifications explains each step): the notification string's ID, an Open
	Cloud API key saved as the secret Config.DailyNotify.SecretName, and HTTP requests allowed.
	Without them nothing is queued and nothing is sent.
]]

local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DataService = require(script.Parent:WaitForChild("DataService"))

local DailyNotify = {}

local MAP_NAME = "RinseCycle_DailyNotify"
local POLL_EVERY = 60
local BATCH = 20
local CLAIM_SECONDS = 120 -- a taken entry is left alone this long (the sender removes it)

local initialized = false
local queue: MemoryStoreSortedMap? = nil
local warned = false

local function enabled(): boolean
	return Config.DailyNotify.MessageId ~= "" and game.GameId > 0
end

-- Queues this player's "ready" notification for when their next daily reward unlocks.
function DailyNotify.Queue(player: Player)
	local profile = DataService.Get(player)
	if not profile or not enabled() or not queue then
		return
	end
	local due = (profile.DailyLast or os.time()) + Config.Daily.Cooldown
	local streak = (profile.DailyStreak or 0) % #Config.DailyRewards + 1
	profile.DailyNotifyAt = due
	local map = queue :: MemoryStoreSortedMap
	task.spawn(function()
		local ok, err = pcall(function()
			-- Kept until well after it's due (servers may be quiet for a while).
			map:SetAsync(tostring(player.UserId), { Due = due, Streak = streak }, Config.Daily.Cooldown + 2 * 86400, due)
		end)
		if not ok then
			warn("[DailyNotify] couldn't queue: " .. tostring(err))
		end
	end)
end

local function send(userId: number, streak: number): boolean
	local okSecret, secret = pcall(function()
		return HttpService:GetSecret(Config.DailyNotify.SecretName)
	end)
	if not okSecret then
		if not warned then
			warned = true
			warn("[DailyNotify] no API key secret '" .. Config.DailyNotify.SecretName .. "': " .. tostring(secret))
		end
		return false
	end
	local body = HttpService:JSONEncode({
		source = { universe = "universes/" .. tostring(game.GameId) },
		payload = {
			message_id = Config.DailyNotify.MessageId,
			type = "MOMENT",
			parameters = { streak = { string_value = tostring(streak) } },
			join_experience = { launch_data = "daily" },
		},
		analytics_data = { category = "Daily reward" },
	})
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = string.format("https://apis.roblox.com/cloud/v2/users/%d/notifications", userId),
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json", ["x-api-key"] = secret :: any },
			Body = body,
		})
	end)
	if not ok then
		warn("[DailyNotify] request failed: " .. tostring(response))
		return false
	end
	if not response.Success then
		warn(string.format("[DailyNotify] %d %s", response.StatusCode, tostring(response.Body)))
		-- 4xx (not opted in, bad id) won't get better by retrying: drop it.
		return response.StatusCode >= 400 and response.StatusCode < 500
	end
	return true
end

local function poll()
	local map = queue
	if not map or not enabled() then
		return
	end
	local now = os.time()
	local ok, items = pcall(function()
		return map:GetRangeAsync(Enum.SortDirection.Ascending, BATCH, nil, { sortKey = now + 1 })
	end)
	if not ok or type(items) ~= "table" then
		return
	end
	for _, item in items do
		local key = item.key
		local userId = tonumber(key)
		-- Take it (another server may be looking at the same entry).
		local mine = false
		local taken = nil
		pcall(function()
			map:UpdateAsync(key, function(value, sortKey)
				if type(value) ~= "table" or (value.Due or 0) > now then
					return nil
				end
				if value.TakenAt and now - value.TakenAt < CLAIM_SECONDS then
					return nil
				end
				value.TakenAt = now
				mine = true
				taken = value
				return value, sortKey
			end, CLAIM_SECONDS * 2)
		end)
		if mine and userId and taken then
			local value: any = taken
			-- Already in this server: the Daily button's "!" says it; no notification needed.
			local here = Players:GetPlayerByUserId(userId) ~= nil
			local done = here or DailyNotify.Send(userId, tonumber(value.Streak) or 1)
			if done then
				pcall(function()
					map:RemoveAsync(key)
				end)
			end
		end
	end
end

DailyNotify.Send = send

-- Tests: a stand-in queue, and one poll on demand.
function DailyNotify.SetQueueForTests(map: any)
	queue = map
end
DailyNotify.Poll = poll

function DailyNotify.Init()
	if initialized then
		return
	end
	initialized = true
	pcall(function()
		queue = MemoryStoreService:GetSortedMap(MAP_NAME)
	end)
end

function DailyNotify.Start()
	if RunService:IsStudio() then
		return -- no notifications from Studio test sessions
	end
	task.spawn(function()
		while true do
			task.wait(POLL_EVERY + math.random() * 10)
			pcall(poll)
		end
	end)
end

return DailyNotify
