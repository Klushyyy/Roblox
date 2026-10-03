--[[
	PollUI - the community poll card (admin panel > Global > Poll, AdminServer "GlobalPoll").
	A card near the bottom of the screen with the question, one button per answer and a countdown.
	Tap an answer to vote (tap another to change your mind); the card goes when the poll ends and the
	results come up as a banner everywhere.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))

local PollUI = {}

local Colors = UIKit.Theme.Colors

local initialized = false

function PollUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, root = UIKit.CreateScreen("PollUI", 12)
	local card = UIKit.Card({
		Name = "Poll",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -130),
		Size = UDim2.fromOffset(460, 170),
		Color = Colors.PanelDark,
		Parent = root,
	})
	card.Visible = false
	UIKit.Stroke(card, Colors.Primary, 3, 0)
	local title = UIKit.Label({ Text = "POLL", TextSize = 16, TextColor3 = Colors.Primary, Position = UDim2.fromOffset(14, 6), Size = UDim2.fromOffset(120, 20), TextXAlignment = Enum.TextXAlignment.Left, Parent = card })
	local timer = UIKit.Label({ Text = "", TextSize = 16, TextColor3 = Colors.TextDim, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 6), Size = UDim2.fromOffset(120, 20), TextXAlignment = Enum.TextXAlignment.Right, Parent = card })
	local question = UIKit.Label({ Text = "", TextSize = 20, TextWrapped = true, TextScaled = true, Position = UDim2.fromOffset(14, 28), Size = UDim2.new(1, -28, 0, 48), Parent = card })
	local row = Instance.new("Frame")
	row.Name = "Answers"
	row.BackgroundTransparency = 1
	row.Position = UDim2.fromOffset(14, 84)
	row.Size = UDim2.new(1, -28, 0, 72)
	row.Parent = card
	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.fromOffset(8, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = row
	local _ = title

	local currentId: string? = nil
	local endsAt = 0
	local buttons: { TextButton } = {}

	local voteRemote = ReplicatedStorage:WaitForChild("GlobalPollVote", 30)
	local pollRemote = ReplicatedStorage:WaitForChild("GlobalPoll", 30)
	if not pollRemote or not voteRemote then
		return
	end

	local function show(id: string, text: string, options: { string }, closesAt: number)
		currentId = id
		endsAt = closesAt
		question.Text = text
		for _, b in buttons do
			b:Destroy()
		end
		table.clear(buttons)
		local count = math.max(1, #options)
		-- Two answers side by side; three or four in two rows of two.
		layout.CellSize = if count <= 2 then UDim2.new(1 / count, -8, 0, 64) else UDim2.new(0.5, -4, 0, 32)
		for i, option in options do
			local b = UIKit.Button({
				Text = tostring(option),
				Color = Colors.PanelLight,
				TextSize = 16,
				LayoutOrder = i,
				Parent = row,
				OnClick = function()
					if currentId ~= id then
						return
					end
					voteRemote:FireServer(id, i)
					for j, other in buttons do
						UIKit.SetButtonColor(other, if j == i then Colors.Good else Colors.PanelLight)
					end
				end,
			})
			table.insert(buttons, b)
		end
		card.Visible = true
		UIKit.Bounce(card)
	end

	pollRemote.OnClientEvent:Connect(function(kind, id, text, options, closesAt)
		if kind == "Start" and type(id) == "string" and type(options) == "table" then
			show(id, tostring(text), options, tonumber(closesAt) or os.time())
		elseif kind == "End" and id == currentId then
			currentId = nil
			card.Visible = false
		end
	end)

	task.spawn(function()
		while true do
			if card.Visible then
				local left = math.max(0, endsAt - os.time())
				timer.Text = string.format("%d s left", left)
				if left <= 0 and currentId then
					timer.Text = "Counting votes..."
				end
			end
			task.wait(0.5)
		end
	end)
end

return PollUI
