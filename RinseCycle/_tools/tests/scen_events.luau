-- Treasure Chest event, Clubs, the Next Event zone and the 2-wide button grid.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Club = M[R .. "ServerScriptService/Server/Services/ClubService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local p = G.player
local prof = DS.Get(p)
local function chest(action, value)
	local r = call("client", function()
		return Remotes.Function("ChestRequest"):InvokeServer(action, value)
	end)
	pump(0.7, G.frame)
	local names = {}
	for _, x in (r and r.Rewards) or {} do
		table.insert(names, x.Text)
	end
	out(string.format("chest %-5s %s -> ok=%s %s [%s]", action, tostring(value or ""), tostring(r and r.Ok), tostring(r and r.Error or ""), table.concat(names, ", ")))
end
local function club(action, value)
	local r = call("client", function()
		return Remotes.Function("ClubRequest"):InvokeServer(action, value)
	end)
	pump(0.6, G.frame)
	local extra = ""
	if r and r.Club then
		extra = string.format(" club=[%s] %s n=%s public=%s code=%s", r.Club.Tag, r.Club.Name, tostring(r.Club.Count), tostring(r.Club.Public), tostring(r.Club.Code))
	end
	if r and r.Clubs then
		extra ..= " clubs=" .. #r.Clubs
	end
	out(string.format("club %-8s -> ok=%s %s%s", action, tostring(r and r.Ok), tostring(r and (r.Error or r.Message) or ""), extra))
	return r
end
-- Chest odds add up and the packs are popcorn-priced.
for _, pack in Config.ChestEvent.Packs do
	out(string.format("pack x%d R$%d = %.1f each", pack.Count, pack.Price, pack.Price / pack.Count))
end
out("free left (meta): " .. tostring(CS.Meta and CS.Meta.ChestFreeLeft))
chest("Free")
chest("Free")
chest("Test", 3)
chest("Test", 10)
out("opened: " .. prof.ChestsOpened .. " free left: " .. tostring(CS.Meta and CS.Meta.ChestFreeLeft))
-- Every reward kind gives something.
local EventService = M[R .. "ServerScriptService/Server/Services/EventService.luau"]
local before = { prof.Bubbles, prof.Gems, #prof.Pets }
local counts = {}
for _ = 1, 400 do
	for _, res in EventService.Open(p, 1) do
		counts[res.Index] = (counts[res.Index] or 0) + 1
	end
end
local parts = {}
for i, r in Config.ChestEvent.Rewards do
	table.insert(parts, string.format("%s=%d", Config.ChestRewardName(r), counts[i] or 0))
end
out("400 opens: " .. table.concat(parts, " | "))
out(string.format("bubbles +%d gems +%d pets +%d", prof.Bubbles - before[1], prof.Gems - before[2], #prof.Pets - before[3]))
-- The window and reveal.
call("client", function()
	UIKit.OpenWindow("Chest")
end)
pump(1, G.frame)
local chestGui = p.PlayerGui:FindFirstChild("ChestUI")
out("chest window rows: " .. #(chestGui and chestGui:FindFirstChild("List", true) and chestGui:FindFirstChild("List", true):GetChildren() or {}))
call("client", function()
	UIKit.CloseWindow()
end)

-- Clubs.
prof.Gems = 100
club("Create", { Name = "Soap Squad", Tag = "SOAP", Public = true, ReqLevel = 0, ReqRebirths = 0 })
prof.Gems = 2000
club("Create", { Name = "x", Tag = "SOAP" })
club("Create", { Name = "Soap Squad", Tag = "S" })
local made = club("Create", { Name = "Soap Squad", Tag = "soap", Public = false, ReqLevel = 0, ReqRebirths = 0 })
out("gems after create: " .. prof.Gems .. " tag attr: " .. tostring(p:GetAttribute("ClubTag")) .. " profile club: " .. prof.ClubId)
club("Create", { Name = "Another", Tag = "ANO" })
club("Mine")
club("Top")
club("Find", "soap")
club("Find", made.Club and made.Club.Code or "")
club("Settings", { Public = true, ReqLevel = 2, ReqRebirths = 5 })
club("NewCode")
Club.FlushPoints()
prof.Stats.BubblesEarned += 1234
Club.FlushPoints()
local r = club("Mine")
out("points: " .. tostring(r.Club and r.Club.Points))
club("Leave")
out("after leave: club '" .. prof.ClubId .. "' tag " .. tostring(p:GetAttribute("ClubTag")))
prof.ClubMovedAt = 0
club("Find", "soap")
club("JoinCode", "ZZZZZZ")
-- The club window renders each tab.
call("client", function()
	UIKit.OpenWindow("Clubs")
end)
pump(1.5, G.frame)
local clubsGui = p.PlayerGui:FindFirstChild("ClubsUI")
out("clubs window create card: " .. tostring(clubsGui and clubsGui:FindFirstChild("Create", true) ~= nil))
-- HUD grid.
local col = p.PlayerGui.HUD:FindFirstChild("RightColumn", true)
local vis = {}
for _, b in col:GetChildren() do
	if b:IsA("GuiObject") and b.Visible then
		table.insert(vis, b.LayoutOrder .. ":" .. b.Text)
	end
end
table.sort(vis)
out("right grid: " .. table.concat(vis, " ") .. " grid=" .. tostring(col:FindFirstChildOfClass("UIGridLayout") ~= nil))
-- Next event zone.
local zone
for _, d in G.workspace:GetDescendants() do
	if d.Name == "NextEventZone" then
		zone = d
	end
end
out("zone built: " .. tostring(zone ~= nil) .. "  next: " .. tostring(Config.NextEvent() and Config.NextEvent().Name))
if zone and p.Character then
	p.Character.HumanoidRootPart.CFrame = zone.CFrame
	pump(1.2, G.frame)
	local card = p.PlayerGui:FindFirstChild("NextEvent", true)
	out("card visible: " .. tostring(card and card.Visible))
end
local chestPart
for _, d in G.workspace:GetDescendants() do
	if d.Name == "ChestBox" then
		chestPart = d
	end
end
out("lobby chest: " .. tostring(chestPart ~= nil))
-- Joining: requirements and private clubs (a second "account" = clearing our membership by hand).
prof.ClubMovedAt = 0
local c2 = club("Create", { Name = "Pro Scrubbers", Tag = "PRO", Public = true, ReqLevel = 3, ReqRebirths = 2 })
DS.SetClub(p, "", "", false)
prof.ClubMovedAt = 0
local rebirths, times = prof.Rebirths, prof.BestTimes
prof.Rebirths, prof.BestTimes = 0, {}
club("Join", c2.Club.Id)
prof.Rebirths = 3
club("Join", c2.Club.Id)
prof.ClubMovedAt = os.time()
DS.SetClub(p, "", "", true)
club("Join", c2.Club.Id)
prof.Rebirths, prof.BestTimes = rebirths, times
