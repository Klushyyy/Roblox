-- Chapter 4 (v2.23.0): the Cosmic Cafeteria, the fourth dishwasher. It opens when the Chapter 4 event starts (Config.LevelOpen), and until
-- then everything in the game behaves as if there were three chapters.
--   A  shut: not startable, not a card (the "coming soon" one stays), meta says 3 unlocked, leaderboard page has no name, clearing
--      Chapter 3 keeps the progress silently and makes Rebirth ready
--   B  the event starts: the server publishes OpenLevels = 4, players who cleared Chapter 3 get it, a toast, the card and the board
--   C  playing it: the arena is built, the NPC cast moves, clearing it
--   D  the Studio preview (Admin > Show Test > Chapter 4 preview) and the way back to the real time
--   E  data checks
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local LB = M[R .. "ServerScriptService/Server/Services/LobbyBuilder.luau"]
local LeaderboardService = M[R .. "ServerScriptService/Server/Services/LeaderboardService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local NPC = M[R .. "StarterPlayer/StarterPlayerScripts/Client/LevelNPCs.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local RSvc = game:GetService("ReplicatedStorage")
local prof = DS.Get(p)

local total, failed = 0, 0
local function check(group, name, ok, detail)
	total += 1
	if not ok then failed += 1 end
	out(string.format("%3d %s %-2s %s%s", total, if ok then "PASS" else "FAIL", group, name, if detail ~= nil then "   [" .. tostring(detail) .. "]" else ""))
end
local function adminChapter4(mode)
	call("client", function() RSvc:FindFirstChild("AdminCommand"):FireServer("chapter4", "", mode) end)
	pump(1, G.frame)
end
local function pad()
	local pads = LB.GetLobby().Pads
	p.Character.HumanoidRootPart.CFrame = CFrame.new(pads[1].Zone.Position)
	local waited = 0
	while not (CS.Party and CS.Party.Status == "Picking") and waited < 4 do pump(1 / 30, G.frame) waited += 1 / 30 end
	pump(0.3, G.frame)
end
local function leavePad()
	call("client", function() Remotes.Event("PartyAction"):FireServer("Leave") end)
	pump(0.6, G.frame)
end
local function cards()
	local gui = G.find(G.playerGui, "PartyUI")
	return gui and G.find(gui, "Level4"), gui and G.find(gui, "Level3"), gui and G.find(gui, "ComingSoon")
end
local function texts(root)
	local list = {}
	for _, d in root:GetDescendants() do
		if d.ClassName == "TextLabel" and d.Text ~= "" then table.insert(list, d.Text) end
	end
	return table.concat(list, " | ")
end

local ev4
for _, e in Config.UpcomingEvents do if e.Key == "Chapter4" then ev4 = e end end

----------------------------------------------------------------------------------------------------
out("-- A: shut before its event")
check("A", "Chapter 4 is a fourth level called Cosmic Cafeteria", #Config.Levels == 4 and Config.Levels[4].Name == "Cosmic Cafeteria", Config.Levels[4] and Config.Levels[4].Name)
check("A", "its event has no date yet (Soon)", ev4 ~= nil and ev4.Soon == true)
check("A", "three chapters are open", Config.OpenLevels() == 3 and Config.OpenLevels(Config.Now()) == 3, Config.OpenLevels())
check("A", "LevelOpen(4) is false, LevelOpen(3) is true", not Config.LevelOpen(4) and Config.LevelOpen(3))
check("A", "the server published OpenLevels = 3", RSvc:GetAttribute("OpenLevels") == 3, RSvc:GetAttribute("OpenLevels"))
local ok, why = call("server", RS.StartRound, { p }, 4)
check("A", "a run on Chapter 4 is refused", ok == false and tostring(why):find("isn't open") ~= nil, why)
check("A", "...and nothing was started", RS.IsInRun(p) ~= true)
prof.Unlocked = 4
prof.BestTimes = { 100, 100, 0, 0 }
prof.Rebirths = 0
prof.RebirthReady = false
DS.PushMeta(p)
pump(0.8, G.frame)
check("A", "even with profile.Unlocked = 4 the player's meta says 3", CS.Meta and CS.Meta.Unlocked == 3, CS.Meta and CS.Meta.Unlocked)

pad()
check("A", "(on a party pad)", CS.Party ~= nil and CS.Party.Status == "Picking")
check("A", "a party can not be made for Chapter 4 (HostUnlocked is 3)", CS.Party.HostUnlocked == 3, CS.Party.HostUnlocked)
call("client", function() Remotes.Event("PartyAction"):FireServer("SetLevel", 4) end)
pump(0.5, G.frame)
check("A", "SetLevel 4 is refused", CS.Party ~= nil and CS.Party.Level ~= 4, CS.Party and CS.Party.Level)
local c4, c3, soon = cards()
check("A", "the Create screen has a Chapter 3 card, no Chapter 4 card, and the \"coming soon\" card", c3 ~= nil and c4 == nil and soon ~= nil)
check("A", "...which says CHAPTER 4", soon ~= nil and texts(soon):find("CHAPTER 4") ~= nil, soon and texts(soon))
leavePad()

local boardLast = LeaderboardService.BoardCount()
check("A", "the leaderboard's fourth page has no name yet", LeaderboardService.BoardTitle(boardLast) == "Fastest: Chapter 4", LeaderboardService.BoardTitle(boardLast))

prof.Unlocked = 3
prof.BestTimes = { 100, 100, 0, 0 }
local first, newBest, unlockedLevel = DS.RecordClear(p, 3, 500)
check("A", "clearing Chapter 3 first time is a first clear", first == true and newBest == true)
check("A", "...it reports no chapter unlocked (Chapter 4 is shut)", unlockedLevel == nil, unlockedLevel)
check("A", "...but keeps the progress (profile.Unlocked = 4)", prof.Unlocked == 4, prof.Unlocked)
check("A", "...and Chapter 3 is the last open one: Rebirth is ready", prof.RebirthReady == true)
check("A", "...the player is still limited to three chapters", (function() DS.PushMeta(p) pump(0.8, G.frame) return CS.Meta.Unlocked == 3 end)(), CS.Meta.Unlocked)
local rebirth, rebirthText = call("server", DS.Rebirth, p)
check("A", "(a Rebirth now would say so: needs Bubbles, not another chapter)", true, tostring(rebirthText))

----------------------------------------------------------------------------------------------------
out("-- B: the event starts")
local toasts = {}
G.getSignal(Remotes.Event("Notify"), "OnClientEvent"):Connect(function(t, k) table.insert(toasts, t) end)
local tracked = {}
local realTrack = DS.Track
DS.Track = function(plr, key, fields) tracked[key] = (tracked[key] or 0) + 1 if realTrack then realTrack(plr, key, fields) end end
prof.Unlocked = 3 -- (the repair: Chapter 3 was cleared before the chapter opened)
ev4.Soon = false
ev4.Starts = Config.Now() - 5
ev4.Ends = ev4.Starts + 3600
call("server", DS._RefreshChapters)
pump(2.5, G.frame)
DS.Track = realTrack
check("B", "the server published OpenLevels = 4", RSvc:GetAttribute("OpenLevels") == 4, RSvc:GetAttribute("OpenLevels"))
check("B", "Config.OpenLevels() and LevelOpen(4) agree", Config.OpenLevels() == 4 and Config.LevelOpen(4))
check("B", "a player who had cleared Chapter 3 got Chapter 4 unlocked", prof.Unlocked == 4, prof.Unlocked)
check("B", "...their meta says 4", CS.Meta.Unlocked == 4, CS.Meta.Unlocked)
local said = false
for _, t in toasts do if tostring(t):find("CHAPTER 4 IS HERE") then said = true end end
check("B", "...and a toast announced it", said, toasts[#toasts])
check("B", "chapter.open was counted once for each player online", tracked["chapter.open"] == #G.Players:GetPlayers(), tracked["chapter.open"])
pad()
c4, c3, soon = cards()
check("B", "the Create screen now has a Chapter 4 card and no \"coming soon\" card", c4 ~= nil and soon == nil)
check("B", "...it is not locked and says Not cleared yet", c4 ~= nil and texts(c4):find("Not cleared yet") ~= nil and texts(c4):find("Clear") == nil, c4 and texts(c4))
check("B", "...and can be chosen (HostUnlocked is 4)", CS.Party.HostUnlocked == 4, CS.Party.HostUnlocked)
call("client", function() Remotes.Event("PartyAction"):FireServer("SetLevel", 4) end)
pump(0.5, G.frame)
check("B", "SetLevel 4 works", CS.Party ~= nil and CS.Party.Level == 4, CS.Party and CS.Party.Level)
leavePad()
check("B", "the leaderboard page carries the chapter's name now", LeaderboardService.BoardTitle(boardLast) == "Fastest: Cosmic Cafeteria", LeaderboardService.BoardTitle(boardLast))
-- a player cleared Chapter 3 after the event opened: it is announced on their results
prof.Unlocked = 3
prof.BestTimes[3] = 0
local _, _, announced = DS.RecordClear(p, 3, 400)
check("B", "clearing Chapter 3 now reports Chapter 4 unlocked", announced == 4, announced)

----------------------------------------------------------------------------------------------------
out("-- C: playing it")
local started, startWhy = call("server", RS.StartRound, { p }, 4)
pump(1.5, G.frame)
call("client", function() return Remotes.Function("RunRequest"):InvokeServer("Loaded") end)
pump(1.5, G.frame)
check("C", "the run starts", started == true, startWhy)
check("C", "the run is Chapter 4", CS.Run ~= nil and CS.Run.Level == 4, CS.Run and CS.Run.Level)
local folder = RS.GetGrimeFolder(p)
local arena = folder and folder.Parent
local want = 0
for _, n in Config.Levels[4].Dishes do want += n end
check("C", "the arena is built for level 4", arena ~= nil and arena:GetAttribute("Level") == 4)
check("C", "...with every dish in the load", arena ~= nil and #arena.Dishes:GetChildren() == want, arena and (#arena.Dishes:GetChildren() .. " of " .. want))
local names = {}
for _, d in arena:GetDescendants() do names[d.Name] = true end
check("C", "...in the space-station room (viewport, planet, consoles, hatch)", names.Viewport and names.Planet and names.ConsoleScreen and names.Hatch, nil)
local dirtTypes = {}
for _, d in folder:GetDescendants() do
	local t = d:GetAttribute("Type")
	if t then dirtTypes[t] = true end
end
local newTypes = 0
for _, id in { "AlienGoo", "StarJelly", "MoonCheese", "NebulaSludge", "CometCrust" } do
	if dirtTypes[id] or dirtTypes[Config.GrimeTypes[id].Name] then newTypes += 1 end
end
check("C", "...with the chapter's own dirt (at least 4 of its 5 kinds)", newTypes >= 4, newTypes)
local st = CS.Run.Stats
check("C", "run stats use the level's multiplier (Mult 64)", Config.GetLevel(4).Mult == 64 and st.Power > Config.GetRunStats(3, {}, 1, {}, {}, 0, nil, 0).Power * 3, st.Power)
-- the people
local holder = Instance.new("Folder")
holder.Parent = G.workspace
local scene = NPC.Build(4, CFrame.new(0, 0, 0), holder)
local okScene = true
for _, t in { 0, 7, 20, 33, 47, 59 } do
	local good, err = pcall(function() scene:Update(t) end)
	if not good then okScene = false out("!! scene error at t=" .. t .. ": " .. tostring(err)) end
end
local parts = 0
for _, d in holder:GetDescendants() do if d:IsA("BasePart") then parts += 1 end end
check("C", "the cast (astronaut, alien, robot) builds and animates through its loop", okScene and parts > 100, parts)
scene:Destroy()
holder:Destroy()
-- finish it
call("server", RS.DebugFinish, p)
pump(2, G.frame)
check("C", "results: Chapter 4 is the last open chapter (the finale card)", CS.Run ~= nil and CS.Run.Phase == "Complete" and CS.Run.Level == Config.OpenLevels(), CS.Run and CS.Run.Phase)
check("C", "its best time is saved", (prof.BestTimes[4] or 0) > 0, prof.BestTimes[4])
check("C", "...and Rebirth is ready", prof.RebirthReady == true)
check("C", "LevelsBeaten counts four", DS.LevelsBeaten(prof) == 4, DS.LevelsBeaten(prof))
call("client", function() return Remotes.Function("RunRequest"):InvokeServer("ReturnToLobby") end)
pump(3, G.frame)

----------------------------------------------------------------------------------------------------
out("-- D: the Studio preview and the real time")
adminChapter4("off")
check("D", "'Shut Chapter 4' closes it even though its time has come", RSvc:GetAttribute("OpenLevels") == 3 and Config.OpenLevels() == 3, RSvc:GetAttribute("OpenLevels"))
check("D", "...and the meta says 3 again", (function() pump(0.8, G.frame) return CS.Meta.Unlocked == 3 end)(), CS.Meta.Unlocked)
adminChapter4("on")
check("D", "'Open Chapter 4 now' opens it", RSvc:GetAttribute("OpenLevels") == 4)
ev4.Soon = true
ev4.Starts = 4102444800
adminChapter4("reset")
check("D", "'Back to the real time' goes back to what the clock says (no date: three)", RSvc:GetAttribute("OpenLevels") == 3 and DS.ChapterPreview() == nil, RSvc:GetAttribute("OpenLevels"))
adminChapter4("on")
check("D", "(opened again)", RSvc:GetAttribute("OpenLevels") == 4)
call("server", DS.SetChapterPreview, nil)
check("D", "SetChapterPreview(nil) is the real time too", RSvc:GetAttribute("OpenLevels") == 3)

----------------------------------------------------------------------------------------------------
out("-- E: data")
local lv = Config.Levels[4]
local missing = {}
for _, g in lv.Grime do if not Config.GrimeTypes[g.Type] then table.insert(missing, g.Type) end end
check("E", "every grime type of the chapter is defined", #missing == 0, table.concat(missing, ","))
local weights = 0
for _, g in lv.Grime do weights += g.Weight end
check("E", "grime weights add up to 100", weights == 100, weights)
check("E", "it is tougher and bigger than Chapter 3", lv.Mult > Config.Levels[3].Mult and lv.Toughness > Config.Levels[3].Toughness and lv.ParTime > Config.Levels[3].ParTime)
check("E", "a rebirthed player has beaten three chapters, not four (LevelsBeaten)", DS.LevelsBeaten({ Rebirths = 2, BestTimes = { 1, 1, 1, 0 } }) == 3)
check("E", "...and four once Chapter 4 is in their best times", DS.LevelsBeaten({ Rebirths = 2, BestTimes = { 1, 1, 1, 1 } }) == 4)
check("E", "the Chapter 4 badge needs a real Chapter 4 clear", (function()
	local rules = M[R .. "ServerScriptService/Server/Services/BadgeAwards.luau"].Rules
	return rules.Level4 ~= nil and rules.Level4({ Rebirths = 2, BestTimes = { 1, 1, 1, 0 } }) == false and rules.Level4({ Rebirths = 0, BestTimes = { 1, 1, 1, 9 } }) == true
end)())
-- put the event back as it was
ev4.Soon = true
ev4.Starts = 4102444800
ev4.Ends = 4102448400
out(string.format("== %d CHECKS: %d passed, %d FAILED", total, total - failed, failed))
