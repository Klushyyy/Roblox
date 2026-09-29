--[[
	PartyUI - everything shown while ClientState.Party ~= nil (standing in a lobby pad).

	Two screens, Search-for-the-Needle style:
	  * Create Party (host, Status == "Picking"): a big card for the chosen dishwasher with
	    Public/Friends, Party Size -/+ and CREATE, a list of every dishwasher on the right, and BACK
	    underneath. Nothing is sent until CREATE (PartyAction "Create" { Level, MaxPlayers, Privacy });
	    BACK sends "Leave".
	  * Waiting card (everyone, Status == "Waiting"/"Launching"): a compact card at the top right with
	    the dishwasher, "2/4", "Teleporting in 12", member avatars, and [Start] (host) / [Leave].

	Works with mouse, touch and gamepad: the Create screen selects CREATE for gamepads, and B backs out.
	The server validates and rate-limits every PartyAction.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Colors = UIKit.Theme.Colors

local PartyUI = {}

local CREATE_SIZE = Vector2.new(940, 600)
local WAIT_WIDTH = 300
local RIGHT_COLUMN_CLEARANCE = 132 -- the HUD's right-hand button column

local initialized = false

local root: Frame
local createScreen: Frame
local createScale: UIScale
local leftCard: Frame
local levelList: ScrollingFrame
local waitCard: Frame
local waitContent: Frame
local waitStatus: TextLabel? = nil
local createButton: TextButton? = nil

-- Create-screen selections (local until CREATE is pressed).
local selLevel = 1
local selMax = Config.Party.MaxPlayers
local selPrivacy = "Public"
local wasPicking = false

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local thumbCache: { [number]: string } = {}
local thumbPending: { [number]: boolean } = {}

local function fetchThumbnail(userId: number, onReady: (content: string) -> ())
	local cached = thumbCache[userId]
	if cached then
		onReady(cached)
		return
	end
	if thumbPending[userId] then
		return
	end
	thumbPending[userId] = true
	task.spawn(function()
		local ok, content = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		thumbPending[userId] = nil
		if ok and type(content) == "string" and content ~= "" then
			thumbCache[userId] = content
			onReady(content)
		end
	end)
end

local function sendPartyAction(action: string, value: any?)
	local ok, err = pcall(function()
		Remotes.Event("PartyAction"):FireServer(action, value)
	end)
	if not ok then
		warn("[PartyUI] PartyAction failed: " .. tostring(err))
	end
end

local function unlocked(): number
	local party = ClientState.Party :: Types.PartyState?
	if party then
		return math.max(1, party.HostUnlocked)
	end
	local meta = ClientState.Meta :: Types.MetaState?
	return if meta then meta.Unlocked else 1
end

local function bestTime(levelIndex: number): number?
	local meta = ClientState.Meta :: Types.MetaState?
	local t = meta and meta.BestTimes[levelIndex]
	return if t and t > 0 then t else nil
end

-- "Map thumbnail" art for a dishwasher: a gradient in its theme colours, the chapter number big on
-- a soft glow, and a few bubbles. Built from UI only (no uploaded images).
local function levelArt(parent: Instance, levelIndex: number, size: UDim2, iconSize: number, locked: boolean, emblemAt: UDim2?): Frame
	local level = Config.GetLevel(levelIndex)
	local art = Instance.new("Frame")
	art.Name = "Art"
	art.Size = size
	art.BackgroundColor3 = Color3.new(1, 1, 1)
	art.BorderSizePixel = 0
	art.ClipsDescendants = true
	UIKit.Corner(art, 14)
	UIKit.Gradient(art, UIKit.Lighten(level.Theme.Accent, 0.25), UIKit.Darken(level.Theme.Accent, 0.35))
	for i = 1, 6 do
		local b = Instance.new("Frame")
		local d = 14 + (i * 37) % 30
		b.Size = UDim2.fromOffset(d, d)
		b.Position = UDim2.new((i * 0.173) % 1, 0, (i * 0.311) % 1, 0)
		b.BackgroundColor3 = Color3.new(1, 1, 1)
		b.BackgroundTransparency = 0.75
		UIKit.Corner(b, 999)
		b.Parent = art
	end
	-- A soft glow behind the level's emblem (a padlock while it's locked).
	local emblemSize = math.floor(iconSize * 1.35)
	local at = emblemAt or UDim2.fromScale(0.5, 0.52)
	local glow = Instance.new("Frame")
	glow.AnchorPoint = Vector2.new(0.5, 0.5)
	glow.Position = at
	glow.Size = UDim2.fromOffset(emblemSize * 1.25, emblemSize * 1.25)
	glow.BackgroundColor3 = Color3.new(1, 1, 1)
	glow.BackgroundTransparency = 0.72
	glow.BorderSizePixel = 0
	UIKit.Corner(glow, 999)
	glow.Parent = art
	if locked then
		UIKit.Icon("Lock", emblemSize, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = at,
			Parent = art,
		})
	else
		-- the chapter number, big and bold, on the glow
		UIKit.Label({
			Text = tostring(levelIndex),
			TextSize = math.floor(emblemSize * 0.95),
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = at,
			Size = UDim2.fromOffset(emblemSize, emblemSize),
			StrokeThickness = math.max(2, math.floor(emblemSize / 18)),
			Parent = art,
		})
	end
	if locked then
		art.BackgroundColor3 = Color3.fromRGB(120, 125, 135)
	end
	art.Parent = parent
	return art
