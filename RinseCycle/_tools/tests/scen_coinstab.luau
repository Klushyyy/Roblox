-- The Shop's Coins tab: hidden in the lobby, there in a dishwasher.
local M = G.modules
local UIKit = M["/home/user/Roblox/RinseCycle/StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local p = G.player
local function coinsTab()
	for _, d in G.find(p.PlayerGui, "ShopUI"):GetDescendants() do
		if d:IsA("TextButton") and d.Parent and d.Parent.Name == "Tabs" then
			local l = d.Text ~= "" and d.Text or (d:FindFirstChildWhichIsA("TextLabel", true) and d:FindFirstChildWhichIsA("TextLabel", true).Text)
			if l == "Coins" then
				return d
			end
		end
	end
end
call("client", function() UIKit.OpenWindow("Shop", "Coins") end)
pump(0.5, G.frame)
out("lobby: coins tab visible=" .. tostring(coinsTab() and coinsTab().Visible))
