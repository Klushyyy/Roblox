-- Badges: each rule against a profile, awards only with an Id, never twice.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local BA = M[R .. "ServerScriptService/Server/Services/BadgeAwards.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local p = G.player
local prof = DS.Get(p)
local function rules()
	local got = {}
	for _, b in Config.Badges do
		if BA.Rules[b.Key](prof) then
			table.insert(got, b.Key)
		end
	end
	return table.concat(got, " ")
end
out("badges: " .. #Config.Badges .. "  fresh profile earns: " .. rules())
prof.BestTimes = { 50, 80 }
prof.Pets = { { Uid = "1", Id = "RubberDuck", Tier = 2 } }
prof.Rank = "" prof.Ranks = {}
for _, r in Config.Ranks do
	if r.Rarity == "Legendary" then
		prof.Ranks = { r.Id }
		break
	end
end
prof.ClubId = "abc"
prof.Stats.DishesCleaned = 1000
out("after progress: " .. rules())
prof.Rebirths = 1
out("after rebirth: " .. rules())
-- Awarding: only badges with an Id; noted in BadgesGot.
for i, b in Config.Badges do
	b.Id = if i <= 3 then 1000 + i else 0
end
local awarded = {}
local bs = game:GetService("BadgeService")
bs.AwardBadge = function(_self, userId, id)
	if userId == p.UserId then
		table.insert(awarded, id)
	end
	return true
end
BA.Check(p)
pump(1, G.frame)
local got = {}
for k in prof.BadgesGot do
	table.insert(got, k)
end
table.sort(got)
out("awarded (ids set for first 3): " .. table.concat(got, " ") .. "  calls: " .. #awarded)
BA.Check(p)
pump(1, G.frame)
out("calls after a 2nd check (no repeats): " .. #awarded .. " " .. table.concat(awarded, ","))
-- Daily claim queues a notification (only with a message id).
Config.DailyNotify.MessageId = "test-id"
pcall(function()
	game.GameId = 123
end)
local DN = M[R .. "ServerScriptService/Server/Services/DailyNotify.luau"]
-- A stand-in MemoryStore sorted map.
local store = {}
local fake = {}
function fake:SetAsync(key, value, _exp, sortKey)
	store[key] = { value = value, sortKey = sortKey }
end
function fake:GetRangeAsync(_dir, count, _lo, hi)
	local list = {}
	for k, e in store do
		if e.sortKey < hi.sortKey then
			table.insert(list, { key = k, value = e.value, sortKey = e.sortKey })
		end
	end
	table.sort(list, function(a, b)
		return a.sortKey < b.sortKey
	end)
	return { table.unpack(list, 1, math.min(count, #list)) }
end
function fake:UpdateAsync(key, fn)
	local e = store[key]
	local v, sk = fn(e and e.value, e and e.sortKey)
	if v ~= nil then
		store[key] = { value = v, sortKey = sk }
	end
end
function fake:RemoveAsync(key)
	store[key] = nil
end
DN.SetQueueForTests(fake)
local sent = {}
DN.Send = function(userId, streak)
	table.insert(sent, userId .. ":day" .. streak)
	return true
end
prof.DailyLast = os.time()
prof.DailyStreak = 3
DN.Queue(p)
pump(0.5, G.frame)
local count = 0
for _ in store do
	count += 1
end
out("queued entries: " .. count)
DN.Poll()
out("poll before due -> sent: " .. #sent)
store["777"] = { value = { Due = os.time() - 5, Streak = 2 }, sortKey = os.time() - 5 }
DN.Poll()
DN.Poll()
out("poll with one due (offline user 777) -> sent: " .. table.concat(sent, ",") .. "  left in queue: " .. (if store["777"] then "yes" else "no"))
out(if prof.DailyNotifyAt > 0 then "notify at +h: " .. string.format("%.1f", (prof.DailyNotifyAt - os.time()) / 3600) else "notify: not queued (the sim has no MemoryStore)")
