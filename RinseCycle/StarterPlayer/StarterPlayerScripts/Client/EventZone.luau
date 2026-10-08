--[[
	EventZone - the Next Event spot in the lobby (LobbyBuilder's glowing ring, tag "NextEventZone").

	Walk into the ring and Roblox's own event pop-up comes up for the next event (Config.NextEvent,
	SocialService:PromptRsvpToEventAsync with its RobloxEventId from StoreIds > EventIds): the event
	card with Notify Me, or Join while it's on. Until an event ID is pasted in, a card of ours shows
	the event and its countdown, with Notify Me (experience notifications) and No thanks.
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
local ClientState = require(Client:WaitForChild("ClientState"))

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
	if event.Soon then
		return "COMING SOON"
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
	ClientState.Track("event.rsvp")
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
	-- No Roblox event linked yet: just ask for notifications, and say ONE thing about it.
	local RewardsUI = require(Client:WaitForChild("RewardsUI")) :: any
	local name = if event then event.Name else "the next event"
	if RewardsUI.PromptNotifications() == "AlreadyOn" then
		UIKit.Toast("Notifications are already on. We'll let you know when " .. name .. " starts!", "Good")
	end
end

local lastPrompt = 0

-- Roblox's event pop-up, when the event is set up on Roblox. True if it was shown.
local function robloxPopup(event: any): boolean
	local id = tostring(event and event.RobloxEventId or "")
	if id == "" or id == "0" or os.clock() - lastPrompt < 20 then
		return id ~= "" and id ~= "0"
	end
	lastPrompt = os.clock()
	local ok, err = pcall(function()
		SocialService:PromptRsvpToEventAsync(id)
	end)
	if not ok then
		warn("[EventZone] event pop-up failed: " .. tostring(err))
	else
		ClientState.Track("event.rsvp")
	end
	return ok
end

local function show(event: any)
	if robloxPopup(event) then
		return
	end
	shownFor = event
	nameLabel.Text = if event then event.Name else "No events planned yet"
	descLabel.Text = if event then event.Desc else "Check back soon. Turn on notifications so you never miss one!"
	whenLabel.Text = EventZone.WhenText(event)
	whenLabel.TextColor3 = if event and os.time() >= event.Starts then Colors.Good else Colors.Coin
	local label = notifyButton:FindFirstChild("Label", true)
	local text = if event and os.time() >= event.Starts then "IT'S ON!" else "TURN ON NOTIFICATIONS"
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
		Text = "TURN ON NOTIFICATIONS",
		Color = Color3.fromRGB(240, 90, 140),
		TextSize = 22,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(0.5, 30, 1, -12),
		Size = UDim2.fromOffset(310, 52),
		Parent = card,
		OnClick = function()
			card.Visible = false
			task.spawn(notify, shownFor)
		end,
	})
	UIKit.Button({
		Text = "NO THANKS",
		Color = Colors.PanelLight,
		TextSize = 20,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.5, 40, 1, -12),
		Size = UDim2.fromOffset(150, 52),
		Parent = card,
		OnClick = function()
			card.Visible = false
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
			-- (the server may have moved Admin Abuse's schedule: a test start, or the show being over, which makes Chapter 4 the
			-- next event; its attributes are the truth, this copy of Config is only the default)
			local starts, ends = tonumber(ReplicatedStorage:GetAttribute("AbuseStarts")), tonumber(ReplicatedStorage:GetAttribute("AbuseEnds"))
			if starts and ends then
				for _, e in Config.UpcomingEvents do
					if e.Key == Config.AbuseShow.EventKey then
						e.Starts, e.Ends = starts, ends
					end
				end
			end
			local event = Config.NextEvent()
			local when = EventZone.WhenText(event)
			for _, label in CollectionService:GetTagged("NextEventName") do
				if label:IsA("TextLabel") then
					label.Text = if event then event.Name else ""
				end
			end
			for _, label in CollectionService:GetTagged("NextEventCountdown") do
				if label:IsA("TextLabel") then
					label.Text = when
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
			if ReplicatedStorage:GetAttribute("AbuseLive") == true then
				isInside = false -- (no pop-ups while the Admin Abuse show runs)
				card.Visible = false
			end
			if isInside and not wasInside then
				ClientState.Track("event.sign")
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
