--[[
	ClubsUI - the Clubs window (HUD "Clubs" button, C key).

	Tabs (not in a club):  CREATE CLUB  |  TOP CLUBS  |  FIND CLUBS
	Tabs (in a club):      MY CLUB  |  TOP CLUBS  |  FIND CLUBS  |  LEADERBOARD  |  CHAT

	  CREATE CLUB  Name, prefix (the [TAG] in front of members' names; the ? inside its box explains
	               it), public / private, requirements, CREATE (Gems, with a "Creating..." overlay).
	               Or join with a club code.
	  MY CLUB      The banner (prefix, name, points, members, requirements, the club code). The
	               owner can edit the name and prefix (each once every 30 days, with a warning
	               first) and the settings. Click a member for their options: Promote to Co-Leader
	               (owner, with a warning), Demote, Kick (owner: anyone; co-leaders: members).
	               Leave / Close club ask first.
	  TOP CLUBS    The top 25 by Bubbles donated this month: FULL, INVITE ONLY, LOCKED, JOIN or YOURS.
	               Click a club to see its members and what each has given.
	  FIND CLUBS   Type and the clubs starting with it come up, A to Z (a club code finds that club).
	               The filter button opens filters (public / private, friends in it, ones you can
	               join, ones with space); Back returns to the results.
	  LEADERBOARD  Your club's members by the Bubbles they've donated this month, and when the monthly
	               contest resets (in your own time). DONATE BUBBLES is on MY CLUB.
	  CHAT         The club's chat (filtered, kept between sessions).

	Everything goes through ClubRequest (ClubService); ClubState pushes changes, ClubChat messages.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local ClubsUI = {}

local Colors = UIKit.Theme.Colors
local Fonts = UIKit.Theme.Fonts
local LocalPlayer = Players.LocalPlayer

local initialized = false
local busy = false
local tab = "Club"
local myClub: any = nil
local content: Frame
local tabsRow: Frame
local pageHolder: Frame
local overlay: Frame
local chatLog: { any } = {}
local chatLoaded = false
local friends: { [number]: boolean }? = nil
local filters = { Type = "Any", Friends = false, CanJoin = false, Space = false }
local findText = ""
local renderToken = 0
local render: () -> ()
local inClubPerMeta: () -> boolean
local fetchMine: () -> ()

local ROLE_NAMES = { Owner = "Owner", CoLeader = "Co-Leader", Member = "Member" }

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

-- `busyText`: shows the bouncing dots over the window ("Creating your club...") while it waits.
local function request(action: string, value: any?, busyText: string?): any
	if busy then
		return { Ok = false, Error = "One moment..." }
	end
	busy = true
	local done = if busyText then UIKit.Busy(busyText, true) else nil
	local ok, result = pcall(function()
		return Remotes.Function("ClubRequest"):InvokeServer(action, value)
	end)
	if done then
		done()
	end
	busy = false
	if not ok or type(result) ~= "table" then
		return { Ok = false, Error = "Couldn't reach the server." }
	end
	return result
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function setText(button: TextButton, text: string)
	button.Text = text
	local label = button:FindFirstChild("Label", true)
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function reqText(club: any): string
	local parts = {}
	if (club.ReqLevel or 0) > 0 then
		table.insert(parts, "Beat level " .. club.ReqLevel)
	end
	if (club.ReqRebirths or 0) > 0 then
		table.insert(parts, club.ReqRebirths .. " rebirths")
	end
	return if #parts > 0 then table.concat(parts, ", ") else "Anyone can join"
end

local function meetsReq(club: any): boolean
	local meta = ClientState.Meta :: any
	if not meta then
		return false
	end
	return (tonumber(meta.LevelsBeaten) or 0) >= (club.ReqLevel or 0) and (tonumber(meta.Rebirths) or 0) >= (club.ReqRebirths or 0)
end

local function daysText(seconds: number): string
	local days = math.ceil(seconds / 86400)
	return if days <= 1 then "1 day" else days .. " days"
end

-- `help`: { Title, Text } puts a small "?" at the right end of the box that explains the field.
local showInfo: (string, string) -> ()
local applyResult: (any, string?) -> ()

local function textBox(parent: Instance, placeholder: string, props: { [string]: any }, maxLength: number?, help: { string }?): TextBox
	local frame = UIKit.Card({ Color = Colors.PanelDark, Parent = parent })
	for k, v in props do
		(frame :: any)[k] = v
	end
	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.Size = UDim2.new(1, if help then -52 else -20, 1, 0)
	box.Position = UDim2.fromOffset(10, 0)
	box.Font = Fonts.Title
	box.TextSize = 20
	box.TextColor3 = Colors.Text
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Colors.TextDim
	box.Text = ""
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Parent = frame
	if help then
		UIKit.Button({
			Text = "?",
			Color = Colors.Accent,
			TextSize = 16,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -8, 0.5, 0),
			Size = UDim2.fromOffset(28, 28),
			CornerRadius = 14,
			Parent = frame,
			OnClick = function()
				showInfo(help[1], help[2])
			end,
		})
	end
	if maxLength then
		box:GetPropertyChangedSignal("Text"):Connect(function()
			if #box.Text > maxLength then
				box.Text = string.sub(box.Text, 1, maxLength)
			end
		end)
	end
	return box
end

local function toast(result: any, good: string?)
	if result.Ok then
		UIKit.PlaySound("Sparkle")
		if result.Message or good then
			UIKit.Toast(result.Message or good, "Good")
		end
	else
		UIKit.Toast(result.Error or "Couldn't do that.", "Info")
	end
end

local function scrollList(parent: Instance, top: number): ScrollingFrame
	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(0, top)
	list.Size = UDim2.new(1, 0, 1, -top)
	list.ScrollBarThickness = 8
	list.ScrollBarImageColor3 = Colors.Primary
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = list
	return list
end

----------------------------------------------------------------------------------------------------
-- Dialogs (drawn over the window's content)
----------------------------------------------------------------------------------------------------

local function closeDialog()
	clear(overlay)
	overlay.Visible = false
end

-- A dialog card; returns the card to fill. `height` in pixels.
local function dialog(title: string, height: number, width: number?): Frame
	clear(overlay)
	overlay.Visible = true
	local card = UIKit.Card({
		Name = "Dialog",
		Color = Colors.Panel,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(width or 460, height),
		Parent = overlay,
	})
	UIKit.Stroke(card, Colors.Primary, 3, 0)
	UIKit.Label({ Text = title, TextSize = 24, TextColor3 = Colors.Coin, Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, 0, 0, 30), Parent = card })
	UIKit.Bounce(card)
	return card
end

-- "Are you sure?" with a message, a yes button (colour) and Cancel.
local function confirm(title: string, message: string, yesText: string, yesColor: Color3, onYes: () -> ())
	local card = dialog(title, 230)
	UIKit.Label({ Text = message, TextSize = 17, TextWrapped = true, TextColor3 = Colors.Text, Position = UDim2.fromOffset(20, 48), Size = UDim2.new(1, -40, 0, 100), Parent = card })
	UIKit.Button({
		Text = yesText,
		Color = yesColor,
		TextSize = 18,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(0.5, -6, 1, -16),
		Size = UDim2.fromOffset(190, 50),
		Parent = card,
		OnClick = function()
			closeDialog()
			onYes()
		end,
	})
	UIKit.Button({
		Text = "Cancel",
		Color = Colors.PanelLight,
		TextSize = 18,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0.5, 6, 1, -16),
		Size = UDim2.fromOffset(150, 50),
		Parent = card,
		OnClick = closeDialog,
	})