end

local function listLayout(parent: Instance, dir: Enum.FillDirection, pad: number, hAlign: Enum.HorizontalAlignment?): UIListLayout
	local l = Instance.new("UIListLayout")
	l.SortOrder = Enum.SortOrder.LayoutOrder
	l.FillDirection = dir
	l.Padding = UDim.new(0, pad)
	l.HorizontalAlignment = hAlign or Enum.HorizontalAlignment.Center
	-- Scrolling lists must be top-aligned: a centred list taller than its frame spills above the
	-- top, where it can't be scrolled to (that's what cut off the first dishwasher card).
	l.VerticalAlignment = if parent:IsA("ScrollingFrame") then Enum.VerticalAlignment.Top else Enum.VerticalAlignment.Center
	l.Parent = parent
	return l
end

local function panel(parent: Instance, size: UDim2): Frame
	local f = Instance.new("Frame")
	f.Size = size
	f.BackgroundColor3 = Color3.new(1, 1, 1)
	f.BorderSizePixel = 0
	UIKit.Corner(f, 18)
	UIKit.Gradient(f, Colors.Panel, Colors.PanelDark)
	UIKit.Stroke(f, Colors.Ink, 3)
	f.Parent = parent
	return f
end

----------------------------------------------------------------------------------------------------
-- Create Party screen
----------------------------------------------------------------------------------------------------

local renderCreate: () -> ()

