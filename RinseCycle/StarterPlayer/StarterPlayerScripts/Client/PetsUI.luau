-- PetsUI: the "Pets" inventory window and the "Eggs" hatchery window, plus the full-screen hatch
-- reveal animation. Everything here is built with UIKit; see DESIGN.md section 6 ("PetsUI") for
-- the contract. Both windows rebuild their contents from ClientState.Meta whenever it changes and
-- the relevant window is open, so a purchase/hatch/equip anywhere refreshes what's on screen.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Format = require(Shared:WaitForChild("Format"))
local PetModels = require(Shared:WaitForChild("PetModels"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local PetsUI = {}

local C = UIKit.Theme.Colors

----------------------------------------------------------------------------------------------------
-- Small shared helpers
----------------------------------------------------------------------------------------------------

-- A safe pet definition even for an id that has left Config (kept in the profile, per DESIGN /
-- PetService "profile hygiene"), so the inventory never errors on a stale entry.
local PLACEHOLDER_DEF = { Name = "???", Rarity = "Common", PowerShare = 0, CoinBonus = 0 }
local function petDef(id: string)
	return Config.Pets[id] or PLACEHOLDER_DEF
end

local function rarityOrder(rarity: string): number
	local def = Config.Rarities[rarity]
	return (def and def.Order) or 0
end

local ZERO_STATS = { Speed = 0, Capacity = 0, CoinBonus = 0 }
local function petStats(id: string, tier: number?)
	return Config.PetStats(id, tier) or ZERO_STATS
end

-- "Golden Rubber Duck" / "Rubber Duck".
local function petTitle(id: string, tier: number?): string
	local t = Config.PetTier(tier)
	return if t.Name ~= "" then t.Name .. " " .. petDef(id).Name else petDef(id).Name
end

-- meta.Pets sorted best-first: speed (tier included), then rarity, then Uid (stable).
local function sortedPetList(meta: Types.MetaState)
	local list = {}
	for _, entry in meta.Pets do
		local tier = entry.Tier or 1
		table.insert(list, { Uid = entry.Uid, Id = entry.Id, Tier = tier, Def = petDef(entry.Id), Stats = petStats(entry.Id, tier) })
	end
	table.sort(list, function(a, b)
		if a.Stats.Speed ~= b.Stats.Speed then
			return a.Stats.Speed > b.Stats.Speed
		end
		local ra, rb = rarityOrder(a.Def.Rarity), rarityOrder(b.Def.Rarity)
		if ra ~= rb then
			return ra > rb
		end
		return a.Uid < b.Uid
	end)
	return list
end

local function isEquipped(meta: Types.MetaState, uid: string): boolean
	return table.find(meta.Equipped, uid) ~= nil
end

-- "⚡ Speed 45%" (share of your pet power it cleans per second), "🎒 Holds 26", "+12% coins".
local function powerShareText(share: number): string
	local pct = (Format.Percent(share):gsub("^%+", ""))
	return string.format("⚡ Cleans at %s of your power", pct)
end
local function coinBonusText(bonus: number, capacity: number?): string
	local bag = if capacity then string.format("🎒 Holds %d  •  ", capacity) else ""
	return bag .. "💰 " .. Format.Percent(bonus) .. " coins"
end
local function shortStats(stats): string
	return string.format("⚡ %s  🎒 %d  💰 %s", (Format.Percent(stats.Speed):gsub("^%+", "")), stats.Capacity, Format.Percent(stats.CoinBonus))
end

----------------------------------------------------------------------------------------------------
-- Module state
----------------------------------------------------------------------------------------------------

local initialized = false
local root: Frame

local petsContent: Frame
local eggsContent: Frame

-- Pets window
local gridScroll: ScrollingFrame
local equippedLabel: TextLabel
local countLabel: TextLabel
local detailEmpty: Frame
local detailFilled: Frame
local detailViewport: ViewportFrame
local detailName: TextLabel
local detailRarity: TextLabel
local detailPower: TextLabel
local detailCoin: TextLabel
local equipButton: TextButton
local deleteConfirmFrame: Frame
local selectedUid: string? = nil
local deleteToken = 0

-- Merge mode: pick MergeCount pets of one rarity; they become one pet of the next rarity.
local MERGE_COUNT = Config.PetRules.MergeCount or 3
local mergeMode = false
local mergeSel: { string } = {}
local mergeButton: TextButton
local mergePanel: Frame
local mergeInfo: TextLabel
local mergeResult: TextLabel
local mergeGo: TextButton
local detailsCard: Frame

-- Eggs window
local eggTabsHolder: Frame
local eggViewport: ViewportFrame
local eggNameLabel: TextLabel
local eggCostLabel: TextLabel
local eggLockedLabel: TextLabel
local oddsScroll: ScrollingFrame
local hatch1Button: TextButton
local hatch3Button: TextButton
local currentEggId: string? = nil

----------------------------------------------------------------------------------------------------
-- Pets window: grid + details panel
----------------------------------------------------------------------------------------------------

local GRID_CELL = Vector2.new(122, 156)
local GRID_GAP = 10

-- Merge rule (same as the server): three of the same pet at the same tier -> that pet, next tier.
local function petOf(uid: string?)
	local meta = ClientState.Meta
	if not uid or not meta then
		return nil
	end
	for _, pet in meta.Pets do
		if pet.Uid == uid then
			return pet
		end
	end
	return nil
end
local function canMergeWith(first, pet): boolean
	local tier = pet.Tier or 1
	if tier >= #Config.PetTiers then
		return false
	end
	return first == nil or (first.Id == pet.Id and (first.Tier or 1) == tier)
end

local function buildPetCard(parent: Instance, entry, equipped: boolean, onClick: (uid: string) -> ())
	local card = UIKit.Card({
		Size = UDim2.fromOffset(GRID_CELL.X, GRID_CELL.Y),
		Color = C.PanelLight,
		StrokeColor = UIKit.RarityColor(entry.Def.Rarity),
		Parent = parent,
	})
	local stroke = card:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Thickness = 3
		stroke.Transparency = 0
	end

	-- Invisible hit surface. Not a UIKit.Button: we want the plain card look, not the chunky style.
	local hit = Instance.new("TextButton")
	hit.Name = "Hit"
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.Size = UDim2.fromScale(1, 1)
	hit.ZIndex = 5
	hit.AutoButtonColor = false
	hit.Parent = card

	local viewport = UIKit.Viewport({
		Model = PetModels.Build(entry.Id, entry.Tier),
		Size = UDim2.fromOffset(GRID_CELL.X - 16, 86),
		Position = UDim2.new(0.5, 0, 0, 6),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = card,
	})
	viewport.ZIndex = 1

	UIKit.Label({
		Text = petTitle(entry.Id, entry.Tier),
		TextColor3 = Config.PetTier(entry.Tier).Color or C.Text,
		Size = UDim2.new(1, -10, 0, 20),
		Position = UDim2.new(0.5, 0, 0, 96),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 16,
		TextScaled = true,
		Parent = card,
		ZIndex = 2,
	})
	UIKit.Label({
		Text = entry.Def.Rarity .. "  ⚡" .. (Format.Percent(entry.Stats.Speed):gsub("^%+", "")),
		Size = UDim2.new(1, -10, 0, 16),
		Position = UDim2.new(0.5, 0, 0, 118),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 13,
		TextColor3 = UIKit.RarityColor(entry.Def.Rarity),
		Parent = card,
		ZIndex = 2,
	})

	if equipped then
		local check = UIKit.Label({
			Text = "✔",
			Size = UDim2.fromOffset(26, 26),
			Position = UDim2.new(1, -4, 0, 4),
			AnchorPoint = Vector2.new(1, 0),
			TextSize = 20,
			TextColor3 = C.Good,
			Parent = card,
			ZIndex = 3,
		})
		check.Name = "EquippedCheck"
	end

	if mergeMode then
		local pick = table.find(mergeSel, entry.Uid)
		local blocked = not canMergeWith(petOf(mergeSel[1]), entry)
		if pick then
			local ring = UIKit.Stroke(card, C.Good, 4, 0)
			ring.Name = "MergeRing"
			local badge = UIKit.Label({
				Text = tostring(pick),
				Size = UDim2.fromOffset(28, 28),
				Position = UDim2.fromOffset(4, 4),
				TextSize = 20,
				TextColor3 = C.Good,
				Parent = card,
				ZIndex = 4,
			})
			badge.Name = "MergeBadge"
		elseif blocked then
			local shade = Instance.new("Frame")
			shade.Name = "Blocked"
			shade.Size = UDim2.fromScale(1, 1)
			shade.BackgroundColor3 = Color3.new(0, 0, 0)
			shade.BackgroundTransparency = 0.5
			shade.ZIndex = 4
			UIKit.Corner(shade, 12)
			shade.Parent = card
		end
	elseif selectedUid == entry.Uid then
		local ring = UIKit.Stroke(card, C.Text, 3, 0.35)
		ring.Name = "SelectRing"
	end

	hit.Activated:Connect(function()
		onClick(entry.Uid)
	end)
	return card
end

local function refreshDetailPanel(meta: Types.MetaState?)
	local entry = nil
	if meta and selectedUid then
		for _, pet in meta.Pets do
			if pet.Uid == selectedUid then
				entry = { Uid = pet.Uid, Id = pet.Id, Tier = pet.Tier or 1, Def = petDef(pet.Id), Stats = petStats(pet.Id, pet.Tier) }
				break
			end
		end
	end
	if not entry then
		selectedUid = nil
		detailEmpty.Visible = true
		detailFilled.Visible = false
		return
	end

	detailEmpty.Visible = false
	detailFilled.Visible = true
	deleteConfirmFrame.Visible = false

	UIKit.SetViewportModel(detailViewport, PetModels.Build(entry.Id, entry.Tier), true)
	detailName.Text = petTitle(entry.Id, entry.Tier)
	detailRarity.Text = entry.Def.Rarity
	detailRarity.TextColor3 = UIKit.RarityColor(entry.Def.Rarity)
	detailPower.Text = powerShareText(entry.Stats.Speed)
	detailCoin.Text = coinBonusText(entry.Stats.CoinBonus, entry.Stats.Capacity)

	local equipped = isEquipped(meta :: Types.MetaState, entry.Uid)
	equipButton.Text = if equipped then "Unequip" else "Equip"
	equipButton.BackgroundColor3 = if equipped then C.Warning else C.Good
end

local function refreshMergePanel()
	local first = petOf(mergeSel[1])
	mergeInfo.Text = string.format("Pick %d of the same pet (same tier). Picked %d/%d.", MERGE_COUNT, #mergeSel, MERGE_COUNT)
	if first then
		local nextTier = (first.Tier or 1) + 1
		local tierDef = Config.PetTier(nextTier)
		mergeResult.Text = "➡️ " .. petTitle(first.Id, nextTier)
		mergeResult.TextColor3 = tierDef.Color or C.Text
	else
		mergeResult.Text = "➡️ Golden, then Rainbow!"
		mergeResult.TextColor3 = C.TextDim
	end
	UIKit.SetButtonColor(mergeGo, if #mergeSel == MERGE_COUNT then C.Good else C.Disabled)
end

local function selectPet(uid: string?)
	if mergeMode then
		local meta = ClientState.Meta
		if uid and meta then
			local at = table.find(mergeSel, uid)
			if at then
				table.remove(mergeSel, at)
			elseif #mergeSel < MERGE_COUNT then
				local pet = petOf(uid)
				if pet and (pet.Tier or 1) >= #Config.PetTiers then
					UIKit.Toast("Rainbow pets are already maxed!", "Bad")
				elseif pet and not canMergeWith(petOf(mergeSel[1]), pet) then
					UIKit.Toast("Pick three of the SAME pet at the same tier.", "Bad")
				elseif pet then
					table.insert(mergeSel, uid)
				end
			end
		end
		refreshMergePanel()
		PetsUI._refreshGrid()
		return
	end
	selectedUid = uid
	deleteConfirmFrame.Visible = false
	refreshDetailPanel(ClientState.Meta)
	-- The grid highlights the selection: cheapest is a full rebuild, and this list is at most
	-- Config.PetRules.MaxInventory (60) cards, so it's not worth a more surgical update.
	PetsUI._refreshGrid()
end

local function setMergeMode(on: boolean)
	mergeMode = on
	table.clear(mergeSel)
	mergePanel.Visible = on
	detailEmpty.Parent = if on then nil else detailsCard
	detailFilled.Parent = if on then nil else detailsCard
	mergeButton.Text = if on then "Done" else "🔮 Merge"
	if on then
		refreshMergePanel()
	end
	PetsUI._refreshGrid()
end

local function doMerge()
	if #mergeSel ~= MERGE_COUNT then
		UIKit.Toast(string.format("Pick %d pets of the same rarity first.", MERGE_COUNT), "Bad")
		return
	end
	local result = ClientState.MetaRequest("Merge", table.clone(mergeSel))
	if not result.Ok then
		UIKit.Toast(result.Error or "Couldn't merge those.", "Bad")
		return
	end
	table.clear(mergeSel)
	UIKit.PlaySound("Hatch")
	UIKit.Confetti()
	local made = result.Pets and result.Pets[1]
	UIKit.Toast(if made then ("✨ You made a " .. petTitle(made.Id, made.Tier) .. "!") else "Merged!", "Good")
	refreshMergePanel()
end

local function doEquipToggle()
	local uid = selectedUid
	local meta = ClientState.Meta
	if not uid or not meta then
		return
	end
	local equipped = isEquipped(meta, uid)
	local result = ClientState.MetaRequest(if equipped then "Unequip" else "Equip", uid)
	if not result.Ok then
		UIKit.Toast(result.Error or "Couldn't do that.", "Bad")
	end
end

local function armDeleteConfirm()
	deleteToken += 1
	local token = deleteToken
	deleteConfirmFrame.Visible = true
	task.delay(4, function()
		if deleteToken == token then
			deleteConfirmFrame.Visible = false
		end
	end)
end

local function doDelete()
	deleteToken += 1
	deleteConfirmFrame.Visible = false
	local uid = selectedUid
	if not uid then
		return
	end
	local result = ClientState.MetaRequest("Delete", uid)
	if not result.Ok then
		UIKit.Toast(result.Error or "Couldn't delete that.", "Bad")
	else
		selectedUid = nil
	end
end

function PetsUI._refreshGrid()
	local meta = ClientState.Meta
	for _, child in gridScroll:GetChildren() do
		if child:IsA("Frame") or child:IsA("TextButton") then
			child:Destroy()
		end
	end
	if not meta then
		return
	end
	local list = sortedPetList(meta)
	for _, entry in list do
		buildPetCard(gridScroll, entry, isEquipped(meta, entry.Uid), selectPet)
	end
	local equippedCount = math.min(#meta.Equipped, meta.PetSlots)
	equippedLabel.Text = string.format("Equipped %d/%d", equippedCount, meta.PetSlots)
	countLabel.Text = string.format("%d/%d", #meta.Pets, meta.MaxPets)
	refreshDetailPanel(meta)
end

local function buildPetsWindow()
	local _window
	_window, petsContent = UIKit.Window({
		Name = "Pets",
		Title = "Pets",
		Icon = "🐾",
		Size = Vector2.new(880, 560),
		Parent = root,
	})

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 40)
	header.Parent = petsContent

	equippedLabel = UIKit.Label({
		Text = "Equipped 0/0",
		Size = UDim2.new(0.3, 0, 1, 0),
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = header,
	})
	countLabel = UIKit.Label({
		Text = "0/0",
		Size = UDim2.new(0.12, 0, 1, 0),
		Position = UDim2.new(0.3, 0, 0, 0),
		TextSize = 22,
		TextColor3 = C.TextDim,
		Parent = header,
	})
	mergeButton = UIKit.Button({
		Text = "🔮 Merge",
		Size = UDim2.fromOffset(140, 40),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -190, 0, 0),
		Color = Color3.fromRGB(170, 110, 255),
		Parent = header,
		OnClick = function()
			setMergeMode(not mergeMode)
		end,
	})
	UIKit.Button({
		Text = "Equip Best",
		Icon = "⭐",
		Size = UDim2.fromOffset(180, 40),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		Color = C.Accent,
		Parent = header,
		OnClick = function()
			local result = ClientState.MetaRequest("EquipBest")
			if not result.Ok then
				UIKit.Toast(result.Error or "Couldn't equip pets.", "Bad")
			else
				UIKit.Toast("Equipped your best pets!", "Good")
			end
		end,
	})

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.new(0, 0, 0, 48)
	body.Size = UDim2.new(1, 0, 1, -48)
	body.Parent = petsContent

	gridScroll = Instance.new("ScrollingFrame")
	gridScroll.Name = "Grid"
	gridScroll.BackgroundColor3 = C.PanelDark
	gridScroll.BackgroundTransparency = 0.35
	gridScroll.BorderSizePixel = 0
	gridScroll.Size = UDim2.new(0, 546, 1, 0)
	gridScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	gridScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	gridScroll.ScrollBarThickness = 8
	gridScroll.ScrollBarImageColor3 = C.Primary
	UIKit.Corner(gridScroll, 12)
	gridScroll.Parent = body

	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(GRID_CELL.X, GRID_CELL.Y)
	gridLayout.CellPadding = UDim2.fromOffset(GRID_GAP, GRID_GAP)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = gridScroll
	local gridPad = UIKit.Padding(gridScroll, 10)
	gridPad.Parent = gridScroll

	-- Details panel (or the merge panel, in merge mode)
	local details = UIKit.Card({
		Size = UDim2.new(0, 300, 1, 0),
		Position = UDim2.new(1, 0, 0, 0),
		AnchorPoint = Vector2.new(1, 0),
		Color = C.PanelDark,
		Parent = body,
	})

	detailsCard = details

	mergePanel = Instance.new("Frame")
	mergePanel.Name = "Merge"
	mergePanel.BackgroundTransparency = 1
	mergePanel.Size = UDim2.fromScale(1, 1)
	mergePanel.Visible = false
	mergePanel.Parent = details
	UIKit.Label({ Text = "🔮 Merge Pets", Size = UDim2.new(1, -16, 0, 34), Position = UDim2.new(0.5, 0, 0, 14), AnchorPoint = Vector2.new(0.5, 0), TextSize = 26, Parent = mergePanel })
	UIKit.Label({
		Text = string.format("%d of the same pet become 1 Golden one; %d Golden make a Rainbow. Better speed, bigger bag, more coins.", MERGE_COUNT, MERGE_COUNT),
		Size = UDim2.new(1, -24, 0, 48),
		Position = UDim2.new(0.5, 0, 0, 56),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 16,
		TextWrapped = true,
		TextColor3 = C.TextDim,
		Parent = mergePanel,
	})
	mergeInfo = UIKit.Label({ Text = "", Size = UDim2.new(1, -24, 0, 44), Position = UDim2.new(0.5, 0, 0, 116), AnchorPoint = Vector2.new(0.5, 0), TextSize = 17, TextWrapped = true, Parent = mergePanel })
	mergeResult = UIKit.Label({ Text = "➡️ ?", Size = UDim2.new(1, -24, 0, 36), Position = UDim2.new(0.5, 0, 0, 170), AnchorPoint = Vector2.new(0.5, 0), TextSize = 22, TextScaled = true, Parent = mergePanel })
	mergeGo = UIKit.Button({
		Text = "MERGE!",
		Icon = "✨",
		Size = UDim2.new(1, -24, 0, 56),
		Position = UDim2.new(0.5, 0, 0, 232),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = C.Disabled,
		Parent = mergePanel,
		OnClick = doMerge,
	})
	UIKit.Button({
		Text = "Clear picks",
		Size = UDim2.new(1, -24, 0, 40),
		Position = UDim2.new(0.5, 0, 0, 300),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = C.PanelLight,
		Parent = mergePanel,
		OnClick = function()
			table.clear(mergeSel)
			refreshMergePanel()
			PetsUI._refreshGrid()
		end,
	})

	detailEmpty = Instance.new("Frame")
	detailEmpty.Name = "Empty"
	detailEmpty.BackgroundTransparency = 1
	detailEmpty.Size = UDim2.fromScale(1, 1)
	detailEmpty.Parent = details
	UIKit.Label({
		Text = "Select a pet to see its details.",
		Size = UDim2.new(1, -20, 0, 60),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		TextSize = 18,
		TextColor3 = C.TextDim,
		TextWrapped = true,
		Parent = detailEmpty,
	})

	detailFilled = Instance.new("Frame")
	detailFilled.Name = "Filled"
	detailFilled.BackgroundTransparency = 1
	detailFilled.Size = UDim2.fromScale(1, 1)
	detailFilled.Visible = false
	detailFilled.Parent = details

	detailViewport = UIKit.Viewport({
		Size = UDim2.fromOffset(180, 140),
		Position = UDim2.new(0.5, 0, 0, 12),
		AnchorPoint = Vector2.new(0.5, 0),
		Spin = true,
		Parent = detailFilled,
	})
	detailName = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -16, 0, 28),
		Position = UDim2.new(0.5, 0, 0, 156),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 24,
		TextScaled = true,
		Parent = detailFilled,
	})
	detailRarity = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -16, 0, 20),
		Position = UDim2.new(0.5, 0, 0, 184),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 16,
		Parent = detailFilled,
	})
	detailPower = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -24, 0, 40),
		Position = UDim2.new(0.5, 0, 0, 212),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 16,
		TextWrapped = true,
		TextColor3 = C.TextDim,
		Parent = detailFilled,
	})
	detailCoin = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -24, 0, 24),
		Position = UDim2.new(0.5, 0, 0, 252),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 16,
		TextColor3 = C.Coin,
		Parent = detailFilled,
	})

	equipButton = UIKit.Button({
		Text = "Equip",
		Size = UDim2.new(1, -24, 0, 46),
		Position = UDim2.new(0.5, 0, 0, 296),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = C.Good,
		Parent = detailFilled,
		OnClick = doEquipToggle,
	})
	local _deleteButton = UIKit.Button({
		Text = "Delete",
		Size = UDim2.new(1, -24, 0, 40),
		Position = UDim2.new(0.5, 0, 0, 352),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = C.Bad,
		Parent = detailFilled,
		OnClick = armDeleteConfirm,
	})

	deleteConfirmFrame = Instance.new("Frame")
	deleteConfirmFrame.Name = "DeleteConfirm"
	deleteConfirmFrame.BackgroundTransparency = 1
	deleteConfirmFrame.Size = UDim2.new(1, -24, 0, 70)
	deleteConfirmFrame.Position = UDim2.new(0.5, 0, 0, 400)
	deleteConfirmFrame.AnchorPoint = Vector2.new(0.5, 0)
	deleteConfirmFrame.Visible = false
	deleteConfirmFrame.Parent = detailFilled
	UIKit.Label({
		Text = "Delete this pet forever?",
		Size = UDim2.new(1, 0, 0, 20),
		TextSize = 15,
		TextColor3 = C.Bad,
		Parent = deleteConfirmFrame,
	})
	UIKit.Button({
		Text = "Yes, delete",
		Size = UDim2.new(0.48, -4, 0, 38),
		Position = UDim2.new(0, 0, 0, 26),
		Color = C.Bad,
		TextSize = 16,
		Parent = deleteConfirmFrame,
		OnClick = doDelete,
	})
	UIKit.Button({
		Text = "Cancel",
		Size = UDim2.new(0.48, -4, 0, 38),
		Position = UDim2.new(0.52, 4, 0, 26),
		Color = C.Disabled,
		TextSize = 16,
		Parent = deleteConfirmFrame,
		OnClick = function()
			deleteToken += 1
			deleteConfirmFrame.Visible = false
		end,
	})

	UIKit.RegisterWindow("Pets", {
		Open = function()
			if mergeMode then
				setMergeMode(false)
			end
			PetsUI._refreshGrid()
		end,
		Close = function()
			if mergeMode then
				setMergeMode(false)
			end
		end,
	})
