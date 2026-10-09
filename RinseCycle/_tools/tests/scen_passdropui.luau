-- The pass drop's "Congrats" card and its winners window at phone sizes (dumps for guirender.py), with 25 winners.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local p = G.player
local RS = game:GetService("ReplicatedStorage")
call("client", function()
	local UIS = game:GetService("UserInputService")
	UIS.TouchEnabled = true
	UIS.KeyboardEnabled = false
end)
local function size(w, h)
	local probe = p.PlayerGui:FindFirstChild("UIKitProbeFull")
	call("client", function()
		probe.AbsoluteSize = Vector2.new(w, h)
		G.getSignal(probe, "AbsoluteSize"):Fire()
	end)
	pump(1.5, G.frame)
end
local function findButton(root, text)
	for _, d in root:GetDescendants() do
		if d.ClassName == "TextButton" and d.Text == text then return d end
	end
end
local passes = { "2x Coins", "Spray Nozzle", "Pressure Washer", "Foam Cannon" }
local board = {}
for i = 1, 25 do
	table.insert(board, { Id = if i == 3 then p.UserId else 1000 + i, Name = (if i == 3 then p.Name else "SomePlayerName" .. i), Pass = passes[(i - 1) % #passes + 1] })
end
for _, s in { { "land", 844, 390 }, { "port", 390, 844 }, { "small", 667, 375 } } do
	size(s[2], s[3])
	out("-- " .. s[1] .. " " .. s[2] .. "x" .. s[3])
	call("server", function() RS:FindFirstChild("PassWinners"):FireClient(p, "Drop", board) end)
	pump(1, G.frame)
	local status = p.PlayerGui:FindFirstChild("AdminStatus")
	local card = G.find(status, "PassDropCard")
	out("card shown: " .. tostring(card ~= nil) .. (if card then " width " .. tostring(card.Size.X.Offset) else ""))
	G.dumpGui(status, OUT .. "passdrop_card_" .. s[1] .. ".json")
	local view = card and findButton(card, "VIEW")
	if view then
		G.getSignal(view, "Activated"):Fire()
		pump(0.8, G.frame)
		local win = G.find(status, "PassWinnersWindow")
		out("window shown: " .. tostring(win ~= nil))
		G.dumpGui(status, OUT .. "passdrop_list_" .. s[1] .. ".json")
		local close = win and findButton(win, "CLOSE")
		if close then G.getSignal(close, "Activated"):Fire() end
		pump(0.4, G.frame)
	end
end
