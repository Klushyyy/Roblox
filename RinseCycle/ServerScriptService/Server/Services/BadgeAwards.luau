--[[
	BadgeAwards - gives the Roblox badges in Config.Badges (IDs in StoreIds > Badges).

	Every few seconds (and right after a save loads) each player's profile is checked against the
	badge rules below. A badge that's earned and has an ID is awarded with BadgeService and noted in
	the profile (BadgesGot) so it's never asked for twice. Badges without an ID yet are skipped and
	not noted, so they're handed out as soon as the ID is pasted in, including for things players
	did before the badge existed. Roblox shows its own "badge awarded" pop-up.
]]

local BadgeService = game:GetService("BadgeService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DataService = require(script.Parent:WaitForChild("DataService"))

local BadgeAwards = {}

local CHECK_EVERY = 5
local DISH_MASTER = 1000

local initialized = false
local awarding: { [Player]: { [string]: boolean } } = {}

local function bestRankOrder(profile: any): number
	local best = 0
	local function consider(id: any)
		local rank = if type(id) == "string" then Config.GetRank(id) else nil
		local rarity = rank and Config.RankRarities[rank.Rarity]
		if rarity then
			best = math.max(best, rarity.Order)
		end
	end
	consider(profile.Rank)
	for _, id in profile.Ranks or {} do
		consider(id)
	end
	return best
end

-- Has this player earned the badge? (Only reads the profile.)
local RULES: { [string]: (any) -> boolean } = {
	Welcome = function()
		return true
	end,
	Level1 = function(p)
		return DataService.LevelsBeaten(p) >= 1
	end,
	Level2 = function(p)
		return DataService.LevelsBeaten(p) >= 2
	end,
	Level3 = function(p)
		return DataService.LevelsBeaten(p) >= 3
	end,
	FirstPet = function(p)
		return #(p.Pets or {}) > 0 or ((p.Stats and p.Stats.EggsHatched) or 0) > 0
	end,
	GoldenPet = function(p)
		for _, pet in p.Pets or {} do
			if (tonumber(pet.Tier) or 1) >= 2 then
				return true
			end
		end
		return false
	end,
	Rebirth = function(p)
		return (p.Rebirths or 0) > 0
	end,
	LegendRank = function(p)
		return bestRankOrder(p) >= Config.RankRarities.Legendary.Order
	end,
	Club = function(p)
		return type(p.ClubId) == "string" and p.ClubId ~= ""
	end,
	DishMaster = function(p)
		return ((p.Stats and p.Stats.DishesCleaned) or 0) >= DISH_MASTER
	end,
}
BadgeAwards.Rules = RULES

local function award(player: Player, badge: any)
	local busy = awarding[player]
	if not busy or busy[badge.Key] then
		return
	end
	busy[badge.Key] = true
	task.spawn(function()
		local ok, result = pcall(function()
			return BadgeService:AwardBadge(player.UserId, badge.Id)
		end)
		local profile = DataService.Get(player)
		if ok and profile then
			-- true = given now. false usually means they already had it: note it either way.
			profile.BadgesGot[badge.Key] = true
		elseif not ok then
			warn(string.format("[BadgeAwards] %s for %s: %s", badge.Key, player.Name, tostring(result)))
		end
		task.wait(if ok then 0 else 60) -- a failed award is tried again a minute later
		if awarding[player] then
			awarding[player][badge.Key] = nil
		end
	end)
end

function BadgeAwards.Check(player: Player)
	local profile = DataService.Get(player)
	if not profile or type(profile.BadgesGot) ~= "table" then
		return
	end
	for _, badge in Config.Badges do
		local rule = RULES[badge.Key]
		if type(badge.Id) == "number" and badge.Id > 0 and not profile.BadgesGot[badge.Key] and rule then
			local ok, earned = pcall(rule, profile)
			if ok and earned then
				award(player, badge)
			end
		end
	end
end

function BadgeAwards.Init()
	if initialized then
		return
	end
	initialized = true
	Players.PlayerAdded:Connect(function(player)
		awarding[player] = {}
	end)
	for _, player in Players:GetPlayers() do
		awarding[player] = {}
	end
	Players.PlayerRemoving:Connect(function(player)
		awarding[player] = nil
	end)
	DataService.ProfileLoaded:Connect(function(player)
		task.defer(BadgeAwards.Check, player)
	end)
end

function BadgeAwards.Start()
	task.spawn(function()
		while true do
			task.wait(CHECK_EVERY)
			for _, player in Players:GetPlayers() do
				pcall(BadgeAwards.Check, player)
			end
		end
	end)
end

return BadgeAwards