local function renderLevelList()
	for _, child in levelList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local maxUnlocked = unlocked()
	for i, level in Config.Levels do
		local locked = i > maxUnlocked
		local selected = i == selLevel
		local card = Instance.new("TextButton")
		card.Name = "Level" .. i
		card.LayoutOrder = i
		card.Size = UDim2.new(1, -8, 0, 112)
		card.AutoButtonColor = false
		card.Text = ""
		card.BackgroundTransparency = 1
		card.SelectionImageObject = nil
		card.Parent = levelList
		local art = levelArt(card, i, UDim2.fromScale(1, 1), 54, locked, UDim2.new(0, 60, 0.5, 0))
		local stroke = UIKit.Stroke(art, if selected then Color3.new(1, 1, 1) else Colors.Ink, if selected then 4 else 2)
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		UIKit.Label({
			Text = string.upper(level.Name),
			TextSize = 24,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -10, 1, -6),
			Size = UDim2.new(1, -130, 0, 30),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextScaled = true,
			Parent = art,
		})
		UIKit.Label({
			Text = "CHAPTER " .. i,
			TextSize = 18,
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -10, 1, -36),
			Size = UDim2.new(1, -130, 0, 22),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = Color3.fromRGB(255, 220, 110),
			Parent = art,
		})
		local best = bestTime(i)
		UIKit.Label({
			Text = if locked then string.format("Clear %s to unlock", Config.GetLevel(i - 1).Name) elseif best then "Best " .. UIKit.Time(best) else "Not cleared yet",
			TextSize = 15,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 6),
			Size = UDim2.new(1, -130, 0, 20),
			TextXAlignment = Enum.TextXAlignment.Right,
			TextScaled = true,
			TextColor3 = Color3.fromRGB(235, 240, 250),
			Parent = art,
		})
		card.Activated:Connect(function()
			if locked then
				UIKit.PlaySound("Error")
				UIKit.Toast("Clear " .. Config.GetLevel(i - 1).Name .. " first!", "Bad")
				return
			end
			UIKit.PlaySound("Click")
			selLevel = i
			renderCreate()
		end)
	end
	-- The next chapter, still being written.
	local n = #Config.Levels + 1
	local soon = Instance.new("TextButton")
	soon.Name = "ComingSoon"
	soon.LayoutOrder = n
	soon.Size = UDim2.new(1, -8, 0, 112)
	soon.AutoButtonColor = false
	soon.Text = ""
	soon.BackgroundColor3 = Color3.fromRGB(96, 102, 116)
	soon.BorderSizePixel = 0
	soon.SelectionImageObject = nil
	UIKit.Corner(soon, 14)
	UIKit.Gradient(soon, Color3.fromRGB(124, 130, 146), Color3.fromRGB(78, 84, 98))
	local soonStroke = UIKit.Stroke(soon, Colors.Ink, 2)
	soonStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	soon.Parent = levelList
	UIKit.Icon("Lock", 64, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0, 60, 0.5, 0), Parent = soon })
	UIKit.Label({
		Text = "CHAPTER " .. n,
		TextSize = 18,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -36),
		Size = UDim2.new(1, -130, 0, 22),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Color3.fromRGB(255, 220, 110),
		Parent = soon,
	})
	UIKit.Label({
		Text = "MORE CHAPTERS COMING SOON",
		TextSize = 22,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -6),
		Size = UDim2.new(1, -130, 0, 28),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextScaled = true,
		Parent = soon,
	})
	soon.Activated:Connect(function()
		UIKit.PlaySound("Error")
		UIKit.Toast("The next chapter is on its way. Stay tuned!", "Info")
	end)
end

