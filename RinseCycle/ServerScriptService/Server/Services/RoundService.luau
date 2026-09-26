-- RoundService: owns every run (one party inside one dishwasher).
--
-- A run's life:
--   StartRound  -> claim an arena slot, ArenaBuilder.Build (yields), index the grime, create a
--                  PlayerRun per member, teleport them onto the open door, push RunState.
--   Playing     -> Scrub packets and pets call DamageGrime; cleaned grime fills the tank; standing
--                  in the drain sells the tank for coins; coins buy upgrades and tools (RunRequest).
--   Complete    -> the last spot is gone: Bubbles are paid, per-player Results are pushed, and after
--                  Config.Round.ResultsSeconds everyone still inside is sent back to the lobby.
--   Ended       -> the last member left: the arena is destroyed and its slot is freed.
--
-- The server trusts nothing from the client: every Scrub is checked for run state, a finite aim,
-- reach and rate, and the damage it deals is derived from server-side time, never from the packet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

local DataService = require(script.Parent:WaitForChild("DataService"))
local ArenaBuilder = require(script.Parent:WaitForChild("ArenaBuilder"))
local DishFactory = require(script.Parent:WaitForChild("DishFactory"))
local LobbyBuilder = require(script.Parent:WaitForChild("LobbyBuilder"))
local Characters = require(script.Parent:WaitForChild("Characters"))
local ToolModels = require(Shared:WaitForChild("ToolModels"))

local RoundService = {}

----------------------------------------------------------------------------------------------------
-- Types (server-side only; network payloads use Types.luau)
----------------------------------------------------------------------------------------------------

-- What ArenaBuilder.Build returns (DESIGN.md section 5, ArenaBuilder).
type Arena = {
	Slot: number,
	Name: string,
	Model: Model,
	Origin: CFrame,
	Spawns: { CFrame },
	DrainPosition: Vector3,
	DrainRadius: number?,
	StationPosition: Vector3?,
	GrimeFolder: Folder,
	Dishes: { [number]: any },
	TotalGrime: number,
	KillY: number?,
}

-- Cached copy of one grime spot's attributes. The table is the authority for HP during a run;
-- the part's "HP" attribute is only a mirror for clients.
type GrimeEntry = {
	HP: number,
	MaxHP: number,
	Units: number,
	DishId: number,
	Golden: boolean,
	MinTool: number,
	Color: Color3,
	Dead: boolean, -- set the instant the spot is retired, so a second hit in the same frame is a no-op
}

type DishState = {
	Id: number,
	Kind: string,
	Model: Model?,
	Center: Vector3,
	Remaining: number, -- grime spots left on this dish
	Units: number, -- total units of every spot it started with (for the dish bonus)
	Done: boolean,
}

type PlayerRun = {
	Coins: number,
	Tank: number,
	Upgrades: Types.RunUpgrades, -- global upgrades (TankSize, Sneakers); per-tool ones live in ToolUpgrades
	ToolIndex: number, -- the tool in hand
	OwnedTools: { boolean },
	ToolUpgrades: { Types.RunUpgrades }, -- [toolIndex] = that tool's HandSize / ScrubPower levels
	Stats: Types.RunStats,
	GrimeCleaned: number,
	LastScrubAt: number, -- os.clock() of the last accepted Scrub packet
	LastFullFX: number, -- os.clock() of the last "TankFull" FX (throttled)
	Results: Types.RunResults?,
}

type Run = {
	Id: number,
	Slot: number,
	Arena: Arena,
	ArenaName: string,
	Level: number,
	Players: { [Player]: PlayerRun },
	Order: { Player }, -- members in join order (spawn assignment, results order)
	MemberIds: { number }, -- cached UserIds for RunState.Members
	StartedAt: number, -- Util.Now() (server time, so client timers agree)
	Phase: "Playing" | "Complete",
	Ended: boolean,
	Total: number,
	Cleaned: number,
	Remaining: number,
	LastDamageAt: number, -- os.clock() (stuck guard)
	Grime: { [BasePart]: GrimeEntry },
	Dishes: { [number]: DishState },
	Overlap: OverlapParams, -- Include filter on this run's GrimeFolder, built once per run
	Connections: { RBXScriptConnection },
	DrainSound: Sound?,
	DrainRadius: number,
	KillY: number,
}

----------------------------------------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------------------------------------

local R = Config.Round
local PUSH_INTERVAL = 0.1 -- RunState: at most one push per player per 0.1 s
local DRAIN_INTERVAL = 0.2
local WATCHDOG_INTERVAL = 0.5 -- fall guard + stuck guard
local DRAIN_MAX_DY = 8 -- vertical tolerance for "standing in the drain"
local TANK_FULL_FX_COOLDOWN = 2
-- Held-scrub packets closer together than this are dropped without touching LastScrubAt, so the
-- time rolls into the next accepted packet: no damage is lost, but a flood can't burn server CPU
-- on spatial queries.
local HOLD_MIN_INTERVAL = R.ScrubSendInterval * 0.4
local HP_EPSILON = 1e-3
local REQUESTS_PER_SECOND = 10
local LEFT_GAME = "PlayerRemoving" -- internal RemoveFromRun reason: skip everything client-facing
local EMPTY: { [string]: any } = table.freeze({})

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------

local runs: { [number]: Run } = {}
local runOf: { [Player]: Run } = {}
local slotBusy: { [number]: boolean } = {}
local starting: { [Player]: boolean } = {} -- members of a StartRound that is still building
local pushInfo: { [Player]: { Last: number, Scheduled: boolean } } = {}
local requestWindow: { [Player]: { Start: number, Count: number } } = {}
local nextRunId = 0
local rng = Random.new()

local RunStateRemote: RemoteEvent
local RunFXRemote: RemoteEvent
local NotifyRemote: RemoteEvent

-- Forward declarations (these call each other).
local completeRun: (run: Run) -> ()
local endRun: (run: Run) -> ()
local sell: (run: Run, player: Player, pr: PlayerRun) -> ()

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

