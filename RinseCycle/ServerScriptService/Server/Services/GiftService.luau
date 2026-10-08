--[[
	GiftService - gifting game passes to another player.

	Roblox can't sell a game pass to one player on behalf of another, so every pass has a matching
	developer product (Config.GiftProducts, "Gift: VIP", same price, Ids in StoreIds > GiftPasses).

	  1. The buyer picks a pass and a player in their server (ShopUI). GiftRequest checks the gift
	     makes sense (they're here, they don't own it yet) and remembers "this buyer is gifting this
	     pass to that player", then the client shows Roblox's purchase prompt for the gift product.
	  2. When Roblox confirms the purchase, MarketService's receipt handler calls Deliver: the
	     recipient gets the pass (the same kind of grant the admin panel's :givegamepass makes, saved
	     in the "RinseCycleGamepassGrants" store, so it lasts forever), and both players get a popup.
	  3. If the recipient left or hopped servers meanwhile the grant is still saved, and any server
	     they're in right now is told through MessagingService.

	In Studio (gift product Id still 0) a gift is free, for testing.
]]

local MessagingService = game:GetService("MessagingService")
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local DataService = require(script.Parent:WaitForChild("DataService"))

local GiftService = {}

local TOPIC = "RinseCycle_Gift"
local GRANT_STORE = "RinseCycleGamepassGrants" -- shared with AdminServer (:givegamepass)
local PENDING_TTL = 600 -- seconds a picked recipient is remembered while the prompt is open
local SAVE_ATTEMPTS = 4

type Pending = { Key: string, ToUserId: number, ToName: string, At: number }
local pending: { [Player]: Pending } = {}
local grantStore: DataStore? = nil

local function isHere(player: Player): boolean
	return player.Parent == Players
end

local function passByKey(key: any)
	if type(key) ~= "string" then
		return nil
	end
	return Config.GetPass(key)
end

-- A popup with confetti on that player's screen (Celebrate on the client).
function GiftService.Celebrate(player: Player, title: string, text: string, icon: string?)
	if isHere(player) then
		Remotes.Event("Celebrate"):FireClient(player, title, text, icon)
	end
end

local function owns(player: Player, key: string): boolean
	if player:GetAttribute("GP_" .. key) == true then
		return true
	end
	local ok, passes = pcall(DataService.GetPasses, player)
	return ok and type(passes) == "table" and passes[key] == true
end

-- Turns the pass on for a recipient who is in this server, with their popup.
local function applyHere(recipient: Player, key: string, fromName: string)
	local pass = passByKey(key)
	if not pass or not isHere(recipient) then
		return
	end
	recipient:SetAttribute("GP_" .. key, true)
	DataService.SetPass(recipient, key, true)
	GiftService.Celebrate(recipient, "You got a gift!", string.format("%s gifted you %s!", fromName, pass.Name), pass.Icon)
end

-- Saves the grant for good (same record AdminServer loads on join).
local function saveGrant(userId: number, key: string)
	task.spawn(function()
		if not grantStore then
			local ok, store = pcall(function()
				return DataStoreService:GetDataStore(GRANT_STORE)
			end)
			if ok then
				grantStore = store
			end
		end
		local store = grantStore
		if not store then
			return
		end
		for attempt = 1, SAVE_ATTEMPTS do
			local ok, err = pcall(function()
				store:UpdateAsync("grants_" .. tostring(userId), function(old)
					local list = if type(old) == "table" then old else {}
					if not table.find(list, key) then
						table.insert(list, key)
					end
					return list
				end)
			end)
			if ok then
				return
			end
			if attempt == SAVE_ATTEMPTS then
				warn(string.format("[GiftService] couldn't save gift %s for %d: %s", key, userId, tostring(err)))
			else
				task.wait(attempt * 2)
			end
		end
	end)
end

