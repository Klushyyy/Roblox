-- The first minutes (v2.20.0), part 1: the server rules and the "Look around first" path.
--   A  the START CLEANING card shows for a brand-new player, and "Look around first" hides it for good (no auto start)
--   B  QuickStart (server): a party of one on a free pad, dishwasher 1, going in a few seconds
--   C  the first dishwasher is lighter (about 40% of the normal dirt) and sets no best time (par exactly)
--   D  QuickStart is refused for anyone with a finished run, in a party, or in a run
--   E  a party with a veteran in it never gets the light dishwasher
--   F  the light dishwasher is only dishwasher 1
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local LB = M[R .. "ServerScriptService/Server/Services/LobbyBuilder.luau"]
local p, victim = G.player, G.victim

local total, failed = 0, 0
local function check(group, name, ok, detail)
	total += 1
	if not ok then failed += 1 end
	out(string.format("%3d %s %-2s %s%s", total, if ok then "PASS" else "FAIL", group, name, if detail ~= nil then "   [" .. tostring(detail) .. "]" else ""))
end

local tracked: { [string]: number } = {}
local realTrack = DS.Track
DS.Track = function(plr, key, fields)
	tracked[key] = (tracked[key] or 0) + 1
	if realTrack then realTrack(plr, key, fields) end
end

local partyAct = Remotes.Event("PartyAction")
local function act(action, value)
	call("client", function() partyAct:FireServer(action, value) end)
end
local function press(btn)
	G.getSignal(btn, "Activated"):Fire()
end
local function findText(root, text)
	for _, d in root:GetDescendants() do
		if (d.ClassName == "TextButton" or d.ClassName == "TextLabel") and d.Text == text then return d end
	end
end
local function toLobby()
	_G.__side = "server"
	pcall(RS.RemoveFromRun, p, "Test")
	pump(1, G.frame)
end
local function arenaTotal(plr)
	local folder = RS.GetGrimeFolder(plr)
	local model = folder and folder.Parent
	return model and model:GetAttribute("Total") or 0
end
local function startRound(players, level)
	_G.__side = "server"
	call("server", RS.StartRound, players, level)
	pump(1, G.frame)
	return RS.IsInRun(players[1])
end
local function endRound(plr)
	_G.__side = "server"
	call("server", RS.DebugFinish, plr)
	pump(8, G.frame)
	pcall(RS.RemoveFromRun, plr, "Test")
	pump(1, G.frame)
end

local profile = DS.Get(p)
check("A", "the test player is a brand-new player", profile.Stats.Runs == 0 and (profile.An.Runs or 0) == 0, profile.Stats.Runs)
check("A", "the meta the client sees says no runs started", CS.Meta and CS.Meta.RunsStarted == 0, CS.Meta and CS.Meta.RunsStarted)

----------------------------------------------------------------------------------------------------
-- A: the card, and "Look around first"
----------------------------------------------------------------------------------------------------
local pad1 = LB.GetLobby().Pads[1]
p.Character.HumanoidRootPart.CFrame = CFrame.new(pad1.Zone.Position + Vector3.new(60, 0, 40)) -- out in the lobby, away from every pad
pump(1, G.frame)
local card = p.PlayerGui:FindFirstChild("Welcome", true)
check("A", "the card is built", card ~= nil)
-- (the sim has been running in the lobby for a while by now, so the delay is over and the card is up)
check("A", "shown for a brand-new player in the lobby with nothing else open", card.Visible == true)
local startBtn = findText(card, "START CLEANING")
local lookBtn = findText(card, "Look around first")
check("A", "it has the START CLEANING and Look around first buttons", startBtn ~= nil and lookBtn ~= nil)
local count = findText(card, "") -- the countdown label
local sawCountdown = false
for _, d in card:GetDescendants() do
	if d.ClassName == "TextLabel" and string.find(d.Text, "Starts by itself in") then sawCountdown = true end
