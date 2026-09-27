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

print("[AdminServer] Script started")

-- Looked up this early (rather than down in the "Give" section where the
-- rest of :give's logic lives) because GetAdminInfo's response, just
-- below, needs the current item names for the client's :give
-- autocomplete - referencing it from there would be a forward reference
-- to a local that doesn't exist yet in Lua's lexical scoping. Create
-- this folder ONCE in Studio's EDIT mode (not while Play-testing) and
-- leave your giveable Tools in it there - anything only added during a
-- Play session doesn't get saved with the place and would need to be
-- re-added every single time the server restarts.
local giveableItemsFolder = ServerStorage:FindFirstChild("AdminGiveableItems")
if not giveableItemsFolder then
	giveableItemsFolder = Instance.new("Folder")
	giveableItemsFolder.Name = "AdminGiveableItems"
	giveableItemsFolder.Parent = ServerStorage
	print("[AdminServer] Created ServerStorage.AdminGiveableItems - empty until Tools are placed there (in EDIT mode, not Play mode) for :give to hand out")
end

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
	warn("[AdminServer] DataStore '" .. name .. "' unavailable (" .. tostring(store) .. ") - bans, warnings, mutes and logs won't save this session")
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
	"viewinv", "clearinv",
	"fly", "give",
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
local STUDIO_ONLY_COMMANDS = {
	"setadminrank", "wipelogs", "givegamepass", "removegamepass", "daily",
	"finishrun", "givecoins", "givepet", "unlockall", "setrebirths",
}

-- Commands FOUNDER alone gets, on top of everything Developer has.
--
-- Founder and Developer otherwise share one list (both are ALL_COMMANDS
-- below), so a genuinely Founder-only command needs its own. :setbubbles and
-- :setgems hand out the game's currencies - that's not
-- a Studio tool, it's a live one, but it's also not something a
-- Developer should be able to do on a whim.
local FOUNDER_ONLY_COMMANDS = { "setbubbles", "setgems" }

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

local STUDIO_TIER_VALUES = { "Moderator", "Admin", "Developer", "Founder" }
-- The "Admin" tier's own list, kept separate so both it and the smaller
-- Moderator list can each name only the commands they actually get,
-- rather than every tier needing to redundantly re-list Moderator's
-- commands too.
local ADMIN_TIER_COMMANDS = {
	"kick", "mute", "tempmute", "warn", "msg", "goto", "ban", "tempban",
	"freeze", "unfreeze", "bring", "warnlist", "banlist", "mutelist",
	"setrank", "promote", "demote", "announce", "cmdlogs", "playerlogs",
	"kill", "jail", "god", "respawn",
	"spectate", "controlplayer", "invis",
	"viewinv", "clearinv",
}
local TIER_COMMANDS = {
	Moderator = {"kick", "mute", "tempmute", "warn", "msg", "goto", "mutelist"},
	-- :fly/:give held back from Admin - these are sandbox/testing
	-- utilities (free flight, handing out items - including the
	-- "btools" build-tools item, given out via :give like anything else
	-- in ServerStorage.AdminGiveableItems) rather than moderation tools,
	-- so they stay Developer+ only, same tier split the game already
	-- draws elsewhere (Admin gets full moderation power, Developer gets
	-- that plus everything else).
	Admin = ADMIN_TIER_COMMANDS,
	Developer = ALL_COMMANDS,
	-- Everything Developer has, plus FOUNDER_ONLY_COMMANDS. Built as its
	-- own list rather than pointing at ALL_COMMANDS: the two tiers used
	-- to share that exact table, so appending to it for Founder would
	-- silently hand the same command to Developer as well.
	Founder = (function()
		local list = table.clone(ALL_COMMANDS)
		for _, name in ipairs(FOUNDER_ONLY_COMMANDS) do
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

	-- Only the owner, by UserId. Everyone else has no tier at all (so no panel and no commands).
	if isOwnerAccount(player) then return "Founder" end
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
local GetAdminInfo = Instance.new("RemoteFunction")
GetAdminInfo.Name = "GetAdminInfo"
GetAdminInfo.Parent = ReplicatedStorage

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
		warn("[AdminServer] Failed to load gamepass grants for " .. player.Name .. ": " .. tostring(value))
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
			warn("[AdminServer] Failed to save gamepass grants for " .. player.Name .. ": " .. tostring(err))
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

GetAdminInfo.OnServerInvoke = function(player)
	local info = tierInfo(getPlayerTier(player), player)
	-- Prints the name the server actually sees alongside the verdict, so
	-- a missing Remove button can be diagnosed from the Output window
	-- rather than guessed at - the usual cause is the test client not
	-- being signed in under the owner's username at all.
	print(string.format(
		"[AdminServer] GetAdminInfo for '%s' -> tier %s, canRemoveLogs %s",
		player.Name, tostring(info.Tier), tostring(info.CanRemoveLogs)
	))
	return info
end

local AdminCommand = Instance.new("RemoteEvent")
AdminCommand.Name = "AdminCommand"
AdminCommand.Parent = ReplicatedStorage

-- Generic "notice" popup - covers the warn popup, the mute popup, and
-- the freeze popup, all rendered by the same one component client-side
-- (title + body + optional footnote line + an OK button) rather than
-- three near-identical UI builders.
local AdminNotice = Instance.new("RemoteEvent")
AdminNotice.Name = "AdminNotice"
AdminNotice.Parent = ReplicatedStorage

local AdminFeedback = Instance.new("RemoteEvent")
AdminFeedback.Name = "AdminFeedback"
AdminFeedback.Parent = ReplicatedStorage

-- Per-user warnings detail (list of individual warnings + a Remove
-- button per one) - reached either from :warnlist's master list
-- ("Modify" on a row fires AdminViewWarnings) or refreshed in place
-- after a removal.
local AdminWarningsList = Instance.new("RemoteEvent")
AdminWarningsList.Name = "AdminWarningsList"
AdminWarningsList.Parent = ReplicatedStorage

local AdminViewWarnings = Instance.new("RemoteEvent")
AdminViewWarnings.Name = "AdminViewWarnings"
AdminViewWarnings.Parent = ReplicatedStorage

local AdminRemoveWarning = Instance.new("RemoteEvent")
AdminRemoveWarning.Name = "AdminRemoveWarning"
AdminRemoveWarning.Parent = ReplicatedStorage

-- Master lists (:banlist/:mutelist/:warnlist) - every user ever
-- punished, online or not, each row's "Modify" button opening either
-- the ban/mute detail-edit popup or (for warnlist) the per-user
-- warnings detail above.
local AdminBanList = Instance.new("RemoteEvent")
AdminBanList.Name = "AdminBanList"
AdminBanList.Parent = ReplicatedStorage

local AdminMuteList = Instance.new("RemoteEvent")
AdminMuteList.Name = "AdminMuteList"
AdminMuteList.Parent = ReplicatedStorage

local AdminWarnList = Instance.new("RemoteEvent")
AdminWarnList.Name = "AdminWarnList"
AdminWarnList.Parent = ReplicatedStorage

-- Single unified remote for editing a ban or mute record - action is
-- "remove" (unban/unmute), "reason" (value = new reason string), or
-- "duration" (value = new duration in seconds, or nil for permanent).
-- One remote for both punishment types and all three actions, rather
-- than a growing pile of near-identical single-purpose ones.
local AdminModifyPunishment = Instance.new("RemoteEvent")
AdminModifyPunishment.Name = "AdminModifyPunishment"
AdminModifyPunishment.Parent = ReplicatedStorage

-- Shared by :cmdlogs (every entry) and :playerlogs (filtered to one
-- admin) - same list popup component, just different title/entries.
local AdminLogsList = Instance.new("RemoteEvent")
AdminLogsList.Name = "AdminLogsList"
AdminLogsList.Parent = ReplicatedStorage

-- Tells one client to black its screen out and fade back in. Fired at a
-- player the server is teleporting a long way without them asking for it
-- (:jail and the release from it), so the teleport itself and the
-- lighting rebuild that follows it both happen behind a cover rather
-- than on screen. AdminClient.lua's AdminScreenFade handler has the
-- full reasoning.
local AdminScreenFade = Instance.new("RemoteEvent")
AdminScreenFade.Name = "AdminScreenFade"
AdminScreenFade.Parent = ReplicatedStorage

-- Owner-only deletion of a single command-log entry, fired from the log
-- detail popup. See isOwner above for why this isn't tier-gated.
local AdminRemoveLogEntry = Instance.new("RemoteEvent")
AdminRemoveLogEntry.Name = "AdminRemoveLogEntry"
AdminRemoveLogEntry.Parent = ReplicatedStorage

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

-- Separate from AdminNotice - an announcement is a top-of-screen banner
-- to everyone, not the same centered/blurred single-recipient popup
-- :warn/:mute/:freeze/:msg use.
local AdminAnnouncement = Instance.new("RemoteEvent")
AdminAnnouncement.Name = "AdminAnnouncement"
AdminAnnouncement.Parent = ReplicatedStorage

-- Separate from the one-shot AdminNotice popup above - that only tells a
-- frozen player once, at the moment it happens. This instead carries the
-- ongoing true/false frozen state itself, so the client can show a
-- persistent "YOU ARE FROZEN" indicator for as long as it stays true,
-- not just a popup that can be dismissed and forgotten while still
-- actually frozen.
local AdminFreezeStatus = Instance.new("RemoteEvent")
AdminFreezeStatus.Name = "AdminFreezeStatus"
AdminFreezeStatus.Parent = ReplicatedStorage

-- Same idea as AdminFreezeStatus above, but for mutes - carries the
-- ongoing muted/not-muted state (plus ExpiresAt, or nil for permanent) so
-- the client can show a persistent "muted for/permanently muted" bottom
-- indicator for as long as it's actually true, not just a one-shot popup
-- at the moment :mute/:tempmute happens.
local AdminMuteStatus = Instance.new("RemoteEvent")
AdminMuteStatus.Name = "AdminMuteStatus"
AdminMuteStatus.Parent = ReplicatedStorage

-- Fired to the TARGET's own client (not the admin's) with true/false -
-- :fly can be aimed at anyone, not just staff, so this has to work for
-- every player's client, not just inside the staff-only admin panel.
local AdminSetFlying = Instance.new("RemoteEvent")
AdminSetFlying.Name = "AdminSetFlying"
AdminSetFlying.Parent = ReplicatedStorage

-- Fired to the ADMIN's own client with either a target Player (start
-- spectating them) or nil (stop) - only ever changes the admin's OWN
-- camera/character, never the target's. Stopping is no longer a typed
-- :unspectate command - it's the client's own "Stop Spectating" button,
-- which fires AdminStopSpectating below instead.
local AdminSpectate = Instance.new("RemoteEvent")
AdminSpectate.Name = "AdminSpectate"
AdminSpectate.Parent = ReplicatedStorage

-- Fired FROM the admin's own client - the "Stop Spectating" button shown
-- alongside the "You are currently spectating: X" indicator.
local AdminStopSpectating = Instance.new("RemoteEvent")
AdminStopSpectating.Name = "AdminStopSpectating"
AdminStopSpectating.Parent = ReplicatedStorage

-- Fired to the ADMIN's own client with either a target Player (start
-- controlling them - camera lock + WASD forwarding) or nil (stop), same
-- shape as AdminSpectate above but for :controlplayer.
local AdminControlPlayer = Instance.new("RemoteEvent")
AdminControlPlayer.Name = "AdminControlPlayer"
AdminControlPlayer.Parent = ReplicatedStorage

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
local AdminStopControlling = Instance.new("RemoteEvent")
AdminStopControlling.Name = "AdminStopControlling"
AdminStopControlling.Parent = ReplicatedStorage

