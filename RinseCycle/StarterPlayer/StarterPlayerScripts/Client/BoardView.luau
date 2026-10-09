--[[
	BoardView - the lobby leaderboards on this player's screen.

	  * Scrolling: a SurfaceGui only takes the mouse wheel / a finger when it lives in PlayerGui, so
	    each leaderboard's SurfaceGui (tag "LeaderboardBoard", drawn by LeaderboardService) is moved
	    into PlayerGui and adorned back onto its board. The server keeps drawing into it as before.
	  * Your position: under every page, a highlighted row with your rank, name and score
	    ("#515  you  12,345"), from the player attribute "Lb_<board><page>" = "<rank>|<value>".
	    Rank 0 with a value means you're further down than the board looks (past #1000).
	  * Your row in the top 100 is lit up too.
	  * Near a board, "Next page" and "Refresh" chips fade in at the bottom of the screen (F / X on a keyboard, X / D-pad up on a
	    controller, a tap on a phone) and fade out as you walk away.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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
-- Paging: the pages of a board are Page1..PageN in its SurfaceGui, only one visible. This only changes this screen's view.
----------------------------------------------------------------------------------------------------
local function boardGuiOf(board: Instance): SurfaceGui?
	return board:FindFirstChildOfClass("SurfaceGui") or guis[board]
end

local function pageCount(board: Instance): number
	local gui = boardGuiOf(board)
	local n = 0
	while gui and gui:FindFirstChild("Page" .. (n + 1)) do
		n += 1
	end
	return n
end

-- Shows the next (dir 1) or previous (dir -1) page of a board. The arrows on the board and the "Next page" chip both use it.
function BoardView.Flip(board: Instance, dir: number)
	local gui = boardGuiOf(board)
	if not gui then
		return
	end
	local pages = {}
	local current = 1
	for i = 1, 20 do
		local page = gui:FindFirstChild("Page" .. i)
		if not page or not page:IsA("GuiObject") then
			break
		end
		pages[i] = page
		if page.Visible then
			current = i
		end
	end
	if #pages < 2 then
		return
	end
	local nextIndex = (current - 1 + dir) % #pages + 1
	for i, page in pages do
		page.Visible = i == nextIndex
	end
	UIKit.PlaySound("Click")
end

----------------------------------------------------------------------------------------------------
-- The chips: near a leaderboard two small buttons, "Next page" and "Refresh", sit side by side at a fixed place at the bottom
-- of the screen (no proximity prompts on the boards: they overlapped each other and the board). Next page: F on a keyboard,
-- X on a controller; Refresh: X on a keyboard, D-pad up on a controller; a tap on a phone. They fade in as you walk toward a
-- board and fade out as you walk away (all of the way in from FADE_FULL studs, gone at FADE_GONE). Refresh redraws the boards so
-- you can see yourself on them after a run; LeaderboardService answers, at most once per 20 s per player.
----------------------------------------------------------------------------------------------------
local FADE_FULL = 28 -- studs from the nearest board: fully there up to here
local FADE_GONE = 46 -- ... and gone from here (in between it fades)
local USABLE = 0.35 -- a chip that is less there than this ignores presses
local REFRESH_PAUSE = 3 -- this screen's own pause between two presses
local ITEM_H = 66 -- a chip: the key hanging on the button's top edge (18) and the button (48)
local BUTTON_H = 48
local KEY_H = 24

type Chip = { Frame: Frame, Button: TextButton, Badge: Frame, Key: TextLabel }
local group: CanvasGroup? = nil
local nextChip: Chip? = nil
local refreshChip: Chip? = nil
local fade = 0 -- how much of the chips shows: 0 (gone) to 1 (all of the way there)
local nearest: BasePart? = nil -- the board "Next page" turns: the nearest one
local lastPress = -math.huge

-- The nearest leaderboard and how far away it is.
local function nearestBoard(): (BasePart?, number)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil, math.huge
	end
	local best: BasePart? = nil
	local bestDist = math.huge
	for _, board in CollectionService:GetTagged("LeaderboardBoard") do
		if board:IsA("BasePart") then
			local dist = (board.Position - root.Position).Magnitude
			if dist < bestDist then
				best, bestDist = board, dist
			end
		end
	end
	return best, bestDist
end

local function pressRefresh()
	local now = os.clock()
	if fade < USABLE or now - lastPress < REFRESH_PAUSE then
		return
	end
	lastPress = now
	UIKit.PlaySound("Click")
	Remotes.Event("BoardRefresh"):FireServer()
	local button = if refreshChip then refreshChip.Button else nil
	if button then
		button.Text = "Refreshing..."
		task.delay(1.5, function()
			if button.Parent then
				button.Text = "Refresh"
			end
		end)
	end
end

local function pressNext()
	local board = nearest
	if fade < USABLE or not board then
		return
	end
	BoardView.Flip(board, 1) -- (plays the click)
end

local function makeChip(parent: Instance, text: string, color: Color3, onClick: () -> ()): Chip
	local frame = Instance.new("Frame")
	frame.Name = text
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromOffset(168, ITEM_H)
	frame.Parent = parent
	local button = UIKit.Button({
		Text = text,
		Color = color,
		Size = UDim2.new(1, 0, 0, BUTTON_H),
		Position = UDim2.fromOffset(0, ITEM_H - BUTTON_H),
		Sound = false,
		Parent = frame,
		OnClick = onClick,
	})
	-- the key to press, on the button's top edge (not on a phone, where you tap it)
	local badge = Instance.new("Frame")
	badge.Name = "Key"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.Position = UDim2.new(0.5, 0, 0, ITEM_H - BUTTON_H - 5) -- (hangs over the button's top edge, clear of its text)
	badge.Size = UDim2.fromOffset(34, KEY_H)
	badge.BackgroundColor3 = UIKit.Theme.Colors.Ink
	badge.BorderSizePixel = 0
	badge.ZIndex = 20
	badge.Parent = frame
	UIKit.Corner(badge, 8)
	UIKit.Stroke(badge, UIKit.Theme.Colors.Text, 2, 0.5)
	local key = UIKit.Label({ Text = "", TextSize = 17, Size = UDim2.fromScale(1, 1), ZIndex = 21, Parent = badge })
	return { Frame = frame, Button = button, Badge = badge, Key = key }
end

local layoutKey = ""
-- Sizes and places the chips for what is on show (two, or only Refresh when the board has one page) and for the device.
local function layoutChips(withNext: boolean)
	local g, nextC, refreshC = group, nextChip, refreshChip
	if not g or not nextC or not refreshC then
		return
	end
	local touch = UIKit.IsTouch()
	local pad = UIKit.IsGamepad()
	local key = string.format("%s|%s|%s", tostring(withNext), tostring(touch), tostring(pad))
	if key == layoutKey then
		return
	end
	layoutKey = key
	local w = if touch then 136 else 168
	local gap = if touch then 12 else 18
	local count = if withNext then 2 else 1
	g.Size = UDim2.fromOffset(w * count + gap * (count - 1), ITEM_H)
	nextC.Frame.Visible = withNext
	nextC.Frame.Size = UDim2.fromOffset(w, ITEM_H)
	nextC.Frame.Position = UDim2.fromOffset(0, 0)
	refreshC.Frame.Size = UDim2.fromOffset(w, ITEM_H)
	refreshC.Frame.Position = UDim2.fromOffset(if withNext then w + gap else 0, 0)
	for _, chipItem in { nextC, refreshC } do
		chipItem.Badge.Visible = not touch or pad
	end
	nextC.Key.Text = if pad then "X" else "F"
	nextC.Badge.Size = UDim2.fromOffset(34, KEY_H)
	refreshC.Key.Text = if pad then "D-pad \u{2191}" else "X"
	refreshC.Badge.Size = UDim2.fromOffset(if pad then 84 else 34, KEY_H)
end

local function placeChips()
	local g = group
	if g then
		local safe = UIKit.SafeInsets()
		g.Position = UDim2.new(0.5, 0, 1, -((if UIKit.IsTouch() then 102 else 82) + safe.Bottom))
	end
end

local function setupChips()
	local _gui, root = UIKit.CreateScreen("BoardChips", 6)
	local g = Instance.new("CanvasGroup") -- (one group so everything fades together)
	g.Name = "Chips"
	g.AnchorPoint = Vector2.new(0.5, 1)
	g.Size = UDim2.fromOffset(354, ITEM_H)
	g.BackgroundTransparency = 1
	g.GroupTransparency = 1
	g.Visible = false
	g.Parent = root
	UIKit.PhoneBoost(g, 1.15)
	group = g
	nextChip = makeChip(g, "Next page", UIKit.Theme.Colors.Primary, pressNext)
	refreshChip = makeChip(g, "Refresh", UIKit.Theme.Colors.Accent, pressRefresh)
	layoutChips(true)
	placeChips()
	UIKit.LayoutChanged:Connect(function()
		placeChips()
		layoutKey = "" -- (the device may have changed)
	end)

	-- Keys: Next page is F on a keyboard / X on a controller; Refresh is X on a keyboard / D-pad up on a controller.
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or fade < USABLE then
			return
		end
		local code = input.KeyCode
		if code == Enum.KeyCode.X or code == Enum.KeyCode.DPadUp then
			pressRefresh()
		elseif code == Enum.KeyCode.F or code == Enum.KeyCode.ButtonX then
			pressNext()
		end
	end)

	-- The fade: toward 1 as you come up to a board, toward 0 as you walk off (or while a run, the tutorial, the show or a window
	-- has the screen), eased so it is smooth rather than jumping.
	RunService.RenderStepped:Connect(function(dt: number)
		local board, dist = nearestBoard()
		nearest = board
		local away = ClientState.Run ~= nil or ClientState.TutorialStep ~= nil or ReplicatedStorage:GetAttribute("AbuseLive") == true or UIKit.IsWindowOpen()
		local target = if away or not board then 0 else math.clamp((FADE_GONE - dist) / (FADE_GONE - FADE_FULL), 0, 1)
		if math.abs(target - fade) < 0.003 then
			fade = target
		else
			fade += (target - fade) * (1 - math.exp(-dt * 10))
		end
		local show = fade > 0.01
		if g.Visible ~= show then
			g.Visible = show
		end
		if show then
			g.GroupTransparency = 1 - fade
			layoutChips(board ~= nil and pageCount(board) >= 2)
		end
	end)
end

function BoardView.Init()
	if initialized then
		return
	end
	initialized = true
	setupChips()
	for _, board in CollectionService:GetTagged("LeaderboardBoard") do
		task.spawn(setup, board)
	end
	CollectionService:GetInstanceAddedSignal("LeaderboardBoard"):Connect(function(board)
		task.spawn(setup, board)
	end)
end

return BoardView
