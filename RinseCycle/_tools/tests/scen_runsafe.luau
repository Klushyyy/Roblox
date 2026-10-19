-- v2.21.0 hotfix: a party's run server must not throw its players out of the dishwasher.
-- Every server that starts after the Admin Abuse date runs the "show is over" branch once; that used to put the whole lobby
-- back (and sweep everybody below the lobby floor to the lobby spawn), and the dishwashers are 2,500 studs below the floor.
--   A  a server that starts after the show: the player stays in the arena
--   B  the sweep itself leaves a player who is in a run alone, and still catches somebody who really fell
--   C  the pad's Create screen starts on Chapter 1
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local LB = M[R .. "ServerScriptService/Server/Services/LobbyBuilder.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player

local total, failed = 0, 0
local function check(group, name, ok, detail)
	total += 1
	if not ok then failed += 1 end
	out(string.format("%3d %s %-2s %s%s", total, if ok then "PASS" else "FAIL", group, name, if detail ~= nil then "   [" .. tostring(detail) .. "]" else ""))
end
local function rootY() return p.Character.HumanoidRootPart.Position.Y end

_G.__side = "server"
call("server", RS.StartRound, { p }, 1)
pump(1.5, G.frame)
check("A", "the player is in a dishwasher far below the lobby floor", p:GetAttribute("InRun") == true and rootY() < -1000, rootY())
local before = p.Character.HumanoidRootPart.Position

-- the show's date is long past, in a server that has just started
local abuse
for _, e in Config.UpcomingEvents do if e.Key == "AdminAbuse" then abuse = e end end
local realNow = Config.Now
Config.Now = function() return abuse.Starts + Config.AbuseShow.ShowSeconds + 3 * 86400 end
pump(8, G.frame) -- (the show loop looks every second; the end-of-show check runs 3 seconds after)
check("A", "a server started after the show leaves the player where they are", (p.Character.HumanoidRootPart.Position - before).Magnitude < 5 and rootY() < -1000, rootY())
check("A", "...and they are still in the run", RS.IsInRun(p) == true)
Config.Now = realNow

-- D: and if anything ever DOES move a player up to the lobby spawn mid-run, the server puts them back
local tracked = {}
local realTrack = DS.Track
DS.Track = function(plr, key, fields) tracked[key] = (tracked[key] or 0) + 1 if realTrack then realTrack(plr, key, fields) end end
local arenaPos = p.Character.HumanoidRootPart.Position
local lobbySpawn = LB.GetSpawnCFrame().Position
p.Character.HumanoidRootPart.CFrame = CFrame.new(lobbySpawn.X, 4, lobbySpawn.Z)
pump(0.2, G.frame)
check("D", "(moved to the lobby spawn mid-run)", rootY() > 0, rootY())
pump(5, G.frame)
check("D", "a player found up in the lobby in the middle of a run is put back in the dishwasher", rootY() < -1000, rootY())
check("D", "...and run.misplaced was counted once", tracked["run.misplaced"] == 1, tracked["run.misplaced"])
DS.Track = realTrack
-- walking about the arena is never "misplaced"
pump(4, G.frame)
check("D", "someone playing normally is never put back (no extra counts)", tracked["run.misplaced"] == 1, tracked["run.misplaced"])

-- B: the sweep
_G.__side = "server"
LB.SetBarriers(false) -- (closing the invisible walls sweeps strays)
pump(0.5, G.frame)
check("B", "closing the walls does not touch someone playing a dishwasher", rootY() < -1000, rootY())
pcall(RS.RemoveFromRun, p, "Test")
pump(1.5, G.frame)
check("B", "(out of the run now)", p:GetAttribute("InRun") ~= true)
local spawn = LB.GetSpawnCFrame().Position
p.Character.HumanoidRootPart.CFrame = CFrame.new(spawn.X, -60, spawn.Z)
pump(0.2, G.frame)
LB.SetBarriers(false)
pump(0.5, G.frame)
check("B", "somebody who really fell below the lobby is still put back at the spawn", rootY() > -20, rootY())

-- C: the Create screen starts on Chapter 1
DS.Get(p).Unlocked = 3
local pads = LB.GetLobby().Pads
p.Character.HumanoidRootPart.CFrame = CFrame.new(pads[1].Zone.Position)
local waited = 0
while not (CS.Party and CS.Party.Status == "Picking") and waited < 4 do pump(1 / 30, G.frame) waited += 1 / 30 end
check("C", "with every chapter unlocked, a new party still starts on Chapter 1", CS.Party ~= nil and CS.Party.Level == 1, CS.Party and CS.Party.Level)
check("C", "...and all three chapters can still be picked (HostUnlocked)", CS.Party ~= nil and CS.Party.HostUnlocked == 3, CS.Party and CS.Party.HostUnlocked)
call("client", function() Remotes.Event("PartyAction"):FireServer("Leave") end)
pump(0.5, G.frame)

out(string.format("== %d CHECKS: %d passed, %d FAILED", total, total - failed, failed))
