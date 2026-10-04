--!nocheck
-- AdminServer (Script, ServerScriptService.Admin) - Rinse Cycle's admin commands.
--
-- Ported from the owner's admin system for another game: the moderation commands (kick/mute/
-- tempmute/warn/msg/goto/ban/tempban/freeze/unfreeze/bring/warnlist/banlist/mutelist/announce/
-- cmdlogs/playerlogs/kill/jail/god/respawn/spectate/controlplayer/invis/viewinv/clearinv/fly/give)
-- are kept as they were. The game-specific ones were swapped for Rinse Cycle's:
--   :setrank/:promote/:demote   -> our rolled Ranks (Config.Ranks)
--   :setpoints                  -> :setbubbles / :setgems
--   :givegamepass/:removegamepass -> our game passes (Config.GamePasses), honoured by DataService
--   :daily                      -> our 24-hour daily reward streak
--   :dirtycinema/:cleancinema   -> :finishrun (cleans a player's whole dishwasher)
--   :training/:resettraining    -> :givecoins, :givepet, :unlockall, :setrebirths
--
-- ONLY THE OWNER can use any of it: in a live server the one account allowed is
-- Config.Social.CreatorUserId (by UserId, which Roblox guarantees is unique). Nobody else gets a
-- panel, a command list, or even an "unknown command" hint that anything exists. In Studio every
-- tester counts as the owner (your own machine, your own place file).
--
-- Permission checks are always re-verified here - never trusted from the client.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local TextChatService = game:GetService("TextChatService")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService") -- swings the jail cell door
local ServerScriptService = game:GetService("ServerScriptService")

-- Rinse Cycle's own services (shared module instances with the rest of the server).
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Remotes"))
local GameServices = ServerScriptService:WaitForChild("Server"):WaitForChild("Services")
local DataService = require(GameServices:WaitForChild("DataService"))
local RoundService = require(GameServices:WaitForChild("RoundService"))
local PetService = require(GameServices:WaitForChild("PetService"))
local LeaderboardService = require(GameServices:WaitForChild("LeaderboardService"))
local RunServers = require(GameServices:WaitForChild("RunServers"))
local MessagingService = game:GetService("MessagingService")
local TeleportService = game:GetService("TeleportService")

-- The big "congrats" popup with confetti (Celebrate on the client).
local function celebrate(player, title, text, icon)
	pcall(function()
		Remotes.Event("Celebrate"):FireClient(player, title, text, icon)
	end)
end

-- Quiet by default: the Output window only gets one "ready" line and real problems. Set VERBOSE
-- to true to see every step and every command in the Output window again.
local VERBOSE = false
local function log(...)
	if VERBOSE then
		print(...)
	end
end
-- True when DataStores can't be used at all (Studio without a published place / API access): every
-- save and load then fails the same way, so those failures stay silent instead of filling Output.
local storesOffline = false
local function dsWarn(message)
	local text = tostring(message)
	if text:find("StudioAccessToApisNotAllowed", 1, true) or text:find("publish", 1, true) or text:find("API Services", 1, true) then
		storesOffline = true
	end
	if not storesOffline then
		warn(text)
	end
end

-- :give (hand out Tools from a ServerStorage folder) isn't used in Rinse Cycle and was removed;
-- this empty stand-in keeps the leftover inventory helpers below working.
local giveableItemsFolder = Instance.new("Folder")

-- The one account allowed to use the admin system in a live server: EnderBuilda (display name
-- Klushy). Matched by UserId, with the username as a backup in case the id in Config changes.
local OWNER_USER_ID = Config.Social.CreatorUserId
local OWNER_USERNAME = "enderbuilda"

local function isOwnerAccount(player)
	return player.UserId == OWNER_USER_ID or string.lower(player.Name) == OWNER_USERNAME
end

-- GetDataStore throws in Studio when the place isn't published or "Enable Studio Access to API
-- Services" is off. A throw here used to stop this whole script before its remotes existed, so the
-- panel never appeared. A failed lookup now hands back a stand-in whose calls fail like a DataStore
-- outage; every caller already pcalls and carries on without saving.
local function getStore(name)
	local ok, store = pcall(function()
		return DataStoreService:GetDataStore(name)
	end)
	if ok and store then
		return store
	end
	storesOffline = true
	local function unavailable()
		error("DataStore unavailable", 2)
	end
	return {
		GetAsync = unavailable,
		SetAsync = unavailable,
		UpdateAsync = unavailable,
		RemoveAsync = unavailable,
		ListKeysAsync = unavailable,
	}
end

local ALL_COMMANDS = {
	"kick", "mute", "tempmute", "warn", "msg", "goto", "ban", "tempban",
	"freeze", "unfreeze", "bring", "warnlist", "banlist", "mutelist",
	"setrank", "promote", "demote", "announce", "cmdlogs", "playerlogs",
	"kill", "jail", "god", "respawn",
	"spectate", "controlplayer", "invis",
	"viewpets", "givepet",
	"fly", "noclip", "giant",
	"leaderboards", "globalannounce", "joinserver", "bringserver", "serverlist",
	"globalpoll",
}

-- =====================================================================
-- Studio-only testing commands
-- =====================================================================
-- These are NOT in ALL_COMMANDS, on purpose. Outside Studio they are not
-- registered as commands at all, so the server answers "Unknown command"
-- exactly as it would for a typo - it never admits they exist. They're
-- also never included in the command list sent to anyone who isn't the
-- owner, so their panel has no category to draw and nothing to
-- autocomplete. There is nothing for them to find in a live game.
--
-- Every one of them either manufactures currency, rewrites your own
-- permissions, or erases an audit trail. Any of those reaching an
-- ordinary player would be worse than a bug, which is why the gate is
-- "Studio, or you are the owner account" rather than "you are senior
-- enough" - a Developer or a Founder still gets nothing.
-- Nothing is hidden behind Studio any more: every command belongs to a staff tier (below), and
-- the owner-only ones (staff ranks, gifted passes, wiping the log) are only on the owner's list.
local STUDIO_ONLY_COMMANDS = { "abuseshow" }

-- Commands FOUNDER alone gets, on top of everything Developer has.
--
-- Founder and Developer otherwise share one list (both are ALL_COMMANDS
-- below), so a genuinely Founder-only command needs its own. :setbubbles and
-- :setgems hand out the game's currencies - that's not
-- a Studio tool, it's a live one, but it's also not something a
-- Developer should be able to do on a whim.
-- Developer: everything on ALL_COMMANDS plus these game tools.
local FOUNDER_ONLY_COMMANDS = { "setbubbles", "setgems", "daily", "finishrun", "givecoins", "unlockall", "setrebirths" }

local STUDIO_ONLY_SET = {}
for _, name in ipairs(STUDIO_ONLY_COMMANDS) do
	STUDIO_ONLY_SET[name] = true
end

-- Gated on Studio ALONE, deliberately - not on tier as well.
--
-- Tier-gating these was a trap: :setadminrank is one of them, so setting
-- yourself to Moderator with it immediately dropped you below the bar
-- and every Studio command - including the one that would put you back -
-- became "unknown". The tool locked you out the first time you used it.
--
-- Studio is your own machine running your own place file, where anyone
-- present can edit the scripts outright, so tier adds no protection here
-- worth that failure mode. In a live server none of these exist at all,
-- which is the check that actually matters.
-- Forward-declared, assigned just below isOwner further down this file.
--
-- A bare declaration then an assignment, NOT a second `local function`
-- down there: re-declaring would create a new local, and the closure
-- below would keep the nil it captured here. Same trap that has bitten
-- this file before.
local ownerCheck

-- Studio, OR the owner account in a live server.
--
-- Not tier-gated, deliberately. :setadminrank is one of these, so setting
-- yourself to Moderator with it immediately dropped you below any tier
-- bar and every command here - including the one that would put you back
-- - became "unknown". The tool locked you out the first time you used it.
--
-- Studio is your own machine running your own place file, where anyone
-- present can edit the scripts outright, so tier adds no protection there
-- worth that failure mode. In a live server the username is the check
-- that matters, and it is the one thing Roblox guarantees is unique - a
-- display name isn't, and a tier is something an exploited remote could
-- try to talk its way into.
--
-- Anyone who is not the owner still gets no trace of these at all: they
-- are absent from the command list the panel is built from, so there is
-- nothing to render, nothing to autocomplete, and running one by hand
-- reports "Unknown command" rather than a refusal.
local function canUseStudioCommands(player)
	if RunService:IsStudio() then return true end
	return ownerCheck ~= nil and ownerCheck(player) == true
end

-- The staff ranks the owner can hand out with :setadminrank ("Founder" is the owner alone).
local STUDIO_TIER_VALUES = { "Moderator", "Admin", "Developer" }
-- Admin: every Punish command, plus the Move ones except pulling people (Bring, Bring any server)
-- and Control Player.
local ADMIN_TIER_COMMANDS = {
	"kick", "mute", "tempmute", "warn", "ban", "tempban", "warnlist", "banlist", "mutelist",
	"goto", "joinserver", "spectate", "serverlist",
}
local TIER_COMMANDS = {
	-- Moderator: the Punish commands except banning.
	Moderator = { "kick", "mute", "tempmute", "warn", "warnlist", "mutelist" },
	Admin = ADMIN_TIER_COMMANDS,
	-- Developer: every command, except the owner's own (staff ranks, gifted passes, wiping logs).
	Developer = (function()
		local list = table.clone(ALL_COMMANDS)
		for _, name in ipairs(FOUNDER_ONLY_COMMANDS) do
			table.insert(list, name)
		end
		return list
	end)(),
	-- The owner: everything.
	Founder = (function()
		local list = table.clone(ALL_COMMANDS)
		for _, name in ipairs(FOUNDER_ONLY_COMMANDS) do
			table.insert(list, name)
		end
		for _, name in ipairs({ "setadminrank", "stafflist", "wipelogs", "givegamepass", "removegamepass", "globalgive", "globalpassdrop", "globalboost", "globalcountdown", "cancelcountdown" }) do
			table.insert(list, name)
		end
		return list
	end)(),
}

-- Built from Founder's list, which is the superset - this set only
-- answers "is this a real command at all", and a Founder-only command
-- still has to be real for everyone, or the permission check below never
-- gets a chance to give a lower tier the proper refusal.
local ALL_COMMANDS_SET = {}
for _, name in ipairs(TIER_COMMANDS.Founder) do
	ALL_COMMANDS_SET[name] = true
end

-- =====================================================================
-- Staff ranks (Moderator / Admin / Developer), given by the owner with :setadminrank.
-- Saved in one DataStore record (userId -> { Tier, Name }), so they last, apply in every server,
-- and can be taken away while the person is offline (:stafflist). A change is broadcast to every
-- server (MessagingService), which applies it on the spot: no rejoin needed.
-- =====================================================================
local Staff = {
	Map = {} :: { [string]: { Tier: string, Name: string } },
	Store = getStore("RinseCycleStaffTiers"),
	Key = "staff",
	Topic = "RinseCycle_StaffChanged",
	-- Tag shown before the name (chat and overhead): text and colour per tier.
	Tags = { Moderator = "MOD", Admin = "ADMIN", Developer = "DEV", Founder = "OWNER" },
}

function Staff.Load()
	local ok, value = pcall(function()
		return Staff.Store:GetAsync(Staff.Key)
	end)
	if ok then
		Staff.Map = if type(value) == "table" then value else {}
	end
	return ok
end

-- Sets (tier) or clears (nil) a user's staff rank in the saved record. Returns true once saved.
function Staff.Save(userId, tier, name)
	local newMap
	local ok, err = pcall(function()
		Staff.Store:UpdateAsync(Staff.Key, function(old)
			local map = if type(old) == "table" then old else {}
			map[tostring(userId)] = if tier then { Tier = tier, Name = name } else nil
			newMap = map
			return map
		end)
	end)
	if ok and newMap then
		Staff.Map = newMap
	elseif not ok then
		-- DataStores unavailable (Studio without API access): keep it for this session at least.
		dsWarn("[AdminServer] couldn't save staff rank: " .. tostring(err))
		Staff.Map[tostring(userId)] = if tier then { Tier = tier, Name = name } else nil
	end
	return ok
end

function Staff.TierOf(userId)
	local entry = Staff.Map[tostring(userId)]
	return if type(entry) == "table" and type(entry.Tier) == "string" then entry.Tier else nil
end

-- Every server of the game, for the admin's "All servers" list (filled in at the bottom).
local ServerList = {}
local GlobalEvents = { Commands = {} } -- the panel's Global tab (filled in near the bottom)

local function getPlayerTier(player)
	-- Studio-only testing override, set via Studio's Command Bar (View >
	-- Command Bar) while Play testing:
	--   game.Players.YourName:SetAttribute("AdminTierOverride", "Founder")
	-- Valid values are "Moderator", "Admin", "Developer", "Founder" - any
	-- other value (including a typo) is ignored and falls through to the
	-- real group-rank check below. RunService:IsStudio() is false in the
	-- published/live game, so this can never grant admin there no matter
	-- what an attribute is set to - it only exists inside Studio.
	if RunService:IsStudio() then
		local override = player:GetAttribute("AdminTierOverride")
		if override and TIER_COMMANDS[override] then
			return override
		end
	end

	-- The owner, by UserId; then anyone the owner made staff.
	if isOwnerAccount(player) then return "Founder" end
	local staffTier = Staff.TierOf(player.UserId)
	if staffTier and TIER_COMMANDS[staffTier] then return staffTier end
	-- In Studio every tester is treated as the owner - it's your own machine and place file.
	if RunService:IsStudio() then return "Founder" end
	return nil
end

local function tierHasCommand(tier, commandName)
	if not tier then return false end
	local commands = TIER_COMMANDS[tier]
	if not commands then return false end
	for _, name in ipairs(commands) do
		if name == commandName then return true end
	end
	return false
end

-- =====================================================================
-- Remotes
-- =====================================================================
-- Every RemoteEvent / RemoteFunction this script makes, in one table (Luau allows at most 200
-- top-level locals in a script, and this one is big).
local Remote = {}

Remote.GetAdminInfo = Instance.new("RemoteFunction")
Remote.GetAdminInfo.Name = "GetAdminInfo"
Remote.GetAdminInfo.Parent = ReplicatedStorage

-- Turns a technical Tool name (lowercase, no spaces - "glock17", "btools")
-- into a nicer autocomplete label ("Glock 17", "Btools") by inserting a
-- space before a trailing run of digits and before an internal capital
-- letter, then capitalizing the first letter of each resulting word. An
-- explicit DisplayName attribute on the Tool (set it directly in Studio)
-- always wins over the guess, for the rare name this can't get right on
-- its own (e.g. "noclip" guesses "Noclip", not "No Clip").
local function prettifyItemName(rawName)
	local spaced = rawName:gsub("(%a)(%d)", "%1 %2"):gsub("(%l)(%u)", "%1 %2")
	local words = {}
	for word in spaced:gmatch("%S+") do
		table.insert(words, word:sub(1, 1):upper() .. word:sub(2))
	end
	return table.concat(words, " ")
end

local function getItemDisplayName(item)
	local override = item:GetAttribute("DisplayName")
	if typeof(override) == "string" and override ~= "" then
		return override
	end
	return prettifyItemName(item.Name)
end

local function currentGiveableItemNames()
	local names = {}
	for _, item in ipairs(giveableItemsFolder:GetChildren()) do
		table.insert(names, getItemDisplayName(item))
	end
	table.sort(names)
	return names
end

-- Deleting an entry from the command log isn't a rank power - it's an
-- owner power. Every tier above Moderator can READ the log; exactly one
-- account can remove anything from it, because the whole point of an
-- audit trail is that the people it records can't edit it. Matched
-- case-insensitively against the username, which is what Roblox
-- guarantees is unique (a display name isn't).
local function isOwner(player)
	if player == nil then return false end
	if isOwnerAccount(player) then return true end

	-- Studio fallback. A Studio test client is very often NOT signed in
	-- under the owner's username - multi-client testing names its players
	-- "Player1", "Player2", and even a solo playtest can come up as
	-- something else depending on how the session was started - so the
	-- username check alone made this impossible to actually test. Studio
	-- is also not a place where the check is protecting anything: it's
	-- your own machine, running your own place file, and anyone there can
	-- already edit the scripts outright.
	--
	-- Gated on Founder rather than just "in Studio" so it still tracks
	-- who you've deliberately granted the top tier to via the
	-- AdminTierOverride attribute, instead of handing it to every test
	-- dummy in the session. Never applies in a live server, where the
	-- username is the only thing that counts.
	if RunService:IsStudio() and getPlayerTier(player) == "Founder" then
		return true
	end
	return false
end

-- Hands the real implementation to the forward declaration above, which
-- canUseStudioCommands closed over before isOwner existed.
ownerCheck = isOwner

-- =====================================================================
-- Gifted gamepasses
-- =====================================================================
-- :givegamepass and :removegamepass let the owner hand somebody a pass
-- without them paying for it, and take it back. Testing tool first and
-- foremost - checking what the shop, the passes and the x2 payouts
-- actually do for an owner is otherwise a real Robux purchase every time
-- - but it works in a live server too, so it doubles as a way to make
-- good on a failed purchase.
--
-- A grant never touches Roblox's own record - it cannot: the real entitlement lives on Roblox's
-- side and only a purchase changes it. This is the game choosing to treat someone as an owner.
local GamepassGrantStore = getStore("RinseCycleGamepassGrants")

-- Rinse Cycle's passes come straight from Config.GamePasses, matched by Key ("doublecoins"), by
-- name ("2x Coins") or by Id once one is pasted in. A grant is stored by Key (passes can still
-- have Id 0 while they're being set up) as a GP_<Key> attribute on the player, and handed to
-- DataService.SetPass so every system that reads passes honours it. MarketService keeps a gifted
-- pass on when Roblox says the player hasn't bought it.
local GAMEPASS_NAMES = {}
for _, pass in ipairs(Config.GamePasses) do
	table.insert(GAMEPASS_NAMES, string.lower(pass.Key))
end

local function gamepassAttribute(key)
	return "GP_" .. tostring(key)
end

-- Accepts a Key, a name or a raw Id. Returns the Config.GamePasses entry, or nil.
local function resolveGamepass(text)
	if typeof(text) ~= "string" then return nil end
	local cleaned = text:lower():gsub("[^%w]", "")
	local asNumber = tonumber(text)
	for _, pass in ipairs(Config.GamePasses) do
		if string.lower(pass.Key) == cleaned or (pass.Name:lower():gsub("[^%w]", "")) == cleaned
			or (asNumber and pass.Id ~= 0 and pass.Id == asNumber) then
			return pass
		end
	end
	return nil
end

local function grantKey(userId)
	return "grants_" .. tostring(userId)
end

-- Applies every gifted pass to the game's own pass table once the profile exists.
local function applyGrantsToGame(player)
	task.spawn(function()
		if not DataService.WaitFor(player, 30) then return end
		for name, value in pairs(player:GetAttributes()) do
			local key = name:match("^GP_(.+)$")
			if key and value == true then
				DataService.SetPass(player, key, true)
			end
		end
	end)
end

local function loadGamepassGrants(player)
	local ok, value = pcall(function()
		return GamepassGrantStore:GetAsync(grantKey(player.UserId))
	end)
	if not ok then
		dsWarn("[AdminServer] Failed to load gamepass grants for " .. player.Name .. ": " .. tostring(value))
		return
	end
	if type(value) ~= "table" then return end

	for _, key in ipairs(value) do
		if type(key) == "string" then
			player:SetAttribute(gamepassAttribute(key), true)
		end
	end
	applyGrantsToGame(player)
end

-- Rebuilt from the attributes rather than tracked separately, so the
-- saved record and what the game is actually honouring cannot drift.
local function saveGamepassGrants(player)
	local granted = {}
	for name, value in pairs(player:GetAttributes()) do
		local key = name:match("^GP_(.+)$")
		if key and value == true then
			table.insert(granted, key)
		end
	end

	task.spawn(function()
		local ok, err = pcall(function()
			GamepassGrantStore:SetAsync(grantKey(player.UserId), granted)
		end)
		if not ok then
			dsWarn("[AdminServer] Failed to save gamepass grants for " .. player.Name .. ": " .. tostring(err))
		end
	end)
end

local function setGamepassGrant(player, pass, granted, bought)
	player:SetAttribute(gamepassAttribute(pass.Key), granted or nil)
	saveGamepassGrants(player)
	DataService.SetPass(player, pass.Key, granted or bought == true)
end

Players.PlayerAdded:Connect(loadGamepassGrants)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(loadGamepassGrants, player)
end

-- CanRemoveLogs is sent to the client so the panel knows whether to draw
-- the Remove button at all. It's a display hint only - the server checks
-- isOwner again on the actual removal, since anything a client is told
-- is something a client can lie about.
local function tierInfo(tier, player)
	if not tier then return {Tier = nil, Commands = {}, GiveableItems = {}, CanRemoveLogs = false} end
	-- The Studio testing commands are appended to what the client is told
	-- exists, and ONLY in Studio. Outside it the client never receives
	-- these names, so it cannot render the category, cannot autocomplete
	-- them, and has no record that they exist - the panel is built
	-- entirely from this list.
	local commands = TIER_COMMANDS[tier]
	if canUseStudioCommands(player) then
		commands = table.clone(commands)
		for _, name in ipairs(STUDIO_ONLY_COMMANDS) do
			table.insert(commands, name)
		end
	end

	return {
		Tier = tier,
		Commands = commands,
		GiveableItems = currentGiveableItemNames(),
		CanRemoveLogs = isOwner(player),
	}
end

Remote.GetAdminInfo.OnServerInvoke = function(player)
	local info = tierInfo(getPlayerTier(player), player)
	-- Prints the name the server actually sees alongside the verdict, so
	-- a missing Remove button can be diagnosed from the Output window
	-- rather than guessed at - the usual cause is the test client not
	-- being signed in under the owner's username at all.
	log(string.format(
		"[AdminServer] Remote.GetAdminInfo for '%s' -> tier %s, canRemoveLogs %s",
		player.Name, tostring(info.Tier), tostring(info.CanRemoveLogs)
	))
	return info
end

Remote.AdminCommand = Instance.new("RemoteEvent")
Remote.AdminCommand.Name = "AdminCommand"
Remote.AdminCommand.Parent = ReplicatedStorage

-- Generic "notice" popup - covers the warn popup, the mute popup, and
-- the freeze popup, all rendered by the same one component client-side
-- (title + body + optional footnote line + an OK button) rather than
-- three near-identical UI builders.
Remote.AdminNotice = Instance.new("RemoteEvent")
Remote.AdminNotice.Name = "AdminNotice"
Remote.AdminNotice.Parent = ReplicatedStorage

Remote.AdminFeedback = Instance.new("RemoteEvent")
Remote.AdminFeedback.Name = "AdminFeedback"
Remote.AdminFeedback.Parent = ReplicatedStorage

-- Per-user warnings detail (list of individual warnings + a Remove
-- button per one) - reached either from :warnlist's master list
-- ("Modify" on a row fires Remote.AdminViewWarnings) or refreshed in place
-- after a removal.
Remote.AdminWarningsList = Instance.new("RemoteEvent")
Remote.AdminWarningsList.Name = "AdminWarningsList"
Remote.AdminWarningsList.Parent = ReplicatedStorage

Remote.AdminViewWarnings = Instance.new("RemoteEvent")
Remote.AdminViewWarnings.Name = "AdminViewWarnings"
Remote.AdminViewWarnings.Parent = ReplicatedStorage

Remote.AdminRemoveWarning = Instance.new("RemoteEvent")
Remote.AdminRemoveWarning.Name = "AdminRemoveWarning"
Remote.AdminRemoveWarning.Parent = ReplicatedStorage

-- Master lists (:banlist/:mutelist/:warnlist) - every user ever
-- punished, online or not, each row's "Modify" button opening either
-- the ban/mute detail-edit popup or (for warnlist) the per-user
-- warnings detail above.
Remote.AdminBanList = Instance.new("RemoteEvent")
Remote.AdminBanList.Name = "AdminBanList"
Remote.AdminBanList.Parent = ReplicatedStorage

Remote.AdminMuteList = Instance.new("RemoteEvent")
Remote.AdminMuteList.Name = "AdminMuteList"
Remote.AdminMuteList.Parent = ReplicatedStorage

Remote.AdminWarnList = Instance.new("RemoteEvent")
Remote.AdminWarnList.Name = "AdminWarnList"
Remote.AdminWarnList.Parent = ReplicatedStorage

-- Single unified remote for editing a ban or mute record - action is
-- "remove" (unban/unmute), "reason" (value = new reason string), or
-- "duration" (value = new duration in seconds, or nil for permanent).
-- One remote for both punishment types and all three actions, rather
-- than a growing pile of near-identical single-purpose ones.
Remote.AdminModifyPunishment = Instance.new("RemoteEvent")
Remote.AdminModifyPunishment.Name = "AdminModifyPunishment"
Remote.AdminModifyPunishment.Parent = ReplicatedStorage

-- Shared by :cmdlogs (every entry) and :playerlogs (filtered to one
-- admin) - same list popup component, just different title/entries.
Remote.AdminLogsList = Instance.new("RemoteEvent")
Remote.AdminLogsList.Name = "AdminLogsList"
Remote.AdminLogsList.Parent = ReplicatedStorage

-- The Pets view (:viewpets). S->C (targetUserId, title, rows); C->S ("Remove", targetUserId, uid)
-- / ("Add", targetUserId, petId, tier).
Remote.AdminPetList = Instance.new("RemoteEvent")
Remote.AdminPetList.Name = "AdminPetList"
Remote.AdminPetList.Parent = ReplicatedStorage
Remote.AdminPetAction = Instance.new("RemoteEvent")
Remote.AdminPetAction.Name = "AdminPetAction"
Remote.AdminPetAction.Parent = ReplicatedStorage
local sendPetList -- assigned at the bottom of this file

-- The Leaderboards view. C->S ("View", boardIndex) / ("Reset", boardIndex, userId);
-- S->C (boardIndex, boardCount, title, rows).
Remote.AdminLeaderboard = Instance.new("RemoteEvent")
Remote.AdminLeaderboard.Name = "AdminLeaderboard"
Remote.AdminLeaderboard.Parent = ReplicatedStorage

-- Tells one client to black its screen out and fade back in. Fired at a
-- player the server is teleporting a long way without them asking for it
-- (:jail and the release from it), so the teleport itself and the
-- lighting rebuild that follows it both happen behind a cover rather
-- than on screen. AdminClient.lua's Remote.AdminScreenFade handler has the
-- full reasoning.
Remote.AdminScreenFade = Instance.new("RemoteEvent")
Remote.AdminScreenFade.Name = "AdminScreenFade"
Remote.AdminScreenFade.Parent = ReplicatedStorage

-- Owner-only deletion of a single command-log entry, fired from the log
-- detail popup. See isOwner above for why this isn't tier-gated.
Remote.AdminRemoveLogEntry = Instance.new("RemoteEvent")
Remote.AdminRemoveLogEntry.Name = "AdminRemoveLogEntry"
Remote.AdminRemoveLogEntry.Parent = ReplicatedStorage

-- [userId] = which log view that admin currently has open, so removing
-- an entry can refresh exactly what they were looking at instead of
-- dumping them back to the full log. false = the whole log (:cmdlogs),
-- a name string = that admin's entries (:playerlogs).
--
-- Declared up here rather than down beside the log code that fills it:
-- the player-leaving cleanup further down clears this table, and a
-- `local` declared after that point would leave the cleanup reading a
-- nil global instead - the same forward-reference trap that has bitten
-- this file before.
local lastLogFilter = {}

-- Separate from Remote.AdminNotice - an announcement is a top-of-screen banner
-- to everyone, not the same centered/blurred single-recipient popup
-- :warn/:mute/:freeze/:msg use.
Remote.AdminAnnouncement = Instance.new("RemoteEvent")
Remote.AdminAnnouncement.Name = "AdminAnnouncement"
Remote.AdminAnnouncement.Parent = ReplicatedStorage

-- Separate from the one-shot Remote.AdminNotice popup above - that only tells a
-- frozen player once, at the moment it happens. This instead carries the
-- ongoing true/false frozen state itself, so the client can show a
-- persistent "YOU ARE FROZEN" indicator for as long as it stays true,
-- not just a popup that can be dismissed and forgotten while still
-- actually frozen.
Remote.AdminFreezeStatus = Instance.new("RemoteEvent")
Remote.AdminFreezeStatus.Name = "AdminFreezeStatus"
Remote.AdminFreezeStatus.Parent = ReplicatedStorage

-- Same idea as Remote.AdminFreezeStatus above, but for mutes - carries the
-- ongoing muted/not-muted state (plus ExpiresAt, or nil for permanent) so
-- the client can show a persistent "muted for/permanently muted" bottom
-- indicator for as long as it's actually true, not just a one-shot popup
-- at the moment :mute/:tempmute happens.
Remote.AdminMuteStatus = Instance.new("RemoteEvent")
Remote.AdminMuteStatus.Name = "AdminMuteStatus"
Remote.AdminMuteStatus.Parent = ReplicatedStorage

-- Fired to the TARGET's own client (not the admin's) with true/false -
-- :fly can be aimed at anyone, not just staff, so this has to work for
-- every player's client, not just inside the staff-only admin panel.
Remote.AbuseSay = Instance.new("RemoteEvent") -- S->C (ownerName, text): a line of chat from the owner during Admin Abuse
Remote.AbuseSay.Name = "AbuseSay"
Remote.AbuseSay.Parent = ReplicatedStorage
Remote.AdminSetFlying = Instance.new("RemoteEvent")
Remote.AdminSetFlying.Name = "AdminSetFlying"
Remote.AdminSetFlying.Parent = ReplicatedStorage

-- Fired to the ADMIN's own client with either a target Player (start
-- spectating them) or nil (stop) - only ever changes the admin's OWN
-- camera/character, never the target's. Stopping is no longer a typed
-- :unspectate command - it's the client's own "Stop Spectating" button,
-- which fires Remote.AdminStopSpectating below instead.
Remote.AdminSpectate = Instance.new("RemoteEvent")
Remote.AdminSpectate.Name = "AdminSpectate"
Remote.AdminSpectate.Parent = ReplicatedStorage

