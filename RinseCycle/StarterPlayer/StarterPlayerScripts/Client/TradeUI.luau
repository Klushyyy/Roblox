--[[
	TradeUI - pet trading (lobby only; TradeService on the server checks everything).

	  * The 🤝 Trade button (HUD) opens the Trade window: everyone in the server with a Request
	    button. A sent request can be cancelled while it's open; the same player can only be asked
	    again after a wait (shown on the button), unless they've accepted one before.
	  * A request you receive pops up at the top of the screen with Accept / Decline (it goes away
	    if the sender cancels).
	  * During a trade the window shows both offers, and your pets below: tap a pet to offer it,
	    tap it in your offer to take it back. Both press Ready; after a "3, 2, 1" countdown the pets
	    swap (either side can still cancel or un-ready during it). Any change un-readies both sides. Closing the window cancels the trade.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local PetModels = require(Shared:WaitForChild("PetModels"))

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))

local TradeUI = {}

local Colors = UIKit.Theme.Colors
local LocalPlayer = Players.LocalPlayer

local CELL = Vector2.new(96, 112)

local initialized = false
local state: any = nil -- the current TradeState, nil when not trading
-- Requests I've sent: [tostring(userId)] = { PendingUntil?, WaitUntil? } (server time).
local outgoing: { [string]: { PendingUntil: number?, WaitUntil: number? } } = {}
local pickerRows: { { Button: TextButton, Cancel: TextButton, UserId: number } } = {}
local inviteCards: { [number]: Frame } = {}
local content: Frame
local body: Frame
local actionRemote: RemoteEvent

local function send(action: string, value: any?)
	actionRemote:FireServer(action, value)
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		child:Destroy()
	end
end

local function petName(id: string, tier: number?): string
	local def = Config.Pets[id]
	local name = if def then def.Name else id
	local tierName = Config.PetTier(tier).Name
	return if tierName ~= "" then tierName .. " " .. name else name
end

-- One pet tile. onClick is optional.
local function petCell(parent: Instance, entry: any, order: number, onClick: (() -> ())?, highlight: boolean?): Frame
	local card = UIKit.Card({
		Size = UDim2.fromOffset(CELL.X, CELL.Y),
		Color = if highlight then Colors.Primary else Colors.PanelLight,
		Parent = parent,
	})
	card.LayoutOrder = order
	local vp = UIKit.Viewport({
		Model = PetModels.Build(entry.Id, entry.Tier),
		Size = UDim2.fromOffset(CELL.X - 12, 72),
		Position = UDim2.new(0.5, 0, 0, 4),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = card,
	})
	vp.ZIndex = 1
	UIKit.Label({
		Text = petName(entry.Id, entry.Tier),
		TextSize = 14,
		TextScaled = true,
		TextColor3 = Config.PetTier(entry.Tier).Color or Colors.Text,
		Size = UDim2.new(1, -8, 0, 30),
		Position = UDim2.new(0.5, 0, 0, 78),
		AnchorPoint = Vector2.new(0.5, 0),
		TextWrapped = true,
		Parent = card,
	})
	if onClick then
		local hit = Instance.new("TextButton")
		hit.BackgroundTransparency = 1
		hit.Text = ""
		hit.Size = UDim2.fromScale(1, 1)
		hit.ZIndex = 5
		hit.Parent = card
		hit.MouseButton1Click:Connect(onClick)
	end
	return card
end

local function grid(parent: Instance, size: UDim2, position: UDim2): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.Size = size
	s.Position = position
	s.ScrollBarThickness = 6
	s.CanvasSize = UDim2.new()
	s.AutomaticCanvasSize = Enum.AutomaticSize.Y
	s.Parent = parent
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(CELL.X, CELL.Y)
	layout.CellPadding = UDim2.fromOffset(8, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = s
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 4)
	pad.Parent = s
	return s
end

-- A small grey heading. position / size are UDim2s so the two halves follow the window's width.
local function heading(text: string, position: UDim2, size: UDim2)
	UIKit.Label({
		Text = text,
		TextSize = 18,
		TextScaled = true,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = position,
		Size = size,
		Parent = body,
	})
