--[[
	PartyUI - the little panel that appears bottom-centre while ClientState.Party ~= nil (waiting in a
	lobby pad). It is NOT a UIKit.Window: it has no title bar and no X, and it is always on screen for
	as long as the player is in a party, so it can show the live countdown even while other windows
	(Shop, Pets) are open on top of it.

	The host gets settings (max players, privacy, level) and [Start Now]; members get a read-only
	summary. Everyone gets [Leave]. All of it collapses to a single "Launching! 🫧" message, with every
	control disabled, once the pad calls PartyAction "StartNow" (or the countdown hits zero).

	Sends the C->S RemoteEvent PartyAction directly (fire-and-forget; the server validates and rate-
	limits everything), and reads ClientState.Party for state.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Colors = UIKit.Theme.Colors

local PartyUI = {}

local PANEL_WIDTH = 620
local BOTTOM_MARGIN = 18
local TOUCH_X_OFFSET = 60 -- shifts the panel into the gap between the thumbstick and jump zones

local initialized = false

-- Built once in Init(); rebuilt (children replaced) every time ClientState.Party changes.
local panelBG: Frame
local content: Frame
local countdownLabel: TextLabel? = nil -- kept live by the 10x/s loop below; nil while not shown

----------------------------------------------------------------------------------------------------
-- Avatar thumbnails: fetched once per user id and cached forever (they don't change mid-session).
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

----------------------------------------------------------------------------------------------------
-- Small builders
----------------------------------------------------------------------------------------------------

-- A horizontal strip of instances, auto-height, used for every control row.
local function makeRow(parent: Instance, layoutOrder: number, spacing: number?): Frame
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.LayoutOrder = layoutOrder
	row.Size = UDim2.new(1, 0, 0, 0)
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.BackgroundTransparency = 1
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.Padding = UDim.new(0, spacing or 8)
	list.Parent = row
	row.Parent = parent
	return row
end

local function memberCard(member: Types.PartyMember, isHostMember: boolean): Frame
	local card = Instance.new("Frame")
	card.Name = "Member"
	card.Size = UDim2.fromOffset(84, 88)
	card.BackgroundTransparency = 1

	local AVATAR = 54
	local avatar = UIKit.New("ImageLabel", {
		Name = "Avatar",
		Size = UDim2.fromOffset(AVATAR, AVATAR),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 0),
		BackgroundColor3 = Colors.PanelLight,
		ScaleType = Enum.ScaleType.Crop,
		Parent = card,
	}) :: ImageLabel
	UIKit.Corner(avatar, 999)
	UIKit.Stroke(avatar, if isHostMember then Colors.Coin else Colors.Ink, if isHostMember then 3 else 2)
	fetchThumbnail(member.UserId, function(image)
		if avatar.Parent then
			avatar.Image = image
		end
	end)

	if isHostMember then
		UIKit.Label({
			Text = "👑",
			TextSize = 20,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 6, 0, -8),
			Size = UDim2.fromOffset(24, 24),
			ZIndex = 3,
			Parent = card,
		})
	end

	UIKit.Label({
		Text = member.DisplayName ~= "" and member.DisplayName or member.Name,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextScaled = true,
		Position = UDim2.new(0, 0, 0, AVATAR + 4),
		Size = UDim2.new(1, 0, 0, 20),
		Parent = card,
	})

	return card
end

----------------------------------------------------------------------------------------------------
-- Render: fully rebuilds `content` from the current ClientState.Party. Called on every party change
-- (state pushes are infrequent - a settings tweak or a join/leave - so a full rebuild is cheap).
----------------------------------------------------------------------------------------------------
local function render()
	local party = ClientState.Party :: Types.PartyState?
	if not party then
		panelBG.Visible = false
		countdownLabel = nil
		return
	end
	panelBG.Visible = true

	content:ClearAllChildren()
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 8)
	list.Parent = content

	local launching = party.Status == "Launching"
	local memberCount = #party.Members

	-- Row 1: title + countdown / launching banner.
	local header = makeRow(content, 1, 12)
	header.Size = UDim2.new(1, 0, 0, 26)
	UIKit.Label({
		Text = string.format("🎉 Party (%d/%d)", memberCount, party.MaxPlayers),
		TextSize = 22,
		Parent = header,
	})
	local status = UIKit.Label({
		Text = "",
		TextSize = 18,
		TextColor3 = if launching then Colors.Good else Colors.TextDim,
		Parent = header,
	})
	if launching then
		status.Text = "Launching! 🫧"
		countdownLabel = nil
		UIKit.Bounce(status)
	else
		countdownLabel = status
	end

	-- Row 2: member avatars, longest-waiting first (Members[1]), host marked with a crown.
	local membersRow = makeRow(content, 2, 6)
	for _, member in party.Members do
		memberCard(member, member.UserId == party.HostUserId).Parent = membersRow
	end

	if party.IsHost then
		-- Row 3: Max players (segmented) + Public/Friends toggle.
		local settingsRow = makeRow(content, 3, 18)

		local maxGroup = Instance.new("Frame")
		maxGroup.Name = "MaxGroup"
		maxGroup.Size = UDim2.fromOffset(4 * 38 + 3 * 6 + 46, 34)
		maxGroup.BackgroundTransparency = 1
		maxGroup.Parent = settingsRow
		UIKit.Label({
			Text = "Max",
			TextSize = 16,
			TextColor3 = Colors.TextDim,
			Size = UDim2.fromOffset(40, 34),
			TextYAlignment = Enum.TextYAlignment.Center,
			Parent = maxGroup,
		})
		local maxButtons = Instance.new("UIListLayout")
		maxButtons.SortOrder = Enum.SortOrder.LayoutOrder
		maxButtons.FillDirection = Enum.FillDirection.Horizontal
		maxButtons.Padding = UDim.new(0, 6)
		maxButtons.Parent = maxGroup
		for i = 1, Config.Party.MaxPlayers do
			UIKit.Button({
				Text = tostring(i),
				Size = UDim2.fromOffset(34, 34),
				CornerRadius = 8,
				Color = if i == party.MaxPlayers then Colors.Primary else Colors.PanelLight,
				Disabled = launching or i < memberCount,
				LayoutOrder = i + 1,
				Parent = maxGroup,
				OnClick = function()
					sendPartyAction("SetMax", i)
				end,
			})
		end

		local isPublic = party.Privacy == "Public"
		UIKit.Button({
			Text = if isPublic then "🌐 Public" else "👥 Friends",
			Size = UDim2.fromOffset(140, 34),
			CornerRadius = 8,
			Color = if isPublic then Colors.Primary else Colors.Accent,
			Disabled = launching,
			Parent = settingsRow,
			OnClick = function()
				sendPartyAction("SetPrivacy", if isPublic then "Friends" else "Public")
			end,
		})

		-- Row 4: level picker.
		local levelRow = makeRow(content, 4, 10)
		local level = Config.GetLevel(party.Level)
		local atMin, atMax = party.Level <= 1, party.Level >= party.HostUnlocked
		UIKit.Button({
			Text = "◀",
			Size = UDim2.fromOffset(34, 44),
			CornerRadius = 8,
			Disabled = launching or atMin,
			Parent = levelRow,
			OnClick = function()
				sendPartyAction("SetLevel", math.max(1, party.Level - 1))
			end,
		})
		local card = UIKit.Card({ Size = UDim2.fromOffset(320, 44), Parent = levelRow })
		UIKit.Label({
			Text = level.Icon .. " " .. level.Name,
			TextSize = 18,
			Position = UDim2.fromOffset(10, 2),
			Size = UDim2.new(1, -20, 0, 20),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = card,
		})
		UIKit.Label({
			Text = if atMax and party.HostUnlocked < #Config.Levels
				then "🔒 Clear this to unlock more dishwashers"
				else level.Subtitle,
			TextSize = 13,
			TextColor3 = Colors.TextDim,
			Position = UDim2.fromOffset(10, 22),
			Size = UDim2.new(1, -20, 0, 18),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextScaled = true,
			Parent = card,
		})
		UIKit.Button({
			Text = "▶",
			Size = UDim2.fromOffset(34, 44),
			CornerRadius = 8,
			Disabled = launching or atMax,
			Parent = levelRow,
			OnClick = function()
				sendPartyAction("SetLevel", math.min(party.HostUnlocked, party.Level + 1))
			end,
		})

		-- Row 5: Start Now + Leave.
		local buttonsRow = makeRow(content, 5, 12)
		UIKit.Button({
			Text = "Start Now",
			Icon = "🚀",
			Size = UDim2.fromOffset(220, 48),
			Color = Colors.Good,
			Disabled = launching,
			Parent = buttonsRow,
			OnClick = function()
				sendPartyAction("StartNow", nil)
			end,
		})
		UIKit.Button({
			Text = "Leave",
			Size = UDim2.fromOffset(140, 48),
			Color = Colors.Bad,
			Disabled = launching,
			Parent = buttonsRow,
			OnClick = function()
				sendPartyAction("Leave", nil)
			end,
		})
	else
		-- Member: read-only summary of the host's settings, plus Leave.
		local level = Config.GetLevel(party.Level)
		local summaryRow = makeRow(content, 3, 0)
		UIKit.Label({
			Text = string.format(
				"%s %s  •  %s  •  Max %d",
				level.Icon,
				level.Name,
				if party.Privacy == "Public" then "🌐 Public" else "👥 Friends",
				party.MaxPlayers
			),
			TextSize = 16,
			TextColor3 = Colors.TextDim,
			TextScaled = true,
			Size = UDim2.fromOffset(560, 22),
			Parent = summaryRow,
		})
		local buttonsRow = makeRow(content, 4, 0)
		UIKit.Button({
			Text = "Leave",
			Size = UDim2.fromOffset(160, 44),
			Color = Colors.Bad,
			Disabled = launching,
			Parent = buttonsRow,
			OnClick = function()
				sendPartyAction("Leave", nil)
			end,
		})
	end

	if countdownLabel then
		local remaining = math.max(0, math.ceil(party.EndsAt - workspace:GetServerTimeNow()))
		countdownLabel.Text = string.format("⏱️ Starting in %ds", remaining)
	end
