--[[
	Tutorial - the first-run guide for new players (level 1, the kitchen).

	Until it is finished (or skipped) the screen stays simple: only the coins, the tank and the progress bar are there. A
	hint card at the top says what to do next and the world points at it, then each step shows a bit more:

	  1. Hold on a dirty dish to scrub it clean (the closest dish is marked)
	  2. Keep scrubbing: every spot you clean fills the tank
	  3. Tank filling up: walk to the glowing drain to sell it for coins (the drain is marked)
	  4. Coins buy upgrades: press Tab / tap Upgrades (that button appears and pulses)
	  5. Inside the Upgrade Book: buy something
	  6. Done: the rest of the buttons appear

	Finishing or skipping it tells the server (MetaRequest "TutorialDone"), so it never shows again; anyone who has
	already finished a run counts as done. ClientState.TutorialStep tells the HUD which buttons to show.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))
local ClientState = require(Client:WaitForChild("ClientState"))
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types"))

local Tutorial = {}

local Colors = UIKit.Theme.Colors
local LocalPlayer = Players.LocalPlayer

local initialized = false

local TOTAL_STEPS = 5

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

	local _gui, root = UIKit.CreateScreen("Tutorial", 40)

	-- The hint card.
	local holder = Instance.new("Frame")
	holder.Name = "HintHolder"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Size = UDim2.fromOffset(560, 104)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder.Parent = root
	local card = UIKit.Card({ Name = "Hint", Position = UDim2.fromOffset(4, 3), Size = UDim2.new(1, -8, 1, -6), Color = Colors.PanelDark, Parent = holder })
	UIKit.Stroke(card, Colors.Good, 3, 0)
	local stepLabel = UIKit.Label({ Text = "", Font = UIKit.Theme.Fonts.Title, TextSize = 16, TextColor3 = Colors.Good, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(16, 8), Size = UDim2.new(1, -140, 0, 20), Parent = card })
	local hintLabel = UIKit.Label({ Text = "", Font = UIKit.Theme.Fonts.Title, TextSize = 22, TextWrapped = true, TextScaled = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(16, 32), Size = UDim2.new(1, -32, 1, -42), Parent = card })
	local skipButton = UIKit.Button({
		Text = "Skip",
		Color = Colors.PanelLight,
		TextSize = 16,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 6),
		Size = UDim2.fromOffset(90, 28),
		Parent = card,
	})

	local function place()
		holder.Position = UDim2.new(0.5, 0, 0, UIKit.TopInset() + 78)
	end
	place()
	UIKit.LayoutChanged:Connect(place)

	-- The pointer in the world: a bouncing arrow over a dish or the drain.
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
		local gui = Instance.new("BillboardGui")
		gui.Name = "TutorialPointer"
		gui.Adornee = adornee
		gui.AlwaysOnTop = true
		gui.Size = UDim2.fromOffset(70, 70)
		gui.StudsOffsetWorldSpace = Vector3.new(0, 7, 0)
		gui.MaxDistance = 400
		gui.LightInfluence = 0
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
		arrow.Parent = gui
		TweenService:Create(arrow, TweenInfo.new(0.45, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Position = UDim2.fromOffset(0, 14) }):Play()
		gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
		pointerGui = gui
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

	local function nearestDish(run: Types.RunState): Instance?
		local arenas = workspace:FindFirstChild("Arenas")
		local arena = arenas and arenas:FindFirstChild(run.ArenaName)
		local dishes = arena and arena:FindFirstChild("Dishes")
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not dishes or not root then
			return nil
		end
		local best, bestD = nil, math.huge
		for _, d in dishes:GetChildren() do
			if d:IsA("Model") then
				local d2 = (d:GetPivot().Position - root.Position).Magnitude
				if d2 < bestD then
					best, bestD = d, d2
				end
			end
		end
		return best
	end

	local isTouch = UIKit.IsTouch() and not UIKit.IsGamepad()
	local finished = false
	local step = 0
	local resumeStep = 1 -- where the tutorial carries on if a run ends in the middle of it
	local stepSince = 0
	local baseline = 0
	local showHint: (number, string) -> ()
	local function setStep(n: number)
		step = n
		stepSince = os.clock()
		ClientState.TutorialStep = if n >= 1 and n <= TOTAL_STEPS then n else nil
		ClientState.Changed:Fire("Tutorial")
		local run = ClientState.Run :: Types.RunState?
		baseline = if run then upgradeLevels(run) else 0
	end

	local function finish(toast: boolean)
		if finished then
			return
		end
		finished = true
		clearPointer()
		pulseUpgrades(false)
		step = 0
		ClientState.TutorialStep = nil
		ClientState.Changed:Fire("Tutorial")
		task.spawn(function()
			ClientState.MetaRequest("TutorialDone")
		end)
		if toast then
			stepLabel.Text = "ALL SET!"
			hintLabel.Text = "That's it! Clean every dish to finish the level, then try the next kitchen."
			holder.Visible = true
			UIKit.Bounce(card)
			UIKit.PlaySound("Sparkle")
			UIKit.Confetti(60)
			task.delay(6, function()
				holder.Visible = false
			end)
		else
			holder.Visible = false
		end
	end
	skipButton.Activated:Connect(function()
		finish(false)
	end)

	local shown = 0
	showHint = function(n: number, text: string)
		stepLabel.Text = string.format("TIP %d of %d", n, TOTAL_STEPS)
		hintLabel.Text = text
		if shown ~= n then
			shown = n
			holder.Visible = true
			UIKit.Bounce(card)
			UIKit.PlaySound("Pop")
		end
	end

	task.spawn(function()
		while not finished do
			task.wait(0.25)
			local meta = ClientState.Meta :: any
			local run = ClientState.Run :: Types.RunState?
			if not meta or meta.TutorialDone == true then
				if meta and meta.TutorialDone == true then
					finished = true
					ClientState.TutorialStep = nil
				end
				continue
			end
			local active = run ~= nil and run.Level == 1 and run.Phase == "Playing" and (run.ClockAt or 0) > 0
			if not active or not run then
				-- between runs: the card goes, the screen goes back to normal; the tutorial picks up again next run
				holder.Visible = false
				shown = 0
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
			end
			local tankFrac = if run.TankMax > 0 then run.Tank / run.TankMax else 0
			if step == 1 then
				showHint(1, if isTouch then "Press and hold on a dirty dish to scrub it clean!" else "Hold the mouse button on a dirty dish to scrub it clean!")
				pointAt(nearestDish(run))
				if (run.Cleaned or 0) >= 1 then
					clearPointer()
					setStep(2)
				end
			elseif step == 2 then
				showHint(2, "Nice! Keep scrubbing: every spot you clean fills your tank.")
				if (run.Cleaned or 0) >= 6 or tankFrac >= 0.4 then
					setStep(3)
				end
			elseif step == 3 then
				showHint(3, "Your tank fills up as you clean. Walk to the glowing drain to sell it for coins!")
				pointAt(nil, run.DrainPosition)
				if (run.Coins or 0) > 0 then
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
end

return Tutorial
