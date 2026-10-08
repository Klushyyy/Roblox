--[[
	Tutorial - the first-run guide for new players (level 1, the kitchen). An interactive one: it points at the thing to do,
	turns the camera to it, dims everything else and only lets the highlighted thing be pressed.

	Until it is finished (or skipped) the screen stays simple: no Bubbles / Gems / level bar, only the coins and the tank,
	and the tip card sits at the very top (it moves to the bottom if it would cover what it is pointing at). Loot toasts
	("your pet found golden dirt...") are held back while it runs. The steps (TIP n of 5):

	  1. "Your job is to clean these dishes!" (the camera looks over them), then hold on a dirty dish to scrub it
	  2. Keep scrubbing: every spot you clean fills the tank
	  3. Tank filling up: the camera looks at the glowing drain, walk there to sell it (the arrow points at it)
	  4. The Upgrades button flashes: open the book (Tab / Y / tap it; nothing else works). Then a tour with a Next
	     button: the screen dims and one thing is lit at a time (Power, Size, Tank Size, Sneakers, then the tools)
	  5. Buy Power: only that one button can be pressed
	  Done: the card goes, the reward popup shows, and when it is dismissed the rest of the HUD comes back.

	The camera only ever turns on the spot (it never moves to a new place, so it can't end up inside a wall), lasts a few
	seconds, and any click / tap / key hands it straight back. "Skip tutorial" (small, next to Next) asks first and pays no
	reward. Finishing or skipping tells the server (MetaRequest "TutorialDone", true = finished); anyone who has already
	finished a run counts as done. ClientState.TutorialStep tells the HUD which buttons to show (6 = the reward popup is up);
	ClientState.TutorialAllowBook is true while the player is meant to open the book (the hotkeys are off otherwise).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))

local Tutorial = {}

local Colors = UIKit.Theme.Colors
local LocalPlayer = Players.LocalPlayer

local initialized = false

local TOTAL_STEPS = 5
local STEP_KEYS = { "tut.start", "tut.s2", "tut.s3", "tut.s4", "tut.s5" } -- Analytics: one moment per tip
local FINISHING = 6 -- ClientState.TutorialStep while the reward popup is up
local PAN_TRAVEL = 0.9 -- seconds for the camera to turn to the thing...
local PAN_BACK = 0.9 -- ...and to turn back
local CARD_H = 132

local function upgradeLevels(run: Types.RunState): number
	local up = run.Upgrades :: any
	local total = 0
	for _, key in { "Hold", "HandSize", "ScrubPower", "TankSize", "Sneakers" } do
		total += tonumber(up[key]) or 0
	end
	-- tools bought count as well
	for _, owned in run.OwnedTools do
		if owned then
			total += 1
		end
	end
	return total
end

local function padMode(): boolean
	return UIKit.IsGamepad()
end
local function touchMode(): boolean
	return UIKit.IsTouch() and not UIKit.IsGamepad()
end

function Tutorial.Init()
	if initialized then
		return
	end
	initialized = true

	local gui, root = UIKit.CreateScreen("Tutorial", 40)
	local rewardText = Config.RewardText(Config.Tutorial.Reward)
	local Celebrate = require(Client:WaitForChild("Celebrate")) :: any

	----------------------------------------------------------------------------------------------
	-- The spotlight: four dark panels round a hole (so the hole is the only place that gets clicks), a flashing ring
	-- round the hole, and, when the lit thing must not be pressed yet, a clear panel over the hole.
	----------------------------------------------------------------------------------------------
	local function panel(name: string): TextButton
		local b = Instance.new("TextButton")
		b.Name = name
		b.Text = ""
		b.AutoButtonColor = false
		b.Selectable = false
		b.BackgroundColor3 = Color3.new(0, 0, 0)
		b.BackgroundTransparency = 0.5
		b.BorderSizePixel = 0
		b.ZIndex = 10
		b.Visible = false
		b.Parent = root
		return b
	end
	local dimTop, dimBottom, dimLeft, dimRight = panel("DimTop"), panel("DimBottom"), panel("DimLeft"), panel("DimRight")
	local holeBlock = panel("HoleBlock")
	holeBlock.BackgroundTransparency = 1
	local ring = Instance.new("Frame")
	ring.Name = "SpotRing"
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.ZIndex = 11
	ring.Visible = false
	UIKit.Corner(ring, 14)
	local ringStroke = Instance.new("UIStroke")
	ringStroke.Thickness = 5
	ringStroke.Color = Colors.Coin
	ringStroke.Parent = ring
	ring.Parent = root
	TweenService:Create(ringStroke, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Thickness = 10, Color = Color3.new(1, 1, 1) }):Play()

	-- What is lit now: Find returns the live thing (it is looked up every frame: the Upgrade Book rebuilds its cards).
	local spot: { Find: (() -> GuiObject?)?, Pad: number, Clickable: boolean, Dim: number } = { Find = nil, Pad = 8, Clickable = false, Dim = 0.5 }
	local holeRect: { X: number, Y: number, W: number, H: number }? = nil
	local selectedFor: GuiObject? = nil

	local function setSpot(find: (() -> GuiObject?)?, clickable: boolean?, pad: number?, dim: number?)
		spot.Find = find
		spot.Clickable = clickable == true
		spot.Pad = pad or 8
		spot.Dim = dim or 0.5
		if not find then
			holeRect = nil
			for _, p in { dimTop, dimBottom, dimLeft, dimRight, holeBlock, ring } do
				p.Visible = false
			end
			selectedFor = nil
		end
	end

	local function updateSpot()
		local find = spot.Find
		if not find then
			return
		end
		local target = find()
		if target and target.Parent and target.AbsoluteSize.X > 0 then
			local scale = math.max(UIKit.GetScale(), 0.01)
			local origin = root.AbsolutePosition
			local ap, as = target.AbsolutePosition, target.AbsoluteSize
			local pad = spot.Pad
			holeRect = { X = (ap.X - origin.X) / scale - pad, Y = (ap.Y - origin.Y) / scale - pad, W = as.X / scale + pad * 2, H = as.Y / scale + pad * 2 }
		end
		local rect = holeRect
		local canvas = UIKit.CanvasSize()
		if not rect then
			-- (nothing found yet: everything is covered, nothing is lit)
			dimTop.Position, dimTop.Size = UDim2.fromOffset(0, 0), UDim2.fromOffset(canvas.X, canvas.Y)
			dimTop.BackgroundTransparency = spot.Dim
			dimTop.Visible = true
			dimBottom.Visible, dimLeft.Visible, dimRight.Visible, holeBlock.Visible, ring.Visible = false, false, false, false, false
			return
		end
		local x0, y0 = math.max(0, rect.X), math.max(0, rect.Y)
		local x1, y1 = math.min(canvas.X, rect.X + rect.W), math.min(canvas.Y, rect.Y + rect.H)
		dimTop.Position, dimTop.Size = UDim2.fromOffset(0, 0), UDim2.fromOffset(canvas.X, y0)
		dimBottom.Position, dimBottom.Size = UDim2.fromOffset(0, y1), UDim2.fromOffset(canvas.X, math.max(0, canvas.Y - y1))
		dimLeft.Position, dimLeft.Size = UDim2.fromOffset(0, y0), UDim2.fromOffset(x0, math.max(0, y1 - y0))
		dimRight.Position, dimRight.Size = UDim2.fromOffset(x1, y0), UDim2.fromOffset(math.max(0, canvas.X - x1), math.max(0, y1 - y0))
		holeBlock.Position, holeBlock.Size = UDim2.fromOffset(x0, y0), UDim2.fromOffset(math.max(0, x1 - x0), math.max(0, y1 - y0))
		ring.Position, ring.Size = UDim2.fromOffset(rect.X, rect.Y), UDim2.fromOffset(rect.W, rect.H)
		for _, p in { dimTop, dimBottom, dimLeft, dimRight } do
			p.BackgroundTransparency = spot.Dim
			p.Visible = true
		end
		holeBlock.Visible = not spot.Clickable
		ring.Visible = true
		-- a gamepad has to land on the lit button
		if spot.Clickable and target and padMode() and selectedFor ~= target and target:IsA("GuiButton") then
			selectedFor = target
			pcall(function()
				GuiService.SelectedObject = target
			end)
		end
	end

	----------------------------------------------------------------------------------------------
	-- The tip card.
	----------------------------------------------------------------------------------------------
	local holder = Instance.new("Frame")
	holder.Name = "HintHolder"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Size = UDim2.fromOffset(560, CARD_H)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.ZIndex = 30
	holder.Parent = root
	local card = UIKit.Card({ Name = "Hint", Position = UDim2.fromOffset(4, 3), Size = UDim2.new(1, -8, 1, -6), Color = Colors.PanelDark, Parent = holder })
	UIKit.Stroke(card, Colors.Good, 3, 0)
	local stepLabel = UIKit.Label({ Text = "", Font = UIKit.Theme.Fonts.Title, TextSize = 16, TextColor3 = Colors.Good, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(16, 8), Size = UDim2.new(0.35, 0, 0, 20), Parent = card })
	UIKit.Label({ Name = "Reward", Text = "Finish for " .. rewardText, Font = UIKit.Theme.Fonts.Title, TextSize = 14, TextColor3 = Colors.Coin, TextXAlignment = Enum.TextXAlignment.Right, TextTruncate = Enum.TextTruncate.AtEnd, AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 8), Size = UDim2.new(0.62, -14, 0, 20), Parent = card })
	local hintLabel = UIKit.Label({ Text = "", Font = UIKit.Theme.Fonts.Title, TextSize = 22, TextWrapped = true, TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center, Position = UDim2.fromOffset(16, 30), Size = UDim2.new(1, -32, 0, 62), Parent = card })
	local sizeCap = Instance.new("UITextSizeConstraint")
	sizeCap.MaxTextSize = 24
	sizeCap.MinTextSize = 12
	sizeCap.Parent = hintLabel
	-- One dot per step: filled once that step is done.
	local dots: { Frame } = {}
	for i = 1, TOTAL_STEPS do
		local dot = Instance.new("Frame")
		dot.Name = "Dot" .. i
		dot.AnchorPoint = Vector2.new(0, 1)
		dot.Position = UDim2.new(0, 18 + (i - 1) * 20, 1, -18)
		dot.Size = UDim2.fromOffset(12, 12)
		dot.BackgroundColor3 = Colors.PanelLight
		dot.BorderSizePixel = 0
		UIKit.Corner(dot, 6)
		dot.Parent = card
		dots[i] = dot
	end
	-- Bottom right: Next (only on the "look at this" steps), then a small Skip.
	local skipButton = UIKit.Button({
		Text = "Skip tutorial",
		Color = Colors.PanelLight,
		TextColor3 = Colors.TextDim,
		TextSize = 12,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -10),
		Size = UDim2.fromOffset(100, 26),
		Parent = card,
	})
	local nextButton = UIKit.Button({
		Name = "Next",
		Text = "Next",
		Color = Colors.Good,
		TextSize = 18,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -118, 1, -8),
		Size = UDim2.fromOffset(104, 34),
		Visible = false,
		Parent = card,
	})
	nextButton.Visible = false

	local cardTop = true -- where the card is now: the very top, or the bottom if the top would cover what is lit
	local cardY = 6
	local function place()
		local canvas = UIKit.CanvasSize()
		holder.Size = UDim2.fromOffset(math.min(560, canvas.X - 24), CARD_H)
		local topY = if canvas.X < 900 then UIKit.TopInset() + 4 else 6
		local bottomY = canvas.Y - CARD_H - 8 - UIKit.SafeInsets().Bottom
		-- (move away from what is lit; the card never covers it)
		local rect = holeRect
		if rect and spot.Find then
			local overlapsTop = rect.Y < topY + CARD_H + 6
			local overlapsBottom = rect.Y + rect.H > bottomY - 6
			if overlapsTop and not overlapsBottom then
				cardTop = false
			elseif overlapsBottom and not overlapsTop then
				cardTop = true
			elseif overlapsTop and overlapsBottom then
				-- (a tall thing: whichever side leaves more of it clear)
				cardTop = (rect.Y + rect.H - (topY + CARD_H)) > (bottomY - rect.Y)
			end
		else
			cardTop = true
		end
		local goal = if cardTop then topY else bottomY
		cardY = cardY + (goal - cardY) * 0.25
		if math.abs(goal - cardY) < 0.5 then
			cardY = goal
		end
		holder.Position = UDim2.new(0.5, 0, 0, cardY)
	end
	place()
	UIKit.LayoutChanged:Connect(place)

	local function paintDots(done: number)
		for i, dot in dots do
			dot.BackgroundColor3 = if i <= done then Colors.Good else Colors.PanelLight
		end
	end

	----------------------------------------------------------------------------------------------
	-- "Skip the whole tutorial?" (asks first)
	----------------------------------------------------------------------------------------------
	local confirm = Instance.new("TextButton") -- (a button so it eats every click behind it)
	confirm.Name = "SkipConfirm"
	confirm.Text = ""
	confirm.AutoButtonColor = false
	confirm.Selectable = false
	confirm.Size = UDim2.fromScale(1, 1)
	confirm.BackgroundColor3 = Color3.new(0, 0, 0)
	confirm.BackgroundTransparency = 0.45
	confirm.BorderSizePixel = 0
	confirm.ZIndex = 50
	confirm.Visible = false
	confirm.Parent = root
	local confirmCard = UIKit.Card({ Name = "Card", Color = Colors.Panel, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(440, 270), Parent = confirm })
	UIKit.Stroke(confirmCard, Colors.Bad, 3, 0)
	UIKit.Label({ Text = "Skip the tutorial?", TextSize = 26, TextColor3 = Colors.Coin, Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 34), Parent = confirmCard })
	UIKit.Label({
		Text = "This skips the whole tutorial, and you won't get the reward for finishing it (" .. rewardText .. ").",
		TextSize = 19,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(24, 58),
		Size = UDim2.new(1, -48, 0, 100),
		Parent = confirmCard,
	})
	local keepButton = UIKit.Button({ Text = "Keep going", Color = Colors.Good, TextSize = 20, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 22, 1, -20), Size = UDim2.new(0.5, -28, 0, 56), Parent = confirmCard })
	local skipYesButton = UIKit.Button({ Text = "Skip it", Color = Colors.Bad, TextSize = 20, AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -22, 1, -20), Size = UDim2.new(0.5, -28, 0, 56), Parent = confirmCard })
	local function closeConfirm()
		confirm.Visible = false
		selectedFor = nil
		pcall(function()
			local selected = GuiService.SelectedObject
			if selected and selected:IsDescendantOf(confirm) then
				GuiService.SelectedObject = nil
			end
		end)
	end
	local function openConfirm()
		ClientState.Track("tut.skipask")
		local canvas = UIKit.CanvasSize()
		confirmCard.Size = UDim2.fromOffset(math.min(440, canvas.X - 32), 270)
		confirm.Visible = true
		UIKit.Bounce(confirmCard)
		UIKit.PlaySound("Pop")
		if padMode() then
			pcall(function()
				GuiService.SelectedObject = keepButton
			end)
		end
	end
	keepButton.Activated:Connect(closeConfirm)

	----------------------------------------------------------------------------------------------
	-- The pointer in the world: a bouncing arrow over a dish or the drain.
	----------------------------------------------------------------------------------------------
	local pointerPart: Part? = nil
	local pointerGui: BillboardGui? = nil
	local pointerKey: any = nil -- what it points at now (an Instance, or a Vector3): rebuilt only when that changes
	local function clearPointer()
		if pointerGui then
			pointerGui:Destroy()
			pointerGui = nil
		end
		if pointerPart then
			pointerPart:Destroy()
			pointerPart = nil
		end
		pointerKey = nil
	end
	local function pointAt(target: Instance?, position: Vector3?)
		local key: any = target or position
		if key ~= nil and key == pointerKey then
			return
		end
		clearPointer()
		pointerKey = key
		local adornee: BasePart? = nil
		if target then
			adornee = if target:IsA("BasePart") then target else (target :: any).PrimaryPart or target:FindFirstChildWhichIsA("BasePart", true)
		elseif position then
			local part = Instance.new("Part")
			part.Anchored = true
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Transparency = 1
			part.Size = Vector3.one
			part.Position = position
			part.Parent = workspace
			pointerPart = part
			adornee = part
		end
		if not adornee then
			return
		end
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "TutorialPointer"
		billboard.Adornee = adornee
		billboard.AlwaysOnTop = true
		billboard.Size = UDim2.fromOffset(70, 70)
		billboard.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
		billboard.MaxDistance = 400
		billboard.LightInfluence = 0
		local arrow = Instance.new("TextLabel")
		arrow.BackgroundTransparency = 1
		arrow.Size = UDim2.fromScale(1, 1)
		arrow.Font = UIKit.Theme.Fonts.Title
		arrow.Text = "v"
		arrow.TextScaled = true
		arrow.TextColor3 = Colors.Coin
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 3
		stroke.Color = Colors.Stroke
		stroke.Parent = arrow
		arrow.Parent = billboard
		TweenService:Create(arrow, TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Position = UDim2.fromOffset(0, 14) }):Play()
		billboard.Parent = LocalPlayer:WaitForChild("PlayerGui")
		pointerGui = billboard
	end

	----------------------------------------------------------------------------------------------
	-- The camera turning to look at something (on the spot: it never moves to a new place).
	----------------------------------------------------------------------------------------------
	local panning = false
	local panSkip = false -- the player clicked / tapped / pressed a key: hand the camera back now
	local panCancel: (() -> ())? = nil
	local function cancelPan()
		if panCancel then
			panCancel()
		end
	end
	UserInputService.InputBegan:Connect(function(input)
		if not panning then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch or t == Enum.UserInputType.Keyboard or t == Enum.UserInputType.Gamepad1 then
			panSkip = true
		end
	end)
	-- Turns the camera to `target`, holds for `hold` seconds, turns back; `onDone` runs after. False if it couldn't.
	local function panTo(target: Vector3, hold: number, onDone: (() -> ())?): boolean
		local camera = workspace.CurrentCamera
		local character = LocalPlayer.Character
		local hrp = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if panning or not camera or not hrp or camera.CameraType == Enum.CameraType.Scriptable then
			return false
		end
		panning, panSkip = true, false
		local startCF = camera.CFrame
		local startRoot = hrp.Position
		local previousType = camera.CameraType
		local previousSubject = camera.CameraSubject
		local phase, phaseAt = "go", os.clock()
		local startedAt = phaseAt
		local from = startCF
		local focusCF = CFrame.lookAt(startCF.Position, target)
		local function ease(a: number): number
			return a * a * (3 - 2 * a)
		end
		local function finishPan()
			RunService:UnbindFromRenderStep("TutorialPan")
			panning, panCancel = false, nil
			camera.CameraType = previousType
			if previousSubject then
				camera.CameraSubject = previousSubject
			end
			if onDone then
				task.spawn(onDone)
			end
		end
		panCancel = finishPan
		camera.CameraType = Enum.CameraType.Scriptable
		RunService:BindToRenderStep("TutorialPan", Enum.RenderPriority.Camera.Value + 1, function()
			local now = os.clock()
			local currentRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			-- where the player's own camera would be now (it follows them while they walk)
			local followCF = if currentRoot then startCF + (currentRoot.Position - startRoot) else startCF
			if phase == "go" then
				local a = math.clamp((now - phaseAt) / PAN_TRAVEL, 0, 1)
				camera.CFrame = followCF:Lerp(focusCF, ease(a))
				if panSkip then
					phase, phaseAt, from = "back", now, camera.CFrame
				elseif a >= 1 then
					phase, phaseAt = "hold", now
				end
			elseif phase == "hold" then
				camera.CFrame = focusCF
				if panSkip or now - phaseAt >= hold then
					phase, phaseAt, from = "back", now, focusCF
				end
			else
				local a = math.clamp((now - phaseAt) / PAN_BACK, 0, 1)
				camera.CFrame = from:Lerp(followCF, ease(a))
				if a >= 1 then
					finishPan()
					return
				end
			end
			if now - startedAt > 15 or not currentRoot then
				finishPan() -- (never stuck: they died, or something else took too long)
			end
		end)
		return true
	end

	local function nearestDish(run: Types.RunState): Instance?
		local arenas = workspace:FindFirstChild("Arenas")
		local arena = arenas and arenas:FindFirstChild(run.ArenaName)
		local dishes = arena and arena:FindFirstChild("Dishes")
		local character = LocalPlayer.Character
		local rootPart = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not dishes or not rootPart then
			return nil
		end
		local best, bestD = nil, math.huge
		for _, d in dishes:GetChildren() do
			if d:IsA("Model") then
				local d2 = (d:GetPivot().Position - rootPart.Position).Magnitude
				if d2 < bestD then
					best, bestD = d, d2
				end
			end
		end
		return best
	end

	-- The middle of the dishes still to clean (what "your job" is about).
	local function dishesCenter(run: Types.RunState): Vector3?
		local arenas = workspace:FindFirstChild("Arenas")
		local arena = arenas and arenas:FindFirstChild(run.ArenaName)
		local dishes = arena and arena:FindFirstChild("Dishes")
		if not dishes then
			return nil
		end
		local sum, count = Vector3.zero, 0
		for _, d in dishes:GetChildren() do
			if d:IsA("Model") then
				sum += d:GetPivot().Position
				count += 1
			end
		end
		return if count > 0 then sum / count else nil
	end

	----------------------------------------------------------------------------------------------
	-- Finding things in the Upgrade Book (it rebuilds its cards on every change, so they are looked up by name each frame).
	----------------------------------------------------------------------------------------------
	local function inBook(name: string): GuiObject?
		local g = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("UpgradesUI")
		local found = g and g:FindFirstChild(name, true)
		return if found and found:IsA("GuiObject") then found else nil
	end
	local function hudUpgradesButton(): GuiObject?
		local hud = require(Client:WaitForChild("HUD")) :: any
		return hud.UpgradesButton :: GuiObject?
	end
	local function buyButton(): GuiObject?
		local c = inBook("ScrubPower")
		local b = c and c:FindFirstChild("Button")
		return if b and b:IsA("GuiObject") then b else nil
	end

	-- The tour of the open Upgrade Book: one thing lit at a time, a Next button, nothing else can be pressed.
	local TOUR: { { Find: () -> GuiObject?, Text: string } } = {
		{ Find = function() return inBook("LeftPage") end, Text = "This is your Upgrade Book! Coins buy upgrades for your tools. Here's a quick tour: press Next." },
		{ Find = function() return inBook("ScrubPower") end, Text = "POWER: how fast your tool cleans. Every tool has its own Power level." },
		{ Find = function() return inBook("HandSize") end, Text = "SIZE: how much dirt you clean at once. Also separate for every tool." },
		{ Find = function() return inBook("TankSize") end, Text = "TANK SIZE: this one is for ALL your tools. A bigger tank carries more before you run to the drain." },
		{ Find = function() return inBook("Sneakers") end, Text = "SNEAKERS: run faster with every tool, so trips to the drain are quicker." },
		{ Find = function() return inBook("RightPage") end, Text = "On the right are all the tools. Each one has its own perk and its own downside. Let's meet them." },
		{ Find = function() return inBook("Tool2") end, Text = "SPONGE: scrubs more than twice as fast as your hands, but you have to stand close." },
		{ Find = function() return inBook("Tool3") end, Text = "SPRAY NOZZLE: a water stream that cleans from far away, so you can stay put." },
		{ Find = function() return inBook("Tool4") end, Text = "PRESSURE WASHER: a long, thin blast. Sweep it across the dirt and it melts away." },
		{ Find = function() return inBook("Tool5") end, Text = "FOAM CANNON: shoots foam that keeps cleaning where it lands. Aim, shoot, relax!" },
	}

	----------------------------------------------------------------------------------------------
	-- The steps.
	----------------------------------------------------------------------------------------------
	local finished = false
	local finishedAt = 0
	local step = 0
	local resumeStep = 1 -- where the tutorial carries on if a run ends in the middle of it
	local baseline = 0
	local coinsBaseline = 0
	local tourIndex = 0 -- 0 = the book is not open yet; otherwise the TOUR entry being shown
	local panned: { [number]: boolean } = {} -- the camera has looked at this step's thing already
	local shown = 0
	local shownText = ""
	local nextAction: (() -> ())? = nil -- what Next does now (nil: it is hidden)

	local function setStep(n: number)
		if n > step and step >= 1 then
			-- (the step before this one is done)
			paintDots(step)
			UIKit.PlaySound("Sparkle")
			UIKit.Bounce(card)
		end
		step = n
		tourIndex = 0
		if STEP_KEYS[n] then
			ClientState.Track(STEP_KEYS[n]) -- (Analytics: how far the tutorial gets)
		end
		if n < 4 then
			setSpot(nil)
		end
		ClientState.TutorialStep = if n >= 1 and n <= TOTAL_STEPS then n else nil
		ClientState.TutorialAllowBook = n == 4
		ClientState.Changed:Fire("Tutorial")
		local run = ClientState.Run :: Types.RunState?
		baseline = if run then upgradeLevels(run) else 0
		coinsBaseline = if run then run.Coins or 0 else 0
	end

	local function showHint(n: number, text: string, onNext: (() -> ())?)
		stepLabel.Text = string.format("TIP %d of %d", n, TOTAL_STEPS)
		hintLabel.Text = text
		if shown ~= n then
			shown = n
			holder.Visible = true
			UIKit.Bounce(card)
			UIKit.PlaySound("Pop")
		elseif shownText ~= text then
			UIKit.Bounce(card)
		end
		shownText = text
		nextAction = onNext
		nextButton.Visible = onNext ~= nil
		if onNext and padMode() and not confirm.Visible then
			pcall(function()
				GuiService.SelectedObject = nextButton
			end)
		end
	end

	local function finish(completed: boolean)
		if finished then
			return
		end
		finished = true
		ClientState.Track(if completed then "tut.done" else "tut.skip")
		finishedAt = os.clock()
		closeConfirm()
		cancelPan()
		clearPointer()
		setSpot(nil)
		nextAction = nil
		nextButton.Visible = false
		holder.Visible = false
		if UIKit.IsWindowOpen("Upgrades") then
			pcall(UIKit.CloseWindow, "Upgrades")
		end
		step = 0
		tourIndex = 0
		ClientState.TutorialAllowBook = false
		-- (finishing: the HUD stays away until the reward popup has been dismissed)
		ClientState.TutorialStep = if completed then FINISHING else nil
		ClientState.Changed:Fire("Tutorial")
		task.spawn(function()
			local result = ClientState.MetaRequest("TutorialDone", completed)
			if not completed then
				return
			end
			paintDots(TOTAL_STEPS)
			UIKit.PlaySound("Sparkle")
			UIKit.Confetti(60)
			if result and result.Message and ReplicatedStorage:GetAttribute("AbuseLive") ~= true then
				-- the reward popup comes from the server in a moment: wait until the player has pressed Awesome (20 s at most)
				local dismissed = false
				local conn = Celebrate.Dismissed:Connect(function()
					dismissed = true
				end)
				local t0 = os.clock()
				while not dismissed and os.clock() - t0 < 20 and ClientState.Run ~= nil do
					task.wait(0.2)
				end
				conn:Disconnect()
				task.wait(0.25)
			else
				task.wait(0.6)
			end
			if ClientState.TutorialStep == FINISHING then
				ClientState.TutorialStep = nil
				ClientState.Changed:Fire("Tutorial")
			end
		end)
	end
	skipButton.Activated:Connect(function()
		if not finished then
			openConfirm()
		end
	end)
	skipYesButton.Activated:Connect(function()
		finish(false)
	end)
	nextButton.Activated:Connect(function()
		local action = nextAction
		if action and not confirm.Visible then
			UIKit.PlaySound("Click")
			action()
		end
	end)
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode == Enum.KeyCode.Return and nextAction and not confirm.Visible and not processed then
			nextAction()
		end
	end)

	RunService.RenderStepped:Connect(function()
		updateSpot()
		place()
	end)

	local function goTour(i: number)
		tourIndex = i
		if i == 1 then
			ClientState.Track("tut.book")
		end
		ClientState.Track("tut.tour", tostring(i))
	end

	task.spawn(function()
		while true do
			task.wait(0.25)
			local meta = ClientState.Meta :: any
			local run = ClientState.Run :: Types.RunState?
			if finished and meta and meta.TutorialDone ~= true and os.clock() - finishedAt > 15 then
				-- (a staff "reset my first run": the tutorial starts over)
				finished = false
				step, resumeStep, shown, shownText = 0, 1, 0, ""
				panned = {}
				paintDots(0)
			end
			if finished or not meta or meta.TutorialDone == true then
				if meta and meta.TutorialDone == true then
					finished = true
					if ClientState.TutorialStep ~= FINISHING then
						ClientState.TutorialStep = nil
					end
					if confirm.Visible then
						closeConfirm()
					end
				end
				continue
			end
			local active = run ~= nil and run.Level == 1 and run.Phase == "Playing" and (run.ClockAt or 0) > 0
			if not active or not run then
				-- between runs: the card goes, the screen goes back to normal; the tutorial picks up again next run
				holder.Visible = false
				shown, shownText = 0, ""
				closeConfirm()
				cancelPan()
				clearPointer()
				setSpot(nil)
				nextAction = nil
				nextButton.Visible = false
				ClientState.TutorialAllowBook = false
				if step ~= 0 then
					resumeStep = step
					setStep(0)
				end
				continue
			end
			if step <= 0 then
				setStep(math.max(1, math.min(resumeStep, 4)))
				paintDots(step - 1)
			end
			local tankFrac = if run.TankMax > 0 then run.Tank / run.TankMax else 0
			if step == 1 then
				setSpot(nil)
				if not panned[1] then
					local center = dishesCenter(run)
					panned[1] = true
					if center then
						panTo(center, 1.6)
					end
				end
				if panning then
					showHint(1, "Your job is to clean these dishes!")
					clearPointer()
				else
					showHint(1, if padMode() then "Hold the right trigger (RT) on a dirty dish to scrub it clean!" elseif touchMode() then "Press and hold on a dirty dish to scrub it clean!" else "Hold the mouse button on a dirty dish to scrub it clean!")
					pointAt(nearestDish(run))
				end
				if (run.Cleaned or 0) >= 1 then
					cancelPan()
					clearPointer()
					setStep(2)
				end
			elseif step == 2 then
				showHint(2, "Nice! Keep scrubbing: every spot you clean fills your tank.")
				if (run.Cleaned or 0) >= 6 or tankFrac >= 0.4 then
					setStep(3)
				end
			elseif step == 3 then
				if not panned[3] then
					panned[3] = true
					if run.DrainPosition then
						panTo(run.DrainPosition, 1.4)
					end
				end
				if panning then
					showHint(3, "Your tank is filling up! This glowing drain turns it into coins.")
				else
					showHint(3, "Walk to the glowing drain to sell your tank for coins!")
				end
				pointAt(nil, run.DrainPosition)
				-- (every run starts with a few coins, so "has coins" means nothing: the coins have to go UP)
				if (run.Coins or 0) > coinsBaseline then
					cancelPan()
					clearPointer()
					setStep(4)
				end
			elseif step == 4 then
				clearPointer()
				local open = UIKit.IsWindowOpen("Upgrades")
				if not open then
					-- the Upgrades button flashes: nothing else on the screen works
					tourIndex = 0
					ClientState.TutorialAllowBook = true
					showHint(4, if padMode() then "Coins buy upgrades! Press Y to open your Upgrade Book." elseif touchMode() then "Coins buy upgrades! Tap the flashing Upgrades button to open your Upgrade Book." else "Coins buy upgrades! Click the flashing Upgrades button (or press TAB) to open your Upgrade Book.")
					setSpot(hudUpgradesButton, true, 8, 0.4)
				else
					ClientState.TutorialAllowBook = false
					if tourIndex < 1 then
						goTour(1)
					end
					local entry = TOUR[tourIndex]
					setSpot(entry.Find, false, 8, 0.55)
					showHint(4, entry.Text, function()
						if tourIndex >= #TOUR then
							setStep(5)
						else
							goTour(tourIndex + 1)
						end
					end)
				end
			elseif step == 5 then
				clearPointer()
				ClientState.TutorialAllowBook = false
				if not UIKit.IsWindowOpen("Upgrades") then
					-- (the book got closed: back to opening it)
					setStep(4)
				else
					showHint(5, if touchMode() then "Now you try! Tap the green button to buy POWER with your coins." elseif padMode() then "Now you try! Press A on the green button to buy POWER with your coins." else "Now you try! Click the green button to buy POWER with your coins.")
					setSpot(buyButton, true, 8, 0.55)
					if upgradeLevels(run) > baseline then
						finish(true)
					end
				end
			end
		end
	end)

	gui.Destroying:Connect(cancelPan)
end

return Tutorial
