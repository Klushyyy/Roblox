--[[
	RanksUI - the "Ranks" window (Rank Shrine in the lobby, the HUD's Ranks button, R / gamepad RB).

	Left: your equipped rank (icon, name in its rarity colour, perk), a big ROLL button that costs
	Config.RankRoll.Cost gems, and your gems. Rolling opens a full-screen popup: a slot reel of rank
	cards spins while the server rolls, slows down and lands on your new rank (the Insta Roll pass
	skips the spin).
	Right: every rank with its exact odds (x2 Luck applied if you own the pass: gems can be bought with
	Robux, so the odds are always shown before rolling), its perk, and Equip for the ones you own.

	All rolling happens on the server (MetaRequest "RollRank"). A roll REPLACES your rank (there is
	no collection), so rolling again is a gamble; the button stays locked until the reel has landed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

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
local luckActive: Frame? = nil
local adButton: TextButton
local luckSummary: TextLabel
local watchingAd = false

-- Your luck right now: the total multiplier (Config.LuckMult), ad stacks and seconds left on them.
local function currentLuck(meta: any): (number, number, number)
	local hasPass = meta ~= nil and meta.Passes.DoubleLuck == true
	local left = if meta then math.max(0, (tonumber(meta.AdLuckUntil) or 0) - os.time()) else 0
	local stacks = if left > 0 then math.clamp(tonumber(meta.AdLuckStacks) or 0, 0, Config.RankRoll.AdLuck.MaxAds) else 0
	return Config.LuckMult(hasPass, stacks), stacks, left
end

local function multText(mult: number): string
	local s = string.format("%.1f", mult)
	return "x" .. (string.gsub(s, "%.0$", ""))
end

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
	gemsLabel.Text = string.format("You have %s Gems", UIKit.Commas(gems))
	UIKit.SetDisabled(rollButton, rolling) -- short of gems, Roll opens the Gems shop instead
	if luckActive then
		luckActive.Visible = luck
	end
	if adButton then
		local mult, stacks, left = currentLuck(meta)
		local ad = Config.RankRoll.AdLuck
		local label = adButton:FindFirstChildWhichIsA("TextLabel", true)
		if label then
			label.Text = if watchingAd
				then "Loading ad..."
				else string.format("+%d%% Luck  WATCH AD (%d/%d)", math.floor(ad.PerAd * 100 + 0.5), stacks, ad.MaxAds)
		end
		UIKit.SetDisabled(adButton, watchingAd)
		if mult > 1 then
			luckSummary.Text = if left > 0
				then string.format("LUCK %s  •  ads end in %d:%02d", multText(mult), left // 60, left % 60)
				else string.format("LUCK %s", multText(mult))
			luckSummary.TextColor3 = Colors.Good
		else
			luckSummary.Text = string.format("Watch %d ads for x2 luck (x4 with the pass)", ad.MaxAds)
			luckSummary.TextColor3 = Colors.TextDim
		end
	end
	if luckButton then
		local pass = Config.GetPass("DoubleLuck")
		luckButton.Visible = not luck
		local label = luckButton:FindFirstChildWhichIsA("TextLabel", true)
		if label and pass then
			ShopUI.WatchPrice(pass, true, function(price)
				label.Text = string.format("x2 Luck  R$ %d", price)
			end)
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Right panel: odds list
----------------------------------------------------------------------------------------------------

local function pct(chance: number): string
	return if chance < 1 then string.format("%.2f%%", chance) else string.format("%.1f%%", chance)
end

local function renderList()
	clear(list)
	local meta = ClientState.Meta :: Types.MetaState?
	local mult = currentLuck(meta)
	local luck = mult > 1
	local weights, total = Config.RankWeights(mult)
	-- The chances both ways, so a boosted rank can show what it was / what it would be.
	local plain, plainTotal = Config.RankWeights(false)
	local lucky, luckyTotal = Config.RankWeights(true)
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
		local boosted = Config.RankRarities[rank.Rarity].Order >= 3
		local chance = entry.Weight / total * 100
		UIKit.Label({
			Text = string.format("%s\n%s", rank.Rarity, pct(chance)),
			TextSize = 15,
			TextColor3 = color,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -112, 0, if boosted then 4 else 12),
			Size = UDim2.fromOffset(96, 40),
			Parent = row,
		})
		if boosted then
			-- With luck (pass and/or ads): a green "x2.6" on the row and what the chance was without
			-- it. Without: what it would be with the pass.
			local other = if luck then plain[i].Weight / plainTotal * 100 else lucky[i].Weight / luckyTotal * 100
			UIKit.Label({
				Text = if luck then "was " .. pct(other) else "x2 Luck: " .. pct(other),
				TextSize = 12,
				TextColor3 = if luck then Colors.TextDim else Colors.Good,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -112, 0, 46),
				Size = UDim2.fromOffset(96, 16),
				Parent = row,
			})
			if luck then
				local tag = Instance.new("Frame")
				tag.Name = "LuckTag"
				tag.Position = UDim2.fromOffset(4, 4)
				tag.Size = UDim2.fromOffset(36, 18)
				tag.BackgroundColor3 = Colors.Good
				tag.ZIndex = 3
				UIKit.Corner(tag, 9)
				UIKit.Label({ Text = multText(mult), TextSize = 13, Size = UDim2.fromScale(1, 1), ZIndex = 4, Parent = tag })
				tag.Parent = row
			end
		end
		if equipped then
			UIKit.Label({ Text = "Yours", TextSize = 18, TextColor3 = Colors.Good, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(96, 36), Parent = row })
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

----------------------------------------------------------------------------------------------------
-- Roll popup: a full-screen slot reel. Rank cards race past a gold marker, slow down and stop on
-- the rank the server rolled, then the result is revealed (rarity banner, glow, confetti for Epic+).
-- The Insta Roll pass skips the spin and shows the result straight away.
----------------------------------------------------------------------------------------------------
local CARD_W, CARD_GAP = 136, 12
local PITCH = CARD_W + CARD_GAP
local REEL_W, REEL_H = 780, 176
local SPIN_SPEED = 1900 -- px/s while waiting for the server
local CARD_COUNT = 90

local roll: () -> ()
local popupGui: ScreenGui? = nil
local popup: {
	Dim: TextButton,
	Panel: Frame,
	Title: TextLabel,
	Strip: Frame,
	Cards: { Frame },
	Result: Frame,
	Buttons: Frame,
	Again: TextButton,
	Insta: TextButton,
}? = nil

local function pickWeighted(weights: { any }, total: number): any
	local x = math.random() * total
	for _, e in weights do
		x -= e.Weight
		if x <= 0 then
			return e.Rank
		end
	end
	return weights[#weights].Rank
end

local function paintCard(card: Frame, rank: any)
	local color = rarityColor(rank.Rarity)
	card.BackgroundColor3 = UIKit.Darken(color, 0.55)
	local stroke = card:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = color
	end
	local icon = card:FindFirstChild("Icon") :: TextLabel
	local name = card:FindFirstChild("RankName") :: TextLabel
	local bar = card:FindFirstChild("Bar") :: Frame
	icon.Text = rank.Icon
	name.Text = rank.Name
	name.TextColor3 = UIKit.Lighten(color, 0.35)
	bar.BackgroundColor3 = color
end

local function makeCard(parent: Instance, index: number): Frame
	local card = Instance.new("Frame")
	card.Name = "Card" .. index
	card.Size = UDim2.fromOffset(CARD_W, REEL_H - 24)
	card.Position = UDim2.fromOffset((index - 1) * PITCH, 12)
	card.BorderSizePixel = 0
	UIKit.Corner(card, 14)
	UIKit.Stroke(card, Colors.Text, 3)
	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 170))
	grad.Rotation = 90
	grad.Parent = card
	UIKit.Label({ Name = "Icon", Text = "", TextSize = 56, Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 70), Stroke = false, Parent = card })
	UIKit.Label({ Name = "RankName", Text = "", TextSize = 20, Position = UDim2.fromOffset(8, 88), Size = UDim2.new(1, -16, 0, 30), TextScaled = true, Parent = card })
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.BorderSizePixel = 0
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.new(0.5, 0, 1, -8)
	bar.Size = UDim2.new(1, -24, 0, 6)
	UIKit.Corner(bar, 3)
	bar.Parent = card
	card.Parent = parent
	return card
