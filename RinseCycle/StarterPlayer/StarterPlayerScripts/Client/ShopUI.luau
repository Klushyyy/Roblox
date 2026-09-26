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

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Colors = UIKit.Theme.Colors
local LocalPlayer = Players.LocalPlayer

local ShopUI = {}

local WINDOW_SIZE = Vector2.new(880, 560)

local initialized = false
type Tab = "Perks" | "Passes" | "Bubbles" | "Gems" | "Coins"
local activeTab: Tab = "Perks"
local TABS: { { Key: Tab, Text: string, Color: Color3 } } = {
	{ Key = "Perks", Text = "🧼 Perks", Color = Colors.Bubble },
	{ Key = "Passes", Text = "👑 Passes", Color = Colors.Good },
	{ Key = "Bubbles", Text = "🧼 Bubbles", Color = Colors.Primary },
	{ Key = "Gems", Text = "💎 Gems", Color = Colors.Accent },
	{ Key = "Coins", Text = "💰 Coins", Color = Colors.Coin },
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
			Text = "🧼 " .. UIKit.Short(cost),
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
		UIKit.Label({
			Text = "✅ Owned",
			TextSize = 18,
			TextColor3 = Colors.Good,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Size = UDim2.fromOffset(130, 30),
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = row,
		})
	else
		UIKit.Button({
			Text = "R$ " .. tostring(def.Price or "?"),
			Size = UDim2.fromOffset(130, 46),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Color = Colors.Good,
			Parent = row,
			OnClick = function()
				if type(def.Id) == "number" and def.Id ~= 0 then
					-- A real pass: Roblox's purchase prompt; MarketService grants it when bought.
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
			end,
		})
	end

	return row
end

----------------------------------------------------------------------------------------------------
-- Developer products (Bubbles / Gems / Coins packs)
----------------------------------------------------------------------------------------------------

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
	UIKit.Button({
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

	-- Celebrate a pass the moment it becomes owned (a real purchase or a test grant).
	local ownedBefore: { [string]: boolean }? = nil
	ClientState.Changed:Connect(function(kind)
		if kind ~= "Meta" then
			return
		end
		local meta = ClientState.Meta
		if meta then
			local now = table.clone(meta.Passes or {})
			if ownedBefore then
				for key, owned in now do
					if owned and not ownedBefore[key] then
						local pass = Config.GetPass(key)
						UIKit.Confetti()
						UIKit.Toast(string.format("%s %s unlocked!", pass and pass.Icon or "🎉", pass and pass.Name or key), "Good")
					end
				end
			end
			ownedBefore = now
		end
		if UIKit.IsWindowOpen("Shop") then
			render()
		end
	end)
end

return ShopUI
