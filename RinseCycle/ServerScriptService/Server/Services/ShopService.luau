-- ShopService: owns the MetaRequest RemoteFunction (permanent purchases and pet management).
--
--   "BuyPerk"   (perkId)                     handled here: price from Config.PerkCost, pay with
--                                            DataService.SpendBubbles, level up, push MetaState, and
--                                            refresh run stats if the buyer is mid-run.
--   "Hatch"     ({ Egg = id, Count = 1|3 })  shape-checked here, then PetService.Hatch
--   "Equip" / "Unequip" / "Delete" (uid)     shape-checked here, then PetService
--   "EquipBest"                              PetService.EquipBest
--
-- Whatever the client sends, the reply is always a Types.RequestResult and this never throws.
-- Requests are rate limited (REQUESTS_PER_SECOND per player) and handled one at a time per player.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Format = require(Shared:WaitForChild("Format"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))

local DataService = require(script.Parent:WaitForChild("DataService"))
local PetService = require(script.Parent:WaitForChild("PetService"))
local RoundService = require(script.Parent:WaitForChild("RoundService"))

local ShopService = {}

local REQUESTS_PER_SECOND = 8 -- sustained rate, and also the burst size
local MAX_ID_LENGTH = 64 -- longer strings can't be a real perk id, egg id or uid

local ERR_GENERIC = "Something went wrong. Try again."
local ERR_SLOW = "Slow down a little!"
local ERR_BUSY = "Still working on your last request..."
local ERR_LOADING = "Your save is still loading. Try again in a moment."
local ERR_UNKNOWN = "Unknown request."

local budgets: { [Player]: { Tokens: number, At: number } } = {}
local busy: { [Player]: boolean } = {}
local initialized = false

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local function fail(message: string): Types.RequestResult
	return { Ok = false, Error = message }
end

local function isId(value: any): boolean
	return type(value) == "string" and #value > 0 and #value <= MAX_ID_LENGTH
end

-- Token bucket: REQUESTS_PER_SECOND tokens, refilled continuously.
local function allowRequest(player: Player): boolean
	local now = os.clock()
	local budget = budgets[player]
	if not budget then
		budget = { Tokens = REQUESTS_PER_SECOND, At = now }
		budgets[player] = budget
	end
	budget.Tokens = math.min(REQUESTS_PER_SECOND, budget.Tokens + (now - budget.At) * REQUESTS_PER_SECOND)
	budget.At = now
	if budget.Tokens < 1 then
		return false
	end
	budget.Tokens -= 1
	return true
end

-- Whatever a handler returned, turn it into a well-formed RequestResult.
local function normalize(result: any): Types.RequestResult
	if type(result) ~= "table" then
		return fail(ERR_GENERIC)
	end
	local out: Types.RequestResult = { Ok = result.Ok == true }
	if type(result.Error) == "string" then
		out.Error = result.Error
	elseif not out.Ok then
		out.Error = ERR_GENERIC
	end
	if type(result.Pets) == "table" then
		out.Pets = result.Pets
	end
	return out
end

local function callPetService(name: string, ...: any): any
	local fn = (PetService :: any)[name]
	if type(fn) ~= "function" then
		warn("[ShopService] PetService." .. name .. " is missing")
		return fail(ERR_GENERIC)
	end
	return fn(...)
end

-- Run stats depend on perks; a failure here must not turn a successful purchase into an error.
local function refreshRunStats(player: Player)
	local ok, err = pcall(function()
		if RoundService.IsInRun(player) then
			RoundService.RefreshStats(player)
		end
	end)
	if not ok then
		warn("[ShopService] RefreshStats failed: " .. tostring(err))
	end
end

----------------------------------------------------------------------------------------------------
-- Actions
----------------------------------------------------------------------------------------------------