end

local function ensurePopup()
	if popup then
		return popup
	end
	local gui, root = UIKit.CreateScreen("RankRollPopup", 40)
	popupGui = gui
	gui.Enabled = false

	local dim = Instance.new("TextButton") -- a button so clicks don't fall through to the world
	dim.Name = "Dim"
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Color3.fromRGB(4, 10, 26)
	dim.BackgroundTransparency = 0.3
	dim.BorderSizePixel = 0
	dim.Parent = root

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(REEL_W + 60, 460)
	panel.BackgroundTransparency = 1
	panel.Parent = root
	local panelScale = Instance.new("UIScale")
	panelScale.Name = "PopScale"
	panelScale.Parent = panel

	local title = UIKit.Label({ Name = "Title", Text = "ROLLING...", TextSize = 46, Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 0, 50), Parent = panel })

	-- The reel window.
	local reelFrame = Instance.new("Frame")
	reelFrame.Name = "Reel"
	reelFrame.AnchorPoint = Vector2.new(0.5, 0)
	reelFrame.Position = UDim2.new(0.5, 0, 0, 64)
	reelFrame.Size = UDim2.fromOffset(REEL_W, REEL_H)
	reelFrame.BackgroundColor3 = Color3.fromRGB(14, 24, 48)
	reelFrame.ClipsDescendants = true
	reelFrame.BorderSizePixel = 0
	UIKit.Corner(reelFrame, 18)
	UIKit.Stroke(reelFrame, Colors.Ink, 4)
	reelFrame.Parent = panel
	local strip = Instance.new("Frame")
	strip.Name = "Strip"
	strip.BackgroundTransparency = 1
	strip.Size = UDim2.fromOffset(CARD_COUNT * PITCH, REEL_H)
	strip.Parent = reelFrame
	local cards = {}
	for i = 1, CARD_COUNT do
		cards[i] = makeCard(strip, i)
	end
	-- Fade the edges so cards slide in and out of darkness.
	for _, side in { 0, 1 } do
		local fade = Instance.new("Frame")
		fade.Name = "Fade"
		fade.BorderSizePixel = 0
		fade.BackgroundColor3 = Color3.fromRGB(14, 24, 48)
		fade.AnchorPoint = Vector2.new(side, 0)
		fade.Position = UDim2.fromScale(side, 0)
		fade.Size = UDim2.new(0, 120, 1, 0)
		fade.ZIndex = 3
		local g = Instance.new("UIGradient")
		g.Transparency = if side == 0 then NumberSequence.new(0, 1) else NumberSequence.new(1, 0)
		g.Parent = fade
		fade.Parent = reelFrame
	end
	-- Gold marker down the middle with a pointer at each end.
	local marker = Instance.new("Frame")
	marker.Name = "Marker"
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Position = UDim2.new(0.5, 0, 0, 64 + REEL_H / 2)
	marker.Size = UDim2.fromOffset(4, REEL_H + 8)
	marker.BackgroundTransparency = 1 -- just the two pointers: a line would cover the card's name
	marker.BorderSizePixel = 0
	marker.ZIndex = 4
	marker.Parent = panel
	for _, y in { 0, 1 } do
		local tip = Instance.new("Frame")
		tip.Name = "Pointer"
		tip.AnchorPoint = Vector2.new(0.5, 0.5)
		tip.Position = UDim2.fromScale(0.5, y)
		tip.Size = UDim2.fromOffset(22, 22)
		tip.Rotation = 45
		tip.BackgroundColor3 = Color3.fromRGB(255, 214, 70)
		tip.BorderSizePixel = 0
		tip.ZIndex = 4
		UIKit.Stroke(tip, Colors.Ink, 2)
		tip.Parent = marker
	end

	-- Result text under the reel.
	local result = Instance.new("Frame")
	result.Name = "Result"
	result.BackgroundTransparency = 1
	result.Position = UDim2.fromOffset(0, 64 + REEL_H + 12)
	result.Size = UDim2.new(1, 0, 0, 110)
	result.Parent = panel
	UIKit.Label({ Name = "Rarity", Text = "", TextSize = 38, Size = UDim2.new(1, 0, 0, 40), Parent = result })
	UIKit.Label({ Name = "Perk", Text = "", TextSize = 21, Position = UDim2.fromOffset(20, 42), Size = UDim2.new(1, -40, 0, 26), TextWrapped = true, Parent = result })
	UIKit.Label({ Name = "Replaced", Text = "", TextSize = 15, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(20, 72), Size = UDim2.new(1, -40, 0, 22), Parent = result })

	local buttons = Instance.new("Frame")
	buttons.Name = "Buttons"
	buttons.BackgroundTransparency = 1
	buttons.Position = UDim2.fromOffset(0, 64 + REEL_H + 128)
	buttons.Size = UDim2.new(1, 0, 0, 60)
	buttons.Parent = panel
	local again = UIKit.Button({
		Text = string.format("Roll again (%d Gems)", Config.RankRoll.Cost),
		Size = UDim2.fromOffset(300, 56),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(0.5, -8, 0, 0),
		Color = Colors.Accent,
		TextSize = 22,
		Parent = buttons,
		OnClick = function()
			task.spawn(roll)
		end,
	})
	UIKit.Button({
		Text = "Close",
		Size = UDim2.fromOffset(180, 56),
		Position = UDim2.new(0.5, 8, 0, 0),
		Color = Colors.PanelLight,
		TextSize = 22,
		Parent = buttons,
		OnClick = function()
			gui.Enabled = false
		end,
	})
	-- Offered while the reel spins (the spin itself is the ad for it).
	local insta = UIKit.Button({
		Text = "Insta Roll pass: skip the spin",
		Size = UDim2.fromOffset(320, 44),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 64 + REEL_H + 40),
		Color = Color3.fromRGB(250, 190, 40),
		TextSize = 18,
		Parent = panel,
		OnClick = function()
			ShopUI.BuyPass("InstaRoll")
		end,
	})
	local pass = Config.GetPass("InstaRoll")
	if pass then
		local label = insta:FindFirstChildWhichIsA("TextLabel", true)
		ShopUI.WatchPrice(pass, true, function(price)
			if label then
				label.Text = string.format("Insta Roll pass: skip the spin  •  R$ %d", price)
			end
		end)
	end

	popup = { Dim = dim, Panel = panel, Title = title, Strip = strip, Cards = cards, Result = result, Buttons = buttons, Again = again, Insta = insta }
	return popup
