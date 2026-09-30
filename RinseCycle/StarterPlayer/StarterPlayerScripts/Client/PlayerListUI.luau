--[[
	PlayerListUI - the game's own player list (top right, Tab or tap the header to fold it).

	Roblox's built-in list can't hide one player, so it's switched off (HUD) and this one is used
	instead. Anyone the admin :invis command made invisible (player attribute AdminInvis) isn't
	listed at all; staff still see them, greyed out and marked (hidden). Each row: the staff / VIP
	tag, the display name, and their Bubbles, Dishes and Rebirths (leaderstats).

	Placement: top right under Roblox's top bar, inside the screen's safe area, and never lower
	than just above the HUD's right-hand buttons (Shop / Pets / Ranks); more players than fit
	scroll. In a run the list steps aside (Tab opens the Upgrade Book there).
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))

local PlayerListUI = {}

local Colors = UIKit.Theme.Colors
local LocalPlayer = Players.LocalPlayer

-- Phones draw the whole UI smaller, so the list is bigger there to stay readable.
local TOUCH = UIKit.IsTouch()
local WIDTH = if TOUCH then 330 else 260
local HEADER = if TOUCH then 38 else 30
local TITLES = if TOUCH then 24 else 20
local ROW = if TOUCH then 34 else 26
local GAP = 2
local STATS = { "Bubbles", "Dishes", "Rebirths" }
-- Column titles are icons: they fit however narrow the columns get.
local STAT_ICONS = { Bubbles = "🫧", Dishes = "🍽️", Rebirths = "🔁" }
local NAME_SHARE = 0.52 -- of the row's width; the three numbers share the rest
local STAT_SHARE = (1 - NAME_SHARE) / #STATS
local TAG_COLORS = {
	MOD = Color3.fromRGB(80, 220, 100),
	ADMIN = Color3.fromRGB(255, 75, 75),
	DEV = Color3.fromRGB(80, 160, 255),
	OWNER = Color3.fromRGB(185, 100, 255),
	VIP = Color3.fromRGB(255, 210, 74),
}

local initialized = false
local open = true
local panel: Frame
local list: ScrollingFrame
local header: TextButton
local rightColumn: GuiObject? = nil

local function isStaffViewer(): boolean
	return type(LocalPlayer:GetAttribute("StaffTag")) == "string"
end

local function inRun(): boolean
	return ClientState.Run ~= nil
end

local function statText(player: Player, name: string): string
	local stats = player:FindFirstChild("leaderstats")
	local value = stats and stats:FindFirstChild(name)
	if value and (value:IsA("IntValue") or value:IsA("NumberValue")) then
		return UIKit.Short(value.Value)
	end
	return "-"
end

local function tagOf(player: Player): string?
	local staff = player:GetAttribute("StaffTag")
	if type(staff) == "string" and TAG_COLORS[staff] then
		return staff
	end
	if player:GetAttribute("VIP") == true then
		return "VIP"
	end
	return nil
end

local function cell(parent: Instance, text: string, x: number, w: number, color: Color3?, align: Enum.TextXAlignment?): TextLabel
	return UIKit.Label({
		Text = text,
		TextSize = if TOUCH then 20 else 15,
		TextScaled = true, -- shrinks to fit (never cut off)
		RichText = true,
		TextColor3 = color or Colors.Text,
		TextXAlignment = align or Enum.TextXAlignment.Center,
		Position = UDim2.new(x, 4, 0, 3),
		Size = UDim2.new(w, -8, 1, -6),
		Parent = parent,
	})
end

-- Where the panel goes and how tall it may get (canvas units). Normally top right, reaching down
-- to just above the right-hand buttons. If that leaves room for less than MIN_ROOM (short
-- screens), it moves to the left of those buttons instead and may use the full height. Measured
-- from the frames' on-screen positions (both live in same-style full-screen canvases).
local MIN_ROOM = HEADER + TITLES + 3 * (ROW + GAP) + 10

local function place(height: number)
	local scale = UIKit.GetScale()
	local safe = UIKit.SafeInsets()
	local top = UIKit.TopInset() + 8
	local right = 16 + safe.Right
	local room = UIKit.CanvasSize().Y - 16 - top
	local column = rightColumn
	if column and column.Parent and column.Visible and column.AbsoluteSize.Y > 0 then
		local columnTop = column.AbsolutePosition.Y / scale
		local panelTop = if panel.AbsoluteSize.Y > 0 then panel.AbsolutePosition.Y / scale else top
		local above = columnTop - panelTop - 10
		if above >= MIN_ROOM or height <= above then
			room = math.min(room, above)
		else
			right += column.AbsoluteSize.X / scale + 12 -- beside the buttons, not above them
		end
	end
	panel.Position = UDim2.new(1, -right, 0, top)
	panel.Size = UDim2.fromOffset(WIDTH, math.max(HEADER, math.min(height, room)))
	panel.Visible = not inRun()
end

