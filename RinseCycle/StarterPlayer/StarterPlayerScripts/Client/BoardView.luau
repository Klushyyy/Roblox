--[[
	BoardView - the lobby leaderboards on this player's screen.

	  * Scrolling: a SurfaceGui only takes the mouse wheel / a finger when it lives in PlayerGui, so
	    each leaderboard's SurfaceGui (tag "LeaderboardBoard", drawn by LeaderboardService) is moved
	    into PlayerGui and adorned back onto its board. The server keeps drawing into it as before.
	  * Your position: under every page, a highlighted row with your rank, name and score
	    ("#515  you  12,345"), from the player attribute "Lb_<board><page>" = "<rank>|<value>".
	    Rank 0 with a value means you're further down than the board looks (past #1000).
	  * Your row in the top 100 is lit up too.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))

local LocalPlayer = Players.LocalPlayer

local BoardView = {}

local GOLD = Color3.fromRGB(255, 205, 70)
local INK = Color3.fromRGB(10, 30, 60)

local initialized = false
local guis: { [Instance]: SurfaceGui } = {}

-- The SurfaceGui of a leaderboard part (wherever it lives now). Effects uses this for the arrows.
function BoardView.GuiOf(board: Instance): SurfaceGui?
	return guis[board]
end

local function label(props: { [string]: any }, parent: Instance): TextLabel
	local lbl = Instance.new("TextLabel")
	lbl.BackgroundTransparency = 1
	lbl.Font = Enum.Font.LuckiestGuy
	lbl.TextScaled = true
	lbl.TextColor3 = INK
	for k, v in props do
		(lbl :: any)[k] = v
	end
	lbl.Parent = parent
	return lbl
end

-- Lights up this player's own row among the top 100 (rows carry a UserId attribute).
local function watchList(list: Instance)
	local function paint(row: Instance)
		if row:IsA("Frame") and row:GetAttribute("UserId") == LocalPlayer.UserId and not row:FindFirstChild("YouOutline") then
			row.BackgroundTransparency = 0.75
			local outline = Instance.new("UIStroke")
			outline.Name = "YouOutline"
			outline.Thickness = 3
			outline.Color = GOLD
			outline.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			outline.Parent = row
		end
	end
	for _, row in list:GetChildren() do
		paint(row)
	end
	list.ChildAdded:Connect(paint)
end

-- The "you" row under one page.
local function addYouRow(page: Frame, id: string)
	local hasDots = page:FindFirstChild("PageDots") ~= nil
	local row = Instance.new("Frame")
	row.Name = "YouRow"
	row.AnchorPoint = Vector2.new(0, 1)
	row.Position = UDim2.new(0, 0, 1, if hasDots then -30 else -2)
	row.Size = UDim2.new(1, 0, 0, 40)
	row.BackgroundColor3 = GOLD
	row.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = row
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(255, 245, 200)
	stroke.Parent = row
	local rankLabel = label({ Name = "Rank", Size = UDim2.new(0, 110, 1, -6), Position = UDim2.new(0, 6, 0, 3) }, row)
	label({
		Name = "Player",
		Size = UDim2.new(1, -290, 1, -6),
		Position = UDim2.new(0, 124, 0, 3),
		Text = LocalPlayer.Name .. " (you)",
		TextXAlignment = Enum.TextXAlignment.Left,
	}, row)
	local valueLabel = label({
		Name = "Value",
		Size = UDim2.new(0, 160, 1, -6),
		Position = UDim2.new(1, -166, 0, 3),
		TextXAlignment = Enum.TextXAlignment.Right,
	}, row)
	row.Parent = page

	local attr = "Lb_" .. id
	local function refresh()
		local raw = LocalPlayer:GetAttribute(attr)
		local rank, text = string.match(if type(raw) == "string" then raw else "", "^(%d+)|(.*)$")
		local n = tonumber(rank) or 0
		if not text or text == "" then
			rankLabel.Text = "#-"
			valueLabel.Text = "Not on it yet"
		else
			rankLabel.Text = if n > 0 then "#" .. n else "#1000+"
			valueLabel.Text = text
		end
	end
	refresh()
	LocalPlayer:GetAttributeChangedSignal(attr):Connect(refresh)
end

local function setup(board: Instance)
	if guis[board] or not board:IsA("BasePart") then
		return
	end
	local gui = board:FindFirstChildOfClass("SurfaceGui") or board:WaitForChild("SurfaceGui", 15)
	if not gui or not gui:IsA("SurfaceGui") or guis[board] then
		return
	end
	guis[board] = gui
	local kind = tostring(board:GetAttribute("LbBoard") or "")
	for i = 1, 20 do
		local page = gui:FindFirstChild("Page" .. i)
		if not page or not page:IsA("Frame") then
			break
		end
		local list = page:FindFirstChild("List")
		if list then
			watchList(list)
		end
		if kind ~= "" then
			addYouRow(page, kind .. i)
		end
	end
	-- Into PlayerGui (still drawn on the board) so the list scrolls.
	gui.ResetOnSpawn = false
	gui.Adornee = board
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	board.AncestryChanged:Connect(function()
		if not board:IsDescendantOf(game) then
			guis[board] = nil
			gui:Destroy()
		end
	end)
