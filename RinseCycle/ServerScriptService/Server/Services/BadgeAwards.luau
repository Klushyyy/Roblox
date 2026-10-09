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

----------------------------------------------------------------------------------------------------
-- Talking to Roblox. Every call is wrapped; a badge only counts as given once the player really owns it.
----------------------------------------------------------------------------------------------------

local RETRY_AFTER = 300 -- seconds before a badge that could not be given is tried again
local verified: { [Player]: { [string]: boolean } } = {}
local verifying: { [Player]: boolean } = {}
local warned: { [string]: boolean } = {}
local infoCache: { [number]: { At: number, Enabled: boolean?, Name: string?, Error: string? } } = {}

-- What Roblox knows about the badge (cached for five minutes): is it switched on, and does it exist for this experience?
local function badgeInfo(id: number): { At: number, Enabled: boolean?, Name: string?, Error: string? }
	local cached = infoCache[id]
	if cached and os.clock() - cached.At < 300 then
		return cached
	end
	local ok, result = pcall(function()
		return BadgeService:GetBadgeInfoAsync(id)
	end)
	local record: any = { At = os.clock() }
	if ok and type(result) == "table" then
		record.Enabled = result.IsEnabled
		record.Name = result.Name
	else
		record.Error = tostring(result)
	end
	infoCache[id] = record
	return record
end

-- true / false when Roblox answered, nil (and the reason) when it could not be asked.
local function owns(player: Player, id: number): (boolean?, string?)
	local ok, result = pcall(function()
		return BadgeService:UserHasBadgeAsync(player.UserId, id)
	end)
	if ok then
		return result == true, nil
	end
	return nil, tostring(result)
end

-- Gives the badge (AwardBadgeAsync; the old AwardBadge only if this Roblox has no Async one) and checks the player
-- really has it afterwards. Returns (has it now, why not).
local function tryAward(player: Player, badge: any): (boolean, string?)
	local info = badgeInfo(badge.Id)
	if info.Enabled == false then
		return false, "the badge is switched OFF on Roblox (Creator Hub > Badges > it > Enable)"
	end
	local okCall, result = pcall(function()
		return (BadgeService :: any):AwardBadgeAsync(player.UserId, badge.Id)
	end)
	if not okCall and string.find(tostring(result), "valid member", 1, true) then
		okCall, result = pcall(function()
			return (BadgeService :: any):AwardBadge(player.UserId, badge.Id)
		end)
	end
	local has, whyNot = owns(player, badge.Id)
	if has == true then
		return true, nil
	end
	if has == nil and okCall and result == true then
		return true, nil -- (Roblox said it was given and could not be asked again)
	end
	if not okCall then
		return false, tostring(result)
	end
	return false, whyNot or (if info.Error then "Roblox can't find this badge for this experience: " .. info.Error else "Roblox did not give it (is the badge made in THIS experience and switched on?)")
end

local function award(player: Player, badge: any)
	local busy = awarding[player]
	if not busy or busy[badge.Key] then
		return
	end
	busy[badge.Key] = true
	task.spawn(function()
		local done, reason = tryAward(player, badge)
		local profile = DataService.Get(player)
		if done and profile then
			profile.BadgesGot[badge.Key] = true
		elseif not done then
			local mark = tostring(player.UserId) .. ":" .. badge.Key
			if not warned[mark] then
				warned[mark] = true
				warn(string.format("[BadgeAwards] could not give %s (%d) to %s: %s", badge.Key, badge.Id, player.Name, tostring(reason)))
			end
		end
		task.wait(if done then 0 else RETRY_AFTER) -- a badge that failed is tried again later
		if awarding[player] then
			awarding[player][badge.Key] = nil
		end
	end)
end

-- A badge the save says was given: once per visit, ask Roblox whether the player really has it. If not (an older version
-- marked it given when it was not), the note is cleared and it is given again.
local function verifyOne(player: Player, profile: any)
	if verifying[player] then
		return
	end
	local done = verified[player]
	if not done then
		return
	end
	for _, badge in Config.Badges do
		local rule = RULES[badge.Key]
		if type(badge.Id) == "number" and badge.Id > 0 and profile.BadgesGot[badge.Key] and not done[badge.Key] and rule then
			local ok, earned = pcall(rule, profile)
			if ok and earned then
				verifying[player] = true
				task.spawn(function()
					local has = owns(player, badge.Id)
					done[badge.Key] = true
					if has == false and DataService.Get(player) == profile then
						profile.BadgesGot[badge.Key] = nil
						warn(string.format("[BadgeAwards] %s was marked given to %s but Roblox says they do not have it: giving it again", badge.Key, player.Name))
					end
					verifying[player] = nil
				end)
				return
			end
		end
	end
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
	verifyOne(player, profile)
end

-- For the admin command :badges: every badge, whether this player earned it, has the note, and really owns it on Roblox;
-- an earned badge they do not own is given now. Returns rows { Line1, Line2 }.
function BadgeAwards.Audit(player: Player): { { Line1: string, Line2: string } }
	local rows = {}
	local profile = DataService.Get(player)
	if not profile or type(profile.BadgesGot) ~= "table" then
		return { { Line1 = "Their save is still loading.", Line2 = "" } }
	end
	for _, badge in Config.Badges do
		local rule = RULES[badge.Key]
		local id = badge.Id
		if type(id) ~= "number" or id <= 0 then
			table.insert(rows, { Line1 = string.format("%s  -  NO ID", badge.Name), Line2 = "StoreIds > Badges > " .. badge.Key .. " has no badge ID yet" })
			continue
		end
		local okRule, earned = pcall(rule, profile)
		earned = okRule and earned == true
		local info = badgeInfo(id)
		local has, askError = owns(player, id)
		local flag = profile.BadgesGot[badge.Key] == true
		local verdict
		if has == true then
			verdict = "OK, they have it"
			profile.BadgesGot[badge.Key] = true
		elseif not earned then
			verdict = "not earned yet"
		else
			local done, reason = tryAward(player, badge)
			if done then
				profile.BadgesGot[badge.Key] = true
				verdict = "WAS MISSING: given just now"
			else
				profile.BadgesGot[badge.Key] = nil
				verdict = "EARNED BUT NOT GIVEN: " .. tostring(reason)
			end
		end
		local enabled = if info.Enabled == nil then (if info.Error then "unknown (" .. info.Error .. ")" else "unknown") else (if info.Enabled then "on" else "OFF")
		table.insert(rows, {
			Line1 = string.format("%s  -  %s", badge.Name, verdict),
			Line2 = string.format("id %d  -  earned: %s  -  on Roblox: %s  -  save note: %s  -  badge: %s", id, if earned then "yes" else "no", if has == nil then "? (" .. tostring(askError) .. ")" else (if has then "yes" else "no"), if flag then "yes" else "no", enabled),
		})
	end
	return rows
end

function BadgeAwards.Init()
	if initialized then
		return
	end
	initialized = true
	Players.PlayerAdded:Connect(function(player)
		awarding[player] = {}
		verified[player] = {}
	end)
	for _, player in Players:GetPlayers() do
		awarding[player] = {}
		verified[player] = {}
	end
	Players.PlayerRemoving:Connect(function(player)
		awarding[player] = nil
		verified[player] = nil
		verifying[player] = nil
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
