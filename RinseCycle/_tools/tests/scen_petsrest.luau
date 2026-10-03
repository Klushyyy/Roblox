-- Pets On / Off: switched off, pets stop cleaning (no coins from them); the setting is saved.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local PS = M[R .. "ServerScriptService/Server/Services/PetService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
pump(1, G.frame)
local prof = DS.Get(p)
prof.Pets = { { Uid = "1", Id = "KrakenKing", Tier = 3 }, { Uid = "2", Id = "TidalDragon", Tier = 3 } }
prof.Equipped = { "1", "2" }
PS.Refresh(p)
call("server", RS.StartRound, { p }, 1)
pump(1, G.frame)
call("client", function() return Remotes.Function("RunRequest"):InvokeServer("Loaded") end)
pump(1, G.frame)
-- Stand by the dirt (the sim doesn't move you into the dishwasher).
local root = p.Character.HumanoidRootPart
for _, d in RS.GetGrimeFolder(p):GetDescendants() do
	if d:IsA("BasePart") then
		root.CFrame = CFrame.new(d.Position + Vector3.new(0, 2, 3))
		break
	end
end
local c0 = CS.Run.Coins
pump(6, G.frame)
local c1 = CS.Run.Coins
out(string.format("pets on: coins %d -> %d", c0, c1))
local r = call("client", function() return CS.MetaRequest("SetPetsResting", true) end)
pump(1.5, G.frame)
local c2 = CS.Run.Coins
pump(6, G.frame)
local c3 = CS.Run.Coins
local lbl = G.find(p.PlayerGui, "PetsToggle"):FindFirstChild("Label", true)
out(string.format("pets off (ok=%s saved=%s button=%s): coins %d -> %d", tostring(r and r.Ok), tostring(prof.PetsResting), lbl.Text, c2, c3))
call("client", function() return CS.MetaRequest("SetPetsResting", false) end)
pump(1, G.frame)
local c4 = CS.Run.Coins
pump(6, G.frame)
out(string.format("back on (button=%s): coins %d -> %d", lbl.Text, c4, CS.Run.Coins))
