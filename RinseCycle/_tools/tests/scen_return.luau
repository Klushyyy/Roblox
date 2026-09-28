local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Cutscene = M[R .. "StarterPlayer/StarterPlayerScripts/Client/Cutscene.luau"]
local p = G.player
call("server", RS.StartRound, { p }, 1)
pump(25, G.frame)
call("server", RS.DebugFinish, p)
local root = p.Character.HumanoidRootPart
local runPos = root.Position
local fade = G.find(G.find(G.playerGui, "Cutscene"), "Fade")
local seen = false
for i = 1, 30 * 26 do
	pump(1 / 30, G.frame)
	if not seen and (root.Position - runPos).Magnitude > 50 then
		seen = true
		out(string.format("sent home after %.1fs; fade transparency then = %s", i / 30, tostring(fade.BackgroundTransparency)))
	end
end
out("back in lobby: run=" .. tostring(CS.Run) .. "  still covered=" .. tostring(Cutscene.IsCovered()) .. "  fade=" .. tostring(fade.BackgroundTransparency))
