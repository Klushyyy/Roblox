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
-- Awarding: only badges with an Id (the first five get one here, the fifth is switched OFF on Roblox); noted in BadgesGot only
-- once Roblox says the player really has it; never twice.
for i, b in Config.Badges do
	b.Id = if i <= 5 then 1000 + i else 0
end
local B = G.badges
B.awarded, B.owned = {}, {}
B.off[1005] = true
-- (Level 1 is already noted as given, as an older version did without Roblox ever giving it: the first check asks Roblox,
-- finds the player does not own it, clears the note and gives it)
prof.BadgesGot = { Level1 = true }
local p1 = tostring(p.UserId)
BA.Check(p)
pump(1, G.frame)
local got = {}
for k in prof.BadgesGot do
	table.insert(got, k)
end
table.sort(got)
out("awarded (ids for the first 5, the 5th switched off): " .. table.concat(got, " ") .. "  given on Roblox: " .. table.concat(B.awarded, ","))
BA.Check(p)
pump(1, G.frame)
out("given after a 2nd check (no repeats): " .. #B.awarded)

for _ = 1, 3 do
	pump(1, G.frame)
	BA.Check(p)
end
pump(1, G.frame)
out(string.format("healing: Level1 was noted but not owned -> now owned on Roblox: %s, note: %s, given on Roblox: %s", tostring(B.owned[p1 .. ":1002"] == true), tostring(prof.BadgesGot.Level1), table.concat(B.awarded, ",")))

-- The admin audit (:badges): one row per badge, and the earned one that is switched off says why.
local rows = BA.Audit(p)
local lines = {}
for _, r in rows do
	if r.Line1:find("EARNED BUT NOT GIVEN") or r.Line1:find("WAS MISSING") or r.Line1:find("NO ID") then
		table.insert(lines, r.Line1 .. " / " .. r.Line2:sub(1, 60))
	end
end
out("audit rows: " .. #rows .. " (one per badge: " .. #Config.Badges .. ")")
out("audit problems: " .. table.concat(lines, " | "))
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
