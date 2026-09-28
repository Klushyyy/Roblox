-- Always-on heads-up display, laid out like the big round-based simulators:
--   * top centre: the Bubbles pill with a green "+" (opens the Shop)
--   * right side: big square buttons (Shop/Pets in the lobby, Upgrades/Pets/Leave in a run) with
--     key hints for keyboard (Tab/G/P) or gamepad (Y/LB)
--   * in a run: coins + tank bottom-left, the timer bottom-right, dishwasher progress top-centre
--   * the run-start banner, the results screen and the Leave confirmation
-- On touch the corner widgets move clear of the thumbstick and jump button. See DESIGN.md section 6 "HUD". Everything here is built once in Init() and then only
-- shown/hidden/updated, so there's nothing to leak: no per-run instances, no per-run connections
-- besides the ones this module owns for its whole lifetime.

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Colors = UIKit.Theme.Colors

local LocalPlayer = Players.LocalPlayer

local HUD = {}

-- The owner-only Admin button (AdminClient asks for it once the server confirms the owner). It
-- sits under Free in the left column and, unlike Daily / Codes / Free, stays there in runs too.
local adminClick: (() -> ())? = nil
local addAdminButton: (() -> ())? = nil
local adminButton: TextButton? = nil

function HUD.AddAdminButton(onClick: () -> ())
	adminClick = onClick
	if addAdminButton then
		addAdminButton()
	end
end
local initialized = false

----------------------------------------------------------------------------------------------------
-- Init
----------------------------------------------------------------------------------------------------