end

local function setResultText(rank: any?, previous: string?)
	local pp = ensurePopup()
	local rarity = pp.Result:FindFirstChild("Rarity") :: TextLabel
	local perk = pp.Result:FindFirstChild("Perk") :: TextLabel
	local replaced = pp.Result:FindFirstChild("Replaced") :: TextLabel
	if not rank then
		rarity.Text, perk.Text, replaced.Text = "", "", ""
		return
	end
	rarity.Text = string.upper(rank.Rarity) .. "!  " .. rank.Name
	rarity.TextColor3 = rarityColor(rank.Rarity)
	perk.Text = rank.Desc
	local before = previous and Config.GetRank(previous)
	replaced.Text = if before and before.Id ~= rank.Id then string.format("(replaced %s %s)", before.Icon, before.Name) else ""
end

local function celebrate(rank: any, card: Frame?)
	local pp = ensurePopup()
	local order = Config.RankRarities[rank.Rarity].Order
	pp.Title.Text = if order >= 5 then "INCREDIBLE!" elseif order >= 4 then "AMAZING!" elseif order >= 3 then "NICE!" else "YOU GOT"
	pp.Title.TextColor3 = if order >= 3 then rarityColor(rank.Rarity) else Colors.Text
	setResultText(rank, nil)
	UIKit.Bounce(pp.Title)
	if card then
		UIKit.Bounce(card)
		local glow = card:FindFirstChildOfClass("UIStroke")
		if glow then
			glow.Thickness = 6
		end
	end
	UIKit.PlaySound("Hatch")
	if order >= 4 then
		UIKit.Confetti(if order >= 5 then 140 else 90)
	elseif order >= 3 then
		UIKit.PlaySound("Sparkle")
	end
