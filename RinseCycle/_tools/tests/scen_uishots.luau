-- Phone-size screenshots (dumps for guirender.py): the tutorial card and its Skip question, the pet panel with the delete
-- question, and the club kick question.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local PS = M[R .. "ServerScriptService/Server/Services/PetService.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local prof = DS.Get(p)
prof.Gems, prof.Bubbles = 5000, 50000
prof.Stats.DishesCleaned = 10
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
local function click(btn)
	G.getSignal(btn, "Activated"):Fire()
	pump(0.5, G.frame)
end
local function findButton(root, text)
	for _, d in root:GetDescendants() do
		if d.ClassName == "TextButton" and tostring(d.Text):find(text) then
			return d
		end
	end
end
-- Tutorial
size(844, 390)
DS.ResetFirstRun(p)
pump(1, G.frame)
_G.__side = "server"
call("server", RS.StartRound, { p }, 1)
pump(1, G.frame)
call("client", function() return Remotes.Function("RunRequest"):InvokeServer("Loaded") end)
pump(8, G.frame)
local tut = p.PlayerGui:FindFirstChild("Tutorial")
G.dumpGui(tut, OUT .. "tut_card.json")
click(findButton(tut, "Skip tutorial"))
G.dumpGui(tut, OUT .. "tut_confirm.json")
click(findButton(tut, "Keep going"))
call("server", RS.DebugFinish, p)
pump(8, G.frame)
call("client", function() return Remotes.Function("RunRequest"):InvokeServer("ReturnToLobby") end)
pump(3, G.frame)
-- Pets
local given = 0
for id, def in Config.Pets do
	if not def.Limited and given < 3 then
		local ok = call("server", PS.GivePet, p, id)
		out("give " .. id .. " -> " .. tostring(ok))
		given += 1
	end
end
out("pets owned: " .. #prof.Pets)
pump(1, G.frame)
for _, s in { { "land", 844, 390 }, { "port", 390, 844 } } do
	size(s[2], s[3])
	call("client", function()
		UIKit.CloseWindow()
		UIKit.OpenWindow("Pets")
	end)
	pump(1.5, G.frame)
	local gui = p.PlayerGui:FindFirstChild("PetsUI")
	-- pick the first pet card
	local card
	for _, d in gui:GetDescendants() do
		if d.ClassName == "TextButton" and d.Name == "Hit" then
			card = d
			break
		end
	end
	out(s[1] .. " pet card found: " .. tostring(card ~= nil))
	if card then
		click(card)
	end
	local del = findButton(gui, "Delete")
	if del then
		click(del)
	end
	G.dumpGui(gui, OUT .. "pets_delete_" .. s[1] .. ".json")
	call("client", function() UIKit.CloseWindow() end)
end
