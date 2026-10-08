-- Analytics (Analytics.luau + Telemetry.luau) and the Roblox Premium reward:
--   * a joined player has the An block; moments are counted (n:, u:, f:), funnels reach a fake Roblox
--     AnalyticsService (Onboarding once, the Run funnel per attempt), money goes to Economy, the
--     DataStore tally merges across flushes, retention bits fill in, leaving records where they were
--   * the Telemetry remote only accepts the listed moments, and every :analytics report builds
--   * Premium: +10% Bubbles, a daily gift once, the badge in MetaState
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local Analytics = M[R .. "ServerScriptService/Server/Services/Analytics.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local prof = DS.Get(p)
local A = Config.Analytics

local function count(t)
	local n = 0
	for _ in t do
		n += 1
	end
	return n
end

-- A fake AnalyticsService that remembers every call, and a fake DataStore.
local calls = {}
local fakeRoblox = {}
for _, name in { "LogOnboardingFunnelStepEvent", "LogFunnelStepEvent", "LogEconomyEvent", "LogProgressionEvent", "LogCustomEvent" } do
	fakeRoblox[name] = function(_, ...)
		table.insert(calls, { Name = name, Args = table.pack(...) })
	end
end
local stored = {}
local fakeStore = {
	UpdateAsync = function(_, key, fn)
		stored[key] = fn(stored[key])
	end,
	GetAsync = function(_, key)
		return stored[key]
	end,
}
local function called(name)
	local n = 0
	for _, c in calls do
		if c.Name == name then
			n += 1
		end
	end
	return n
end
local function pend(doc, counter)
	local d = Analytics._Pending()[doc]
	return d and d[counter] or 0
end
local day = os.time() // 86400
local daily = "D" .. os.date("!%Y%m%d", day * 86400)
local cohort = "C" .. os.date("!%Y%m%d", day * 86400)

out("-- the player joined: the An block and the join moments")
local an = prof.An
out(string.format("An.First is today: %s  visits=%d  Last>0=%s", tostring(an.First == day), an.Visits, tostring(an.Last > 0)))
out(string.format("pending: n:join=%d u:join=%d cohort f:join=%d n:visit.new=%d", pend(daily, "n:join"), pend(daily, "u:join"), pend(cohort, "f:join"), pend(daily, "n:visit.new")))
out("state exists: " .. tostring(Analytics._State(p) ~= nil))

Analytics.Configure({ Live = true, Roblox = fakeRoblox, Store = fakeStore })

out("-- funnels reach Roblox")
local Track = DS.Track
out("DataService.Track is Analytics.Event: " .. tostring(Track == Analytics.Event))
Track(p, "pad.enter")
Track(p, "pad.enter")
out(string.format("onboarding step calls after pad.enter x2: %d (once)  funnel(Run) calls: %d", called("LogOnboardingFunnelStepEvent"), called("LogFunnelStepEvent")))
local onboard = calls[1]
out(string.format("first onboarding call: step=%s name=%s", tostring(onboard.Args[2]), tostring(onboard.Args[3])))
local attempt = Analytics.AttemptId(p, "Run")
out("Run attempt id set: " .. tostring(attempt ~= nil))
Track(p, "pad.create", { Level = 1, Max = 4 })
Track(p, "run.launch", { Level = 1, Party = 1 })
out("same attempt carried on: " .. tostring(Analytics.AttemptId(p, "Run") == attempt))
Track(p, "run.arrive", { Level = 1, Party = 1 })
Track(p, "run.arrive.1")
out(string.format("progression calls after arrive: %d (Start)", called("LogProgressionEvent")))
Track(p, "run.clear", { Level = 1 })
Track(p, "run.clear.1")
out(string.format("progression calls after clear: %d (Complete)", called("LogProgressionEvent")))
out(string.format("run.n2 recorded after a 2nd arrive: before=%d", pend(daily, "n:run.n2")))
Track(p, "run.arrive", { Level = 1 })
out(string.format("  after=%d  An.Runs=%d", pend(daily, "n:run.n2"), an.Runs))
Track(p, "totally.unknown")
Track(p, "meta.Hatch")
Track(p, "ui.open.Shop")
out(string.format("unknown key dropped: %s  meta.Hatch counted: %d  family 'meta' counted: %d  ui.open.Shop: %d", tostring(pend(daily, "n:totally.unknown") == 0), pend(daily, "n:meta.Hatch"), pend(daily, "n:meta"), pend(daily, "n:ui.open.Shop")))
out(string.format("Feature custom events sent (non-funnel keys, once each): %d", called("LogCustomEvent")))

out("-- unique and first-ever counts")
Track(p, "meta.Hatch")
out(string.format("n:meta.Hatch=%d u:meta.Hatch=%d f:meta.Hatch=%d (2 uses, 1 player, 1 first)", pend(daily, "n:meta.Hatch"), pend(daily, "u:meta.Hatch"), pend(cohort, "f:meta.Hatch")))

out("-- money")
DS.AddBubbles(p, 120, "Daily")
DS.SpendBubbles(p, 50, "Perk:CoinSoap")
DS.AddGems(p, 7, "Chest")
out(string.format("eco:src:Bubbles:Daily=%d eco:snk:Bubbles:Perk:CoinSoap=%d eco:src:Gems:Chest=%d", pend(daily, "eco:src:Bubbles:Daily"), pend(daily, "eco:snk:Bubbles:Perk:CoinSoap"), pend(daily, "eco:src:Gems:Chest")))
out("Roblox economy events before the flush: " .. called("LogEconomyEvent"))
Analytics._FlushEconomy(p)
out("after the flush: " .. called("LogEconomyEvent"))
for _, c in calls do
	if c.Name == "LogEconomyEvent" and c.Args[6] == "Shop" then
		out(string.format("  sink: currency=%s amount=%s balanceAfter>=0=%s type=%s sku=%s", tostring(c.Args[3]), tostring(c.Args[4]), tostring(c.Args[5] >= 0), tostring(c.Args[6]), tostring(c.Args[7])))
	end
end

out("-- menu requests are counted")
local meta = Remotes.Function("MetaRequest")
local r = call("client", function()
	return meta:InvokeServer("ClaimDaily")
end)
pump(0.3, G.frame)
out(string.format("ClaimDaily ok=%s counted n:meta.ClaimDaily=%d", tostring(r and r.Ok), pend(daily, "n:meta.ClaimDaily")))
prof.Bubbles = 0
local r2 = call("client", function()
	return meta:InvokeServer("BuyPerk", "HeadStart")
end)
pump(0.3, G.frame)
out(string.format("BuyPerk with no Bubbles ok=%s (refused ones go to metafail): metafail.BuyPerk=%d meta.BuyPerk=%d", tostring(r2 and r2.Ok), pend(daily, "n:metafail.BuyPerk"), pend(daily, "n:meta.BuyPerk")))

out("-- the screen's moments (Telemetry remote)")
Analytics.Handle(p, {
	{ "client.ready" },
	{ "dev", "Console" }, -- (the real Telemetry already said Desktop: the first answer stands)
	{ "ui.open", "Shop" },
	{ "tut.s2" },
	{ "tut.tour", "3" },
	{ "buy.prompt", "VIP" },
	{ "buy.prompt", "NotAThing" },
	{ "perf.mid", "38" },
	{ "run.clear" }, -- not allowed from a screen
	{ "ctx", "Win:Shop" },
	{ "bogus.key" },
	"nonsense",
})
out(string.format("client.ready=%d dev.Console=%d dev.Desktop=%d ui.open.Shop=%d tut.s2=%d tut.tour.3=%d buy.prompt.VIP=%d buy.prompt.Other=%d perf.mid=%d", pend(daily, "n:client.ready"), pend(daily, "n:dev.Console"), pend(daily, "n:dev.Desktop"), pend(daily, "n:ui.open.Shop"), pend(daily, "n:tut.s2"), pend(daily, "n:tut.tour.3"), pend(daily, "n:buy.prompt.VIP"), pend(daily, "n:buy.prompt.Other"), pend(daily, "n:perf.mid")))
out(string.format("run.clear from a screen refused: n:run.clear stays %d (it was 1 from the server)  bogus=%d", pend(daily, "n:run.clear"), pend(daily, "n:bogus.key")))
out("sub-context set: " .. tostring(Analytics._State(p).Sub))
out("a flood is cut off: ")
local before = pend(daily, "n:ui.open.Pets")
for i = 1, 20 do
	Analytics.Handle(p, { { "ui.open", "Pets" }, { "ui.open", "Eggs" }, { "ui.open", "Daily" }, { "ui.open", "Codes" } })
end
out(string.format("  accepted %d of 80 (limit per 10 s window)", pend(daily, "n:ui.open.Pets") - before + (pend(daily, "n:ui.open.Eggs") + pend(daily, "n:ui.open.Daily") + pend(daily, "n:ui.open.Codes"))))

out("-- details per family are capped")
local capped = 0
for i = 1, A.MaxDetails + 20 do
	Track(p, "club.Act" .. i)
end
for name in Analytics._Pending()[daily] do
	if name:sub(1, 7) == "n:club." then
		capped += 1
	end
end
out(string.format("different club.* details recorded: %d (cap %d, plus the family itself)", capped, A.MaxDetails))

out("-- saving the tally")
local written = Analytics.Flush(true)
out(string.format("documents written: %d  daily doc has join=%s  cohort doc has f:join=%s  pending now empty=%s", written, tostring(stored[daily] and stored[daily]["n:join"]), tostring(stored[cohort] and stored[cohort]["f:join"]), tostring(next(Analytics._Pending()) == nil)))
Track(p, "meta.Hatch")
Analytics.Flush(true)
out(string.format("after a second flush the counts add up: n:meta.Hatch=%s (3 uses in all)", tostring(stored[daily]["n:meta.Hatch"])))

out("-- reports")
for i = 1, #Analytics.ReportNames do
	local title, rows, shown, total = Analytics.BuildReport(i, 7)
	out(string.format("%d/%d %-36s rows=%d first: %s", shown, total, title, #rows, rows[1] and rows[1].Line1 or "-"))
end
local _, onboardingRows = Analytics.BuildReport(2, 7)
out("onboarding funnel rows:")
for i = 1, math.min(#onboardingRows, 9) do
	out("  " .. onboardingRows[i].Line1)
end
local _, wrap, shown2 = Analytics.BuildReport(12, 7)
out("report number wraps around: 12 -> " .. shown2)

out("-- retention and leaving")
local pass1 = DS.Get(p)
Analytics._Leave(p) -- (they left: where were they?)
local leftKeys = {}
for name in Analytics._Pending()[daily] do
	if name:sub(1, 5) == "left:" or name:sub(1, 4) == "len:" or name:sub(1, 3) == "l1:" then
		table.insert(leftKeys, name)
	end
end
for name in Analytics._Pending()[cohort] or {} do
	if name:sub(1, 3) == "l1:" or name:sub(1, 6) == "l1len:" then
		table.insert(leftKeys, "cohort " .. name)
	end
end
table.sort(leftKeys)
out("leave counters: " .. table.concat(leftKeys, " | "))
out("state gone after leaving: " .. tostring(Analytics._State(p) == nil))
-- a player who signed up 3 days ago comes back
an.First, an.Last, an.Visits, an.VisitStart, an.Mask = day - 3, os.time() - 86400 * 2, 2, 0, 0
Analytics._Join(p, pass1)
local oldCohort = "C" .. os.date("!%Y%m%d", (day - 3) * 86400)
out(string.format("came back on day 3: ret.3=%d in the old sign-up group, mask bit set=%s, visit.back=%d", pend(oldCohort, "ret.3"), tostring(bit32.band(an.Mask, bit32.lshift(1, 3)) ~= 0), pend(daily, "n:visit.back")))
Analytics._Leave(p)
Analytics._Join(p, pass1)
out(string.format("joining again straight away is not another return: ret.3 still %d, visits still %d", pend(oldCohort, "ret.3"), an.Visits))

out("-- the Admin Abuse show clock")
Analytics._Join(p, pass1)
local state = Analytics._State(p)
game:GetService("ReplicatedStorage"):SetAttribute("AbuseLive", true)
Analytics._Tick()
out(string.format("show went live: show.join=%d", pend(daily, "n:show.join")))
game:GetService("ReplicatedStorage"):SetAttribute("AbuseLive", nil)
Analytics._Tick()
out(string.format("show ended: show.end=%d", pend(daily, "n:show.end")))

out("-- Roblox Premium")
local Premium = Config.Premium
local stats0 = Config.GetRunStats(1, nil, 1, nil, {}, 0)
local stats1 = Config.GetRunStats(1, nil, 1, nil, { Premium = true }, 0)
out(string.format("coin multiplier x%.2f with Premium (config %.2f)", stats1.CoinMult / stats0.CoinMult, 1 + Premium.CoinBonus))
prof.PremiumDay = ""
local bubbles0, gems0 = prof.Bubbles, prof.Gems
p.MembershipType = Enum.MembershipType.Premium
G.getSignal(p, "prop:MembershipType"):Fire()
pump(0.3, G.frame)
out(string.format("is Premium after joining as one: %s  daily gift: bubbles +%d gems +%d", tostring(DS.GetPasses(p).Premium), prof.Bubbles - bubbles0, prof.Gems - gems0))
local meta2 = G.modules[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"].Meta
out("client sees the badge flag: " .. tostring(meta2 and meta2.Passes and meta2.Passes.Premium))
G.getSignal(p, "prop:MembershipType"):Fire()
pump(0.3, G.frame)
out(string.format("the gift is once a day: bubbles still +%d", prof.Bubbles - bubbles0))
p.MembershipType = Enum.MembershipType.None
G.getSignal(p, "prop:MembershipType"):Fire()
pump(0.3, G.frame)
out("lapsed: Premium flag is " .. tostring(DS.GetPasses(p).Premium))
out("=== DONE")
