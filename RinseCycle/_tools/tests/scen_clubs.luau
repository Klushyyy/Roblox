-- Clubs: the 24 h wait after leaving, the 24 h ban on a club that kicked you, kicks taking the donated Bubbles
-- off the club, and the "you were kicked from ..." message (online, and for someone who was away).
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Club = M[R .. "ServerScriptService/Server/Services/ClubService.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local me, other = G.player, G.victim
local mine, theirs = DS.Get(me), DS.Get(other)
out("profiles: me=" .. tostring(mine ~= nil) .. " victim=" .. tostring(theirs ~= nil))
if not mine or not theirs then
	return
end
local function ask(plr, action, value)
	pump(0.6, G.frame)
	local r = call("server", function()
		return Remotes.Function("ClubRequest").OnServerInvoke(plr, action, value)
	end)
	local extra = ""
	if r and r.Club then
		extra = string.format(" club=%s n=%s points=%s", tostring(r.Club.Name), tostring(r.Club.Count), tostring(r.Club.Points))
	end
	out(string.format("%-6s %-8s -> ok=%s %s%s", plr == me and "me" or "victim", action, tostring(r and r.Ok), tostring(r and (r.Error or r.Message) or ""), extra))
	return r
end
local function who(plr, prof)
	return string.format("  [%s] club='%s' movedAt>0=%s bans=%d notice='%s'", plr == me and "me" or "victim", prof.ClubId, tostring(prof.ClubMovedAt > 0), (function() local n = 0 for _ in prof.ClubBans do n += 1 end return n end)(), prof.ClubNotice)
end

mine.Gems, theirs.Gems = 5000, 5000
mine.Bubbles, theirs.Bubbles = 100000, 100000
out("-- I make a club, the victim joins, both donate")
local made = ask(me, "Create", { Name = "Kick Test", Tag = "KICK", Public = true, ReqLevel = 0, ReqRebirths = 0 })
local clubId = made.Club.Id
ask(other, "Join", clubId)
ask(me, "Donate", 1000)
local d = ask(other, "Donate", 400)
out("club points after donations: " .. tostring(d.Club and d.Club.Points) .. " (1400 expected)")

out("-- kick the victim: the club loses the 400 they donated")
local k = ask(me, "Kick", other.UserId)
out("club points after kick: " .. tostring(k.Club and k.Club.Points) .. " (1000 expected)")
out(who(other, theirs))
out("victim meta notice: " .. tostring(CS.Meta and CS.Meta.ClubNotice))
ask(other, "Join", clubId)
local clubCooldownMe = mine.ClubMovedAt
out("kicked player was not given the leave wait: movedAt=" .. tostring(theirs.ClubMovedAt))
out("-- the victim makes another club right away (kicks don't block other clubs)")
local other2 = ask(other, "Create", { Name = "Second Club", Tag = "TWO", Public = true, ReqLevel = 0, ReqRebirths = 0 })
out("-- the kick message goes away once seen")
DS.SetClubNotice(other, "")
out(who(other, theirs))

out("-- the victim leaves their club: 24 h wait for any club")
ask(other, "Leave")
out(who(other, theirs))
ask(other, "Create", { Name = "Third Club", Tag = "TRI", Public = true, ReqLevel = 0, ReqRebirths = 0 })
ask(other, "Join", clubId)
out("-- the wait is over, the 24 h ban on the first club is still on")
theirs.ClubMovedAt = os.time() - Config.Clubs.LeaveCooldown - 5
ask(other, "Join", clubId)
out("-- ban over: back in")
for id in theirs.ClubBans do
	theirs.ClubBans[id] = os.time() - Config.Clubs.KickBan - 5
end
ask(other, "Join", clubId)
out(who(other, theirs))

out("-- kicked while away: the victim's profile still says they're in the club")
ask(me, "Kick", other.UserId)
theirs.ClubId, theirs.ClubTag, theirs.ClubNotice, theirs.ClubBans = clubId, "KICK", "", {}
local m = ask(other, "Mine")
out("after 'Mine' (as if just logged in): " .. who(other, theirs))
ask(other, "Join", clubId)

out("-- I leave my own club")
local l = ask(me, "Leave")
out(who(me, mine))
ask(me, "Create", { Name = "Again", Tag = "AGN", Public = true, ReqLevel = 0, ReqRebirths = 0 })
mine.ClubMovedAt = 0
out("-- admin reset clears it all")
theirs.ClubMovedAt = os.time()
theirs.ClubBans = { abc = os.time() }
out("reset: " .. tostring(DS.ResetClubCooldowns(other)) .. who(other, theirs))
