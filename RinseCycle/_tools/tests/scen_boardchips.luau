-- The board chips ("Next page" + "Refresh") as dumps for guirender.py, on a computer and at phone sizes.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local p = G.player
local CS = game:GetService("CollectionService")
local M = G.modules
local UK = M["/home/user/Roblox/RinseCycle/StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
call("client", function() UK.CloseWindow() end)
local board = CS:GetTagged("LeaderboardBoard")[1]
p.Character.HumanoidRootPart.CFrame = board.CFrame * CFrame.new(0, -5, 10)
local function size(w, h)
	local probe = p.PlayerGui:FindFirstChild("UIKitProbeFull")
	call("client", function()
		probe.AbsoluteSize = Vector2.new(w, h)
		G.getSignal(probe, "AbsoluteSize"):Fire()
	end)
	pump(60, G.frame)
end
local function shot(name, w, h)
	size(w, h)
	local gui = p.PlayerGui:FindFirstChild("BoardChips")
	local chips = G.find(gui, "Chips")
	out(string.format("%s %dx%d: visible=%s size=%s", name, w, h, tostring(chips and chips.Visible), tostring(chips and chips.Size)))
	G.dumpGui(gui, OUT .. "chips_" .. name .. ".json")
end
shot("pc", 1280, 720)
local UIS = game:GetService("UserInputService")
call("client", function() UIS.GamepadEnabled = true end)
shot("pad", 1280, 720)
call("client", function() UIS.GamepadEnabled = false; UIS.TouchEnabled = true; UIS.KeyboardEnabled = false end)
shot("land", 844, 390)
shot("port", 390, 844)
shot("small", 667, 375)