-- Fired to the TARGET's own client with true/false - drives their
-- persistent "you are currently being controlled by staff" indicator,
-- same idea as AdminFreezeStatus/AdminMuteStatus but worded for this.
local AdminControlTargetStatus = Instance.new("RemoteEvent")
AdminControlTargetStatus.Name = "AdminControlTargetStatus"
AdminControlTargetStatus.Parent = ReplicatedStorage

-- Shared by :viewinv - same list popup component every other master
-- list uses, just showing one target's current Backpack/equipped Tool
-- names instead of a punishment record.
local AdminInventoryList = Instance.new("RemoteEvent")
AdminInventoryList.Name = "AdminInventoryList"
AdminInventoryList.Parent = ReplicatedStorage

-- Fired FROM the admin's own client - the per-row Remove button on the
-- :viewinv popup, for removing one specific item rather than needing
-- the separate all-or-nothing :clearinv.
local AdminInventoryRemoveItem = Instance.new("RemoteEvent")
AdminInventoryRemoveItem.Name = "AdminInventoryRemoveItem"
AdminInventoryRemoveItem.Parent = ReplicatedStorage

-- Broadcast to EVERY connected client (including the invisible player's
-- own) whenever :invis/:uninvis runs, so PlayerInfo.lua can hide/restore
-- that specific player's overhead name/rank tag - a BillboardGui isn't a
-- BasePart or Decal, so setInvisible's own Transparency sweep never
-- touches it, and being invisible while still showing a nameplate
-- floating in midair rather defeats the point.
local AdminInvisStatus = Instance.new("RemoteEvent")
AdminInvisStatus.Name = "AdminInvisStatus"
AdminInvisStatus.Parent = ReplicatedStorage

