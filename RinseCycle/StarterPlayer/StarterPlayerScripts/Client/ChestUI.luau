--[[
	ChestUI - the Treasure Chest event, played at the chest itself (LobbyBuilder's "EventChest").

	  * Above the chest: a board with every reward and its exact chance, and "1 FREE CHEST!" while
	    you still have your free one.
	  * Walk up to it and the Open boxes come up at the bottom of the screen: OPEN 1 (FREE, or 49 R$),
	    OPEN 3 and OPEN 10. They're priced like cinema popcorn: x3 is barely cheaper per chest (and
	    looks it, small and grey), x10 is the big gold BEST VALUE. E opens one.
	  * Opening: the lid flies open and a card spins for every chest, slowing down until it lands on
	    what you got (like a rank roll), rarest last with confetti.
	  * The HUD's Event button (and E anywhere else in the lobby) takes you to the chest.

	Free chests ask EventService (ChestRequest "Free"); bought packs open on the server when Roblox
	confirms the purchase, and the results arrive on ChestResult. Studio: packs without a product
	ID open for free (ChestRequest "Test").
]]

local CollectionService = game:GetService("CollectionService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local ChestUI = {}

local Colors = UIKit.Theme.Colors
local LocalPlayer = Players.LocalPlayer

local NEAR = 16 -- studs from the chest for the Open boxes
local CARD_W, CARD_H = 150, 180

local initialized = false
local busy = false
local revealing = false
local near = false
local promptsShown = 0
local panel: Frame
local firstLabel: TextLabel
local firstPrice: TextLabel
local firstButton: TextButton
local freeSign: TextLabel? = nil
local reveal: Frame
local revealGrid: Frame
local revealTitle: TextLabel
local revealDone: TextButton

----------------------------------------------------------------------------------------------------
-- Rewards: how each one looks
----------------------------------------------------------------------------------------------------

local function rewardColor(r: any): Color3
	if r.Kind == "Bubbles" then
		return Colors.Bubble
	elseif r.Kind == "Gems" then
		return Colors.Primary
	elseif r.Kind == "Boost" then
		return Colors.Good
	elseif r.Kind == "Pet" then
		if (r.Tier or 1) > 1 then
			return Config.PetTiers[r.Tier].Color or Colors.Coin
		end
		local pet = Config.Pets[r.Pet]
		local rarity = pet and Config.Rarities[pet.Rarity]
		return if rarity then rarity.Color else Colors.Accent
	end
	return Colors.Coin
end

local function rewardIcon(r: any): string
	if r.Kind == "Bubbles" then
		return "Bubble"
	elseif r.Kind == "Gems" then
		return "Gem"
	elseif r.Kind == "Boost" then
		return "Drop"
	elseif r.Kind == "Pet" then
		return "Paw"
	end
	return "Crown"
end

-- How rare a reward feels, from its chance.
local function tierOf(r: any): (string, number)
	if r.Chance < 1 then
		return "LEGENDARY", 4
	elseif r.Chance < 5 then
		return "EPIC", 3
	elseif r.Chance < 15 then
		return "RARE", 2
	end
	return "COMMON", 1
end

local function pctText(chance: number): string
	return if chance < 1 then string.format("%.1f%%", chance) else string.format("%g%%", chance)
end

----------------------------------------------------------------------------------------------------
-- The chest in the world
----------------------------------------------------------------------------------------------------

local function chestModel(): Model?
	for _, m in CollectionService:GetTagged("EventChest") do
		if m:IsA("Model") and m:IsDescendantOf(workspace) then
			return m
		end
	end
	return nil
end

local function chestPivot(): CFrame?
	local model = chestModel()
	local box = model and model.PrimaryPart
	return if box then box.CFrame else nil
end

-- The odds board and the free sign above the chest (built here, so each player sees their own).
local function buildBoard(model: Model): boolean
	local box = model.PrimaryPart
	if not box or freeSign ~= nil then
		return false
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "OddsBoard"
	gui.Adornee = box
	gui.Size = UDim2.fromScale(10, 9)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 8.5, 0) -- above the lid, under the title sign
	gui.MaxDistance = 70
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	local list = Instance.new("Frame")
	list.BackgroundColor3 = Colors.PanelDark
	list.BackgroundTransparency = 0.15
	list.Size = UDim2.fromScale(1, 0.84)
	list.Position = UDim2.fromScale(0, 0.16)
	UIKit.Corner(list, 14)
	list.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0.01, 0)
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.03, 0)
	pad.PaddingLeft = UDim.new(0.04, 0)
	pad.PaddingRight = UDim.new(0.04, 0)
	pad.Parent = list
	local count = #Config.ChestEvent.Rewards
	for i, r in Config.ChestEvent.Rewards do
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.fromScale(1, 0.94 / count - 0.01)
		row.LayoutOrder = i
		row.Parent = list
		local name = UIKit.Label({ Text = Config.ChestRewardName(r), TextScaled = true, TextColor3 = rewardColor(r), TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.fromScale(0.74, 1), Parent = row })
		local _ = name
		UIKit.Label({ Text = pctText(r.Chance), TextScaled = true, TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.fromScale(0.74, 0), Size = UDim2.fromScale(0.26, 1), Parent = row })
	end
	freeSign = UIKit.Label({ Name = "FreeSign", Text = "1 FREE CHEST!", TextScaled = true, TextColor3 = Colors.Good, Size = UDim2.fromScale(1, 0.14), Parent = gui })
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	return true
end

