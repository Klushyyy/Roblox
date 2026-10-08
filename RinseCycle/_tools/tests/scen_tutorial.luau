-- The first-run tutorial: hint card, camera turn, Skip (asks first, pays nothing), the whole interactive walk-through
-- (scrub, sell, open the book, the Next tour, buying Power), finishing pays the reward once, the HUD comes back only after
-- the reward popup is dismissed, and no loot toasts while it runs.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
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
	for _, d in tut("Hint"):GetDescendants() do
		if d.ClassName == "TextButton" and tostring(d.Text):find("Skip") then
			return d
		end
	end
end
local function nextButton()
	for _, d in tut("Hint"):GetDescendants() do
		if d.ClassName == "TextButton" and tostring(d.Text) == "Next" then
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
	local texts = {}
	for _, d in tut("Hint"):GetDescendants() do
		if d.ClassName == "TextLabel" and d.Text ~= "" and d.Text ~= "v" then
			table.insert(texts, d.Text)
		end
	end
	return table.concat(texts, " | ")
end
local function hudVisible(name)
	local b
	for _, d in G.find(G.playerGui, "HUD"):GetDescendants() do
		if d.Name == name or (d.ClassName == "TextButton" and d.Text == name) then
			b = d
			break
		end
	end
	return b and b.Visible
end
local function spot()
	local dims = 0
	for _, n in { "DimTop", "DimBottom", "DimLeft", "DimRight" } do
		if visible(tut(n)) then dims += 1 end
	end
	return string.format("dim panels=%d ring=%s holeBlock=%s", dims, tostring(visible(tut("SpotRing"))), tostring(visible(tut("HoleBlock"))))
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
local toasts = {}
G.getSignal(Remotes.Event("Notify"), "OnClientEvent"):Connect(function(t, k) table.insert(toasts, t) end)

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
out("in the tutorial: pets button=" .. tostring(hudVisible("Pets")) .. " bubbles pill=" .. tostring(hudVisible("TopCurrency")) .. " gems pill=" .. tostring(hudVisible("Gems")) .. " level bar=" .. tostring(hudVisible("TopBar")))
out("Next button on an action step: " .. tostring(visible(nextButton())))
out("-- Skip asks first")
click(skipButton())
out("confirm visible: " .. tostring(visible(tut("SkipConfirm"))))
click(confirmButton("Keep"))
out("after Keep going: confirm visible=" .. tostring(visible(tut("SkipConfirm"))) .. " tutorial step=" .. tostring(CS.TutorialStep) .. " done=" .. tostring(prof.TutorialDone))
click(skipButton())
click(confirmButton("Skip it"))
pump(1, G.frame)
out(string.format("after Skip it: done=%s step=%s card=%s reward paid: gems %+d bubbles %+d", tostring(prof.TutorialDone), tostring(CS.TutorialStep), tostring(visible(tut("HintHolder"))), prof.Gems - gems0, prof.Bubbles - bubbles0))
out("after: pets button=" .. tostring(hudVisible("Pets")) .. " bubbles pill=" .. tostring(hudVisible("TopCurrency")))
endRun()
out("pets button back in the lobby: " .. tostring(hudVisible("Pets")))

out("-- the whole walk-through")
DS.ResetFirstRun(p)
pump(1, G.frame)
gems0, bubbles0 = prof.Gems, prof.Bubbles
startRun()
local run = CS.Run
out("start coins: " .. tostring(run.Coins) .. " (step 3 must not be skipped by them)")
-- 1-2: scrub a dirt spot
local folder = RS.GetGrimeFolder(p)
local dirt
for _, d in (folder and folder:GetDescendants() or {}) do
	if d.Name == "Dirt" and d:GetAttribute("HP") then
		dirt = d
		break
	end
end
local root = p.Character.HumanoidRootPart
root.CFrame = CFrame.new(dirt.Position + Vector3.new(0, 0, 4))
local scrub = Remotes.Event("Scrub")
for _ = 1, 40 do
	call("client", function() scrub:FireServer(dirt.Position, true) end)
	pump(0.12, G.frame)
