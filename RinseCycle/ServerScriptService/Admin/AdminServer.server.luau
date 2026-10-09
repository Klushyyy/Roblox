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
local DailyNotify = require(GameServices:WaitForChild("DailyNotify"))
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

-- The one account allowed to use the admin system in a live server: Klushy (display name
-- Klushy). Matched by UserId, with the username as a backup in case the id in Config changes.
local OWNER_USER_ID = Config.Social.CreatorUserId
local OWNER_USERNAME = "klushy"

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
	"globalpoll", "analytics", "badges",
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
local STUDIO_ONLY_COMMANDS = { "abuseshow", "abuselocal", "privatelobby", "abusefx", "abusedebug", "notifytest", "resetfirstrun", "clubreset" }

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
local AnalyticsReport = {}
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
Remote.AbuseSay = Instance.new("RemoteEvent") -- S->C (ownerName, text, append?): a line of chat from the owner during Admin Abuse ({HOLD} in the text becomes this player's prompt key; append adds to the box that is up, for the countdown)
Remote.AbuseSay.Name = "AbuseSay"
Remote.AbuseSay.Parent = ReplicatedStorage
Remote.AbuseBoom = Instance.new("RemoteEvent") -- S->C (strength, position): a stomp or blast: shakes the screen
Remote.AbuseBoom.Name = "AbuseBoom"
Remote.AbuseBoom.Parent = ReplicatedStorage
Remote.AbuseOffer = Instance.new("RemoteEvent") -- S->C (offer id, seconds): "do you want to fly?" (seconds 0 closes it)
Remote.AbuseOffer.Name = "AbuseOffer"
Remote.AbuseOffer.Parent = ReplicatedStorage
Remote.AbuseOfferReply = Instance.new("RemoteEvent") -- C->S (pick id, "fly" / "giant" / "speed", or nothing for No thanks)
Remote.AbuseOfferReply.Name = "AbuseOfferReply"
Remote.AbuseOfferReply.Parent = ReplicatedStorage
Remote.AbusePerk = Instance.new("RemoteEvent") -- S->C (kind: "giant" or nil, on): the giant power-up's on/off button
Remote.AbusePerk.Name = "AbusePerk"
Remote.AbusePerk.Parent = ReplicatedStorage
Remote.AbuseFlyState = Instance.new("RemoteEvent") -- C->S (on): the player started / stopped flying (the obby does not count progress made in the air)
Remote.AbuseFlyState.Name = "AbuseFlyState"
Remote.AbuseFlyState.Parent = ReplicatedStorage
Remote.AbuseGrab = Instance.new("RemoteEvent") -- S->C (on): the player is caught by a black hole / tornado / UFO: flying stops
Remote.AbuseGrab.Name = "AbuseGrab"
Remote.AbuseGrab.Parent = ReplicatedStorage
Remote.AbusePerkToggle = Instance.new("RemoteEvent") -- C->S: turn the giant power-up off / on
Remote.AbusePerkToggle.Name = "AbusePerkToggle"
Remote.AbusePerkToggle.Parent = ReplicatedStorage
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
		label.Font = Enum.Font.SourceSansBold
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
	if not enabled then
		target:SetAttribute("Flying", nil)
	end
	Remote.AdminSetFlying:FireClient(target, enabled)
	return true
end
Remote.AbuseFlyState.OnServerEvent:Connect(function(plr: Player, on: any)
	if on == true and flyingUserIds[plr.UserId] then
		plr:SetAttribute("Flying", true)
	else
		if plr:GetAttribute("Flying") then
			plr:SetAttribute("FlyOffAt", os.clock())
		end
		plr:SetAttribute("Flying", nil)
	end
end)


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
			celebrate(target, "Gift pass!", "Congrats! An admin gave you the " .. pass.Name .. " game pass as a gift.", pass.Icon)
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
		task.spawn(ServerList.Send, admin, 1)
		sendFeedback(admin, "Loading every server...", false)
		return
	end

	-- :badges [player] - checks every Roblox badge for that player against Roblox itself (earned? really owned? is the
	-- badge on?) and gives any they earned but do not have, with the reason when it can't.
	if commandName == "badges" then
		local target = requireTarget(":badges [player]")
		if not target then return end
		task.spawn(function()
			local module = GameServices:FindFirstChild("BadgeAwards")
			local okLoad, BadgeAwards = false, nil
			if module and module:IsA("ModuleScript") then
				okLoad, BadgeAwards = pcall(require, module)
			end
			if not okLoad or type(BadgeAwards) ~= "table" or type(BadgeAwards.Audit) ~= "function" then
				sendFeedback(admin, "BadgeAwards isn't installed", true)
				return
			end
			local built, rows = pcall(BadgeAwards.Audit, target)
			if not built then
				sendFeedback(admin, "The badge check failed: " .. tostring(rows), true)
				return
			end
			Remote.AdminReport:FireClient(admin, "Badges - " .. target.Name, rows, 0, 0, 0)
		end)
		sendFeedback(admin, "Checking " .. target.Name .. "'s badges with Roblox...", false)
		logCommand(admin, "badges", target.Name, nil, admin.Name .. " checked " .. target.Name .. "'s badges")
		return
	end

	-- :analytics [report] [days] - where players get stuck and leave (Analytics.luau; see ANALYTICS.md).
	if commandName == "analytics" then
		local index, days = extraText:match("^%s*(%d*)%s*(%d*)")
		task.spawn(AnalyticsReport.Send, admin, tonumber(index) or 1, tonumber(days))
		sendFeedback(admin, "Loading the analytics report...", false)
		logCommand(admin, "analytics", nil, extraText, admin.Name .. " opened the analytics report")
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

-- A private lobby (see :privatelobby): the first player in a server who arrives with PrivateOwner set to
-- their own id owns it; nobody else may stay.
local privateOwnerId: number? = nil
if game.PrivateServerOwnerId ~= 0 then
	-- A Roblox private (VIP) server is locked to its owner as well.
	privateOwnerId = game.PrivateServerOwnerId
	ReplicatedStorage:SetAttribute("PrivateLobby", true)
end
local function guardPrivate(player)
	local ok, data = pcall(function()
		return player:GetJoinData()
	end)
	local td = ok and type(data) == "table" and data.TeleportData or nil
	if privateOwnerId == nil and type(td) == "table" and td.PrivateOwner == player.UserId and game.PrivateServerId ~= "" then
		privateOwnerId = player.UserId
		ReplicatedStorage:SetAttribute("PrivateLobby", true)
		task.delay(4, function()
			if player.Parent then
				sendFeedback(player, "Private lobby: only you can join. Open the Studio tab for the Local Admin Abuse test.", false)
			end
		end)
	end
	if privateOwnerId ~= nil and player.UserId ~= privateOwnerId then
		task.defer(function()
			player:Kick("This lobby is private.")
		end)
	end
end
Players.PlayerAdded:Connect(guardPrivate)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(guardPrivate, player)
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

-- :analytics - the report pages (Analytics.BuildReport) shown in the same list window as the servers.
Remote.AdminReport = Instance.new("RemoteEvent")
Remote.AdminReport.Name = "AdminReport"
Remote.AdminReport.Parent = ReplicatedStorage

function AnalyticsReport.Send(admin, index: number?, days: number?)
	local module = GameServices:FindFirstChild("Analytics")
	local ok, Analytics = false, nil
	if module and module:IsA("ModuleScript") then
		ok, Analytics = pcall(require, module)
	end
	if not ok or type(Analytics) ~= "table" or type(Analytics.BuildReport) ~= "function" then
		sendFeedback(admin, "Analytics isn't installed (Server > Services > Analytics is missing)", true)
		return
	end
	local built, title, rows, shown, count = pcall(Analytics.BuildReport, index, days)
	if not built then
		sendFeedback(admin, "The analytics report failed: " .. tostring(title), true)
		return
	end
	Remote.AdminReport:FireClient(admin, title, rows, shown, count, days or Config.Analytics.ReportDays)
end

ServerList.TTL = 90
ServerList.Map = nil
pcall(function()
	ServerList.Map = game:GetService("MemoryStoreService"):GetSortedMap("RinseCycle_ServerList")
end)

ServerList.Started = os.time() -- (when this server began: servers are numbered oldest first, Lobby 1, Lobby 2...)

function ServerList.Snapshot()
	local list = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		table.insert(list, { UserId = plr.UserId, Name = plr.Name, Display = plr.DisplayName, Hidden = plr:GetAttribute("AdminInvis") == true })
	end
	return { Players = list, Run = RunServers.IsRunServer, Level = RunServers.GetLevel and RunServers.GetLevel() or nil, Started = ServerList.Started, Updated = os.time() }
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
					table.insert(servers, { JobId = item.key, Run = item.value.Run == true, Level = tonumber(item.value.Level), Started = tonumber(item.value.Started) or 0, Players = item.value.Players or {} })
				end
			end
		end)
	end
	local here = ServerList.Snapshot()
	table.insert(servers, 1, { JobId = game.JobId, Run = here.Run, Level = here.Level, Started = here.Started, Players = here.Players, Here = true })
	return servers
end

-- The filters the server list cycles through (the arrows in the panel).
ServerList.Filters = { "all", "lobby", "game", "level1", "level2", "level3" }
local function levelLabel(level: number): string
	local def = Config.Levels[level]
	return string.format("Level %d - %s (Chapter %d)", level, if def then tostring(def.Name) else "?", level)
end
local function filterLabel(filter: string): string
	if filter == "lobby" then
		return "Lobby servers"
	elseif filter == "game" then
		return "Game servers (all levels)"
	elseif string.sub(filter, 1, 5) == "level" then
		return levelLabel(tonumber(string.sub(filter, 6)) or 1) .. " games"
	end
	return "All servers"
