-- Phone-size check: sets the screen size, opens each new window, dumps it for guirender.py.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local prof = DS.Get(p)
prof.Gems = 5000
prof.Bubbles = 50000
DS.PushMeta(p)
local camera = _G.__workspace.CurrentCamera
call("client", function()
	local UIS = game:GetService("UserInputService")
	UIS.TouchEnabled = true
	UIS.KeyboardEnabled = false
end)
local sizes = { { "land", 844, 390 }, { "port", 390, 844 } }
call("client", function()
	Remotes.Function("ClubRequest"):InvokeServer("Create", { Name = "Soap Squad", Tag = "SOAP", Public = true })
end)
pump(1, G.frame)
for _, s in sizes do
	local probe = p.PlayerGui:FindFirstChild("UIKitProbeFull")
	call("client", function()
		probe.AbsoluteSize = Vector2.new(s[2], s[3])
		G.getSignal(probe, "AbsoluteSize"):Fire()
	end)
	pump(1.5, G.frame)
	local canvas = call("client", function() return UIKit.CanvasSize() end)
	local scale = call("client", function() return UIKit.GetScale() end)
	out(string.format("%s %dx%d: canvas %dx%d scale %.2f", s[1], s[2], s[3], canvas.X, canvas.Y, scale))
	for _, w in { { "Clubs", "ClubsUI" }, { "Ranks", "RanksUI" }, { "Pets", "PetsUI" }, { "Shop", "ShopUI" }, { "Free", "RewardsUI" } } do
		call("client", function()
			UIKit.CloseWindow()
			UIKit.OpenWindow(w[1])
		end)
		pump(1.5, G.frame)
		local gui = p.PlayerGui:FindFirstChild(w[2])
		if gui then
			G.dumpGui(gui, OUT .. "mob_" .. s[1] .. "_" .. w[1] .. ".json")
		else
			out("no gui " .. w[2])
		end
	end
	call("client", function() UIKit.CloseWindow() end)
	pump(1, G.frame)
	G.dumpGui(p.PlayerGui.HUD, OUT .. "mob_" .. s[1] .. "_HUD.json")
end