end

function showInfo(title: string, message: string)
	local card = dialog(title, 210)
	UIKit.Label({ Text = message, TextSize = 17, TextWrapped = true, Position = UDim2.fromOffset(20, 48), Size = UDim2.new(1, -40, 0, 90), Parent = card })
	UIKit.Button({
		Text = "Got it",
		Color = Colors.Primary,
		TextSize = 18,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(160, 48),
		Parent = card,
		OnClick = closeDialog,
	})
end

----------------------------------------------------------------------------------------------------
-- The monthly contest: text, donating, and a club's details
----------------------------------------------------------------------------------------------------

-- Bouncing dots in the middle of a page while its data loads ("Loading your club...").
local function dotsPage(page: Instance, text: string)
	local holder = Instance.new("Frame")
	holder.Name = "Loading"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromScale(1, 1)
	holder.Parent = page
	UIKit.Label({ Text = text, TextSize = 24, TextColor3 = Colors.TextDim, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0.5, -26), Size = UDim2.new(1, 0, 0, 36), Parent = holder })
	for i = 1, 3 do
		local dot = Instance.new("Frame")
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.new(0.5, (i - 2) * 30, 0.5, 22)
		dot.Size = UDim2.fromOffset(16, 16)
		dot.BackgroundColor3 = Colors.Primary
		UIKit.Corner(dot, 8)
		dot.Parent = holder
		TweenService:Create(dot, TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, i * 0.12), { Position = UDim2.new(0.5, (i - 2) * 30, 0.5, 10) }):Play()
	end
end

local POINTS_HELP = "Points are Bubbles donated to your club (DONATE BUBBLES on MY CLUB). Every month the clubs with the most points win prizes: the top 3 clubs' members get Gems, and the #1 club's members also get a limited pet nothing else gives. On the 1st of every month everyone's points start again from zero."

-- "Resets 1 November 2026, 1:00 PM (your time)" from the server's UTC reset time.
local function resetText(season: any): string
	if type(season) ~= "table" or type(season.ResetAt) ~= "number" then
		return ""
	end
	local day = tonumber(os.date("%d", season.ResetAt)) or 1
	local rest = os.date("%B %Y, %I:%M %p", season.ResetAt)
	local cleaned = string.gsub(rest, "^(%a+ %d+, )0", "%1")
	return string.format("Resets %d %s (your time)", day, cleaned)
end

local function prizeText(): string
	local rules = Config.Clubs.Season
	local pet = Config.Pets[rules.Pet]
	return string.format(
		"Prizes: #1 %d Gems + the limited %s pet, #2 %d Gems, #3 %d Gems (for every member).",
		rules.PrizeGems[1],
		if pet then pet.Name else "pet",
		rules.PrizeGems[2],
		rules.PrizeGems[3]
	)
end