-- Lid open / shut (client only, just for looks). Lid parts turn about the back hinge.
local lidHome: { [BasePart]: CFrame } = {}
local function setLid(open: boolean)
	local model = chestModel()
	local box = model and model.PrimaryPart
	if not model or not box then
		return
	end
	local hinge = box.CFrame * CFrame.new(0, box.Size.Y / 2, box.Size.Z / 2)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and (CollectionService:HasTag(part, "EventChestLid") or part:GetAttribute("LidPart")) then
			lidHome[part] = lidHome[part] or part.CFrame
			local home = lidHome[part]
			local target = if open then hinge * CFrame.Angles(math.rad(-105), 0, 0) * hinge:Inverse() * home else home
			TweenService:Create(part, TweenInfo.new(if open then 0.35 else 0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { CFrame = target }):Play()
		end
	end
end

function ChestUI.GoToChest()
	local pivot = chestPivot()
	local character = LocalPlayer.Character
	if not pivot or not character or ClientState.Run ~= nil then
		if not pivot then
			UIKit.Toast("The Treasure Chest event isn't on right now.", "Info")
		end
		return
	end
	-- In front of the lock, looking at the chest.
	local spot = (pivot * CFrame.new(0, 1, -10)).Position
	character:PivotTo(CFrame.lookAt(spot, Vector3.new(pivot.Position.X, spot.Y, pivot.Position.Z)))
end

----------------------------------------------------------------------------------------------------
-- Reveal: one spinning card per chest
----------------------------------------------------------------------------------------------------

local function paintCard(card: Frame, r: any, landed: boolean)
	local color = rewardColor(r)
	card.BackgroundColor3 = UIKit.Darken(color, 0.55)
	local stroke = card:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = color
	end
	local holder = card:FindFirstChild("IconHolder") :: Frame
	for _, c in holder:GetChildren() do
		c:Destroy()
	end
	local icon = UIKit.Icon(rewardIcon(r), 64, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5) })
	icon.Parent = holder
	local name = card:FindFirstChild("RewardName") :: TextLabel
	name.Text = Config.ChestRewardName(r)
	name.TextColor3 = color
	local tierLabel = card:FindFirstChild("Tier") :: TextLabel
	tierLabel.Text = if landed then (tierOf(r)) else ""
	tierLabel.TextColor3 = color
end