end

-- One side's offer: a dark panel holding the pet tiles, with a centred hint while it's empty
-- (the hint sits on the panel, not in the tile grid, so it's never cut to one tile's width).
local function offerPanel(position: UDim2, hint: string, empty: boolean): ScrollingFrame
	local panel = UIKit.Card({
		Size = UDim2.new(0.5, -8, 0, CELL.Y + 20),
		Position = position,
		Color = Colors.PanelDark,
		Parent = body,
	})
	local tiles = grid(panel, UDim2.new(1, -8, 1, -4), UDim2.fromOffset(4, 2))
	if empty then
		UIKit.Label({
			Text = hint,
			TextSize = 20,
			TextScaled = true,
			TextWrapped = true,
			TextColor3 = Colors.TextDim,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -24, 0, 48),
			Parent = panel,
		})
	end
	return tiles
end

----------------------------------------------------------------------------------------------------
-- Pages
----------------------------------------------------------------------------------------------------

-- The button on a player's row: Request / Requested (+ Cancel) / Wait m:ss.
local function paintPickerRow(row: { Button: TextButton, Cancel: TextButton, UserId: number })
	local info = outgoing[tostring(row.UserId)]
	local now = Workspace:GetServerTimeNow()
	local pending = info and info.PendingUntil and info.PendingUntil > now
	local wait = info and info.WaitUntil and info.WaitUntil > now and info.WaitUntil - now
	row.Cancel.Visible = pending == true
	if pending then
		row.Button.Text = "Requested..."
		UIKit.SetButtonColor(row.Button, Colors.Disabled)
	elseif wait then
		local left = math.ceil(wait :: number)
		row.Button.Text = string.format("Wait %d:%02d", left // 60, left % 60)
		UIKit.SetButtonColor(row.Button, Colors.Disabled)
	else
		row.Button.Text = "Request"
		UIKit.SetButtonColor(row.Button, Colors.Good)
	end
end

local function drawPicker()
	clear(body)
	table.clear(pickerRows)
	UIKit.Label({
		Text = "Click someone to request to trade with them",
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = body,
	})
	local list = Instance.new("ScrollingFrame")
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Size = UDim2.new(1, 0, 1, -40)
	list.Position = UDim2.fromOffset(0, 40)
	list.ScrollBarThickness = 6
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = body
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local count = 0
	for i, plr in Players:GetPlayers() do
		-- Invisible admins aren't there as far as everyone else is concerned.
		if plr == LocalPlayer or plr:GetAttribute("AdminInvis") == true then
			continue
		end
		count += 1
		local card = UIKit.Card({ Size = UDim2.new(1, -12, 0, 60), Color = Colors.PanelLight, Parent = list })
		card.LayoutOrder = i
		UIKit.Label({
			Text = plr.DisplayName .. "  @" .. plr.Name,
			TextSize = 20,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(1, -330, 1, 0),
			Parent = card,
		})
		local userId = plr.UserId
		local button = UIKit.Button({
			Text = "Request",
			Color = Colors.Good,
			TextSize = 18,
			Size = UDim2.fromOffset(160, 44),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Parent = card,
			OnClick = function()
				send("Request", userId)
			end,
		})
		local cancel = UIKit.Button({
			Text = "Cancel",
			Color = Colors.Bad,
			TextSize = 18,
			Size = UDim2.fromOffset(120, 44),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -178, 0.5, 0),
			Parent = card,
			OnClick = function()
				send("CancelRequest", userId)
			end,
		})
		local row = { Button = button, Cancel = cancel, UserId = userId }
		table.insert(pickerRows, row)
		paintPickerRow(row)
	end
	if count == 0 then
		UIKit.Label({
			Text = "No one else is here to trade with yet.",
			TextSize = 20,
			TextColor3 = Colors.TextDim,
			Size = UDim2.new(1, 0, 0, 60),
			Parent = list,
		})
	end
