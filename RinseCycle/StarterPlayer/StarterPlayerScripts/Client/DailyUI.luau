--[[
	DailyUI - the daily reward calendar. The server claims today's reward when you join
	(DataService, Config.DailyRewards); this window pops up once per session to show what you got,
	the streak so far, and what tomorrow brings, so there's always a reason to come back.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Colors = UIKit.Theme.Colors

local DailyUI = {}

local initialized = false
local shown = false
local row: Frame
local footer: TextLabel

local function rewardText(reward): string
	return string.format("%s %s", if reward.Kind == "Gems" then "💎" else "🧼", UIKit.Commas(reward.Amount))
end

local function render()
	local meta = ClientState.Meta :: Types.MetaState?
	local streak = (meta and meta.DailyStreak) or 0
	for _, child in row:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for day, reward in Config.DailyRewards do
		local claimed = day <= streak
		local today = day == streak
		local card = UIKit.Card({
			Size = UDim2.fromOffset(96, 132),
			LayoutOrder = day,
			Color = if today then Colors.Good elseif claimed then Colors.PanelLight else Colors.PanelDark,
			Parent = row,
		})
		if today then
			UIKit.Stroke(card, Color3.fromRGB(255, 230, 120), 3)
		end
		UIKit.Label({ Text = if day == #Config.DailyRewards then "Day 7 🎉" else "Day " .. day, TextSize = 18, Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 8), Parent = card })
		UIKit.Label({ Text = if reward.Kind == "Gems" then "💎" else "🧼", TextSize = 38, Size = UDim2.new(1, 0, 0, 44), Position = UDim2.fromOffset(0, 36), Stroke = false, Parent = card })
		UIKit.Label({ Text = UIKit.Commas(reward.Amount), TextSize = 20, Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 82), Parent = card })
		UIKit.Label({ Text = if claimed then "✅" else "", TextSize = 18, Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 106), Parent = card })
	end
	local nextDay = streak % #Config.DailyRewards + 1
	footer.Text = string.format("Today: %s   •   Tomorrow (Day %d): %s", if streak > 0 then rewardText(Config.DailyRewards[streak]) else "-", nextDay, rewardText(Config.DailyRewards[nextDay]))
end

function DailyUI.Init()
	if initialized then
		return
	end
	initialized = true
	local _gui, screenRoot = UIKit.CreateScreen("DailyUI", 11)
	local _window, content = UIKit.Window({
		Name = "Daily",
		Title = "Daily Reward",
		Icon = "🎁",
		Size = Vector2.new(820, 380),
		Parent = screenRoot,
	})
	row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Size = UDim2.new(1, 0, 0, 140)
	row.Position = UDim2.fromOffset(0, 6)
	row.Parent = content
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = row
	footer = UIKit.Label({ Text = "", TextSize = 20, TextWrapped = true, Size = UDim2.new(1, -20, 0, 32), Position = UDim2.new(0.5, 0, 0, 154), AnchorPoint = Vector2.new(0.5, 0), Parent = content })
	UIKit.Button({
		Text = "Awesome!",
		Size = UDim2.fromOffset(220, 52),
		Position = UDim2.new(0.5, 0, 0, 196),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Good,
		Parent = content,
		OnClick = function()
			UIKit.CloseWindow("Daily")
		end,
	})
	UIKit.RegisterWindow("Daily", {
		Open = function()
			render()
		end,
	})
	-- Pop up once per session, the first time we know today's reward was claimed.
	local function maybeShow()
		local meta = ClientState.Meta :: Types.MetaState?
		if shown or not meta or not Players.LocalPlayer:GetAttribute("DailyJustClaimed") or ClientState.InRun() then
			return
		end
		shown = true
		task.delay(2, function()
			if not UIKit.IsWindowOpen() then
				UIKit.OpenWindow("Daily")
				UIKit.Confetti(40)
			end
		end)
	end
	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" then
			maybeShow()
		end
	end)
	Players.LocalPlayer:GetAttributeChangedSignal("DailyJustClaimed"):Connect(maybeShow)
	maybeShow()
end

return DailyUI
