--[[
	PlayerListUI - the game's own player list (top right, Tab to show / hide in the lobby).

	Roblox's built-in list can't hide one player, so it's switched off (HUD) and this one is used
	instead. Anyone the admin :invis command made invisible (player attribute AdminInvis) isn't
	listed at all; staff still see them, greyed out and marked (hidden). Each row: the staff / VIP
	tag, the display name, and their Bubbles, Dishes and Rebirths (leaderstats).
	In a run the list steps aside (Tab opens the Upgrade Book there).
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

local WIDTH = 330
local ROW = 30
local STATS = { "Bubbles", "Dishes", "Rebirths" }
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
local list: Frame
local header: TextButton

local function isStaffViewer(): boolean
	return type(LocalPlayer:GetAttribute("StaffTag")) == "string"
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

local function cell(parent: Instance, text: string, x: UDim, w: UDim, color: Color3?, align: Enum.TextXAlignment?): TextLabel
	local label = UIKit.Label({
		Text = text,
		TextSize = 15,
		TextScaled = true,
		RichText = true,
		TextColor3 = color or Colors.Text,
		TextXAlignment = align or Enum.TextXAlignment.Center,
		Position = UDim2.new(x, UDim.new(0, 4)),
		Size = UDim2.new(w, UDim.new(1, -8)),
		Parent = parent,
	})
	return label
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
	header.Text = string.format("  Players (%d)   %s", #shown, if open then "▲" else "▼")
	list.Visible = open
	if not open then
		panel.Size = UDim2.fromOffset(WIDTH, 34)
		return
	end
	-- Column titles.
	local titles = Instance.new("Frame")
	titles.BackgroundTransparency = 1
	titles.Size = UDim2.new(1, 0, 0, 22)
	titles.LayoutOrder = 0
	titles.Parent = list
	cell(titles, "Bubbles", UDim.new(0.52, 0), UDim.new(0.16, 0), Colors.TextDim)
	cell(titles, "Dishes", UDim.new(0.68, 0), UDim.new(0.16, 0), Colors.TextDim)
	cell(titles, "Rebirths", UDim.new(0.84, 0), UDim.new(0.16, 0), Colors.TextDim)
	for i, player in shown do
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, ROW)
		row.BackgroundColor3 = if player == LocalPlayer then Colors.Primary else Colors.PanelLight
		row.BackgroundTransparency = if player == LocalPlayer then 0.5 else 0.7
		row.BorderSizePixel = 0
		row.LayoutOrder = i
		UIKit.Corner(row, 8)
		row.Parent = list
		local hidden = player:GetAttribute("AdminInvis") == true
		local tag = tagOf(player)
		local name = player.DisplayName:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
		local text = if tag then string.format('<font color="#%s">[%s]</font> %s', TAG_COLORS[tag]:ToHex(), tag, name) else name
		if hidden then
			text ..= ' <font color="#9AA4B2">(hidden)</font>'
		end
		local nameLabel = cell(row, text, UDim.new(0, 6), UDim.new(0.52, -6), if hidden then Colors.TextDim else Colors.Text, Enum.TextXAlignment.Left)
		nameLabel.TextTransparency = if hidden then 0.3 else 0
		for c, stat in STATS do
			cell(row, statText(player, stat), UDim.new(0.52 + (c - 1) * 0.16, 0), UDim.new(0.16, 0))
		end
	end
	panel.Size = UDim2.fromOffset(WIDTH, 34 + 4 + 22 + #shown * (ROW + 3) + 8)
end

local function setOpen(value: boolean)
	open = value
	redraw()
end

local function inRun(): boolean
	return ClientState.Run ~= nil
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
	panel.BackgroundTransparency = 0.25
	panel.BorderSizePixel = 0
	panel.Size = UDim2.fromOffset(WIDTH, 34)
	panel.ClipsDescendants = true
	UIKit.Corner(panel, 12)
	panel.Parent = root

	header = Instance.new("TextButton")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 34)
	header.Font = UIKit.Theme.Fonts.Title
	header.TextSize = 18
	header.TextColor3 = Colors.Text
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Text = "  Players"
	header.Parent = panel
	header.MouseButton1Click:Connect(function()
		setOpen(not open)
	end)

	list = Instance.new("Frame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(6, 36)
	list.Size = UDim2.new(1, -12, 1, -40)
	list.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 3)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	-- Open on computers, folded up on phones (tap the header to open).
	open = not UIKit.IsTouch()

	local function place()
		panel.Position = UDim2.new(1, -16, 0, UIKit.TopInset() + 8)
		panel.Visible = not inRun()
	end
	place()
	ClientState.Changed:Connect(function(kind)
		if kind == "Run" then
			place()
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
