--[[
	PlayerListUI - the player list (Tab), replacing Roblox's own on a computer.

	Roblox's list can't be resized by a game: it grows a row per player and covers whatever is under it. This one is always
	at most FOUR rows tall; with more players it scrolls. The HUD keeps the buttons on the right below that fixed space, so
	nothing moves when people join or leave (player attribute PlayerListHeight, set here).

	  * Columns: People, then the player's leaderstats (Bubbles, Dishes, Rebirths), sorted by Bubbles like Roblox's.
	  * Open by default in the lobby; Tab or the X closes and opens it. In a run Tab belongs to the Upgrade Book, so the
	    list is away then (and during the first-run tutorial).
	  * Phones and consoles keep Roblox's own list (it is closed until opened from the menu): this one only runs on a
	    computer. If this script is missing the game plays the same with Roblox's list.
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))

local PlayerListUI = {}

local Colors = UIKit.Theme.Colors
local Fonts = UIKit.Theme.Fonts
local LocalPlayer = Players.LocalPlayer

local VISIBLE_ROWS = 4
local ROW_H = 40
local HEAD_H = 28
local PAD = 8
local PANEL_W = 430
local COL_W = 88 -- the three number columns
local MAX_H = PAD + HEAD_H + ROW_H * VISIBLE_ROWS + PAD -- the most it is ever tall (what the HUD keeps clear)
local STATS = { "Bubbles", "Dishes", "Rebirths" }

local STAFF_COLORS = {
	MOD = Color3.fromRGB(80, 220, 100),
	ADMIN = Color3.fromRGB(255, 75, 75),
	DEV = Color3.fromRGB(80, 160, 255),
	OWNER = Color3.fromRGB(185, 100, 255),
}

local initialized = false
local panel: Frame? = nil
local scroller: ScrollingFrame? = nil
local rows: { [Player]: { Frame: Frame, Name: TextLabel, Values: { TextLabel } } } = {}
local wantOpen = true -- Tab / X
local shown = false

local function statValue(player: Player, name: string): number
	local folder = player:FindFirstChild("leaderstats")
	local value = folder and folder:FindFirstChild(name)
	if value and value:IsA("IntValue") then
		return value.Value
	end
	return 0
end

local function onComputer(): boolean
	return not UIKit.IsTouch() and not UIKit.IsGamepad()
end

