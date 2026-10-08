-- The first-run tutorial: hint card, camera turn, Skip (asks first, pays nothing), finishing pays the reward once, and the
-- Pets button is always there afterwards.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local prof = DS.Get(p)
local rf = Remotes.Function("RunRequest")
local function tut(name)
	local gui = G.find(G.playerGui, "Tutorial")
	return gui and gui:FindFirstChild(name, true)
end
local function visible(inst)
	return inst ~= nil and inst.Visible == true
end
local function click(btn)
	G.getSignal(btn, "Activated"):Fire()
	pump(0.4, G.frame)
end
local function skipButton()
	local card = tut("Hint")
	for _, d in card:GetDescendants() do
		if d.ClassName == "TextButton" and tostring(d.Text):find("Skip") then
			return d
		end
	end
end
local function confirmButton(text)
	local c = tut("SkipConfirm")
	for _, d in c:GetDescendants() do
		if d.ClassName == "TextButton" and tostring(d.Text):find(text) then
			return d
		end
	end
end
local function hint()
	local label
	for _, d in tut("Hint"):GetDescendants() do
		if d.ClassName == "TextLabel" and d.TextSize == 22 then
			label = d
		end
	end
	local texts = {}
	for _, d in tut("Hint"):GetDescendants() do
		if d.ClassName == "TextLabel" and d.Text ~= "" and d.Text ~= "v" then
			table.insert(texts, d.Text)
		end
	end
	return table.concat(texts, " | ")
end
local function petsVisible()
	local b
	for _, d in G.find(G.playerGui, "HUD"):GetDescendants() do
		if d.ClassName == "TextButton" and (d.Name == "Pets" or d.Text == "Pets") then
			b = d
			break
		end
	end
	return b and b.Visible
end
local function startRun()
	_G.__side = "server"
	call("server", RS.StartRound, { p }, 1)
	pump(1, G.frame)
	call("client", function() return rf:InvokeServer("Loaded") end)
	pump(2, G.frame)
end
local function endRun()
	call("server", RS.DebugFinish, p)
	pump(8, G.frame)
	call("client", function() return rf:InvokeServer("ReturnToLobby") end)
	pump(3, G.frame)
end

out("-- brand-new player")
prof.Stats.DishesCleaned = 10
local gems0, bubbles0 = prof.Gems, prof.Bubbles
out("reset: " .. tostring(DS.ResetFirstRun(p)))
pump(1, G.frame)
out("meta TutorialDone=" .. tostring(CS.Meta and CS.Meta.TutorialDone))
startRun()
out("card visible: " .. tostring(visible(tut("HintHolder"))) .. " step=" .. tostring(CS.TutorialStep))
out("hint: " .. hint())
local cam = G.workspace.CurrentCamera
out("camera type while turning: " .. tostring(cam and cam.CameraType))
pump(6, G.frame)
out("hint after the camera turn: " .. hint())
out("camera type after: " .. tostring(cam and cam.CameraType))
out("pets button in the tutorial: " .. tostring(petsVisible()))
out("-- Skip asks first")
click(skipButton())
out("confirm visible: " .. tostring(visible(tut("SkipConfirm"))))
click(confirmButton("Keep"))
out("after Keep going: confirm visible=" .. tostring(visible(tut("SkipConfirm"))) .. " tutorial step=" .. tostring(CS.TutorialStep) .. " done=" .. tostring(prof.TutorialDone))
click(skipButton())
click(confirmButton("Skip it"))
pump(1, G.frame)
out(string.format("after Skip it: done=%s step=%s card=%s reward paid: gems %+d bubbles %+d", tostring(prof.TutorialDone), tostring(CS.TutorialStep), tostring(visible(tut("HintHolder"))), prof.Gems - gems0, prof.Bubbles - bubbles0))
out("pets button after: " .. tostring(petsVisible()))
endRun()
out("pets button back in the lobby: " .. tostring(petsVisible()))

out("-- finishing it pays once")
DS.ResetFirstRun(p)
pump(1, G.frame)
gems0, bubbles0 = prof.Gems, prof.Bubbles
startRun()
local run = CS.Run
call("server", RS.AddCoins, p, 100000)
local folder = RS.GetGrimeFolder(p)
-- clean a few things: the dish counter drives steps 1-3
local arena = G.workspace.Arenas:FindFirstChild(run.ArenaName)
out("arena: " .. tostring(arena ~= nil) .. " dishes: " .. tostring(arena and arena:FindFirstChild("Dishes") ~= nil))
for _ = 1, 3 do
	call("server", RS.DebugFinish, p)
	break
end
pump(2, G.frame)
out("step now: " .. tostring(CS.TutorialStep) .. " hint: " .. hint())
local r1 = call("client", function() return Remotes.Function("MetaRequest"):InvokeServer("TutorialDone", true) end)
out(string.format("finish request: ok=%s message=%s done=%s gems %+d bubbles %+d", tostring(r1 and r1.Ok), tostring(r1 and r1.Message), tostring(prof.TutorialDone), prof.Gems - gems0, prof.Bubbles - bubbles0))
local r2 = call("client", function() return Remotes.Function("MetaRequest"):InvokeServer("TutorialDone", true) end)
out(string.format("second request: gems %+d (same as before = paid once)", prof.Gems - gems0))