end

----------------------------------------------------------------------------------------------------
-- Eggs window
----------------------------------------------------------------------------------------------------

local function eggAffordable(egg, count: number, meta: Types.MetaState?): boolean
	if not meta then
		return false
	end
	local cost = egg.Cost * count
	local room = meta.MaxPets - #meta.Pets
	return meta.Bubbles >= cost and room >= count
end

local function buildOddsRow(parent: Instance, entry, layoutOrder: number)
	local row = UIKit.Card({
		Size = UDim2.new(1, 0, 0, 60),
		Color = C.PanelLight,
		LayoutOrder = layoutOrder,
		Parent = parent,
	})
	local def = petDef(entry.Pet)
	UIKit.Viewport({
		Model = PetModels.Build(entry.Pet),
		Size = UDim2.fromOffset(52, 52),
		Position = UDim2.new(0, 6, 0.5, 0),
		AnchorPoint = Vector2.new(0, 0.5),
		Parent = row,
	})
	UIKit.Label({
		Text = def.Name,
		Size = UDim2.new(1, -180, 0, 22),
		Position = UDim2.new(0, 66, 0, 8),
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	UIKit.Label({
		Text = def.Rarity .. "   " .. shortStats(petStats(entry.Pet)),
		Size = UDim2.new(1, -170, 0, 18),
		Position = UDim2.new(0, 66, 0, 32),
		TextSize = 14,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = UIKit.RarityColor(def.Rarity),
		Parent = row,
	})
	UIKit.Label({
		Text = Format.Chance(entry.Chance),
		Size = UDim2.new(0, 90, 1, 0),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -8, 0, 0),
		TextSize = 20,
		TextColor3 = C.Text,
		Parent = row,
	})
end

local function selectEgg(eggId: string)
	local egg = Config.GetEgg(eggId)
	if not egg then
		return
	end
	currentEggId = eggId

	for _, child in eggTabsHolder:GetChildren() do
		if child:IsA("TextButton") then
			local active = child:GetAttribute("EggId") == eggId
			child.BackgroundColor3 = if active then C.Primary else C.PanelLight
		end
	end

	UIKit.SetViewportModel(eggViewport, PetModels.Egg(eggId), true)
	eggNameLabel.Text = egg.Name
	eggCostLabel.Text = "🧼 " .. Format.Commas(egg.Cost)

	for _, child in oddsScroll:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	local order = 0
	for _, entry in egg.Pets do
		order += 1
		buildOddsRow(oddsScroll, entry, order)
	end

	PetsUI._refreshEggButtons()
end

function PetsUI._refreshEggButtons()
	local eggId = currentEggId
	if not eggId then
		return
	end
	local egg = Config.GetEgg(eggId)
	local meta = ClientState.Meta
	local unlocked = meta and meta.Unlocked or 0
	local locked = unlocked < egg.RequiredLevel

	eggLockedLabel.Visible = locked
	if locked then
		local level = Config.Levels[egg.RequiredLevel]
		local where = if level then (level.Icon or "") .. " " .. level.Name else ("Level " .. egg.RequiredLevel)
		eggLockedLabel.Text = "🔒 Unlock " .. where .. " to hatch this egg!"
	end

	hatch1Button:SetAttribute("Disabled", locked or not eggAffordable(egg, 1, meta))
	hatch3Button:SetAttribute("Disabled", locked or not eggAffordable(egg, 3, meta))
	hatch1Button.Text = "Hatch 1 (🧼 " .. Format.Commas(egg.Cost) .. ")"
	hatch3Button.Text = "Hatch 3 (🧼 " .. Format.Commas(egg.Cost * 3) .. ")"
end

local function doHatch(count: number)
	local eggId = currentEggId
	if not eggId then
		return
	end
	local result = ClientState.MetaRequest("Hatch", { Egg = eggId, Count = count })
	if not result.Ok then
		UIKit.Toast(result.Error or "Couldn't hatch that egg.", "Bad")
		return
	end
	PetsUI.PlayHatchAnimation(eggId, result.Pets or {})
end

local function buildEggsWindow()
	local _window
	_window, eggsContent = UIKit.Window({
		Name = "Eggs",
		Title = "Egg Hatchery",
		Icon = "🥚",
		Size = Vector2.new(860, 560),
		Parent = root,
	})

	eggTabsHolder = Instance.new("Frame")
	eggTabsHolder.Name = "Tabs"
	eggTabsHolder.BackgroundTransparency = 1
	eggTabsHolder.Size = UDim2.new(1, 0, 0, 40)
	eggTabsHolder.Parent = eggsContent
	local tabsLayout = Instance.new("UIListLayout")
	tabsLayout.FillDirection = Enum.FillDirection.Horizontal
	tabsLayout.Padding = UDim.new(0, 8)
	tabsLayout.Parent = eggTabsHolder

	for _, egg in Config.Eggs do
		local tab = UIKit.Button({
			Text = egg.Name,
			Size = UDim2.fromOffset(160, 40),
			TextSize = 16,
			Color = C.PanelLight,
			Parent = eggTabsHolder,
			OnClick = function()
				selectEgg(egg.Id)
			end,
		})
		tab:SetAttribute("EggId", egg.Id)
	end

	local body = Instance.new("Frame")
	body.Name = "Body"
	body.BackgroundTransparency = 1
	body.Position = UDim2.new(0, 0, 0, 48)
	body.Size = UDim2.new(1, 0, 1, -48)
	body.Parent = eggsContent

	local left = UIKit.Card({
		Size = UDim2.new(0, 260, 1, 0),
		Color = C.PanelDark,
		Parent = body,
	})
	eggViewport = UIKit.Viewport({
		Size = UDim2.fromOffset(190, 160),
		Position = UDim2.new(0.5, 0, 0, 14),
		AnchorPoint = Vector2.new(0.5, 0),
		Spin = true,
		Parent = left,
	})
	eggNameLabel = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -16, 0, 30),
		Position = UDim2.new(0.5, 0, 0, 182),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 24,
		TextScaled = true,
		Parent = left,
	})
	eggCostLabel = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -16, 0, 24),
		Position = UDim2.new(0.5, 0, 0, 214),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 20,
		TextColor3 = C.Bubble,
		Parent = left,
	})
	eggLockedLabel = UIKit.Label({
		Text = "",
		Size = UDim2.new(1, -20, 0, 60),
		Position = UDim2.new(0.5, 0, 0, 250),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 14,
		TextColor3 = C.Bad,
		TextWrapped = true,
		Visible = false,
		Parent = left,
	})

	hatch1Button = UIKit.Button({
		Text = "Hatch 1",
		Size = UDim2.new(1, -20, 0, 46),
		Position = UDim2.new(0.5, 0, 1, -110),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = C.Good,
		TextSize = 16,
		Parent = left,
		OnClick = function()
			doHatch(1)
		end,
	})
	hatch3Button = UIKit.Button({
		Text = "Hatch 3",
		Size = UDim2.new(1, -20, 0, 46),
		Position = UDim2.new(0.5, 0, 1, -56),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = C.Accent,
		TextSize = 16,
		Parent = left,
		OnClick = function()
			doHatch(3)
		end,
	})

	local right = Instance.new("Frame")
	right.Name = "Odds"
	right.BackgroundTransparency = 1
	right.Position = UDim2.new(0, 274, 0, 0)
	right.Size = UDim2.new(1, -274, 1, 0)
	right.Parent = body

	UIKit.Label({
		Text = "Odds",
		Size = UDim2.new(1, 0, 0, 26),
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = right,
	})

	oddsScroll = Instance.new("ScrollingFrame")
	oddsScroll.Name = "OddsList"
	oddsScroll.BackgroundTransparency = 1
	oddsScroll.BorderSizePixel = 0
	oddsScroll.Position = UDim2.new(0, 0, 0, 30)
	oddsScroll.Size = UDim2.new(1, 0, 1, -30)
	oddsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	oddsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	oddsScroll.ScrollBarThickness = 8
	oddsScroll.ScrollBarImageColor3 = C.Primary
	oddsScroll.Parent = right
	local oddsLayout = Instance.new("UIListLayout")
	oddsLayout.Padding = UDim.new(0, 8)
	oddsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	oddsLayout.Parent = oddsScroll

	UIKit.RegisterWindow("Eggs", {
		Open = function(arg: any?)
			local eggId = if type(arg) == "string" and Config.GetEgg(arg) then arg else Config.Eggs[1].Id
			selectEgg(eggId)
		end,
		Close = function() end,
	})
