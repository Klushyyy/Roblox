--[[
	DailyUI - the daily reward calendar (🎁 Daily button on the left; it also pops up by itself once
	per session when a reward is waiting).

	The next reward unlocks 24 hours after you claim one (Config.Daily). The window shows the 7-day
	streak, a CLAIM button (or a live countdown to the next one), and when you've missed a day, a
	"Restore Streak" offer (Config.DevProducts "RestoreStreak") so the streak isn't lost. The server
	does the timing (MetaRequest "ClaimDaily").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))
local ShopUI = require(Client:WaitForChild("ShopUI"))

local Colors = UIKit.Theme.Colors

local DailyUI = {}

local initialized = false
local autoShown = false
local claiming = false
local row: Frame
local footer: TextLabel
local claimButton: TextButton
local restoreButton: TextButton

local function now(): number
	return Workspace:GetServerTimeNow()
end

-- True when a reward is waiting (the HUD shows a "!" on the Daily button).
function DailyUI.Ready(): boolean
	local meta = ClientState.Meta :: Types.MetaState?
	return meta ~= nil and (meta.DailyReadyAt == 0 or now() >= meta.DailyReadyAt)
end

local function rewardText(reward): string
	return string.format("%s %s", if reward.Kind == "Gems" then "💎" else "🧼", UIKit.Commas(reward.Amount))
end

local function clock(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%02d:%02d:%02d", seconds // 3600, (seconds % 3600) // 60, seconds % 60)
end

-- The day the next claim would give.
local function nextDay(meta: Types.MetaState): number
	if meta.DailyBroken or meta.DailyStreak == 0 then
		return 1
	end
	return meta.DailyStreak % #Config.DailyRewards + 1
end

local function render()
	local meta = ClientState.Meta :: Types.MetaState?
	if not meta then
		return
	end
	local ready = DailyUI.Ready()
	local streak = if meta.DailyBroken then 0 else meta.DailyStreak
	local upcoming = nextDay(meta)
	for _, child in row:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for day, reward in Config.DailyRewards do
		-- A finished week starts over once the next reward is ready.
		local claimed = day <= streak and not (ready and upcoming == 1)
		local isNext = day == upcoming
		local card = UIKit.Card({
			Size = UDim2.fromOffset(96, 132),
			LayoutOrder = day,
			Color = if isNext and ready then Colors.Good elseif claimed then Colors.PanelLight else Colors.PanelDark,
			Parent = row,
		})
		if isNext then
			UIKit.Stroke(card, Color3.fromRGB(255, 230, 120), 3)
		end
		UIKit.Label({ Text = if day == #Config.DailyRewards then "Day 7 🎉" else "Day " .. day, TextSize = 18, Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 8), Parent = card })
		UIKit.Label({ Text = if reward.Kind == "Gems" then "💎" else "🧼", TextSize = 38, Size = UDim2.new(1, 0, 0, 44), Position = UDim2.fromOffset(0, 36), Stroke = false, Parent = card })
		UIKit.Label({ Text = UIKit.Commas(reward.Amount), TextSize = 20, Size = UDim2.new(1, 0, 0, 24), Position = UDim2.fromOffset(0, 82), Parent = card })
		UIKit.Label({ Text = if claimed then "✅" else "", TextSize = 18, Size = UDim2.new(1, 0, 0, 20), Position = UDim2.fromOffset(0, 106), Parent = card })
	end
	if ready then
		footer.Text = string.format("Day %d is ready: %s!", upcoming, rewardText(Config.DailyRewards[upcoming]))
		claimButton.Text = "CLAIM!"
		UIKit.SetButtonColor(claimButton, Colors.Good)
	else
		footer.Text = string.format("Next up: Day %d (%s)", upcoming, rewardText(Config.DailyRewards[upcoming]))
		claimButton.Text = "⏳ " .. clock(meta.DailyReadyAt - now())
		UIKit.SetButtonColor(claimButton, Colors.Disabled)
	end
	-- Missed a day with a streak worth saving: offer to restore it.
	restoreButton.Visible = meta.DailyBroken and meta.DailyStreak > 1
	if restoreButton.Visible then
		footer.Text = string.format("You missed a day! Your Day %d streak will restart...", meta.DailyStreak)
	end
end

local function claim()
	if claiming or not DailyUI.Ready() then
		return
	end
	claiming = true
	local result = ClientState.MetaRequest("ClaimDaily")
	claiming = false
	if not result.Ok then
		UIKit.Toast(result.Error or "Not yet!", "Info")
		return
	end
	UIKit.PlaySound("Sparkle")
	UIKit.Confetti(50)
	UIKit.Toast(string.format("🎁 Day %d: %s!", result.Day or 1, result.Message or ""), "Good")
	render()
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
		Size = Vector2.new(820, 400),
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
	claimButton = UIKit.Button({
		Text = "CLAIM!",
		Size = UDim2.fromOffset(240, 56),
		Position = UDim2.new(0.5, 0, 0, 196),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Good,
		TextSize = 26,
		Parent = content,
		OnClick = claim,
	})
	local restore = Config.GetProduct("RestoreStreak")
	restoreButton = UIKit.Button({
		Text = string.format("🔥 Restore Streak  (R$ %d)", restore and restore.Price or 0),
		Size = UDim2.fromOffset(320, 48),
		Position = UDim2.new(0.5, 0, 0, 262),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Warning,
		TextSize = 20,
		Visible = false,
		Parent = content,
		OnClick = function()
			if ShopUI.BuyProduct("RestoreStreak") then
				UIKit.Toast("🔥 Streak restored! Claim your reward.", "Good")
			end
		end,
	})
	UIKit.RegisterWindow("Daily", {
		Open = function()
			render()
		end,
	})
	-- Live countdown while the window is open.
	task.spawn(function()
		while true do
			task.wait(1)
			if UIKit.IsWindowOpen("Daily") then
				render()
			end
		end
	end)
	-- Pops up by itself once per session when a reward is waiting (in the lobby, nothing else open).
	local function maybeShow()
		if autoShown or not DailyUI.Ready() or ClientState.InRun() then
			return
		end
		autoShown = true
		task.delay(2.5, function()
			if not UIKit.IsWindowOpen() and not ClientState.InRun() then
				UIKit.OpenWindow("Daily")
			end
		end)
	end
	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" then
			maybeShow()
			if UIKit.IsWindowOpen("Daily") then
				render()
			end
		end
	end)
	maybeShow()
end

return DailyUI