end

-- Spins the reel until `getResult()` returns a rank id (or false on failure), then lands on it.
-- Returns once the reel has stopped.
local function spinReel(getResult: () -> any, weights: { any }, total: number): boolean
	local pp = ensurePopup()
	local cards = pp.Cards
	for _, card in cards do
		paintCard(card, pickWeighted(weights, total))
		local stroke = card:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Thickness = 3
		end
	end
	local centre = REEL_W / 2 - CARD_W / 2 -- strip offset that puts card 1 under the marker
	local offset = 0 -- how far the strip has scrolled left
	pp.Strip.Position = UDim2.fromOffset(centre, 0)
	local lastTick = 0
	local function place(o: number)
		offset = o
		pp.Strip.Position = UDim2.fromOffset(math.floor(centre - o + 0.5), 0)
		local passed = math.floor((o + CARD_W / 2) / PITCH)
		if passed ~= lastTick then
			lastTick = passed
			UIKit.PlaySound("Click", 1.1 + (passed % 3) * 0.06)
		end
	end

	-- Phase 1: full speed until the server answers (at least half a second, for the feel).
	local started = os.clock()
	local result = nil
	while true do
		local dt = RunService.RenderStepped:Wait()
		place(offset + SPIN_SPEED * dt)
		result = getResult()
		if result ~= nil and os.clock() - started > 0.5 then
			break
		end
		if offset > (CARD_COUNT - 30) * PITCH then
			offset = 0 -- very slow server: loop the strip (the cards are random anyway)
		end
	end
	if result == false then
		return false
	end
	local rank = Config.GetRank(result)
	if not rank then
		return false
	end

	-- Phase 2: pick a landing card ~18 cards ahead, paint it with the result, and ease out onto it
	-- (a cubic ease-out whose starting speed matches the spin, so there is no jolt).
	local target = math.floor(offset / PITCH) + 18
	paintCard(cards[target], rank)
	local jitter = (math.random() - 0.5) * CARD_W * 0.6
	local land = (target - 1) * PITCH + jitter
	local distance = land - offset
	local duration = 3 * distance / SPIN_SPEED
	local from = offset
	local t = 0
	while t < duration do
		t += RunService.RenderStepped:Wait()
		local k = math.min(t / duration, 1)
		place(from + distance * (1 - (1 - k) ^ 3))
	end
	-- Settle onto the middle of the card.
	local settleFrom = offset
	local settle = 0
	while settle < 0.3 do
		settle += RunService.RenderStepped:Wait()
		local k = math.min(settle / 0.3, 1)
		local e = k * k * (3 - 2 * k)
		place(settleFrom + ((target - 1) * PITCH - settleFrom) * e)
	end
	celebrate(rank, cards[target])
	return true