local function donateDialog()
	local meta = ClientState.Meta :: any
	local have = if meta then tonumber(meta.Bubbles) or 0 else 0
	local card = dialog("Donate Bubbles", 300)
	UIKit.Label({
		Text = string.format("You have %s Bubbles. Donated Bubbles can't be taken back: they become points for your club this month.", UIKit.Commas(have)),
		TextSize = 16,
		TextWrapped = true,
		Position = UDim2.fromOffset(20, 46),
		Size = UDim2.new(1, -40, 0, 60),
		Parent = card,
	})
	local amounts: { number } = table.clone(Config.Clubs.Season.DonateAmounts)
	table.insert(amounts, -1) -- "ALL"
	for i, amount in amounts do
		local all = amount < 0
		local value = if all then have else amount
		UIKit.Button({
			Text = if all then string.format("ALL (%s)", UIKit.Commas(have)) else UIKit.Commas(amount),
			Color = if value > 0 and value <= have then Colors.Good else Colors.Disabled,
			TextSize = 18,
			Position = UDim2.new(0, 20 + ((i - 1) % 2) * 210, 0, 116 + ((i - 1) // 2) * 58),
			Size = UDim2.fromOffset(200, 50),
			Parent = card,
			OnClick = function()
				if value <= 0 or value > have then
					UIKit.Toast(if have <= 0 then "You don't have any Bubbles to donate yet." else "You don't have that many Bubbles.", "Info")
					return
				end
				closeDialog()
				task.spawn(function()
					local result = request("Donate", value, "Donating")
					if result.Ok then
						UIKit.Confetti(40)
					end
					applyResult(result)
				end)
			end,
		})
	end
	UIKit.Button({ Text = "Close", Color = Colors.PanelLight, TextSize = 16, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.fromOffset(140, 40), Parent = card, OnClick = closeDialog })
end

-- A club's details: who's in it and what each has given this month (scrolls). Opened from TOP CLUBS /
-- FIND. Private clubs show too: private only means you need the code to join.
local function clubInfoDialog(summary: any)
	local card = dialog(string.format("[%s] %s", summary.Tag, summary.Name), 500, 560)
	UIKit.Label({ Name = "Status", Text = "Loading...", TextSize = 14, TextWrapped = true, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(16, 40), Size = UDim2.new(1, -32, 0, 34), Parent = card })
	local list = scrollList(card, 74)
	list.Position = UDim2.fromOffset(16, 74)
	list.Size = UDim2.new(1, -32, 1, -150)
	UIKit.Button({ Text = "Close", Color = Colors.PanelLight, TextSize = 18, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.fromOffset(160, 46), Parent = card, OnClick = closeDialog })
	task.spawn(function()
		local result = request("Info", summary.Id)
		if not card.Parent then
			return
		end
		if not result.Ok then
			(card:FindFirstChild("Status") :: TextLabel).Text = result.Error or "Couldn't load that club."
			return
		end
		local club = result.Club
		;(card:FindFirstChild("Status") :: TextLabel).Text = string.format(
			"%s Bubbles donated this month  •  %d/%d members  •  %s  •  %s",
			UIKit.Commas(club.Points or 0),
			club.Count or 0,
			club.Max or Config.Clubs.MaxMembers,
			if club.Public then "Public" else "Private (needs a code)",
			reqText(club)
		)
		local members: { any } = table.clone(club.Members or {})
		table.sort(members, function(a, b)
			if (a.Points or 0) ~= (b.Points or 0) then
				return (a.Points or 0) > (b.Points or 0)
			end
			return string.lower(a.Name) < string.lower(b.Name)
		end)
		for i, m in members do
			local row = UIKit.Card({ Name = "Entry", Size = UDim2.new(1, 0, 0, 40), LayoutOrder = i, Parent = list })
			local rankColor = if i == 1 then Colors.Coin elseif i == 2 then Color3.fromRGB(210, 220, 235) elseif i == 3 then Color3.fromRGB(230, 150, 90) else Colors.TextDim
			UIKit.Label({ Text = "#" .. i, TextSize = 18, TextColor3 = rankColor, Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(46, 40), Parent = row })
			UIKit.Label({ Text = m.Name .. (if m.Role == "Owner" then "  (Owner)" elseif m.Role == "CoLeader" then "  (Co-Leader)" else ""), TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(56, 0), Size = UDim2.new(1, -200, 1, 0), Parent = row })
			UIKit.Label({ Text = UIKit.Commas(m.Points or 0), TextSize = 16, TextColor3 = Colors.Coin, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0), Size = UDim2.fromOffset(130, 40), Parent = row })
		end
	end)
end

----------------------------------------------------------------------------------------------------
-- Club rows (TOP CLUBS and FIND CLUBS)
----------------------------------------------------------------------------------------------------

local function joinClub(club: any)
	task.spawn(function()
		local result = if club.ByCode then request("JoinCode", club.Code or findText, "Joining the club") else request("Join", club.Id, "Joining the club")
		closeDialog()
		toast(result)
		if result.Ok then
			myClub = result.Club
			tab = "Club"
			render()
		end
	end)
end

local function clubRow(parent: Instance, club: any, order: number)
	local row = UIKit.Card({ Name = "ClubRow", Size = UDim2.new(1, 0, 0, 64), LayoutOrder = order, Parent = parent })
	if club.Mine then
		UIKit.Stroke(row, Colors.Coin, 3, 0)
	end
	-- The whole row opens the club's members (the JOIN button, added last, sits on top of this).
	local hit = Instance.new("TextButton")
	hit.Name = "Open"
	hit.Text = ""
	hit.BackgroundTransparency = 1
	hit.Size = UDim2.fromScale(1, 1)
	hit.Parent = row
	hit.Activated:Connect(function()
		clubInfoDialog(club)
	end)
	local left = 12
	if club.Rank then
		local rankColor = if club.Rank == 1 then Colors.Coin elseif club.Rank == 2 then Color3.fromRGB(210, 220, 235) elseif club.Rank == 3 then Color3.fromRGB(230, 150, 90) else Colors.TextDim
		UIKit.Label({ Text = "#" .. club.Rank, TextSize = 22, TextColor3 = rankColor, Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(50, 64), Parent = row })
		left = 60
	end
	UIKit.Label({
		Text = string.format("[%s] %s", club.Tag, club.Name),
		TextSize = 20,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(left, 6),
		Size = UDim2.new(1, -(left + 170), 0, 28),
		Parent = row,
	})
	UIKit.Label({
		Text = string.format("%s donated  •  %d/%d  •  %s  •  %s", UIKit.Commas(club.Points or 0), club.Count or 0, club.Max or Config.Clubs.MaxMembers, if club.Public then "Public" else "Private (code)", reqText(club)),
		TextSize = 14,
		TextScaled = true,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(left, 36),
		Size = UDim2.new(1, -(left + 170), 0, 20),
		Parent = row,
	})
	local full = (club.Count or 0) >= (club.Max or Config.Clubs.MaxMembers)
	local label, color, enabled
	if club.Mine then
		label, color, enabled = "YOURS", Colors.Coin, false
	elseif full then
		label, color, enabled = "FULL", Colors.Bad, false
	elseif not club.Public and not club.ByCode then
		label, color, enabled = "INVITE ONLY", Colors.Disabled, false
	elseif not meetsReq(club) then
		label, color, enabled = "LOCKED", Colors.Disabled, false
	else
		label, color, enabled = "JOIN", Colors.Good, true
	end
	UIKit.Button({
		Text = label,
		Color = color,
		TextSize = 16,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(150, 44),
		Parent = row,
		OnClick = function()
			if enabled then
				joinClub(club)
			elseif label == "LOCKED" then
				UIKit.Toast("You don't meet this club's requirements yet: " .. reqText(club), "Info")
			elseif label == "INVITE ONLY" then
				UIKit.Toast("This club is private. Ask a member for the club code!", "Info")
			end
		end,
	})
	return row
end

----------------------------------------------------------------------------------------------------
-- CREATE CLUB
----------------------------------------------------------------------------------------------------

-- A button that cycles through values ("Level: anyone" -> "Must beat level 1" -> ...).
local function cycler(parent: Instance, values: { any }, format: (any) -> string, start: number, props: { [string]: any }): () -> any
	local index = start
	local button: TextButton
	button = UIKit.Button({
		Text = format(values[index]),
		Color = Colors.PanelLight,
		TextSize = 16,
		Parent = parent,
		OnClick = function()
			index = index % #values + 1
			setText(button, format(values[index]))
		end,
	})
	for k, v in props do
		(button :: any)[k] = v
	end
	return function()
		return values[index]
	end
end

local function levelValues(): { number }
	local out = {}
	for i = 0, Config.Clubs.MaxLevelReq do
		table.insert(out, i)
	end
	return out
end

local REBIRTH_STEPS = { 0, 1, 2, 3, 5, 10, 15, 20, 30, 50 }

local function levelText(n: number): string
	return if n == 0 then "Level: anyone" else "Must beat level " .. n
end

local function rebirthText(n: number): string
	return if n == 0 then "Rebirths: any" else n .. "+ rebirths"
end

local PREFIX_HELP = "The prefix is the short tag shown in front of every member's name, so everyone can see which club they're in. Example: [SOAP] YourName."

local function renderCreate(page: Frame)
	local rules = Config.Clubs
	local create = UIKit.Card({ Name = "Create", Color = Colors.PanelDark, Size = UDim2.new(0.6, -8, 1, 0), Parent = page })
	UIKit.Label({ Text = "MAKE A CLUB", TextSize = 22, TextColor3 = Colors.Coin, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 28), Parent = create })
	UIKit.Label({ Text = "Club name", TextSize = 14, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(18, 38), Size = UDim2.new(0.6, 0, 0, 16), Parent = create })
	local nameBox = textBox(create, string.format("%d-%d letters", rules.NameLength[1], rules.NameLength[2]), {
		Position = UDim2.fromOffset(16, 56),
		Size = UDim2.new(1, -32, 0, 44),
	}, rules.NameLength[2])
	UIKit.Label({ Text = "Club prefix", TextSize = 14, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(18, 106), Size = UDim2.new(0.4, 0, 0, 16), Parent = create })
	local tagBox = textBox(create, string.format("%d-%d letters", rules.TagLength[1], rules.TagLength[2]), {
		Position = UDim2.fromOffset(16, 132),
		Size = UDim2.new(0.5, -22, 0, 44),
	}, rules.TagLength[2], { "What's a prefix?", PREFIX_HELP })
	tagBox:GetPropertyChangedSignal("Text"):Connect(function()
		local upper = string.upper(tagBox.Text)
		if upper ~= tagBox.Text then
			tagBox.Text = upper
		end
	end)
	local getPublic = cycler(create, { true, false }, function(v)
		return if v then "Public" else "Private (code)"
	end, 1, { Position = UDim2.new(0.5, 6, 0, 132), Size = UDim2.new(0.5, -22, 0, 44) })
	local getLevel = cycler(create, levelValues(), levelText, 1, { Position = UDim2.fromOffset(16, 186), Size = UDim2.new(0.5, -22, 0, 44) })
	local getRebirths = cycler(create, REBIRTH_STEPS, rebirthText, 1, { Position = UDim2.new(0.5, 6, 0, 186), Size = UDim2.new(0.5, -22, 0, 44) })
	UIKit.Label({
		Text = string.format("Up to %d members. Donate Bubbles to earn club points: the top 3 clubs win prizes every month!", rules.MaxMembers),
		TextSize = 14,
		TextWrapped = true,
		TextColor3 = Colors.TextDim,
		Position = UDim2.fromOffset(16, 236),
		Size = UDim2.new(1, -32, 0, 40),
		Parent = create,
	})
	UIKit.Button({
		Text = string.format("CREATE  (%d Gems)", rules.CreateCost),
		Color = Colors.Good,
		TextSize = 22,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.new(1, -32, 0, 54),
		Parent = create,
		OnClick = function()
			local meta = ClientState.Meta :: any
			if meta and (meta.Gems or 0) < rules.CreateCost then
				UIKit.Toast(string.format("You need %d Gems to make a club. Get more here!", rules.CreateCost), "Info")
				UIKit.OpenWindow("Shop", "Gems")
				return
			end
			task.spawn(function()
				local result = request("Create", {
					Name = nameBox.Text,
					Tag = tagBox.Text,
					Public = getPublic(),
					ReqLevel = getLevel(),
					ReqRebirths = getRebirths(),
				}, "Creating your club")
				closeDialog()
				toast(result)
				if result.Ok then
					UIKit.Confetti(80)
					myClub = result.Club
					tab = "Club"
					render()
				end
			end)
		end,
	})

	-- Join with a code.
	local join = UIKit.Card({ Name = "JoinCode", Color = Colors.PanelDark, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.new(0.4, -8, 0, 210), Parent = page })
	UIKit.Label({ Text = "HAVE A CODE?", TextSize = 22, TextColor3 = Colors.Primary, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 28), Parent = join })
	UIKit.Label({ Text = "Private clubs are joined with their club code.", TextSize = 14, TextWrapped = true, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(12, 40), Size = UDim2.new(1, -24, 0, 36), Parent = join })
	local codeBox = textBox(join, "Club code", { Position = UDim2.fromOffset(16, 82), Size = UDim2.new(1, -32, 0, 48) }, 12)
	UIKit.Button({
		Text = "JOIN",
		Color = Colors.Primary,
		TextSize = 22,
		Position = UDim2.fromOffset(16, 142),
		Size = UDim2.new(1, -32, 0, 52),
		Parent = join,
		OnClick = function()
			findText = codeBox.Text
			joinClub({ ByCode = true, Code = codeBox.Text })
		end,
	})
	local browse = UIKit.Card({ Name = "Browse", Color = Colors.PanelDark, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.new(0.4, -8, 1, -222), Parent = page })
	UIKit.Label({ Text = "Or join a public club from TOP CLUBS or FIND CLUBS.", TextSize = 15, TextWrapped = true, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(12, 10), Size = UDim2.new(1, -24, 0, 44), Parent = browse })
	UIKit.Button({
		Text = "FIND CLUBS",
		Color = Colors.Accent,
		TextSize = 18,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.new(1, -32, 0, 46),
		Parent = browse,
		OnClick = function()
			tab = "Find"
			render()
		end,
	})
