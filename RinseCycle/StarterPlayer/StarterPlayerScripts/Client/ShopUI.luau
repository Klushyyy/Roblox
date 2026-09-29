--[[
	ShopUI - the lobby "Shop" window: Perks (bought with Bubbles, permanent) and Robux (game passes).
	Opened from the Soap Shop ProximityPrompt (routed by Effects via OpenWindow="Shop"), the HUD [🛒 Shop]
	button, or the G key - all outside our scope, they just call UIKit.OpenWindow("Shop").

	Everything here reads ClientState.Meta, which is nil until the profile finishes loading; the window
	shows a "loading" placeholder rather than erroring if it's opened in that window.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Colors = UIKit.Theme.Colors
local LocalPlayer = Players.LocalPlayer

local ShopUI = {}

-- Live Robux prices. With Roblox's regional pricing on, players in some countries pay a different
-- price than the one in Config, so once an item has a real Id the shop asks Roblox for the price
-- this player will actually see and shows that (Config's Price is only the fallback).
local livePrice: { [string]: number } = {}
local priceWaiters: { [string]: { (number) -> () } } = {}
function ShopUI.WatchPrice(def: any, isPass: boolean, apply: (number) -> ())
	apply(def.Price or 0)
	if type(def.Id) ~= "number" or def.Id <= 0 then
		return
	end
	local key = (if isPass then "P" else "D") .. def.Id
	if livePrice[key] then
		apply(livePrice[key])
		return
	end
	local waiting = priceWaiters[key]
	if waiting then
		table.insert(waiting, apply)
		return
	end
	priceWaiters[key] = { apply }
	task.spawn(function()
		local ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(def.Id, if isPass then Enum.InfoType.GamePass else Enum.InfoType.Product)
		end)
		local price = if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then info.PriceInRobux else nil
		local list = priceWaiters[key] or {}
		priceWaiters[key] = nil
		if price then
			livePrice[key] = price
			for _, fn in list do
				pcall(fn, price)
			end
		end
	end)
end

local WINDOW_SIZE = Vector2.new(880, 560)

local initialized = false
type Tab = "Perks" | "Passes" | "Bubbles" | "Gems" | "Coins"
local activeTab: Tab = "Perks"
local TABS: { { Key: Tab, Text: string, Color: Color3 } } = {
	{ Key = "Perks", Text = "Perks", Color = Colors.Bubble },
	{ Key = "Passes", Text = "Passes", Color = Colors.Good },
	{ Key = "Bubbles", Text = "Bubbles", Color = Colors.Primary },
	{ Key = "Gems", Text = "Gems", Color = Colors.Accent },
	{ Key = "Coins", Text = "Coins", Color = Colors.Coin },
}
local tabButtons: { [string]: TextButton } = {}

local content: Frame
local tabsRow: Frame
local list: ScrollingFrame

----------------------------------------------------------------------------------------------------
-- Perks tab
----------------------------------------------------------------------------------------------------

local function buildPerkRow(def: any): Frame
	local meta = ClientState.Meta
	local level = (meta and meta.Perks[def.Id]) or 0
	local bubbles = (meta and meta.Bubbles) or 0

	local row = UIKit.Card({ Size = UDim2.new(1, 0, 0, 84), Name = def.Id })

	UIKit.Label({
		Text = def.Icon,
		TextSize = 32,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(44, 44),
		Parent = row,
	})

	local textCol = Instance.new("Frame")
	textCol.BackgroundTransparency = 1
	textCol.AnchorPoint = Vector2.new(0, 0.5)
	textCol.Position = UDim2.new(0, 66, 0.5, 0)
	textCol.Size = UDim2.new(1, -66 - 150, 1, -12)
	textCol.Parent = row
	UIKit.Label({
		Text = def.Name .. "   Lv " .. level .. "/" .. def.Max,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 22),
		Parent = textCol,
	})
	UIKit.Label({
		Text = def.Desc,
		TextSize = 13,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 0, 40),
		Parent = textCol,
	})

	local cost = Config.PerkCost(def.Id, level)
	if not cost then
		UIKit.Button({
			Text = "MAX",
			Size = UDim2.fromOffset(130, 46),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Color = Colors.Disabled,
			Disabled = true,
			Sound = false,
			Parent = row,
		})
	else
		UIKit.Button({
			Text = UIKit.Short(cost) .. " Bubbles",
			Size = UDim2.fromOffset(130, 46),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Color = Colors.Bubble,
			Disabled = not meta or bubbles < cost,
			Parent = row,
			OnClick = function()
				local result = ClientState.MetaRequest("BuyPerk", def.Id)
				if result.Ok then
					UIKit.Bounce(row)
					UIKit.PlaySound("Coins")
				else
					UIKit.Toast(result.Error or "Couldn't buy that.", "Bad")
					UIKit.PlaySound("Error")
				end
			end,
		})
	end

	return row
