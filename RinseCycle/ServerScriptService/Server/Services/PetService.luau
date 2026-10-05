-- PetService: pet inventory (Hatch / Equip / Unequip / EquipBest / Delete), the EquippedPets
-- folders clients render from, and the pet auto-clean loop inside runs.
--
--   * Every inventory op validates everything first, then writes the profile with no yield in
--     between, then pushes MetaState, rebuilds EquippedPets and refreshes run stats. Ops never
--     throw: any error comes back as { Ok = false, Error = ... }. A per-player lock stops two
--     requests from interleaving if a DataService call ever yields.
--   * Hatch rolls the pets BEFORE taking the Bubbles, so nothing after the payment can fail halfway.
--   * Only the first GetPetSlots(player) valid uids of profile.Equipped are "active" (rendered and
--     cleaning). Equipped is never trimmed on load: game passes are checked asynchronously after
--     the profile loads, so trimming would cost a +2 slot owner their pets on every join. A slow
--     watcher rebuilds whenever the slot count changes (perk bought, pass granted).
--   * Auto-clean (every PetRules.ThinkInterval): each active slot holds one grime target. The pet
--     "flies" for distance / Speed seconds (clients animate it from the Target ObjectValue), then
--     deals GetRunPower(owner) * PowerShare per second through RoundService.DamageGrime(..., true).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Format = require(Shared:WaitForChild("Format"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

local DataService = require(script.Parent:WaitForChild("DataService"))
local RoundService = require(script.Parent:WaitForChild("RoundService"))

local PetService = {}

----------------------------------------------------------------------------------------------------
-- Tuning (gameplay numbers live in Config.PetRules)
----------------------------------------------------------------------------------------------------

local RULES = Config.PetRules
local FOLDER_NAME = "EquippedPets"
local PAY_INTERVAL = 1 -- seconds: a pet's cleaning is paid out this often
local MAX_HIT_DT = RULES.ThinkInterval * 2 -- a server hitch can't turn into one giant pet hit
local QUERY_MAX_PARTS = 250 -- grime parts considered per owner per think
local SLOT_WATCH_INTERVAL = 1 -- seconds between slot-count checks (perks / passes / late profiles)
local MAX_SLOTS = 20 -- sanity clamp on whatever GetPetSlots returns
local MAX_UID_LENGTH = 16
-- Legendary hatches are announced after the hatcher's reveal animation (egg wobbles, flash,
-- card), so their own toast doesn't spoil it.
local ANNOUNCE_DELAY = 3
local LOADING = "Your data is still loading. Try again in a moment!"

----------------------------------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------------------------------

-- Profile fields this service reads and writes (DESIGN.md section 5, DataService).
type Profile = {
	Bubbles: number,
	Perks: { [string]: number },
	Pets: { Types.PetEntry },
	Equipped: { string },
	NextUid: number,
	Unlocked: number,
}

type ActiveEntry = { Uid: string, Id: string, Tier: number, Share: number, Capacity: number }

-- One active pet slot: the replicated StringValue/ObjectValue pair plus server-only cleaning state.
type Slot = {
	Uid: string,
	PetId: string,
	Share: number, -- Config.PetStats Speed (share of the owner's pet power per second)
	Tier: number,
	Capacity: number, -- bag size in dirt units, before the level multiplier
	Bag: number, -- units cleaned and not yet paid out (paid every PAY_INTERVAL)
	LastPay: number?, -- os.clock() of the last payout
	Value: StringValue, -- EquippedPets["<index>"], Value = pet id; attributes Uid, Tier, Bag (0..1)
	TargetValue: ObjectValue, -- its "Target" child
	Target: BasePart?, -- the grime part this pet is cleaning (mirrors TargetValue.Value)
	ArriveAt: number, -- os.clock() when the pet reaches Target
	LastHit: number, -- os.clock() of the last damage tick (the next tick's dt starts here)
	From: Vector3?, -- where the pet just finished a spot (travel starts there); nil = at the owner
}

type OwnerState = {
	Slots: { Slot },
	Cap: number, -- slot count the folder was last built with (-1 = never built)
	Loaded: boolean, -- the profile has been seen and sanitized
	Ignore: { [BasePart]: boolean }, -- weak-keyed: parts DamageGrime refused (not grime of this run)
}

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

local owners: { [Player]: OwnerState } = {}
local busy: { [Player]: boolean } = {}
-- Players who have left. Weak keys, so this can't leak; it stops a late rebuild from recreating
-- state for someone who is already gone.
local gone: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local rng = Random.new()
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Include
overlap.MaxParts = QUERY_MAX_PARTS

local NotifyRemote: RemoteEvent

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

-- pcall wrapper for calls into other services (DataService / RoundService may be mid-rewrite or
-- fail); errors are logged and swallowed so an inventory op never half-applies because of them.
local function safe(fn: any, ...: any): (boolean, any)
	if type(fn) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		warn("[PetService] " .. tostring(result))
		return false, nil
	end
	return true, result
end

local function fail(message: string): Types.RequestResult
	return { Ok = false, Error = message }
end

local function isHere(player: Player): boolean
	return player.Parent == Players and not gone[player]
end

local function getProfile(player: Player): Profile?
	local ok, profile = safe(DataService.Get, player)
	if ok and type(profile) == "table" then
		return profile :: Profile
	end
	return nil
end

-- Equip slots right now, from DataService (perks + passes). Falls back to perks only.
local function slotCap(player: Player, profile: Profile?): number
	local ok, n = safe(DataService.GetPetSlots, player)
	if not ok or type(n) ~= "number" or n ~= n then
		n = Config.PetSlots(profile and profile.Perks, nil)
	end
	return math.clamp(math.floor(n), 0, MAX_SLOTS)
end

local function inRun(player: Player): boolean
	local ok, result = safe(RoundService.IsInRun, player)
	return ok and result == true
end

-- Living character root, without depending on Characters (not in PetService's dependency list).
local function getRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- Client uids arrive as strings; tolerate an integer number, reject anything else.
local function normalizeUid(value: any): string?
	if type(value) == "number" and value == value and value % 1 == 0 and value > 0 and value < 1e12 then
		return string.format("%d", value)
	end
	if type(value) == "string" and #value > 0 and #value <= MAX_UID_LENGTH then
		return value
	end
	return nil
end

-- Numeric uids compare as numbers (so "10" sorts after "9"); anything else as strings.
local function uidLess(a: string, b: string): boolean
	local na, nb = tonumber(a), tonumber(b)
	if na and nb and na ~= nb then
		return na < nb
	end
	return a < b
end

local function findPet(profile: Profile, uid: string): (Types.PetEntry?, number?)
	for i, pet in profile.Pets do
		if pet.Uid == uid then
			return pet, i
		end
	end
	return nil, nil
end

----------------------------------------------------------------------------------------------------
-- Profile hygiene
----------------------------------------------------------------------------------------------------

--[[
	Makes the pet fields safe to work with. Cheap (at most MaxInventory pets), so every op runs it:
	  * Pets: drops malformed entries and duplicate uids. Pets whose id left Config are KEPT (they may
	    come back); they just can't be equipped.
	  * Equipped: drops duplicates, unknown uids and pets without a Config entry. It is NOT trimmed
	    to the slot count (see the header).
	  * NextUid: a positive integer greater than every numeric uid, so a new uid can never collide.
]]
local function sanitize(profile: Profile)
	local p = profile :: any
	if type(p.Pets) ~= "table" then
		p.Pets = {}
	end
	if type(p.Equipped) ~= "table" then
		p.Equipped = {}
	end

	local pets = {}
	local byUid: { [string]: Types.PetEntry } = {}
	local maxUid = 0
	for _, pet in p.Pets do
		if type(pet) == "table" and type(pet.Uid) == "string" and type(pet.Id) == "string" and not byUid[pet.Uid] then
			-- Tier: nil (normal), 2 (Golden) or 3 (Rainbow); anything else is dropped.
			if pet.Tier ~= nil and not (pet.Tier == 2 or pet.Tier == 3) then
				pet.Tier = nil
			end
			byUid[pet.Uid] = pet
			table.insert(pets, pet)
			local n = tonumber(pet.Uid)
			if n and n > maxUid then
				maxUid = n
			end
		end
	end
	if #pets ~= #p.Pets then
		p.Pets = pets
	end

	local equipped = {}
	local seen: { [string]: boolean } = {}
	for _, uid in p.Equipped do
		local pet = type(uid) == "string" and byUid[uid] or nil
		if pet and not seen[uid] and Config.Pets[pet.Id] then
			seen[uid] = true
			table.insert(equipped, uid)
		end
	end
	if #equipped ~= #p.Equipped then
		p.Equipped = equipped
	end

	local raw = tonumber(p.NextUid)
	local nextUid: number = 1
	if raw and raw == raw and raw >= 1 and raw < math.huge then
		nextUid = math.floor(raw)
	end
	if nextUid <= maxUid then
		nextUid = math.floor(maxUid) + 1
	end
	p.NextUid = nextUid
end

-- The pets that are actually out: the first `cap` equipped uids that still resolve to a Config pet.
local function activeEntries(profile: Profile, cap: number): { ActiveEntry }
	local byUid: { [string]: Types.PetEntry } = {}
	for _, pet in profile.Pets do
		byUid[pet.Uid] = pet
	end
	local out: { ActiveEntry } = {}
	for _, uid in profile.Equipped do
		if #out >= cap then
			break
		end
		local pet = byUid[uid]
		local stats = pet and Config.PetStats(pet.Id, pet.Tier)
		if pet and stats then
			table.insert(out, { Uid = uid, Id = pet.Id, Tier = pet.Tier or 1, Share = stats.Speed, Capacity = stats.Capacity })
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- EquippedPets folder (DESIGN.md section 4): StringValue "1".."n" (Value = pet id), each with an
-- ObjectValue "Target" (Value = grime part or nil). Clients render from this and nothing else.
----------------------------------------------------------------------------------------------------

local function ensureState(player: Player): OwnerState?
	if not isHere(player) then
		return nil
	end
	local state = owners[player]
	if not state then
		state = {
			Slots = {},
			Cap = -1,
			Loaded = false,
			Ignore = setmetatable({}, { __mode = "k" }) :: any,
		}
		owners[player] = state
	end
	return state
end

local function getFolder(player: Player): Folder?
	if not isHere(player) then
		return nil
	end
	local existing = player:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = player
	return folder
end

local function setTarget(slot: Slot, part: BasePart?)
	slot.Target = part
	if slot.TargetValue.Value ~= part then
		slot.TargetValue.Value = part
	end
end

local function destroySlot(slot: Slot)
	slot.Target = nil
	slot.Value:Destroy()
end

local function newSlot(folder: Folder, index: number, entry: ActiveEntry): Slot
	local value = Instance.new("StringValue")
	value.Name = tostring(index)
	value.Value = entry.Id
	value:SetAttribute("Uid", entry.Uid)
	value:SetAttribute("Tier", entry.Tier)

	local target = Instance.new("ObjectValue")
	target.Name = "Target"
	target.Parent = value

	value.Parent = folder
	return {
		Uid = entry.Uid,
		PetId = entry.Id,
		Share = entry.Share,
		Tier = entry.Tier,
		Capacity = entry.Capacity,
		Bag = 0,
		LastPay = nil,
		Value = value,
		TargetValue = target,
		Target = nil,
		ArriveAt = 0,
		LastHit = 0,
		From = nil,
	}
end

--[[
	Brings the folder in line with the profile. A slot whose pet id is unchanged keeps its
	StringValue (and its target), so the client model doesn't flicker. A slot whose pet changed is
	destroyed and recreated, so a renderer that only listens to ChildAdded/ChildRemoved stays correct.
]]
local function rebuild(player: Player)
	local state = ensureState(player)
	local folder = getFolder(player)
	if not state or not folder then
		return
	end
	local profile = getProfile(player)
	local cap = slotCap(player, profile)
	local active: { ActiveEntry } = {}
	if profile then
		sanitize(profile)
		state.Loaded = true
		active = activeEntries(profile, cap)
	end
	state.Cap = cap

	for i, entry in active do
		local slot = state.Slots[i]
		if slot and slot.PetId == entry.Id and slot.Tier == entry.Tier and slot.Value.Parent == folder then
			slot.Uid = entry.Uid
			slot.Share = entry.Share
			slot.Capacity = entry.Capacity
			if slot.Value:GetAttribute("Uid") ~= entry.Uid then
				slot.Value:SetAttribute("Uid", entry.Uid)
			end
		else
			if slot then
				destroySlot(slot)
			end
			state.Slots[i] = newSlot(folder, i, entry)
		end
	end
	for i = #state.Slots, #active + 1, -1 do
		destroySlot(state.Slots[i])
		state.Slots[i] = nil
	end

	-- Anything else in the folder (left over from an old slot layout) goes.
	local keep: { [Instance]: boolean } = {}
	for _, slot in state.Slots do
		keep[slot.Value] = true
	end
	for _, child in folder:GetChildren() do
		if not keep[child] then
			child:Destroy()
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Auto-clean loop (DESIGN.md section 5, "PetService"). Every ThinkInterval, for players in a run:
--   * a slot keeps its target while it's still alive and within Range of the owner
--   * otherwise it claims the nearest unclaimed grime part within Range (parts already targeted by
--     another slot of the same owner this tick don't count)
--   * a freshly-claimed target gets an arrival delay (distance / Speed); only after arriving does it
--     start dealing GetRunPower(owner) * PowerShare per second, applied via RoundService.DamageGrime
--   * a full tank clears every target (pets drift back to the owner formation on the client)
--   * outside a run every Target is nil
----------------------------------------------------------------------------------------------------


local function runPower(player: Player): number
	local ok, power = safe(RoundService.GetRunPower, player)
	if ok and type(power) == "number" and power == power and power >= 0 then
		return power
	end
	return 0
end

-- (alive, units): alive while the part still stands; units the pet picked up if it finished it.
local function damageGrime(owner: Player, part: BasePart, amount: number): (boolean, number)
	local ok, alive, units = pcall(RoundService.DamageGrime, owner, part, amount, true)
	if not ok then
		warn("[PetService] " .. tostring(alive))
		return false, 0
	end
	return alive == true, tonumber(units) or 0
end

local function grimeFolderOf(player: Player): Folder?
	local ok, folder = safe(RoundService.GetGrimeFolder, player)
	if ok and typeof(folder) == "Instance" and folder:IsA("Folder") then
		return folder
	end
	return nil
end

-- Drops every slot's target (used when the owner leaves the run or their tank fills up).
local function clearTargets(state: OwnerState)
	for _, slot in state.Slots do
		if slot.Target then
			setTarget(slot, nil)
		end
		slot.From = nil
	end
end

-- Nearest grime part in `grimeFolder` within Range of `root` that isn't in `claimed` or `ignored`.
local function pickTarget(root: BasePart, grimeFolder: Folder, claimed: { [BasePart]: boolean }, ignored: { [BasePart]: boolean }): BasePart?
	overlap.FilterDescendantsInstances = { grimeFolder }
	local ok, parts = pcall(workspace.GetPartBoundsInRadius, workspace, root.Position, RULES.Range, overlap)
	if not ok or type(parts) ~= "table" then
		return nil
	end
	local best: BasePart? = nil
	local bestDist = math.huge
	for _, part in parts do
		if part:IsA("BasePart") and not claimed[part] and not ignored[part] then
			local dist = (part.Position - root.Position).Magnitude
			if dist <= RULES.Range and dist < bestDist then
				best = part
				bestDist = dist
			end
		end
	end
	return best
end

-- One think tick for a single owner. `now` is os.clock(), shared by every owner this tick.
local function think(player: Player, state: OwnerState, now: number)
	if #state.Slots == 0 then
		return
	end
	if not inRun(player) then
		clearTargets(state)
		return
	end
	local root = getRoot(player)
	local grimeFolder = grimeFolderOf(player)
	-- An admin who is hidden (invisible, spectating, controlling someone) has their pets put away.
	local character = player.Character
	local hidden = character ~= nil and character:GetAttribute("AdminHidden") == true
	-- Switched off by the player (the Pets On / Off button): they just follow, no cleaning.
	local resting = player:GetAttribute("PetsResting") == true
	if not root or not grimeFolder or hidden or resting then
		clearTargets(state)
		return
	end

	-- Parts already spoken for this tick, so two slots of the same owner never chase the same spot.
	local claimed: { [BasePart]: boolean } = {}
	for _, slot in state.Slots do
		if slot.Target then
			claimed[slot.Target] = true
		end
	end

	local power = runPower(player)

	for slotIndex, slot in state.Slots do
		-- No bag any more: what a pet cleans is paid straight to the owner's coins, gathered up
		-- and paid about once a second (PAY_INTERVAL) so the coin pop-ups don't spam.
		if slot.Bag > 0 and now - (slot.LastPay or 0) >= PAY_INTERVAL then
			local units = slot.Bag
			slot.Bag = 0
			slot.LastPay = now
			safe(RoundService.PayPetCoins, player, units, slotIndex) -- "+coins" floats over that pet
		end

		local target = slot.Target
		if target then
			local alive = target.Parent == grimeFolder
			if alive and (target.Position - root.Position).Magnitude > RULES.Range then
				alive = false
			end
			if not alive then
				claimed[target] = nil
				slot.From = target.Position
				setTarget(slot, nil)
				target = nil
			end
		end

		if not target then
			local pick = pickTarget(root, grimeFolder, claimed, state.Ignore)
			if pick then
				claimed[pick] = true
				local from = slot.From or root.Position
				local travel = (pick.Position - from).Magnitude / RULES.Speed
				slot.ArriveAt = now + travel
				slot.LastHit = now + travel -- damage starts counting from the moment it arrives
				slot.From = nil
				setTarget(slot, pick)
				target = pick
			end
		end

		if target and now >= slot.ArriveAt then
			local sinceLast = math.min(now - slot.LastHit, MAX_HIT_DT)
			if sinceLast > 0 then
				slot.LastHit = now
				local amount = power * slot.Share * sinceLast
				if amount > 0 then
					local alive, units = damageGrime(player, target, amount)
					if units > 0 then
						slot.Bag += units
					end
					if not alive then
						if target.Parent then
							-- Refused for a reason other than dying (e.g. it stopped belonging to this
							-- run mid-tick). Remember it so this slot doesn't just re-target it.
							state.Ignore[target] = true
						end
						slot.From = target.Position
						setTarget(slot, nil)
					end
				end
			end
		end
	end
end

local function autoCleanTick()
	local now = os.clock()
	for player, state in owners do
		if isHere(player) then
			local ok, err = pcall(think, player, state, now)
			if not ok then
				warn("[PetService] auto-clean tick failed for " .. player.Name .. ": " .. tostring(err))
			end
		end
	end
end

-- Catches slot-count changes that don't go through PetService itself: a Pet Slot perk purchase
-- (ShopService writes profile.Perks directly) or a +2 Pet Slots pass grant that raced ahead of
-- PassesChanged (SetPass already fires it, but this is a cheap, harmless backstop).
local function slotWatchTick()
	for player, state in owners do
		if isHere(player) and state.Loaded then
			local profile = getProfile(player)
			local cap = slotCap(player, profile)
			if cap ~= state.Cap then
				local ok, err = pcall(rebuild, player)
				if not ok then
					warn("[PetService] slot watcher rebuild failed for " .. player.Name .. ": " .. tostring(err))
				end
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Inventory operations
----------------------------------------------------------------------------------------------------

-- Everything that follows a successful change. equipChanged = the active pets may differ, which
-- changes the coin bonus RoundService folds into run stats.
local function afterChange(player: Player, equipChanged: boolean)
	safe(DataService.PushMeta, player)
	rebuild(player)
	if equipChanged and inRun(player) then
		safe(RoundService.RefreshStats, player)
	end
end

-- Runs one op under the player's lock and turns any error into a RequestResult.
local function guarded(player: any, op: (Player, any, any) -> Types.RequestResult, a: any, b: any): Types.RequestResult
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return fail("Unknown player.")
	end
	if busy[player] then
		return fail("Hold on, still working on your last request!")
	end
	busy[player] = true
	local ok, result = pcall(op, player, a, b)
	busy[player] = nil
	if not ok then
		warn("[PetService] " .. tostring(result))
		return fail("Something went wrong. Try again!")
	end
	return result
end

-- Puts newly hatched pets into empty slots (never replaces anything). Returns true if it did.
local function autoEquip(player: Player, profile: Profile, hatched: { Types.PetEntry }): boolean
	local cap = slotCap(player, profile)
	local changed = false
	for _, pet in hatched do
		if #profile.Equipped >= cap then
			break
		end
		table.insert(profile.Equipped, pet.Uid)
		changed = true
	end
	return changed
end

local function announceLegendary(player: Player, petName: string)
	local who = player.DisplayName
	task.delay(ANNOUNCE_DELAY, function()
		NotifyRemote:FireAllClients(string.format("%s hatched a Legendary %s!", who, petName), "Good")
	end)
end

local function hatch(player: Player, eggId: any, count: any): Types.RequestResult
	if type(eggId) ~= "string" then
		return fail("That egg doesn't exist.")
	end
	if count ~= 1 and count ~= 3 then
		return fail("You can hatch 1 or 3 eggs at a time.")
	end
	local egg = Config.GetEgg(eggId)
	if not egg then
		return fail("That egg doesn't exist.")
	end
	local profile = getProfile(player)
	if not profile then
		return fail(LOADING)
	end
	sanitize(profile)

	local unlocked = tonumber(profile.Unlocked) or 1
	if unlocked < egg.RequiredLevel then
		local level = Config.Levels[egg.RequiredLevel]
		local where = if level then level.Name else "the next dishwasher"
		return fail(string.format("Unlock %s to hatch the %s!", where, egg.Name))
	end
	local room = RULES.MaxInventory - #profile.Pets
	if room < count then
		if room <= 0 then
			return fail("Your pet inventory is full! Delete some pets first.")
		end
		return fail(string.format("Only room for %d more pet%s! Delete some first.", room, if room == 1 then "" else "s"))
	end
	local cost = egg.Cost * count
	if (tonumber(profile.Bubbles) or 0) < cost then
		return fail(string.format("Not enough Bubbles! You need %s.", Format.Commas(cost)))
	end

	-- Roll first: after the payment below, nothing can fail.
	local rolled: { string } = {}
	for i = 1, count do
		rolled[i] = Util.WeightedPick(egg.Pets, "Chance", rng).Pet
	end
	local paid, spent = safe(DataService.SpendBubbles, player, cost)
	if not paid or spent ~= true then
		return fail("Not enough Bubbles!")
	end

	local used: { [string]: boolean } = {}
	for _, pet in profile.Pets do
		used[pet.Uid] = true
	end
	local nextUid = profile.NextUid
	local hatched: { Types.PetEntry } = {}
	for _, petId in rolled do
		while used[tostring(nextUid)] do
			nextUid += 1
		end
		local uid = tostring(nextUid)
		nextUid += 1
		used[uid] = true
		table.insert(profile.Pets, { Uid = uid, Id = petId })
		table.insert(hatched, { Uid = uid, Id = petId }) -- a separate copy goes over the network
	end
	profile.NextUid = nextUid

	safe(DataService.AddStat, player, "EggsHatched", count)
	afterChange(player, autoEquip(player, profile, hatched))

	for _, pet in hatched do
		local def = Config.Pets[pet.Id]
		if def and def.Rarity == "Legendary" then
			announceLegendary(player, def.Name)
		end
	end
	return { Ok = true, Pets = hatched }
end

local function equip(player: Player, rawUid: any): Types.RequestResult
	local uid = normalizeUid(rawUid)
	local profile = getProfile(player)
	if not profile then
		return fail(LOADING)
	end
	sanitize(profile)
	local pet = uid and findPet(profile, uid)
	if not uid or not pet then
		return fail("That pet doesn't exist.")
	end
	if not Config.Pets[pet.Id] then
		return fail("That pet can't be equipped.")
	end
	if table.find(profile.Equipped, uid) then
		return { Ok = true } -- already out (double click): nothing to do
	end
	local cap = slotCap(player, profile)
	if #profile.Equipped >= cap then
		return fail(string.format("All %d pet slots are full! Unequip a pet first.", cap))
	end
	table.insert(profile.Equipped, uid)
	afterChange(player, true)
	return { Ok = true }
end

local function unequip(player: Player, rawUid: any): Types.RequestResult
	local uid = normalizeUid(rawUid)
	local profile = getProfile(player)
	if not profile then
		return fail(LOADING)
	end
	sanitize(profile)
	if not uid or not findPet(profile, uid) then
		return fail("That pet doesn't exist.")
	end
	local index = table.find(profile.Equipped, uid)
	if not index then
		return { Ok = true } -- already put away
	end
	table.remove(profile.Equipped, index)
	afterChange(player, true)
	return { Ok = true }
end

type Ranked = { Uid: string, Share: number, Coin: number }

local function equipBest(player: Player): Types.RequestResult
	local profile = getProfile(player)
	if not profile then
		return fail(LOADING)
	end
	sanitize(profile)

	local ranked: { Ranked } = {}
	for _, pet in profile.Pets do
		local stats = Config.PetStats(pet.Id, pet.Tier)
		if stats then
			table.insert(ranked, { Uid = pet.Uid, Share = stats.Speed + stats.Capacity * 0.002, Coin = stats.CoinBonus })
		end
	end
	if #ranked == 0 then
		return fail("You don't have any pets yet. Hatch an egg!")
	end
	-- Best cleaners first; ties go to the bigger coin bonus, then the older pet (stable order).
	table.sort(ranked, function(a, b)
		if a.Share ~= b.Share then
			return a.Share > b.Share
		end
		if a.Coin ~= b.Coin then
			return a.Coin > b.Coin
		end
		return uidLess(a.Uid, b.Uid)
	end)

	local cap = slotCap(player, profile)
	local best: { [string]: boolean } = {}
	for i = 1, math.min(cap, #ranked) do
		best[ranked[i].Uid] = true
	end
	-- Pets that stay keep their slot position (no model shuffle on the client); the rest follow in
	-- rank order.
	local equipped: { string } = {}
	for _, uid in profile.Equipped do
		if best[uid] then
			table.insert(equipped, uid)
			best[uid] = nil
		end
	end
	for i = 1, math.min(cap, #ranked) do
		local uid = ranked[i].Uid
		if best[uid] then
			table.insert(equipped, uid)
		end
	end

	local changed = #equipped ~= #profile.Equipped
	if not changed then
		for i, uid in equipped do
			if profile.Equipped[i] ~= uid then
				changed = true
				break
			end
		end
	end
	if changed then
		profile.Equipped = equipped
		afterChange(player, true)
	end
	return { Ok = true }
end

local function delete(player: Player, rawUid: any): Types.RequestResult
	local uid = normalizeUid(rawUid)
	local profile = getProfile(player)
	if not profile then
		return fail(LOADING)
	end
	sanitize(profile)
	if not uid then
		return fail("That pet doesn't exist.")
	end
	local _, index = findPet(profile, uid)
	if not index then
		return fail("That pet doesn't exist.")
	end
	table.remove(profile.Pets, index)
	local equippedAt = table.find(profile.Equipped, uid)
	if equippedAt then
		table.remove(profile.Equipped, equippedAt)
	end
	afterChange(player, equippedAt ~= nil)
	return { Ok = true }
end

-- Merge: three of the SAME pet at the same tier become one of that pet at the next tier (normal ->
-- Golden -> Rainbow; Config.PetTiers). If any of them was out, the new one takes its slot.
local MERGE_COUNT = RULES.MergeCount or 3

local function merge(player: Player, rawUids: any): Types.RequestResult
	if type(rawUids) ~= "table" then
		return fail("Pick three of the same pet to merge.")
	end
	local profile = getProfile(player)
	if not profile then
		return fail(LOADING)
	end
	sanitize(profile)
	local uids: { string } = {}
	local seen: { [string]: boolean } = {}
	local petId: string? = nil
	local tier = 1
	for i = 1, MERGE_COUNT do
		local uid = normalizeUid(rawUids[i])
		local pet = uid and findPet(profile, uid)
		if not uid or seen[uid] or not pet or not Config.Pets[pet.Id] then
			return fail("Pick three different pets to merge.")
		end
		if Config.Pets[pet.Id].Event then
			return fail("Limited pets can't be merged.")
		end
		local petTier = pet.Tier or 1
		if petId and (pet.Id ~= petId or petTier ~= tier) then
			return fail("Merging needs three of the SAME pet at the same tier.")
		end
		petId, tier = pet.Id, petTier
		seen[uid] = true
		uids[i] = uid
	end
	if tier >= #Config.PetTiers then
		return fail("Rainbow pets are already maxed!")
	end

	-- Everything is checked: remove the three, add the new one (no yields in between).
	local slot: number? = nil
	for _, uid in uids do
		local _, index = findPet(profile, uid)
		if index then
			table.remove(profile.Pets, index)
		end
		local at = table.find(profile.Equipped, uid)
		if at then
			table.remove(profile.Equipped, at)
			slot = math.min(slot or at, at)
		end
	end
	local used: { [string]: boolean } = {}
	for _, pet in profile.Pets do
		used[pet.Uid] = true
	end
	local nextUid = profile.NextUid
	while used[tostring(nextUid)] do
		nextUid += 1
	end
	local uid = tostring(nextUid)
	profile.NextUid = nextUid + 1
	local newTier = tier + 1
	table.insert(profile.Pets, { Uid = uid, Id = petId :: string, Tier = newTier })
	if slot then
		table.insert(profile.Equipped, math.min(slot, #profile.Equipped + 1), uid)
	end
	afterChange(player, true)
	return { Ok = true, Pets = { { Uid = uid, Id = petId :: string, Tier = newTier } } }
end

-- Public API: each returns a Types.RequestResult and never throws.

-- Admin (:givepet): adds one pet (tier 1 normal, 2 Golden, 3 Rainbow) to the player's collection.
function PetService.GivePet(player: Player, petId: string, tier: number?): (boolean, string?)
	local profile = DataService.Get(player)
	if not profile then
		return false, "Their data isn't loaded yet"
	end
	if not Config.Pets[petId] then
		return false, "That pet doesn't exist"
	end
	if #profile.Pets >= Config.PetRules.MaxInventory then
		return false, "Their pet inventory is full"
	end
	local used: { [string]: boolean } = {}
	for _, pet in profile.Pets do
		used[pet.Uid] = true
	end
	local nextUid = profile.NextUid
	while used[tostring(nextUid)] do
		nextUid += 1
	end
	local entry: Types.PetEntry = { Uid = tostring(nextUid), Id = petId }
	if tier and tier > 1 then
		entry.Tier = tier
	end
	table.insert(profile.Pets, entry)
	profile.NextUid = nextUid + 1
	afterChange(player, false)
	return true, nil
end

function PetService.Merge(player: Player, uids: { string }): Types.RequestResult
	return guarded(player, merge, uids)
end

function PetService.Hatch(player: Player, eggId: string, count: number): Types.RequestResult
	return guarded(player, hatch, eggId, count)
end

function PetService.Equip(player: Player, uid: string): Types.RequestResult
	return guarded(player, equip, uid)
end

function PetService.Unequip(player: Player, uid: string): Types.RequestResult
	return guarded(player, unequip, uid)
end

function PetService.EquipBest(player: Player): Types.RequestResult
	return guarded(player, function(p)
		return equipBest(p)
	end)
end

function PetService.Delete(player: Player, uid: string): Types.RequestResult
	return guarded(player, delete, uid)
end

-- (Trading) Swaps pets between two players in one go: a's `giveA` uids go to b, b's `giveB` go to
-- a. Everything is checked first (both still own every pet, both have room), then both profiles
-- change with no yield in between, so a trade can never half-happen or duplicate a pet. Moved pets
-- get fresh uids from their new owner. Returns (true) or (false, reason).
function PetService.Transfer(a: Player, b: Player, giveA: { string }, giveB: { string }): (boolean, string?)
	if a == b or busy[a] or busy[b] then
		return false, "Hold on, still working on your last request!"
	end
	local pa, pb = getProfile(a), getProfile(b)
	if not pa or not pb then
		return false, LOADING
	end
	local function collect(profile: Profile, uids: { string }): { Types.PetEntry }?
		local out, seen = {}, {}
		for _, uid in uids do
			local pet = type(uid) == "string" and not seen[uid] and findPet(profile, uid) or nil
			if not pet then
				return nil
			end
			seen[uid] = true
			table.insert(out, pet)
		end
		return out
	end
	local petsA, petsB = collect(pa, giveA), collect(pb, giveB)
	if not petsA or not petsB then
		return false, "A pet in the trade isn't there any more."
	end
	local max = RULES.MaxInventory
	if #pa.Pets - #petsA + #petsB > max or #pb.Pets - #petsB + #petsA > max then
		return false, "Someone's pet inventory would be too full."
	end

	busy[a], busy[b] = true, true
	local ok, err = pcall(function()
		local function take(profile: Profile, pets: { Types.PetEntry })
			for _, pet in pets do
				local _, index = findPet(profile, pet.Uid)
				if index then
					table.remove(profile.Pets, index)
				end
				local e = table.find(profile.Equipped, pet.Uid)
				if e then
					table.remove(profile.Equipped, e)
				end
			end
		end
		local function give(profile: Profile, pets: { Types.PetEntry })
			local used = {}
			for _, pet in profile.Pets do
				used[pet.Uid] = true
			end
			local nextUid = math.max(1, math.floor(tonumber(profile.NextUid) or 1))
			for _, pet in pets do
				while used[tostring(nextUid)] do
					nextUid += 1
				end
				local entry: Types.PetEntry = { Uid = tostring(nextUid), Id = pet.Id }
				if pet.Tier and pet.Tier > 1 then
					entry.Tier = pet.Tier
				end
				used[entry.Uid] = true
				table.insert(profile.Pets, entry)
				nextUid += 1
			end
			profile.NextUid = nextUid
		end
		take(pa, petsA)
		take(pb, petsB)
		give(pa, petsB)
		give(pb, petsA)
	end)
	busy[a], busy[b] = nil, nil
	if not ok then
		warn("[PetService] Transfer: " .. tostring(err))
		return false, "Something went wrong. Try again!"
	end
	afterChange(a, true)
	afterChange(b, true)
	return true, nil
end

-- Rebuilds a player's EquippedPets now (e.g. right after a Pet Slot perk purchase). Optional: the
-- slot watcher catches slot-count changes within SLOT_WATCH_INTERVAL anyway.
function PetService.Refresh(player: Player)
	if typeof(player) == "Instance" and player:IsA("Player") then
		local ok, err = pcall(rebuild, player)
		if not ok then
			warn("[PetService] Refresh: " .. tostring(err))
		end
	end
end

local initialized = false
local started = false

-- Rebuilds now, swallowing errors (used from signal handlers, where a throw would kill the signal
-- for every other listener too).
local function safeRebuild(player: Player)
	if isHere(player) then
		local ok, err = pcall(rebuild, player)
		if not ok then
			warn("[PetService] rebuild failed for " .. player.Name .. ": " .. tostring(err))
		end
	end
end

function PetService.Init()
	if initialized then
		return
	end
	initialized = true
	NotifyRemote = Remotes.Event("Notify")

	-- The profile may already be loaded for players who joined before this service subscribed
	-- (boot order, or a service restart in Studio).
	DataService.ProfileLoaded:Connect(function(player)
		safeRebuild(player)
	end)
	for _, player in Players:GetPlayers() do
		if getProfile(player) then
			task.spawn(safeRebuild, player)
		end
	end

	-- Pet slots depend on perks and passes; a pass grant (or the trim SetPass already does) can
	-- change the active count without going through any PetService op.
	DataService.PassesChanged:Connect(function(player)
		safeRebuild(player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		gone[player] = true
		owners[player] = nil
		busy[player] = nil
	end)
end

function PetService.Start()
	if started then
		return
	end
	started = true

	task.spawn(function()
		while true do
			task.wait(RULES.ThinkInterval)
			autoCleanTick()
		end
	end)

	task.spawn(function()
		while true do
			task.wait(SLOT_WATCH_INTERVAL)
			slotWatchTick()
		end
	end)
end

return PetService
