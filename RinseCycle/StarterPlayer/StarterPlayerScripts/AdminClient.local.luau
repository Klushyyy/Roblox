--[[
	AdminClient - Rinse Cycle's admin panel and the admin effects every player can see.

	Everyone:
	  * Notices from staff (a centred card with an OK button), announcements (a banner across the
	    top), and status chips under the top bar: 🧊 Frozen, 🔇 Muted (with time left; the chat bar
	    is switched off too), 🎮 Being controlled, 🕊️ Flying (tap it or press F to take off / land).
	  * The full-screen cover that hides admin teleports (jail, spectate, control).

	The owner only (the server's GetAdminInfo decides; nobody else gets any of the panel):
	  * A 🛡️ Admin button under Trade in the left column (HUD.AddAdminButton). It opens the Admin window,
	    built with the game's own UIKit window style.
	  * Left: every player in the server (search, tap to pick). Top: command groups. Middle: that
	    group's commands. Bottom: the picked command's options (reason, amount, duration, rank, pet,
	    pass...) and a RUN button. There's also a command line (":mute name reason") for speed.
	  * Ban / mute / warn lists, the command log and inventories open inside the window, with
	    Modify / Remove / View on each row.
	  * Spectate and Control Player show a bar at the bottom with a Stop button.

	The server checks every command again (tier, owner, Studio-only). This script only draws.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local Client = script.Parent:WaitForChild("Client")
local UIKit = require(Client:WaitForChild("UIKit"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Colors = UIKit.Theme.Colors
local Fonts = UIKit.Theme.Fonts

local function remote(name: string): any
	return ReplicatedStorage:WaitForChild(name)
end

local GetAdminInfo = remote("GetAdminInfo")
local AdminCommand = remote("AdminCommand")
local AdminNotice = remote("AdminNotice")
local AdminFeedback = remote("AdminFeedback")
local AdminWarningsList = remote("AdminWarningsList")
local AdminViewWarnings = remote("AdminViewWarnings")
local AdminRemoveWarning = remote("AdminRemoveWarning")
local AdminBanList = remote("AdminBanList")
local AdminMuteList = remote("AdminMuteList")
local AdminWarnList = remote("AdminWarnList")
local AdminModifyPunishment = remote("AdminModifyPunishment")
local AdminLogsList = remote("AdminLogsList")
local AdminScreenFade = remote("AdminScreenFade")
local AdminRemoveLogEntry = remote("AdminRemoveLogEntry")
local AdminAnnouncement = remote("AdminAnnouncement")
local AdminFreezeStatus = remote("AdminFreezeStatus")
local AdminMuteStatus = remote("AdminMuteStatus")
local AdminSetFlying = remote("AdminSetFlying")
local AdminSpectate = remote("AdminSpectate")
local AdminStopSpectating = remote("AdminStopSpectating")
local AdminControlPlayer = remote("AdminControlPlayer")
local AdminControlMove = remote("AdminControlMove")
local AdminStopControlling = remote("AdminStopControlling")
local AdminControlTargetStatus = remote("AdminControlTargetStatus")
local AdminInventoryList = remote("AdminInventoryList")
local AdminInventoryRemoveItem = remote("AdminInventoryRemoveItem")
-- Remotes added in later versions of AdminServer. They're never waited on up front: if the server
-- script is older (or hasn't made them yet) the panel and the Admin button still appear, and only
-- that one feature does nothing until it exists.
local function laterRemote(name: string): any
	return {
		FireServer = function(_, ...)
			local r = ReplicatedStorage:FindFirstChild(name)
			if r and r:IsA("RemoteEvent") then
				r:FireServer(...)
			end
		end,
		OnClientEvent = {
			Connect = function(_, fn)
				task.spawn(function()
					local r = ReplicatedStorage:WaitForChild(name)
					if r:IsA("RemoteEvent") then
						r.OnClientEvent:Connect(fn)
					end
				end)
			end,
		},
	}
end
local AdminLeaderboard = laterRemote("AdminLeaderboard")
local AdminPetList = laterRemote("AdminPetList")
local AdminPetAction = laterRemote("AdminPetAction")
local AdminStaffList = laterRemote("AdminStaffList")
local AdminStaffAction = laterRemote("AdminStaffAction")
local AdminServerList = laterRemote("AdminServerList")
local AdminServerAction = laterRemote("AdminServerAction")
local AdminReport = laterRemote("AdminReport")
local PassWinners = laterRemote("PassWinners")

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

local function formatDuration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local d = seconds // 86400
	local h = (seconds % 86400) // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if d > 0 then
		return string.format("%dd %dh", d, h)
	elseif h > 0 then
		return string.format("%dh %dm", h, m)
	elseif m > 0 then
		return string.format("%dm %ds", m, s)
	end
	return string.format("%ds", s)
end

local function textBox(props: { [string]: any }): TextBox
	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Fonts.Body
	box.TextSize = 18
	box.TextColor3 = Colors.Text
	box.PlaceholderColor3 = Colors.TextDim
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Text = ""
	for k, v in props do
		(box :: any)[k] = v
	end
	return box
end

-- A dark rounded field holding a TextBox.
local function field(parent: Instance, size: UDim2, position: UDim2, placeholder: string): TextBox
	local card = UIKit.Card({ Size = size, Position = position, Color = Colors.PanelDark, Parent = parent })
	card.Name = "Field"
	return textBox({
		Name = "Box",
		Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		PlaceholderText = placeholder,
		Parent = card,
	})
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIGridLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local function listLayout(parent: Instance, padding: number, horizontal: boolean?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, padding)
	if horizontal then
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
	end
	layout.Parent = parent
	return layout
end

local function scroller(parent: Instance, size: UDim2, position: UDim2, horizontal: boolean?): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.Size = size
	s.Position = position
	s.ScrollBarThickness = 6
	s.ScrollBarImageColor3 = Colors.Primary
	s.CanvasSize = UDim2.new()
	s.AutomaticCanvasSize = if horizontal then Enum.AutomaticSize.X else Enum.AutomaticSize.Y
	s.ScrollingDirection = if horizontal then Enum.ScrollingDirection.X else Enum.ScrollingDirection.Y
	s.Parent = parent
	return s
end

----------------------------------------------------------------------------------------------------
-- Everyone: notices, announcements, status chips, flying, the teleport cover
----------------------------------------------------------------------------------------------------

local _statusGui, statusRoot = UIKit.CreateScreen("AdminStatus", 40)

-- Notice card (from AdminNotice): one at a time, the newest replaces the old one.
local noticeFrame: Frame? = nil
local function showNotice(title: string?, body: string?, footnote: string?, buttonLabel: string?)
	if noticeFrame then
		noticeFrame:Destroy()
	end
	local dim = Instance.new("Frame")
	dim.Name = "AdminNotice"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Colors.Ink
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Active = true
	dim.ZIndex = 50
	dim.Parent = statusRoot
	noticeFrame = dim
	local card = UIKit.Card({
		Size = UDim2.fromOffset(560, 300),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = Colors.Panel,
		Parent = dim,
	})
	UIKit.Stroke(card, Colors.Ink, 4)
	UIKit.Label({
		Text = "🛡️ " .. tostring(title or "Message from staff"),
		TextSize = 32,
		Size = UDim2.new(1, -40, 0, 44),
		Position = UDim2.fromOffset(20, 18),
		TextColor3 = Colors.Primary,
		Parent = card,
	})
	UIKit.Label({
		Text = tostring(body or ""),
		TextSize = 22,
		TextWrapped = true,
		Font = Fonts.Body,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, -48, 0, 120),
		Position = UDim2.fromOffset(24, 72),
		Parent = card,
	})
	if footnote and footnote ~= "" then
		UIKit.Label({
			Text = tostring(footnote),
			TextSize = 16,
			TextWrapped = true,
			TextColor3 = Colors.TextDim,
			Size = UDim2.new(1, -48, 0, 24),
			Position = UDim2.fromOffset(24, 196),
			Parent = card,
		})
	end
	UIKit.Button({
		Text = tostring(buttonLabel or "OKAY"),
		Color = Colors.Primary,
		Size = UDim2.fromOffset(200, 54),
		Position = UDim2.new(0.5, 0, 1, -18),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = card,
		OnClick = function()
			dim:Destroy()
			if noticeFrame == dim then
				noticeFrame = nil
			end
		end,
	})
end
AdminNotice.OnClientEvent:Connect(showNotice)

-- Announcement banner (from :announce).
local bannerToken = 0
AdminAnnouncement.OnClientEvent:Connect(function(message: string)
	bannerToken += 1
	local token = bannerToken
	local old = statusRoot:FindFirstChild("Announcement")
	if old then
		old:Destroy()
	end
	local banner = UIKit.Card({
		Size = UDim2.fromOffset(820, 116),
		Position = UDim2.new(0.5, 0, 0, -140),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Panel,
		Parent = statusRoot,
	})
	banner.Name = "Announcement"
	UIKit.Stroke(banner, Colors.Primary, 4)
	UIKit.Label({
		Text = "📢 ANNOUNCEMENT",
		TextSize = 20,
		TextColor3 = Colors.Primary,
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.fromOffset(0, 8),
		Parent = banner,
	})
	UIKit.Label({
		Text = tostring(message),
		TextSize = 26,
		TextWrapped = true,
		TextScaled = true, -- shrinks to fit: a long message is never cut off
		Size = UDim2.new(1, -40, 0, 70),
		Position = UDim2.fromOffset(20, 38),
		Parent = banner,
	})
	UIKit.PlaySound("Click")
	local shown = UDim2.new(0.5, 0, 0, UIKit.TopInset() + 12)
	TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = shown }):Play()
	task.delay(8, function()
		if token ~= bannerToken or not banner.Parent then
			return
		end
		TweenService:Create(banner, TweenInfo.new(0.3), { Position = UDim2.new(0.5, 0, 0, -140) }):Play()
		task.delay(0.35, function()
			banner:Destroy()
		end)
	end)
end)

-- Pass drop ("Congrats to those who won a gamepass!"): a card across the top with a View button that opens the list of who
-- won which pass. Sent to everyone by :globalpassdrop and by the Admin Abuse prize (AdminServer "PassWinners").
local winnersWindow: Frame? = nil
local function openWinners(board: { any })
	if winnersWindow then
		winnersWindow:Destroy()
	end
	local dim = Instance.new("Frame")
	dim.Name = "PassWinnersWindow"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Colors.Ink
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Active = true
	dim.ZIndex = 50
	dim.Parent = statusRoot
	winnersWindow = dim
	local card = UIKit.Card({
		Size = UDim2.fromOffset(600, 470),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = Colors.Panel,
		Parent = dim,
	})
	UIKit.Stroke(card, Colors.Ink, 4)
	-- (never wider or taller than the screen: a portrait phone's canvas is only about 720 wide)
	local PHONE_BOOST = 1.2
	UIKit.PhoneBoost(card, PHONE_BOOST) -- (drawn a little bigger on a phone, where the 20 px text would be tiny)
	local function fit()
		local canvas = UIKit.CanvasSize()
		local boost = if UIKit.IsTouch() and canvas.Y <= 800 then PHONE_BOOST else 1
		card.Size = UDim2.fromOffset(math.min(600, (canvas.X - 24) / boost), math.min(470, (canvas.Y - 24) / boost))
	end
	fit()
	local fitConn = UIKit.LayoutChanged:Connect(fit)
	dim.Destroying:Connect(function()
		fitConn:Disconnect()
		if winnersWindow == dim then
			winnersWindow = nil
		end
	end)
	local mine = false
	for _, w in board do
		if w.Id == player.UserId then
			mine = true
		end
	end
	UIKit.Label({
		Text = "Gamepass winners",
		TextSize = 32,
		TextScaled = true,
		TextColor3 = Colors.Coin,
		Size = UDim2.new(1, -40, 0, 44),
		Position = UDim2.fromOffset(20, 14),
		Parent = card,
	})
	UIKit.Label({
		Text = string.format("%d winner%s%s", #board, if #board == 1 then "" else "s", if mine then " - and you are one of them!" else ""),
		TextSize = 20,
		TextScaled = true,
		TextColor3 = if mine then Colors.Good else Colors.TextDim,
		Size = UDim2.new(1, -40, 0, 28),
		Position = UDim2.fromOffset(20, 60),
		Parent = card,
	})
	local list = scroller(card, UDim2.new(1, -40, 1, -184), UDim2.fromOffset(20, 96))
	listLayout(list, 6)
	-- grouped by pass, in the order each pass first came up
	local order, groups = {}, {}
	for _, w in board do
		local group = groups[w.Pass]
		if not group then
			group = {}
			groups[w.Pass] = group
			table.insert(order, w.Pass)
		end
		table.insert(group, w)
	end
	local row = 0
	for _, passName in order do
		local group = groups[passName]
		row += 1
		UIKit.Label({
			Text = string.format("%s  (%d)", passName, #group),
			TextSize = 22,
			TextColor3 = Colors.Coin,
			TextXAlignment = Enum.TextXAlignment.Left,
			Size = UDim2.new(1, -10, 0, 30),
			LayoutOrder = row,
			Parent = list,
		})
		for _, w in group do
			row += 1
			local you = w.Id == player.UserId
			local line = UIKit.Card({ Size = UDim2.new(1, -10, 0, 38), Color = if you then Colors.PrimaryDark else Colors.PanelDark, LayoutOrder = row, Parent = list })
			UIKit.Label({
				Text = tostring(w.Name) .. (if you then "  (you)" else ""),
				TextSize = 20,
				Font = Fonts.Body,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -28, 1, 0),
				Position = UDim2.fromOffset(14, 0),
				Parent = line,
			})
		end
	end
	UIKit.Button({
		Text = "CLOSE",
		Color = Colors.Primary,
		Size = UDim2.fromOffset(200, 54),
		Position = UDim2.new(0.5, 0, 1, -16),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = card,
		OnClick = function()
			dim:Destroy()
		end,
	})
end

local passDropToken = 0
PassWinners.OnClientEvent:Connect(function(kind: any, board: any)
	if kind ~= "Drop" or type(board) ~= "table" or #board == 0 then
		return
	end
	passDropToken += 1
	local token = passDropToken
	local old = statusRoot:FindFirstChild("PassDropCard")
	if old then
		old:Destroy()
	end
	local mine = false
	local names = {}
	for _, w in board do
		if w.Id == player.UserId then
			mine = true
		end
		table.insert(names, tostring(w.Name))
	end
	local card = UIKit.Card({
		Size = UDim2.fromOffset(760, 156),
		Position = UDim2.new(0.5, 0, 0, -200),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Panel,
		Parent = statusRoot,
	})
	card.Name = "PassDropCard"
	UIKit.Stroke(card, Colors.Coin, 4)
	local PHONE_BOOST = 1.2
	UIKit.PhoneBoost(card, PHONE_BOOST)
	local function fit()
		local canvas = UIKit.CanvasSize()
		local boost = if UIKit.IsTouch() and canvas.Y <= 800 then PHONE_BOOST else 1
		card.Size = UDim2.fromOffset(math.min(760, (canvas.X - 24) / boost), 156)
	end
	fit()
	local fitConn = UIKit.LayoutChanged:Connect(fit)
	card.Destroying:Connect(function()
		fitConn:Disconnect()
	end)
	UIKit.Label({
		Text = "GAMEPASS GIVEAWAY",
		TextSize = 18,
		TextColor3 = Colors.Coin,
		Size = UDim2.new(1, 0, 0, 24),
		Position = UDim2.fromOffset(0, 8),
		Parent = card,
	})
	UIKit.Label({
		Text = "Congrats to those who won a gamepass!",
		TextSize = 30,
		TextScaled = true,
		Size = UDim2.new(1, -40, 0, 40),
		Position = UDim2.fromOffset(20, 34),
		Parent = card,
	})
	local shown = table.concat(names, ", ", 1, math.min(#names, 3)) .. (if #names > 3 then string.format(" and %d more", #names - 3) else "")
	UIKit.Label({
		Text = if mine then "That includes YOU: " .. shown else shown,
		TextSize = 20,
		TextScaled = true,
		TextColor3 = if mine then Colors.Good else Colors.TextDim,
		Size = UDim2.new(1, -40, 0, 26),
		Position = UDim2.fromOffset(20, 76),
		Parent = card,
	})
	local function dismiss()
		if token ~= passDropToken or not card.Parent then
			return
		end
		passDropToken += 1 -- (the 25-second timer below is now stale)
		TweenService:Create(card, TweenInfo.new(0.3), { Position = UDim2.new(0.5, 0, 0, -200) }):Play()
		task.delay(0.35, function()
			card:Destroy()
		end)
	end
	UIKit.Button({
		Text = "VIEW",
		Color = Colors.Primary,
		Size = UDim2.fromOffset(150, 42),
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(0.5, -6, 1, -8),
		Parent = card,
		OnClick = function()
			openWinners(board)
			dismiss()
		end,
	})
	UIKit.Button({
		Text = "CLOSE",
		Color = Colors.PanelLight,
		Size = UDim2.fromOffset(150, 42),
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.5, 6, 1, -8),
		Parent = card,
		OnClick = dismiss,
	})
	UIKit.PlaySound("Click")
	TweenService:Create(card, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.new(0.5, 0, 0, UIKit.TopInset() + 12) }):Play()
	task.delay(25, dismiss)
end)

-- Status chips under the top bar.
local chipRow = Instance.new("Frame")
chipRow.Name = "Chips"
chipRow.BackgroundTransparency = 1
chipRow.AnchorPoint = Vector2.new(0.5, 0)
chipRow.Size = UDim2.fromOffset(900, 44)
chipRow.Parent = statusRoot
local chipLayout = listLayout(chipRow, 10, true)
chipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
local function placeChips()
	-- (during the Admin Abuse show the speech box sits at the very top middle, so the chips go under it)
	local live = ReplicatedStorage:GetAttribute("AbuseLive") == true
	chipRow.Position = UDim2.new(0.5, 0, 0, UIKit.TopInset() + (if live then (if UIKit.CanvasSize().X < 900 then 150 else 114) else 70))
end
placeChips()
UIKit.LayoutChanged:Connect(placeChips)
ReplicatedStorage:GetAttributeChangedSignal("AbuseLive"):Connect(placeChips)

local function makeChip(name: string, color: Color3, order: number): (TextButton, TextLabel)
	local chip = Instance.new("TextButton")
	chip.Name = name
	chip.AutoButtonColor = false
	chip.Text = ""
	chip.Size = UDim2.fromOffset(200, 40)
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.BackgroundColor3 = color
	chip.BorderSizePixel = 0
	chip.LayoutOrder = order
	chip.Visible = false
	UIKit.Corner(chip, 20)
	UIKit.Stroke(chip, Colors.Ink, 3)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = chip
	local label = UIKit.Label({
		Text = "",
		TextSize = 20,
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = chip,
	})
	chip.Parent = chipRow
	return chip, label
end

local frozenChip, frozenLabel = makeChip("Frozen", Color3.fromRGB(96, 165, 250), 1)
frozenLabel.Text = "🧊 Frozen by staff"
local mutedChip, mutedLabel = makeChip("Muted", Colors.Bad, 2)
local controlledChip, controlledLabel = makeChip("Controlled", Colors.Warning, 3)
controlledLabel.Text = "🎮 Being controlled by staff"
local flyChip, flyLabel = makeChip("Flying", Colors.Accent, 4)
local giantChip, giantLabel = makeChip("GiantPerk", Colors.Warning, 5)

-- While frozen or being controlled by staff, this player's own movement keys / thumbstick / jump
-- do nothing at all (Roblox's PlayerModule controls are switched off), so they can't fight it.
local controlLocks: { [string]: boolean? } = {}
local function applyControlLock()
	local locked = next(controlLocks) ~= nil
	pcall(function()
		local playerModule = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: any) :: any
		local controls = playerModule:GetControls()
		if locked then
			controls:Disable()
		else
			controls:Enable()
		end
	end)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and locked then
		humanoid.Jump = false
	end
end
local function setControlLock(reason: string, on: boolean)
	controlLocks[reason] = if on then true else nil
	applyControlLock()
end

AdminFreezeStatus.OnClientEvent:Connect(function(frozen: boolean)
	frozenChip.Visible = frozen == true
	setControlLock("Frozen", frozen == true)
end)
AdminControlTargetStatus.OnClientEvent:Connect(function(controlled: boolean)
	controlledChip.Visible = controlled == true
	setControlLock("Controlled", controlled == true)
end)
-- A freeze only covers the character it was put on: a new character moves again.
player.CharacterAdded:Connect(function()
	if controlLocks.Frozen then
		frozenChip.Visible = false
		setControlLock("Frozen", false)
	end
end)

-- Muted: a chip with the time left, and the chat bar switched off (the server blocks the messages
-- themselves; this just makes it obvious).
local muteExpiresAt: number? = nil
local muted = false
local function setChatBar(enabled: boolean)
	pcall(function()
		local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
		if bar then
			bar.Enabled = enabled
		end
	end)
end
local function refreshMuteChip()
	mutedChip.Visible = muted
	if not muted then
		return
	end
	if muteExpiresAt then
		mutedLabel.Text = "🔇 Muted · " .. formatDuration(muteExpiresAt - os.time()) .. " left"
	else
		mutedLabel.Text = "🔇 Muted"
	end
end
AdminMuteStatus.OnClientEvent:Connect(function(isMuted: boolean, expiresAt: number?)
	muted = isMuted == true
	muteExpiresAt = if muted and type(expiresAt) == "number" then expiresAt else nil
	setChatBar(not muted)
	refreshMuteChip()
end)
task.spawn(function()
	while true do
		task.wait(1)
		if muted and muteExpiresAt and os.time() >= muteExpiresAt then
			muted = false
			muteExpiresAt = nil
			setChatBar(true)
		end
		refreshMuteChip()
	end
end)

-- Flying (:fly). While allowed: F or the chip takes off / lands. Moves with the normal controls
-- in the camera's direction; Space rises, Left Ctrl / Q sinks, Shift is faster.
local FLY_SPEED = 60
local flyAllowed = false
local flying = false
local flyParts: { Instance } = {}
local flyConn: RBXScriptConnection? = nil
local controls: any = nil
pcall(function()
	controls = (require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")) :: any):GetControls()
end)

local function moveVector(): Vector3
	local mv = Vector3.zero
	if controls then
		local ok, v = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(v) == "Vector3" then
			mv = v
		end
	end
	return mv
end

-- The server only learns that someone is flying from us (the flight is made on this screen): the obby uses it.
local flyStateRemote: RemoteEvent? = nil
task.spawn(function()
	flyStateRemote = ReplicatedStorage:WaitForChild("AbuseFlyState", 60) :: RemoteEvent?
end)
local function reportFlying(on: boolean)
	if flyStateRemote then
		flyStateRemote:FireServer(on)
	end
end

local function stopFlying()
	if flying then
		reportFlying(false)
	end
	flying = false
	if flyConn then
		flyConn:Disconnect()
		flyConn = nil
	end
	for _, inst in flyParts do
		inst:Destroy()
	end
	table.clear(flyParts)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
	end
end

local function startFlying()
	stopFlying()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return
	end
	flying = true
	reportFlying(true)
	local attachment = Instance.new("Attachment")
	attachment.Name = "AdminFly"
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.MaxForce = math.huge
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = true
	align.Parent = root
	flyParts = { attachment, velocity, align }
	humanoid.PlatformStand = true
	flyConn = RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		if not camera or not root.Parent then
			return
		end
		local mv = moveVector()
		local dir = camera.CFrame.RightVector * mv.X - camera.CFrame.LookVector * mv.Z
		if UserInputService:GetFocusedTextBox() == nil then
			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				dir += Vector3.yAxis
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
				dir -= Vector3.yAxis
			end
		end
		local speed = if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then FLY_SPEED * 2 else FLY_SPEED
		velocity.VectorVelocity = if dir.Magnitude > 1e-3 then dir.Unit * speed else Vector3.zero
		local look = camera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		align.CFrame = CFrame.lookAt(Vector3.zero, if flat.Magnitude > 1e-3 then flat else Vector3.new(0, 0, -1))
	end)
end

local function refreshFlyChip()
	flyChip.Visible = flyAllowed
	flyLabel.Text = if flying then "Fly perk: ON (F)" else "Fly perk: OFF (F)"
end

-- Caught by a black hole, tornado or UFO: flight stops, and can't be switched on until it lets go.
local grabbed = false
local function toggleFly()
	if not flyAllowed or grabbed then
		return
	end
	if flying then
		stopFlying()
	else
		startFlying()
	end
	refreshFlyChip()
end
flyChip.MouseButton1Click:Connect(toggleFly)
task.spawn(function()
	local grabRemote = ReplicatedStorage:WaitForChild("AbuseGrab", 60) :: RemoteEvent?
	if grabRemote then
		grabRemote.OnClientEvent:Connect(function(on: boolean)
			grabbed = on == true
			if grabbed and flying then
				stopFlying()
				refreshFlyChip()
			end
		end)
	end
end)

-- The giant and speed power-ups: a chip that turns the power-up off and on again during the event.
local PERK_NAMES = { giant = "Size perk", speed = "Speed perk" }
local perkToggleRemote: RemoteEvent? = nil
task.spawn(function()
	local AbusePerk = ReplicatedStorage:WaitForChild("AbusePerk", 60) :: RemoteEvent?
	local AbusePerkToggle = ReplicatedStorage:WaitForChild("AbusePerkToggle", 60) :: RemoteEvent?
	perkToggleRemote = AbusePerkToggle
	if AbusePerk then
		AbusePerk.OnClientEvent:Connect(function(kind: string?, on: boolean)
			local name = if kind then PERK_NAMES[kind] else nil
			giantChip.Visible = name ~= nil
			if name then
				giantLabel.Text = if on == true then name .. ": ON (F)" else name .. ": OFF (F)"
			end
		end)
	end
	giantChip.MouseButton1Click:Connect(function()
		if AbusePerkToggle then
			AbusePerkToggle:FireServer()
		end
	end)
end)

AdminSetFlying.OnClientEvent:Connect(function(enabled: boolean)
	flyAllowed = enabled == true
	if flyAllowed then
		startFlying()
	else
		stopFlying()
	end
	refreshFlyChip()
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.F then
		return
	end
	if flyAllowed then
		toggleFly()
	elseif giantChip.Visible and perkToggleRemote then
		perkToggleRemote:FireServer() -- F also switches the size / speed power-up on and off
	end
end)
player.CharacterAdded:Connect(function()
	if flying then
		task.wait(0.5)
		startFlying()
	end
end)

-- The No Clip tool (:noclip): while it's held the character flies and walks through walls; clicking
-- teleports to where the mouse points.
local noClipConn: RBXScriptConnection? = nil
local noClipTool: Tool? = nil
local function stopNoClip()
	if noClipConn then
		noClipConn:Disconnect()
		noClipConn = nil
	end
	noClipTool = nil
	if flying and not flyAllowed then
		stopFlying()
	end
	local character = player.Character
	if character then
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
				part.CanCollide = part.Name == "Head" or part.Name == "Torso" or part.Name == "UpperTorso" or part.Name == "LowerTorso"
			end
		end
	end
end
local function startNoClip(tool: Tool)
	stopNoClip()
	noClipTool = tool
	if not flying then
		startFlying()
	end
	noClipConn = RunService.Stepped:Connect(function()
		local character = player.Character
		if not character then
			return
		end
		for _, part in character:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
			end
		end
	end)
end
local function watchNoClipCharacter(character: Model)
	character.ChildAdded:Connect(function(child)
		if child:IsA("Tool") and child:GetAttribute("NoClipTool") then
			startNoClip(child)
			child.Activated:Connect(function()
				local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
				local camera = workspace.CurrentCamera
				if not root or not camera then
					return
				end
				local mouse = UserInputService:GetMouseLocation()
				local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
				local params = RaycastParams.new()
				params.FilterDescendantsInstances = { character }
				params.FilterType = Enum.RaycastFilterType.Exclude
				local hit = workspace:Raycast(ray.Origin, ray.Direction * 2000, params)
				local point = if hit then hit.Position + Vector3.new(0, 4, 0) else ray.Origin + ray.Direction * 200
				root.CFrame = CFrame.new(point) * root.CFrame.Rotation
			end)
		end
	end)
	character.ChildRemoved:Connect(function(child)
		if child == noClipTool then
			stopNoClip()
		end
	end)
end
if player.Character then
	watchNoClipCharacter(player.Character)
end
player.CharacterAdded:Connect(function(character)
	stopNoClip()
	watchNoClipCharacter(character)
end)

-- Admin Abuse show (for everyone): the countdown in the top right corner, the owner's lines (in chat and in a
-- speech box at the bottom), and the booms that shake the screen. The remotes are waited for in the
-- background, so the admin panel never waits on them.
do
	local abuse = Config.AbuseShow

	-- Countdown / LIVE pill, very top right.
	local _, timerRoot = UIKit.CreateScreen("AbuseTimer", 60)
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.AnchorPoint = Vector2.new(1, 0)
	pill.Size = UDim2.fromOffset(250, 30)
	pill.BackgroundColor3 = Colors.PanelDark
	pill.Visible = false
	UIKit.Corner(pill, 15)
	local pillStroke = UIKit.Stroke(pill, Colors.Coin, 2, 0)
	local pillText = UIKit.Label({ Text = "", TextSize = 16, Size = UDim2.new(1, -16, 1, 0), Position = UDim2.fromOffset(8, 0), Parent = pill })
	pill.Parent = timerRoot
	local function placePill()
		pill.Position = UDim2.new(1, -(8 + UIKit.SafeInsets().Right), 0, 6)
	end
	placePill()
	UIKit.LayoutChanged:Connect(placePill)
	task.spawn(function()
		while true do
			local starts = tonumber(ReplicatedStorage:GetAttribute("AbuseStarts"))
			if not starts then
				for _, e in Config.UpcomingEvents do
					if e.Key == abuse.EventKey then
						starts = e.Starts
					end
				end
			end
			local now = Config.Now()
			if starts then
				local left = starts - now
				if left > 0 and left <= math.max(abuse.PreSeconds, 3600) then
					pill.Visible = true
					pillText.Text = string.format("ADMIN ABUSE IN %d:%02d", left // 60, left % 60)
					pillStroke.Color = if left <= 60 then Colors.Bad else Colors.Coin
				elseif left <= 0 and -left < abuse.ShowSeconds then
					pill.Visible = true
					local petsEnd = ReplicatedStorage:GetAttribute("AbusePetsEnd")
					if type(petsEnd) == "number" and petsEnd > now then
						-- the pet hunt: a countdown on the pill
						pillText.Text = string.format("CATCH THE PETS: %d:%02d", (petsEnd - now) // 60, (petsEnd - now) % 60)
					else
						pillText.Text = if ReplicatedStorage:GetAttribute("AbuseHeat") then "ADMIN ABUSE: MAX HEAT!" else "ADMIN ABUSE IS LIVE!"
					end
					pillStroke.Color = if math.floor(os.clock() * 2) % 2 == 0 then Colors.Bad else Colors.Coin
				else
					pill.Visible = false
				end
			end
			task.wait(0.5)
		end
	end)

	-- Speech box: the owner's name and the line, typed out.
	local _, talkRoot = UIKit.CreateScreen("AbuseTalk", 61)
	local box = Instance.new("Frame")
	box.Name = "Box"
	box.AnchorPoint = Vector2.new(0.5, 0)
	local function placeBox()
		-- top middle: clear of the pill (top right), the chips (under it) and the poll card (bottom); on a narrow
		-- screen the box would run under the pill, so it goes just below it
		local narrow = UIKit.CanvasSize().X < 900
		box.Position = UDim2.new(0.5, 0, 0, if narrow then UIKit.TopInset() + 40 else 6) -- (right at the top edge on a wide screen)
	end
	placeBox()
	UIKit.LayoutChanged:Connect(placeBox)
	box.Size = UDim2.fromOffset(560, 92)
	box.BackgroundColor3 = Colors.PanelDark
	box.Visible = false
	UIKit.Corner(box, 14)
	UIKit.Stroke(box, Colors.Coin, 3, 0)
	UIKit.Label({ Text = abuse.OwnerName, TextSize = 20, TextColor3 = Colors.Coin, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(16, 8), Size = UDim2.new(1, -32, 0, 24), Parent = box })
	local speech = UIKit.Label({ Text = "", TextSize = 19, TextWrapped = true, TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(16, 36), Size = UDim2.new(1, -32, 1, -44), Parent = box })
	box.Parent = talkRoot
	UIKit.PhoneBoost(box, 1.2)
	local talkToken = 0
	local HOLD_SECONDS = 15
	local function speak(text: string, append: boolean?)
		talkToken += 1
		local mine = talkToken
		if append and box.Visible then
			-- (a countdown: "the obby comes down in 5..." then " 4..." " 3...": ONE box that keeps growing, never a new one)
			speech.Text ..= text
			speech.MaxVisibleGraphemes = -1
			task.delay(HOLD_SECONDS, function()
				if talkToken == mine then
					box.Visible = false
				end
			end)
			return
		end
		speech.Text = text
		speech.MaxVisibleGraphemes = 0
		box.Visible = true
		task.spawn(function()
			for i = 1, #text do
				if talkToken ~= mine then
					return
				end
				speech.MaxVisibleGraphemes = i
				task.wait(0.03)
			end
			-- (what he says stays up until his next line comes: at most HOLD_SECONDS, so there is nearly always something there)
			task.wait(HOLD_SECONDS)
			if talkToken == mine then
				box.Visible = false
			end
		end)
	end
	-- {HOLD} in a line becomes what this player presses to hold a prompt: E on a keyboard, X on a gamepad, the button that pops
	-- up next to the thing on a phone.
	local function platformText(text: string): string
		local how = if UIKit.IsGamepad() then "Hold X on" elseif UIKit.IsTouch() then "Hold the button next to" else "Hold E on"
		return (string.gsub(text, "{HOLD}", how))
	end

	-- Screen shake (after the camera script, so it never accumulates) and the opening flash + title.
	local shakeAmp = 0
	local heatPulse: () -> () = function() end
	RunService:BindToRenderStep("AbuseShake", Enum.RenderPriority.Camera.Value + 1, function(dt)
		if shakeAmp > 0.03 then
			local camera = workspace.CurrentCamera
			if camera then
				camera.CFrame = camera.CFrame * CFrame.new((math.random() - 0.5) * shakeAmp, (math.random() - 0.5) * shakeAmp, 0) * CFrame.Angles(0, 0, (math.random() - 0.5) * shakeAmp * 0.03)
			end
			shakeAmp *= math.exp(-dt * 6)
		else
			shakeAmp = 0
		end
	end)
	local _, fxRoot = UIKit.CreateScreen("AbuseFx", 62)
	local flash = Instance.new("Frame")
	flash.Size = UDim2.fromScale(2, 2)
	flash.AnchorPoint = Vector2.new(0.5, 0.5)
	flash.Position = UDim2.fromScale(0.5, 0.5)
	flash.BackgroundColor3 = Color3.fromRGB(255, 244, 214)
	flash.BackgroundTransparency = 1
	flash.Parent = fxRoot
	local title = UIKit.Label({ Text = "ADMIN ABUSE", TextSize = 64, TextColor3 = Colors.Coin, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.42), Size = UDim2.fromOffset(700, 90), Visible = false, Parent = fxRoot })
	local titleStroke = title:FindFirstChildOfClass("UIStroke")
	-- The big title: zooms in, holds, then the text AND its outline fade together (an outline left
	-- on its own looks like hollow letters), and it is hidden for good.
	local titleToken = 0
	local function playTitle(text: string, color: Color3)
		titleToken += 1
		local mine = titleToken
		title.Text = text
		title.TextColor3 = color
		title.Visible = true
		title.TextTransparency = 0
		title.Size = UDim2.fromOffset(1100, 150)
		if titleStroke then
			titleStroke.Transparency = 0
		end
		TweenService:Create(title, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = UDim2.fromOffset(760, 100) }):Play()
		task.delay(2.2, function()
			if titleToken ~= mine then
				return
			end
			TweenService:Create(title, TweenInfo.new(0.8), { TextTransparency = 1 }):Play()
			if titleStroke then
				TweenService:Create(titleStroke, TweenInfo.new(0.8), { Transparency = 1 }):Play()
			end
			task.delay(0.9, function()
				if titleToken == mine then
					title.Visible = false
				end
			end)
		end)
	end
	-- Heat: a red vignette that pulses on every big blast, and a title when it starts.
	local heatFrame = Instance.new("Frame")
	heatFrame.Size = UDim2.fromScale(2, 2)
	heatFrame.AnchorPoint = Vector2.new(0.5, 0.5)
	heatFrame.Position = UDim2.fromScale(0.5, 0.5)
	heatFrame.BackgroundColor3 = Color3.fromRGB(255, 50, 30)
	heatFrame.BackgroundTransparency = 1
	heatFrame.Parent = fxRoot
	heatPulse = function()
		heatFrame.BackgroundTransparency = 0.78
		TweenService:Create(heatFrame, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()
	end
	local lastIntroStart: any = nil
	local function intro()
		-- once per show (not on every big boom)
		local key = ReplicatedStorage:GetAttribute("AbuseStarts") or -1
		if lastIntroStart == key then
			return
		end
		lastIntroStart = key
		flash.BackgroundTransparency = 0.15
		TweenService:Create(flash, TweenInfo.new(0.9), { BackgroundTransparency = 1 }):Play()
		playTitle("ADMIN ABUSE", Colors.Coin)
	end
	ReplicatedStorage:GetAttributeChangedSignal("AbuseHeat"):Connect(function()
		if ReplicatedStorage:GetAttribute("AbuseHeat") then
			heatPulse()
			playTitle("TURN UP THE HEAT", Colors.Bad)
		end
	end)
	-- While the show is live every other window and the whole HUD fade away (nothing in them is usable then
	-- anyway), and come back when it is over. Polls, prizes, the show's own text and the admin panel stay.
	local UI_KEEP = { AbuseTimer = true, AbuseTalk = true, AbuseFx = true, PollUI = true, Celebrate = true, UIKitToasts = true, AdminStatus = true, AdminPanel = true, AbuseOffer = true, StayOffer = true }
	local uiHidden: { [ScreenGui]: boolean } = {}
	local function setLiveUi(live: boolean)
		local pg = player:FindFirstChildOfClass("PlayerGui")
		if not pg then
			return
		end
		if live then
			-- anything open (a shop, pets, a menu...) is closed as the show starts
			for _ = 1, 4 do
				if UIKit.IsWindowOpen() then
					pcall(UIKit.CloseWindow)
				end
			end
			for _, sg in pg:GetChildren() do
				if sg:IsA("ScreenGui") and not UI_KEEP[sg.Name] and sg.Enabled and not uiHidden[sg] then
					uiHidden[sg] = true
					task.spawn(function()
						local recs: { { any } } = {}
						for _, d in sg:GetDescendants() do
							if d:IsA("GuiObject") then
								table.insert(recs, { d, "BackgroundTransparency", d.BackgroundTransparency })
								if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then
									table.insert(recs, { d, "TextTransparency", (d :: any).TextTransparency })
									table.insert(recs, { d, "TextStrokeTransparency", (d :: any).TextStrokeTransparency })
								elseif d:IsA("ImageLabel") or d:IsA("ImageButton") then
									table.insert(recs, { d, "ImageTransparency", (d :: any).ImageTransparency })
								end
							elseif d:IsA("UIStroke") then
								table.insert(recs, { d, "Transparency", d.Transparency })
							end
						end
						local t0 = os.clock()
						while uiHidden[sg] do
							local f = math.min(1, (os.clock() - t0) / 0.9)
							for _, r in recs do
								pcall(function()
									r[1][r[2]] = (r[3] :: number) + (1 - (r[3] :: number)) * f
								end)
							end
							if f >= 1 then
								break
							end
							task.wait()
						end
						if uiHidden[sg] then
							sg.Enabled = false
						end
						for _, r in recs do
							pcall(function()
								r[1][r[2]] = r[3]
							end)
						end
					end)
				end
			end
		else
			for sg in uiHidden do
				uiHidden[sg] = nil
				sg.Enabled = true
			end
		end
	end
	ReplicatedStorage:GetAttributeChangedSignal("AbuseLive"):Connect(function()
		setLiveUi(ReplicatedStorage:GetAttribute("AbuseLive") == true)
	end)
	if ReplicatedStorage:GetAttribute("AbuseLive") == true then
		setLiveUi(true)
	end

	-- The opening shot: the instant the show starts everyone's camera turns, on the spot, to where he is about to appear (the
	-- south end of the room, while the booms shake it), then tracks him as he appears and starts to walk, then turns back to
	-- their own character. The camera never changes place (only turns), so it can't pass through chairs or the table, and it
	-- doesn't wait for him: before he appears it is already looking at the spot. (Only for people who are there at the
	-- start, and never over another camera.)
	local cinemaBusy = false
	local function openingShot()
		local camera = workspace.CurrentCamera
		if cinemaBusy or not camera or camera.CameraType == Enum.CameraType.Scriptable then
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then
			return
		end
		cinemaBusy = true
		local startCF = camera.CFrame
		local startRoot = root.Position
		local PAN, HOLD, BACK = 1.0, 9.0, 1.4 -- seconds: turn to the spot, watch him, turn back
		local ARRIVAL = Vector3.new(0, -130 + 100, 282) -- where he appears (the south end of the room), at about chest height
		local t0 = os.clock()
		local last = t0
		local focus = ARRIVAL -- what the camera looks at now (it eases toward him)
		local backFrom: CFrame? = nil
		local function smooth(x: number): number
			x = math.clamp(x, 0, 1)
			return x * x * (3 - 2 * x)
		end
		local function finish()
			pcall(function()
				RunService:UnbindFromRenderStep("AbuseOpeningShot")
			end)
			camera.CameraType = Enum.CameraType.Custom
			camera.CameraSubject = humanoid
			cinemaBusy = false
		end
		camera.CameraType = Enum.CameraType.Scriptable
		RunService:BindToRenderStep("AbuseOpeningShot", Enum.RenderPriority.Camera.Value, function()
			if not root.Parent or ReplicatedStorage:GetAttribute("AbuseLive") ~= true then
				finish()
				return
			end
			local now = os.clock()
			local dt = now - last
			last = now
			local e = now - t0
			-- the player's own camera, following them if they walk
			local home = startCF + (root.Position - startRoot)
			local g = workspace:FindFirstChild("AbuseGiant")
			local gRoot = g and g:FindFirstChild("HumanoidRootPart") :: BasePart?
			-- (before he appears he is parked far above the room)
			local present = gRoot ~= nil and gRoot.Position.Y < 1500
			local height = if present and g then math.max(80, (g :: Model):GetExtentsSize().Y) else 200
			local wanted = if present and gRoot then gRoot.Position + Vector3.new(0, height * 0.3, 0) else ARRIVAL
			focus = focus:Lerp(wanted, 1 - math.exp(-dt * 4))
			local shot = CFrame.lookAt(home.Position, focus)
			if e < PAN then
				camera.CFrame = home:Lerp(shot, smooth(e / PAN))
			elseif e < PAN + HOLD and (present or e < PAN + 6) then
				camera.CFrame = shot
				backFrom = shot
			else
				if not backFrom then
					backFrom = shot
					t0 = now - (PAN + HOLD) -- (he never showed up: just turn back)
					e = PAN + HOLD
				end
				local a = (e - PAN - HOLD) / BACK
				if a >= 1 then
					finish()
					return
				end
				camera.CFrame = (backFrom :: CFrame):Lerp(home, smooth(a))
			end
		end)
	end
	-- The obby builds itself in about 9 seconds ("now. im going to build something."): every camera turns, on the spot (it never
	-- moves, so it cannot clip), to the start of the course, then sweeps along it with the pieces as they rise, then turns back.
	local function buildShot()
		local camera = workspace.CurrentCamera
		if cinemaBusy or not camera or camera.CameraType == Enum.CameraType.Scriptable or ReplicatedStorage:GetAttribute("AbuseLive") ~= true then
			return
		end
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then
			return
		end
		cinemaBusy = true
		local obby: Instance? = nil
		for _ = 1, 25 do
			local lobby = workspace:FindFirstChild("Lobby")
			obby = lobby and lobby:FindFirstChild("Obby")
			if obby then
				break
			end
			task.wait(0.1)
		end
		local points: { Vector3 } = {}
		if obby then
			-- (the pieces start 45 studs below where they end up, and rise one after another from the start)
			for _, name in { "Start", "Hop4", "Checkpoint1", "SideSlider3", "Checkpoint2", "SpinnerDeck", "Checkpoint3", "Slider2", "Checkpoint4", "Conveyor", "Checkpoint5", "Finish" } do
				local part = obby:FindFirstChild(name)
				if part and part:IsA("BasePart") then
					table.insert(points, part.Position + Vector3.new(0, if part.Transparency >= 0.5 then 49 else 4, 0))
				end
			end
		end
		if #points < 2 then
			cinemaBusy = false
			return
		end
		local startCF = camera.CFrame
		local startRoot = root.Position
		local PAN, FOLLOW, BACK = 1.0, 4.4, 1.2
		local t0, last = os.clock(), os.clock()
		local focus = points[1]
		local function smooth(x: number): number
			x = math.clamp(x, 0, 1)
			return x * x * (3 - 2 * x)
		end
		-- a point `f` (0..1) of the way along the course
		local total = 0
		for i = 2, #points do
			total += (points[i] - points[i - 1]).Magnitude
		end
		local function along(f: number): Vector3
			local want = f * total
			for i = 2, #points do
				local seg = (points[i] - points[i - 1]).Magnitude
				if want <= seg or i == #points then
					return points[i - 1]:Lerp(points[i], if seg > 0 then math.clamp(want / seg, 0, 1) else 0)
				end
				want -= seg
			end
			return points[#points]
		end
		local function finish()
			pcall(function()
				RunService:UnbindFromRenderStep("AbuseBuildShot")
			end)
			camera.CameraType = Enum.CameraType.Custom
			camera.CameraSubject = humanoid
			cinemaBusy = false
		end
		camera.CameraType = Enum.CameraType.Scriptable
		RunService:BindToRenderStep("AbuseBuildShot", Enum.RenderPriority.Camera.Value, function()
			if not root.Parent or ReplicatedStorage:GetAttribute("AbuseLive") ~= true then
				finish()
				return
			end
			local now = os.clock()
			local dt = now - last
			last = now
			local e = now - t0
			local home = startCF + (root.Position - startRoot)
			local wanted = if e < PAN then points[1] else along(smooth((e - PAN) / FOLLOW))
			focus = focus:Lerp(wanted, 1 - math.exp(-dt * 5))
			local shot = CFrame.lookAt(home.Position, focus)
			if e < PAN then
				camera.CFrame = home:Lerp(shot, smooth(e / PAN))
			elseif e < PAN + FOLLOW then
				camera.CFrame = shot
			else
				local a = (e - PAN - FOLLOW) / BACK
				if a >= 1 then
					finish()
					return
				end
				camera.CFrame = shot:Lerp(home, smooth(a))
			end
		end)
	end
	ReplicatedStorage:GetAttributeChangedSignal("AbuseObbyBuild"):Connect(function()
		task.spawn(buildShot)
	end)
	ReplicatedStorage:GetAttributeChangedSignal("AbuseLive"):Connect(function()
		if ReplicatedStorage:GetAttribute("AbuseLive") == true then
			local starts = tonumber(ReplicatedStorage:GetAttribute("AbuseStarts"))
			if starts and Config.Now() - starts <= 12 then
				task.spawn(openingShot)
			end
		end
	end)
	-- Joining while the event is on (or within the hour before it): say so, so people stay.
	task.spawn(function()
		task.wait(7)
		local starts = tonumber(ReplicatedStorage:GetAttribute("AbuseStarts"))
		if not starts then
			return
		end
		local now = Config.Now()
		if ReplicatedStorage:GetAttribute("AbuseLive") == true then
			if now - starts > 15 then
				UIKit.Toast("Admin Abuse is LIVE! Stay in the game for free game passes, gems and limited pets.", "Good")
			end
		elseif starts - now > 0 and starts - now <= 3600 then
			local mins = math.ceil((starts - now) / 60)
			UIKit.Toast(string.format("Admin Abuse starts in %d minute%s. Stay tuned for free game passes, ranks and giveaways!", mins, if mins == 1 then "" else "s"), "Info")
		end
	end)
	-- The power-up pick: everyone gets a card (same look as the vote card) with 3 power-ups and "No thanks".
	task.spawn(function()
		local offer = ReplicatedStorage:WaitForChild("AbuseOffer", 120) :: RemoteEvent?
		local reply = ReplicatedStorage:WaitForChild("AbuseOfferReply", 120) :: RemoteEvent?
		if not offer or not reply then
			return
		end
		local _gui, root = UIKit.CreateScreen("AbuseOffer", 9)
		local holder = Instance.new("Frame")
		holder.Name = "PickHolder"
		holder.AnchorPoint = Vector2.new(0.5, 1)
		holder.Position = UDim2.new(0.5, 0, 1, -110)
		holder.Size = UDim2.fromOffset(480, 200)
		holder.BackgroundTransparency = 1
		holder.Visible = false
		holder.Parent = root
		UIKit.PhoneBoost(holder)
		local card = UIKit.Card({
			Name = "Pick",
			Position = UDim2.fromOffset(4, 2),
			Size = UDim2.new(1, -8, 1, -6),
			Color = Colors.PanelDark,
			Parent = holder,
		})
		UIKit.Stroke(card, Colors.Primary, 3, 0)
		UIKit.Label({ Text = "POWER-UP", Font = UIKit.Theme.Fonts.Title, TextSize = 16, TextScaled = true, TextColor3 = Colors.Primary, Position = UDim2.fromOffset(14, 6), Size = UDim2.new(1, -230, 0, 20), TextXAlignment = Enum.TextXAlignment.Left, Parent = card })
		local timerLabel = UIKit.Label({ Text = "", Font = UIKit.Theme.Fonts.Title, TextSize = 16, TextColor3 = Colors.TextDim, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 6), Size = UDim2.fromOffset(150, 20), TextXAlignment = Enum.TextXAlignment.Right, Parent = card })
		UIKit.Label({ Text = "Pick one power-up for the rest of the event", TextSize = 20, TextWrapped = true, TextScaled = true, Position = UDim2.fromOffset(14, 30), Size = UDim2.new(1, -28, 0, 44), Parent = card })
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Position = UDim2.fromOffset(14, 82)
		row.Size = UDim2.new(1, -28, 0, 70)
		row.Parent = card
		local layout = Instance.new("UIGridLayout")
		layout.CellPadding = UDim2.fromOffset(8, 8)
		layout.CellSize = UDim2.new(1 / 3, -6, 0, 70)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = row
		local currentId, ends = 0, 0
		local function answer(choice: string?)
			if currentId ~= 0 then
				reply:FireServer(currentId, choice)
			end
			currentId = 0
			holder.Visible = false
		end
		for i, choice in { { "fly", "Fly perk" }, { "giant", "Size perk" }, { "speed", "Speed perk" } } do
			UIKit.Button({
				Text = choice[2],
				Color = Colors.PanelLight,
				TextSize = 18,
				LayoutOrder = i,
				Parent = row,
				OnClick = function()
					answer(choice[1])
				end,
			})
		end
		UIKit.Button({
			Text = "No thanks",
			Color = Colors.PanelLight,
			TextSize = 15,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Size = UDim2.fromOffset(150, 28),
			Parent = card,
			OnClick = function()
				answer(nil)
			end,
		})
		offer.OnClientEvent:Connect(function(id: any, seconds: any)
			if type(id) ~= "number" or type(seconds) ~= "number" then
				return
			end
			if seconds <= 0 then
				currentId = 0
				holder.Visible = false
				return
			end
			currentId = id
			ends = os.clock() + seconds
			holder.Visible = true
			UIKit.Bounce(card)
			task.spawn(function()
				while holder.Visible and currentId == id do
					local left = math.max(0, math.ceil(ends - os.clock()))
					timerLabel.Text = string.format("%d s left", left)
					if left <= 0 then
						currentId = 0
						holder.Visible = false
						break
					end
					task.wait(0.25)
				end
			end)
		end)
	end)
	task.spawn(function()
		local say = ReplicatedStorage:WaitForChild("AbuseSay", 120)
		if say then
			say.OnClientEvent:Connect(function(name: any, text: any, append: any)
				if type(name) ~= "string" or type(text) ~= "string" then
					return
				end
				text = platformText(text)
				speak(text, append == true)
				pcall(function()
					if append == true then
						return -- (the 5, 4, 3, 2, 1 only go in the speech box, not into chat)
					end
					local channel = TextChatService:FindFirstChild("TextChannels") and TextChatService.TextChannels:FindFirstChild("RBXGeneral")
					if channel then
						local safe = string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")
						;(channel :: any):DisplaySystemMessage(string.format('<font color="#FFD54A"><b>[Owner] %s:</b></font> %s', name, safe))
					end
				end)
			end)
		end
	end)
	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild("AbuseBoom", 120)
		if remote then
			remote.OnClientEvent:Connect(function(strength: any, pos: any)
				if type(strength) ~= "number" then
					return
				end
				local camera = workspace.CurrentCamera
				local distance = if camera and typeof(pos) == "Vector3" then (camera.CFrame.Position - pos).Magnitude else 300
				local near = math.clamp(1.15 - distance / 1100, 0.2, 1)
				local heatMult = if ReplicatedStorage:GetAttribute("AbuseHeat") then 1.5 else 1
				shakeAmp = math.max(shakeAmp, strength * 1.1 * near * heatMult)
				if heatMult > 1 and strength >= 1.5 then
					heatPulse()
				end
				if strength >= 3 then
					intro()
				end
			end)
		end
	end)
end

-- Full-screen cover that hides teleports (jail, spectate, control).
local cover = Instance.new("Frame")
cover.Name = "TeleportCover"
cover.Size = UDim2.fromScale(1, 1)
cover.BackgroundColor3 = Colors.PanelDark
cover.BackgroundTransparency = 1
cover.BorderSizePixel = 0
cover.ZIndex = 60
cover.Visible = false
cover.Parent = statusRoot
local coverToken = 0
local function coverScreen()
	coverToken += 1
	cover.Visible = true
	local tween = TweenService:Create(cover, TweenInfo.new(0.2), { BackgroundTransparency = 0 })
	tween:Play()
	task.wait(0.22)
end
local function revealScreen()
	coverToken += 1
	local token = coverToken
	local tween = TweenService:Create(cover, TweenInfo.new(0.3), { BackgroundTransparency = 1 })
	tween:Play()
	task.delay(0.32, function()
		if token == coverToken then
			cover.Visible = false
		end
	end)
end
-- Covers now and uncovers by itself after `timeout` if nothing else does.
local function coverFor(timeout: number)
	task.spawn(function()
		coverScreen()
		local token = coverToken
		task.wait(timeout)
		if token == coverToken then
			revealScreen()
		end
	end)
end
AdminScreenFade.OnClientEvent:Connect(function()
	task.spawn(function()
		coverScreen()
		task.wait(0.5)
		revealScreen()
	end)
end)

----------------------------------------------------------------------------------------------------
-- Owner panel
----------------------------------------------------------------------------------------------------

-- Every command the panel knows, grouped. Only the ones the server lists for you are shown.
--   Target: "player" (the picked player), "none", or "text" (typed into the first box).
--   Inputs: what goes after the name, in order: { Kind = "text"|"number"|"duration"|"choice", ... }
type Input = { Kind: string, Placeholder: string?, Required: boolean?, Options: (() -> { { Label: string, Value: string } })? }
type Command = { Name: string, Icon: string, Label: string, Desc: string, Group: string, Target: string, Inputs: { Input }?, Danger: boolean? }

local function opts(list: { string }): () -> { { Label: string, Value: string } }
	return function()
		local out = {}
		for _, v in list do
			table.insert(out, { Label = v, Value = v })
		end
		return out
	end
end


local REASON: Input = { Kind = "text", Placeholder = "Reason (optional)" }
local DURATION: Input = { Kind = "duration" }

local COMMANDS: { Command } = ({
	-- Punish
	{ Name = "kick", Icon = "👢", Label = "Kick", Desc = "Removes them from the server.", Group = "Punish", Target = "player", Inputs = { REASON }, Danger = true },
	{ Name = "ban", Icon = "🔨", Label = "Ban", Desc = "Bans them for good (undo it from the Ban list).", Group = "Punish", Target = "player", Inputs = { REASON }, Danger = true },
	{ Name = "tempban", Icon = "⏳", Label = "Temp ban", Desc = "Bans them for a set time.", Group = "Punish", Target = "player", Inputs = { DURATION, REASON }, Danger = true },
	{ Name = "mute", Icon = "🔇", Label = "Mute / unmute", Desc = "Stops their chat messages. Run it again to unmute.", Group = "Punish", Target = "player", Inputs = { REASON } },
	{ Name = "tempmute", Icon = "⏱️", Label = "Temp mute", Desc = "Mutes them for a set time.", Group = "Punish", Target = "player", Inputs = { DURATION, REASON } },
	{ Name = "warn", Icon = "⚠️", Label = "Warn", Desc = "Gives them a warning they have to read.", Group = "Punish", Target = "player", Inputs = { { Kind = "text", Placeholder = "Reason", Required = true } } },
	{ Name = "banlist", Icon = "📋", Label = "Ban list", Desc = "Everyone banned. Modify or unban from here.", Group = "Punish", Target = "none" },
	{ Name = "mutelist", Icon = "📋", Label = "Mute list", Desc = "Everyone muted. Modify or unmute from here.", Group = "Punish", Target = "none" },
	{ Name = "warnlist", Icon = "📋", Label = "Warn list", Desc = "Everyone with warnings.", Group = "Punish", Target = "none" },
	-- Control
	{ Name = "freeze", Icon = "🧊", Label = "Freeze / unfreeze", Desc = "Stops them moving. Run it again to thaw.", Group = "Control", Target = "player" },
	{ Name = "unfreeze", Icon = "🔥", Label = "Unfreeze", Desc = "Lets them move again.", Group = "Control", Target = "player" },
	{ Name = "kill", Icon = "💀", Label = "Kill", Desc = "Resets their character.", Group = "Control", Target = "player" },
	{ Name = "respawn", Icon = "🔄", Label = "Respawn", Desc = "Respawns them where they were.", Group = "Control", Target = "player" },
	{ Name = "jail", Icon = "🚔", Label = "Jail / free", Desc = "Locks them in the jail. Run it again to let them out.", Group = "Control", Target = "player" },
	{ Name = "god", Icon = "✨", Label = "God mode", Desc = "Can't be hurt. Run it again to turn off.", Group = "Control", Target = "player" },
	{ Name = "invis", Icon = "👻", Label = "Invisible", Desc = "Hides their character and name tag. Toggles.", Group = "Control", Target = "player" },
	{ Name = "fly", Icon = "🕊️", Label = "Fly", Desc = "Lets them fly (F to take off / land). Toggles.", Group = "Control", Target = "player" },
	{ Name = "noclip", Icon = "🚪", Label = "No Clip tool", Desc = "Gives (or takes back) a tool: hold it to fly through walls, click to teleport.", Group = "Control", Target = "player" },
	{ Name = "giant", Icon = "🗿", Label = "Giant", Desc = "Makes them huge (or back to normal). Toggles.", Group = "Control", Target = "player", Inputs = { { Kind = "number", Placeholder = "Size 2-30 (8)" } } },
	{ Name = "msg", Icon = "💬", Label = "Message", Desc = "Pops a message up on their screen.", Group = "Control", Target = "player", Inputs = { { Kind = "text", Placeholder = "Message", Required = true } } },
	-- Move
	{ Name = "goto", Icon = "➡️", Label = "Go to", Desc = "Teleports you to them.", Group = "Move", Target = "player" },
	{ Name = "bring", Icon = "⬅️", Label = "Bring", Desc = "Teleports them to you.", Group = "Move", Target = "player" },
	{ Name = "spectate", Icon = "👁️", Label = "Spectate", Desc = "Watch them. Stop from the bar at the bottom.", Group = "Move", Target = "player" },
	{ Name = "controlplayer", Icon = "🎮", Label = "Control", Desc = "Move their character with your controls.", Group = "Move", Target = "player" },
	{ Name = "serverlist", Icon = "🌍", Label = "All servers", Desc = "Every server of the game, sorted: Lobby 1, Lobby 2...; and game servers by level (Level 1 / Chapter 1, Level 2 / Chapter 2, Level 3 / Chapter 3) with who is in each and how long it has been up. Use the arrows to filter: All, Lobbies only, Game servers only, or one level. Join any of them (you arrive invisible).", Group = "Global", Target = "none" },
	{ Name = "badges", Icon = "🏅", Label = "Badges", Desc = "Checks all ten Roblox badges for that player against Roblox itself: earned? really owned? is the badge switched on? Anything they earned but don't have is given on the spot, or the reason it can't be is shown.", Group = "Game", Target = "player" },
	{ Name = "analytics", Icon = "📈", Label = "Analytics", Desc = "Where players get stuck and leave. Pick a report (what new players do step by step, retention, where they were when they left, runs, features, money, devices and errors, the Admin Abuse show) and how many days back. The arrows flip between reports. Needs the game published for real numbers.", Group = "Global", Target = "none", Inputs = { { Kind = "choice", Required = true, Options = function()
	return {
		{ Label = "Overview", Value = "1" },
		{ Label = "What new players do (funnel)", Value = "2" },
		{ Label = "Retention", Value = "3" },
		{ Label = "Where players leave", Value = "4" },
		{ Label = "Runs", Value = "5" },
		{ Label = "Features used", Value = "6" },
		{ Label = "Economy", Value = "7" },
		{ Label = "Devices and errors", Value = "8" },
		{ Label = "Admin Abuse show", Value = "9" },
	}
end }, { Kind = "choice", Required = true, Options = function()
	return { { Label = "Last 7 days", Value = "7" }, { Label = "Today", Value = "1" }, { Label = "Last 3 days", Value = "3" }, { Label = "Last 14 days", Value = "14" }, { Label = "Last 30 days", Value = "30" } }
end } } },
	{ Name = "joinserver", Icon = "🛰️", Label = "Join server", Desc = "Teleport to that player's server, wherever they are (type their username).", Group = "Global", Target = "text", Inputs = { { Kind = "text", Placeholder = "Username", Required = true } } },
	{ Name = "bringserver", Icon = "🧲", Label = "Bring (any server)", Desc = "Pull that player from their server into yours (type their username).", Group = "Global", Target = "text", Inputs = { { Kind = "text", Placeholder = "Username", Required = true } } },
	{ Name = "viewpets", Icon = "🐾", Label = "Pets", Desc = "See their pets. Remove any, or add new ones.", Group = "Game", Target = "player" },
	-- Game
	{ Name = "givecoins", Icon = "💰", Label = "Give coins", Desc = "Coins for their current run.", Group = "Game", Target = "player", Inputs = { { Kind = "number", Placeholder = "Amount", Required = true } } },
	{ Name = "setbubbles", Icon = "🧼", Label = "Set bubbles", Desc = "Sets their Bubbles to an amount.", Group = "Game", Target = "player", Inputs = { { Kind = "number", Placeholder = "Amount", Required = true } } },
	{ Name = "setgems", Icon = "💎", Label = "Set gems", Desc = "Sets their Gems to an amount.", Group = "Game", Target = "player", Inputs = { { Kind = "number", Placeholder = "Amount", Required = true } } },
	{ Name = "givepet", Icon = "🐾", Label = "Give pet", Desc = "Adds a pet to their pets.", Group = "Game", Target = "player", Inputs = {
		{ Kind = "choice", Required = true, Options = function()
			local out = {}
			for _, def in Config.Pets do
				table.insert(out, { Label = def.Name, Value = def.Name })
			end
			table.sort(out, function(a, b)
				return a.Label < b.Label
			end)
			return out
		end },
		{ Kind = "choice", Options = function()
			return { { Label = "Normal", Value = "" }, { Label = "Golden", Value = "golden" }, { Label = "Rainbow", Value = "rainbow" } }
		end },
	} },
	{ Name = "setrebirths", Icon = "🌀", Label = "Set rebirths", Desc = "Sets how many times they've rebirthed.", Group = "Game", Target = "player", Inputs = { { Kind = "number", Placeholder = "Rebirths", Required = true } } },
	{ Name = "unlockall", Icon = "🔓", Label = "Unlock levels", Desc = "Unlocks every level for them.", Group = "Game", Target = "player" },
	{ Name = "finishrun", Icon = "🏁", Label = "Finish run", Desc = "Cleans every dish in their current run.", Group = "Game", Target = "player" },
	{ Name = "daily", Icon = "📅", Label = "Daily streak", Desc = "Check or change their daily reward streak.", Group = "Game", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = function()
		local out = {
			{ Label = "Show", Value = "show" },
			{ Label = "Ready now", Value = "skip" },
			{ Label = "Break streak", Value = "break" },
			{ Label = "Reset", Value = "reset" },
		}
		for day = 1, #Config.DailyRewards do
			table.insert(out, { Label = "Day " .. day, Value = "day " .. day })
		end
		return out
	end } } },
	{ Name = "setrank", Icon = "🎖️", Label = "Set rank", Desc = "Gives them a rank and equips it.", Group = "Game", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = function()
		local out = {}
		for _, rank in Config.Ranks do
			table.insert(out, { Label = rank.Icon .. " " .. rank.Name, Value = rank.Name })
		end
		return out
	end } } },
	{ Name = "promote", Icon = "⬆️", Label = "Promote", Desc = "Next rarer rank.", Group = "Game", Target = "player" },
	{ Name = "demote", Icon = "⬇️", Label = "Demote", Desc = "Next more common rank.", Group = "Game", Target = "player" },
	-- Server
	{ Name = "announce", Icon = "📢", Label = "Announce", Desc = "A banner on everyone's screen.", Group = "Server", Target = "none", Inputs = { { Kind = "text", Placeholder = "Announcement", Required = true } } },
	{ Name = "globalannounce", Icon = "🌍", Label = "Global announce", Desc = "A banner on everyone's screen in EVERY server of the game.", Group = "Global", Target = "none", Inputs = { { Kind = "text", Placeholder = "Announcement", Required = true } } },
	{ Name = "leaderboards", Icon = "🏆", Label = "Leaderboards", Desc = "See everyone on every leaderboard; reset someone's spot (they keep their stats).", Group = "Server", Target = "none" },
	{ Name = "givegamepass", Icon = "🎟️", Label = "Gift pass", Desc = "Gives them a game pass for free (saved).", Group = "Server", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = function()
		local out = {}
		for _, pass in Config.GamePasses do
			table.insert(out, { Label = pass.Icon .. " " .. pass.Name, Value = pass.Key })
		end
		return out
	end } } },
	{ Name = "removegamepass", Icon = "✂️", Label = "Remove pass", Desc = "Takes back a gifted pass.", Group = "Server", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = function()
		local out = {}
		for _, pass in Config.GamePasses do
			table.insert(out, { Label = pass.Icon .. " " .. pass.Name, Value = pass.Key })
		end
		return out
	end } } },
	{ Name = "cmdlogs", Icon = "📜", Label = "Command log", Desc = "Every admin command used.", Group = "Server", Target = "none" },
	{ Name = "playerlogs", Icon = "🔎", Label = "Logs by admin", Desc = "Commands used by one admin (type their username).", Group = "Server", Target = "text", Inputs = { { Kind = "text", Placeholder = "Admin username", Required = true } } },
	{ Name = "wipelogs", Icon = "🧹", Label = "Wipe logs", Desc = "Deletes the whole command log.", Group = "Server", Target = "none", Danger = true },
	{ Name = "setadminrank", Icon = "🛡️", Label = "Staff tier", Desc = "Make them Moderator, Admin or Developer (saved, works straight away), or clear it.", Group = "Server", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = opts({ "Moderator", "Admin", "Developer", "clear" }) } } },
	{ Name = "stafflist", Icon = "📋", Label = "Staff list", Desc = "Everyone with a staff rank, online or not. Remove anyone.", Group = "Server", Target = "none" },
	{ Name = "globalpoll", Icon = "📊", Label = "Poll", Desc = "A poll in EVERY server. Type: Question | answer | answer (2 to 4 answers). When it ends, everyone's poll card shows the results.", Group = "Global", Target = "none", Inputs = { { Kind = "choice", Required = true, Options = function()
		return { { Label = "30 seconds", Value = "30" }, { Label = "1 minute", Value = "60" }, { Label = "2 minutes", Value = "120" } }
	end }, { Kind = "text", Placeholder = "Which level next? | Pizzeria | Castle", Required = true } } },
	{ Name = "globalgive", Icon = "🎁", Label = "Give everyone", Desc = "Everyone online in EVERY server gets this much (Coins only reach people inside a dishwasher).", Group = "Global", Target = "none", Inputs = { { Kind = "choice", Required = true, Options = opts({ "Bubbles", "Gems", "Coins" }) }, { Kind = "number", Placeholder = "Amount", Required = true } } },
	{ Name = "globalpassdrop", Icon = "🎟️", Label = "Pass drop", Desc = "Random players from EVERY server win a game pass. Type HOW MANY players win (a number from 1 to 25), then pick what they win: 'Random pass each' gives every winner a different random pass, or pick one pass and every winner gets that same pass. Winners get a congratulations pop-up with confetti. Anyone who already owns the pass gets 100 Gems instead.", Group = "Global", Target = "none", Inputs = { { Kind = "number", Placeholder = "How many players win? (type 1 to 25)", Required = true }, { Kind = "choice", Required = true, Options = function()
		local out = { { Label = "Random pass each", Value = "random" } }
		for _, pass in Config.GamePasses do
			table.insert(out, { Label = pass.Name, Value = pass.Key })
		end
		return out
	end } } },
	{ Name = "globalcountdown", Icon = "⏳", Label = "Event countdown", Desc = "A countdown on everyone's screen in EVERY server (and for anyone who joins later), then LIVE NOW for an hour. Pick the time, then type a name if you want one on it; leave the name blank for just a countdown timer with no name.", Group = "Global", Target = "none", Inputs = { { Kind = "choice", Required = true, Options = opts({ "1h", "6h", "12h", "24h", "48h", "3d", "7d" }) }, { Kind = "text", Placeholder = "Name (optional: blank = just the timer)" } } },
	{ Name = "notifytest", Icon = "🔔", Label = "Notification test", Desc = "Sends the \"daily reward is ready\" notification to you right now and says how it went: is the key found, is HTTP on, are you opted in.", Group = "Studio", Target = "none" },
	{ Name = "abusefx", Icon = "💥", Label = "Test Admin Abuse effects", Desc = "Tries one piece of the Admin Abuse show on its own (it spawns the giant first): each effect, the table holes, the obby, the heat, the exit. 'Every effect' plays them all, 9 seconds apart.", Group = "Studio", Target = "none", Inputs = { { Kind = "choice", Required = true, Options = function()
		local list = {}
		for _, name in { "all", "beam", "meteors", "lightning", "shockwave", "barrage", "fireworks", "laser", "blackhole", "tornado", "ufo", "disco", "fountains", "eyes", "fireballs", "dishwasher", "bombs", "chairshow", "nuke", "petchase", "hole1", "hole2", "heal", "obby", "obbybreak", "heat", "calm", "leave", "off" } do
			local label = if name == "all" then "Every effect, one after another" elseif name == "off" then "Put everything away" elseif name == "heal" then "Close the table holes" elseif name == "hole1" then "Table hole 1" elseif name == "hole2" then "Table hole 2" elseif name == "obby" then "Build the obby" elseif name == "obbybreak" then "Smash the obby" elseif name == "heat" then "Turn up the heat" elseif name == "calm" then "Cool down" elseif name == "leave" then "The exit through the roof" else name
			table.insert(list, { Label = label, Value = name })
		end
		return list
	end } } },
	{ Name = "resetfirstrun", Icon = "🆕", Label = "Reset my first run", Desc = "Puts your account back to a brand-new player's: the tutorial is not done, your run count is 0 and the level 1 cutscene is unseen, so the next run you start shows the tutorial and the cutscene again. Your Bubbles, pets and everything else stay.", Group = "Studio", Target = "none", Inputs = {} },
	{ Name = "clubreset", Icon = "🏷", Label = "Reset my club waiting times", Desc = "Clears the 24 hour wait after leaving a club and any 24 hour kick bans on your account (and a waiting \"you were kicked\" message), so you can test joining, leaving and being kicked straight away.", Group = "Studio", Target = "none", Inputs = {} },
	{ Name = "abusedebug", Icon = "🐞", Label = "Giant debug readout", Desc = "Toggles a floating readout above the Admin Abuse giant (state, height, floor, feet) and prints it to the Output once a second. Use it to see where he sinks or stops.", Group = "Studio", Target = "none", Inputs = {} },
	{ Name = "abuseshow", Icon = "🎆", Label = "Global Admin Abuse event test", Desc = "Starts the whole Admin Abuse show in EVERY server (what everyone would see): rounds pause, a giant, chat lines, votes and prizes. Pick when it starts, or put the real time back.", Group = "Studio", Target = "none", Inputs = { { Kind = "choice", Required = true, Options = function()
		return {
			{ Label = "Start in 15 seconds", Value = "0.25" },
			{ Label = "Start in 1 minute", Value = "1" },
			{ Label = "Start in 5 minutes", Value = "5" },
			{ Label = "Start in 20 minutes", Value = "20" },
			{ Label = "Start in 30 minutes", Value = "30" },
			{ Label = "Back to the real time", Value = "reset" },
		}
	end } } },
	{ Name = "abuselocal", Icon = "🧪", Label = "Local Admin Abuse event test", Desc = "Runs the whole Admin Abuse show in THIS server only (nothing is sent to other servers): the same show, to test it in the real game. Works in the published game too. Pick when it starts, or put the real time back.", Group = "Studio", Target = "none", Inputs = { { Kind = "choice", Required = true, Options = function()
		return {
			{ Label = "Start in 15 seconds", Value = "0.25" },
			{ Label = "Start in 1 minute", Value = "1" },
			{ Label = "Start in 5 minutes", Value = "5" },
			{ Label = "Start in 20 minutes", Value = "20" },
			{ Label = "Start in 30 minutes", Value = "30" },
			{ Label = "Back to the real time", Value = "reset" },
		}
	end } } },
	{ Name = "privatelobby", Icon = "🔒", Label = "Private lobby", Desc = "Takes you to a lobby only you can join (a private server of this game that nobody else can reach, not even friends). Combine it with the Local Admin Abuse event test to try the show in the real game. Only works in the published game.", Group = "Studio", Target = "none", Inputs = { { Kind = "choice", Required = true, Options = function()
		return {
			{ Label = "Take me to my private lobby", Value = "join" },
			{ Label = "Make a fresh private lobby", Value = "new" },
		}
	end } } },
	{ Name = "cancelcountdown", Icon = "🛑", Label = "Cancel countdown", Desc = "Removes the event countdown from everyone's screen, in every server.", Group = "Global", Target = "none", Danger = true },
	{ Name = "globalboost", Icon = "⚡", Label = "x2 boost", Desc = "x2 Cleaning for everyone online in EVERY server, for this many minutes.", Group = "Global", Target = "none", Inputs = { { Kind = "number", Placeholder = "How many minutes? (type 1 to 180)", Required = true } } },
}) :: any
local GROUPS = {
	{ Name = "Punish", Icon = "🔨" },
	{ Name = "Control", Icon = "🧊" },
	{ Name = "Move", Icon = "🧭" },
	{ Name = "Game", Icon = "🧼" },
	{ Name = "Server", Icon = "📢" },
	{ Name = "Global", Icon = "🌍" },
	{ Name = "Studio", Icon = "🧪" },
}
local DURATIONS = { "1h", "6h", "24h", "3d", "7d", "30d" }
local PRESETS = {
	{ Label = "1 hour", Seconds = 3600 },
	{ Label = "24 hours", Seconds = 86400 },
	{ Label = "7 days", Seconds = 7 * 86400 },
	{ Label = "30 days", Seconds = 30 * 86400 },
	{ Label = "Permanent", Seconds = nil },
}

