-- MarketService: Robux purchases.
--
-- Game passes (Config.GamePasses, only entries with Id ~= 0):
--   * When a profile loads, ownership is checked with UserOwnsGamePassAsync and recorded with
--     DataService.SetPass. Passes are runtime-only and re-checked every session.
--   * PromptGamePassPurchaseFinished grants a pass the moment it's bought.
--   * DataService.SetPass fires DataService.PassesChanged, which RoundService (run stats) and
--     PetService (slot count) listen to. We can't call RoundService from here: it requires
--     DataService, and MarketService may only require DataService.
--
-- Developer products (Config.DevProducts, entries with Id ~= 0): Bubbles, Gems and in-run Coins packs.
-- MarketService.GrantProduct gives the goods; ShopService also uses it for Studio test purchases.
-- ProcessReceipt implements the idempotent pattern:
--   1. unknown product / player not here / save not writable  -> NotProcessedYet (Roblox retries)
--   2. PurchaseId already in profile.Receipts (and saved)      -> PurchaseGranted, grant nothing
--   3. otherwise grant, append PurchaseId to Receipts, save now; PurchaseGranted only once saved

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local DataService = require(script.Parent:WaitForChild("DataService"))
local RoundService = require(script.Parent:WaitForChild("RoundService"))

local MarketService = {}

local OWNERSHIP_ATTEMPTS = 3
local RECHECK_DELAY = 60 -- a pass check that failed completely is tried once more after this long
local RECEIPT_PROFILE_WAIT = 20
local MAX_RECEIPTS = 50

type Receipt = {
	PlayerId: number,
	ProductId: number,
	PurchaseId: string,
	CurrencySpent: number?,
	PlaceIdWherePurchased: number?,
}

-- ProductId -> grant(player, profile, receipt). The grant edits the profile (or calls DataService
-- helpers) and must not yield; if it throws, nothing is recorded and Roblox retries later.
-- Example shape for a future product (never Bubbles, see DESIGN.md section 7):
--   [1234567890] = function(player, profile, receipt)
--       -- give the item here
--   end,
local PRODUCTS: { [number]: (Player, any, Receipt) -> () } = {}

-- Gives a developer product's goods. Never yields. Coins only make sense inside a run; bought
-- anywhere else (e.g. the run ended while the prompt was open) they turn into Bubbles instead.
function MarketService.GrantProduct(player: Player, product: any): boolean
	if type(product) ~= "table" or type(product.Amount) ~= "number" then
		return false
	end
	if product.Kind == "Bubbles" then
		return DataService.AddBubbles(player, product.Amount, "Product")
	elseif product.Kind == "Gems" then
		return DataService.AddGems(player, product.Amount)
	elseif product.Kind == "RestoreStreak" then
		return DataService.RestoreStreak(player)
	elseif product.Kind == "Coins" then
		if RoundService.AddCoins(player, product.Amount) then
			return true
		end
		return DataService.AddBubbles(player, math.floor(product.Amount / 2), "ProductCoinsFallback")
	end
	return false
end

for _, product in Config.DevProducts or {} do
	if type(product.Id) == "number" and product.Id ~= 0 then
		PRODUCTS[product.Id] = function(player: Player, _profile: any, _receipt: Receipt)
			if not MarketService.GrantProduct(player, product) then
				error("grant failed")
			end
		end
	end
end

local checked: { [Player]: boolean } = {}
local boughtThisSession: { [Player]: { [string]: boolean } } = {} -- never downgraded by a stale check
local processing: { [string]: boolean } = {} -- PurchaseIds being granted right now
local unsavedReceipts: { [Player]: { [string]: boolean } } = {} -- granted in memory, save not landed yet

local notifyRemote: RemoteEvent
local initialized = false

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local function isHere(player: Player): boolean
	return player.Parent == Players
end

local function notify(player: Player, text: string, kind: string)
	if isHere(player) then
		notifyRemote:FireClient(player, text, kind)
	end
end

-- Passes that are actually on sale (a real Id was pasted into Config).
local function livePasses()
	local list = {}
	for _, pass in Config.GamePasses do
		if type(pass.Id) == "number" and pass.Id > 0 then
			table.insert(list, pass)
		end
	end
	return list
end

local function passById(passId: number)
	if type(passId) ~= "number" or passId <= 0 then
		return nil
	end
	for _, pass in Config.GamePasses do
		if pass.Id == passId then
			return pass
		end
	end
	return nil
end

-- true / false when Roblox answered, nil when every attempt failed (or the player left).
local function ownsPass(player: Player, passId: number): boolean?
	for attempt = 1, OWNERSHIP_ATTEMPTS do
		local ok, result = pcall(function()
			return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
		end)
		if ok then
			return result == true
		end
		if not isHere(player) then
			return nil
		end
		if attempt < OWNERSHIP_ATTEMPTS then
			task.wait(attempt)
		else
			warn(string.format("[MarketService] ownership check for pass %d failed: %s", passId, tostring(result)))
		end
	end
	return nil
end

