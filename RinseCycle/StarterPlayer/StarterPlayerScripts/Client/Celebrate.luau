--[[
	Celebrate - the big "congrats" popup with confetti: a gift you sent or got (game passes, a rank
	from an admin). The server sends ("Celebrate", title, text, icon); popups that arrive together
	are shown one after another.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))

local Celebrate = {}

local Colors = UIKit.Theme.Colors

local initialized = false
local queue: { { Title: string, Text: string, Icon: string } } = {}
local showing = false

local titleLabel: TextLabel
local textLabel: TextLabel
local iconLabel: TextLabel

local showNext: () -> ()

showNext = function()
	local item = table.remove(queue, 1)
	if not item then
		showing = false
		return
	end
	showing = true
	titleLabel.Text = item.Title
	textLabel.Text = item.Text
	iconLabel.Text = item.Icon
	UIKit.OpenWindow("Celebrate")
	UIKit.Confetti()
end

-- Shows a popup now (or after the ones already waiting).
function Celebrate.Show(title: string, text: string, icon: string?)
	table.insert(queue, { Title = tostring(title), Text = tostring(text), Icon = if icon and icon ~= "" then icon else "🎁" })
	if not showing then
		showNext()
	end
end

function Celebrate.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, root = UIKit.CreateScreen("Celebrate", 30)
	local _window, content = UIKit.Window({
		Name = "Celebrate",
		Title = "Congrats!",
		Icon = "🎉",
		Size = Vector2.new(480, 330),
		Parent = root,
	})
	iconLabel = UIKit.Label({
		Text = "🎁",
		TextSize = 64,
		Stroke = false,
		Size = UDim2.new(1, 0, 0, 76),
		Parent = content,
	})
	titleLabel = UIKit.Label({
		Text = "",
		TextSize = 30,
		TextColor3 = Colors.Warning,
		TextScaled = true,
		Position = UDim2.fromOffset(0, 78),
		Size = UDim2.new(1, 0, 0, 38),
		Parent = content,
	})
	textLabel = UIKit.Label({
		Text = "",
		TextSize = 20,
		TextWrapped = true,
		TextScaled = true,
		Position = UDim2.fromOffset(10, 120),
		Size = UDim2.new(1, -20, 0, 50),
		Parent = content,
	})
	UIKit.Button({
		Text = "Awesome!",
		Color = Colors.Good,
		TextSize = 24,
		Size = UDim2.fromOffset(220, 52),
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -4),
		Parent = content,
		OnClick = function()
			UIKit.CloseWindow()
		end,
	})
	UIKit.RegisterWindow("Celebrate", {
		Open = function() end,
		Close = function()
			task.delay(0.3, showNext)
		end,
	})

	Remotes.Event("Celebrate").OnClientEvent:Connect(function(title, text, icon)
		Celebrate.Show(title, text, icon)
	end)
end

return Celebrate