local panelBuilt = false
local allowed: { [string]: boolean } = {}
local canRemoveLogs = false

local function buildPanel(info: any)
	if type(info) ~= "table" then
		return
	end
	local HUD = require(Client:WaitForChild("HUD")) :: any
	if not info.Tier then
		-- Not staff (any more): the panel and its button go away straight away.
		table.clear(allowed)
		if panelBuilt then
			if UIKit.IsWindowOpen("Admin") then
				UIKit.CloseWindow("Admin")
			end
			HUD.SetAdminButtonVisible(false)
		end
		return
	end
	allowed = {}
	for _, name in info.Commands or {} do
		allowed[string.lower(tostring(name))] = true
	end
	canRemoveLogs = info.CanRemoveLogs == true
	if panelBuilt then
		-- Already built (a new or changed rank): the button comes back and the commands are the
		-- new rank's the next time the window opens.
		HUD.SetAdminButtonVisible(true)
		if UIKit.IsWindowOpen("Admin") then
			UIKit.CloseWindow("Admin")
			UIKit.OpenWindow("Admin")
		end
		return
	end
	panelBuilt = true

	local _gui, panelRoot = UIKit.CreateScreen("AdminPanel", 12)
	local window, content = UIKit.Window({
		Name = "Admin",
		Title = "Admin",
		Icon = "🛡️",
		Size = Vector2.new(1000, 620),
		Parent = panelRoot,
	})

	-- The HUD button first, so it's there even if anything below goes wrong.
	HUD.AddAdminButton(function()
		UIKit.ToggleWindow("Admin")
	end)

	local selectedPlayer: Player? = nil
	local selectedGroup = GROUPS[1].Name
	local selectedCommand: Command? = nil

	------------------------------------------------------------------ players (left)
	local left = UIKit.Card({ Size = UDim2.new(0, 250, 1, -64), Color = Colors.PanelDark, Parent = content })
	left.Name = "Players"
	UIKit.Label({ Text = "PLAYERS", TextSize = 20, Size = UDim2.new(1, 0, 0, 30), Position = UDim2.fromOffset(0, 8), Parent = left })
	local search = field(left, UDim2.new(1, -20, 0, 38), UDim2.fromOffset(10, 42), "🔍 Search")
	local playerList = scroller(left, UDim2.new(1, -12, 1, -94), UDim2.fromOffset(6, 88))
	listLayout(playerList, 6)
	local playerRows: { [Player]: TextButton } = {}

	local formTitle: TextLabel
	local refreshForm: () -> ()

	local function paintRows()
		for plr, row in playerRows do
			row.BackgroundColor3 = if plr == selectedPlayer then Colors.Primary else Colors.PanelLight
		end
	end

	local function refreshPlayers()
		clear(playerList)
		table.clear(playerRows)
		local filter = string.lower(search.Text)
		local list = Players:GetPlayers()
		table.sort(list, function(a, b)
			return a.Name:lower() < b.Name:lower()
		end)
		if selectedPlayer and selectedPlayer.Parent ~= Players then
			selectedPlayer = nil
		end
		for i, plr in list do
			if filter ~= "" and not (plr.Name:lower():find(filter, 1, true) or plr.DisplayName:lower():find(filter, 1, true)) then
				continue
			end
			local row = Instance.new("TextButton")
			row.Name = plr.Name
			row.AutoButtonColor = true
			row.Text = ""
			row.Size = UDim2.new(1, -8, 0, 56)
			row.LayoutOrder = i
			row.BorderSizePixel = 0
			row.BackgroundColor3 = Colors.PanelLight
			UIKit.Corner(row, 10)
			local head = Instance.new("ImageLabel")
			head.Size = UDim2.fromOffset(44, 44)
			head.Position = UDim2.fromOffset(6, 6)
			head.BackgroundColor3 = Colors.Panel
			head.BorderSizePixel = 0
			UIKit.Corner(head, 22)
			head.Parent = row
			task.spawn(function()
				local ok, image = pcall(function()
					return Players:GetUserThumbnailAsync(plr.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
				end)
				if ok and head.Parent then
					head.Image = image
				end
			end)
			UIKit.Label({
				Text = plr.DisplayName,
				TextSize = 18,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -64, 0, 24),
				Position = UDim2.fromOffset(58, 6),
				Parent = row,
			})
			UIKit.Label({
				Text = "@" .. plr.Name .. (if plr == player then " (you)" else ""),
				TextSize = 14,
				TextColor3 = Colors.TextDim,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -64, 0, 20),
				Position = UDim2.fromOffset(58, 30),
				Parent = row,
			})
			row.MouseButton1Click:Connect(function()
				selectedPlayer = if selectedPlayer == plr then nil else plr
				paintRows()
				refreshForm()
			end)
			row.Parent = playerList
			playerRows[plr] = row
		end
		paintRows()
	end
	search:GetPropertyChangedSignal("Text"):Connect(refreshPlayers)

	------------------------------------------------------------------ groups + commands (right)
	local right = Instance.new("Frame")
	right.Name = "Right"
	right.BackgroundTransparency = 1
	right.Position = UDim2.fromOffset(262, 0)
	right.Size = UDim2.new(1, -262, 1, -64)
	right.Parent = content

	-- The group tabs scroll sideways when they don't all fit.
	local tabs = Instance.new("ScrollingFrame")
	tabs.Name = "Groups"
	tabs.BackgroundTransparency = 1
	tabs.BorderSizePixel = 0
	tabs.Size = UDim2.new(1, 0, 0, 52)
	tabs.ScrollingDirection = Enum.ScrollingDirection.X
	tabs.AutomaticCanvasSize = Enum.AutomaticSize.X
	tabs.CanvasSize = UDim2.new()
	tabs.ScrollBarThickness = 4
	tabs.ScrollBarImageColor3 = Colors.Primary
	tabs.VerticalScrollBarInset = Enum.ScrollBarInset.None
	tabs.Parent = right
	listLayout(tabs, 8, true)
	local tabButtons: { [string]: TextButton } = {}

	local grid = scroller(right, UDim2.new(1, 0, 1, -236), UDim2.fromOffset(0, 56))
	grid.Name = "Commands"
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(170, 64)
	gridLayout.CellPadding = UDim2.fromOffset(10, 10)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	local gridPad = Instance.new("UIPadding")
	gridPad.PaddingTop = UDim.new(0, 4)
	gridPad.PaddingLeft = UDim.new(0, 4)
	gridPad.Parent = grid

	-- The options for the picked command, and RUN.
	local form = UIKit.Card({
		Size = UDim2.new(1, 0, 0, 170),
		Position = UDim2.new(0, 0, 1, -170),
		Color = Colors.PanelDark,
		Parent = right,
	})
	form.Name = "Form"
	formTitle = UIKit.Label({
		Text = "",
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -200, 0, 30),
		Position = UDim2.fromOffset(16, 10),
		Parent = form,
	})
	local formDesc = UIKit.Label({
		Text = "",
		TextSize = 15,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Size = UDim2.new(1, -200, 0, 20),
		Position = UDim2.fromOffset(16, 40),
		Parent = form,
	})
	local inputsFrame = Instance.new("Frame")
	inputsFrame.Name = "Inputs"
	inputsFrame.BackgroundTransparency = 1
	inputsFrame.Size = UDim2.new(1, -200, 0, 96)
	inputsFrame.Position = UDim2.fromOffset(12, 66)
	inputsFrame.Parent = form
	listLayout(inputsFrame, 6)
	local runButton = UIKit.Button({
		Name = "Run",
		Text = "RUN",
		Icon = "▶",
		Color = Colors.Good,
		Size = UDim2.fromOffset(160, 64),
		Position = UDim2.new(1, -16, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Parent = form,
	})

	-- Current values of the form's inputs, in order.
	local values: { string } = {}

	------------------------------------------------------------------ bottom: command line + feedback
	local bottom = Instance.new("Frame")
	bottom.Name = "Bottom"
	bottom.BackgroundTransparency = 1
	bottom.Size = UDim2.new(1, 0, 0, 52)
	bottom.Position = UDim2.new(0, 0, 1, -52)
	bottom.Parent = content
	local commandLine = field(bottom, UDim2.new(0.5, -6, 1, 0), UDim2.fromOffset(0, 0), "Type a command: :mute name reason   (Enter to run)")
	commandLine.Name = "CommandLine"
	local feedbackCard = UIKit.Card({ Size = UDim2.new(0.5, -6, 1, 0), Position = UDim2.new(0.5, 6, 0, 0), Color = Colors.PanelDark, Parent = bottom })
	local feedback = UIKit.Label({
		Name = "Feedback",
		Text = "Pick a player, then a command.",
		TextSize = 16,
		TextColor3 = Colors.TextDim,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		Parent = feedbackCard,
	})

	local function say(text: string, isError: boolean?)
		feedback.Text = text
		feedback.TextColor3 = if isError then Colors.Bad else Colors.Good
		if not window.Visible then
			UIKit.Toast(text, if isError then "Bad" else "Good")
		end
	end

	local function send(command: string, target: string, extra: string)
		if command == "spectate" or command == "controlplayer" then
			if target ~= "" and target:lower() ~= player.Name:lower() then
				coverFor(3)
			end
		end
		AdminCommand:FireServer(command, target, extra)
	end

	------------------------------------------------------------------ the form
	local function inputRow(): Frame
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 42)
		row.LayoutOrder = #inputsFrame:GetChildren()
		row.Parent = inputsFrame
		return row
	end

	local function choiceRow(index: number, choices: { { Label: string, Value: string } }, default: string?)
		local row = inputRow()
		local strip = scroller(row, UDim2.fromScale(1, 1), UDim2.new(), true)
		strip.ScrollBarThickness = 4
		listLayout(strip, 6, true)
		local buttons: { [TextButton]: string } = {}
		local function paint()
			for b, v in buttons do
				b.BackgroundColor3 = if values[index] == v then Colors.Primary else Colors.PanelLight
			end
		end
		values[index] = default or ""
		if #choices == 0 then
			UIKit.Label({ Text = "Nothing to pick.", TextSize = 15, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 1, 0), Parent = strip })
		end
		for i, choice in choices do
			local b = Instance.new("TextButton")
			b.AutoButtonColor = true
			b.Size = UDim2.fromOffset(0, 36)
			b.AutomaticSize = Enum.AutomaticSize.X
			b.LayoutOrder = i
			b.BorderSizePixel = 0
			b.Font = Fonts.Body
			b.TextSize = 16
			b.TextColor3 = Colors.Text
			b.Text = "  " .. choice.Label .. "  "
			UIKit.Corner(b, 10)
			b.MouseButton1Click:Connect(function()
				values[index] = choice.Value
				paint()
			end)
			b.Parent = strip
			buttons[b] = choice.Value
		end
		paint()
	end

	refreshForm = function()
		clear(inputsFrame)
		table.clear(values)
		local cmd = selectedCommand
		if not cmd then
			formTitle.Text = "Pick a command"
			formDesc.Text = "Pick a player on the left, then a command above."
			runButton.Visible = false
			return
		end
		runButton.Visible = true
		local who = if cmd.Target == "player" then (if selectedPlayer then " → @" .. selectedPlayer.Name else " → pick a player") else ""
		formTitle.Text = cmd.Icon .. " " .. cmd.Label .. who
		formDesc.Text = cmd.Desc
		for i, input in cmd.Inputs or {} do
			if input.Kind == "choice" and input.Options then
				local choices = input.Options()
				choiceRow(i, choices, if input.Required then nil else (choices[1] and choices[1].Value))
			elseif input.Kind == "duration" then
				local list = {}
				for _, d in DURATIONS do
					table.insert(list, { Label = d, Value = d })
				end
				choiceRow(i, list, "24h")
			else
				local row = inputRow()
				local box = field(row, UDim2.fromScale(1, 1), UDim2.new(), input.Placeholder or "")
				if input.Kind == "number" then
					box.PlaceholderText = input.Placeholder or "Type a number"
				end
				values[i] = ""
				box:GetPropertyChangedSignal("Text"):Connect(function()
					values[i] = box.Text
				end)
				-- A name box (":joinserver" and friends): suggest players here, Tab completes.
				if cmd.Target == "text" and i == 1 then
					local Autocomplete = require(Client:WaitForChild("Autocomplete")) :: any
					local detach = Autocomplete.Attach(box, function(text: string)
						local names = {}
						for _, plr in Players:GetPlayers() do
							table.insert(names, { Text = plr.Name, Hint = if plr.DisplayName ~= plr.Name then plr.DisplayName else nil })
						end
						return { Items = Autocomplete.Match((string.gsub(text, "%s+$", "")), names), Replace = 1 }
					end, { Above = false })
					box.Destroying:Connect(detach)
				end
			end
		end
	end

	local function runSelected()
		local cmd = selectedCommand
		if not cmd then
			return
		end
		local target = ""
		local firstInput = 1
		if cmd.Target == "player" then
			if not selectedPlayer then
				say("Pick a player on the left first.", true)
				return
			end
			target = selectedPlayer.Name
		elseif cmd.Target == "text" then
			target = (values[1] or ""):match("^%s*(.-)%s*$") or ""
			firstInput = 2
			if target == "" then
				say("Type a name first.", true)
				return
			end
		end
		local parts = {}
		for i, input in cmd.Inputs or {} do
			if i < firstInput then
				continue
			end
			local v = ((values[i] or ""):match("^%s*(.-)%s*$")) or ""
			if input.Required and v == "" then
				say("Fill in: " .. (input.Placeholder or "pick an option"), true)
				return
			end
			if input.Kind == "number" and v ~= "" and not tonumber(v) then
				say((input.Placeholder or "That") .. " has to be a number.", true)
				return
			end
			if v ~= "" then
				table.insert(parts, v)
			end
		end
		send(cmd.Name, target, table.concat(parts, " "))
		say("Sent :" .. cmd.Name .. (if target ~= "" then " " .. target else ""), false)
		feedback.TextColor3 = Colors.TextDim
	end
	runButton.MouseButton1Click:Connect(runSelected)

	------------------------------------------------------------------ command grid
	local function drawGroup()
		clear(grid)
		for name, b in tabButtons do
			b.BackgroundColor3 = if name == selectedGroup then Colors.Primary else Colors.PanelLight
		end
		local order = 0
		for _, cmd in COMMANDS do
			if cmd.Group ~= selectedGroup or not allowed[cmd.Name] then
				continue
			end
			order += 1
			local cell = Instance.new("TextButton")
			cell.Name = "Cmd_" .. cmd.Name
			cell.AutoButtonColor = true
			cell.Text = ""
			cell.LayoutOrder = order
			cell.BorderSizePixel = 0
			cell.BackgroundColor3 = if selectedCommand == cmd then Colors.Primary elseif cmd.Danger then Color3.fromRGB(120, 40, 60) else Colors.PanelLight
			UIKit.Corner(cell, 12)
			UIKit.Stroke(cell, Colors.Ink, 2)
			UIKit.Label({ Text = cmd.Icon, TextSize = 26, Size = UDim2.fromOffset(40, 64), Position = UDim2.fromOffset(6, 0), Parent = cell })
			UIKit.Label({
				Text = cmd.Label,
				TextSize = 17,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, -52, 1, 0),
				Position = UDim2.fromOffset(48, 0),
				Parent = cell,
			})
			cell.MouseButton1Click:Connect(function()
				selectedCommand = cmd
				refreshForm()
				drawGroup()
				-- Nothing to fill in and no one to pick: just run it.
				if cmd.Target == "none" and not cmd.Inputs and not cmd.Danger then
					runSelected()
				end
			end)
			cell.Parent = grid
		end
		if order == 0 then
			UIKit.Label({ Text = "No commands here for your rank.", TextSize = 18, TextColor3 = Colors.TextDim, Size = UDim2.fromOffset(400, 40), Parent = grid })
		end
	end

	for i, group in GROUPS do
		local b = UIKit.Button({
			Name = group.Name,
			Text = group.Name,
			Icon = group.Icon,
			Color = Colors.PanelLight,
			Size = UDim2.fromOffset(134, 44),
			TextSize = 18,
			LayoutOrder = i,
			Parent = tabs,
			OnClick = function()
				selectedGroup = group.Name
				selectedCommand = nil
				refreshForm()
				drawGroup()
			end,
		})
		tabButtons[group.Name] = b
	end

	------------------------------------------------------------------ lists (ban / mute / warn / logs / inventory)
	local overlay = Instance.new("Frame")
	overlay.Name = "ListView"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Colors.Panel
	overlay.BorderSizePixel = 0
	overlay.Visible = false
	overlay.ZIndex = 10
	overlay.Active = true
	overlay.Parent = content
	UIKit.Corner(overlay, 12)
	local overlayTitle = UIKit.Label({ Text = "", TextSize = 24, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -440, 0, 44), Position = UDim2.fromOffset(150, 4), Parent = overlay })
	UIKit.Button({
		Text = "Back",
		Icon = "◀",
		Color = Colors.PanelLight,
		Size = UDim2.fromOffset(130, 44),
		TextSize = 18,
		Position = UDim2.fromOffset(4, 4),
		Parent = overlay,
		OnClick = function()
			overlay.Visible = false
		end,
	})
	local listSearch = field(overlay, UDim2.fromOffset(270, 40), UDim2.new(1, -274, 0, 6), "🔍 Filter")
	-- ◀ ▶ to flip between pages of a list that has several (the Leaderboards view).
	local listNav: { Prev: () -> (), Next: () -> () }? = nil
	local navPrev = UIKit.Button({
		Text = "◀",
		Color = Colors.Primary,
		Size = UDim2.fromOffset(48, 40),
		TextSize = 20,
		Position = UDim2.new(1, -384, 0, 6),
		Parent = overlay,
		OnClick = function()
			if listNav then
				listNav.Prev()
			end
		end,
	})
	local navNext = UIKit.Button({
		Text = "▶",
		Color = Colors.Primary,
		Size = UDim2.fromOffset(48, 40),
		TextSize = 20,
		Position = UDim2.new(1, -330, 0, 6),
		Parent = overlay,
		OnClick = function()
			if listNav then
				listNav.Next()
			end
		end,
	})
	navPrev.Visible = false
	navNext.Visible = false
	-- An extra button in the list's header (the Pets view's "Add pet").
	local headerAction: (() -> ())? = nil
	local headerButton = UIKit.Button({
		Text = "",
		Color = Colors.Good,
		Size = UDim2.fromOffset(140, 40),
		TextSize = 18,
		Position = UDim2.new(1, -420, 0, 6),
		Parent = overlay,
		OnClick = function()
			if headerAction then
				headerAction()
			end
		end,
	})
	headerButton.Visible = false
	local listScroll = scroller(overlay, UDim2.new(1, -8, 1, -60), UDim2.fromOffset(4, 56))
	listLayout(listScroll, 6)

	local detail = Instance.new("Frame")
	detail.Name = "Detail"
	detail.Size = UDim2.fromScale(1, 1)
	detail.BackgroundColor3 = Colors.Panel
	detail.BorderSizePixel = 0
	detail.Visible = false
	detail.ZIndex = 20
	detail.Active = true
	detail.Parent = overlay
	UIKit.Corner(detail, 12)

	type Row = { Id: any, Line1: string?, Line2: string?, [string]: any }
	local currentRows: { Row } = {}
	local currentAction: string? = nil
	local currentOnAction: ((Row) -> ())? = nil
	-- An optional second button on each row (the All servers list: Join + Bring).
	local currentAction2: string? = nil
	local currentOnAction2: ((Row) -> ())? = nil

	local function drawRows()
		clear(listScroll)
		local filter = string.lower(listSearch.Text)
		local shown = 0
		for i, entry in currentRows do
			local line1 = tostring(entry.Line1 or "")
			local line2 = tostring(entry.Line2 or "")
			if filter ~= "" and not (line1:lower():find(filter, 1, true) or line2:lower():find(filter, 1, true)) then
				continue
			end
			shown += 1
			if shown > 300 then
				break
			end
			local row = UIKit.Card({ Size = UDim2.new(1, -10, 0, 64), Color = Colors.PanelLight, Parent = listScroll })
			row.LayoutOrder = i
			local textRoom = if currentAction2 then -310 else -170
			UIKit.Label({ Text = line1, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, textRoom, 0, 26), Position = UDim2.fromOffset(14, 6), Parent = row })
			UIKit.Label({ Text = line2, TextSize = 14, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, textRoom, 0, 22), Position = UDim2.fromOffset(14, 34), Parent = row })
			if currentAction2 and currentOnAction2 then
				local onAction2 = currentOnAction2
				UIKit.Button({
					Text = currentAction2,
					Color = Colors.Warning,
					Size = UDim2.fromOffset(130, 44),
					TextSize = 18,
					Position = UDim2.new(1, -152, 0.5, 0),
					AnchorPoint = Vector2.new(1, 0.5),
					Parent = row,
					OnClick = function()
						onAction2(entry)
					end,
				})
			end
			if currentAction and currentOnAction then
				local onAction = currentOnAction
				UIKit.Button({
					Text = currentAction,
					Color = if currentAction == "Remove" then Colors.Bad else Colors.Primary,
					Size = UDim2.fromOffset(130, 44),
					TextSize = 18,
					Position = UDim2.new(1, -12, 0.5, 0),
					AnchorPoint = Vector2.new(1, 0.5),
					Parent = row,
					OnClick = function()
						onAction(entry)
					end,
				})
			end
		end
		if shown == 0 then
			UIKit.Label({ Text = "Nothing here.", TextSize = 20, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 60), Parent = listScroll })
		end
	end
	listSearch:GetPropertyChangedSignal("Text"):Connect(drawRows)

	local function showList(title: string, rows: { Row }, action: string?, onAction: ((Row) -> ())?, nav: { Prev: () -> (), Next: () -> () }?, extra: { Text: string, OnClick: () -> () }?)
		listNav = nav
		navPrev.Visible = nav ~= nil
		navNext.Visible = nav ~= nil
		currentAction2 = nil
		currentOnAction2 = nil
		headerAction = if extra then extra.OnClick else nil
		headerButton.Visible = extra ~= nil
		if extra then
			headerButton.Text = extra.Text
		end
		overlayTitle.Size = if nav or extra then UDim2.new(1, -580, 0, 44) else UDim2.new(1, -440, 0, 44)
		overlayTitle.Text = title
		currentRows = if type(rows) == "table" then rows else {}
		currentAction = action
		currentOnAction = onAction
		detail.Visible = false
		overlay.Visible = true
		drawRows()
		if not window.Visible then
			UIKit.OpenWindow("Admin")
		end
	end

	local function detailPage(title: string): Frame
		clear(detail)
		detail.Visible = true
		UIKit.Button({
			Text = "Back",
			Icon = "◀",
			Color = Colors.PanelLight,
			Size = UDim2.fromOffset(130, 44),
			TextSize = 18,
			Position = UDim2.fromOffset(4, 4),
			Parent = detail,
			OnClick = function()
				detail.Visible = false
			end,
		})
		UIKit.Label({ Text = title, TextSize = 24, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -170, 0, 44), Position = UDim2.fromOffset(150, 4), Parent = detail })
		local body = Instance.new("Frame")
		body.BackgroundTransparency = 1
		body.Size = UDim2.new(1, -40, 1, -70)
		body.Position = UDim2.fromOffset(20, 64)
		body.Parent = detail
		return body
	end

	-- Ban / mute: change the reason or the length, or lift it.
	local function modifyPunishment(kind: string, entry: Row)
		local body = detailPage((if kind == "ban" then "🔨 Ban · " else "🔇 Mute · ") .. tostring(entry.Name or entry.Line1 or "?"))
		UIKit.Label({ Text = "REASON", TextSize = 16, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 22), Parent = body })
		local reason = field(body, UDim2.new(1, -160, 0, 46), UDim2.fromOffset(0, 26), "Reason")
		reason.Text = tostring(entry.Reason or "")
		UIKit.Button({
			Text = "Save",
			Color = Colors.Primary,
			Size = UDim2.fromOffset(140, 46),
			Position = UDim2.new(1, 0, 0, 26),
			AnchorPoint = Vector2.new(1, 0),
			Parent = body,
			OnClick = function()
				AdminModifyPunishment:FireServer(kind, entry.Id, "reason", reason.Text)
				detail.Visible = false
			end,
		})
		UIKit.Label({ Text = "LENGTH · now " .. tostring(entry.DurationText or "Permanent"), TextSize = 16, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 22), Position = UDim2.fromOffset(0, 92), Parent = body })
		local presetRow = Instance.new("Frame")
		presetRow.BackgroundTransparency = 1
		presetRow.Size = UDim2.new(1, 0, 0, 50)
		presetRow.Position = UDim2.fromOffset(0, 118)
		presetRow.Parent = body
		listLayout(presetRow, 8, true)
		for i, preset in PRESETS do
			UIKit.Button({
				Text = preset.Label,
				Color = Colors.PanelLight,
				Size = UDim2.fromOffset(150, 46),
				TextSize = 18,
				LayoutOrder = i,
				Parent = presetRow,
				OnClick = function()
					AdminModifyPunishment:FireServer(kind, entry.Id, "duration", preset.Seconds)
					detail.Visible = false
				end,
			})
		end
		UIKit.Button({
			Text = if kind == "ban" then "UNBAN" else "UNMUTE",
			Color = Colors.Bad,
			Size = UDim2.fromOffset(260, 60),
			Position = UDim2.new(0.5, 0, 0, 210),
			AnchorPoint = Vector2.new(0.5, 0),
			Parent = body,
			OnClick = function()
				AdminModifyPunishment:FireServer(kind, entry.Id, "remove")
				detail.Visible = false
			end,
		})
	end

	local function logDetail(entry: Row)
		local body = detailPage("📜 :" .. tostring(entry.Command or "?"))
		local lines = {
			"Admin: " .. tostring(entry.Admin or "?") .. (if entry.Tier then " (" .. tostring(entry.Tier) .. ")" else ""),
			"Target: " .. tostring(entry.Target or "-"),
			"Details: " .. tostring(entry.Extra or "-"),
			"When: " .. (if type(entry.Timestamp) == "number" then os.date("%Y-%m-%d %H:%M:%S", entry.Timestamp) else "?"),
			"",
			tostring(entry.Description or ""),
		}
		UIKit.Label({
			Text = table.concat(lines, "\n"),
			TextSize = 20,
			Font = Fonts.Body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Size = UDim2.new(1, 0, 1, -80),
			Parent = body,
		})
		if canRemoveLogs then
			UIKit.Button({
				Text = "Remove from log",
				Color = Colors.Bad,
				Size = UDim2.fromOffset(240, 54),
				Position = UDim2.new(0.5, 0, 1, -6),
				AnchorPoint = Vector2.new(0.5, 1),
				Parent = body,
				OnClick = function()
					AdminRemoveLogEntry:FireServer(entry.Id)
					detail.Visible = false
				end,
			})
		end
	end

	AdminBanList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "Modify", function(entry)
			modifyPunishment("ban", entry)
		end)
	end)
	AdminMuteList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "Modify", function(entry)
			modifyPunishment("mute", entry)
		end)
	end)
	AdminWarnList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "View", function(entry)
			AdminViewWarnings:FireServer(entry.Id)
		end)
	end)
	local lastWarningsName = "?"
	AdminWarningsList.OnClientEvent:Connect(function(targetName, targetUserId, warnings)
		if targetName then
			lastWarningsName = tostring(targetName)
		end
		local rows = {}
		for i, w in warnings or {} do
			table.insert(rows, {
				Id = i,
				Line1 = "#" .. i .. ": " .. tostring(w.Reason),
				Line2 = "by " .. tostring(w.By) .. " · " .. os.date("%Y-%m-%d %H:%M", w.Timestamp or 0),
			})
		end
		showList("⚠️ Warnings · " .. lastWarningsName .. " (" .. #rows .. ")", rows, "Remove", function(entry)
			AdminRemoveWarning:FireServer(targetUserId, entry.Id)
		end)
	end)
	AdminInventoryList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "Remove", function(entry)
			AdminInventoryRemoveItem:FireServer(entry.Id)
		end)
	end)
	AdminLogsList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "View", logDetail)
	end)

	-- Pets: every pet a player owns, Remove on each, "Add pet" to give one (pick pet + tier).
	local petTarget: number? = nil
	local function addPetPage()
		local body = detailPage("🐾 Add a pet")
		local tier = 1
		local tierRow = Instance.new("Frame")
		tierRow.BackgroundTransparency = 1
		tierRow.Size = UDim2.new(1, 0, 0, 48)
		tierRow.Parent = body
		listLayout(tierRow, 8, true)
		local tierButtons = {}
		local function paintTiers()
			for t, b in tierButtons do
				UIKit.SetButtonColor(b, if t == tier then Colors.Primary else Colors.PanelLight)
			end
		end
		for t, label in { "Normal", "Golden", "Rainbow" } do
			tierButtons[t] = UIKit.Button({
				Text = label,
				Color = Colors.PanelLight,
				Size = UDim2.fromOffset(150, 44),
				TextSize = 18,
				LayoutOrder = t,
				Parent = tierRow,
				OnClick = function()
					tier = t
					paintTiers()
				end,
			})
		end
		paintTiers()
		local list = scroller(body, UDim2.new(1, 0, 1, -60), UDim2.fromOffset(0, 58))
		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromOffset(200, 50)
		grid.CellPadding = UDim2.fromOffset(8, 8)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = list
		local ids = {}
		for id in Config.Pets do
			table.insert(ids, id)
		end
		table.sort(ids, function(a, b)
			return Config.Pets[a].Name < Config.Pets[b].Name
		end)
		for i, id in ids do
			UIKit.Button({
				Text = Config.Pets[id].Name,
				Color = Colors.Good,
				TextSize = 16,
				LayoutOrder = i,
				Parent = list,
				OnClick = function()
					if petTarget then
						AdminPetAction:FireServer("Add", petTarget, id, tier)
					end
				end,
			})
		end
	end
	-- All servers: one row per server (its players underneath) with a single Join (arrive invisible).
	AdminServerList.OnClientEvent:Connect(function(title, entries, busiestJobId, filterIndex, filterCount)
		local extra = nil
		if type(busiestJobId) == "string" then
			extra = {
				Text = "Busiest lobby",
				OnClick = function()
					AdminServerAction:FireServer("Join", busiestJobId)
				end,
			}
		end
		-- The arrows flip through the filters: All servers, Lobby servers, Game servers, Level 1, Level 2, Level 3.
		local index = tonumber(filterIndex) or 1
		local count = math.max(tonumber(filterCount) or 1, 1)
		showList(tostring(title), entries, "Join", function(entry)
			AdminServerAction:FireServer("Join", entry.JobId, entry.Id)
		end, {
			Prev = function()
				AdminServerAction:FireServer("List", tostring(((index - 2) % count) + 1))
			end,
			Next = function()
				AdminServerAction:FireServer("List", tostring((index % count) + 1))
			end,
		}, extra)
	end)

	-- Analytics reports: the same list window, the arrows flip between the reports.
	AdminReport.OnClientEvent:Connect(function(title, entries, index, count, days)
		local shown = tonumber(index) or 1
		local total = math.max(tonumber(count) or 1, 1)
		local back = tonumber(days) or 7
		-- (count 0 = a plain list with no arrows, like the badge check)
		showList(tostring(title), entries, nil, nil, if (tonumber(count) or 1) <= 0 then nil else {
			Prev = function()
				AdminServerAction:FireServer("Report", string.format("%d:%d", ((shown - 2) % total) + 1, back))
			end,
			Next = function()
				AdminServerAction:FireServer("Report", string.format("%d:%d", (shown % total) + 1, back))
			end,
		})
	end)

	AdminStaffList.OnClientEvent:Connect(function(title, entries)
		showList(tostring(title), entries, "Remove", function(entry)
			AdminStaffAction:FireServer("Remove", entry.Id)
		end)
	end)

	AdminPetList.OnClientEvent:Connect(function(targetUserId, title, entries)
		petTarget = tonumber(targetUserId)
		local keepDetail = detail.Visible
		showList(tostring(title), entries, "Remove", function(entry)
			if petTarget then
				AdminPetAction:FireServer("Remove", petTarget, entry.Id)
			end
		end, nil, { Text = "+ Add pet", OnClick = addPetPage })
		-- Adding several pets in a row: stay on the picker.
		if keepDetail then
			detail.Visible = true
		end
	end)

	-- Leaderboards: one board at a time, ◀ ▶ to flip, Reset on each row (with a confirm step).
	local boardIndex, boardCount = 1, 1
	-- Pages already seen show straight away (then refresh); a reply for a page you've already
	-- flipped past is ignored, so fast clicking never jumps back.
	local boardCache: { [number]: { Count: number, Title: string, Entries: { any } } } = {}
	local showBoard: (number, number, string, { any }) -> () = nil :: any
	local pendingBoard: number? = nil
	local function requestBoard(index: number)
		boardIndex = ((index - 1) % math.max(boardCount, 1)) + 1
		pendingBoard = boardIndex
		local cached = boardCache[boardIndex]
		if cached then
			showBoard(boardIndex, cached.Count, cached.Title, cached.Entries)
		end
		AdminLeaderboard:FireServer("View", boardIndex)
	end
	local function confirmReset(entry: Row)
		local body = detailPage("Reset " .. tostring(entry.Name))
		UIKit.Label({
			Text = string.format("Take %s off \"%s\"?\n\nThey keep all their real stats. Only this leaderboard starts again from zero for them.", tostring(entry.Name), tostring(entry.Board)),
			TextSize = 20,
			Font = Fonts.Body,
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, 120),
			Parent = body,
		})
		UIKit.Button({
			Text = "RESET",
			Color = Colors.Bad,
			Size = UDim2.fromOffset(260, 60),
			Position = UDim2.new(0.5, 0, 0, 150),
			AnchorPoint = Vector2.new(0.5, 0),
			Parent = body,
			OnClick = function()
				detail.Visible = false
				AdminLeaderboard:FireServer("Reset", boardIndex, entry.Id)
			end,
		})
	end
	showBoard = function(index: number, count: number, title: string, entries: { any })
		boardIndex = index
		boardCount = count
		local rows = {}
		for i, e in entries do
			table.insert(rows, {
				Id = e.UserId,
				Name = e.Name,
				Board = title,
				Line1 = string.format("#%d  %s", i, tostring(e.Name)),
				Line2 = tostring(e.Text) .. "  ·  UserId " .. tostring(e.UserId),
			})
		end
		showList(string.format("%s (%d/%d)", title, boardIndex, boardCount), rows, "Reset", confirmReset, {
			Prev = function()
				requestBoard(boardIndex - 1)
			end,
			Next = function()
				requestBoard(boardIndex + 1)
			end,
		})
	end
	AdminLeaderboard.OnClientEvent:Connect(function(index, count, title, entries)
		local i = tonumber(index) or 1
		local data = { Count = tonumber(count) or 1, Title = tostring(title), Entries = if type(entries) == "table" then entries else {} }
		boardCache[i] = data
		boardCount = data.Count
		-- A slow reply for a page you've already flipped past is only cached, not drawn.
		if pendingBoard == nil or i == pendingBoard then
			pendingBoard = nil
			showBoard(i, data.Count, data.Title, data.Entries)
		end
	end)

	AdminFeedback.OnClientEvent:Connect(function(text, isError)
		say(tostring(text), isError == true)
		if isError then
			revealScreen()
		end
	end)

	------------------------------------------------------------------ command line
	-- Suggestions as you type, like Minecraft: the command, then a player, then each option.
	-- Tab completes (Autocomplete never leaves a tab character in the box).
	local Autocomplete = require(Client:WaitForChild("Autocomplete")) :: any
	local function playerItems(): { any }
		local out = {}
		for _, plr in Players:GetPlayers() do
			table.insert(out, { Text = plr.Name, Hint = if plr.DisplayName ~= plr.Name then plr.DisplayName else nil })
		end
		return out
	end
	local function usageOf(cmd: any): string
		local bits = { ":" .. cmd.Name }
		if cmd.Target == "player" then
			table.insert(bits, "<player>")
		end
		for _, input in cmd.Inputs or {} do
			local name = if input.Kind == "duration" then "time" elseif input.Kind == "choice" then "option" else string.lower(input.Placeholder or input.Kind)
			table.insert(bits, if input.Required or input.Kind == "duration" then "<" .. name .. ">" else "[" .. name .. "]")
		end
		return table.concat(bits, " ") .. "   -  " .. cmd.Label
	end
	Autocomplete.Attach(commandLine, function(text: string)
		local words, lastStart = Autocomplete.Split(text)
		local first = string.lower((string.gsub(words[1] or "", "^:", "")))
		if #words <= 1 then
			local start = if string.sub(text, lastStart, lastStart) == ":" then lastStart + 1 else lastStart
			local candidates = {}
			for _, cmd in COMMANDS do
				if allowed[cmd.Name] then
					table.insert(candidates, { Text = cmd.Name, Hint = cmd.Label })
				end
			end
			return { Items = Autocomplete.Match(string.sub(text, start), candidates), Replace = start }
		end
		local cmd = nil
		for _, c in COMMANDS do
			if c.Name == first and allowed[c.Name] then
				cmd = c
			end
		end
		if not cmd then
			return { Usage = "Unknown command", Items = {}, Replace = lastStart }
		end
		local word = words[#words]
		local index = #words - 1 -- 1 = the first thing after the command
		local usage = usageOf(cmd)
		if cmd.Target == "player" or cmd.Target == "text" then
			if index == 1 then
				return { Usage = usage, Items = Autocomplete.Match(word, playerItems()), Replace = lastStart }
			end
			index -= if cmd.Target == "player" then 1 else 0
		end
		local input = (cmd.Inputs or {})[index]
		local items = {}
		if input and input.Kind == "choice" and input.Options then
			for _, o in input.Options() do
				table.insert(items, { Text = o.Value, Hint = if o.Label ~= o.Value then o.Label else nil })
			end
		elseif input and input.Kind == "duration" then
			for _, d in DURATIONS do
				table.insert(items, { Text = d })
			end
		end
		return { Usage = usage, Items = Autocomplete.Match(word, items, true), Replace = lastStart }
	end)

	commandLine.FocusLost:Connect(function(enterPressed)
		if not enterPressed then
			return
		end
		local text = commandLine.Text
		commandLine.Text = ""
		local command, after = text:match("^%s*:?(%S*)%s*(.*)$")
		command = string.lower(command or "")
		if command == "" then
			return
		end
		local target, rest = (after or ""):match("^(%S*)%s*(.*)$")
		for _, cmd in COMMANDS do
			if cmd.Name == command and cmd.Target == "none" then
				-- These take no name: everything after the command is the text.
				rest = ((target or "") .. " " .. (rest or "")):match("^%s*(.-)%s*$")
				target = ""
				break
			end
		end
		send(command, target or "", rest or "")
		feedback.Text = "Sent :" .. command
		feedback.TextColor3 = Colors.TextDim
	end)

	------------------------------------------------------------------ window
	UIKit.RegisterWindow("Admin", {
		Open = function()
			refreshPlayers()
			refreshForm()
			drawGroup()
		end,
	})
	Players.PlayerAdded:Connect(function()
		if window.Visible then
			refreshPlayers()
		end
	end)
	Players.PlayerRemoving:Connect(function(plr)
		if plr == selectedPlayer then
			selectedPlayer = nil
		end
		task.defer(function()
			if window.Visible then
				refreshPlayers()
				refreshForm()
			end
		end)
	end)

end

------------------------------------------------------------------ spectate / control bars (sent only to admins)
local actionBar = UIKit.Card({
	Size = UDim2.fromOffset(520, 70),
	Position = UDim2.new(0.5, 0, 1, -130),
	AnchorPoint = Vector2.new(0.5, 1),
	Color = Colors.Panel,
	Parent = statusRoot,
})
actionBar.Name = "AdminActionBar"
actionBar.Visible = false
UIKit.Stroke(actionBar, Colors.Primary, 3)
local actionLabel = UIKit.Label({ Text = "", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -170, 1, 0), Position = UDim2.fromOffset(18, 0), Parent = actionBar })
local actionStop: (() -> ())? = nil
UIKit.Button({
	Text = "Stop",
	Icon = "⏹",
	Color = Colors.Bad,
	Size = UDim2.fromOffset(140, 50),
	Position = UDim2.new(1, -12, 0.5, 0),
	AnchorPoint = Vector2.new(1, 0.5),
	Parent = actionBar,
	OnClick = function()
		if actionStop then
			actionStop()
		end
	end,
})

