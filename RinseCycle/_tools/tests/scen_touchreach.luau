-- Phones reach 1.5x further with every tool: the client tells the server it is a touch screen (SetTouch) and the run's Reach grows.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local p = G.player
call("server", RS.StartRound, { p }, 1)
pump(1, G.frame)
call("client", function() return M[R .. "ReplicatedStorage/Shared/Remotes.luau"].Function("RunRequest"):InvokeServer("Loaded") end)
pump(1, G.frame)
local base = CS.Run and CS.Run.Stats.Reach
out("reach on a computer: " .. tostring(base) .. "  (TouchReachMult " .. tostring(Config.Round.TouchReachMult) .. ")")
local function tell(touch)
	return call("client", function() return CS.MetaRequest("SetTouch", touch) end)
end
local reply = tell(true)
pump(1, G.frame)
out("SetTouch(true) -> " .. tostring(reply and reply.Ok) .. "  attribute: " .. tostring(p:GetAttribute("TouchReach")) .. "  reach now: " .. tostring(CS.Run and CS.Run.Stats.Reach) .. "  (x" .. string.format("%.2f", (CS.Run and CS.Run.Stats.Reach or 0) / (base or 1)) .. ")")
local bad = tell("yes")
out("SetTouch with junk -> " .. tostring(bad and bad.Ok) .. "  attribute stays: " .. tostring(p:GetAttribute("TouchReach")))
tell(false)
pump(1, G.frame)
out("SetTouch(false) -> reach back to " .. tostring(CS.Run and CS.Run.Stats.Reach))