end

----------------------------------------------------------------------------------------------------
-- Robux tab
----------------------------------------------------------------------------------------------------

-- Buying a pass for yourself: Roblox's prompt (MarketService grants it), or a free Studio test.
local function buyPassForSelf(def: any)
	if type(def.Id) == "number" and def.Id ~= 0 then
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(LocalPlayer, def.Id)
		end)
		return
	end
	-- No Id yet: test mode (Studio only by default). See Config.GamePasses.
	local result = ClientState.MetaRequest("TestPass", def.Key)
	if not result.Ok then
		UIKit.Toast(result.Error or "Coming soon!", "Info")
	end
end

local function openPassBuy(def: any, giftOnly: boolean?)
	UIKit.OpenWindow("PassBuy", { Def = def, GiftOnly = giftOnly == true })
end

local function buildPassRow(def: any): Frame
	local meta = ClientState.Meta
	local owned = meta ~= nil and meta.Passes[def.Key] == true

	local row = UIKit.Card({ Size = UDim2.new(1, 0, 0, 84), Name = def.Key })

	UIKit.Label({
		Text = def.Icon,
		TextSize = 32,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(44, 44),
		Parent = row,
	})

	local textCol = Instance.new("Frame")
	textCol.BackgroundTransparency = 1
	textCol.AnchorPoint = Vector2.new(0, 0.5)
	textCol.Position = UDim2.new(0, 66, 0.5, 0)
	textCol.Size = UDim2.new(1, -66 - 150, 1, -12)
	textCol.Parent = row
	UIKit.Label({
		Text = def.Name,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 22),
		Parent = textCol,
	})
	UIKit.Label({
		Text = def.Desc,
		TextSize = 13,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 0, 40),
		Parent = textCol,
	})

	if owned then
		-- You have it: you can still gift it to someone.
		UIKit.Label({
			Text = "Owned",
			TextSize = 14,
			TextColor3 = Colors.Good,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -14, 0, 4),
			Size = UDim2.fromOffset(130, 18),
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = row,
		})
		UIKit.Button({
			Text = "🎁 Gift",
			Size = UDim2.fromOffset(130, 42),
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -14, 1, -6),
			Color = Colors.Primary,
			Parent = row,
			OnClick = function()
				openPassBuy(def, true)
			end,
		})
	else
		local buyButton = UIKit.Button({
			Text = "R$ " .. tostring(def.Price or "?"),
			Size = UDim2.fromOffset(130, 46),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Color = Colors.Good,
			Parent = row,
			OnClick = function()
				-- For yourself, or as a gift? (PassBuy window)
				openPassBuy(def)
			end,
		})
		ShopUI.WatchPrice(def, true, function(price)
			if buyButton.Parent then
				buyButton.Text = "R$ " .. price
			end
		end)
	end

	return row
end

----------------------------------------------------------------------------------------------------
-- Developer products (Bubbles / Gems / Coins packs)
----------------------------------------------------------------------------------------------------

