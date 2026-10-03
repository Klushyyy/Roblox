--[[
	StayOffer - "WAIT! Don't leave yet!" When a player opens the Roblox menu (usually on the way to
	Leave), they're offered a free x2 cleaning boost for 15 minutes, once a day
	(DataService.ClaimStayBoost; saved to their data, so leaving and rejoining can't claim it twice).
	The popup is big and loud on purpose: it sits behind Roblox's menu, so it's the first thing they
	see the moment they close it.

	Also the boost badges: a row of small chips under the Bubbles pill showing what's boosting you
	right now - "x2 Cleaning 14:32" while the stay boost runs, and one chip per owned multiplier
	pass (x2 Coins, x2 Bubbles, x2 Luck, ...).
]]

local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))

local StayOffer = {}

local Colors = UIKit.Theme.Colors

-- Passes that multiply something, in the order their chips appear.
local PASS_BADGES = {
	{ Key = "DoubleCoins", Text = "x2 Coins", Color = Colors.Coin },
	{ Key = "DoubleBubbles", Text = "x2 Bubbles", Color = Colors.Bubble },
	{ Key = "DoubleLuck", Text = "x2 Luck", Color = Colors.Good },
	{ Key = "LuckyCharm", Text = "x2 Gold Dirt", Color = Colors.Coin },
	{ Key = "MegaTank", Text = "x2 Tank", Color = Colors.Primary },
	{ Key = "SuperScrub", Text = "+50% Clean", Color = Colors.Primary },
	{ Key = "VIP", Text = "VIP +25%", Color = Colors.Coin },
}

local initialized = false
local offeredThisSession = false

local function boostLeft(): number
	local meta = ClientState.Meta :: any
	local untilTime = meta and tonumber(meta.BoostUntil) or 0
	return math.max(0, untilTime - os.time())
end

local function claim()
	local result = ClientState.MetaRequest("ClaimStayBoost")
	UIKit.CloseWindow("StayOffer")
	if result.Ok then
		UIKit.PlaySound("Sparkle")
		UIKit.Confetti(80)
		UIKit.Toast(result.Message or "x2 Cleaning for 15 minutes!", "Good")
	else
		UIKit.Toast(result.Error or "Couldn't claim that.", "Info")
	end
end

-- Grows and shrinks a GUI forever (while it's visible), to pull the eye.
local function pulse(gui: GuiObject, amount: number, period: number)
	local scale = Instance.new("UIScale")
	scale.Parent = gui
	local tween = TweenService:Create(
		scale,
		TweenInfo.new(period / 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Scale = 1 + amount }
	)
	tween:Play()
end

local function badge(parent: GuiObject, text: string, color: Color3, order: number, width: number?): (Frame, TextLabel)
	local chip = Instance.new("Frame")
	chip.Name = "Badge"
	chip.LayoutOrder = order
	chip.Size = UDim2.fromOffset(width or (#text * 10 + 18), 26)
	chip.BackgroundColor3 = color
	chip.BorderSizePixel = 0
	chip.Visible = false
	UIKit.Corner(chip, 8)
	UIKit.Stroke(chip, Colors.Ink, 2)
	local label = UIKit.Label({
		Text = text,
		TextSize = 16,
		Size = UDim2.fromScale(1, 1),
		Parent = chip,
	})
	chip.Parent = parent
	return chip, label
end

function StayOffer.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, root = UIKit.CreateScreen("StayOffer", 35)
	local _window, content = UIKit.Window({
		Name = "StayOffer",
		Title = "Before you go...",
		Size = Vector2.new(940, 580), -- as big as the screen allows (windows shrink to fit)
		Parent = root,
	})
	local headline = UIKit.Label({
		Text = "WAIT! DON'T LEAVE YET!",
		TextSize = 72,
		TextScaled = true,
		TextColor3 = Colors.Bad,
		Size = UDim2.new(1, -40, 0, 82),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Parent = content,
	})
	pulse(headline, 0.06, 0.9)
	UIKit.Label({
		Text = "FREE x2 Cleaning Speed for 15 minutes!",
		TextSize = 44,
		TextScaled = true,
		TextColor3 = Colors.Coin,
		Size = UDim2.new(1, -60, 0, 54),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Parent = content,
	})
	UIKit.Label({
		Text = "Everything you and your pets clean counts DOUBLE. Only once a day, and it's gone if you leave now!",
		TextSize = 26,
		TextWrapped = true,
		Size = UDim2.new(1, -80, 0, 70),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 158),
		Parent = content,
	})
	local claimButton = UIKit.Button({
		Text = "CLAIM x2 BOOST!",
		Color = Colors.Good,
		TextSize = 52,
		Size = UDim2.new(1, -160, 0, 110),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 244),
		Parent = content,
		OnClick = function()
			task.spawn(claim)
		end,
	})
	pulse(claimButton, 0.05, 0.8)
	UIKit.Button({
		Text = "No thanks, I'll leave",
		Color = Colors.Disabled,
		TextSize = 18,
		Size = UDim2.fromOffset(260, 44),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 378),
		Parent = content,
		OnClick = function()
			UIKit.CloseWindow("StayOffer")
		end,
	})
	UIKit.RegisterWindow("StayOffer", { Open = function() end })

	-- Boost badges, in a row under the Bubbles pill.
	local row = Instance.new("Frame")
	row.Name = "BoostBadges"
	row.AnchorPoint = Vector2.new(0.5, 0)
	row.Position = UDim2.new(0.5, 0, 0, 60)
	row.Size = UDim2.fromOffset(900, 26)
	row.BackgroundTransparency = 1
	row.Parent = root
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = row

	local boostChip, boostLabel = badge(row, "", Colors.Good, 0, 170)
	local passChips = {}
	for i, def in PASS_BADGES do
		passChips[def.Key] = badge(row, def.Text, def.Color, i)
	end

	local function cutscenePlaying(): boolean
		local ok, playing = pcall(function()
			return (require(Client:WaitForChild("Cutscene")) :: any).IsPlaying()
		end)
		return ok and playing == true
	end

	task.spawn(function()
		while true do
			local meta = ClientState.Meta :: any
			local passes = meta and meta.Passes or {}
			row.Visible = not cutscenePlaying()
			local left = boostLeft()
			boostChip.Visible = left > 0
			if left > 0 then
				boostLabel.Text = string.format("x2 Cleaning %d:%02d", left // 60, left % 60)
			end
			for key, chip in passChips do
				chip.Visible = passes[key] == true
			end
			task.wait(1)
		end
	end)

	-- Opening the Roblox menu: offer today's boost (once a session, and only if it's still free).
	GuiService.MenuOpened:Connect(function()
		local meta = ClientState.Meta :: any
		if offeredThisSession or not meta or meta.StayBoostReady ~= true or boostLeft() > 0 then
			return
		end
		offeredThisSession = true
		UIKit.OpenWindow("StayOffer")
	end)
end

return StayOffer
