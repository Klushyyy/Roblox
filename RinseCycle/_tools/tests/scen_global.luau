-- Admin panel > Global: poll (vote, results banner), give everyone, pass drop, x2 boost.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local me, other = G.player, G.victim
pump(1, G.frame)
local RSt = G.ReplicatedStorage
local cmd = RSt:FindFirstChild("AdminCommand")
local feedback, banners = {}, {}
G.getSignal(RSt:FindFirstChild("AdminFeedback"), "OnClientEvent"):Connect(function(t) table.insert(feedback, t) end)
G.getSignal(RSt:FindFirstChild("AdminAnnouncement"), "OnClientEvent"):Connect(function(t) table.insert(banners, t) end)
local function asMe(c, t, x) call("client", function() cmd:FireServer(c, t or "", x or "") end) pump(0.5, G.frame) end
local function last() return feedback[#feedback] end
-- poll
asMe("globalpoll", "30", "Best level? | Pizzeria | Castle | Both")
out("poll: " .. tostring(last()))
local card = G.find(me.PlayerGui, "Poll")
out("poll card visible: " .. tostring(card and card.Visible))
local vote = RSt:FindFirstChild("GlobalPollVote")
local pollId
for _, d in card:GetDescendants() do end
-- vote as me (through the card's 2nd button) and as the other player directly
local answers = card:FindFirstChild("Answers")
local btns = {}
for _, b in answers:GetChildren() do if b:IsA("TextButton") then table.insert(btns, b) end end
table.sort(btns, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
G.getSignal(btns[2], "Activated"):Fire()
pump(1.5, G.frame)
local slider = G.find(me.PlayerGui, "Slider")
local tab = G.find(me.PlayerGui, "PullTab")
out("after voting: tucked (slider y) = " .. tostring(slider.Position.Y.Offset) .. "  pull tab shown: " .. tostring(tab.Visible))
pump(40, G.frame)
local holder = G.find(me.PlayerGui, "PollHolder")
local lines = {}
for _, d in card:GetDescendants() do
	if d.ClassName == "TextLabel" and d.Parent and d.Parent.Name == "Result" then
		table.insert(lines, d.Text)
	end
end
local title
for _, d in card:GetChildren() do
	if d.ClassName == "TextLabel" and tostring(d.Text):find("POLL") then
		title = d.Text
	end
end
out("after end: shown=" .. tostring(holder.Visible) .. " slider y=" .. tostring(slider.Position.Y.Offset) .. " title=" .. tostring(title) .. " results: " .. table.concat(lines, " | "))
out("results banner (should be none): " .. tostring(banners[#banners]))
out("admin got: " .. tostring(last()))
-- give everyone
local b0 = DS.Get(me).Bubbles
asMe("globalgive", "Bubbles", "250")
out(string.format("give: %s | bubbles %d -> %d (other %s)", tostring(last()), b0, DS.Get(me).Bubbles, tostring(DS.Get(other) and DS.Get(other).Bubbles)))
asMe("globalgive", "Rubies", "5")
out("bad give: " .. tostring(last()))
-- boost
asMe("globalboost", "10", "")
out(string.format("boost: %s | left %d s", tostring(last()), DS.Get(me).BoostUntil - os.time()))
-- pass drop: everyone gets a "Congrats" card with a VIEW button, which opens the winners (grouped by pass)
local dropsSeen = {}
G.getSignal(RSt:FindFirstChild("PassWinners"), "OnClientEvent"):Connect(function(kind, board) table.insert(dropsSeen, { kind = kind, board = board }) end)
asMe("globalpassdrop", "2", "DoubleCoins")
pump(1, G.frame)
out("pass drop: " .. tostring(last()))
out("banner: " .. tostring(banners[#banners]))
out("me has DoubleCoins: " .. tostring(DS.GetPasses(me).DoubleCoins) .. ", other: " .. tostring(DS.Get(other) and DS.GetPasses(other).DoubleCoins))

out("pass drop cards sent: " .. #dropsSeen .. (dropsSeen[1] and (" (" .. #dropsSeen[1].board .. " winners: " .. (function() local t = {} for _, w in dropsSeen[1].board do table.insert(t, w.Name .. "=" .. w.Pass) end return table.concat(t, ", ") end)() .. ")") or ""))
local dropCard = G.find(me.PlayerGui, "PassDropCard")
out("congrats card shown: " .. tostring(dropCard ~= nil))
local function findButton(root, text)
	for _, d in root:GetDescendants() do
		if d.ClassName == "TextButton" and d.Text == text then return d end
	end
end
if dropCard then
	local texts = {}
	for _, d in dropCard:GetDescendants() do
		if d.ClassName == "TextLabel" and d.Text ~= "" then table.insert(texts, d.Text) end
	end
	out("card text: " .. table.concat(texts, " | "))
	local view = findButton(dropCard, "VIEW")
	out("VIEW button: " .. tostring(view ~= nil))
	if view then
		G.getSignal(view, "Activated"):Fire()
		pump(0.6, G.frame)
		local win = G.find(me.PlayerGui, "PassWinnersWindow")
		out("winners window opened: " .. tostring(win ~= nil))
		if win then
			local rows = {}
			for _, d in win:GetDescendants() do
				if d.ClassName == "TextLabel" and d.Text ~= "" then table.insert(rows, d.Text) end
			end
			out("window text: " .. table.concat(rows, " | "))
			local close = findButton(win, "CLOSE")
			if close then
				G.getSignal(close, "Activated"):Fire()
				pump(0.3, G.frame)
			end
			out("window closed: " .. tostring(G.find(me.PlayerGui, "PassWinnersWindow") == nil))
		end
	end
end