end
local function upText(seconds: number): string
	seconds = math.max(0, seconds)
	if seconds >= 3600 then
		return string.format("%dh %02dm", seconds // 3600, (seconds % 3600) // 60)
	end
	return string.format("%d min", seconds // 60)
end

function ServerList.Send(admin, filterIndex: number?)
	local index = ((math.floor(tonumber(filterIndex) or 1) - 1) % #ServerList.Filters) + 1
	local filter = ServerList.Filters[index]
	local servers = ServerList.Read()
	-- numbered oldest first: Lobby 1, Lobby 2...; game servers numbered within their level
	table.sort(servers, function(a, b)
		if a.Started ~= b.Started then
			return a.Started < b.Started
		end
		return a.JobId < b.JobId
	end)
	local lobbyNumber, gameNumber = 0, { 0, 0, 0, 0, 0, 0 }
	local lobbies, games, people = 0, 0, 0
	local entries = {}
	for _, server in ipairs(servers) do
		local names, follow, hidden = {}, nil, 0
		for _, p in ipairs(server.Players) do
			if p.Hidden then
				hidden += 1
			elseif p.UserId ~= admin.UserId then
				table.insert(names, tostring(p.Name))
				follow = follow or p.UserId
			end
		end
		local count = #server.Players
		if count == 0 then
			continue
		end
		people += count
		local category, label
		if server.Run then
			games += 1
			local level = server.Level or 0
			gameNumber[level + 1] = (gameNumber[level + 1] or 0) + 1
			category = if level >= 1 then "level" .. level else "game"
			label = (if level >= 1 then levelLabel(level) else "Game server") .. " - game #" .. gameNumber[level + 1]
		else
			lobbies += 1
			lobbyNumber += 1
			category = "lobby"
			label = "Lobby " .. lobbyNumber
		end
		table.insert(entries, { Category = category, Server = server, Names = names, Follow = follow, Count = count, Label = label })
	end
	local rows = {}
	for _, entry in ipairs(entries) do
		local show = filter == "all" or filter == entry.Category or (filter == "game" and string.sub(entry.Category, 1, 5) == "level") or (filter == "game" and entry.Category == "game")
		if show then
			local names = entry.Names
			local shown = if #names == 0 then "(only you / hidden staff)" else table.concat(names, ", ", 1, math.min(#names, 8)) .. (if #names > 8 then ", +" .. (#names - 8) .. " more" else "")
			table.insert(rows, {
				Id = entry.Follow,
				JobId = entry.Server.JobId,
				Line1 = string.format("%s%s  -  %d player%s  -  up %s", entry.Label, if entry.Server.Here then " (you are here)" else "", entry.Count, if entry.Count == 1 then "" else "s", upText(os.time() - (entry.Server.Started or os.time()))),
				Line2 = shown,
			})
		end
	end
	local busiest, busiestCount = nil, 0
	for _, entry in ipairs(entries) do
		if not entry.Server.Here and entry.Category == "lobby" and entry.Count > busiestCount then
			busiest, busiestCount = entry.Server.JobId, entry.Count
		end
	end
	local title = string.format("%s (%d)   |   %d lobbies, %d game servers, %d players", filterLabel(filter), #rows, lobbies, games, people)
	Remote.AdminServerList:FireClient(admin, title, rows, busiest, index, #ServerList.Filters)
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
	if action == "List" then
		-- (the arrows on the server list: the next / previous filter)
		if tierHasCommand(tier, "serverlist") then
			task.spawn(ServerList.Send, admin, tonumber(jobId))
		end
		return
	end
	if action == "Report" then
		-- (the arrows on an analytics report: "<report number>:<days>")
		if tierHasCommand(tier, "analytics") then
			local index, days = string.match(jobId, "^(%d+):(%d+)$")
			task.spawn(AnalyticsReport.Send, admin, tonumber(index) or 1, tonumber(days))
		end
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
Remote.PassWinners = Instance.new("RemoteEvent") -- S->C ("Drop", { { Id, Name, Pass }... }): the pass drop's "Congrats" card + winners list
Remote.PassWinners.Name = "PassWinners"
Remote.PassWinners.Parent = ReplicatedStorage
do
	local TextService = game:GetService("TextService")
	local Format = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Format"))
	local TOPIC = "RinseCycle_GlobalEvent"
	local handlers = {}
	local Commands = GlobalEvents.Commands

	local localShow = false
	-- While a LOCAL Admin Abuse test runs, everything the show publishes stays in this server (no other
	-- server hears about it, and its votes and prizes are not shared).
	local LOCAL_KINDS = { AbuseSchedule = true, AbuseEffect = true, AbuseSay = true, Banner = true, GiveAll = true, PetDrop = true, PassDrop = true, PollStart = true, PollTally = true, PollResult = true }
	local function publish(data)
		if localShow and LOCAL_KINDS[data.Kind] then
			local handler = handlers[data.Kind]
			if handler then
				task.spawn(handler, data)
			end
			return false
		end
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
		if ReplicatedStorage:GetAttribute("AbuseLive") == true then
			return -- (no announcement banners during the Admin Abuse show: the speech box and the pill say it all)
		end
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
		Remote.GlobalPoll:FireClient(plr, "Start", poll.Id, poll.Question, poll.Options, poll.EndsAt, poll.Hint)
	end
	handlers.PollStart = function(d)
		if type(d.Id) ~= "string" or type(d.Options) ~= "table" or polls[d.Id] then
			return
		end
		local poll = { Id = d.Id, Question = tostring(d.Question), Options = d.Options, EndsAt = tonumber(d.EndsAt) or Config.Now(), Origin = d.Origin, Votes = {}, Silent = d.Silent == true, Hint = if type(d.Hint) == "string" then string.sub(d.Hint, 1, 60) else nil }
		polls[d.Id] = poll
		for _, plr in ipairs(Players:GetPlayers()) do
			sendPoll(plr, poll)
		end
		task.delay(math.max(0, poll.EndsAt - Config.Now()) + 0.5, function()
			local counts = {}
			for i = 1, #poll.Options do
				counts[i] = 0
			end
			for _, index in pairs(poll.Votes) do
				counts[index] += 1
			end
			polls[poll.Id] = nil
			for _, plr in ipairs(Players:GetPlayers()) do
				-- A show poll's card goes away the second it ends (no results card).
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
			Remote.GlobalPoll:FireClient(plr, "Result", d.Id, tostring(d.Question), d.Options, d.Counts, tonumber(d.Auto))
		end
	end
	Players.PlayerAdded:Connect(function(plr)
		for _, poll in pairs(polls) do
			if poll.EndsAt > Config.Now() then
				sendPoll(plr, poll)
			end
		end
	end)
	Remote.GlobalPollVote.OnServerEvent:Connect(function(plr, id, index)
		local poll = type(id) == "string" and polls[id]
		if poll and type(index) == "number" and index == math.floor(index) and index >= 1 and index <= #poll.Options and Config.Now() <= poll.EndsAt then
			poll.Votes[plr.UserId] = index -- you can change your mind until it ends
			if ReplicatedStorage:GetAttribute("AbuseLive") == true then
				DataService.Track(plr, "show.vote")
			end
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
				given = DataService.AddBubbles(plr, amount, "AdminGive")
			elseif currency == "Gems" then
				given = DataService.AddGems(plr, amount, "AdminGive")
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
	-- server) win a game pass
	-- (or 100 Gems instead if they already own it).
	-- A drop travels as several small messages (MessagingService allows about 1 KB each: 25 winners with their names do not fit
	-- in one). Each server grants its own players' passes as the parts arrive and shows the "Congrats" card once all of them
	-- have (or after a few seconds, with whoever has).
	local PASS_DROP_CHUNK = 8
	local passDrops = {} -- [dropId] = { Board = {...}, Got = 0, Shown = false }
	local function showPassDrop(id)
		local drop = passDrops[id]
		if not drop or drop.Shown then
			return
		end
		drop.Shown = true
		-- Everyone gets the card (a banner with a View button), except during the Admin Abuse show, whose speech box and pill say it.
		if ReplicatedStorage:GetAttribute("AbuseLive") ~= true and #drop.Board > 0 then
			for _, plr in ipairs(Players:GetPlayers()) do
				Remote.PassWinners:FireClient(plr, "Drop", drop.Board)
			end
		end
		task.delay(30, function()
			passDrops[id] = nil
		end)
	end
	handlers.PassDrop = function(d)
		if type(d.W) ~= "table" then
			return
		end
		local id = if type(d.Id) == "string" then d.Id else tostring(os.clock())
		local drop = passDrops[id]
		if not drop then
			drop = { Board = {}, Got = 0, Shown = false }
			passDrops[id] = drop
			task.delay(6, showPassDrop, id)
		end
		drop.Got += 1
		-- (what the card lists: every winner of the drop, from every server, with the pass they won)
		for _, w in ipairs(d.W) do
			local pass = Config.GetPass(tostring(w.p))
			local userId = tonumber(w.u) or 0
			local plr = Players:GetPlayerByUserId(userId)
			table.insert(drop.Board, {
				Id = userId,
				Name = string.sub(tostring(w.n or (plr and plr.Name) or "A player"), 1, 24),
				Pass = if pass then pass.Name else tostring(w.p),
			})
			if plr then
				local passes = DataService.GetPasses and DataService.GetPasses(plr) or {}
				local function has(key)
					return passes[key] == true or plr:GetAttribute(gamepassAttribute(key)) == true
				end
				if pass and has(pass.Key) then
					pass = nil -- they already own it: Gems instead (below)
				end
				if pass then
					setGamepassGrant(plr, pass, true, false)
					celebrate(plr, "Pass drop winner!", "Congrats! You won the " .. pass.Name .. " game pass from the pass drop.", pass.Icon)
				else
					DataService.AddGems(plr, 100, "PassDrop")
					celebrate(plr, "Pass drop winner!", "Congrats! You won a game pass from the pass drop, but you already own it, so here are 100 Gems instead.", "@Gift")
				end
			end
		end
		if drop.Got >= math.max(1, tonumber(d.Parts) or 1) then
			showPassDrop(id)
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
			table.insert(winners, { u = pick.UserId, p = key, n = pick.Name })
			table.insert(names, pick.Name)
		end
		local shown = table.concat(names, ", ", 1, math.min(#names, 3)) .. (if #names > 3 then string.format(" and %d more", #names - 3) else "")
		local dropId = game.JobId .. ":" .. tostring(os.clock())
		local parts = math.ceil(#winners / PASS_DROP_CHUNK)
		local ok = true
		for i = 1, parts do
			local slice = { table.unpack(winners, (i - 1) * PASS_DROP_CHUNK + 1, math.min(#winners, i * PASS_DROP_CHUNK)) }
			if not publish({ Kind = "PassDrop", Id = dropId, Part = i, Parts = parts, W = slice }) then
				ok = false
			end
		end
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
		-- (no name typed = a plain countdown timer with no name on it: it no longer says "Admin Abuse")
		local name = string.match(rest or "", "^%s*(.-)%s*$") or ""
		if name ~= "" then
			local okFilter, filtered = pcall(function()
				return TextService:FilterStringAsync(name, admin.UserId):GetNonChatStringForBroadcastAsync()
			end)
			if okFilter and type(filtered) == "string" then
				name = filtered
			end
		end
		name = string.sub(name, 1, 40)
		local data = { Kind = "CountdownSet", Name = name, EndsAt = os.time() + math.floor(seconds), LiveMinutes = LIVE_MINUTES }
		if countdownMap then
			pcall(function()
				countdownMap:SetAsync("current", data, math.min(math.floor(seconds) + LIVE_MINUTES * 60 + 600, 3888000))
			end)
		end
		local ok = publish(data)
		local shownName = if name == "" then "a plain timer" else name
		sendFeedback(admin, string.format("Countdown for %s set (%s)%s", shownName, Format.Time and Format.Time(seconds) or tostring(math.floor(seconds / 60)) .. " min", if ok then " in every server" else " (this server only)"), false)
		logCommand(admin, "globalcountdown", nil, name, string.format("%s started a countdown for %s (%d min)", admin.Name, shownName, math.floor(seconds / 60)))
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
	-- (Everything below lives in its own function, so its locals have their own budget of 200 registers.)
	;(function()
	-- Runs by itself in EVERY server from the event's Starts time (Config.UpcomingEvents, key
	-- AdminAbuse), so no one has to press anything: every server reads the same clock. Banners and the
	-- warning countdown, the lobby giant and the chat lines are per server; the votes and the prizes
	-- are done once for the whole game: a server "claims" a step in a MemoryStore hash map first, so
	-- only one server runs it, and the existing global poll / give / pass drop do the rest.
	-- :abuseshow [minutes] starts the whole thing that many minutes from now, to try it; ":abuseshow
	-- reset" puts the real time back.
	local Show = Config.AbuseShow
	local LobbyBuilder = require(GameServices:WaitForChild("LobbyBuilder"))
	local PartyService = require(GameServices:WaitForChild("PartyService"))
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
	-- The schedule is also an attribute on ReplicatedStorage, so every client's countdown follows it
	-- (including a test start).
	local function publishSchedule()
		local e = abuseEvent()
		if e then
			ReplicatedStorage:SetAttribute("AbuseStarts", e.Starts)
			ReplicatedStorage:SetAttribute("AbuseEnds", e.Ends)
		end
	end
	publishSchedule()
	handlers.AbuseSchedule = function(d)
		local e = abuseEvent()
		if e and tonumber(d.Starts) and tonumber(d.Ends) then
			e.Starts, e.Ends = d.Starts, d.Ends
			publishSchedule()
		end
	end

	local STUB = { Name = Show.OwnerName .. " (event)", UserId = 0 } -- stands in for an admin in the commands
	-- `append`: the text is added to the speech box that is already up (a countdown), not shown as a new line.
	local function say(text: string, append: boolean?)
		for _, plr in ipairs(Players:GetPlayers()) do
			Remote.AbuseSay:FireClient(plr, Show.OwnerName, text, append)
		end
	end
	local claimMap = nil
	pcall(function()
		claimMap = game:GetService("MemoryStoreService"):GetHashMap("RinseCycle_AbuseSteps")
	end)
	-- True on exactly one server per step (and on this one when MemoryStore isn't there: Studio).
	local function claim(step: string): boolean
		if localShow or not claimMap then
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

	-- n random online players (every server, hidden staff left out).
	local function pickWinners(count: number): { number }
		local pool, seen = {}, {}
		for _, server in ipairs(ServerList.Read()) do
			for _, p in ipairs(server.Players or {}) do
				local id = tonumber(p.UserId)
				if id and not p.Hidden and not seen[id] then
					seen[id] = true
					table.insert(pool, id)
				end
			end
		end
		local out = {}
		for _ = 1, math.min(count, #pool) do
			table.insert(out, table.remove(pool, math.random(1, #pool)))
		end
		return out
	end
	handlers.PetDrop = function(d)
		if type(d.W) ~= "table" then
			return
		end
		local def = Config.Pets[Show.Pet]
		for _, id in ipairs(d.W) do
			local plr = Players:GetPlayerByUserId(tonumber(id) or 0)
			if plr and def then
				DataService.Track(plr, "show.prize")
				if PetService.GivePet(plr, Show.Pet) then
					celebrate(plr, "You won a limited pet!", "Admin Abuse: you got the limited " .. def.Name .. "!", "@Gift")
				else
					DataService.AddGems(plr, 150, "ShowPrize")
					celebrate(plr, "You won!", "Your pet bag is full, so here are 150 Gems instead of the " .. def.Name .. "!", "@Gift")
				end
			end
		end
		if type(d.Text) == "string" then
			bannerAll(d.Text)
		end
	end

	local heat = false -- set by the clock once he turns up the heat
	local chosenEffect = "meteors" -- what the chat voted for ("winner" in the Script)
	local playEffect: (string, number?) -> () = function() end -- set once the effects exist
	-- The stage: big events never overlap (a new one waits for the one before it to finish) and each of the four vote
	-- events (black hole, tornado, meteor storm, fireworks) happens ONCE in the whole show: the one the chat voted for
	-- right away, the other three later at the script's "rest" slots.
	local ONCE = { blackhole = true, tornado = true, meteors = true, fireworks = true }
	local STAGE = { blackhole = 12, tornado = 14, meteors = 9, fireworks = 10, ufo = 26, bombs = 12, tablebreak = 8, dishwasher = 14, nuke = 6 } -- seconds each keeps the stage
	local onceDone: { [string]: boolean } = {}
	local stageBusyUntil = 0
	local nukeQuietUntil = 0 -- while the nuke counts down and goes off nothing else happens
	local timeSkip = 0 -- seconds the show has jumped ahead (the pet hunt ended early)
	local showEnded: { [string]: boolean } = {} -- shows (by start time) that have been put away: they do not run again
	-- Jumps the show ahead `seconds` (and drops the script steps in the seconds it skips, so none of them fires late).
	local skipScript: (number) -> () = function() end

	-- Gives the prize (an option from Config.AbuseOption) to everyone / the winners, in every server.
	local function applyOutcome(option: any)
		if option.Kind == "Bubbles" or option.Kind == "Gems" then
			publish({ Kind = "GiveAll", Currency = option.Kind, Amount = option.PerPlayer })
		elseif option.Kind == "Passes" then
			Commands.globalpassdrop(STUB, tostring(option.Count) .. " random")
		elseif option.Kind == "Pet" then
			local winners = pickWinners(option.Count)
			publish({ Kind = "PetDrop", W = winners, Text = string.format("Admin Abuse: %d player%s won the limited %s pet!", #winners, if #winners == 1 then "" else "s", Config.Pets[Show.Pet].Name) })
		elseif option.Kind == "Effect" then
			publish({ Kind = "AbuseEffect", Name = option.Effect, Winner = true })
		end
	end
	-- One round. A poll goes to every server (the existing global poll, "silent": its card closes the
	-- second the vote ends), the counts come back here, and the winner is applied. An announced round
	-- just happens. The winner is the most votes (the first on a tie; nobody voted = the first).
	local function runRound(round: any)
		local n = everyoneOnline()
		local function fill(text: string, option: any): string
			local out = string.gsub(text, "{players}", string.format("%d lucky player%s", option.Count, if option.Count == 1 then "" else "s"))
			out = string.gsub(out, "{n}", tostring(option.Count))
			out = string.gsub(out, "{pet}", Config.Pets[Show.Pet].Name)
			out = string.gsub(out, "{text}", option.Text)
			return out
		end
		if round.Kind == "Announce" then
			local option = Config.AbuseOption(round.Option, n)
			publish({ Kind = "AbuseSay", Text = fill(round.Intro, option) })
			task.delay(8, function()
				applyOutcome(option)
				if round.Done then
					task.delay(5, function()
						publish({ Kind = "AbuseSay", Text = round.Done })
					end)
				end
			end)
			return
		end
		local options, picked = {}, {}
		for _, o in round.Options do
			local option = Config.AbuseOption(o, n)
			table.insert(picked, option)
			table.insert(options, option.Text)
		end
		local id = game.JobId .. ":abuse:" .. tostring(os.clock())
		local counts = {}
		for i = 1, #options do
			counts[i] = 0
		end
		collecting[id] = { Counts = counts, Question = round.Question, Options = options }
		publish({ Kind = "PollStart", Id = id, Silent = true, Hint = "EVERYONE VOTES - MOST VOTES WINS", Question = round.Question, Options = options, EndsAt = Config.Now() + round.Seconds, Origin = game.JobId })
		task.delay(round.Seconds + 3, function()
			local c = collecting[id]
			collecting[id] = nil
			if not c then
				return
			end
			local best, bestVotes = 1, -1
			for i, count in ipairs(c.Counts) do
				if count > bestVotes then
					best, bestVotes = i, count
				end
			end
			local winner = picked[best]
			-- the same vote card turns into the results (percentages, the winner lit up) for everyone, at once
			publish({ Kind = "PollResult", Id = id, Question = round.Question, Options = options, Counts = c.Counts, Auto = 7 })
			publish({ Kind = "AbuseSay", Text = fill(round.Chosen, winner) })
			task.delay(2, applyOutcome, winner)
		end)
	end
	handlers.AbuseSay = function(d)
		if type(d.Text) == "string" then
			say(string.sub(d.Text, 1, 200))
		end
	end
	handlers.AbuseEffect = function(d)
		if type(d.Name) == "string" then
			if d.Winner then
				chosenEffect = d.Name
			end
			playEffect(d.Name)
		end
	end

	----------------------------------------------------------------- the giant and his toys
	-- The giant: the owner's real avatar (hair and clothes from their HumanoidDescription), scaled up,
	-- walking a circle round the lobby room with Roblox's default R15 animations (only the root part is
	-- anchored, so the animations really move his limbs). The root's height is locked to his lowest
	-- foot sole every frame, so he never sinks into or hovers over the floor, and every footfall
	-- booms. Between stops he does what the show's Script says (effects below; all harmless).
	local Debris = game:GetService("Debris")
	local KeyframeSequenceProvider = game:GetService("KeyframeSequenceProvider")
	local giantDebug = false
	local Lighting = game:GetService("Lighting")
	local ROOM_FLOOR = -130 -- LobbyBuilder's room floor
	local ROOF_Y = 330 -- LobbyBuilder's ceiling
	local TABLE_CENTER = Vector3.new(0, ROOM_FLOOR, -18)
	local giant: Model? = nil
	local giantConn: RBXScriptConnection? = nil
	local giantHead: BasePart? = nil
	-- The room's real lighting, taken before the show changes any of it (the rainbow and the heat both do), so
	-- the end can put back exactly what was there.
	local baseLighting: { [string]: any }? = nil
	local fadingOut = false -- the finale: everything is fading back to normal (see the "restore" step)
	local function captureLighting()
		if not baseLighting then
			baseLighting = { ClockTime = Lighting.ClockTime, Brightness = Lighting.Brightness, Ambient = Lighting.Ambient, OutdoorAmbient = Lighting.OutdoorAmbient, ColorShift_Top = Lighting.ColorShift_Top, ColorShift_Bottom = Lighting.ColorShift_Bottom, ExposureCompensation = Lighting.ExposureCompensation }
		end
	end
	local function restoreLighting(seconds: number?)
		if baseLighting then
			local goal = baseLighting
			baseLighting = nil
			TweenService:Create(Lighting, TweenInfo.new(seconds or 4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), goal):Play()
		end
	end
	local eyesFor: number? = nil -- how long the next eye-laser burst lasts (set just before it starts)
	local stopChase: (() -> ())? = nil -- ends the pet hunt (and removes any pets still running about)
	local giantLeave: (() -> ())? = nil
	local giantSit: (() -> ())? = nil
	local giantGesture: ((string?) -> ())? = nil -- arm pose for the dishwasher charge
	local giantStand: (() -> ())? = nil
	local giantChairShow: (() -> ())? = nil
	local parkRequested = false -- the next time he passes the south side he stops there (to say goodbye and leave)
	local chairShowBusy = false
	local punchLaunch: Vector3? = nil -- set by the punch: the next table hole flings what is in it this way
	local leaving = false -- set once he starts the exit: nothing respawns him afterwards
	local giantRescale: ((number, number) -> ())? = nil
	local boom: (number, Vector3) -> () = function() end
	local function removeGiant()
		if giantConn then
			giantConn:Disconnect()
			giantConn = nil
		end
		if giant then
			giant:Destroy()
			giant = nil
		end
		for _, c in workspace:GetChildren() do
			if c.Name == "AbuseGiant" then
				c:Destroy()
			end
		end
		giantHead, giantLeave, giantRescale = nil, nil, nil
		giantSit, giantStand, giantChairShow, punchLaunch, giantGesture = nil, nil, nil, nil, nil
		chairShowBusy = false
		parkRequested = false
	end
	local function ringAt(pos: Vector3, size: number, seconds: number, color: Color3)
		local ring = Instance.new("Part")
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(1, 10, 10)
		ring.CFrame = CFrame.new(pos.X, pos.Y + 1, pos.Z) * CFrame.Angles(0, 0, math.pi / 2)
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanTouch = false
		ring.CanQuery = false
		ring.CastShadow = false
		ring.Material = Enum.Material.Neon
		ring.Color = color
		ring.Transparency = 0.2
		ring.Parent = workspace
		TweenService:Create(ring, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(1, size, size), Transparency = 1 }):Play()
		Debris:AddItem(ring, seconds + 0.2)
	end
	local function dustAt(pos: Vector3)
		local anchor = Instance.new("Part")
		anchor.Transparency = 1
		anchor.Anchored = true
		anchor.CanCollide = false
		anchor.CanTouch = false
		anchor.CanQuery = false
		anchor.Size = Vector3.new(4, 1, 4)
		anchor.Position = pos + Vector3.new(0, 4, 0)
		local dust = Instance.new("ParticleEmitter")
		dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
		dust.Color = ColorSequence.new(Color3.fromRGB(200, 190, 175))
		dust.Lifetime = NumberRange.new(1.2, 2)
		dust.Speed = NumberRange.new(40, 90)
		dust.SpreadAngle = Vector2.new(180, 20)
		dust.Size = NumberSequence.new(25, 70)
		dust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
		dust.Rate = 0
		dust.EmissionDirection = Enum.NormalId.Top
		dust.Parent = anchor
		anchor.Parent = workspace
		dust:Emit(28)
		Debris:AddItem(anchor, 3)
	end
	boom = function(strength: number, pos: Vector3)
		ringAt(pos, 120 + 160 * strength, 0.8, if heat then Color3.fromRGB(255, 90, 60) else Color3.fromRGB(255, 205, 110))
		dustAt(pos)
		Remote.AbuseBoom:FireAllClients(strength, pos)
	end
	local function plazaSpot(): Vector3
		return Vector3.new(math.random(-80, 80), 0.2, math.random(-90, 55))
	end
	-- Players caught by a force effect (black hole, tornado) are moved by a LinearVelocity on their root part (the
	-- server updates its speed every frame, the player's own physics does the rest, so it stays smooth) and tumble
	-- (PlatformStand) while held. Nobody who is flying (their own mover would fight it) is caught. Never any damage.
	local function catchPlayer(plr: Player): any?
		local ch = plr.Character
		local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = ch and ch:FindFirstChildOfClass("Humanoid")
		if not root or not hum or hum.Health <= 0 or plr:GetAttribute("AdminInvis") == true then
			return nil
		end
		-- someone who is flying is caught too: their flight is switched off (they can press F again afterwards)
		Remote.AbuseGrab:FireClient(plr, true)
		plr:SetAttribute("AbuseGrabbed", true) -- (the obby must not mistake the mover for the player flying)
		local att = Instance.new("Attachment")
		att.Parent = root
		local mover = Instance.new("LinearVelocity")
		mover.Attachment0 = att
		mover.RelativeTo = Enum.ActuatorRelativeTo.World
		mover.MaxForce = 1e7
		mover.VectorVelocity = Vector3.zero
		mover.Parent = root
		hum.PlatformStand = true
		return { Plr = plr, Root = root, Hum = hum, Att = att, Mover = mover, A = math.random() * math.pi * 2, H = 4 }
	end
	local function releasePlayer(g: any, velocity: Vector3?)
		pcall(function()
			Remote.AbuseGrab:FireClient(g.Plr, false)
			g.Plr:SetAttribute("AbuseGrabbed", nil)
			g.Mover:Destroy()
			g.Att:Destroy()
			if velocity and g.Root.Parent then
				g.Root.AssemblyLinearVelocity = velocity
			end
			if g.Hum.Parent then
				g.Hum.PlatformStand = false
				g.Hum:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
		end)
	end
	-- Where the nearest living player is (flat), from a point: the tornado and the UFO drift after somebody.
	local function nearestPlayerXZ(x: number, z: number): (number, number)
		local bestD, bx, bz = math.huge, x, z
		for _, plr in Players:GetPlayers() do
			local ch = plr.Character
			local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			if root and hum and hum.Health > 0 and root.Position.Y > ROOM_FLOOR + 20 and root.Position.Y < 160 and plr:GetAttribute("AdminInvis") ~= true then
				local d = (root.Position.X - x) ^ 2 + (root.Position.Z - z) ^ 2
				if d < bestD then
					bestD, bx, bz = d, root.Position.X, root.Position.Z
				end
			end
		end
		return bx, bz
	end
	-- A shove for everyone near a blast: up and away (harmless: the rescue puts anyone who ends up off the table back).
	local function shoveNear(pos: Vector3, radius: number, up: number, out: number)
		for _, plr in Players:GetPlayers() do
			local ch = plr.Character
			local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
			local hum = ch and ch:FindFirstChildOfClass("Humanoid")
			if root and hum and not flyingUserIds[plr.UserId] then
				local off = Vector3.new(root.Position.X - pos.X, 0, root.Position.Z - pos.Z)
				if off.Magnitude < radius and root.Position.Y < pos.Y + 60 and root.Position.Y > ROOM_FLOOR + 20 then
					local dir = if off.Magnitude > 0.5 then off.Unit else Vector3.new(0, 0, 1)
					pcall(function()
						hum:ChangeState(Enum.HumanoidStateType.Freefall)
						root.AssemblyLinearVelocity = dir * out + Vector3.new(0, up, 0)
					end)
				end
			end
		end
	end
	-- A burst of light (no Explosion object at all: those can hurt Humanoids, and this show never should).
	local function harmlessBlast(pos: Vector3, radius: number)
		local flash = Instance.new("Part")
		flash.Shape = Enum.PartType.Ball
		flash.Anchored = true
		flash.CanCollide = false
		flash.CanTouch = false
		flash.CanQuery = false
		flash.CastShadow = false
		flash.Material = Enum.Material.Neon
		flash.Color = Color3.fromRGB(255, 170, 80)
		flash.Size = Vector3.new(2, 2, 2)
		flash.Position = pos
		flash.Parent = workspace
		TweenService:Create(flash, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(radius * 2.2, radius * 2.2, radius * 2.2), Transparency = 1 }):Play()
		Debris:AddItem(flash, 0.6)
	end
	-- Every glowing / temporary part of the show is remembered, so the end of the show can fade the lot away.
	local fxParts: { Instance } = {}
	local function track(inst: Instance)
		if #fxParts > 600 then
			local keep = {}
			for _, p in fxParts do
				if p.Parent then
					table.insert(keep, p)
				end
			end
			fxParts = keep
		end
		table.insert(fxParts, inst)
	end
	local function clearFx()
		local list = fxParts
		fxParts = {}
		for _, p in list do
			if p.Parent then
				if p:IsA("BasePart") then
					TweenService:Create(p, TweenInfo.new(1.2), { Transparency = 1 }):Play()
				end
				for _, d in p:GetDescendants() do
					if d:IsA("Light") then
						d.Enabled = false
					elseif d:IsA("ParticleEmitter") then
						d.Enabled = false
					end
				end
				task.delay(1.3, function()
					p:Destroy()
				end)
			end
		end
	end
	local function neonPart(size: Vector3, color: Color3, shape: Enum.PartType?): Part
		local part = Instance.new("Part")
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = color
		part.Size = size
		if shape then
			part.Shape = shape
		end
		track(part)
		return part
	end
	local function upright(part: BasePart, pos: Vector3)
		part.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.pi / 2)
	end
	local PALETTE = {
		Color3.fromRGB(255, 90, 90),
		Color3.fromRGB(255, 190, 60),
		Color3.fromRGB(110, 255, 150),
		Color3.fromRGB(90, 190, 255),
		Color3.fromRGB(200, 120, 255),
		Color3.fromRGB(255, 120, 200),
	}
	-- Floating admin command above his head (typed out, then it floats up and fades).
	local FAKE_COMMANDS = { ":give all everything", ":global speed 999", ":kill dishes", ":fly all", ":globalgive * 999999", ":smite table", ":size me 99", ":unban fun", ":setadminrank me 99", ":clean all", ":spawn meteor", ":gravity 0", ":rain gems", ":time 0" }
	local commandIndex = 0
	local function commandText(text: string?)
		local head = giantHead
		if not head then
			return
		end
		commandIndex += 1
		local tag = Instance.new("BillboardGui")
		tag.Size = UDim2.fromOffset(520, 60)
		tag.StudsOffsetWorldSpace = Vector3.new(0, head.Size.Y * 2.4, 0)
		tag.AlwaysOnTop = true
		tag.MaxDistance = 6000
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.Code
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 80, 70)
		label.TextStrokeTransparency = 0
		label.Text = text or FAKE_COMMANDS[(commandIndex - 1) % #FAKE_COMMANDS + 1]
		label.Parent = tag
		tag.Parent = head
		TweenService:Create(tag, TweenInfo.new(2.4), { StudsOffsetWorldSpace = Vector3.new(0, head.Size.Y * 4, 0) }):Play()
		TweenService:Create(label, TweenInfo.new(2.4), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
		Debris:AddItem(tag, 2.6)
	end

	-- The effects. Each is one thing he does to the plaza; the clock's Script says which and when.
	local FX = (function()
		local fx: { [string]: () -> () } = {}
		local function headPoint(): Vector3
			return if giantHead then giantHead.Position else Vector3.new(0, 140, 280)
		end
		fx.beam = function()
			local from = headPoint()
			for i = 1, if heat then 3 else 1 do
				task.delay((i - 1) * 0.5, function()
					local target = plazaSpot()
					local len = (target - from).Magnitude
					local beam = neonPart(Vector3.new(8, 8, len), Color3.fromRGB(255, 120, 60))
					beam.CFrame = CFrame.lookAt(from, target) * CFrame.new(0, 0, -len / 2)
					beam.Parent = workspace
					TweenService:Create(beam, TweenInfo.new(1.4), { Transparency = 1, Size = Vector3.new(2, 2, len) }):Play()
					Debris:AddItem(beam, 1.6)
					harmlessBlast(target, 14)
					boom(2, target)
				end)
			end
		end
		local dentCount = 199 -- hole indexes 200 and up are the meteors' small dents
		fx.meteors = function()
			-- A real meteor shower: lots of big rocks with fire tails. Every impact blasts away whoever is near it
			-- (a wide radius, hard), every third one leaves a small dent in the table, every fourth a patch of fire.
			local n = if heat then 44 else 30
			for i = 1, n do
				task.delay(i * 0.14, function()
					local target = plazaSpot()
					local rock = neonPart(Vector3.new(22, 22, 22), Color3.fromRGB(255, 140, 50), Enum.PartType.Ball)
					rock.Position = target + Vector3.new(math.random(-180, 180), 300, math.random(-180, 180))
					rock.Parent = workspace
					local tail = Instance.new("ParticleEmitter")
					tail.Texture = "rbxasset://textures/particles/fire_main.dds"
					tail.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 70, 20))
					tail.Lifetime = NumberRange.new(0.5, 0.9)
					tail.Speed = NumberRange.new(0, 6)
					tail.Rate = 90
					tail.Size = NumberSequence.new(20, 0)
					tail.LightEmission = 1
					tail.Parent = rock
					local fall = TweenService:Create(rock, TweenInfo.new(0.75, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = target + Vector3.new(0, 10, 0) })
					fall.Completed:Connect(function()
						rock:Destroy()
						harmlessBlast(target, 20)
						boom(2.2, target)
						shoveNear(target, 46, 85, 120)
						if i % 4 == 0 and not LobbyBuilder.IsHoleAt(target.X, target.Z, 10) then
							dentCount += 1
							LobbyBuilder.OpenCrater(dentCount, target.X, target.Z, 5.5) -- (small: the storm should not eat the table)
						end
						if i % 4 == 0 then
							local fire = neonPart(Vector3.new(14, 1, 14), Color3.fromRGB(255, 120, 40), Enum.PartType.Cylinder)
							fire.Transparency = 0.5
							fire.CFrame = CFrame.new(target.X, 0.4, target.Z) * CFrame.Angles(0, 0, math.pi / 2)
							fire.Parent = workspace
							local flames = Instance.new("ParticleEmitter")
							flames.Texture = "rbxasset://textures/particles/fire_main.dds"
							flames.Color = ColorSequence.new(Color3.fromRGB(255, 200, 80), Color3.fromRGB(255, 60, 20))
							flames.Lifetime = NumberRange.new(0.8, 1.4)
							flames.Speed = NumberRange.new(6, 14)
							flames.EmissionDirection = Enum.NormalId.Top
							flames.Rate = 24
							flames.Size = NumberSequence.new(9, 2)
							flames.LightEmission = 1
							flames.Parent = fire
							task.delay(6, function()
								flames.Enabled = false
								TweenService:Create(fire, TweenInfo.new(1.5), { Transparency = 1 }):Play()
								Debris:AddItem(fire, 1.7)
							end)
						end
					end)
					fall:Play()
				end)
			end
		end
		-- "right. the table. lets see how much it can take": a quick barrage of big fiery rocks over the whole table (a third of them
		-- round the spot where the hole opens a moment later).
		fx.tablebreak = function()
			local hole = Show.Holes[2] or { 86, 56, 22 }
			for i = 1, 18 do
				task.delay(i * 0.14, function()
					-- (two in three land anywhere on the table, the rest round the spot where the hole opens)
					local target = if i % 3 == 0
						then Vector3.new(math.clamp(hole[1] + math.random(-34, 26), -88, 88), 0.2, math.clamp(hole[2] + math.random(-36, 26), -92, 58))
						else plazaSpot()
					local rock = neonPart(Vector3.new(26, 26, 26), Color3.fromRGB(255, 130, 45), Enum.PartType.Ball)
					rock.Position = target + Vector3.new(math.random(-120, 120), 280, math.random(-120, 120))
					rock.Parent = workspace
					local tail = Instance.new("ParticleEmitter")
					tail.Texture = "rbxasset://textures/particles/fire_main.dds"
					tail.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 70, 20))
					tail.Lifetime = NumberRange.new(0.5, 0.9)
					tail.Speed = NumberRange.new(0, 6)
					tail.Rate = 90
					tail.Size = NumberSequence.new(24, 0)
					tail.LightEmission = 1
					tail.Parent = rock
					local fall = TweenService:Create(rock, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = target + Vector3.new(0, 12, 0) })
					fall.Completed:Connect(function()
						rock:Destroy()
						harmlessBlast(target, 24)
						boom(2.6, target)
						shoveNear(target, 48, 85, 120)
					end)
					fall:Play()
				end)
			end
		end
		fx.lightning = function()
			for i = 1, if heat then 8 else 4 do
				task.delay(i * 0.28, function()
					local target = plazaSpot()
					local from = target + Vector3.new(math.random(-40, 40), 340, math.random(-40, 40))
					local previous = from
					for step = 1, 5 do
						local nextPoint = from:Lerp(target, step / 5) + (if step < 5 then Vector3.new(math.random(-25, 25), 0, math.random(-25, 25)) else Vector3.zero)
						local len = (nextPoint - previous).Magnitude
						local bolt = neonPart(Vector3.new(3, 3, len), Color3.fromRGB(190, 220, 255))
						bolt.CFrame = CFrame.lookAt(previous, nextPoint) * CFrame.new(0, 0, -len / 2)
						bolt.Parent = workspace
						TweenService:Create(bolt, TweenInfo.new(0.5), { Transparency = 1 }):Play()
						Debris:AddItem(bolt, 0.6)
						previous = nextPoint
					end
					harmlessBlast(target, 10)
					boom(1.4, target)
				end)
			end
		end
		fx.shockwave = function()
			local feet = if giantHead then Vector3.new(giantHead.Position.X, ROOM_FLOOR, giantHead.Position.Z) else TABLE_CENTER
			for i = 0, 2 do
				task.delay(i * 0.25, function()
					ringAt(feet, 1400 + i * 400, 1.6, Color3.fromRGB(255, 80 + i * 50, 60))
				end)
			end
			boom(3, feet)
		end
		fx.barrage = function()
			for i = 1, if heat then 10 else 6 do
				task.delay(i * 0.28, function()
					boom(1.8, plazaSpot())
				end)
			end
		end
		fx.fireworks = function()
			-- Minecraft style: a rocket (red, gold, blue...) streaks up from the table or the obby with a
			-- spark trail, bursts big, then crackles in a few more booms. Everything is particle bursts,
			-- so it stays smooth, and big enough to see from the obby.
			local SHELLS = {
				{ Color3.fromRGB(255, 70, 60), Color3.fromRGB(255, 200, 90) },
				{ Color3.fromRGB(80, 170, 255), Color3.fromRGB(255, 255, 255) },
				{ Color3.fromRGB(90, 255, 140), Color3.fromRGB(255, 255, 160) },
				{ Color3.fromRGB(200, 110, 255), Color3.fromRGB(255, 150, 220) },
				{ Color3.fromRGB(255, 190, 60), Color3.fromRGB(255, 90, 50) },
			}
			local function burst(at: Vector3, colors: { Color3 }, count: number, speed: number, size: number, life: number)
				local anchor = Instance.new("Part")
				anchor.Transparency = 1
				anchor.Anchored = true
				anchor.CanCollide = false
				anchor.CanTouch = false
				anchor.CanQuery = false
				anchor.Size = Vector3.new(1, 1, 1)
				anchor.Position = at
				local e = Instance.new("ParticleEmitter")
				e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
				e.Color = ColorSequence.new(colors[1], colors[2])
				e.Lifetime = NumberRange.new(life * 0.7, life)
				e.Speed = NumberRange.new(speed * 0.55, speed)
				e.SpreadAngle = Vector2.new(180, 180)
				e.Acceleration = Vector3.new(0, -26, 0)
				e.Drag = 1.6
				e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(0.7, size * 0.7), NumberSequenceKeypoint.new(1, 0) })
				e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.8, 0.2), NumberSequenceKeypoint.new(1, 1) })
				e.LightEmission = 1
				e.Rate = 0
				e.Parent = anchor
				anchor.Parent = workspace
				e:Emit(count)
				-- the flash at the middle
				local core = neonPart(Vector3.new(6, 6, 6), Color3.new(1, 1, 1), Enum.PartType.Ball)
				core.Position = at
				core.Parent = workspace
				TweenService:Create(core, TweenInfo.new(0.45), { Size = Vector3.new(size * 9, size * 9, size * 9), Transparency = 1 }):Play()
				Debris:AddItem(core, 0.5)
				Debris:AddItem(anchor, life + 0.6)
			end
			-- Rockets go up from all over the room (the floor right across it, and the table), two or three at a time
			-- at all heights, so the whole room is full of fireworks, not one corner.
			local count = 90
			for i = 1, count do
				task.delay((i - 1) * 0.28, function()
					local onFloor = math.random() < 0.7
					local base = if onFloor then Vector3.new(math.random(-370, 370), ROOM_FLOOR + 2, math.random(-500, 360)) else plazaSpot()
					local shell = SHELLS[(i - 1) % #SHELLS + 1]
					-- the rocket: a bright head with a long spark tail
					local rocket = neonPart(Vector3.new(3, 3, 3), Color3.new(1, 0.9, 0.7), Enum.PartType.Ball)
					rocket.Position = base
					rocket.Parent = workspace
					local trail = Instance.new("ParticleEmitter")
					trail.Texture = "rbxasset://textures/particles/sparkles_main.dds"
					trail.Color = ColorSequence.new(shell[2], shell[1])
					trail.Lifetime = NumberRange.new(0.7, 1.2)
					trail.Speed = NumberRange.new(2, 8)
					trail.SpreadAngle = Vector2.new(25, 25)
					trail.Rate = 140
					trail.Size = NumberSequence.new(4, 0)
					trail.LightEmission = 1
					trail.Parent = rocket
					Remote.AbuseBoom:FireAllClients(0.3, base) -- the launch: shoom
					local ceiling = 300 -- (the room's ceiling is at 330)
					local height = math.random(90, math.max(120, math.floor(ceiling - base.Y)))
					local top = base + Vector3.new(math.random(-40, 40), height, math.random(-40, 40))
					local rise = TweenService:Create(rocket, TweenInfo.new(0.5 + height / 300, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = top })
					rise.Completed:Connect(function()
						rocket:Destroy()
						burst(top, shell, 100, 40 + height * 0.2, 12 + height * 0.01, 2.2)
						Remote.AbuseBoom:FireAllClients(1.1, top) -- boom
						-- boom, boom: it crackles
						for k = 1, 2 do
							task.delay(0.45 + k * 0.28, function()
								local p = top + Vector3.new(math.random(-80, 80), math.random(-60, 30), math.random(-80, 80))
								burst(p, { shell[2], shell[1] }, 30, 60, 8, 1.5)
								Remote.AbuseBoom:FireAllClients(0.6, p)
							end)
						end
					end)
					rise:Play()
				end)
			end
		end
		fx.laser = function()
			local from = headPoint()
			local z = math.random(-60, 20)
			local a = math.random() < 0.5
			task.spawn(function()
				local t0 = os.clock()
				local lastBlast = 0
				local beams = {}
				for i = 1, 2 do
					local b = neonPart(Vector3.new(5, 5, 10), if i == 1 then Color3.fromRGB(255, 70, 90) else Color3.fromRGB(90, 200, 255))
					b.Parent = workspace
					beams[i] = b
				end
				while os.clock() - t0 < 4.5 do
					local f = (os.clock() - t0) / 4.5
					for i, b in beams do
						local x = (if (i == 1) == a then -1 else 1) * (90 - 180 * f)
						local target = Vector3.new(x, 0.5, z + (if i == 1 then -22 else 22))
						local len = (target - from).Magnitude
						b.Size = Vector3.new(5, 5, len)
						b.CFrame = CFrame.lookAt(from, target) * CFrame.new(0, 0, -len / 2)
						if os.clock() - lastBlast > 0.35 then
							lastBlast = os.clock()
							boom(0.9, target)
						end
					end
					RunService.Heartbeat:Wait()
				end
				for _, b in beams do
					b:Destroy()
				end
			end)
		end
		fx.blackhole = function()
			-- It opens above the table: a black core with a thin white ring round it, an accretion disk (a dozen thin
			-- rings from white-hot to violet), streaks of light spiralling in, and two jets. It slowly drags everyone in
			-- (they spin round it, harmlessly), faster and faster, then bursts in a blinding flash and shoots everyone out.
			local center = Vector3.new(math.random(-30, 30), 70, math.random(-50, 10))
			local tilt = CFrame.new(center) * CFrame.Angles(math.rad(-16), 0, math.rad(10)) -- the disk's plane
			local core = neonPart(Vector3.new(2, 2, 2), Color3.fromRGB(2, 0, 6), Enum.PartType.Ball)
			core.Material = Enum.Material.SmoothPlastic
			core.Position = center
			core.Parent = workspace
			TweenService:Create(core, TweenInfo.new(1.4, Enum.EasingStyle.Back), { Size = Vector3.new(36, 36, 36) }):Play()
			local glow = Instance.new("PointLight")
			glow.Color = Color3.fromRGB(190, 120, 255)
			glow.Range = 160
			glow.Brightness = 4
			glow.Parent = core
			-- the thin bright ring right at the edge of the dark
			local photon = neonPart(Vector3.new(0.7, 44, 44), Color3.fromRGB(255, 240, 255), Enum.PartType.Cylinder)
			photon.Transparency = 0.1
			photon.Parent = workspace
			-- the accretion disk: concentric rings, hot white at the middle to violet at the rim
			local ringCount = 12
			local rings = {}
			for i = 1, ringCount do
				local f = (i - 1) / (ringCount - 1)
				local diameter = 52 + f * 150
				local color = if f < 0.35 then Color3.fromRGB(255, 245, 220):Lerp(Color3.fromRGB(255, 170, 70), f / 0.35) elseif f < 0.7 then Color3.fromRGB(255, 170, 70):Lerp(Color3.fromRGB(235, 70, 170), (f - 0.35) / 0.35) else Color3.fromRGB(235, 70, 170):Lerp(Color3.fromRGB(110, 70, 255), (f - 0.7) / 0.3)
				local ring = neonPart(Vector3.new(0.5 + (1 - f) * 0.8, diameter, diameter), color, Enum.PartType.Cylinder)
				ring.Transparency = 0.3 + f * 0.5
				ring.Parent = workspace
				rings[i] = ring
			end
			-- two jets along the axis
			local jets = {}
			for i = 1, 2 do
				local jet = neonPart(Vector3.new(230, 3.5 * i * i, 3.5 * i * i), if i == 1 then Color3.fromRGB(235, 225, 255) else Color3.fromRGB(150, 110, 255), Enum.PartType.Cylinder)
				jet.Transparency = if i == 1 then 0.35 else 0.78
				jet.Parent = workspace
				jets[i] = jet
			end
			-- streaks of light spiralling in
			local streaks = {}
			for i = 1, 26 do
				local dot = neonPart(Vector3.new(3, 3, 3), PALETTE[i % #PALETTE + 1], Enum.PartType.Ball)
				local a0 = Instance.new("Attachment")
				a0.Position = Vector3.new(0, 1.2, 0)
				a0.Parent = dot
				local a1 = Instance.new("Attachment")
				a1.Position = Vector3.new(0, -1.2, 0)
				a1.Parent = dot
				local trail = Instance.new("Trail")
				trail.Attachment0 = a0
				trail.Attachment1 = a1
				trail.Lifetime = 0.7
				trail.LightEmission = 1
				trail.Color = ColorSequence.new(dot.Color, Color3.fromRGB(80, 40, 160))
				trail.Transparency = NumberSequence.new(0.1, 1)
				trail.Parent = dot
				dot.Parent = workspace
				streaks[i] = { Part = dot, A = math.random() * math.pi * 2, R = 40 + math.random() * 80 }
			end
			local function placeSystem(t: number, f: number)
				for i, ring in rings do
					local wobble = math.sin(t * 1.3 + i) * 0.04
					ring.CFrame = tilt * CFrame.Angles(wobble, 0, math.pi / 2 + wobble)
				end
				photon.CFrame = tilt * CFrame.Angles(0, 0, math.pi / 2)
				photon.Size = Vector3.new(0.7, 44 + math.sin(t * 9) * 2, 44 + math.sin(t * 9) * 2)
				for _, jet in jets do
					jet.CFrame = tilt * CFrame.Angles(0, 0, math.pi / 2) -- along the disk's axis
				end
				for _, st in streaks do
					-- inner streaks go round faster, and everything drifts inward (then starts again at the rim)
					st.R -= (10 + 50 * f) * 0.016
					if st.R < 22 then
						st.R = 100 + math.random() * 60
					end
					st.A += (60 / (st.R + 10)) * 0.9 * 0.016 * (1 + f * 1.5)
					st.Part.CFrame = tilt * CFrame.new(math.cos(st.A) * st.R, math.sin(st.A * 2) * 3, math.sin(st.A) * st.R)
				end
				glow.Brightness = 4 + 6 * f
			end
			task.spawn(function()
				local grabs = {}
				for _, plr in Players:GetPlayers() do
					local ch = plr.Character
					local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
					if root and Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z).Magnitude < 150 and root.Position.Y < 200 and root.Position.Y > ROOM_FLOOR + 20 then
						local g = catchPlayer(plr)
						if g then
							table.insert(grabs, g)
						end
					end
				end
				local t0 = os.clock()
				local length = if heat then 9 else 8
				local lastShake = 0
				while os.clock() - t0 < length do
					local t = os.clock() - t0
					local f = t / length
					placeSystem(t, f)
					-- the pull: gentle at first, then stronger; a swirl round the middle
					local pull = 5 + 38 * f * f
					for _, g in grabs do
						if g.Root.Parent and g.Hum.Health > 0 then
							local to = center - g.Root.Position
							local dist = to.Magnitude
							if dist > 6 then
								local swirl = Vector3.new(-to.Z, 0, to.X)
								swirl = if swirl.Magnitude > 0.1 then swirl.Unit * (6 + 22 * f) else Vector3.zero
								g.Mover.VectorVelocity = to.Unit * math.min(pull, dist * 2.5) + swirl
							else
								g.Mover.VectorVelocity = Vector3.new(0, 0, 0) -- (held at the middle until it bursts)
							end
						end
					end
					if t - lastShake > 0.8 then
						lastShake = t
						Remote.AbuseBoom:FireAllClients(0.5 + f, center)
					end
					RunService.Heartbeat:Wait()
				end
				for _, ring in rings do
					ring:Destroy()
				end
				for _, jet in jets do
					jet:Destroy()
				end
				for _, st in streaks do
					st.Part:Destroy()
				end
				photon:Destroy()
				-- the burst: a white flash, a shockwave, and everyone is shot out
				local flash = neonPart(Vector3.new(40, 40, 40), Color3.new(1, 1, 1), Enum.PartType.Ball)
				flash.Position = center
				flash.Parent = workspace
				TweenService:Create(flash, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(900, 900, 900), Transparency = 1 }):Play()
				Debris:AddItem(flash, 1)
				for i = 0, 2 do
					task.delay(i * 0.12, function()
						ringAt(Vector3.new(center.X, 2, center.Z), 500 + i * 450, 1.4, Color3.fromRGB(235, 210, 255))
					end)
				end
				boom(5, center)
				for _, g in grabs do
					if g.Root.Parent then
						local out = Vector3.new(g.Root.Position.X - center.X, 0, g.Root.Position.Z - center.Z)
						local dir = if out.Magnitude > 1 then out.Unit else Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
						releasePlayer(g, dir * 230 + Vector3.new(0, 70, 0))
					else
						releasePlayer(g, nil)
					end
				end
				TweenService:Create(core, TweenInfo.new(0.3), { Size = Vector3.new(2, 2, 2) }):Play()
				task.wait(0.3)
				core:Destroy()
				boom(3, Vector3.new(center.X, 0.2, center.Z))
				harmlessBlast(center, 30)
			end)
		end
		fx.tornado = function()
			-- A big funnel (stacked spinning rings, dust at the foot, flying debris) sweeps across the table. Anyone it
			-- touches is lifted up into it and spun round and round inside, then thrown out the side when it ends.
			local N = 12
			local discs = {}
			for i = 1, N do
				local width = 14 + i * 9
				local disc = neonPart(Vector3.new(5, width, width), Color3.fromRGB(110 + i * 8, 112 + i * 8, 120 + i * 8), Enum.PartType.Cylinder)
				disc.Material = Enum.Material.SmoothPlastic
				disc.Transparency = 0.35 + (i % 2) * 0.12
				disc.Parent = workspace
				discs[i] = disc
			end
			local foot = neonPart(Vector3.new(4, 4, 4), Color3.new(1, 1, 1))
			foot.Transparency = 1
			foot.Parent = workspace
			local dust = Instance.new("ParticleEmitter")
			dust.Texture = "rbxasset://textures/particles/smoke_main.dds"
			dust.Color = ColorSequence.new(Color3.fromRGB(150, 130, 105))
			dust.Lifetime = NumberRange.new(1.2, 2)
			dust.Speed = NumberRange.new(30, 60)
			dust.SpreadAngle = Vector2.new(180, 15)
			dust.Size = NumberSequence.new(14, 36)
			dust.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
			dust.Rate = 50
			dust.EmissionDirection = Enum.NormalId.Top
			dust.Parent = foot
			local chunks = {}
			for i = 1, 26 do
				local size = 2 + (i % 4)
				local chunk = neonPart(Vector3.new(size, size * 0.6, size * 1.4), if i % 3 == 0 then Color3.fromRGB(160, 110, 70) else Color3.fromRGB(120, 120, 130))
				chunk.Material = Enum.Material.SmoothPlastic
				chunk.Parent = workspace
				chunks[i] = chunk
			end
			task.spawn(function()
				local t0 = os.clock()
				local length = if heat then 13 else 11
				local grabs: { any } = {}
				local caught: { [Player]: boolean } = {}
				local last = os.clock()
				local lastBoom = 0
				-- it wanders across the table but keeps swinging toward the nearest player, so it really finds people
				local cx, cz = math.random(-60, 60), math.random(-80, 20)
				while os.clock() - t0 < length do
					local now = os.clock()
					local dt = now - last
					last = now
					local t = now - t0
					local nx, nz = nearestPlayerXZ(cx, cz)
					local toX, toZ = nx - cx, nz - cz
					local dist = math.sqrt(toX * toX + toZ * toZ)
					if dist > 1 then
						local step = math.min(dist, 38 * dt)
						cx += toX / dist * step
						cz += toZ / dist * step
					end
					cx = math.clamp(cx, -92, 92)
					cz = math.clamp(cz, -96, 60)
					foot.CFrame = CFrame.new(cx, 3, cz)
					for i, disc in discs do
						local wob = math.sin(t * 3 + i) * 2.5 * (i / N)
						disc.CFrame = CFrame.new(cx + wob, i * 13 - 4, cz + wob) * CFrame.Angles(0, t * (3 + i * 0.25), math.pi / 2)
					end
					for i, chunk in chunks do
						local h = ((t * (14 + i % 5 * 4) + i * 11) % 150)
						local a = t * (2.4 + (i % 4) * 0.5) + i * 1.7
						local r = 12 + h * 0.4 + (i % 3) * 4
						chunk.CFrame = CFrame.new(cx + math.cos(a) * r, h + 4, cz + math.sin(a) * r) * CFrame.Angles(a, a * 0.7, 0)
					end
					-- catch whoever walks into it (never twice)
					if t < length - 2.5 then
						for _, plr in Players:GetPlayers() do
							local ch = plr.Character
							local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
							if root and not caught[plr] and root.Position.Y > ROOM_FLOOR + 20 and root.Position.Y < 160 and Vector3.new(root.Position.X - cx, 0, root.Position.Z - cz).Magnitude < 48 then
								local g = catchPlayer(plr)
								if g then
									caught[plr] = true
									g.T0 = t
									table.insert(grabs, g)
								end
							end
						end
					end
					-- the caught ones spiral up inside the funnel and spin round it
					for _, g in grabs do
						if g.Root.Parent and g.Hum.Health > 0 then
							local rise = math.min(1, (t - g.T0) / 3.5)
							local h = 6 + rise * 80 + math.sin(t * 1.5 + g.A) * 8 * rise
							g.A += dt * (3.4 + rise * 1.4)
							local r = 6 + h * 0.34
							local target = Vector3.new(cx + math.cos(g.A) * r, h, cz + math.sin(g.A) * r)
							local v = (target - g.Root.Position) * 6
							g.Mover.VectorVelocity = if v.Magnitude > 110 then v.Unit * 110 else v
						end
					end
					if t - lastBoom > 0.5 then
						lastBoom = t
						Remote.AbuseBoom:FireAllClients(0.6, Vector3.new(cx, 0.2, cz))
					end
					RunService.Heartbeat:Wait()
				end
				-- it dies down: whoever is still inside is thrown out of the side
				for _, g in grabs do
					if g.Root.Parent then
						local tangent = Vector3.new(-math.sin(g.A), 0, math.cos(g.A))
						releasePlayer(g, tangent * 75 + Vector3.new(0, 25, 0))
					else
						releasePlayer(g, nil)
					end
				end
				dust.Enabled = false
				for _, part in discs do
					TweenService:Create(part, TweenInfo.new(0.8), { Transparency = 1 }):Play()
					Debris:AddItem(part, 0.9)
				end
				for _, chunk in chunks do
					Debris:AddItem(chunk, 0.1)
				end
				Debris:AddItem(foot, 2.5)
			end)
		end
		fx.ufo = function()
			-- The ship drifts slowly in from the edge of the table and cruises over random places on it (some of them over
			-- players); its beam, on while it is over the table, pulls everyone under it up (slow at first, then faster).
			-- Whoever reaches the top of the ship is sent straight back to the spawn (nobody is hurt). Anyone it did not
			-- finish with is let go when it leaves.
			local ship = Instance.new("Model")
			local body = neonPart(Vector3.new(6, 46, 46), Color3.fromRGB(170, 180, 200), Enum.PartType.Cylinder)
			body.Material = Enum.Material.Metal
			upright(body, Vector3.new(0, 0, 0))
			local dome = neonPart(Vector3.new(22, 22, 22), Color3.fromRGB(120, 255, 200), Enum.PartType.Ball)
			dome.Transparency = 0.3
			local SHIP_Y, BEAM_R = 130, 20
			local beamPart = neonPart(Vector3.new(SHIP_Y + 10, BEAM_R * 2, BEAM_R * 2), Color3.fromRGB(150, 255, 190), Enum.PartType.Cylinder)
			beamPart.Transparency = 1
			body.Parent, dome.Parent, beamPart.Parent = ship, ship, ship
			ship.Parent = workspace
			-- where it goes: a few places over the table, every other one near a player
			local function playerSpot(): Vector3?
				local list = {}
				for _, plr in Players:GetPlayers() do
					local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if root and root.Position.Y > ROOM_FLOOR + 20 and root.Position.Y < 60 and math.abs(root.Position.X) < 92 and root.Position.Z > -98 and root.Position.Z < 60 then
						table.insert(list, root.Position)
					end
				end
				return if #list > 0 then list[math.random(1, #list)] else nil
			end
			local waypoints: { Vector3 } = {}
			for k = 1, 4 do
				local spot = if k % 2 == 0 then playerSpot() else nil
				local x = if spot then spot.X + math.random(-14, 14) else math.random(-80, 80)
				local z = if spot then spot.Z + math.random(-14, 14) else math.random(-85, 50)
				table.insert(waypoints, Vector3.new(math.clamp(x, -88, 88), SHIP_Y, math.clamp(z, -92, 56)))
			end
			local fromEast = math.random() < 0.5
			local start = Vector3.new(if fromEast then 150 else -150, SHIP_Y, math.random(-60, 20))
			local finish = Vector3.new(if fromEast then -150 else 150, SHIP_Y, math.random(-60, 20))
			table.insert(waypoints, 1, start)
			table.insert(waypoints, finish)
			task.spawn(function()
				local SPEED = 26
				local grabs: { any } = {}
				local caught: { [Player]: boolean } = {}
				local freeAt: { [Player]: number } = {} -- when somebody who was let go (or taken up) can be caught again
				local shipPos = start
				local target = 2
				local last = os.clock()
				local t0 = last
				local lastBoom = 0
				while target <= #waypoints do
					local now = os.clock()
					local dt = now - last
					last = now
					local t = now - t0
					local goal = waypoints[target]
					local toGoal = goal - shipPos
					if toGoal.Magnitude <= SPEED * dt + 0.5 then
						shipPos = goal
						target += 1
					else
						shipPos += toGoal.Unit * SPEED * dt
					end
					local drawn = Vector3.new(shipPos.X, SHIP_Y + math.sin(t * 2.2) * 3, shipPos.Z)
					upright(body, drawn)
					dome.Position = drawn + Vector3.new(0, 8, 0)
					local overTable = math.abs(shipPos.X) < 98 and shipPos.Z > -100 and shipPos.Z < 62
					beamPart.CFrame = CFrame.new(drawn - Vector3.new(0, (SHIP_Y + 10) / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
					beamPart.Transparency = if overTable then 0.5 + math.sin(now * 12) * 0.12 else 1
					if overTable then
						for _, plr in Players:GetPlayers() do
							local ch = plr.Character
							local root = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
							if root and not caught[plr] and now >= (freeAt[plr] or 0) and root.Position.Y > ROOM_FLOOR + 20 and root.Position.Y < SHIP_Y - 20 and Vector3.new(root.Position.X - shipPos.X, 0, root.Position.Z - shipPos.Z).Magnitude < BEAM_R then
								local g = catchPlayer(plr)
								if g then
									caught[plr] = true
									g.T0 = t
									table.insert(grabs, g)
								end
							end
						end
					end
					for _, g in grabs do
						if g.Done then
							continue
						end
						if not g.Root.Parent or g.Hum.Health <= 0 then
							g.Done = true
							caught[g.Plr] = nil
							freeAt[g.Plr] = now + 2
							releasePlayer(g, nil)
							continue
						end
						if g.Root.Position.Y >= drawn.Y - 14 then
							-- touched the top of the ship: straight back to the spawn (the beam can take them again later)
							g.Done = true
							caught[g.Plr] = nil
							freeAt[g.Plr] = now + 3
							harmlessBlast(drawn, 16)
							Remote.AbuseBoom:FireAllClients(1.2, drawn)
							releasePlayer(g, Vector3.zero)
							LobbyBuilder.SendToSpawn(g.Plr)
							continue
						end
						local rise = math.min(1, (t - g.T0) / 5)
						local up = 9 + 32 * rise * rise
						local toCentre = Vector3.new(drawn.X - g.Root.Position.X, 0, drawn.Z - g.Root.Position.Z)
						local v = toCentre * 2.5 + Vector3.new(0, up, 0)
						g.Mover.VectorVelocity = if v.Magnitude > 65 then v.Unit * 65 else v
					end
					if t - lastBoom > 1.1 then
						lastBoom = t
						if overTable then
							boom(0.8, Vector3.new(shipPos.X, 0.2, shipPos.Z))
						end
					end
					RunService.Heartbeat:Wait()
				end
				-- anyone not carried all the way up is let go
				for _, g in grabs do
					if not g.Done then
						releasePlayer(g, Vector3.zero)
					end
				end
				ship:Destroy()
			end)
		end
		-- Lasers out of his eyes that draw glowing trails on the table. Each use is different: it grows from one
		-- laser per eye up to four per eye, and the pattern changes (circles, sweeps across, a spiral out).
		local eyesBusy = false
		local eyesUses = 0
		fx.eyes = function()
			if eyesBusy or not giantHead then
				return
			end
			eyesBusy = true
			eyesUses += 1
			local headPart = giantHead :: BasePart
			local DURATION = eyesFor or 5.5
			eyesFor = nil
			local perEye = (eyesUses - 1) % 4 + 1
			local pattern = (eyesUses - 1) % 3 -- 0 circles, 1 sweeps, 2 spiral
			local count = perEye * 2
			local beams, sparks = {}, {}
			for i = 1, count do
				local b = neonPart(Vector3.new(4, 4, 10), if i % 2 == 1 then Color3.fromRGB(255, 60, 60) else Color3.fromRGB(255, 120, 60))
				b.Parent = workspace
				beams[i] = b
				local anchor = Instance.new("Part")
				anchor.Transparency = 1
				anchor.Anchored = true
				anchor.CanCollide = false
				anchor.CanQuery = false
				anchor.Size = Vector3.one
				local e = Instance.new("ParticleEmitter")
				e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
				e.Color = ColorSequence.new(Color3.fromRGB(255, 240, 140), Color3.fromRGB(255, 80, 40))
				e.Lifetime = NumberRange.new(0.5, 1)
				e.Speed = NumberRange.new(10, 30)
				e.SpreadAngle = Vector2.new(70, 70)
				e.Rate = 40
				e.Size = NumberSequence.new(3, 0)
				e.LightEmission = 1
				e.Parent = anchor
				anchor.Parent = workspace
				sparks[i] = anchor
			end
			local t0 = os.clock()
			local lastDot = 0
			local conn: RBXScriptConnection? = nil
			local function finish()
				if conn then
					conn:Disconnect()
				end
				for _, b in beams do
					b:Destroy()
				end
				for _, a in sparks do
					Debris:AddItem(a, 1)
					local e = a:FindFirstChildOfClass("ParticleEmitter")
					if e then
						e.Enabled = false
					end
				end
				eyesBusy = false
			end
			conn = RunService.Heartbeat:Connect(function()
				local t = os.clock() - t0
				if t > DURATION or not headPart.Parent then
					finish()
					return
				end
				local fade = math.max(0.05, math.min(1, t / 0.25, (DURATION - t) / 0.3))
				local dotNow = os.clock() - lastDot > 0.06
				local progress = t / DURATION
				for i, b in beams do
					local left = i % 2 == 1
					local from = (headPart.CFrame * CFrame.new((if left then -0.22 else 0.22) * headPart.Size.X, 0.08 * headPart.Size.Y, -0.5 * headPart.Size.Z)).Position
					local phase = (i - 1) / count * math.pi * 2
					local dir = if left then 1 else -1
					local x, z
					if pattern == 0 then
						local a = t * 1.5 * dir + phase
						local r = 35 + 25 * math.sin(t * 2.2 + i)
						x, z = math.cos(a) * r, 15 + math.sin(a) * r * 1.1
					elseif pattern == 1 then
						-- sweeping lines: side to side while moving down the table
						x = math.sin(t * 3 + phase) * 65
						z = 15 + (progress * 2 - 1) * 65 * dir
					else
						-- a spiral that opens out
						local a = t * 4 * dir + phase
						local r = 8 + 70 * progress
						x, z = math.cos(a) * r, 15 + math.sin(a) * r
					end
					local target = Vector3.new(x, 0.5, z)
					local len = (target - from).Magnitude
					b.Size = Vector3.new(4 * fade, 4 * fade, len)
					b.CFrame = CFrame.lookAt(from, target) * CFrame.new(0, 0, -len / 2)
					sparks[i].Position = target + Vector3.new(0, 1, 0)
					if dotNow then
						local dot = neonPart(Vector3.new(0.5, 4, 4), Color3.fromRGB(255, 150, 50), Enum.PartType.Cylinder)
						dot.CFrame = CFrame.new(target.X, 1.0, target.Z) * CFrame.Angles(0, 0, math.rad(90))
						dot.Parent = workspace
						TweenService:Create(dot, TweenInfo.new(2.5), { Transparency = 1, Color = Color3.fromRGB(120, 30, 20) }):Play()
						Debris:AddItem(dot, 2.6)
					end
				end
				if dotNow then
					lastDot = os.clock()
				end
			end)
			Remote.AbuseBoom:FireAllClients(1.4, Vector3.new(0, 0, 15))
		end
		local discoBusy = false
		-- The world goes rainbow and STAYS that way until the heat starts (then the red takes over). Called
		-- again while it is on, it does nothing. (In the heat it is a short burst: it never fights the red.)
		fx.disco = function()
			if discoBusy then
				return
			end
			discoBusy = true
			captureLighting()
			local original = { (baseLighting :: any).ColorShift_Top, (baseLighting :: any).OutdoorAmbient }
			local wasLive = ReplicatedStorage:GetAttribute("AbuseLive") == true
			task.spawn(function()
				local maxSteps = if heat then 16 else 1500
				for i = 1, maxSteps do
					if maxSteps > 16 and (heat or fadingOut or (i > 3 and not giant) or (wasLive and ReplicatedStorage:GetAttribute("AbuseLive") ~= true)) then
						break
					end
					local c = Color3.fromHSV((i / 16 * 2) % 1, 0.8, 1)
					-- (a smooth glide from colour to colour, not a jump every step)
					local glide: { [string]: any } = { ColorShift_Top = c }
					if not heat then
						glide.OutdoorAmbient = c:Lerp(Color3.new(1, 1, 1), 0.4)
					end
					TweenService:Create(Lighting, TweenInfo.new(0.4, Enum.EasingStyle.Linear), glide):Play()
					if i % 8 == 0 then
						Remote.AbuseBoom:FireAllClients(0.5, Vector3.new(0, 0, 0))
					end
					task.wait(0.4)
				end
				-- fade back (never a sudden click); if the show is over restoreLighting is fading it already
				local back: { [string]: any } = { ColorShift_Top = original[1] }
				if not heat then
					back.OutdoorAmbient = original[2]
				end
				if baseLighting then
					TweenService:Create(Lighting, TweenInfo.new(2.5, Enum.EasingStyle.Sine), back):Play()
				end
				discoBusy = false
			end)
		end
		-- Fireballs fall on the table one after another and shake it. More of them each time it is used.
		local fireUses = 0
		fx.fireballs = function()
			fireUses += 1
			local n = math.min(22, 4 + fireUses * 3 + (if heat then 4 else 0))
			for i = 1, n do
				task.delay((i - 1) * 0.18, function()
					local spot = plazaSpot()
					local ball = neonPart(Vector3.new(11, 11, 11), Color3.fromRGB(255, 120, 40), Enum.PartType.Ball)
					ball.Position = spot + Vector3.new(math.random(-50, 50), 260, math.random(-50, 50))
					local fire = Instance.new("ParticleEmitter")
					fire.Texture = "rbxasset://textures/particles/fire_main.dds"
					fire.Color = ColorSequence.new(Color3.fromRGB(255, 220, 90), Color3.fromRGB(255, 60, 20))
					fire.Lifetime = NumberRange.new(0.4, 0.8)
					fire.Speed = NumberRange.new(2, 10)
					fire.Rate = 90
					fire.Size = NumberSequence.new(14, 0)
					fire.LightEmission = 1
					fire.Parent = ball
					ball.Parent = workspace
					local fall = TweenService:Create(ball, TweenInfo.new(0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = spot + Vector3.new(0, 5, 0) })
					fall.Completed:Connect(function()
						ball:Destroy()
						harmlessBlast(spot + Vector3.new(0, 4, 0), 18)
						-- a short glow where it landed (no dark marks left on the table: they looked like black lines)
						local ember = neonPart(Vector3.new(0.5, 16, 16), Color3.fromRGB(255, 130, 50), Enum.PartType.Cylinder)
						ember.Transparency = 0.5
						ember.CFrame = CFrame.new(spot.X, 1.2, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
						ember.Parent = workspace
						TweenService:Create(ember, TweenInfo.new(1.6), { Transparency = 1, Size = Vector3.new(0.5, 26, 26) }):Play()
						Debris:AddItem(ember, 1.7)
						Remote.AbuseBoom:FireAllClients(1.3, spot) -- the table shakes
						local ring = neonPart(Vector3.new(0.4, 6, 6), Color3.fromRGB(255, 170, 60), Enum.PartType.Cylinder)
						ring.CFrame = CFrame.new(spot.X, 1.0, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
						ring.Parent = workspace
						TweenService:Create(ring, TweenInfo.new(0.6), { Size = Vector3.new(0.4, 40, 40), Transparency = 1 }):Play()
						Debris:AddItem(ring, 0.7)
					end)
					fall:Play()
					Debris:AddItem(ball, 2)
				end)
			end
		end
		-- The big one: he gathers a glowing ball in front of his chest, then fires it at the giant dishwasher,
		-- which blows apart into pieces that fly everywhere.
		fx.dishwasher = function()
			local model = giant
			local rootPart = model and model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not model or not rootPart or LobbyBuilder.DishwasherBroken() then
				return
			end
			say("see that machine? i never liked it.") -- (said as he starts to gather the fireball, a few seconds before it hits)
			local unit = if giantHead then giantHead.Size.Y else 45
			-- where his hands meet: out in front of his chest (a head is about 1.2 studs tall at scale 1)
			local scale = unit / 1.2
			local function chest(ballSize: number): Vector3
				-- between his real hands (arms stretched out in front), the ball a little way ahead of them
				local rh, lh = model:FindFirstChild("RightHand") :: BasePart?, model:FindFirstChild("LeftHand") :: BasePart?
				if rh and lh then
					return (rh.Position + lh.Position) / 2 + rootPart.CFrame.LookVector * (ballSize * 0.4 + scale * 0.4)
				end
				return rootPart.Position + rootPart.CFrame.LookVector * (scale * 3.1 + ballSize * 0.25) + Vector3.new(0, scale * 1.4, 0)
			end
			local ball = neonPart(Vector3.new(6, 6, 6), Color3.fromRGB(255, 230, 150), Enum.PartType.Ball)
			if giantGesture then
				giantGesture("charge")
			end
			ball.Position = chest(6)
			local light = Instance.new("PointLight")
			light.Range = 90
			light.Brightness = 6
			light.Color = Color3.fromRGB(255, 190, 90)
			light.Parent = ball
			local glow = Instance.new("ParticleEmitter")
			glow.Texture = "rbxasset://textures/particles/sparkles_main.dds"
			glow.Color = ColorSequence.new(Color3.fromRGB(255, 240, 160), Color3.fromRGB(255, 120, 40))
			glow.Lifetime = NumberRange.new(0.4, 0.9)
			glow.Speed = NumberRange.new(5, 25)
			glow.SpreadAngle = Vector2.new(180, 180)
			glow.Rate = 120
			glow.Size = NumberSequence.new(10, 0)
			glow.LightEmission = 1
			glow.Parent = ball
			ball.Parent = workspace
			local CHARGE, FLIGHT = 3.2, 1.3
			local target = Vector3.new(0, 28, -78) -- the front of the dishwasher
			task.spawn(function()
				local t0 = os.clock()
				-- charging: it swells and throbs in front of him while the room rumbles
				local lastRumble = 0
				while giant == model do
					local t = os.clock() - t0
					if t >= CHARGE then
						break
					end
					local f = t / CHARGE
					local size = 6 + 60 * f * f + math.sin(t * 22) * 2.5 * f
					ball.Size = Vector3.new(size, size, size)
					ball.Position = chest(size)
					light.Brightness = 4 + 10 * f
					if t - lastRumble > 0.5 then
						lastRumble = t
						Remote.AbuseBoom:FireAllClients(0.5 + f, ball.Position)
					end
					task.wait()
				end
				if giant ~= model then
					ball:Destroy()
					return
				end
				-- fired
				Remote.AbuseBoom:FireAllClients(2.2, ball.Position)
				task.delay(FLIGHT, function()
					if giantGesture then
						giantGesture(nil)
					end
				end)
				local from = ball.Position
				local f0 = os.clock()
				while true do
					local f = (os.clock() - f0) / FLIGHT
					if f >= 1 then
						break
					end
					ball.Position = from:Lerp(target, f)
					task.wait()
				end
				ball:Destroy()
				-- impact
				LobbyBuilder.BreakDishwasher(target)
				local flash = neonPart(Vector3.new(30, 30, 30), Color3.new(1, 1, 1), Enum.PartType.Ball)
				flash.Position = target
				flash.Parent = workspace
				TweenService:Create(flash, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(420, 420, 420), Transparency = 1 }):Play()
				Debris:AddItem(flash, 1)
				for i = 0, 3 do
					task.delay(i * 0.15, function()
						ringAt(Vector3.new(0, 2, -78), 200 + i * 160, 1, Color3.fromRGB(255, 190, 90))
						Remote.AbuseBoom:FireAllClients(3.4, target)
					end)
				end
				-- the wreck burns and smokes for a while
				local fire = Instance.new("Part")
				fire.Name = "Wreck"
				fire.Transparency = 1
				fire.Anchored = true
				fire.CanCollide = false
				fire.CanQuery = false
				fire.Size = Vector3.new(60, 2, 20)
				fire.Position = Vector3.new(0, 4, -88)
				for _, kind in { "fire", "smoke" } do
					local e = Instance.new("ParticleEmitter")
					e.Texture = if kind == "fire" then "rbxasset://textures/particles/fire_main.dds" else "rbxasset://textures/particles/smoke_main.dds"
					e.Color = if kind == "fire" then ColorSequence.new(Color3.fromRGB(255, 200, 80), Color3.fromRGB(255, 70, 20)) else ColorSequence.new(Color3.fromRGB(60, 60, 64))
					e.Lifetime = NumberRange.new(1, 2.4)
					e.Speed = NumberRange.new(6, 18)
					e.SpreadAngle = Vector2.new(25, 25)
					e.EmissionDirection = Enum.NormalId.Top
					e.Rate = if kind == "fire" then 25 else 14
					e.Size = NumberSequence.new(if kind == "fire" then 9 else 14, 3)
					e.Transparency = NumberSequence.new(if kind == "fire" then 0.2 else 0.5, 1)
					e.LightEmission = if kind == "fire" then 1 else 0
					e.Parent = fire
				end
				fire.Parent = workspace
				track(fire)
				Debris:AddItem(fire, 40)
				task.delay(30, function()
					for _, e in fire:GetChildren() do
						if e:IsA("ParticleEmitter") then
							e.Enabled = false
						end
					end
				end)
			end)
		end
		-- Bombs: red circles show where each one will land; two seconds and a half later it does, and anyone
		-- standing in the circle is thrown out of it (no damage). Each leaves a small crater until the show ends.
		-- Two rounds, ten seconds apart.
		local craterCount = 9 -- hole indexes 10 and up belong to the bomb craters
		local function bombRound(round: number)
			local spots: { Vector3 } = {}
			local function clampSpot(v: Vector3): Vector3
				return Vector3.new(math.clamp(v.X, -75, 75), 0.25, math.clamp(v.Z, -85, 55))
			end
			for _, plr in Players:GetPlayers() do
				local c = plr.Character
				local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
				if r and r.Position.Y > -5 and r.Position.Y < 120 and math.abs(r.Position.X) < 100 and r.Position.Z > -100 and r.Position.Z < 60 then
					table.insert(spots, clampSpot(r.Position + Vector3.new(math.random(-12, 12), 0, math.random(-12, 12))))
				end
			end
			-- (a few scattered ones so there are always several, even with one player)
			-- (a few scattered ones so there are always several, even with one player; never close together or
			-- on the two big holes)
			local function spaced(v: Vector3): boolean
				for _, other in spots do
					if (other - v).Magnitude < 30 then
						return false
					end
				end
				for _, def in Show.Holes do
					if (Vector3.new(def[1], 0.25, def[2]) - v).Magnitude < def[3] + 22 then
						return false
					end
				end
				return true
			end
			local near = spots
			spots = {}
			for _, v in near do
				if spaced(v) then
					table.insert(spots, v)
				end
			end
			local target = math.min(6, 3 + round)
			local tries = 0
			while #spots < target and tries < 80 do
				tries += 1
				local v = clampSpot(plazaSpot())
				if spaced(v) then
					table.insert(spots, v)
				end
			end
			while #spots > 6 do
				table.remove(spots, math.random(1, #spots))
			end
			local RADIUS, FALL = 14, 2.6
			for i, spot in spots do
				task.delay((i - 1) * 0.08, function()
					local warn = neonPart(Vector3.new(0.5, RADIUS * 2, RADIUS * 2), Color3.fromRGB(255, 50, 40), Enum.PartType.Cylinder)
					warn.Transparency = 0.55
					warn.CFrame = CFrame.new(spot.X, 1.3, spot.Z) * CFrame.Angles(0, 0, math.rad(90))
					warn.Parent = workspace
					TweenService:Create(warn, TweenInfo.new(0.3, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, true), { Transparency = 0.15 }):Play()
					local bomb = Instance.new("Part")
					bomb.Shape = Enum.PartType.Ball
					bomb.Size = Vector3.new(8, 8, 8)
					bomb.Color = Color3.fromRGB(38, 38, 46)
					bomb.Material = Enum.Material.Metal
					bomb.Anchored = true
					bomb.CanCollide = false
					bomb.CanTouch = false
					bomb.CanQuery = false
					bomb.Position = spot + Vector3.new(math.random(-20, 20), 280, math.random(-20, 20))
					local smoke = Instance.new("ParticleEmitter")
					smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
					smoke.Color = ColorSequence.new(Color3.fromRGB(90, 90, 96))
					smoke.Lifetime = NumberRange.new(0.6, 1)
					smoke.Rate = 40
					smoke.Speed = NumberRange.new(0, 3)
					smoke.Size = NumberSequence.new(5, 1)
					smoke.Parent = bomb
					bomb.Parent = workspace
					track(warn)
					track(bomb)
					local fall = TweenService:Create(bomb, TweenInfo.new(FALL, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = spot + Vector3.new(0, 4, 0) })
					fall.Completed:Connect(function()
						bomb:Destroy()
						warn:Destroy()
						harmlessBlast(spot + Vector3.new(0, 4, 0), 26)
						Remote.AbuseBoom:FireAllClients(1.8, spot)
						ringAt(spot, 60, 0.6, Color3.fromRGB(255, 170, 70))
						-- a real hole through the table (the bits near it are moved clear), then whoever was close is thrown out
						craterCount += 1
						LobbyBuilder.OpenCrater(craterCount, spot.X, spot.Z, 9)
						for _, plr in Players:GetPlayers() do
							local c = plr.Character
							local r = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
							local hum = c and c:FindFirstChildOfClass("Humanoid")
							if r and hum then
								local off = Vector3.new(r.Position.X - spot.X, 0, r.Position.Z - spot.Z)
								if off.Magnitude < 40 and r.Position.Y < spot.Y + 40 then
									local dir = if off.Magnitude > 0.5 then off.Unit else Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
									pcall(function()
										hum:ChangeState(Enum.HumanoidStateType.Freefall)
										r.AssemblyLinearVelocity = dir * 70 + Vector3.new(0, 45, 0)
									end)
								end
							end
						end
					end)
					fall:Play()
				end)
			end
		end
		fx.bombs = function()
			bombRound(1)
			task.delay(10, function()
				if giant then
					bombRound(2)
				end
			end)
		end
		-- The nuke: he picks it up (hands together), throws it onto the right side of the table, where it sits
		-- with a countdown over it, and at the end of the countdown (just before he leaves) it goes off and breaks
		-- a big part of that side of the table. The spawn and the obby are far from it, so they stay usable.
		local nukeActive = false
		fx.nuke = function()
			local model = giant
			local rootPart = model and model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not model or not rootPart or nukeActive then
				return
			end
			nukeActive = true
			-- It goes off COUNT seconds after it lands: the display starts at 10 and stays on it a little longer (the first
			-- digit used to be 9 because he started late), then 9, 8, ... 1.
			local COUNT = 10.8
			nukeQuietUntil = os.clock() + 3.6 + COUNT + 12 -- nothing else happens until it has gone off
			say("this spot looks empty... how about a nuke.")
			local unit = if giantHead then giantHead.Size.Y else 45
			local scale = unit / 1.2
			local parts: { BasePart } = {}
			local offsets: { CFrame } = {}
			local function add(part: BasePart, offset: CFrame)
				part.Parent = workspace
				track(part)
				table.insert(parts, part)
				table.insert(offsets, offset)
			end
			local function metal(size: Vector3, color: Color3, shape: Enum.PartType?): Part
				local part = Instance.new("Part")
				part.Anchored = true
				part.CanCollide = false
				part.CanTouch = false
				part.CanQuery = false
				part.Material = Enum.Material.Metal
				part.Color = color
				part.Size = size
				if shape then
					part.Shape = shape
				end
				return part
			end
			-- A proper bomb, like the real ones: a fat egg-shaped body with a hazard band, a short tail section and a cross of
			-- big fins (not a long thin tube, which looked like a headphone jack).
			local dark = Color3.fromRGB(52, 58, 54)
			local function ellipsoid(size: Vector3, color: Color3): Part
				local part = metal(size, color)
				local mesh = Instance.new("SpecialMesh")
				mesh.MeshType = Enum.MeshType.Sphere
				mesh.Parent = part
				return part
			end
			local body = ellipsoid(Vector3.new(34, 26, 26), dark)
			add(body, CFrame.identity)
			-- tail: a taper behind the body, then a boxed cage with a cross of fins
			add(metal(Vector3.new(10, 15, 15), dark, Enum.PartType.Cylinder), CFrame.new(-19, 0, 0))
			add(metal(Vector3.new(9, 19, 19), Color3.fromRGB(70, 76, 70)), CFrame.new(-27, 0, 0))
			add(metal(Vector3.new(9, 30, 1), Color3.fromRGB(70, 76, 70)), CFrame.new(-27, 0, 0))
			add(metal(Vector3.new(9, 1, 30), Color3.fromRGB(70, 76, 70)), CFrame.new(-27, 0, 0))
			-- bands round the body: hazard yellow and red
			add(neonPart(Vector3.new(3, 25.4, 25.4), Color3.fromRGB(255, 205, 40), Enum.PartType.Cylinder), CFrame.new(8, 0, 0))
			for _, x in { -6, -1 } do
				add(neonPart(Vector3.new(1.4, 25.8, 25.8), Color3.fromRGB(255, 50, 40), Enum.PartType.Cylinder), CFrame.new(x, 0, 0))
			end
			-- a nose tip
			add(metal(Vector3.new(4, 4, 4), Color3.fromRGB(120, 124, 120), Enum.PartType.Ball), CFrame.new(17, 0, 0))
			local function place(cf: CFrame)
				for i, p in parts do
					p.CFrame = cf * offsets[i]
				end
			end
			local function hands(): Vector3
				local rh, lh = model:FindFirstChild("RightHand") :: BasePart?, model:FindFirstChild("LeftHand") :: BasePart?
				if rh and lh then
					return (rh.Position + lh.Position) / 2 + rootPart.CFrame.LookVector * (scale * 1.6)
				end
				return rootPart.Position + rootPart.CFrame.LookVector * (scale * 3.4) + Vector3.new(0, scale * 1.4, 0)
			end
			local function cleanup()
				for _, p in parts do
					p:Destroy()
				end
				nukeActive = false
			end
			if giantGesture then
				giantGesture("charge")
			end
			task.spawn(function()
				-- held out in front of him
				local t0 = os.clock()
				while os.clock() - t0 < 1.6 do
					if giant ~= model then
						cleanup()
						return
					end
					local look = rootPart.CFrame.LookVector
					place(CFrame.lookAt(hands(), hands() + look) * CFrame.Angles(0, math.rad(90), 0))
					task.wait()
				end
				-- thrown onto the right side of the table
				if giantGesture then
					giantGesture(nil)
				end
				local target = Vector3.new(0, 4.5, -89) -- where the dishwasher stood
				local from = hands()
				local f0 = os.clock()
				local FLIGHT = 1.7
				Remote.AbuseBoom:FireAllClients(1.8, from)
				while true do
					local f = (os.clock() - f0) / FLIGHT
					if f >= 1 or giant ~= model then
						break
					end
					local pos = from:Lerp(target, f) + Vector3.new(0, math.sin(math.pi * f) * 110, 0)
					place(CFrame.new(pos) * CFrame.Angles(f * 9, f * 5, 0))
					task.wait()
				end
				if not body.Parent then
					cleanup()
					return
				end
				local landed = CFrame.new(target) * CFrame.Angles(0, math.rad(28), 0)
				place(landed)
				Remote.AbuseBoom:FireAllClients(2.6, target)
				ringAt(Vector3.new(target.X, 1, target.Z), 160, 0.8, Color3.fromRGB(255, 150, 60))
				-- the countdown over it
				local gui = Instance.new("BillboardGui")
				gui.Size = UDim2.fromOffset(300, 110)
				gui.StudsOffsetWorldSpace = Vector3.new(0, 16, 0)
				gui.AlwaysOnTop = true
				gui.MaxDistance = 4000
				local label = Instance.new("TextLabel")
				label.Size = UDim2.fromScale(1, 1)
				label.BackgroundTransparency = 1
				label.Font = Enum.Font.LuckiestGuy
				label.TextScaled = true
				label.TextColor3 = Color3.fromRGB(255, 70, 60)
				label.TextStrokeTransparency = 0
				label.Parent = gui
				gui.Parent = body
				local glow = Instance.new("PointLight")
				glow.Color = Color3.fromRGB(255, 60, 40)
				glow.Range = 60
				glow.Parent = body
				local lastShown = -1
				local boomClock = os.clock() + COUNT
				while true do
					if not body.Parent then
						cleanup() -- (the show was put away early: it never goes off)
						return
					end
					local left = math.ceil(boomClock - os.clock())
					if left ~= lastShown then
						lastShown = left
						label.Text = tostring(math.clamp(left, 0, 10))
						glow.Brightness = if left <= 10 then 6 else 2
						if left <= 10 and left > 0 then
							Remote.AbuseBoom:FireAllClients(0.8, target)
						end
					end
					if left <= 0 then
						break
					end
					task.wait(0.2)
				end
				-- it goes off
				cleanup()
				-- a blinding flash, the fireball, and a column of fire climbing into a mushroom cloud
				local flash = neonPart(Vector3.new(50, 50, 50), Color3.new(1, 1, 1), Enum.PartType.Ball)
				flash.Position = target + Vector3.new(0, 8, 0)
				flash.Parent = workspace
				TweenService:Create(flash, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(2600, 2600, 2600), Transparency = 1 }):Play()
				Debris:AddItem(flash, 1.8)
				local fireball = neonPart(Vector3.new(70, 70, 70), Color3.fromRGB(255, 150, 50), Enum.PartType.Ball)
				fireball.Transparency = 0.15
				fireball.Position = target + Vector3.new(0, 24, 0)
				fireball.Parent = workspace
				TweenService:Create(fireball, TweenInfo.new(2.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(560, 560, 560), Position = target + Vector3.new(0, 160, 0), Transparency = 1 }):Play()
				Debris:AddItem(fireball, 2.8)
				local stem = neonPart(Vector3.new(6, 60, 60), Color3.fromRGB(255, 120, 40), Enum.PartType.Cylinder)
				stem.Transparency = 0.25
				stem.CFrame = CFrame.new(target + Vector3.new(0, 3, 0)) * CFrame.Angles(0, 0, math.pi / 2)
				stem.Parent = workspace
				TweenService:Create(stem, TweenInfo.new(2.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(300, 80, 80), CFrame = CFrame.new(target + Vector3.new(0, 150, 0)) * CFrame.Angles(0, 0, math.pi / 2), Transparency = 0.8 }):Play()
				Debris:AddItem(stem, 2.4)
				local cap = neonPart(Vector3.new(30, 30, 30), Color3.fromRGB(255, 190, 80), Enum.PartType.Ball)
				cap.Transparency = 0.2
				cap.Position = target + Vector3.new(0, 40, 0)
				cap.Parent = workspace
				TweenService:Create(cap, TweenInfo.new(2.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(300, 170, 300), Position = target + Vector3.new(0, 300, 0), Transparency = 0.85 }):Play()
				Debris:AddItem(cap, 2.8)
				for i = 0, 4 do
					task.delay(i * 0.25, function()
						ringAt(Vector3.new(target.X, 2, target.Z), 600 + i * 700, 1.8, Color3.fromRGB(255, 190, 90))
						Remote.AbuseBoom:FireAllClients(if i == 0 then 8 else 5, target)
					end)
				end
				-- the table breaks open at once, round: ONE big round hole over the back half of the table, its tiles blown up and out
				craterCount += 1
				local cx = math.clamp(target.X, -90, 90)
				local cz = math.clamp(target.Z + 40, -96, 24)
				LobbyBuilder.OpenCrater(craterCount, cx, cz, 64, true)
				-- and a real blast wave: everybody in the room is thrown away from it (a brief pull on each player, then
				-- let go at speed), harder the nearer they were; the fliers too
				for _, plr in Players:GetPlayers() do
					local ch = plr.Character
					local r = ch and ch:FindFirstChild("HumanoidRootPart") :: BasePart?
					if r and r.Position.Y > ROOM_FLOOR + 15 then
						local off = Vector3.new(r.Position.X - target.X, 0, r.Position.Z - target.Z)
						local dist = off.Magnitude
						if dist < 520 then
							local dir = if dist > 0.5 then off.Unit else Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
							local speed = math.clamp(230 - dist * 0.22, 100, 230)
							local g = catchPlayer(plr)
							if g then
								g.Mover.VectorVelocity = dir * speed + Vector3.new(0, 70, 0)
								task.delay(0.5, function()
									releasePlayer(g, dir * speed * 0.8 + Vector3.new(0, 25, 0))
								end)
							end
						end
					end
				end
				local wreck = Instance.new("Part")
				wreck.Name = "Wreck"
				wreck.Transparency = 1
				wreck.Anchored = true
				wreck.CanCollide = false
				wreck.CanQuery = false
				wreck.Size = Vector3.new(50, 2, 50)
				wreck.Position = Vector3.new(target.X, -4, target.Z)
				for _, kind in { "fire", "smoke" } do
					local em = Instance.new("ParticleEmitter")
					em.Texture = if kind == "fire" then "rbxasset://textures/particles/fire_main.dds" else "rbxasset://textures/particles/smoke_main.dds"
					em.Color = if kind == "fire" then ColorSequence.new(Color3.fromRGB(255, 200, 80), Color3.fromRGB(255, 70, 20)) else ColorSequence.new(Color3.fromRGB(50, 50, 54))
					em.Lifetime = NumberRange.new(1.2, 2.8)
					em.Speed = NumberRange.new(8, 24)
					em.SpreadAngle = Vector2.new(30, 30)
					em.EmissionDirection = Enum.NormalId.Top
					em.Rate = if kind == "fire" then 22 else 12
					em.Size = NumberSequence.new(if kind == "fire" then 12 else 18, 4)
					em.Transparency = NumberSequence.new(if kind == "fire" then 0.2 else 0.5, 1)
					em.LightEmission = if kind == "fire" then 1 else 0
					em.Parent = wreck
				end
				wreck.Parent = workspace
				track(wreck)
				nukeActive = false
			end)
		end
		-- The pet hunt: limited pets (a different one from the dragon) are let loose on the undamaged part of the table.
		-- How many depends on how many players are in this server. They run away from people, fast; holding E on one
		-- for three seconds catches it (it struggles, slowing down, while someone holds). After a minute whatever is
		-- left fades away. A countdown shows on everyone's screen.
		local chaseActive = false
		fx.petchase = function()
			if chaseActive then
				return
			end
			local petId = Show.ChasePet
			local def = Config.Pets[petId]
			if not def then
				return
			end
			chaseActive = true
			local PetModels = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("PetModels"))
			local players = #Players:GetPlayers()
			local count = if players <= 3 then 1 elseif players <= 5 then 2 elseif players <= 10 then 3 else math.min(10, 3 + math.ceil((players - 10) / 6))
			local DURATION = 60
			local endsAt = Config.Now() + DURATION
			ReplicatedStorage:SetAttribute("AbusePetsEnd", endsAt)
			local pets: { { Model: Model, Root: BasePart, Dir: Vector3, Holding: number, Done: boolean, Height: number } } = {}
			local function bounded(x: number, z: number): boolean
				return math.abs(x) < 82 and z > -88 and z < 52 and not LobbyBuilder.IsHoleAt(x, z, 12)
			end
			local function freeSpot(): Vector3
				for _ = 1, 40 do
					local x, z = math.random(-80, 80), math.random(-85, 50)
					if bounded(x, z) then
						return Vector3.new(x, 0, z)
					end
				end
				return Vector3.new(0, 0, 20)
			end
			local function removePet(rec: any)
				rec.Done = true
				for _, d in rec.Model:GetDescendants() do
					if d:IsA("BasePart") then
						TweenService:Create(d, TweenInfo.new(0.8), { Transparency = 1 }):Play()
					end
				end
				task.delay(0.9, function()
					rec.Model:Destroy()
				end)
			end
			for _ = 1, count do
				local okBuild, model = pcall(PetModels.Build, petId, 1)
				if okBuild and model then
					pcall(function()
						model:ScaleTo(2.6)
					end)
					local root = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
					if root then
						for _, d in model:GetDescendants() do
							if d:IsA("BasePart") then
								d.Anchored = true
								d.CanCollide = false
								d.CanQuery = true
							end
						end
						model.Name = "AbuseChasePet"
						local spot = freeSpot()
						local _, size = model:GetBoundingBox()
						local rec = { Model = model, Root = root, Dir = Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit, Holding = 0, Done = false, Height = size.Y / 2 }
						model:PivotTo(CFrame.new(spot.X, rec.Height + 0.4, spot.Z))
						model.Parent = workspace
						local prompt = Instance.new("ProximityPrompt")
						prompt.ActionText = "Catch"
						prompt.ObjectText = def.Name .. " (limited)"
						prompt.HoldDuration = 3
						prompt.MaxActivationDistance = 11
						prompt.RequiresLineOfSight = false
						prompt.KeyboardKeyCode = Enum.KeyCode.E
						prompt.Parent = root
						prompt.PromptButtonHoldBegan:Connect(function()
							rec.Holding += 1
						end)
						prompt.PromptButtonHoldEnded:Connect(function()
							rec.Holding = math.max(0, rec.Holding - 1)
						end)
						prompt.Triggered:Connect(function(plr)
							if rec.Done then
								return
							end
							removePet(rec)
							local given = PetService.GivePet(plr, petId)
							DataService.Track(plr, "show.prize")
							if given then
								celebrate(plr, "You caught it!", "You got the limited " .. def.Name .. "!", "@Gift")
							else
								DataService.AddGems(plr, 150, "ShowPrize")
								celebrate(plr, "You caught it!", "Your pet bag is full, so here are 150 Gems instead of the " .. def.Name .. "!", "@Gift")
							end
							say(plr.Name .. " caught one!")
						end)
						table.insert(pets, rec)
					else
						model:Destroy()
					end
				end
			end
			local conn: RBXScriptConnection? = nil
			local function finish()
				if conn then
					conn:Disconnect()
					conn = nil
				end
				for _, rec in pets do
					if not rec.Done then
						removePet(rec)
					end
				end
				ReplicatedStorage:SetAttribute("AbusePetsEnd", nil)
				chaseActive = false
				stopChase = nil
			end
			stopChase = finish
			local hop = 0
			conn = RunService.Heartbeat:Connect(function(dt)
				hop += dt
				if Config.Now() >= endsAt then
					finish()
					return
				end
				local alive = 0
				for _, rec in pets do
					if not rec.Done then
						alive += 1
						local pos = rec.Root.Position
						-- away from anyone close, plus a little wandering
						local flee = Vector3.zero
						for _, plr in Players:GetPlayers() do
							local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
							if r then
								local off = Vector3.new(pos.X - r.Position.X, 0, pos.Z - r.Position.Z)
								local d = off.Magnitude
								if d < 45 and d > 0.1 then
									flee += off.Unit * (45 - d) / 45
								end
							end
						end
						local want = rec.Dir + flee * 2.2 + Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 0.3
						if want.Magnitude < 0.05 then
							want = rec.Dir
						end
						rec.Dir = rec.Dir:Lerp(want.Unit, math.clamp(dt * 6, 0, 1))
						if rec.Dir.Magnitude < 0.01 then
							rec.Dir = want.Unit
						end
						rec.Dir = rec.Dir.Unit
						-- (a bit slower than before, and almost stuck while someone holds E / taps and holds the prompt)
						local speed = if rec.Holding > 0 then 1.5 else (if flee.Magnitude > 0.05 then 30 else 16)
						-- never into a hole in the table or off its edge: turn away until the next step is on solid table
						local nx, nz = pos.X + rec.Dir.X * speed * dt, pos.Z + rec.Dir.Z * speed * dt
						if not bounded(nx, nz) then
							local found = false
							for k = 1, 12 do
								local a = math.rad(30 * k) * (if k % 2 == 0 then 1 else -1)
								local cosA, sinA = math.cos(a), math.sin(a)
								local d2 = Vector3.new(rec.Dir.X * cosA - rec.Dir.Z * sinA, 0, rec.Dir.X * sinA + rec.Dir.Z * cosA)
								local tx, tz = pos.X + d2.X * speed * dt * 3, pos.Z + d2.Z * speed * dt * 3
								if bounded(tx, tz) then
									rec.Dir = d2
									nx, nz = pos.X + d2.X * speed * dt, pos.Z + d2.Z * speed * dt
									found = true
									break
								end
							end
							if not found then
								nx, nz = pos.X, pos.Z
							end
						end
						local y = rec.Height + 0.4 + math.abs(math.sin(hop * 9 + alive)) * 1.2
						rec.Model:PivotTo(CFrame.lookAt(Vector3.new(nx, y, nz), Vector3.new(nx + rec.Dir.X, y, nz + rec.Dir.Z)))
					end
				end
				if alive == 0 then
					-- every pet is caught: no waiting around for the rest of the minute, the show moves on
					local left = endsAt - Config.Now()
					finish()
					if left > 3 then
						skipScript(left)
						say("all the pets got caught. well done.")
					end
				end
			end)
		end
		fx.fountains = function()
			for i = 1, if heat then 8 else 5 do
				task.delay(i * 0.25, function()
					local spot = plazaSpot()
					local jet = neonPart(Vector3.new(2, 8, 8), PALETTE[i % #PALETTE + 1], Enum.PartType.Cylinder)
					jet.Transparency = 0.25
					upright(jet, spot + Vector3.new(0, 1, 0))
					jet.Parent = workspace
					TweenService:Create(jet, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(120, 12, 12), Transparency = 1 }):Play()
					local lift = Instance.new("NumberValue")
					lift.Value = 1
					TweenService:Create(lift, TweenInfo.new(1.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Value = 120 }):Play()
					lift.Changed:Connect(function(h)
						upright(jet, spot + Vector3.new(0, h / 2, 0))
					end)
					Debris:AddItem(jet, 1.8)
					Debris:AddItem(lift, 1.8)
					boom(1.2, spot)
				end)
			end
		end
		return fx
	end)()
	playEffect = function(name: string)
		if name == "winner" then
			name = chosenEffect
		end
		local effect = FX[name]
		if effect and giant then
			commandText(nil)
			effect()
			if name == "meteors" or name == "blackhole" or name == "tornado" then
				Remote.AbuseBoom:FireAllClients(2.5, Vector3.new(0, 0, 0))
			end
		end
	end

	-- Holes in the table (LobbyBuilder cuts and repairs the table itself).
	local function openHole(index: number)
		local def = Show.Holes[index]
		if not def then
			return
		end
		local pos = Vector3.new(def[1], 0.2, def[2])
		LobbyBuilder.OpenHole(index, punchLaunch)
		punchLaunch = nil
		boom(3, pos)
		for i = 1, 3 do
			task.delay(i * 0.3, function()
				harmlessBlast(pos + Vector3.new(math.random(-12, 12), 0, math.random(-12, 12)), 18)
				ringAt(pos, 200 + i * 160, 1.2, Color3.fromRGB(255, 150, 60))
				Remote.AbuseBoom:FireAllClients(2.4, pos)
			end)
		end
	end
	local function closeHoles(seconds: number?)
		-- the fires and smoke die down first, then the table builds itself back, slowly
		for _, p in fxParts do
			if p.Name == "Wreck" then
				for _, e in p:GetDescendants() do
					if e:IsA("ParticleEmitter") then
						e.Enabled = false
					end
				end
			end
		end
		LobbyBuilder.HealHoles(seconds or 9)
	end

	local spawning, spawnFailures, nextSpawnTry = false, 0, 0
	local spawnGiantNow: () -> ()
	-- Builds him once at a time, and gives up after three failures (each 20 s apart).
	local function spawnGiant()
		if giant or spawning or spawnFailures >= 3 or os.clock() < nextSpawnTry then
			return
		end
		spawning = true
		spawnGiantNow()
		spawning = false
	end
	-- The lowest point of a part (its rotated box), so a foot's sole is found whatever the pose.
	local function lowestPoint(part: BasePart?): number
		if not part then
			return math.huge
		end
		local cf, size = part.CFrame, part.Size
		local reach = (math.abs(cf.RightVector.Y) * size.X + math.abs(cf.UpVector.Y) * size.Y + math.abs(cf.LookVector.Y) * size.Z) / 2
		return cf.Position.Y - reach
	end
	local function softenParts(model: Model)
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
				part.CanTouch = false
				part.CanQuery = false
				part.Massless = true
			end
		end
	end
	spawnGiantNow = function()
		local ok, model, desc = pcall(function()
			local d = Players:GetHumanoidDescriptionFromUserId(Show.OwnerUserId)
			return Players:CreateHumanoidModelFromDescription(d, Enum.HumanoidRigType.R15), d
		end)
		if not ok or not model then
			spawnFailures += 1
			nextSpawnTry = os.clock() + 20
			warn("[AdminServer] couldn't build the Admin Abuse giant: " .. tostring(model))
			return
		end
		model.Name = "AbuseGiant"
		local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then
			model:Destroy()
			return
		end
		root.Anchored = true
		model.PrimaryPart = root
		model:PivotTo(CFrame.new(0, ROOM_FLOOR + 6000, 0)) -- built far away, out of sight, until it appears with a bang
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		-- No state machine: it moves the hips up and down (the "sinking into the floor"), but the
		-- Humanoid stays so the clothes and hair (layered or not) render and animate.
		pcall(function()
			humanoid.EvaluateStateMachine = false
		end)
		-- Nothing can kill or break him: no death, no joints breaking, a (hidden) force field.
		humanoid.BreakJointsOnDeath = false
		pcall(function()
			humanoid.MaxHealth = 1e9
			humanoid.Health = 1e9
			humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		end)
		local shield = Instance.new("ForceField")
		shield.Visible = false
		shield.Parent = model
		model.Parent = workspace
		-- Applying the description once the model is in the world makes sure the hair and clothes load.
		pcall(function()
			humanoid:ApplyDescription(desc)
		end)
		model.DescendantAdded:Connect(function(d)
			if d:IsA("BasePart") then
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
				d.Massless = true
			end
		end)
		softenParts(model)
		if giant then
			model:Destroy() -- (another build finished first: never two giants)
			return
		end
		local baseScale = if heat then Show.HeatScale else Show.GiantScale
		pcall(function()
			model:ScaleTo(baseScale)
		end)
		task.wait(0.3)
		softenParts(model)
		if giant then
			model:Destroy()
			return
		end
		giant = model
		local scaleNow = baseScale

		-- Animations (Roblox's default R15 walk and idle). The emotes (wave, point, cheer) are NOT used: they
		-- move the hips, which on a giant is tens of studs (that was the "teleporting into the floor").
		local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator", humanoid)
		local function load(id: string, priority: Enum.AnimationPriority, looped: boolean): AnimationTrack?
			local track: AnimationTrack? = nil
			pcall(function()
				local anim = Instance.new("Animation")
				anim.AnimationId = "rbxassetid://" .. id
				track = animator:LoadAnimation(anim)
				if track then
					track.Priority = priority
					track.Looped = looped
				end
			end)
			return track
		end
		local walkTrack = load("507777826", Enum.AnimationPriority.Movement, true)
		local idleTrack = load("507766388", Enum.AnimationPriority.Idle, true)
		-- The idle animation puts the feet ~2x further below the hips than the walk does (his logs: feet 113
		-- studs under the floor each time he stopped), so he never uses it: standing still is the walk cycle
		-- frozen (speed 0), which is known to stand on the floor.
		if walkTrack then
			walkTrack:Play(0)
			walkTrack:AdjustSpeed(0)
		elseif idleTrack then
			idleTrack:Play()
		end
		task.wait(0.8) -- (still far away and out of sight) let the pose settle before measuring it

		local footL = model:FindFirstChild("LeftFoot") :: BasePart?
		local footR = model:FindFirstChild("RightFoot") :: BasePart?
		local low = math.min(lowestPoint(footL), lowestPoint(footR))
		local rootAbove = if low == math.huge then humanoid.HipHeight + root.Size.Y / 2 else root.Position.Y - low
		-- (a sane range: the hips' own height is the other way to know it)
		local hipAbove = humanoid.HipHeight + root.Size.Y / 2
		if hipAbove > 0 and (rootAbove < hipAbove * 0.6 or rootAbove > hipAbove * 1.6) then
			rootAbove = hipAbove
		end
		local rootAboveBase = rootAbove / baseScale
		local rootY = ROOM_FLOOR + rootAbove

		-- Name tag.
		local head = model:FindFirstChild("Head") :: BasePart?
		giantHead = head
		if head then
			local tag = Instance.new("BillboardGui")
			tag.Size = UDim2.fromOffset(360, 70)
			tag.StudsOffsetWorldSpace = Vector3.new(0, head.Size.Y * 1.2, 0)
			tag.AlwaysOnTop = true
			tag.MaxDistance = 6000
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundTransparency = 1
			label.Font = Enum.Font.LuckiestGuy
			label.TextScaled = true
			label.TextColor3 = Color3.fromRGB(255, 213, 74)
			label.TextStrokeTransparency = 0
			label.Text = Show.OwnerName
			label.Parent = tag
			tag.Parent = head
		end

		-- Arm animations: small runtime animations that pose only the upper arms (Motor6D properties can't be
		-- written from a script; animations can). If one can't be made the giant simply doesn't use it.
		-- R15 shoulder poses: raising an arm FORWARD is +X rotation; swinging it OUT to the side is +Z for the right
		-- arm and -Z for the left; the arms hang down at rest.
		local gestureTracks: { [string]: AnimationTrack } = {}
		local function Rx(deg: number): CFrame
			return CFrame.Angles(math.rad(deg), 0, 0)
		end
		local function Ry(deg: number): CFrame
			return CFrame.Angles(0, math.rad(deg), 0)
		end
		local function Rz(deg: number): CFrame
			return CFrame.Angles(0, 0, math.rad(deg))
		end
		-- frames: { { time, rightArmPose?, leftArmPose? } }
		local function makeAnim(name: string, frames: { { any } }, looped: boolean)
			local ok, err = pcall(function()
				local seq = Instance.new("KeyframeSequence")
				seq.Name = "Giant" .. name
				seq.Priority = Enum.AnimationPriority.Action2
				seq.Loop = looped
				for _, f in frames do
					local kf = Instance.new("Keyframe")
					kf.Time = f[1] :: number
					local rootPose = Instance.new("Pose")
					rootPose.Name = "HumanoidRootPart"
					rootPose.Weight = 0
					local lower = Instance.new("Pose")
					lower.Name = "LowerTorso"
					lower.Weight = 0
					local upper = Instance.new("Pose")
					upper.Name = "UpperTorso"
					upper.Weight = 0
					upper.Parent = lower
					lower.Parent = rootPose
					if f[2] then
						local r = Instance.new("Pose")
						r.Name = "RightUpperArm"
						r.CFrame = f[2] :: CFrame
						r.Weight = 1
						r.Parent = upper
					end
					if f[3] then
						local l = Instance.new("Pose")
						l.Name = "LeftUpperArm"
						l.CFrame = f[3] :: CFrame
						l.Weight = 1
						l.Parent = upper
					end
					rootPose.Parent = kf
					kf.Parent = seq
				end
				local anim = Instance.new("Animation")
				anim.AnimationId = KeyframeSequenceProvider:RegisterKeyframeSequence(seq)
				local track = animator:LoadAnimation(anim)
				track.Priority = Enum.AnimationPriority.Action2
				track.Looped = looped
				gestureTracks[name] = track
			end)
			if not ok then
				warn("[AbuseGiant] animation '" .. name .. "' unavailable: " .. tostring(err))
			end
		end
		local ID = CFrame.identity
		-- held poses (looping)
		makeAnim("point", { { 0, Rx(90) }, { 0.5, Rx(90) } }, true)
		-- (arms out to the sides, never up toward the sky: they used to go straight up and cross in front of his face)
		makeAnim("cheer", { { 0, Rz(100), Rz(-100) }, { 0.3, Rz(86), Rz(-86) }, { 0.6, Rz(100), Rz(-100) } }, true)
		makeAnim("wave", { { 0, Rz(98) }, { 0.25, Rz(118) }, { 0.5, Rz(98) } }, true)
		makeAnim("flex", { { 0, Rz(90), Rz(-90) }, { 0.5, Rz(90), Rz(-90) } }, true)
		-- the right hand straight up (a touch out to the side, clear of his head): the leaving beam comes out of it
		makeAnim("up", { { 0, Rz(172) }, { 0.5, Rz(172) } }, true)
		-- both arms out in front, turned in so the hands meet (he holds the glowing ball / the nuke there)
		makeAnim("charge", { { 0, Ry(14) * Rx(86), Ry(-14) * Rx(86) }, { 0.5, Ry(14) * Rx(86), Ry(-14) * Rx(86) } }, true)
		-- one-shots
		makeAnim("slamR", { { 0, ID }, { 0.4, Rz(135) }, { 0.7, Rz(60) * Rx(40) }, { 1.2, Rz(60) * Rx(40) }, { 1.5, ID } }, false)
		makeAnim("punchR", { { 0, ID }, { 0.15, Rx(-45) }, { 0.3, Rx(95) }, { 0.55, Rx(95) }, { 0.8, ID } }, false)
		makeAnim("punchL", { { 0, ID, ID }, { 0.15, nil, Rx(-45) }, { 0.3, nil, Rx(95) }, { 0.55, nil, Rx(95) }, { 0.8, nil, ID } }, false)
		local gestureNow: string? = nil
		local function setGesture(name: string?)
			if name == gestureNow then
				return
			end
			gestureNow = name
			for key, track in gestureTracks do
				pcall(function()
					if track.Looped then
						if key == name then
							if not track.IsPlaying then
								track:Play(0.3)
							end
						elseif track.IsPlaying then
							track:Stop(0.3)
						end
					end
				end)
			end
		end
		-- a one-shot arm move (slam, punch): the held pose is put away first
		local function playAnim(name: string)
			setGesture(nil)
			local track = gestureTracks[name]
			if track then
				pcall(function()
					track:Play(0.1)
				end)
			end
		end
		giantGesture = setGesture

		-- Debugging: ":abusedebug" turns on a floating readout and prints. DEBUG is checked every frame.
		local lastDebugPrint = 0
		local lastErr = 0
		local debugLabel: TextLabel? = nil
		local function debugStep(info: { [string]: any })
			if not giantDebug then
				if debugLabel then
					debugLabel.Parent:Destroy()
					debugLabel = nil
				end
				return
			end
			if head and not debugLabel then
				local gui = Instance.new("BillboardGui")
				gui.Size = UDim2.fromOffset(520, 150)
				gui.StudsOffsetWorldSpace = Vector3.new(0, head.Size.Y * 2.6, 0)
				gui.AlwaysOnTop = true
				gui.MaxDistance = 6000
				local l = Instance.new("TextLabel")
				l.Size = UDim2.fromScale(1, 1)
				l.BackgroundColor3 = Color3.new(0, 0, 0)
				l.BackgroundTransparency = 0.35
				l.TextColor3 = Color3.new(1, 1, 1)
				l.Font = Enum.Font.Code
				l.TextSize = 18
				l.Parent = gui
				gui.Parent = head
				debugLabel = l
			end
			local text = string.format(
				"state=%s walking=%s gesture=%s\nrootY=%.1f rootAbove=%.1f scale=%.1f\nlow=%.2f floor=%.1f leap=%.1f\nangle=%.0f",
				info.state, tostring(info.walking), tostring(gestureNow), info.rootY, info.rootAbove, info.scale, info.low, ROOM_FLOOR, info.leap, math.deg(info.angle) % 360
			)
			if debugLabel then
				debugLabel.Text = text
			end
			if os.clock() - lastDebugPrint > 1 then
				lastDebugPrint = os.clock()
				print("[AbuseGiant] " .. string.gsub(text, "\n", " | "))
			end
		end

		-- A circle round the table. Behind the dishwasher building (the north side) nobody in the lobby can see
		-- him, so he does nothing there: effects and the exit wait until he is back round on the visible side.
		local RADIUS = 300
		local angle = math.pi / 2
		local function hiddenNow(): boolean
			-- Not where the chairs are (east and west of the table: lasers would pass through them) and not
			-- directly behind the dishwasher / the chair at its end. South (spawn side) and the four corners are fine.
			local deg = math.deg(angle) % 360
			return deg > 335 or deg < 25 or (deg > 155 and deg < 205) or (deg > 250 and deg < 290)
		end
		local walkSpeed = 100
		local state, stateUntil = "arrive", os.clock() + 2.5
		local facing = Vector3.new(-1, 0, 0)
		local pos = Vector3.new(0, ROOM_FLOOR, TABLE_CENTER.Z + RADIUS)
		local acts = 0
		local BONUS = { "eyes", "eyes", "fireballs", "shockwave", "eyes", "fireballs", "barrage", "eyes", "shockwave", "fireballs", "eyes" }
		local flyHeight, flySpeed = 0, 60
		local rollAngle = 0 -- the somersault he does while he leaps
		local leapHeight = 0 -- how far he is above the floor while jumping over the obby
		local airborne = false -- the walk cycle is held while he is in the air
		local leanTarget, leanNow = 0, 0 -- (seated) how far he leans forward over the table, radians (negative = forward)
		local shiftTarget, shiftNow = Vector3.zero, Vector3.zero -- (seated) how far he has scooted toward what he is hitting
		local function face(dir: Vector3, dt: number)
			local flat = Vector3.new(dir.X, 0, dir.Z)
			if flat.Magnitude > 1e-3 then
				facing = facing:Lerp(flat.Unit, math.clamp(dt * 3, 0, 1))
			end
		end
		local function setWalking(on: boolean)
			if walkTrack then
				if not walkTrack.IsPlaying then
					walkTrack:Play(0.1)
				end
				-- A stride on a giant is huge: slow the cycle so his feet don't skate (0 = standing still).
				walkTrack:AdjustSpeed(if on then walkSpeed / (16 * scaleNow) * 1.5 else 0)
			end
		end
		-- Standing still (before he parks, or before he flies up and away): the walk cycle is stopped, so the legs go to
		-- their normal straight standing pose instead of being frozen mid-stride.
		local function standStill()
			if walkTrack then
				walkTrack:Stop(0.5)
			end
		end
		-- Sitting on the chair at the end of the table (behind the dishwasher), punching the leaderboard off the
		-- table from there, and standing up again. (Animation ids are Roblox's default R15 sit and tool-slash.)
		local sitTrack = load("2506281703", Enum.AnimationPriority.Action, true)
		local SIT_X, SIT_Z, SIT_TOP, SIT_LIFT = 0, -168, -43, 1.0 -- the chair; how far the hips sit above the seat (x scale)
		local MOVE_TIME = 1.8 -- (sitting down / standing up: he lowers into the chair, no leap)
		local lookYaw, nextLook, nextIdle = 0, 0, 0
		local aimDir: Vector3? = nil -- (chair show) which way he is turning to aim; his facing eases toward it
		local moveT0, moveFromPos, moveFromY = 0, pos, rootY
		giantSit = function()
			if state ~= "walk" then
				return
			end
			state = "sitleap"
			leanNow, shiftNow = 0, Vector3.zero
			say("my legs hurt. im sitting down. and then im going to have a look at that table.")
			moveT0, moveFromPos, moveFromY = os.clock(), pos, rootY
			-- the chair slides out of his way while he walks in, and back under him as he lowers
			LobbyBuilder.SlideGiantChair(150, 0.5)
			task.delay(MOVE_TIME * 0.95, function()
				LobbyBuilder.SlideGiantChair(0, 0.3)
			end)
			if walkTrack then
				walkTrack:Stop(0.4)
			end
			-- (he folds into the sitting pose while he is in the air, so there is no pop when he lands)
			if sitTrack then
				sitTrack:Play(0.6)
			end
			commandText(":sit")
		end
		giantStand = function()
			if state ~= "seated" then
				return
			end
			state = "standleap"
			moveT0, moveFromPos, moveFromY = os.clock(), pos, rootY
			-- the chair slides out from under him as he gets up, and comes back once he is past it
			LobbyBuilder.SlideGiantChair(150, 0.4)
			task.delay(MOVE_TIME * 0.7, function()
				LobbyBuilder.SlideGiantChair(0, 0.5)
			end)
			if sitTrack then
				sitTrack:Stop(0.7)
			end
			commandText(":stand")
		end
		-- The chair show: he walks round to the north side, sits on the chair at the end of the table and, without leaving
		-- it, shoots the Fastest Clean board, the soap shop, the pet stand and every egg, one at a time, from where he
		-- sits, then gets up again. (Each hit unanchors what is there and flings it the way the shot went.)
		local function impactAt(target: Vector3, radius: number, strong: boolean)
			Remote.AbuseBoom:FireAllClients(if strong then 3 else 2.2, target)
			harmlessBlast(target + Vector3.new(0, 10, 0), radius * 1.6)
			ringAt(target, radius * 12, 0.8, Color3.fromRGB(255, 220, 150))
		end
		-- A small white burst (so what is about to break is hidden for a moment) at a point.
		local function puffAt(point: Vector3, size: number)
			local puff = neonPart(Vector3.new(size * 0.4, size * 0.4, size * 0.4), Color3.new(1, 1, 1), Enum.PartType.Ball)
			puff.Position = point
			puff.Parent = workspace
			TweenService:Create(puff, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(size, size, size), Transparency = 1 }):Play()
			Debris:AddItem(puff, 0.45)
		end
		-- One shot. He stays on the chair (no leaning in, no scooting off it: the things he hits are far across the table now).
		-- He turns to the target, the arm on that side goes up toward it (the angle is worked out from the shoulder to the
		-- target), a glowing ball swells in his hand, and it is shot at the target. Returns when the shot arrives; the hit
		-- itself (the smash and the shake) is done by the caller. Any trouble with the arm or the effects is skipped, never
		-- left to stop the show.
		local function shoot(rightHand: boolean, target: Vector3, color: Color3, big: boolean)
			leanTarget, shiftTarget = 0, Vector3.zero
			local armPart = model:FindFirstChild(if rightHand then "RightUpperArm" else "LeftUpperArm") :: BasePart?
			local handPart = model:FindFirstChild(if rightHand then "RightHand" else "LeftHand") :: BasePart?
			local aimAt = target + Vector3.new(0, 4, 0)
			pcall(function()
				-- the arm: 0 = hanging down, 90 = level and forward (it is aimed along the target's direction, since he faces it)
				local angle = 90
				if armPart then
					local v = aimAt - armPart.Position
					angle = math.clamp(math.deg(math.atan2(Vector3.new(v.X, 0, v.Z).Magnitude, -v.Y)), 45, 150)
				end
				local name = if rightHand then "shootR" else "shootL"
				local frames = if rightHand
					then { { 0, ID }, { 0.35, Rx(angle) }, { 1.6, Rx(angle) }, { 2.1, ID } }
					else { { 0, ID, ID }, { 0.35, nil, Rx(angle) }, { 1.6, nil, Rx(angle) }, { 2.1, nil, ID } }
				makeAnim(name, frames, false)
				playAnim(name)
			end)
			task.wait(0.45)
			local from = if handPart then handPart.Position else Vector3.new(pos.X, rootY, pos.Z) + facing * scaleNow * 2
			local toward = (aimAt - from).Unit
			local muzzle = from + toward * scaleNow * 0.9
			-- the charge: a ball that swells in the hand
			local ball: Part? = nil
			pcall(function()
				local b = neonPart(Vector3.new(1, 1, 1), color, Enum.PartType.Ball)
				b.Position = muzzle
				b.Parent = workspace
				ball = b
				local size = scaleNow * (if big then 1.5 else 1.0)
				TweenService:Create(b, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(size, size, size) }):Play()
			end)
			task.wait(0.55)
			-- the shot: the ball flies to the target with a thin beam behind it, and a flash at the hand
			local travel = math.clamp((aimAt - muzzle).Magnitude / 320, 0.35, 0.9)
			pcall(function()
				puffAt(muzzle, scaleNow * 1.2)
				Remote.AbuseBoom:FireAllClients(1.2, muzzle)
				local len = (aimAt - muzzle).Magnitude
				local beam = neonPart(Vector3.new(scaleNow * 0.12, scaleNow * 0.12, len), color)
				beam.CFrame = CFrame.lookAt(muzzle, aimAt) * CFrame.new(0, 0, -len / 2)
				beam.Transparency = 0.3
				beam.Parent = workspace
				TweenService:Create(beam, TweenInfo.new(travel + 0.3), { Transparency = 1 }):Play()
				Debris:AddItem(beam, travel + 0.5)
				local b = ball
				if b then
					TweenService:Create(b, TweenInfo.new(travel, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = aimAt }):Play()
					Debris:AddItem(b, travel + 0.1)
				end
			end)
			task.wait(travel)
		end
		giantChairShow = function()
			if chairShowBusy then
				return
			end
			chairShowBusy = true
			task.spawn(function()
				local function alive(): boolean
					return giant == model and not leaving
				end
				-- to the north side, then up onto the chair
				for _ = 1, 200 do
					if not alive() then
						break
					end
					local d = math.deg(angle) % 360
					if state == "walk" and d > 255 and d < 285 and leapHeight < 5 then
						if giantSit then
							giantSit()
						end
						break
					end
					task.wait(0.2)
				end
				for _ = 1, 60 do
					if state == "seated" or not alive() then
						break
					end
					task.wait(0.2)
				end
				if alive() and state == "seated" then
					task.wait(0.6)
					local seat = Vector3.new(SIT_X, 0, SIT_Z)
					local function turnTo(target: Vector3)
						local flat = Vector3.new(target.X - seat.X, 0, target.Z - seat.Z)
						if flat.Magnitude > 1 then
							aimDir = flat.Unit
						end
					end
					-- ONE shot for each thing, one after the other: the Fastest Clean board, then the soap shop, the pet stand
					-- and every egg (shot with the hand on their side), each broken by its own hit
					local board = LobbyBuilder.Layout.TimesBoard
					local list = { { Name = "Fastest Clean board", Pos = board, Radius = 22 } }
					for _, t in LobbyBuilder.GetSmashTargets() do
						table.insert(list, t)
					end
					for i, t in list do
						if not alive() then
							break
						end
						turnTo(t.Pos)
						task.wait(0.8) -- (he turns in his seat to face it)
						local right = t.Pos.X < seat.X -- (facing +Z, his right hand is the -X side)
						shoot(right, t.Pos, PALETTE[(i - 1) % #PALETTE + 1], t.Name == "Fastest Clean board")
						if not alive() then
							break
						end
						local dir = Vector3.new(t.Pos.X - seat.X, 0, t.Pos.Z - seat.Z).Unit
						if t.Name == "Fastest Clean board" then
							punchLaunch = dir * 140 + Vector3.new(0, 60, 0)
							openHole(1)
							impactAt(t.Pos, 22, true)
						else
							LobbyBuilder.SmashProps(t.Pos, t.Radius, dir * 110 + Vector3.new(0, 40, 0))
							impactAt(t.Pos, 14, false)
						end
						task.wait(0.35)
					end
					leanTarget, shiftTarget = 0, Vector3.zero
					if alive() then
						task.wait(0.8)
						aimDir = Vector3.new(0, 0, 1)
						task.wait(0.8)
						if giantStand then
							giantStand()
						end
					end
				end
				leanTarget, shiftTarget = 0, Vector3.zero
				aimDir = nil
				chairShowBusy = false
			end)
		end

		-- Bigger (or smaller) over a few seconds; the floor lock follows by itself.
		giantRescale = function(target: number, seconds: number)
			task.spawn(function()
				local from, t0 = scaleNow, os.clock()
				while giant == model do
					local f = math.min(1, (os.clock() - t0) / seconds)
					scaleNow = from + (target - from) * f
					rootAbove = rootAboveBase * scaleNow
					pcall(function()
						model:ScaleTo(scaleNow)
					end)
					if f >= 1 then
						break
					end
					task.wait(0.1)
				end
			end)
		end
		-- The exit: he types a command, cuts a round hole in the ceiling with a laser, flies up through it,
		-- and the ceiling mends itself. (Nothing respawns him afterwards: `leaving` stays set.)
		giantLeave = function()
			if state == "leave" or state == "fly" then
				return
			end
			if hiddenNow() and state ~= "seated" then
				-- not while he is behind the dishwasher: nobody could see it
				task.spawn(function()
					for _ = 1, 40 do
						task.wait(0.5)
						if giant ~= model or not hiddenNow() then
							break
						end
					end
					if giant == model and giantLeave then
						giantLeave()
					end
				end)
				return
			end
			-- He leaves from the south side, in front of the couch where everyone can see: if he is somewhere else he
			-- walks round there first and stops.
			if state == "walk" then
				parkRequested = true
				task.spawn(function()
					for _ = 1, 160 do
						task.wait(0.25)
						if giant ~= model or state == "park" then
							break
						end
					end
					parkRequested = false
					if giant == model then
						if state == "walk" then
							state = "park" -- (took too long: leave from wherever he is)
							standStill()
						end
						if giantLeave then
							giantLeave()
						end
					end
				end)
				return
			end
			leaving = true
			state = "leave"
			standStill()
			setGesture("point")
			commandText(":noclip")
			local hx, hz = pos.X, pos.Z
			task.delay(2, function()
				if giant ~= model then
					return
				end
				-- his right hand goes straight up, and the beam comes out of the hand (it used to come out of his face)
				setGesture("up")
				task.wait(0.9)
				if giant ~= model then
					return
				end
				local handPart = model:FindFirstChild("RightHand") :: BasePart?
				local from = if handPart then handPart.Position + Vector3.new(0, scaleNow * 0.7, 0) else pos + Vector3.new(60, 200, 0)
				local target = Vector3.new(from.X, ROOF_Y, from.Z)
				local len = (target - from).Magnitude
				local laser = neonPart(Vector3.new(10, 10, len), Color3.fromRGB(255, 70, 60))
				laser.CFrame = CFrame.lookAt(from, target, Vector3.xAxis) * CFrame.new(0, 0, -len / 2)
				laser.Parent = workspace
				Debris:AddItem(laser, 2.5)
				TweenService:Create(laser, TweenInfo.new(2.5), { Transparency = 0.7 }):Play()
				-- the hole in the ceiling is round and centred between the beam and him, so he fits through it
				local holeX, holeZ = (hx + from.X) / 2, (hz + from.Z) / 2
				LobbyBuilder.OpenRoofHole(holeX, holeZ, 104)
				for i = 0, 3 do
					task.delay(i * 0.6, function()
						Remote.AbuseBoom:FireAllClients(2.4, Vector3.new(holeX, ROOF_Y, holeZ))
						harmlessBlast(Vector3.new(holeX + math.random(-50, 50), ROOF_Y - 8, holeZ + math.random(-50, 50)), 20)
					end)
				end
				task.delay(3, function()
					if giant ~= model then
						return
					end
					state = "fly"
					flyHeight = 0
					flySpeed = 40
					setGesture(nil)
					-- Iron Man: fire and sparks pour out of his feet and he is shot up through the hole
					for _, foot in { footL, footR } do
						if foot then
							local flame = Instance.new("ParticleEmitter")
							flame.Texture = "rbxasset://textures/particles/fire_main.dds"
							flame.Color = ColorSequence.new(Color3.fromRGB(190, 230, 255), Color3.fromRGB(255, 110, 30))
							flame.Lifetime = NumberRange.new(0.5, 1.1)
							flame.Speed = NumberRange.new(60, 120)
							flame.SpreadAngle = Vector2.new(12, 12)
							flame.EmissionDirection = Enum.NormalId.Bottom
							flame.Rate = 350
							flame.Size = NumberSequence.new(scaleNow * 0.4, 0)
							flame.Transparency = NumberSequence.new(0.1, 1)
							flame.LightEmission = 1
							flame.Parent = foot
							local sparks = Instance.new("ParticleEmitter")
							sparks.Texture = "rbxasset://textures/particles/sparkles_main.dds"
							sparks.Color = ColorSequence.new(Color3.fromRGB(255, 240, 160), Color3.fromRGB(255, 120, 40))
							sparks.Lifetime = NumberRange.new(0.8, 1.8)
							sparks.Speed = NumberRange.new(90, 220)
							sparks.SpreadAngle = Vector2.new(25, 25)
							sparks.EmissionDirection = Enum.NormalId.Bottom
							sparks.Rate = 250
							sparks.Size = NumberSequence.new(scaleNow * 0.22, 0)
							sparks.LightEmission = 1
							sparks.Parent = foot
							local light = Instance.new("PointLight")
							light.Color = Color3.fromRGB(255, 160, 70)
							light.Range = 120
							light.Brightness = 6
							light.Parent = foot
						end
					end
				end)
				-- Once he is through, the ceiling mends itself.
				task.delay(10, function()
					LobbyBuilder.HealRoof(7)
					boom(3, Vector3.new(hx, ROOF_Y - 200, hz))
				end)
			end)
		end

		local feetUp = { L = false, R = false }
		local lastStep = os.clock()
		local function footfall(foot: BasePart)
			lastStep = os.clock()
			boom(if heat then 1.8 else 1.4, Vector3.new(foot.Position.X, ROOM_FLOOR, foot.Position.Z))
		end
		local function smooth(x: number): number
			x = math.clamp(x, 0, 1)
			return x * x * (3 - 2 * x)
		end

		-- He is built early (the build takes a few seconds) and parked out of sight; he waits here until the show goes live, so he
		-- appears with the opening flash instead of a moment after it.
		local gateStart = os.clock()
		while ReplicatedStorage:GetAttribute("AbuseLive") ~= true and giant == model do
			local e = abuseEvent()
			if (not e or Config.Now() < e.Starts - 45) and os.clock() - gateStart > 3 then
				-- (the event moved or was cancelled: never leave him waiting)
				giant = nil
				giantHead = nil
				model:Destroy()
				return
			end
			task.wait(0.05)
		end
		if giant ~= model then
			return
		end
		-- The arrival: a flash and a blast where he stands, and only then is he there.
		local arrival = Vector3.new(pos.X, ROOM_FLOOR + 110, pos.Z)
		local flash = neonPart(Vector3.new(30, 30, 30), Color3.new(1, 1, 1), Enum.PartType.Ball)
		flash.Position = arrival
		flash.Parent = workspace
		TweenService:Create(flash, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(520, 520, 520), Transparency = 1 }):Play()
		Debris:AddItem(flash, 0.8)
		boom(3, Vector3.new(pos.X, ROOM_FLOOR, pos.Z))
		for i = 1, 3 do
			task.delay(i * 0.12, function()
				ringAt(Vector3.new(pos.X, ROOM_FLOOR, pos.Z), 500 + i * 300, 1.1, Color3.fromRGB(255, 220, 140))
				Remote.AbuseBoom:FireAllClients(3, arrival)
			end)
		end
		root.CFrame = CFrame.lookAt(Vector3.new(pos.X, rootY, pos.Z), Vector3.new(pos.X + facing.X, rootY, pos.Z + facing.Z))
		task.wait(0.05)
		-- (he moves the instant the flash goes off: no standing about in a frozen pose)
		state = "walk"
		setWalking(true)

		local function step(dt: number)
			local now = os.clock()
			walkSpeed = (if heat then 150 else 100) * scaleNow / Show.GiantScale
			if state == "arrive" and now >= stateUntil then
				state = "walk"
				setWalking(true)
			end
			if state == "walk" then
				angle += walkSpeed / RADIUS * dt
				pos = Vector3.new(math.cos(angle) * RADIUS, ROOM_FLOOR, TABLE_CENTER.Z + math.sin(angle) * RADIUS)
				face(Vector3.new(-math.sin(angle), 0, math.cos(angle)), dt)
				-- Where the circle runs through the obby (the south side) he leaps over ALL of it: up over a
				-- few degrees, flat above it, down again. A pure function of the angle (no easing to fight).
				local deg = math.deg(angle) % 360
				local wasLeap = leapHeight
				if LobbyBuilder.ObbyExists() and deg > 8 and deg < 120 then
					-- (never higher than the ceiling allows: his head, which swings round during the flips, stays under it)
					local ceilingRoom = ROOF_Y - 25 - 3.7 * scaleNow - rootY
					leapHeight = math.max(0, math.min(215, ceilingRoom)) * math.min(smooth((deg - 8) / 14), smooth((120 - deg) / 14))
					rollAngle = -math.pi * 4 * smooth((deg - 24) / 94) -- two forward flips over the obby, finished just as he lands (no walking steps tacked on)
				else
					leapHeight = 0
					rollAngle = 0
				end
				if parkRequested and deg > 84 and deg < 96 and leapHeight < 5 then
					state = "park"
					parkRequested = false
					standStill()
				end
				if wasLeap > 30 and leapHeight <= 30 and deg > 100 then
					boom(3, Vector3.new(pos.X, ROOM_FLOOR, pos.Z)) -- lands
				end
				-- the legs do not walk in the air: the stride is held while he is off the ground and goes on at the landing
				if leapHeight > 3 then
					if walkTrack and not airborne then
						airborne = true
						walkTrack:AdjustSpeed(0)
					end
				elseif airborne then
					airborne = false
					setWalking(true)
				end
			elseif state == "act" then
				face(TABLE_CENTER - pos, dt)
				if now >= stateUntil then
					state = "walk"
					setWalking(true)
					setGesture(nil)
				end
			elseif state == "sitleap" or state == "standleap" then
				local f = math.clamp((now - moveT0) / MOVE_TIME, 0, 1)
				local e = smooth(f)
				local toPos, toY
				if state == "sitleap" then
					toPos = Vector3.new(SIT_X, ROOM_FLOOR, SIT_Z)
					toY = SIT_TOP + SIT_LIFT * scaleNow
					face(Vector3.new(0, 0, 1), dt)
				else
					toPos = Vector3.new(0, ROOM_FLOOR, TABLE_CENTER.Z - RADIUS)
					toY = ROOM_FLOOR + rootAbove
					face(Vector3.new(1, 0, 0), dt)
				end
				pos = moveFromPos:Lerp(toPos, e)
				rootY = moveFromY + (toY - moveFromY) * e
				leapHeight = 0 -- (no jump: he simply lowers into the chair, or pushes himself up out of it)
				if f >= 1 then
					leapHeight = 0
					boom(1.2, Vector3.new(toPos.X, ROOM_FLOOR, toPos.Z))
					if state == "sitleap" then
						state = "seated"
						facing = Vector3.new(0, 0, 1)
					else
						angle = 3 * math.pi / 2
						state = "walk"
						setWalking(true)
					end
				end
			elseif state == "seated" then
				leanNow += (leanTarget - leanNow) * math.min(1, dt * 4)
				shiftNow = shiftNow:Lerp(shiftTarget, math.min(1, dt * 4))
				pos = Vector3.new(SIT_X, ROOM_FLOOR, SIT_Z) + shiftNow
				-- (he is not a statue: he sways a little, turns to look at different parts of the table, and every
				-- few seconds raises an arm)
				rootY = SIT_TOP + SIT_LIFT * scaleNow + math.sin(now * 1.3) * scaleNow * 0.04
				leapHeight = 0
				if chairShowBusy and aimDir then
					facing = facing:Lerp(aimDir, math.clamp(dt * 4, 0, 1))
					if facing.Magnitude > 1e-3 then
						facing = facing.Unit
					end
				end
				if not chairShowBusy then
					if now >= nextLook then
						nextLook = now + 2.2 + math.random() * 3
						lookYaw = (math.random() - 0.5) * math.rad(110)
					end
					local want = Vector3.new(math.sin(lookYaw), 0, math.cos(lookYaw))
					facing = facing:Lerp(want, math.clamp(dt * 1.6, 0, 1))
					if facing.Magnitude > 1e-3 then
						facing = facing.Unit
					end
					if now >= nextIdle and gestureNow == nil then
						nextIdle = now + 4 + math.random() * 4
						local g = ({ "point", "wave", "flex", "cheer" })[math.random(1, 4)]
						setGesture(g)
						task.delay(2.2, function()
							if giant == model and state == "seated" and gestureNow == g then
								setGesture(nil)
							end
						end)
					end
				end
			elseif state == "park" then
				face(TABLE_CENTER - pos, dt)
			elseif state == "leave" then
				face(TABLE_CENTER - pos, dt)
			elseif state == "fly" then
				flySpeed = math.min(460, flySpeed + 150 * dt)
				flyHeight += flySpeed * dt
				if flyHeight > ROOF_Y - ROOM_FLOOR + 330 then
					removeGiant()
					return
				end
			end
			if state ~= "fly" and state ~= "sitleap" and state ~= "standleap" and state ~= "seated" then
				-- Floor lock: the lowest sole sits on the floor, whatever the animation does. Gently (a low
				-- gain can't oscillate even if the feet lag a frame), with a dead zone and a speed limit.
				local low2 = math.min(lowestPoint(footL), lowestPoint(footR))
				if low2 ~= math.huge and leapHeight < 0.5 then
					local above = math.clamp(rootY - low2, rootAbove * 0.3, rootAbove * 4)
					local error = ROOM_FLOOR + above - rootY
					if math.abs(error) > scaleNow * 2 then
						rootY += error -- a pose change moved the feet a long way: snap, never slide through the floor
					elseif math.abs(error) > scaleNow * 0.02 then
						rootY += math.clamp(error * math.min(1, dt * 12), -scaleNow * dt * 8, scaleNow * dt * 8)
					end
				end
			end
			local y = if state == "fly" then rootY + flyHeight else rootY + leapHeight
			debugStep({ state = state, walking = walkTrack ~= nil and walkTrack.IsPlaying, rootY = rootY, rootAbove = rootAbove, scale = scaleNow, low = math.min(lowestPoint(footL), lowestPoint(footR)) - ROOM_FLOOR, leap = leapHeight, angle = angle })
			root.CFrame = CFrame.lookAt(Vector3.new(pos.X, y, pos.Z), Vector3.new(pos.X + facing.X, y, pos.Z + facing.Z)) * CFrame.Angles(if state == "walk" then rollAngle elseif state == "seated" then leanNow else 0, 0, 0)
			-- Footfalls: a foot that was lifted and is back on the floor is a step: boom.
			if state == "walk" and leapHeight < 6 then
				for side, foot in { L = footL, R = footR } do
					if foot then
						local h = lowestPoint(foot) - ROOM_FLOOR
						if h > scaleNow * 0.1 then
							feetUp[side] = true
						elseif feetUp[side] and h < scaleNow * 0.04 then
							feetUp[side] = false
							footfall(foot)
						end
					end
				end
				if now - lastStep > 1.6 then
					-- the animation isn't giving steps (not loaded?): keep the beat anyway
					footfall(root)
				end
			end
		end
		giantConn = RunService.Heartbeat:Connect(function(dt)
			local ok, err = pcall(step, dt)
			if not ok then
				-- (one bad frame must never freeze him: place him anyway, and say what happened)
				if os.clock() - lastErr > 2 then
					lastErr = os.clock()
					warn("[AbuseGiant] step failed: " .. tostring(err))
				end
				pcall(function()
					local y = rootY + leapHeight
					root.CFrame = CFrame.lookAt(Vector3.new(pos.X, y, pos.Z), Vector3.new(pos.X + facing.X, y, pos.Z + facing.Z))
				end)
			end
		end)
		-- The script stops him and raises an arm when he does something.
		playEffect = function(name: string, tries: number?)
			if name == "rest" then
				-- the next of the four vote events that has not happened yet
				local nextName: string? = nil
				for _, n in { "blackhole", "tornado", "fireworks", "meteors" } do
					if not onceDone[n] then
						nextName = n
						break
					end
				end
				if not nextName then
					return
				end
				name = nextName
			end
			if name == "winner" then
				name = chosenEffect
			end
			if name == "parksouth" then
				parkRequested = true
				return
			end
			if name == "chairshow" then
				if giantChairShow then
					giantChairShow()
				end
				return
			end
			local effect = FX[name]
			if not effect or giant ~= model or state == "leave" or state == "fly" then
				return
			end
			if ONCE[name] and onceDone[name] then
				return -- (each of the four vote events happens once)
			end
			if os.clock() < nukeQuietUntil and name ~= "nuke" then
				return -- (the nuke has the stage to itself)
			end
			local stageSeconds = STAGE[name]
			if stageSeconds then
				if os.clock() < stageBusyUntil or (chairShowBusy and name ~= "dishwasher") then
					-- a big event waits for the one before it (it is not dropped)
					if (tries or 0) < 60 then
						task.delay(0.6, playEffect, name, (tries or 0) + 1)
					end
					return
				end
			elseif os.clock() < stageBusyUntil or chairShowBusy then
				return -- (small effects keep out of the way of the big ones and of the chair show)
			end
			-- Where and when he may do it: away from the chairs and the dishwasher's back (the dishwasher smash
			-- itself needs him on the south side, in front of the couch, on the ground).
			local function canAct(): boolean
				if state == "walk" and leapHeight >= 5 then
					return false -- never start something in the middle of the somersault over the obby
				end
				if name == "dishwasher" or name == "nuke" then
					local deg = math.deg(angle) % 360
					return state == "walk" and deg > 80 and deg < 100 and leapHeight < 5
				end
				return state == "seated" or state == "park" or not hiddenNow()
			end
			if not canAct() then
				task.spawn(function()
					for _ = 1, 100 do
						task.wait(0.25)
						if giant ~= model or state == "leave" or state == "fly" or canAct() then
							break
						end
					end
					if giant == model and state ~= "leave" and state ~= "fly" and canAct() then
						playEffect(name)
					end
				end)
				return
			end
			if stageSeconds then
				stageBusyUntil = os.clock() + stageSeconds
			else
				stageBusyUntil = os.clock() + 5 -- (a small effect and its extra take a few seconds: a big one waits for them)
			end
			if ONCE[name] then
				onceDone[name] = true
			end
			acts += 1
			if state == "walk" then
				state, stateUntil = "act", os.clock() + (if name == "dishwasher" then 10 elseif name == "nuke" then 9 elseif name == "bombs" then 6 elseif heat then 3.6 else 4.6)
				setWalking(false)
			end
			-- an arm move that goes with it (the dishwasher and the nuke do their own)
			if name ~= "dishwasher" and name ~= "nuke" and (state == "act" or state == "seated" or state == "park") then
				-- (while he shoots lasers from his eyes his arms are held out to the sides, never in front of his face)
				local gesture = if BONUS[(acts - 1) % #BONUS + 1] == "eyes" then "flex" else ({ "point", "cheer", "wave", "flex" })[(acts - 1) % 4 + 1]
				setGesture(gesture)
				if state ~= "act" then
					task.delay(3.2, function()
						if giant == model and (state == "seated" or state == "park") and gestureNow == gesture then
							setGesture(nil)
						end
					end)
				end
			end
			commandText(nil)
			task.delay(0.8, effect)
			-- Something extra with the act, never the same thing twice running: lasers a couple of times, then
			-- fireballs, meteors and shockwaves, then lasers again with more beams, and so on.
			local bonus = BONUS[(acts - 1) % #BONUS + 1]
			if not stageSeconds and bonus ~= name and (state == "act" or state == "seated" or state == "park") and FX[bonus] then
				task.delay(0.4, function()
					if state == "act" or state == "seated" or state == "park" then
						if bonus == "eyes" then
							eyesFor = if state ~= "act" then 4 else math.max(1.2, stateUntil - os.clock() - 0.2)
						end
						FX[bonus]()
					end
				end)
			end
			if name == "meteors" or name == "blackhole" or name == "tornado" then
				Remote.AbuseBoom:FireAllClients(2.5, Vector3.new(0, 0, 0))
			end
		end
	end

	----------------------------------------------------------------- the power-ups
	-- Near the end of the warm-up EVERYONE in the server picks ONE temporary power-up for the rest of the show:
	-- fly, giant or speed (not a vote: each player simply gets the one they choose; "No thanks" is allowed). Each
	-- has an on/off button on screen (flying: the Flying chip, the others: the AbusePerk chip). They are all taken
	-- away when the show is put away or the player leaves (nothing is saved: coming back means normal), and flying
	-- is no advantage in the obby (it ignores checkpoints and the finish while flying).
	local PERK_SET = { fly = true, giant = true, speed = true }
	local PERK_GIANT_SCALE = 4
	local PERK_SPEED = 70
	local PICK_SECONDS = 40
	local offerId = 0
	local pendingOffer: { [Player]: number } = {}
	local perks: { [Player]: string } = {} -- chosen: "fly", "giant" or "speed"
	local perkOff: { [Player]: boolean } = {} -- switched off with its button (giant / speed)
	local baseSpeed: { [Player]: number } = {}
	local pickOpenUntil = 0
	local pickId = 0
	local function humanoidOf(plr: Player): Humanoid?
		return plr.Character and plr.Character:FindFirstChildOfClass("Humanoid")
	end
	-- Puts the player's perk on (or off) their current character.
	local function setPerkOn(plr: Player, on: boolean)
		local kind = perks[plr]
		if kind == "fly" then
			pcall(setFlying, plr, on)
		elseif kind == "giant" then
			pcall(setGiantScale, plr, if on then PERK_GIANT_SCALE else 1)
		elseif kind == "speed" then
			local hum = humanoidOf(plr)
			if hum then
				if on then
					baseSpeed[plr] = baseSpeed[plr] or hum.WalkSpeed
					hum.WalkSpeed = PERK_SPEED
				else
					hum.WalkSpeed = baseSpeed[plr] or 16
				end
			end
		end
		if kind == "giant" or kind == "speed" then
			Remote.AbusePerk:FireClient(plr, kind, on)
		end
	end
	local function takePerk(plr: Player)
		if not perks[plr] then
			return
		end
		setPerkOn(plr, false)
		Remote.AbusePerk:FireClient(plr, nil, false)
		perks[plr], perkOff[plr], baseSpeed[plr] = nil, nil, nil
	end
	Remote.AbusePerkToggle.OnServerEvent:Connect(function(plr: Player)
		local kind = perks[plr]
		if (kind ~= "giant" and kind ~= "speed") or ReplicatedStorage:GetAttribute("AbuseLive") ~= true then
			return
		end
		local off = not perkOff[plr]
		perkOff[plr] = if off then true else nil
		setPerkOn(plr, not off)
	end)
	Remote.AbuseOfferReply.OnServerEvent:Connect(function(plr: Player, id: any, choice: any)
		if not pendingOffer[plr] or pendingOffer[plr] ~= id then
			return
		end
		pendingOffer[plr] = nil
		if type(choice) == "string" and PERK_SET[choice] and plr.Parent == Players and ReplicatedStorage:GetAttribute("AbuseLive") == true then
			if perks[plr] then
				takePerk(plr)
			end
			perks[plr] = choice
			perkOff[plr] = nil
			setPerkOn(plr, true)
		end
	end)
	-- A respawn gives the character back to normal: put the chosen power-up on again.
	local function watchPerks(plr: Player)
		plr.CharacterAdded:Connect(function()
			task.wait(1)
			if perks[plr] and not perkOff[plr] and ReplicatedStorage:GetAttribute("AbuseLive") == true then
				setPerkOn(plr, true)
			end
		end)
	end
	local function sendPick(plr: Player, id: number, seconds: number)
		if plr:GetAttribute("AdminInvis") == true then
			return
		end
		pendingOffer[plr] = id
		Remote.AbuseOffer:FireClient(plr, id, seconds, "Pick ONE power-up for the rest of the event. It is yours, not a vote.")
	end
	Players.PlayerAdded:Connect(function(plr)
		watchPerks(plr)
		-- someone who joins while the pick is open gets the card too
		if os.clock() < pickOpenUntil and ReplicatedStorage:GetAttribute("AbuseLive") == true then
			task.delay(4, function()
				if plr.Parent == Players and os.clock() < pickOpenUntil then
					sendPick(plr, pickId, math.max(5, math.floor(pickOpenUntil - os.clock())))
				end
			end)
		end
	end)
	for _, plr in Players:GetPlayers() do
		watchPerks(plr)
	end
	Players.PlayerRemoving:Connect(function(plr)
		perks[plr], perkOff[plr], baseSpeed[plr], pendingOffer[plr] = nil, nil, nil, nil
	end)
	-- Everyone in this server gets the pick card.
	local function offerAll()
		offerId += 1
		pickId = offerId
		pickOpenUntil = os.clock() + PICK_SECONDS
		for _, plr in Players:GetPlayers() do
			sendPick(plr, pickId, PICK_SECONDS)
		end
		task.delay(PICK_SECONDS + 1, function()
			for plr, id in pendingOffer do
				if id == pickId then
					pendingOffer[plr] = nil
				end
			end
		end)
	end
	local function endPerks()
		for plr in perks do
			takePerk(plr)
		end
		pendingOffer = {}
		pickOpenUntil = 0
		Remote.AbuseOffer:FireAllClients(0, 0)
	end

	----------------------------------------------------------------- the clock
	-- Each step happens once per server, a second or so after its time comes (a server that joins late
	-- skips what is already over).
	local fired: { [string]: boolean } = {}
	local function once(key: string): boolean
		if fired[key] then
			return false
		end
		fired[key] = true
		return true
	end
	skipScript = function(seconds: number)
		local e = abuseEvent()
		if e then
			local tag = tostring(e.Starts)
			local from = Config.Now() - e.Starts + timeSkip
			for i, step in ipairs(Show.Script) do
				if step[1] >= from and step[1] < from + seconds then
					fired["s" .. i .. tag] = true
				end
			end
		end
		timeSkip += seconds
	end
	local obbyOpen = false
	local function setObby(open: boolean)
		if open ~= obbyOpen then
			obbyOpen = open
			ReplicatedStorage:SetAttribute("AbuseObbyOpen", open)
			if open then
				ReplicatedStorage:SetAttribute("AbuseObbyWinner", nil)
			end
		end
	end
	-- The room reacts to the heat: it goes dark and red (and comes back).
	local function roomHeat(on: boolean)
		if on then
			captureLighting()
			TweenService:Create(Lighting, TweenInfo.new(4), { ClockTime = 0.2, Brightness = 0.6, Ambient = Color3.fromRGB(70, 22, 26), OutdoorAmbient = Color3.fromRGB(96, 30, 30) }):Play()
		else
			restoreLighting()
		end
	end
	local function setMusic(which: string?)
		ReplicatedStorage:SetAttribute("AbuseMusic", which)
	end
	local function resetShow()
		leaving = false
		fadingOut = false
		onceDone, stageBusyUntil, nukeQuietUntil, timeSkip = {}, 0, 0, 0
		removeGiant()
		LobbyBuilder.SetBarriers(false)
		closeHoles()
		heat = false
		ReplicatedStorage:SetAttribute("AbuseHeat", false)
		ReplicatedStorage:SetAttribute("AbuseLive", false)
		setMusic(nil)
		roomHeat(false)
		setObby(false)
		LobbyBuilder.BreakObby()
		LobbyBuilder.SetRescue(false)
		restoreLighting()
		endPerks()
		if stopChase then
			stopChase()
		end
		LobbyBuilder.SetPadsEnabled(true)
		LobbyBuilder.SetPromptsEnabled(true)
		LobbyBuilder.SetUiEnabled(true)
		LobbyBuilder.RepairDishwasher()
		LobbyBuilder.RestoreProps()
		clearFx()
		-- When the fades are over, the net under all of it: every part of the lobby is checked against the picture taken at the start
		-- (anything still loose, hidden, moved or not solid goes back) and anyone out of bounds is put back at the spawn.
		task.delay(3, function()
			local ok, fixed = pcall(LobbyBuilder.HardReset)
			if ok and (fixed :: number) > 0 then
				print(string.format("[AdminServer] the end-of-show check put %d lobby parts back", fixed :: number))
			elseif not ok then
				warn("[AdminServer] HardReset failed: " .. tostring(fixed))
			end
		end)
	end
	-- The first player to finish the obby in each server wins a game pass, announced to that server.
	local obbyFirstFor: number? = nil
	ReplicatedStorage:GetAttributeChangedSignal("AbuseObbyFinish"):Connect(function()
		local info = tostring(ReplicatedStorage:GetAttribute("AbuseObbyFinish") or "")
		local name = string.match(info, "^(.-):")
		local e = abuseEvent()
		if not name or not e or not obbyOpen then
			return
		end
		task.spawn(function()
			-- ONE popup per finisher (the gems were already added): the first finisher in any server also
			-- wins a game pass, announced once in the speech box (no banner on top of everything).
			local plr = Players:FindFirstChild(name)
			local gems = Config.Obby.ShowGems
			local first = obbyFirstFor ~= e.Starts -- the first finisher IN THIS SERVER (each server has its own winner)
			obbyFirstFor = e.Starts
			if not (plr and plr:IsA("Player")) then
				if first then
					say(name .. " finished the obby first and wins a game pass. well done.")
				end
				return
			end
			if first then
				local passes = DataService.GetPasses and DataService.GetPasses(plr) or {}
				local free = {}
				for _, pass in ipairs(Config.GamePasses) do
					if passes[pass.Key] ~= true and plr:GetAttribute(gamepassAttribute(pass.Key)) ~= true then
						table.insert(free, pass)
					end
				end
				if #free > 0 then
					local pass = free[math.random(1, #free)]
					setGamepassGrant(plr, pass, true, false)
					celebrate(plr, "First to finish!", string.format("You won %s and %d Gems for finishing the obby first!", pass.Name, gems), pass.Icon)
				else
					DataService.AddGems(plr, 100, "ShowPrize")
					celebrate(plr, "First to finish!", string.format("You finished first! %d Gems, plus 100 more because you own every pass.", gems), "@Gem")
				end
				say(name .. " finished the obby first and wins a game pass. well done.")
			else
				celebrate(plr, "You beat the obby!", string.format("You got %d Gems!", gems), "@Gem")
			end
		end)
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			local e = abuseEvent()
			if not e then
				continue
			end
			local t = Config.Now() - e.Starts + timeSkip -- negative before the start (timeSkip: the pet hunt ended early)
			local tag = tostring(e.Starts)
			if showEnded[tag] then
				continue -- (this show has been put away: it never starts again, even though the clock, minus the skipped seconds, says it still could)
			end
			if t >= 0 and t < Show.ShowSeconds then
				local wasHeat = heat
				heat = t >= Show.HeatAt and not fadingOut
				if once("live" .. tag) then
					ReplicatedStorage:SetAttribute("AbuseLive", true)
					LobbyBuilder.Snapshot() -- (the lobby as it is now: the end of the show puts back anything the effects left changed)
					LobbyBuilder.SetBarriers(true) -- no invisible walls for the whole show
					LobbyBuilder.SetRescue(true)
					-- party pads and the lobby's prompts and labels are off for the whole show; anyone inside a pad is
					-- walked out of it
					LobbyBuilder.SetPadsEnabled(false)
					LobbyBuilder.SetPromptsEnabled(false)
					for _, plr in Players:GetPlayers() do
						pcall(function()
							if PartyService.IsInParty(plr) then
								PartyService.RemovePlayer(plr)
							end
						end)
					end
					setMusic("Warm")
				end
				if heat ~= wasHeat then
					ReplicatedStorage:SetAttribute("AbuseHeat", heat)
					roomHeat(heat)
					setMusic(if heat then "Heat" else "Warm")
					if giantRescale then
						giantRescale(if heat then Show.HeatScale else Show.GiantScale, 3)
					end
				end
				-- Anyone still in a run goes back to the lobby.
				for _, plr in ipairs(Players:GetPlayers()) do
					if RoundService.IsInRun(plr) then
						RoundService.RemoveFromRun(plr)
					end
				end
				if once("intro" .. tag) then
					-- boom, boom, boom: the lobby shakes before he arrives
					for i = 0, 2 do
						task.delay(i * 0.9, function()
							Remote.AbuseBoom:FireAllClients(3, Vector3.new(0, ROOM_FLOOR, 330))
						end)
					end
				end
				if not RunServers.IsRunServer and t >= 3 and not leaving then
					task.spawn(spawnGiant)
				end
				-- The script, in order.
				for i, step in ipairs(Show.Script) do
					if t >= step[1] and t < step[1] + 20 and once("s" .. i .. tag) then
						local kind = step[2]
						if kind == "say" then
							say(step[3])
						elseif kind == "count" then
							-- "the obby comes down in 5... 4... 3... 2... 1...": ONE speech box that grows a number a second
							local lead = tostring(step[4] or "")
							task.spawn(function()
								for n = step[3], 1, -1 do
									if n == step[3] then
										say(lead .. n .. "...")
									else
										say(" " .. n .. "...", true)
									end
									task.wait(1)
								end
							end)
						elseif kind == "attack" then
							if step[3] == "perkpick" then
								offerAll()
							else
								playEffect(step[3])
							end
						elseif kind == "round" then
							if claim("round" .. step[3] .. ":" .. tag) then
								runRound(Show.Rounds[step[3]])
							end
						elseif kind == "hole" then
							openHole(step[3])
						elseif kind == "heal" then
							closeHoles()
						elseif kind == "restore" then
							-- THE FINALE: everything fades back together over 10 seconds (light, the red of the heat, the
							-- rainbow, the table, the dishwasher), and then the show says it is done.
							fadingOut = true
							ReplicatedStorage:SetAttribute("AbuseHeat", false)
							restoreLighting(10)
							closeHoles(10)
							LobbyBuilder.RepairDishwasher(10)
							LobbyBuilder.RestoreProps()
						elseif kind == "thanks" then
							-- everyone online gets something for staying (this server's players; every server runs this)
							for _, plr in ipairs(Players:GetPlayers()) do
								if DataService.AddGems(plr, Show.ThanksGems, "ShowThanks") then
									celebrate(plr, "Thanks for coming!", string.format("Everyone who stayed got %d Gems. See you in Chapter 4!", Show.ThanksGems), "@Gem")
								end
							end
						elseif kind == "obby" then
							if step[3] then
								LobbyBuilder.OpenObby()
								-- every client turns its camera to the obby while it builds itself (AdminClient buildShot)
								ReplicatedStorage:SetAttribute("AbuseObbyBuild", (tonumber(ReplicatedStorage:GetAttribute("AbuseObbyBuild")) or 0) + 1)
								task.delay(10, function()
									setObby(true)
								end)
							else
								setObby(false)
								LobbyBuilder.BreakObby()
							end
						elseif kind == "leave" then
							if giantLeave then
								giantLeave()
							end
							-- failsafe: whatever happens, he is gone a little later
							task.delay(16, function()
								removeGiant()
							end)
						end
					end
				end
			elseif t < 0 and t > -30 then
				-- The 30 seconds before the start: he is built now (hidden) so that he is there the moment the show begins.
				if not RunServers.IsRunServer and not leaving then
					task.spawn(spawnGiant)
				end
			elseif t >= Show.ShowSeconds then
				-- The show is over: everything is put away, and rounds can start again.
				if once("end" .. tag) then
					showEnded[tag] = true
					local wasLocal = localShow
					resetShow()
					localShow = false
					local isTest = realStarts ~= nil and e.Starts ~= realStarts
					if not isTest or RunService:IsStudio() then
						-- The real show is over (or a test in Studio, to see it): the Next Event sign moves on to the next event
						-- (Chapter 4) in this session. Nothing is saved: a restart is back to the real schedule.
						handlers.AbuseSchedule({ Starts = e.Starts, Ends = math.min(e.Ends, Config.Now()) })
					elseif wasLocal and realStarts then
						-- a test in the real game is over: this server goes back to the real event time (the real event has
						-- not happened, so the sign keeps counting down to it)
						handlers.AbuseSchedule({ Starts = realStarts, Ends = realEnds })
					end
				end
			end
		end
	end)

	-- :notifytest (Studio tab): sends the "daily reward ready" notification to you right now and tells you how
	-- it went (secret found? HTTP on? are you opted in to notifications for this experience?).
	Commands.notifytest = function(admin, _text)
		task.spawn(function()
			local result = tostring(DailyNotify.TestNow(admin) or "No answer.")
			sendFeedback(admin, "Notification test: " .. result, not string.find(result, "^Sent"))
		end)
	end

	local function runAbuseShow(admin, text, localOnly: boolean)
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
		if claimMap and not localOnly then
			-- steps from an earlier try would otherwise count as already done
			pcall(function()
				for key in Show.Rounds do
					claimMap:RemoveAsync("round" .. key .. ":" .. tostring(starts))
				end
			end)
		end
		resetShow() -- (this server) put away anything from an earlier try
		localShow = localOnly and arg ~= "reset"
		local ok = publish({ Kind = "AbuseSchedule", Starts = starts, Ends = ends })
		sendFeedback(admin, if arg == "reset" then "Admin Abuse is back on its real time." else string.format("Admin Abuse show starts in %s%s. Rounds are paused from now.", Format.Time and Format.Time(starts - Config.Now()) or tostring(math.floor((starts - Config.Now()) / 60)) .. " min", if localOnly then " (this server only: a local test)" elseif ok then " (every server)" else " (this server only)"), false)
		logCommand(admin, if localOnly then "abuselocal" else "abuseshow", nil, arg, admin.Name .. " set the Admin Abuse show: " .. tostring(arg))
	end
	Commands.abuseshow = function(admin, text)
		runAbuseShow(admin, text, false)
	end
	Commands.abuselocal = function(admin, text)
		runAbuseShow(admin, text, true)
	end

	-- :privatelobby [join|new]: a lobby only the owner can enter. It is a reserved server (nobody can reach it
	-- without its access code, which is only kept for the owner); and the first player in it must be the owner,
	-- anyone else who somehow arrives is kicked. Teleports only work in the published game.
	local privateMap = nil
	pcall(function()
		privateMap = game:GetService("MemoryStoreService"):GetHashMap("RinseCycle_PrivateLobbies")
	end)
	Commands.privatelobby = function(admin, text)
		if RunService:IsStudio() then
			sendFeedback(admin, "Private lobbies only work in the published game (Studio can't teleport). Use the Local Admin Abuse test here instead.", true)
			return
		end
		local arg = string.lower(text:match("^%s*(%S*)") or "")
		local key = tostring(admin.UserId)
		local ok, err = pcall(function()
			local code = nil
			if arg ~= "new" and privateMap then
				code = privateMap:GetAsync(key)
			end
			if not code then
				code = TeleportService:ReserveServer(game.PlaceId)
				if privateMap then
					privateMap:SetAsync(key, code, 3888000)
				end
			end
			local options = Instance.new("TeleportOptions")
			options.ReservedServerAccessCode = code
			options:SetTeleportData({ PrivateOwner = admin.UserId })
			TeleportService:TeleportAsync(game.PlaceId, { admin }, options)
		end)
		if ok then
			sendFeedback(admin, "Taking you to your private lobby...", false)
		else
			sendFeedback(admin, "Couldn't open the private lobby: " .. tostring(err), true)
		end
		logCommand(admin, "privatelobby", nil, arg, admin.Name .. " opened their private lobby")
	end

	-- :resetfirstrun (Studio tab): your account goes back to a brand-new player's first run, to try the tutorial and the
	-- level 1 cutscene again: tutorial not done, run count 0, story chapters unseen.
	Commands.resetfirstrun = function(admin, _text)
		if DataService.ResetFirstRun(admin) then
			sendFeedback(admin, "Reset: the tutorial and the level 1 cutscene will play again on your next run (start one from a party pad).", false)
		else
			sendFeedback(admin, "Your data is still loading.", true)
		end
		logCommand(admin, "resetfirstrun", nil, "", admin.Name .. " reset their first-run state")
	end

	-- :clubreset (Studio tab): no wait after leaving a club, no kick bans and no pending "you were kicked" message, to test
	-- joining / leaving / being kicked without waiting 24 hours.
	Commands.clubreset = function(admin, _text)
		if DataService.ResetClubCooldowns(admin) then
			sendFeedback(admin, "Reset: you can join or make a club right now and no club has you banned.", false)
		else
			sendFeedback(admin, "Your data is still loading.", true)
		end
		logCommand(admin, "clubreset", nil, "", admin.Name .. " reset their club waiting times")
	end

	Commands.abusedebug = function(admin, _text)
		giantDebug = not giantDebug
		sendFeedback(admin, if giantDebug then "Giant debug is ON (readout above him, prints in Output)." else "Giant debug is off.", false)
	end

	-- :abusefx <name> (Studio tab): try one piece of the show on its own (it spawns the giant if needed).
	local FX_NAMES = { "beam", "meteors", "lightning", "shockwave", "barrage", "fireworks", "laser", "blackhole", "tornado", "ufo", "disco", "fountains", "eyes", "fireballs", "dishwasher", "bombs", "chairshow", "nuke", "petchase", "tablebreak" }
	Commands.abusefx = function(admin, text)
		local arg = string.lower(text:match("^%s*(%S*)") or "")
		local function needGiant(): boolean
			if giant then
				return true
			end
			spawnFailures = 0
			task.spawn(spawnGiant)
			for _ = 1, 40 do
				if giant then
					return true
				end
				task.wait(0.5)
			end
			return giant ~= nil
		end
		task.spawn(function()
			if arg == "all" then
				if not needGiant() then
					sendFeedback(admin, "Couldn't build the giant (see the output).", true)
					return
				end
				sendFeedback(admin, "Playing every effect, 9 seconds apart: " .. table.concat(FX_NAMES, ", "), false)
				for _, name in ipairs(FX_NAMES) do
					say("[test] " .. name)
					playEffect(name)
					task.wait(9)
				end
			elseif table.find(FX_NAMES, arg) then
				if needGiant() then
					onceDone[arg] = nil -- (a test may repeat the one-time events)
					stageBusyUntil = 0
					playEffect(arg)
					sendFeedback(admin, "Playing: " .. arg, false)
				end
			elseif arg == "hole1" or arg == "hole2" then
				openHole(tonumber(string.sub(arg, 5)) :: number)
				sendFeedback(admin, "Opened " .. arg .. ". (:abusefx heal puts it back.)", false)
			elseif arg == "heal" then
				closeHoles()
				sendFeedback(admin, "The holes are closing.", false)
			elseif arg == "obby" then
				LobbyBuilder.OpenObby()
				task.delay(10, function()
					setObby(true)
					LobbyBuilder.SetRescue(true)
				end)
				sendFeedback(admin, "Building the obby (about 10 seconds).", false)
			elseif arg == "obbybreak" then
				setObby(false)
				LobbyBuilder.BreakObby()
				sendFeedback(admin, "Smashing the obby.", false)
			elseif arg == "heat" or arg == "calm" then
				heat = arg == "heat"
				ReplicatedStorage:SetAttribute("AbuseHeat", heat)
				roomHeat(heat)
				if giantRescale then
					giantRescale(if heat then Show.HeatScale else Show.GiantScale, 3)
				end
				sendFeedback(admin, if heat then "Heat is up (:abusefx calm to cool it)." else "Back to calm.", false)
			elseif arg == "leave" then
				if needGiant() and giantLeave then
					giantLeave()
					sendFeedback(admin, "He is leaving through the roof.", false)
				end
			elseif arg == "off" then
				resetShow()
				sendFeedback(admin, "Everything put away.", false)
			else
				sendFeedback(admin, "Usage: :abusefx [all | " .. table.concat(FX_NAMES, " | ") .. " | hole1 | hole2 | heal | obby | obbybreak | heat | calm | leave | off]", true)
			end
		end)
	end
	end)()
end
