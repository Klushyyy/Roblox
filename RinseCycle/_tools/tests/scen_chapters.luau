local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Cut = M[R .. "StarterPlayer/StarterPlayerScripts/Client/Cutscene.luau"]
local ws = game:GetService("Workspace")
local function run(level)
	call("server", RS.StartRound, { G.player }, level)
	pump(3, G.frame)
	local model = ws:FindFirstChild("Cutscene")
	local cam = ws.CurrentCamera
	out(string.format("level %d: playing=%s model=%s camType=%s", level, tostring(Cut.IsPlaying()), tostring(model ~= nil), tostring(cam and cam.CameraType)))
	local seen = {}
	for _ = 1, 40 do
		pump(1, G.frame)
		local line = G.find(G.playerGui, "Line")
		if line and line.Text ~= "" and not seen[line.Text] then
			seen[line.Text] = true
			out("  sub: " .. line.Text)
		end
	end
	out(string.format("  after: playing=%s model=%s", tostring(Cut.IsPlaying()), tostring(ws:FindFirstChild("Cutscene") ~= nil)))
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
