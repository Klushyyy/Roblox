local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
call("server", RS.StartRound, { G.player }, tonumber(require and 2) or 2)
pump(4, G.frame)
local f = G.workspace:FindFirstChild("LevelNPCs")
local n = 0
if f then
	for _ in G.methods.GetDescendants(f) do
		n += 1
	end
end
out(string.format("NPC folder %s, %d parts", tostring(f ~= nil), n))