local function buyPerk(player: Player, value: any): Types.RequestResult
	if not isId(value) then
		return fail("That perk doesn't exist.")
	end
	local perk = Config.GetPerk(value)
	local profile = DataService.Get(player)
	if not perk then
		return fail("That perk doesn't exist.")
	end
	if not profile then
		return fail(ERR_LOADING)
	end
	local level = profile.Perks[perk.Id] or 0
	local cost = Config.PerkCost(perk.Id, level)
	if not cost then
		return fail(perk.Name .. " is maxed out!")
	end
	if profile.Bubbles < cost then
		return fail("You need " .. Format.Short(cost - profile.Bubbles) .. " more 🧼")
	end
	if not DataService.SpendBubbles(player, cost) then
		return fail("Not enough Bubbles!")
	end
	profile.Perks[perk.Id] = level + 1
	DataService.PushMeta(player)
	refreshRunStats(player)
	return { Ok = true }
end

local function hatch(player: Player, value: any): Types.RequestResult
	if type(value) ~= "table" or not isId(value.Egg) then
		return fail("Pick an egg to hatch.")
	end
	local count = value.Count
	if count ~= 1 and count ~= 3 then
		return fail("You can hatch 1 or 3 eggs at a time.")
	end
	return callPetService("Hatch", player, value.Egg, count)
end

local function petAction(name: string): (Player, any) -> Types.RequestResult
	return function(player: Player, value: any): Types.RequestResult
		if not isId(value) then
			return fail("That pet doesn't exist.")
		end
		return callPetService(name, player, value)
	end
end

-- Test mode for game passes that don't have an Id yet (see Config.GamePasses): grants the pass for
-- this session only, and only in Studio unless Config.TestPasses.AllowInLiveGame is on.
local function testPass(player: Player, value: any): Types.RequestResult
	if type(value) ~= "string" then
		return fail(ERR_UNKNOWN)
	end
	local pass = Config.GetPass(value)
	if not pass then
		return fail("That pass doesn't exist.")
	end
	if type(pass.Id) == "number" and pass.Id ~= 0 then
		return fail("This pass is on sale for real. Use the purchase prompt!")
	end
	local rules = Config.TestPasses or {}
	local allowed = if RunService:IsStudio() then rules.AllowInStudio == true else rules.AllowInLiveGame == true
	if not allowed then
		return fail("Coming soon!")
	end
	DataService.SetPass(player, pass.Key, true)
	return { Ok = true }
end

local HANDLERS: { [string]: (Player, any) -> Types.RequestResult } = {
	BuyPerk = buyPerk,
	TestPass = testPass,
	Hatch = hatch,
	Equip = petAction("Equip"),
	Unequip = petAction("Unequip"),
	Delete = petAction("Delete"),
	EquipBest = function(player: Player, _value: any): Types.RequestResult
		return callPetService("EquipBest", player)
	end,
}

local function onMetaRequest(player: Player, action: any, value: any): Types.RequestResult
	if player.Parent ~= Players then
		return fail(ERR_GENERIC)
	end
	if not allowRequest(player) then
		return fail(ERR_SLOW)
	end
	local handler = if type(action) == "string" then HANDLERS[action] else nil
	if not handler then
		return fail(ERR_UNKNOWN)
	end
	if not DataService.Get(player) then
		return fail(ERR_LOADING)
	end
	-- Handlers don't yield today, but if one ever does, a second request must not interleave with it
	-- (that is how double-spends happen).
	if busy[player] then
		return fail(ERR_BUSY)
	end
	busy[player] = true
	local ok, result = pcall(handler, player, value)
	busy[player] = nil
	if not ok then
		warn(string.format("[ShopService] %s failed for %s: %s", action, player.Name, tostring(result)))
		return fail(ERR_GENERIC)
	end
	return normalize(result)
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

function ShopService.Init()
	if initialized then
		return
	end
	initialized = true
	Remotes.Function("MetaRequest").OnServerInvoke = onMetaRequest
	Players.PlayerRemoving:Connect(function(player)
		budgets[player] = nil
		busy[player] = nil
	end)
end

function ShopService.Start()
	-- Nothing to loop: every purchase arrives through MetaRequest.
end

return ShopService