function renderCreate()
	for _, child in leftCard:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local level = Config.GetLevel(selLevel)

	local art = levelArt(leftCard, selLevel, UDim2.new(1, -24, 0, 190), 110, false)
	art.Position = UDim2.fromOffset(12, 12)
	UIKit.Label({
		Text = "CHAPTER " .. selLevel,
		TextSize = 22,
		Position = UDim2.fromOffset(14, 10),
		Size = UDim2.fromOffset(200, 28),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = art,
	})
	UIKit.Label({
		Text = string.upper(level.Name),
		TextSize = 44,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 208),
		Size = UDim2.new(1, -24, 0, 50),
		TextScaled = true,
		Parent = leftCard,
	})
	UIKit.Label({
		Text = "CREATE PARTY",
		TextSize = 26,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 254),
		Size = UDim2.new(1, -24, 0, 32),
		Parent = leftCard,
	})
	local divider = Instance.new("Frame")
	divider.Size = UDim2.new(0.8, 0, 0, 3)
	divider.AnchorPoint = Vector2.new(0.5, 0)
	divider.Position = UDim2.new(0.5, 0, 0, 288)
	divider.BackgroundColor3 = Color3.new(1, 1, 1)
	divider.BorderSizePixel = 0
	divider.Parent = leftCard

	-- Public / Friends.
	local privacyRow = Instance.new("Frame")
	privacyRow.BackgroundTransparency = 1
	privacyRow.AnchorPoint = Vector2.new(0.5, 0)
	privacyRow.Position = UDim2.new(0.5, 0, 0, 298)
	privacyRow.Size = UDim2.new(1, -24, 0, 50)
	privacyRow.Parent = leftCard
	listLayout(privacyRow, Enum.FillDirection.Horizontal, 10)
	for _, option in { { "Public", "PUBLIC", Colors.Primary }, { "Friends", "FRIENDS", Colors.Accent } } do
		local key = option[1]
		UIKit.Button({
			Text = option[2],
			Size = UDim2.fromOffset(180, 46),
			Color = if selPrivacy == key then option[3] else Colors.Disabled,
			TextSize = 22,
			Parent = privacyRow,
			OnClick = function()
				selPrivacy = key
				renderCreate()
			end,
		})
	end

	-- Party size.
	UIKit.Label({
		Text = "Party Size:",
		TextSize = 28,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 350),
		Size = UDim2.new(1, -24, 0, 32),
		Parent = leftCard,
	})
	local sizeRow = Instance.new("Frame")
	sizeRow.BackgroundTransparency = 1
	sizeRow.AnchorPoint = Vector2.new(0.5, 0)
	sizeRow.Position = UDim2.new(0.5, 0, 0, 382)
	sizeRow.Size = UDim2.new(1, -24, 0, 52)
	sizeRow.Parent = leftCard
	listLayout(sizeRow, Enum.FillDirection.Horizontal, 16)
	UIKit.Button({
		Text = "−",
		Size = UDim2.fromOffset(60, 50),
		Color = Colors.PanelLight,
		Disabled = selMax <= 1,
		LayoutOrder = 1,
		Parent = sizeRow,
		OnClick = function()
			selMax = math.max(1, selMax - 1)
			renderCreate()
		end,
	})
	local count = UIKit.Card({ Size = UDim2.fromOffset(70, 50), LayoutOrder = 2, Parent = sizeRow })
	UIKit.Label({ Text = tostring(selMax), TextSize = 36, Size = UDim2.fromScale(1, 1), Parent = count })
	UIKit.Button({
		Text = "+",
		Size = UDim2.fromOffset(60, 50),
		Color = Colors.PanelLight,
		Disabled = selMax >= Config.Party.MaxPlayers,
		LayoutOrder = 3,
		Parent = sizeRow,
		OnClick = function()
			selMax = math.min(Config.Party.MaxPlayers, selMax + 1)
			renderCreate()
		end,
	})

	createButton = UIKit.Button({
		Name = "Create",
		Text = "CREATE",
		Size = UDim2.fromOffset(300, 60),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Color = Colors.Good,
		TextSize = 32,
		Parent = leftCard,
		OnClick = function()
			sendPartyAction("Create", { Level = selLevel, MaxPlayers = selMax, Privacy = selPrivacy })
		end,
	})

	renderLevelList()
	if UIKit.IsGamepad() and createButton then
		GuiService.SelectedObject = createButton
	end
end

local function layoutCreate()
	local canvas = UIKit.CanvasSize()
	local inset = UIKit.TopInset()
	local fit = math.clamp(math.min((canvas.X - 24) / CREATE_SIZE.X, (canvas.Y - inset - 24) / CREATE_SIZE.Y), 0.4, 1)
	createScale.Scale = fit
	createScreen.Position = UDim2.new(0.5, 0, 0.5, math.floor(inset / 2))
end

