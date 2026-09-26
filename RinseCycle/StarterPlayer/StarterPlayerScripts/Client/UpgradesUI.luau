--[[
	UpgradesUI - the in-run "Upgrades" window: the tool ladder (Sponge -> Cannon) across the top, and a
	scrollable list of the five Coins upgrades below (Hold, Hand Size, Scrub Power, Tank Size, Sneakers).

	Only meaningful inside a run, so it closes itself the moment ClientState.Run goes nil (run ended or
	the player left). Everything it shows - levels, costs, the current -> next stat preview - comes
	straight from ClientState.Run (server-authoritative) and Config's pure helpers; there is no local
	state to keep in sync.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Colors = UIKit.Theme.Colors

local UpgradesUI = {}

local WINDOW_SIZE = Vector2.new(900, 560)
local TOOL_CARD_SIZE = Vector2.new(128, 132)

local initialized = false

local content: Frame
local coinsLabel: TextLabel
local toolsRow: Frame
local upgradeList: ScrollingFrame

----------------------------------------------------------------------------------------------------
-- Formatting helpers for the stat preview line.
----------------------------------------------------------------------------------------------------

-- Trims a trailing ".0" so whole numbers read as "16" not "16.0", but keeps one decimal otherwise.
local function fmtNum(n: number): string
	if n ~= n then
		return "0"
	end
	if math.abs(n - math.floor(n + 0.5)) < 0.05 then
		return string.format("%d", math.floor(n + 0.5))
	end
	return string.format("%.1f", n)
end

-- Every stat-affecting upgrade's preview line, current stats -> stats with one more level of it.
-- (Hold is boolean and handled separately - "Click -> Hold" isn't a number.)
local PREVIEW: { [string]: { Label: string, Get: (Types.RunStats) -> number, Suffix: string? } } = {
	HandSize = { Label = "Radius", Get = function(s) return s.Radius end },
	ScrubPower = { Label = "Power", Get = function(s) return s.Power end, Suffix = "/s" },
	TankSize = { Label = "Tank", Get = function(s) return s.TankMax end },
	Sneakers = { Label = "Speed", Get = function(s) return s.WalkSpeed end },
}

-- Recomputes stats as if `upgradeId` had one more level, using the run's real level/tool/perks/passes
-- so the preview matches what the server would actually give. Meta may not have loaded yet; default
-- to no perks/passes/pet bonus rather than erroring (the preview will just be conservative).
local function previewStats(run: Types.RunState, upgradeId: string): (Types.RunStats, Types.RunStats)
	local meta = ClientState.Meta
	local perks = (meta and meta.Perks) or {}
	local passes = (meta and meta.Passes) or {}
	local petBonus = if meta then Config.PetCoinBonus(meta.Pets, meta.Equipped) else 0

	local currentStats = run.Stats
	local nextUpgrades = table.clone(run.Upgrades)
	;(nextUpgrades :: any)[upgradeId] = ((run.Upgrades :: any)[upgradeId] or 0) + 1
	local nextStats = Config.GetRunStats(run.Level, nextUpgrades, run.ToolIndex, perks, passes, petBonus)
	return currentStats, nextStats
end

----------------------------------------------------------------------------------------------------
-- Buying
----------------------------------------------------------------------------------------------------

local function buy(action: string, value: any, onRow: GuiObject)
	local result = ClientState.RunRequest(action, value)
	if result.Ok then
		UIKit.Bounce(onRow)
		UIKit.PlaySound("Coins")
	else
		UIKit.Toast(result.Error or "Couldn't buy that.", "Bad")
		UIKit.PlaySound("Error")
	end
end

----------------------------------------------------------------------------------------------------
-- Tool ladder (top row)
----------------------------------------------------------------------------------------------------

local function buildToolCard(toolIndex: number, run: Types.RunState): Frame
	local tool = Config.Tools[toolIndex]
	local card = UIKit.Card({
		Size = UDim2.fromOffset(TOOL_CARD_SIZE.X, TOOL_CARD_SIZE.Y),
		Color = if toolIndex == run.ToolIndex then Colors.PanelLight else Colors.PanelDark,
		StrokeColor = if toolIndex == run.ToolIndex then Colors.Coin else nil,
	})

	UIKit.Label({
		Text = tool.Icon,
		TextSize = 34,
		Position = UDim2.new(0.5, 0, 0, 8),
		AnchorPoint = Vector2.new(0.5, 0),
		Size = UDim2.fromOffset(48, 40),
		Parent = card,
	})
	UIKit.Label({
		Text = tool.Name,
		TextSize = 15,
		TextScaled = true,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 50),
		Size = UDim2.new(1, -10, 0, 18),
		Parent = card,
	})

	if toolIndex <= run.ToolIndex then
		UIKit.Label({
			Text = if toolIndex == run.ToolIndex then "✅ Equipped" else "✅ Owned",
			TextSize = 14,
			TextColor3 = Colors.Good,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -10),
			Size = UDim2.fromOffset(110, 20),
			Parent = card,
		})
	elseif toolIndex == run.ToolIndex + 1 then
		local cost = Config.ToolCost(toolIndex, run.Level) or 0
		UIKit.Button({
			Text = "🪙 " .. UIKit.Short(cost),
			Size = UDim2.fromOffset(104, 32),
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -8),
			Color = Colors.Coin,
			Disabled = run.Coins < cost,
			Parent = card,
			OnClick = function()
				buy("BuyTool", toolIndex, card)
			end,
		})
	else
		UIKit.Label({
			Text = "🔒",
			TextSize = 20,
			TextColor3 = Colors.Disabled,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -14),
			Size = UDim2.fromOffset(40, 24),
			Parent = card,
		})
	end

	return card
