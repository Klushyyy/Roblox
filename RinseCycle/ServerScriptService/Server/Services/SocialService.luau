-- SocialService: the Follow / Favorite rewards and friend referrals (Config.Social). Nothing is
-- paid without a check.
--
-- The Free Rewards window's buttons check straight away (CheckNow). A follow Roblox can't show us
-- yet stays pending and is checked again automatically on the next join:
--   * Follow: the player's public following list is read (friends API, through Config.Social.
--     ProxyDomain because games can't call roblox.com directly; needs "Allow HTTP Requests" on in
--     Game Settings > Security). The dev on it = reward. Not on it, or the check can't run = no
--     reward (they're told why).
--   * Favorite: checked on the player's own device with AvatarEditorService (the game's place is
--     favorited), which is the only way Roblox offers. Likes can't be checked by any game, so
--     there is no Like reward any more. (Saves keep the old "Like" field names for this reward.)

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
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
			-- HTTP off or the proxy is down: the caller treats "can't check" as a follow (on trust).
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
	if profile.FollowPending and not profile.FollowReward then
		local result = follows(player.UserId, Config.Social.CreatorUserId)
		if player.Parent ~= Players then
			return
		end
		-- Only a follow we can actually see is paid. Can't check right now: stay pending.
		if result == nil then
			return
		end
		if result == true then
			if DataService.GrantSocialReward(player, "Follow") then
				DataService.Notice(player, "Thanks for following! You got " .. Config.RewardText(Config.Social.FollowReward) .. "!", "Good")
			end
		else
			DataService.SetSocialPending(player, "Follow", false)
			DataService.Notice(player, "We couldn't find your follow yet. Follow the dev, press the button again, then rejoin.", "Info")
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
	if kind == "Favorite" then
		-- The client only sends this after AvatarEditorService confirmed the favorite.
		if not Config.Social.LikeReward then
			return false, "That reward isn't available."
		end
		if profile.LikeReward then
			return false, "You already got this reward. Thank you!"
		end
		DataService.GrantSocialReward(player, "Like")
		return true, "Thanks for favoriting and liking the game! You got " .. Config.RewardText(Config.Social.LikeReward :: any) .. "!"
	elseif kind == "Follow" then
		if profile.FollowReward then
			return false, "You already got this reward. Thank you!"
		end
		local result = follows(player.UserId, Config.Social.CreatorUserId)
		if result == nil then
			return false, "We couldn't check your follow right now. Try again in a minute!"
		end
		if result == true then
			DataService.GrantSocialReward(player, "Follow")
			return true, "Thanks for following! You got " .. Config.RewardText(Config.Social.FollowReward) .. "!"
		end
		-- Roblox can take a little while to show a new follow: keep it pending so the next join
		-- checks again by itself.
		DataService.SetSocialPending(player, "Follow", true)
		return false, "We can't see your follow yet. If you followed and it's not working, please leave and rejoin the game."
	end
	return false, "That reward doesn't exist."
end

----------------------------------------------------------------------------------------------------
-- Referrals. The Free Rewards "Invite" button opens Roblox's invite prompt with the inviter's
-- UserId as launch data. When a friend joins through it, their join data carries that UserId:
--   * the friend gets Config.Social.ReferredReward (only if they're new: DataService.ClaimReferred)
--   * the inviter gets Config.Social.ReferralReward: straight away if they're in this server,
--     otherwise it waits in the "RinseCycle_ReferralPending" store and MessagingService tells
--     their server (or it's paid on their next join).
----------------------------------------------------------------------------------------------------

local PENDING_STORE = "RinseCycle_ReferralPending"
local REFERRAL_TOPIC = "RinseCycle_Referral"
local pendingStore: DataStore? = nil

local function getPendingStore(): DataStore?
	if pendingStore == nil and not DataService.IsOffline() then
		pcall(function()
			pendingStore = DataStoreService:GetDataStore(PENDING_STORE)
		end)
	end
	return pendingStore
end

local function celebrate(player: Player, title: string, text: string)
	pcall(function()
		local Remotes = require(Shared:WaitForChild("Remotes"))
		Remotes.Event("Celebrate"):FireClient(player, title, text, "@Gift")
	end)
end

local function payInviter(inviter: Player, count: number)
	local paid = DataService.AddReferrals(inviter, count)
	if paid > 0 then
		local reward = Config.Social.ReferralReward
		local each = Config.RewardText({ Bubbles = (reward.Bubbles or 0) * paid, Gems = (reward.Gems or 0) * paid })
		celebrate(inviter, "A friend joined!", string.format("%d friend%s joined from your invite: +%s!", paid, if paid == 1 then "" else "s", each))
	end
end

-- Takes whatever referrals are waiting for this player and pays them.
local function claimPending(player: Player)
	local store = getPendingStore()
	if not store then
		return
	end
	local taken = 0
	local ok = pcall(function()
		store:UpdateAsync("u_" .. player.UserId, function(old)
			taken = math.max(0, math.floor(tonumber(old) or 0))
			if taken == 0 then
				return nil
			end
			return 0
		end)
	end)
	if ok and taken > 0 and player.Parent then
		payInviter(player, taken)
	end
end

local function creditInviter(inviterId: number)
	local inviter = Players:GetPlayerByUserId(inviterId)
	if inviter and DataService.Get(inviter) then
		payInviter(inviter, 1)
		return
	end
	local store = getPendingStore()
	if not store then
		return
	end
	local ok = pcall(function()
		store:UpdateAsync("u_" .. inviterId, function(old)
			return math.max(0, math.floor(tonumber(old) or 0)) + 1
		end)
	end)
	if ok then
		pcall(function()
			MessagingService:PublishAsync(REFERRAL_TOPIC, { UserId = inviterId })
		end)
	end
end

-- A player who joined through someone's invite.
local function checkReferral(player: Player)
	local launch = nil
	pcall(function()
		launch = player:GetJoinData().LaunchData
	end)
	local inviterId = tonumber(launch)
	if not inviterId or inviterId <= 0 or inviterId == player.UserId then
		return
	end
	if DataService.ClaimReferred(player, inviterId) then
		celebrate(player, "Welcome!", "You joined from a friend's invite: +" .. Config.RewardText(Config.Social.ReferredReward) .. "!")
		creditInviter(inviterId)
	end
end

function SocialService.Init()
	if initialized then
		return
	end
	initialized = true
	DataService.ProfileLoaded:Connect(function(player)
		task.spawn(settle, player)
		task.spawn(checkReferral, player)
		task.spawn(claimPending, player)
	end)
	-- Another server says one of our players got a referral: pay it now.
	task.spawn(function()
		pcall(function()
			MessagingService:SubscribeAsync(REFERRAL_TOPIC, function(message)
				local data = message.Data
				local player = type(data) == "table" and Players:GetPlayerByUserId(tonumber(data.UserId) or 0)
				if player then
					claimPending(player)
				end
			end)
		end)
	end)
end

function SocialService.Start() end

return SocialService