local function makeCard(i: number): Frame
	local card = Instance.new("Frame")
	card.Name = "Card" .. i
	card.LayoutOrder = i
	card.BackgroundColor3 = Colors.PanelLight
	UIKit.Corner(card, 14)
	UIKit.Stroke(card, Colors.Coin, 3, 0)
	local holder = Instance.new("Frame")
	holder.Name = "IconHolder"
	holder.BackgroundTransparency = 1
	holder.Position = UDim2.fromScale(0, 0.12)
	holder.Size = UDim2.fromScale(1, 0.5)
	holder.Parent = card
	UIKit.Label({ Name = "Tier", Text = "", TextSize = 14, Position = UDim2.fromScale(0, 0.02), Size = UDim2.fromScale(1, 0.12), Parent = card })
	UIKit.Label({ Name = "RewardName", Text = "", TextScaled = true, TextWrapped = true, AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.new(1, -10, 0.3, 0), Parent = card })
	local scale = Instance.new("UIScale")
	scale.Name = "Pop"
	scale.Parent = card
	return card
end

-- Picks a random reward by weight, for the spinning faces.
local function randomReward(): any
	local x = math.random() * 100
	for _, r in Config.ChestEvent.Rewards do
		x -= r.Chance
		if x <= 0 then
			return r
		end
	end
	return Config.ChestEvent.Rewards[1]
end