local function buildCreateScreen()
	createScreen = Instance.new("Frame")
	createScreen.Name = "CreateParty"
	createScreen.AnchorPoint = Vector2.new(0.5, 0.5)
	createScreen.Size = UDim2.fromOffset(CREATE_SIZE.X, CREATE_SIZE.Y)
	createScreen.BackgroundTransparency = 1
	createScreen.Visible = false
	createScreen.ZIndex = 20
	createScreen.Parent = root
	createScale = Instance.new("UIScale")
	createScale.Parent = createScreen

	leftCard = panel(createScreen, UDim2.fromOffset(540, 520))
	leftCard.Name = "Selected"

	local right = panel(createScreen, UDim2.fromOffset(380, 520))
	right.Name = "Dishwashers"
	right.Position = UDim2.fromOffset(560, 0)
	UIKit.Label({
		Text = "CHAPTERS",
		TextSize = 26,
		Position = UDim2.fromOffset(0, 10),
		Size = UDim2.new(1, 0, 0, 30),
		Parent = right,
	})
	levelList = Instance.new("ScrollingFrame")
	levelList.Name = "List"
	levelList.Position = UDim2.fromOffset(12, 48)
	levelList.Size = UDim2.new(1, -18, 1, -60)
	levelList.BackgroundTransparency = 1
	levelList.BorderSizePixel = 0
	levelList.ScrollBarThickness = 6
	levelList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	levelList.CanvasSize = UDim2.new()
	levelList.Parent = right
	listLayout(levelList, Enum.FillDirection.Vertical, 10, Enum.HorizontalAlignment.Left)
	local listPad = Instance.new("UIPadding")
	listPad.PaddingTop = UDim.new(0, 8)
	listPad.PaddingBottom = UDim.new(0, 8)
	listPad.PaddingLeft = UDim.new(0, 6)
	listPad.PaddingRight = UDim.new(0, 6)
	listPad.Parent = levelList

	UIKit.Button({
		Text = "BACK",
		Size = UDim2.fromOffset(200, 56),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0, 270, 1, 0),
		Color = Colors.Bad,
		TextSize = 30,
		Parent = createScreen,
		OnClick = function()
			sendPartyAction("Leave", nil)
		end,
	})
end

----------------------------------------------------------------------------------------------------
-- Waiting card
----------------------------------------------------------------------------------------------------

