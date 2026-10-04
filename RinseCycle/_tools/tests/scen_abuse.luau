-- The Admin Abuse show: lockdown before it, banner + chat lines + vote + prize when it starts.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local me = G.player
local base, t0 = os.time(), _G.__now
Config.Now = function() return base + math.floor(_G.__now - t0) end
pump(1, G.frame)
local RSt = G.ReplicatedStorage
local cmd = RSt:FindFirstChild("AdminCommand")
local feedback, banners, says = {}, {}, {}
G.getSignal(RSt:FindFirstChild("AdminFeedback"), "OnClientEvent"):Connect(function(t) table.insert(feedback, t) end)
G.getSignal(RSt:FindFirstChild("AdminAnnouncement"), "OnClientEvent"):Connect(function(t) table.insert(banners, t) end)
G.getSignal(RSt:FindFirstChild("AbuseSay"), "OnClientEvent"):Connect(function(n, t) table.insert(says, n .. ": " .. t) end)
local booms, pillTexts = 0, {}
local bm = RSt:FindFirstChild("AbuseBoom")
if bm then G.getSignal(bm, "OnClientEvent"):Connect(function() booms += 1 end) end
local function pill() local f = G.find(me.PlayerGui, "Pill") return f and f.Visible, f and G.find(f, "Label") and G.find(f, "Label").Text end
local function asMe(c, t, x) call("client", function() cmd:FireServer(c, t or "", x or "") end) pump(0.5, G.frame) end
out("lockdown at the real time (weeks away): " .. tostring((Config.EventLockdown(Config.Now()))))
local bubbles0 = DS.Get(me).Bubbles
asMe("abuseshow", "0.25")
out("feedback: " .. tostring(feedback[#feedback]))
local locked, why = Config.EventLockdown(Config.Now())
out("lockdown now: " .. tostring(locked) .. "  " .. why)
pump(2, G.frame)
out("countdown pill: " .. tostring(select(2, pill())) .. " visible " .. tostring((pill())))
pump(18, G.frame)
out("pill when live: " .. tostring(select(2, pill())))
out("booms: " .. booms)
out("banners: " .. table.concat(banners, " | "))
pump(30, G.frame)
out("lockdown during the show: " .. tostring((Config.EventLockdown(Config.Now()))))
out("chat lines so far: " .. #says)
for _, l in says do out("  " .. l) end
local box = G.find(me.PlayerGui, "Box")
out("speech box visible: " .. tostring(box and box.Visible))
local giant = _G.__workspace:FindFirstChild("AbuseGiant")
out("giant in the lobby: " .. tostring(giant ~= nil))
pump(3, G.frame)
local card = G.find(me.PlayerGui, "Poll")
out("poll card visible: " .. tostring(card and card.Visible))
local vote = RSt:FindFirstChild("GlobalPollVote")
local answers = card and G.find(card, "Answers")
if answers then
	local btns = {}
	for _, b in answers:GetChildren() do if b:IsA("TextButton") then table.insert(btns, b) end end
	table.sort(btns, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	out("answers: " .. #btns .. " children: " .. #answers:GetChildren())
	for _, c in answers:GetChildren() do out("   " .. c.ClassName .. " " .. c.Name) end
	if btns[1] then G.getSignal(btns[1], "Activated"):Fire() end
end
pump(75, G.frame)
out("bubbles gained from the vote: " .. (DS.Get(me).Bubbles - bubbles0))
out("chat lines: " .. #says .. "  last: " .. tostring(says[#says]))
out("poll card after the vote ends (should be gone): " .. tostring(card and card.Parent.Parent.Visible))
local passes0 = 0
pump(130, G.frame)
out("chat lines by the pass round: " .. #says .. "  last: " .. tostring(says[#says]))
pump(185, G.frame)
card = G.find(me.PlayerGui, "Poll")
out("final poll visible: " .. tostring(card and card.Visible) .. "  heat attr: " .. tostring(RSt:GetAttribute("AbuseHeat")))
answers = card and G.find(card, "Answers")
if answers then
	local btns = {}
	for _, b in answers:GetChildren() do if b:IsA("TextButton") then table.insert(btns, b) end end
	table.sort(btns, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
	out("final answers: " .. #btns)
	if btns[1] then G.getSignal(btns[1], "Activated"):Fire() end
end
pump(70, G.frame)
out("final card gone: " .. tostring(not (card and card.Parent.Parent.Visible)))
local pets = 0
for _, p in DS.Get(me).Pets do if p.Id == "AdminAbuse" then pets += 1 end end
out("limited pets won: " .. pets)
pump(200, G.frame)
out("chat lines total: " .. #says .. "  giant alive: " .. tostring(_G.__workspace:FindFirstChild("AbuseGiant") ~= nil) .. "  booms " .. booms)
pump(60, G.frame)
asMe("abuseshow", "reset")
out("after reset lockdown: " .. tostring((Config.EventLockdown(Config.Now()))))
