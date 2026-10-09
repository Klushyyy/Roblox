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

local GroupService = game:GetService("GroupService")
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
	if type(result.Rank) == "string" then
		out.Rank = result.Rank
		out.Equipped = result.Equipped == true
	end
	if type(result.Previous) == "string" then
		out.Previous = result.Previous
	end
	if type(result.Message) == "string" then
		out.Message = result.Message
	end
	if type(result.Day) == "number" then
		out.Day = result.Day
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
		return fail("You need " .. Format.Short(cost - profile.Bubbles) .. " more Bubbles")
	end
	if not DataService.SpendBubbles(player, cost, "Perk:" .. perk.Id) then
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

-- Free "test purchases" of passes/products without an Id: Studio only, unless Config says otherwise.
local function testAllowed(): boolean
	local rules = Config.TestPasses or {}
	return if RunService:IsStudio() then rules.AllowInStudio == true else rules.AllowInLiveGame == true
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
	if not testAllowed() then
		return fail("Coming soon!")
	end
	DataService.SetPass(player, pass.Key, true)
	return { Ok = true }
end

-- Test mode for developer products without an Id: gives the goods for free (Studio only).
local function testProduct(player: Player, value: any): Types.RequestResult
	local product = if type(value) == "string" then Config.GetProduct(value) else nil
	if not product then
		return fail("That item doesn't exist.")
	end
	if type(product.Id) == "number" and product.Id ~= 0 then
		return fail("This is on sale for real. Use the purchase prompt!")
	end
	if not testAllowed() then
		return fail("Coming soon!")
	end
	local MarketService = require(script.Parent:WaitForChild("MarketService")) :: any
	if not MarketService.GrantProduct(player, product) then
		return fail("Couldn't give that right now.")
	end
	return { Ok = true }
end

