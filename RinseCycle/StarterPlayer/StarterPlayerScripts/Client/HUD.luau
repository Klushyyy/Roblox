-- Always-on heads-up display: currency pill(s), the in-run tank bar, the top progress/timer bar,
-- HUD buttons (Pets/Shop lobby, Upgrades/Pets/Leave in-run), the run-start banner and the results
-- screen. See DESIGN.md section 6 "HUD". Everything here is built once in Init() and then only
-- shown/hidden/updated, so there's nothing to leak: no per-run instances, no per-run connections
-- besides the ones this module owns for its whole lifetime.

local Players = game:GetService("Players")
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
local initialized = false

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

-- A currency pill: icon + a number that tweens toward new values and bounces when it goes up.
-- `big` toggles between the large in-run Coins size and the small Bubbles-next-to-it size; the
-- lobby Bubbles pill is switched back to "big" with setBig(true) when there's no run.
local function createPill(icon: string, color: Color3, parent: Instance, big: boolean)
	local height = if big then 54 else 40
	local frame = Instance.new("Frame")
	frame.Name = "Pill"
	frame.Size = UDim2.new(0, if big then 190 else 150, 0, height)
	frame.BackgroundColor3 = Colors.PanelLight
	frame.BorderSizePixel = 0
	UIKit.Corner(frame, 999)
	UIKit.Stroke(frame, Colors.Ink, 2, 0.15)

	local iconSize = if big then 30 else 22
	local iconLabel = UIKit.Label({
		Name = "Icon",
		Text = icon,
		Size = UDim2.fromOffset(iconSize + 16, height),
		Position = UDim2.fromOffset(8, 0),
		TextSize = iconSize,
		Parent = frame,
	})
	local textLabel = UIKit.Label({
		Name = "Value",
		Text = "0",
		Size = UDim2.new(1, -(iconSize + 30), 1, 0),
		Position = UDim2.fromOffset(iconSize + 20, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextSize = if big then 28 else 20,
		TextColor3 = color,
		Parent = frame,
	})

	-- A NumberValue drives the count-up tween; its Changed signal keeps the label text in sync.
	local nv = Instance.new("NumberValue")
	nv.Name = "Shown"
	nv.Parent = frame
	nv:GetPropertyChangedSignal("Value"):Connect(function()
		textLabel.Text = UIKit.Short(math.floor(nv.Value + 0.5))
	end)

	local shown = -1 -- -1 = nothing set yet, so the very first value never bounces
	local function setValue(value: number)
		value = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
		if value == shown then
			return
		end
		local increased = shown >= 0 and value > shown
		shown = value
		if shown < 0 then
			nv.Value = value
			textLabel.Text = UIKit.Short(value)
		else
			UIKit.Tween(nv, { Value = value }, 0.4)
		end
		if increased then
			UIKit.Bounce(frame)
		end
	end

	local function setBig(isBig: boolean)
		if isBig == big then
			return
		end
		big = isBig
		local h = if isBig then 54 else 40
		local is_ = if isBig then 30 else 22
		frame.Size = UDim2.new(0, if isBig then 190 else 150, 0, h)
		iconLabel.Size = UDim2.fromOffset(is_ + 16, h)
		iconLabel.TextSize = is_
		textLabel.Size = UDim2.new(1, -(is_ + 30), 1, 0)
		textLabel.Position = UDim2.fromOffset(is_ + 20, 0)
		textLabel.TextSize = if isBig then 28 else 20
	end

	frame.Parent = parent
	return frame, setValue, setBig
end

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
	-- Left-centre column: currency, tank bar, buttons.
	--------------------------------------------------------------------------------------------------
	local leftColumn = Instance.new("Frame")
	leftColumn.Name = "LeftColumn"
	leftColumn.AnchorPoint = Vector2.new(0, 0.5)
	leftColumn.Position = UDim2.new(0, 16, 0.5, 0)
	leftColumn.Size = UDim2.new(0, 210, 0, 0)
	leftColumn.AutomaticSize = Enum.AutomaticSize.Y
	leftColumn.BackgroundTransparency = 1
	leftColumn.Parent = root

	local columnLayout = Instance.new("UIListLayout")
	columnLayout.SortOrder = Enum.SortOrder.LayoutOrder
	columnLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	columnLayout.Padding = UDim.new(0, 10)
	columnLayout.Parent = leftColumn

	-- Currency row (Coins big + Bubbles small in-run; Bubbles alone, big, in the lobby).
	local currencyRow = Instance.new("Frame")
	currencyRow.Name = "Currency"
	currencyRow.BackgroundTransparency = 1
	currencyRow.Size = UDim2.new(0, 210, 0, 54)
	currencyRow.AutomaticSize = Enum.AutomaticSize.X
	currencyRow.LayoutOrder = 1
	currencyRow.Parent = leftColumn
	local currencyLayout = Instance.new("UIListLayout")
	currencyLayout.FillDirection = Enum.FillDirection.Horizontal
	currencyLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	currencyLayout.Padding = UDim.new(0, 8)
	currencyLayout.Parent = currencyRow

	local coinsFrame, setCoins = createPill("🪙", Colors.Coin, currencyRow, true)
	coinsFrame.LayoutOrder = 1
	local bubblesFrame, setBubbles, setBubblesBig = createPill("🫧", Colors.Bubble, currencyRow, false)
	bubblesFrame.LayoutOrder = 2

	-- Tank bar (in-run only). Flashes red with "FULL!" at capacity.
	local tankBar = UIKit.ProgressBar({
		Size = UDim2.new(0, 210, 0, 34),
		Color = Colors.Primary,
		Text = "💧 0/0",
		Parent = leftColumn,
	})
	tankBar.Frame.Name = "Tank"
	tankBar.Frame.LayoutOrder = 2

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

	-- HUD buttons. All four exist all the time; visibility and LayoutOrder change with the mode so
	-- the row reflows instead of being rebuilt.
	local buttonsRow = Instance.new("Frame")
	buttonsRow.Name = "Buttons"
	buttonsRow.BackgroundTransparency = 1
	buttonsRow.Size = UDim2.new(0, 210, 0, 84)
	buttonsRow.AutomaticSize = Enum.AutomaticSize.X
	buttonsRow.LayoutOrder = 3
	buttonsRow.Parent = leftColumn
	local buttonsLayout = Instance.new("UIListLayout")
	buttonsLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonsLayout.Padding = UDim.new(0, 10)
	buttonsLayout.Parent = buttonsRow

	local petsButton = UIKit.IconButton({
		Icon = "🐾",
		Label = "Pets",
		Color = Colors.Accent,
		Parent = buttonsRow,
		OnClick = function()
			UIKit.ToggleWindow("Pets")
		end,
	})
	local shopButton = UIKit.IconButton({
		Icon = "🛒",
		Label = "Shop",
		Color = Colors.Primary,
		Parent = buttonsRow,
		OnClick = function()
			UIKit.ToggleWindow("Shop")
		end,
	})
	local upgradesButton = UIKit.IconButton({
		Icon = "⬆️",
		Label = "Upgrades",
		Color = Colors.Good,
		Parent = buttonsRow,
		OnClick = function()
			UIKit.ToggleWindow("Upgrades")
		end,
	})
	local leaveButton = UIKit.IconButton({
		Icon = "🚪",
		Label = "Leave",
		Color = Colors.Bad,
		Parent = buttonsRow,
		OnClick = function()
			UIKit.OpenWindow("LeaveConfirm")
		end,
	})

	-- Keep the column clear of the touch thumbstick (bottom-left) and the topbar, on any device.
	local function relayoutLeftColumn()
		local canvas = UIKit.CanvasSize()
		local half = leftColumn.AbsoluteSize.Y / 2
		local centerY = canvas.Y / 2
		local yOffset = 0
		if UIKit.IsTouch() then
			local maxCenterY = canvas.Y - (320 + 24) - half
			if centerY > maxCenterY then
				yOffset = maxCenterY - centerY
			end
		end
		local minCenterY = UIKit.TopInset() + 16 + half
		if centerY + yOffset < minCenterY then
			yOffset = minCenterY - centerY
		end
		local safe = UIKit.SafeInsets()
		leftColumn.Position = UDim2.new(0, 16 + safe.Left, 0.5, math.floor(yOffset))
	end
	leftColumn:GetPropertyChangedSignal("AbsoluteSize"):Connect(relayoutLeftColumn)

	--------------------------------------------------------------------------------------------------
	-- Top-centre, in-run: level, cleaning progress, timer.
	--------------------------------------------------------------------------------------------------
	local topBar = Instance.new("Frame")
	topBar.Name = "TopBar"
	topBar.AnchorPoint = Vector2.new(0.5, 0)
	topBar.Size = UDim2.new(0, 460, 0, 96)
	topBar.BackgroundTransparency = 1
	topBar.Visible = false
	topBar.Parent = root

	local levelLabel = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, 0, 0, 32),
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = topBar,
	})
	local progressBar = UIKit.ProgressBar({
		Size = UDim2.new(0, 400, 0, 30),
		Position = UDim2.new(0.5, 0, 0, 36),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Good,
		Parent = topBar,
	})
	local timerLabel = UIKit.Label({
		Text = "0:00",
		Size = UDim2.new(1, 0, 0, 26),
		Position = UDim2.new(0, 0, 0, 70),
		TextSize = 20,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = topBar,
	})

	local function relayoutTopBar()
		topBar.Position = UDim2.new(0.5, 0, 0, math.floor(UIKit.TopInset() + 10))
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
		Text = "🧽 Clean every dish! 🧽",
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

	local function relayoutBanner()
		banner.Position = UDim2.new(0.5, 0, 0, math.floor(UIKit.TopInset() + 40))
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
		Text = "✨ SPARKLING CLEAN! ✨",
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
		Text = "⭐ NEW BEST!",
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
	UIKit.Label({ Text = "🫧", TextSize = 34, Size = UDim2.fromOffset(40, 40), Parent = bubblesRow })
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
		Text = "SPOTS",
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
		Position = UDim2.new(0, 20, 1, -84),
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
			local result = ClientState.RunRequest("ReturnToLobby")
			if not result.Ok then
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
		local underParText = if results.UnderPar then "  🔥 Under par!" else ""
		timeLabel.Text = string.format(
			"⏱ %s   (Par %s)%s",
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
			unlockedLabel.Text = string.format("🔓 %s unlocked!", tostring(unlocked.Name))
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
			local result = ClientState.RunRequest("Leave")
			if not result.Ok then
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
	end

	local function refreshMode()
		local run = ClientState.Run :: Types.RunState?
		local inRun = run ~= nil
		local playing = run ~= nil and run.Phase == "Playing"
		local complete = run ~= nil and run.Phase == "Complete"

		coinsFrame.Visible = inRun
		setBubblesBig(not inRun)
		tankBar.Frame.Visible = playing
		topBar.Visible = playing

		shopButton.Visible = not inRun
		upgradesButton.Visible = inRun
		leaveButton.Visible = inRun
		upgradesButton.LayoutOrder = 1
		petsButton.LayoutOrder = if inRun then 2 else 1
		shopButton.LayoutOrder = 2
		leaveButton.LayoutOrder = 3

		if playing and run then
			local level = Config.GetLevel(run.Level)
			levelLabel.Text = string.format("%s %s", tostring(level.Icon), tostring(level.Name))
			local full = run.Tank >= run.TankMax and run.TankMax > 0
			setTankFull(full)
			tankBar.Set(
				if run.TankMax > 0 then run.Tank / run.TankMax else 0,
				if full then "💧 FULL!" else string.format("💧 %d/%d", run.Tank, run.TankMax)
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
		end
	end

	local function checkRunStartBanner()
		local run = ClientState.Run :: Types.RunState?
		if run and run.Phase == "Playing" then
			if lastBannerStartedAt ~= run.StartedAt then
				lastBannerStartedAt = run.StartedAt
				showRunStartBanner(run.Level)
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
		relayoutLeftColumn()
		relayoutTopBar()
		relayoutBanner()
		if resultsFrame.Visible then
			layoutResults()
		end
	end)

	-- One slow loop drives the run timer and the results countdown; both are cheap 2Hz text updates.
	task.spawn(function()
		while true do
			local run = ClientState.Run :: Types.RunState?
			if run then
				if run.Phase == "Playing" then
					timerLabel.Text = UIKit.Time(Util.Now() - run.StartedAt)
				elseif run.Phase == "Complete" and run.Results then
					local remaining = math.max(0, run.Results.ReturnAt - Util.Now())
					countdownLabel.Text = string.format("Returning to lobby in %ds", math.ceil(remaining))
				end
			end
			task.wait(0.5)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or UserInputService:GetFocusedTextBox() ~= nil then
			return
		end
		local key = input.KeyCode
		local inRun = ClientState.Run ~= nil
		if (key == Enum.KeyCode.Q or key == Enum.KeyCode.Tab) and inRun then
			UIKit.ToggleWindow("Upgrades")
		elseif key == Enum.KeyCode.P then
			UIKit.ToggleWindow("Pets")
		elseif key == Enum.KeyCode.G and not inRun then
			UIKit.ToggleWindow("Shop")
		end
	end)

	relayoutLeftColumn()
	relayoutTopBar()
	relayoutBanner()
	refreshMode()
	updateCurrencyValues()
	refreshArenaWatch()
	checkRunStartBanner()
end

return HUD