end

----------------------------------------------------------------------------------------------------
-- MY CLUB
----------------------------------------------------------------------------------------------------

function applyResult(result: any, good: string?)
	toast(result, good)
	if result.Ok and result.Club then
		myClub = result.Club
	end
	render()
end

-- Edit the name or the prefix (owner): a warning about the 30-day wait, then the box.
local function editField(field: string)
	local club = myClub
	if not club then
		return
	end
	local isName = field == "Name"
	local wait = if isName then club.NameWait or 0 else club.TagWait or 0
	local what = if isName then "club name" else "prefix"
	if wait > 0 then
		showInfo("Not yet", string.format("You can change the %s again in %s.", what, daysText(wait)))
		return
	end
	local rules = Config.Clubs
	local card = dialog(if isName then "Change club name" else "Change prefix", 290)
	UIKit.Label({
		Text = string.format("You can only change the %s once every %d days. Make sure you like it!", what, rules.RenameDays),
		TextSize = 16,
		TextWrapped = true,
		TextColor3 = Colors.Warning,
		Position = UDim2.fromOffset(20, 46),
		Size = UDim2.new(1, -40, 0, 50),
		Parent = card,
	})
	local limits = if isName then rules.NameLength else rules.TagLength
	local box = textBox(card, string.format("%d-%d letters", limits[1], limits[2]), { Position = UDim2.fromOffset(20, 104), Size = UDim2.new(1, -40, 0, 48) }, limits[2])
	box.Text = if isName then club.Name else club.Tag
	if not isName then
		box:GetPropertyChangedSignal("Text"):Connect(function()
			local upper = string.upper(box.Text)
			if upper ~= box.Text then
				box.Text = upper
			end
		end)
	end
	UIKit.Button({
		Text = "SAVE",
		Color = Colors.Good,
		TextSize = 18,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(0.5, -6, 1, -16),
		Size = UDim2.fromOffset(170, 50),
		Parent = card,
		OnClick = function()
			local text = box.Text
			task.spawn(function()
				local result = request("Rename", if isName then { Name = text } else { Tag = text }, "Saving")
				closeDialog()
				applyResult(result)
			end)
		end,
	})
	UIKit.Button({ Text = "Cancel", Color = Colors.PanelLight, TextSize = 18, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0.5, 6, 1, -16), Size = UDim2.fromOffset(150, 50), Parent = card, OnClick = closeDialog })
end

-- A member's options (from clicking their row).
local function memberOptions(m: any)
	local club = myClub
	if not club or m.UserId == LocalPlayer.UserId then
		return
	end
	local myRole = club.MyRole
	local canKick = myRole == "Owner" or (myRole == "CoLeader" and m.Role == "Member")
	local isOwner = myRole == "Owner"
	local options: { any } = {}
	if isOwner and m.Role == "Member" then
		table.insert(options, {
			Text = "Promote to Co-Leader",
			Color = Colors.Good,
			Run = function()
				confirm("Promote to Co-Leader?", string.format("%s will become a Co-Leader. Co-Leaders can kick members from the club.", m.Name), "PROMOTE", Colors.Good, function()
					task.spawn(function()
						applyResult(request("Promote", m.UserId, "Promoting"), m.Name .. " is now a Co-Leader!")
					end)
				end)
			end,
		})
	elseif isOwner and m.Role == "CoLeader" then
		table.insert(options, {
			Text = "Make a Member again",
			Color = Colors.Warning,
			Run = function()
				task.spawn(function()
					applyResult(request("Demote", m.UserId, "Updating"), m.Name .. " is a Member again.")
				end)
			end,
		})
	end
	if canKick then
		table.insert(options, {
			Text = "Kick from club",
			Color = Colors.Bad,
			Run = function()
				confirm("Kick " .. m.Name .. "?", string.format("%s will be removed from %s.", m.Name, club.Name), "KICK", Colors.Bad, function()
					task.spawn(function()
						applyResult(request("Kick", m.UserId, "Removing them"), m.Name .. " was removed.")
					end)
				end)
			end,
		})
	end
	local card = dialog(m.Name, 120 + #options * 58 + 20)
	UIKit.Label({ Text = string.format("%s  •  %s points", ROLE_NAMES[m.Role] or "Member", UIKit.Commas(m.Points or 0)), TextSize = 16, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(0, 42), Size = UDim2.new(1, 0, 0, 20), Parent = card })
	for i, opt in options do
		UIKit.Button({
			Text = opt.Text,
			Color = opt.Color,
			TextSize = 18,
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 70 + (i - 1) * 58),
			Size = UDim2.fromOffset(300, 48),
			Parent = card,
			OnClick = function()
				closeDialog()
				opt.Run()
			end,
		})
	end
	UIKit.Button({ Text = "Close", Color = Colors.PanelLight, TextSize = 16, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -12), Size = UDim2.fromOffset(140, 40), Parent = card, OnClick = closeDialog })
	if #options == 0 then
		UIKit.Label({ Text = "Nothing you can change for them.", TextSize = 15, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(0, 74), Size = UDim2.new(1, 0, 0, 20), Parent = card })
	end