-- Fired FROM the admin's own client - the "Stop Spectating" button shown
-- alongside the "You are currently spectating: X" indicator.
Remote.AdminStopSpectating = Instance.new("RemoteEvent")
Remote.AdminStopSpectating.Name = "AdminStopSpectating"
Remote.AdminStopSpectating.Parent = ReplicatedStorage

-- Fired to the ADMIN's own client with either a target Player (start
-- controlling them - camera lock + WASD forwarding) or nil (stop), same
-- shape as Remote.AdminSpectate above but for :controlplayer.
Remote.AdminControlPlayer = Instance.new("RemoteEvent")
Remote.AdminControlPlayer.Name = "AdminControlPlayer"
Remote.AdminControlPlayer.Parent = ReplicatedStorage

-- Fired FROM the admin's own client while controlling someone - a
-- camera-relative movement direction (and a jump flag) captured from
-- their own WASD every Heartbeat, forwarded here since the admin's
-- client has no permission to touch another player's Humanoid directly -
-- only the server can move the target's own character. An
-- UnreliableRemoteEvent (not a regular one) - every one of these is
-- immediately superseded by the next one a fraction of a second later,
-- so Roblox's usual delivery-order/retry guarantees only add latency
-- here for no benefit; this is exactly the kind of frequent,
-- self-correcting update Roblox recommends it for, and cut the
-- perceptible input delay noticeably.
local AdminControlMove = Instance.new("UnreliableRemoteEvent")
AdminControlMove.Name = "AdminControlMove"
AdminControlMove.Parent = ReplicatedStorage

-- Fired FROM the admin's own client - the "Stop Controlling" button.
Remote.AdminStopControlling = Instance.new("RemoteEvent")
Remote.AdminStopControlling.Name = "AdminStopControlling"
Remote.AdminStopControlling.Parent = ReplicatedStorage

-- Fired to the TARGET's own client with true/false - drives their
-- persistent "you are currently being controlled by staff" indicator,
-- same idea as Remote.AdminFreezeStatus/Remote.AdminMuteStatus but worded for this.
Remote.AdminControlTargetStatus = Instance.new("RemoteEvent")
Remote.AdminControlTargetStatus.Name = "AdminControlTargetStatus"
Remote.AdminControlTargetStatus.Parent = ReplicatedStorage

-- Shared by :viewinv - same list popup component every other master
-- list uses, just showing one target's current Backpack/equipped Tool
-- names instead of a punishment record.
Remote.AdminInventoryList = Instance.new("RemoteEvent")
Remote.AdminInventoryList.Name = "AdminInventoryList"
Remote.AdminInventoryList.Parent = ReplicatedStorage

-- Fired FROM the admin's own client - the per-row Remove button on the
-- :viewinv popup, for removing one specific item rather than needing
-- the separate all-or-nothing :clearinv.
Remote.AdminInventoryRemoveItem = Instance.new("RemoteEvent")
Remote.AdminInventoryRemoveItem.Name = "AdminInventoryRemoveItem"
Remote.AdminInventoryRemoveItem.Parent = ReplicatedStorage

-- Broadcast to EVERY connected client (including the invisible player's
-- own) whenever :invis/:uninvis runs, so PlayerInfo.lua can hide/restore
-- that specific player's overhead name/rank tag - a BillboardGui isn't a
-- BasePart or Decal, so setInvisible's own Transparency sweep never
-- touches it, and being invisible while still showing a nameplate
-- floating in midair rather defeats the point.
Remote.AdminInvisStatus = Instance.new("RemoteEvent")
Remote.AdminInvisStatus.Name = "AdminInvisStatus"
Remote.AdminInvisStatus.Parent = ReplicatedStorage

-- Fired whenever a player's tier might have changed after their client
-- already checked once - :setadminrank, in Studio or by the owner in a
-- live game. Without
-- this, setting the override attribute from the Command Bar after a
-- client's one-time Remote.GetAdminInfo check already ran (which is nearly
-- always the case in practice - it takes real time just to reach the
-- Command Bar and type the line) had no visible effect until rejoining,
-- which loses the attribute anyway since Play sessions don't persist it.
Remote.AdminInfoChanged = Instance.new("RemoteEvent")
Remote.AdminInfoChanged.Name = "AdminInfoChanged"
Remote.AdminInfoChanged.Parent = ReplicatedStorage

-- NOT Studio-only.
--
-- It used to be, on the reasoning that only the Studio testing override
-- ever changed a tier mid-session. That was wrong: :setadminrank is
-- gated on "Studio, OR you are the owner", so the owner can run it in a
-- live game - and there the attribute was set, the rank label changed,
-- and the client was never told, so the person was given a staff rank
-- with no admin panel to go with it.
-- Puts a player's current tier into effect right now: their panel (built, changed or taken away)
-- and the [MOD] / [ADMIN] / [DEV] / [OWNER] tag (player attribute StaffTag, read by NameTags and
-- ChatNames).
function Staff.Apply(player)
	local tier = getPlayerTier(player)
	-- In Studio every tester counts as the owner for testing, but only the real owner wears [OWNER].
	local tag = if tier == "Founder" and not isOwnerAccount(player) then nil else Staff.Tags[tier or ""]
	player:SetAttribute("StaffTag", tag)
	Remote.AdminInfoChanged:FireClient(player, tierInfo(tier, player))
end

local function watchOverride(player)
	player:GetAttributeChangedSignal("AdminTierOverride"):Connect(function()
		Staff.Apply(player)
	end)
	Staff.Apply(player)
end
for _, player in ipairs(Players:GetPlayers()) do
	watchOverride(player)
end
Players.PlayerAdded:Connect(watchOverride)

-- The saved staff ranks: read at start and every 2 minutes; another server's change is heard at once.
task.spawn(function()
	while true do
		if Staff.Load() then
			for _, player in ipairs(Players:GetPlayers()) do
				Staff.Apply(player)
			end
		end
		task.wait(120)
	end
end)
task.spawn(function()
	pcall(function()
		MessagingService:SubscribeAsync(Staff.Topic, function(message)
			local data = message.Data
			local userId = type(data) == "table" and tonumber(data.UserId)
			if not userId then
				return
			end
			if type(data.Tier) == "string" then
				Staff.Map[tostring(userId)] = { Tier = data.Tier, Name = tostring(data.Name or "") }
			else
				Staff.Map[tostring(userId)] = nil
			end
			local player = Players:GetPlayerByUserId(userId)
			if player then
				Staff.Apply(player)
			end
		end)
	end)
end)

-- Gives (tier) or takes away (nil) a staff rank: saved, applied here now, and told to every server.
function Staff.Set(userId, tier, name)
	Staff.Save(userId, tier, name)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		Staff.Apply(player)
	end
	task.spawn(function()
		pcall(function()
			MessagingService:PublishAsync(Staff.Topic, { UserId = userId, Tier = tier, Name = name })
		end)
	end)
end

log("[AdminServer] Remotes ready")

-- =====================================================================
-- Shared helpers
-- =====================================================================
-- Days included once a duration reaches 24h - "167h 59m" for a 7-day mute
-- is technically correct but unreadable at a glance compared to "6d 23h".
-- Minutes are dropped once days are shown (matching the existing
-- hours-drops-minutes-only-below-1h convention one step further) since a
-- day-scale duration doesn't need minute precision.
local function formatDuration(seconds)
	if seconds <= 0 then return "less than a minute" end
	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if days > 0 then
		return days .. "d " .. hours .. "h"
	end
	if hours > 0 then
		return hours .. "h " .. minutes .. "m"
	end
	return minutes .. "m"
end

-- Enumerates every key ever written to a DataStore via
-- DataStoreService:ListKeysAsync, rather than maintaining a hand-rolled
-- index table alongside it. An index is one more piece of state that
-- can silently drift out of sync with the real records - which is
-- exactly what happened here: two bans written before an index existed
-- at all never appeared on :banlist, because nothing had ever added
-- them to it. Listing the store's actual keys can't ever miss a record
-- like that, no matter when it was written.
local function listAllKeys(store)
	local keys = {}
	local success, pages = pcall(function()
		return store:ListKeysAsync()
	end)
	if not success then
		dsWarn("[AdminServer] ListKeysAsync failed: " .. tostring(pages))
		return keys
	end
	while true do
		local ok, currentPage = pcall(function() return pages:GetCurrentPage() end)
		if not ok then break end
		for _, keyInfo in ipairs(currentPage) do
			table.insert(keys, keyInfo.KeyName)
		end
		if pages.IsFinished then break end
		local advanced = pcall(function() pages:AdvanceToNextPageAsync() end)
		if not advanced then break end
	end
	return keys
end

-- Memoizes Players:GetNameFromUserIdAsync - a network call - across every
-- list render in this server session, rather than re-resolving the same
-- offline user's name every single time :banlist/:mutelist/:warnlist is
-- opened. Names essentially never change mid-session for this purpose.
local usernameCache = {}
local function resolveUsername(userId)
	if usernameCache[userId] then return usernameCache[userId] end
	local success, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	local resolved = (success and name) or ("UserId " .. tostring(userId))
	usernameCache[userId] = resolved
	return resolved
end

local DURATION_UNIT_SECONDS = {
	h = 3600, hr = 3600, hrs = 3600, hour = 3600, hours = 3600,
	d = 86400, day = 86400, days = 86400,
	w = 604800, wk = 604800, wks = 604800, week = 604800, weeks = 604800,
}

-- Parses a duration off the front of :tempban/:tempmute's free-text
-- argument, accepting both a compact suffix ("24h", "3D", "1w") and a
-- spelled-out unit with a space ("24 hours", "20 days", "2 weeks") -
-- case-insensitive either way. Returns (seconds, remainingText) on a
-- match, or (nil, originalText) if the text doesn't start with a
-- recognizable duration at all.
local function parseDurationAndReason(text)
	text = text or ""
	local compactNum, compactUnit, compactRest = text:match("^(%d+%.?%d*)(%a+)%s*(.*)$")
	if compactNum and DURATION_UNIT_SECONDS[string.lower(compactUnit)] then
		return math.floor(tonumber(compactNum) * DURATION_UNIT_SECONDS[string.lower(compactUnit)]), compactRest
	end

	local spacedNum, spacedUnit, spacedRest = text:match("^(%d+%.?%d*)%s+(%a+)%s*(.*)$")
	if spacedNum and DURATION_UNIT_SECONDS[string.lower(spacedUnit)] then
		return math.floor(tonumber(spacedNum) * DURATION_UNIT_SECONDS[string.lower(spacedUnit)]), spacedRest
	end

	return nil, text
end

-- =====================================================================
-- Ban persistence - supports an optional expiry (ExpiresAt, a unix
-- timestamp) for temporary bans; nil/absent means permanent.
-- =====================================================================
local BanStore = getStore("RinseCycleBans")

-- Authoritative in-memory mirror of BanStore - [userIdStr] = banData, or
-- false for "checked, not banned". Seeded once at startup below and kept
-- in sync by every write this script makes (banUser/unbanUser are the
-- only things that ever write to BanStore), which is what turns
-- :banlist from "ListKeysAsync + one GetAsync per banned user, every
-- single time the list is opened" (slow enough to feel laggy, and the
-- exact thing that made modifying a reason/duration feel delayed too,
-- since that also re-renders the list the same way) into a purely
-- in-memory read after the one-time startup cost.
local banRecordsCache = {}

local function isBanned(userId)
	local userIdStr = tostring(userId)
	local cached = banRecordsCache[userIdStr]
	if cached ~= nil then
		return cached or nil
	end
	local success, data = pcall(function()
		return BanStore:GetAsync(userIdStr)
	end)
	if success then
		banRecordsCache[userIdStr] = data or false
		return data
	end
	dsWarn("[AdminServer] Failed to check ban status for " .. userIdStr .. ": " .. tostring(data))
	return nil
end

-- Cache updated FIRST, synchronously, with the actual SetAsync/RemoveAsync
-- call kicked off in the background afterward - this is what actually
-- fixed "modifying a ban/mute/warning feels delayed" (the DataStore-read
-- caching earlier in this file only sped up OPENING a list; every WRITE
-- path here still did a blocking network call to Roblox's DataStore
-- service BEFORE sending the refreshed list back to the client, which is
-- exactly the "second or so" lag - SetAsync/RemoveAsync latency is real
-- network time, not something server-side caching alone can remove). The
-- in-memory cache is already the sole source of truth for every read in
-- this file, so the client-visible result (list refresh, popup closing)
-- can safely reflect the change immediately; the persisted copy just
-- catches up a moment later. On the rare failure of that background
-- write, this only warns - the change still holds for the rest of this
-- server session via the cache, which is an acceptable trade for admin
-- tooling responsiveness.
-- waitForPersist forces the actual DataStore write to complete before
-- this returns, instead of firing it in the background. Every caller
-- that immediately Kicks the target after this (:ban, :tempban, the
-- warning-threshold auto-ban) MUST pass true: the background-write
-- version returns before the save has actually reached the DataStore,
-- and if the server stops shortly after (a live server cycling, or -
-- guaranteed - stopping Play in Studio to test rejoining) that ban was
-- never actually persisted, so a fresh server never sees it and the ban
-- silently does nothing. This is exactly what "temp ban doesn't work
-- when I rejoin" traced back to. Editing an existing ban's reason/
-- duration from the Modify popup doesn't Kick anyone, so it can keep
-- using the background-write path for speed - see the comment above
-- this whole section for why that matters for admin-tool
-- responsiveness.
local function banUser(userId, reason, bannedBy, durationSeconds, waitForPersist)
	local data = {
		Reason = reason,
		BannedBy = bannedBy,
		Timestamp = os.time(),
		ExpiresAt = durationSeconds and (os.time() + durationSeconds) or nil,
	}
	banRecordsCache[tostring(userId)] = data
	local function persist()
		local success, err = pcall(function()
			BanStore:SetAsync(tostring(userId), data)
		end)
		if not success then
			dsWarn("[AdminServer] Failed to save ban for " .. tostring(userId) .. ": " .. tostring(err))
		end
	end
	if waitForPersist then
		persist()
	else
		task.spawn(persist)
	end
	return true
end

local function unbanUser(userId)
	banRecordsCache[tostring(userId)] = false
	task.spawn(function()
		local success, err = pcall(function()
			BanStore:RemoveAsync(tostring(userId))
		end)
		if not success then
			dsWarn("[AdminServer] Failed to remove ban for " .. tostring(userId) .. ": " .. tostring(err))
		end
	end)
	return true
end

