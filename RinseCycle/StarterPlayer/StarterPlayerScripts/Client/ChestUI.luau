--[[
	ChestUI - the Treasure Chest event window (HUD "Event" button, and the chest in the lobby).

	Left: the event (name, time left), the FREE chest while you have one, and the three packs. The
	packs are priced like cinema popcorn: x1 is fine, x3 looks barely better (greyed and small, on
	purpose), and x10 is the big gold "BEST VALUE" one.
	Right: WHAT'S INSIDE, every reward with its exact chance (Config.ChestEvent.Rewards).

	Opening: the free chest asks EventService (ChestRequest "Free"); bought packs open on the server
	when Roblox confirms the purchase and the results arrive on ChestResult. Either way the reveal
	popup flips the results in one by one.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local ChestUI = {}

local Colors = UIKit.Theme.Colors
local LocalPlayer = Players.LocalPlayer

local initialized = false
local busy = false
local freeButton: TextButton
local freeNote: TextLabel
local timeLabel: TextLabel
local reveal: Frame
local revealGrid: Frame
local revealTitle: TextLabel

local function rewardColor(r: any): Color3
	if r.Kind == "Bubbles" then
		return Colors.Bubble
	elseif r.Kind == "Gems" then
		return Colors.Primary
	elseif r.Kind == "Boost" then
		return Colors.Good
	elseif r.Kind == "Pet" then
		local pet = Config.Pets[r.Pet]
		if (r.Tier or 1) > 1 then
			return Config.PetTiers[r.Tier].Color or Colors.Coin
		end
		local rarity = pet and Config.Rarities[pet.Rarity]
		return if rarity then rarity.Color else Colors.Accent
	end
	return Colors.Coin
end

local function rewardIcon(r: any): string
	if r.Kind == "Bubbles" then
		return "Bubble"
	elseif r.Kind == "Gems" then
		return "Gem"
	elseif r.Kind == "Boost" then
		return "Drop"
	elseif r.Kind == "Pet" then
		return "Paw"
	end
	return "Crown"
end

local function isBig(r: any): boolean
	return r.Kind == "Pass" or (r.Kind == "Pet" and r.Chance <= 5)
end

local function timeLeft(): string
	local left = math.max(0, Config.ChestEvent.Ends - os.time())
	if left <= 0 then
		return "Event over"
	end
	local d, h, m = left // 86400, (left % 86400) // 3600, (left % 3600) // 60
	if d > 0 then
		return string.format("Ends in %dd %02dh", d, h)
	end
	return string.format("Ends in %dh %02dm", h, m)
end

----------------------------------------------------------------------------------------------------
-- Reveal
----------------------------------------------------------------------------------------------------

local function showResults(results: { any })
	if type(results) ~= "table" or #results == 0 then
		return
	end
	for _, child in revealGrid:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local layout = revealGrid:FindFirstChildOfClass("UIGridLayout") :: UIGridLayout
	local many = #results > 5
	layout.CellSize = if many then UDim2.fromOffset(130, 130) else UDim2.fromOffset(150, 170)
	revealTitle.Text = if #results == 1 then "YOU GOT" else string.format("%d CHESTS OPENED", #results)
	reveal.Visible = true
	UIKit.Bounce(reveal)
	UIKit.PlaySound("Sparkle")
	local best = false
	for i, res in results do
		local def = Config.ChestEvent.Rewards[tonumber(res.Index) or 0]
		local color = if def then rewardColor(def) else Colors.Coin
		local card = UIKit.Card({ Name = "Result", Color = UIKit.Darken(color, 0.55), LayoutOrder = i, Parent = revealGrid })
		UIKit.Stroke(card, color, 3, 0)
		local icon = UIKit.Icon(if def then rewardIcon(def) else "Star", if many then 56 else 70, {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 10),
		})
		icon.Parent = card
		UIKit.Label({
			Text = tostring(res.Text),
			TextSize = 16,
			TextScaled = true,
			TextWrapped = true,
			TextColor3 = color,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Size = UDim2.new(1, -12, 0, if many then 44 else 56),
			Parent = card,
		})
		local scale = Instance.new("UIScale")
		scale.Scale = 0
		scale.Parent = card
		TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		if def and isBig(def) then
			best = true
		end
		UIKit.PlaySound("Pop", 0.9 + i * 0.04)
		task.wait(if many then 0.12 else 0.25)
	end
	if best then
		UIKit.Confetti(120)
		UIKit.PlaySound("Sparkle", 1.2)
	end
end

----------------------------------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------------------------------

local function refresh()
	local meta = ClientState.Meta :: any
	local free = if meta then tonumber(meta.ChestFreeLeft) or 0 else 0
	local live = Config.ChestEventLive()
	freeButton.Visible = free > 0 and live
	freeNote.Visible = not freeButton.Visible
	local opened = if meta then tonumber(meta.ChestsOpened) or 0 else 0
	freeNote.Text = if not live
		then "This event has ended. See you at the next one!"
		elseif opened > 0 then string.format("Free chest opened! You've opened %d chests.", opened)
		else "Free chest opened!"
	timeLabel.Text = timeLeft()
end

local function openFree()
	if busy then
		return
	end
	busy = true
	UIKit.SetDisabled(freeButton, true)
	local result = Remotes.Function("ChestRequest"):InvokeServer("Free")
	busy = false
	UIKit.SetDisabled(freeButton, false)
	if result and result.Ok then
		task.spawn(showResults, result.Rewards)
	else
		UIKit.Toast(result and result.Error or "Couldn't open that.", "Info")
	end
	refresh()
end

local function buy(pack: any)
	local id = Config.EventProducts[pack.Key]
	if type(id) == "number" and id > 0 then
		pcall(function()
			MarketplaceService:PromptProductPurchase(LocalPlayer, id)
		end)
		return
	end
	-- No product yet: Studio test (free), "coming soon" in a live game.
	if busy then
		return
	end
	busy = true
	local result = Remotes.Function("ChestRequest"):InvokeServer("Test", pack.Count)
	busy = false
	if result and result.Ok then
		task.spawn(showResults, result.Rewards)
	else
		UIKit.Toast(result and result.Error or "Coming soon!", "Info")
	end
end

-- One pack card. `style`: "plain", "decoy" (the x3: dull and small) or "best" (the x10).
local function packCard(parent: Frame, pack: any, style: string, x: number, width: number, height: number)
	local base = Config.ChestEvent.Packs[1]
	local each = pack.Price / pack.Count
	local save = math.floor((1 - each / (base.Price / base.Count)) * 100 + 0.5)
	local color = if style == "best" then Colors.Coin elseif style == "decoy" then Colors.Disabled else Colors.Primary
	local card = UIKit.Card({
		Name = "Pack" .. pack.Count,
		Color = if style == "best" then UIKit.Darken(Colors.Coin, 0.5) else Colors.PanelLight,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, x, 1, 0),
		Size = UDim2.fromOffset(width, height),
		Parent = parent,
	})
	UIKit.Stroke(card, color, if style == "best" then 4 else 2, 0)
	local iconSize = if style == "best" then 86 elseif style == "decoy" then 50 else 60
	local icon = UIKit.Icon("Chest", iconSize, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, if style == "best" then 30 else 14) })
	icon.Parent = card
	UIKit.Label({
		Text = string.format("x%d", pack.Count),
		TextSize = if style == "best" then 34 else 26,
		TextColor3 = if style == "decoy" then Colors.TextDim else Colors.Text,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, iconSize + (if style == "best" then 30 else 14)),
		Size = UDim2.new(1, -10, 0, 34),
		Parent = card,
	})
	UIKit.Label({
		Text = if save > 0 then string.format("%d R$ each  (save %d%%)", math.floor(each + 0.5), save) else string.format("%d R$ each", pack.Price),
		TextSize = if style == "best" then 16 else 13,
		TextColor3 = if style == "best" then Colors.Good else Colors.TextDim,
		TextScaled = true,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, if style == "best" then -66 else -58),
		Size = UDim2.new(1, -12, 0, 18),
		Parent = card,
	})
	UIKit.Button({
		Text = string.format("R$ %d", pack.Price),
		Color = if style == "best" then Colors.Good elseif style == "decoy" then Colors.Disabled else Colors.Primary,
		TextSize = if style == "best" then 26 else 18,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(1, -16, 0, if style == "best" then 52 else 44),
		Parent = card,
		OnClick = function()
			task.spawn(buy, pack)
		end,
	})
	if pack.Tag then
		local ribbon = Instance.new("Frame")
		ribbon.Name = "Ribbon"
		ribbon.AnchorPoint = Vector2.new(0.5, 0.5)
		ribbon.Position = UDim2.new(0.5, 0, 0, 2)
		ribbon.Size = UDim2.fromOffset(width - 30, 30)
		ribbon.BackgroundColor3 = Colors.Bad
		ribbon.ZIndex = 6
		UIKit.Corner(ribbon, 15)
		UIKit.Stroke(ribbon, Colors.Ink, 2)
		UIKit.Label({ Text = pack.Tag, TextSize = 18, Size = UDim2.fromScale(1, 1), ZIndex = 7, Parent = ribbon })
		ribbon.Parent = card
		-- A slow pulse so the eye lands on it first.
		local scale = Instance.new("UIScale")
		scale.Parent = card
		TweenService:Create(scale, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.04 }):Play()
	end
	return card
