-- The first minutes (v2.20.0), part 3: opening a menu while the START CLEANING card is up.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local UK = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local p = G.player
local total, failed = 0, 0
local function check(name, ok, detail)
	total += 1
	if not ok then failed += 1 end
	out(string.format("%3d %s %s%s", total, if ok then "PASS" else "FAIL", name, if detail ~= nil then "   [" .. tostring(detail) .. "]" else ""))
end
local welcome = p.PlayerGui:FindFirstChild("Welcome", true)
check("the card is up", welcome.Visible == true)
call("client", function() UK.OpenWindow("Shop") end)
pump(0.6, G.frame)
check("opening a menu hides it", welcome.Visible == false)
call("client", function() UK.CloseWindow() end)
pump(Config.FirstRun.AutoStart + Config.FirstRun.CardDelay + 6, G.frame)
check("...for good: it does not come back", welcome.Visible == false)
check("...and nothing started by itself", p:GetAttribute("InParty") ~= true and not RS.IsInRun(p))
out(string.format("== %d CHECKS: %d passed, %d FAILED", total, total - failed, failed))
