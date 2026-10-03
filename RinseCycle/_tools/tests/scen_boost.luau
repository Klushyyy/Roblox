local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local meta = Remotes.Function("MetaRequest")
local function req(action)
	local r = call("client", function()
		return meta:InvokeServer(action)
	end)
	pump(0.3, G.frame)
	out(string.format("%-16s -> ok=%s %s %s", action, tostring(r and r.Ok), tostring(r and r.Error or ""), tostring(r and r.Message or "")))
	return r
end
local prof = DS.Get(p)
out("ready before: " .. tostring(CS.Meta and CS.Meta.StayBoostReady))
req("ClaimStayBoost")
out("boost left s: " .. tostring((tonumber(prof.BoostUntil) or 0) - os.time()) .. " client BoostUntil set: " .. tostring((CS.Meta and CS.Meta.BoostUntil or 0) > 0) .. " ready after: " .. tostring(CS.Meta and CS.Meta.StayBoostReady))
req("ClaimStayBoost")
out("L1 toughness " .. Config.Levels[1].Toughness .. " start coins L1 " .. tostring(Config.StartCoins(1)) .. " L2 " .. tostring(Config.StartCoins(2)))
out("music lists: " .. #Config.Music.Lobby .. " / " .. #Config.Music.Run)
-- Daily rewards: 24 h after the last claim continues the streak, over 48 h restarts at day 1.
local function daily(label)
	local r = req("ClaimDaily")
	out(label .. " -> streak " .. tostring(prof.DailyStreak))
	return r
end
prof.DailyLast, prof.DailyStreak = 0, 0
daily("first ever")
daily("again straight away (should refuse)")
prof.DailyLast = os.time() - 25 * 3600
daily("25 h later")
prof.DailyLast = os.time() - 47 * 3600
daily("47 h later")
prof.DailyLast = os.time() - 49 * 3600
daily("49 h later (missed a day)")
prof.DailyLast, prof.DailyStreak = os.time() - 25 * 3600, 7
daily("after day 7")
-- Badges: the boost chip and a pass chip.
prof.BoostUntil = os.time() + 600
DS.SetPass(p, "DoubleCoins", true)
DS.SetPass(p, "VIP", true)
DS.PushMeta(p)
pump(1.5, G.frame)
local row
for _, d in p.PlayerGui:GetDescendants() do
	if d.Name == "BoostBadges" and d:IsA("Frame") then
		row = d
	end
end
local shown = {}
for _, c in row:GetChildren() do
	if c:IsA("Frame") and c.Visible then
		local l = c:FindFirstChildWhichIsA("TextLabel")
		table.insert(shown, l and l.Text or "?")
	end
end
out("badges: " .. table.concat(shown, " | "))