end

----------------------------------------------------------------------------------------------------
-- Upgrade rows (scrolling list)
----------------------------------------------------------------------------------------------------

local function buildUpgradeRow(def: any, run: Types.RunState): Frame
	local level = ((run.Upgrades :: any)[def.Id] :: number?) or 0
	local row = UIKit.Card({ Size = UDim2.new(1, 0, 0, 76), Name = def.Id })

	UIKit.Label({
		Text = def.Icon,
		TextSize = 30,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(40, 40),
		Parent = row,
	})

	local textCol = Instance.new("Frame")
	textCol.Name = "Text"
	textCol.BackgroundTransparency = 1
	textCol.AnchorPoint = Vector2.new(0, 0.5)
	textCol.Position = UDim2.new(0, 62, 0.5, 0)
	textCol.Size = UDim2.new(0, 300, 1, -12)
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
		Size = UDim2.new(1, 0, 0, 34),
		Parent = textCol,
	})

	-- Stat preview (or the one-off "Click -> Hold" line for the Hold upgrade).
	local previewText: string
	if def.Id == "Hold" then
		previewText = if level >= def.Max then "🖱️ Hold to Scrub" else "🖱️ Click -> Hold"
	else
		local spec = PREVIEW[def.Id]
		if spec and level < def.Max then
			local current, upgraded = previewStats(run, def.Id)
			previewText = string.format(
				"%s %s -> %s%s",
				spec.Label,
				fmtNum(spec.Get(current)),
				fmtNum(spec.Get(upgraded)),
				spec.Suffix or ""
			)
		elseif spec then
			previewText = spec.Label .. " " .. fmtNum(spec.Get(run.Stats)) .. (spec.Suffix or "") .. " (max)"
		else
			previewText = ""
		end
	end
	UIKit.Label({
		Text = previewText,
		TextSize = 15,
		TextColor3 = Colors.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 372, 0.5, 0),
		Size = UDim2.new(0, 190, 0, 22),
		Parent = row,
	})

	local cost = Config.UpgradeCost(def.Id, level, run.Level)
	if not cost then
		UIKit.Button({
			Text = "MAX",
			Size = UDim2.fromOffset(120, 44),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Color = Colors.Disabled,
			Disabled = true,
			Sound = false,
			Parent = row,
		})
	else
		UIKit.Button({
			Text = "🪙 " .. UIKit.Short(cost),
			Size = UDim2.fromOffset(120, 44),
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -14, 0.5, 0),
			Color = Colors.Good,
			Disabled = run.Coins < cost,
			Parent = row,
			OnClick = function()
				buy("BuyUpgrade", def.Id, row)
			end,
		})
	end

	return row
