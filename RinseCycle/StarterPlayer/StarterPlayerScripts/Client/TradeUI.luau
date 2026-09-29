--[[
	TradeUI - pet trading (lobby only; TradeService on the server checks everything).

	  * The 🤝 Trade button (HUD) opens the Trade window: pick someone in the server and send a
	    request.
	  * A request you receive pops up at the top of the screen with Accept / Decline.
	  * During a trade the window shows both offers, and your pets below: tap a pet to offer it,
	    tap it in your offer to take it back. Both press Ready; after a short countdown the pets
	    swap. Any change un-readies both sides. Closing the window cancels the trade.
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

local function heading(text: string, x: number, y: number, w: number)
	UIKit.Label({
		Text = text,
		TextSize = 18,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(x, y),
		Size = UDim2.new(0, w, 0, 24),
		Parent = body,
	})
end

----------------------------------------------------------------------------------------------------
-- Pages
----------------------------------------------------------------------------------------------------

local function drawPicker()
	clear(body)
	UIKit.Label({
		Text = "Pick someone to trade pets with",
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
		if plr == LocalPlayer then
			continue
		end
		count += 1
		local row = UIKit.Card({ Size = UDim2.new(1, -12, 0, 60), Color = Colors.PanelLight, Parent = list })
		row.LayoutOrder = i
		UIKit.Label({
			Text = plr.DisplayName .. "  @" .. plr.Name,
			TextSize = 20,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(1, -200, 1, 0),
			Parent = row,
		})
		UIKit.Button({
			Text = "Send request",
			Color = Colors.Good,
			TextSize = 18,
			Size = UDim2.fromOffset(170, 44),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -10, 0.5, 0),
			Parent = row,
			OnClick = function()
				send("Request", plr.UserId)
			end,
		})
	end
	if count == 0 then
		UIKit.Label({
			Text = "Nobody else is in this server yet.",
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

	local half = 410
	heading(string.format("YOUR OFFER  (%d/%d)%s", #s.Mine, s.MaxOffer, if s.MyReady then "  ✅ READY" else ""), 0, 32, half)
	heading(string.format("%s'S OFFER%s", string.upper(tostring(s.Partner.Name)), if s.TheirReady then "  ✅ READY" else ""), half + 20, 32, half)
	local mine = grid(body, UDim2.fromOffset(half, CELL.Y + 16), UDim2.fromOffset(0, 58))
	local theirs = grid(body, UDim2.fromOffset(half, CELL.Y + 16), UDim2.fromOffset(half + 20, 58))
	for i, entry in s.Mine do
		petCell(mine, entry, i, function()
			send("Remove", entry.Uid)
		end)
	end
	for i, entry in s.Theirs do
		petCell(theirs, entry, i)
	end
	if #s.Mine == 0 then
		UIKit.Label({ Text = "Tap your pets below to offer them.", TextSize = 16, TextColor3 = Colors.TextDim, Size = UDim2.fromOffset(half - 12, 40), Parent = mine })
	end
	if #s.Theirs == 0 then
		UIKit.Label({ Text = "Nothing offered yet.", TextSize = 16, TextColor3 = Colors.TextDim, Size = UDim2.fromOffset(half - 12, 40), Parent = theirs })
	end

	heading("YOUR PETS  (tap to offer)", 0, 196, 400)
	local offered: { [string]: boolean } = {}
	for _, e in s.Mine do
		offered[e.Uid] = true
	end
	local pets = grid(body, UDim2.new(1, -190, 1, -226), UDim2.fromOffset(0, 222))
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
		status = "Both ready! Swapping..."
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
					statusLabel.Text = "Swapping..."
					break
				end
				statusLabel.Text = "Both ready! Swapping in " .. left .. "..."
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
	local function close()
		if card.Parent then
			card:Destroy()
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
