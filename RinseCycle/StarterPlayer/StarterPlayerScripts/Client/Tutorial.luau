--[[
	Tutorial - the first-run guide for new players (level 1, the kitchen).

	Until it is finished (or skipped) the screen stays simple: only the coins, the tank and the progress bar are there. A
	hint card at the top says what to do next, the world points at it and the camera turns to look at it once, then each
	step shows a bit more:

	  1. "Your job is to clean these dishes!" (the camera looks over the dishes) -> hold on a dirty dish to scrub it
	  2. Keep scrubbing: every spot you clean fills the tank
	  3. Tank filling up: the camera looks at the glowing drain -> walk there to sell it for coins
	  4. Coins buy upgrades: press Tab / tap Upgrades (that button appears and pulses)
	  5. Inside the Upgrade Book: buy something
	  6. Done: the rest of the buttons appear and the reward is paid (Config.Tutorial.Reward)

	The camera only ever turns on the spot (it never moves to a new place, so it can't end up inside a wall), lasts a few
	seconds, and any click / tap / key hands it straight back: the player is always in control.

	Skip (bottom right of the card) asks first: skipping ends the whole tutorial and pays no reward. Finishing or skipping
	tells the server (MetaRequest "TutorialDone", true = finished), so it never shows again; anyone who has already
	finished a run counts as done. ClientState.TutorialStep tells the HUD which buttons to show.
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
local PAN_TRAVEL = 0.9 -- seconds for the camera to turn to the thing...
local PAN_BACK = 0.9 -- ...and to turn back

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

function Tutorial.Init()
	if initialized then
		return
	end
	initialized = true

	local gui, root = UIKit.CreateScreen("Tutorial", 40)
	local rewardText = Config.RewardText(Config.Tutorial.Reward)

	----------------------------------------------------------------------------------------------
	-- The hint card.
	----------------------------------------------------------------------------------------------
	local holder = Instance.new("Frame")
	holder.Name = "HintHolder"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Size = UDim2.fromOffset(560, 136)
	holder.BackgroundTransparency = 1
	holder.Visible = false
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
		dot.Position = UDim2.new(0, 18 + (i - 1) * 20, 1, -16)
		dot.Size = UDim2.fromOffset(12, 12)
		dot.BackgroundColor3 = Colors.PanelLight
		dot.BorderSizePixel = 0
		UIKit.Corner(dot, 6)
		dot.Parent = card
		dots[i] = dot
	end
	local skipButton = UIKit.Button({
		Text = "Skip tutorial",
		Color = Colors.PanelLight,
		TextColor3 = Colors.TextDim,
		TextSize = 14,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -12, 1, -10),
		Size = UDim2.fromOffset(136, 34),
		Parent = card,
	})

	local function place()
		local canvas = UIKit.CanvasSize()
		holder.Size = UDim2.fromOffset(math.min(560, canvas.X - 24), 136)
		holder.Position = UDim2.new(0.5, 0, 0, UIKit.TopInset() + 78)
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
		pcall(function()
			local selected = GuiService.SelectedObject
			if selected and selected:IsDescendantOf(confirm) then
				GuiService.SelectedObject = nil
			end
		end)
	end
	local function openConfirm()
		local canvas = UIKit.CanvasSize()
		confirmCard.Size = UDim2.fromOffset(math.min(440, canvas.X - 32), 270)
		confirm.Visible = true
		UIKit.Bounce(confirmCard)
		UIKit.PlaySound("Pop")
		if UIKit.IsGamepad() then
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

	-- A pulsing gold outline on the Upgrades button.
	local pulse: UIStroke? = nil
	local pulseTween: Tween? = nil
	local function pulseUpgrades(on: boolean)
		local hud = require(Client:WaitForChild("HUD")) :: any
		local button = hud.UpgradesButton :: GuiObject?
		if on and button and not pulse then
			local stroke = Instance.new("UIStroke")
			stroke.Color = Colors.Coin
			stroke.Thickness = 3
			stroke.Parent = button
			local tween = TweenService:Create(stroke, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Thickness = 8 })
			tween:Play()
			pulse, pulseTween = stroke, tween
		elseif not on and pulse then
			if pulseTween then
				pulseTween:Cancel()
			end
			pulse:Destroy()
			pulse, pulseTween = nil, nil
		end
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
		local function finish()
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
		panCancel = finish
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
					finish()
					return
				end
			end
			if now - startedAt > 15 or not currentRoot then
				finish() -- (never stuck: they died, or something else took too long)
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
	-- The steps.
	----------------------------------------------------------------------------------------------
	local isTouch = UIKit.IsTouch() and not UIKit.IsGamepad()
	local finished = false
	local finishedAt = 0
	local step = 0
	local resumeStep = 1 -- where the tutorial carries on if a run ends in the middle of it
	local stepSince = 0
	local baseline = 0
	local panned: { [number]: boolean } = {} -- the camera has looked at this step's thing already
	local shown = 0
	local shownText = ""
	local function setStep(n: number)
		if n > step and step >= 1 then
			-- (the step before this one is done)
			paintDots(step)
			UIKit.PlaySound("Sparkle")
			UIKit.Bounce(card)
		end
		step = n
		stepSince = os.clock()
		ClientState.TutorialStep = if n >= 1 and n <= TOTAL_STEPS then n else nil
		ClientState.Changed:Fire("Tutorial")
		local run = ClientState.Run :: Types.RunState?
		baseline = if run then upgradeLevels(run) else 0
	end

	local function showHint(n: number, text: string)
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
	end

	local function finish(completed: boolean)
		if finished then
			return
		end
		finished = true
		finishedAt = os.clock()
		closeConfirm()
		cancelPan()
		clearPointer()
		pulseUpgrades(false)
		step = 0
		ClientState.TutorialStep = nil
		ClientState.Changed:Fire("Tutorial")
		task.spawn(function()
			ClientState.MetaRequest("TutorialDone", completed)
		end)
		if completed then
			paintDots(TOTAL_STEPS)
			stepLabel.Text = "ALL SET!"
			hintLabel.Text = "You did it! Your reward is on its way. Clean every dish to finish the level."
			shownText = ""
			holder.Visible = true
			UIKit.Bounce(card)
			UIKit.PlaySound("Sparkle")
			UIKit.Confetti(60)
			task.delay(6, function()
				if finished then
					holder.Visible = false
				end
			end)
		else
			holder.Visible = false
		end
	end
	skipButton.Activated:Connect(function()
		if not finished then
			openConfirm()
		end
	end)
	skipYesButton.Activated:Connect(function()
		finish(false)
	end)

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
					ClientState.TutorialStep = nil
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
				pulseUpgrades(false)
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
					showHint(1, if isTouch then "Press and hold on a dirty dish to scrub it clean!" else "Hold the mouse button on a dirty dish to scrub it clean!")
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
				if (run.Coins or 0) > 0 then
					cancelPan()
					clearPointer()
					setStep(4)
				end
			elseif step == 4 then
				showHint(4, if isTouch then "Coins buy upgrades! Tap Upgrades to open the Upgrade Book." else "Coins buy upgrades! Press TAB or click Upgrades to open the Upgrade Book.")
				pulseUpgrades(true)
				if UIKit.IsWindowOpen("Upgrades") then
					pulseUpgrades(false)
					setStep(5)
				end
			elseif step == 5 then
				showHint(5, "Buy something you can afford: upgrades make you clean faster and carry more.")
				if upgradeLevels(run) > baseline or (not UIKit.IsWindowOpen("Upgrades") and os.clock() - stepSince > 1.5) then
					finish(true)
				end
			end
		end
	end)

	gui.Destroying:Connect(cancelPan)
end

return Tutorial
