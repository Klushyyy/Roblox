-- Rank luck from rewarded ads: +20% per ad up to 5 (x2), doubled by the x2 Luck pass (x4).
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local p = G.player
local meta = Remotes.Function("MetaRequest")
local function req(action)
	local r = call("client", function()
		return meta:InvokeServer(action)
	end)
	pump(0.3, G.frame)
	out(string.format("%-12s -> ok=%s %s %s", action, tostring(r and r.Ok), tostring(r and r.Error or ""), tostring(r and r.Message or "")))
	return r
end
local function mythic(luck)
	local w, t = Config.RankWeights(luck)
	local m = 0
	for _, e in w do
		if e.Rank.Rarity == "Mythic" then
			m += e.Weight
		end
	end
	return string.format("%.3f%%", m / t * 100)
end
out("LuckMult: none " .. Config.LuckMult(false, 0) .. " 1ad " .. Config.LuckMult(false, 1) .. " 5ads " .. Config.LuckMult(false, 5) .. " pass " .. Config.LuckMult(true, 0) .. " pass+5 " .. Config.LuckMult(true, 5) .. " 9ads(clamped) " .. Config.LuckMult(false, 9))
out("Mythic odds: x1 " .. mythic(1) .. " x2 " .. mythic(2) .. " x4 " .. mythic(4))
local prof = DS.Get(p)
for _ = 1, 6 do
	req("WatchLuckAd")
end
out("stacks " .. DS.AdLuckStacks(prof) .. " client " .. tostring(CS.Meta and CS.Meta.AdLuckStacks) .. " minutes left " .. math.floor(((prof.AdLuckUntil or 0) - os.time()) / 60 + 0.5))
call("client", function()
	UIKit.OpenWindow("Ranks")
end)
pump(1.5, G.frame)
local summary = p.PlayerGui:FindFirstChild("LuckSummary", true)
out("summary: " .. tostring(summary and summary.Text))
DS.SetPass(p, "DoubleLuck", true)
DS.PushMeta(p)
pump(1.5, G.frame)
out("summary with pass: " .. tostring(summary and summary.Text))
local tag = p.PlayerGui:FindFirstChild("LuckTag", true)
local tl = tag and tag:FindFirstChildWhichIsA("TextLabel")
out("row tag: " .. tostring(tl and tl.Text))
prof.AdLuckUntil = os.time() - 1
DS.PushMeta(p)
pump(2.5, G.frame)
out("expired: stacks " .. DS.AdLuckStacks(prof) .. " summary: " .. tostring(summary and summary.Text))
