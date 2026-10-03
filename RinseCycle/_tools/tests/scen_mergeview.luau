-- Merge mode only shows pets you can merge (3+ of the same pet and tier, not Rainbow).
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local p = G.player
local prof = DS.Get(p)
local function setPets(list)
	prof.Pets = list
	prof.Equipped = {}
	DS.PushMeta(p)
	pump(0.5, G.frame)
end
local function cards()
	local n = 0
	for _, c in G.find(p.PlayerGui, "Grid"):GetChildren() do
		if c:IsA("Frame") then
			n += 1
		end
	end
	return n
end
local function mergeToggle()
	for _, b in G.find(p.PlayerGui, "Header"):GetChildren() do
		local l = b:IsA("TextButton") and (b.Text ~= "" and b.Text or (b:FindFirstChildWhichIsA("TextLabel") and b:FindFirstChildWhichIsA("TextLabel").Text))
		if l == "Merge" or l == "Done" then
			G.getSignal(b, "Activated"):Fire()
		end
	end
	pump(0.5, G.frame)
end
setPets({
	{ Uid = "1", Id = "TidalDragon", Tier = 1 }, { Uid = "2", Id = "TidalDragon", Tier = 1 }, { Uid = "3", Id = "TidalDragon", Tier = 1 },
	{ Uid = "4", Id = "RubberDuck", Tier = 1 }, { Uid = "5", Id = "RubberDuck", Tier = 1 },
	{ Uid = "6", Id = "KrakenKing", Tier = 3 }, { Uid = "7", Id = "KrakenKing", Tier = 3 }, { Uid = "8", Id = "KrakenKing", Tier = 3 },
})
call("client", function() UIKit.OpenWindow("Pets") end)
pump(0.5, G.frame)
out("normal view cards: " .. cards())
mergeToggle()
out("merge view cards: " .. cards())
mergeToggle()
setPets({ { Uid = "4", Id = "RubberDuck", Tier = 1 }, { Uid = "5", Id = "RubberDuck", Tier = 1 } })
mergeToggle()
local msg
for _, d in G.find(p.PlayerGui, "PetsUI"):GetDescendants() do
	if d:IsA("TextLabel") and tostring(d.Text):find("^You don't have") then msg = d end
end
out("nothing to merge: cards " .. cards() .. ", message visible " .. tostring(msg and msg.Visible))