end

local function renderMyClub(page: Frame, club: any)
	local isOwner = club.MyRole == "Owner"
	-- Banner.
	local banner = UIKit.Card({ Name = "Banner", Size = UDim2.new(1, 0, 0, 112), Color = Colors.PanelDark, Parent = page })
	UIKit.Gradient(banner, Color3.fromRGB(40, 120, 200), Color3.fromRGB(14, 40, 90))
	local crest = UIKit.Icon("Club", 84, { Position = UDim2.fromOffset(14, 14) })
	crest.Parent = banner
	UIKit.Label({
		Text = string.format("[%s] %s", club.Tag, club.Name),
		TextSize = 28,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(110, 10),
		Size = UDim2.new(1, -(if isOwner then 470 else 330), 0, 34),
		Parent = banner,
	})
	if isOwner then
		-- Edit name / prefix.
		local editRow = Instance.new("Frame")
		editRow.BackgroundTransparency = 1
		editRow.AnchorPoint = Vector2.new(1, 0)
		editRow.Position = UDim2.new(1, -224, 0, 10)
		editRow.Size = UDim2.fromOffset(136, 34)
		editRow.Parent = banner
		UIKit.Button({ Text = "Name", Color = Colors.PanelLight, TextSize = 14, Size = UDim2.fromOffset(64, 32), Parent = editRow, OnClick = function()
			editField("Name")
		end })
		UIKit.Button({ Text = "Prefix", Color = Colors.PanelLight, TextSize = 14, Position = UDim2.fromOffset(70, 0), Size = UDim2.fromOffset(66, 32), Parent = editRow, OnClick = function()
			editField("Tag")
		end })
	end
	UIKit.Label({
		Text = string.format("%s points this month  •  %d/%d members  •  %s", UIKit.Commas(club.Points or 0), club.Count or 0, club.Max, if club.Public then "Public" else "Private"),
		TextSize = 16,
		TextScaled = true,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(110, 48),
		Size = UDim2.new(1, -330, 0, 22),
		Parent = banner,
	})
	UIKit.Label({
		Text = "Requirements: " .. reqText(club),
		TextSize = 15,
		TextScaled = true,
		TextColor3 = Colors.Coin,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(110, 76),
		Size = UDim2.new(1, -330, 0, 20),
		Parent = banner,
	})
	local codeCard = UIKit.Card({ Name = "Code", Color = Colors.PanelDark, AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.fromOffset(200, 88), Parent = banner })
	UIKit.Label({ Text = "CLUB CODE", TextSize = 14, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, 0, 0, 18), Parent = codeCard })
	local codeText = Instance.new("TextBox") -- read-only, so it can be selected and copied
	codeText.Name = "CodeText"
	codeText.BackgroundTransparency = 1
	codeText.TextEditable = false
	codeText.ClearTextOnFocus = false
	codeText.Font = Fonts.Title
	codeText.TextSize = 28
	codeText.TextColor3 = Colors.Coin
	codeText.Text = club.Code or "------"
	codeText.Position = UDim2.fromOffset(0, 22)
	codeText.Size = UDim2.new(1, 0, 0, 32)
	codeText.Parent = codeCard
	if isOwner then
		UIKit.Button({
			Text = "New code",
			Color = Colors.PanelLight,
			TextSize = 13,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -4),
			Size = UDim2.fromOffset(110, 26),
			Parent = codeCard,
			OnClick = function()
				confirm("New club code?", "The old code stops working straight away.", "NEW CODE", Colors.Primary, function()
					task.spawn(function()
						applyResult(request("NewCode", nil, "Making a new code"), "New club code made.")
					end)
				end)
			end,
		})
	end

	-- Members (click one for options).
	local membersCard = UIKit.Card({
		Name = "Members",
		Color = Colors.PanelDark,
		Position = UDim2.fromOffset(0, 124),
		Size = UDim2.new(if isOwner then 0.62 else 1, if isOwner then -8 else 0, 1, -124),
		Parent = page,
	})
	UIKit.Label({ Text = "MEMBERS", TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(14, 8), Size = UDim2.fromOffset(110, 26), Parent = membersCard })
	UIKit.Button({
		Text = "?",
		Color = Colors.Accent,
		TextSize = 16,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 6),
		Size = UDim2.fromOffset(30, 30),
		CornerRadius = 15,
		Parent = membersCard,
		OnClick = function()
			showInfo("What are points?", POINTS_HELP)
		end,
	})
	UIKit.Button({
		Text = "DONATE BUBBLES",
		Color = Colors.Good,
		TextSize = 14,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -44, 0, 6),
		Size = UDim2.fromOffset(160, 30),
		Parent = membersCard,
		OnClick = donateDialog,
	})
	local list = scrollList(membersCard, 34)
	list.Size = UDim2.new(1, -12, 1, -94)
	list.Position = UDim2.fromOffset(6, 40)
	for i, m in club.Members or {} do
		local row = Instance.new("TextButton")
		row.Name = "Member"
		row.Text = ""
		row.AutoButtonColor = true
		row.Size = UDim2.new(1, 0, 0, 40)
		row.LayoutOrder = i
		row.BackgroundColor3 = Colors.PanelLight
		UIKit.Corner(row, 10)
		row.Parent = list
		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(12, 12)
		dot.Position = UDim2.fromOffset(10, 14)
		dot.BackgroundColor3 = if m.Online then Colors.Good else Colors.Disabled
		UIKit.Corner(dot, 6)
		dot.Parent = row
		local roleColor = if m.Role == "Owner" then Colors.Coin elseif m.Role == "CoLeader" then Colors.Primary else Colors.Text
		UIKit.Label({ Text = m.Name, TextSize = 17, TextColor3 = roleColor, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(30, 0), Size = UDim2.new(1, -250, 1, 0), Parent = row })
		UIKit.Label({ Text = ROLE_NAMES[m.Role] or "Member", TextSize = 13, TextColor3 = roleColor, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -112, 0, 0), Size = UDim2.fromOffset(80, 40), Parent = row })
		UIKit.Label({ Text = UIKit.Commas(m.Points or 0), TextSize = 15, TextColor3 = Colors.Coin, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 0), Size = UDim2.fromOffset(96, 40), Parent = row })
		row.Activated:Connect(function()
			memberOptions(m)
		end)
	end
	local closing = isOwner and (club.Count or 0) <= 1
	UIKit.Button({
		Text = if closing then "Close club" else "Leave club",
		Color = Colors.Bad,
		TextSize = 16,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.fromOffset(180, 44),
		Parent = membersCard,
		OnClick = function()
			local title = if closing then "Close your club?" else "Leave the club?"
			local message = if closing
				then string.format("%s will be deleted for good, and the %d Gems you spent on it won't come back.", club.Name, Config.Clubs.CreateCost)
				elseif isOwner then "You're the owner: the club goes to a Co-Leader (or the longest member)."
				else string.format("You'll leave %s. You can join another club after a minute.", club.Name)
			confirm(title, message, if closing then "CLOSE CLUB" else "LEAVE", Colors.Bad, function()
				task.spawn(function()
					local result = request("Leave", nil, if closing then "Closing your club" else "Leaving the club")
					toast(result)
					if result.Ok then
						myClub = nil
						tab = "Club"
						render()
					end
				end)
			end)
		end,
	})

	if isOwner then
		local settingsCard = UIKit.Card({ Name = "Settings", Color = Colors.PanelDark, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 124), Size = UDim2.new(0.38, -8, 1, -124), Parent = page })
		UIKit.Label({ Text = "SETTINGS", TextSize = 18, Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 22), Parent = settingsCard })
		local function startIndex(values: { any }, current: any): number
			return table.find(values, current) or 1
		end
		local getPublic = cycler(settingsCard, { true, false }, function(v)
			return if v then "Public" else "Private (code)"
		end, if club.Public then 1 else 2, { Position = UDim2.fromOffset(12, 38), Size = UDim2.new(1, -24, 0, 44) })
		local levels = levelValues()
		local getLevel = cycler(settingsCard, levels, levelText, startIndex(levels, club.ReqLevel), { Position = UDim2.fromOffset(12, 90), Size = UDim2.new(1, -24, 0, 44) })
		local getRebirths = cycler(settingsCard, REBIRTH_STEPS, rebirthText, startIndex(REBIRTH_STEPS, club.ReqRebirths), { Position = UDim2.fromOffset(12, 142), Size = UDim2.new(1, -24, 0, 44) })
		UIKit.Button({
			Text = "SAVE",
			Color = Colors.Good,
			TextSize = 18,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -10),
			Size = UDim2.new(1, -24, 0, 44),
			Parent = settingsCard,
			OnClick = function()
				task.spawn(function()
					applyResult(request("Settings", { Public = getPublic(), ReqLevel = getLevel(), ReqRebirths = getRebirths() }, "Saving"), "Club settings saved.")
				end)
			end,
		})
	end