local function makeRow(player: Player)
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.Size = UDim2.new(1, -10, 0, ROW_H)
	row.BackgroundColor3 = Colors.Primary
	row.BackgroundTransparency = if player == LocalPlayer then 0.82 else 1
	row.BorderSizePixel = 0
	row.Parent = scroller
	UIKit.Corner(row, 6)
	local name = UIKit.Label({
		Text = "",
		TextSize = 19,
		Font = Fonts.Body,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		RichText = true,
		Size = UDim2.new(1, -(COL_W * #STATS + 18), 1, 0),
		Position = UDim2.fromOffset(10, 0),
		Parent = row,
	})
	local values = {}
	for i = 1, #STATS do
		values[i] = UIKit.Label({
			Text = "0",
			TextSize = 18,
			Font = Fonts.Body,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Size = UDim2.fromOffset(COL_W - 8, ROW_H),
			Position = UDim2.new(1, -8 - (#STATS - i) * COL_W, 0, 0),
			Parent = row,
		})
	end
	-- a thin line under each row
	local line = Instance.new("Frame")
	line.Name = "Line"
	line.AnchorPoint = Vector2.new(0, 1)
	line.Position = UDim2.new(0, 0, 1, 0)
	line.Size = UDim2.new(1, 0, 0, 1)
	line.BackgroundColor3 = Colors.TextDim
	line.BackgroundTransparency = 0.85
	line.BorderSizePixel = 0
	line.Parent = row
	rows[player] = { Frame = row, Name = name, Values = values }
end

local function nameText(player: Player): string
	local text = player.DisplayName ~= "" and player.DisplayName or player.Name
	text = string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;") -- (the label reads rich text)
	local tag = player:GetAttribute("StaffTag")
	if type(tag) == "string" and STAFF_COLORS[tag] then
		local c = STAFF_COLORS[tag]
		text = string.format('<font color="rgb(%d,%d,%d)">[%s]</font> %s', math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255), tag, text)
	end
	return text
end

-- Brings the rows up to date: who is here, their numbers, the order (most Bubbles first), the panel's height.
local function refresh()
	if not panel or not scroller then
		return
	end
	local list = Players:GetPlayers()
	for player, row in rows do
		if player.Parent ~= Players then
			row.Frame:Destroy()
			rows[player] = nil
		end
	end
	local stats = {}
	for _, player in list do
		if not rows[player] then
			makeRow(player)
		end
		stats[player] = { statValue(player, "Bubbles"), statValue(player, "Dishes"), statValue(player, "Rebirths") }
	end
	table.sort(list, function(a, b)
		local sa, sb = stats[a][1], stats[b][1]
		if sa ~= sb then
			return sa > sb
		end
		return string.lower(a.Name) < string.lower(b.Name)
	end)
	for order, player in list do
		local row = rows[player]
		row.Frame.LayoutOrder = order
		row.Name.Text = nameText(player)
		for i = 1, #STATS do
			row.Values[i].Text = UIKit.Short(stats[player][i])
		end
	end
	-- Room for four rows, never more: with fewer it is shorter, with more the list scrolls.
	local visible = math.clamp(#list, 1, VISIBLE_ROWS)
	scroller.Size = UDim2.new(1, -(PAD * 2), 0, ROW_H * visible)
	panel.Size = UDim2.fromOffset(PANEL_W, PAD + HEAD_H + ROW_H * visible + PAD)
end

local function place()
	if not panel then
		return
	end
	local safe = UIKit.SafeInsets()
	panel.Position = UDim2.new(1, -(12 + safe.Right), 0, UIKit.TopInset() + 6)
end

-- Whether the list is the one in use at all (a computer, in the lobby, not in the tutorial) and whether it is open.
local function apply()
	local computer = onComputer()
	local away = ClientState.Run ~= nil or ClientState.TutorialStep ~= nil
	local active = computer and not away
	-- Roblox's own list steps aside whenever this one is the list in use (HUD reads the attribute for the in-run case).
	LocalPlayer:SetAttribute("CustomPlayerList", if computer then true else nil)
	local reserve = if active then MAX_H else 0
	if LocalPlayer:GetAttribute("PlayerListHeight") ~= reserve then
		LocalPlayer:SetAttribute("PlayerListHeight", reserve)
	end
	if computer then
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		end)
	end
	local visible = active and wantOpen
	if panel and visible ~= shown then
		shown = visible
		panel.Visible = visible
		if visible then
			refresh()
		end
	end
end

function PlayerListUI.Toggle()
	wantOpen = not wantOpen
	apply()
end

function PlayerListUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, root = UIKit.CreateScreen("PlayerList", 3)
	local card = Instance.new("Frame")
	card.Name = "Panel"
	card.AnchorPoint = Vector2.new(1, 0)
	card.Size = UDim2.fromOffset(PANEL_W, MAX_H)
	card.BackgroundColor3 = Color3.fromRGB(22, 28, 40)
	card.BackgroundTransparency = 0.12
	card.BorderSizePixel = 0
	card.Visible = false
	card.Parent = root
	UIKit.Corner(card, 10)
	UIKit.Stroke(card, Colors.Ink, 2, 0.4)
	panel = card

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.Text = "X"
	close.Font = Fonts.Body
	close.TextSize = 18
	close.TextColor3 = Colors.TextDim
	close.BackgroundTransparency = 1
	close.Size = UDim2.fromOffset(HEAD_H, HEAD_H)
	close.Position = UDim2.fromOffset(PAD - 2, PAD - 2)
	close.AutoButtonColor = false
	close.Parent = card
	close.Activated:Connect(PlayerListUI.Toggle)

	UIKit.Label({
		Text = "People",
		TextSize = 16,
		Font = Fonts.Body,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(120, HEAD_H),
		Position = UDim2.fromOffset(PAD + HEAD_H + 2, PAD),
		Parent = card,
	})
	for i, stat in STATS do
		UIKit.Label({
			Text = stat,
			TextSize = 16,
			Font = Fonts.Body,
			TextColor3 = Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Size = UDim2.fromOffset(COL_W - 8, HEAD_H),
			Position = UDim2.new(1, -(PAD + 8) - (#STATS - i) * COL_W - 6, 0, PAD),
			Parent = card,
		})
	end

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "List"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(PAD, PAD + HEAD_H)
	scroll.Size = UDim2.new(1, -(PAD * 2), 0, ROW_H * VISIBLE_ROWS)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 5
	scroll.ScrollBarImageColor3 = Colors.TextDim
	scroll.Parent = card
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll
	scroller = scroll

	place()
	UIKit.LayoutChanged:Connect(function()
		place()
		apply()
	end)

	-- Tab opens and closes it (in the lobby; in a run Tab is the Upgrade Book)
	UserInputService.InputBegan:Connect(function(input: InputObject, _processed: boolean)
		if input.KeyCode == Enum.KeyCode.Tab and onComputer() and ClientState.Run == nil and UserInputService:GetFocusedTextBox() == nil then
			PlayerListUI.Toggle()
		end
	end)

	Players.PlayerAdded:Connect(refresh)
	Players.PlayerRemoving:Connect(function()
		task.defer(refresh)
	end)
	-- The numbers, the order and who is in a run or the tutorial change all the time: a quick look twice a second
	task.spawn(function()
		while true do
			apply()
			if shown then
				refresh()
			end
			task.wait(0.5)
		end
	end)
	refresh()
	apply()
end

return PlayerListUI