end
pump(1, G.frame)
out("after scrubbing: step=" .. tostring(CS.TutorialStep) .. " hint: " .. hint())
-- keep scrubbing other dirt until step 3
for _, d in (folder and folder:GetDescendants() or {}) do
	if CS.TutorialStep and CS.TutorialStep >= 3 then break end
	if d.Name == "Dirt" and d:GetAttribute("HP") and d.Parent then
		root.CFrame = CFrame.new(d.Position + Vector3.new(0, 0, 4))
		for _ = 1, 30 do
			call("client", function() scrub:FireServer(d.Position, true) end)
			pump(0.1, G.frame)
		end
	end
end
pump(1, G.frame)
out("step=" .. tostring(CS.TutorialStep) .. " tank=" .. tostring(CS.Run.Tank) .. "/" .. tostring(CS.Run.TankMax) .. " hint: " .. hint())
-- 3: sell
local drain = RS.GetDrainPart(p)
local coinsBefore = CS.Run.Coins
root.CFrame = CFrame.new(drain.Position + Vector3.new(0, 3, 0))
pump(3, G.frame)
out("after the drain: coins " .. tostring(coinsBefore) .. " -> " .. tostring(CS.Run.Coins) .. " step=" .. tostring(CS.TutorialStep) .. " hint: " .. hint())
out("book button lit: " .. spot() .. " allowBook=" .. tostring(CS.TutorialAllowBook) .. " upgrades button=" .. tostring(hudVisible("Upgrades")))
-- 4: other keys do nothing, the book key opens it
local UIS = game:GetService("UserInputService")
-- (a real key press is not simulated here: the window is opened the way the button does it)
call("client", function() UIKit.OpenWindow("Upgrades") end)
pump(1, G.frame)
out("book open: " .. tostring(UIKit.IsWindowOpen("Upgrades")) .. " hint: " .. hint())
out("Next visible: " .. tostring(visible(nextButton())) .. " " .. spot())
local clicks = 0
while nextButton() and visible(nextButton()) and clicks < 14 do
	if clicks == 0 or clicks == 6 then
		out("  tour: " .. hint())
	end
	click(nextButton())
	clicks += 1
	pump(0.3, G.frame)
end
out("Next presses: " .. clicks .. " step now=" .. tostring(CS.TutorialStep) .. " hint: " .. hint() .. " " .. spot())
-- 5: buy Power
local before = CS.Run.Upgrades.ScrubPower
call("client", function() return rf:InvokeServer("BuyUpgrade", "ScrubPower") end)
pump(1.5, G.frame)
out("bought Power: " .. tostring(before) .. " -> " .. tostring(CS.Run.Upgrades.ScrubPower) .. " step=" .. tostring(CS.TutorialStep) .. " card=" .. tostring(visible(tut("HintHolder"))) .. " book open=" .. tostring(UIKit.IsWindowOpen("Upgrades")))
out(string.format("reward: gems %+d bubbles %+d  popup up: %s", prof.Gems - gems0, prof.Bubbles - bubbles0, tostring(visible(G.find(G.playerGui, "Celebrate") and G.find(G.playerGui, "Celebrate"):FindFirstChild("Celebrate", true)))))
out("HUD while the popup is up: step=" .. tostring(CS.TutorialStep) .. " bubbles pill=" .. tostring(hudVisible("TopCurrency")) .. " pets=" .. tostring(hudVisible("Pets")))
call("client", function() UIKit.CloseWindow() end)
pump(2, G.frame)
out("after Awesome: step=" .. tostring(CS.TutorialStep) .. " bubbles pill=" .. tostring(hudVisible("TopCurrency")) .. " pets=" .. tostring(hudVisible("Pets")) .. " level bar=" .. tostring(hudVisible("TopBar")))
local r2 = call("client", function() return Remotes.Function("MetaRequest"):InvokeServer("TutorialDone", true) end)
out(string.format("second request pays nothing more: gems %+d (same as above)", prof.Gems - gems0))