end
check("A", "it counts down to the automatic start", sawCountdown)
press(lookBtn)
pump(0.5, G.frame)
check("A", "Look around first hides it", card.Visible == false)
pump(Config.FirstRun.AutoStart + 8, G.frame)
check("A", "...and it stays hidden (no automatic start)", card.Visible == false)
check("A", "...nobody was sent into a party", p:GetAttribute("InParty") ~= true and CS.Party == nil)
check("A", "...and no run was started", not RS.IsInRun(p))
check("A", "Look around first never started anything", (tracked["welcome.go"] or 0) == 0)

----------------------------------------------------------------------------------------------------
-- B: QuickStart, server side
----------------------------------------------------------------------------------------------------
act("QuickStart", "button")
pump(0.4, G.frame)
check("B", "QuickStart puts the player in a party", p:GetAttribute("InParty") == true, p:GetAttribute("InParty"))
check("B", "the party is dishwasher 1", CS.Party ~= nil and CS.Party.Level == 1, CS.Party and CS.Party.Level)
check("B", "...for one player", CS.Party ~= nil and CS.Party.MaxPlayers == 1, CS.Party and CS.Party.MaxPlayers)
check("B", "...waiting to go", CS.Party ~= nil and (CS.Party.Status == "Waiting" or CS.Party.Status == "Launching"), CS.Party and CS.Party.Status)
check("B", "welcome.go was tracked, welcome.auto was not", tracked["welcome.go"] == 1 and (tracked["welcome.auto"] or 0) == 0)
local inZone = false
do
	local pos = p.Character.HumanoidRootPart.Position
	for _, pd in LB.GetLobby().Pads do
		if (pd.Zone.Position - pos).Magnitude < (pd.Radius or 9) + 4 then inZone = true end
	end
end
check("B", "the player stands on a pad", inZone)
-- a second press while in the party does nothing more
act("QuickStart", "button")
pump(0.2, G.frame)
check("B", "a second press changes nothing", tracked["welcome.go"] == 1, tracked["welcome.go"])
pump(6, G.frame)
check("B", "a few seconds later they are in a dishwasher", RS.IsInRun(p))

----------------------------------------------------------------------------------------------------
-- C: the lighter dishwasher, and no best time
----------------------------------------------------------------------------------------------------
local easyTotal = arenaTotal(p)
check("C", "run.easy was tracked", tracked["run.easy"] == 1, tracked["run.easy"])
_G.__side = "client"
local rf = Remotes.Function("RunRequest")
call("client", function() return rf:InvokeServer("Loaded") end)
pump(0.5, G.frame)
endRound(p)
profile = DS.Get(p)
check("C", "the run counted (Runs = 1)", profile.Stats.Runs == 1, profile.Stats.Runs)
check("C", "dishwasher 2 unlocked", profile.Unlocked >= 2, profile.Unlocked)
check("C", "the best time is exactly par, not the real (much quicker) time", profile.BestTimes[1] == Config.Levels[1].ParTime, profile.BestTimes[1])

-- a normal run for comparison (Runs is 1 now)
check("C", "a veteran-to-be starts a normal run", startRound({ p }, 1) == true)
local normalTotal = arenaTotal(p)
check("C", "run.easy was NOT tracked again", tracked["run.easy"] == 1, tracked["run.easy"])
local ratio = easyTotal / math.max(1, normalTotal)
check("C", "the first dishwasher has about 40% of the dirt", ratio > 0.25 and ratio < 0.55, string.format("%d vs %d = %.2f", easyTotal, normalTotal, ratio))
check("C", "...but never nothing (every dish still has dirt)", easyTotal >= 40, easyTotal)
endRound(p)

