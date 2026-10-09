-- 100+ checks that a player Roblox does NOT restrict is never restricted (and that a restricted one is, exactly):
--   A  the policy lookup: every shape of answer, every kind of failure, slow answers, players who leave   (fake players)
--   B  the test switch ForcePaidRandomRestricted: only a real `true` restricts
--   C  the gates (rank roll, hatch, chest) and everything else the shop does, for both kinds of player
--   D  the screens (Ranks, Eggs): normal, restricted, and back
--   E  one player's state never touches another's; leaving and rejoining start fresh
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local p, victim = G.player, G.victim

local total, failed = 0, 0
local function check(group, name, ok, detail)
	total += 1
	if not ok then failed += 1 end
	out(string.format("%3d %s %-2s %s%s", total, if ok then "PASS" else "FAIL", group, name, if detail ~= nil then "   [" .. tostring(detail) .. "]" else ""))
end

----------------------------------------------------------------------------------------------------
-- A: the policy lookup, with a PolicyService we control
----------------------------------------------------------------------------------------------------
local policy = game:GetService("PolicyService")
local behavior: { [number]: (number) -> any } = {}
local asks: { [number]: number } = {}
policy.GetPolicyInfoForPlayerAsync = function(_, plr)
	local id = plr.UserId
	asks[id] = (asks[id] or 0) + 1
	local fn = behavior[id]
	if not fn then error("no behaviour for " .. tostring(id)) end
	return fn(asks[id], plr)
end
local tracked: { [any]: string } = {}
local realTrack = DS.Track
DS.Track = function(plr, key) tracked[plr] = key end

local function info(v) return { ArePaidRandomItemsRestricted = v, AreAdsAllowed = true, IsContentSharingAllowed = true } end
local function failN(n, after) -- fails n times, then answers `after`
	return function(attempt) if attempt <= n then error("HTTP 500") end return after end
end
-- name, behaviour, restricted?, number of asks, the analytics key (nil = none recorded: the player left)
local cases = {
	{ "answer false", function() return info(false) end, false, 1, "policy.allowed" },
	{ "answer true", function() return info(true) end, true, 1, "policy.restricted" },
	{ "key missing", function() return {} end, false, 1, "policy.allowed" },
	{ "other keys true, ours false", function() return { ArePaidRandomItemsRestricted = false, IsPaidItemTradingAllowed = true, AreAdsAllowed = true } end, false, 1, "policy.allowed" },
	{ "other keys true, ours true", function() return { ArePaidRandomItemsRestricted = true, IsPaidItemTradingAllowed = true } end, true, 1, "policy.restricted" },
	{ "string 'true' never restricts", function() return { ArePaidRandomItemsRestricted = "true" } end, false, 1, "policy.allowed" },
	{ "number 1 never restricts", function() return { ArePaidRandomItemsRestricted = 1 } end, false, 1, "policy.allowed" },
	{ "table value never restricts", function() return { ArePaidRandomItemsRestricted = {} } end, false, 1, "policy.allowed" },
	{ "returns nil (4 tries)", function() return nil end, false, 4, "policy.unknown" },
	{ "returns false (4 tries)", function() return false end, false, 4, "policy.unknown" },
	{ "returns a string (4 tries)", function() return "oops" end, false, 4, "policy.unknown" },
	{ "returns a number (4 tries)", function() return 5 end, false, 4, "policy.unknown" },
	{ "errors every time", function() error("PolicyService is down") end, false, 4, "policy.unknown" },
	{ "rate limited every time", function() error("GetPolicyInfoForPlayerAsync is called too many times") end, false, 4, "policy.unknown" },
	{ "fails once, then false", failN(1, info(false)), false, 2, "policy.allowed" },
	{ "fails once, then true", failN(1, info(true)), true, 2, "policy.restricted" },
	{ "fails twice, then false", failN(2, info(false)), false, 3, "policy.allowed" },
	{ "fails twice, then true", failN(2, info(true)), true, 3, "policy.restricted" },
	{ "fails 3 times, then false", failN(3, info(false)), false, 4, "policy.allowed" },
	{ "fails 3 times, then true", failN(3, info(true)), true, 4, "policy.restricted" },
	{ "nil once, then false", function(a) if a == 1 then return nil end return info(false) end, false, 2, "policy.allowed" },
	{ "slow (2 s) then false", function() task.wait(2) return info(false) end, false, 1, "policy.allowed" },
	{ "slow (3 s) then true", function() task.wait(3) return info(true) end, true, 1, "policy.restricted" },
}
local fakes = {}
for i, case in cases do
	local fake = Instance.new("Player")
	fake.Name = "Fake" .. i
	fake.UserId = 7000 + i
	behavior[fake.UserId] = case[2]
	fake.Parent = Players
	fakes[i] = fake