local function checkPasses(player: Player, isRetry: boolean)
	local passes = livePasses()
	if #passes == 0 then
		return
	end
	local failed = false
	for _, pass in passes do
		if not isHere(player) then
			return
		end
		local owned = ownsPass(player, pass.Id)
		if not isHere(player) then
			return
		end
		if owned == nil then
			failed = true
		else
			-- A purchase that landed while this check was in flight wins over a cached "not owned".
			local bought = boughtThisSession[player]
			if owned or not (bought and bought[pass.Key]) then
				DataService.SetPass(player, pass.Key, owned)
			end
		end
	end
	DataService.PushMeta(player)
	if failed and not isRetry then
		task.delay(RECHECK_DELAY, function()
			if isHere(player) and checked[player] then
				checkPasses(player, true)
			end
		end)
	end
end

local function onProfileLoaded(player: Player)
	if checked[player] or not isHere(player) then
		return
	end
	checked[player] = true
	checkPasses(player, false)
end

local function onPassPurchaseFinished(player: Player, passId: number, wasPurchased: boolean)
	if not wasPurchased or not isHere(player) then
		return
	end
	local pass = passById(passId)
	if not pass then
		return
	end
	local bought = boughtThisSession[player]
	if not bought then
		bought = {}
		boughtThisSession[player] = bought
	end
	bought[pass.Key] = true
	DataService.SetPass(player, pass.Key, true)
	DataService.PushMeta(player)
	notify(player, "Thanks! " .. pass.Icon .. " " .. pass.Name .. " unlocked", "Good")
end

----------------------------------------------------------------------------------------------------
-- Developer products
----------------------------------------------------------------------------------------------------

local function markUnsaved(player: Player, purchaseId: string, unsaved: boolean)
	local set = unsavedReceipts[player]
	if unsaved then
		if not set then
			set = {}
			unsavedReceipts[player] = set
		end
		set[purchaseId] = true
	elseif set then
		set[purchaseId] = nil
	end
end

local function grantReceipt(receipt: Receipt, purchaseId: string): Enum.ProductPurchaseDecision
	local grant = PRODUCTS[receipt.ProductId]
	if not grant then
		warn("[MarketService] receipt for unknown product " .. tostring(receipt.ProductId))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player then
		return Enum.ProductPurchaseDecision.NotProcessedYet -- granted next time they join
	end
	local profile = DataService.WaitFor(player, RECEIPT_PROFILE_WAIT)
	if not profile or not isHere(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local offline = DataService.IsOffline()
	if not isHere(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if not offline and not DataService.CanSave(player) then
		-- A temporary (unloaded) profile: granting here would vanish. Wait for a session that saves.
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	local receipts = profile.Receipts
	local pending = unsavedReceipts[player]
	if table.find(receipts, purchaseId) then
		if not (pending and pending[purchaseId]) then
			return Enum.ProductPurchaseDecision.PurchaseGranted -- granted and saved before
		end
		-- Granted earlier this session but the save didn't land yet: just try saving again below.
	else
		local ok, err = pcall(grant, player, profile, receipt)
		if not ok then
			warn("[MarketService] grant failed for product " .. tostring(receipt.ProductId) .. ": " .. tostring(err))
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		table.insert(receipts, purchaseId)
		while #receipts > MAX_RECEIPTS do
			table.remove(receipts, 1)
		end
		markUnsaved(player, purchaseId, true)
		DataService.PushMeta(player)
	end

	if offline or DataService.Save(player) then
		markUnsaved(player, purchaseId, false)
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	-- The grant and its receipt are in memory; the retry only needs to save. If this server dies
	-- first, both are lost together and the purchase is granted again elsewhere.
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function processReceipt(receiptInfo: { [string]: any }): Enum.ProductPurchaseDecision
	local receipt = receiptInfo :: any
	if type(receipt) ~= "table" or receipt.PurchaseId == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local purchaseId = tostring(receipt.PurchaseId)
	-- Roblox can deliver the same receipt twice at once; only one grant may run.
	if processing[purchaseId] then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	processing[purchaseId] = true
	local ok, decision = pcall(grantReceipt, receipt, purchaseId)
	processing[purchaseId] = nil
	if not ok then
		warn("[MarketService] ProcessReceipt error: " .. tostring(decision))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return decision
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

function MarketService.Init()
	if initialized then
		return
	end
	initialized = true
	notifyRemote = Remotes.Event("Notify")

	DataService.ProfileLoaded:Connect(onProfileLoaded)
	-- Profiles that loaded before we subscribed.
	for _, player in Players:GetPlayers() do
		if DataService.Get(player) then
			task.spawn(onProfileLoaded, player)
		end
	end

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPurchaseFinished)
	MarketplaceService.ProcessReceipt = processReceipt

	Players.PlayerRemoving:Connect(function(player)
		checked[player] = nil
		boughtThisSession[player] = nil
		unsavedReceipts[player] = nil
	end)
end

function MarketService.Start()
	-- Nothing to loop: everything here is event driven.
end

return MarketService
