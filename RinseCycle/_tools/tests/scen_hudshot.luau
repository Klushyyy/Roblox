-- Renders the lobby HUD (and a phone-sized one) for a look at the buttons.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
call("client", function()
	UIKit.CloseWindow()
end)
pump(1.5, G.frame)
G.dumpGui(G.player.PlayerGui.HUD, OUT .. "hud_lobby.json")
G.dumpGui(G.player.PlayerGui.BoostBadges, OUT .. "hud_badges.json")
out("dumped")