end

----------------------------------------------------------------------------------------------------
-- Hatch reveal animation (its own high-DisplayOrder ScreenGui, per DESIGN.md)
----------------------------------------------------------------------------------------------------

local hatchGui: ScreenGui
local hatchRoot: Frame
local hatchDarken: Frame
local hatchEggHolder: Frame
local hatchEggViewport: ViewportFrame
local hatchFlash: Frame
local hatchCardsHolder: Frame
local hatchClickCatcher: TextButton
local hatchToken = 0
-- "wobble" while the egg is shaking, "revealed" once the cards are up (click closes instead of skips).
local hatchPhase: string? = nil

local function bestRarity(pets: { Types.PetEntry })
	local best = "Common"
	local bestOrder = 0
	for _, pet in pets do
		local def = petDef(pet.Id)
		local order = rarityOrder(def.Rarity)
		if order > bestOrder then
			bestOrder = order
			best = def.Rarity
		end
	end
	return best
end

local function buildHatchCard(parent: Instance, pet: Types.PetEntry, index: number, total: number)
	local def = petDef(pet.Id)
	local color = UIKit.RarityColor(def.Rarity)
	local isEpicPlus = rarityOrder(def.Rarity) >= rarityOrder("Epic")

	local width = if total > 1 then 220 else 280
	local card = Instance.new("Frame")
	card.Name = "Card" .. index
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Size = UDim2.fromOffset(width, 320)
	card.BackgroundTransparency = 1
	card.LayoutOrder = index
	card.Parent = parent

	if isEpicPlus then
		local glow = Instance.new("ImageLabel")
		glow.Name = "Glow"
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.Position = UDim2.fromScale(0.5, 0.5)
		glow.Size = UDim2.fromOffset(width + 120, 440)
		glow.BackgroundTransparency = 1
		glow.Image = "rbxasset://textures/particles/forcefield_glow_main.dds"
		glow.ImageColor3 = color
		glow.ImageTransparency = 0.35
		glow.ZIndex = 1
		glow.Parent = card
		local pulse = UIKit.Tween(glow, { ImageTransparency = 0.6 }, 0.9)
		pulse.Completed:Connect(function()
			if glow.Parent then
				UIKit.Tween(glow, { ImageTransparency = 0.35 }, 0.9)
			end
		end)
	end

	local panel = UIKit.Card({
		Size = UDim2.new(1, 0, 1, 0),
		Color = C.PanelDark,
		StrokeColor = color,
		Parent = card,
	})
	panel.ZIndex = 2
	local panelStroke = panel:FindFirstChildOfClass("UIStroke")
	if panelStroke then
		panelStroke.Thickness = 4
	end

	UIKit.Viewport({
		Model = PetModels.Build(pet.Id),
		Size = UDim2.fromOffset(width - 40, 200),
		Position = UDim2.new(0.5, 0, 0, 16),
		AnchorPoint = Vector2.new(0.5, 0),
		Spin = true,
		Parent = panel,
		ZIndex = 3,
	})
	UIKit.Label({
		Text = def.Name,
		Size = UDim2.new(1, -16, 0, 32),
		Position = UDim2.new(0.5, 0, 0, 226),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 26,
		TextScaled = true,
		Parent = panel,
		ZIndex = 3,
	})
	UIKit.Label({
		Text = def.Rarity,
		Size = UDim2.new(1, -16, 0, 26),
		Position = UDim2.new(0.5, 0, 0, 262),
		AnchorPoint = Vector2.new(0.5, 0),
		TextSize = 20,
		TextColor3 = color,
		Parent = panel,
		ZIndex = 3,
	})

	-- Pop in, staggered per card.
	card.Position = UDim2.fromScale(0.5, 0.6)
	local scaler = Instance.new("UIScale")
	scaler.Scale = 0.2
	scaler.Parent = card
	task.delay((index - 1) * 0.12, function()
		if not card.Parent then
			return
		end
		UIKit.Tween(scaler, { Scale = 1 }, 0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	end)
	return card
end

local function layoutHatchCards(count: number)
	local layout = hatchCardsHolder:FindFirstChildOfClass("UIListLayout")
	if not layout then
		layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.Padding = UDim.new(0, if count > 1 then 20 else 0)
		layout.Parent = hatchCardsHolder
	else
		layout.Padding = UDim.new(0, if count > 1 then 20 else 0)
	end
end

local function ensureHatchGui()
	if hatchGui then
		return
	end
	hatchGui, hatchRoot = UIKit.CreateScreen("PetsHatch", 60)

	hatchDarken = Instance.new("Frame")
	hatchDarken.Name = "Darken"
	hatchDarken.Size = UDim2.fromScale(1, 1)
	hatchDarken.BackgroundColor3 = Color3.new(0, 0, 0)
	hatchDarken.BackgroundTransparency = 1
	hatchDarken.Visible = false
	hatchDarken.ZIndex = 1
	hatchDarken.Parent = hatchRoot

	hatchEggHolder = Instance.new("Frame")
	hatchEggHolder.Name = "EggHolder"
	hatchEggHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	hatchEggHolder.Position = UDim2.fromScale(0.5, 0.5)
	hatchEggHolder.Size = UDim2.fromOffset(260, 260)
	hatchEggHolder.BackgroundTransparency = 1
	hatchEggHolder.Visible = false
	hatchEggHolder.ZIndex = 2
	hatchEggHolder.Parent = hatchRoot
	hatchEggViewport = UIKit.Viewport({
		Size = UDim2.fromScale(1, 1),
		Parent = hatchEggHolder,
		ZIndex = 2,
	})

	hatchCardsHolder = Instance.new("Frame")
	hatchCardsHolder.Name = "Cards"
	hatchCardsHolder.AnchorPoint = Vector2.new(0.5, 0.5)
	hatchCardsHolder.Position = UDim2.fromScale(0.5, 0.5)
	hatchCardsHolder.Size = UDim2.new(1, -40, 0, 360)
	hatchCardsHolder.BackgroundTransparency = 1
	hatchCardsHolder.Visible = false
	hatchCardsHolder.ZIndex = 2
	hatchCardsHolder.Parent = hatchRoot

	hatchFlash = Instance.new("Frame")
	hatchFlash.Name = "Flash"
	hatchFlash.Size = UDim2.fromScale(1, 1)
	hatchFlash.BackgroundColor3 = Color3.new(1, 1, 1)
	hatchFlash.BackgroundTransparency = 1
	hatchFlash.ZIndex = 3
	hatchFlash.Parent = hatchRoot

	hatchClickCatcher = Instance.new("TextButton")
	hatchClickCatcher.Name = "ClickCatcher"
	hatchClickCatcher.Size = UDim2.fromScale(1, 1)
	hatchClickCatcher.BackgroundTransparency = 1
	hatchClickCatcher.Text = ""
	hatchClickCatcher.AutoButtonColor = false
	hatchClickCatcher.ZIndex = 4
	hatchClickCatcher.Visible = false
	hatchClickCatcher.Parent = hatchRoot
	hatchClickCatcher.Activated:Connect(function()
		if hatchPhase == "wobble" then
			hatchToken += 1 -- cancel the wobble/flash coroutine; it jumps straight to the reveal
			PetsUI._revealNow()
		elseif hatchPhase == "revealed" then
			PetsUI._closeHatch()
		end
	end)
end

function PetsUI._closeHatch()
	hatchToken += 1
	hatchPhase = nil
	hatchRoot.Visible = false
	hatchDarken.Visible = false
	hatchEggHolder.Visible = false
	hatchCardsHolder.Visible = false
	hatchClickCatcher.Visible = false
	for _, child in hatchCardsHolder:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
end

local pendingReveal: { Types.PetEntry }? = nil -- captured so a skip click can jump straight to the reveal

function PetsUI._revealNow()
	if not pendingReveal then
		return
	end
	local pets = pendingReveal
	pendingReveal = nil
	hatchPhase = "revealed"
	hatchEggHolder.Visible = false
	hatchFlash.BackgroundTransparency = 1
	hatchDarken.BackgroundTransparency = 0.55

	for _, child in hatchCardsHolder:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	layoutHatchCards(#pets)
	hatchCardsHolder.Visible = true
	local order = 0
	for _, pet in pets do
		order += 1
		buildHatchCard(hatchCardsHolder, pet, order, #pets)
	end
end

-- Plays the wobble -> flash -> reveal sequence for a completed hatch. `pets` is the RequestResult's
-- Pets list (already added to the profile server-side).
function PetsUI.PlayHatchAnimation(eggId: string, pets: { Types.PetEntry })
	ensureHatchGui()
	if #pets == 0 then
		return
	end
	hatchToken += 1
	local token = hatchToken
	pendingReveal = pets
	hatchPhase = "wobble"

	hatchRoot.Visible = true
	hatchClickCatcher.Visible = true
	hatchDarken.Visible = true
	hatchDarken.BackgroundTransparency = 1
	UIKit.Tween(hatchDarken, { BackgroundTransparency = 0.55 }, 0.2)

	hatchEggHolder.Visible = true
	hatchEggHolder.Rotation = 0
	UIKit.SetViewportModel(hatchEggViewport, PetModels.Egg(eggId), true)
	hatchCardsHolder.Visible = false

	UIKit.PlaySound("Hatch")

	task.spawn(function()
		-- Three wobbles of rising intensity.
		for wobble = 1, 3 do
			if hatchToken ~= token then
				return
			end
			local angle = 6 * wobble
			local time = 0.16
			hatchEggHolder.Rotation = 0
			local a = UIKit.Tween(hatchEggHolder, { Rotation = angle }, time)
			a.Completed:Wait()
			if hatchToken ~= token then
				return
			end
			local b = UIKit.Tween(hatchEggHolder, { Rotation = -angle }, time * 2, Enum.EasingStyle.Sine)
			b.Completed:Wait()
			if hatchToken ~= token then
				return
			end
			local c = UIKit.Tween(hatchEggHolder, { Rotation = 0 }, time)
			c.Completed:Wait()
			if hatchToken ~= token then
				return
			end
			task.wait(0.08)
		end
		if hatchToken ~= token then
			return
		end

		-- Flash tinted by the best rarity hatched.
		local color = UIKit.RarityColor(bestRarity(pets))
		hatchFlash.BackgroundColor3 = color
		hatchFlash.BackgroundTransparency = 1
		local up = UIKit.Tween(hatchFlash, { BackgroundTransparency = 0.05 }, 0.12)
		up.Completed:Wait()
		if hatchToken ~= token then
			return
		end
		task.wait(0.05)
		UIKit.Tween(hatchFlash, { BackgroundTransparency = 1 }, 0.35)

		if hatchToken ~= token then
			return
		end
		PetsUI._revealNow()
	end)
end

----------------------------------------------------------------------------------------------------
-- Init
----------------------------------------------------------------------------------------------------

function PetsUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui
	_gui, root = UIKit.CreateScreen("PetsUI", 10)

	buildPetsWindow()
	buildEggsWindow()
	ensureHatchGui()

	ClientState.Changed:Connect(function(kind: string)
		if kind ~= "Meta" then
			return
		end
		if UIKit.IsWindowOpen("Pets") then
			PetsUI._refreshGrid()
		end
		if UIKit.IsWindowOpen("Eggs") then
			PetsUI._refreshEggButtons()
		end
	end)
end

return PetsUI
