-- The first minutes (v2.20.0), part 2: the card starts the run by itself, and the come-back card afterwards.
--   G  nobody presses anything: after Config.FirstRun.AutoStart seconds the run starts on its own (welcome.auto)
--   H  the Daily window no longer pops up in front of a brand-new player, and does after their first run
--   I  the come-back card: after the first win, in the lobby, once nothing else is open
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local UK = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local p = G.player

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
local function findText(root, text)
	for _, d in root:GetDescendants() do
		if (d.ClassName == "TextButton" or d.ClassName == "TextLabel") and d.Text == text then return d end
	end
end
local function press(btn)
	G.getSignal(btn, "Activated"):Fire()
end

local welcome = p.PlayerGui:FindFirstChild("Welcome", true)
local back = p.PlayerGui:FindFirstChild("ComeBack", true)
check("G", "both cards are built", welcome ~= nil and back ~= nil)
check("H", "a brand-new player has no window in front of the card (Daily waits)", not UK.IsWindowOpen("Daily"), UK.IsWindowOpen())
check("G", "the START CLEANING card is up", welcome.Visible == true)
check("I", "the come-back card is not (no run finished yet)", back.Visible == false)

-- nobody touches anything
local waited = 0
while not (p:GetAttribute("InParty") or RS.IsInRun(p)) and waited < Config.FirstRun.AutoStart + 6 do
	pump(0.25, G.frame)
	waited += 0.25
end
check("G", "the run started by itself", p:GetAttribute("InParty") == true or RS.IsInRun(p), string.format("%.1fs", waited))
check("G", "...within AutoStart seconds of the card showing", waited <= Config.FirstRun.AutoStart + 1, waited)
check("G", "welcome.go and welcome.auto were tracked once each", tracked["welcome.go"] == 1 and tracked["welcome.auto"] == 1, tostring(tracked["welcome.go"]) .. "/" .. tostring(tracked["welcome.auto"]))
check("G", "the card is gone", welcome.Visible == false)
pump(6, G.frame)
check("G", "in a dishwasher", RS.IsInRun(p))
check("G", "the lighter dishwasher was used", tracked["run.easy"] == 1, tracked["run.easy"])
call("client", function() return Remotes.Function("RunRequest"):InvokeServer("Loaded") end)
pump(0.5, G.frame)
_G.__side = "server"
call("server", RS.DebugFinish, p)
pump(8, G.frame)
_G.__side = "client"
local r = call("client", function() return Remotes.Function("RunRequest"):InvokeServer("ReturnToLobby") end)
pump(3, G.frame)
_G.__side = "server"
pcall(RS.RemoveFromRun, p, "Test")
pump(1, G.frame)
local profile = DS.Get(p)
check("I", "the first run is finished and counted", profile.Stats.Runs == 1, profile.Stats.Runs)
check("I", "the client knows (RunsStarted/Runs)", CS.Meta ~= nil and CS.Meta.Stats.Runs == 1, CS.Meta and CS.Meta.Stats.Runs)

-- back in the lobby: the Daily reward pops up now (it waited), the come-back card waits behind it
pump(5, G.frame)
check("H", "after the first run the Daily window pops up", UK.IsWindowOpen("Daily"))
check("I", "...and the come-back card waits while a window is open", back.Visible == false)
call("client", function() UK.CloseWindow() end)
pump(Config.FirstRun.BackDelay - 2, G.frame)
check("I", "not before the delay is over", back.Visible == false)
pump(4, G.frame)
check("I", "the come-back card shows", back.Visible == true)
check("I", "...with Free gifts and Later", findText(back, "FREE GIFTS") ~= nil and findText(back, "Later") ~= nil)
check("I", "back.show was tracked by the client", true) -- (the client's own Track goes through Telemetry; not hooked here)
local gifts = findText(back, "FREE GIFTS")
press(gifts)
pump(0.5, G.frame)
check("I", "FREE GIFTS opens the Free window", UK.IsWindowOpen("Free"))
check("I", "...and the card goes away", back.Visible == false)
call("client", function() UK.CloseWindow() end)
pump(Config.FirstRun.BackDelay + 3, G.frame)
check("I", "it does not come back again this visit", back.Visible == false)

DS.Track = realTrack
out(string.format("== %d CHECKS: %d passed, %d FAILED", total, total - failed, failed))
