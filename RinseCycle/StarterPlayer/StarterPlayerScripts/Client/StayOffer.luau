--[[
	StayOffer - "Don't go yet!" When a player opens the Roblox menu (usually on the way to Leave),
	they're offered a free x2 cleaning boost for 15 minutes, once a day (DataService.ClaimStayBoost).
	The popup is behind Roblox's menu, so it's what they see the moment they close it.

	While a boost runs, a small "x2 Cleaning 14:32" timer sits under the currency pills.
]]

local GuiService = game:GetService("GuiService")

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))

local StayOffer = {}

local Colors = UIKit.Theme.Colors

local initialized = false
local offeredThisSession = false

local function boostLeft(): number
	local meta = ClientState.Meta :: any
	local untilTime = meta and tonumber(meta.BoostUntil) or 0
	return math.max(0, untilTime - os.time())
end

local function claim()
	local result = ClientState.MetaRequest("ClaimStayBoost")
	UIKit.CloseWindow("StayOffer")
	if result.Ok then
		UIKit.Confetti(60)
		UIKit.Toast(result.Message or "x2 Cleaning for 15 minutes!", "Good")
	else
		UIKit.Toast(result.Error or "Couldn't claim that.", "Info")
	end
end

function StayOffer.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, root = UIKit.CreateScreen("StayOffer", 35)
	local _window, content = UIKit.Window({
		Name = "StayOffer",
		Title = "Don't go yet!",
		Size = Vector2.new(520, 320),
		Parent = root,
	})
	UIKit.Label({
		Text = "Stay and play: FREE x2 Cleaning Speed",
		TextSize = 28,
		TextScaled = true,
		TextColor3 = Colors.Warning,
		Size = UDim2.new(1, -20, 0, 44),
		Position = UDim2.fromOffset(10, 4),
		Parent = content,
	})
	UIKit.Label({
		Text = "Everything you and your pets clean counts double for the next 15 minutes.",
		TextSize = 20,
		TextWrapped = true,
		TextScaled = true,
		Size = UDim2.new(1, -40, 0, 60),
		Position = UDim2.fromOffset(20, 56),
		Parent = content,
	})
	UIKit.Button({
		Text = "Claim x2 Boost!",
		Color = Colors.Good,
		TextSize = 26,
		Size = UDim2.new(1, -60, 0, 64),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 130),
		Parent = content,
		OnClick = function()
			task.spawn(claim)
		end,
	})
	UIKit.Button({
		Text = "No thanks",
		Color = Colors.PanelLight,
		TextSize = 18,
		Size = UDim2.fromOffset(180, 40),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 206),
		Parent = content,
		OnClick = function()
			UIKit.CloseWindow("StayOffer")
		end,
	})
	UIKit.RegisterWindow("StayOffer", { Open = function() end })

	-- The timer chip while the boost runs.
	local chip = UIKit.Card({
		Size = UDim2.fromOffset(190, 34),
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 52),
		Color = Colors.Good,
		Parent = root,
	})
	chip.Visible = false
	local chipLabel = UIKit.Label({ Text = "", TextSize = 18, Size = UDim2.fromScale(1, 1), Parent = chip })
	task.spawn(function()
		while true do
			local left = boostLeft()
			chip.Visible = left > 0
			if left > 0 then
				chipLabel.Text = string.format("x2 Cleaning %d:%02d", left // 60, left % 60)
			end
			task.wait(1)
		end
	end)

	-- Opening the Roblox menu: offer today's boost (once a session, and only if it's still free).
	GuiService.MenuOpened:Connect(function()
		local meta = ClientState.Meta :: any
		if offeredThisSession or not meta or meta.StayBoostReady ~= true or boostLeft() > 0 then
			return
		end
		offeredThisSession = true
		UIKit.OpenWindow("StayOffer")
	end)
end

return StayOffer
