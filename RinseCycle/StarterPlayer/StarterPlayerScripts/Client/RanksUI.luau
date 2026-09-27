--[[
	RanksUI - the "Ranks" window (Rank Shrine in the lobby, the HUD's Ranks button, R / gamepad RB).

	Left: your equipped rank (icon, name in its rarity colour, perk), a big ROLL button that costs
	Config.RankRoll.Cost gems, a slot-machine reel that spins while the server rolls, and your gems.
	Right: every rank with its exact odds (x2 Luck applied if you own the pass: gems can be bought with
	Robux, so the odds are always shown before rolling), its perk, and Equip for the ones you own.

	All rolling happens on the server (MetaRequest "RollRank"). A roll REPLACES your rank (there is
	no collection), so rolling again is a gamble; the button stays locked until the reel has landed.
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

local RanksUI = {}

local WINDOW_SIZE = Vector2.new(900, 560)

local initialized = false
local rolling = false

local leftPanel: Frame
local list: ScrollingFrame
local reel: TextLabel
local rollButton: TextButton
local gemsLabel: TextLabel
local luckButton: TextButton

local function rarityColor(rarity: string): Color3
	local r = Config.RankRarities[rarity]
	return if r then r.Color else Colors.Text
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Left panel: current rank + roll
----------------------------------------------------------------------------------------------------

local currentCard: Frame

local function renderCurrent()
	clear(currentCard)
	local meta = ClientState.Meta :: Types.MetaState?
	local rank = meta and Config.GetRank(meta.Rank)
	local color = if rank then rarityColor(rank.Rarity) else Colors.TextDim
	local old = currentCard:FindFirstChildOfClass("UIGradient")
	if old then
		old:Destroy()
	end
	UIKit.Gradient(currentCard, UIKit.Lighten(color, 0.15), UIKit.Darken(color, 0.45))
	UIKit.Label({ Text = "YOUR RANK", TextSize = 18, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 22), Parent = currentCard })
	UIKit.Label({ Text = if rank then rank.Icon else "❔", TextSize = 64, Position = UDim2.fromOffset(0, 32), Size = UDim2.new(1, 0, 0, 70), Stroke = false, Parent = currentCard })
	UIKit.Label({
		Text = if rank then rank.Name else "No rank yet",
		TextSize = 30,
		Position = UDim2.fromOffset(8, 104),
		Size = UDim2.new(1, -16, 0, 34),
		TextScaled = true,
		Parent = currentCard,
	})
	UIKit.Label({
		Text = if rank then string.format("%s  •  %s", rank.Rarity, rank.Desc) else "Roll to get your first rank!",
		TextSize = 16,
		Position = UDim2.fromOffset(8, 140),
		Size = UDim2.new(1, -16, 0, 40),
		TextWrapped = true,
		Parent = currentCard,
	})
end

local function renderGems()
	local meta = ClientState.Meta :: Types.MetaState?
	local gems = if meta then meta.Gems or 0 else 0
	local luck = meta ~= nil and meta.Passes.DoubleLuck == true
	gemsLabel.Text = string.format("You have 💎 %s%s", UIKit.Commas(gems), if luck then "   🍀 x2 Luck!" else "")
	UIKit.SetDisabled(rollButton, rolling or gems < Config.RankRoll.Cost)
	if luckButton then
		local pass = Config.GetPass("DoubleLuck")
		luckButton.Visible = not luck
		local label = luckButton:FindFirstChildWhichIsA("TextLabel", true)
		if label and pass then
			ShopUI.WatchPrice(pass, true, function(price)
				label.Text = string.format("🍀 x2 Luck pass  •  R$ %d", price)
			end)
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Right panel: odds list
----------------------------------------------------------------------------------------------------

local function renderList()
	clear(list)
	local meta = ClientState.Meta :: Types.MetaState?
	local luck = meta ~= nil and meta.Passes.DoubleLuck == true
	local weights, total = Config.RankWeights(luck)
	for i, entry in weights do
		local rank = entry.Rank
		local equipped = meta ~= nil and meta.Rank == rank.Id
		local color = rarityColor(rank.Rarity)
		local row = UIKit.Card({ Size = UDim2.new(1, -8, 0, 68), LayoutOrder = i, Parent = list })
		UIKit.Stroke(row, color, if equipped then 3 else 1.5)
		UIKit.Label({ Text = rank.Icon, TextSize = 30, Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(44, 68), Stroke = false, Parent = row })
		UIKit.Label({
			Text = rank.Name,
			TextSize = 20,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(54, 6),
			Size = UDim2.new(1, -250, 0, 24),
			TextScaled = true,
			Parent = row,
		})
		UIKit.Label({
			Text = rank.Desc,
			TextSize = 14,
			TextColor3 = Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(54, 34),
			Size = UDim2.new(1, -250, 0, 26),
			TextWrapped = true,
			Parent = row,
		})
		UIKit.Label({
			Text = string.format("%s\n%.1f%%", rank.Rarity, entry.Weight / total * 100),
			TextSize = 15,
			TextColor3 = color,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -112, 0.5, 0),
			Size = UDim2.fromOffset(84, 44),
			Parent = row,
		})
		if equipped then
			UIKit.Label({ Text = "✅ Yours", TextSize = 18, TextColor3 = Colors.Good, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(96, 36), Parent = row })
		end
	end
end

local function render()
	renderCurrent()
	renderGems()
	renderList()
end

----------------------------------------------------------------------------------------------------
-- Rolling
----------------------------------------------------------------------------------------------------

local function roll()
	if rolling then
		return
	end
	rolling = true
	renderGems()
	-- Spin the reel while the server decides.
	local spinning = true
	task.spawn(function()
		local i = 0
		while spinning do
			i += 1
			local r = Config.Ranks[(i % #Config.Ranks) + 1]
			reel.Text = r.Icon .. " " .. r.Name
			reel.TextColor3 = rarityColor(r.Rarity)
			UIKit.PlaySound("Click", 1 + (i % 5) * 0.05)
			task.wait(0.07)
		end
	end)
	local result = ClientState.MetaRequest("RollRank")
	task.wait(1.2)
	spinning = false
	rolling = false
	if not result.Ok or not result.Rank then
		reel.Text = "🎲 Roll again!"
		reel.TextColor3 = Colors.Text
		UIKit.Toast(result.Error or "Couldn't roll right now.", "Bad")
		renderGems()
		return
	end
	local rank = Config.GetRank(result.Rank)
	if rank then
		reel.Text = rank.Icon .. " " .. rank.Name .. "!"
		reel.TextColor3 = rarityColor(rank.Rarity)
		UIKit.Bounce(reel)
		UIKit.PlaySound("Hatch")
		local order = Config.RankRarities[rank.Rarity].Order
		if order >= 4 then
			UIKit.Confetti(if order >= 5 then 140 else 90)
		end
		local before = result.Previous and Config.GetRank(result.Previous)
		local lost = if before and before.Id ~= rank.Id then string.format("  (replaced %s %s)", before.Icon, before.Name) else ""
		UIKit.Toast(string.format("%s %s (%s)!%s", rank.Icon, rank.Name, rank.Rarity, lost), if order >= 3 then "Good" else "Info")
	end
	render()
end

function RanksUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, screenRoot = UIKit.CreateScreen("RanksUI", 10)
	local _window, content = UIKit.Window({
		Name = "Ranks",
		Title = "Ranks",
		Icon = "💎",
		Size = WINDOW_SIZE,
		Parent = screenRoot,
	})

	leftPanel = Instance.new("Frame")
	leftPanel.Name = "Left"
	leftPanel.BackgroundTransparency = 1
	leftPanel.Size = UDim2.new(0, 330, 1, 0)
	leftPanel.Parent = content

	currentCard = Instance.new("Frame")
	currentCard.Name = "Current"
	currentCard.Size = UDim2.new(1, 0, 0, 190)
	currentCard.BackgroundColor3 = Color3.new(1, 1, 1)
	currentCard.BorderSizePixel = 0
	UIKit.Corner(currentCard, 16)
	UIKit.Stroke(currentCard, Colors.Ink, 3)
	currentCard.Parent = leftPanel

	reel = UIKit.Label({
		Name = "Reel",
		Text = "🎲 Try your luck!",
		TextSize = 26,
		Position = UDim2.fromOffset(0, 202),
		Size = UDim2.new(1, 0, 0, 40),
		TextScaled = true,
		Parent = leftPanel,
	})

	rollButton = UIKit.Button({
		Text = string.format("🎲 ROLL   💎 %d", Config.RankRoll.Cost),
		Size = UDim2.new(1, 0, 0, 70),
		Position = UDim2.fromOffset(0, 252),
		Color = Colors.Accent,
		TextSize = 30,
		Parent = leftPanel,
		OnClick = function()
			task.spawn(roll)
		end,
	})

	gemsLabel = UIKit.Label({
		Text = "",
		TextSize = 20,
		Position = UDim2.fromOffset(0, 330),
		Size = UDim2.new(1, 0, 0, 26),
		Parent = leftPanel,
	})

	UIKit.Button({
		Text = "💎 Get more Gems",
		Size = UDim2.new(1, 0, 0, 48),
		Position = UDim2.fromOffset(0, 364),
		Color = Colors.Good,
		TextSize = 22,
		Parent = leftPanel,
		OnClick = function()
			UIKit.OpenWindow("Shop", "Gems")
		end,
	})
	luckButton = UIKit.Button({
		Text = "🍀 x2 Luck pass",
		Size = UDim2.new(1, 0, 0, 44),
		Position = UDim2.fromOffset(0, 418),
		Color = Color3.fromRGB(90, 190, 110),
		TextSize = 20,
		Parent = leftPanel,
		OnClick = function()
			ShopUI.BuyPass("DoubleLuck")
		end,
	})
	UIKit.Label({
		Text = "⚠️ A roll replaces your current rank! Rare+ ranks are twice as likely with x2 Luck.",
		TextSize = 14,
		TextColor3 = Colors.Warning,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, 466),
		Size = UDim2.new(1, 0, 0, 36),
		Parent = leftPanel,
	})

	local right = Instance.new("Frame")
	right.Name = "Odds"
	right.BackgroundTransparency = 1
	right.Position = UDim2.fromOffset(346, 0)
	right.Size = UDim2.new(1, -346, 1, 0)
	right.Parent = content
	UIKit.Label({ Text = "ALL RANKS & ODDS", TextSize = 20, Size = UDim2.new(1, 0, 0, 26), Parent = right })
	list = Instance.new("ScrollingFrame")
	list.Position = UDim2.fromOffset(0, 32)
	list.Size = UDim2.new(1, 0, 1, -32)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 8
	list.ScrollBarImageColor3 = Colors.Accent
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = right
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 4)
	pad.Parent = list

	UIKit.RegisterWindow("Ranks", {
		Open = function()
			render()
		end,
	})
	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" and UIKit.IsWindowOpen("Ranks") and not rolling then
			render()
		end
	end)
end

return RanksUI