-- Rank roll: spend gems, pick a weighted random rank (x2 Luck pass boosts Rare+) and it REPLACES
-- your rank - a gamble, so a good rank is worth keeping. One roll at a time per player.
local rankRng = Random.new()
local ROLL_SECONDS = 1.2 -- matches the client's reel; no second roll until it has landed
local rollingUntil: { [Player]: number } = {}
Players.PlayerRemoving:Connect(function(player)
	rollingUntil[player] = nil
end)
local function rollRank(player: Player, _value: any): Types.RequestResult
	local now = os.clock()
	if now < (rollingUntil[player] or 0) then
		return fail("Wait for your roll to finish!")
	end
	local locked = Config.EventLockdown()
	if locked then
		return fail("Ranks are closed while Admin Abuse is on!")
	end
	local cost = Config.RankRoll.Cost
	local profile = DataService.Get(player)
	if not profile then
		return fail(ERR_LOADING)
	end
	if profile.Gems < cost then
		return fail(string.format("You need %d Gems to roll!", cost))
	end
	if not DataService.SpendGems(player, cost, "RankRoll") then
		return fail(ERR_GENERIC)
	end
	local passes = DataService.GetPasses(player)
	rollingUntil[player] = now + ROLL_SECONDS
	local weights, total = Config.RankWeights(Config.LuckMult(passes.DoubleLuck == true, profile.Referrals))
	local r = rankRng:NextNumber() * total
	local picked = weights[#weights].Rank
	for _, entry in weights do
		r -= entry.Weight
		if r <= 0 then
			picked = entry.Rank
			break
		end
	end
	local previous = profile.Rank
	DataService.AddRank(player, picked.Id)
	DataService.SetRank(player, picked.Id)
	return { Ok = true, Rank = picked.Id, Equipped = true, Previous = previous }
end


local function rebirth(player: Player, _value: any): Types.RequestResult
	if RoundService.IsInRun(player) then
		return fail("Finish your wash first!")
	end
	local ok, err = DataService.Rebirth(player)
	if not ok then
		return fail(err or ERR_GENERIC)
	end
	-- Everyone hears about it: rebirths are the big flex.
	local profile = DataService.Get(player)
	local count = profile and profile.Rebirths or 1
	local notify = Remotes.Event("Notify")
	for _, other in Players:GetPlayers() do
		if other ~= player then
			notify:FireClient(other, string.format("%s just reached Rebirth %d!", player.DisplayName, count), "Good")
		end
	end
	return { Ok = true }
end

-- Daily reward: claimable 24 hours after the last one (DataService.ClaimDaily).
local function claimDaily(player: Player, _value: any): Types.RequestResult
	local day, err = DataService.ClaimDaily(player)
	if not day then
		return fail(err or ERR_GENERIC)
	end
	-- "Your next reward is ready" notification for 24 h from now.
	pcall(function()
		(require(script.Parent:WaitForChild("DailyNotify")) :: any).Queue(player)
	end)
	return { Ok = true, Day = day, Message = Config.RewardText({
		Bubbles = if Config.DailyRewards[day].Kind == "Gems" then nil else Config.DailyRewards[day].Amount,
		Gems = if Config.DailyRewards[day].Kind == "Gems" then Config.DailyRewards[day].Amount else nil,
	}) }
end

local function redeemCode(player: Player, value: any): Types.RequestResult
	if type(value) ~= "string" or #value == 0 or #value > 40 then
		return fail("Type a code first!")
	end
	local ok, message = DataService.RedeemCode(player, value)
	if not ok then
		return fail(message)
	end
	return { Ok = true, Message = message }
end

-- Community reward: checked live with Roblox (GroupService:GetGroupsAsync isn't cached for the
-- session like the old Player:IsInGroup), so it works right after joining from the in-game prompt.
local function inGroup(player: Player, groupId: number): boolean
	local ok, groups = pcall(function()
		return GroupService:GetGroupsAsync(player.UserId)
	end)
	if ok and type(groups) == "table" then
		for _, g in groups do
			if type(g) == "table" and g.Id == groupId then
				return true
			end
		end
		return false
	end
	local okFallback, member = pcall(function()
		return player:IsInGroupAsync(groupId)
	end)
	return okFallback and member == true
end

local function claimGroup(player: Player, _value: any): Types.RequestResult
	local groupId = Config.GetGroupId()
	if groupId <= 0 then
		return fail("The community isn't set up yet!")
	end
	local profile = DataService.Get(player)
	if not profile then
		return fail(ERR_LOADING)
	end
	if profile.GroupReward then
		return fail("You already got this reward. Thanks for joining!")
	end
	if not inGroup(player, groupId) then
		return fail("Join the community first, then claim!")
	end
	if not DataService.GrantGroupReward(player) then
		return fail(ERR_GENERIC)
	end
	return { Ok = true, Message = Config.RewardText(Config.Social.GroupReward) }
end

-- Follow / Like: checked right away (SocialService.CheckNow).
local function socialDone(player: Player, value: any): Types.RequestResult
	local SocialService = require(script.Parent:WaitForChild("SocialService")) :: any
	local ok, message = SocialService.CheckNow(player, if type(value) == "string" then value else "")
	if not ok then
		return fail(message)
	end
	return { Ok = true, Message = message }
end

-- The free x2 cleaning boost offered when a player opens the Roblox menu (once a day).
local function claimStayBoost(player: Player, _value: any): Types.RequestResult
	local ok, message = DataService.ClaimStayBoost(player)
	if not ok then
		return fail(message)
	end
	return { Ok = true, Message = message }
end

local function setPetsResting(player: Player, value: any): Types.RequestResult
	if type(value) ~= "boolean" then
		return fail("Bad request.")
	end
	if not DataService.SetPetsResting(player, value) then
		return fail("Your data is still loading.")
	end
	return { Ok = true }
end

-- The first-run tutorial was finished (value true: the reward is paid once) or skipped (never shown again).
local function tutorialDone(player: Player, value: any): Types.RequestResult
	local ok, rewarded = DataService.SetTutorialDone(player, value == true)
	if not ok then
		return fail("Your data is still loading.")
	end
	if rewarded then
		local GiftService = require(script.Parent:WaitForChild("GiftService")) :: any
		GiftService.Celebrate(player, "Tutorial complete!", Config.RewardText(Config.Tutorial.Reward), "Gem")
	end
	return { Ok = true, Message = if rewarded then Config.RewardText(Config.Tutorial.Reward) else nil }
end

-- The client has shown the pending club message ("You were kicked from ...").
local function clubNoticeSeen(player: Player, _value: any): Types.RequestResult
	DataService.SetClubNotice(player, "")
	return { Ok = true }
end

-- Menu requests that are bookkeeping rather than something the player chose.
local UNTRACKED: { [string]: boolean } = { ClubNoticeSeen = true, SawEpisode = true, SetTouch = true }

local HANDLERS: { [string]: (Player, any) -> Types.RequestResult } = {
	TutorialDone = tutorialDone,
	ClubNoticeSeen = clubNoticeSeen,
	-- The player's screen is a touch screen (value true) or not: tools reach Config.Round.TouchReachMult times as far on touch.
	SetTouch = function(player: Player, value: any): Types.RequestResult
		player:SetAttribute("TouchReach", value == true)
		RoundService.RefreshStats(player)
		return { Ok = true }
	end,
	ClaimDaily = claimDaily,
	ClaimStayBoost = claimStayBoost,
	SetPetsResting = setPetsResting,
	SocialDone = socialDone,
	RedeemCode = redeemCode,
	ClaimGroup = claimGroup,
	Rebirth = rebirth,
	BuyPerk = buyPerk,
	TestPass = testPass,
	TestProduct = testProduct,
	RollRank = rollRank,
	Hatch = hatch,
	Equip = petAction("Equip"),
	Unequip = petAction("Unequip"),
	Delete = petAction("Delete"),
	Merge = function(player: Player, value: any): Types.RequestResult
		local n = Config.PetRules.MergeCount or 3
		if type(value) ~= "table" or #value ~= n then
			return fail(string.format("Pick %d pets to merge.", n))
		end
		local uids = {}
		for i = 1, n do
			if not isId(value[i]) then
				return fail("That pet doesn't exist.")
			end
			uids[i] = value[i]
		end
		return callPetService("Merge", player, uids)
	end,
	EquipBest = function(player: Player, _value: any): Types.RequestResult
		return callPetService("EquipBest", player)
	end,
	-- The run-start cutscene played (or was skipped): move this level's story on a chapter.
	SawEpisode = function(player: Player, value: any): Types.RequestResult
		if type(value) ~= "number" or not DataService.SawEpisode(player, value) then
			return fail(ERR_GENERIC)
		end
		return { Ok = true }
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
	-- Random results that cost Robux, or Gems / Bubbles that can be bought with Robux: not for players Roblox's policy
	-- restricts (DataService.PaidRandomRestricted). The screens grey these buttons out; this is the real check.
	if (action == "RollRank" or action == "Hatch") and DataService.PaidRandomRestricted(player) then
		return fail("Rolling and hatching aren't available for your account.")
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
	local answer = normalize(result)
	if not UNTRACKED[action] then
		-- (what the menus are used for, and which buttons get refused: Analytics)
		DataService.Track(player, (if answer.Ok then "meta." else "metafail.") .. action)
	end
	return answer
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
