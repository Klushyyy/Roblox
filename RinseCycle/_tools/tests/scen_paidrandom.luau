-- Roblox's paid random items policy (ArePaidRandomItemsRestricted): a restricted player cannot roll a rank, hatch an egg or open a
-- paid chest pack, and their screens grey those buttons out; the free chest stays. Restricted is forced here with the player
-- attribute ForcePaidRandomRestricted (the sim has no PolicyService), then lifted again.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local p = G.player
local RS = game:GetService("ReplicatedStorage")
local prof = DS.Get(p)
-- the Studio Test tab's "Restricted test" button (the admin command :paidtest on / off)
local function paidtest(mode)
	call("client", function() RS:FindFirstChild("AdminCommand"):FireServer("paidtest", "", mode) end)
	pump(1, G.frame)
end
prof.Gems = 500
prof.Bubbles = 5000
DS.PushMeta(p)
pump(8, G.frame) -- (the policy question has been answered or has given up by now)
out("policy answer for this player (sim): attribute=" .. tostring(p:GetAttribute("PaidRandomRestricted")) .. "  function=" .. tostring(DS.PaidRandomRestricted(p)))
local function request(action, value)
	return call("client", function() return CS.MetaRequest(action, value) end)
end
local function chest(action, value)
	return call("client", function() return Remotes.Function("ChestRequest"):InvokeServer(action, value) end)
end
local function find(root, className, text)
	for _, d in root:GetDescendants() do
		if d:IsA(className) and tostring(d.Text):find(text) then return d end
	end
end

-- a player who is allowed: roll and hatch work
if DS.PaidRandomRestricted(p) then
	out("(the sim's policy says restricted: unrestricted checks are skipped)")
else
	local r1 = request("RollRank")
	local r2 = request("Hatch", { Egg = "Bubble", Count = 1 })
	out(string.format("allowed: roll ok=%s  hatch ok=%s  gems=%d bubbles=%d", tostring(r1.Ok), tostring(r2.Ok), prof.Gems, prof.Bubbles))
end

-- a restricted player
prof.Gems, prof.Bubbles = 500, 5000
local pets, ranks = #prof.Pets, #prof.Ranks
-- the Ranks window is OPEN when the test starts: its button must change by itself
call("client", function() UIKit.OpenWindow("Ranks") end)
pump(0.8, G.frame)
local openBtn = find(p.PlayerGui, "TextButton", "ROLL")
out("Ranks window open, before: [" .. tostring(openBtn and openBtn.Text) .. "]")
paidtest("on")
out("Ranks window open, after the test button: [" .. tostring(openBtn and openBtn.Text) .. "]")
call("client", function() UIKit.CloseWindow() end)
out("restricted: attribute=" .. tostring(p:GetAttribute("PaidRandomRestricted")) .. "  function=" .. tostring(DS.PaidRandomRestricted(p)))
local rr = request("RollRank")
local hh = request("Hatch", { Egg = "Bubble", Count = 1 })
out(string.format("restricted: roll ok=%s [%s]  hatch ok=%s [%s]", tostring(rr.Ok), tostring(rr.Error), tostring(hh.Ok), tostring(hh.Error)))
out(string.format("nothing spent or given: gems=%d bubbles=%d pets %d -> %d ranks %d -> %d", prof.Gems, prof.Bubbles, pets, #prof.Pets, ranks, #prof.Ranks))
local pack = chest("Test", Config.ChestEvent.Packs[1].Count)
out(string.format("restricted: chest pack ok=%s [%s]", tostring(pack.Ok), tostring(pack.Error)))
pump(1, G.frame) -- (the chest answers at most twice a second)
local free = chest("Free")
out(string.format("restricted: the free chest is not blocked by the policy: ok=%s [%s]", tostring(free.Ok), tostring(free.Error)))

-- the screens
call("client", function() UIKit.OpenWindow("Ranks") end)
pump(0.8, G.frame)
local rollBtn = find(p.PlayerGui, "TextButton", "ACCOUNT RESTRICTED")
out("Ranks window button: [" .. tostring(rollBtn and rollBtn.Text) .. "]")
call("client", function() UIKit.CloseWindow() end)
call("client", function() UIKit.OpenWindow("Eggs") end)
pump(0.8, G.frame)
local hatchBtn = find(G.find(p.PlayerGui, "PetsUI"), "TextButton", "Account restricted")
out("Egg window hatch button: [" .. tostring(hatchBtn and hatchBtn.Text) .. "] disabled=" .. tostring(hatchBtn and hatchBtn:GetAttribute("Disabled")))
G.getSignal(hatchBtn, "Activated"):Fire()
pump(0.5, G.frame)
out(string.format("clicking it hatched nothing: pets=%d bubbles=%d", #prof.Pets, prof.Bubbles))

-- lifted again
paidtest("off")
out("lifted: attribute=" .. tostring(p:GetAttribute("PaidRandomRestricted")) .. "  roll button: [" .. tostring(openBtn and openBtn.Text) .. "]")

-- Roblox cannot answer (four failed tries): paid random items stay ON for that player
local Players = game:GetService("Players")
local policy = game:GetService("PolicyService")
local asked = 0
policy.GetPolicyInfoForPlayerAsync = function() asked += 1 error("PolicyService is down") end
local fake = Instance.new("Player")
fake.Name = "NoAnswer"
fake.UserId = 987654
fake.Parent = Players
DS._WatchPaidRandomPolicy(fake)
pump(12, G.frame)
out(string.format("policy down: asked %d times, restricted=%s, attribute=%s", asked, tostring(DS.PaidRandomRestricted(fake)), tostring(fake:GetAttribute("PaidRandomRestricted"))))
