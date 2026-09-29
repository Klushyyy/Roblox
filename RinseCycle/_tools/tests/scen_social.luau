-- Pet trading, pass gifting and the admin leaderboard reset.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local LBS = M[R .. "ServerScriptService/Server/Services/LeaderboardService.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local me, other = G.player, G.victim
pump(1, G.frame)
local pa, pb = DS.Get(me), DS.Get(other)
out("profiles: " .. tostring(pa ~= nil) .. " " .. tostring(pb ~= nil))
local petId = next(Config.Pets)
pa.Pets = { { Uid = "1", Id = petId }, { Uid = "2", Id = petId, Tier = 2 } }
pa.Equipped = { "1" }
pa.NextUid = 3
pb.Pets = { { Uid = "1", Id = petId } }
pb.Equipped = {}
pb.NextUid = 2

local trade = Remotes.Event("TradeAction")
local function asMe(a, v)
	call("client", function() trade:FireServer(a, v) end)
	pump(0.1, G.frame)
end
local function asOther(a, v)
	call("server", function() G.getSignal(trade, "OnServerEvent"):Fire(other, a, v) end)
	pump(0.1, G.frame)
end
asMe("Request", other.UserId)
asOther("Accept", me.UserId)
local tgui = G.find(G.playerGui, "TradeUI")
out("trade window open: " .. tostring(UIKit.IsWindowOpen("Trade")))
asMe("Add", "2")
asMe("Add", "999") -- not mine: ignored
asOther("Add", "1")
asMe("Ready", true)
asOther("Ready", true)
pump(2, G.frame)
asOther("Remove", "1") -- a change mid-countdown un-readies both
pump(3, G.frame)
out("after change: my pets " .. #pa.Pets .. ", theirs " .. #pb.Pets .. " (no swap yet)")
asOther("Add", "1")
asMe("Ready", true)
asOther("Ready", true)
pump(5, G.frame)
local function list(p)
	local t = {}
	for _, e in p.Pets do table.insert(t, e.Uid .. ":" .. e.Id .. (e.Tier and ("*" .. e.Tier) or "")) end
	return table.concat(t, ", ")
end
out("after trade: me [" .. list(pa) .. "] equipped " .. #pa.Equipped .. " | other [" .. list(pb) .. "]")
out("trade window open after: " .. tostring(UIKit.IsWindowOpen("Trade")))

-- Gift a pass (Studio: free).
local res
call("client", function() res = Remotes.Function("GiftRequest"):InvokeServer("VIP", other.UserId) end)
pump(0.5, G.frame)
out("gift result: " .. tostring(res and res.Ok) .. " done=" .. tostring(res and res.Done) .. " err=" .. tostring(res and res.Error))
out("other has VIP: attr " .. tostring(other:GetAttribute("GP_VIP")) .. " pass " .. tostring(DS.GetPasses(other).VIP))
local cel = G.find(G.playerGui, "Celebrate")
out("my celebrate popup open: " .. tostring(UIKit.IsWindowOpen("Celebrate")))
call("client", function() res = Remotes.Function("GiftRequest"):InvokeServer("VIP", other.UserId) end)
out("gift again: " .. tostring(res and res.Error))

-- Leaderboard reset (offline: in-memory).
pa.Stats.DishesCleaned = 2000
local rows = LBS.ListBoard(1, 100)
local mine
for _, r in rows do if r.UserId == me.UserId then mine = r end end
out("board 1 '" .. LBS.BoardTitle(1) .. "' me = " .. tostring(mine and mine.Text))
local ok, msg = LBS.ResetEntry(1, me.UserId)
out("reset: " .. tostring(ok) .. " " .. msg)
rows = LBS.ListBoard(1, 100)
mine = nil
for _, r in rows do if r.UserId == me.UserId then mine = r end end
out("after reset me = " .. tostring(mine and mine.Text) .. ", real stat still " .. pa.Stats.DishesCleaned)
pa.Stats.DishesCleaned = 4000
rows = LBS.ListBoard(1, 100)
for _, r in rows do if r.UserId == me.UserId then mine = r end end
out("after 2000 more: board " .. tostring(mine and mine.Text) .. ", real " .. pa.Stats.DishesCleaned)
out("boards: " .. LBS.BoardCount())
-- Admin panel view.
local AdminLeaderboard = G.ReplicatedStorage:FindFirstChild("AdminLeaderboard")
call("client", function() G.getSignal(AdminLeaderboard, "OnServerEvent"):Fire(me, "View", 4) end)
pump(0.5, G.frame)
