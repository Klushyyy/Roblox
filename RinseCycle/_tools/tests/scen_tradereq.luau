local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local me, other = G.player, G.victim
pump(1, G.frame)
local trade = Remotes.Event("TradeAction")
local toasts = {}
G.getSignal(Remotes.Event("Notify"), "OnClientEvent"):Connect(function(t) table.insert(toasts, t) end)
local function asMe(a, v) call("client", function() trade:FireServer(a, v) end) pump(0.1, G.frame) end
local function asOther(a, v) call("server", function() G.getSignal(trade, "OnServerEvent"):Fire(other, a, v) end) pump(0.1, G.frame) end
UIKit.OpenWindow("Trade")
pump(0.3, G.frame)
local function btn()
	for _, d in G.find(G.playerGui, "TradeUI"):GetDescendants() do
		if d.ClassName == "TextButton" and (tostring(d.Text):find("Request") or tostring(d.Text):find("Wait")) then return d.Text end
	end
end
out("picker button: " .. tostring(btn()))
asMe("Request", other.UserId)
pump(0.3, G.frame)
out("after request: " .. tostring(btn()))
asMe("CancelRequest", other.UserId)
pump(0.3, G.frame)
out("after cancel: " .. tostring(btn()))
pump(3, G.frame)
asMe("Request", other.UserId)
out("re-request: " .. tostring(toasts[#toasts]))
-- other asks me, I accept -> trusted: asking again straight away works
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local invites = 0
G.getSignal(Remotes.Event("TradeState"), "OnClientEvent"):Connect(function(a) if a == "Invite" then invites += 1 end end)
asOther("Request", me.UserId)
asMe("Accept", other.UserId)
pump(0.3, G.frame)
asMe("Cancel")
pump(3, G.frame)
asOther("Request", me.UserId)
out("invites received: " .. invites .. " (2 = the second one got through without a wait)")
DS.Get(me).Pets = { { Uid = "1", Id = next(Config.Pets) } }
asMe("Accept", other.UserId)
asMe("Add", "1")
asOther("Ready", true) asMe("Ready", true)
for t = 1, 4 do
	pump(0.8, G.frame)
	for _, d in G.find(G.playerGui, "TradeUI"):GetDescendants() do
		if d.ClassName == "TextLabel" and tostring(d.Text):find("^Trading") and not tostring(d.Text):find("with") then out("countdown: " .. d.Text) end
	end
end
out("my pets after: " .. #DS.Get(me).Pets)
