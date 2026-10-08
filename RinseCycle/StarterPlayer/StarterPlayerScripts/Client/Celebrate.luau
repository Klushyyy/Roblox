--[[
	Celebrate - the big "congrats" popup with confetti: a gift you sent or got (game passes, a rank
	from an admin). The server sends ("Celebrate", title, text, icon); popups that arrive together
	are shown one after another.
]]

local Players = game:GetService("Players")
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
local iconArt: Frame? = nil

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
	-- "@Gift" etc. are the game's drawn icons (IconArt); anything else is an emoji.
	if iconArt then
		iconArt:Destroy()
		iconArt = nil
	end
	local kind = string.match(item.Icon, "^@(%a+)$")
	if kind then
		iconLabel.Text = ""
		local art = UIKit.Icon(kind, 64)
		art.AnchorPoint = Vector2.new(0.5, 0.5)
		art.Position = UDim2.fromScale(0.5, 0.5)
		art.Parent = iconLabel
		iconArt = art
	else
		iconLabel.Text = item.Icon
	end
	UIKit.OpenWindow("Celebrate")
	UIKit.Confetti()
end

-- During the Admin Abuse show prizes use a small card (the same look as the vote card) instead of the big
-- window, one at a time, so they never pile up on top of the vote, the power-up pick and the speech box.
local prizeQueue: { { Title: string, Text: string, Icon: string } } = {}
local prizeBusy = false
local prizeHolder: Frame? = nil
local prizeTitle: TextLabel
local prizeText: TextLabel
local prizeIconHolder: Frame

local function showPrize()
	local item = table.remove(prizeQueue, 1)
	local holder = prizeHolder
	if not item or not holder then
		prizeBusy = false
		return
	end
	prizeBusy = true
	-- "You won!" on top of "You won ..." is said twice: for those the card is just the message, big
	local plain = string.find(item.Title, "^You won") ~= nil or string.find(item.Title, "^You got") ~= nil
	prizeTitle.Text = item.Title
	prizeTitle.Visible = not plain
	prizeText.Text = item.Text
	prizeText.Position = if plain then UDim2.fromOffset(90, 12) else UDim2.fromOffset(90, 42)
	prizeText.Size = if plain then UDim2.new(1, -104, 1, -30) else UDim2.new(1, -104, 0, 44)
	prizeText.TextYAlignment = if plain then Enum.TextYAlignment.Center else Enum.TextYAlignment.Top
	for _, c in prizeIconHolder:GetChildren() do
		c:Destroy()
	end
	local kind = string.match(item.Icon, "^@(%a+)$")
	if kind then
		local art = UIKit.Icon(kind, 56)
		art.AnchorPoint = Vector2.new(0.5, 0.5)
		art.Position = UDim2.fromScale(0.5, 0.5)
		art.Parent = prizeIconHolder
	else
		UIKit.Label({ Text = item.Icon, TextSize = 44, Stroke = false, Size = UDim2.fromScale(1, 1), Parent = prizeIconHolder })
	end
	holder.Visible = true
	UIKit.Bounce(holder)
	UIKit.PlaySound("Sparkle")
	UIKit.Confetti(40)
	-- it sits where the vote / power-up cards sit, and stacks above them while one of those is up
	task.spawn(function()
		while holder.Visible do
			local gui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
			local pollUp = false
			if gui then
				local poll = gui:FindFirstChild("PollHolder", true)
				local pick = gui:FindFirstChild("PickHolder", true)
				pollUp = (poll ~= nil and poll:IsA("GuiObject") and poll.Visible) or (pick ~= nil and pick:IsA("GuiObject") and pick.Visible)
			end
			holder.Position = UDim2.new(0.5, 0, 1, if pollUp then -340 else -110)
			task.wait(0.15)
		end
	end)
	task.delay(4.2, function()
		holder.Visible = false
		task.delay(0.25, showPrize)
	end)
end

-- Shows a popup now (or after the ones already waiting).
function Celebrate.Show(title: string, text: string, icon: string?)
	if ReplicatedStorage:GetAttribute("AbuseLive") == true and prizeHolder then
		table.insert(prizeQueue, { Title = tostring(title), Text = tostring(text), Icon = if icon and icon ~= "" then icon else "🎁" })
		if not prizeBusy then
			showPrize()
		end
		return
	end
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

	-- the small prize card of the show
	local holder = Instance.new("Frame")
	holder.Name = "ShowPrize"
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -110) -- the same spot as the vote and power-up cards
	holder.Size = UDim2.fromOffset(480, 100)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = root
	local card = UIKit.Card({ Name = "Prize", Size = UDim2.new(1, -8, 1, -6), Position = UDim2.fromOffset(4, 3), Color = Colors.PanelDark, Parent = holder })
	UIKit.Stroke(card, Colors.Primary, 3, 0)
	prizeIconHolder = Instance.new("Frame")
	prizeIconHolder.BackgroundTransparency = 1
	prizeIconHolder.Position = UDim2.fromOffset(12, 12)
	prizeIconHolder.Size = UDim2.fromOffset(64, 64)
	prizeIconHolder.Parent = card
	prizeTitle = UIKit.Label({ Text = "", Font = UIKit.Theme.Fonts.Title, TextSize = 22, TextScaled = true, TextColor3 = Colors.Warning, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(90, 10), Size = UDim2.new(1, -104, 0, 28), Parent = card })
	prizeText = UIKit.Label({ Text = "", Font = UIKit.Theme.Fonts.Title, TextSize = 18, TextScaled = true, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(90, 42), Size = UDim2.new(1, -104, 0, 44), Parent = card })
	prizeHolder = holder

	Remotes.Event("Celebrate").OnClientEvent:Connect(function(title, text, icon)
		Celebrate.Show(title, text, icon)
	end)
end

return Celebrate
