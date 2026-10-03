--[[
	EventService - the limited-time Treasure Chest event (Config.ChestEvent).

	  * Free chests: ChestRequest "Free" opens one (Config.ChestEvent.FreeOpens per event, saved).
	  * Bought chests: x1 / x3 / x10 developer products (StoreIds > Events). Roblox's receipt lands in
	    MarketService, which calls the grant registered here: the chests are opened on the server
	    right away and the results go to the client (ChestResult) for the reveal.
	  * Studio: packs without a product Id open for free (ChestRequest "Test"), like the shop's tests.

	Every roll is weighted by Config.ChestEvent.Rewards (the same odds the chest window shows).
	Rewards never yield: Bubbles / Gems / the x2 Cleaning boost / a pet / a game pass (a random one
	you don't own, saved like a gift; if you own them all, Gems instead).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local DataService = require(script.Parent:WaitForChild("DataService"))
local MarketService = require(script.Parent:WaitForChild("MarketService"))

local EventService = {}

local rng = Random.new()
local initialized = false
local lastRequest: { [Player]: number } = {}

local function petService(): any
	return require(script.Parent:WaitForChild("PetService")) :: any
end

local function giftService(): any
	return require(script.Parent:WaitForChild("GiftService")) :: any
end

local function pick(): (number, any)
	local rewards = Config.ChestEvent.Rewards
	local x = rng:NextNumber() * 100
	for i, r in rewards do
		x -= r.Chance
		if x <= 0 then
			return i, r
		end
	end
	return 1, rewards[1]
end

-- Gives one reward; returns what to show ("Golden Treasure Turtle", "x2 Luck pass!").
local function give(player: Player, reward: any): string
	local name = Config.ChestRewardName(reward)
	if reward.Kind == "Bubbles" then
		DataService.AddBubbles(player, reward.Amount, "Chest")
	elseif reward.Kind == "Gems" then
		DataService.AddGems(player, reward.Amount)
	elseif reward.Kind == "Boost" then
		DataService.AddBoost(player, reward.Minutes * 60)
	elseif reward.Kind == "Pet" then
		local ok = petService().GivePet(player, reward.Pet, reward.Tier)
		if not ok then
			-- Inventory full: the pet's worth in Gems instead, so nothing is lost.
			local gems = if reward.Tier and reward.Tier > 1 then 250 elseif Config.Pets[reward.Pet].Rarity == "Legendary" then 150 else 60
			DataService.AddGems(player, gems)
			name = string.format("%s (bag full: %d Gems)", name, gems)
		end
	elseif reward.Kind == "Pass" then
		local free = {}
		for _, pass in Config.GamePasses do
			if not giftService().Owns(player, pass.Key) then
				table.insert(free, pass)
			end
		end
		if #free > 0 then
			local pass = free[rng:NextInteger(1, #free)]
			giftService().GrantPass(player, pass.Key, "JACKPOT!", "The Treasure Chest had " .. pass.Name .. " inside!")
			name = pass.Name .. " pass!"
		else
			DataService.AddGems(player, reward.Fallback or 150)
			name = string.format("%d Gems (you own every pass!)", reward.Fallback or 150)
		end
	end
	return name
end

-- Opens `count` chests for this player. Never yields.
function EventService.Open(player: Player, count: number): { { Index: number, Text: string } }
	local results = {}
	for _ = 1, count do
		local index, reward = pick()
		local ok, text = pcall(give, player, reward)
		table.insert(results, { Index = index, Text = if ok then text else Config.ChestRewardName(reward) })
		if not ok then
			warn("[EventService] chest reward failed: " .. tostring(text))
		end
	end
	DataService.CountChests(player, count)
	return results
end

local function testAllowed(): boolean
	local rules: any = Config.TestPasses or {}
	return if RunService:IsStudio() then rules.AllowInStudio == true else rules.AllowInLiveGame == true
end

local function onRequest(player: Player, action: any, value: any): any
	local now = os.clock()
	if now - (lastRequest[player] or 0) < 0.5 then
		return { Ok = false, Error = "Slow down a little!" }
	end
	lastRequest[player] = now
	if not DataService.Get(player) then
		return { Ok = false, Error = "Your save is still loading." }
	end
	if action == "Free" then
		if not DataService.UseFreeChest(player) then
			return { Ok = false, Error = if Config.ChestEventLive() then "You've opened your free chest!" else "The event has ended." }
		end
		return { Ok = true, Rewards = EventService.Open(player, 1) }
	elseif action == "Test" then
		-- A pack without a product Id: free in Studio, so the buttons can be tried.
		for _, pack in Config.ChestEvent.Packs do
			if pack.Count == value then
				local id = Config.EventProducts[pack.Key]
				if type(id) == "number" and id > 0 then
					return { Ok = false, Error = "This is on sale for real. Use the purchase prompt!" }
				end
				if not testAllowed() then
					return { Ok = false, Error = "Coming soon!" }
				end
				return { Ok = true, Rewards = EventService.Open(player, pack.Count) }
			end
		end
	end
	return { Ok = false, Error = "Unknown request." }
end

function EventService.Init()
	if initialized then
		return
	end
	initialized = true
	Remotes.Function("ChestRequest").OnServerInvoke = onRequest
	local resultRemote = Remotes.Event("ChestResult")
	for _, pack in Config.ChestEvent.Packs do
		MarketService.RegisterProduct(Config.EventProducts[pack.Key], function(player)
			if not DataService.Get(player) then
				error("profile not loaded")
			end
			-- Bought: always opens, even if the event ended while the prompt was up.
			local results = EventService.Open(player, pack.Count)
			if player.Parent == Players then
				resultRemote:FireClient(player, results)
			end
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastRequest[player] = nil
	end)
end

function EventService.Start() end

return EventService