-- Fired whenever a player's tier might have changed after their client
-- already checked once - :setadminrank, in Studio or by the owner in a
-- live game. Without
-- this, setting the override attribute from the Command Bar after a
-- client's one-time GetAdminInfo check already ran (which is nearly
-- always the case in practice - it takes real time just to reach the
-- Command Bar and type the line) had no visible effect until rejoining,
-- which loses the attribute anyway since Play sessions don't persist it.
local AdminInfoChanged = Instance.new("RemoteEvent")
AdminInfoChanged.Name = "AdminInfoChanged"
AdminInfoChanged.Parent = ReplicatedStorage

-- NOT Studio-only.
--
-- It used to be, on the reasoning that only the Studio testing override
-- ever changed a tier mid-session. That was wrong: :setadminrank is
-- gated on "Studio, OR you are the owner", so the owner can run it in a
-- live game - and there the attribute was set, the rank label changed,
-- and the client was never told, so the person was given a staff rank
-- with no admin panel to go with it.
local function watchOverride(player)
	player:GetAttributeChangedSignal("AdminTierOverride"):Connect(function()
		AdminInfoChanged:FireClient(player, tierInfo(getPlayerTier(player), player))
	end)
end
for _, player in ipairs(Players:GetPlayers()) do
	watchOverride(player)
end
Players.PlayerAdded:Connect(watchOverride)