local function redraw()
	if not panel then
		return
	end
	for _, child in list:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local staffView = isStaffViewer()
	local shown = {}
	for _, player in Players:GetPlayers() do
		local hidden = player:GetAttribute("AdminInvis") == true
		if not hidden or staffView or player == LocalPlayer then
			table.insert(shown, player)
		end
	end
	table.sort(shown, function(a, b)
		if a == LocalPlayer then
			return true
		elseif b == LocalPlayer then
			return false
		end
		return a.DisplayName:lower() < b.DisplayName:lower()
	end)
	header.Text = string.format("  Players (%d)  %s", #shown, if open then "▲" else "▼")
	list.Visible = open
	if not open then
		place(HEADER)
		return
	end
	local titles = Instance.new("Frame")
	titles.BackgroundTransparency = 1
	titles.Size = UDim2.new(1, 0, 0, TITLES)
	titles.LayoutOrder = 0
	titles.Parent = list
	for c, stat in STATS do
		cell(titles, STAT_ICONS[stat] or stat, NAME_SHARE + (c - 1) * STAT_SHARE, STAT_SHARE, Colors.TextDim)
	end
	for i, player in shown do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, ROW)
		row.BackgroundColor3 = if player == LocalPlayer then Colors.Primary else Colors.PanelLight
		row.BackgroundTransparency = if player == LocalPlayer then 0.5 else 0.7
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		UIKit.Corner(row, 6)
		row.Parent = list
		local hidden = player:GetAttribute("AdminInvis") == true
		local tag = tagOf(player)
		local name = (player.DisplayName:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
		local text = if tag then string.format('<font color="#%s">[%s]</font> %s', TAG_COLORS[tag]:ToHex(), tag, name) else name
		if hidden then
			text ..= ' <font color="#9AA4B2">(hidden)</font>'
		end
		local nameLabel = cell(row, text, 0, NAME_SHARE, if hidden then Colors.TextDim else Colors.Text, Enum.TextXAlignment.Left)
		nameLabel.Position = UDim2.new(0, 6, 0, 3)
		nameLabel.TextTransparency = if hidden then 0.3 else 0
		for c, stat in STATS do
			cell(row, statText(player, stat), NAME_SHARE + (c - 1) * STAT_SHARE, STAT_SHARE)
		end
	end
	local contentHeight = TITLES + GAP + #shown * (ROW + GAP)
	list.CanvasSize = UDim2.fromOffset(0, contentHeight)
	place(HEADER + 4 + contentHeight + 6)
end

local function setOpen(value: boolean)
	open = value
	redraw()
end

function PlayerListUI.Init()
	if initialized then
		return
	end
	initialized = true
	-- Roblox's own list can't leave anyone out, so ours replaces it.
	task.spawn(function()
		for _ = 1, 10 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
			end)
			if ok then
				break
			end
			task.wait(1)
		end
	end)

	local _gui, root = UIKit.CreateScreen("PlayerList", 4)
	panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.BackgroundColor3 = Colors.PanelDark
	panel.BackgroundTransparency = 0.2
	panel.BorderSizePixel = 0
	panel.Size = UDim2.fromOffset(WIDTH, HEADER)
	panel.ClipsDescendants = true
	UIKit.Corner(panel, 10)
	panel.Parent = root

	header = Instance.new("TextButton")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, HEADER)
	header.Font = UIKit.Theme.Fonts.Title
	header.TextSize = if TOUCH then 20 else 16
	header.TextColor3 = Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "  Players"
	header.Parent = panel
	header.MouseButton1Click:Connect(function()
		setOpen(not open)
	end)

	list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(5, HEADER + 2)
	list.Size = UDim2.new(1, -10, 1, -(HEADER + 6))
	list.ScrollBarThickness = 4
	list.CanvasSize = UDim2.new()
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, GAP)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	-- Open on computers, folded up on phones and tablets (tap the header to open).
	open = not UIKit.IsTouch()

	-- The HUD's right-hand buttons, so the list never reaches down over them.
	task.spawn(function()
		local playerGui = LocalPlayer:WaitForChild("PlayerGui")
		local hud = playerGui:WaitForChild("HUD", 30)
		local column = hud and hud:FindFirstChild("RightColumn", true)
		if column and column:IsA("GuiObject") then
			rightColumn = column
			column:GetPropertyChangedSignal("AbsolutePosition"):Connect(redraw)
		end
		redraw()
	end)

	ClientState.Changed:Connect(function(kind)
		if kind == "Run" then
			redraw()
		end
	end)
	UserInputService.InputBegan:Connect(function(input)
		-- (not "processed": Tab can arrive marked as used by Roblox; only skip it while typing)
		if input.KeyCode ~= Enum.KeyCode.Tab or inRun() or UserInputService:GetFocusedTextBox() then
			return
		end
		setOpen(not open)
	end)

	-- Refresh: players coming and going, tags / hidden changing, and the numbers once a second.
	Players.PlayerAdded:Connect(redraw)
	Players.PlayerRemoving:Connect(function()
		task.defer(redraw)
	end)
	task.spawn(function()
		while true do
			redraw()
			task.wait(1)
		end
	end)
end

return PlayerListUI