local function renderWait(party: Types.PartyState)
	for _, child in waitContent:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local level = Config.GetLevel(party.Level)
	local launching = party.Status == "Launching"

	local art = levelArt(waitContent, party.Level, UDim2.new(1, 0, 0, 110), 64, false)
	art.LayoutOrder = 1
	UIKit.Label({
		Text = string.format("CH. %d: %s", party.Level, string.upper(level.Name)),
		TextSize = 22,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4),
		Size = UDim2.new(1, -12, 0, 26),
		TextScaled = true,
		Parent = art,
	})
	UIKit.Label({
		Text = if party.Privacy == "Public" then "🌐" else "👥",
		TextSize = 20,
		Position = UDim2.fromOffset(6, 4),
		Size = UDim2.fromOffset(26, 26),
		Parent = art,
	})

	UIKit.Label({
		Text = string.format("%d/%d", #party.Members, party.MaxPlayers),
		TextSize = 54,
		Size = UDim2.new(1, 0, 0, 58),
		LayoutOrder = 2,
		Parent = waitContent,
	})
	local status = UIKit.Label({
		Text = if launching then "Teleporting..." else "",
		TextSize = 24,
		Size = UDim2.new(1, 0, 0, 30),
		TextColor3 = if launching then Colors.Good else Colors.Text,
		LayoutOrder = 3,
		Parent = waitContent,
	})
	waitStatus = if launching then nil else status

	local avatars = Instance.new("Frame")
	avatars.BackgroundTransparency = 1
	avatars.Size = UDim2.new(1, 0, 0, 46)
	avatars.LayoutOrder = 4
	avatars.Parent = waitContent
	listLayout(avatars, Enum.FillDirection.Horizontal, 6)
	for _, member in party.Members do
		local isHost = member.UserId == party.HostUserId
		local avatarSize = if #party.Members > 5 then 34 else 42 -- up to 8 fit on one row
		local img = UIKit.New("ImageLabel", {
			Size = UDim2.fromOffset(avatarSize, avatarSize),
			BackgroundColor3 = Colors.PanelLight,
			ScaleType = Enum.ScaleType.Crop,
			Parent = avatars,
		}) :: ImageLabel
		UIKit.Corner(img, 999)
		UIKit.Stroke(img, if isHost then Colors.Coin else Colors.Ink, if isHost then 3 else 2)
		fetchThumbnail(member.UserId, function(image)
			if img.Parent then
				img.Image = image
			end
		end)
	end

	local buttons = Instance.new("Frame")
	buttons.BackgroundTransparency = 1
	buttons.Size = UDim2.new(1, 0, 0, 48)
	buttons.LayoutOrder = 5
	buttons.Parent = waitContent
	listLayout(buttons, Enum.FillDirection.Horizontal, 10)
	if party.IsHost then
		UIKit.Button({
			Text = "START",
			Size = UDim2.fromOffset(130, 44),
			Color = Colors.Good,
			Disabled = launching,
			Parent = buttons,
			OnClick = function()
				sendPartyAction("StartNow", nil)
			end,
		})
	end
	UIKit.Button({
		Text = "LEAVE",
		Size = UDim2.fromOffset(130, 44),
		Color = Colors.Bad,
		Disabled = launching,
		Parent = buttons,
		OnClick = function()
			sendPartyAction("Leave", nil)
		end,
	})
	if waitStatus then
		local remaining = math.max(0, math.ceil(party.EndsAt - workspace:GetServerTimeNow()))
		waitStatus.Text = string.format("Teleporting in %d", remaining)
	end
end

local function buildWaitCard()
	waitCard = panel(root, UDim2.fromOffset(WAIT_WIDTH, 0))
	waitCard.Name = "PartyWaiting"
	waitCard.AnchorPoint = Vector2.new(1, 0)
	waitCard.AutomaticSize = Enum.AutomaticSize.Y
	waitCard.Visible = false
	waitCard.ZIndex = 10
	waitContent = Instance.new("Frame")
	waitContent.BackgroundTransparency = 1
	waitContent.Size = UDim2.new(1, 0, 0, 0)
	waitContent.AutomaticSize = Enum.AutomaticSize.Y
	waitContent.Parent = waitCard
	UIKit.Padding(waitContent, 12)
	listLayout(waitContent, Enum.FillDirection.Vertical, 6)
end

local function layoutWait()
	local safe = UIKit.SafeInsets()
	waitCard.Position = UDim2.new(1, -(RIGHT_COLUMN_CLEARANCE + safe.Right), 0, UIKit.TopInset() + 90)
end

----------------------------------------------------------------------------------------------------
-- Render
----------------------------------------------------------------------------------------------------

local function render()
	local party = ClientState.Party :: Types.PartyState?
	local picking = party ~= nil and party.Status == "Picking" and party.IsHost
	if picking and not wasPicking and party then
		-- Fresh Create screen: start from the server's defaults (their best dishwasher).
		selLevel = math.clamp(party.Level, 1, unlocked())
		selMax = party.MaxPlayers
		selPrivacy = party.Privacy
		UIKit.CloseWindow()
	end
	wasPicking = picking

	createScreen.Visible = picking
	if picking then
		layoutCreate()
		renderCreate()
	elseif GuiService.SelectedObject and GuiService.SelectedObject:IsDescendantOf(createScreen) then
		GuiService.SelectedObject = nil
	end

	local waiting = party ~= nil and not picking
	waitCard.Visible = waiting
	if waiting and party then
		layoutWait()
		renderWait(party)
	else
		waitStatus = nil
	end
end

local function countdownLoop()
	while true do
		local party = ClientState.Party
		if party and party.Status == "Waiting" and waitStatus and waitStatus.Parent then
			local remaining = math.max(0, math.ceil(party.EndsAt - workspace:GetServerTimeNow()))
			waitStatus.Text = string.format("Teleporting in %d", remaining)
			task.wait(0.1)
		else
			task.wait(0.5)
		end
	end
end

function PartyUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, r = UIKit.CreateScreen("PartyUI", 8)
	root = r
	buildCreateScreen()
	buildWaitCard()

	UIKit.LayoutChanged:Connect(function()
		if createScreen.Visible then
			layoutCreate()
		end
		if waitCard.Visible then
			layoutWait()
		end
	end)

	ClientState.Changed:Connect(function(kind)
		if kind == "Party" or (kind == "Meta" and createScreen.Visible) then
			render()
		end
	end)

	-- B on a gamepad (or Backspace) backs out of the Create screen, like the BACK button.
	UserInputService.InputBegan:Connect(function(input, processed)
		if not createScreen.Visible then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB or (not processed and input.KeyCode == Enum.KeyCode.Backspace) then
			sendPartyAction("Leave", nil)
		end
	end)

	render()
	task.spawn(countdownLoop)
end

return PartyUI
