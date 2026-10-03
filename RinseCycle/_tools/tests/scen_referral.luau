-- Referrals: a new player who joined from an invite gets their reward once; the inviter gets theirs.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local me, friend = G.player, G.victim
pump(1, G.frame)
local f, m = DS.Get(friend), DS.Get(me)
f.Stats.Runs, f.Stats.DishesCleaned, f.Rebirths = 0, 0, 0
local b0, g0 = f.Bubbles, f.Gems
out("new friend claims: " .. tostring(DS.ClaimReferred(friend, me.UserId)) .. string.format(" (bubbles +%d, gems +%d, referredBy ok=%s)", f.Bubbles - b0, f.Gems - g0, tostring(f.ReferredBy == me.UserId)))
out("claims again: " .. tostring(DS.ClaimReferred(friend, me.UserId)))
m.Stats.Runs = 3
out("an old player can't be referred: " .. tostring(DS.ClaimReferred(me, friend.UserId)))
local mb, mg = m.Bubbles, m.Gems
out("inviter paid for 1: " .. DS.AddReferrals(me, 1) .. string.format(" (bubbles +%d, gems +%d, total referrals %d)", m.Bubbles - mb, m.Gems - mg, m.Referrals))
m.Referrals = 49
out("cap at 50: paid " .. DS.AddReferrals(me, 5) .. ", total " .. m.Referrals)
pump(0.5, G.frame)
call("client", function() UIKit.OpenWindow("Free") end)
pump(0.5, G.frame)
local titles = {}
for _, d in G.find(me.PlayerGui, "RewardsUI"):GetDescendants() do
	if d.Name == "Title" and d:IsA("TextLabel") and d.Text ~= "" and d.Text ~= "Free Rewards" then table.insert(titles, d.Text) end
end
out("Free window cards: " .. table.concat(titles, " / "))
