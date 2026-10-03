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
	lbl.Font = Enum.Font.FredokaOne
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

function BoardView.Init()
	if initialized then
		return
	end
	initialized = true
	for _, board in CollectionService:GetTagged("LeaderboardBoard") do
		task.spawn(setup, board)
	end
	CollectionService:GetInstanceAddedSignal("LeaderboardBoard"):Connect(function(board)
		task.spawn(setup, board)
	end)
end

return BoardView