end

----------------------------------------------------------------------------------------------------
-- LEADERBOARD and CHAT
----------------------------------------------------------------------------------------------------

local function renderLeaderboard(page: Frame, club: any)
	UIKit.Label({ Text = string.format("[%s] %s  -  Bubbles donated this month (%s)", club.Tag, club.Name, tostring(if club.Season then club.Season.Label else "")), TextSize = 18, Size = UDim2.new(1, -44, 0, 26), Parent = page })
	UIKit.Button({
		Text = "?",
		Color = Colors.Accent,
		TextSize = 16,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(30, 30),
		CornerRadius = 15,
		Parent = page,
		OnClick = function()
			showInfo("Monthly contest", POINTS_HELP)
		end,
	})
	UIKit.Label({ Text = resetText(club.Season) .. "  •  every club starts again from zero", TextSize = 14, TextColor3 = Colors.Warning, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(4, 30), Size = UDim2.new(1, -8, 0, 18), Parent = page })
	UIKit.Label({ Text = prizeText(), TextSize = 13, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(4, 48), Size = UDim2.new(1, -8, 0, 18), Parent = page })
	local list = scrollList(page, 74)
	local members: { any } = table.clone(club.Members or {})
	table.sort(members, function(a, b)
		if (a.Points or 0) ~= (b.Points or 0) then
			return (a.Points or 0) > (b.Points or 0)
		end
		return a.Name < b.Name
	end)
	for i, m in members do
		local mine = m.UserId == LocalPlayer.UserId
		local row = UIKit.Card({ Name = "Entry", Size = UDim2.new(1, 0, 0, 46), LayoutOrder = i, Color = if mine then UIKit.Darken(Colors.Coin, 0.55) else Colors.PanelLight, Parent = list })
		local rankColor = if i == 1 then Colors.Coin elseif i == 2 then Color3.fromRGB(210, 220, 235) elseif i == 3 then Color3.fromRGB(230, 150, 90) else Colors.TextDim
		UIKit.Label({ Text = "#" .. i, TextSize = 20, TextColor3 = rankColor, Position = UDim2.fromOffset(8, 0), Size = UDim2.fromOffset(50, 46), Parent = row })
		UIKit.Label({ Text = m.Name .. (if mine then " (you)" else ""), TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(64, 0), Size = UDim2.new(1, -260, 1, 0), Parent = row })
		UIKit.Label({ Text = UIKit.Commas(m.Points or 0) .. " pts", TextSize = 18, TextColor3 = Colors.Coin, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 0), Size = UDim2.fromOffset(180, 46), Parent = row })
	end
end

local chatList: ScrollingFrame? = nil

local function addChatLine(list: ScrollingFrame, msg: any, order: number)
	local mine = msg.U == LocalPlayer.UserId
	local line = UIKit.Label({
		Name = "Line",
		Text = string.format('<font color="#%s">%s:</font> %s', (if mine then Colors.Coin else Colors.Primary):ToHex(), tostring(msg.N), tostring(msg.T)),
		RichText = true,
		TextSize = 17,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -10, 0, 22),
		LayoutOrder = order,
		Parent = list,
	})
	local _ = line
end

local function escape(text: string): string
	return (string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
end

local function renderChat(page: Frame)
	local list = scrollList(page, 0)
	list.Size = UDim2.new(1, 0, 1, -62)
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	chatList = list
	local function fill()
		clear(list)
		for i, msg in chatLog do
			addChatLine(list, msg, i)
		end
		task.defer(function()
			list.CanvasPosition = Vector2.new(0, 1e6)
		end)
	end
	if chatLoaded then
		fill()
	else
		UIKit.Label({ Text = "Loading chat...", TextSize = 18, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 40), Parent = list })
		task.spawn(function()
			local result = request("ChatHistory")
			if result.Ok then
				chatLog = {}
				for _, msg in result.Messages or {} do
					table.insert(chatLog, { U = msg.U, N = escape(tostring(msg.N)), T = escape(tostring(msg.T)), At = msg.At })
				end
				chatLoaded = true
			end
			if chatList == list then
				fill()
			end
		end)
	end
	local box = textBox(page, "Say something to your club...", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, -140, 0, 50) }, Config.Clubs.ChatLength)
	local function send()
		local text = box.Text
		if text == "" then
			return
		end
		box.Text = ""
		task.spawn(function()
			local result = request("Chat", text)
			if not result.Ok then
				UIKit.Toast(result.Error or "Couldn't send that.", "Info")
			end
		end)
	end
	box.FocusLost:Connect(function(enter)
		if enter then
			send()
		end
	end)
	UIKit.Button({ Text = "SEND", Color = Colors.Primary, TextSize = 20, AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(1, 1), Size = UDim2.fromOffset(128, 50), Parent = page, OnClick = send })