end

----------------------------------------------------------------------------------------------------
-- The Refresh chip: near a leaderboard, a small "Refresh" button at a fixed place on the screen redraws the boards, so you
-- can see yourself on them after a run. X on a keyboard, D-pad up on a controller, a tap on a phone. (It used to be a
-- second proximity prompt stacked under "Next page" and the two overlapped, worse the closer you zoomed; this has a place
-- of its own, away from the board.) LeaderboardService answers, at most once per 20 s per player.
----------------------------------------------------------------------------------------------------
local REFRESH_RANGE = 45 -- studs from a board
local REFRESH_PAUSE = 3 -- this screen's own pause between two presses
local chip: Frame? = nil
local chipButton: TextButton? = nil
local chipKey: TextLabel? = nil
local lastPress = -math.huge

local function nearBoard(): boolean
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	for _, board in CollectionService:GetTagged("LeaderboardBoard") do
		if board:IsA("BasePart") and (board.Position - root.Position).Magnitude <= REFRESH_RANGE then
			return true
		end
	end
	return false
end

local function pressRefresh()
	local now = os.clock()
	if now - lastPress < REFRESH_PAUSE then
		return
	end
	lastPress = now
	UIKit.PlaySound("Click")
	Remotes.Event("BoardRefresh"):FireServer()
	local button = chipButton
	if button then
		button.Text = "Refreshing..."
		task.delay(1.5, function()
			if button.Parent then
				button.Text = "Refresh"
			end
		end)
	end
end

local function placeChip()
	local frame = chip
	if frame then
		local safe = UIKit.SafeInsets()
		frame.Position = UDim2.new(0.5, 0, 1, -((if UIKit.IsTouch() then 104 else 84) + safe.Bottom))
	end
end

local function setupRefreshChip()
	local _gui, root = UIKit.CreateScreen("BoardRefresh", 6)
	local frame = Instance.new("Frame")
	frame.Name = "RefreshChip"
	frame.AnchorPoint = Vector2.new(0.5, 1)
	frame.Size = UDim2.fromOffset(190, 52)
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.Parent = root
	UIKit.PhoneBoost(frame, 1.25)
	chip = frame
	chipButton = UIKit.Button({
		Text = "Refresh",
		Color = UIKit.Theme.Colors.Accent,
		Size = UDim2.fromOffset(190, 48),
		Position = UDim2.fromOffset(0, 2),
		Sound = false,
		Parent = frame,
		OnClick = pressRefresh,
	})
	-- the key to press, on the button's corner (not on a phone, where you tap it)
	local badge = Instance.new("Frame")
	badge.Name = "Key"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, -10, 0, 4)
	badge.Size = UDim2.fromOffset(34, 30)
	badge.BackgroundColor3 = UIKit.Theme.Colors.Ink
	badge.BorderSizePixel = 0
	badge.ZIndex = 20
	badge.Parent = frame
	UIKit.Corner(badge, 8)
	UIKit.Stroke(badge, UIKit.Theme.Colors.Text, 2, 0.5)
	chipKey = UIKit.Label({ Text = "X", TextSize = 18, Size = UDim2.fromScale(1, 1), ZIndex = 21, Parent = badge })
	placeChip()
	UIKit.LayoutChanged:Connect(placeChip)

	-- Keys: X on a keyboard, D-pad up on a controller (Next page's own key there is X).
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local shown = chip and chip.Visible
		if processed or not shown then
			return
		end
		if input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.DPadUp then
			pressRefresh()
		end
	end)

	task.spawn(function()
		while true do
			local away = ClientState.Run ~= nil or ClientState.TutorialStep ~= nil or ReplicatedStorage:GetAttribute("AbuseLive") == true or UIKit.IsWindowOpen()
			local show = not away and nearBoard()
			if chip and chip.Visible ~= show then
				chip.Visible = show
			end
			if show and chipKey then
				local badgeFrame = chipKey.Parent :: Frame
				local pad = UIKit.IsGamepad()
				badgeFrame.Visible = not UIKit.IsTouch() or pad
				badgeFrame.Size = UDim2.fromOffset(if pad then 84 else 34, 30)
				chipKey.Text = if pad then "D-pad \u{2191}" else "X"
			end
			task.wait(0.25)
		end
	end)
end

function BoardView.Init()
	if initialized then
		return
	end
	initialized = true
	setupRefreshChip()
	for _, board in CollectionService:GetTagged("LeaderboardBoard") do
		task.spawn(setup, board)
	end
	CollectionService:GetInstanceAddedSignal("LeaderboardBoard"):Connect(function(board)
		task.spawn(setup, board)
	end)
end

return BoardView
