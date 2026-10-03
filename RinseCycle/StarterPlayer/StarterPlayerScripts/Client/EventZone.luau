--[[
	EventZone - the Next Event spot in the lobby (LobbyBuilder's glowing ring, tag "NextEventZone").

	Walk into the ring and a card pops up with the next event (Config.NextEvent): its name, what
	happens, and when ("Starts in 3d 04h", or LIVE NOW). The button is Roblox's own Notify Me
	(SocialService:PromptRsvpToEventAsync) when the event has a RobloxEventId; otherwise it asks for
	experience notifications, so players still hear about it. Walking out closes the card.
	The banner over the ring (tag "NextEventCountdown") counts down too.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))

local EventZone = {}

local Colors = UIKit.Theme.Colors
local LocalPlayer = Players.LocalPlayer

local initialized = false
local card: Frame
local nameLabel: TextLabel
local descLabel: TextLabel
local whenLabel: TextLabel
local notifyButton: TextButton
local shownFor: any = nil

-- "Starts in 3d 04h" / "LIVE NOW!" / "" when there's nothing coming.
function EventZone.WhenText(event: any, now: number?): string
	if not event then
		return "More events soon!"
	end
	local t = now or os.time()
	if t >= event.Starts then
		return "LIVE NOW!"
	end
	local left = event.Starts - t
	local d, h, m, sec = left // 86400, (left % 86400) // 3600, (left % 3600) // 60, left % 60
	if d > 0 then
		return string.format("Starts in %dd %02dh", d, h)
	elseif h > 0 then
		return string.format("Starts in %dh %02dm", h, m)
	end
	return string.format("Starts in %dm %02ds", m, sec)
end

local function notify(event: any)
	local id = tostring(event and event.RobloxEventId or "0")
	if id ~= "" and id ~= "0" then
		local ok, err = pcall(function()
			SocialService:PromptRsvpToEventAsync(id)
		end)
		if ok then
			return
		end
		warn("[EventZone] RSVP prompt failed: " .. tostring(err))
	end
	-- No Roblox event set up: experience notifications instead.
	local RewardsUI = require(Client:WaitForChild("RewardsUI")) :: any
	RewardsUI.PromptNotifications(true)
	UIKit.Toast("We'll let you know when " .. (if event then event.Name else "the next event") .. " starts!", "Good")
end

local function show(event: any)
	shownFor = event
	nameLabel.Text = if event then event.Name else "No events planned yet"
	descLabel.Text = if event then event.Desc else "Check back soon. Turn on notifications so you never miss one!"
	whenLabel.Text = EventZone.WhenText(event)
	whenLabel.TextColor3 = if event and os.time() >= event.Starts then Colors.Good else Colors.Coin
	local label = notifyButton:FindFirstChild("Label", true)
	local text = if event and os.time() >= event.Starts then "IT'S ON!" else "NOTIFY ME"
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
	notifyButton.Text = text
	if not card.Visible then
		card.Visible = true
		UIKit.Bounce(card)
		UIKit.PlaySound("Pop")
	end
end

local function inside(zone: BasePart, position: Vector3): boolean
	local p = zone.CFrame:PointToObjectSpace(position)
	local half = zone.Size / 2
	return math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y + 3 and math.abs(p.Z) <= half.Z
end

function EventZone.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, root = UIKit.CreateScreen("EventZone", 13)
	card = UIKit.Card({
		Name = "NextEvent",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -120),
		Size = UDim2.fromOffset(520, 210),
		Color = Colors.PanelDark,
		Parent = root,
	})
	card.Visible = false
	UIKit.Stroke(card, Color3.fromRGB(255, 120, 160), 3, 0)
	local icon = UIKit.Icon("Calendar", 72, { Position = UDim2.fromOffset(16, 18) })
	icon.Parent = card
	UIKit.Label({ Text = "NEXT EVENT", TextSize = 15, TextColor3 = Color3.fromRGB(255, 160, 200), TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(104, 12), Size = UDim2.new(1, -150, 0, 18), Parent = card })
	nameLabel = UIKit.Label({ Text = "", TextSize = 26, TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(104, 30), Size = UDim2.new(1, -120, 0, 32), Parent = card })
	whenLabel = UIKit.Label({ Text = "", TextSize = 20, TextColor3 = Colors.Coin, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(104, 64), Size = UDim2.new(1, -120, 0, 24), Parent = card })
	descLabel = UIKit.Label({ Text = "", TextSize = 15, TextWrapped = true, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(16, 98), Size = UDim2.new(1, -32, 0, 40), Parent = card })
	notifyButton = UIKit.Button({
		Text = "NOTIFY ME",
		Color = Color3.fromRGB(240, 90, 140),
		TextSize = 22,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.fromOffset(260, 52),
		Parent = card,
		OnClick = function()
			task.spawn(notify, shownFor)
		end,
	})
	UIKit.Button({
		Text = "X",
		Color = Colors.Bad,
		TextSize = 18,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 8),
		Size = UDim2.fromOffset(36, 36),
		Parent = card,
		OnClick = function()
			card.Visible = false
		end,
	})

	local wasInside = false
	task.spawn(function()
		while true do
			local event = Config.NextEvent()
			local when = EventZone.WhenText(event)
			for _, label in CollectionService:GetTagged("NextEventCountdown") do
				if label:IsA("TextLabel") then
					label.Text = if event then event.Name .. "  •  " .. when else when
				end
			end
			local character = LocalPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local isInside = false
			if rootPart and rootPart:IsA("BasePart") then
				for _, zone in CollectionService:GetTagged("NextEventZone") do
					if zone:IsA("BasePart") and inside(zone, rootPart.Position) then
						isInside = true
						break
					end
				end
			end
			if isInside and not wasInside then
				show(event)
			elseif isInside and card.Visible then
				whenLabel.Text = when
			elseif not isInside and wasInside then
				card.Visible = false
			end
			wasInside = isInside
			task.wait(0.3)
		end
	end)
end

return EventZone