end

----------------------------------------------------------------------------------------------------
-- Render
----------------------------------------------------------------------------------------------------

local function render()
	local run = ClientState.Run
	if not run then
		return
	end

	coinsLabel.Text = "🪙 " .. UIKit.Commas(run.Coins)

	toolsRow:ClearAllChildren()
	local toolsLayout = Instance.new("UIListLayout")
	toolsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	toolsLayout.FillDirection = Enum.FillDirection.Horizontal
	toolsLayout.Padding = UDim.new(0, 10)
	toolsLayout.Parent = toolsRow
	for i in Config.Tools do
		buildToolCard(i, run).Parent = toolsRow
	end

	upgradeList:ClearAllChildren()
	local rowsLayout = Instance.new("UIListLayout")
	rowsLayout.Padding = UDim.new(0, 10)
	rowsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	rowsLayout.Parent = upgradeList
	for _, def in Config.Upgrades do
		buildUpgradeRow(def, run).Parent = upgradeList
	end
end

function UpgradesUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, screenRoot = UIKit.CreateScreen("UpgradesUI", 10)

	local _window, windowContent = UIKit.Window({
		Name = "Upgrades",
		Title = "Upgrades",
		Icon = "⬆️",
		Size = WINDOW_SIZE,
		Parent = screenRoot,
	})
	content = windowContent

	coinsLabel = UIKit.Label({
		Text = "🪙 0",
		TextSize = 26,
		TextColor3 = Colors.Coin,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 0),
		Size = UDim2.fromOffset(160, 30),
		Parent = content,
	})

	toolsRow = Instance.new("Frame")
	toolsRow.Name = "Tools"
	toolsRow.Position = UDim2.fromOffset(0, 36)
	toolsRow.Size = UDim2.new(1, 0, 0, TOOL_CARD_SIZE.Y)
	toolsRow.BackgroundTransparency = 1
	toolsRow.Parent = content

	upgradeList = Instance.new("ScrollingFrame")
	upgradeList.Name = "Upgrades"
	upgradeList.Position = UDim2.fromOffset(0, TOOL_CARD_SIZE.Y + 48)
	upgradeList.Size = UDim2.new(1, 0, 1, -(TOOL_CARD_SIZE.Y + 48))
	upgradeList.BackgroundTransparency = 1
	upgradeList.BorderSizePixel = 0
	upgradeList.ScrollBarThickness = 8
	upgradeList.ScrollBarImageColor3 = Colors.Primary
	upgradeList.CanvasSize = UDim2.new(0, 0, 0, 0)
	upgradeList.AutomaticCanvasSize = Enum.AutomaticSize.Y
	upgradeList.Parent = content

	UIKit.RegisterWindow("Upgrades", {
		Open = function()
			if not ClientState.InRun() then
				-- Nothing to show outside a run; close right back up.
				task.defer(UIKit.CloseWindow, "Upgrades")
				return
			end
			render()
		end,
	})

	ClientState.Changed:Connect(function(kind)
		if kind == "Run" then
			if not ClientState.Run then
				if UIKit.IsWindowOpen("Upgrades") then
					UIKit.CloseWindow("Upgrades")
				end
			elseif UIKit.IsWindowOpen("Upgrades") then
				render()
			end
		elseif kind == "Meta" and UIKit.IsWindowOpen("Upgrades") then
			-- Perks/passes can change the stat preview (e.g. a new perk purchased mid-run via Shop
			-- isn't possible today, but Meta also updates on egg/pet actions - harmless to refresh).
			render()
		end
	end)
end

return UpgradesUI