function HUD.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, root = UIKit.CreateScreen("HUD", 5)

	--------------------------------------------------------------------------------------------------
	-- Top centre: the Bubbles pill with a green "+" (opens the shop), like every simulator's.
	--------------------------------------------------------------------------------------------------
	local topCurrency = Instance.new("Frame")
	topCurrency.Name = "TopCurrency"
	topCurrency.AnchorPoint = Vector2.new(0.5, 0)
	topCurrency.Size = UDim2.fromOffset(250, 54)
	topCurrency.BackgroundColor3 = Color3.new(1, 1, 1)
	topCurrency.BorderSizePixel = 0
	UIKit.Corner(topCurrency, 16)
	UIKit.Gradient(topCurrency, Color3.fromRGB(120, 130, 145), Color3.fromRGB(70, 78, 92))
	UIKit.Stroke(topCurrency, Colors.Ink, 3)
	topCurrency.Parent = root

	UIKit.Icon("Bubble", 40, { Position = UDim2.fromOffset(10, 7), Parent = topCurrency })
	local bubblesValue = UIKit.Label({
		Name = "Value",
		Text = "0",
		TextSize = 38,
		Position = UDim2.fromOffset(58, 0),
		Size = UDim2.new(1, -120, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = topCurrency,
	})
	local plusButton = UIKit.Button({
		Name = "Plus",
		Text = "+",
		Size = UDim2.fromOffset(46, 46),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -6, 0.5, 0),
		Color = Colors.Good,
		TextSize = 34,
		CornerRadius = 10,
		Parent = topCurrency,
		OnClick = function()
			UIKit.OpenWindow("Shop", "Bubbles")
		end,
	})

	-- Count-up animation for the Bubbles number.
	local bubblesNV = Instance.new("NumberValue")
	bubblesNV.Parent = topCurrency
	bubblesNV:GetPropertyChangedSignal("Value"):Connect(function()
		bubblesValue.Text = UIKit.Commas(math.floor(bubblesNV.Value + 0.5))
	end)
	local bubblesShown = -1
	local function setBubbles(value: number)
		value = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
		if value == bubblesShown then
			return
		end
		local increased = bubblesShown >= 0 and value > bubblesShown
		if bubblesShown < 0 then
			bubblesNV.Value = value
			bubblesValue.Text = UIKit.Commas(value)
		else
			UIKit.Tween(bubblesNV, { Value = value }, 0.4)
		end
		bubblesShown = value
		if increased then
			UIKit.Bounce(topCurrency)
		end
	end

	-- Gems pill, to the right of the Bubbles pill.
	local gemsPill = Instance.new("Frame")
	gemsPill.Name = "Gems"
	gemsPill.AnchorPoint = Vector2.new(0, 0)
	gemsPill.Size = UDim2.fromOffset(168, 44)
	gemsPill.BackgroundColor3 = Color3.new(1, 1, 1)
	gemsPill.BorderSizePixel = 0
	UIKit.Corner(gemsPill, 14)
	UIKit.Gradient(gemsPill, Color3.fromRGB(150, 100, 200), Color3.fromRGB(90, 55, 140))
	UIKit.Stroke(gemsPill, Colors.Ink, 3)
	gemsPill.Parent = root
	UIKit.Icon("Gem", 34, { Position = UDim2.fromOffset(6, 5), Parent = gemsPill })
	local gemsValue = UIKit.Label({
		Text = "0",
		TextSize = 28,
		Position = UDim2.fromOffset(44, 0),
		Size = UDim2.new(1, -86, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = gemsPill,
	})
	UIKit.Button({
		Name = "Plus",
		Text = "+",
		Size = UDim2.fromOffset(36, 36),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -4, 0.5, 0),
		Color = Colors.Good,
		TextSize = 28,
		CornerRadius = 9,
		Parent = gemsPill,
		OnClick = function()
			UIKit.OpenWindow("Shop", "Gems")
		end,
	})
	local gemsShown = -1
	local function setGems(value: number)
		value = math.max(0, math.floor(tonumber(value) or 0))
		if value ~= gemsShown then
			if gemsShown >= 0 and value > gemsShown then
				UIKit.Bounce(gemsPill)
			end
			gemsShown = value
			gemsValue.Text = UIKit.Commas(value)
		end
	end

	--------------------------------------------------------------------------------------------------
	-- Right column: big square buttons (Shop/Pets in the lobby; Upgrades/Pets/Leave in a run), each
	-- with a small key hint for keyboard or gamepad.
	--------------------------------------------------------------------------------------------------
	local rightColumn = Instance.new("Frame")
	rightColumn.Name = "RightColumn"
	rightColumn.AnchorPoint = Vector2.new(1, 0.5)
	rightColumn.Size = UDim2.fromOffset(104, 0)
	rightColumn.AutomaticSize = Enum.AutomaticSize.Y
	rightColumn.BackgroundTransparency = 1
	rightColumn.Parent = root
	local rightLayout = Instance.new("UIListLayout")
	rightLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rightLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	rightLayout.Padding = UDim.new(0, 12)
	rightLayout.Parent = rightColumn

	local hints: { [TextButton]: { Key: string, Pad: string } } = {}
	local function sideButton(icon: string, label: string, color: Color3, keyHint: string, padHint: string, onClick: () -> ()): TextButton
		local b = UIKit.IconButton({
			Icon = icon,
			Label = label,
			Color = color,
			Size = UDim2.fromOffset(100, 100),
			Parent = rightColumn,
			OnClick = onClick,
		})
		local badge = Instance.new("Frame")
		badge.Name = "KeyHint"
		badge.AnchorPoint = Vector2.new(0, 0)
		badge.Position = UDim2.fromOffset(-8, -8)
		badge.Size = UDim2.fromOffset(34, 28)
		badge.BackgroundColor3 = Colors.PanelDark
		badge.ZIndex = 6
		UIKit.Corner(badge, 8)
		UIKit.Stroke(badge, Colors.Ink, 2)
		UIKit.Label({ Name = "Text", Text = keyHint, TextSize = 16, Size = UDim2.fromScale(1, 1), ZIndex = 7, Parent = badge })
		badge.Parent = b
		hints[b] = { Key = keyHint, Pad = padHint }
		return b
	end

	local upgradesButton = sideButton("📖", "Upgrades", Colors.Good, "Tab", "Y", function()
		UIKit.ToggleWindow("Upgrades")
	end)
	local shopButton = sideButton("@Cart", "Shop", Colors.Bad, "G", "Y", function()
		UIKit.ToggleWindow("Shop")
	end)
	local petsButton = sideButton("@Paw", "Pets", Colors.Warning, "P", "LB", function()
		UIKit.ToggleWindow("Pets")
	end)
	local ranksButton = sideButton("@Medal", "Ranks", Colors.Accent, "R", "RB", function()
		UIKit.ToggleWindow("Ranks")
	end)
	local leaveButton = sideButton("🚪", "Leave", Colors.PanelLight, "", "", function()
		UIKit.OpenWindow("LeaveConfirm")
	end)

	--------------------------------------------------------------------------------------------------
	-- Left column (lobby only): Daily reward (with a "!" when one is waiting), Codes, Free Rewards.
	--------------------------------------------------------------------------------------------------
	local leftColumn = Instance.new("Frame")
	leftColumn.Name = "LeftColumn"
	leftColumn.AnchorPoint = Vector2.new(0, 0.5)
	leftColumn.Size = UDim2.fromOffset(84, 0)
	leftColumn.AutomaticSize = Enum.AutomaticSize.Y
	leftColumn.BackgroundTransparency = 1
	leftColumn.Parent = root
	local leftLayout = Instance.new("UIListLayout")
	leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
	leftLayout.Padding = UDim.new(0, 10)
	leftLayout.Parent = leftColumn
	local function leftButton(order: number, icon: string, label: string, color: Color3, window: string): TextButton
		return UIKit.IconButton({
			Icon = icon,
			Label = label,
			Color = color,
			Size = UDim2.fromOffset(80, 80),
			LayoutOrder = order,
			Parent = leftColumn,
			OnClick = function()
				UIKit.ToggleWindow(window)
			end,
		})
	end
	local dailyButton = leftButton(1, "@Gift", "Daily", Colors.Bubble, "Daily")
	local codesButton = leftButton(2, "@Ticket", "Codes", Colors.Primary, "Codes")
	local freeButton = leftButton(3, "@Heart", "Free", Colors.Good, "Free")
	local function makeAdminButton()
		if adminButton or not adminClick then
			return
		end
		adminButton = UIKit.IconButton({
			Name = "AdminButton",
			Icon = "@Shield",
			Label = "Admin",
			Color = Colors.PanelLight,
			Size = UDim2.fromOffset(80, 80),
			LayoutOrder = 4,
			Parent = leftColumn,
			OnClick = function()
				if adminClick then
					adminClick()
				end
			end,
		})
		local inRun = ClientState.Run ~= nil
		dailyButton.Visible = not inRun
		codesButton.Visible = not inRun
		freeButton.Visible = not inRun
		leftColumn.Visible = true
	end
	addAdminButton = makeAdminButton
	makeAdminButton()
	local dailyDot = Instance.new("Frame")
	dailyDot.Name = "Ready"
	dailyDot.AnchorPoint = Vector2.new(0.5, 0.5)
	dailyDot.Position = UDim2.new(1, -4, 0, 4)
	dailyDot.Size = UDim2.fromOffset(28, 28)
	dailyDot.BackgroundColor3 = Colors.Bad
	dailyDot.ZIndex = 8
	dailyDot.Visible = false
	UIKit.Corner(dailyDot, 14)
	UIKit.Stroke(dailyDot, Colors.Ink, 2)
	UIKit.Label({ Text = "!", TextSize = 20, Size = UDim2.fromScale(1, 1), ZIndex = 9, Parent = dailyDot })
	dailyDot.Parent = dailyButton
	task.spawn(function()
		local DailyUI = require(script.Parent:WaitForChild("DailyUI")) :: any
		while true do
			dailyDot.Visible = DailyUI.Ready()
			task.wait(1)
		end
	end)

	--------------------------------------------------------------------------------------------------
	-- Hotbar (in a run): one slot per tool. Owned tools can be put in your hand (click / tap, keys
	-- 1-6, gamepad D-pad left/right); locked ones show a lock and open the Upgrade Book.
	--------------------------------------------------------------------------------------------------
	local SLOT = 68
	local hotbar = Instance.new("Frame")
	hotbar.Name = "Hotbar"
	hotbar.AnchorPoint = Vector2.new(0.5, 1)
	hotbar.Size = UDim2.fromOffset(#Config.Tools * (SLOT + 8), SLOT + 18)
	hotbar.BackgroundTransparency = 1
	hotbar.Visible = false
	hotbar.Parent = root
	local hotbarLayout = Instance.new("UIListLayout")
	hotbarLayout.FillDirection = Enum.FillDirection.Horizontal
	hotbarLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	hotbarLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	hotbarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	hotbarLayout.Padding = UDim.new(0, 8)
	hotbarLayout.Parent = hotbar

	local equipping = false
	local function equipTool(index: number)
		local run = ClientState.Run :: Types.RunState?
		if not run or equipping then
			return
		end
		if not (run.OwnedTools and run.OwnedTools[index]) then
			-- Not yours yet: buy it (or get offered its pass if you're short of coins).
			local ShopUI = require(script.Parent:WaitForChild("ShopUI")) :: any
			local result = ShopUI.GetTool(index)
			if result and not result.Ok then
				UIKit.Toast(result.Error or "Can't buy that yet.", "Bad")
			end
			return
		end
		if run.ToolIndex == index then
			return
		end
		equipping = true
		local result = ClientState.RunRequest("EquipTool", index)
		equipping = false
		if not result.Ok then
			UIKit.Toast(result.Error or "Can't use that yet.", "Bad")
		end
	end

	local slots: { TextButton } = {}
	for i, tool in Config.Tools do
		local slot = UIKit.IconButton({
			Name = "Slot" .. i,
			Icon = tool.Icon,
			Label = "",
			Color = Colors.PanelLight,
			Size = UDim2.fromOffset(SLOT, SLOT),
			LayoutOrder = i,
			Parent = hotbar,
			OnClick = function()
				task.spawn(equipTool, i)
			end,
		})
		local num = UIKit.Label({ Name = "Key", Text = tostring(i), TextSize = 16, Position = UDim2.fromOffset(6, 2), Size = UDim2.fromOffset(16, 18), ZIndex = 8, Parent = slot })
		num.TextXAlignment = Enum.TextXAlignment.Left
		slots[i] = slot
	end

	local function refreshHotbar()
		local run = ClientState.Run :: Types.RunState?
		for i, slot in slots do
			local owned = run ~= nil and run.OwnedTools ~= nil and run.OwnedTools[i] == true
			local inHand = run ~= nil and run.ToolIndex == i
			slot.BackgroundColor3 = if inHand then Colors.Good elseif owned then Colors.Primary else Colors.PanelDark
			slot:SetAttribute("Icon", if owned then Config.Tools[i].Icon else "🔒")
			UIKit.Bounce(slot)
		end
	end
	local lastHotbarKey = ""
	local function hotbarKey(): string
		local run = ClientState.Run :: Types.RunState?
		if not run then
			return ""
		end
		local parts = { tostring(run.ToolIndex) }
		for i in Config.Tools do
			table.insert(parts, if run.OwnedTools and run.OwnedTools[i] then "1" else "0")
		end
		return table.concat(parts)
	end

	local function refreshHints()
		local touch = UIKit.IsTouch()
		local pad = UIKit.IsGamepad()
		for button, hint in hints do
			local badge = button:FindFirstChild("KeyHint") :: Frame?
			if badge then
				local text = if pad then hint.Pad else hint.Key
				badge.Visible = not touch and text ~= ""
				local lbl = badge:FindFirstChild("Text") :: TextLabel?
				if lbl then
					lbl.Text = text
				end
				badge.Size = UDim2.fromOffset(math.max(28, 12 + #text * 10), 28)
			end
		end
	end

	--------------------------------------------------------------------------------------------------
	-- In-run corner widgets: money + tank bottom-left, timer bottom-right.
	--------------------------------------------------------------------------------------------------
	local moneyBlock = Instance.new("Frame")
	moneyBlock.Name = "Money"
	moneyBlock.AnchorPoint = Vector2.new(0, 1)
	moneyBlock.Size = UDim2.fromOffset(300, 150)
	moneyBlock.BackgroundTransparency = 1
	moneyBlock.Visible = false
	moneyBlock.Parent = root

	UIKit.Icon("Coin", 50, { Position = UDim2.fromOffset(0, 6), Parent = moneyBlock })
	local coinsLabel = UIKit.Label({
		Name = "Coins",
		Text = "0",
		TextSize = 54,
		Position = UDim2.fromOffset(58, 0),
		Size = UDim2.new(1, -58, 0, 62),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = Color3.fromRGB(90, 235, 110),
		StrokeThickness = 3,
		Parent = moneyBlock,
	})
	-- Green "+" right after the number: opens the shop on the Coins tab.
	local coinsPlus = UIKit.Button({
		Name = "CoinsPlus",
		Text = "+",
		Size = UDim2.fromOffset(44, 44),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromOffset(200, 31),
		Color = Colors.Good,
		TextSize = 32,
		CornerRadius = 10,
		Parent = moneyBlock,
		OnClick = function()
			UIKit.OpenWindow("Shop", "Coins")
		end,
	})
	coinsLabel:GetPropertyChangedSignal("TextBounds"):Connect(function()
		coinsPlus.Position = UDim2.fromOffset(math.floor(coinsLabel.TextBounds.X / UIKit.GetScale()) + 12 + 58, 31)
	end)
	local coinsNV = Instance.new("NumberValue")
	coinsNV.Parent = moneyBlock
	coinsNV:GetPropertyChangedSignal("Value"):Connect(function()
		coinsLabel.Text = UIKit.Commas(math.floor(coinsNV.Value + 0.5))
	end)
	local coinsShown = -1
	local function setCoins(value: number)
		value = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
		if value == coinsShown then
			return
		end
		local increased = coinsShown >= 0 and value > coinsShown
		if coinsShown < 0 then
			coinsNV.Value = value
		else
			UIKit.Tween(coinsNV, { Value = value }, 0.4)
		end
		coinsShown = value
		if increased then
			UIKit.Bounce(coinsLabel)
		end
	end

	UIKit.Icon("Drop", 40, { Position = UDim2.fromOffset(2, 72), Parent = moneyBlock })
	local tankBar = UIKit.ProgressBar({
		Size = UDim2.new(0, 240, 0, 44),
		Position = UDim2.fromOffset(48, 70),
		Color = Colors.Primary,
		Text = "0/0",
		TextSize = 24,
		Parent = moneyBlock,
	})
	tankBar.Frame.Name = "Tank"

	-- Bubble-jet fuel (BubbleJets writes the LocalPlayer's JetFuel attribute, 0..1).
	local jetBar = UIKit.ProgressBar({
		Size = UDim2.new(0, 280, 0, 26),
		Position = UDim2.fromOffset(0, 122),
		Color = Color3.fromRGB(150, 215, 255),
		Text = "Hold jump to fly",
		TextSize = 16,
		Value = 1,
		Parent = moneyBlock,
	})
	jetBar.Frame.Name = "JetFuel"
	local lastJet = 1
	Players.LocalPlayer:GetAttributeChangedSignal("JetFuel"):Connect(function()
		local f = tonumber(Players.LocalPlayer:GetAttribute("JetFuel")) or 1
		if math.abs(f - lastJet) > 0.02 or (f >= 1 and lastJet < 1) then
			lastJet = f
			jetBar.Set(f, if f <= 0.01 then "Land to refill" else "Hold jump to fly")
		end
	end)

	local tankFlash: Tween? = nil
	local function setTankFull(isFull: boolean)
		if isFull and not tankFlash then
			tankBar.SetColor(Colors.Bad)
			local info = TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
			local tw = TweenService:Create(tankBar.Fill, info, { BackgroundTransparency = 0.55 })
			tankFlash = tw
			tw:Play()
		elseif not isFull and tankFlash then
			tankFlash:Cancel()
			tankFlash = nil
			tankBar.Fill.BackgroundTransparency = 0
			tankBar.SetColor(Colors.Primary)
		end
	end

	local timerLabel = UIKit.Label({
		Name = "Timer",
		Text = "00:00:00",
		TextSize = 48,
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(260, 56),
		TextXAlignment = Enum.TextXAlignment.Right,
		Visible = false,
		Parent = root,
	})

	--------------------------------------------------------------------------------------------------
	-- Top centre, in-run: dishwasher name and cleaning progress (under the currency pill).
	--------------------------------------------------------------------------------------------------
	local topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.AnchorPoint = Vector2.new(0.5, 0)
	topBar.Size = UDim2.new(0, 460, 0, 70)
	topBar.BackgroundTransparency = 1
	topBar.Visible = false
	topBar.Parent = root

	local levelLabel = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, 0, 0, 28),
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = topBar,
	})
	local progressBar = UIKit.ProgressBar({
		Size = UDim2.new(0, 400, 0, 32),
		Position = UDim2.new(0.5, 0, 0, 32),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Good,
		Parent = topBar,
	})

	--------------------------------------------------------------------------------------------------
	-- Layout: keeps everything inside the safe area and clear of the touch thumbstick/jump zones.
	--------------------------------------------------------------------------------------------------
	local function relayoutHud()
		local canvas = UIKit.CanvasSize()
		local inset = UIKit.TopInset()
		local safe = UIKit.SafeInsets()
		local touch = UIKit.IsTouch()

		-- The pill sits in the topbar row itself (the middle of Roblox's topbar is empty), like the
		-- big simulators do; the run's progress bar goes right under it.
		topCurrency.Position = UDim2.new(0.5, 0, 0, 2)
		gemsPill.Position = UDim2.new(0.5, 133, 0, 7)
		hotbar.Position = UDim2.new(0.5, 0, 1, -(if touch then 24 else 12) - safe.Bottom)
		topBar.Position = UDim2.new(0.5, 0, 0, 72)

		-- Right column: vertically centred, but on touch kept above the jump button.
		local colH = rightColumn.AbsoluteSize.Y / UIKit.GetScale()
		local centerY = canvas.Y / 2
		if touch then
			centerY = math.min(centerY, canvas.Y - 300 - colH / 2)
		end
		centerY = math.max(centerY, inset + 80 + colH / 2)
		rightColumn.Position = UDim2.new(1, -(16 + safe.Right), 0, math.floor(centerY))
		-- Left column: mirrors the right one (above the thumbstick on touch).
		local leftH = leftColumn.AbsoluteSize.Y / UIKit.GetScale()
		local leftY = canvas.Y / 2
		if touch then
			leftY = math.min(leftY, canvas.Y - 300 - leftH / 2)
		end
		-- Money block: bottom-left on desktop/console; above the thumbstick on touch.
		local bottom = if touch then canvas.Y - 330 else canvas.Y - 16 - safe.Bottom
		moneyBlock.Position = UDim2.new(0, 20 + safe.Left, 0, math.floor(bottom))
		-- In a run the column (the owner's Admin button) stays clear above the money block.
		if moneyBlock.Visible then
			leftY = math.min(leftY, bottom - moneyBlock.Size.Y.Offset - 16 - leftH / 2)
		end
		leftY = math.max(leftY, inset + 80 + leftH / 2)
		leftColumn.Position = UDim2.new(0, 16 + safe.Left, 0, math.floor(leftY))

		-- Timer: bottom-right on desktop/console; top-right under the topbar on touch.
		if touch then
			timerLabel.AnchorPoint = Vector2.new(1, 0)
			timerLabel.TextSize = 34
			timerLabel.Position = UDim2.new(1, -(16 + safe.Right), 0, math.floor(inset + 10))
		else
			timerLabel.AnchorPoint = Vector2.new(1, 1)
			timerLabel.TextSize = 48
			timerLabel.Position = UDim2.new(1, -(20 + safe.Right), 1, -(12 + safe.Bottom))
		end
		refreshHints()
	end
	rightColumn:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutHud)
	leftColumn:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutHud)
	moneyBlock:GetPropertyChangedSignal("Visible"):Connect(relayoutHud)

	local function relayoutTopBar()
		relayoutHud()
	end

	--------------------------------------------------------------------------------------------------
	-- Run-start banner.
	--------------------------------------------------------------------------------------------------
	local banner = Instance.new("Frame")
	banner.Name = "RunStartBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Size = UDim2.new(0, 640, 0, 96)
	banner.BackgroundTransparency = 1
	banner.Visible = false
	banner.ZIndex = 25
	banner.Parent = root

	local bannerTitle = UIKit.Label({
		Text = "Clean every dish!",
		Size = UDim2.new(1, 0, 0, 52),
		TextSize = 40,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = banner,
	})
	local bannerSubtitle = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, 0, 0, 34),
		Position = UDim2.new(0, 0, 0, 54),
		TextSize = 26,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = banner,
	})

	-- The banner shows in the middle of the screen (a quarter of the way down), well below the
	-- Bubbles pill and the progress bar, so nothing ever overlaps.
	local function relayoutBanner()
		local canvas = UIKit.CanvasSize()
		banner.Position = UDim2.new(0.5, 0, 0, math.floor(math.max(170, canvas.Y * 0.26)))
	end

	local bannerToken = 0
	local function showRunStartBanner(levelIndex: number)
		local level = Config.GetLevel(levelIndex)
		bannerSubtitle.Text = tostring(level.Name)
		bannerToken += 1
		local token = bannerToken
		relayoutBanner()
		banner.Visible = true
		bannerTitle.TextTransparency = 0
		bannerSubtitle.TextTransparency = 0
		UIKit.Bounce(banner)
		task.delay(2.5, function()
			if token ~= bannerToken then
				return
			end
			UIKit.Tween(bannerTitle, { TextTransparency = 1 }, 0.4)
			UIKit.Tween(bannerSubtitle, { TextTransparency = 1 }, 0.4)
			task.delay(0.45, function()
				if token == bannerToken then
					banner.Visible = false
				end
			end)
		end)
	end

	--------------------------------------------------------------------------------------------------
	-- Results screen (Phase == "Complete").
	--------------------------------------------------------------------------------------------------
	local RESULTS_BASE = Vector2.new(860, 560)
	local resultsFrame = Instance.new("Frame")
	resultsFrame.Name = "Results"
	resultsFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	resultsFrame.Size = UDim2.fromOffset(RESULTS_BASE.X, RESULTS_BASE.Y)
	resultsFrame.BorderSizePixel = 0
	resultsFrame.Visible = false
	resultsFrame.ZIndex = 15
	UIKit.Corner(resultsFrame, 20)
	UIKit.Gradient(resultsFrame, Colors.Panel, Colors.PanelDark)
	UIKit.Stroke(resultsFrame, Colors.Ink, 3)
	resultsFrame.Parent = root

	local resultsScale = Instance.new("UIScale")
	resultsScale.Parent = resultsFrame

	local _titleLabel = UIKit.Label({
		Text = "SPARKLING CLEAN!",
		Size = UDim2.new(1, -40, 0, 56),
		Position = UDim2.new(0, 20, 0, 18),
		TextSize = 40,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = resultsFrame,
	})
	local timeLabel = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -40, 0, 28),
		Position = UDim2.new(0, 20, 0, 78),
		TextSize = 22,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = resultsFrame,
	})
	local bestLabel = UIKit.Label({
		Text = "NEW BEST!",
		Size = UDim2.new(1, -40, 0, 26),
		Position = UDim2.new(0, 20, 0, 108),
		TextSize = 22,
		TextColor3 = Colors.Good,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		Parent = resultsFrame,
	})

	local bubblesRow = Instance.new("Frame")
	bubblesRow.BackgroundTransparency = 1
	bubblesRow.Size = UDim2.new(1, -40, 0, 46)
	bubblesRow.Position = UDim2.new(0, 20, 0, 138)
	bubblesRow.Parent = resultsFrame
	local bubblesRowLayout = Instance.new("UIListLayout")
	bubblesRowLayout.FillDirection = Enum.FillDirection.Horizontal
	bubblesRowLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bubblesRowLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	bubblesRowLayout.Padding = UDim.new(0, 8)
	bubblesRowLayout.Parent = bubblesRow
	UIKit.Icon("Bubble", 38, { LayoutOrder = -1, Parent = bubblesRow })
	local resultsBubblesLabel = UIKit.Label({
		Text = "+0",
		TextSize = 34,
		TextColor3 = Colors.Bubble,
		Size = UDim2.fromOffset(200, 40),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = bubblesRow,
	})
	local resultsBubblesNV = Instance.new("NumberValue")
	resultsBubblesNV.Parent = resultsFrame
	resultsBubblesNV:GetPropertyChangedSignal("Value"):Connect(function()
		resultsBubblesLabel.Text = "+" .. UIKit.Commas(math.floor(resultsBubblesNV.Value + 0.5))
	end)
	local resultsBubblesShown = -1

	local unlockedLabel = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -40, 0, 26),
		Position = UDim2.new(0, 20, 0, 188),
		TextSize = 20,
		TextColor3 = Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
		Parent = resultsFrame,
	})

	local headerRow = Instance.new("Frame")
	headerRow.BackgroundTransparency = 1
	headerRow.Size = UDim2.new(1, -40, 0, 24)
	headerRow.Position = UDim2.new(0, 20, 0, 222)
	headerRow.Parent = resultsFrame
	UIKit.Label({
		Text = "PLAYER",
		Size = UDim2.new(0.5, 0, 1, 0),
		TextSize = 16,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = headerRow,
	})
	UIKit.Label({
		Text = "CLEANED",
		Size = UDim2.new(0.25, 0, 1, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		TextSize = 16,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = headerRow,
	})
	UIKit.Label({
		Text = "SHARE",
		Size = UDim2.new(0.25, 0, 1, 0),
		Position = UDim2.new(0.75, 0, 0, 0),
		TextSize = 16,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = headerRow,
	})

	local scrollFrame = Instance.new("ScrollingFrame")
	scrollFrame.Name = "PlayerTable"
	scrollFrame.Size = UDim2.new(1, -40, 0, 190)
	scrollFrame.Position = UDim2.new(0, 20, 0, 250)
	scrollFrame.BackgroundTransparency = 1
	scrollFrame.BorderSizePixel = 0
	scrollFrame.ScrollBarThickness = 6
	scrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
	scrollFrame.Parent = resultsFrame
	local scrollLayout = Instance.new("UIListLayout")
	scrollLayout.SortOrder = Enum.SortOrder.LayoutOrder
	scrollLayout.Padding = UDim.new(0, 4)
	scrollLayout.Parent = scrollFrame

	local countdownLabel = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -40, 0, 24),
		Position = UDim2.new(0, 20, 1, -108),
		TextSize = 18,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = resultsFrame,
	})

	UIKit.Button({
		Text = "Back to Lobby",
		Icon = "🚪",
		Size = UDim2.fromOffset(240, 54),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Color = Colors.Good,
		Parent = resultsFrame,
		OnClick = function()
			-- Fade out first so the teleport home is never seen; the cover lifts in the lobby.
			local Cutscene = require(script.Parent:WaitForChild("Cutscene")) :: any
			Cutscene.Cover(nil, 6)
			local result = ClientState.RunRequest("ReturnToLobby")
			if not result.Ok then
				Cutscene.Uncover()
				UIKit.Toast(result.Error or "Couldn't return to the lobby.", "Bad")
			end
		end,
	})

	local function layoutResults()
		local canvas = UIKit.CanvasSize()
		local inset = UIKit.TopInset()
		local availW = canvas.X - 32
		local availH = canvas.Y - inset - 32
		local fit = math.clamp(math.min(availW / RESULTS_BASE.X, availH / RESULTS_BASE.Y), 0.4, 1)
		resultsScale.Scale = fit
		resultsFrame.Position = UDim2.new(0.5, 0, 0.5, math.floor(inset / 2))
	end

	local function refreshResults(run: Types.RunState)
		local results = run.Results
		if not results then
			return
		end
		local underParText = if results.UnderPar then "   Under par!" else ""
		timeLabel.Text = string.format(
			"%s   (Par %s)%s",
			UIKit.Time(results.TimeSeconds),
			UIKit.Time(results.ParTime),
			underParText
		)
		bestLabel.Visible = results.NewBest == true
		if results.NewBest then
			UIKit.Bounce(bestLabel)
		end
		if resultsBubblesShown ~= results.Bubbles then
			resultsBubblesShown = results.Bubbles
			resultsBubblesNV.Value = 0
			UIKit.Tween(resultsBubblesNV, { Value = results.Bubbles }, 0.8)
		end
		if results.UnlockedLevel then
			local unlocked = Config.GetLevel(results.UnlockedLevel)
			unlockedLabel.Text = string.format("%s unlocked!", tostring(unlocked.Name))
			unlockedLabel.Visible = true
		else
			unlockedLabel.Visible = false
		end

		for _, child in scrollFrame:GetChildren() do
			if child:IsA("Frame") then
				child:Destroy()
			end
		end
		for order, row in results.Players do
			local r = Instance.new("Frame")
			r.Name = "Row"
			r.BackgroundTransparency = 1
			r.Size = UDim2.new(1, 0, 0, 28)
			r.LayoutOrder = order
			UIKit.Label({
				Text = row.Name,
				Size = UDim2.new(0.5, 0, 1, 0),
				TextSize = 18,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = r,
			})
			UIKit.Label({
				Text = tostring(row.Grime),
				Size = UDim2.new(0.25, 0, 1, 0),
				Position = UDim2.new(0.5, 0, 0, 0),
				TextSize = 18,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = r,
			})
			UIKit.Label({
				Text = string.format("%d%%", math.floor(row.Share * 100 + 0.5)),
				Size = UDim2.new(0.25, 0, 1, 0),
				Position = UDim2.new(0.75, 0, 0, 0),
				TextSize = 18,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = r,
			})
			r.Parent = scrollFrame
		end
	end

	--------------------------------------------------------------------------------------------------
	-- Leave confirmation.
	--------------------------------------------------------------------------------------------------
	local _leaveWindow, leaveContent = UIKit.Window({
		Name = "LeaveConfirm",
		Title = "Leave the Run?",
		Icon = "🚪",
		Size = Vector2.new(420, 220),
		Parent = root,
	})
	UIKit.RegisterWindow("LeaveConfirm", { Open = function() end, Close = function() end })

	UIKit.Label({
		Text = "Leave the run? You'll get no Bubbles.",
		Size = UDim2.new(1, 0, 0, 70),
		Position = UDim2.new(0, 0, 0, 6),
		TextSize = 20,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = leaveContent,
	})
	local leaveButtonsRow = Instance.new("Frame")
	leaveButtonsRow.BackgroundTransparency = 1
	leaveButtonsRow.Size = UDim2.new(1, 0, 0, 54)
	leaveButtonsRow.Position = UDim2.new(0, 0, 1, -70)
	leaveButtonsRow.Parent = leaveContent
	local leaveButtonsLayout = Instance.new("UIListLayout")
	leaveButtonsLayout.FillDirection = Enum.FillDirection.Horizontal
	leaveButtonsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	leaveButtonsLayout.Padding = UDim.new(0, 16)
	leaveButtonsLayout.Parent = leaveButtonsRow
	UIKit.Button({
		Text = "Cancel",
		Color = Colors.Primary,
		Size = UDim2.fromOffset(150, 50),
		Parent = leaveButtonsRow,
		OnClick = function()
			UIKit.CloseWindow("LeaveConfirm")
		end,
	})
	UIKit.Button({
		Text = "Leave",
		Color = Colors.Bad,
		Size = UDim2.fromOffset(150, 50),
		Parent = leaveButtonsRow,
		OnClick = function()
			UIKit.CloseWindow("LeaveConfirm")
			local Cutscene = require(script.Parent:WaitForChild("Cutscene")) :: any
			Cutscene.Cover(nil, 6)
			local result = ClientState.RunRequest("Leave")
			if not result.Ok then
				Cutscene.Uncover()
				UIKit.Toast(result.Error or "Couldn't leave the run.", "Bad")
			end
		end,
	})

	--------------------------------------------------------------------------------------------------
	-- Arena progress (Cleaned/Total), read live off the arena Model with a RunState fallback.
	--------------------------------------------------------------------------------------------------
	local arenaConnections: { RBXScriptConnection } = {}
	local watchedArena: Model? = nil
	local arenaWatchToken = 0

	local function updateProgress()
		local run = ClientState.Run :: Types.RunState?
		if not run then
			return
		end
		local cleaned, total = nil, nil
		local arena = watchedArena
		if arena and arena.Parent then
			local c, t = arena:GetAttribute("Cleaned"), arena:GetAttribute("Total")
			if typeof(c) == "number" and typeof(t) == "number" then
				cleaned, total = c, t
			end
		end
		if not (cleaned and total and total > 0) then
			cleaned, total = run.Cleaned, run.Total
		end
		total = math.max(total or 0, 1)
		cleaned = math.clamp(cleaned or 0, 0, total)
		local pct = math.floor(cleaned / total * 100 + 0.5)
		progressBar.Set(cleaned / total, string.format("Dishwasher %d%% clean", pct))
	end

	local function clearArenaWatch()
		for _, c in arenaConnections do
			c:Disconnect()
		end
		table.clear(arenaConnections)
		watchedArena = nil
	end

	-- The arena may not have replicated to the client yet when RunState arrives, so this retries
	-- for a few seconds instead of giving up after one failed ClientState.GetArena() call.
	local function refreshArenaWatch()
		arenaWatchToken += 1
		local token = arenaWatchToken
		clearArenaWatch()
		if not ClientState.Run then
			return
		end
		task.spawn(function()
			for _ = 1, 30 do
				if token ~= arenaWatchToken then
					return
				end
				local arena = ClientState.GetArena()
				if arena then
					watchedArena = arena
					table.insert(arenaConnections, arena:GetAttributeChangedSignal("Cleaned"):Connect(updateProgress))
					table.insert(arenaConnections, arena:GetAttributeChangedSignal("Total"):Connect(updateProgress))
					updateProgress()
					return
				end
				task.wait(0.5)
			end
		end)
	end

	--------------------------------------------------------------------------------------------------
	-- Mode switching + value refresh.
	--------------------------------------------------------------------------------------------------
	local lastBannerStartedAt: number? = nil

	local function updateCurrencyValues()
		local run = ClientState.Run :: Types.RunState?
		if run then
			setCoins(run.Coins)
		end
		local meta = ClientState.Meta :: Types.MetaState?
		local bubbles = if meta then meta.Bubbles else (LocalPlayer:GetAttribute("Bubbles") :: number?) or 0
		setBubbles(bubbles)
		setGems(if meta then meta.Gems or 0 else 0)
	end

	local function refreshMode()
		local run = ClientState.Run :: Types.RunState?
		local inRun = run ~= nil
		local playing = run ~= nil and run.Phase == "Playing"
		local complete = run ~= nil and run.Phase == "Complete"

		moneyBlock.Visible = playing
		timerLabel.Visible = playing
		topBar.Visible = playing

		-- The Shop is always there (Robux items work in a run too); Ranks only in the lobby.
		shopButton.Visible = true
		upgradesButton.Visible = inRun
		leaveButton.Visible = inRun
		ranksButton.Visible = not inRun
		dailyButton.Visible = not inRun
		codesButton.Visible = not inRun
		freeButton.Visible = not inRun
		leftColumn.Visible = not inRun or adminButton ~= nil
		upgradesButton.LayoutOrder = 1
		shopButton.LayoutOrder = 2
		petsButton.LayoutOrder = 3
		ranksButton.LayoutOrder = 4
		leaveButton.LayoutOrder = 5
		plusButton.Visible = true
		hotbar.Visible = playing
		local key = hotbarKey()
		if key ~= lastHotbarKey then
			lastHotbarKey = key
			refreshHotbar()
		end
		-- In a run Tab opens the Upgrade Book, so the player list (also on Tab) steps aside.
		pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, not inRun)
		end)

		if playing and run then
			local level = Config.GetLevel(run.Level)
			levelLabel.Text = tostring(level.Name)
			local full = run.Tank >= run.TankMax and run.TankMax > 0
			setTankFull(full)
			tankBar.Set(
				if run.TankMax > 0 then run.Tank / run.TankMax else 0,
				if full then "FULL! Sell at the drain" else string.format("%s / %s", UIKit.Short(run.Tank), UIKit.Short(run.TankMax))
			)
			updateProgress()
		else
			setTankFull(false)
		end

		if complete and run and run.Results then
			layoutResults()
			resultsFrame.Visible = true
			refreshResults(run)
		else
			resultsFrame.Visible = false
		end

		if not run then
			lastBannerStartedAt = nil
			resultsBubblesShown = -1
			coinsShown = -1
		end
	end

	local function checkRunStartBanner()
		local run = ClientState.Run :: Types.RunState?
		if run and run.Phase == "Playing" then
			if lastBannerStartedAt ~= run.StartedAt then
				lastBannerStartedAt = run.StartedAt
				local level = run.Level
				-- After the run-start cutscene, if one plays (it starts on the same RunState).
				task.spawn(function()
					task.wait(0.4)
					local okCs, Cutscene = pcall(function()
						return require(script.Parent:WaitForChild("Cutscene")) :: any
					end)
					while okCs and Cutscene.IsPlaying() do
						task.wait(0.2)
					end
					showRunStartBanner(level)
				end)
			end
		end
	end

	--------------------------------------------------------------------------------------------------
	-- Wiring: ClientState, UIKit.LayoutChanged, a slow tick for the timer/countdown, and shortcuts.
	--------------------------------------------------------------------------------------------------
	ClientState.Changed:Connect(function(kind: string)
		if kind == "Run" then
			refreshMode()
			updateCurrencyValues()
			refreshArenaWatch()
			checkRunStartBanner()
		elseif kind == "Meta" then
			updateCurrencyValues()
		end
	end)

	LocalPlayer:GetAttributeChangedSignal("Bubbles"):Connect(function()
		if not ClientState.Meta then
			updateCurrencyValues()
		end
	end)

	UIKit.LayoutChanged:Connect(function()
		relayoutTopBar()
		relayoutBanner()
		if resultsFrame.Visible then
			layoutResults()
		end
	end)

	-- One slow loop drives the run timer and the results countdown; both are cheap 2Hz text updates.
	local coveredForReturn: number? = nil
	task.spawn(function()
		while true do
			local run = ClientState.Run :: Types.RunState?
			if run then
				if run.Phase == "Playing" then
					local t = if run.ClockAt and run.ClockAt > 0 then math.max(0, math.floor(Util.Now() - run.ClockAt)) else 0
					timerLabel.Text = string.format("%02d:%02d:%02d", t // 3600, (t % 3600) // 60, t % 60)
				elseif run.Phase == "Complete" and run.Results then
					local remaining = math.max(0, run.Results.ReturnAt - Util.Now())
					countdownLabel.Text = string.format("Returning to lobby in %ds", math.ceil(remaining))
					-- Fade out just before the server sends everyone home, so that teleport isn't seen
					-- either (the cover lifts again once we're back in the lobby).
					if remaining <= 0.9 and coveredForReturn ~= run.Results.ReturnAt then
						coveredForReturn = run.Results.ReturnAt
						local Cutscene = require(script.Parent:WaitForChild("Cutscene")) :: any
						task.spawn(Cutscene.Cover, nil, 5)
					end
				end
			end
			task.wait(0.5)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		local key = input.KeyCode
		local inRun = ClientState.Run ~= nil
		-- Roblox's player list marks Tab as processed, so Tab (and gamepad Y) skip that check.
		if processed and not (inRun and key == Enum.KeyCode.Tab) and key ~= Enum.KeyCode.ButtonY then
			return
		end
		if (key == Enum.KeyCode.Q or key == Enum.KeyCode.Tab) and inRun then
			UIKit.ToggleWindow("Upgrades")
		elseif key == Enum.KeyCode.P or key == Enum.KeyCode.ButtonL1 then
			UIKit.ToggleWindow("Pets")
		elseif key == Enum.KeyCode.G and not inRun then
			UIKit.ToggleWindow("Shop")
		elseif key == Enum.KeyCode.ButtonY then
			UIKit.ToggleWindow(if inRun then "Upgrades" else "Shop")
		elseif (key == Enum.KeyCode.R or key == Enum.KeyCode.ButtonR1) and not inRun then
			UIKit.ToggleWindow("Ranks")
		elseif inRun and (key == Enum.KeyCode.DPadLeft or key == Enum.KeyCode.DPadRight) then
			local run = ClientState.Run :: Types.RunState?
			if run and run.OwnedTools then
				local step = if key == Enum.KeyCode.DPadRight then 1 else -1
				local n = #Config.Tools
				local i = run.ToolIndex
				for _ = 1, n do
					i = ((i - 1 + step) % n) + 1
					if run.OwnedTools[i] then
						task.spawn(equipTool, i)
						break
					end
				end
			end
		elseif inRun then
			local numbers = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five, Enum.KeyCode.Six }
			local index = table.find(numbers, key)
			if index and Config.Tools[index] then
				task.spawn(equipTool, index)
			end
		end
	end)

	relayoutTopBar()
	relayoutBanner()
	refreshMode()
	updateCurrencyValues()
	refreshArenaWatch()
	checkRunStartBanner()
end

return HUD
