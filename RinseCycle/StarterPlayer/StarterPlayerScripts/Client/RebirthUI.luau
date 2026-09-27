--[[
	RebirthUI - the "Rebirth" window (the Rebirth Fountain in the lobby).

	The endgame loop: once you've cleaned the last dishwasher, trade your Bubbles, unlocked
	dishwashers and perks for a permanent bonus (Config.Rebirth). Shows how many rebirths you have,
	your current bonuses, what the next one gives, the two requirements (with ticks), exactly what
	resets and what you keep, and the REBIRTH button. The server does all the checks (MetaRequest
	"Rebirth").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Colors = UIKit.Theme.Colors

local RebirthUI = {}

local initialized = false
local busy = false

local countLabel: TextLabel
local nowLabel: TextLabel
local nextLabel: TextLabel
local reqLevel: TextLabel
local reqBubbles: TextLabel
local rebirthButton: TextButton

local function pct(x: number): string
	return string.format("%d%%", math.floor(x * 100 + 0.5))
end

local function render()
	local meta = ClientState.Meta :: Types.MetaState?
	local rebirths = (meta and meta.Rebirths) or 0
	local rb = Config.Rebirth
	countLabel.Text = string.format("✨ Rebirth %d", rebirths)
	nowLabel.Text = if rebirths > 0
		then string.format("Now: +%s coins, +%s Bubbles", pct(rb.CoinsPer * rebirths), pct(rb.BubblesPer * rebirths))
		else "No rebirth bonuses yet."
	nextLabel.Text = string.format(
		"Next rebirth: +%s coins and +%s Bubbles forever, and %d 💎",
		pct(rb.CoinsPer * (rebirths + 1)),
		pct(rb.BubblesPer * (rebirths + 1)),
		rb.Gems
	)
	local last = Config.Levels[#Config.Levels]
	local levelDone = meta ~= nil and meta.RebirthReady == true
	reqLevel.Text = string.format("%s Clean %s %s", if levelDone then "✅" else "⬜", last.Icon, last.Name)
	reqLevel.TextColor3 = if levelDone then Colors.Good else Colors.Text
	local cost = Config.RebirthCost(rebirths)
	local have = (meta and meta.Bubbles) or 0
	local enough = have >= cost
	reqBubbles.Text = string.format("%s Have %s / %s 🧼", if enough then "✅" else "⬜", UIKit.Commas(have), UIKit.Commas(cost))
	reqBubbles.TextColor3 = if enough then Colors.Good else Colors.Text
	UIKit.SetButtonColor(rebirthButton, if levelDone and enough then Colors.Good else Colors.Disabled)
end

local function doRebirth()
	if busy then
		return
	end
	busy = true
	local result = ClientState.MetaRequest("Rebirth")
	busy = false
	if not result.Ok then
		UIKit.Toast(result.Error or "Can't rebirth yet.", "Bad")
		return
	end
	UIKit.PlaySound("Sparkle")
	UIKit.Confetti(80)
	UIKit.Toast("✨ Rebirthed! Your bonuses are now permanent.", "Good")
	render()
end

function RebirthUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, screenRoot = UIKit.CreateScreen("RebirthUI", 10)
	local _window, content = UIKit.Window({
		Name = "Rebirth",
		Title = "Rebirth",
		Icon = "✨",
		Size = Vector2.new(620, 520),
		Parent = screenRoot,
	})

	local y = 0
	local function line(props: { [string]: any }, height: number): TextLabel
		props.Size = UDim2.new(1, -20, 0, height)
		props.Position = UDim2.new(0.5, 0, 0, y)
		props.AnchorPoint = Vector2.new(0.5, 0)
		props.Parent = content
		props.TextWrapped = true
		y += height + 6
		return UIKit.Label(props)
	end

	countLabel = line({ Text = "", TextSize = 34, TextColor3 = Color3.fromRGB(255, 220, 110) }, 42)
	nowLabel = line({ Text = "", TextSize = 18, TextColor3 = Colors.TextDim }, 24)
	nextLabel = line({ Text = "", TextSize = 20 }, 50)

	local reqCard = UIKit.Card({
		Size = UDim2.new(1, -20, 0, 96),
		Position = UDim2.new(0.5, 0, 0, y),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.PanelDark,
		Parent = content,
	})
	y += 104
	reqLevel = UIKit.Label({ Text = "", TextSize = 20, Size = UDim2.new(1, -24, 0, 36), Position = UDim2.fromOffset(12, 8), TextXAlignment = Enum.TextXAlignment.Left, Parent = reqCard })
	reqBubbles = UIKit.Label({ Text = "", TextSize = 20, Size = UDim2.new(1, -24, 0, 36), Position = UDim2.fromOffset(12, 50), TextXAlignment = Enum.TextXAlignment.Left, Parent = reqCard })

	line({
		Text = "Resets: Bubbles, unlocked levels and perks.\nYou keep: pets, gems, ranks, passes and best times.",
		TextSize = 16,
		TextColor3 = Colors.TextDim,
	}, 48)

	rebirthButton = UIKit.Button({
		Text = "REBIRTH",
		Icon = "✨",
		Size = UDim2.new(1, -40, 0, 64),
		Position = UDim2.new(0.5, 0, 0, y + 4),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Disabled,
		TextSize = 30,
		Parent = content,
		OnClick = doRebirth,
	})

	UIKit.RegisterWindow("Rebirth", {
		Open = function()
			render()
		end,
	})
	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" and UIKit.IsWindowOpen("Rebirth") then
			render()
		end
	end)
end

return RebirthUI
