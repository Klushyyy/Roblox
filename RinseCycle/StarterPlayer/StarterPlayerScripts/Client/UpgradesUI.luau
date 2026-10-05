--[[
	UpgradesUI - the in-run "Upgrades" window, drawn as an open book:
	  * left page: your current tool (big), its stats, and the four Coins upgrades as cards with a
	    level pip bar, the next-level preview and a buy button
	  * right page: every tool. Buy any of them in any order; owned ones go in your hand with Equip
	    (or the hotbar, keys 1-6). Power and Size are per tool; Tank and Sneakers count for all.

	Only meaningful inside a run, so it closes itself the moment ClientState.Run goes nil. Everything it
	shows comes from ClientState.Run (server-authoritative) and Config's pure helpers.
	Open it with the HUD button, Tab/Q, or gamepad Y.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))
local ShopUI = require(Client:WaitForChild("ShopUI"))

local Colors = UIKit.Theme.Colors

local UpgradesUI = {}

local WINDOW_SIZE = Vector2.new(920, 580)

local PAGE = Color3.fromRGB(252, 246, 228)
local PAGE_EDGE = Color3.fromRGB(226, 212, 176)
local COVER = Color3.fromRGB(40, 90, 170)
local INK = Color3.fromRGB(40, 70, 140)
local INK_DIM = Color3.fromRGB(120, 110, 90)

local initialized = false

local book: Frame
local leftPage: Frame
local rightPage: Frame

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local function fmtNum(n: number): string
	if n ~= n then
		return "0"
	end
	if math.abs(n - math.floor(n + 0.5)) < 0.05 then
		return UIKit.Short(math.floor(n + 0.5))
	end
	return string.format("%.1f", n)
end

local PREVIEW: { [string]: { Label: string, Get: (Types.RunStats) -> number, Suffix: string? } } = {
	-- Size is the circle for scrub/spray tools, the line length for the washer, the splat for foam.
	HandSize = { Label = "Size", Get = function(s) return s.LineLength or s.Radius end },
	ScrubPower = { Label = "Power", Get = function(s) return s.Power end, Suffix = "/s" },
	TankSize = { Label = "Tank", Get = function(s) return s.TankMax end },
	Sneakers = { Label = "Speed", Get = function(s) return s.WalkSpeed end },
}

local function previewStats(run: Types.RunState, upgradeId: string): Types.RunStats
	local meta = ClientState.Meta
	local perks = (meta and meta.Perks) or {}
	local passes = (meta and meta.Passes) or {}
	local petBonus = if meta then Config.PetCoinBonus(meta.Pets, meta.Equipped, meta.PetIndex) else 0
	local nextUpgrades = table.clone(run.Upgrades)
	;(nextUpgrades :: any)[upgradeId] = ((run.Upgrades :: any)[upgradeId] or 0) + 1
	return Config.GetRunStats(run.Level, nextUpgrades, run.ToolIndex, perks, passes, petBonus, meta and meta.Rank or nil, meta and meta.Rebirths or 0)
end

local function buy(action: string, value: any, onRow: GuiObject)
	local result = if action == "BuyTool" then ShopUI.GetTool(value) else ClientState.RunRequest(action, value)
	if not result then
		return -- short of coins: the tool's pass was offered
	end
	if result.Ok then
		UIKit.Bounce(onRow)
		UIKit.PlaySound("Coins")
	else
		UIKit.Toast(result.Error or "Couldn't buy that.", "Bad")
		UIKit.PlaySound("Error")
	end
end

-- Dark "ink" text for the paper pages (no white outline).
local function ink(props: { [string]: any }): TextLabel
	props.TextColor3 = props.TextColor3 or INK
	props.Stroke = false
	return UIKit.Label(props)
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function tile(parent: Instance, size: UDim2, pos: UDim2, color: Color3): Frame
	local f = Instance.new("Frame")
	f.Size = size
	f.Position = pos
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	UIKit.Corner(f, 12)
	UIKit.Stroke(f, PAGE_EDGE, 2)
	f.Parent = parent
	return f
