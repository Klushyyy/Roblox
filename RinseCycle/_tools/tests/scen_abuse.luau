-- The Admin Abuse show: lockdown before it, banner + chat lines + vote + prize when it starts.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local me = G.player
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
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
local bubbles0, gems0 = DS.Get(me).Bubbles, DS.Get(me).Gems
asMe("abuseshow", "0.25")
out("feedback: " .. tostring(feedback[#feedback]))
out("lockdown now: " .. tostring((Config.EventLockdown(Config.Now()))))
local function tl(label) -- t = seconds into the show
	out(string.format("[%s] says=%d booms=%d heat=%s obby=%s", label, #says, booms, tostring(RSt:GetAttribute("AbuseHeat")), tostring(RSt:GetAttribute("AbuseObbyOpen"))))
end
call("client", function() UIKit.CloseWindow() end)
local function pollVisible()
	call("client", function() UIKit.CloseWindow() end)
	pump(0.7, G.frame)
	local card = G.find(me.PlayerGui, "Poll")
	return card and card.Parent.Parent.Visible
end
pump(18, G.frame)
out("pill when live: " .. tostring(select(2, pill())))
pump(20, G.frame) tl("t~23")
pump(20, G.frame) out("poll 1 visible: " .. tostring(pollVisible())) tl("t~43")
pump(45, G.frame) out("poll 1 visible after it ends (should be false): " .. tostring(pollVisible()))
out("bubbles gained: " .. (DS.Get(me).Bubbles - bubbles0))
pump(60, G.frame) tl("t~170") out("last says: " .. says[#says-1] .. " / " .. says[#says])
pump(70, G.frame) tl("t~240")
local WS = _G.__workspace
out("hole 1 pieces folder: " .. tostring(WS:FindFirstChild("HolePieces1") ~= nil))
local lobbyM = WS:FindFirstChild("Lobby")
out("obby built: " .. tostring(lobbyM and lobbyM:FindFirstChild("Obby") ~= nil))
pump(60, G.frame) tl("t~300 (obby should be open)")
out("banners: " .. #banners .. "  last: " .. tostring(banners[#banners]))
pump(45, G.frame) tl("t~345 (heat)") out("final poll visible: " .. tostring(pollVisible()))
pump(80, G.frame)
local pets = 0
for _, p in DS.Get(me).Pets do if p.Id == "AdminAbuse" then pets += 1 end end
out("limited pets won: " .. pets .. "   final poll visible (should be false): " .. tostring(pollVisible()))
pump(150, G.frame) tl("t~600")
local seen = {}
local dupes = 0
for _, l in says do if seen[l] then dupes += 1 end seen[l] = true end
out("repeated lines: " .. dupes)
pump(110, G.frame) tl("t~700 (over)")
lobbyM = WS:FindFirstChild("Lobby")
out("obby after the show (should be false): " .. tostring(lobbyM and lobbyM:FindFirstChild("Obby") ~= nil) .. "   hole pieces left: " .. tostring(WS:FindFirstChild("HolePieces1") ~= nil))
out("lockdown after the show: " .. tostring((Config.EventLockdown(Config.Now()))) .. "   banners: " .. tostring(banners[#banners]))
asMe("abuseshow", "reset")
out("after reset lockdown: " .. tostring((Config.EventLockdown(Config.Now()))))
