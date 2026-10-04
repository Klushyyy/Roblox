-- Rank luck from friends: +10% per friend who joined through your invites, up to 10 (x2), doubled by the x2 Luck pass (x4).
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local p = G.player
out("LuckMult: none " .. Config.LuckMult(false, 0) .. " 1 friend " .. Config.LuckMult(false, 1) .. " 10 friends " .. Config.LuckMult(false, 10) .. " pass " .. Config.LuckMult(true, 0) .. " pass+10 " .. Config.LuckMult(true, 10) .. " 99(clamped) " .. Config.LuckMult(false, 99))
local prof = DS.Get(p)
call("client", function()
	UIKit.OpenWindow("Ranks")
end)
pump(1.5, G.frame)
local summary = p.PlayerGui:FindFirstChild("LuckSummary", true)
out("0 friends: " .. tostring(summary and summary.Text))
prof.Referrals = 3
DS.PushMeta(p)
pump(1.5, G.frame)
out("3 friends: " .. tostring(summary and summary.Text))
local invite = p.PlayerGui:FindFirstChild("INVITE FRIENDS", true)
DS.SetPass(p, "DoubleLuck", true)
DS.PushMeta(p)
pump(1.5, G.frame)
out("3 friends + pass: " .. tostring(summary and summary.Text))
prof.Referrals = 12
DS.PushMeta(p)
pump(1.5, G.frame)
out("12 friends (cap 10) + pass: " .. tostring(summary and summary.Text))