end

----------------------------------------------------------------------------------------------------
-- Left page: current tool + upgrades
----------------------------------------------------------------------------------------------------

local function upgradeCard(parent: Instance, def: any, run: Types.RunState, order: number): Frame
	local level = ((run.Upgrades :: any)[def.Id] :: number?) or 0
	local card = tile(parent, UDim2.new(0.5, -6, 0, 140), UDim2.new(), Color3.fromRGB(255, 252, 240))
	card.Name = def.Id
	card.LayoutOrder = order

	ink({ Text = def.Icon, TextSize = 34, Position = UDim2.fromOffset(8, 6), Size = UDim2.fromOffset(42, 42), Parent = card })
	ink({
		Text = def.Name,
		TextSize = 20,
		Position = UDim2.fromOffset(52, 6),
		Size = UDim2.new(1, -58, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		Parent = card,
	})
	ink({
		Text = string.format("Lv %d/%d  •  %s", level, def.Max, if def.PerTool then "this tool" else "all tools"),
		TextSize = 15,
		TextColor3 = INK_DIM,
		Position = UDim2.fromOffset(52, 28),
		Size = UDim2.new(1, -58, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = card,
	})

	-- Level pips.
	local pips = Instance.new("Frame")
	pips.BackgroundTransparency = 1
	pips.Position = UDim2.fromOffset(10, 54)
	pips.Size = UDim2.new(1, -20, 0, 12)
	pips.Parent = card
	local pipLayout = Instance.new("UIListLayout")
	pipLayout.FillDirection = Enum.FillDirection.Horizontal
	pipLayout.Padding = UDim.new(0, 2)
	pipLayout.Parent = pips
	for i = 1, def.Max do
		local pip = Instance.new("Frame")
		pip.Size = UDim2.new(1 / def.Max, -2, 1, 0)
		pip.BackgroundColor3 = if i <= level then Colors.Good else Color3.fromRGB(220, 210, 185)
		pip.BorderSizePixel = 0
		UIKit.Corner(pip, 3)
		pip.Parent = pips
	end

	local spec = PREVIEW[def.Id]
	local previewText = def.Desc
	if spec then
		local now = spec.Get(run.Stats)
		if level < def.Max then
			previewText = string.format("%s %s → %s%s", spec.Label, fmtNum(now), fmtNum(spec.Get(previewStats(run, def.Id))), spec.Suffix or "")
		else
			previewText = string.format("%s %s%s (max)", spec.Label, fmtNum(now), spec.Suffix or "")
		end
	end
	ink({
		Text = previewText,
		TextSize = 16,
		Position = UDim2.fromOffset(10, 69),
		Size = UDim2.new(1, -20, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		Parent = card,
	})

	local cost = Config.UpgradeCost(def.Id, level, run.Level, run.ToolIndex)
	UIKit.Button({
		Text = if cost then UIKit.Short(cost) .. " coins" else "MAX",
		Size = UDim2.new(1, -20, 0, 42),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Color = if cost then Colors.Good else Colors.Disabled,
		Disabled = cost == nil or run.Coins < (cost or 0),
		Sound = if cost then nil else false,
		Parent = card,
		OnClick = function()
			if cost then
				buy("BuyUpgrade", def.Id, card)
			end
		end,
	})
	return card
end

local function renderLeft(run: Types.RunState)
	clear(leftPage)
	local tool = Config.Tools[run.ToolIndex] or Config.Tools[1]
	ink({ Text = "In your hand", TextSize = 34, Size = UDim2.new(1, 0, 0, 38), Parent = leftPage })

	-- Current tool banner.
	local banner = tile(leftPage, UDim2.new(1, 0, 0, 92), UDim2.fromOffset(0, 42), Color3.fromRGB(255, 252, 240))
	local iconTile = tile(banner, UDim2.fromOffset(76, 76), UDim2.fromOffset(8, 8), tool.Color)
	UIKit.Label({ Text = tool.Icon, TextSize = 46, Size = UDim2.fromScale(1, 1), Stroke = false, Parent = iconTile })
	ink({
		Text = tool.Name,
		TextSize = 26,
		Position = UDim2.fromOffset(94, 8),
		Size = UDim2.new(1, -100, 0, 30),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		Parent = banner,
	})
	local s = run.Stats
	ink({
		Text = string.format(
			"Power %s/s   %s   Reach %s",
			fmtNum(s.Power),
			if s.Mode == "Line" then "Line " .. fmtNum(s.LineLength or 0)
				elseif s.Mode == "Foam" then "Splat " .. fmtNum(s.Radius)
				else "Size " .. fmtNum(s.Radius),
			fmtNum(s.Reach)
		),
		TextSize = 16,
		TextColor3 = INK_DIM,
		Position = UDim2.fromOffset(94, 42),
		Size = UDim2.new(1, -100, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		Parent = banner,
	})
	ink({
		Text = tool.Desc,
		TextSize = 14,
		TextColor3 = INK_DIM,
		Position = UDim2.fromOffset(94, 64),
		Size = UDim2.new(1, -100, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextScaled = true,
		Parent = banner,
	})

	local grid = Instance.new("Frame")
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromOffset(0, 144)
	grid.Size = UDim2.new(1, 0, 1, -144)
	grid.Parent = leftPage
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0.5, -6, 0, 140)
	layout.CellPadding = UDim2.fromOffset(12, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	for i, def in Config.Upgrades do
		upgradeCard(grid, def, run, i)
	end
end

----------------------------------------------------------------------------------------------------
-- Right page: tool ladder + money
----------------------------------------------------------------------------------------------------

local function toolCard(parent: Instance, index: number, run: Types.RunState): Frame
	local tool = Config.Tools[index]
	local owned = run.OwnedTools ~= nil and run.OwnedTools[index] == true
	local inHand = index == run.ToolIndex
	local card = tile(parent, UDim2.fromOffset(120, 140), UDim2.new(), if owned then Color3.fromRGB(225, 250, 230) else Color3.fromRGB(255, 252, 240))
	card.LayoutOrder = index
	if inHand then
		UIKit.Stroke(card, Colors.Good, 3)
	end

	local iconTile = tile(card, UDim2.fromOffset(72, 58), UDim2.new(0.5, -36, 0, 8), tool.Color)
	UIKit.Label({ Text = tool.Icon, TextSize = 38, Size = UDim2.fromScale(1, 1), Stroke = false, Parent = iconTile })
	ink({
		Text = tool.Name,
		TextSize = 16,
		Position = UDim2.fromOffset(4, 68),
		Size = UDim2.new(1, -8, 0, 20),
		TextScaled = true,
		Parent = card,
	})

	if inHand then
		ink({
			Text = "In hand",
			TextSize = 16,
			TextColor3 = Color3.fromRGB(40, 150, 80),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -12),
			Size = UDim2.new(1, -8, 0, 22),
			Parent = card,
		})
	elseif owned then
		UIKit.Button({
			Text = "Equip",
			Size = UDim2.new(1, -14, 0, 40),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -6),
			Color = Colors.Primary,
			Parent = card,
			OnClick = function()
				buy("EquipTool", index, card)
			end,
		})
	else
		local cost = Config.ToolCost(index, run.Level) or 0
		UIKit.Button({
			Text = UIKit.Short(cost) .. " coins",
			Size = UDim2.new(1, -14, 0, 40),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -6),
			Color = Colors.Coin,
			TextColor3 = Colors.Text,
			Disabled = run.Coins < cost,
			Parent = card,
			OnClick = function()
				buy("BuyTool", index, card)
			end,
		})
	end
	return card
end

local function renderRight(run: Types.RunState)
	clear(rightPage)
	ink({ Text = "Tools (any order!)", TextSize = 30, Size = UDim2.new(1, 0, 0, 38), Parent = rightPage })

	local grid = Instance.new("Frame")
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromOffset(0, 44)
	grid.Size = UDim2.new(1, 0, 1, -110)
	grid.Parent = rightPage
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(120, 140)
	layout.CellPadding = UDim2.fromOffset(12, 12)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	for i in Config.Tools do
		toolCard(grid, i, run)
	end

	local money = Instance.new("Frame")
	money.BackgroundTransparency = 1
	money.AnchorPoint = Vector2.new(0.5, 1)
	money.Position = UDim2.new(0.5, 0, 1, -6)
	money.Size = UDim2.new(1, 0, 0, 50)
	money.Parent = rightPage
	ink({
		Text = "your money:",
		TextSize = 24,
		Size = UDim2.new(0.5, 0, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = money,
	})
	UIKit.Label({
		Text = UIKit.Commas(run.Coins) .. " coins",
		TextSize = 30,
		TextColor3 = Color3.fromRGB(90, 235, 110),
		Position = UDim2.new(0.5, 10, 0, 0),
		Size = UDim2.new(0.5, -10, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = money,
	})
end

----------------------------------------------------------------------------------------------------
-- Render / init
----------------------------------------------------------------------------------------------------

local function render()
	local run = ClientState.Run
	if not run then
		return
	end
	renderLeft(run)
	renderRight(run)
end

local function buildBook(content: Frame)
	book = Instance.new("Frame")
	book.Name = "Book"
	book.Size = UDim2.fromScale(1, 1)
	book.BackgroundColor3 = COVER
	book.BorderSizePixel = 0
	UIKit.Corner(book, 18)
	UIKit.Stroke(book, Colors.Ink, 3)
	book.Parent = content

	local function page(x: UDim, name: string): Frame
		local p = Instance.new("Frame")
		p.Name = name
		p.Position = UDim2.new(x.Scale, x.Offset, 0, 10)
		p.Size = UDim2.new(0.5, -18, 1, -20)
		p.BackgroundColor3 = PAGE
		p.BorderSizePixel = 0
		UIKit.Corner(p, 12)
		UIKit.Gradient(p, PAGE, Color3.fromRGB(245, 236, 210))
		UIKit.Stroke(p, PAGE_EDGE, 2)
		p.Parent = book
		local inner = Instance.new("Frame")
		inner.Name = "Inner"
		inner.BackgroundTransparency = 1
		inner.Size = UDim2.fromScale(1, 1)
		inner.Parent = p
		UIKit.Padding(inner, 14)
		return inner
	end
	leftPage = page(UDim.new(0, 12), "LeftPage")
	rightPage = page(UDim.new(0.5, 6), "RightPage")

	-- Spine rings down the middle.
	for i = 0, 7 do
		local ring = Instance.new("Frame")
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.new(0.5, 0, (i + 0.5) / 8, 0)
		ring.Size = UDim2.fromOffset(16, 26)
		ring.BackgroundColor3 = Color3.fromRGB(230, 190, 90)
		ring.BorderSizePixel = 0
		ring.ZIndex = 3
		UIKit.Corner(ring, 999)
		UIKit.Stroke(ring, Color3.fromRGB(120, 90, 30), 2)
		ring.Parent = book
	end
end

function UpgradesUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, screenRoot = UIKit.CreateScreen("UpgradesUI", 10)

	local _window, windowContent = UIKit.Window({
		Name = "Upgrades",
		Title = "Upgrades",
		Icon = "📖",
		Size = WINDOW_SIZE,
		Parent = screenRoot,
	})
	buildBook(windowContent)

	UIKit.RegisterWindow("Upgrades", {
		Open = function()
			if not ClientState.InRun() then
				task.defer(UIKit.CloseWindow, "Upgrades")
				return
			end
			render()
		end,
	})

	ClientState.Changed:Connect(function(kind)
		if kind == "Run" then
			if not ClientState.Run then
				if UIKit.IsWindowOpen("Upgrades") then
					UIKit.CloseWindow("Upgrades")
				end
			elseif UIKit.IsWindowOpen("Upgrades") then
				render()
			end
		elseif kind == "Meta" and UIKit.IsWindowOpen("Upgrades") then
			render()
		end
	end)
end

return UpgradesUI