end

----------------------------------------------------------------------------------------------------
-- FIND CLUBS (with filters)
----------------------------------------------------------------------------------------------------

local function loadFriends()
	if friends then
		return
	end
	local set: { [number]: boolean } = {}
	friends = set
	pcall(function()
		local pages = Players:GetFriendsAsync(LocalPlayer.UserId)
		while true do
			for _, f in pages:GetCurrentPage() do
				set[f.Id] = true
			end
			if pages.IsFinished then
				break
			end
			pages:AdvanceToNextPageAsync()
		end
	end)
end

local function passesFilters(club: any): boolean
	if filters.Type == "Public" and not club.Public then
		return false
	elseif filters.Type == "Private" and club.Public then
		return false
	end
	if filters.CanJoin and not meetsReq(club) then
		return false
	end
	if filters.Space and (club.Count or 0) >= (club.Max or Config.Clubs.MaxMembers) then
		return false
	end
	if filters.Friends then
		local set = friends or {}
		local any = false
		for _, id in club.MemberIds or {} do
			if set[id] then
				any = true
				break
			end
		end
		if not any then
			return false
		end
	end
	return true
end

local function filterCount(): number
	return (if filters.Type ~= "Any" then 1 else 0) + (if filters.Friends then 1 else 0) + (if filters.CanJoin then 1 else 0) + (if filters.Space then 1 else 0)
end

local function renderFilters(page: Frame)
	UIKit.Button({
		Text = "< Back",
		Color = Colors.PanelLight,
		TextSize = 18,
		Size = UDim2.fromOffset(130, 44),
		Parent = page,
		OnClick = function()
			tab = "Find"
			render()
		end,
	})
	UIKit.Label({ Text = "FILTERS", TextSize = 24, TextColor3 = Colors.Coin, Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, 0, 0, 36), Parent = page })
	local y = 62
	local function row(title: string, values: { string }, get: () -> string, set: (string) -> ())
		UIKit.Label({ Text = title, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(10, y), Size = UDim2.fromOffset(260, 44), Parent = page })
		for i, v in values do
			local selected = get() == v
			UIKit.Button({
				Text = v,
				Color = if selected then Colors.Primary else Colors.PanelLight,
				TextSize = 16,
				Position = UDim2.fromOffset(270 + (i - 1) * 180, y),
				Size = UDim2.fromOffset(170, 44),
				Parent = page,
				OnClick = function()
					set(v)
					render()
				end,
			})
		end
		y += 58
	end
	row("Type", { "Any", "Public", "Private" }, function()
		return filters.Type
	end, function(v)
		filters.Type = v
	end)
	row("Friends", { "Any", "Has my friends" }, function()
		return if filters.Friends then "Has my friends" else "Any"
	end, function(v)
		filters.Friends = v ~= "Any"
		if filters.Friends then
			task.spawn(loadFriends)
		end
	end)
	row("Requirements", { "Any", "I can join" }, function()
		return if filters.CanJoin then "I can join" else "Any"
	end, function(v)
		filters.CanJoin = v ~= "Any"
	end)
	row("Space", { "Any", "Not full" }, function()
		return if filters.Space then "Not full" else "Any"
	end, function(v)
		filters.Space = v ~= "Any"
	end)
	UIKit.Button({
		Text = "Clear filters",
		Color = Colors.Bad,
		TextSize = 16,
		Position = UDim2.fromOffset(270, y + 6),
		Size = UDim2.fromOffset(170, 44),
		Parent = page,
		OnClick = function()
			filters = { Type = "Any", Friends = false, CanJoin = false, Space = false }
			render()
		end,
	})
	UIKit.Button({
		Text = "SHOW CLUBS",
		Color = Colors.Good,
		TextSize = 18,
		Position = UDim2.fromOffset(450, y + 6),
		Size = UDim2.fromOffset(200, 44),
		Parent = page,
		OnClick = function()
			tab = "Find"
			render()
		end,
	})
end

local function renderFind(page: Frame, token: number)
	local box = textBox(page, "Type a club name (or a club code)", { Size = UDim2.new(1, -220, 0, 50) }, 30)
	box.Text = findText
	local count = filterCount()
	UIKit.Button({
		Text = if count > 0 then string.format("Filters (%d)", count) else "Filters",
		Color = if count > 0 then Colors.Accent else Colors.PanelLight,
		TextSize = 16,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -108, 0, 0),
		Size = UDim2.fromOffset(104, 50),
		Parent = page,
		OnClick = function()
			findText = box.Text
			tab = "Filters"
			render()
		end,
	})
	local results = scrollList(page, 62)
	local searchToken = 0
	local function search()
		searchToken += 1
		local mine = searchToken
		findText = box.Text
		local text = string.gsub(box.Text, "^%s+", "")
		clear(results)
		if text == "" then
			UIKit.Label({ Text = "Start typing: clubs starting with it show up here, A to Z.", TextSize = 18, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 50), Parent = results })
			return
		end
		UIKit.Label({ Name = "Searching", Text = "Searching...", TextSize = 18, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 50), Parent = results })
		task.spawn(function()
			if filters.Friends then
				loadFriends()
			end
			local result = request("Find", text)
			if token ~= renderToken or mine ~= searchToken then
				return
			end
			clear(results)
			if not result.Ok then
				UIKit.Label({ Text = result.Error or "Couldn't search.", TextSize = 18, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 50), Parent = results })
				return
			end
			local shown = 0
			for _, club in result.Clubs or {} do
				if club.ByCode or passesFilters(club) then
					shown += 1
					clubRow(results, club, shown)
				end
			end
			if shown == 0 then
				UIKit.Label({ Text = if #(result.Clubs or {}) > 0 then "No clubs match your filters." else "No clubs found.", TextSize = 18, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 50), Parent = results })
			end
		end)
	end
	-- Live: search a moment after typing stops.
	local typedAt = 0
	box:GetPropertyChangedSignal("Text"):Connect(function()
		typedAt = os.clock()
		local at = typedAt
		task.delay(0.45, function()
			if at == typedAt and token == renderToken then
				search()
			end
		end)
	end)
	box.FocusLost:Connect(function(enter)
		if enter then
			search()
		end
	end)
	UIKit.Button({ Text = "FIND", Color = Colors.Primary, TextSize = 20, AnchorPoint = Vector2.new(1, 0), Position = UDim2.fromScale(1, 0), Size = UDim2.fromOffset(100, 50), Parent = page, OnClick = search })
	search()
end

----------------------------------------------------------------------------------------------------
-- Tabs
----------------------------------------------------------------------------------------------------

local function tabList(): { { string } }
	if myClub or inClubPerMeta() then
		return { { "Club", "MY CLUB" }, { "Top", "TOP CLUBS" }, { "Find", "FIND CLUBS" }, { "Board", "LEADERBOARD" }, { "Chat", "CHAT" } }
	end
	return { { "Club", "CREATE CLUB" }, { "Top", "TOP CLUBS" }, { "Find", "FIND CLUBS" } }
end

-- Does your save say you're in a club? (Known from login, before the club's details arrive.)
function inClubPerMeta(): boolean
	local meta = ClientState.Meta :: any
	return meta ~= nil and type(meta.ClubId) == "string" and meta.ClubId ~= ""
