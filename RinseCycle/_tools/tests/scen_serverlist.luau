-- The admin "All servers" list: tabs along the top (All servers / Lobbies / Chapter 1 / 2 / 3), a title that fits, one card per
-- server with a coloured badge. Dumps for guirender.py at the panel's usual size.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local p = G.player
local RS = game:GetService("ReplicatedStorage")
local function listView() return G.find(p.PlayerGui, "ListView") end
local function buttonTexts(root)
	local t = {}
	for _, d in root:GetDescendants() do
		if d.ClassName == "TextButton" and d.Text ~= "" then table.insert(t, d.Text) end
	end
	return table.concat(t, " | ")
end
-- the real thing: the admin asks the server for the list, the server answers (this one server only offline)
local asked = {}
G.getSignal(RS:FindFirstChild("AdminServerList"), "OnClientEvent"):Connect(function(title, rows, busiest, index, count, tabs)
	table.insert(asked, { Title = title, Rows = rows, Index = index, Count = count, Tabs = tabs })
end)
call("client", function() RS:FindFirstChild("AdminServerAction"):FireServer("List", "1") end)
pump(2, G.frame)
local got = asked[#asked]
if got then
	out("server answered: title=[" .. tostring(got.Title) .. "] rows=" .. #got.Rows .. " filter " .. tostring(got.Index) .. "/" .. tostring(got.Count) .. " tabs=" .. (got.Tabs and table.concat(got.Tabs, " | ") or "nil"))
	local r = got.Rows[1]
	if r then out(string.format("row 1: kind=%s badge=%s | %s | %s", tostring(r.Kind), tostring(r.Badge), tostring(r.Line1), tostring(r.Line2))) end
else
	out("server did not answer (not an admin in the sim?)")
end
-- mock data: two lobbies, a chapter 2 game, a chapter 3 game
local rows = {
	{ Id = 11, JobId = "a", Kind = "lobby", Badge = "LOBBY", Line1 = "Lobby 1   (you are here)", Line2 = "1 player  -  up 1 min   |   (only you / hidden staff)" },
	{ Id = 12, JobId = "b", Kind = "lobby", Badge = "LOBBY", Line1 = "Lobby 2", Line2 = "14 players  -  up 2h 05m   |   alpha, beta, gamma, delta, epsilon, zeta, eta, theta" },
	{ Id = 13, JobId = "c", Kind = "level2", Badge = "CH 2", Line1 = "Pizza Party  -  game #1", Line2 = "1 player  -  up 0 min   |   summerj1907j" },
	{ Id = 14, JobId = "d", Kind = "level3", Badge = "CH 3", Line1 = "Castle Kitchen  -  game #1", Line2 = "3 players  -  up 12 min   |   one, two, three" },
}
local tabs = { "All servers (4)", "Lobbies (2)", "Chapter 1 (0)", "Chapter 2 (1)", "Chapter 3 (1)" }
local sent = {}
G.getSignal(RS:FindFirstChild("AdminServerAction"), "OnServerEvent"):Connect(function(_, action, a, b) table.insert(sent, tostring(action) .. ":" .. tostring(a)) end)
local function show(w, h, name, index, shownRows)
	local probe = p.PlayerGui:FindFirstChild("UIKitProbeFull")
	call("client", function()
		probe.AbsoluteSize = Vector2.new(w, h)
		G.getSignal(probe, "AbsoluteSize"):Fire()
	end)
	call("server", function() RS:FindFirstChild("AdminServerList"):FireClient(p, "19 players on 4 servers", shownRows or rows, "b", index, 5, tabs) end)
	pump(2, G.frame)
	local lv = listView()
	out(string.format("%s %dx%d: list view visible=%s title=[%s]", name, w, h, tostring(lv and lv.Visible), tostring(G.find(lv, "Label") and G.find(lv, "Label").Text)))
	return lv
end
local lv = show(1280, 720, "pc", 1)
local tabsRow = G.find(lv, "Tabs")
out("tabs row visible=" .. tostring(tabsRow and tabsRow.Visible) .. "  buttons: " .. (tabsRow and buttonTexts(tabsRow) or "-"))
local selectedBefore
for _, d in (tabsRow and tabsRow:GetDescendants() or {}) do
	if d.ClassName == "TextButton" and d.Text == "All servers (4)" then selectedBefore = d.BackgroundColor3 end
end
local scroll = G.find(lv, "ScrollingFrame")
local cards = 0
for _, c in (scroll and scroll:GetChildren() or {}) do if c.ClassName == "Frame" then cards += 1 end end
out("cards listed: " .. cards)
G.dumpGui(p.PlayerGui:FindFirstChild("AdminPanel"), OUT .. "servers_pc.json")
local lobbiesButton
for _, d in (tabsRow and tabsRow:GetDescendants() or {}) do
	if d.ClassName == "TextButton" and d.Text == "Lobbies (2)" then lobbiesButton = d end
end
if lobbiesButton then
	G.getSignal(lobbiesButton, "Activated"):Fire()
	pump(1, G.frame)
	out("tap on Lobbies sent: " .. tostring(sent[#sent]))
end
show(844, 390, "land", 4, { rows[3] })
G.dumpGui(p.PlayerGui:FindFirstChild("AdminPanel"), OUT .. "servers_land.json")
show(390, 844, "port", 1)
G.dumpGui(p.PlayerGui:FindFirstChild("AdminPanel"), OUT .. "servers_port.json")