do
	local keys = listAllKeys(BanStore)
	for _, userIdStr in ipairs(keys) do
		local success, data = pcall(function()
			return BanStore:GetAsync(userIdStr)
		end)
		banRecordsCache[userIdStr] = (success and data) or false
	end
	log("[AdminServer] Ban cache seeded: " .. #keys .. " record(s)")
end

local function buildBanListEntries()
	local entries = {}
	for userIdStr, banData in pairs(banRecordsCache) do
		if banData then
			local userId = tonumber(userIdStr)
			if banData.ExpiresAt and os.time() >= banData.ExpiresAt then
				-- Expired temp ban - clean it up instead of listing it.
				-- Safe to call mid-iteration: this only overwrites an
				-- existing key's value (to false), never adds/removes one.
				unbanUser(userId)
			else
				local displayName = resolveUsername(userId)
				local durationText = banData.ExpiresAt
					and ("Expires in " .. formatDuration(math.max(0, banData.ExpiresAt - os.time())))
					or "Permanent"
				table.insert(entries, {
					Id = userIdStr,
					Name = displayName,
					Reason = banData.Reason,
					DurationText = durationText,
					Line1 = displayName .. ((banData.Reason and banData.Reason ~= "") and (" - " .. banData.Reason) or ""),
					Line2 = "banned by " .. tostring(banData.BannedBy) .. " - " .. durationText,
				})
			end
		end
	end
	table.sort(entries, function(a, b) return a.Line1 < b.Line1 end)
	return entries
end

Players.PlayerAdded:Connect(function(player)
	local banData = isBanned(player.UserId)
	if not banData then return end

	if banData.ExpiresAt and os.time() >= banData.ExpiresAt then
		-- Temp ban has expired - clean up the record and let them in.
		unbanUser(player.UserId)
		return
	end

	-- Delayed rather than instant - kicking the moment the Player object
	-- exists (the previous behavior) landed mid-way through the client's
	-- own loading-screen -> main menu sequence, which is why a banned
	-- player who didn't immediately dismiss the kick dialog saw a broken
	-- half-loaded menu behind it: the topbar/menu buttons (built almost
	-- instantly by their own scripts) were up, but the loading screen's
	-- asset-loading step (which is what actually gates the transition
	-- into the game world/camera settling into its normal framed view)
	-- hadn't finished yet. Waiting here gives that sequence time to fully
	-- complete first, so a banned player sees the exact same properly-
	-- rendered main menu as anyone else for the few seconds before the
	-- kick lands - they still can't do anything with it, this is purely
	-- so what's behind the kick dialog isn't broken.
	task.wait(8)
	if not player.Parent then return end -- already left on their own during the wait

	local message = "You are banned from this game.\nReason: " .. tostring(banData.Reason or "No reason given")
	if banData.ExpiresAt then
		message = message .. "\nTime remaining: " .. formatDuration(banData.ExpiresAt - os.time())
	end
	player:Kick(message)
end)

-- =====================================================================
-- Warnings - persisted per UserId (works for offline players too, e.g.
-- :warnlist covers someone who has since left) so nothing is lost when
-- a player leaves. Reaching certain totals auto-escalates: 3rd warning
-- kicks, 5th bans for 24 hours, 7th bans permanently.
-- =====================================================================
local WarningStore = getStore("RinseCycleWarnings")

-- Authoritative in-memory mirror of WarningStore - [userIdStr] = the
-- warnings array (possibly empty). getWarnings/saveWarnings are the only
-- things that ever touch WarningStore, so this stays in sync without
-- needing to re-list/re-fetch from the DataStore on every :warnlist open
-- - same reasoning as banRecordsCache above.
local warningRecordsCache = {}

local function getWarnings(userId)
	local userIdStr = tostring(userId)
	if warningRecordsCache[userIdStr] then
		return warningRecordsCache[userIdStr]
	end
	local success, data = pcall(function()
		return WarningStore:GetAsync(userIdStr)
	end)
	local warnings = (success and data) or {}
	warningRecordsCache[userIdStr] = warnings
	return warnings
end

-- Cache-first, background-persisted - see the comment above banUser for
-- why (this is exactly what made "remove a warning takes a second to
-- actually go away" happen: the old blocking SetAsync ran before
-- Remote.AdminWarningsList:FireClient below ever fired).
local function saveWarnings(userId, warnings)
	warningRecordsCache[tostring(userId)] = warnings
	task.spawn(function()
		local success, err = pcall(function()
			WarningStore:SetAsync(tostring(userId), warnings)
		end)
		if not success then
			dsWarn("[AdminServer] Failed to save warnings for " .. tostring(userId) .. ": " .. tostring(err))
		end
	end)
	return true
end

do
	local keys = listAllKeys(WarningStore)
	for _, userIdStr in ipairs(keys) do
		local success, data = pcall(function()
			return WarningStore:GetAsync(userIdStr)
		end)
		warningRecordsCache[userIdStr] = (success and data) or {}
	end
	log("[AdminServer] Warning cache seeded: " .. #keys .. " record(s)")
end

local function buildWarnListEntries()
	local entries = {}
	for userIdStr, warnings in pairs(warningRecordsCache) do
		if warnings and #warnings > 0 then
			local userId = tonumber(userIdStr)
			local displayName = resolveUsername(userId)
			table.insert(entries, {
				Id = userIdStr,
				Name = displayName,
				Line1 = displayName .. " - " .. #warnings .. " warning(s)",
				Line2 = "latest: " .. tostring(warnings[#warnings].Reason) .. " (by " .. tostring(warnings[#warnings].By) .. ")",
			})
		end
	end
	table.sort(entries, function(a, b) return a.Line1 < b.Line1 end)
	return entries
end

-- =====================================================================
-- Mute - filters chat delivery via TextChatService rather than blocking
-- the message client-side, so a muted player can't just ignore a local
-- flag. Persisted per UserId (like bans/warnings) so :mutelist can show
-- everyone ever muted, online or not, and a mute survives the muted
-- player leaving and rejoining. mutedUserIds is kept as a plain
-- in-memory cache of the persisted data for whichever muted users are
-- currently online, since the chat filter below runs on every single
-- message and can't afford an async DataStore call per message.
-- =====================================================================
local MuteStore = getStore("RinseCycleMutes")
local mutedUserIds = {} -- [userId] = {Reason=, By=, Timestamp=, ExpiresAt=} - online users only, mirrors MuteStore

-- Authoritative in-memory mirror of MuteStore covering EVERYONE ever
-- muted, online or not - [userIdStr] = muteData, or false for "checked,
-- not muted". This is separate from mutedUserIds above (which only ever
-- tracks currently-online muted players, for the chat filter's per-
-- message hot path) - getMuteData/saveMuteData/removeMuteData are the
-- only things that ever touch MuteStore, so keeping this in sync there
-- means :mutelist never needs to re-list/re-fetch from the DataStore.
local muteRecordsCache = {}

local function getMuteData(userId)
	local userIdStr = tostring(userId)
	local cached = muteRecordsCache[userIdStr]
	if cached ~= nil then
		return cached or nil
	end
	local success, data = pcall(function()
		return MuteStore:GetAsync(userIdStr)
	end)
	if success then
		muteRecordsCache[userIdStr] = data or false
		return data
	end
	return nil
end

-- Cache-first, background-persisted - see the comment above banUser.
-- waitForPersist - same reasoning as banUser: an edit that only reached
-- the in-memory cache before the server happened to stop would silently
-- revert once a fresh server reseeds from the DataStore.
local function saveMuteData(userId, data, waitForPersist)
	muteRecordsCache[tostring(userId)] = data
	local function persist()
		local success, err = pcall(function()
			MuteStore:SetAsync(tostring(userId), data)
		end)
		if not success then
			dsWarn("[AdminServer] Failed to save mute for " .. tostring(userId) .. ": " .. tostring(err))
		end
	end
	if waitForPersist then
		persist()
	else
		task.spawn(persist)
	end
	return true
end

local function removeMuteData(userId)
	muteRecordsCache[tostring(userId)] = false
	task.spawn(function()
		pcall(function()
			MuteStore:RemoveAsync(tostring(userId))
		end)
	end)
end

do
	local keys = listAllKeys(MuteStore)
	for _, userIdStr in ipairs(keys) do
		local success, data = pcall(function()
			return MuteStore:GetAsync(userIdStr)
		end)
		muteRecordsCache[userIdStr] = (success and data) or false
	end
	log("[AdminServer] Mute cache seeded: " .. #keys .. " record(s)")
end

-- Dedups the "you are muted" reminder so a single blocked chat message
-- only pops the notice once, not once per other player subscribed to
-- the channel (ShouldDeliverCallback runs once per potential
-- recipient). Cleared periodically so it can't grow unbounded over a
-- long session.
local notifiedMuteMessageIds = {}
local notifiedMuteCount = 0
local function markMuteNotified(messageId)
	if notifiedMuteMessageIds[messageId] then return false end
	notifiedMuteMessageIds[messageId] = true
	notifiedMuteCount += 1
	if notifiedMuteCount > 300 then
		notifiedMuteMessageIds = {}
		notifiedMuteCount = 0
	end
	return true
end

local function muteNoticeBody(muteData)
	local body
	if muteData.Reason and muteData.Reason ~= "" then
		body = muteData.Reason
	else
		body = muteData.ExpiresAt and "No reason given." or "You are permanently muted."
	end
	if muteData.ExpiresAt then
		body = body .. "\nExpires in: " .. formatDuration(math.max(0, muteData.ExpiresAt - os.time()))
	end
	return body
end

-- Shown every time a muted player's message gets blocked (not the
-- richer reason/duration notice above, which is only for the moment
-- they're actually muted) - a plain, consistent explanation of why
-- nothing happened when they tried to type.
local MUTE_TYPING_REMINDER = "You are currently muted. No one else can see your messages."

local function attachMuteFilter(channel)
	channel.ShouldDeliverCallback = function(message)
		-- Fails open (delivers the message) if anything here errors, so a
		-- bug in this filter can never silently break chat for everyone -
		-- worst case a mute doesn't take effect, instead of chat breaking.
		local ok, blocked = pcall(function()
			local source = message.TextSource
			if not source then return false end
			local muteData = mutedUserIds[source.UserId]
			if not muteData then return false end

			if muteData.ExpiresAt and os.time() >= muteData.ExpiresAt then
				mutedUserIds[source.UserId] = nil
				removeMuteData(source.UserId)
				return false
			end

			if markMuteNotified(message.MessageId) then
				local mutedPlayerObj = Players:GetPlayerByUserId(source.UserId)
				if mutedPlayerObj then
					Remote.AdminNotice:FireClient(mutedPlayerObj, "You are muted", MUTE_TYPING_REMINDER)
				end
			end
			return true
		end)
		if not ok then return true end
		return not blocked
	end
	log("[AdminServer] Mute filter attached to " .. channel.Name)
end

-- The real mute: Roblox's own TextSource.CanSend. Every player has one TextSource per chat
-- channel; turning CanSend off stops the message at the source, so nobody (the sender included)
-- ever sees it. The delivery filter above stays on as a second line. Kept in sync by
-- syncChatMutes, run right after any mute change and every second (which also ends tempmutes on
-- time and tells the player).
local function isMutedNow(userId)
	local data = mutedUserIds[userId]
	if not data then return false end
	if data.ExpiresAt and os.time() >= data.ExpiresAt then
		mutedUserIds[userId] = nil
		removeMuteData(userId)
		local plr = Players:GetPlayerByUserId(userId)
		if plr then
			Remote.AdminMuteStatus:FireClient(plr, false, nil)
			Remote.AdminNotice:FireClient(plr, "You are no longer muted", "Your mute has ended. You can chat again.")
		end
		return false
	end
	return true
end

local function applyTextSource(source)
	if not source:IsA("TextSource") then return end
	local canSend = not isMutedNow(source.UserId)
	if source.CanSend ~= canSend then
		source.CanSend = canSend
	end
end

local function syncChatMutes()
	local textChannels = TextChatService:FindFirstChild("TextChannels")
	if not textChannels then return end
	for _, channel in ipairs(textChannels:GetChildren()) do
		if channel:IsA("TextChannel") then
			for _, source in ipairs(channel:GetChildren()) do
				pcall(applyTextSource, source)
			end
		end
	end
end

task.spawn(function()
	while true do
		task.wait(1)
		pcall(syncChatMutes)
	end
end)

-- Attached to every current AND future text channel rather than a
-- single channel hardcoded by name ("RBXGeneral") - if this game's
-- channel is actually named something else, or there's more than one
-- (e.g. a team channel), hardcoding one name would silently mean
-- :mute never actually blocked anything even though the command itself
-- reported success.
task.spawn(function()
	-- Made by Roblox shortly after start (the place file turns on the modern chat). Waits quietly.
	local textChannels = TextChatService:FindFirstChild("TextChannels")
	local waited = 0
	while not textChannels do
		task.wait(1)
		waited += 1
		textChannels = TextChatService:FindFirstChild("TextChannels")
		if waited == 60 and not textChannels then
			warn("[AdminServer] Chat channels still missing after a minute: is Chat > ChatVersion set to TextChatService? :mute needs it")
		end
	end
	local function watchChannel(channel)
		attachMuteFilter(channel)
		channel.ChildAdded:Connect(function(source)
			pcall(applyTextSource, source)
		end)
	end
	for _, channel in ipairs(textChannels:GetChildren()) do
		if channel:IsA("TextChannel") then
			watchChannel(channel)
		end
	end
	textChannels.ChildAdded:Connect(function(child)
		if child:IsA("TextChannel") then
			watchChannel(child)
		end
	end)
end)

Players.PlayerAdded:Connect(function(player)
	local muteData = getMuteData(player.UserId)
	if not muteData then return end
	if muteData.ExpiresAt and os.time() >= muteData.ExpiresAt then
		removeMuteData(player.UserId)
		return
	end
	mutedUserIds[player.UserId] = muteData
	-- Restores the persistent "muted for/permanently muted" indicator on
	-- rejoin - without this, a still-muted player who leaves and comes
	-- back would only ever see it again the next time an admin touches
	-- their mute record.
	Remote.AdminMuteStatus:FireClient(player, true, muteData.ExpiresAt)
end)

-- Returns (nowMuted, muteData) - muteData is the new record when nowMuted
-- is true, nil when unmuting - so callers can fire Remote.AdminMuteStatus with
-- the right ExpiresAt without a second lookup.
local function toggleMute(target, admin, reason)
	if mutedUserIds[target.UserId] then
		mutedUserIds[target.UserId] = nil
		removeMuteData(target.UserId)
		return false, nil
	end
	local data = {Reason = reason, By = admin.Name, Timestamp = os.time(), ExpiresAt = nil}
	mutedUserIds[target.UserId] = data
	saveMuteData(target.UserId, data)
	return true, data
end

local function buildMuteListEntries()
	local entries = {}
	for userIdStr, data in pairs(muteRecordsCache) do
		if data then
			local userId = tonumber(userIdStr)
			if data.ExpiresAt and os.time() >= data.ExpiresAt then
				-- Safe to call mid-iteration - see buildBanListEntries above.
				removeMuteData(userId)
				mutedUserIds[userId] = nil
			else
				local displayName = resolveUsername(userId)
				local durationText = data.ExpiresAt
					and ("Expires in " .. formatDuration(math.max(0, data.ExpiresAt - os.time())))
					or "Permanent"
				table.insert(entries, {
					Id = userIdStr,
					Name = displayName,
					Reason = data.Reason,
					DurationText = durationText,
					Line1 = displayName .. ((data.Reason and data.Reason ~= "") and (" - " .. data.Reason) or ""),
					Line2 = "muted by " .. tostring(data.By) .. " - " .. durationText,
				})
			end
		end
	end
	table.sort(entries, function(a, b) return a.Line1 < b.Line1 end)
	return entries
end

-- =====================================================================
-- In-game rank management (:setrank/:promote/:demote): the rank shown under a player's name,
-- normally rolled with gems in the lobby. These bypass rolling entirely (that's the point of an
-- admin override) and write straight through to the saved profile.
-- =====================================================================
-- Rinse Cycle's ranks (Config.Ranks), ordered from the most common to the rarest, so :promote
-- and :demote step one rarity at a time. A rank set here is the player's equipped rank, the same
-- one a roll gives - it shows on their name tag straight away.
local IN_GAME_RANKS = {}
do
	for index, rank in ipairs(Config.Ranks) do
		local rarity = Config.RankRarities[rank.Rarity]
		table.insert(IN_GAME_RANKS, {Id = rank.Id, Label = rank.Name, Order = (rarity and rarity.Order or 0) * 1000 + index})
	end
	table.sort(IN_GAME_RANKS, function(a, b) return a.Order < b.Order end)
end
local IN_GAME_RANK_INDEX = {}
for i, rank in ipairs(IN_GAME_RANKS) do
	IN_GAME_RANK_INDEX[rank.Id] = i
end

local function applyRank(target, rank)
	DataService.AddRank(target, rank.Id)
	DataService.SetRank(target, rank.Id)
	DataService.PassesChanged:Fire(target) -- name tag and run stats pick it up
end

local function getCurrentRankIndex(target)
	local profile = DataService.Get(target)
	local currentId = profile and profile.Rank
	return (currentId and IN_GAME_RANK_INDEX[currentId]) or 0
end

-- Matches by exact label/id first ("Dish Wizard" or its id), then falls back to an unambiguous prefix match
-- ("dish") - same case-insensitive partial-match convention as
-- findTargetPlayer below, just over the rank list instead of the
-- player list.
local function findRank(query)
	if typeof(query) ~= "string" then return nil, nil end
	-- Trimmed defensively - a stray leading/trailing space (e.g. from a
	-- client-side autocomplete quirk) would otherwise fail both the
	-- exact-match and prefix-match checks below even though the typed
	-- name is really a perfect match, reporting "no rank found" for a
	-- name that's actually correct.
	query = query:gsub("^%s+", ""):gsub("%s+$", "")
	if query == "" then return nil, nil end
	local lowerQuery = string.lower(query)

	for _, rank in ipairs(IN_GAME_RANKS) do
		if string.lower(rank.Label) == lowerQuery or string.lower(rank.Id) == lowerQuery then
			return rank, nil
		end
	end

	local matches = {}
	for _, rank in ipairs(IN_GAME_RANKS) do
		if string.sub(string.lower(rank.Label), 1, #lowerQuery) == lowerQuery then
			table.insert(matches, rank)
		end
	end
	if #matches == 1 then
		return matches[1], nil
	elseif #matches > 1 then
		local names = {}
		for _, r in ipairs(matches) do table.insert(names, r.Label) end
		return nil, "Multiple ranks match \"" .. query .. "\": " .. table.concat(names, ", ")
	end
	return nil, nil
end

-- =====================================================================
-- Freeze / unfreeze - two explicit one-way commands rather than a
-- single toggle, so the sidebar/typed command always does exactly what
-- it says instead of depending on hidden state the admin has to
-- remember.
-- =====================================================================
local frozenUserIds = {}

local function setFrozen(target, frozen)
	local character = target.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	hrp.Anchored = frozen
	frozenUserIds[target.UserId] = frozen or nil
	return true
end

-- =====================================================================
-- God mode - keeps a player's Humanoid topped up at full health for as
-- long as it's on, by re-asserting Health the instant it actually drops
-- (via HealthChanged) rather than polling. Like :freeze, this only ever
-- covers the CURRENT character - dying and respawning ends it, the same
-- way freezing doesn't carry over to a new life either; :god has to be
-- run again after a respawn if it's still wanted.
-- =====================================================================
local godModeUserIds = {}
local godModeConnections = {} -- [userId] = the HealthChanged connection while on

local function setGodMode(target, enabled)
	local userId = target.UserId
	local existingConn = godModeConnections[userId]
	if existingConn then
		existingConn:Disconnect()
		godModeConnections[userId] = nil
	end
	godModeUserIds[userId] = enabled or nil
	if not enabled then return true end

	local character = target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		godModeUserIds[userId] = nil
		return false
	end
	humanoid.Health = humanoid.MaxHealth
	godModeConnections[userId] = humanoid.HealthChanged:Connect(function()
		if humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = humanoid.MaxHealth
		end
	end)
	return true
end

-- =====================================================================
-- Jail - a three-cell block with a corridor.
--
-- Earlier versions worth recording so they aren't retried: a plain
-- sealed cube (read as a storage cupboard), then bars added to the
-- INSIDE of one wall (bars with a solid wall behind them aren't bars,
-- they're wallpaper). The constraint behind both is that a genuine
-- barred opening 300 studs underground looks out into empty void, which
-- is worse again. The fix is a block big enough to contain the view:
-- cells facing a lit corridor, so there is somewhere real to look.
--
-- Everything here is built to read well at a GLANCE rather than to be
-- densely detailed. Procedural geometry gets worse, not better, the more
-- small props are thrown at it - a few well-proportioned, properly
-- grounded shapes look deliberate, while lots of little floating ones
-- look like an accident. Anything decorative is sized off the block's
-- own constants so nothing drifts if those change.
--
-- Placed BELOW the map rather than above it, but only moderately so:
-- Roblox destroys anything falling past workspace.FallenPartsDestroyHeight
-- (default -500, not set anywhere in these scripts). -300 keeps the
-- whole block clear of that with room to spare.
-- =====================================================================
local JAIL_CFRAME = CFrame.new(0, -300, 0)

-- Roomier than it first looks on paper: a 12-stud ceiling felt like a
-- crawlspace once a character was stood under it, and 14-deep cells left
-- no floor once a bunk was in.
-- The jail's sizes and colours, in one table (Luau allows at most 200 top-level locals, see Remote).
local Jail = {}
Jail.CELL_W, Jail.CELL_D, Jail.CELL_H = 18, 16, 16
Jail.CORRIDOR_D = 15
Jail.DIVIDER = 1
Jail.JAIL_WALL = 1
Jail.DOOR_WIDTH = 5

Jail.BLOCK_W = Jail.CELL_W * 3 + Jail.DIVIDER * 2
Jail.CELL_Z0, Jail.CELL_Z1 = -Jail.CELL_D - 1, -1
Jail.CORR_Z1 = Jail.CELL_Z1 + Jail.CORRIDOR_D
Jail.FLOOR_Y, Jail.CEIL_Y = -Jail.CELL_H / 2, Jail.CELL_H / 2
Jail.CELL_MID_Z = (Jail.CELL_Z0 + Jail.CELL_Z1) / 2
Jail.CORR_MID_Z = Jail.CELL_Z1 + Jail.CORRIDOR_D / 2
Jail.CELL_X = { -(Jail.CELL_W + Jail.DIVIDER), 0, Jail.CELL_W + Jail.DIVIDER }

local JAIL_SPAWN_CFRAME = JAIL_CFRAME * CFrame.new(0, Jail.FLOOR_Y + 4, Jail.CELL_MID_Z)

-- A narrow palette, and floor/walls deliberately different values so the
-- room has some contrast instead of being one flat grey.
Jail.C_WALL = Color3.fromRGB(104, 104, 108)
Jail.C_WALL_LOW = Color3.fromRGB(74, 74, 79)
Jail.C_FLOOR = Color3.fromRGB(58, 58, 62)
Jail.C_STEEL = Color3.fromRGB(78, 82, 90)
Jail.C_ACCENT = Color3.fromRGB(196, 158, 46)
Jail.C_MATTRESS = Color3.fromRGB(72, 86, 108)
Jail.C_PORCELAIN = Color3.fromRGB(198, 201, 206)
Jail.C_WOOD = Color3.fromRGB(96, 72, 52)

local jailFolder = Instance.new("Folder")
jailFolder.Name = "AdminJailCell"
jailFolder.Parent = workspace

-- Positions are LOCAL to the block, converted here, so every measurement
-- below reads as an offset from the block's own origin rather than an
-- absolute world coordinate. `rot` is applied after the offset, which is
-- what lets bars be cylinders (a cylinder Part runs along its X axis, so
-- standing one upright means rotating it 90 degrees about Z).
local function jailPart(props)
	local part = Instance.new("Part")
	part.Name = props.Name or "JailPart"
	part.Anchored = true
	part.CanCollide = props.CanCollide ~= false
	part.Material = props.Material or Enum.Material.Concrete
	part.Color = props.Color or Jail.C_WALL
	part.Size = props.Size
	part.CFrame = JAIL_CFRAME * CFrame.new(props.X or 0, props.Y or 0, props.Z or 0) * (props.Rot or CFrame.new())
	if props.Shape then part.Shape = props.Shape end
	part.Parent = props.Parent or jailFolder
	return part
end

local setCellDoorOpen

do
	local overlap = Jail.JAIL_WALL
	local blockCentreZ = (Jail.CELL_Z0 + Jail.CORR_Z1) / 2
	local blockDepth = Jail.CORR_Z1 - Jail.CELL_Z0
	local halfW = Jail.BLOCK_W / 2

	-- Shell. Every piece OVERLAPS its neighbours at the seams rather than
	-- butting edge-to-edge: parts that merely touch along a shared
	-- boundary can flicker straight through when the camera clips into
	-- the geometry, and overlapping solid material leaves no exact
	-- coincident edge to slip through.
	local shellW, shellD, shellH = Jail.BLOCK_W + overlap * 2, blockDepth + overlap * 2, Jail.CELL_H + overlap * 2
	jailPart({Name = "Floor", Size = Vector3.new(shellW, Jail.JAIL_WALL, shellD), Y = Jail.FLOOR_Y - Jail.JAIL_WALL / 2, Z = blockCentreZ, Color = Jail.C_FLOOR})
	-- Not as dark as the wall band: at the first pass the ceiling read as
	-- an open black void above the lights rather than as a surface.
	jailPart({Name = "Ceiling", Size = Vector3.new(shellW, Jail.JAIL_WALL, shellD), Y = Jail.CEIL_Y + Jail.JAIL_WALL / 2, Z = blockCentreZ, Color = Color3.fromRGB(88, 88, 93)})
	jailPart({Name = "WallBack", Size = Vector3.new(shellW, shellH, Jail.JAIL_WALL), Z = Jail.CELL_Z0 - Jail.JAIL_WALL / 2})
	jailPart({Name = "WallFront", Size = Vector3.new(shellW, shellH, Jail.JAIL_WALL), Z = Jail.CORR_Z1 + Jail.JAIL_WALL / 2})
	jailPart({Name = "WallLeft", Size = Vector3.new(Jail.JAIL_WALL, shellH, shellD), X = -halfW - Jail.JAIL_WALL / 2, Z = blockCentreZ})
	jailPart({Name = "WallRight", Size = Vector3.new(Jail.JAIL_WALL, shellH, shellD), X = halfW + Jail.JAIL_WALL / 2, Z = blockCentreZ})

	-- A darker band around the lower third of the walls. One horizontal
	-- line does more to stop a room reading as a flat grey box than any
	-- number of small props, because it gives the eye a height reference.
	local BAND_H = Jail.CELL_H * 0.34
	jailPart({Name = "BandFront", Size = Vector3.new(shellW, BAND_H, 0.12), Y = Jail.FLOOR_Y + BAND_H / 2, Z = Jail.CORR_Z1 - 0.06, Material = Enum.Material.SmoothPlastic, Color = Jail.C_WALL_LOW, CanCollide = false})
	for _, dir in ipairs({-1, 1}) do
		jailPart({Name = "BandSide", Size = Vector3.new(0.12, BAND_H, shellD), X = dir * (halfW - 0.06), Y = Jail.FLOOR_Y + BAND_H / 2, Z = blockCentreZ, Material = Enum.Material.SmoothPlastic, Color = Jail.C_WALL_LOW, CanCollide = false})
	end
	jailPart({Name = "BandStripe", Size = Vector3.new(shellW, 0.18, 0.14), Y = Jail.FLOOR_Y + BAND_H, Z = Jail.CORR_Z1 - 0.07, Material = Enum.Material.SmoothPlastic, Color = Jail.C_ACCENT, CanCollide = false})
	jailPart({Name = "FloorLine", Size = Vector3.new(Jail.BLOCK_W - 3, 0.06, 0.7), Y = Jail.FLOOR_Y + 0.04, Z = Jail.CORR_MID_Z, Material = Enum.Material.SmoothPlastic, Color = Jail.C_ACCENT, CanCollide = false})

	for i = 1, 2 do
		jailPart({Name = "CellDivider" .. i, Size = Vector3.new(Jail.DIVIDER, Jail.CELL_H, Jail.CELL_D + overlap), X = Jail.CELL_X[i] + Jail.CELL_W / 2 + Jail.DIVIDER / 2, Z = Jail.CELL_MID_Z})
	end

	local barTop, barBottom = Jail.CEIL_Y - 0.5, Jail.FLOOR_Y + 0.5
	local barHeight = barTop - barBottom
	local barMidY = (barTop + barBottom) / 2
	local doorHalf = Jail.DOOR_WIDTH / 2
	local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

	-- ROUND bars, not square ones. Square uprights were the single
	-- biggest reason the last version looked cheap - real cell bars are
	-- round, and a cylinder catches the light along its length instead of
	-- presenting one flat grey face.
	local function bar(name, x, y, z, length, thickness, parent)
		return jailPart({Name = name, Size = Vector3.new(length, thickness, thickness),
			X = x, Y = y, Z = z, Rot = UPRIGHT, Shape = Enum.PartType.Cylinder,
			Material = Enum.Material.Metal, Color = Jail.C_STEEL, Parent = parent})
	end

	local function buildCellFront(cellIndex)
		local cx = Jail.CELL_X[cellIndex]
		local function barsBetween(x0, x1, tag)
			local span = x1 - x0
			local count = math.max(2, math.floor(span / 1.45))
			for i = 0, count do
				bar("Bar" .. cellIndex .. tag .. i, x0 + span * (i / count), barMidY, Jail.CELL_Z1, barHeight, 0.34)
			end
		end
		barsBetween(cx - Jail.CELL_W / 2 + 0.5, cx - doorHalf - 0.5, "L")
		barsBetween(cx + doorHalf + 0.5, cx + Jail.CELL_W / 2 - 0.5, "R")

		-- Rails stop short of the doorway on both sides so the opening is
		-- genuinely open rather than crossed by a bar.
		local sideSpan = Jail.CELL_W / 2 - doorHalf
		for _, y in ipairs({barBottom + 0.2, barMidY, barTop - 0.2}) do
			for _, dir in ipairs({-1, 1}) do
				jailPart({Name = "BarRail", Size = Vector3.new(sideSpan, 0.26, 0.26),
					X = cx + dir * (doorHalf + sideSpan / 2), Y = y, Z = Jail.CELL_Z1,
					Material = Enum.Material.Metal, Color = Jail.C_STEEL, CanCollide = false})
			end
		end
		for _, dir in ipairs({-1, 1}) do
			jailPart({Name = "DoorPost", Size = Vector3.new(0.6, barHeight + 0.8, 0.6),
				X = cx + dir * doorHalf, Y = barMidY, Z = Jail.CELL_Z1,
				Material = Enum.Material.Metal, Color = Jail.C_STEEL})
		end
		jailPart({Name = "DoorLintel", Size = Vector3.new(Jail.DOOR_WIDTH + 1.2, 0.6, 0.55),
			X = cx, Y = barTop + 0.55, Z = Jail.CELL_Z1, Material = Enum.Material.Metal, Color = Jail.C_STEEL})

		local plate = jailPart({Name = "CellPlate", Size = Vector3.new(3, 1.3, 0.16),
			X = cx, Y = barTop + 1.6, Z = Jail.CELL_Z1, Material = Enum.Material.SmoothPlastic,
			Color = Jail.C_WALL_LOW, CanCollide = false})
		local sign = Instance.new("SurfaceGui")
		sign.Face = Enum.NormalId.Front
		sign.CanvasSize = Vector2.new(300, 130)
		sign.Parent = plate
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextColor3 = Jail.C_ACCENT
		label.TextScaled = true
		label.Text = "CELL " .. cellIndex
		label.Parent = sign
	end

	local function buildCellDoor(cellIndex)
		local cx = Jail.CELL_X[cellIndex]
		local door = Instance.new("Model")
		door.Name = "CellDoor" .. cellIndex
		door.Parent = jailFolder

		local frame = jailPart({Name = "DoorFrame", Size = Vector3.new(Jail.DOOR_WIDTH - 0.4, barHeight - 0.3, 0.3),
			X = cx, Y = barMidY, Z = Jail.CELL_Z1, Material = Enum.Material.Metal, Color = Jail.C_STEEL, Parent = door})
		frame.Transparency = 1
		door.PrimaryPart = frame

		for i = 1, 4 do
			bar("DoorBar" .. i, cx - Jail.DOOR_WIDTH / 2 + Jail.DOOR_WIDTH * (i / 5), barMidY, Jail.CELL_Z1, barHeight - 0.5, 0.3, door)
		end
		for _, y in ipairs({barMidY - barHeight / 2 + 0.5, barMidY, barMidY + barHeight / 2 - 0.5}) do
			jailPart({Name = "DoorRail", Size = Vector3.new(Jail.DOOR_WIDTH - 0.4, 0.24, 0.24),
				X = cx, Y = y, Z = Jail.CELL_Z1, Material = Enum.Material.Metal, Color = Jail.C_STEEL, Parent = door})
		end
		-- Slim and steel, kept close to the door plane. A chunky gold
		-- block standing proud of the bars just read as a stray part.
		jailPart({Name = "DoorHandle", Size = Vector3.new(0.18, 0.18, 0.95), X = cx + doorHalf - 0.75,
			Y = barMidY, Z = Jail.CELL_Z1 + 0.28, Material = Enum.Material.Metal, Color = Jail.C_STEEL, Parent = door})

		local hinge = JAIL_CFRAME * CFrame.new(cx - doorHalf, barMidY, Jail.CELL_Z1)
		local closedPivot = JAIL_CFRAME * CFrame.new(cx, barMidY, Jail.CELL_Z1)
		local openPivot = hinge * CFrame.Angles(0, math.rad(100), 0) * hinge:Inverse() * closedPivot

		local isOpen, activeTween = false, nil
		local function setOpen(open)
			if isOpen == open then return end
			isOpen = open
			-- Tweening a CFrameValue and mirroring it onto the model each
			-- frame: TweenService cannot animate a Model directly, and
			-- moving each bar on its own would let them drift apart.
			local driver = Instance.new("CFrameValue")
			driver.Value = door:GetPivot()
			local conn = driver.Changed:Connect(function(value) door:PivotTo(value) end)
			if activeTween then activeTween:Cancel() end
			activeTween = TweenService:Create(driver,
				TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{Value = open and openPivot or closedPivot})
			activeTween:Play()
			activeTween.Completed:Once(function()
				conn:Disconnect()
				driver:Destroy()
			end)
		end

		-- Staff-only, checked on the SERVER at click time. A ClickDetector
		-- fires for anyone who clicks it, so this tier check is the entire
		-- lock - there is no client-side gate to bypass because there
		-- isn't one. Attached to every part of the door so any bar works;
		-- only one part is hit per click, so it cannot double-toggle.
		for _, piece in ipairs(door:GetDescendants()) do
			if piece:IsA("BasePart") then
				local click = Instance.new("ClickDetector")
				click.MaxActivationDistance = 26
				click.Parent = piece
				click.MouseClick:Connect(function(clicker)
					if not getPlayerTier(clicker) then return end
					setOpen(not isOpen)
				end)
			end
		end
		return setOpen
	end

	-- Furniture is deliberately sparse, and everything either sits on the
	-- floor or is visibly braced to a wall. The previous pass had a basin
	-- and a desktop hanging in mid-air, which is the fastest way to make
	-- a build look broken.
	local function furnishCell(cellIndex)
		local cx = Jail.CELL_X[cellIndex]
		local bunkX = cx - Jail.CELL_W / 2 + 2.6
		local bunkY = Jail.FLOOR_Y + 2.1

		jailPart({Name = "BunkFrame", Size = Vector3.new(3.8, 0.35, 8), X = bunkX, Y = bunkY, Z = Jail.CELL_MID_Z, Material = Enum.Material.Metal, Color = Jail.C_STEEL})
		jailPart({Name = "Mattress", Size = Vector3.new(3.5, 0.5, 7.6), X = bunkX, Y = bunkY + 0.42, Z = Jail.CELL_MID_Z, Material = Enum.Material.Fabric, Color = Jail.C_MATTRESS})
		jailPart({Name = "Pillow", Size = Vector3.new(3.1, 0.35, 1.6), X = bunkX, Y = bunkY + 0.8, Z = Jail.CELL_MID_Z - 2.9, Material = Enum.Material.Fabric, Color = Color3.fromRGB(166, 170, 178)})
		-- Braced into the wall rather than standing on legs, so there is
		-- nothing to float: the slab runs into the divider behind it.
		jailPart({Name = "BunkBrace", Size = Vector3.new(0.5, bunkY - Jail.FLOOR_Y, 8), X = bunkX - 1.9, Y = Jail.FLOOR_Y + (bunkY - Jail.FLOOR_Y) / 2, Z = Jail.CELL_MID_Z, Material = Enum.Material.Metal, Color = Jail.C_STEEL})

		-- Sanitary fixtures, pushed FLUSH to the walls. Sitting them a
		-- stud or two clear of the wall is what made the previous pass
		-- read as white crates dumped in a corner rather than plumbing -
		-- real fixtures touch something.
		local wallX = cx + Jail.CELL_W / 2
		local backZ = Jail.CELL_Z0

		-- Bowl and seat as upright cylinders. A cube reads as a box no
		-- matter what colour it is; the round profile is most of what
		-- makes this legible as a toilet at a glance.
		jailPart({Name = "ToiletBowl", Size = Vector3.new(1.7, 1.8, 1.8), X = wallX - 1.7, Y = Jail.FLOOR_Y + 0.85, Z = backZ + 1.6, Rot = UPRIGHT, Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = Jail.C_PORCELAIN})
		jailPart({Name = "ToiletSeat", Size = Vector3.new(0.22, 2.1, 2.1), X = wallX - 1.7, Y = Jail.FLOOR_Y + 1.81, Z = backZ + 1.6, Rot = UPRIGHT, Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = Jail.C_WALL_LOW})
		jailPart({Name = "Cistern", Size = Vector3.new(2.2, 2.6, 0.7), X = wallX - 1.7, Y = Jail.FLOOR_Y + 3.1, Z = backZ + 0.45, Material = Enum.Material.SmoothPlastic, Color = Jail.C_PORCELAIN})

		-- Basin against the side wall, on a bracket that visibly reaches
		-- the floor so nothing appears to hang in mid-air.
		jailPart({Name = "Basin", Size = Vector3.new(1.3, 0.8, 2.4), X = wallX - 0.7, Y = Jail.FLOOR_Y + 3.3, Z = backZ + 5.4, Material = Enum.Material.SmoothPlastic, Color = Jail.C_PORCELAIN})
		jailPart({Name = "BasinStand", Size = Vector3.new(0.7, 2.9, 0.8), X = wallX - 0.45, Y = Jail.FLOOR_Y + 1.45, Z = backZ + 5.4, Material = Enum.Material.Metal, Color = Jail.C_STEEL})
	end

	for i = 1, 3 do
		buildCellFront(i)
		furnishCell(i)
	end

	local doorSetters = {}
	for i = 1, 3 do doorSetters[i] = buildCellDoor(i) end
	-- jail/unjail only ever use the centre cell, which is where
	-- JAIL_SPAWN_CFRAME puts people.
	setCellDoorOpen = doorSetters[2]

	-- Guard desk, built as a solid block with a top rather than a
	-- floating slab and a disconnected front panel.
	local deskX, deskZ = -halfW + 5, Jail.CORR_Z1 - 3.5
	jailPart({Name = "DeskBody", Size = Vector3.new(8, 3.2, 3), X = deskX, Y = Jail.FLOOR_Y + 1.6, Z = deskZ, Material = Enum.Material.WoodPlanks, Color = Jail.C_WOOD})
	jailPart({Name = "DeskTop", Size = Vector3.new(9, 0.35, 3.8), X = deskX, Y = Jail.FLOOR_Y + 3.38, Z = deskZ, Material = Enum.Material.WoodPlanks, Color = Jail.C_WOOD})
	jailPart({Name = "DeskChairSeat", Size = Vector3.new(2, 0.35, 2), X = deskX, Y = Jail.FLOOR_Y + 1.9, Z = deskZ + 3.4, Material = Enum.Material.SmoothPlastic, Color = Jail.C_WALL_LOW})
	jailPart({Name = "DeskChairBack", Size = Vector3.new(2, 2.2, 0.35), X = deskX, Y = Jail.FLOOR_Y + 3, Z = deskZ + 4.3, Material = Enum.Material.SmoothPlastic, Color = Jail.C_WALL_LOW})
	jailPart({Name = "DeskChairStem", Size = Vector3.new(0.5, 1.75, 0.5), X = deskX, Y = Jail.FLOOR_Y + 0.88, Z = deskZ + 3.4, Material = Enum.Material.Metal, Color = Jail.C_STEEL})

	-- Long recessed strip lights rather than bare points: a visible
	-- fixture reads as a light, while an invisible source just makes the
	-- room glow from nowhere. Dimmer and more numerous than before, which
	-- is what stops the harsh single-source look.
	local function stripLight(name, x, z, length)
		jailPart({Name = name .. "Housing", Size = Vector3.new(length, 0.35, 1.1), X = x, Y = Jail.CEIL_Y - 0.5, Z = z, Material = Enum.Material.Metal, Color = Jail.C_STEEL, CanCollide = false})
		local lens = jailPart({Name = name .. "Lens", Size = Vector3.new(length - 0.6, 0.12, 0.8), X = x, Y = Jail.CEIL_Y - 0.72, Z = z, Material = Enum.Material.Neon, Color = Color3.fromRGB(236, 242, 250), CanCollide = false})
		local light = Instance.new("PointLight")
		light.Brightness = 1.35
		light.Range = 26
		light.Color = Color3.fromRGB(226, 234, 245)
		light.Shadows = false
		light.Parent = lens
	end
	for i = 1, 3 do
		stripLight("CellLight" .. i, Jail.CELL_X[i], Jail.CELL_MID_Z, Jail.CELL_W * 0.45)
		stripLight("CorridorLightA" .. i, Jail.CELL_X[i], Jail.CORR_MID_Z - 3.5, Jail.CELL_W * 0.5)
		stripLight("CorridorLightB" .. i, Jail.CELL_X[i], Jail.CORR_MID_Z + 3.5, Jail.CELL_W * 0.5)
	end

	log("[AdminServer] Jail block built (3 cells)")
end

local jailedUserIds = {}

-- How long the server holds a teleport back after telling the client to
-- cover the screen. Must be at least the client's TRANSITION_SLIDE_TIME
-- (AdminClient.lua), because the cover is a wipe that slides in rather
-- than a cut: fire and teleport in the same breath and the panel slides
-- down over a jail the player has already been looking at, which makes
-- the reveal afterwards pointless. A small margin on top absorbs the
-- round trip to the client.
local JAIL_COVER_TIME = 0.75

local function jailPlayer(target)
	local character = target.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	jailedUserIds[target.UserId] = true

	-- Cover first, move second - see JAIL_COVER_TIME. Backgrounded so the
	-- admin who ran :jail still gets their confirmation immediately
	-- instead of waiting out the transition playing on someone else's
	-- screen.
	Remote.AdminScreenFade:FireClient(target)
	task.spawn(function()
		task.wait(JAIL_COVER_TIME)
		-- Re-checked after the wait: they may have been released, or
		-- respawned into a different character, while the cover was
		-- sliding down. Teleporting a stale HumanoidRootPart would drop
		-- a freed player back into the cell.
		if not jailedUserIds[target.UserId] then return end
		if target.Character ~= character or hrp.Parent == nil then return end
		hrp.CFrame = JAIL_SPAWN_CFRAME
		-- Shut behind them. Only ever called from server code, so a
		-- jailed player has no way to open it themselves.
		setCellDoorOpen(false)
	end)
	return true
end

-- Sends them back to the game's normal spawn rather than trying to
-- remember exactly where they were before being jailed - simpler, and
-- always safe for what's meant to be a temporary punishment anyway.
local function unjailPlayer(target)
	if not jailedUserIds[target.UserId] then return false end
	jailedUserIds[target.UserId] = nil
	-- Swung open the moment an admin releases them - the visible half of
	-- "only an admin can open this". It closes again once nobody is left
	-- inside, at the end of this function.
	setCellDoorOpen(true)
	local character = target.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return true end
	-- FindFirstChildOfClass only checks DIRECT children of workspace - a
	-- SpawnLocation nested inside a model/folder (as it is here, e.g.
	-- under the Lobby model) was never found that way, which is
	-- exactly why this warned "no SpawnLocation found" every time even
	-- though one genuinely exists. FindFirstChildWhichIsA's second
	-- argument makes it search every descendant instead of just direct
	-- children.
	local spawnLocation = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	if spawnLocation then
		-- The trip OUT is the one that most needed covering: sealed cell
		-- to open sky is the biggest lighting jump in the game, and it
		-- used to land as "every shadow is far too dark" for a second or
		-- two before snapping right. Same cover-then-move ordering as
		-- jailPlayer above.
		Remote.AdminScreenFade:FireClient(target)
		task.spawn(function()
			task.wait(JAIL_COVER_TIME)
			if target.Character ~= character or hrp.Parent == nil then return end
			hrp.CFrame = spawnLocation.CFrame + Vector3.new(0, 5, 0)

			-- Shut once the cell is actually empty. Checked rather than
			-- assumed: releasing one of two jailed players should not
			-- leave the door standing open for the one still in there.
			task.wait(1)
			if next(jailedUserIds) == nil then
				setCellDoorOpen(false)
			end
		end)
	else
		warn("[AdminServer] No SpawnLocation found anywhere in Workspace - unjailed player left in the jail cell")
	end
	return true
end

-- =====================================================================
-- Invis / uninvis - stores each part's ORIGINAL Transparency before
-- hiding it, so :uninvis restores exactly what it was rather than
-- assuming everything started at 0 (not true for accessories/clothing
-- that are already partially transparent by design). Like :freeze and
-- :god, this only covers the CURRENT character.
-- =====================================================================
local invisibleUserIds = {} -- [userId] = {[part] = {Transparency=, CanCollide=, CanTouch=}, ...}

-- Also drops CanCollide/CanTouch alongside Transparency (restoring all
-- three on uninvis) - Transparency alone only hides a part visually, it
-- doesn't stop anyone from walking into/standing on top of it, or from
-- physically-invisible-but-still-solid parts blocking movement or
-- tripping .Touched-based triggers. This matters most for :spectate
-- (below), which makes the spectating admin invisible for the duration -
-- without this, their own frozen body was still a solid, climbable
-- obstacle sitting right where they started spectating from.
local function setInvisible(target, invisible)
	local userId = target.UserId
	local character = target.Character
	if not character then return false end

	if invisible then
		if invisibleUserIds[userId] then return true end
		local originals = {}
		for _, part in ipairs(character:GetDescendants()) do
			if part:IsA("BasePart") then
				originals[part] = {Transparency = part.Transparency, CanCollide = part.CanCollide, CanTouch = part.CanTouch}
				part.Transparency = 1
				part.CanCollide = false
				part.CanTouch = false
			elseif part:IsA("Decal") then
				originals[part] = {Transparency = part.Transparency}
				part.Transparency = 1
			end
		end
		invisibleUserIds[userId] = originals
		-- The overhead name tag is a BillboardGui, which the sweep above can't hide.
		character:SetAttribute("AdminHidden", true)
		local tag = character:FindFirstChild("NameTag", true)
		if tag and tag:IsA("BillboardGui") then tag.Enabled = false end
	else
		local originals = invisibleUserIds[userId]
		if not originals then return true end
		for part, original in pairs(originals) do
			if part.Parent then
				part.Transparency = original.Transparency
				if original.CanCollide ~= nil then part.CanCollide = original.CanCollide end
				if original.CanTouch ~= nil then part.CanTouch = original.CanTouch end
			end
		end
		invisibleUserIds[userId] = nil
		character:SetAttribute("AdminHidden", nil)
		local tag = character:FindFirstChild("NameTag", true)
		if tag and tag:IsA("BillboardGui") then tag.Enabled = true end
	end
	-- Everyone currently connected (including the target's own client)
	-- needs to know, so PlayerInfo.lua can hide/restore just this one
	-- player's overhead tag - see the comment above Remote.AdminInvisStatus's
	-- own declaration for why that can't just ride along with the
	-- Transparency sweep above.
	for _, plr in ipairs(Players:GetPlayers()) do
		Remote.AdminInvisStatus:FireClient(plr, target, invisible)
	end
	return true
end

-- =====================================================================
-- Fly - the actual flight control lives client-side, in AdminClient.lua
-- (a real Tool+LocalScript can't be built from a running server script -
-- Source isn't scriptable at runtime). This just tracks who currently
-- has flight PERMISSION and tells their client to turn it on/off - the
-- client also lets a flying player pause/resume the actual flight
-- mechanic on their own via a "Disable Fly"/"Enable Fly" button without
-- that touching this permission at all, so :fly toggling it back off
-- later still works exactly the same regardless of whichever state the
-- button last left the actual flying in.
-- =====================================================================
local flyingUserIds = {}

local function setFlying(target, enabled)
	flyingUserIds[target.UserId] = enabled or nil
	Remote.AdminSetFlying:FireClient(target, enabled)
	return true
end


-- =====================================================================
-- :noclip (a tool that walks through walls), and :giant
-- =====================================================================
-- The No Clip tool is made here (nothing to place in ServerStorage). AdminClient sees it in the
-- character: while it's held the player flies through walls, and clicking teleports to the mouse.
local NO_CLIP_TOOL = "No Clip"
local function toggleNoClipTool(target: Player): boolean
	local found = false
	for _, holder in { target:FindFirstChildOfClass("Backpack"), target.Character } do
		if holder then
			for _, child in holder:GetChildren() do
				if child:IsA("Tool") and child:GetAttribute("NoClipTool") then
					child:Destroy()
					found = true
				end
			end
		end
	end
	if found then
		return false
	end
	local tool = Instance.new("Tool")
	tool.Name = NO_CLIP_TOOL
	tool.ToolTip = "Hold to fly through walls. Click to teleport."
	tool.RequiresHandle = false
	tool.CanBeDropped = false
	tool:SetAttribute("NoClipTool", true)
	tool:SetAttribute("DisplayName", NO_CLIP_TOOL)
	tool.Parent = target:FindFirstChildOfClass("Backpack") or target
	return true
end

-- Scales the whole character (1 = normal). Respawning resets it.
local function setGiantScale(target: Player, size: number): boolean
	local character = target.Character
	if not character then
		return false
	end
	local ok = pcall(function()
		character:ScaleTo(size)
	end)
	return ok
end
local function isGiant(target: Player): boolean
	local character = target.Character
	if not character then
		return false
	end
	local ok, scale = pcall(function()
		return character:GetScale()
	end)
	return ok and scale > 1.5
end

-- =====================================================================
-- Spectate - the spectating admin is made invisible and frozen for the
-- duration (so they can't be seen, and can't move/interact with anyone
-- while just watching), restored to their exact previous position AND
-- previous invis/frozen state the moment they stop. Ending only ever
-- happens via the admin's own "Stop Spectating" button (Remote.AdminStopSpectating)
-- now, not a separate typed :unspectate command.
--
-- On top of invis (which also drops CanCollide/CanTouch - see
-- setInvisible), the admin's HumanoidRootPart is ALSO teleported way up
-- into empty space for the duration - belt-and-suspenders on top of the
-- collision fix, so there's genuinely nothing solid left sitting at
-- their old spot even in some edge case CanCollide/CanTouch doesn't
-- cover. A different height (and sign) than JAIL_CFRAME (-300) so this
-- never lands inside the jail cell itself. PreCFrame (captured below, from BEFORE
-- this teleport) is what makes restoring to the exact original spot on
-- stop work regardless.
-- =====================================================================
local SPECTATE_LIMBO_CFRAME = CFrame.new(0, 5000, 0)
local spectatingState = {} -- [adminUserId] = {Target=, PreCFrame=, PreInvis=, PreFrozen=}

-- Bare-forward-declared (see the comment further down, above
-- Remote.AdminStopSpectating's own listener, for why this pattern is needed at
-- all) - startSpectating below needs both to enforce "can't spectate and
-- control at the same time", but neither is assigned/populated until
-- further down in the file.
local stopControlling
local controllingUserIds

local function stopSpectatingServer(admin)
	local state = spectatingState[admin.UserId]
	if not state then return end
	spectatingState[admin.UserId] = nil

	-- Only undoes what spectating itself applied - if the admin was
	-- already invis/frozen (by their own or another admin's earlier
	-- command) before this ever started, that state is left exactly as
	-- it was rather than being switched off underneath them.
	if not state.PreFrozen then
		setFrozen(admin, false)
	end
	if not state.PreInvis then
		setInvisible(admin, false)
	end
	local character = admin.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and state.PreCFrame then
		hrp.CFrame = state.PreCFrame
	end

	Remote.AdminSpectate:FireClient(admin, nil)
end

local function startSpectating(admin, target)
	-- Can't spectate and control at the same time - restores the admin to
	-- their normal pre-control state FIRST (position, invis, frozen) so
	-- the snapshot taken below reflects their real state, not the
	-- parked-in-limbo one control left them in.
	if controllingUserIds[admin.UserId] then
		stopControlling(admin)
	end

	local character = admin.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end

	-- Already spectating someone - swap targets in place rather than
	-- stacking a second "previous state" snapshot on top of the first,
	-- which would restore to the wrong place/state once they finally
	-- stop.
	if spectatingState[admin.UserId] then
		spectatingState[admin.UserId].Target = target
		Remote.AdminSpectate:FireClient(admin, target)
		return true
	end

	spectatingState[admin.UserId] = {
		Target = target,
		PreCFrame = hrp.CFrame,
		PreInvis = invisibleUserIds[admin.UserId] ~= nil,
		PreFrozen = frozenUserIds[admin.UserId] ~= nil,
	}
	hrp.CFrame = SPECTATE_LIMBO_CFRAME
	setInvisible(admin, true)
	setFrozen(admin, true)
	Remote.AdminSpectate:FireClient(admin, target)
	return true
end

-- Remote.AdminStopSpectating's own .OnServerEvent listener is registered much
-- further down (right alongside Remote.AdminStopControlling's), after
-- logCommand/sendFeedback are actually declared as locals - a reference
-- to either from here, this early in the file, would resolve to a
-- nonexistent GLOBAL of the same name instead of those locals (Lua only
-- treats a name as referring to a local declared LATER in the same
-- chunk if it's been forward-declared bare, like `local x` with no
-- value yet - a plain `local function f()` doesn't create the name
-- until that exact line runs), and calling that nil global is exactly
-- what made the Stop Spectating/Stop Controlling buttons silently crash
-- before ever reaching stopSpectatingServer/stopControlling - which is
-- also why the admin's invis/frozen state and the target's "being
-- controlled" indicator were never actually getting restored/cleared.

-- =====================================================================
-- Control player - :controlplayer puppets a target's movement by
-- calling Humanoid:Move directly (the SAME call the engine itself makes
-- from a player's own input), driven by the admin's own WASD forwarded
-- over AdminControlMove every Heartbeat, rather than fighting the
-- Humanoid with an external BodyVelocity+PlatformStand - that combination
-- was what caused the stiff, un-animated pose and the target sinking
-- halfway into the floor (PlatformStand disables the Humanoid's own
-- ground-following entirely, and a zero-Y-force BodyVelocity doesn't
-- replace that). Driving the real Humanoid instead keeps normal ground
-- physics, animations, and jump all working exactly like the target
-- walking themselves. The controlling admin's OWN character is made
-- invisible/uncollidable/frozen for the duration (same as :spectate) so
-- they can't be seen, walked into, or seen still wandering around while
-- puppeting someone else - restored to their exact previous invis/frozen
-- state when they stop. Ends only via the admin's own "Stop Controlling"
-- button (Remote.AdminStopControlling), matching :spectate's own design above.
-- =====================================================================
-- controllingUserIds itself was already bare-forward-declared above (see
-- that comment) so startSpectating could reference it - this just
-- assigns the real table now, rather than shadowing it with a second
-- local of the same name.
controllingUserIds = {} -- [adminUserId] = target Player
local controlledByAdmin = {} -- [targetUserId] = admin Player
local controllingAdminPreState = {} -- [adminUserId] = {PreCFrame=, PreInvis=, PreFrozen=}
local controlledTargetPreGod = {} -- [targetUserId] = true if they were ALREADY in god mode before control started (so stopControlling doesn't strip a god mode they had for some other reason)
-- [targetUserId] = true if they were frozen (Anchored) right before this
-- control session started - :controlplayer needs them unanchored so
-- Humanoid:Move can actually move them at all (Anchored blocks ALL
-- movement, admin-driven or not), and this is what lets stopControlling
-- put them back exactly how it found them.
local controlledTargetPreFrozen = {}

stopControlling = function(admin)
	local target = controllingUserIds[admin.UserId]
	if not target then return end
	controllingUserIds[admin.UserId] = nil
	controlledByAdmin[target.UserId] = nil

	local targetHrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if targetHrp then
		-- Hands physics simulation back to the target's own client (the
		-- normal default) now that the server's done driving it - see the
		-- comment in startControlling for why this needed touching at all.
		local ok = pcall(function() targetHrp:SetNetworkOwnershipAuto() end)
		if not ok then
			pcall(function() targetHrp:SetNetworkOwner(target) end)
		end
	end
	local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid:Move(Vector3.new(0, 0, 0), false)
	end

	if not controlledTargetPreGod[target.UserId] then
		setGodMode(target, false)
	end
	controlledTargetPreGod[target.UserId] = nil

	-- Puts the freeze back exactly the way startControlling found it - if
	-- they weren't frozen to begin with, this is a no-op (setFrozen would
	-- just unfreeze an already-unfrozen target).
	if controlledTargetPreFrozen[target.UserId] then
		setFrozen(target, true)
	end
	controlledTargetPreFrozen[target.UserId] = nil

	local preState = controllingAdminPreState[admin.UserId]
	controllingAdminPreState[admin.UserId] = nil
	if preState then
		if not preState.PreFrozen then setFrozen(admin, false) end
		if not preState.PreInvis then setInvisible(admin, false) end
		local adminCharacter = admin.Character
		local adminHrp = adminCharacter and adminCharacter:FindFirstChild("HumanoidRootPart")
		if adminHrp and preState.PreCFrame then
			adminHrp.CFrame = preState.PreCFrame
		end
	end

	Remote.AdminControlTargetStatus:FireClient(target, false)
	Remote.AdminControlPlayer:FireClient(admin, nil)
end

local function startControlling(admin, target)
	-- Can't spectate and control at the same time - restores the admin to
	-- their normal pre-spectate state FIRST (position, invis, frozen) so
	-- the snapshot taken below reflects their real state, not the
	-- parked-in-limbo one spectating left them in.
	if spectatingState[admin.UserId] then
		stopSpectatingServer(admin)
	end

	local character = target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local targetHrp = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not targetHrp then return false end
	local adminHrp = admin.Character and admin.Character:FindFirstChild("HumanoidRootPart")
	if not adminHrp then return false end

	-- By default a character's physics are simulated on ITS OWN owning
	-- client, for responsiveness - which is exactly what made the
	-- server's own Humanoid:Move calls below feel laggy/delayed and
	-- "fight" the target's own client (Roblox hands ownership back to a
	-- character's associated player within a frame or two of anything
	-- else trying to claim it, unless the server explicitly takes and
	-- keeps it). Taking ownership here makes the server fully
	-- authoritative for movement while controlling, so its Move calls
	-- apply immediately with no competing client-side prediction.
	pcall(function() targetHrp:SetNetworkOwner(nil) end)

	-- Already controlled by someone else - hand control over cleanly
	-- rather than ending up with two admins fighting over the same
	-- target's movement.
	local previousAdmin = controlledByAdmin[target.UserId]
	if previousAdmin and previousAdmin ~= admin then
		stopControlling(previousAdmin)
	end
	-- Re-running against a target this same admin already controls is a
	-- no-op.
	if controllingUserIds[admin.UserId] == target then
		return true
	end

	-- Anchored (frozen) blocks ALL movement of the HumanoidRootPart, not
	-- just the target's own input - including the server's own
	-- Humanoid:Move calls below, which would otherwise silently do
	-- nothing for the whole session. Unfreezing here (and remembering to
	-- put it back in stopControlling) is what lets an admin control a
	-- target who happened to already be frozen at all. Computed only
	-- here, after both early-outs above - doing it any earlier would
	-- either leak an unfrozen target with no session left to re-freeze
	-- them (if this function bails out first) or clobber the real
	-- pre-frozen flag with "false" on a harmless re-run against a target
	-- already being controlled (who's already unfrozen for that reason).
	controlledTargetPreFrozen[target.UserId] = frozenUserIds[target.UserId] == true
	if controlledTargetPreFrozen[target.UserId] then
		setFrozen(target, false)
	end

	controllingAdminPreState[admin.UserId] = {
		PreCFrame = adminHrp.CFrame,
		PreInvis = invisibleUserIds[admin.UserId] ~= nil,
		PreFrozen = frozenUserIds[admin.UserId] ~= nil,
	}
	-- Same belt-and-suspenders limbo teleport as :spectate above, on top
	-- of invis's own CanCollide/CanTouch drop - reused rather than a
	-- second constant, since any number of admins can safely share the
	-- exact same out-of-the-way spot (none of them can see or collide
	-- with anything there anyway, and none of them are looking at their
	-- own camera while spectating/controlling).
	adminHrp.CFrame = SPECTATE_LIMBO_CFRAME
	setInvisible(admin, true)
	setFrozen(admin, true)

	-- Keeps the target from dying (and respawning, which would leave the
	-- admin controlling a now-destroyed character - the source of the
	-- reported "camera stuck, glitchy movement" once that happened) for
	-- as long as control lasts. Combined with the client-side Reset
	-- Character button being disabled below, there's no way for the
	-- target to end up respawning out from under an active control
	-- session.
	controlledTargetPreGod[target.UserId] = godModeUserIds[target.UserId] ~= nil
	setGodMode(target, true)

	controllingUserIds[admin.UserId] = target
	controlledByAdmin[target.UserId] = admin

	Remote.AdminControlTargetStatus:FireClient(target, true)
	Remote.AdminNotice:FireClient(target, "You are being controlled by staff", "Leaving the game is punishable.")
	Remote.AdminControlPlayer:FireClient(admin, target)
	return true
end

AdminControlMove.OnServerEvent:Connect(function(admin, moveDirection, jumpRequested)
	local target = controllingUserIds[admin.UserId]
	if not target then return end
	if typeof(moveDirection) ~= "Vector3" then return end
	local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end
	-- Clamped server-side rather than trusting the magnitude a client
	-- reports - a modified client sending an oversized vector shouldn't
	-- be able to move the controlled player faster than a normal walk.
	local horizontal = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	if horizontal.Magnitude > 1 then
		horizontal = horizontal.Unit
	end
	humanoid:Move(horizontal, false)
	if jumpRequested == true then
		humanoid.Jump = true
	end
end)

-- Keeps the controlling admin's own body on top of the person they're
-- controlling.
--
-- Nothing about the camera needed this - but ClickDetector and
-- ProximityPrompt both measure MaxActivationDistance from the LOCAL
-- PLAYER'S CHARACTER, not from the camera. The admin's real body is
-- parked, invisible and anchored, wherever they were standing when
-- control started, so every door and prompt the controlled character
-- walked up to was still tens of studs away as far as Roblox was
-- concerned, and simply would not fire. That is why you could drive
-- someone up to a door and not open it.
--
-- Moving the parked body along fixes both at once and costs nothing:
-- it is already invisible and non-collidable, so it cannot be seen,
-- bumped into, or stood on while it rides along.
--
-- Anchored parts still accept a CFrame write - being anchored stops the
-- physics solver moving them, not the script.
--
-- stopControlling restores PreCFrame, so the admin is still returned to
-- exactly where they started.
RunService.Heartbeat:Connect(function()
	for adminUserId, target in pairs(controllingUserIds) do
		local admin = Players:GetPlayerByUserId(adminUserId)
		local adminHrp = admin and admin.Character
			and admin.Character:FindFirstChild("HumanoidRootPart")
		local targetHrp = target and target.Parent and target.Character
			and target.Character:FindFirstChild("HumanoidRootPart")
		if adminHrp and targetHrp then
			adminHrp.CFrame = targetHrp.CFrame
		end
	end
end)

-- Remote.AdminStopControlling's own .OnServerEvent listener is registered
-- further down too, alongside Remote.AdminStopSpectating's - see the comment
-- above that one for why it can't live up here.

-- Resetting/respawning mid-spectate or mid-control leaves nothing
-- meaningful to restore to (the admin's old character - the one that was
-- actually made invisible/frozen - is already gone), and trying to
-- re-apply that to a brand new character on the fly is exactly the kind
-- of state that used to "glitch out". Simplest and most robust: treat the
-- admin's own respawn as an implicit stop, cleanly ending whichever of
-- the two was active so the fresh character starts from a normal,
-- interactable state instead of an inconsistent one.
local function watchAdminRespawnForSpectateAndControl(adminPlayer)
	adminPlayer.CharacterAdded:Connect(function(newCharacter)
		-- Invisibility the admin chose carries over to the new body (going into a run or back to
		-- the lobby respawns you), so the next toggle really does bring you - and your name tag -
		-- back. Invisibility that only spectate/control applied ends with them.
		local userId = adminPlayer.UserId
		local wasInvisible = invisibleUserIds[userId] ~= nil
		local spectate = spectatingState[userId]
		local control = controllingAdminPreState[userId]
		local chosen = wasInvisible and ((spectate == nil and control == nil)
			or (spectate ~= nil and spectate.PreInvis) or (control ~= nil and control.PreInvis))
		invisibleUserIds[userId] = nil
		if chosen then
			task.spawn(function()
				newCharacter:WaitForChild("Head", 10)
				task.wait(0.5) -- after the name tag, accessories and body parts arrive
				if adminPlayer.Character == newCharacter and not invisibleUserIds[userId] then
					setInvisible(adminPlayer, true)
				end
			end)
		elseif wasInvisible then
			for _, plr in ipairs(Players:GetPlayers()) do
				Remote.AdminInvisStatus:FireClient(plr, adminPlayer, false)
			end
		end
		if spectatingState[adminPlayer.UserId] then
			spectatingState[adminPlayer.UserId] = nil
			Remote.AdminSpectate:FireClient(adminPlayer, nil)
		end
		if controllingUserIds[adminPlayer.UserId] then
			local target = controllingUserIds[adminPlayer.UserId]
			controllingUserIds[adminPlayer.UserId] = nil
			controlledByAdmin[target.UserId] = nil
			controllingAdminPreState[adminPlayer.UserId] = nil
			if not controlledTargetPreGod[target.UserId] then
				setGodMode(target, false)
			end
			controlledTargetPreGod[target.UserId] = nil
			if controlledTargetPreFrozen[target.UserId] then
				setFrozen(target, true)
			end
			controlledTargetPreFrozen[target.UserId] = nil
			local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
			if humanoid then humanoid:Move(Vector3.new(0, 0, 0), false) end
			Remote.AdminControlTargetStatus:FireClient(target, false)
			Remote.AdminControlPlayer:FireClient(adminPlayer, nil)
		end
	end)
end
for _, existingPlayer in ipairs(Players:GetPlayers()) do
	watchAdminRespawnForSpectateAndControl(existingPlayer)
end
Players.PlayerAdded:Connect(watchAdminRespawnForSpectateAndControl)

-- Handles the TARGET side respawning, rather than the admin's own -
-- :spectate is meant to keep following whoever it's pointed at even
-- through a death/respawn (they can still fully control their own
-- character - spectating never restricts them - so this just re-locks
-- the camera onto their fresh character once it exists). :controlplayer
-- is the opposite: the god mode + disabled Reset button above should
-- make this unreachable while controlling, but if a respawn ever
-- slipped through anyway, cleanly ending control instead of leaving the
-- admin stuck looking at/driving a now-destroyed character is far
-- better than leaving that glitched.
local function watchTargetRespawnForSpectateAndControl(targetPlayer)
	targetPlayer.CharacterAdded:Connect(function(newCharacter)
		for adminUserId, state in pairs(spectatingState) do
			if state.Target == targetPlayer then
				local adminPlayer = Players:GetPlayerByUserId(adminUserId)
				if adminPlayer then
					task.spawn(function()
						local humanoid = newCharacter:WaitForChild("Humanoid", 5)
						-- Re-checked after the wait - the admin could have
						-- stopped spectating (or switched targets) while
						-- this was waiting for the new Humanoid to exist.
						local currentState = spectatingState[adminUserId]
						if humanoid and currentState and currentState.Target == targetPlayer then
							Remote.AdminSpectate:FireClient(adminPlayer, targetPlayer)
						end
					end)
				end
			end
		end

		local controllingAdmin = controlledByAdmin[targetPlayer.UserId]
		if controllingAdmin then
			stopControlling(controllingAdmin)
		end
	end)
end
for _, existingPlayer in ipairs(Players:GetPlayers()) do
	watchTargetRespawnForSpectateAndControl(existingPlayer)
end
Players.PlayerAdded:Connect(watchTargetRespawnForSpectateAndControl)

-- None of god mode/jail/invis/fly persist to a DataStore - they're
-- session-only toggles - so a stale true left behind after someone
-- disconnects (mid-flight, mid-jail, etc.) would otherwise silently
-- flip the WRONG way the next time the same command runs against them
-- after they rejoin (e.g. :fly reading a leftover "already flying" and
-- turning it off instead of on, with no client actually flying to
-- match). Clearing all of it on disconnect keeps a rejoin starting from
-- a clean slate.
Players.PlayerRemoving:Connect(function(player)
	local userId = player.UserId
	local godConn = godModeConnections[userId]
	if godConn then
		godConn:Disconnect()
		godModeConnections[userId] = nil
	end
	godModeUserIds[userId] = nil
	jailedUserIds[userId] = nil
	invisibleUserIds[userId] = nil
	flyingUserIds[userId] = nil
	-- Which log view they had open is meaningless once they're gone, and
	-- leaving it behind would keep a row per departed player forever.
	lastLogFilter[userId] = nil

	-- If the leaving player was mid-spectate, there's nothing left to
	-- restore them to - just drop the record. If they were the one being
	-- WATCHED, whichever admin was spectating them gets snapped back
	-- (restored position/invis/frozen state) rather than left staring at
	-- a spot where a now-gone player used to be.
	spectatingState[userId] = nil
	for adminUserId, state in pairs(spectatingState) do
		if state.Target == player then
			local adminPlayer = Players:GetPlayerByUserId(adminUserId)
			if adminPlayer then stopSpectatingServer(adminPlayer) end
		end
	end

	-- Same idea for :controlplayer - if the leaving player was
	-- controlling someone, that target gets their own input back; if the
	-- leaving player was the one being controlled, the constraints they
	-- were carrying would otherwise be destroyed with their character
	-- anyway, but the controlling admin's own indicator/camera lock still
	-- needs to be cleared.
	if controllingUserIds[userId] then
		stopControlling(player)
	end
	local controllingAdmin = controlledByAdmin[userId]
	if controllingAdmin then
		stopControlling(controllingAdmin)
	end
end)

-- =====================================================================
-- Inventory - :viewinv/:checkinv reads a target's current Backpack plus
-- whatever Tool is currently equipped in their Character (which isn't
-- inside Backpack while held), with nothing needed from the target's
-- own client; :clearinv/:strip removes all of it the same way.
-- =====================================================================
local function getTargetTools(target)
	local tools = {}
	local backpack = target:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, tool in ipairs(backpack:GetChildren()) do
			if tool:IsA("Tool") then
				table.insert(tools, tool)
			end
		end
	end
	if target.Character then
		for _, tool in ipairs(target.Character:GetChildren()) do
			if tool:IsA("Tool") then
				table.insert(tools, tool)
			end
		end
	end
	return tools
end

local function buildInventoryEntries(target)
	local entries = {}
	for _, tool in ipairs(getTargetTools(target)) do
		table.insert(entries, {
			-- Id carries the actual Tool instance, not just a name/index -
			-- Instances pass through RemoteEvents fine, and this is what
			-- lets each row's own Remove button (wired up client-side)
			-- unambiguously identify exactly which Tool to destroy, even
			-- if the target is holding two of the same-named item.
			Id = tool,
			Line1 = tool.Name,
			Line2 = (tool.Parent == target.Character) and "currently equipped" or "in backpack",
		})
	end
	return entries
end

local function clearTargetInventory(target)
	local count = 0
	for _, tool in ipairs(getTargetTools(target)) do
		tool:Destroy()
		count += 1
	end
	return count
end

-- Shared by :viewinv and the per-row Remove button below (which re-sends
-- the list after removing one item, the same refresh-in-place pattern
-- the ban/mute Modify popups already use).
local function sendInventoryList(admin, target)
	local entries = buildInventoryEntries(target)
	Remote.AdminInventoryList:FireClient(admin, "Inventory - " .. target.Name .. " (" .. #entries .. ")", entries)
end

-- Resolves which Player a given Tool currently belongs to, whether it's
-- sitting in their Backpack (parented directly to the Player itself) or
-- actively equipped in their Character - needed by the Remove-button
-- handler below to know whose list to re-send after removing one item.
local function findToolOwner(tool)
	if not tool or not tool.Parent then return nil end
	if tool.Parent:IsA("Backpack") then
		local owner = tool.Parent.Parent
		return (owner and owner:IsA("Player")) and owner or nil
	end
	return Players:GetPlayerFromCharacter(tool.Parent)
end

-- =====================================================================
-- Give - clones a named Tool from a ServerStorage folder (looked up near
-- the top of this file, before tierInfo, since Remote.GetAdminInfo's response
-- needs its contents too) into the target's Backpack. Populate
-- ServerStorage.AdminGiveableItems with whatever Tools should be handed
-- out this way - :give matches by name, case-insensitively, same
-- partial-match convention as :setrank's rank lookup.
-- =====================================================================
-- Matches against BOTH the raw Tool name ("glock17") and its display
-- name ("Glock 17") - the client's autocomplete now suggests display
-- names, but an admin who types the raw technical name straight in
-- (skipping the dropdown) should still find it.
local function findGiveableItem(query)
	if typeof(query) ~= "string" or query == "" then return nil, nil end
	local lowerQuery = string.lower(query)
	local items = giveableItemsFolder:GetChildren()

	for _, item in ipairs(items) do
		if string.lower(item.Name) == lowerQuery or string.lower(getItemDisplayName(item)) == lowerQuery then
			return item, nil
		end
	end

	local matches = {}
	for _, item in ipairs(items) do
		local displayName = getItemDisplayName(item)
		if string.sub(string.lower(item.Name), 1, #lowerQuery) == lowerQuery
			or string.sub(string.lower(displayName), 1, #lowerQuery) == lowerQuery then
			table.insert(matches, item)
		end
	end
	if #matches == 1 then
		return matches[1], nil
	elseif #matches > 1 then
		local names = {}
		for _, item in ipairs(matches) do table.insert(names, getItemDisplayName(item)) end
		return nil, "Multiple items match \"" .. query .. "\": " .. table.concat(names, ", ")
	end
	return nil, nil
end

local function giveItem(target, query)
	local item, err = findGiveableItem(query)
	if err then return false, err end
	if not item then
		return false, "No giveable item found matching \"" .. query .. "\" - add it to ServerStorage.AdminGiveableItems first"
	end
	local clone = item:Clone()
	-- Some free-model Tool assets are packaged inside an outer wrapper
	-- (a Model/Folder holding the real Tool alongside other supporting
	-- parts) rather than being the Tool itself. Handing out that wrapper
	-- as-is isn't a real, equippable item at all - Roblox's own Backpack
	-- (and every inventory list this admin system builds) only ever
	-- recognizes actual Tool instances - which is exactly what made
	-- :give report success while the item never showed up anywhere,
	-- for any item placed in ServerStorage.AdminGiveableItems this way.
	-- Unwrap automatically by handing out the first real Tool found
	-- nested inside instead, if the clone itself isn't already one.
	if not clone:IsA("Tool") then
		local innerTool = clone:FindFirstChildWhichIsA("Tool", true)
		if innerTool then
			innerTool.Parent = nil
			clone:Destroy()
			clone = innerTool
		end
	end
	-- Carries the same polished name :give's own autocomplete already
	-- shows ("Glock 17", "Btools") onto the actual Tool instance, as a
	-- plain Attribute - PlayerInfo.lua's own inventory display reads this
	-- first (falling back to its own prettify guess for tools that were
	-- never given this way) so the hotbar/full list show the same nice
	-- name instead of the raw lowercase Tool.Name.
	clone:SetAttribute("DisplayName", getItemDisplayName(item))
	local destination = target:FindFirstChildOfClass("Backpack")
	clone.Parent = destination or target
	return true, getItemDisplayName(item)
end

-- =====================================================================
-- Goto / bring - CFrame is set directly on the mover's own
-- HumanoidRootPart, so this never trusts a client-reported position for
-- either the admin or the target.
-- =====================================================================
local function gotoPlayer(admin, target)
	local adminHrp = admin.Character and admin.Character:FindFirstChild("HumanoidRootPart")
	local targetHrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not adminHrp or not targetHrp then return false end
	adminHrp.CFrame = CFrame.new(targetHrp.Position + Vector3.new(3, 0, 0))
	return true
end

local function bringPlayer(admin, target)
	local adminHrp = admin.Character and admin.Character:FindFirstChild("HumanoidRootPart")
	local targetHrp = target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	if not adminHrp or not targetHrp then return false end
	targetHrp.CFrame = adminHrp.CFrame * CFrame.new(0, 0, -3)
	return true
end

-- =====================================================================
-- Warn - the popup itself is drawn client-side (AdminClient.lua),
-- listening on every player's client since the target of a warn is
-- often not staff at all.
-- =====================================================================
local function warnPlayer(target, reason, count)
	Remote.AdminNotice:FireClient(
		target,
		"You have been warned (#" .. count .. ")",
		reason,
		"3 warnings results in a kick, 5 in a 24 hour ban, 7 in a permanent ban."
	)
end

-- =====================================================================
-- Command log - captures who ran what on whom, persisted to a
-- DataStore so it survives a server restart (stopping/restarting Play
-- in Studio, or a live server shutting down) instead of resetting to
-- empty every session. Kept as one array under a single fixed key
-- (matching the whole log's own MAX_LOG_ENTRIES cap, so it never grows
-- large enough to threaten DataStore's per-key size limit) rather than
-- one key per entry, since the whole log is always read/shown as one
-- list anyway. Viewable in-panel via :cmdlogs (everything) and
-- :playerlogs [admin] (filtered to one admin, so abuse of a specific
-- staff member's commands can be reviewed on its own).
-- =====================================================================
local CommandLogStore = getStore("RinseCycleCommandLog")
local COMMAND_LOG_KEY = "Log"
-- Raised from 200 alongside the date filter and paging below. Browsing
-- the log by day is only worth having if the log actually reaches back
-- more than a day or two, and 200 entries is a single busy session.
-- 1000 entries is roughly 200KB serialised, comfortably inside
-- DataStore's 4MB per-key limit, and paging means the size never has to
-- reach the client's UI all at once.
local MAX_LOG_ENTRIES = 1000

-- Every entry carries a stable Id, handed out from here. Removal needs
-- to name ONE specific entry, and a position in the array can't do that
-- safely: between the client receiving a list and clicking Remove on it,
-- another command can be logged, or the MAX_LOG_ENTRIES cap can drop the
-- oldest entry and shift everything down by one - either of which would
-- turn "delete row 12" into deleting the wrong row. An Id can't drift.
local nextLogId = 1

local commandLog = {}
do
	local success, savedLog = pcall(function()
		return CommandLogStore:GetAsync(COMMAND_LOG_KEY)
	end)
	if success and typeof(savedLog) == "table" then
		commandLog = savedLog
		-- Entries saved before Ids existed get one now, and the counter
		-- resumes past the highest already in use so a restart can't
		-- reissue an Id that's still on an older entry.
		for _, entry in ipairs(commandLog) do
			if type(entry.Id) == "number" then
				nextLogId = math.max(nextLogId, entry.Id + 1)
			end
		end
		for _, entry in ipairs(commandLog) do
			if type(entry.Id) ~= "number" then
				entry.Id = nextLogId
				nextLogId += 1
			end
		end
		log("[AdminServer] Loaded " .. #commandLog .. " persisted command log entries")
	elseif success then
		-- [DEBUG] savedLog was nil, not a load failure - either nothing
		-- has ever been saved under this key yet, or this build of the
		-- script (with persistence at all) hasn't run in this place
		-- before. Printed either way so it's obvious from the Output
		-- whether persistence is even active, instead of silently
		-- starting fresh with no visible signal.
		log("[AdminServer] No persisted command log found (savedLog=" .. tostring(savedLog) .. ") - starting empty")
	else
		dsWarn("[AdminServer] Failed to load persisted command log: " .. tostring(savedLog))
	end
end

-- Backgrounded like every other DataStore write above - logCommand calls
-- this synchronously on essentially every admin action, so a blocking
-- SetAsync here was adding real lag to every single command, not just
-- list opens/edits. commandLog itself (the in-memory table) is already
-- updated before this runs, so :cmdlogs/:playerlogs and the client
-- response never waited on this in the first place once it's async - only
-- the persisted copy lags a moment behind now.
local function saveCommandLog()
	task.spawn(function()
		local success, err = pcall(function()
			CommandLogStore:SetAsync(COMMAND_LOG_KEY, commandLog)
		end)
		if success then
			-- [DEBUG] Confirms the write actually completed, since
			-- logCommand's own print below always fires regardless of
			-- whether this save succeeded - without this there was no way
			-- to tell "persistence is silently failing" apart from
			-- "persistence is working but the paste in Studio is stale"
			-- just from the Output log.
			log("[AdminServer] Command log saved (" .. #commandLog .. " entries)")
		else
			dsWarn("[AdminServer] Failed to persist command log: " .. tostring(err))
		end
	end)
end

-- Wipes the whole log, in memory and in the DataStore. Deliberately NOT
-- an admin command and not in the panel: erasing an audit trail isn't a
-- moderation action, and there's no rank that should be able to do it
-- from inside a running game. It exists purely so a place full of
-- testing noise can be cleared before real moderation starts.
--
-- Reached the same way as the AdminTierOverride testing hook above - the
-- Studio Command Bar with the context dropdown set to Server:
--   game.ServerStorage.WipeCommandLog:Invoke()
--
-- A BindableFunction in ServerStorage is what keeps it out of reach:
-- ServerStorage never replicates, so no client can see this object at
-- all, let alone invoke it. That's a stronger guarantee than a tier
-- check, which would still be a code path a client could try to reach.
do
	local wipeLogs = Instance.new("BindableFunction")
	wipeLogs.Name = "WipeCommandLog"
	wipeLogs.OnInvoke = function()
		local wiped = #commandLog
		-- Reassigns rather than table.clear so any list already sent to a
		-- client keeps whatever it was holding; the next :cmdlogs reads
		-- this new empty one.
		commandLog = {}
		saveCommandLog()
		local message = "[AdminServer] Command log wiped (" .. wiped .. " entries removed)"
		print(message)
		return message
	end
	wipeLogs.Parent = ServerStorage
	log("[AdminServer] Log wipe ready - run game.ServerStorage.WipeCommandLog:Invoke() in the Studio Command Bar (context: Server)")
end

-- description is a full, grammatical sentence ("EnderBuilda muted
-- PlayerOne for spamming") built by the caller, since only the caller
-- knows enough about what actually happened to phrase it naturally -
-- Extra is kept separately as a short tag for the compact list row
-- (Line2's "(...)" suffix) and search/autocomplete, while Description is
-- what the detail popup shows. Every call site below supplies one, since
-- not every logged action is a real typed command (:unban, :unmute, a
-- reason/duration edit) and reconstructing ":command target extra" for
-- those read badly.
-- Shared by logCommand (a real admin ran a typed command) and
-- logSystemAction below (the server itself acted - e.g. the auto-kick/ban
-- from reaching a warning threshold - with no admin Player behind it at
-- all, so there's nothing to call getPlayerTier on).
local function logEntry(adminName, adminTier, commandName, targetName, extra, description)
	table.insert(commandLog, {
		Id = nextLogId,
		Admin = adminName,
		Tier = adminTier,
		Command = commandName,
		Target = targetName,
		Extra = extra,
		Description = description,
		Timestamp = os.time(),
	})
	nextLogId += 1
	if #commandLog > MAX_LOG_ENTRIES then
		table.remove(commandLog, 1)
	end
	saveCommandLog()
	log(string.format(
		"[AdminServer][LOG] %s used :%s on %s%s",
		adminName, commandName, targetName or "-",
		(extra and extra ~= "") and (" (" .. extra .. ")") or ""
	))
end

local function logCommand(admin, commandName, targetName, extra, description)
	if typeof(admin) ~= "Instance" then
		return
	end
	-- Captured at execution time, not looked up later - an admin's tier
	-- (in particular the Studio testing override) can change over a
	-- session, and a log entry should reflect what they were when they
	-- actually ran the command, not whatever they are now.
	logEntry(admin.Name, getPlayerTier(admin) or "?", commandName, targetName, extra, description)
end

-- For actions the SERVER takes on its own - the auto-escalation kick/ban
-- when a player reaches a warning threshold - rather than something an
-- admin typed. Attributed to "Server"/"System" instead of whichever admin
-- happened to run the :warn that triggered it, since they didn't actually
-- choose to kick or ban anyone - the system did, automatically.
local function logSystemAction(commandName, targetName, extra, description)
	logEntry("Server", "System", commandName, targetName, extra, description)
end

-- Newest first. filterAdmin, if given, only includes entries by that
-- exact admin (case-insensitive) - matched against the plain name
-- string logCommand stored, so this works even for an admin who has
-- since left (no live Player object needed).
--
-- Returns EVERY match, with no cap. There used to be a hard 100-entry
-- limit here, which silently hid the rest of the log - so :playerlogs on
-- a busy admin showed their 100 most recent actions and gave no hint
-- that there were more. The client pages through the result instead, so
-- nothing is lost and the UI still only draws a screenful at a time.
local function buildLogEntries(filterAdmin)
	local lowerFilter = filterAdmin and string.lower(filterAdmin) or nil
	local entries = {}
	for i = #commandLog, 1, -1 do
		local entry = commandLog[i]
		if not lowerFilter or string.lower(entry.Admin) == lowerFilter then
			table.insert(entries, {
				-- Carried through so the owner-only Remove button in the
				-- detail popup can name exactly which entry to delete.
				Id = entry.Id,
				Line1 = ":" .. entry.Command .. (entry.Target and (" - " .. entry.Target) or ""),
				Line2 = "by " .. entry.Admin .. " - " .. os.date("%Y-%m-%d %H:%M", entry.Timestamp)
					.. ((entry.Extra and entry.Extra ~= "") and (" (" .. entry.Extra .. ")") or ""),
				-- Full fields carried alongside Line1/Line2 so clicking a
				-- row can show the complete breakdown purely client-side
				-- (AdminClient.lua's showLogDetailPopup) - no second
				-- round trip to the server needed just to view one entry.
				Admin = entry.Admin,
				Tier = entry.Tier,
				Command = entry.Command,
				Target = entry.Target,
				Extra = entry.Extra,
				Description = entry.Description,
				Timestamp = entry.Timestamp,
			})
		end
	end
	return entries
end


-- =====================================================================
-- Dispatcher
-- =====================================================================
local function sendFeedback(player, text, isError)
	if typeof(player) ~= "Instance" then
		return -- the Admin Abuse show runs commands without a player
	end
	Remote.AdminFeedback:FireClient(player, text, isError == true)
end

-- Owner-only, re-checked here rather than trusting the CanRemoveLogs
-- flag the client was handed - a RemoteEvent is callable by any client
-- that knows its name, whatever their panel chose to draw. A refusal is
-- silent for everyone except the owner: someone probing this doesn't
-- need to be told it exists and that they're not allowed.
Remote.AdminRemoveLogEntry.OnServerEvent:Connect(function(player, entryId)
	if not isOwner(player) then
		warn("[AdminServer] Rejected log-entry removal from " .. player.Name .. " - not the owner")
		return
	end
	if type(entryId) ~= "number" then return end

	local removed = nil
	for i, entry in ipairs(commandLog) do
		if entry.Id == entryId then
			removed = table.remove(commandLog, i)
			break
		end
	end
	if not removed then
		sendFeedback(player, "That log entry is already gone", true)
		return
	end
	saveCommandLog()

	-- Refreshes whichever view they had open (see lastLogFilter) rather
	-- than always sending the full log back - removing an entry from a
	-- :playerlogs list shouldn't dump them into :cmdlogs.
	local filter = lastLogFilter[player.UserId]
	local entries = buildLogEntries(filter or nil)
	local title = filter and ("Logs - " .. filter .. " (" .. #entries .. ")")
		or ("Command Log (" .. #entries .. ")")
	Remote.AdminLogsList:FireClient(player, title, entries)

	sendFeedback(player, "Removed log entry: :" .. tostring(removed.Command)
		.. (removed.Target and (" - " .. removed.Target) or ""), false)
	print("[AdminServer] " .. player.Name .. " removed log entry #" .. entryId
		.. " (:" .. tostring(removed.Command) .. " by " .. tostring(removed.Admin) .. ")")
end)

-- Case-insensitive, matching the client's autocomplete dropdown - and
-- also resolves an unambiguous partial name even if the admin typed it
-- and hit Enter directly instead of using the dropdown/Tab. Returns
-- (player, nil) on a clean resolution, (nil, message) when the partial
-- matches more than one online player (so the admin can be told exactly
-- who it's ambiguous between), or (nil, nil) for no match at all.
local function findTargetPlayer(partial)
	if typeof(partial) ~= "string" or partial == "" then return nil, nil end
	local lowerPartial = string.lower(partial)

	for _, plr in ipairs(Players:GetPlayers()) do
		if string.lower(plr.Name) == lowerPartial then
			return plr, nil
		end
	end

	local matches = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if string.sub(string.lower(plr.Name), 1, #lowerPartial) == lowerPartial then
			table.insert(matches, plr)
		end
	end

	if #matches == 1 then
		return matches[1], nil
	elseif #matches > 1 then
		local names = {}
		for _, plr in ipairs(matches) do
			table.insert(names, plr.Name)
		end
		return nil, "Multiple players match \"" .. partial .. "\": " .. table.concat(names, ", ") .. " - be more specific"
	end

	return nil, nil
end

Remote.AdminCommand.OnServerEvent:Connect(function(admin, commandName, targetName, extraText)
	if typeof(commandName) ~= "string" then return end
	commandName = string.lower(commandName)

	-- Checked before the permission check, and worded differently, so a
	-- typo'd/nonexistent command doesn't get told "you do not have
	-- permission" - that phrasing should only ever mean "this is a real
	-- command your tier can't use", not "this isn't a command at all".
	local tier = getPlayerTier(admin)
	local isStudioCommand = STUDIO_ONLY_SET[commandName] == true

	-- A Studio command outside Studio is reported as UNKNOWN, not as
	-- forbidden. "You do not have permission" would confirm the command
	-- exists, which is exactly the trace these are supposed to leave
	-- none of. As far as a live server is concerned, :tier is a typo.
	if isStudioCommand then
		if not canUseStudioCommands(admin) then
			sendFeedback(admin, "Unknown command: :" .. commandName, true)
			return
		end
	elseif not ALL_COMMANDS_SET[commandName] then
		sendFeedback(admin, "Unknown command: :" .. commandName, true)
		return
	elseif not tierHasCommand(tier, commandName) then
		sendFeedback(admin, "You do not have permission to use :" .. commandName, true)
		return
	end

	extraText = typeof(extraText) == "string" and extraText or ""
	if #extraText > 200 then
		extraText = string.sub(extraText, 1, 200)
	end

	-- The Global tab's events (polls, giveaways, pass drops, boosts): the whole input is free text.
	local globalCommand = GlobalEvents.Commands[commandName]
	if globalCommand then
		local text = ((if typeof(targetName) == "string" then targetName else "") .. " " .. extraText):match("^%s*(.-)%s*$")
		globalCommand(admin, text)
		return
	end

	-- Handled before target resolution: the three list commands don't
	-- target anyone at all. Unbanning is no longer a standalone typed
	-- command - it's done from :banlist's per-row "Modify" popup, which
	-- already has the exact UserId on hand and doesn't need a username
	-- lookup at all.
	if commandName == "banlist" then
		local entries = buildBanListEntries()
		Remote.AdminBanList:FireClient(admin, "Banned Players (" .. #entries .. ")", entries)
		sendFeedback(admin, #entries .. " active ban(s)", false)
		return
	end

	if commandName == "mutelist" then
		local entries = buildMuteListEntries()
		Remote.AdminMuteList:FireClient(admin, "Muted Players (" .. #entries .. ")", entries)
		sendFeedback(admin, #entries .. " player(s) currently muted", false)
		return
	end

	if commandName == "warnlist" then
		local entries = buildWarnListEntries()
		Remote.AdminWarnList:FireClient(admin, "Warned Players (" .. #entries .. ")", entries)
		sendFeedback(admin, #entries .. " player(s) with warnings", false)
		return
	end

	-- Takes no arguments - the whole log goes to the client and the panel
	-- pages through it 100 at a time, so there's nothing to narrow down
	-- here.
	-- =================================================================
	-- Studio-only testing commands
	-- =================================================================
	-- Reaching this point already means canUseStudioCommands passed, so
	-- these don't re-check Studio individually. The game ones call
	-- Rinse Cycle's own services (DataService, RoundService, PetService).
	-- :setadminrank [player] [rank] - makes someone a staff rank for this
	-- Studio session only.
	--
	-- Sets the AdminTierOverride attribute the admin system checks for permission.
	--   AdminTierOverride - what the admin system checks for permission
	--   Rank / RankLabel  - what the overhead tag and the Tab list read
	--
	-- Deliberately NOT written to the rank DataStore, unlike :setrank.
	-- This is a testing tool: stop the playtest and you are whatever you
	-- really are again, with nothing left behind on the account.
	if commandName == "setadminrank" then
		if not isOwner(admin) then
			sendFeedback(admin, "Unknown command: :" .. commandName, true)
			return
		end
		local wanted = string.lower(extraText:match("^%s*(%S*)") or "")
		local usage = "Usage: :setadminrank [player] [Moderator/Admin/Developer, or clear]"
		if targetName == "" or wanted == "" then
			sendFeedback(admin, usage, true)
			return
		end
		local target, matchError = findTargetPlayer(targetName)
		if matchError then
			sendFeedback(admin, matchError, true)
			return
		end
		if not target then
			sendFeedback(admin, "Player not found: " .. targetName .. " (to remove someone who's offline, use Staff list)", true)
			return
		end
		if isOwnerAccount(target) then
			sendFeedback(admin, "That's the owner account", true)
			return
		end
		local newTier = nil
		if wanted ~= "clear" and wanted ~= "none" then
			for _, value in ipairs(STUDIO_TIER_VALUES) do
				if string.lower(value) == wanted or string.lower(value):sub(1, 3) == wanted:sub(1, 3) then
					newTier = value
				end
			end
			if not newTier then
				sendFeedback(admin, usage, true)
				return
			end
		end
		task.spawn(function()
			Staff.Set(target.UserId, newTier, target.Name)
			if newTier then
				celebrate(target, "You're staff!", "You've been made " .. newTier .. " by the owner. Your admin panel is on the left.", "🛡️")
			end
		end)
		logCommand(admin, "setadminrank", target.Name, newTier or "cleared",
			admin.Name .. (if newTier then " made " .. target.Name .. " " .. newTier else " removed " .. target.Name .. "'s staff rank"))
		sendFeedback(admin, if newTier then (target.Name .. " is now " .. newTier) else (target.Name .. " is no longer staff"), false)
		return
	end

	-- :stafflist - every staff member (online or not), with Remove.
	if commandName == "stafflist" then
		if not isOwner(admin) then
			sendFeedback(admin, "Unknown command: :" .. commandName, true)
			return
		end
		Staff.SendList(admin)
		return
	end

	-- Clears the command log in memory and in the DataStore. The
	-- ServerStorage.WipeCommandLog hook still exists alongside this and
	-- is still the better option for clearing test noise BEFORE a
	-- session, since it works in edit mode with no playtest running.
	if commandName == "wipelogs" then
		local wiped = #commandLog
		commandLog = {}
		saveCommandLog()
		sendFeedback(admin, "Wiped " .. wiped .. " log entries", false)
		log("[AdminServer] Command log wiped by " .. admin.Name .. " (" .. wiped .. " entries)")
		return
	end

	-- Finds the player named as the first argument, reporting a mistake to the admin itself.
	local function requireTarget(usage)
		if targetName == "" then
			sendFeedback(admin, "Usage: " .. usage, true)
			return nil
		end
		local target, matchError = findTargetPlayer(targetName)
		if matchError then
			sendFeedback(admin, matchError, true)
			return nil
		end
		if not target then
			sendFeedback(admin, "Player not found: " .. targetName, true)
			return nil
		end
		return target
	end

	-- =================================================================
	-- Founder-only, and NOT Studio-only - these work in a live game.
	-- =================================================================
	-- :setbubbles / :setgems [player] [amount] set someone's Bubbles or Gems outright (fixing a
	-- lost purchase, seeding a tester). They're the premium/progression currencies, so Founder only.
	if commandName == "setbubbles" or commandName == "setgems" then
		local field = if commandName == "setbubbles" then "Bubbles" else "Gems"
		local amount = tonumber(extraText:match("^%s*(%S*)") or "")
		local target = requireTarget(":" .. commandName .. " [player] [amount]")
		if not target then return end
		if not amount or amount < 0 then
			sendFeedback(admin, "Usage: :" .. commandName .. " [player] [amount]", true)
			return
		end
		local profile = DataService.Get(target)
		if not profile then
			sendFeedback(admin, target.Name .. "'s data isn't loaded yet", true)
			return
		end
		profile[field] = math.floor(amount)
		DataService.PushMeta(target)
		logCommand(admin, commandName, target.Name, tostring(math.floor(amount)),
			admin.Name .. " set " .. target.Name .. "'s " .. field .. " to " .. math.floor(amount))
		sendFeedback(admin, "Set " .. target.Name .. "'s " .. field .. " to " .. math.floor(amount), false)
		return
	end

	-- =================================================================
	-- Owner tools (Studio, or the owner in a live game) - testing and fixing things.
	-- =================================================================
	-- :daily [player] [skip|break|day N|reset|show] - fast-forwards the 24-hour daily reward.
	--   skip   the 24 hours have passed - the next reward is claimable now, streak intact
	--   break  a day was missed - the streak will restart unless restored
	--   day N  jump to having day N waiting (claimable now)
	--   reset  wipe back to a fresh start
	--   show   report the current state and change nothing
	if commandName == "daily" then
		local target = requireTarget(":daily [player] [skip|break|day N|reset|show]")
		if not target then return end
		local profile = DataService.Get(target)
		if not profile then
			sendFeedback(admin, target.Name .. "'s data isn't loaded yet", true)
			return
		end
		local mode, value = extraText:match("^%s*(%S*)%s*(%S*)")
		mode = string.lower(mode or "")
		local now = os.time()
		local cooldown, grace = Config.Daily.Cooldown, Config.Daily.Grace
		if mode == "skip" then
			profile.DailyLast = now - cooldown
		elseif mode == "break" then
			profile.DailyLast = now - cooldown - grace - 60
		elseif mode == "day" then
			local day = math.clamp(math.floor(tonumber(value) or 1), 1, #Config.DailyRewards)
			profile.DailyStreak = day - 1
			profile.DailyLast = if day == 1 then 0 else now - cooldown
		elseif mode == "reset" then
			profile.DailyStreak = 0
			profile.DailyLast = 0
		elseif mode ~= "" and mode ~= "show" then
			sendFeedback(admin, "Usage: :daily [player] [skip|break|day N|reset|show]", true)
			return
		end
		DataService.PushMeta(target)
		local wait = math.max(0, profile.DailyLast + cooldown - now)
		sendFeedback(admin, string.format("%s: streak day %d, %s", target.Name, profile.DailyStreak,
			if profile.DailyLast == 0 or wait == 0 then "next reward ready" else ("next reward in " .. formatDuration(wait))), false)
		if mode ~= "" and mode ~= "show" then
			logCommand(admin, "daily", target.Name, mode, admin.Name .. " used :daily " .. mode .. " on " .. target.Name)
		end
		return
	end

	-- :finishrun [player] - cleans every bit of dirt in that player's dishwasher at once.
	if commandName == "finishrun" then
		local target = requireTarget(":finishrun [player]")
		if not target then return end
		local cleaned = RoundService.DebugFinish(target)
		if not cleaned then
			sendFeedback(admin, target.Name .. " isn't in a run", true)
			return
		end
		logCommand(admin, "finishrun", target.Name, nil, admin.Name .. " finished " .. target.Name .. "'s run")
		sendFeedback(admin, "Finished " .. target.Name .. "'s run (" .. cleaned .. " spots)", false)
		return
	end

	-- :givecoins [player] [amount] - in-run coins (only while they're in a dishwasher).
	if commandName == "givecoins" then
		local target = requireTarget(":givecoins [player] [amount]")
		if not target then return end
		local amount = tonumber(extraText:match("^%s*(%S*)") or "")
		if not amount or amount <= 0 then
			sendFeedback(admin, "Usage: :givecoins [player] [amount]", true)
			return
		end
		if not RoundService.AddCoins(target, math.floor(amount)) then
			sendFeedback(admin, target.Name .. " isn't in a run", true)
			return
		end
		logCommand(admin, "givecoins", target.Name, tostring(math.floor(amount)), admin.Name .. " gave " .. target.Name .. " " .. math.floor(amount) .. " coins")
		sendFeedback(admin, "Gave " .. target.Name .. " " .. math.floor(amount) .. " coins", false)
		return
	end

	-- :givepet [player] [pet name] - adds a pet (end the name with "golden" or "rainbow" for a tier).
	if commandName == "givepet" then
		local target = requireTarget(":givepet [player] [pet name]")
		if not target then return end
		local text = extraText:gsub("^%s+", ""):gsub("%s+$", "")
		local petTier = 1
		local lowerText = string.lower(text)
		if lowerText:match("%s+golden$") then
			petTier, text = 2, text:gsub("%s+[Gg]olden$", "")
		elseif lowerText:match("%s+rainbow$") then
			petTier, text = 3, text:gsub("%s+[Rr]ainbow$", "")
		end
		local wanted = string.lower((text:gsub("[^%w]", "")))
		local petId = nil
		for id, def in pairs(Config.Pets) do
			if string.lower(id) == wanted or (string.lower(def.Name):gsub("[^%w]", "")) == wanted then
				petId = id
				break
			end
		end
		if not petId then
			sendFeedback(admin, "No pet found matching \"" .. text .. "\"", true)
			return
		end
		local ok, err = PetService.GivePet(target, petId, petTier)
		if not ok then
			sendFeedback(admin, err or "Couldn't give that pet", true)
			return
		end
		local label = Config.Pets[petId].Name .. (petTier == 2 and " (Golden)" or petTier == 3 and " (Rainbow)" or "")
		logCommand(admin, "givepet", target.Name, label, admin.Name .. " gave " .. target.Name .. " a " .. label)
		sendFeedback(admin, "Gave " .. target.Name .. " a " .. label, false)
		return
	end

	-- :unlockall [player] - unlocks every dishwasher.
	if commandName == "unlockall" then
		local target = requireTarget(":unlockall [player]")
		if not target then return end
		local profile = DataService.Get(target)
		if not profile then
			sendFeedback(admin, target.Name .. "'s data isn't loaded yet", true)
			return
		end
		profile.Unlocked = #Config.Levels
		DataService.PushMeta(target)
		logCommand(admin, "unlockall", target.Name, nil, admin.Name .. " unlocked every level for " .. target.Name)
		sendFeedback(admin, "Unlocked every level for " .. target.Name, false)
		return
	end

	-- :setrebirths [player] [count]
	if commandName == "setrebirths" then
		local target = requireTarget(":setrebirths [player] [count]")
		if not target then return end
		local count = tonumber(extraText:match("^%s*(%S*)") or "")
		local profile = DataService.Get(target)
		if not count or count < 0 or not profile then
			sendFeedback(admin, if profile then "Usage: :setrebirths [player] [count]" else (target.Name .. "'s data isn't loaded yet"), true)
			return
		end
		profile.Rebirths = math.floor(count)
		DataService.PushMeta(target)
		DataService.PassesChanged:Fire(target) -- rebirth bonuses and the name tag
		logCommand(admin, "setrebirths", target.Name, tostring(math.floor(count)), admin.Name .. " set " .. target.Name .. "'s rebirths to " .. math.floor(count))
		sendFeedback(admin, "Set " .. target.Name .. "'s rebirths to " .. math.floor(count), false)
		return
	end

	-- =================================================================
	-- Gifted gamepasses. Owner only, and NOT Studio-only - these work in
	-- a live server, which is half the point of them.
	-- =================================================================
	-- The extra isOwner check on top of the Studio/owner gate above is
	-- deliberate. In Studio that gate passes for any Founder-tier tester,
	-- which is right for :finishrun and wrong for a command that hands
	-- out paid entitlements - so these two ask the narrower question.
	if commandName == "givegamepass" or commandName == "removegamepass" then
		local giving = commandName == "givegamepass"

		if not isOwner(admin) then
			sendFeedback(admin, "Unknown command: :" .. commandName, true)
			return
		end

		local passText = extraText:gsub("^%s+", ""):gsub("%s+$", "")
		local pass = resolveGamepass(passText)
		if targetName == "" or not pass then
			sendFeedback(admin, "Usage: :" .. commandName .. " [player] [pass]", true)
			return
		end

		local target, matchError = findTargetPlayer(targetName)
		if matchError then
			sendFeedback(admin, matchError, true)
			return
		end
		if not target then
			sendFeedback(admin, "Player not found: " .. targetName, true)
			return
		end

		-- Two different kinds of "has it": bought from Roblox, or given
		-- by this command. They need telling apart, because only one of
		-- them can be taken away again.
		local granted = target:GetAttribute(gamepassAttribute(pass.Key)) == true
		local bought = false
		if type(pass.Id) == "number" and pass.Id > 0 then
			local ok, result = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(target.UserId, pass.Id)
			end)
			if not ok then
				sendFeedback(admin, "Couldn't check " .. target.Name .. "'s passes", true)
				return
			end
			bought = result == true
		end

		if giving then
			if bought then
				sendFeedback(admin, target.Name .. " already bought that pass", true)
				return
			end
			if granted then
				sendFeedback(admin, target.Name .. " was already gifted that pass", true)
				return
			end
		else
			if not granted then
				sendFeedback(admin, bought
					and (target.Name .. " bought that pass - can't remove")
					or (target.Name .. " wasn't gifted that pass"), true)
				return
			end
		end

		setGamepassGrant(target, pass, giving, bought)

		-- The recipient gets told, with the game's usual celebration toast - only on the way IN.
		if giving then
			celebrate(target, "You got a gift!", "You've been gifted " .. pass.Name .. " by an admin!", pass.Icon)
		end

		sendFeedback(admin, (giving and "Gave " or "Removed ") .. pass.Name
			.. (giving and " to " or " from ") .. target.Name, false)
		logCommand(admin, commandName, target.Name, pass.Name,
			admin.Name .. (giving and " gave " or " removed ") .. pass.Name
			.. (giving and " to " or " from ") .. target.Name)
		return
	end

	if commandName == "cmdlogs" then
		local entries = buildLogEntries(nil)
		lastLogFilter[admin.UserId] = false
		Remote.AdminLogsList:FireClient(admin, "Command Log (" .. #entries .. ")", entries)
		sendFeedback(admin, #entries .. " log entries", false)
		return
	end

	-- Matched against the plain name string each log entry was recorded
	-- under, not a live Player - works for an admin who has since left,
	-- unlike findTargetPlayer below.
	if commandName == "playerlogs" then
		if targetName == "" then
			sendFeedback(admin, "Usage: :playerlogs [admin username]", true)
			return
		end
		local entries = buildLogEntries(targetName)
		lastLogFilter[admin.UserId] = targetName
		Remote.AdminLogsList:FireClient(admin, "Logs - " .. targetName .. " (" .. #entries .. ")", entries)
		sendFeedback(admin, #entries .. " log entries for " .. targetName, false)
		return
	end

	-- No player target at all - the whole rest of the input (targetName
	-- + extraText, which the client only split apart because every other
	-- command has a target as its first word) is the announcement text.
	-- :joinserver [username] - go to that player's server, wherever it is (runs included).
	-- :bringserver [username] - pull that player from their server into yours.
	if commandName == "joinserver" or commandName == "bringserver" then
		local joining = commandName == "joinserver"
		local name = targetName:gsub("^%s+", ""):gsub("%s+$", "")
		if name == "" then
			sendFeedback(admin, "Usage: :" .. commandName .. " [username]", true)
			return
		end
		-- Already here: the normal goto / bring.
		local here = findTargetPlayer(name)
		if here and here ~= admin then
			if joining then
				gotoPlayer(admin, here)
				sendFeedback(admin, here.Name .. " is in this server - teleported to them", false)
			else
				bringPlayer(admin, here)
				sendFeedback(admin, here.Name .. " is in this server - brought them", false)
			end
			return
		end
		task.spawn(function()
			local okId, userId = pcall(function()
				return Players:GetUserIdFromNameAsync(name)
			end)
			if not okId or type(userId) ~= "number" then
				sendFeedback(admin, "No Roblox user called " .. name, true)
				return
			end
			if not joining then
				local ok = pcall(function()
					MessagingService:PublishAsync("RinseCycle_AdminBring", {
						UserId = userId,
						JobId = game.JobId,
						Code = RunServers.AccessCodeForJob(game.JobId),
						AdminId = admin.UserId,
					})
				end)
				sendFeedback(admin, if ok then ("Asked " .. name .. "'s server to send them here...") else "Couldn't reach other servers", not ok)
				if ok then
					logCommand(admin, "bringserver", name, nil, admin.Name .. " brought " .. name .. " from another server")
				end
				return
			end
			local ok, _current, _err, _placeId, jobId = pcall(function()
				return TeleportService:GetPlayerPlaceInstanceAsync(userId)
			end)
			if not ok or type(jobId) ~= "string" or jobId == "" then
				sendFeedback(admin, "Couldn't find " .. name .. " in any server (offline, or their joins are turned off)", true)
				return
			end
			local code = RunServers.AccessCodeForJob(jobId)
			local sent = pcall(function()
				local options = Instance.new("TeleportOptions")
				if code then
					options.ReservedServerAccessCode = code
				else
					options.ServerInstanceId = jobId
				end
				-- Always arrive invisible (and off the player list): nobody sees you join.
				options:SetTeleportData({ Mode = "AdminJoin", FollowUserId = userId, AdminInvis = { admin.UserId } })
				TeleportService:TeleportAsync(game.PlaceId, { admin }, options)
			end)
			sendFeedback(admin, if sent then ("Teleporting to " .. name .. "'s server...") else "That teleport couldn't start", not sent)
			if sent then
				logCommand(admin, "joinserver", name, nil, admin.Name .. " joined " .. name .. "'s server")
			end
		end)
		return
	end

	-- :serverlist - every player in every server of the game, with Join / Bring on each.
	if commandName == "serverlist" then
		task.spawn(ServerList.Send, admin)
		sendFeedback(admin, "Loading every server...", false)
		return
	end

	if commandName == "leaderboards" then
		task.spawn(function()
			local rows = LeaderboardService.ListBoard(1, 100)
			Remote.AdminLeaderboard:FireClient(admin, 1, LeaderboardService.BoardCount(), LeaderboardService.BoardTitle(1), rows)
		end)
		sendFeedback(admin, "Loading leaderboards...", false)
		return
	end

	-- Like :announce, but on every server of the game (MessagingService).
	if commandName == "globalannounce" then
		local fullMessage = (targetName ~= "" and (targetName .. " " .. extraText) or extraText)
		fullMessage = fullMessage:gsub("%s+$", "")
		if fullMessage == "" then
			sendFeedback(admin, "Usage: :globalannounce [message]", true)
			return
		end
		local ok = pcall(function()
			MessagingService:PublishAsync("RinseCycle_GlobalAnnounce", { Text = fullMessage })
		end)
		if not ok then
			-- MessagingService isn't available (Studio): at least tell this server.
			for _, plr in ipairs(Players:GetPlayers()) do
				Remote.AdminAnnouncement:FireClient(plr, fullMessage)
			end
		end
		logCommand(admin, "globalannounce", nil, fullMessage, admin.Name .. " announced to every server: " .. fullMessage)
		sendFeedback(admin, if ok then "Announcement sent to every server" else "Couldn't reach other servers - announced here only", not ok)
		return
	end

	if commandName == "announce" then
		local fullMessage = (targetName ~= "" and (targetName .. " " .. extraText) or extraText)
		fullMessage = fullMessage:gsub("%s+$", "")
		if fullMessage == "" then
			sendFeedback(admin, "Usage: :announce [message]", true)
			return
		end
		local players = Players:GetPlayers()
		for _, plr in ipairs(players) do
			Remote.AdminAnnouncement:FireClient(plr, fullMessage)
		end
		logCommand(admin, "announce", nil, fullMessage, admin.Name .. " announced: " .. fullMessage)
		sendFeedback(admin, "Announcement sent to " .. #players .. " player(s)", false)
		return
	end

	-- :fly with no name typed targets the issuing admin themselves,
	-- rather than requiring ":fly MyOwnUsername" every time - :fly [name]
	-- still works normally for flying someone else.
	if (commandName == "fly" or commandName == "noclip" or commandName == "giant") and targetName == "" then
		targetName = admin.Name
	end

	-- Nothing typed where the player name goes. Every command that reaches
	-- this point takes a player as its first argument (the ones that don't
	-- have all returned above), so this is always the same mistake:
	-- pressing enter half way through writing the command. It used to fall
	-- through to findTargetPlayer and come back as "Player not found: "
	-- with an empty name, which reads like the player is missing rather
	-- than the command being. The commands that need a SECOND argument
	-- (:give an item, :setrank a rank, :tempban a duration...) already
	-- report their own "Usage:" line further down, so this only has to
	-- cover the first one.
	if targetName == "" then
		sendFeedback(admin, "Incomplete command - :" .. commandName .. " needs a player name", true)
		return
	end

	local target, matchError = findTargetPlayer(targetName)
	if matchError then
		sendFeedback(admin, matchError, true)
		return
	end
	if not target then
		sendFeedback(admin, "Player not found: " .. tostring(targetName), true)
		return
	end
	-- Staff can't use commands on staff at or above their own rank (a Moderator can't kick an Admin
	-- or the owner). The owner can use anything on anyone.
	if target ~= admin and tier ~= "Founder" then
		local order = { Moderator = 1, Admin = 2, Developer = 3, Founder = 4 }
		local targetTier = getPlayerTier(target)
		if targetTier and (order[targetTier] or 0) >= (order[tier] or 0) then
			sendFeedback(admin, "You can't use that on " .. target.Name .. " (staff at or above your rank)", true)
			return
		end
	end
	-- Self-targeting rules. :kick/:ban are locked out for the obvious
	-- reason. :spectate/:controlplayer are locked out because both park
	-- the admin's own character in limbo and hand their camera to the
	-- target - aimed at yourself that means being puppeted by, and
	-- watching, a character that's been teleported away and frozen, which
	-- is just a broken state to be in rather than anything useful.
	-- :freeze is deliberately NOT in this list: freezing yourself is a
	-- genuinely handy way to test the frozen state without needing a
	-- second player.
	if target == admin and (commandName == "kick" or commandName == "ban"
		or commandName == "spectate" or commandName == "controlplayer") then
		sendFeedback(admin, "You can't :" .. commandName .. " yourself.", true)
		return
	end

	if commandName == "kick" then
		target:Kick("Kicked by an admin.\nReason: " .. (extraText ~= "" and extraText or "No reason given"))
		logCommand(admin, "kick", target.Name, extraText,
			admin.Name .. " kicked " .. target.Name .. (extraText ~= "" and (" - reason: " .. extraText) or " (no reason given)"))
		sendFeedback(admin, "Kicked " .. target.Name, false)

	elseif commandName == "mute" then
		local nowMuted, muteData = toggleMute(target, admin, extraText)
		local muteDescription
		if nowMuted then
			muteDescription = admin.Name .. " muted " .. target.Name .. (extraText ~= "" and (" - reason: " .. extraText) or " (no reason given, permanent)")
		else
			muteDescription = admin.Name .. " unmuted " .. target.Name
		end
		logCommand(admin, "mute", target.Name, nowMuted and ("muted: " .. extraText) or "unmuted", muteDescription)
		if nowMuted then
			Remote.AdminNotice:FireClient(target, "You have been muted", muteNoticeBody(muteData))
		end
		Remote.AdminMuteStatus:FireClient(target, nowMuted, nowMuted and muteData.ExpiresAt or nil)
		syncChatMutes()
		sendFeedback(admin, (nowMuted and "Muted " or "Unmuted ") .. target.Name, false)

	elseif commandName == "tempmute" then
		local durationSeconds, reasonText = parseDurationAndReason(extraText)
		if not durationSeconds then
			sendFeedback(admin, "Usage: :tempmute [player] [duration e.g. 24h, 3d, 1w] [reason]", true)
			return
		end
		local data = {Reason = reasonText, By = admin.Name, Timestamp = os.time(), ExpiresAt = os.time() + durationSeconds}
		mutedUserIds[target.UserId] = data
		saveMuteData(target.UserId, data)
		logCommand(admin, "tempmute", target.Name, formatDuration(durationSeconds) .. " - " .. reasonText,
			admin.Name .. " muted " .. target.Name .. " for " .. formatDuration(durationSeconds) .. (reasonText ~= "" and (" - reason: " .. reasonText) or ""))
		Remote.AdminNotice:FireClient(target, "You have been muted", muteNoticeBody(data))
		Remote.AdminMuteStatus:FireClient(target, true, data.ExpiresAt)
		syncChatMutes()
		sendFeedback(admin, "Muted " .. target.Name .. " for " .. formatDuration(durationSeconds), false)

	elseif commandName == "warn" then
		if extraText == "" then
			sendFeedback(admin, "Usage: :warn [player] [reason]", true)
			return
		end

		local warnings = getWarnings(target.UserId)
		table.insert(warnings, {Reason = extraText, By = admin.Name, Timestamp = os.time()})
		saveWarnings(target.UserId, warnings)
		local count = #warnings

		warnPlayer(target, extraText, count)
		logCommand(admin, "warn", target.Name, extraText .. " (warning #" .. count .. ")",
			admin.Name .. " warned " .. target.Name .. " (warning #" .. count .. ") - reason: " .. extraText)

		if count == 7 then
			banUser(target.UserId, "Reached 7 warnings (auto-escalation)", "System", nil, true)
			logSystemAction("ban", target.Name, "reached 7 warnings", "Server permanently banned " .. target.Name .. " for reaching 7 warnings")
			sendFeedback(admin, "Warned " .. target.Name .. " - 7 warnings, perm ban", false)
			target:Kick("You have been permanently banned - you reached 7 warnings.")
		elseif count == 5 then
			banUser(target.UserId, "Reached 5 warnings (auto-escalation)", "System", 24 * 3600, true)
			logSystemAction("tempban", target.Name, "reached 5 warnings", "Server banned " .. target.Name .. " for 24 hours for reaching 5 warnings")
			sendFeedback(admin, "Warned " .. target.Name .. " - 5 warnings, 24h ban", false)
			target:Kick("You have been banned for 24 hours - you reached 5 warnings.")
		elseif count == 3 then
			logSystemAction("kick", target.Name, "reached 3 warnings", "Server kicked " .. target.Name .. " for reaching 3 warnings")
			sendFeedback(admin, "Warned " .. target.Name .. " - 3 warnings, kicked", false)
			target:Kick("You have been kicked - you reached 3 warnings.\nLatest reason: " .. extraText)
		else
			sendFeedback(admin, "Warned " .. target.Name .. " (warning #" .. count .. ")", false)
		end

	elseif commandName == "msg" then
		if extraText == "" then
			sendFeedback(admin, "Usage: :msg [player] [message]", true)
			return
		end
		Remote.AdminNotice:FireClient(target, "Message from staff", extraText, nil, "OKAY")
		logCommand(admin, "msg", target.Name, extraText, admin.Name .. " sent a message to " .. target.Name .. ": " .. extraText)
		sendFeedback(admin, "Sent message to " .. target.Name, false)

	elseif commandName == "setrank" then
		if extraText == "" then
			sendFeedback(admin, "Usage: :setrank [player] [rank name]", true)
			return
		end
		local rank, rankErr = findRank(extraText)
		if rankErr then
			sendFeedback(admin, rankErr, true)
			return
		end
		if not rank then
			sendFeedback(admin, "No rank found matching \"" .. extraText .. "\"", true)
			return
		end
		applyRank(target, rank)
		celebrate(target, "Congrats!", "You've been gifted the " .. rank.Label .. " rank by an admin!", "🎖️")
		logCommand(admin, "setrank", target.Name, rank.Label, admin.Name .. " set " .. target.Name .. "'s rank to " .. rank.Label)
		sendFeedback(admin, "Set " .. target.Name .. "'s rank to " .. rank.Label, false)

	elseif commandName == "promote" then
		local index = getCurrentRankIndex(target)
		if index >= #IN_GAME_RANKS then
			sendFeedback(admin, target.Name .. " is already at the highest rank", true)
			return
		end
		local rank = IN_GAME_RANKS[index + 1]
		applyRank(target, rank)
		celebrate(target, "Congrats!", "An admin promoted you to the " .. rank.Label .. " rank!", "🎖️")
		logCommand(admin, "promote", target.Name, rank.Label, admin.Name .. " promoted " .. target.Name .. " to " .. rank.Label)
		sendFeedback(admin, "Promoted " .. target.Name .. " to " .. rank.Label, false)

	elseif commandName == "demote" then
		local index = getCurrentRankIndex(target)
		if index <= 1 then
			sendFeedback(admin, target.Name .. " is already at the lowest rank", true)
			return
		end
		local rank = IN_GAME_RANKS[index - 1]
		applyRank(target, rank)
		logCommand(admin, "demote", target.Name, rank.Label, admin.Name .. " demoted " .. target.Name .. " to " .. rank.Label)
		sendFeedback(admin, "Demoted " .. target.Name .. " to " .. rank.Label, false)

	elseif commandName == "goto" then
		if gotoPlayer(admin, target) then
			logCommand(admin, "goto", target.Name, nil, admin.Name .. " teleported to " .. target.Name)
			sendFeedback(admin, "Teleported to " .. target.Name, false)
		else
			sendFeedback(admin, "Could not teleport - character not found", true)
		end

	elseif commandName == "bring" then
		if bringPlayer(admin, target) then
			logCommand(admin, "bring", target.Name, nil, admin.Name .. " brought " .. target.Name .. " to them")
			sendFeedback(admin, "Brought " .. target.Name, false)
		else
			sendFeedback(admin, "Could not bring - character not found", true)
		end

	elseif commandName == "freeze" then
		-- Toggles: running it against someone already frozen unfreezes
		-- them, rather than refusing with "already frozen". :unfreeze is
		-- kept as its own command for when you specifically want the
		-- one-way version (and it's what the sidebar/autocomplete still
		-- offers), but this way a single command covers the common
		-- freeze-check-unfreeze loop without switching commands halfway.
		local nowFrozen = not frozenUserIds[target.UserId]
		if setFrozen(target, nowFrozen) then
			logCommand(admin, "freeze", target.Name, nowFrozen and "frozen" or "unfrozen",
				admin.Name .. (nowFrozen and " froze " or " unfroze ") .. target.Name)
			if nowFrozen then
				Remote.AdminNotice:FireClient(target, "You are frozen", "Leaving the game is punishable.")
			end
			Remote.AdminFreezeStatus:FireClient(target, nowFrozen)
			sendFeedback(admin, (nowFrozen and "Froze " or "Unfroze ") .. target.Name, false)
		else
			sendFeedback(admin, "Could not " .. (nowFrozen and "freeze" or "unfreeze") .. " - character not found", true)
		end

	elseif commandName == "unfreeze" then
		if not frozenUserIds[target.UserId] then
			sendFeedback(admin, target.Name .. " is not frozen", true)
			return
		end
		if setFrozen(target, false) then
			logCommand(admin, "unfreeze", target.Name, nil, admin.Name .. " unfroze " .. target.Name)
			Remote.AdminFreezeStatus:FireClient(target, false)
			sendFeedback(admin, "Unfroze " .. target.Name, false)
		else
			sendFeedback(admin, "Could not unfreeze - character not found", true)
		end

	elseif commandName == "ban" then
		if banUser(target.UserId, extraText, admin.Name, nil, true) then
			logCommand(admin, "ban", target.Name, extraText,
				admin.Name .. " banned " .. target.Name .. (extraText ~= "" and (" - reason: " .. extraText) or " (no reason given, permanent)"))
			sendFeedback(admin, "Banned " .. target.Name, false)
			target:Kick("You have been banned.\nReason: " .. (extraText ~= "" and extraText or "No reason given"))
		else
			sendFeedback(admin, "Failed to save ban - try again", true)
		end

	elseif commandName == "tempban" then
		local durationSeconds, reasonText = parseDurationAndReason(extraText)
		if not durationSeconds then
			sendFeedback(admin, "Usage: :tempban [player] [duration e.g. 24h, 3d, 1w] [reason]", true)
			return
		end
		if banUser(target.UserId, reasonText, admin.Name, durationSeconds, true) then
			logCommand(admin, "tempban", target.Name, formatDuration(durationSeconds) .. " - " .. reasonText,
				admin.Name .. " banned " .. target.Name .. " for " .. formatDuration(durationSeconds) .. (reasonText ~= "" and (" - reason: " .. reasonText) or ""))
			sendFeedback(admin, "Banned " .. target.Name .. " for " .. formatDuration(durationSeconds), false)
			target:Kick("You have been banned for " .. formatDuration(durationSeconds) .. ".\nReason: " .. (reasonText ~= "" and reasonText or "No reason given"))
		else
			sendFeedback(admin, "Failed to save ban - try again", true)
		end

	elseif commandName == "kill" then
		local character = target.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = 0
			logCommand(admin, "kill", target.Name, nil, admin.Name .. " killed " .. target.Name)
			sendFeedback(admin, "Killed " .. target.Name, false)
		else
			sendFeedback(admin, "Could not kill - character not found", true)
		end

	elseif commandName == "jail" then
		local nowJailed = not jailedUserIds[target.UserId]
		local success = nowJailed and jailPlayer(target) or (not nowJailed and unjailPlayer(target))
		if success then
			logCommand(admin, "jail", target.Name, nowJailed and "jailed" or "unjailed",
				admin.Name .. " " .. (nowJailed and "jailed " or "unjailed ") .. target.Name)
			sendFeedback(admin, (nowJailed and "Jailed " or "Unjailed ") .. target.Name, false)
		else
			sendFeedback(admin, "Could not " .. (nowJailed and "jail" or "unjail") .. " - character not found", true)
		end

	elseif commandName == "god" then
		local nowGod = not godModeUserIds[target.UserId]
		if setGodMode(target, nowGod) then
			logCommand(admin, "god", target.Name, nowGod and "enabled" or "disabled",
				admin.Name .. " " .. (nowGod and "enabled" or "disabled") .. " god mode for " .. target.Name)
			sendFeedback(admin, (nowGod and "Enabled" or "Disabled") .. " god mode for " .. target.Name, false)
		else
			sendFeedback(admin, "Could not toggle god mode - character not found", true)
		end

	elseif commandName == "respawn" then
		target:LoadCharacter()
		logCommand(admin, "respawn", target.Name, nil, admin.Name .. " respawned " .. target.Name)
		sendFeedback(admin, "Respawned " .. target.Name, false)

	elseif commandName == "spectate" then
		if startSpectating(admin, target) then
			logCommand(admin, "spectate", target.Name, nil, admin.Name .. " started spectating " .. target.Name)
			sendFeedback(admin, "Spectating " .. target.Name, false)
		else
			sendFeedback(admin, "Could not spectate - character not found", true)
		end

	elseif commandName == "controlplayer" then
		if startControlling(admin, target) then
			logCommand(admin, "controlplayer", target.Name, nil, admin.Name .. " started controlling " .. target.Name)
			sendFeedback(admin, "Now controlling " .. target.Name, false)
		else
			sendFeedback(admin, "Could not control - character not found", true)
		end

	elseif commandName == "invis" then
		local nowInvisible = not invisibleUserIds[target.UserId]
		if setInvisible(target, nowInvisible) then
			-- Kept on the player: a respawn or a server hop (runs, :joinserver) keeps them invisible.
			target:SetAttribute("AdminInvis", if nowInvisible then true else nil)
			logCommand(admin, "invis", target.Name, nowInvisible and "hidden" or "shown",
				admin.Name .. " made " .. target.Name .. (nowInvisible and " invisible" or " visible again"))
			sendFeedback(admin, "Made " .. target.Name .. (nowInvisible and " invisible" or " visible again"), false)
		else
			sendFeedback(admin, "Could not toggle invisibility - character not found", true)
		end

	elseif commandName == "viewpets" then
		sendPetList(admin, target)
		sendFeedback(admin, "Showing " .. target.Name .. "'s pets", false)

	elseif commandName == "viewinv" then
		sendInventoryList(admin, target)
		sendFeedback(admin, "Showing " .. target.Name .. "'s inventory", false)

	elseif commandName == "clearinv" then
		local count = clearTargetInventory(target)
		logCommand(admin, "clearinv", target.Name, count .. " item(s)", admin.Name .. " cleared " .. target.Name .. "'s inventory (" .. count .. " item(s))")
		sendFeedback(admin, "Cleared " .. count .. " item(s) from " .. target.Name .. "'s inventory", false)

	elseif commandName == "fly" then
		local nowFlying = not flyingUserIds[target.UserId]
		setFlying(target, nowFlying)
		logCommand(admin, "fly", target.Name, nowFlying and "enabled" or "disabled",
			admin.Name .. " " .. (nowFlying and "enabled" or "disabled") .. " flight for " .. target.Name)
		sendFeedback(admin, (nowFlying and "Enabled" or "Disabled") .. " flight for " .. target.Name, false)

	elseif commandName == "noclip" then
		local given = toggleNoClipTool(target)
		logCommand(admin, "noclip", target.Name, given and "given" or "removed",
			admin.Name .. (given and " gave " or " took ") .. "the No Clip tool " .. (given and "to " or "from ") .. target.Name)
		sendFeedback(admin, if given then "Gave " .. target.Name .. " the No Clip tool (hold it: fly through walls, click to teleport)" else "Took the No Clip tool from " .. target.Name, false)

	elseif commandName == "giant" then
		local size = math.clamp(tonumber(extraText:match("^%s*(%S*)") or "") or 8, 2, 30)
		local makeGiant = not isGiant(target)
		if not setGiantScale(target, if makeGiant then size else 1) then
			sendFeedback(admin, target.Name .. " has no character right now", true)
			return
		end
		logCommand(admin, "giant", target.Name, makeGiant and ("x" .. size) or "normal",
			admin.Name .. " made " .. target.Name .. (makeGiant and (" giant (x" .. size .. ")") or " normal size"))
		sendFeedback(admin, target.Name .. (makeGiant and (" is now x" .. size .. " size") or " is back to normal size"), false)

	elseif commandName == "give" then
		if extraText == "" then
			sendFeedback(admin, "Usage: :give [player] [item name]", true)
			return
		end
		local success, itemNameOrErr = giveItem(target, extraText)
		if success then
			logCommand(admin, "give", target.Name, itemNameOrErr, admin.Name .. " gave " .. target.Name .. " a " .. itemNameOrErr)
			sendFeedback(admin, "Gave " .. target.Name .. " a " .. itemNameOrErr, false)
		else
			sendFeedback(admin, itemNameOrErr, true)
		end
	end
end)

Remote.AdminRemoveWarning.OnServerEvent:Connect(function(admin, targetUserId, warningIndex)
	local tier = getPlayerTier(admin)
	if not tierHasCommand(tier, "warnlist") then return end
	if typeof(targetUserId) ~= "number" or typeof(warningIndex) ~= "number" then return end

	local warnings = getWarnings(targetUserId)
	if warningIndex < 1 or warningIndex > #warnings then
		sendFeedback(admin, "That warning no longer exists.", true)
		return
	end

	-- Captured before removal - buildLogEntries below only has the
	-- removed warning's own Reason to show once it's gone from the
	-- live list, and this is the only point where that text still exists.
	local removedWarning = warnings[warningIndex]
	table.remove(warnings, warningIndex)
	saveWarnings(targetUserId, warnings)
	sendFeedback(admin, "Removed warning #" .. warningIndex, false)
	Remote.AdminWarningsList:FireClient(admin, nil, targetUserId, warnings)

	-- Logged the same way every other command is - previously this
	-- action wasn't logged at all, so removing a warning left no trace
	-- in :cmdlogs/:playerlogs even though every other admin action did.
	local success, targetName = pcall(function()
		return Players:GetNameFromUserIdAsync(targetUserId)
	end)
	local unwarnTargetName = success and targetName or ("UserId " .. tostring(targetUserId))
	logCommand(
		admin,
		"unwarn",
		unwarnTargetName,
		"removed warning #" .. warningIndex .. " (" .. tostring(removedWarning.Reason) .. ")",
		admin.Name .. " removed " .. unwarnTargetName .. "'s warning #" .. warningIndex .. " (" .. tostring(removedWarning.Reason) .. ")"
	)
end)

Remote.AdminViewWarnings.OnServerEvent:Connect(function(admin, userIdStr)
	local tier = getPlayerTier(admin)
	if not tierHasCommand(tier, "warnlist") then return end
	local userId = tonumber(userIdStr)
	if not userId then return end

	local warnings = getWarnings(userId)
	local success, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	Remote.AdminWarningsList:FireClient(admin, success and name or ("UserId " .. userIdStr), userId, warnings)
end)

Remote.AdminModifyPunishment.OnServerEvent:Connect(function(admin, kind, userIdStr, action, value)
	if kind ~= "ban" and kind ~= "mute" then return end
	-- Gated on whoever can see the list this came from, rather than a
	-- dedicated command - :unban no longer exists as its own typed
	-- command (unbanning is only ever done from :banlist's "Modify"
	-- popup now), so there's no other command left to gate this on.
	local requiredCommand = (kind == "ban") and "banlist" or "mutelist"
	local tier = getPlayerTier(admin)
	if not tierHasCommand(tier, requiredCommand) then return end
	local userId = tonumber(userIdStr)
	if not userId then return end

	if kind == "ban" then
		if action == "remove" then
			-- Captured before removal, same reasoning as the warning
			-- removal above - once unbanUser runs, the reason that was on
			-- this ban is gone for good, and previously this action wasn't
			-- logged with any detail at all (just the raw UserId, not even
			-- a resolved username).
			local banData = isBanned(userId)
			unbanUser(userId)
			local success, targetName = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			local unbanTargetName = success and targetName or ("UserId " .. userIdStr)
			logCommand(
				admin,
				"unban",
				unbanTargetName,
				banData and ("removed ban: " .. tostring(banData.Reason)) or "removed ban",
				admin.Name .. " unbanned " .. unbanTargetName .. (banData and (" (was: " .. tostring(banData.Reason) .. ")") or "")
			)
			sendFeedback(admin, "Unbanned", false)
		elseif action == "reason" and typeof(value) == "string" then
			local banData = isBanned(userId)
			if banData then
				-- Captured before mutation - banData is the SAME table
				-- reference cached in banRecordsCache, so assigning
				-- banData.Reason below overwrites it in place before
				-- there's a chance to log what it used to say.
				local oldReason = banData.Reason
				local newReason = string.sub(value, 1, 200)
				-- waitForPersist=true - same reasoning as :ban/:tempban: an
			-- edit that only reached the in-memory cache before the
			-- server happened to stop (a live server cycling, or -
			-- guaranteed - Studio's Stop button) would silently revert
			-- to whatever the DataStore last actually had once a fresh
			-- server reseeds from it, undoing this edit with no trace.
			banUser(userId, newReason, banData.BannedBy, banData.ExpiresAt and (banData.ExpiresAt - os.time()) or nil, true)
				local success, targetName = pcall(function()
					return Players:GetNameFromUserIdAsync(userId)
				end)
				local reasonTargetName = success and targetName or ("UserId " .. userIdStr)
				-- Logged under the same "ban" command name (not a made-up
				-- "banreason") so :cmdlogs' own search-by-command picks
				-- this up alongside the original :ban/:tempban entries for
				-- the same user - the Extra text is what actually says
				-- this was an edit, not a fresh ban.
				logCommand(admin, "ban", reasonTargetName, "reason updated: " .. newReason,
					admin.Name .. " changed " .. reasonTargetName .. "'s ban reason from \"" .. (oldReason ~= "" and oldReason or "no reason") .. "\" to \"" .. newReason .. "\"")
				sendFeedback(admin, "Updated ban reason", false)
			end
		elseif action == "duration" then
			local banData = isBanned(userId)
			if banData then
				local oldDurationText = banData.ExpiresAt and formatDuration(math.max(0, banData.ExpiresAt - os.time())) or "Permanent"
				local durationSeconds = (typeof(value) == "number") and value or nil
				local newDurationText = durationSeconds and formatDuration(durationSeconds) or "Permanent"
				-- waitForPersist=true - see the comment on the reason
				-- branch above.
				banUser(userId, banData.Reason, banData.BannedBy, durationSeconds, true)
				local success, targetName = pcall(function()
					return Players:GetNameFromUserIdAsync(userId)
				end)
				local durationTargetName = success and targetName or ("UserId " .. userIdStr)
				logCommand(admin, "ban", durationTargetName, "duration updated: " .. newDurationText,
					admin.Name .. " changed " .. durationTargetName .. "'s ban duration from " .. oldDurationText .. " to " .. newDurationText)
				sendFeedback(admin, "Updated ban duration", false)
			end
		end
		local entries = buildBanListEntries()
		Remote.AdminBanList:FireClient(admin, "Banned Players (" .. #entries .. ")", entries)

	elseif kind == "mute" then
		if action == "remove" then
			-- Captured before removal - same reasoning as unban/unwarn
			-- above, and this previously logged under the "mute" command
			-- name with no detail, which made an unmute in :cmdlogs
			-- indistinguishable from a fresh :mute at a glance.
			local muteData = getMuteData(userId)
			mutedUserIds[userId] = nil
			removeMuteData(userId)
			local success, targetName = pcall(function()
				return Players:GetNameFromUserIdAsync(userId)
			end)
			local unmuteTargetName = success and targetName or ("UserId " .. userIdStr)
			logCommand(
				admin,
				"unmute",
				unmuteTargetName,
				muteData and ("removed mute: " .. tostring(muteData.Reason)) or "removed mute",
				admin.Name .. " unmuted " .. unmuteTargetName .. (muteData and (" (was: " .. tostring(muteData.Reason) .. ")") or "")
			)
			local targetPlayerObj = Players:GetPlayerByUserId(userId)
			if targetPlayerObj then
				Remote.AdminMuteStatus:FireClient(targetPlayerObj, false, nil)
			end
			sendFeedback(admin, "Unmuted", false)
		elseif action == "reason" and typeof(value) == "string" then
			local data = getMuteData(userId)
			if data then
				-- Captured before mutation - same reasoning as the ban
				-- reason branch above (data is the same table reference
				-- cached in muteRecordsCache).
				local oldReason = data.Reason
				local newReason = string.sub(value, 1, 200)
				data.Reason = newReason
				saveMuteData(userId, data, true)
				if mutedUserIds[userId] then mutedUserIds[userId] = data end
				local success, targetName = pcall(function()
					return Players:GetNameFromUserIdAsync(userId)
				end)
				local reasonTargetName = success and targetName or ("UserId " .. userIdStr)
				logCommand(admin, "mute", reasonTargetName, "reason updated: " .. newReason,
					admin.Name .. " changed " .. reasonTargetName .. "'s mute reason from \"" .. (oldReason ~= "" and oldReason or "no reason") .. "\" to \"" .. newReason .. "\"")
				sendFeedback(admin, "Updated mute reason", false)
			end
		elseif action == "duration" then
			local data = getMuteData(userId)
			if data then
				local oldDurationText = data.ExpiresAt and formatDuration(math.max(0, data.ExpiresAt - os.time())) or "Permanent"
				data.ExpiresAt = (typeof(value) == "number") and (os.time() + value) or nil
				local newDurationText = data.ExpiresAt and formatDuration(data.ExpiresAt - os.time()) or "Permanent"
				saveMuteData(userId, data, true)
				if mutedUserIds[userId] then mutedUserIds[userId] = data end
				local success, targetName = pcall(function()
					return Players:GetNameFromUserIdAsync(userId)
				end)
				local durationTargetName = success and targetName or ("UserId " .. userIdStr)
				logCommand(admin, "mute", durationTargetName, "duration updated: " .. newDurationText,
					admin.Name .. " changed " .. durationTargetName .. "'s mute duration from " .. oldDurationText .. " to " .. newDurationText)
				local targetPlayerObj = Players:GetPlayerByUserId(userId)
				if targetPlayerObj then
					Remote.AdminMuteStatus:FireClient(targetPlayerObj, true, data.ExpiresAt)
				end
				sendFeedback(admin, "Updated mute duration", false)
			end
		end
		syncChatMutes()
		local entries = buildMuteListEntries()
		Remote.AdminMuteList:FireClient(admin, "Muted Players (" .. #entries .. ")", entries)
	end
end)

Remote.AdminInventoryRemoveItem.OnServerEvent:Connect(function(admin, tool)
	local tier = getPlayerTier(admin)
	if not tierHasCommand(tier, "viewinv") and not tierHasCommand(tier, "clearinv") then return end
	if typeof(tool) ~= "Instance" or not tool:IsA("Tool") then return end

	-- Resolved BEFORE destroying it - once it's gone, there's no more
	-- Parent chain left to trace back to whoever it belonged to.
	local owner = findToolOwner(tool)
	local toolName = tool.Name
	tool:Destroy()

	if owner then
		logCommand(admin, "clearinv", owner.Name, "removed " .. toolName,
			admin.Name .. " removed " .. owner.Name .. "'s " .. toolName)
		sendInventoryList(admin, owner)
	end
	sendFeedback(admin, "Removed " .. toolName, false)
end)

-- Registered here (rather than up alongside startSpectating/
-- startControlling, where the rest of the spectate/controlplayer logic
-- lives) specifically because this needs logCommand/sendFeedback, both
-- declared as locals well after this point in the file - see the
-- comment left in their place, right after startSpectating, for the
-- full explanation.
Remote.AdminStopSpectating.OnServerEvent:Connect(function(admin)
	local state = spectatingState[admin.UserId]
	if not state then return end
	logCommand(admin, "spectate", state.Target.Name, "stopped", admin.Name .. " stopped spectating " .. state.Target.Name)
	stopSpectatingServer(admin)
	sendFeedback(admin, "Stopped spectating", false)
end)

Remote.AdminStopControlling.OnServerEvent:Connect(function(admin)
	local target = controllingUserIds[admin.UserId]
	if not target then return end
	logCommand(admin, "controlplayer", target.Name, "stopped", admin.Name .. " stopped controlling " .. target.Name)
	stopControlling(admin)
	sendFeedback(admin, "Stopped controlling " .. target.Name, false)
end)

print("[AdminServer] ready" .. (if storesOffline then " (Studio: bans, mutes, warnings and logs are kept for this session only; they save once the place is published with API access on)" else ""))

-- =====================================================================
-- Leaderboards view (admin panel): every board, reset a player on one
-- =====================================================================
do
local leaderboardBusy = {}
Remote.AdminLeaderboard.OnServerEvent:Connect(function(admin, action, index, userId)
	if not tierHasCommand(getPlayerTier(admin), "leaderboards") then
		return
	end
	-- Only a reset waits its turn; viewing reads the boards' cache, so every click is answered.
	if action == "Reset" and leaderboardBusy[admin] then
		return
	end
	local count = LeaderboardService.BoardCount()
	if type(index) ~= "number" or index ~= index then
		return
	end
	index = ((math.floor(index) - 1) % count) + 1
	if action == "Reset" then
		leaderboardBusy[admin] = true
	end
	local ok, err = pcall(function()
		if action == "Reset" then
			if type(userId) ~= "number" then
				return
			end
			local done, message = LeaderboardService.ResetEntry(index, userId)
			sendFeedback(admin, message, not done)
			if done then
				logCommand(admin, "leaderboards", tostring(userId), LeaderboardService.BoardTitle(index), admin.Name .. " " .. message)
			end
		end
		local rows = LeaderboardService.ListBoard(index, 100)
		-- A reset player can still be in the list for a moment (DataStore caching): hide them here.
		if action == "Reset" and type(userId) == "number" then
			for i = #rows, 1, -1 do
				if rows[i].UserId == userId then
					table.remove(rows, i)
				end
			end
		end
		Remote.AdminLeaderboard:FireClient(admin, index, count, LeaderboardService.BoardTitle(index), rows)
	end)
	if action == "Reset" then
		leaderboardBusy[admin] = nil
	end
	if not ok then
		dsWarn("[AdminServer] leaderboards: " .. tostring(err))
		sendFeedback(admin, "Couldn't load that leaderboard", true)
	end
end)
Players.PlayerRemoving:Connect(function(p)
	leaderboardBusy[p] = nil
end)
end

-- :globalannounce from any server shows here too.
task.spawn(function()
	pcall(function()
		MessagingService:SubscribeAsync("RinseCycle_GlobalAnnounce", function(message)
			local data = message.Data
			local text = type(data) == "table" and data.Text
			if type(text) == "string" and text ~= "" then
				for _, plr in ipairs(Players:GetPlayers()) do
					Remote.AdminAnnouncement:FireClient(plr, string.sub(text, 1, 200))
				end
			end
		end)
	end)
end)

-- =====================================================================
-- Pets view (:viewpets): see a player's pets, remove one, or add one
-- =====================================================================
do
local PET_TIER_NAMES = { "", "Golden ", "Rainbow " }
sendPetList = function(admin, target)
	local profile = DataService.Get(target)
	local rows = {}
	if profile then
		local equipped = {}
		for _, uid in ipairs(profile.Equipped or {}) do
			equipped[uid] = true
		end
		for _, pet in ipairs(profile.Pets or {}) do
			local def = Config.Pets[pet.Id]
			if def then
				local tier = math.clamp(tonumber(pet.Tier) or 1, 1, 3)
				table.insert(rows, {
					Id = pet.Uid,
					Line1 = PET_TIER_NAMES[tier] .. def.Name .. (if equipped[pet.Uid] then "  (equipped)" else ""),
					Line2 = def.Rarity .. "  ·  Speed " .. tostring(Config.PetSpeedRating(pet.Id, tier)) .. "/100",
				})
			end
		end
	end
	Remote.AdminPetList:FireClient(admin, target.UserId, "🐾 " .. target.Name .. "'s pets (" .. #rows .. ")", rows)
end

Remote.AdminPetAction.OnServerEvent:Connect(function(admin, action, targetUserId, a, b)
	if not tierHasCommand(getPlayerTier(admin), "viewpets") then
		return
	end
	local target = type(targetUserId) == "number" and Players:GetPlayerByUserId(targetUserId) or nil
	if not target then
		sendFeedback(admin, "They're not in this server any more", true)
		return
	end
	if action == "Remove" and type(a) == "string" then
		local result = PetService.Delete(target, a)
		if result and result.Ok then
			logCommand(admin, "viewpets", target.Name, "removed pet " .. a, admin.Name .. " removed a pet from " .. target.Name)
			sendFeedback(admin, "Removed that pet from " .. target.Name, false)
		else
			sendFeedback(admin, (result and result.Error) or "Couldn't remove that pet", true)
		end
	elseif action == "Add" and type(a) == "string" and Config.Pets[a] then
		local tier = math.clamp(math.floor(tonumber(b) or 1), 1, 3)
		local ok, err = PetService.GivePet(target, a, tier)
		if ok then
			local label = PET_TIER_NAMES[tier] .. Config.Pets[a].Name
			logCommand(admin, "givepet", target.Name, label, admin.Name .. " gave " .. target.Name .. " a " .. label)
			sendFeedback(admin, "Gave " .. target.Name .. " a " .. label, false)
		else
			sendFeedback(admin, err or "Couldn't add that pet", true)
		end
	else
		return
	end
	sendPetList(admin, target)
end)
end

-- =====================================================================
-- Server hops: invisibility carries over, and :joinserver / :bringserver land you next to them
-- =====================================================================
do
local function afterArrival(player)
	local data
	pcall(function()
		data = player:GetJoinData().TeleportData
	end)
	if type(data) ~= "table" then
		return
	end
	if type(data.AdminInvis) == "table" and table.find(data.AdminInvis, player.UserId) then
		player:SetAttribute("AdminInvis", true)
	end
	local followId = tonumber(data.FollowUserId)
	if followId and (data.Mode == "AdminJoin" or data.Mode == "AdminBring") then
		task.spawn(function()
			local character = player.Character or player.CharacterAdded:Wait()
			local root = character:WaitForChild("HumanoidRootPart", 10)
			task.wait(1)
			local other = Players:GetPlayerByUserId(followId)
			local otherRoot = other and other.Character and other.Character:FindFirstChild("HumanoidRootPart")
			if root and otherRoot then
				root.CFrame = otherRoot.CFrame * CFrame.new(0, 0, 4)
			end
		end)
	end
end

-- Keeps an :invis'd player invisible on every new character (respawns, and after a server hop).
local function watchInvis(player)
	player.CharacterAdded:Connect(function(character)
		if player:GetAttribute("AdminInvis") ~= true then
			return
		end
		invisibleUserIds[player.UserId] = nil -- the old character's saved looks don't apply any more
		character:WaitForChild("HumanoidRootPart", 10)
		task.wait(0.5)
		if player:GetAttribute("AdminInvis") == true and player.Character == character then
			setInvisible(player, true)
		end
	end)
	if player:GetAttribute("AdminInvis") == true and player.Character then
		invisibleUserIds[player.UserId] = nil
		setInvisible(player, true)
	end
end

Players.PlayerAdded:Connect(function(player)
	afterArrival(player)
	watchInvis(player)
end)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		afterArrival(player)
		watchInvis(player)
	end)
end
end

-- :bringserver from another server: if they're here, send them over.
task.spawn(function()
	pcall(function()
		MessagingService:SubscribeAsync("RinseCycle_AdminBring", function(message)
			local data = message.Data
			if type(data) ~= "table" or type(data.UserId) ~= "number" or type(data.JobId) ~= "string" then
				return
			end
			local player = Players:GetPlayerByUserId(data.UserId)
			if not player or data.JobId == game.JobId then
				return
			end
			pcall(function()
				local options = Instance.new("TeleportOptions")
				if type(data.Code) == "string" and data.Code ~= "" then
					options.ReservedServerAccessCode = data.Code
				else
					options.ServerInstanceId = data.JobId
				end
				options:SetTeleportData({ Mode = "AdminBring", FollowUserId = data.AdminId, AdminInvis = RunServers.InvisList({ player }) })
				TeleportService:TeleportAsync(game.PlaceId, { player }, options)
			end)
		end)
	end)
end)

-- =====================================================================
-- Staff list (:stafflist): everyone with a staff rank, Remove works even when they're offline
-- =====================================================================
Remote.AdminStaffList = Instance.new("RemoteEvent")
Remote.AdminStaffList.Name = "AdminStaffList"
Remote.AdminStaffList.Parent = ReplicatedStorage
Remote.AdminStaffAction = Instance.new("RemoteEvent")
Remote.AdminStaffAction.Name = "AdminStaffAction"
Remote.AdminStaffAction.Parent = ReplicatedStorage

function Staff.SendList(admin)
	local rows = {}
	for id, entry in pairs(Staff.Map) do
		if type(entry) == "table" then
			local online = Players:GetPlayerByUserId(tonumber(id) or 0) ~= nil
			table.insert(rows, {
				Id = tonumber(id),
				Line1 = tostring(entry.Name or id) .. "  [" .. tostring(Staff.Tags[entry.Tier] or entry.Tier) .. "]",
				Line2 = tostring(entry.Tier) .. "  ·  UserId " .. id .. (if online then "  ·  online" else ""),
			})
		end
	end
	table.sort(rows, function(a, b)
		return a.Line1 < b.Line1
	end)
	Remote.AdminStaffList:FireClient(admin, "🛡️ Staff (" .. #rows .. ")", rows)
end

Remote.AdminStaffAction.OnServerEvent:Connect(function(admin, action, userId)
	if not isOwner(admin) or action ~= "Remove" or type(userId) ~= "number" then
		return
	end
	local entry = Staff.Map[tostring(userId)]
	local name = if type(entry) == "table" then tostring(entry.Name) else tostring(userId)
	task.spawn(function()
		Staff.Set(userId, nil, nil)
		logCommand(admin, "setadminrank", name, "cleared", admin.Name .. " removed " .. name .. "'s staff rank")
		sendFeedback(admin, name .. " is no longer staff", false)
		Staff.SendList(admin)
	end)
end)

-- =====================================================================
-- All servers (:serverlist): each server lists its players in a shared MemoryStore map every
-- 30 s; the admin sees everyone everywhere and can join (arriving invisible) or bring anyone.
-- =====================================================================
Remote.AdminServerList = Instance.new("RemoteEvent")
Remote.AdminServerList.Name = "AdminServerList"
Remote.AdminServerList.Parent = ReplicatedStorage
Remote.AdminServerAction = Instance.new("RemoteEvent")
Remote.AdminServerAction.Name = "AdminServerAction"
Remote.AdminServerAction.Parent = ReplicatedStorage

ServerList.TTL = 90
ServerList.Map = nil
pcall(function()
	ServerList.Map = game:GetService("MemoryStoreService"):GetSortedMap("RinseCycle_ServerList")
end)

function ServerList.Snapshot()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		table.insert(list, { UserId = plr.UserId, Name = plr.Name, Display = plr.DisplayName, Hidden = plr:GetAttribute("AdminInvis") == true })
	end
	return { Players = list, Run = RunServers.IsRunServer, Updated = os.time() }
end

function ServerList.Publish()
	local map = ServerList.Map
	if not map then
		return
	end
	pcall(function()
		if #Players:GetPlayers() == 0 then
			map:RemoveAsync(game.JobId)
		else
			map:SetAsync(game.JobId, ServerList.Snapshot(), ServerList.TTL)
		end
	end)
end

-- Every server (this one included), as { JobId, Run, Players }.
function ServerList.Read()
	local servers = {}
	local map = ServerList.Map
	if map then
		pcall(function()
			for _, item in ipairs(map:GetRangeAsync(Enum.SortDirection.Ascending, 200)) do
				if type(item.value) == "table" and item.key ~= game.JobId then
					table.insert(servers, { JobId = item.key, Run = item.value.Run == true, Players = item.value.Players or {} })
				end
			end
		end)
	end
	local here = ServerList.Snapshot()
	table.insert(servers, 1, { JobId = game.JobId, Run = here.Run, Players = here.Players, Here = true })
	return servers
end

function ServerList.Send(admin)
	local rows = {}
	local busiest, busiestCount = nil, 0
	for i, server in ipairs(ServerList.Read()) do
		local names, follow = {}, nil
		for _, p in ipairs(server.Players) do
			if p.UserId ~= admin.UserId and not p.Hidden then
				table.insert(names, tostring(p.Name))
				follow = follow or p.UserId
			end
		end
		local count = #names
		if not server.Here and not server.Run and count > busiestCount then
			busiest, busiestCount = server.JobId, count
		end
		-- One row (and one Join) per server; your own server isn't listed.
		if not server.Here and count > 0 then
			local shown = table.concat(names, ", ", 1, math.min(#names, 6)) .. (if #names > 6 then ", +" .. (#names - 6) .. " more" else "")
			table.insert(rows, {
				Id = follow,
				JobId = server.JobId,
				Line1 = (if server.Run then "Run" else "Lobby") .. " server " .. i .. " - " .. count .. " player" .. (if count == 1 then "" else "s"),
				Line2 = shown,
			})
		end
	end
	Remote.AdminServerList:FireClient(admin, "Every server (" .. #rows .. ")", rows, busiest)
end

-- Teleports the admin into a server, invisible (they arrive hidden: nobody sees them join).
function ServerList.Join(admin, jobId, followUserId)
	if jobId == game.JobId then
		local target = followUserId and Players:GetPlayerByUserId(followUserId)
		if target then
			gotoPlayer(admin, target)
		end
		return true
	end
	local code = RunServers.AccessCodeForJob(jobId)
	return pcall(function()
		local options = Instance.new("TeleportOptions")
		if code then
			options.ReservedServerAccessCode = code
		else
			options.ServerInstanceId = jobId
		end
		options:SetTeleportData({ Mode = "AdminJoin", FollowUserId = followUserId, AdminInvis = { admin.UserId } })
		TeleportService:TeleportAsync(game.PlaceId, { admin }, options)
	end)
end

Remote.AdminServerAction.OnServerEvent:Connect(function(admin, action, jobId, userId)
	local tier = getPlayerTier(admin)
	if type(jobId) ~= "string" or jobId == "" then
		return
	end
	if action == "Join" and tierHasCommand(tier, "joinserver") then
		local ok = ServerList.Join(admin, jobId, tonumber(userId))
		sendFeedback(admin, if ok then "Joining that server (you'll arrive invisible)..." else "That teleport couldn't start", not ok)
		if ok then
			logCommand(admin, "joinserver", tostring(userId or jobId), nil, admin.Name .. " joined another server from the server list")
		end
	elseif action == "Bring" and tierHasCommand(tier, "bringserver") and type(userId) == "number" then
		local here = Players:GetPlayerByUserId(userId)
		if here then
			bringPlayer(admin, here)
			sendFeedback(admin, "Brought " .. here.Name, false)
			return
		end
		local ok = pcall(function()
			MessagingService:PublishAsync("RinseCycle_AdminBring", {
				UserId = userId,
				JobId = game.JobId,
				Code = RunServers.AccessCodeForJob(game.JobId),
				AdminId = admin.UserId,
			})
		end)
		sendFeedback(admin, if ok then "Asked their server to send them here..." else "Couldn't reach other servers", not ok)
	end
end)

task.spawn(function()
	while true do
		ServerList.Publish()
		task.wait(30)
	end
end)
Players.PlayerAdded:Connect(function()
	task.delay(2, ServerList.Publish)
end)
Players.PlayerRemoving:Connect(function()
	task.delay(1, ServerList.Publish)
end)
game:BindToClose(function()
	if ServerList.Map then
		pcall(function()
			ServerList.Map:RemoveAsync(game.JobId)
		end)
	end
end)

-- =====================================================================
-- Global events (the panel's Global tab): polls, giveaways, pass drops and x2 boosts in EVERY
-- server. One MessagingService topic carries them all; each server runs its own players' part.
-- Without MessagingService (Studio) everything just runs in this server.
-- =====================================================================
Remote.GlobalPoll = Instance.new("RemoteEvent")
Remote.GlobalPoll.Name = "GlobalPoll"
Remote.GlobalPoll.Parent = ReplicatedStorage
Remote.GlobalPollVote = Instance.new("RemoteEvent")
Remote.GlobalPollVote.Name = "GlobalPollVote"
Remote.GlobalPollVote.Parent = ReplicatedStorage
Remote.GlobalCountdown = Instance.new("RemoteEvent") -- S->C ("Set", name, endsAt, liveMinutes) / ("Clear")
Remote.GlobalCountdown.Name = "GlobalCountdown"
Remote.GlobalCountdown.Parent = ReplicatedStorage
do
	local TextService = game:GetService("TextService")
	local Format = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Format"))
	local TOPIC = "RinseCycle_GlobalEvent"
	local handlers = {}
	local Commands = GlobalEvents.Commands

	local function publish(data)
		local ok = pcall(function()
			MessagingService:PublishAsync(TOPIC, data)
		end)
		if not ok then
			local handler = handlers[data.Kind]
			if handler then
				task.spawn(handler, data)
			end
		end
		return ok
	end
	task.spawn(function()
		pcall(function()
			MessagingService:SubscribeAsync(TOPIC, function(message)
				local data = message.Data
				local handler = type(data) == "table" and handlers[data.Kind]
				if handler then
					handler(data)
				end
			end)
		end)
	end)

	local function bannerAll(text)
		for _, plr in ipairs(Players:GetPlayers()) do
			Remote.AdminAnnouncement:FireClient(plr, string.sub(text, 1, 200))
		end
	end
	handlers.Banner = function(d)
		if type(d.Text) == "string" then
			bannerAll(d.Text)
		end
	end

	----------------------------------------------------------------- polls
	-- :globalpoll [30|60|120] Question | answer | answer ... Everyone gets a popup with buttons;
	-- each server counts its own votes and sends the counts back to the admin's server, which sends
	-- the final results to every server: each player's poll card turns into the results (once, no
	-- banner), and stays until they close it.
	local polls = {} -- [id] = { Id, Question, Options, EndsAt, Votes = { [userId] = index } }
	local collecting = {} -- on the admin's server: [id] = { Counts, Question, Options, Admin }

	local function sendPoll(plr, poll)
		Remote.GlobalPoll:FireClient(plr, "Start", poll.Id, poll.Question, poll.Options, poll.EndsAt)
	end
	handlers.PollStart = function(d)
		if type(d.Id) ~= "string" or type(d.Options) ~= "table" or polls[d.Id] then
			return
		end
		local poll = { Id = d.Id, Question = tostring(d.Question), Options = d.Options, EndsAt = tonumber(d.EndsAt) or os.time(), Origin = d.Origin, Votes = {} }
		polls[d.Id] = poll
		for _, plr in ipairs(Players:GetPlayers()) do
			sendPoll(plr, poll)
		end
		task.delay(math.max(0, poll.EndsAt - os.time()) + 0.5, function()
			local counts = {}
			for i = 1, #poll.Options do
				counts[i] = 0
			end
			for _, index in pairs(poll.Votes) do
				counts[index] += 1
			end
			polls[poll.Id] = nil
			for _, plr in ipairs(Players:GetPlayers()) do
				Remote.GlobalPoll:FireClient(plr, "End", poll.Id)
			end
			publish({ Kind = "PollTally", Id = poll.Id, Origin = poll.Origin, Counts = counts })
		end)
	end
	handlers.PollTally = function(d)
		local c = collecting[d.Id]
		if not c or d.Origin ~= game.JobId or type(d.Counts) ~= "table" then
			return
		end
		for i = 1, #c.Options do
			c.Counts[i] += math.max(0, math.floor(tonumber(d.Counts[i]) or 0))
		end
	end
	handlers.PollResult = function(d)
		if type(d.Id) ~= "string" or type(d.Options) ~= "table" or type(d.Counts) ~= "table" then
			return
		end
		for _, plr in ipairs(Players:GetPlayers()) do
			Remote.GlobalPoll:FireClient(plr, "Result", d.Id, tostring(d.Question), d.Options, d.Counts)
		end
	end
	Players.PlayerAdded:Connect(function(plr)
		for _, poll in pairs(polls) do
			if poll.EndsAt > os.time() then
				sendPoll(plr, poll)
			end
		end
	end)
	Remote.GlobalPollVote.OnServerEvent:Connect(function(plr, id, index)
		local poll = type(id) == "string" and polls[id]
		if poll and type(index) == "number" and index == math.floor(index) and index >= 1 and index <= #poll.Options and os.time() <= poll.EndsAt then
			poll.Votes[plr.UserId] = index -- you can change your mind until it ends
		end
	end)

	Commands.globalpoll = function(admin, text)
		local seconds, rest = text:match("^(%d+)%s+(.+)$")
		seconds = math.clamp(tonumber(seconds) or 60, 15, 300)
		local parts = {}
		for piece in string.gmatch(rest or text, "[^|]+") do
			piece = piece:match("^%s*(.-)%s*$")
			if piece ~= "" then
				table.insert(parts, string.sub(piece, 1, 60))
			end
		end
		if #parts < 3 then
			sendFeedback(admin, "Usage: :globalpoll 60 Question | answer | answer (2 to 4 answers)", true)
			return
		end
		local question = table.remove(parts, 1)
		local options = { table.unpack(parts, 1, math.min(#parts, 4)) }
		-- Chat filter: the question and answers are shown to everyone.
		local okFilter, filtered = pcall(function()
			local all = question .. "\n" .. table.concat(options, "\n")
			return TextService:FilterStringAsync(all, admin.UserId):GetNonChatStringForBroadcastAsync()
		end)
		if okFilter and type(filtered) == "string" then
			local lines = string.split(filtered, "\n")
			question = lines[1] or question
			for i = 1, #options do
				options[i] = lines[i + 1] or options[i]
			end
		end
		local id = game.JobId .. ":" .. tostring(os.clock())
		local counts = {}
		for i = 1, #options do
			counts[i] = 0
		end
		collecting[id] = { Counts = counts, Question = question, Options = options }
		publish({ Kind = "PollStart", Id = id, Question = question, Options = options, EndsAt = os.time() + seconds, Origin = game.JobId })
		sendFeedback(admin, string.format("Poll sent to every server: results in %d s", seconds), false)
		logCommand(admin, "globalpoll", nil, question, admin.Name .. " started a global poll: " .. question)
		-- Every server's counts come back a few seconds after it closes.
		task.delay(seconds + 7, function()
			local c = collecting[id]
			collecting[id] = nil
			if not c then
				return
			end
			publish({ Kind = "PollResult", Id = id, Question = c.Question, Options = c.Options, Counts = c.Counts })
		end)
	end

	----------------------------------------------------------------- giveaways
	-- :globalgive [Bubbles|Gems|Coins] [amount]: everyone online, in every server. Coins only exist
	-- inside a dishwasher, so they go to whoever is cleaning right now.
	local CURRENCIES = { bubbles = "Bubbles", gems = "Gems", coins = "Coins" }
	handlers.GiveAll = function(d)
		local currency = CURRENCIES[string.lower(tostring(d.Currency))]
		local amount = math.floor(tonumber(d.Amount) or 0)
		if not currency or amount <= 0 then
			return
		end
		for _, plr in ipairs(Players:GetPlayers()) do
			local given = false
			if currency == "Bubbles" then
				given = DataService.AddBubbles(plr, amount, "admin event")
			elseif currency == "Gems" then
				given = DataService.AddGems(plr, amount)
			else
				given = RoundService.AddCoins(plr, amount)
			end
			if given then
				celebrate(plr, "Admin event!", string.format("Everyone got %s %s!", Format.Commas(amount), currency), "@Gift")
			end
		end
	end
	Commands.globalgive = function(admin, text)
		local currencyText, amountText = text:match("^(%a+)%s+(%d+)")
		local currency = currencyText and CURRENCIES[string.lower(currencyText)]
		local amount = math.clamp(math.floor(tonumber(amountText) or 0), 0, 1000000)
		if not currency or amount <= 0 then
			sendFeedback(admin, "Usage: :globalgive [Bubbles|Gems|Coins] [amount]", true)
			return
		end
		local ok = publish({ Kind = "GiveAll", Currency = currency, Amount = amount })
		sendFeedback(admin, string.format("Gave everyone %s %s%s", Format.Commas(amount), currency, if ok then " in every server" else " (this server only)"), false)
		logCommand(admin, "globalgive", nil, currency .. " " .. amount, string.format("%s gave everyone %d %s", admin.Name, amount, currency))
	end

	----------------------------------------------------------------- pass drops
	-- :globalpassdrop [winners] [pass key | random]: that many random players (across every
	-- server) win a game pass. Someone who already has it gets a different pass they don't have
	-- (or 50 Gems if they own them all).
	handlers.PassDrop = function(d)
		if type(d.W) ~= "table" then
			return
		end
		for _, w in ipairs(d.W) do
			local plr = Players:GetPlayerByUserId(tonumber(w.u) or 0)
			if plr then
				local passes = DataService.GetPasses and DataService.GetPasses(plr) or {}
				local function has(key)
					return passes[key] == true or plr:GetAttribute(gamepassAttribute(key)) == true
				end
				local pass = Config.GetPass(tostring(w.p))
				if not pass or has(pass.Key) then
					pass = nil
					local free = {}
					for _, p in ipairs(Config.GamePasses) do
						if not has(p.Key) then
							table.insert(free, p)
						end
					end
					if #free > 0 then
						pass = free[math.random(1, #free)]
					end
				end
				if pass then
					setGamepassGrant(plr, pass, true, false)
					celebrate(plr, "You won a game pass!", "Lucky draw: you got " .. pass.Name .. "!", pass.Icon)
				else
					DataService.AddGems(plr, 50)
					celebrate(plr, "You won!", "You own every pass already, so here are 50 Gems!", "@Gift")
				end
			end
		end
		if type(d.Text) == "string" then
			bannerAll(d.Text)
		end
	end
	Commands.globalpassdrop = function(admin, text)
		local countText, passText = text:match("^(%d+)%s*(.*)$")
		local count = math.clamp(math.floor(tonumber(countText) or 0), 0, 25)
		if count <= 0 then
			sendFeedback(admin, "Usage: :globalpassdrop [winners 1-25] [pass or random]", true)
			return
		end
		local chosen = nil
		if passText ~= "" and string.lower(passText) ~= "random" then
			chosen = resolveGamepass(passText)
			if not chosen then
				sendFeedback(admin, "Unknown pass: " .. passText, true)
				return
			end
		end
		-- Everyone online in every server (from the server list), hidden staff left out.
		local pool = {}
		local seen = {}
		for _, server in ipairs(ServerList.Read()) do
			for _, p in ipairs(server.Players or {}) do
				local id = tonumber(p.UserId)
				if id and not p.Hidden and not seen[id] then
					seen[id] = true
					table.insert(pool, { UserId = id, Name = tostring(p.Name) })
				end
			end
		end
		if #pool == 0 then
			sendFeedback(admin, "Nobody online to win.", true)
			return
		end
		local winners, names = {}, {}
		for _ = 1, math.min(count, #pool) do
			local pick = table.remove(pool, math.random(1, #pool))
			local key = if chosen then chosen.Key else Config.GamePasses[math.random(1, #Config.GamePasses)].Key
			table.insert(winners, { u = pick.UserId, p = key })
			table.insert(names, pick.Name)
		end
		local shown = table.concat(names, ", ", 1, math.min(#names, 8)) .. (if #names > 8 then string.format(" and %d more", #names - 8) else "")
		local banner = string.format("Pass drop! %s won %s!", shown, if chosen then chosen.Name else "a game pass")
		local ok = publish({ Kind = "PassDrop", W = winners, Text = banner })
		sendFeedback(admin, string.format("%d winner(s): %s%s", #winners, shown, if ok then "" else " (this server only)"), false)
		logCommand(admin, "globalpassdrop", nil, if chosen then chosen.Name else "random", admin.Name .. " ran a pass drop: " .. shown)
	end

	----------------------------------------------------------------- event countdown
	-- :globalcountdown <time> [name]: a countdown banner on everyone's screen, in every server, and
	-- for anyone who joins later (it lives in a MemoryStore hash map, every server re-reads it each
	-- minute). At zero it turns into "<NAME> IS LIVE NOW!" for LIVE_MINUTES, then goes. :cancelcountdown
	-- removes it. Time: 90m, 24h, 2d (plain numbers are minutes), from 1 minute to 14 days.
	local LIVE_MINUTES = 60
	local countdown = nil -- { Name, EndsAt, LiveMinutes }
	local countdownMap = nil
	pcall(function()
		countdownMap = game:GetService("MemoryStoreService"):GetHashMap("RinseCycle_Countdown")
	end)
	local function sendCountdown(plr)
		if countdown and os.time() < countdown.EndsAt + countdown.LiveMinutes * 60 then
			Remote.GlobalCountdown:FireClient(plr, "Set", countdown.Name, countdown.EndsAt, countdown.LiveMinutes)
		else
			Remote.GlobalCountdown:FireClient(plr, "Clear")
		end
	end
	handlers.CountdownSet = function(d)
		if type(d.Name) ~= "string" or type(d.EndsAt) ~= "number" then
			return
		end
		countdown = { Name = string.sub(d.Name, 1, 40), EndsAt = d.EndsAt, LiveMinutes = tonumber(d.LiveMinutes) or LIVE_MINUTES }
		for _, plr in ipairs(Players:GetPlayers()) do
			sendCountdown(plr)
		end
	end
	handlers.CountdownClear = function()
		countdown = nil
		for _, plr in ipairs(Players:GetPlayers()) do
			sendCountdown(plr)
		end
	end
	Players.PlayerAdded:Connect(function(plr)
		task.defer(sendCountdown, plr)
	end)
	-- Servers that started after the command (or missed the message) catch up from the store.
	local function syncCountdown()
		if not countdownMap then
			return
		end
		local ok, value = pcall(function()
			return countdownMap:GetAsync("current")
		end)
		if not ok then
			return
		end
		if type(value) == "table" and type(value.EndsAt) == "number" then
			if not countdown or countdown.EndsAt ~= value.EndsAt or countdown.Name ~= value.Name then
				handlers.CountdownSet(value)
			end
		elseif countdown then
			handlers.CountdownClear()
		end
	end
	task.spawn(function()
		while true do
			syncCountdown()
			task.wait(60)
		end
	end)
	Commands.globalcountdown = function(admin, text)
		local num, unit, rest = string.match(text, "^%s*(%d+%.?%d*)%s*([smhdSMHD]?)%s*(.*)$")
		local mult = ({ s = 1, m = 60, h = 3600, d = 86400 })[string.lower(unit or "")] or 60
		local seconds = (tonumber(num) or 0) * mult
		if seconds < 60 or seconds > 14 * 86400 then
			sendFeedback(admin, "Usage: :globalcountdown <time 1m-14d, like 24h> [event name]", true)
			return
		end
		local name = string.match(rest or "", "^%s*(.-)%s*$")
		if not name or name == "" then
			name = "Admin Abuse"
		end
		local okFilter, filtered = pcall(function()
			return TextService:FilterStringAsync(name, admin.UserId):GetNonChatStringForBroadcastAsync()
		end)
		if okFilter and type(filtered) == "string" then
			name = filtered
		end
		name = string.sub(name, 1, 40)
		local data = { Kind = "CountdownSet", Name = name, EndsAt = os.time() + math.floor(seconds), LiveMinutes = LIVE_MINUTES }
		if countdownMap then
			pcall(function()
				countdownMap:SetAsync("current", data, math.min(math.floor(seconds) + LIVE_MINUTES * 60 + 600, 3888000))
			end)
		end
		local ok = publish(data)
		sendFeedback(admin, string.format("Countdown for %s set (%s)%s", name, Format.Time and Format.Time(seconds) or tostring(math.floor(seconds / 60)) .. " min", if ok then " in every server" else " (this server only)"), false)
		logCommand(admin, "globalcountdown", nil, name, string.format("%s started a countdown for %s (%d min)", admin.Name, name, math.floor(seconds / 60)))
	end
	Commands.cancelcountdown = function(admin, _text)
		if countdownMap then
			pcall(function()
				countdownMap:RemoveAsync("current")
			end)
		end
		local ok = publish({ Kind = "CountdownClear" })
		sendFeedback(admin, "Event countdown cancelled" .. (if ok then " in every server" else " (this server only)"), false)
		logCommand(admin, "cancelcountdown", nil, "", admin.Name .. " cancelled the event countdown")
	end

	----------------------------------------------------------------- x2 boost
	-- :globalboost [minutes]: everyone online gets x2 cleaning for that long (on top of any boost).
	handlers.Boost = function(d)
		local minutes = math.floor(tonumber(d.Minutes) or 0)
		if minutes <= 0 then
			return
		end
		for _, plr in ipairs(Players:GetPlayers()) do
			if DataService.AddBoost(plr, minutes * 60) then
				celebrate(plr, "Admin event!", string.format("x2 Cleaning for everyone: %d minutes!", minutes), "@Gift")
			end
		end
	end
	Commands.globalboost = function(admin, text)
		local minutes = math.clamp(math.floor(tonumber(text:match("^(%d+)")) or 0), 0, 180)
		if minutes <= 0 then
			sendFeedback(admin, "Usage: :globalboost [minutes 1-180]", true)
			return
		end
		local ok = publish({ Kind = "Boost", Minutes = minutes })
		sendFeedback(admin, string.format("x2 Cleaning for everyone for %d minutes%s", minutes, if ok then " in every server" else " (this server only)"), false)
		logCommand(admin, "globalboost", nil, tostring(minutes), string.format("%s gave everyone %d min of x2 cleaning", admin.Name, minutes))
	end
	----------------------------------------------------------------- Admin Abuse show
	-- Runs by itself in EVERY server from the event's Starts time (Config.UpcomingEvents, key
	-- AdminAbuse), so no one has to press anything: every server reads the same clock. Banners and the
	-- warning countdown, the lobby giant and the chat lines are per server; the votes and the prizes
	-- are done once for the whole game: a server "claims" a step in a MemoryStore hash map first, so
	-- only one server runs it, and the existing global poll / give / pass drop do the rest.
	-- :abuseshow [minutes] starts the whole thing that many minutes from now, to try it; ":abuseshow
	-- reset" puts the real time back.
	local Show = Config.AbuseShow
	local function abuseEvent(): any
		for _, e in Config.UpcomingEvents do
			if e.Key == Show.EventKey then
				return e
			end
		end
		return nil
	end
	local realStarts, realEnds = nil, nil
	do
		local e = abuseEvent()
		if e then
			realStarts, realEnds = e.Starts, e.Ends
		end
	end
	handlers.AbuseSchedule = function(d)
		local e = abuseEvent()
		if e and tonumber(d.Starts) and tonumber(d.Ends) then
			e.Starts, e.Ends = d.Starts, d.Ends
		end
	end

	local STUB = { Name = Show.OwnerName .. " (event)", UserId = 0 } -- stands in for an admin in the commands
	local function say(text: string)
		for _, plr in ipairs(Players:GetPlayers()) do
			Remote.AbuseSay:FireClient(plr, Show.OwnerName, text)
		end
	end
	local claimMap = nil
	pcall(function()
		claimMap = game:GetService("MemoryStoreService"):GetHashMap("RinseCycle_AbuseSteps")
	end)
	-- True on exactly one server per step (and on this one when MemoryStore isn't there: Studio).
	local function claim(step: string): boolean
		if not claimMap then
			return true
		end
		local ok, result = pcall(function()
			return claimMap:UpdateAsync(step, function(old)
				if old ~= nil then
					return nil
				end
				return game.JobId
			end, 7200)
		end)
		return ok and result == game.JobId
	end
	local function everyoneOnline(): number
		local seen, n = {}, 0
		for _, server in ipairs(ServerList.Read()) do
			for _, p in ipairs(server.Players or {}) do
				local id = tonumber(p.UserId)
				if id and not p.Hidden and not seen[id] then
					seen[id] = true
					n += 1
				end
			end
		end
		return math.max(n, #Players:GetPlayers(), 1)
	end

	local function applyOutcome(option: any)
		if option.Kind == "Bubbles" or option.Kind == "Gems" then
			local share = math.max(1, math.floor(option.Amount / everyoneOnline()))
			publish({ Kind = "GiveAll", Currency = option.Kind, Amount = share })
			publish({ Kind = "Banner", Text = string.format("%s: everyone gets %s %s!", option.Text, Format.Commas(share), option.Kind) })
		elseif option.Kind == "Passes" then
			Commands.globalpassdrop(STUB, tostring(option.Amount) .. " random")
		end
	end
	-- One vote: the poll goes to every server (the existing global poll), the counts come back here, and
	-- the winner is applied. The winner is the most votes (the first on a tie; nobody voted = the first).
	local function runRound(round: any)
		local options = {}
		for _, o in round.Options do
			table.insert(options, o.Text)
		end
		local id = game.JobId .. ":abuse:" .. tostring(os.clock())
		local counts = {}
		for i = 1, #options do
			counts[i] = 0
		end
		collecting[id] = { Counts = counts, Question = round.Question, Options = options }
		publish({ Kind = "PollStart", Id = id, Question = round.Question, Options = options, EndsAt = Config.Now() + round.Seconds, Origin = game.JobId })
		task.delay(round.Seconds + 7, function()
			local c = collecting[id]
			collecting[id] = nil
			if not c then
				return
			end
			publish({ Kind = "PollResult", Id = id, Question = c.Question, Options = c.Options, Counts = c.Counts })
			local best, bestVotes = 1, -1
			for i, n in ipairs(c.Counts) do
				if n > bestVotes then
					best, bestVotes = i, n
				end
			end
			local winner = round.Options[best]
			publish({ Kind = "AbuseSay", Text = "chat has spoken: " .. winner.Text .. "!" })
			task.delay(3, applyOutcome, winner)
		end)
	end
	handlers.AbuseSay = function(d)
		if type(d.Text) == "string" then
			say(string.sub(d.Text, 1, 200))
		end
	end

	-- The giant: a copy of the owner's avatar, scaled up, pacing round the lobby room. Anchored and
	-- non-colliding (players walk through him), animated with Roblox's default R15 walk and wave.
	local giant: Model? = nil
	local giantConn: RBXScriptConnection? = nil
	local function removeGiant()
		if giantConn then
			giantConn:Disconnect()
			giantConn = nil
		end
		if giant then
			giant:Destroy()
			giant = nil
		end
	end
	local function spawnGiant()
		if giant then
			return
		end
		local ok, model = pcall(function()
			return Players:CreateHumanoidModelFromUserId(Show.OwnerUserId)
		end)
		if not ok or not model then
			return
		end
		model.Name = "AbuseGiant"
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.CanTouch = false
				part.CanQuery = false
				part.Anchored = true
			end
		end
		local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then
			model:Destroy()
			return
		end
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		model.Parent = workspace
		pcall(function()
			model:ScaleTo(Show.GiantScale)
		end)
		giant = model
		-- A name tag over his head.
		local head = model:FindFirstChild("Head") :: BasePart?
		if head then
			local tag = Instance.new("BillboardGui")
			tag.Size = UDim2.fromOffset(360, 70)
			tag.StudsOffsetWorldSpace = Vector3.new(0, 12 * Show.GiantScale / 6, 0)
			tag.AlwaysOnTop = true
			tag.MaxDistance = 5000
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundTransparency = 1
			label.Font = Enum.Font.FredokaOne
			label.TextScaled = true
			label.TextColor3 = Color3.fromRGB(255, 213, 74)
			label.TextStrokeTransparency = 0
			label.Text = Show.OwnerName
			label.Parent = tag
			tag.Parent = head
		end
		local track: AnimationTrack? = nil
		pcall(function()
			local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
			local anim = Instance.new("Animation")
			anim.AnimationId = "rbxassetid://507777826" -- default R15 walk
			track = animator:LoadAnimation(anim)
			track.Looped = true
			track:Play()
		end)
		-- Round the room, inset from its walls (the lobby room is 840 wide, z -560..400, floor at -130).
		local floorY = -130
		local path = { Vector3.new(-320, floorY, 300), Vector3.new(320, floorY, 300), Vector3.new(320, floorY, -460), Vector3.new(-320, floorY, -460) }
		local seg, pos = 1, path[1]
		local speed = 70
		local cf0, size0 = model:GetBoundingBox()
		local rootY = root.Position.Y + (floorY - (cf0.Position.Y - size0.Y / 2)) -- feet on the floor
		giantConn = RunService.Heartbeat:Connect(function(dt)
			local target = path[seg % #path + 1]
			local dir = target - pos
			if dir.Magnitude < speed * dt then
				pos = target
				seg = seg % #path + 1
			else
				pos += dir.Unit * speed * dt
			end
			local look = path[seg % #path + 1] - pos
			model:PivotTo(CFrame.lookAt(Vector3.new(pos.X, rootY, pos.Z), Vector3.new(pos.X + look.X, rootY, pos.Z + look.Z)))
		end)
	end

	-- The clock. Each step happens once per server, a second or so after its time comes.
	local fired: { [string]: boolean } = {}
	local function once(key: string): boolean
		if fired[key] then
			return false
		end
		fired[key] = true
		return true
	end
	task.spawn(function()
		while true do
			task.wait(1)
			local e = abuseEvent()
			if not e then
				continue
			end
			local t = Config.Now() - e.Starts -- negative before the start
			local tag = tostring(e.Starts)
			-- Countdown warnings (only if we're still within a minute of them: late servers stay quiet).
			for _, w in ipairs(Show.Warnings) do
				if t >= -w and t < -w + 60 and once("warn" .. w .. tag) then
					local mins = math.floor(w / 60)
					bannerAll(string.format("Admin Abuse starts in %d minute%s! You can't start a round right now. Stay tuned for free game passes, Bubbles and surprises!", mins, if mins == 1 then "" else "s"))
				end
			end
			if t >= 0 and t < Show.ShowSeconds then
				if once("start" .. tag) then
					bannerAll("ADMIN ABUSE IS LIVE!")
				end
				-- Anyone still in a run goes back to the lobby.
				for _, plr in ipairs(Players:GetPlayers()) do
					if RoundService.IsInRun(plr) then
						RoundService.RemoveFromRun(plr)
					end
				end
				if not RunServers.IsRunServer and t >= 2 then
					spawnGiant()
				end
				for i, line in ipairs(Show.Lines) do
					if t >= line[1] and t < line[1] + 30 and once("line" .. i .. tag) then
						say(line[2])
					end
				end
				for i, round in ipairs(Show.Rounds) do
					if t >= round.At and t < round.At + 30 and once("round" .. i .. tag) and claim("round" .. i .. ":" .. tag) then
						runRound(round)
					end
				end
			elseif t >= Show.ShowSeconds then
				if giant then
					removeGiant()
				end
			end
		end
	end)

	Commands.abuseshow = function(admin, text)
		local e = abuseEvent()
		if not e then
			sendFeedback(admin, "No Admin Abuse event is set up.", true)
			return
		end
		local arg = string.lower(text:match("^%s*(%S*)") or "")
		local starts, ends
		if arg == "reset" then
			if not realStarts then
				return
			end
			starts, ends = realStarts, realEnds
		else
			local minutes = math.clamp(tonumber(arg) or 1, 0.25, 600)
			starts = Config.Now() + math.floor(minutes * 60)
			ends = starts + 3600
		end
		if claimMap then
			-- steps from an earlier try would otherwise count as already done
			pcall(function()
				for i = 1, #Show.Rounds do
					claimMap:RemoveAsync("round" .. i .. ":" .. tostring(starts))
				end
			end)
		end
		local ok = publish({ Kind = "AbuseSchedule", Starts = starts, Ends = ends })
		if arg ~= "reset" then
			local mins = math.ceil((starts - Config.Now()) / 60)
			publish({ Kind = "Banner", Text = string.format("Admin Abuse starts in %d minute%s! You can't start a round right now. Stay tuned for free game passes, Bubbles and surprises!", mins, if mins == 1 then "" else "s") })
		end
		sendFeedback(admin, if arg == "reset" then "Admin Abuse is back on its real time." else string.format("Admin Abuse show starts in %s%s. Rounds are paused from now.", Format.Time and Format.Time(starts - Config.Now()) or tostring(math.floor((starts - Config.Now()) / 60)) .. " min", if ok then " (every server)" else " (this server only)"), false)
		logCommand(admin, "abuseshow", nil, arg, admin.Name .. " set the Admin Abuse show: " .. tostring(arg))
	end
end
