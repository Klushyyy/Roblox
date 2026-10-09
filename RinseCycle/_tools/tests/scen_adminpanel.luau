-- The admin panel's tabs: every tab shows at most nine commands (three rows of three), every command the server lists is on
-- exactly one tab, the line under the tabs says what the tab is for, and dumps for guirender.py.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local p = G.player
local RS = game:GetService("ReplicatedStorage")
local UK = G.modules["/home/user/Roblox/RinseCycle/StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local function size(w, h)
	local probe = p.PlayerGui:FindFirstChild("UIKitProbeFull")
	call("client", function()
		probe.AbsoluteSize = Vector2.new(w, h)
		G.getSignal(probe, "AbsoluteSize"):Fire()
	end)
	pump(1.5, G.frame)
end
size(1280, 720)
call("client", function() UK.OpenWindow("Admin") end)
pump(3, G.frame)
local panel = p.PlayerGui:FindFirstChild("AdminPanel")
local groups = G.find(panel, "Groups")
local info
call("client", function() info = RS:FindFirstChild("GetAdminInfo"):InvokeServer() end)
local listed = {}
for _, name in (info and info.Commands or {}) do listed[string.lower(name)] = true end
local seen, tabsFound = {}, 0
local function blurb() local b = G.find(panel, "Blurb") return b and b.Text or "?" end
for _, btn in groups:GetChildren() do
	if btn.ClassName == "TextButton" then
		tabsFound += 1
		G.getSignal(btn, "Activated"):Fire()
		pump(1, G.frame)
		local grid = G.find(panel, "Commands")
		local names = {}
		for _, c in grid:GetChildren() do
			if c.ClassName == "TextButton" and string.sub(c.Name, 1, 4) == "Cmd_" then
				table.insert(names, string.sub(c.Name, 5))
				seen[string.sub(c.Name, 5)] = (seen[string.sub(c.Name, 5)] or 0) + 1
			end
		end
		out(string.format("tab %-12s %d commands: %s", btn.Name, #names, table.concat(names, ", ")))
		out("   line under the tabs: " .. blurb())
		G.dumpGui(panel, OUT .. "adminpanel_" .. string.gsub(btn.Name, " ", "_") .. ".json")
	end
end
out("tabs: " .. tabsFound)
local missing, twice = {}, {}
local TYPED_ONLY = { promote = true, demote = true } -- (no button: Set rank does the same; typing :promote / :demote still works)
for name in listed do if not seen[name] and not TYPED_ONLY[name] then table.insert(missing, name) end end
for name, n in seen do if n > 1 then table.insert(twice, name) end end
table.sort(missing)
out("listed by the server but on no tab: " .. (#missing == 0 and "none" or table.concat(missing, ", ")))
out("on more than one tab: " .. (#twice == 0 and "none" or table.concat(twice, ", ")))
out("analytics is on the Studio Test tab, not Global: " .. tostring(seen.analytics == 1))
out("unfreeze / givecoins listed: " .. tostring(listed.unfreeze == true or listed.givecoins == true))
-- a command with two inputs (the form must hold them): Global > Global poll, and a player command with the player picked
for _, btn in groups:GetChildren() do
	if btn.ClassName == "TextButton" and btn.Name == "Global" then G.getSignal(btn, "Activated"):Fire() end
end
pump(1, G.frame)
G.getSignal(G.find(G.find(panel, "Commands"), "Cmd_globalpoll"), "MouseButton1Click"):Fire()
pump(1, G.frame)
G.dumpGui(panel, OUT .. "adminpanel_form_poll.json")
for _, btn in groups:GetChildren() do
	if btn.ClassName == "TextButton" and btn.Name == "Move" then G.getSignal(btn, "Activated"):Fire() end
end
pump(1, G.frame)
G.getSignal(G.find(G.find(panel, "Commands"), "Cmd_speed"), "MouseButton1Click"):Fire()
pump(1, G.frame)
out("Move tab with you picked, line under the tabs: " .. blurb())
G.dumpGui(panel, OUT .. "adminpanel_form_speed.json")