-- Gives a pass for good (Treasure Chest prizes): saved like a gift, with a popup. Never yields.
function GiftService.GrantPass(player: Player, key: string, title: string, text: string): boolean
	local pass = passByKey(key)
	if not pass or not isHere(player) then
		return false
	end
	saveGrant(player.UserId, key)
	player:SetAttribute("GP_" .. key, true)
	DataService.SetPass(player, key, true)
	GiftService.Celebrate(player, title, text, pass.Icon)
	return true
end

function GiftService.Owns(player: Player, key: string): boolean
	return owns(player, key)
end

-- Called when a gift product purchase is confirmed. Never yields. Returns true when handled.
function GiftService.Deliver(buyer: Player, key: string): boolean
	local pass = passByKey(key)
	if not pass then
		return false
	end
	local p = pending[buyer]
	pending[buyer] = nil
	local toUserId, toName
	if p and p.Key == key then
		toUserId, toName = p.ToUserId, p.ToName
	else
		-- We lost track of who it was for (e.g. the buyer rejoined): they keep it themselves.
		toUserId, toName = buyer.UserId, buyer.DisplayName
	end

	saveGrant(toUserId, key)
	local recipient = Players:GetPlayerByUserId(toUserId)
	if recipient then
		applyHere(recipient, key, buyer.DisplayName)
	else
		task.spawn(function()
			pcall(function()
				MessagingService:PublishAsync(TOPIC, { UserId = toUserId, Key = key, From = buyer.DisplayName })
			end)
		end)
	end
	if toUserId ~= buyer.UserId then
		GiftService.Celebrate(buyer, "Gift sent!", string.format("Successfully gifted %s to %s!", pass.Name, toName), pass.Icon)
	end
	return true
end

local function onGiftRequest(player: Player, key: any, toUserId: any)
	local pass = passByKey(key)
	local gift = pass and Config.GetGiftProduct(pass.Key)
	if not pass or not gift then
		return { Ok = false, Error = "That can't be gifted." }
	end
	DataService.Track(player, "gift.request")
	if type(toUserId) ~= "number" or toUserId == player.UserId then
		return { Ok = false, Error = "Pick someone to gift it to." }
	end
	local target = Players:GetPlayerByUserId(toUserId)
	if not target then
		return { Ok = false, Error = "They're not in this server any more." }
	end
	if owns(target, pass.Key) then
		return { Ok = false, Error = string.format("%s already has %s!", target.DisplayName, pass.Name) }
	end
	pending[player] = { Key = pass.Key, ToUserId = target.UserId, ToName = target.DisplayName, At = os.clock() }
	if type(gift.Id) == "number" and gift.Id > 0 then
		return { Ok = true, ProductId = gift.Id }
	end
	-- No gift product Id yet: free in Studio tests, "coming soon" in the live game.
	local test = Config.TestPasses
	if (RunService:IsStudio() and test.AllowInStudio) or test.AllowInLiveGame then
		GiftService.Deliver(player, pass.Key)
		return { Ok = true, Done = true }
	end
	pending[player] = nil
	return { Ok = false, Error = "Gifting this is coming soon!" }
end

function GiftService.Init()
	Remotes.Function("GiftRequest").OnServerInvoke = onGiftRequest
	Players.PlayerRemoving:Connect(function(player)
		pending[player] = nil
	end)
	-- Forget recipients picked long ago (a prompt that was never finished).
	task.spawn(function()
		while true do
			task.wait(60)
			local now = os.clock()
			for player, p in pending do
				if now - p.At > PENDING_TTL then
					pending[player] = nil
				end
			end
		end
	end)
	-- A gift bought in another server for someone playing here.
	task.spawn(function()
		pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function(message)
				local data = message.Data
				if type(data) ~= "table" or type(data.UserId) ~= "number" then
					return
				end
				local recipient = Players:GetPlayerByUserId(data.UserId)
				if recipient then
					applyHere(recipient, tostring(data.Key), tostring(data.From or "Someone"))
				end
			end)
		end)
	end)
end

return GiftService
