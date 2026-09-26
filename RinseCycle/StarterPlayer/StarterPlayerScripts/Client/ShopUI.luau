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

local WINDOW_SIZE = Vector2.new(820, 540)

local initialized = false
local activeTab: "Perks" | "Robux" = "Perks"

local content: Frame
local tabsRow: Frame
local list: ScrollingFrame
local perksTabButton: TextButton
local robuxTabButton: TextButton

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
			Text = "🫧 " .. UIKit.Short(cost),
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
			Text = "Buy",
			Size = UDim2.fromOffset(130, 46),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Color = Colors.Primary,
			Parent = row,
			OnClick = function()
				pcall(function()
					MarketplaceService:PromptGamePassPurchase(LocalPlayer, def.Id)
				end)
			end,
		})
	end

	return row
end

----------------------------------------------------------------------------------------------------
-- Render
----------------------------------------------------------------------------------------------------

local function styleTab(button: TextButton, active: boolean)
	UIKit.SetButtonColor(button, if active then Colors.Primary else Colors.PanelLight)
end

local function render()
	styleTab(perksTabButton, activeTab == "Perks")
	styleTab(robuxTabButton, activeTab == "Robux")

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
	else
		local shown = 0
		for _, def in Config.GamePasses do
			if def.Id ~= 0 then
				buildPassRow(def).Parent = list
				shown += 1
			end
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

local function setTab(tab: "Perks" | "Robux")
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
		Title = "Soap Shop",
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

	perksTabButton = UIKit.Button({
		Text = "🫧 Perks",
		Size = UDim2.fromOffset(160, 44),
		CornerRadius = 10,
		Parent = tabsRow,
		OnClick = function()
			setTab("Perks")
		end,
	})
	robuxTabButton = UIKit.Button({
		Text = "💎 Robux",
		Size = UDim2.fromOffset(160, 44),
		CornerRadius = 10,
		Parent = tabsRow,
		OnClick = function()
			setTab("Robux")
		end,
	})

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

	UIKit.RegisterWindow("Shop", {
		Open = function()
			render()
		end,
	})

	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" and UIKit.IsWindowOpen("Shop") then
			render()
		end
	end)
end

return ShopUI