local function showResults(results: { any })
	if type(results) ~= "table" or #results == 0 then
		return
	end
	revealing = true
	panel.Visible = false
	for _, c in revealGrid:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local count = #results
	local layout = revealGrid:FindFirstChildOfClass("UIGridLayout") :: UIGridLayout
	local scale = if count == 1 then 1.35 elseif count <= 3 then 1.1 else 0.8
	layout.CellSize = UDim2.fromOffset(math.floor(CARD_W * scale), math.floor(CARD_H * scale))
	revealTitle.Text = if count == 1 then "OPENING..." else string.format("OPENING %d CHESTS...", count)
	revealDone.Visible = false
	reveal.Visible = true
	UIKit.Bounce(reveal)
	setLid(true)
	UIKit.PlaySound("Sparkle")

	-- Land the rarest last, so the best moment comes at the end.
	local order = {}
	for i, res in results do
		local def = Config.ChestEvent.Rewards[tonumber(res.Index) or 0] or Config.ChestEvent.Rewards[1]
		table.insert(order, { Def = def, Text = res.Text, I = i })
	end
	local cards = {}
	for i = 1, count do
		local card = makeCard(i)
		card.Parent = revealGrid
		paintCard(card, randomReward(), false)
		cards[i] = card
	end
	local landOrder = table.clone(order)
	table.sort(landOrder, function(a, b)
		local ta, tb = select(2, tierOf(a.Def)), select(2, tierOf(b.Def))
		if ta ~= tb then
			return ta < tb
		end
		return a.I < b.I
	end)
	local landAt: { [number]: number } = {}
	local start = os.clock()
	local spinFor = if count == 1 then 2.4 else 1.6
	local step = if count == 1 then 0 else math.min(0.22, 1.6 / count)
	for k, entry in landOrder do
		landAt[entry.I] = spinFor + (k - 1) * step
	end
	local nextFlip: { [number]: number } = {}
	local landed: { [number]: boolean } = {}
	local best = 0
	while true do
		local t = os.clock() - start
		local all = true
		for i, card in cards do
			if not landed[i] then
				all = false
				local left = landAt[i] - t
				if left <= 0 then
					landed[i] = true
					local entry = order[i]
					paintCard(card, entry.Def, true)
					local nameLabel = card:FindFirstChild("RewardName") :: TextLabel
					nameLabel.Text = tostring(entry.Text)
					local pop = card:FindFirstChild("Pop") :: UIScale
					pop.Scale = 1.25
					TweenService:Create(pop, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
					local tier = select(2, tierOf(entry.Def))
					best = math.max(best, tier)
					UIKit.PlaySound(if tier >= 3 then "Sparkle" else "Pop", 0.9 + tier * 0.1)
					if tier >= 3 then
						UIKit.Confetti(if tier >= 4 then 140 else 70)
					end
				elseif t >= (nextFlip[i] or 0) then
					-- Faster at first, slowing right down as it lands.
					local gap = 0.05 + 0.3 * math.clamp(1 - left / 1.2, 0, 1) ^ 2
					nextFlip[i] = t + gap
					paintCard(card, randomReward(), false)
					UIKit.PlaySound("Click", 1.4)
				end
			end
		end
		if all then
			break
		end
		RunService.RenderStepped:Wait()
	end
	revealTitle.Text = if best >= 4 then "JACKPOT!" elseif best >= 3 then "AMAZING!" else "YOU GOT"
	revealDone.Visible = true
	UIKit.Bounce(revealDone)
end

local function finishReveal()
	reveal.Visible = false
	revealing = false
	setLid(false)
end

----------------------------------------------------------------------------------------------------
-- Opening
----------------------------------------------------------------------------------------------------

local function freeLeft(): number
	local meta = ClientState.Meta :: any
	return if meta then tonumber(meta.ChestFreeLeft) or 0 else 0
end

local function request(action: string, value: any?)
	if busy or revealing then
		return
	end
	busy = true
	local ok, result = pcall(function()
		return Remotes.Function("ChestRequest"):InvokeServer(action, value)
	end)
	busy = false
	if ok and result and result.Ok then
		task.spawn(showResults, result.Rewards)
	else
		UIKit.Toast(if ok and result then result.Error or "Couldn't open that." else "Couldn't open that.", "Info")
	end
end

function ChestUI.Open(count: number)
	if busy or revealing then
		return
	end
	if count == 1 and freeLeft() > 0 then
		task.spawn(request, "Free")
		return
	end
	for _, pack in Config.ChestEvent.Packs do
		if pack.Count == count then
			local id = Config.EventProducts[pack.Key]
			if type(id) == "number" and id > 0 then
				pcall(function()
					MarketplaceService:PromptProductPurchase(LocalPlayer, id)
				end)
			else
				task.spawn(request, "Test", pack.Count) -- Studio: free test
			end
			return
		end
	end
end

----------------------------------------------------------------------------------------------------
-- The Open boxes
----------------------------------------------------------------------------------------------------

-- style: "plain", "decoy" (the x3: small and grey on purpose) or "best" (the big gold x10).
local function openBox(parent: Frame, pack: any, style: string, order: number): (TextButton, TextLabel, TextLabel)
	local base = Config.ChestEvent.Packs[1]
	local each = pack.Price / pack.Count
	local save = math.floor((1 - each / (base.Price / base.Count)) * 100 + 0.5)
	local w, h = if style == "best" then 200 elseif style == "decoy" then 128 else 150, if style == "best" then 132 elseif style == "decoy" then 96 else 112
	local color = if style == "best" then Colors.Coin elseif style == "decoy" then Colors.Disabled else Colors.Primary
	local button = Instance.new("TextButton")
	button.Name = "Open" .. pack.Count
	button.Text = ""
	button.AutoButtonColor = false
	button.LayoutOrder = order
	button.Size = UDim2.fromOffset(w, h)
	button.BackgroundColor3 = if style == "best" then UIKit.Darken(Colors.Coin, 0.45) else Colors.PanelDark
	UIKit.Corner(button, 16)
	UIKit.Stroke(button, color, if style == "best" then 4 else 3, 0)
	local title = UIKit.Label({
		Name = "Title",
		Text = string.format("OPEN %d", pack.Count),
		TextSize = if style == "best" then 30 elseif style == "decoy" then 18 else 24,
		TextColor3 = if style == "decoy" then Colors.TextDim else Colors.Text,
		Position = UDim2.fromScale(0, 0.08),
		Size = UDim2.fromScale(1, 0.32),
		Parent = button,
	})
	local price = UIKit.Label({
		Name = "Price",
		Text = string.format("R$ %d", pack.Price),
		TextSize = if style == "best" then 28 elseif style == "decoy" then 16 else 22,
		TextColor3 = if style == "best" then Colors.Good elseif style == "decoy" then Colors.TextDim else Colors.Coin,
		Position = UDim2.fromScale(0, 0.4),
		Size = UDim2.fromScale(1, 0.3),
		Parent = button,
	})
	UIKit.Label({
		Name = "Each",
		Text = if save > 0 then string.format("%d each, save %d%%", math.floor(each + 0.5), save) else "per chest",
		TextSize = if style == "best" then 15 else 12,
		TextColor3 = if style == "best" then Colors.Good else Colors.TextDim,
		Position = UDim2.fromScale(0, 0.72),
		Size = UDim2.fromScale(1, 0.2),
		Parent = button,
	})
	if pack.Tag then
		local ribbon = Instance.new("Frame")
		ribbon.Name = "Ribbon"
		ribbon.AnchorPoint = Vector2.new(0.5, 0.5)
		ribbon.Position = UDim2.fromScale(0.5, 0)
		ribbon.Size = UDim2.fromOffset(w - 30, 28)
		ribbon.BackgroundColor3 = Colors.Bad
		ribbon.ZIndex = 3
		UIKit.Corner(ribbon, 14)
		UIKit.Stroke(ribbon, Colors.Ink, 2)
		UIKit.Label({ Text = pack.Tag, TextSize = 16, Size = UDim2.fromScale(1, 1), ZIndex = 4, Parent = ribbon })
		ribbon.Parent = button
		local pulse = Instance.new("UIScale")
		pulse.Parent = button
		TweenService:Create(pulse, TweenInfo.new(0.7, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Scale = 1.05 }):Play()
	end
	button.Activated:Connect(function()
		UIKit.PlaySound("Click")
		ChestUI.Open(pack.Count)
	end)
	button.Parent = parent
	return button, title, price
end

local function refresh()
	local free = freeLeft()
	local packOne = Config.ChestEvent.Packs[1]
	if free > 0 then
		firstLabel.Text = "OPEN 1"
		firstPrice.Text = "FREE!"
		firstPrice.TextColor3 = Colors.Good
	else
		firstLabel.Text = "OPEN 1"
		firstPrice.Text = string.format("R$ %d", packOne.Price)
		firstPrice.TextColor3 = Colors.Coin
	end
	local each = firstButton:FindFirstChild("Each")
	if each and each:IsA("TextLabel") then
		each.Visible = free <= 0
	end
	local stroke = firstButton:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if free > 0 then Colors.Good else Colors.Primary
	end
	if freeSign then
		(freeSign :: TextLabel).Visible = free > 0
	end
end

function ChestUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, root = UIKit.CreateScreen("ChestUI", 9)
	panel = Instance.new("Frame")
	panel.Name = "OpenBoxes"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -24)
	panel.Size = UDim2.fromOffset(520, 150)
	panel.BackgroundTransparency = 1
	panel.Visible = false
	panel.Parent = root
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.HorizontalAlignment = Enum.HorizontalAlignment.Center
	row.VerticalAlignment = Enum.VerticalAlignment.Bottom
	row.Padding = UDim.new(0, 14)
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.Parent = panel
	local packs = Config.ChestEvent.Packs
	firstButton, firstLabel, firstPrice = openBox(panel, packs[1], "plain", 1)
	-- The E hint on the first box.
	local hint = Instance.new("Frame")
	hint.Name = "KeyHint"
	hint.Position = UDim2.fromOffset(-8, -8)
	hint.Size = UDim2.fromOffset(30, 28)
	hint.BackgroundColor3 = Colors.PanelDark
	hint.ZIndex = 5
	UIKit.Corner(hint, 8)
	UIKit.Stroke(hint, Colors.Ink, 2)
	UIKit.Label({ Text = "E", TextSize = 16, Size = UDim2.fromScale(1, 1), ZIndex = 6, Parent = hint })
	hint.Parent = firstButton
	openBox(panel, packs[2], "decoy", 2)
	openBox(panel, packs[3], "best", 3)

	-- The reveal (over everything).
	local _rgui, revealRoot = UIKit.CreateScreen("ChestReveal", 40)
	reveal = Instance.new("Frame")
	reveal.Name = "Reveal"
	reveal.AnchorPoint = Vector2.new(0.5, 0.5)
	reveal.Position = UDim2.fromScale(0.5, 0.5)
	reveal.Size = UDim2.fromOffset(860, 520)
	reveal.BackgroundColor3 = Colors.PanelDark
	reveal.BackgroundTransparency = 0.05
	reveal.Visible = false
	UIKit.Corner(reveal, 20)
	UIKit.Stroke(reveal, Colors.Coin, 4, 0)
	reveal.Parent = revealRoot
	revealTitle = UIKit.Label({ Text = "", TextSize = 38, TextColor3 = Colors.Coin, Position = UDim2.fromOffset(0, 12), Size = UDim2.new(1, 0, 0, 46), Parent = reveal })
	revealGrid = Instance.new("Frame")
	revealGrid.Name = "Grid"
	revealGrid.BackgroundTransparency = 1
	revealGrid.Position = UDim2.fromOffset(20, 66)
	revealGrid.Size = UDim2.new(1, -40, 1, -150)
	revealGrid.Parent = reveal
	local grid = Instance.new("UIGridLayout")
	grid.CellPadding = UDim2.fromOffset(12, 12)
	grid.HorizontalAlignment = Enum.HorizontalAlignment.Center
	grid.VerticalAlignment = Enum.VerticalAlignment.Center
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = revealGrid
	revealDone = UIKit.Button({
		Text = "AWESOME!",
		Color = Colors.Good,
		TextSize = 24,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(240, 56),
		Parent = reveal,
		OnClick = finishReveal,
	})

	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" then
			refresh()
		end
	end)
	Remotes.Event("ChestResult").OnClientEvent:Connect(function(results)
		task.spawn(showResults, results)
	end)
	ProximityPromptService.PromptShown:Connect(function()
		promptsShown += 1
	end)
	ProximityPromptService.PromptHidden:Connect(function()
		promptsShown = math.max(0, promptsShown - 1)
	end)
	-- E: open one at the chest; anywhere else in the lobby, go to it. (Leaves E alone while
	-- another prompt is up or you're typing.)
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.KeyCode ~= Enum.KeyCode.E or processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if ClientState.Run ~= nil or promptsShown > 0 or revealing or UIKit.IsWindowOpen() then
			return
		end
		if not Config.ChestEventLive() then
			return
		end
		if near then
			ChestUI.Open(1)
		else
			ChestUI.GoToChest()
		end
	end)

	-- Near the chest? Show the boxes. (Also builds the odds board once the chest has streamed in.)
	task.spawn(function()
		while true do
			local model = chestModel()
			if model and buildBoard(model) then
				refresh()
			end
			local pivot = chestPivot()
			local character = LocalPlayer.Character
			local rootPart = character and character:FindFirstChild("HumanoidRootPart")
			local isNear = pivot ~= nil
				and rootPart ~= nil
				and rootPart:IsA("BasePart")
				and ClientState.Run == nil
				and (rootPart.Position - pivot.Position).Magnitude <= NEAR
			if isNear ~= near then
				near = isNear
				refresh()
				if near and not revealing then
					panel.Visible = true
					UIKit.Bounce(panel)
				end
			end
			if not near then
				panel.Visible = false
			elseif not revealing then
				panel.Visible = not UIKit.IsWindowOpen()
			end
			task.wait(0.2)
		end
	end)
	refresh()
end

return ChestUI