end
-- one who leaves in the middle of the lookup
local leaver = Instance.new("Player")
leaver.Name = "Leaver"
leaver.UserId = 7999
behavior[7999] = function() leaver.Parent = nil error("gone") end
leaver.Parent = Players
for _, fake in fakes do DS._WatchPaidRandomPolicy(fake) end
DS._WatchPaidRandomPolicy(leaver)
pump(14, G.frame)
for i, case in cases do
	local fake = fakes[i]
	local want = case[3]
	check("A", case[1] .. ": restricted = " .. tostring(want), DS.PaidRandomRestricted(fake) == want, DS.PaidRandomRestricted(fake))
	check("A", case[1] .. ": screens told " .. tostring(want), fake:GetAttribute("PaidRandomRestricted") == want, fake:GetAttribute("PaidRandomRestricted"))
	check("A", case[1] .. ": asked " .. case[4] .. "x", asks[fake.UserId] == case[4], asks[fake.UserId])
	check("A", case[1] .. ": counted as " .. tostring(case[5]), tracked[fake] == case[5], tracked[fake])
end
check("A", "leaver: not restricted", DS.PaidRandomRestricted(leaver) == false)
check("A", "leaver: nothing published", leaver:GetAttribute("PaidRandomRestricted") == nil)
check("A", "leaver: nothing counted", tracked[leaver] == nil)
check("A", "leaver: asked once (the lookup stopped)", asks[7999] == 1, asks[7999])

----------------------------------------------------------------------------------------------------
-- B: the test switch
----------------------------------------------------------------------------------------------------
local allowedFake, restrictedFake = fakes[1], fakes[2]
for _, value in { false, "true", 1, "yes", "restricted", 0 } do
	allowedFake:SetAttribute("ForcePaidRandomRestricted", value)
	pump(0.2, G.frame)
	check("B", "an allowed player with Force = " .. tostring(value) .. " is not restricted", DS.PaidRandomRestricted(allowedFake) == false and allowedFake:GetAttribute("PaidRandomRestricted") == false)
end
allowedFake:SetAttribute("ForcePaidRandomRestricted", true)
pump(0.2, G.frame)
check("B", "Force = true restricts an allowed player", DS.PaidRandomRestricted(allowedFake) == true and allowedFake:GetAttribute("PaidRandomRestricted") == true)
allowedFake:SetAttribute("ForcePaidRandomRestricted", nil)
pump(0.2, G.frame)
check("B", "Force cleared: allowed again", DS.PaidRandomRestricted(allowedFake) == false and allowedFake:GetAttribute("PaidRandomRestricted") == false)
for _, value in { false, nil } do
	restrictedFake:SetAttribute("ForcePaidRandomRestricted", value)
	pump(0.2, G.frame)
	check("B", "Roblox's 'restricted' is not lifted by Force = " .. tostring(value), DS.PaidRandomRestricted(restrictedFake) == true and restrictedFake:GetAttribute("PaidRandomRestricted") == true)
end