end

local function showPopup(instant: boolean)
	local pp = ensurePopup()
	-- Insta Roll: rolling again from an open popup just swaps the card (no pop-in, no flicker).
	if instant and popupGui and popupGui.Enabled then
		pp.Insta.Visible = false
		return
	end
	if popupGui then
		popupGui.Enabled = true
	end
	pp.Title.Text = if instant then "" else "ROLLING..."
	pp.Title.TextColor3 = Colors.Text
	setResultText(nil)
	pp.Buttons.Visible = instant
	local meta = ClientState.Meta :: Types.MetaState?
	pp.Insta.Visible = not instant and not (meta ~= nil and meta.Passes.InstaRoll == true)
	local scale = pp.Panel:FindFirstChild("PopScale") :: UIScale
	scale.Scale = 0.85
	TweenService:Create(scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function finishPopup(ok: boolean)
	local pp = ensurePopup()
	pp.Insta.Visible = false
	pp.Buttons.Visible = true
	UIKit.SetDisabled(pp.Again, false) -- short of gems, it opens the Gems shop
	if not ok then
		pp.Title.Text = "Couldn't roll"
		pp.Title.TextColor3 = Colors.Bad
	end
end

local queued = false -- an Insta Roll click that came in while the last answer was on its way

local function roll_()
	-- Not enough gems: straight to the Gems shop.
	local metaNow = ClientState.Meta :: Types.MetaState?
	if not rolling and (if metaNow then metaNow.Gems or 0 else 0) < Config.RankRoll.Cost then
		if popupGui then
			popupGui.Enabled = false
		end
		UIKit.Toast(string.format("You need %d Gems to roll. Get more here!", Config.RankRoll.Cost), "Info")
		UIKit.OpenWindow("Shop", "Gems")
		return
	end
	if rolling then
		local meta = ClientState.Meta :: Types.MetaState?
		if meta ~= nil and meta.Passes.InstaRoll == true then
			queued = true
		end
		return
	end
	rolling = true
	renderGems()
	local meta = ClientState.Meta :: Types.MetaState?
	local instant = meta ~= nil and meta.Passes.InstaRoll == true
	local weights, total = Config.RankWeights((currentLuck(meta)))
	showPopup(instant)

	-- Ask the server in the background; the reel spins until it answers.
	local answer: any = nil
	local response: any = nil
	task.spawn(function()
		local r = ClientState.MetaRequest("RollRank")
		response = r
		answer = if r and r.Ok and r.Rank then r.Rank else false
	end)

	local ok
	if instant then
		while answer == nil do
			RunService.RenderStepped:Wait()
		end
		ok = answer ~= false
		local rank = ok and Config.GetRank(answer)
		if rank then
			local pp = ensurePopup()
			-- Just the one card, dead centre.
			pp.Strip.Position = UDim2.fromOffset(REEL_W / 2 - CARD_W / 2, 0)
			for i, card in pp.Cards do
				card.Visible = i == 1
			end
			paintCard(pp.Cards[1], rank)
			celebrate(rank, pp.Cards[1])
		end
	else
		local pp = ensurePopup()
		for _, card in pp.Cards do
			card.Visible = true
		end
		ok = spinReel(function()
			return answer
		end, weights, total)
	end
	if ok and response then
		local rank = Config.GetRank(response.Rank)
		setResultText(rank, response.Previous)
		if rank then
			reel.Text = rank.Icon .. " " .. rank.Name
			reel.TextColor3 = rarityColor(rank.Rarity)
		end
	elseif response and response.Error then
		UIKit.Toast(response.Error, "Bad")
	end
	rolling = false
	finishPopup(ok)
	render()
	if queued then
		queued = false
		if ok and instant then
			task.defer(roll)
		end
	end
end

roll = function()
	local ok, err = pcall(roll_)
	if not ok then
		rolling = false
		warn("[RanksUI] roll failed: " .. tostring(err))
		finishPopup(false)
	end
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
	currentCard.Size = UDim2.new(1, 0, 0, 184)
	currentCard.BackgroundColor3 = Color3.new(1, 1, 1)
	currentCard.BorderSizePixel = 0
	UIKit.Corner(currentCard, 16)
	UIKit.Stroke(currentCard, Colors.Ink, 3)
	currentCard.Parent = leftPanel

	reel = UIKit.Label({
		Name = "Reel",
		Text = "Try your luck!",
		TextSize = 26,
		Position = UDim2.fromOffset(0, 190),
		Size = UDim2.new(1, 0, 0, 32),
		TextScaled = true,
		Parent = leftPanel,
	})

	rollButton = UIKit.Button({
		Text = string.format("ROLL  (%d Gems)", Config.RankRoll.Cost),
		Size = UDim2.new(1, 0, 0, 62),
		Position = UDim2.fromOffset(0, 228),
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
		Position = UDim2.fromOffset(0, 296),
		Size = UDim2.new(1, 0, 0, 24),
		Parent = leftPanel,
	})

	-- Two side by side: the x2 Luck pass (or "x2 LUCK OWNED") and the rewarded ad.
	luckButton = UIKit.Button({
		Text = "x2 Luck pass",
		Size = UDim2.new(0.5, -4, 0, 46),
		Position = UDim2.fromOffset(0, 330),
		Color = Color3.fromRGB(90, 190, 110),
		TextSize = 15,
		Parent = leftPanel,
		OnClick = function()
			ShopUI.BuyPass("DoubleLuck")
		end,
	})
	-- When you own x2 Luck: a clear green badge where the buy button was.
	local active = Instance.new("Frame")
	active.Name = "LuckActive"
	active.Size = UDim2.new(0.5, -4, 0, 46)
	active.Position = UDim2.fromOffset(0, 330)
	active.BackgroundColor3 = Colors.Good
	active.Visible = false
	UIKit.Corner(active, 12)
	UIKit.Stroke(active, Color3.fromRGB(220, 255, 230), 3, 0)
	UIKit.Label({ Text = "x2 LUCK OWNED", TextSize = 18, Size = UDim2.fromScale(1, 1), Parent = active })
	active.Parent = leftPanel
	luckActive = active
	adButton = UIKit.Button({
		Text = "WATCH AD",
		Size = UDim2.new(0.5, -4, 0, 46),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 330),
		Color = Colors.Primary,
		TextSize = 14,
		Parent = leftPanel,
		OnClick = function()
			if watchingAd then
				return
			end
			watchingAd = true
			renderGems()
			task.spawn(function()
				local result = ClientState.MetaRequest("WatchLuckAd")
				watchingAd = false
				if result.Ok then
					UIKit.PlaySound("Sparkle")
					UIKit.Toast(result.Message or "+20% Luck!", "Good")
				else
					UIKit.Toast(result.Error or "No ad available right now.", "Info")
				end
				render()
			end)
		end,
	})
	luckSummary = UIKit.Label({
		Name = "LuckSummary",
		Text = "",
		TextSize = 16,
		TextScaled = true,
		Position = UDim2.fromOffset(0, 380),
		Size = UDim2.new(1, 0, 0, 22),
		Parent = leftPanel,
	})
	UIKit.Label({
		Text = "A roll replaces your current rank! Luck makes Rare ranks and higher more likely.",
		TextSize = 14,
		TextColor3 = Colors.Warning,
		TextWrapped = true,
		TextScaled = true,
		Position = UDim2.fromOffset(0, 408),
		Size = UDim2.new(1, 0, 0, 38),
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
	-- The ad luck countdown; the odds change back when it runs out.
	task.spawn(function()
		local wasActive = false
		while true do
			task.wait(1)
			if UIKit.IsWindowOpen("Ranks") and not rolling then
				local _mult, stacks = currentLuck(ClientState.Meta)
				renderGems()
				if wasActive and stacks == 0 then
					renderList()
				end
				wasActive = stacks > 0
			end
		end
	end)
end

return RanksUI
