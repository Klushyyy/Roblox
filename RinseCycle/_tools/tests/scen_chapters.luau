local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Cut = M[R .. "StarterPlayer/StarterPlayerScripts/Client/Cutscene.luau"]
local ws = game:GetService("Workspace")
local prof = DS.Get(G.player)
local function run(level)
	local before = prof.Episodes[level]
	call("server", RS.StartRound, { G.player }, level)
	pump(3, G.frame)
	local model = ws:FindFirstChild("Cutscene")
	local cam = ws.CurrentCamera
	out(string.format("level %d: playing=%s model=%s camType=%s", level, tostring(Cut.IsPlaying()), tostring(model ~= nil), tostring(cam and cam.CameraType)))
	pump(40, G.frame)
	out(string.format("  after: playing=%s model=%s episodes %d -> %d", tostring(Cut.IsPlaying()), tostring(ws:FindFirstChild("Cutscene") ~= nil), before, prof.Episodes[level]))
	local title = G.find(G.playerGui, "Cutscene")
	call("server", RS.RemoveFromRun, G.player, "test")
	pump(4, G.frame)
end
local captured = {}
local Kit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/CutsceneKit.luau"]
local oldTitle = Kit.title
Kit.title = function(ctx, n, name)
	out("  chapter built: " .. n .. " " .. name)
	return oldTitle(ctx, n, name)
end
run(1)
run(1)
run(2)
run(3)