local function cameraToSelf()
	local camera = workspace.CurrentCamera
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

AdminSpectate.OnClientEvent:Connect(function(target: Player?)
	if not target then
		actionBar.Visible = false
		cameraToSelf()
		revealScreen()
		return
	end
	local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	local camera = workspace.CurrentCamera
	if humanoid and camera then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end
	actionLabel.Text = "👁️ Spectating @" .. target.Name
	actionStop = function()
		coverFor(1.5) -- hides the teleport back to where you were
		actionBar.Visible = false
		cameraToSelf()
		AdminStopSpectating:FireServer()
	end
	actionBar.Visible = true
	revealScreen()
end)

local controlConn: RBXScriptConnection? = nil
local jumpQueued = false
UserInputService.JumpRequest:Connect(function()
	jumpQueued = true
end)
AdminControlPlayer.OnClientEvent:Connect(function(target: Player?)
	if controlConn then
		controlConn:Disconnect()
		controlConn = nil
	end
	if not target then
		actionBar.Visible = false
		cameraToSelf()
		revealScreen()
		return
	end
	local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	local camera = workspace.CurrentCamera
	if humanoid and camera then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end
	actionLabel.Text = "🎮 Controlling @" .. target.Name
	actionStop = function()
		coverFor(1.5) -- hides the teleport back to where you were
		if controlConn then
			controlConn:Disconnect()
			controlConn = nil
		end
		actionBar.Visible = false
		cameraToSelf()
		AdminStopControlling:FireServer()
	end
	actionBar.Visible = true
	revealScreen()
	controlConn = RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local mv = moveVector()
		local look = cam.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		flatLook = if flatLook.Magnitude > 1e-3 then flatLook.Unit else Vector3.new(0, 0, -1)
		local rightV = cam.CFrame.RightVector
		local flatRight = Vector3.new(rightV.X, 0, rightV.Z)
		flatRight = if flatRight.Magnitude > 1e-3 then flatRight.Unit else Vector3.new(1, 0, 0)
		local dir = flatRight * mv.X - flatLook * mv.Z
		if dir.Magnitude > 1 then
			dir = dir.Unit
		end
		local jump = jumpQueued or (UserInputService:GetFocusedTextBox() == nil and UserInputService:IsKeyDown(Enum.KeyCode.Space))
		jumpQueued = false
		AdminControlMove:FireServer(dir, jump)
	end)
end)

----------------------------------------------------------------------------------------------------
-- Start: ask the server who we are. The owner and staff get a tier (and so a panel); a rank given or
-- taken away later arrives through AdminInfoChanged.
----------------------------------------------------------------------------------------------------
local ok, info = pcall(function()
	return GetAdminInfo:InvokeServer()
end)
if ok then
	buildPanel(info)
end
task.spawn(function()
	local changed = ReplicatedStorage:WaitForChild("AdminInfoChanged", 30)
	if changed then
		(changed :: any).OnClientEvent:Connect(buildPanel)
	end
end)
