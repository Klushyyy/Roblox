-- Pets pay straight to coins (no bag), hide for a hidden admin, and the admin pets view.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local PS = M[R .. "ServerScriptService/Server/Services/PetService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local p, other = G.player, G.victim
pump(1, G.frame)
local prof = DS.Get(p)
prof.Pets = { { Uid = "1", Id = "KrakenKing", Tier = 3 }, { Uid = "2", Id = "TidalDragon", Tier = 3 } }
prof.Equipped = { "1", "2" }
PS.Refresh(p)
call("server", RS.StartRound, { p }, 1)
pump(1, G.frame)
call("client", function() return Remotes.Function("RunRequest"):InvokeServer("Loaded") end)
pump(1, G.frame)
local c0 = CS.Run and CS.Run.Coins or 0
pump(8, G.frame)
local c1 = CS.Run and CS.Run.Coins or 0
local bags = 0
local eq = p:FindFirstChild("EquippedPets")
for _, v in (eq and eq:GetChildren() or {}) do if v:GetAttribute("Bag") then bags += 1 end end
out(string.format("coins from pets in 8s: %d -> %d (bag attrs: %d)", c0, c1, bags))
-- hidden admin: pets stop
p.Character:SetAttribute("AdminHidden", true)
pump(1, G.frame)
local c2 = CS.Run.Coins
pump(4, G.frame)
local targets = 0
for _, v in (eq and eq:GetChildren() or {}) do
	local t = v:FindFirstChild("Target")
	if t and t.Value then targets += 1 end
end
out(string.format("hidden: coins %d -> %d, pets with a target: %d", c2, CS.Run.Coins, targets))
p.Character:SetAttribute("AdminHidden", nil)
-- admin pets view
local PL, PA = G.ReplicatedStorage:FindFirstChild("AdminPetList"), G.ReplicatedStorage:FindFirstChild("AdminPetAction")
local got
G.getSignal(PL, "OnClientEvent"):Connect(function(uid, title, rows) got = { title, rows } end)
local cmd = G.ReplicatedStorage:FindFirstChild("AdminCommand")
call("client", function() cmd:FireServer("viewpets", "Victim", "") end)
pump(0.5, G.frame)
out("view: " .. tostring(got and got[1]))
call("server", function() G.getSignal(PA, "OnServerEvent"):Fire(p, "Add", other.UserId, "MopCat", 2) end)
pump(0.5, G.frame)
out("after add: " .. tostring(got and got[1]) .. " first=" .. tostring(got and got[2][#got[2]] and got[2][#got[2]].Line1))
local uid = got[2][#got[2]].Id
call("server", function() G.getSignal(PA, "OnServerEvent"):Fire(p, "Remove", other.UserId, uid) end)
pump(0.5, G.frame)
out("after remove: " .. tostring(got and got[1]))
-- invis carries to the next character
call("client", function() cmd:FireServer("invis", "Victim", "") end)
pump(0.5, G.frame)
out("victim AdminInvis attr: " .. tostring(other:GetAttribute("AdminInvis")) .. " hidden: " .. tostring(other.Character:GetAttribute("AdminHidden")))