-- Buy helpers other windows use too (Ranks' x2 Luck button, the "not enough coins" offer).
function ShopUI.BuyPass(key: string)
	local def = Config.GetPass(key)
	if not def then
		return
	end
	if type(def.Id) == "number" and def.Id ~= 0 then
		pcall(function()
			MarketplaceService:PromptGamePassPurchase(LocalPlayer, def.Id)
		end)
		return
	end
	-- No Id pasted yet: in Studio this gives the pass free for the test (never in the live game).
	local result = ClientState.MetaRequest("TestPass", def.Key)
	if result.Ok then
		UIKit.Toast(string.format("Studio test: the %s pass has no ID yet, so you got it free. In the live game this is the Robux prompt.", def.Name), "Info")
	else
		UIKit.Toast(result.Error or "Coming soon!", "Info")
	end
end

-- "I want this tool": buy it with coins if you can afford it, otherwise offer its tool pass
-- (Config.Tools[i].PassKey), which gives it in every run. Returns the RunRequest result, or nil
-- when a pass was offered instead.
local offering = false
function ShopUI.GetTool(index: number): Types.RequestResult?
	local run = ClientState.Run
	local tool = Config.Tools[index]
	if not run or not tool or offering then
		return nil
	end
	local cost = Config.ToolCost(index, run.Level) or 0
	if run.Coins < cost and tool.PassKey then
		local pass = Config.GetPass(tool.PassKey)
		if pass and not (ClientState.Meta and ClientState.Meta.Passes[tool.PassKey]) then
			UIKit.Toast(string.format("Need %s more coins for the %s - or get it forever!", UIKit.Commas(cost - run.Coins), tool.Name), "Info")
			ShopUI.BuyPass(tool.PassKey)
			return nil
		end
	end
	offering = true
	local result = ClientState.RunRequest("BuyTool", index)
	offering = false
	return result
end

-- Returns true if the purchase went through right away (test mode); a real prompt returns false
-- (MarketService grants the goods when Roblox confirms it).
function ShopUI.BuyProduct(key: string): boolean
	local def = Config.GetProduct(key)
	if not def then
		return false
	end
	if type(def.Id) == "number" and def.Id ~= 0 then
		pcall(function()
			MarketplaceService:PromptProductPurchase(LocalPlayer, def.Id)
		end)
		return false
	end
	local result = ClientState.MetaRequest("TestProduct", def.Key)
	if not result.Ok then
		UIKit.Toast(result.Error or "Coming soon!", "Info")
		return false
	end
	UIKit.Confetti(50)
	return true
end

local function buildProductRow(def: any): Frame
	local run = ClientState.Run
	local row = UIKit.Card({ Size = UDim2.new(1, 0, 0, 84), Name = def.Key })
	UIKit.Label({
		Text = def.Icon,
		TextSize = 32,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(44, 44),
		Parent = row,
	})
	local amount = def.Amount
	local unit = if def.Kind == "Gems" then "💎" elseif def.Kind == "Coins" then "💰" else "🧼"
	local note = ""
	if def.Kind == "Coins" then
		if run then
			amount = math.floor(def.Amount * Config.GetLevel(run.Level).Mult + 0.5)
			note = "  (added to this run)"
		else
			note = "  (buy inside a dishwasher)"
		end
	end
	UIKit.Label({
		Text = def.Name,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(66, 10),
		Size = UDim2.new(1, -226, 0, 22),
		Parent = row,
	})
	UIKit.Label({
		Text = string.format("+%s %s%s", UIKit.Commas(amount), unit, note),
		TextSize = 20,
		TextColor3 = if def.Kind == "Gems" then Color3.fromRGB(220, 180, 255) elseif def.Kind == "Coins" then Colors.Coin else Colors.Bubble,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(66, 40),
		Size = UDim2.new(1, -226, 0, 26),
		Parent = row,
	})
	local buyButton = UIKit.Button({
		Text = "R$ " .. tostring(def.Price),
		Size = UDim2.fromOffset(130, 46),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Color = Colors.Good,
		Disabled = def.Kind == "Coins" and not run,
		Parent = row,
		OnClick = function()
			if type(def.Id) == "number" and def.Id ~= 0 then
				pcall(function()
					MarketplaceService:PromptProductPurchase(LocalPlayer, def.Id)
				end)
				return
			end
			-- No Id yet: test mode (Studio only by default). See Config.DevProducts.
			local result = ClientState.MetaRequest("TestProduct", def.Key)
			if result.Ok then
				UIKit.Confetti(50)
				UIKit.Toast(string.format("+%s %s!", UIKit.Commas(amount), unit), "Good")
				UIKit.Bounce(row)
			else
				UIKit.Toast(result.Error or "Coming soon!", "Info")
			end
		end,
	})
	ShopUI.WatchPrice(def, false, function(price)
		if buyButton.Parent then
			buyButton.Text = "R$ " .. price
		end
	end)
	return row
end

----------------------------------------------------------------------------------------------------
-- Render
----------------------------------------------------------------------------------------------------

local function render()
	for _, tab in TABS do
		local button = tabButtons[tab.Key]
		if button then
			UIKit.SetButtonColor(button, if activeTab == tab.Key then tab.Color else Colors.PanelLight)
		end
	end

	list:ClearAllChildren()
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	if not ClientState.Meta then
		UIKit.Label({
			Text = "Loading your profile...",
			TextSize = 20,
			TextColor3 = Colors.TextDim,
			Size = UDim2.new(1, 0, 0, 40),
			Parent = list,
		})
		return
	end

	if activeTab == "Perks" then
		for _, def in Config.Perks do
			buildPerkRow(def).Parent = list
		end
	elseif activeTab ~= "Passes" then
		for i, def in Config.DevProducts or {} do
			if def.Kind == activeTab then
				local row = buildProductRow(def)
				row.LayoutOrder = i
				row.Parent = list
			end
		end
	else
		local shown = 0
		for i, def in Config.GamePasses do
			local row = buildPassRow(def)
			row.LayoutOrder = i
			row.Parent = list
			shown += 1
		end
		if shown == 0 then
			UIKit.Label({
				Text = "More coming soon!",
				TextSize = 22,
				TextColor3 = Colors.TextDim,
				TextXAlignment = Enum.TextXAlignment.Center,
				Size = UDim2.new(1, 0, 0, 60),
				Parent = list,
			})
		end
	end
end

local function setTab(tab: Tab)
	if activeTab == tab then
		return
	end
	activeTab = tab
	render()
end

function ShopUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, screenRoot = UIKit.CreateScreen("ShopUI", 10)

	local _window, windowContent = UIKit.Window({
		Name = "Shop",
		Title = "Shop",
		Icon = "🛒",
		Size = WINDOW_SIZE,
		Parent = screenRoot,
	})
	content = windowContent

	------------------------------------------------------------------ Buy for yourself, or gift it
	local _passWindow, passContent = UIKit.Window({
		Name = "PassBuy",
		Title = "Get a Pass",
		Icon = "🎁",
		Size = Vector2.new(560, 470),
		Parent = screenRoot,
	})
	local passBody = Instance.new("Frame")
	passBody.BackgroundTransparency = 1
	passBody.Size = UDim2.fromScale(1, 1)
	passBody.Parent = passContent
	local function clearBody()
		for _, child in passBody:GetChildren() do
			child:Destroy()
		end
	end
	local function header(def: any)
		UIKit.Label({ Text = def.Icon .. "  " .. def.Name, TextSize = 28, Size = UDim2.new(1, 0, 0, 40), Parent = passBody })
	end
	local function giftTo(def: any, target: Player)
		local ok, result = pcall(function()
			return Remotes.Function("GiftRequest"):InvokeServer(def.Key, target.UserId)
		end)
		if not ok or type(result) ~= "table" then
			UIKit.Toast("Couldn't start the gift. Try again!", "Bad")
			return
		end
		if not result.Ok then
			UIKit.Toast(result.Error or "Couldn't gift that.", "Bad")
			return
		end
		UIKit.CloseWindow("PassBuy")
		if type(result.ProductId) == "number" then
			pcall(function()
				MarketplaceService:PromptProductPurchase(LocalPlayer, result.ProductId)
			end)
		end
	end
	local function drawPicker(def: any)
		clearBody()
		header(def)
		UIKit.Label({ Text = "Who do you want to gift it to?", TextSize = 20, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(0, 44), Size = UDim2.new(1, 0, 0, 26), Parent = passBody })
		local list = Instance.new("ScrollingFrame")
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.Position = UDim2.fromOffset(0, 80)
		list.Size = UDim2.new(1, 0, 1, -80)
		list.ScrollBarThickness = 6
		list.CanvasSize = UDim2.new()
		list.AutomaticCanvasSize = Enum.AutomaticSize.Y
		list.Parent = passBody
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
			local r = UIKit.Card({ Size = UDim2.new(1, -12, 0, 58), Color = Colors.PanelLight, Parent = list })
			r.LayoutOrder = i
			UIKit.Label({ Text = plr.DisplayName .. "  @" .. plr.Name, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(14, 0), Size = UDim2.new(1, -160, 1, 0), Parent = r })
			UIKit.Button({
				Text = "🎁 Gift",
				Color = Colors.Good,
				TextSize = 18,
				Size = UDim2.fromOffset(130, 44),
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -8, 0.5, 0),
				Parent = r,
				OnClick = function()
					giftTo(def, plr)
				end,
			})
		end
		if count == 0 then
			UIKit.Label({ Text = "Nobody else is in this server yet.", TextSize = 18, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 50), Parent = list })
		end
	end
	local function drawChoice(def: any)
		clearBody()
		header(def)
		UIKit.Label({ Text = tostring(def.Desc or ""), TextSize = 18, TextColor3 = Colors.TextDim, TextWrapped = true, Position = UDim2.fromOffset(10, 46), Size = UDim2.new(1, -20, 0, 60), Parent = passBody })
		local selfButton = UIKit.Button({
			Text = "Buy for myself  (R$ " .. tostring(def.Price or "?") .. ")",
			Color = Colors.Good,
			TextSize = 22,
			Size = UDim2.new(1, -40, 0, 70),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 124),
			Parent = passBody,
			OnClick = function()
				UIKit.CloseWindow("PassBuy")
				buyPassForSelf(def)
			end,
		})
		ShopUI.WatchPrice(def, true, function(price)
			if selfButton.Parent then
				selfButton.Text = "Buy for myself  (R$ " .. price .. ")"
			end
		end)
		UIKit.Button({
			Text = "🎁 Gift it to a friend",
			Color = Colors.Primary,
			TextSize = 22,
			Size = UDim2.new(1, -40, 0, 70),
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 210),
			Parent = passBody,
			OnClick = function()
				drawPicker(def)
			end,
		})
	end
	UIKit.RegisterWindow("PassBuy", {
		Open = function(arg)
			local def = type(arg) == "table" and arg.Def
			if not def then
				return
			end
			if arg.GiftOnly or not Config.GetGiftProduct(def.Key) then
				if arg.GiftOnly then
					drawPicker(def)
				else
					UIKit.CloseWindow("PassBuy")
					buyPassForSelf(def)
				end
			else
				drawChoice(def)
			end
		end,
	})

	tabsRow = Instance.new("Frame")
	tabsRow.Name = "Tabs"
	tabsRow.Size = UDim2.new(1, 0, 0, 44)
	tabsRow.BackgroundTransparency = 1
	tabsRow.Parent = content
	local tabsLayout = Instance.new("UIListLayout")
	tabsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabsLayout.FillDirection = Enum.FillDirection.Horizontal
	tabsLayout.Padding = UDim.new(0, 10)
	tabsLayout.Parent = tabsRow

	for i, tab in TABS do
		tabButtons[tab.Key] = UIKit.Button({
			Text = tab.Text,
			Size = UDim2.fromOffset(146, 44),
			CornerRadius = 10,
			TextSize = 20,
			LayoutOrder = i,
			Parent = tabsRow,
			OnClick = function()
				setTab(tab.Key)
			end,
		})
	end

	list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.fromOffset(0, 54)
	list.Size = UDim2.new(1, 0, 1, -54)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 8
	list.ScrollBarImageColor3 = Colors.Primary
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = content

	-- The Shop opens on the tab that's most useful where you are: Coins in a run, Perks outside.
	UIKit.RegisterWindow("Shop", {
		Open = function(arg)
			if type(arg) == "string" then
				activeTab = arg :: Tab
			elseif ClientState.Run then
				activeTab = "Coins"
			end
			render()
		end,
	})
	ClientState.Changed:Connect(function(kind)
		if kind == "Run" and UIKit.IsWindowOpen("Shop") then
			render()
		end
	end)

	-- Celebrate a purchase the moment it happens, never just because a pass you already own showed
	-- up (ownership is re-checked on every join and server hop). MarketService sends the message.
	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, _passId, purchased)
		if player == LocalPlayer and purchased then
			UIKit.Confetti()
		end
	end)
	MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, _productId, purchased)
		if userId == LocalPlayer.UserId and purchased then
			UIKit.Confetti(50)
		end
	end)
	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" and UIKit.IsWindowOpen("Shop") then
			render()
		end
	end)
end

return ShopUI