----------------------------------------------------------------------------------------------------
-- D: who may QuickStart
----------------------------------------------------------------------------------------------------
tracked["welcome.go"] = 0
p.Character.HumanoidRootPart.CFrame = CFrame.new(pad1.Zone.Position + Vector3.new(60, 0, 40))
pump(1, G.frame)
act("QuickStart", "button")
pump(0.4, G.frame)
check("D", "someone with a finished run is refused", p:GetAttribute("InParty") ~= true and (tracked["welcome.go"] or 0) == 0, tracked["welcome.go"])
_G.__side = "server"
DS.ResetFirstRun(p)
pump(0.5, G.frame)
profile = DS.Get(p)
check("D", "(reset: Runs = 0 again)", profile.Stats.Runs == 0)
act("QuickStart", "button")
pump(0.4, G.frame)
check("D", "...and now QuickStart works again", p:GetAttribute("InParty") == true and tracked["welcome.go"] == 1)
act("Leave")
pump(0.5, G.frame)
check("D", "(left the party)", p:GetAttribute("InParty") ~= true)
-- junk values never matter
for _, junk in { 5, true, {}, "x", 0/0 } do
	act("QuickStart", junk)
	pump(0.2, G.frame)
	act("Leave")
	pump(0.3, G.frame)
end
check("D", "junk arguments neither crash nor leave a party behind", p:GetAttribute("InParty") ~= true)
-- a player already in a run
_G.__side = "server"
call("server", RS.StartRound, { p }, 1)
pump(1, G.frame)
tracked["welcome.go"] = 0
act("QuickStart", "button")
pump(0.4, G.frame)
check("D", "someone already in a dishwasher is refused", (tracked["welcome.go"] or 0) == 0)
endRound(p)

----------------------------------------------------------------------------------------------------
-- E / F: parties with a veteran, and other levels
----------------------------------------------------------------------------------------------------
_G.__side = "server"
DS.ResetFirstRun(p)
local vprofile = DS.Get(victim)
vprofile.Stats.Runs = 3
check("E", "setup: me new, the other player a veteran", DS.Get(p).Stats.Runs == 0 and vprofile.Stats.Runs == 3)
tracked["run.easy"] = 0
check("E", "a mixed party starts", startRound({ p, victim }, 1) == true)
local mixed = arenaTotal(p)
check("E", "...with the full dirt (not the light dishwasher)", mixed >= normalTotal * 0.9, string.format("%d vs normal solo %d", mixed, normalTotal))
check("E", "...and run.easy was not tracked", (tracked["run.easy"] or 0) == 0)
endRound(p)
pcall(RS.RemoveFromRun, victim, "Test")
pump(1, G.frame)
vprofile.Stats.Runs = 0
DS.ResetFirstRun(p) -- (finishing the mixed run counted as a run for both)
check("E", "two brand-new players together DO get the light dishwasher", startRound({ p, victim }, 1) == true and (tracked["run.easy"] or 0) == 2, tracked["run.easy"])
local twoNew = arenaTotal(p)
check("E", "...lighter than the mixed party", twoNew < mixed * 0.6, string.format("%d vs %d", twoNew, mixed))
endRound(p)
pcall(RS.RemoveFromRun, victim, "Test")
pump(1, G.frame)

DS.ResetFirstRun(p)
tracked["run.easy"] = 0
check("F", "a new player starting dishwasher 2 starts", startRound({ p }, 2) == true)
check("F", "...is not given the light dishwasher", (tracked["run.easy"] or 0) == 0)
endRound(p)

-- Config switch off
Config.FirstRun.Enabled = false
DS.ResetFirstRun(p)
tracked["run.easy"] = 0
startRound({ p }, 1)
check("F", "with Config.FirstRun.Enabled = false the first run is normal", (tracked["run.easy"] or 0) == 0 and arenaTotal(p) >= normalTotal * 0.9, arenaTotal(p))
endRound(p)
Config.FirstRun.Enabled = true

DS.Track = realTrack
out(string.format("== %d CHECKS: %d passed, %d FAILED", total, total - failed, failed))
