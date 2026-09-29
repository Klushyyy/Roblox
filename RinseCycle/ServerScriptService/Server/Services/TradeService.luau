--[[
	TradeService - pet trading between two players, in the lobby only.

	  1. "Request" (userId): asks another player in the lobby to trade. They get an invite with
	     Accept / Decline (it expires after INVITE_TTL).
	  2. "Accept" (fromUserId) opens the trade for both. Each side adds / removes its own pets
	     ("Add" / "Remove" uid, up to MAX_OFFER each).
	  3. Both press "Ready". Any change to either offer un-readies both. When both are ready a short
	     countdown runs (CONFIRM_SECONDS) so nobody can be tricked by a last-second swap; then
	     PetService.Transfer swaps the pets in one step and both saves are written.
	  4. "Cancel", leaving, dying, joining a party, or starting a run ends the trade.

	Everything is checked on the server: a client can only offer pets it really owns, and the
	offers are re-checked at the moment of the swap.

	TradeState (S->C) is either nil (no trade), a TradeState table, or ("Invite", { UserId, Name }).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Util = require(Shared:WaitForChild("Util"))

local DataService = require(script.Parent:WaitForChild("DataService"))
local RoundService = require(script.Parent:WaitForChild("RoundService"))
local PetService = require(script.Parent:WaitForChild("PetService"))

local TradeService = {}

local INVITE_TTL = 30
local REQUEST_COOLDOWN = 3
local MAX_OFFER = 8
local CONFIRM_SECONDS = 4
local ACTIONS_PER_SECOND = 10
local CHECK_INTERVAL = 0.5

type Trade = {
	A: Player,
	B: Player,
	Offer: { [Player]: { string } },
	Ready: { [Player]: boolean },
	ConfirmAt: number?, -- Util.Now() when the swap happens (both ready)
	Version: number, -- bumps on every change, so a pending countdown knows it's stale
	Done: boolean,
}

local tradeOf: { [Player]: Trade } = {}
local invites: { [Player]: { [number]: number } } = {} -- invites[target][fromUserId] = os.clock() sent
local lastRequest: { [Player]: number } = {}
local actionWindow: { [Player]: { Start: number, Count: number } } = {}

local stateRemote: RemoteEvent
local notifyRemote: RemoteEvent

local function isHere(player: Player): boolean
	return player.Parent == Players
end

local function notify(player: Player, text: string, kind: string?)
	if isHere(player) then
		notifyRemote:FireClient(player, text, kind or "Info")
	end
end

-- Trading is for the lobby: not in a run, a party, a teleport, or a run server.
local function canTrade(player: Player): (boolean, string?)
	if not isHere(player) then
		return false, "They left."
	end
	if Workspace:GetAttribute("RunServer") then
		return false, "Trading is only in the lobby."
	end
	local ok, inRun = pcall(RoundService.IsInRun, player)
	if ok and inRun then
		return false, "Trading is only in the lobby."
	end
	if player:GetAttribute("InParty") == true or player:GetAttribute("Teleporting") == true then
		return false, "Trading is only in the lobby."
	end
	if not DataService.Get(player) then
		return false, "Still loading, try again in a moment."
	end
	return true, nil
end

local function allowAction(player: Player): boolean
	local now = os.clock()
	local w = actionWindow[player]
	if not w or now - w.Start >= 1 then
		w = { Start = now, Count = 0 }
		actionWindow[player] = w
	end
	w.Count += 1
	return w.Count <= ACTIONS_PER_SECOND
end

local function other(trade: Trade, player: Player): Player
	return if trade.A == player then trade.B else trade.A
end

-- The pets behind a list of uids, as the client draws them.
local function describe(owner: Player, uids: { string }): { any }
	local profile = DataService.Get(owner) :: any
	local out = {}
	if not profile then
		return out
	end
	for _, uid in uids do
		for _, pet in profile.Pets do
			if pet.Uid == uid then
				table.insert(out, { Uid = pet.Uid, Id = pet.Id, Tier = pet.Tier })
				break
			end
		end
	end
	return out
end

local function push(trade: Trade)
	for _, p in { trade.A, trade.B } do
		if isHere(p) then
			local partner = other(trade, p)
			stateRemote:FireClient(p, {
				Partner = { UserId = partner.UserId, Name = partner.DisplayName },
				Mine = describe(p, trade.Offer[p]),
				Theirs = describe(partner, trade.Offer[partner]),
				MyReady = trade.Ready[p] == true,
				TheirReady = trade.Ready[partner] == true,
				ConfirmAt = trade.ConfirmAt,
				MaxOffer = MAX_OFFER,
			})
		end
	end
end

local function finish(trade: Trade, message: string?, kind: string?)
	if trade.Done then
		return
	end
	trade.Done = true
	for _, p in { trade.A, trade.B } do
		if tradeOf[p] == trade then
			tradeOf[p] = nil
		end
		if isHere(p) then
			stateRemote:FireClient(p, nil)
			if message then
				notify(p, message, kind)
			end
		end
	end
end

local function changed(trade: Trade)
	trade.Version += 1
	trade.Ready[trade.A] = false
	trade.Ready[trade.B] = false
	trade.ConfirmAt = nil
	push(trade)
end

local function execute(trade: Trade)
	local a, b = trade.A, trade.B
	for _, p in { a, b } do
		local ok, why = canTrade(p)
		if not ok then
			finish(trade, "Trade cancelled: " .. (why or "someone can't trade right now."), "Bad")
			return
		end
	end
	local ok, err = PetService.Transfer(a, b, trade.Offer[a], trade.Offer[b])
	if not ok then
		-- Nothing moved. Back to the offers, un-readied.
		notify(a, err or "The trade didn't go through.", "Bad")
		notify(b, err or "The trade didn't go through.", "Bad")
		changed(trade)
		return
	end
	finish(trade, "Trade complete!", "Good")
	for _, p in { a, b } do
		task.spawn(function()
			pcall(DataService.Save, p)
		end)
	end
end

local function checkReady(trade: Trade)
	if not (trade.Ready[trade.A] and trade.Ready[trade.B]) then
		trade.ConfirmAt = nil
		push(trade)
		return
	end
	if #trade.Offer[trade.A] == 0 and #trade.Offer[trade.B] == 0 then
		trade.Ready[trade.A], trade.Ready[trade.B] = false, false
		push(trade)
		return
	end
	trade.ConfirmAt = Util.Now() + CONFIRM_SECONDS
	local version = trade.Version
	push(trade)
	task.delay(CONFIRM_SECONDS, function()
		if not trade.Done and trade.Version == version and trade.Ready[trade.A] and trade.Ready[trade.B] then
			execute(trade)
		end
	end)
end

local function startTrade(a: Player, b: Player)
	local trade: Trade = {
		A = a,
		B = b,
		Offer = { [a] = {}, [b] = {} },
		Ready = { [a] = false, [b] = false },
		ConfirmAt = nil,
		Version = 0,
		Done = false,
	}
	tradeOf[a], tradeOf[b] = trade, trade
	invites[a], invites[b] = nil, nil
	push(trade)
end

local function onAction(player: Player, action: any, value: any)
	if type(action) ~= "string" or not allowAction(player) then
		return
	end
	local trade = tradeOf[player]

	if action == "Request" then
		if trade then
			return
		end
		local target = type(value) == "number" and Players:GetPlayerByUserId(value) or nil
		if not target or target == player then
			return
		end
		local now = os.clock()
		if lastRequest[player] and now - lastRequest[player] < REQUEST_COOLDOWN then
			notify(player, "Wait a moment before sending another request.")
			return
		end
		local ok, why = canTrade(player)
		if not ok then
			notify(player, why or "You can't trade right now.", "Bad")
			return
		end
		ok, why = canTrade(target)
		if not ok or tradeOf[target] then
			notify(player, target.DisplayName .. " can't trade right now.", "Bad")
			return
		end
		lastRequest[player] = now
		local list = invites[target] or {}
		invites[target] = list
		list[player.UserId] = now
		stateRemote:FireClient(target, "Invite", { UserId = player.UserId, Name = player.DisplayName })
		notify(player, "Trade request sent to " .. target.DisplayName .. "!", "Good")
		return
	end

	if action == "Accept" or action == "Decline" then
		if trade or type(value) ~= "number" then
			return
		end
		local list = invites[player]
		local sentAt = list and list[value]
		if list then
			list[value] = nil
		end
		local from = Players:GetPlayerByUserId(value)
		if not sentAt or os.clock() - sentAt > INVITE_TTL or not from then
			if action == "Accept" then
				notify(player, "That trade request expired.")
			end
			return
		end
		if action == "Decline" then
			notify(from, player.DisplayName .. " declined your trade.")
			return
		end
		if tradeOf[from] then
			notify(player, from.DisplayName .. " is already trading.", "Bad")
			return
		end
		for _, p in { player, from } do
			local ok, why = canTrade(p)
			if not ok then
				notify(player, why or "You can't trade right now.", "Bad")
				return
			end
		end
		startTrade(from, player)
		return
	end

	if not trade or trade.Done then
		return
	end
	if action == "Cancel" then
		local partner = other(trade, player)
		finish(trade, nil)
		notify(player, "Trade cancelled.")
		notify(partner, player.DisplayName .. " cancelled the trade.")
	elseif action == "Add" then
		local offer = trade.Offer[player]
		if type(value) ~= "string" or table.find(offer, value) or #offer >= MAX_OFFER then
			return
		end
		local profile = DataService.Get(player) :: any
		local owns = false
		for _, pet in (profile and profile.Pets or {}) do
			if pet.Uid == value then
				owns = true
				break
			end
		end
		if owns then
			table.insert(offer, value)
			changed(trade)
		end
	elseif action == "Remove" then
		local offer = trade.Offer[player]
		local i = type(value) == "string" and table.find(offer, value)
		if i then
			table.remove(offer, i)
			changed(trade)
		end
	elseif action == "Ready" then
		trade.Ready[player] = value == true
		if not trade.Ready[player] then
			trade.Version += 1 -- stops a countdown in progress
		end
		checkReady(trade)
	end
end

function TradeService.IsTrading(player: Player): boolean
	return tradeOf[player] ~= nil
end

function TradeService.Init()
	stateRemote = Remotes.Event("TradeState")
	notifyRemote = Remotes.Event("Notify")
	Remotes.Event("TradeAction").OnServerEvent:Connect(onAction)
	Players.PlayerRemoving:Connect(function(player)
		local trade = tradeOf[player]
		if trade then
			local partner = other(trade, player)
			finish(trade, nil)
			notify(partner, player.DisplayName .. " left, so the trade was cancelled.", "Bad")
		end
		invites[player] = nil
		lastRequest[player] = nil
		actionWindow[player] = nil
	end)
end

function TradeService.Start()
	-- A trade ends as soon as either side stops being free to trade (party, run, died...).
	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			local seen: { [Trade]: boolean } = {}
			for _, trade in tradeOf do
				if seen[trade] or trade.Done then
					continue
				end
				seen[trade] = true
				for _, p in { trade.A, trade.B } do
					local ok = canTrade(p)
					if not ok then
						finish(trade, "Trade cancelled: trading is only in the lobby.", "Bad")
						break
					end
				end
			end
		end
	end)
end

return TradeService
