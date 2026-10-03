-- Hatch buttons: "(50 Bubbles)", grey when short, and clicking then opens the Bubbles shop.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local p = G.player
local prof = DS.Get(p)
prof.Bubbles = 10
DS.PushMeta(p)
pump(0.5, G.frame)
call("client", function() UIKit.OpenWindow("Eggs") end)
pump(0.5, G.frame)
local hatch
for _, d in G.find(p.PlayerGui, "PetsUI"):GetDescendants() do
	if d:IsA("TextButton") and tostring(d.Text):find("^Hatch 1") then hatch = d end
end
out("button: " .. tostring(hatch.Text) .. " disabled=" .. tostring(hatch:GetAttribute("Disabled")))
G.getSignal(hatch, "Activated"):Fire()
pump(0.5, G.frame)
out("after click: shop open=" .. tostring(UIKit.IsWindowOpen("Shop")) .. " pets=" .. #prof.Pets .. " bubbles=" .. prof.Bubbles)