end

local function drawTrade()
	clear(body)
	local s = state
	UIKit.Label({
		Text = "Trading with " .. tostring(s.Partner.Name),
		TextSize = 22,
		Size = UDim2.new(1, 0, 0, 28),
		Parent = body,
	})

	heading(string.format("YOUR OFFER  (%d/%d)%s", #s.Mine, s.MaxOffer, if s.MyReady then "  ✅ READY" else ""), UDim2.fromOffset(4, 32), UDim2.new(0.5, -12, 0, 22))
	heading(string.format("%s'S OFFER%s", string.upper(tostring(s.Partner.Name)), if s.TheirReady then "  ✅ READY" else ""), UDim2.new(0.5, 8, 0, 32), UDim2.new(0.5, -12, 0, 22))
	local mine = offerPanel(UDim2.fromOffset(0, 58), "Select pets below to offer them", #s.Mine == 0)
	local theirs = offerPanel(UDim2.new(0.5, 8, 0, 58), "Nothing offered yet", #s.Theirs == 0)
	for i, entry in s.Mine do
		petCell(mine, entry, i, function()
			send("Remove", entry.Uid)
		end)
	end
	for i, entry in s.Theirs do
		petCell(theirs, entry, i)
	end

	heading("YOUR PETS  (tap to offer)", UDim2.fromOffset(4, 200), UDim2.new(1, -200, 0, 22))
	local offered: { [string]: boolean } = {}
	for _, e in s.Mine do
		offered[e.Uid] = true
	end
	local pets = grid(body, UDim2.new(1, -196, 1, -228), UDim2.fromOffset(0, 226))
	local meta = ClientState.Meta
	for i, entry in (meta and meta.Pets or {}) do
		if not offered[entry.Uid] then
			petCell(pets, entry, i, function()
				send("Add", entry.Uid)
			end)
		end
	end

	-- Right column: status, Ready, Cancel.
	local status = "Add pets, then both press Ready."
	if s.ConfirmAt then
		status = "Trading in 3..."
	elseif s.MyReady then
		status = "Waiting for " .. tostring(s.Partner.Name) .. "..."
	elseif s.TheirReady then
		status = tostring(s.Partner.Name) .. " is ready!"
	end
	local statusLabel = UIKit.Label({
		Text = status,
		TextSize = 18,
		TextWrapped = true,
		TextScaled = true,
		TextColor3 = if s.ConfirmAt then Colors.Good else Colors.Text,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 222),
		Size = UDim2.fromOffset(176, 70),
		Parent = body,
	})
	UIKit.Button({
		Text = if s.MyReady then "Not ready" else "Ready",
		Color = if s.MyReady then Colors.Warning else Colors.Good,
		TextSize = 22,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 300),
		Size = UDim2.fromOffset(176, 56),
		Parent = body,
		OnClick = function()
			send("Ready", not s.MyReady)
		end,
	})
	UIKit.Button({
		Text = "Cancel",
		Color = Colors.Bad,
		TextSize = 20,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 366),
		Size = UDim2.fromOffset(176, 48),
		Parent = body,
		OnClick = function()
			send("Cancel")
		end,
	})
	-- The countdown ticks on screen.
	if s.ConfirmAt then
		local at = s.ConfirmAt
		task.spawn(function()
			while state == s and statusLabel.Parent do
				local left = math.ceil(at - Workspace:GetServerTimeNow())
				if left <= 0 then
					statusLabel.Text = "Trading!"
					break
				end
				statusLabel.Text = "Trading in " .. left .. "..."
				task.wait(0.2)
			end
		end)
	end
end

local function redraw()
	if not body then
		return
	end
	if state then
		drawTrade()
	else
		drawPicker()
	end
end

----------------------------------------------------------------------------------------------------
-- Invites
----------------------------------------------------------------------------------------------------

local inviteRoot: Frame

local function showInvite(from: { UserId: number, Name: string })
	local card = UIKit.Card({
		Size = UDim2.fromOffset(420, 120),
		Color = Colors.Panel,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 90),
		Parent = inviteRoot,
	})
	UIKit.Stroke(card, Colors.Ink, 3)
	UIKit.Label({
		Text = "🤝 " .. tostring(from.Name) .. " wants to trade pets!",
		TextSize = 20,
		TextScaled = true,
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -24, 0, 34),
		Parent = card,
	})
	local old = inviteCards[from.UserId]
	if old and old.Parent then
		old:Destroy()
	end
	inviteCards[from.UserId] = card
	local function close()
		if card.Parent then
			card:Destroy()
		end
		if inviteCards[from.UserId] == card then
			inviteCards[from.UserId] = nil
		end
	end
	UIKit.Button({
		Text = "Accept",
		Color = Colors.Good,
		TextSize = 20,
		Size = UDim2.fromOffset(170, 50),
		Position = UDim2.new(0.5, -178, 1, -60),
		Parent = card,
		OnClick = function()
			send("Accept", from.UserId)
			close()
		end,
	})
	UIKit.Button({
		Text = "Decline",
		Color = Colors.Bad,
		TextSize = 20,
		Size = UDim2.fromOffset(170, 50),
		Position = UDim2.new(0.5, 8, 1, -60),
		Parent = card,
		OnClick = function()
			send("Decline", from.UserId)
			close()
		end,
	})
	task.delay(30, close)
