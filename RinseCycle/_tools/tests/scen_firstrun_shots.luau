-- Dumps the two new-player cards for guirender.py (the START CLEANING card, the come-back card) at desktop and phone size.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local UK = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local p = G.player
local function size(w, h)
	local probe = p.PlayerGui:FindFirstChild("UIKitProbeFull")
	call("client", function()
		probe.AbsoluteSize = Vector2.new(w, h)
		G.getSignal(probe, "AbsoluteSize"):Fire()
	end)
	pump(1.5, G.frame)
end
local welcome = p.PlayerGui:FindFirstChild("Welcome", true)
local back = p.PlayerGui:FindFirstChild("ComeBack", true)
local function shot(tag, w, h)
	size(w, h)
	G.dumpGui(welcome.Parent.Parent, OUT .. "welcome_" .. tag .. ".json")
	-- the loop hides the come-back card on its next tick, so dump it in the same breath
	welcome.Visible = false
	back.Visible = true
	back.Position = UDim2.new(0.5, 0, 1, -20)
	back.UIScale.Scale = math.clamp((UK.CanvasSize().X - 24) / 540, 0.5, 1)
	G.dumpGui(welcome.Parent.Parent, OUT .. "comeback_" .. tag .. ".json")
	back.Visible = false
end
shot("desktop", 1280, 720)
shot("phone", 740, 360)
-- the same card for someone who is with friends
p:SetAttribute("FriendsHere", true)
welcome.Visible = true
pump(1, G.frame)
size(1280, 720)
G.dumpGui(welcome.Parent.Parent, OUT .. "welcome_friends_desktop.json")
size(740, 360)
G.dumpGui(welcome.Parent.Parent, OUT .. "welcome_friends_phone.json")
out("dumped")
