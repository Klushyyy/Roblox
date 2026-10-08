--[[
	StayOffer - "WAIT! Don't leave yet!" When a player opens the Roblox menu (usually on the way to
	Leave), they're offered a free x2 cleaning boost for 15 minutes, once a day
	(DataService.ClaimStayBoost; saved to their data, so leaving and rejoining can't claim it twice).
	The popup is big and loud on purpose: it sits behind Roblox's menu, so it's the first thing they
	see the moment they close it.

	Also the boost badges: a column of small chips beside the left-hand buttons showing what's boosting you
	right now - "x2 Cleaning 14:32" while the stay boost runs, and one chip per owned multiplier
	pass (x2 Coins, x2 Bubbles, x2 Luck, ...).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))

local StayOffer = {}

local Colors = UIKit.Theme.Colors

-- Passes that multiply something, in the order their chips appear: grouped by colour (green
-- next to the green x2 Cleaning chip, then yellows, blues, pink).
local PASS_BADGES = {
	{ Key = "DoubleLuck", Text = "x2 Luck", Color = Colors.Good },
	{ Key = "DoubleCoins", Text = "x2 Coins", Color = Colors.Coin },
	{ Key = "LuckyCharm", Text = "x2 Gold Dirt", Color = Colors.Coin },
	{ Key = "VIP", Text = "VIP +25%", Color = Colors.Coin },
	{ Key = "MegaTank", Text = "x2 Tank", Color = Colors.Primary },
	{ Key = "SuperScrub", Text = "+50% Clean", Color = Colors.Primary },
	{ Key = "DoubleBubbles", Text = "x2 Bubbles", Color = Colors.Bubble },
	{ Key = "Premium", Text = "Premium +10%", Color = Colors.Bubble }, -- Roblox Premium members (Config.Premium)
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

local BADGE_WIDTH = 124 -- fits the longest, "x2 Clean 14:59"
local BADGE_HEIGHT = 22
local BADGE_GAP = 4
local BADGES_PER_COLUMN = 4

local function badge(parent: GuiObject, text: string, color: Color3, order: number, width: number?): (Frame, TextLabel)
	local chip = Instance.new("Frame")
	chip.Name = "Badge"
	chip.LayoutOrder = order
	chip.Size = UDim2.fromOffset(width or BADGE_WIDTH, BADGE_HEIGHT) -- all one width, so they line up
	chip.BackgroundColor3 = color
	chip.BorderSizePixel = 0
	chip.Visible = false
	UIKit.Corner(chip, 7)
	UIKit.Stroke(chip, Colors.Ink, 2)
	local label = UIKit.Label({
		Text = text,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(8, 0),
		Size = UDim2.new(1, -10, 1, 0),
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
	local subtitle = UIKit.Label({
		Text = "FREE x2 Cleaning Speed for 15 minutes!",
		TextSize = 44,
		TextScaled = true,
		TextColor3 = Colors.Coin,
		Size = UDim2.new(1, -60, 0, 54),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 96),
		Parent = content,
	})
	local bodyText = UIKit.Label({
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
	local leaveButton = UIKit.Button({
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

	-- Two faces of the same window: the daily boost, and (only from the moment the Admin Abuse countdown starts
	-- until the show is over) "don't leave, the event is on / about to start".
	local function setMode(eventNote: string?)
		local event = eventNote ~= nil
		headline.Text = if event then "DON'T LEAVE!" else "WAIT! DON'T LEAVE YET!"
		subtitle.Text = eventNote or "FREE x2 Cleaning Speed for 15 minutes!"
		bodyText.Text = if event then "Free ranks, free game passes, limited pets and giveaways. You'd miss all of it." else "Everything you and your pets clean counts DOUBLE. Only once a day, and it's gone if you leave now!"
		claimButton.Visible = not event
		leaveButton.Text = if event then "Stay" else "No thanks, I'll leave"
		local label = leaveButton:FindFirstChild("Label", true)
		if label and label:IsA("TextLabel") then
			label.Text = leaveButton.Text
		end
		leaveButton.Position = UDim2.new(0.5, 0, 0, if event then 250 else 378)
	end

	-- Boost badges: a neat column just right of the left-hand buttons (Daily, Codes, ...), clear of
	-- the Bubbles pill, the pop-up messages, the run's progress bar and Roblox's player list.
	local row = Instance.new("Frame")
	row.Name = "BoostBadges"
	row.AnchorPoint = Vector2.new(0, 0)
	row.Position = UDim2.fromOffset(108, 140)
	row.Size = UDim2.fromOffset(BADGE_WIDTH, 300)
	row.BackgroundTransparency = 1
	-- Its own screen layer under every window (HUD is 5, windows 10+), so menus cover the badges.
	local _badgeGui, badgeRoot = UIKit.CreateScreen("BoostBadges", 4)
	row.Parent = badgeRoot
	-- Laid out by hand: columns of BADGES_PER_COLUMN, the next column to the right
	-- (1-2-3-4, then 1-2-3), so the stack never gets taller than four.

	-- Above the HUD's left column (it moves for phones, the thumbstick and runs; on PC the HUD
	-- slides it down to make room, from the "BadgeStackHeight" attribute). If there isn't room
	-- above it (phones), beside it instead.
	local function placeRow(count: number)
		local rows = math.min(count, BADGES_PER_COLUMN)
		local height = if rows > 0 then rows * (BADGE_HEIGHT + BADGE_GAP) - BADGE_GAP else 0
		if Players.LocalPlayer:GetAttribute("BadgeStackHeight") ~= height then
			Players.LocalPlayer:SetAttribute("BadgeStackHeight", height)
		end
		local hud = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
		local column = hud and hud:FindFirstChild("LeftColumn", true)
		local inset = UIKit.TopInset()
		if column and column:IsA("GuiObject") and column.Visible and column.AbsoluteSize.Y > 0 then
			local colH = column.AbsoluteSize.Y / UIKit.GetScale()
			local colTop = column.Position.Y.Offset - colH / 2
			local x = column.Position.X.Offset
			if colTop - 10 - height >= inset + 6 then
				row.Position = UDim2.fromOffset(x, math.floor(colTop - 10 - height))
			else
				row.Position = UDim2.fromOffset(x + column.Size.X.Offset + 12, math.floor(colTop + 4))
			end
		else
			local safe = UIKit.SafeInsets()
			row.Position = UDim2.fromOffset(16 + math.floor(safe.Left * 0.5), math.floor(inset + 90))
		end
	end

	local boostChip, boostLabel = badge(row, "", Colors.Good, 0)
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
				boostLabel.Text = string.format("x2 Clean %d:%02d", left // 60, left % 60)
			end
			local shown = {}
			if left > 0 then
				table.insert(shown, boostChip)
			end
			for _, def in PASS_BADGES do
				local chip = passChips[def.Key]
				chip.Visible = passes[def.Key] == true
				if chip.Visible then
					table.insert(shown, chip)
				end
			end
			for i, chip in shown do
				local col, line = (i - 1) // BADGES_PER_COLUMN, (i - 1) % BADGES_PER_COLUMN
				chip.Position = UDim2.fromOffset(col * (BADGE_WIDTH + BADGE_GAP + 2), line * (BADGE_HEIGHT + BADGE_GAP))
			end
			row.Size = UDim2.fromOffset(BADGE_WIDTH * 2 + BADGE_GAP + 2, 300)
			placeRow(#shown)
			task.wait(1)
		end
	end)

	-- Opening the Roblox menu: offer today's boost (once a session, and only if it's still free).
	local lastEventNote = 0
	GuiService.MenuOpened:Connect(function()
		-- (the schedule comes from the replicated attributes: the server may have moved the show's time, which
		-- the client's own copy of Config does not know)
		local nowT = Config.Now()
		local starts = tonumber(ReplicatedStorage:GetAttribute("AbuseStarts"))
		local pre = Config.AbuseShow.PreSeconds
		local locked = ReplicatedStorage:GetAttribute("AbuseLive") == true
			or (starts ~= nil and starts - nowT > 0 and starts - nowT <= pre)
			or Config.EventLockdown()
		if locked then
			if os.clock() - lastEventNote > 20 then
				lastEventNote = os.clock()
				local left = if starts then starts - Config.Now() else 0
				setMode(if left > 0 then string.format("Admin Abuse starts in %d minute%s!", math.ceil(left / 60), if math.ceil(left / 60) == 1 then "" else "s") else "The Admin Abuse event is on right now!")
				UIKit.OpenWindow("StayOffer")
			end
			return
		end
		setMode(nil)
		local meta = ClientState.Meta :: any
		if offeredThisSession or not meta or meta.StayBoostReady ~= true or boostLeft() > 0 then
			return
		end
		offeredThisSession = true
		ClientState.Track("stay.offer")
		UIKit.OpenWindow("StayOffer")
	end)
end

return StayOffer