-- pcall wrapper for calls into other services. A failing DataService call must never break a
-- run's bookkeeping (dish tracking, completion), so errors are logged and swallowed.
local function safe(fn: any, ...: any): (boolean, any, any, any)
	if type(fn) ~= "function" then
		return false, nil, nil, nil
	end
	local ok, a, b, c = pcall(fn, ...)
	if not ok then
		warn("[RoundService] " .. tostring(a))
		return false, nil, nil, nil
	end
	return true, a, b, c
end

local function getProfile(player: Player): any
	local ok, profile = safe(DataService.Get, player)
	if ok and type(profile) == "table" then
		return profile
	end
	return nil
end

local function getPasses(player: Player): { [string]: boolean }
	local ok, passes = safe(DataService.GetPasses, player)
	if ok and type(passes) == "table" then
		return passes
	end
	return EMPTY
end

-- A finite, strictly positive number, or nil.
local function positive(value: any): number?
	if type(value) == "number" and value == value and value > 0 and value < math.huge then
		return value
	end
	return nil
end

local function isHere(player: Player): boolean
	return player.Parent == Players
end

local function notify(player: Player, text: string, kind: string)
	if isHere(player) then
		NotifyRemote:FireClient(player, text, kind)
	end
end

-- RunFX to every member still in the game (never FireAllClients: other parties don't care).
local function fireAll(run: Run, kind: string, data: any)
	for member in run.Players do
		if isHere(member) then
			RunFXRemote:FireClient(member, kind, data)
		end
	end
end

local function fireOne(player: Player, kind: string, data: any)
	if isHere(player) then
		RunFXRemote:FireClient(player, kind, data)
	end
end

local warnedHealth = false
local function setGrimeHealth(part: BasePart, fraction: number)
	local ok, err = pcall(DishFactory.SetGrimeHealth, part, fraction)
	if not ok and not warnedHealth then
		warnedHealth = true
		warn("[RoundService] DishFactory.SetGrimeHealth failed: " .. tostring(err))
	end
end

local function sparkle(model: Model)
	safe(DishFactory.Sparkle, model)
end

local function lobbySpawn(): CFrame
	local ok, cf = safe(LobbyBuilder.GetSpawnCFrame)
	if ok and typeof(cf) == "CFrame" then
		return cf
	end
	return CFrame.new(Config.World.LobbyOrigin + Vector3.new(0, 3, 0))
end

local function randomSpawn(run: Run): CFrame
	local spawns = run.Arena.Spawns
	return spawns[rng:NextInteger(1, #spawns)]
end

local function newUpgrades(): Types.RunUpgrades
	local upgrades: any = { Hold = 0, HandSize = 0, ScrubPower = 0, TankSize = 0, Sneakers = 0 }
	-- Any upgrade added to Config later starts at 0 too.
	for _, def in Config.Upgrades do
		if upgrades[def.Id] == nil then
			upgrades[def.Id] = 0
		end
	end
	return upgrades
end

-- The upgrade levels that apply right now: the global ones plus the tool-in-hand's own.
local function effectiveUpgrades(pr: PlayerRun): Types.RunUpgrades
	local merged = table.clone(pr.Upgrades) :: any
	local own = pr.ToolUpgrades[pr.ToolIndex] :: any
	for _, def in Config.Upgrades do
		if def.PerTool then
			merged[def.Id] = (own and own[def.Id]) or 0
		end
	end
	return merged
end

local function newToolState(): ({ boolean }, { Types.RunUpgrades })
	local owned, ups = {}, {}
	for i in Config.Tools do
		owned[i] = i == 1 -- everyone starts with Bare Hands
		ups[i] = newUpgrades()
	end
	return owned, ups
end

-- Puts a model of the tool in hand into the character's right hand (everyone can see it).
local function attachHeldTool(player: Player, toolIndex: number)
	local character = player.Character
	if not character then
		return
	end
	local old = character:FindFirstChild("HeldTool")
	if old then
		old:Destroy()
	end
	character:SetAttribute("HeldToolIndex", toolIndex)
	if toolIndex <= 1 then
		return
	end
	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		return
	end
	local ok, model = pcall(ToolModels.Build, toolIndex, 0.42)
	if not ok or not model then
		return
	end
	model.Name = "HeldTool"
	local grip = model.PrimaryPart :: BasePart
	local offset = ToolModels.HoldOffset(toolIndex)
	if hand.Name == "Right Arm" then
		offset = CFrame.new(0, -1, 0) * offset
	end
	model:PivotTo(hand.CFrame * offset)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.Massless = true
			if d ~= grip then
				local weld = Instance.new("WeldConstraint")
				weld.Part0 = grip
				weld.Part1 = d
				weld.Parent = d
			end
		end
	end
	local weld = Instance.new("Weld")
	weld.Part0 = hand
	weld.Part1 = grip
	weld.C0 = offset
	weld.Parent = grip
	model.Parent = character
end

local function detachHeldTool(player: Player)
	local character = player.Character
	local old = character and character:FindFirstChild("HeldTool")
	if old then
		old:Destroy()
	end
	if character then
		character:SetAttribute("HeldToolIndex", nil)
	end
end

local function rebuildMemberIds(run: Run)
	table.clear(run.MemberIds)
	for _, member in run.Order do
		table.insert(run.MemberIds, member.UserId)
	end
end

----------------------------------------------------------------------------------------------------
-- RunState pushes (coalesced per player)
----------------------------------------------------------------------------------------------------

local function buildState(run: Run, pr: PlayerRun): Types.RunState
	return {
		Level = run.Level,
		ArenaName = run.ArenaName,
		StartedAt = run.StartedAt,
		Phase = run.Phase,
		Coins = pr.Coins,
		Tank = pr.Tank,
		TankMax = pr.Stats.TankMax,
		ToolIndex = pr.ToolIndex,
		OwnedTools = pr.OwnedTools,
		ToolUpgrades = pr.ToolUpgrades,
		Upgrades = effectiveUpgrades(pr),
		Stats = pr.Stats,
		DrainPosition = run.Arena.DrainPosition,
		StationPosition = run.Arena.StationPosition or run.Arena.DrainPosition,
		Total = run.Total,
		Cleaned = run.Cleaned,
		Members = run.MemberIds,
		Results = pr.Results,
	}
end

local function sendRunState(player: Player)
	local run = runOf[player]
	local pr = run and run.Players[player]
	if not run or not pr or run.Ended or not isHere(player) then
		return
	end
	RunStateRemote:FireClient(player, buildState(run, pr))
end

local function flushPush(player: Player, info: { Last: number, Scheduled: boolean })
	-- A newer info table means RemoveFromRun cancelled this push (and maybe a new run began).
	if pushInfo[player] ~= info then
		return
	end
	info.Scheduled = false
	info.Last = os.clock()
	sendRunState(player)
end

-- Leading-edge throttle: the first change goes out immediately (so RunState reaches the client
-- before PartyService's PartyState(nil)); changes inside the next 0.1 s are merged into one push.
local function queuePush(player: Player)
	local info = pushInfo[player]
	if not info then
		info = { Last = -math.huge, Scheduled = false }
		pushInfo[player] = info
	end
	if info.Scheduled then
		return
	end
	local waitFor = info.Last + PUSH_INTERVAL - os.clock()
	if waitFor <= 0 then
		info.Last = os.clock()
		sendRunState(player)
	else
		info.Scheduled = true
		task.delay(waitFor, flushPush, player, info)
	end
end

local function pushAll(run: Run)
	for member in run.Players do
		queuePush(member)
	end
end

----------------------------------------------------------------------------------------------------
-- Stats
----------------------------------------------------------------------------------------------------

local function computeStats(levelIndex: number, player: Player, pr: PlayerRun): Types.RunStats
	local profile = getProfile(player)
	local perks = profile and profile.Perks
	local petBonus = 0
	if profile then
		local ok, bonus = safe(Config.PetCoinBonus, profile.Pets, profile.Equipped)
		petBonus = (ok and positive(bonus)) or 0
	end
	local rank = profile and profile.Rank or nil
	return Config.GetRunStats(levelIndex, effectiveUpgrades(pr), pr.ToolIndex, perks, getPasses(player), petBonus, rank)
end

-- Recomputes a member's stats from their upgrades, tool, perks, passes and pets, and re-applies
-- walk speed when Sneakers (or anything else) changed it.
local function recomputeStats(run: Run, player: Player, pr: PlayerRun)
	local old = pr.Stats
	local stats = computeStats(run.Level, player, pr)
	pr.Stats = stats
	if not old or old.WalkSpeed ~= stats.WalkSpeed then
		Characters.SetWalkSpeed(player, stats.WalkSpeed)
	end
end

local function sendTankFull(player: Player, pr: PlayerRun)
	local now = os.clock()
	if now - pr.LastFullFX < TANK_FULL_FX_COOLDOWN then
		return
	end
	pr.LastFullFX = now
	fireOne(player, "TankFull", EMPTY)
end

----------------------------------------------------------------------------------------------------
-- Selling at the drain
----------------------------------------------------------------------------------------------------

sell = function(run: Run, player: Player, pr: PlayerRun)
	if pr.Tank <= 0 or run.Phase ~= "Playing" then
		return
	end
	-- Recompute first so a pass or pet granted since the last recompute pays out on this sale.
	recomputeStats(run, player, pr)
	local units = pr.Tank
	local coins = math.floor(units * pr.Stats.CoinMult)
	pr.Tank = 0
	pr.Coins += coins

	local fx: Types.FXSold = { Coins = coins, Units = units, By = player.UserId }
	fireOne(player, "Sold", fx)
	local sound = run.DrainSound
	if sound then
		sound.PlaybackSpeed = 0.9 + rng:NextNumber() * 0.25
		sound:Play()
	end
	queuePush(player)
end

----------------------------------------------------------------------------------------------------
-- Grime
----------------------------------------------------------------------------------------------------

--[[
	Removes one grime spot from the run. Every path that ends a spot goes through here: scrubbing,
	pets, the stuck guard and (defensively) a spot that vanished on its own.
	  cleaner  : the player credited (nil for unrewarded pops)
	  rewarded : false = no tank units, no Bubbles, no dish bonus, no stats
]]
local function retireGrime(run: Run, part: BasePart, entry: GrimeEntry, cleaner: Player?, fromPet: boolean, rewarded: boolean)
	-- Mark first, before anything that could yield or re-enter, so this runs exactly once per spot.
	entry.Dead = true
	entry.HP = 0
	run.Grime[part] = nil
	run.Remaining -= 1
	run.Cleaned += 1

	local pr = if cleaner then run.Players[cleaner] else nil
	local rewardPlayer = if rewarded and pr then cleaner else nil
	local gained = 0
	local bubbles = 0

	if rewardPlayer and pr then
		-- Units go into the tank, capped at TankMax (the overflow is simply lost).
		gained = math.min(entry.Units, math.max(0, pr.Stats.TankMax - pr.Tank))
		pr.Tank += gained
		pr.GrimeCleaned += 1

		local gems = if entry.Golden then Config.Gems.GoldenDrop elseif rng:NextNumber() < Config.Gems.DropChance then 1 else 0
		if gems > 0 then
			safe(DataService.AddGems, rewardPlayer, gems)
			notify(rewardPlayer, string.format("💎 You found %d Gem%s!", gems, if gems == 1 then "" else "s"), "Good")
		end

		if entry.Golden then
			local range = R.GoldenBubbles
			bubbles = rng:NextInteger(range[1], range[2]) * run.Level
			safe(DataService.AddBubbles, rewardPlayer, bubbles, "GoldenGrime")
			local text = if fromPet then "✨ Your pet found golden dirt! +%d 🧼" else "✨ Golden dirt! +%d 🧼"
			notify(rewardPlayer, string.format(text, bubbles), "Good")
		end
	end

	local fx: Types.FXCleaned = {
		Position = part.Position,
		Color = entry.Color,
		Units = gained,
		By = if rewardPlayer then rewardPlayer.UserId else 0,
		Golden = entry.Golden,
		Bubbles = bubbles,
		Pet = fromPet,
	}
	fireAll(run, "Cleaned", fx)

	if part.Parent then
		part:Destroy()
	end

	-- Dish tracking: the spot that finishes a dish makes it sparkle and pays the dish bonus.
	local dish = run.Dishes[entry.DishId]
	if dish and not dish.Done then
		dish.Remaining -= 1
		if dish.Remaining <= 0 then
			dish.Done = true
			if dish.Model then
				task.spawn(sparkle, dish.Model)
			end
			local bonus = 0
			if rewardPlayer and pr then
				bonus = math.floor(dish.Units * R.DishBonusShare)
				pr.Coins += bonus
				for member in run.Players do
					safe(DataService.AddStat, member, "DishesCleaned", 1)
				end
			end
			local doneFx: Types.FXDishDone = {
				Position = dish.Center,
				Kind = dish.Kind,
				By = if rewardPlayer then rewardPlayer.UserId else 0,
				Bonus = bonus,
			}
			fireAll(run, "DishDone", doneFx)
		end
	end

	run.Arena.Model:SetAttribute("Cleaned", run.Cleaned)
	pushAll(run)

	-- The tank just filled: Auto Drain sells it on the spot, everyone else gets the "go sell" cue.
	if rewardPlayer and pr and pr.Tank >= pr.Stats.TankMax then
		if getPasses(rewardPlayer).AutoDrain then
			sell(run, rewardPlayer, pr)
		else
			sendTankFull(rewardPlayer, pr)
		end
	end

	if run.Remaining <= 0 then
		completeRun(run)
	end
end

-- Applies damage to a spot already known to be in `run`. Returns true while the spot is alive.
local function damageEntry(run: Run, player: Player, pr: PlayerRun, part: BasePart, entry: GrimeEntry, amount: number, fromPet: boolean): boolean
	if part.Parent == nil then
		-- Destroyed between the query and now by something else: count it, reward nobody.
		retireGrime(run, part, entry, nil, false, false)
		return false
	end
	if pr.Tank >= pr.Stats.TankMax then
		return true -- tank full: the player (or pet) has to go sell first
	end
	if not fromPet and (pr.Stats.Tier or pr.ToolIndex) < entry.MinTool then
		-- Too tough for this tool: it still works, just slowly (so nobody can get stuck without the
		-- coins for a better tool). Pets ignore MinTool.
		amount *= R.UnderTierMult
	end

	run.LastDamageAt = os.clock()
	local hp = entry.HP - amount
	if hp > HP_EPSILON then
		entry.HP = hp
		setGrimeHealth(part, hp / entry.MaxHP)
		part:SetAttribute("HP", hp)
		return true
	end
	retireGrime(run, part, entry, player, fromPet, true)
	return false
end

-- Reads every grime spot's attributes once, so the hot path never touches attributes.
local function indexGrime(run: Run)
	local arena = run.Arena

	if type(arena.Dishes) == "table" then
		for key, d in arena.Dishes do
			if type(d) == "table" then
				local id = tonumber(d.Id) or tonumber(key)
				if id then
					local model = if typeof(d.Model) == "Instance" and d.Model:IsA("Model") then d.Model else nil
					local center: Vector3 = if typeof(d.Center) == "Vector3"
						then d.Center
						elseif model then model:GetPivot().Position
						else arena.Origin.Position
					run.Dishes[id] = {
						Id = id,
						Kind = tostring(d.Kind or "Dish"),
						Model = model,
						Center = center,
						Remaining = 0,
						Units = 0,
						Done = false,
					}
				end
			end
		end
	end

	local toolCount = #Config.Tools
	for _, child in arena.GrimeFolder:GetChildren() do
		if child:IsA("BasePart") then
			local maxHP = positive(child:GetAttribute("MaxHP")) or positive(child:GetAttribute("HP")) or 1
			local hp = math.min(positive(child:GetAttribute("HP")) or maxHP, maxHP)
			local units = math.max(1, math.floor(positive(child:GetAttribute("Units")) or 1))
			local dishId = tonumber(child:GetAttribute("DishId")) or 0
			local minTool = math.clamp(math.floor(tonumber(child:GetAttribute("MinTool")) or 1), 1, toolCount)
			local entry: GrimeEntry = {
				HP = hp,
				MaxHP = maxHP,
				Units = units,
				DishId = dishId,
				Golden = child:GetAttribute("Golden") == true,
				MinTool = minTool,
				Color = child.Color,
				Dead = false,
			}
			run.Grime[child] = entry
			run.Total += 1
			local dish = run.Dishes[dishId]
			if dish then
				dish.Remaining += 1
				dish.Units += units
			end
		end
	end
	run.Remaining = run.Total
end

-- Stuck guard: nobody has damaged anything for a while and only a few spots are left (probably
-- somewhere unreachable). Pop them with no reward so the party can finish.
local function popRemaining(run: Run)
	-- Snapshot first: retireGrime removes entries from run.Grime.
	local parts: { BasePart } = {}
	local entries: { GrimeEntry } = {}
	for part, entry in run.Grime do
		table.insert(parts, part)
		table.insert(entries, entry)
	end
	for member in run.Players do
		notify(member, "🧼 The last few spots washed away on their own!", "Info")
	end
	for i, entry in entries do
		if not entry.Dead and run.Phase == "Playing" and not run.Ended then
			retireGrime(run, parts[i], entry, nil, false, false)
		end
	end
	-- Counters and the map can only disagree through a bug; never leave a run unfinishable.
	if run.Phase == "Playing" and not run.Ended and next(run.Grime) == nil then
		run.Remaining = 0
		completeRun(run)
	end
end

----------------------------------------------------------------------------------------------------
-- Completion and teardown
----------------------------------------------------------------------------------------------------

-- Pays every member and builds their Results. Runs in its own thread because DataService calls
-- may yield, and DamageGrime (which triggers completion) must never yield for its callers.
local function rewardRun(run: Run, members: { Player }, seconds: number, returnAt: number)
	local level = Config.GetLevel(run.Level)
	local total = math.max(1, run.Total)
	local underPar = seconds < level.ParTime

	local valid = {}
	for _, p in members do
		if run.Players[p] and isHere(p) then
			table.insert(valid, p)
		end
	end
	local n = #valid

	local rows: { Types.ResultRow } = {}
	local personal: { [Player]: { FirstClear: boolean, NewBest: boolean, Unlocked: number?, Bubbles: number } } = {}

	for _, p in valid do
		local pr = run.Players[p]
		if pr then
			local share = pr.GrimeCleaned / total
			local bubbles = level.Bubbles * (0.6 + 0.4 * math.min(1, share * n))

			local ok, first, best, unlocked = safe(DataService.RecordClear, p, run.Level, seconds)
			local firstClear = ok and first == true
			if firstClear then
				bubbles *= R.FirstClearMult
			end
			if underPar then
				bubbles *= 1 + R.UnderParBonus
			end
			if getPasses(p).DoubleBubbles then
				bubbles *= 2
			end
			if getPasses(p).VIP then
				bubbles *= 1.25
			end
			bubbles = math.floor(bubbles)

			safe(DataService.AddBubbles, p, bubbles, "RunClear")
			safe(DataService.AddGems, p, Config.Gems.PerClear * run.Level)
			safe(DataService.AddStat, p, "GrimeCleaned", pr.GrimeCleaned)
			safe(DataService.PushMeta, p)

			table.insert(rows, {
				UserId = p.UserId,
				Name = p.DisplayName,
				Grime = pr.GrimeCleaned,
				Share = pr.GrimeCleaned / total,
				Bubbles = bubbles,
			})
			personal[p] = {
				FirstClear = firstClear,
				NewBest = ok and best == true,
				Unlocked = if ok and type(unlocked) == "number" then unlocked else nil,
				Bubbles = bubbles,
			}
		end
	end

	table.sort(rows, function(a, b)
		if a.Grime ~= b.Grime then
			return a.Grime > b.Grime
		end
		return a.UserId < b.UserId
	end)

	for p, info in personal do
		local pr = run.Players[p]
		if pr and not run.Ended then
			pr.Results = {
				TimeSeconds = seconds,
				ParTime = level.ParTime,
				UnderPar = underPar,
				FirstClear = info.FirstClear,
				NewBest = info.NewBest,
				UnlockedLevel = info.Unlocked,
				Bubbles = info.Bubbles,
				Players = rows,
				ReturnAt = returnAt,
			}
			queuePush(p)
		end
	end
end

local function sendEveryoneHome(run: Run)
	if run.Ended then
		return
	end
	for _, member in table.clone(run.Order) do
		RoundService.RemoveFromRun(member, "Complete")
	end
end

completeRun = function(run: Run)
	-- Phase flips synchronously, so however many callers race here only the first one completes.
	if run.Phase ~= "Playing" or run.Ended then
		return
	end
	run.Phase = "Complete"
	local now = Util.Now()
	local seconds = math.max(0, math.floor((now - run.StartedAt) * 10 + 0.5) / 10)
	local returnAt = now + R.ResultsSeconds
	pushAll(run) -- Phase change first; Results follow as soon as the rewards are written
	task.spawn(rewardRun, run, table.clone(run.Order), seconds, returnAt)
	task.delay(R.ResultsSeconds, sendEveryoneHome, run)
end

endRun = function(run: Run)
	if run.Ended then
		return
	end
	run.Ended = true
	runs[run.Id] = nil
	for _, connection in run.Connections do
		connection:Disconnect()
	end
	table.clear(run.Connections)
	table.clear(run.Grime)
	for member in run.Players do
		if runOf[member] == run then
			runOf[member] = nil
		end
	end
	table.clear(run.Players)

	local arena = run.Arena
	local slot = run.Slot
	task.spawn(function()
		local ok = safe(ArenaBuilder.Destroy, arena)
		if not ok and arena.Model.Parent then
			pcall(function()
				arena.Model:Destroy()
			end)
		end
		slotBusy[slot] = nil
	end)
end

----------------------------------------------------------------------------------------------------
-- Starting a run
----------------------------------------------------------------------------------------------------

local function claimSlot(): number?
	for slot = 1, Config.World.MaxArenas do
		if not slotBusy[slot] then
			slotBusy[slot] = true
			return slot
		end
	end
	return nil
end

local function isValidArena(arena: any): boolean
	return type(arena) == "table"
		and typeof(arena.Model) == "Instance"
		and arena.Model.Parent ~= nil
		and typeof(arena.GrimeFolder) == "Instance"
		and type(arena.Spawns) == "table"
		and #arena.Spawns > 0
		and typeof(arena.DrainPosition) == "Vector3"
		and typeof(arena.Origin) == "CFrame"
end

-- Frees a slot whose build failed or was abandoned, destroying whatever got built.
local function abandonBuild(slot: number, arena: any)
	if type(arena) == "table" then
		safe(ArenaBuilder.Destroy, arena)
	end
	local folder = workspace:FindFirstChild("Arenas")
	local leftover = folder and folder:FindFirstChild("Arena_" .. slot)
	if leftover then
		leftover:Destroy()
	end
	slotBusy[slot] = nil
end

-- A 3D splash at the drain for every sale, so teammates hear it too (the seller also gets the
-- coin sound from the client's "Sold" FX).
local function makeDrainSound(run: Run): Sound?
	local def = Config.Sounds.Splash or Config.Sounds.Fallback
	if not def then
		return nil
	end
	local emitter = Instance.new("Part")
	emitter.Name = "DrainSound"
	emitter.Size = Vector3.new(1, 1, 1)
	emitter.Transparency = 1
	emitter.Anchored = true
	emitter.CanCollide = false
	emitter.CanQuery = false
	emitter.CanTouch = false
	emitter.CastShadow = false
	emitter.CollisionGroup = Characters.Groups.NoCollide
	emitter.CFrame = CFrame.new(run.Arena.DrainPosition)
	local sound = Instance.new("Sound")
	sound.Name = "Sell"
	sound.SoundId = def.Id
	sound.Volume = def.Volume
	sound.RollOffMinDistance = 12
	sound.RollOffMaxDistance = 140
	sound.Parent = emitter
	emitter.Parent = run.Arena.Model
	return sound
end

local function teleportInto(run: Run, player: Player, cf: CFrame)
	if runOf[player] == run and not run.Ended and isHere(player) then
		-- If the character is dead or missing, the respawn resolver brings them here instead.
		Characters.Teleport(player, cf)
	end
end

local function joinRun(run: Run, player: Player, index: number)
	local profile = getProfile(player)
	local pr: PlayerRun = {
		Coins = Config.StartCoins(run.Level, profile and profile.Perks),
		Tank = 0,
		Upgrades = newUpgrades(),
		ToolIndex = 1,
		OwnedTools = {},
		ToolUpgrades = {},
		Stats = nil :: any,
		GrimeCleaned = 0,
		LastScrubAt = 0,
		LastFullFX = 0,
		Results = nil,
	}
	pr.OwnedTools, pr.ToolUpgrades = newToolState()
	pr.Stats = computeStats(run.Level, player, pr)

	run.Players[player] = pr
	table.insert(run.Order, player)
	runOf[player] = run

	Characters.SetGroup(player, Characters.Groups.Players)
	Characters.SetWalkSpeed(player, pr.Stats.WalkSpeed)
	player:SetAttribute("InRun", true)
	player:SetAttribute("RunArena", run.ArenaName)

	local spawns = run.Arena.Spawns
	task.spawn(teleportInto, run, player, spawns[((index - 1) % #spawns) + 1])
end

function RoundService.StartRound(players: { Player }, levelIndex: number): (boolean, string?)
	if type(players) ~= "table" then
		return false, "Nobody is ready to play."
	end
	if type(levelIndex) ~= "number" or levelIndex % 1 ~= 0 or not Config.Levels[levelIndex] then
		return false, "That dishwasher doesn't exist."
	end

	local members: { Player } = {}
	for _, p in players do
		if
			typeof(p) == "Instance"
			and p:IsA("Player")
			and isHere(p)
			and not runOf[p]
			and not starting[p]
			and not table.find(members, p)
		then
			table.insert(members, p)
		end
	end
	if #members == 0 then
		return false, "Nobody is ready to play."
	end

	local slot = claimSlot()
	if not slot then
		return false, "All dishwashers are busy!"
	end

	local level = Config.GetLevel(levelIndex)
	local bestLucky = 0
	local charm = false
	for _, p in members do
		local profile = getProfile(p)
		local lucky = profile and profile.Perks and positive(profile.Perks.LuckySuds) or 0
		bestLucky = math.max(bestLucky, lucky)
		charm = charm or getPasses(p).LuckyCharm == true
		local rank = profile and Config.GetRank(profile.Rank)
		if rank and rank.Effects.Golden then
			charm = true
		end
	end
	local luckyPerk = Config.GetPerk("LuckySuds")
	local goldenChance = level.GoldenChance + bestLucky * (if luckyPerk then luckyPerk.PerLevel else 0.01)
	if charm then
		goldenChance *= 2 -- Lucky Charm pass: anyone in the party having it doubles the whole load's gold
	end
	local options = {
		GrimeScale = 1 + R.PartyGrimeScale * (#members - 1),
		GoldenChance = goldenChance,
	}

	for _, p in members do
		starting[p] = true
	end
	local built, result = pcall(ArenaBuilder.Build, slot, levelIndex, options)
	for _, p in members do
		starting[p] = nil
	end

	-- The build yielded: the arena may have failed and players may have left or been put
	-- into another run meanwhile. Re-check everything.
	local arena: Arena? = if built and isValidArena(result) then result else nil
	if not arena then
		warn("[RoundService] ArenaBuilder.Build failed for slot " .. slot .. ": " .. tostring(result))
		abandonBuild(slot, if built then result else nil)
		return false, "Couldn't fill the dishwasher. Try again!"
	end

	local stillHere: { Player } = {}
	for _, p in members do
		if isHere(p) and not runOf[p] then
			table.insert(stillHere, p)
		end
	end
	if #stillHere == 0 then
		abandonBuild(slot, arena)
		return false, "Everyone left before the wash started."
	end

	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = { arena.GrimeFolder }
	overlap.MaxParts = 60

	nextRunId += 1
	local run: Run = {
		Id = nextRunId,
		Slot = slot,
		Arena = arena,
		ArenaName = arena.Model.Name,
		Level = levelIndex,
		Players = {},
		Order = {},
		MemberIds = {},
		StartedAt = Util.Now(),
		Phase = "Playing",
		Ended = false,
		Total = 0,
		Cleaned = 0,
		Remaining = 0,
		LastDamageAt = os.clock(),
		Grime = {},
		Dishes = {},
		Overlap = overlap,
		Connections = {},
		DrainSound = nil,
		DrainRadius = positive(arena.DrainRadius) or R.DrainRadius,
		KillY = if type(arena.KillY) == "number" then arena.KillY else arena.Origin.Position.Y - 60,
	}

	indexGrime(run)
	if run.Total == 0 then
		warn("[RoundService] Arena_" .. slot .. " was built with no grime")
		abandonBuild(slot, arena)
		return false, "Couldn't fill the dishwasher. Try again!"
	end

	arena.Model:SetAttribute("Level", levelIndex)
	arena.Model:SetAttribute("Total", run.Total)
	arena.Model:SetAttribute("Cleaned", 0)
	run.DrainSound = makeDrainSound(run)

	-- Safety net: a spot removed by anything other than retireGrime still counts, so the run can
	-- always finish. retireGrime drops the map entry first, so its own destroys are ignored here.
	table.insert(
		run.Connections,
		arena.GrimeFolder.ChildRemoved:Connect(function(child)
			local entry = run.Grime[child :: BasePart]
			if entry and not entry.Dead and not run.Ended and run.Phase == "Playing" then
				retireGrime(run, child :: BasePart, entry, nil, false, false)
			end
		end)
	)

	runs[run.Id] = run
	for i, p in stillHere do
		joinRun(run, p, i)
	end
	rebuildMemberIds(run)
	pushAll(run)
	return true
end

----------------------------------------------------------------------------------------------------
-- Leaving a run
----------------------------------------------------------------------------------------------------

local function sendToLobby(player: Player)
	-- Skip if they were put into another run in the meantime or left the game.
	if runOf[player] == nil and isHere(player) then
		Characters.Teleport(player, lobbySpawn())
	end
end

function RoundService.RemoveFromRun(player: Player, reason: string?)
	local run = runOf[player]
	if not run then
		return
	end
	runOf[player] = nil
	pushInfo[player] = nil -- cancels any coalesced push still waiting
	run.Players[player] = nil
	local index = table.find(run.Order, player)
	if index then
		table.remove(run.Order, index)
	end
	rebuildMemberIds(run)

	if reason ~= LEFT_GAME and isHere(player) then
		detachHeldTool(player)
		player:SetAttribute("InRun", false)
		player:SetAttribute("RunArena", "")
		Characters.SetWalkSpeed(player, nil)
		Characters.SetGroup(player, Characters.Groups.Players)
		RunStateRemote:FireClient(player, nil)
		task.spawn(sendToLobby, player)
	end

	if next(run.Players) == nil then
		endRun(run)
	else
		pushAll(run)
	end
end

----------------------------------------------------------------------------------------------------
-- Public queries
----------------------------------------------------------------------------------------------------

function RoundService.IsInRun(player: Player): boolean
	return runOf[player] ~= nil
end

function RoundService.GetGrimeFolder(player: Player): Folder?
	local run = runOf[player]
	if run and not run.Ended then
		return run.Arena.GrimeFolder
	end
	return nil
end

function RoundService.GetRunPower(player: Player): number
	local run = runOf[player]
	local pr = run and run.Players[player]
	return if pr then pr.Stats.Power else 0
end

function RoundService.IsTankFull(player: Player): boolean
	local run = runOf[player]
	local pr = run and run.Players[player]
	return pr ~= nil and pr.Tank >= pr.Stats.TankMax
end

-- Damages a grime part if it belongs to the player's run. Returns true while the part is alive.
-- Used by the Scrub handler (fromPet = false) and PetService (fromPet = true).
function RoundService.DamageGrime(player: Player, part: BasePart, amount: number, fromPet: boolean): boolean
	local run = runOf[player]
	if not run or run.Phase ~= "Playing" or run.Ended then
		return false
	end
	local pr = run.Players[player]
	local entry = run.Grime[part]
	if not pr or not entry or entry.Dead then
		return false
	end
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return part.Parent ~= nil
	end
	return damageEntry(run, player, pr, part, entry, math.min(amount, entry.HP), fromPet == true)
end

-- Recomputes a player's run stats (perks, passes, pets). Called after pet equip changes, perk
-- purchases and pass grants; harmless when the player isn't in a run.
-- Coin packs (MarketService): adds coins to the player's current run. False if not in a run.
function RoundService.AddCoins(player: Player, amount: number): boolean
	local run = runOf[player]
	local pr = run and run.Players[player]
	if not run or not pr or run.Ended or type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return false
	end
	pr.Coins += math.floor(amount * Config.GetLevel(run.Level).Mult + 0.5)
	queuePush(player)
	return true
end

function RoundService.RefreshStats(player: Player)
	local run = runOf[player]
	local pr = run and run.Players[player]
	if not run or not pr or run.Ended then
		return
	end
	recomputeStats(run, player, pr)
	if run.Phase == "Playing" and pr.Tank > 0 and pr.Tank >= pr.Stats.TankMax and getPasses(player).AutoDrain then
		sell(run, player, pr)
	end
	queuePush(player)
end

----------------------------------------------------------------------------------------------------
-- Remote handlers
----------------------------------------------------------------------------------------------------

local function onScrub(player: Player, aim: any, holding: any)
	-- 1. In a Playing run, finite aim, alive.
	local run = runOf[player]
	if not run or run.Phase ~= "Playing" or run.Ended then
		return
	end
	local pr = run.Players[player]
	if not pr or not Util.IsFiniteVector3(aim) then
		return
	end
	local root = Characters.GetRoot(player)
	if not root then
		return
	end

	-- 2. Reach (plus slack for latency).
	local stats = pr.Stats
	if (aim - root.Position).Magnitude > stats.Reach + stats.Radius + R.ReachSlack then
		return
	end

	-- 3. Rate. Damage comes from server time, never from anything in the packet.
	local now = os.clock()
	local seconds
	if holding == true and stats.Hold then
		local dt = now - pr.LastScrubAt
		if dt < HOLD_MIN_INTERVAL then
			return
		end
		seconds = math.min(dt, R.MaxScrubDt)
	else
		if now - pr.LastScrubAt < R.MinClickInterval then
			return
		end
		seconds = R.ClickPulseSeconds
	end
	pr.LastScrubAt = now

	-- 4. Tank full: nothing to do but remind them.
	if pr.Tank >= stats.TankMax then
		sendTankFull(player, pr)
		return
	end

	-- 5. Every grime spot under the hand takes the full hit (that's what Hand Size buys).
	local amount = stats.Power * seconds
	local parts = workspace:GetPartBoundsInRadius(aim, stats.Radius, run.Overlap)
	for _, part in parts do
		local entry = run.Grime[part]
		if entry and not entry.Dead then
			damageEntry(run, player, pr, part, entry, math.min(amount, entry.HP), false)
			if run.Phase ~= "Playing" or pr.Tank >= pr.Stats.TankMax then
				break
			end
		end
	end
end

local function allowRequest(player: Player): boolean
	local now = os.clock()
	local window = requestWindow[player]
	if not window then
		requestWindow[player] = { Start = now, Count = 1 }
		return true
	end
	if now - window.Start >= 1 then
		window.Start = now
		window.Count = 1
		return true
	end
	window.Count += 1
	return window.Count <= REQUESTS_PER_SECOND
end

local function fail(message: string): Types.RequestResult
	return { Ok = false, Error = message }
end

local OK: Types.RequestResult = { Ok = true }

local function handleRunRequest(player: Player, action: any, value: any): Types.RequestResult
	if type(action) ~= "string" then
		return fail("Unknown action.")
	end
	if not allowRequest(player) then
		return fail("Slow down a little!")
	end
	local run = runOf[player]
	local pr = run and run.Players[player]
	if not run or not pr or run.Ended then
		return fail("You're not in a dishwasher right now.")
	end

	if action == "BuyUpgrade" then
		if run.Phase ~= "Playing" then
			return fail("The dishwasher is already sparkling clean!")
		end
		local def = if type(value) == "string" then Config.GetUpgrade(value) else nil
		if not def then
			return fail("That upgrade doesn't exist.")
		end
		-- Per-tool upgrades belong to the tool in hand; the rest are global.
		local upgrades = (if def.PerTool then pr.ToolUpgrades[pr.ToolIndex] else pr.Upgrades) :: any
		local current = upgrades[def.Id] or 0
		local cost = Config.UpgradeCost(def.Id, current, run.Level, pr.ToolIndex)
		if not cost then
			return fail("Already maxed!")
		end
		if pr.Coins < cost then
			return fail("Not enough coins!")
		end
		pr.Coins -= cost
		upgrades[def.Id] = current + 1
		recomputeStats(run, player, pr)
		queuePush(player)
		return OK
	elseif action == "BuyTool" then
		if run.Phase ~= "Playing" then
			return fail("The dishwasher is already sparkling clean!")
		end
		if type(value) ~= "number" or value % 1 ~= 0 or not Config.Tools[value] then
			return fail("That tool doesn't exist.")
		end
		if pr.OwnedTools[value] then
			return fail("You already have that tool!")
		end
		local cost = Config.ToolCost(value, run.Level)
		if not cost then
			return fail("That tool doesn't exist.")
		end
		if pr.Coins < cost then
			return fail("Not enough coins!")
		end
		pr.Coins -= cost
		pr.OwnedTools[value] = true
		pr.ToolIndex = value -- a new tool goes straight into your hand
		recomputeStats(run, player, pr)
		attachHeldTool(player, value)
		queuePush(player)
		return OK
	elseif action == "EquipTool" then
		if type(value) ~= "number" or value % 1 ~= 0 or not pr.OwnedTools[value] then
			return fail("You don't have that tool yet.")
		end
		if pr.ToolIndex ~= value then
			pr.ToolIndex = value
			recomputeStats(run, player, pr)
			attachHeldTool(player, value)
			queuePush(player)
		end
		return OK
	elseif action == "Leave" then
		RoundService.RemoveFromRun(player, "Leave")
		return OK
	elseif action == "ReturnToLobby" then
		if run.Phase ~= "Complete" then
			return fail("Finish the load first!")
		end
		RoundService.RemoveFromRun(player, "ReturnToLobby")
		return OK
	end
	return fail("Unknown action.")
end

----------------------------------------------------------------------------------------------------
-- Loops
----------------------------------------------------------------------------------------------------

-- Anyone standing in their run's drain with grime in the tank sells it.
local function drainStep()
	for _, run in runs do
		if run.Phase == "Playing" and not run.Ended then
			local drain = run.Arena.DrainPosition
			local r2 = run.DrainRadius * run.DrainRadius
			for player, pr in run.Players do
				if pr.Tank > 0 then
					local root = Characters.GetRoot(player)
					if root then
						local pos = root.Position
						local dx, dz = pos.X - drain.X, pos.Z - drain.Z
						if dx * dx + dz * dz <= r2 and math.abs(pos.Y - drain.Y) < DRAIN_MAX_DY then
							sell(run, player, pr)
						end
					end
				end
			end
		end
	end
end

-- Fall guard (below KillY -> back to a spawn) and stuck guard.
local function watchdogStep()
	local now = os.clock()
	for _, run in runs do
		if not run.Ended then
			for player, pr in run.Players do
				local root = Characters.GetRoot(player)
				if root and root.Position.Y < run.KillY then
					Characters.Teleport(player, randomSpawn(run))
				end
				-- Re-attach the tool in hand after a respawn (a new character has none).
				local character = player.Character
				if root and character and character:GetAttribute("HeldToolIndex") ~= pr.ToolIndex then
					attachHeldTool(player, pr.ToolIndex)
				end
			end
			if
				run.Phase == "Playing"
				and run.Remaining > 0
				and run.Remaining <= R.StuckMaxRemaining
				and now - run.LastDamageAt >= R.StuckSeconds
			then
				popRemaining(run)
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------------------------------

function RoundService.Init()
	RunStateRemote = Remotes.Event("RunState")
	RunFXRemote = Remotes.Event("RunFX")
	NotifyRemote = Remotes.Event("Notify")

	Remotes.Event("Scrub").OnServerEvent:Connect(onScrub)

	Remotes.Function("RunRequest").OnServerInvoke = function(player: Player, action: any, value: any)
		local ok, result = pcall(handleRunRequest, player, action, value)
		if not ok then
			warn("[RoundService] RunRequest error: " .. tostring(result))
			return fail("Something went wrong. Try again!")
		end
		return result
	end

	-- A player in a run always respawns on their dishwasher's door.
	Characters.AddRespawnResolver(function(player: Player): CFrame?
		local run = runOf[player]
		if run and not run.Ended then
			return randomSpawn(run)
		end
		return nil
	end)

	local function onPlayerAdded(player: Player)
		if player:GetAttribute("InRun") == nil then
			player:SetAttribute("InRun", false)
		end
		if player:GetAttribute("RunArena") == nil then
			player:SetAttribute("RunArena", "")
		end
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		RoundService.RemoveFromRun(player, LEFT_GAME)
		pushInfo[player] = nil
		requestWindow[player] = nil
		starting[player] = nil
	end)

	-- Pass grants (MarketService) and late-loading profiles change run stats.
	local passesChanged = (DataService :: any).PassesChanged
	if type(passesChanged) == "table" and type(passesChanged.Connect) == "function" then
		passesChanged:Connect(function(player: Player)
			RoundService.RefreshStats(player)
		end)
	end
	local profileLoaded = (DataService :: any).ProfileLoaded
	if type(profileLoaded) == "table" and type(profileLoaded.Connect) == "function" then
		profileLoaded:Connect(function(player: Player)
			RoundService.RefreshStats(player)
		end)
	end
end

function RoundService.Start()
	task.spawn(function()
		while true do
			task.wait(DRAIN_INTERVAL)
			local ok, err = pcall(drainStep)
			if not ok then
				warn("[RoundService] drain loop: " .. tostring(err))
			end
		end
	end)
	task.spawn(function()
		while true do
			task.wait(WATCHDOG_INTERVAL)
			local ok, err = pcall(watchdogStep)
			if not ok then
				warn("[RoundService] watchdog loop: " .. tostring(err))
			end
		end
	end)
end

return RoundService
