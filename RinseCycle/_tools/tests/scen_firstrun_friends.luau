-- The first minutes (v2.20.0), part 4: a brand-new player who is WITH FRIENDS.
--   J  the server marks FriendsHere (followed / invited / a friend in the server) only for brand-new players
--   K  the card then leads with "play with friends" and never starts a run by itself
--   L  "Tutorial on my own" still starts the tutorial dishwasher
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Players = game:GetService("Players")
local p, victim = G.player, G.victim

local total, failed = 0, 0
local function check(group, name, ok, detail)
	total += 1
	if not ok then failed += 1 end
	out(string.format("%3d %s %-2s %s%s", total, if ok then "PASS" else "FAIL", group, name, if detail ~= nil then "   [" .. tostring(detail) .. "]" else ""))
end
local tracked: { [string]: number } = {}
local realTrack = DS.Track
DS.Track = function(plr, key, fields)
	tracked[key] = (tracked[key] or 0) + 1
	if realTrack then realTrack(plr, key, fields) end
end
local function shown(d, root)
	while d and d ~= root do
		if d:IsA("GuiObject") and not d.Visible then return false end
		d = d.Parent
	end
	return true
end
local function findText(root, text)
	for _, d in root:GetDescendants() do
		if (d.ClassName == "TextButton" or d.ClassName == "TextLabel") and d.Text == text and shown(d, root) then return d end
	end
end
local function press(btn)
	G.getSignal(btn, "Activated"):Fire()
end

-- a fake friends list: friends[a][b] = true
local friends: { [number]: { [number]: boolean } } = {}
local function stubFriends(plr)
	plr.IsFriendsWithAsync = function(_, otherId)
		local list = friends[plr.UserId]
		if list == "error" then error("web call failed") end
		return list ~= nil and list[otherId] == true
	end
end
stubFriends(p)
stubFriends(victim)
local function fireProfileLoaded(plr)
	DS.ProfileLoaded:Fire(plr, DS.Get(plr))
	pump(0.5, G.frame)
end

----------------------------------------------------------------------------------------------------
-- J: who is marked
----------------------------------------------------------------------------------------------------
local vprofile = DS.Get(victim)
vprofile.Stats.Runs = 0
victim:SetAttribute("FriendsHere", nil)
victim.GetJoinData = function() return {} end
fireProfileLoaded(victim)
check("J", "a new player with no friends here and no referral is not marked", victim:GetAttribute("FriendsHere") ~= true)
victim.GetJoinData = function() return { ReferredByPlayerId = 4242 } end
fireProfileLoaded(victim)
check("J", "followed a friend in (ReferredByPlayerId): marked", victim:GetAttribute("FriendsHere") == true)
check("J", "...and welcome.friends was tracked", tracked["welcome.friends"] == 1, tracked["welcome.friends"])
victim:SetAttribute("FriendsHere", nil)
victim.GetJoinData = function() return { LaunchData = "777" } end
fireProfileLoaded(victim)
check("J", "joined from an invite (LaunchData is a UserId): marked", victim:GetAttribute("FriendsHere") == true)
victim:SetAttribute("FriendsHere", nil)
victim.GetJoinData = function() return { LaunchData = "not a number" } end
fireProfileLoaded(victim)
check("J", "junk LaunchData does not mark", victim:GetAttribute("FriendsHere") ~= true)
victim.GetJoinData = function() return {} end
friends[victim.UserId] = { [p.UserId] = true }
fireProfileLoaded(victim)
check("J", "a Roblox friend in the server (the other player): marked", victim:GetAttribute("FriendsHere") == true)
victim:SetAttribute("FriendsHere", nil)
friends[victim.UserId] = "error"
fireProfileLoaded(victim)
check("J", "a failed friends lookup does not mark (and does not crash)", victim:GetAttribute("FriendsHere") ~= true)
friends[victim.UserId] = { [p.UserId] = true }
vprofile.Stats.Runs = 2
fireProfileLoaded(victim)
check("J", "a player who has finished a run is never marked", victim:GetAttribute("FriendsHere") ~= true)
vprofile.Stats.Runs = 0
friends[victim.UserId] = nil

----------------------------------------------------------------------------------------------------
-- K: the card, live
----------------------------------------------------------------------------------------------------
local card = p.PlayerGui:FindFirstChild("Welcome", true)
check("K", "the card is up for the brand-new test player", card.Visible == true)
check("K", "it offers the tutorial (no friends yet)", findText(card, "PLAY THE TUTORIAL?") ~= nil and findText(card, "START TUTORIAL") ~= nil and findText(card, "With friends instead") ~= nil)
check("K", "...with the automatic start counting down", (function()
	for _, d in card:GetDescendants() do
		if d.ClassName == "TextLabel" and string.find(d.Text, "Starts by itself in") then return true end
	end
	return false
end)())
-- a friend of the test player walks into the server
local friend = Instance.new("Player")
friend.Name = "TheFriend"
friend.UserId = 9001
friends[p.UserId] = { [9001] = true }
friend.Parent = Players
G.getSignal(Players, "PlayerAdded"):Fire(friend)
pump(1.5, G.frame)
check("K", "a friend arriving marks the test player", p:GetAttribute("FriendsHere") == true)
check("K", "the card changes its wording by itself", findText(card, "PLAYING WITH FRIENDS?") ~= nil and findText(card, "PLAY WITH FRIENDS") ~= nil and findText(card, "Tutorial on my own") ~= nil)
check("K", "...and the tutorial buttons are hidden", findText(card, "START TUTORIAL") == nil and findText(card, "PLAY THE TUTORIAL?") == nil)
check("K", "...and there is no countdown any more", (function()
	for _, d in card:GetDescendants() do
		if d.ClassName == "TextLabel" and d.Visible and string.find(d.Text, "Starts by itself in") then return false end
	end
	return true
end)())
pump(Config.FirstRun.AutoStart + 8, G.frame)
check("K", "the card is still up long after the automatic-start time", card.Visible == true)
check("K", "...and nothing started by itself", p:GetAttribute("InParty") ~= true and not RS.IsInRun(p) and (tracked["welcome.go"] or 0) == 0)

----------------------------------------------------------------------------------------------------
-- L: the tutorial on my own
----------------------------------------------------------------------------------------------------
press(findText(card, "Tutorial on my own"))
pump(0.4, G.frame)
check("L", "Tutorial on my own puts them in a party of one", p:GetAttribute("InParty") == true)
check("L", "welcome.go tracked, welcome.auto not", tracked["welcome.go"] == 1 and (tracked["welcome.auto"] or 0) == 0)
pump(6, G.frame)
check("L", "and into a dishwasher", RS.IsInRun(p))
check("L", "the lighter first dishwasher", tracked["run.easy"] == 1, tracked["run.easy"])

DS.Track = realTrack
out(string.format("== %d CHECKS: %d passed, %d FAILED", total, total - failed, failed))
