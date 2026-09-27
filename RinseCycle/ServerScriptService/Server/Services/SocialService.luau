-- SocialService: settles the Follow / Like rewards (Config.Social) when a player joins.
--
-- The Free Rewards window's buttons check straight away (CheckNow). A follow Roblox can't show us
-- yet stays pending and is checked again automatically on the next join:
--   * Follow: the player's public following list is read (friends API, through Config.Social.
--     ProxyDomain because games can't call roblox.com directly). The dev on it = reward. Not on it =
--     the pending mark is cleared and they're told to follow first. The check failing (HTTP off,
--     proxy down) keeps it pending for next time.
--   * Like: Roblox has no API for likes, so it's paid on trust.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DataService = require(script.Parent:WaitForChild("DataService"))

local SocialService = {}

local MAX_PAGES = 20 -- 2,000 followings is plenty

local initialized = false

-- true / false when the list was read, nil when it couldn't be checked.
local function follows(userId: number, targetId: number): boolean?
	local cursor = ""
	for _ = 1, MAX_PAGES do
		local url = string.format("https://friends.%s/v1/users/%d/followings?limit=100&sortOrder=Desc%s", Config.Social.ProxyDomain, userId, if cursor ~= "" then "&cursor=" .. HttpService:UrlEncode(cursor) else "")
		local ok, body = pcall(function()
			return HttpService:GetAsync(url)
		end)
		if not ok then
			warn("[SocialService] follow check failed: " .. tostring(body))
			return nil
		end
		local okJson, data = pcall(function()
			return HttpService:JSONDecode(body)
		end)
		if not okJson or type(data) ~= "table" or type(data.data) ~= "table" then
			return nil
		end
		for _, entry in data.data do
			if type(entry) == "table" and entry.id == targetId then
				return true
			end
		end
		if type(data.nextPageCursor) ~= "string" or data.nextPageCursor == "" then
			return false
		end
		cursor = data.nextPageCursor
	end
	return false
end

local function settle(player: Player)
	local profile = DataService.Get(player)
	if not profile or player.Parent ~= Players then
		return
	end
	if profile.LikePending and not profile.LikeReward and Config.Social.LikeReward then
		if DataService.GrantSocialReward(player, "Like") then
			DataService.Notice(player, "👍 Thanks for liking the game! You got " .. Config.RewardText(Config.Social.LikeReward :: any) .. "!", "Good")
		end
	end
	if profile.FollowPending and not profile.FollowReward then
		local result = follows(player.UserId, Config.Social.CreatorUserId)
		if player.Parent ~= Players then
			return
		end
		if result == true then
			if DataService.GrantSocialReward(player, "Follow") then
				DataService.Notice(player, "⭐ Thanks for following! You got " .. Config.RewardText(Config.Social.FollowReward) .. "!", "Good")
			end
		elseif result == false then
			DataService.SetSocialPending(player, "Follow", false)
			DataService.Notice(player, "We couldn't find your follow yet. Follow the dev, press the button again, then rejoin.", "Info")
		else
			DataService.Notice(player, "Couldn't check your follow right now. It'll be checked next time you join.", "Info")
		end
	end
end

-- MetaRequest "SocialDone": the Free Rewards button. Follow is checked right now (and, if the
-- check can't see it yet, again automatically next time they join); Like can't be checked by any
-- game, so it's paid on the click. Returns (ok, message).
function SocialService.CheckNow(player: Player, kind: string): (boolean, string)
	local profile = DataService.Get(player)
	if not profile then
		return false, "Your data is still loading."
	end
	if kind == "Like" then
		if not Config.Social.LikeReward then
			return false, "That reward isn't available."
		end
		if profile.LikeReward then
			return false, "You already got this reward. Thank you! 💙"
		end
		DataService.GrantSocialReward(player, "Like")
		return true, "👍 Thanks for liking the game! You got " .. Config.RewardText(Config.Social.LikeReward :: any) .. "!"
	elseif kind == "Follow" then
		if profile.FollowReward then
			return false, "You already got this reward. Thank you! 💙"
		end
		local result = follows(player.UserId, Config.Social.CreatorUserId)
		if result == true then
			DataService.GrantSocialReward(player, "Follow")
			return true, "⭐ Thanks for following! You got " .. Config.RewardText(Config.Social.FollowReward) .. "!"
		end
		-- Roblox can take a little while to show a new follow: keep it pending so the next join
		-- checks again by itself.
		DataService.SetSocialPending(player, "Follow", true)
		if result == false then
			return false, "We can't see your follow yet. If you followed and it's not working, please leave and rejoin the game."
		end
		return false, "Couldn't check right now. If you followed, please leave and rejoin the game."
	end
	return false, "That reward doesn't exist."
end

function SocialService.Init()
	if initialized then
		return
	end
	initialized = true
	DataService.ProfileLoaded:Connect(function(player)
		task.spawn(settle, player)
	end)
end

function SocialService.Start() end

return SocialService
