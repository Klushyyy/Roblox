-- v2.21.0, from the playtest list:
--   A  the Foam Cannon is a machine gun that gets faster with every Power upgrade
--   B  pans and pots really carry dirt in the Royal Banquet, and a pan's base disc no longer shares its bottom plane (z-fighting)
--   C  Auto Drain owners: "Infinity tank" in the HUD, "Infinity bag unlocked" in the Upgrade Book, never "FULL"
--   D  the tutorial card only for a player who still has the tutorial to do (and it comes back after Reset first run)
--   E  the new-player arrow points at a FREE pad only, and at nothing when every pad is taken
--   F  while the Create Party screen is up no other window opens, and the Event button / H does not carry you off the pad
--   G  the finale wording once Admin Abuse has started
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local DF = M[R .. "ServerScriptService/Server/Services/DishFactory.luau"]
local LB = M[R .. "ServerScriptService/Server/Services/LobbyBuilder.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local UK = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local Chest = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ChestUI.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player

local total, failed = 0, 0
local function check(group, name, ok, detail)
	total += 1
	if not ok then failed += 1 end
	out(string.format("%3d %s %-2s %s%s", total, if ok then "PASS" else "FAIL", group, name, if detail ~= nil then "   [" .. tostring(detail) .. "]" else ""))
end
local function findText(root, text)
	for _, d in root:GetDescendants() do
		if (d.ClassName == "TextButton" or d.ClassName == "TextLabel") and d.Text == text then return d end
	end
end
local function shown(d, root)
	while d and d ~= root do
		if d:IsA("GuiObject") and not d.Visible then return false end
		d = d.Parent
	end
	return true
end
local function visibleText(root, text)
	for _, d in root:GetDescendants() do
		if (d.ClassName == "TextButton" or d.ClassName == "TextLabel") and d.Text == text and shown(d, root) then return true end
	end
	return false
end
local partyAct = Remotes.Event("PartyAction")
local function act(a, v)
	call("client", function() partyAct:FireServer(a, v) end)
end

----------------------------------------------------------------------------------------------------
-- A: foam
----------------------------------------------------------------------------------------------------
local cannon
for i, tool in Config.Tools do if tool.Id == "Cannon" then cannon = i end end
local function foam(level) return Config.GetRunStats(1, { ScrubPower = level }, cannon, {}, {}, 0, nil, 0) end
local s0, s3, s6 = foam(0), foam(3), foam(6)
check("A", "a Foam Cannon has the new base rate (0.28 s a shot)", math.abs(s0.FoamInterval - 0.28) < 1e-6, s0.FoamInterval)
check("A", "every Power upgrade shoots faster", s0.FoamInterval > foam(1).FoamInterval and foam(1).FoamInterval > foam(2).FoamInterval and foam(2).FoamInterval > s3.FoamInterval and s3.FoamInterval > foam(4).FoamInterval and foam(4).FoamInterval > foam(5).FoamInterval)
check("A", "...down to a floor (about 8 shots a second at the top)", s6.FoamInterval >= 0.12 - 1e-6 and 1 / s6.FoamInterval <= 8.4, s6.FoamInterval)
check("A", "...and it can never go below the floor, however many upgrades", foam(40).FoamInterval >= 0.12 - 1e-6)
check("A", "more blobs can clean at once (10), each a shorter 1.4 s", s0.FoamMaxSplats == 10 and s0.FoamSeconds == 1.4)
check("A", "no other tool has foam stats", Config.GetRunStats(1, { ScrubPower = 6 }, 4, {}, {}, 0, nil, 0).FoamInterval == nil)
check("A", "the server's per-second request limit leaves room for the top rate", (function() return 1 / s6.FoamInterval < 14 end)())

----------------------------------------------------------------------------------------------------
-- B: pans and pots, dirt and the base disc
----------------------------------------------------------------------------------------------------
do
	local anchor = CFrame.new(0, 10, 0)
	local dish = DF.BuildDish("Pan", anchor, Config.Levels[3].Theme, { NextNumber = function() return 0.5 end, NextInteger = function(_, a) return a end })
	local cyl = {}
	for _, d in dish:GetDescendants() do
		if d:IsA("BasePart") and d.Shape == Enum.PartType.Cylinder then
			table.insert(cyl, { Name = d.Name, Bottom = d.Position.Y - d.Size.X / 2, Radius = d.Size.Y / 2 })
		end
	end
	check("B", "the pan has its body and its base disc as cylinders", #cyl >= 2, #cyl)
	local clash = false
	for i = 1, #cyl do
		for j = i + 1, #cyl do
			if math.abs(cyl[i].Bottom - cyl[j].Bottom) < 0.01 then clash = true end
		end
	end
	check("B", "no two of the pan's cylinders have their bottom face in the same plane (no z-fighting underneath)", not clash, (function()
		local t = {}
		for _, c in cyl do table.insert(t, string.format("%.2f", c.Bottom)) end
		return table.concat(t, ", ")
	end)())
end
_G.__side = "server"
DS.Get(p).Stats.Runs = 1 -- (a veteran: the full dirt load, not the light first dishwasher)
call("server", RS.StartRound, { p }, 3)
pump(1, G.frame)
do
	local folder = RS.GetGrimeFolder(p)
	local dishes = folder.Parent:FindFirstChild("Dishes")
	local perKind = {}
	for _, dish in dishes:GetChildren() do
		local kind = dish:GetAttribute("Kind")
		perKind[kind] = (perKind[kind] or 0) + 1
	end
	local firstId, ids = 1, {}
	for _, kind in Config.DishKinds do
		local n = perKind[kind] or 0
		ids[kind] = { First = firstId, Last = firstId + n - 1, N = n }
		firstId += n
	end
	local counts = {}
	for _, d in folder:GetChildren() do
		local id = d:GetAttribute("DishId")
		for kind, range in ids do
			if id >= range.First and id <= range.Last then counts[kind] = (counts[kind] or 0) + 1 end
		end
	end
	check("B", "Royal Banquet has its 2 pans and 2 pots", ids.Pan.N == 2 and ids.Pot.N == 2, tostring(ids.Pan.N) .. "/" .. tostring(ids.Pot.N))
	check("B", "Royal Banquet pans carry dirt (14 spots each)", (counts.Pan or 0) >= 20, counts.Pan)
	check("B", "Royal Banquet pots carry dirt (16 spots each)", (counts.Pot or 0) >= 24, counts.Pot)
end
-- (first run = the light dishwasher: 40% of the dirt, but never none)
pcall(RS.RemoveFromRun, p, "Test")
pump(1, G.frame)

----------------------------------------------------------------------------------------------------
-- C: Auto Drain
----------------------------------------------------------------------------------------------------
_G.__side = "server"
check("C", "without the pass the client says the tank can be full", CS.AutoDrain() == false)
call("server", RS.StartRound, { p }, 1)
pump(1, G.frame)
call("client", function() return Remotes.Function("RunRequest"):InvokeServer("Loaded") end)
pump(1, G.frame)
local hud = p.PlayerGui:FindFirstChild("HUD")
for _ = 1, 6 do CS.Run.Tank = CS.Run.TankMax CS.Changed:Fire("Run") pump(0.1, G.frame) end
check("C", "without the pass a full tank reads FULL! Sell at the drain", findText(hud, "FULL! Sell at the drain") ~= nil)
_G.__side = "server"
DS.SetPass(p, "AutoDrain", true)
pump(1, G.frame)
check("C", "with the pass the client knows (ClientState.AutoDrain)", CS.AutoDrain() == true)
for _ = 1, 6 do CS.Run.Tank = CS.Run.TankMax CS.Changed:Fire("Run") pump(0.1, G.frame) end
check("C", "the tank bar says Infinity tank", findText(hud, "Infinity tank") ~= nil)
check("C", "...and never FULL", findText(hud, "FULL! Sell at the drain") == nil or not shown(findText(hud, "FULL! Sell at the drain"), hud))
call("client", function() UK.OpenWindow("Upgrades") end)
pump(1, G.frame)
local book = p.PlayerGui:FindFirstChild("UpgradesUI")
check("C", "the Upgrade Book's Tank card says Infinity bag unlocked", book ~= nil and findText(book, "Infinity bag unlocked") ~= nil)
check("C", "...with an UNLOCKED button instead of a price", book ~= nil and findText(book, "UNLOCKED") ~= nil)
call("client", function() UK.CloseWindow() end)
_G.__side = "server"
DS.SetPass(p, "AutoDrain", false)
pcall(RS.RemoveFromRun, p, "Test")
pump(1, G.frame)

----------------------------------------------------------------------------------------------------
-- D / E / F: lobby behaviour for a brand-new player
----------------------------------------------------------------------------------------------------
local pads = LB.GetLobby().Pads
local pad1 = pads[1]
local function getRoot() return p.Character.HumanoidRootPart end
getRoot().CFrame = CFrame.new(pad1.Zone.Position + Vector3.new(60, 0, 40))
_G.__side = "server"
DS.ResetFirstRun(p)
-- (the section above set Runs = 1 for a moment, which queued the Daily popup: let it come, then close it)
pump(3.5, G.frame)
call("client", function() UK.CloseWindow() end)
pump(8, G.frame)
local card = p.PlayerGui:FindFirstChild("Welcome", true)
check("D", "after Reset first run the tutorial card comes (flags start afresh)", card.Visible == true)
local profile = DS.Get(p)
profile.TutorialDone = true
DS.PushMeta(p)
pump(1.5, G.frame)
check("D", "a player who already finished the tutorial gets no tutorial card", card.Visible == false)
pump(8, G.frame)
check("D", "...and it does not come back by itself", card.Visible == false)
DS.ResetFirstRun(p)
pump(8, G.frame)
check("D", "Reset first run brings it back", card.Visible == true)
-- (the card is up: dismiss it so it does not start a run in the checks below)
for _, d in card:GetDescendants() do
	if d.ClassName == "TextButton" and d.Visible then
		local label = d:FindFirstChildOfClass("TextLabel")
		if label and label.Text == "With friends instead" then G.getSignal(d, "Activated"):Fire() end
	end
end
pump(0.5, G.frame)

-- E: the arrow
local hint = p.PlayerGui:FindFirstChild("PadHint")
local function nearestPad(exclude)
	local best, bestD = nil, math.huge
	for _, pad in pads do
		if not exclude[pad] then
			local d = (pad.Zone.Position - getRoot().Position).Magnitude
			if d < bestD then best, bestD = pad, d end
		end
	end
	return best
end
local function anchorPad()
	local a = hint and hint.Adornee
	if not a then return nil end
	local best, bestD = nil, math.huge
	for _, pad in pads do
		local d = (pad.Zone.Position + Vector3.new(0, 17, 0) - a.Position).Magnitude
		if d < bestD then best, bestD = pad, d end
	end
	return best, bestD
end
pump(1.5, G.frame)
local nearest = nearestPad({})
check("E", "the arrow is on and over the nearest pad", hint ~= nil and hint.Enabled == true and anchorPad() == nearest)
local function holdTaken(set, seconds)
	for _ = 1, math.floor(seconds / 0.05) do
		for _, pad in pads do pad.Zone:SetAttribute("Taken", if set[pad] then true else nil) end
		pump(0.05, G.frame)
	end
end
holdTaken({ [nearest] = true }, 1.6)
local moved = anchorPad()
check("E", "when that pad is taken the arrow moves to a free one", hint.Enabled == true and moved ~= nearest and moved == nearestPad({ [nearest] = true }))
local all = {}
for _, pad in pads do all[pad] = true end
holdTaken(all, 1.6)
check("E", "when every pad is taken there is no arrow at all", hint.Enabled == false)
holdTaken({}, 1.6)
check("E", "and it is back when one is free again", hint.Enabled == true and anchorPad() == nearest)
-- the server really publishes Taken: the other player steps on a pad
local victim = G.victim
victim.Character.HumanoidRootPart.CFrame = CFrame.new(pads[2].Zone.Position)
pump(1, G.frame)
check("E", "a pad with a party on it is published as Taken by the server", pads[2].Zone:GetAttribute("Taken") == true, pads[2].Zone:GetAttribute("Taken"))
check("E", "...and the others are not", pads[1].Zone:GetAttribute("Taken") ~= true and pads[3].Zone:GetAttribute("Taken") ~= true)
-- the arrow, with that REAL party: stand right next to the busy pad
local busy = pads[2]
getRoot().CFrame = CFrame.new(busy.Zone.Position + Vector3.new(14, 0, 0))
pump(1.5, G.frame)
local pointedAt = anchorPad()
check("E", "standing next to a pad somebody is using, the arrow is NOT over it", pointedAt ~= busy and hint.Enabled == true, table.find(pads, pointedAt))
victim.Character.HumanoidRootPart.CFrame = CFrame.new(busy.Zone.Position + Vector3.new(0, 0, 150))

-- F: the Create Party screen
getRoot().CFrame = CFrame.new(pad1.Zone.Position)
local waited = 0
while not (CS.Party and CS.Party.Status == "Picking") and waited < 4 do pump(1 / 30, G.frame) waited += 1 / 30 end
check("F", "stepping on a pad opens the Create Party screen", CS.Party ~= nil and CS.Party.Status == "Picking")
check("F", "and that pad is published as Taken", pad1.Zone:GetAttribute("Taken") == true)
call("client", function() UK.OpenWindow("Shop") end)
pump(0.5, G.frame)
check("F", "while it is up the Shop does not open", not UK.IsWindowOpen("Shop"))
call("client", function() UK.OpenWindow("Pets") end)
pump(0.3, G.frame)
check("F", "...nor the Pets window", not UK.IsWindowOpen("Pets"))
local before = getRoot().Position
call("client", function() Chest.GoToChest() end)
pump(0.5, G.frame)
check("F", "the Event button / H does not carry you off the pad", (getRoot().Position - before).Magnitude < 0.5, (getRoot().Position - before).Magnitude)
act("Leave")
pump(1, G.frame)
check("F", "BACK leaves the pad", CS.Party == nil)
check("F", "...and the pad is free (not Taken) again", pad1.Zone:GetAttribute("Taken") ~= true, pad1.Zone:GetAttribute("Taken"))
call("client", function() UK.OpenWindow("Shop") end)
pump(0.5, G.frame)
check("F", "and the Shop opens again", UK.IsWindowOpen("Shop"))
call("client", function() UK.CloseWindow() end)

----------------------------------------------------------------------------------------------------
-- G: the finale
----------------------------------------------------------------------------------------------------
local abuse
for _, e in Config.UpcomingEvents do if e.Key == "AdminAbuse" then abuse = e end end
check("G", "before Admin Abuse starts it is still 'all the current chapters'", Config.ChapterFourAnnounced(abuse.Starts - 10) == false)
check("G", "from the moment it starts Chapter 4 is announced", Config.ChapterFourAnnounced(abuse.Starts) == true and Config.ChapterFourAnnounced(abuse.Ends + 86400) == true)
local ev4
for _, e in Config.UpcomingEvents do if e.Key == "Chapter4" then ev4 = e end end
check("G", "while Chapter 4's event has no date the 'coming soon' wording stays", Config.ChapterFourAnnounced(abuse.Ends + 86400) == true)
ev4.Soon = false
ev4.Starts = abuse.Ends + 100
check("G", "once Chapter 4 is open the 'coming soon' wording is gone (the finale moves to it)", Config.ChapterFourAnnounced(ev4.Starts + 10) == false)
ev4.Soon = true
ev4.Starts = 4102444800

out(string.format("== %d CHECKS: %d passed, %d FAILED", total, total - failed, failed))