end

-- Re-place the panel so it never sits over the thumbstick / jump touch zones (it hugs the gap
-- between them, which is exactly PANEL_WIDTH wide - see DESIGN.md "keep these canvas areas clear").
local function reposition()
	local touch = UIKit.IsTouch()
	local safe = UIKit.SafeInsets()
	panelBG.Position = UDim2.new(0.5, if touch then TOUCH_X_OFFSET else 0, 1, -(BOTTOM_MARGIN + safe.Bottom))
end

-- Keeps the countdown ticking at ~10Hz without touching the rest of the panel. Cheap and only runs
-- while there's something to update.
local function countdownLoop()
	while true do
		local party = ClientState.Party
		if party and party.Status == "Waiting" and countdownLabel and countdownLabel.Parent then
			local remaining = math.max(0, math.ceil(party.EndsAt - workspace:GetServerTimeNow()))
			countdownLabel.Text = string.format("⏱️ Starting in %ds", remaining)
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

	local _gui, root = UIKit.CreateScreen("PartyUI", 5)

	panelBG = Instance.new("Frame")
	panelBG.Name = "Panel"
	panelBG.AnchorPoint = Vector2.new(0.5, 1)
	panelBG.Size = UDim2.fromOffset(PANEL_WIDTH, 0)
	panelBG.AutomaticSize = Enum.AutomaticSize.Y
	panelBG.BackgroundColor3 = Color3.new(1, 1, 1)
	panelBG.BorderSizePixel = 0
	panelBG.Visible = false
	panelBG.ZIndex = 15
	UIKit.Corner(panelBG, 18)
	UIKit.Gradient(panelBG, Colors.Panel, Colors.PanelDark)
	UIKit.Stroke(panelBG, Colors.Ink, 3)
	panelBG.Parent = root

	content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 0, 0)
	content.AutomaticSize = Enum.AutomaticSize.Y
	content.BackgroundTransparency = 1
	content.ZIndex = 15
	UIKit.Padding(content, 14)
	content.Parent = panelBG

	reposition()
	UIKit.LayoutChanged:Connect(reposition)

	ClientState.Changed:Connect(function(kind)
		if kind == "Party" then
			render()
		end
	end)
	render() -- in case Party already replicated before we connected

	task.spawn(countdownLoop)
end

return PartyUI