end

----------------------------------------------------------------------------------------------------
-- Init
----------------------------------------------------------------------------------------------------

function TradeUI.Init()
	if initialized then
		return
	end
	initialized = true
	actionRemote = Remotes.Event("TradeAction")

	local _gui, root = UIKit.CreateScreen("TradeUI", 11)
	local _window, windowContent = UIKit.Window({
		Name = "Trade",
		Title = "Trade Pets",
		Icon = "🤝",
		Size = Vector2.new(880, 600),
		Parent = root,
	})
	content = windowContent
	body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Size = UDim2.fromScale(1, 1)
	body.Parent = content

	local _igui, iroot = UIKit.CreateScreen("TradeInvites", 40)
	inviteRoot = iroot

	UIKit.RegisterWindow("Trade", {
		Open = function()
			redraw()
		end,
		Close = function()
			-- Walking away from the trade window ends the trade.
			if state then
				send("Cancel")
			end
		end,
	})

	Remotes.Event("TradeState").OnClientEvent:Connect(function(first, second)
		if first == "Invite" then
			if type(second) == "table" then
				showInvite(second)
			end
			return
		elseif first == "InviteCancelled" then
			local card = type(second) == "table" and inviteCards[tonumber(second.UserId) or 0]
			if card then
				card:Destroy()
				inviteCards[second.UserId] = nil
			end
			return
		elseif first == "Outgoing" then
			outgoing = if type(second) == "table" then second else {}
			for _, row in pickerRows do
				paintPickerRow(row)
			end
			return
		end
		local was = state
		state = first
		if state and not UIKit.IsWindowOpen("Trade") then
			UIKit.OpenWindow("Trade")
		elseif not state and was and UIKit.IsWindowOpen("Trade") then
			UIKit.CloseWindow("Trade")
		end
		redraw()
	end)
	-- Your pets list changes when a trade completes (or you hatch meanwhile).
	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" and state and UIKit.IsWindowOpen("Trade") then
			redraw()
		end
	end)
	-- The Wait m:ss / Requested timers tick down while the picker is open.
	task.spawn(function()
		while true do
			task.wait(1)
			if not state and UIKit.IsWindowOpen("Trade") then
				for _, row in pickerRows do
					if row.Button.Parent then
						paintPickerRow(row)
					end
				end
			end
		end
	end)
	Players.PlayerAdded:Connect(function()
		if not state and UIKit.IsWindowOpen("Trade") then
			redraw()
		end
	end)
	Players.PlayerRemoving:Connect(function()
		if not state and UIKit.IsWindowOpen("Trade") then
			task.defer(redraw)
		end
	end)
end

return TradeUI
