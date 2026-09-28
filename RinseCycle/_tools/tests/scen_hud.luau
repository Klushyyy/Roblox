local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local hud = G.find(G.playerGui, "HUD")
local col = G.find(hud, "LeftColumn")
local function show(tag)
	local names = {}
	for _, c in G.methods.GetChildren(col) do
		if c.ClassName == "TextButton" then
			table.insert(names, string.format("%s(%s,#%s)", tostring(c.Name == "AdminButton" and "Admin" or c.Text), c.Visible and "shown" or "hidden", tostring(c.LayoutOrder)))
		end
	end
	out(tag .. ": column " .. (col.Visible and "visible" or "hidden") .. " -> " .. table.concat(names, " "))
end
show("lobby")
local btn = G.find(col, "AdminButton")
if btn then
	G.getSignal(btn, "Activated"):Fire()
	pump(0.5, G.frame)
	out("after clicking Admin: window open = " .. tostring(UIKit.IsWindowOpen("Admin")))
	G.getSignal(btn, "Activated"):Fire()
	pump(0.5, G.frame)
	out("after clicking again: window open = " .. tostring(UIKit.IsWindowOpen("Admin")))
end
call("server", RS.StartRound, { G.player }, 1)
pump(2, G.frame)
show("in a run")
