--[[
	PollUI - the community poll card (admin panel > Global > Poll, AdminServer "GlobalPoll").

	  * A poll starts: a card comes up near the bottom with the question, an answer button each and
	    a countdown. Tap an answer to vote (tap another to change your mind).
	  * Once you've voted the card tucks itself away, leaving a small "POLL" tab with an up arrow to
	    bring it back.
	  * When every server's votes are in ("Result"), the card comes back up as POLL FINISHED with the
	    results (answer, votes, percent) and an X. Closed, it's gone for good.
	  * It sits under every window (and hides while one is open).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Client = script.Parent
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local UIKit = require(Client:WaitForChild("UIKit"))

local PollUI = {}

local Colors = UIKit.Theme.Colors

local CARD_H = 180
local TAB_H = 34

local initialized = false

-- The event countdown pill (admin panel > Global > Event countdown): top-left, under every window.
-- "ADMIN ABUSE starts in 23:59:30", then "ADMIN ABUSE IS LIVE NOW!" for the hour after.
local function setupCountdown()
	local remote = ReplicatedStorage:WaitForChild("GlobalCountdown", 30)
	if not remote then
		return
	end
	local _gui, root = UIKit.CreateScreen("EventCountdown", 7)
	local pill = Instance.new("Frame")
	pill.Name = "Countdown"
	pill.Size = UDim2.fromOffset(300, 46)
	pill.BackgroundColor3 = Colors.PanelDark
	pill.Visible = false
	UIKit.Corner(pill, 14)
	local stroke = UIKit.Stroke(pill, Colors.Coin, 3, 0)
	pill.Parent = root
	local title = UIKit.Label({ Text = "", TextSize = 15, TextScaled = true, TextColor3 = Colors.Coin, Position = UDim2.fromOffset(8, 3), Size = UDim2.new(1, -16, 0, 18), Parent = pill })
	local clock = UIKit.Label({ Text = "", TextSize = 22, Position = UDim2.fromOffset(8, 20), Size = UDim2.new(1, -16, 0, 24), Parent = pill })
	local info: { Name: string, EndsAt: number, Live: number }? = nil
	remote.OnClientEvent:Connect(function(kind, name, endsAt, liveMinutes)
		if kind == "Set" and type(name) == "string" and type(endsAt) == "number" then
			info = { Name = string.upper(name), EndsAt = endsAt, Live = (tonumber(liveMinutes) or 60) * 60 }
		else
			info = nil
		end
	end)
	task.spawn(function()
		while true do
			local current = info
			local nowT = Config.Now()
			if current and nowT < current.EndsAt + current.Live then
				local inset = UIKit.TopInset()
				local safe = UIKit.SafeInsets()
				pill.Position = UDim2.fromOffset(16 + math.floor(safe.Left * 0.5), math.floor(inset + 8))
				pill.Visible = true
				if nowT < current.EndsAt then
					local left = current.EndsAt - nowT
					title.Text = current.Name .. " STARTS IN"
					title.TextColor3 = Colors.Coin
					stroke.Color = Colors.Coin
					clock.Text = if left >= 86400
						then string.format("%dd %02d:%02d:%02d", left // 86400, (left % 86400) // 3600, (left % 3600) // 60, left % 60)
						else string.format("%02d:%02d:%02d", left // 3600, (left % 3600) // 60, left % 60)
				else
					title.Text = current.Name
					title.TextColor3 = Colors.Good
					stroke.Color = Colors.Good
					clock.Text = "IS LIVE NOW!"
				end
			else
				pill.Visible = false
			end
			task.wait(0.5)
		end
	end)
end

function PollUI.Init()
	if initialized then
		return
	end
	initialized = true
	task.spawn(setupCountdown)

	-- Display order 8: under every window (10+), over the HUD.
	local _gui, root = UIKit.CreateScreen("PollUI", 8)
	local holder = Instance.new("Frame")
	holder.Name = "PollHolder"
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, -110)
	holder.Size = UDim2.fromOffset(480, CARD_H + TAB_H)
	holder.BackgroundTransparency = 1
	holder.ClipsDescendants = true
	holder.Visible = false
	holder.Parent = root

	local slider = Instance.new("Frame")
	slider.Name = "Slider"
	slider.BackgroundTransparency = 1
	slider.Size = UDim2.new(1, 0, 0, CARD_H + TAB_H)
	slider.Parent = holder

	-- The pull tab (only while tucked away).
	local tab = Instance.new("TextButton")
	tab.Name = "PullTab"
	tab.Text = ""
	tab.AutoButtonColor = false
	tab.AnchorPoint = Vector2.new(0.5, 0)
	tab.Position = UDim2.new(0.5, 0, 0, 0)
	tab.Size = UDim2.fromOffset(150, TAB_H + 12)
	tab.BackgroundColor3 = Colors.Primary
	UIKit.Corner(tab, 12)
	UIKit.Stroke(tab, Colors.Ink, 2)
	local tabLabel = UIKit.Label({ Text = "POLL  ^", TextSize = 18, Size = UDim2.new(1, 0, 0, TAB_H), Parent = tab })
	tab.Parent = slider

	local card = UIKit.Card({
		Name = "Poll",
		-- (inset: the holder clips to a rectangle, which cut the blue outline off at the rounded corners)
		Position = UDim2.fromOffset(4, TAB_H + 2),
		Size = UDim2.new(1, -8, 0, CARD_H - 6),
		Color = Colors.PanelDark,
		Parent = slider,
	})
	UIKit.Stroke(card, Colors.Primary, 3, 0)
	local title = UIKit.Label({ Text = "POLL", TextSize = 16, TextColor3 = Colors.Primary, Position = UDim2.fromOffset(14, 6), Size = UDim2.fromOffset(200, 20), TextXAlignment = Enum.TextXAlignment.Left, Parent = card })
	local timer = UIKit.Label({ Text = "", TextSize = 16, TextColor3 = Colors.TextDim, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -52, 0, 6), Size = UDim2.fromOffset(150, 20), TextXAlignment = Enum.TextXAlignment.Right, Parent = card })
	local question = UIKit.Label({ Text = "", TextSize = 20, TextWrapped = true, TextScaled = true, Position = UDim2.fromOffset(14, 30), Size = UDim2.new(1, -28, 0, 44), Parent = card })
	local row = Instance.new("Frame")
	row.Name = "Answers"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(14, 82)
	row.Size = UDim2.new(1, -28, 0, 86)
	row.Parent = card
	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.fromOffset(8, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row
	local hideButton = UIKit.Button({
		Text = "v",
		Color = Colors.PanelLight,
		TextSize = 16,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 6),
		Size = UDim2.fromOffset(36, 30),
		Parent = card,
	})

	local currentId: string? = nil
	local endsAt = 0
	local phase = "None" -- "Voting" | "Counting" | "Result"
	local closed: { [string]: boolean } = {}
	local buttons: { GuiObject } = {}

	local voteRemote = ReplicatedStorage:WaitForChild("GlobalPollVote", 30)
	local pollRemote = ReplicatedStorage:WaitForChild("GlobalPoll", 30)
	if not pollRemote or not voteRemote then
		return
	end

	local function setTucked(value: boolean, instant: boolean?)
		tab.Visible = value
		local y = if value then CARD_H else 0
		local goal = { Position = UDim2.fromOffset(0, y) }
		if instant then
			slider.Position = goal.Position
		else
			TweenService:Create(slider, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
		end
	end

	local function clearAnswers()
		for _, b in buttons do
			b:Destroy()
		end
		table.clear(buttons)
	end

	local function showVoting(id: string, text: string, options: { string }, closesAt: number)
		currentId = id
		endsAt = closesAt
		phase = "Voting"
		title.Text = "POLL"
		title.TextColor3 = Colors.Primary
		question.Text = text
		hideButton.Visible = true
		clearAnswers()
		local count = math.max(1, #options)
		layout.CellSize = if count <= 2 then UDim2.new(1 / count, -8, 0, 70) else UDim2.new(0.5, -4, 0, 38)
		for i, option in options do
			local b = UIKit.Button({
				Text = tostring(option),
				Color = Colors.PanelLight,
				TextSize = 16,
				LayoutOrder = i,
				Parent = row,
				OnClick = function()
					if currentId ~= id or phase ~= "Voting" then
						return
					end
					voteRemote:FireServer(id, i)
					for j, other in buttons do
						UIKit.SetButtonColor(other, if j == i then Colors.Good else Colors.PanelLight)
					end
					-- Voted: tuck away (the tab brings it back to change your vote).
					task.delay(0.4, function()
						if currentId == id and phase == "Voting" then
							setTucked(true)
						end
					end)
				end,
			})
			table.insert(buttons, b)
		end
		holder.Visible = true
		setTucked(false, true)
		UIKit.Bounce(card)
	end

	local function showResult(id: string, text: string, options: { string }, counts: { number })
		if closed[id] then
			return
		end
		currentId = id
		phase = "Result"
		title.Text = "POLL FINISHED"
		title.TextColor3 = Colors.Good
		timer.Text = ""
		question.Text = text
		hideButton.Visible = true
		clearAnswers()
		local total = 0
		for i = 1, #options do
			total += tonumber(counts[i]) or 0
		end
		layout.CellSize = if #options <= 2 then UDim2.new(1 / #options, -8, 0, 70) else UDim2.new(0.5, -4, 0, 38)
		for i, option in options do
			local n = tonumber(counts[i]) or 0
			local pct = if total > 0 then math.floor(n / total * 100 + 0.5) else 0
			local cell = UIKit.Card({ Name = "Result", LayoutOrder = i, Color = Colors.PanelLight, Parent = row })
			-- A bar for the share of votes.
			local bar = Instance.new("Frame")
			bar.BackgroundColor3 = Colors.Good
			bar.BackgroundTransparency = 0.45
			bar.Size = UDim2.fromScale(pct / 100, 1)
			UIKit.Corner(bar, 10)
			bar.Parent = cell
			UIKit.Label({ Text = string.format("%s  %d (%d%%)", tostring(option), n, pct), TextSize = 16, TextScaled = true, Size = UDim2.new(1, -10, 1, -6), Position = UDim2.fromOffset(5, 3), Parent = cell })
			table.insert(buttons, cell)
		end
		timer.Text = string.format("%d vote%s", total, if total == 1 then "" else "s")
		holder.Visible = true
		setTucked(false)
		UIKit.Bounce(card)
		UIKit.PlaySound("Sparkle")
	end

	local function close()
		if currentId then
			closed[currentId] = true
		end
		currentId = nil
		phase = "None"
		holder.Visible = false
	end

	tab.Activated:Connect(function()
		setTucked(false)
	end)
	hideButton.Activated:Connect(function()
		if phase == "Result" then
			close()
		else
			setTucked(true)
		end
	end)

	pollRemote.OnClientEvent:Connect(function(kind, id, text, options, extra)
		if kind == "Start" and type(id) == "string" and type(options) == "table" then
			showVoting(id, tostring(text), options, tonumber(extra) or Config.Now())
		elseif kind == "Close" and id == currentId then
			close() -- a show poll: gone the second it ends
		elseif kind == "End" and id == currentId and phase == "Voting" then
			phase = "Counting"
			timer.Text = "Counting votes..."
			for _, b in buttons do
				UIKit.SetDisabled(b, true)
			end
		elseif kind == "Result" and type(id) == "string" and type(options) == "table" and type(extra) == "table" then
			showResult(id, tostring(text), options, extra)
		end
	end)

	task.spawn(function()
		while true do
			-- Under every window: out of the way while one is open.
			if currentId then
				holder.Visible = not UIKit.IsWindowOpen()
			end
			if phase == "Voting" then
				local left = math.max(0, endsAt - Config.Now())
				timer.Text = string.format("%d s left", left)
				tabLabel.Text = string.format("POLL  ^  %ds", left)
			elseif phase == "Counting" then
				tabLabel.Text = "POLL  ^"
			end
			hideButton.Text = if phase == "Result" then "X" else "v"
			local label = hideButton:FindFirstChild("Label", true)
			if label and label:IsA("TextLabel") then
				label.Text = hideButton.Text
			end
			task.wait(0.5)
		end
	end)
end

return PollUI