----------------------------------------------------------------------------------------------------
-- C: the gates, for the real player
----------------------------------------------------------------------------------------------------
local prof = DS.Get(p)
prof.Gems, prof.Bubbles = 5000, 1000000
DS.PushMeta(p)
pump(1, G.frame)
local function meta(action, value) return call("client", function() return CS.MetaRequest(action, value) end) end
local function chest(action, value) return call("client", function() return Remotes.Function("ChestRequest"):InvokeServer(action, value) end) end
local function restrictedText(r) return string.find(tostring(r and r.Error or ""), "restricted", 1, true) ~= nil end
check("C", "the real player starts not restricted", DS.PaidRandomRestricted(p) == false and p:GetAttribute("PaidRandomRestricted") ~= true, p:GetAttribute("PaidRandomRestricted"))
-- ten rank rolls in a row: each works, each costs exactly the roll price
local start = prof.Gems
local rollsOk = 0
for i = 1, 10 do
	local r = meta("RollRank")
	if r.Ok then rollsOk += 1 end
	pump(7, G.frame)
end
check("C", "ten rank rolls all work for an unrestricted player", rollsOk == 10, rollsOk)
check("C", "ten rolls cost exactly 10 x the price", start - prof.Gems == 10 * Config.RankRoll.Cost, start - prof.Gems)
check("C", "a rolled rank is kept", prof.Rank ~= nil and #prof.Ranks >= 1)
local petsBefore, bubblesBefore = #prof.Pets, prof.Bubbles
local h1 = meta("Hatch", { Egg = "Bubble", Count = 1 })
pump(1, G.frame)
check("C", "hatching 1 egg works", h1.Ok == true, h1.Error)
check("C", "hatching 1 egg gave a pet", #prof.Pets == petsBefore + 1, #prof.Pets - petsBefore)
local h3 = meta("Hatch", { Egg = "Bubble", Count = 3 })
pump(1, G.frame)
check("C", "hatching 3 eggs works", h3.Ok == true, h3.Error)
check("C", "hatching 3 eggs gave 3 pets", #prof.Pets == petsBefore + 4, #prof.Pets - petsBefore)
check("C", "eggs cost Bubbles", prof.Bubbles < bubblesBefore)
pump(1, G.frame)
local f1 = chest("Free")
check("C", "the free chest is not blocked", not restrictedText(f1), f1 and f1.Error)
pump(1, G.frame)
local t1 = chest("Test", Config.ChestEvent.Packs[1].Count)
check("C", "a chest pack is not blocked by the policy", not restrictedText(t1), t1 and t1.Error)
-- the other things the shop does are never touched by the policy, for either kind of player
local others = {
	{ "EquipBest" }, { "SetPetsResting", true }, { "ClaimDaily" }, { "RedeemCode", "ZZZNOTACODE" }, { "BuyPerk", "Nope" }, { "Merge", { "a", "b", "c" } }, { "Delete", "nothing" },
}
for _, o in others do
	pump(0.7, G.frame)
	local r = meta(o[1], o[2])
	check("C", o[1] .. " is not blocked by the policy (unrestricted)", not restrictedText(r), r and r.Error)
end

-- now restricted (the Studio Test button)
local function paidtest(mode)
	call("client", function() RS:FindFirstChild("AdminCommand"):FireServer("paidtest", "", mode) end)
	pump(1, G.frame)
end
prof.Gems, prof.Bubbles = 5000, 1000000
local gems0, bub0, pets0, ranks0 = prof.Gems, prof.Bubbles, #prof.Pets, #prof.Ranks
paidtest("on")
check("C", "the test button restricts the real player", DS.PaidRandomRestricted(p) == true and p:GetAttribute("PaidRandomRestricted") == true)
local r1, r2 = meta("RollRank"), meta("Hatch", { Egg = "Bubble", Count = 1 })
check("C", "restricted: the rank roll says the account is currently restricted", r1.Ok == false and string.find(tostring(r1.Error), "currently restricted", 1, true) ~= nil, r1.Error)
check("C", "restricted: hatching says the account is currently restricted", r2.Ok == false and string.find(tostring(r2.Error), "currently restricted", 1, true) ~= nil, r2.Error)
check("C", "restricted: nothing spent, nothing given", prof.Gems == gems0 and prof.Bubbles == bub0 and #prof.Pets == pets0 and #prof.Ranks == ranks0)
pump(1, G.frame)
local t2 = chest("Test", Config.ChestEvent.Packs[1].Count)
check("C", "restricted: a chest pack says the account is currently restricted", t2.Ok == false and string.find(tostring(t2.Error), "currently restricted", 1, true) ~= nil, t2.Error)
pump(1, G.frame)
local f2 = chest("Free")
check("C", "restricted: the free chest still works", not restrictedText(f2), f2 and f2.Error)
for _, o in others do
	pump(0.7, G.frame)
	local r = meta(o[1], o[2])
	check("C", o[1] .. " is not blocked by the policy (restricted)", not restrictedText(r), r and r.Error)
end

----------------------------------------------------------------------------------------------------
-- D: the screens
----------------------------------------------------------------------------------------------------
local function find(root, className, text)
	for _, d in root:GetDescendants() do
		if d:IsA(className) and tostring(d.Text):find(text) then return d end
	end
end
call("client", function() UIKit.OpenWindow("Ranks") end)
pump(0.8, G.frame)
local rollBtn = find(p.PlayerGui, "TextButton", "ROLL") or find(p.PlayerGui, "TextButton", "RESTRICTED")
check("D", "restricted: the Roll button says the account is restricted", rollBtn ~= nil and string.find(rollBtn.Text, "RESTRICTED", 1, true) ~= nil, rollBtn and rollBtn.Text)
paidtest("off")
check("D", "back to normal: the open Roll button costs Gems again", rollBtn ~= nil and string.find(rollBtn.Text, "Gems", 1, true) ~= nil, rollBtn and rollBtn.Text)
for _, value in { false, nil } do
	p:SetAttribute("PaidRandomRestricted", value)
	pump(0.3, G.frame)
	check("D", "attribute = " .. tostring(value) .. ": the Roll button is normal", string.find(rollBtn.Text, "Gems", 1, true) ~= nil, rollBtn.Text)
end
-- a click on the normal button really rolls
prof.Gems = 500
DS.PushMeta(p)
pump(1, G.frame)
local before = prof.Gems
G.getSignal(rollBtn, "Activated"):Fire()
pump(8, G.frame)
check("D", "clicking the normal Roll button rolls (Gems spent)", before - prof.Gems == Config.RankRoll.Cost, before - prof.Gems)
call("client", function() UIKit.CloseWindow() end)
call("client", function() UIKit.OpenWindow("Eggs") end)
pump(0.8, G.frame)
local pets1 = #prof.Pets
local hatchBtn = find(G.find(p.PlayerGui, "PetsUI"), "TextButton", "^Hatch 1")
check("D", "normal: the Hatch 1 button shows the price", hatchBtn ~= nil, hatchBtn and hatchBtn.Text)
check("D", "normal: the Hatch 1 button is not disabled", hatchBtn ~= nil and hatchBtn:GetAttribute("Disabled") ~= true)
if hatchBtn then
	G.getSignal(hatchBtn, "Activated"):Fire()
	pump(6, G.frame)
end
check("D", "clicking the normal Hatch button hatches", #prof.Pets == pets1 + 1, #prof.Pets - pets1)
paidtest("on")
local restrictedBtn = find(G.find(p.PlayerGui, "PetsUI"), "TextButton", "Account restricted")
check("D", "restricted: the Hatch button says the account is restricted", restrictedBtn ~= nil, restrictedBtn and restrictedBtn.Text)
paidtest("off")
local backBtn = find(G.find(p.PlayerGui, "PetsUI"), "TextButton", "^Hatch 1")
check("D", "back to normal: the Hatch button is back", backBtn ~= nil and backBtn:GetAttribute("Disabled") ~= true, backBtn and backBtn.Text)
call("client", function() UIKit.CloseWindow() end)

----------------------------------------------------------------------------------------------------
-- E: players do not affect each other; leaving and rejoining start fresh
----------------------------------------------------------------------------------------------------
local vprof = DS.Get(victim)
vprof.Gems = 300
paidtest("on") -- the real player is restricted ...
local function vmeta(action, value)
	return call("server", function() return rawget(Remotes.Function("MetaRequest"), "__p").OnServerInvoke(victim, action, value) end)
end
check("E", "while the real player is restricted, the victim is not", DS.PaidRandomRestricted(victim) == false and victim:GetAttribute("PaidRandomRestricted") ~= true, victim:GetAttribute("PaidRandomRestricted"))
local vg = vprof.Gems
local vr = vmeta("RollRank")
check("E", "... and the victim can still roll", vr and vr.Ok == true, vr and vr.Error)
check("E", "... and pays the normal price", vg - vprof.Gems == Config.RankRoll.Cost, vg - vprof.Gems)
paidtest("off")
check("E", "the restricted fake does not restrict the victim", DS.PaidRandomRestricted(victim) == false)
check("E", "the restricted fake does not restrict the real player", DS.PaidRandomRestricted(p) == false)
-- a restricted player leaves; a new player with the same id is asked fresh
local gone = fakes[2]
G.getSignal(Players, "PlayerRemoving"):Fire(gone)
gone.Parent = nil
pump(0.5, G.frame)
check("E", "a player who left has no state any more", DS.PaidRandomRestricted(gone) == false)
local again = Instance.new("Player")
again.Name = "Rejoined"
again.UserId = gone.UserId
behavior[again.UserId] = function() return info(false) end
asks[again.UserId] = 0
again.Parent = Players
DS._WatchPaidRandomPolicy(again)
pump(1, G.frame)
check("E", "the same account rejoining is asked again and is allowed this time", DS.PaidRandomRestricted(again) == false and again:GetAttribute("PaidRandomRestricted") == false)
-- two lookups for one player: the last answer stands, an allowed player stays allowed
local twice = Instance.new("Player")
twice.Name = "Twice"
twice.UserId = 7800
behavior[7800] = function() return info(false) end
twice.Parent = Players
DS._WatchPaidRandomPolicy(twice)
DS._WatchPaidRandomPolicy(twice)
pump(1, G.frame)
check("E", "two lookups for an allowed player leave them allowed", DS.PaidRandomRestricted(twice) == false)
-- an answer still pending: a request waits for it, then goes ahead
local slow = Instance.new("Player")
slow.Name = "Slow"
slow.UserId = 7801
behavior[7801] = function() task.wait(4) return info(false) end
slow.Parent = Players
DS._WatchPaidRandomPolicy(slow)
local answered
task.spawn(function() answered = DS.PaidRandomRestricted(slow) end)
pump(6, G.frame)
check("E", "a request waits for a slow answer and then goes ahead (not restricted)", answered == false, answered)
-- an answer that never comes: the request goes ahead after 10 s
local never = Instance.new("Player")
never.Name = "Never"
never.UserId = 7802
behavior[7802] = function() task.wait(60) return info(true) end
never.Parent = Players
DS._WatchPaidRandomPolicy(never)
local waitedAnswer
task.spawn(function() waitedAnswer = DS.PaidRandomRestricted(never) end)
pump(12, G.frame)
check("E", "no answer after 10 s: the request goes ahead (not restricted)", waitedAnswer == false, waitedAnswer)

DS.Track = realTrack
out(string.format("== %d CHECKS: %d passed, %d FAILED", total, total - failed, failed))