end

local fetching = false
function fetchMine()
	if fetching then
		return
	end
	fetching = true
	task.spawn(function()
		local result = request("Mine")
		fetching = false
		if result.Ok then
			myClub = result.Club
			if UIKit.IsWindowOpen("Clubs") and (tab == "Club" or tab == "Board") then
				render()
			end
		end
	end)
end

render = function()
	renderToken += 1
	local token = renderToken
	closeDialog()
	-- Tabs that need a club fall back to MY CLUB when you leave one.
	if not myClub and (tab == "Board" or tab == "Chat") then
		tab = "Club"
	end
	clear(tabsRow)
	local tabs = tabList()
	local width = math.floor((868 - (#tabs - 1) * 8) / #tabs)
	for i, def in tabs do
		local selected = def[1] == tab or (tab == "Filters" and def[1] == "Find")
		UIKit.Button({
			Name = "Tab" .. def[1],
			Text = def[2],
			Color = if selected then Colors.Primary else Colors.PanelLight,
			TextSize = 16,
			Size = UDim2.fromOffset(math.min(width, 200), 44),
			LayoutOrder = i,
			Parent = tabsRow,
			OnClick = function()
				tab = def[1]
				render()
			end,
		})
	end
	clear(pageHolder)
	chatList = nil
	local page = Instance.new("Frame")
	page.Name = tab .. "Page"
	page.BackgroundTransparency = 1
	page.Size = UDim2.fromScale(1, 1)
	page.Parent = pageHolder
	if tab == "Club" then
		if myClub then
			renderMyClub(page, myClub)
		elseif inClubPerMeta() then
			-- We know you're in a club but haven't got its details yet: dots, never the Create page.
			dotsPage(page, "Loading your club")
			fetchMine()
		else
			renderCreate(page)
		end
	elseif tab == "Top" then
		dotsPage(page, "Loading clubs")
		task.spawn(function()
			local result = request("Top")
			if token ~= renderToken then
				return
			end
			clear(page)
			if result.Ok then
				UIKit.Label({ Text = string.format("%s CONTEST  -  clubs with the most Bubbles donated", string.upper(tostring(if result.Season then result.Season.Label else ""))), TextSize = 17, TextColor3 = Colors.Coin, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(4, 0), Size = UDim2.new(1, -44, 0, 24), Parent = page })
				UIKit.Button({
					Text = "?",
					Color = Colors.Accent,
					TextSize = 16,
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.fromScale(1, 0),
					Size = UDim2.fromOffset(30, 30),
					CornerRadius = 15,
					Parent = page,
					OnClick = function()
						showInfo("Monthly contest", POINTS_HELP)
					end,
				})
				UIKit.Label({ Text = resetText(result.Season) .. "  •  every club starts again from zero", TextSize = 13, TextColor3 = Colors.Warning, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(4, 24), Size = UDim2.new(1, -8, 0, 16), Parent = page })
				UIKit.Label({ Text = prizeText(), TextSize = 13, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, TextScaled = true, Position = UDim2.fromOffset(4, 42), Size = UDim2.new(1, -8, 0, 16), Parent = page })
			end
			local list = scrollList(page, 66)
			if not result.Ok or #(result.Clubs or {}) == 0 then
				UIKit.Label({ Text = if result.Ok then "No clubs yet. Be the first to make one!" else (result.Error or "Couldn't load clubs."), TextSize = 20, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 60), Parent = list })
				return
			end
			for i, club in result.Clubs do
				clubRow(list, club, i)
			end
		end)
	elseif tab == "Find" then
		renderFind(page, token)
	elseif tab == "Filters" then
		renderFilters(page)
	elseif tab == "Board" and myClub then
		renderLeaderboard(page, myClub)
	elseif tab == "Chat" and myClub then
		renderChat(page)
	end
end

function ClubsUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, screenRoot = UIKit.CreateScreen("ClubsUI", 10)
	local _window, windowContent = UIKit.Window({
		Name = "Clubs",
		Title = "Clubs",
		Size = Vector2.new(900, 580),
		Parent = screenRoot,
	})
	content = windowContent
	tabsRow = Instance.new("Frame")
	tabsRow.Name = "Tabs"
	tabsRow.BackgroundTransparency = 1
	tabsRow.Size = UDim2.new(1, 0, 0, 46)
	tabsRow.Parent = content
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabsRow
	pageHolder = Instance.new("Frame")
	pageHolder.Name = "Pages"
	pageHolder.BackgroundTransparency = 1
	pageHolder.Position = UDim2.fromOffset(0, 58)
	pageHolder.Size = UDim2.new(1, 0, 1, -58)
	pageHolder.Parent = content
	-- Dialogs dim the window under them.
	overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.BackgroundColor3 = Colors.Ink
	overlay.BackgroundTransparency = 0.35
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 50
	overlay.Visible = false
	overlay.Active = true
	overlay.Parent = content

	UIKit.RegisterWindow("Clubs", {
		Open = function()
			render()
			-- Then the real state from the server (it may have changed elsewhere).
			task.spawn(function()
				local result = request("Mine")
				if result.Ok then
					local old, new = myClub, result.Club
					local same = (old == nil and new == nil)
						or (old ~= nil and new ~= nil and old.Id == new.Id and old.Points == new.Points and old.Count == new.Count and old.MyRole == new.MyRole and old.Name == new.Name and old.Tag == new.Tag)
					myClub = new
					-- Only redraw when something actually changed (no flicker).
					if not same and not overlay.Visible then
						render()
					end
				end
			end)
		end,
	})
	-- Know your club before you open the window (so it never has to show the Create page first).
	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" then
			if inClubPerMeta() and not myClub then
				fetchMine()
			elseif not inClubPerMeta() and myClub and not busy then
				myClub = nil
			end
		end
	end)
	if inClubPerMeta() then
		fetchMine()
	end
	Remotes.Event("ClubState").OnClientEvent:Connect(function(club)
		local joinedOrLeft = (myClub == nil) ~= (club == nil) or (myClub and club and myClub.Id ~= club.Id)
		myClub = club
		if joinedOrLeft then
			chatLog = {}
			chatLoaded = false
		end
		if UIKit.IsWindowOpen("Clubs") and (tab == "Club" or tab == "Board" or joinedOrLeft) and not overlay.Visible then
			render()
		end
	end)
	Remotes.Event("ClubChat").OnClientEvent:Connect(function(msg)
		if type(msg) ~= "table" then
			return
		end
		local entry = { U = msg.U, N = escape(tostring(msg.N)), T = escape(tostring(msg.T)), At = msg.At }
		table.insert(chatLog, entry)
		while #chatLog > Config.Clubs.ChatKeep do
			table.remove(chatLog, 1)
		end
		local list = chatList
		if list and list.Parent then
			addChatLine(list, entry, #chatLog + 1000)
			task.defer(function()
				list.CanvasPosition = Vector2.new(0, 1e6)
			end)
		end
	end)
end

return ClubsUI