end

function ChestUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, screenRoot = UIKit.CreateScreen("ChestUI", 10)
	local _window, content = UIKit.Window({
		Name = "Chest",
		Title = "Treasure Chests",
		Icon = "@Chest",
		Size = Vector2.new(920, 580),
		Parent = screenRoot,
	})

	local left = Instance.new("Frame")
	left.Name = "Left"
	left.BackgroundTransparency = 1
	left.Size = UDim2.new(1, -316, 1, 0)
	left.Parent = content

	-- The event header.
	local header = UIKit.Card({ Name = "Header", Size = UDim2.new(1, 0, 0, 132), Color = Colors.PanelDark, Parent = left })
	UIKit.Gradient(header, Color3.fromRGB(30, 110, 150), Color3.fromRGB(12, 40, 80))
	local headIcon = UIKit.Icon("Chest", 100, { Position = UDim2.fromOffset(14, 16) })
	headIcon.Parent = header
	UIKit.Label({
		Text = string.upper(Config.ChestEvent.Name),
		TextSize = 30,
		TextScaled = true,
		TextColor3 = Colors.Coin,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(128, 10),
		Size = UDim2.new(1, -140, 0, 36),
		Parent = header,
	})
	timeLabel = UIKit.Label({
		Text = "",
		TextSize = 18,
		TextColor3 = Colors.Bad,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(128, 46),
		Size = UDim2.new(1, -140, 0, 22),
		Parent = header,
	})
	freeButton = UIKit.Button({
		Text = "OPEN FREE CHEST",
		Color = Colors.Good,
		TextSize = 22,
		Position = UDim2.fromOffset(128, 74),
		Size = UDim2.new(1, -144, 0, 48),
		Parent = header,
		OnClick = function()
			task.spawn(openFree)
		end,
	})
	freeNote = UIKit.Label({
		Text = "",
		TextSize = 16,
		TextWrapped = true,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(128, 74),
		Size = UDim2.new(1, -144, 0, 48),
		Parent = header,
	})

	-- The packs, bottom-aligned: x1, x3 (the decoy), x10 (the big one).
	local packs = Instance.new("Frame")
	packs.Name = "Packs"
	packs.BackgroundTransparency = 1
	packs.Position = UDim2.fromOffset(0, 150)
	packs.Size = UDim2.new(1, 0, 1, -150)
	packs.Parent = left
	local list = Config.ChestEvent.Packs
	packCard(packs, list[1], "plain", 0, 164, 236)
	packCard(packs, list[2], "decoy", 176, 148, 214)
	packCard(packs, list[3], "best", 336, 238, 296)

	-- Odds.
	local right = UIKit.Card({
		Name = "Odds",
		Color = Colors.PanelDark,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Size = UDim2.new(0, 300, 1, 0),
		Parent = content,
	})
	UIKit.Label({ Text = "WHAT'S INSIDE", TextSize = 20, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 24), Parent = right })
	local odds = Instance.new("ScrollingFrame")
	odds.Name = "List"
	odds.BackgroundTransparency = 1
	odds.BorderSizePixel = 0
	odds.Position = UDim2.fromOffset(8, 40)
	odds.Size = UDim2.new(1, -16, 1, -48)
	odds.ScrollBarThickness = 6
	odds.AutomaticCanvasSize = Enum.AutomaticSize.Y
	odds.CanvasSize = UDim2.new()
	odds.Parent = right
	local oddsLayout = Instance.new("UIListLayout")
	oddsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	oddsLayout.Padding = UDim.new(0, 6)
	oddsLayout.Parent = odds
	for i, r in Config.ChestEvent.Rewards do
		local color = rewardColor(r)
		local row = UIKit.Card({ Name = "Reward", Size = UDim2.new(1, -8, 0, 40), LayoutOrder = i, Parent = odds })
		UIKit.Stroke(row, color, if isBig(r) then 2.5 else 1, 0)
		local icon = UIKit.Icon(rewardIcon(r), 28, { Position = UDim2.fromOffset(6, 6) })
		icon.Parent = row
		UIKit.Label({
			Text = Config.ChestRewardName(r),
			TextSize = 15,
			TextScaled = true,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(40, 6),
			Size = UDim2.new(1, -110, 0, 28),
			Parent = row,
		})
		UIKit.Label({
			Text = if r.Chance < 1 then string.format("%.1f%%", r.Chance) else string.format("%g%%", r.Chance),
			TextSize = 17,
			TextXAlignment = Enum.TextXAlignment.Right,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -8, 0, 6),
			Size = UDim2.fromOffset(64, 28),
			Parent = row,
		})
	end

	-- The reveal popup (over everything).
	local _rgui, revealRoot = UIKit.CreateScreen("ChestReveal", 40)
	reveal = Instance.new("Frame")
	reveal.Name = "Reveal"
	reveal.AnchorPoint = Vector2.new(0.5, 0.5)
	reveal.Position = UDim2.fromScale(0.5, 0.5)
	reveal.Size = UDim2.fromOffset(780, 470)
	reveal.BackgroundColor3 = Colors.PanelDark
	reveal.Visible = false
	UIKit.Corner(reveal, 18)
	UIKit.Stroke(reveal, Colors.Coin, 4, 0)
	reveal.Parent = revealRoot
	revealTitle = UIKit.Label({ Text = "YOU GOT", TextSize = 36, TextColor3 = Colors.Coin, Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 44), Parent = reveal })
	revealGrid = Instance.new("Frame")
	revealGrid.Name = "Grid"
	revealGrid.BackgroundTransparency = 1
	revealGrid.Position = UDim2.fromOffset(20, 66)
	revealGrid.Size = UDim2.new(1, -40, 1, -146)
	revealGrid.Parent = reveal
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(10, 10)
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.VerticalAlignment = Enum.VerticalAlignment.Center
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = revealGrid
	UIKit.Button({
		Text = "AWESOME!",
		Color = Colors.Good,
		TextSize = 24,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(240, 56),
		Parent = reveal,
		OnClick = function()
			reveal.Visible = false
			refresh()
		end,
	})

	UIKit.RegisterWindow("Chest", {
		Open = function()
			refresh()
		end,
	})
	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" and UIKit.IsWindowOpen("Chest") then
			refresh()
		end
	end)
	Remotes.Event("ChestResult").OnClientEvent:Connect(function(results)
		task.spawn(showResults, results)
	end)
	task.spawn(function()
		while true do
			task.wait(30)
			if UIKit.IsWindowOpen("Chest") then
				timeLabel.Text = timeLeft()
			end
		end
	end)
end

-- Opens the window (the lobby chest's prompt).
function ChestUI.Open()
	UIKit.OpenWindow("Chest")
end

return ChestUI
