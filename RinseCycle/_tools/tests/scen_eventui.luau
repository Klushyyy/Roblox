-- The Admin Abuse show's on-screen pieces at phone sizes (dumps for guirender.py): the countdown pill, the speech box (a
-- long line), the power-up pick card, a vote card, its results, and the prize card.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local RS = game:GetService("ReplicatedStorage")
local p = G.player
call("client", function()
	local UIS = game:GetService("UserInputService")
	UIS.TouchEnabled = true
	UIS.KeyboardEnabled = false
end)
local function size(w, h)
	local probe = p.PlayerGui:FindFirstChild("UIKitProbeFull")
	call("client", function()
		probe.AbsoluteSize = Vector2.new(w, h)
		G.getSignal(probe, "AbsoluteSize"):Fire()
	end)
	pump(1.5, G.frame)
end
local function fire(name, ...)
	local r = RS:FindFirstChild(name)
	if not r then
		out("!! missing remote " .. name)
		return
	end
	G.getSignal(r, "OnClientEvent"):Fire(...)
end
RS:SetAttribute("AbuseLive", true)
RS:SetAttribute("AbuseStarts", os.time() - 120)
RS:SetAttribute("AbuseEnds", os.time() + 600)
for _, s in { { "land", 844, 390 }, { "port", 390, 844 }, { "small", 667, 375 } } do
	size(s[2], s[3])
	out("-- " .. s[1] .. " " .. s[2] .. "x" .. s[3])
	local timerGui = p.PlayerGui:FindFirstChild("AbuseTimer")
	G.dumpGui(timerGui, OUT .. "event_pill_" .. s[1] .. ".json")
	fire("AbuseSay", "Klushy", "right. the table. lets see how much it can take. hold on to something, everyone.")
	pump(6, G.frame)
	G.dumpGui(p.PlayerGui:FindFirstChild("AbuseTalk"), OUT .. "event_talk_" .. s[1] .. ".json")
	fire("AbuseOffer", 1, 25)
	pump(1, G.frame)
	G.dumpGui(p.PlayerGui:FindFirstChild("AbuseOffer"), OUT .. "event_pick_" .. s[1] .. ".json")
	fire("AbuseOffer", 1, 0)
	local poll = RS:FindFirstChild("GlobalPoll")
	fire("GlobalPoll", "Start", "show1", "FINAL VOTE", { "1,500 Bubbles for everyone", "Limited pet for 1 lucky player", "Game passes for 20% of players", "150 Gems for everyone" }, Config.Now() + 25, "Pick one!")
	pump(1.5, G.frame)
	G.dumpGui(p.PlayerGui:FindFirstChild("PollUI"), OUT .. "event_vote_" .. s[1] .. ".json")
	fire("GlobalPoll", "Result", "show1", "FINAL VOTE", { "1,500 Bubbles for everyone", "Limited pet for 1 lucky player", "Game passes for 20% of players", "150 Gems for everyone" }, { 40, 30, 20, 10 }, 7)
	pump(1.5, G.frame)
	G.dumpGui(p.PlayerGui:FindFirstChild("PollUI"), OUT .. "event_result_" .. s[1] .. ".json")
	fire("GlobalPoll", "Close", "show1")
	pump(0.5, G.frame)
	Remotes.Event("Celebrate") -- (the prize card comes from the server)
	call("server", function()
		Remotes.Event("Celebrate"):FireClient(p, "You won a limited pet!", "Admin Abuse: you got the limited Glitch Fox!", "@Gift")
	end)
	pump(1.5, G.frame)
	G.dumpGui(p.PlayerGui:FindFirstChild("Celebrate"), OUT .. "event_prize_" .. s[1] .. ".json")
	pump(8, G.frame)
end
RS:SetAttribute("AbuseLive", nil)
out("=== DONE")
