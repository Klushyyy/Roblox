-- Dumps the Clubs window (create + my club + find + filters), the chest boxes and reveal.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local prof = DS.Get(p)
prof.Gems = 5000
DS.PushMeta(p)
call("client", function()
	UIKit.CloseWindow()
	UIKit.OpenWindow("Clubs")
end)
pump(1.5, G.frame)
G.dumpGui(p.PlayerGui.ClubsUI, OUT .. "clubs_create.json")
call("client", function()
	Remotes.Function("ClubRequest"):InvokeServer("Create", { Name = "Soap Squad", Tag = "SOAP", Public = true })
end)
pump(1, G.frame)
call("client", function()
	UIKit.CloseWindow()
	UIKit.OpenWindow("Clubs")
end)
pump(1.5, G.frame)
G.dumpGui(p.PlayerGui.ClubsUI, OUT .. "clubs_mine.json")
local function clickTab(name)
	local b = p.PlayerGui.ClubsUI:FindFirstChild("Tab" .. name, true)
	G.getSignal(b, "Activated"):Fire()
	pump(1.5, G.frame)
end
prof.Bubbles = 20000
call("client", function()
	Remotes.Function("ClubRequest"):InvokeServer("Donate", 4200)
end)
pump(0.5, G.frame)
call("client", function()
	UIKit.CloseWindow()
	UIKit.OpenWindow("Clubs")
end)
pump(1.5, G.frame)
G.dumpGui(p.PlayerGui.ClubsUI, OUT .. "clubs_mine2.json")
clickTab("Top")
G.dumpGui(p.PlayerGui.ClubsUI, OUT .. "clubs_top.json")
local rowHit
for _, d in p.PlayerGui.ClubsUI:GetDescendants() do
	if d.Name == "Open" and d.ClassName == "TextButton" then
		rowHit = d
	end
end
G.getSignal(rowHit, "Activated"):Fire()
pump(1.5, G.frame)
G.dumpGui(p.PlayerGui.ClubsUI, OUT .. "clubs_info.json")
clickTab("Board")
G.dumpGui(p.PlayerGui.ClubsUI, OUT .. "clubs_board.json")
clickTab("Club")
local don
for _, d in p.PlayerGui.ClubsUI:GetDescendants() do
	if d.ClassName == "TextLabel" and tostring(d.Text) == "DONATE BUBBLES" then
		don = d
	end
end
out("donate label found: " .. tostring(don ~= nil))
local btn = don and don:FindFirstAncestorWhichIsA("TextButton")
out("donate button: " .. tostring(btn and btn.Name))
if btn then
	G.getSignal(btn, "Activated"):Fire()
end
pump(1, G.frame)
G.dumpGui(p.PlayerGui.ClubsUI, OUT .. "clubs_donate.json")
clickTab("Find")
local box
for _, d in p.PlayerGui.ClubsUI:GetDescendants() do
	if d.ClassName == "TextBox" and d.PlaceholderText:find("club name") then
		box = d
	end
end
out("find box: " .. tostring(box ~= nil))
box.Text = "s"
pump(1.5, G.frame)
G.dumpGui(p.PlayerGui.ClubsUI, OUT .. "clubs_find.json")
clickTab("Chat")
G.dumpGui(p.PlayerGui.ClubsUI, OUT .. "clubs_chat.json")
call("client", function()
	UIKit.CloseWindow()
	M[R .. "StarterPlayer/StarterPlayerScripts/Client/ChestUI.luau"].GoToChest()
end)
pump(1.5, G.frame)
G.dumpGui(p.PlayerGui.ChestUI, OUT .. "chest_boxes.json")
out("dumped")