print("[AdminServer] Remotes ready")

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
		warn("[AdminServer] ListKeysAsync failed: " .. tostring(pages))
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
	warn("[AdminServer] Failed to check ban status for " .. userIdStr .. ": " .. tostring(data))
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
			warn("[AdminServer] Failed to save ban for " .. tostring(userId) .. ": " .. tostring(err))
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
			warn("[AdminServer] Failed to remove ban for " .. tostring(userId) .. ": " .. tostring(err))
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
	print("[AdminServer] Ban cache seeded: " .. #keys .. " record(s)")
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
-- AdminWarningsList:FireClient below ever fired).
local function saveWarnings(userId, warnings)
	warningRecordsCache[tostring(userId)] = warnings
	task.spawn(function()
		local success, err = pcall(function()
			WarningStore:SetAsync(tostring(userId), warnings)
		end)
		if not success then
			warn("[AdminServer] Failed to save warnings for " .. tostring(userId) .. ": " .. tostring(err))
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
	print("[AdminServer] Warning cache seeded: " .. #keys .. " record(s)")
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
			warn("[AdminServer] Failed to save mute for " .. tostring(userId) .. ": " .. tostring(err))
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
	print("[AdminServer] Mute cache seeded: " .. #keys .. " record(s)")
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
					AdminNotice:FireClient(mutedPlayerObj, "You are muted", MUTE_TYPING_REMINDER)
				end
			end
			return true
		end)
		if not ok then return true end
		return not blocked
	end
	print("[AdminServer] Mute filter attached to " .. channel.Name)
end

-- Attached to every current AND future text channel rather than a
-- single channel hardcoded by name ("RBXGeneral") - if this game's
-- channel is actually named something else, or there's more than one
-- (e.g. a team channel), hardcoding one name would silently mean
-- :mute never actually blocked anything even though the command itself
-- reported success.
task.spawn(function()
	local textChannels = TextChatService:WaitForChild("TextChannels", 10)
	if not textChannels then
		warn("[AdminServer] TextChannels not found - :mute will have no effect")
		return
	end
	for _, channel in ipairs(textChannels:GetChildren()) do
		if channel:IsA("TextChannel") then
			attachMuteFilter(channel)
		end
	end
	textChannels.ChildAdded:Connect(function(child)
		if child:IsA("TextChannel") then
			attachMuteFilter(child)
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
	AdminMuteStatus:FireClient(player, true, muteData.ExpiresAt)
end)

-- Returns (nowMuted, muteData) - muteData is the new record when nowMuted
-- is true, nil when unmuting - so callers can fire AdminMuteStatus with
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
local CELL_W, CELL_D, CELL_H = 18, 16, 16
local CORRIDOR_D = 15
local DIVIDER = 1
local JAIL_WALL = 1
local DOOR_WIDTH = 5

local BLOCK_W = CELL_W * 3 + DIVIDER * 2
local CELL_Z0, CELL_Z1 = -CELL_D - 1, -1
local CORR_Z1 = CELL_Z1 + CORRIDOR_D
local FLOOR_Y, CEIL_Y = -CELL_H / 2, CELL_H / 2
local CELL_MID_Z = (CELL_Z0 + CELL_Z1) / 2
local CORR_MID_Z = CELL_Z1 + CORRIDOR_D / 2
local CELL_X = { -(CELL_W + DIVIDER), 0, CELL_W + DIVIDER }

local JAIL_SPAWN_CFRAME = JAIL_CFRAME * CFrame.new(0, FLOOR_Y + 4, CELL_MID_Z)

-- A narrow palette, and floor/walls deliberately different values so the
-- room has some contrast instead of being one flat grey.
local C_WALL = Color3.fromRGB(104, 104, 108)
local C_WALL_LOW = Color3.fromRGB(74, 74, 79)
local C_FLOOR = Color3.fromRGB(58, 58, 62)
local C_STEEL = Color3.fromRGB(78, 82, 90)
local C_ACCENT = Color3.fromRGB(196, 158, 46)
local C_MATTRESS = Color3.fromRGB(72, 86, 108)
local C_PORCELAIN = Color3.fromRGB(198, 201, 206)
local C_WOOD = Color3.fromRGB(96, 72, 52)

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
	part.Color = props.Color or C_WALL
	part.Size = props.Size
	part.CFrame = JAIL_CFRAME * CFrame.new(props.X or 0, props.Y or 0, props.Z or 0) * (props.Rot or CFrame.new())
	if props.Shape then part.Shape = props.Shape end
	part.Parent = props.Parent or jailFolder
	return part
end

local setCellDoorOpen

do
	local overlap = JAIL_WALL
	local blockCentreZ = (CELL_Z0 + CORR_Z1) / 2
	local blockDepth = CORR_Z1 - CELL_Z0
	local halfW = BLOCK_W / 2

	-- Shell. Every piece OVERLAPS its neighbours at the seams rather than
	-- butting edge-to-edge: parts that merely touch along a shared
	-- boundary can flicker straight through when the camera clips into
	-- the geometry, and overlapping solid material leaves no exact
	-- coincident edge to slip through.
	local shellW, shellD, shellH = BLOCK_W + overlap * 2, blockDepth + overlap * 2, CELL_H + overlap * 2
	jailPart({Name = "Floor", Size = Vector3.new(shellW, JAIL_WALL, shellD), Y = FLOOR_Y - JAIL_WALL / 2, Z = blockCentreZ, Color = C_FLOOR})
	-- Not as dark as the wall band: at the first pass the ceiling read as
	-- an open black void above the lights rather than as a surface.
	jailPart({Name = "Ceiling", Size = Vector3.new(shellW, JAIL_WALL, shellD), Y = CEIL_Y + JAIL_WALL / 2, Z = blockCentreZ, Color = Color3.fromRGB(88, 88, 93)})
	jailPart({Name = "WallBack", Size = Vector3.new(shellW, shellH, JAIL_WALL), Z = CELL_Z0 - JAIL_WALL / 2})
	jailPart({Name = "WallFront", Size = Vector3.new(shellW, shellH, JAIL_WALL), Z = CORR_Z1 + JAIL_WALL / 2})
	jailPart({Name = "WallLeft", Size = Vector3.new(JAIL_WALL, shellH, shellD), X = -halfW - JAIL_WALL / 2, Z = blockCentreZ})
	jailPart({Name = "WallRight", Size = Vector3.new(JAIL_WALL, shellH, shellD), X = halfW + JAIL_WALL / 2, Z = blockCentreZ})

	-- A darker band around the lower third of the walls. One horizontal
	-- line does more to stop a room reading as a flat grey box than any
	-- number of small props, because it gives the eye a height reference.
	local BAND_H = CELL_H * 0.34
	jailPart({Name = "BandFront", Size = Vector3.new(shellW, BAND_H, 0.12), Y = FLOOR_Y + BAND_H / 2, Z = CORR_Z1 - 0.06, Material = Enum.Material.SmoothPlastic, Color = C_WALL_LOW, CanCollide = false})
	for _, dir in ipairs({-1, 1}) do
		jailPart({Name = "BandSide", Size = Vector3.new(0.12, BAND_H, shellD), X = dir * (halfW - 0.06), Y = FLOOR_Y + BAND_H / 2, Z = blockCentreZ, Material = Enum.Material.SmoothPlastic, Color = C_WALL_LOW, CanCollide = false})
	end
	jailPart({Name = "BandStripe", Size = Vector3.new(shellW, 0.18, 0.14), Y = FLOOR_Y + BAND_H, Z = CORR_Z1 - 0.07, Material = Enum.Material.SmoothPlastic, Color = C_ACCENT, CanCollide = false})
	jailPart({Name = "FloorLine", Size = Vector3.new(BLOCK_W - 3, 0.06, 0.7), Y = FLOOR_Y + 0.04, Z = CORR_MID_Z, Material = Enum.Material.SmoothPlastic, Color = C_ACCENT, CanCollide = false})

	for i = 1, 2 do
		jailPart({Name = "CellDivider" .. i, Size = Vector3.new(DIVIDER, CELL_H, CELL_D + overlap), X = CELL_X[i] + CELL_W / 2 + DIVIDER / 2, Z = CELL_MID_Z})
	end

	local barTop, barBottom = CEIL_Y - 0.5, FLOOR_Y + 0.5
	local barHeight = barTop - barBottom
	local barMidY = (barTop + barBottom) / 2
	local doorHalf = DOOR_WIDTH / 2
	local UPRIGHT = CFrame.Angles(0, 0, math.rad(90))

	-- ROUND bars, not square ones. Square uprights were the single
	-- biggest reason the last version looked cheap - real cell bars are
	-- round, and a cylinder catches the light along its length instead of
	-- presenting one flat grey face.
	local function bar(name, x, y, z, length, thickness, parent)
		return jailPart({Name = name, Size = Vector3.new(length, thickness, thickness),
			X = x, Y = y, Z = z, Rot = UPRIGHT, Shape = Enum.PartType.Cylinder,
			Material = Enum.Material.Metal, Color = C_STEEL, Parent = parent})
	end

	local function buildCellFront(cellIndex)
		local cx = CELL_X[cellIndex]
		local function barsBetween(x0, x1, tag)
			local span = x1 - x0
			local count = math.max(2, math.floor(span / 1.45))
			for i = 0, count do
				bar("Bar" .. cellIndex .. tag .. i, x0 + span * (i / count), barMidY, CELL_Z1, barHeight, 0.34)
			end
		end
		barsBetween(cx - CELL_W / 2 + 0.5, cx - doorHalf - 0.5, "L")
		barsBetween(cx + doorHalf + 0.5, cx + CELL_W / 2 - 0.5, "R")

		-- Rails stop short of the doorway on both sides so the opening is
		-- genuinely open rather than crossed by a bar.
		local sideSpan = CELL_W / 2 - doorHalf
		for _, y in ipairs({barBottom + 0.2, barMidY, barTop - 0.2}) do
			for _, dir in ipairs({-1, 1}) do
				jailPart({Name = "BarRail", Size = Vector3.new(sideSpan, 0.26, 0.26),
					X = cx + dir * (doorHalf + sideSpan / 2), Y = y, Z = CELL_Z1,
					Material = Enum.Material.Metal, Color = C_STEEL, CanCollide = false})
			end
		end
		for _, dir in ipairs({-1, 1}) do
			jailPart({Name = "DoorPost", Size = Vector3.new(0.6, barHeight + 0.8, 0.6),
				X = cx + dir * doorHalf, Y = barMidY, Z = CELL_Z1,
				Material = Enum.Material.Metal, Color = C_STEEL})
		end
		jailPart({Name = "DoorLintel", Size = Vector3.new(DOOR_WIDTH + 1.2, 0.6, 0.55),
			X = cx, Y = barTop + 0.55, Z = CELL_Z1, Material = Enum.Material.Metal, Color = C_STEEL})

		local plate = jailPart({Name = "CellPlate", Size = Vector3.new(3, 1.3, 0.16),
			X = cx, Y = barTop + 1.6, Z = CELL_Z1, Material = Enum.Material.SmoothPlastic,
			Color = C_WALL_LOW, CanCollide = false})
		local sign = Instance.new("SurfaceGui")
		sign.Face = Enum.NormalId.Front
		sign.CanvasSize = Vector2.new(300, 130)
		sign.Parent = plate
		local label = Instance.new("TextLabel")
		label.Size = UDim2.new(1, 0, 1, 0)
		label.BackgroundTransparency = 1
		label.Font = Enum.Font.GothamBold
		label.TextColor3 = C_ACCENT
		label.TextScaled = true
		label.Text = "CELL " .. cellIndex
		label.Parent = sign
	end

	local function buildCellDoor(cellIndex)
		local cx = CELL_X[cellIndex]
		local door = Instance.new("Model")
		door.Name = "CellDoor" .. cellIndex
		door.Parent = jailFolder

		local frame = jailPart({Name = "DoorFrame", Size = Vector3.new(DOOR_WIDTH - 0.4, barHeight - 0.3, 0.3),
			X = cx, Y = barMidY, Z = CELL_Z1, Material = Enum.Material.Metal, Color = C_STEEL, Parent = door})
		frame.Transparency = 1
		door.PrimaryPart = frame

		for i = 1, 4 do
			bar("DoorBar" .. i, cx - DOOR_WIDTH / 2 + DOOR_WIDTH * (i / 5), barMidY, CELL_Z1, barHeight - 0.5, 0.3, door)
		end
		for _, y in ipairs({barMidY - barHeight / 2 + 0.5, barMidY, barMidY + barHeight / 2 - 0.5}) do
			jailPart({Name = "DoorRail", Size = Vector3.new(DOOR_WIDTH - 0.4, 0.24, 0.24),
				X = cx, Y = y, Z = CELL_Z1, Material = Enum.Material.Metal, Color = C_STEEL, Parent = door})
		end
		-- Slim and steel, kept close to the door plane. A chunky gold
		-- block standing proud of the bars just read as a stray part.
		jailPart({Name = "DoorHandle", Size = Vector3.new(0.18, 0.18, 0.95), X = cx + doorHalf - 0.75,
			Y = barMidY, Z = CELL_Z1 + 0.28, Material = Enum.Material.Metal, Color = C_STEEL, Parent = door})

		local hinge = JAIL_CFRAME * CFrame.new(cx - doorHalf, barMidY, CELL_Z1)
		local closedPivot = JAIL_CFRAME * CFrame.new(cx, barMidY, CELL_Z1)
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
		local cx = CELL_X[cellIndex]
		local bunkX = cx - CELL_W / 2 + 2.6
		local bunkY = FLOOR_Y + 2.1

		jailPart({Name = "BunkFrame", Size = Vector3.new(3.8, 0.35, 8), X = bunkX, Y = bunkY, Z = CELL_MID_Z, Material = Enum.Material.Metal, Color = C_STEEL})
		jailPart({Name = "Mattress", Size = Vector3.new(3.5, 0.5, 7.6), X = bunkX, Y = bunkY + 0.42, Z = CELL_MID_Z, Material = Enum.Material.Fabric, Color = C_MATTRESS})
		jailPart({Name = "Pillow", Size = Vector3.new(3.1, 0.35, 1.6), X = bunkX, Y = bunkY + 0.8, Z = CELL_MID_Z - 2.9, Material = Enum.Material.Fabric, Color = Color3.fromRGB(166, 170, 178)})
		-- Braced into the wall rather than standing on legs, so there is
		-- nothing to float: the slab runs into the divider behind it.
		jailPart({Name = "BunkBrace", Size = Vector3.new(0.5, bunkY - FLOOR_Y, 8), X = bunkX - 1.9, Y = FLOOR_Y + (bunkY - FLOOR_Y) / 2, Z = CELL_MID_Z, Material = Enum.Material.Metal, Color = C_STEEL})

		-- Sanitary fixtures, pushed FLUSH to the walls. Sitting them a
		-- stud or two clear of the wall is what made the previous pass
		-- read as white crates dumped in a corner rather than plumbing -
		-- real fixtures touch something.
		local wallX = cx + CELL_W / 2
		local backZ = CELL_Z0

		-- Bowl and seat as upright cylinders. A cube reads as a box no
		-- matter what colour it is; the round profile is most of what
		-- makes this legible as a toilet at a glance.
		jailPart({Name = "ToiletBowl", Size = Vector3.new(1.7, 1.8, 1.8), X = wallX - 1.7, Y = FLOOR_Y + 0.85, Z = backZ + 1.6, Rot = UPRIGHT, Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = C_PORCELAIN})
		jailPart({Name = "ToiletSeat", Size = Vector3.new(0.22, 2.1, 2.1), X = wallX - 1.7, Y = FLOOR_Y + 1.81, Z = backZ + 1.6, Rot = UPRIGHT, Shape = Enum.PartType.Cylinder, Material = Enum.Material.SmoothPlastic, Color = C_WALL_LOW})
		jailPart({Name = "Cistern", Size = Vector3.new(2.2, 2.6, 0.7), X = wallX - 1.7, Y = FLOOR_Y + 3.1, Z = backZ + 0.45, Material = Enum.Material.SmoothPlastic, Color = C_PORCELAIN})

		-- Basin against the side wall, on a bracket that visibly reaches
		-- the floor so nothing appears to hang in mid-air.
		jailPart({Name = "Basin", Size = Vector3.new(1.3, 0.8, 2.4), X = wallX - 0.7, Y = FLOOR_Y + 3.3, Z = backZ + 5.4, Material = Enum.Material.SmoothPlastic, Color = C_PORCELAIN})
		jailPart({Name = "BasinStand", Size = Vector3.new(0.7, 2.9, 0.8), X = wallX - 0.45, Y = FLOOR_Y + 1.45, Z = backZ + 5.4, Material = Enum.Material.Metal, Color = C_STEEL})
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
	local deskX, deskZ = -halfW + 5, CORR_Z1 - 3.5
	jailPart({Name = "DeskBody", Size = Vector3.new(8, 3.2, 3), X = deskX, Y = FLOOR_Y + 1.6, Z = deskZ, Material = Enum.Material.WoodPlanks, Color = C_WOOD})
	jailPart({Name = "DeskTop", Size = Vector3.new(9, 0.35, 3.8), X = deskX, Y = FLOOR_Y + 3.38, Z = deskZ, Material = Enum.Material.WoodPlanks, Color = C_WOOD})
	jailPart({Name = "DeskChairSeat", Size = Vector3.new(2, 0.35, 2), X = deskX, Y = FLOOR_Y + 1.9, Z = deskZ + 3.4, Material = Enum.Material.SmoothPlastic, Color = C_WALL_LOW})
	jailPart({Name = "DeskChairBack", Size = Vector3.new(2, 2.2, 0.35), X = deskX, Y = FLOOR_Y + 3, Z = deskZ + 4.3, Material = Enum.Material.SmoothPlastic, Color = C_WALL_LOW})
	jailPart({Name = "DeskChairStem", Size = Vector3.new(0.5, 1.75, 0.5), X = deskX, Y = FLOOR_Y + 0.88, Z = deskZ + 3.4, Material = Enum.Material.Metal, Color = C_STEEL})

	-- Long recessed strip lights rather than bare points: a visible
	-- fixture reads as a light, while an invisible source just makes the
	-- room glow from nowhere. Dimmer and more numerous than before, which
	-- is what stops the harsh single-source look.
	local function stripLight(name, x, z, length)
		jailPart({Name = name .. "Housing", Size = Vector3.new(length, 0.35, 1.1), X = x, Y = CEIL_Y - 0.5, Z = z, Material = Enum.Material.Metal, Color = C_STEEL, CanCollide = false})
		local lens = jailPart({Name = name .. "Lens", Size = Vector3.new(length - 0.6, 0.12, 0.8), X = x, Y = CEIL_Y - 0.72, Z = z, Material = Enum.Material.Neon, Color = Color3.fromRGB(236, 242, 250), CanCollide = false})
		local light = Instance.new("PointLight")
		light.Brightness = 1.35
		light.Range = 26
		light.Color = Color3.fromRGB(226, 234, 245)
		light.Shadows = false
		light.Parent = lens
	end
	for i = 1, 3 do
		stripLight("CellLight" .. i, CELL_X[i], CELL_MID_Z, CELL_W * 0.45)
		stripLight("CorridorLightA" .. i, CELL_X[i], CORR_MID_Z - 3.5, CELL_W * 0.5)
		stripLight("CorridorLightB" .. i, CELL_X[i], CORR_MID_Z + 3.5, CELL_W * 0.5)
	end

	print("[AdminServer] Jail block built (3 cells)")
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
	AdminScreenFade:FireClient(target)
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
		AdminScreenFade:FireClient(target)
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
	-- player's overhead tag - see the comment above AdminInvisStatus's
	-- own declaration for why that can't just ride along with the
	-- Transparency sweep above.
	for _, plr in ipairs(Players:GetPlayers()) do
		AdminInvisStatus:FireClient(plr, target, invisible)
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
	AdminSetFlying:FireClient(target, enabled)
	return true
end

-- =====================================================================
-- Spectate - the spectating admin is made invisible and frozen for the
-- duration (so they can't be seen, and can't move/interact with anyone
-- while just watching), restored to their exact previous position AND
-- previous invis/frozen state the moment they stop. Ending only ever
-- happens via the admin's own "Stop Spectating" button (AdminStopSpectating)
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
-- AdminStopSpectating's own listener, for why this pattern is needed at
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

	AdminSpectate:FireClient(admin, nil)
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
		AdminSpectate:FireClient(admin, target)
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
	AdminSpectate:FireClient(admin, target)
	return true
end

-- AdminStopSpectating's own .OnServerEvent listener is registered much
-- further down (right alongside AdminStopControlling's), after
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
-- button (AdminStopControlling), matching :spectate's own design above.
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

	AdminControlTargetStatus:FireClient(target, false)
	AdminControlPlayer:FireClient(admin, nil)
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

	AdminControlTargetStatus:FireClient(target, true)
	AdminNotice:FireClient(target, "You are being controlled by staff", "Leaving the game is punishable.")
	AdminControlPlayer:FireClient(admin, target)
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

-- AdminStopControlling's own .OnServerEvent listener is registered
-- further down too, alongside AdminStopSpectating's - see the comment
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
	adminPlayer.CharacterAdded:Connect(function()
		if spectatingState[adminPlayer.UserId] then
			spectatingState[adminPlayer.UserId] = nil
			AdminSpectate:FireClient(adminPlayer, nil)
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
			AdminControlTargetStatus:FireClient(target, false)
			AdminControlPlayer:FireClient(adminPlayer, nil)
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
							AdminSpectate:FireClient(adminPlayer, targetPlayer)
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
	AdminInventoryList:FireClient(admin, "Inventory - " .. target.Name .. " (" .. #entries .. ")", entries)
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
-- the top of this file, before tierInfo, since GetAdminInfo's response
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
	AdminNotice:FireClient(
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
		print("[AdminServer] Loaded " .. #commandLog .. " persisted command log entries")
	elseif success then
		-- [DEBUG] savedLog was nil, not a load failure - either nothing
		-- has ever been saved under this key yet, or this build of the
		-- script (with persistence at all) hasn't run in this place
		-- before. Printed either way so it's obvious from the Output
		-- whether persistence is even active, instead of silently
		-- starting fresh with no visible signal.
		print("[AdminServer] No persisted command log found (savedLog=" .. tostring(savedLog) .. ") - starting empty")
	else
		warn("[AdminServer] Failed to load persisted command log: " .. tostring(savedLog))
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
			print("[AdminServer] Command log saved (" .. #commandLog .. " entries)")
		else
			warn("[AdminServer] Failed to persist command log: " .. tostring(err))
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
	print("[AdminServer] Log wipe ready - run game.ServerStorage.WipeCommandLog:Invoke() in the Studio Command Bar (context: Server)")
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
	print(string.format(
		"[AdminServer][LOG] %s used :%s on %s%s",
		adminName, commandName, targetName or "-",
		(extra and extra ~= "") and (" (" .. extra .. ")") or ""
	))
end

local function logCommand(admin, commandName, targetName, extra, description)
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
	AdminFeedback:FireClient(player, text, isError == true)
end

-- Owner-only, re-checked here rather than trusting the CanRemoveLogs
-- flag the client was handed - a RemoteEvent is callable by any client
-- that knows its name, whatever their panel chose to draw. A refusal is
-- silent for everyone except the owner: someone probing this doesn't
-- need to be told it exists and that they're not allowed.
AdminRemoveLogEntry.OnServerEvent:Connect(function(player, entryId)
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
	AdminLogsList:FireClient(player, title, entries)

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

AdminCommand.OnServerEvent:Connect(function(admin, commandName, targetName, extraText)
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

	-- Handled before target resolution: the three list commands don't
	-- target anyone at all. Unbanning is no longer a standalone typed
	-- command - it's done from :banlist's per-row "Modify" popup, which
	-- already has the exact UserId on hand and doesn't need a username
	-- lookup at all.
	if commandName == "banlist" then
		local entries = buildBanListEntries()
		AdminBanList:FireClient(admin, "Banned Players (" .. #entries .. ")", entries)
		sendFeedback(admin, #entries .. " active ban(s)", false)
		return
	end

	if commandName == "mutelist" then
		local entries = buildMuteListEntries()
		AdminMuteList:FireClient(admin, "Muted Players (" .. #entries .. ")", entries)
		sendFeedback(admin, #entries .. " player(s) currently muted", false)
		return
	end

	if commandName == "warnlist" then
		local entries = buildWarnListEntries()
		AdminWarnList:FireClient(admin, "Warned Players (" .. #entries .. ")", entries)
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
		local wanted = string.lower(extraText:match("^%s*(%S*)") or "")
		if targetName == "" or wanted == "" then
			sendFeedback(admin, "Usage: :setadminrank [player] [Moderator/Admin/Developer/Founder, or clear]", true)
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

		if wanted == "clear" or wanted == "none" then
			target:SetAttribute("AdminTierOverride", nil)
			sendFeedback(admin, target.Name .. " reset - back to their real rank on next rejoin", false)
			return
		end

		for _, value in ipairs(STUDIO_TIER_VALUES) do
			if string.lower(value) == wanted then
				target:SetAttribute("AdminTierOverride", value)
				sendFeedback(admin, target.Name .. " is now " .. value .. " (this session only)", false)
				print("[AdminServer] " .. admin.Name .. " set " .. target.Name .. " to " .. value .. " (Studio, session only)")
				return
			end
		end

		sendFeedback(admin, "Usage: :setadminrank [player] [Moderator/Admin/Developer/Founder, or clear]", true)
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
		print("[AdminServer] Command log wiped by " .. admin.Name .. " (" .. wiped .. " entries)")
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
			sendFeedback(admin, target.Name .. " isn't in a dishwasher", true)
			return
		end
		logCommand(admin, "finishrun", target.Name, nil, admin.Name .. " finished " .. target.Name .. "'s dishwasher")
		sendFeedback(admin, "Finished " .. target.Name .. "'s dishwasher (" .. cleaned .. " spots)", false)
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
			sendFeedback(admin, target.Name .. " isn't in a dishwasher", true)
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
		logCommand(admin, "unlockall", target.Name, nil, admin.Name .. " unlocked every dishwasher for " .. target.Name)
		sendFeedback(admin, "Unlocked every dishwasher for " .. target.Name, false)
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
			Remotes.Event("Notify"):FireClient(target, "🎁 You were gifted " .. pass.Icon .. " " .. pass.Name .. "!", "Good")
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
		AdminLogsList:FireClient(admin, "Command Log (" .. #entries .. ")", entries)
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
		AdminLogsList:FireClient(admin, "Logs - " .. targetName .. " (" .. #entries .. ")", entries)
		sendFeedback(admin, #entries .. " log entries for " .. targetName, false)
		return
	end

	-- No player target at all - the whole rest of the input (targetName
	-- + extraText, which the client only split apart because every other
	-- command has a target as its first word) is the announcement text.
	if commandName == "announce" then
		local fullMessage = (targetName ~= "" and (targetName .. " " .. extraText) or extraText)
		fullMessage = fullMessage:gsub("%s+$", "")
		if fullMessage == "" then
			sendFeedback(admin, "Usage: :announce [message]", true)
			return
		end
		local players = Players:GetPlayers()
		for _, plr in ipairs(players) do
			AdminAnnouncement:FireClient(plr, fullMessage)
		end
		logCommand(admin, "announce", nil, fullMessage, admin.Name .. " announced: " .. fullMessage)
		sendFeedback(admin, "Announcement sent to " .. #players .. " player(s)", false)
		return
	end

	-- :fly with no name typed targets the issuing admin themselves,
	-- rather than requiring ":fly MyOwnUsername" every time - :fly [name]
	-- still works normally for flying someone else.
	if commandName == "fly" and targetName == "" then
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
			AdminNotice:FireClient(target, "You have been muted", muteNoticeBody(muteData))
		end
		AdminMuteStatus:FireClient(target, nowMuted, nowMuted and muteData.ExpiresAt or nil)
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
		AdminNotice:FireClient(target, "You have been muted", muteNoticeBody(data))
		AdminMuteStatus:FireClient(target, true, data.ExpiresAt)
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
		AdminNotice:FireClient(target, "Message from staff", extraText, nil, "OKAY")
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
				AdminNotice:FireClient(target, "You are frozen", "Leaving the game is punishable.")
			end
			AdminFreezeStatus:FireClient(target, nowFrozen)
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
			AdminFreezeStatus:FireClient(target, false)
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
			logCommand(admin, "invis", target.Name, nowInvisible and "hidden" or "shown",
				admin.Name .. " made " .. target.Name .. (nowInvisible and " invisible" or " visible again"))
			sendFeedback(admin, "Made " .. target.Name .. (nowInvisible and " invisible" or " visible again"), false)
		else
			sendFeedback(admin, "Could not toggle invisibility - character not found", true)
		end

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

AdminRemoveWarning.OnServerEvent:Connect(function(admin, targetUserId, warningIndex)
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
	AdminWarningsList:FireClient(admin, nil, targetUserId, warnings)

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

AdminViewWarnings.OnServerEvent:Connect(function(admin, userIdStr)
	local tier = getPlayerTier(admin)
	if not tierHasCommand(tier, "warnlist") then return end
	local userId = tonumber(userIdStr)
	if not userId then return end

	local warnings = getWarnings(userId)
	local success, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	AdminWarningsList:FireClient(admin, success and name or ("UserId " .. userIdStr), userId, warnings)
end)

AdminModifyPunishment.OnServerEvent:Connect(function(admin, kind, userIdStr, action, value)
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
		AdminBanList:FireClient(admin, "Banned Players (" .. #entries .. ")", entries)

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
				AdminMuteStatus:FireClient(targetPlayerObj, false, nil)
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
					AdminMuteStatus:FireClient(targetPlayerObj, true, data.ExpiresAt)
				end
				sendFeedback(admin, "Updated mute duration", false)
			end
		end
		local entries = buildMuteListEntries()
		AdminMuteList:FireClient(admin, "Muted Players (" .. #entries .. ")", entries)
	end
end)

AdminInventoryRemoveItem.OnServerEvent:Connect(function(admin, tool)
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
AdminStopSpectating.OnServerEvent:Connect(function(admin)
	local state = spectatingState[admin.UserId]
	if not state then return end
	logCommand(admin, "spectate", state.Target.Name, "stopped", admin.Name .. " stopped spectating " .. state.Target.Name)
	stopSpectatingServer(admin)
	sendFeedback(admin, "Stopped spectating", false)
end)

AdminStopControlling.OnServerEvent:Connect(function(admin)
	local target = controllingUserIds[admin.UserId]
	if not target then return end
	logCommand(admin, "controlplayer", target.Name, "stopped", admin.Name .. " stopped controlling " .. target.Name)
	stopControlling(admin)
	sendFeedback(admin, "Stopped controlling " .. target.Name, false)
end)

print("[AdminServer] Fully initialised")
