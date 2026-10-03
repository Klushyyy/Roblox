-- Sub-menus: the gift window's Back button; Roll with too few gems opens the Gems shop (plain X).
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local p = G.player
local prof = DS.Get(p)
prof.Gems = 5
DS.PushMeta(p)
pump(0.5, G.frame)
call("client", function() UIKit.OpenWindow("Ranks") end)
pump(0.5, G.frame)
local roll
for _, d in G.find(p.PlayerGui, "RanksUI"):GetDescendants() do
	if d:IsA("TextButton") and tostring(d.Text):find("^ROLL") then roll = d end
end
G.getSignal(roll, "Activated"):Fire()
pump(0.5, G.frame)
local shop = G.find(p.PlayerGui, "ShopUI")
local function closeText(screen, windowName)
	local w = G.find(screen, windowName)
	local c = w and G.find(w, "Close")
	return c and c.Text or "?"
end
out("after roll with 5 gems, open=" .. (if UIKit.IsWindowOpen("Shop") then "Shop" elseif UIKit.IsWindowOpen("Ranks") then "Ranks" elseif UIKit.IsWindowOpen("PassBuy") then "PassBuy" else "none") .. " shop close button=" .. closeText(shop, "Shop"))
call("client", function() UIKit.GoBack() end)
pump(0.5, G.frame)
out("after Back: open=" .. (if UIKit.IsWindowOpen("Shop") then "Shop" elseif UIKit.IsWindowOpen("Ranks") then "Ranks" elseif UIKit.IsWindowOpen("PassBuy") then "PassBuy" else "none"))
call("client", function() UIKit.OpenWindow("Shop", "Passes") end)
pump(0.5, G.frame)
out("shop opened normally, close button=" .. closeText(shop, "Shop"))
call("client", function() UIKit.OpenSubWindow("PassBuy", { Def = Config.GetPass("SuperScrub") }, "Shop", "Passes") end)
pump(0.5, G.frame)
out("passbuy close button=" .. closeText(shop, "PassBuy") .. " open=" .. (if UIKit.IsWindowOpen("Shop") then "Shop" elseif UIKit.IsWindowOpen("Ranks") then "Ranks" elseif UIKit.IsWindowOpen("PassBuy") then "PassBuy" else "none"))
call("client", function() UIKit.GoBack() end)
pump(0.5, G.frame)
out("after Back: open=" .. (if UIKit.IsWindowOpen("Shop") then "Shop" elseif UIKit.IsWindowOpen("Ranks") then "Ranks" elseif UIKit.IsWindowOpen("PassBuy") then "PassBuy" else "none"))
