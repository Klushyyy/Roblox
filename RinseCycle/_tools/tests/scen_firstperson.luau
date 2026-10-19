-- First person (v2.22.0): the camera is locked to first person for the whole run on every device and is the normal camera in the
-- lobby; the mouse is let go of for windows / pop-ups / results / Alt; the middle dot shows while the mouse is locked; the tutorial's
-- Skip button does not hold the mouse but its spotlight does; the view is turned toward the dishes; plate tops are in reach from the
-- rack without flying; your own name tag is hidden in first person (others stay).
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local UIS = game:GetService("UserInputService")
local rf = Remotes.Function("RunRequest")
local scrub = Remotes.Event("Scrub")

local fails = 0
local function check(cond, label)
	if cond then
		out("ok    " .. label)
	else
		fails += 1
		out("FAIL  " .. label)
	end
end
local function screenOf(name, child)
	local gui = G.find(G.playerGui, name)
	return gui and (if child then gui:FindFirstChild(child, true) else gui)
end
local function modal()
	return screenOf("FirstPersonMouse", "ModalMouse")
end
local function modalUp()
	local m = modal()
	return m ~= nil and m.Visible == true
end
local function dot()
	local c = screenOf("Spray", "Crosshair")
	return c ~= nil and c.Visible == true
end
local function startRun(level)
	call("server", RS.StartRound, { p }, level or 1)
	pump(1, G.frame)
	call("client", function() return rf:InvokeServer("Loaded") end)
	pump(1.5, G.frame)
end
local function endRun()
	call("server", RS.DebugFinish, p)
	pump(2, G.frame)
end
local function backToLobby()
	if CS.Run and CS.Run.Phase ~= "Complete" then
		call("server", RS.DebugFinish, p)
		pump(2, G.frame)
	end
	call("client", function() return rf:InvokeServer("ReturnToLobby") end)
	pump(3, G.frame)
end

out("-- the lobby is not first person")
UIS.MouseBehavior = Enum.MouseBehavior.Default
check(p.CameraMode == nil or p.CameraMode == Enum.CameraMode.Classic, "lobby camera mode is Classic (" .. tostring(p.CameraMode) .. ")")
check(not modalUp(), "no mouse-freeing button in the lobby")
check(not dot(), "no centre dot in the lobby")

out("-- a run is first person")
startRun(1)
check(CS.Run ~= nil, "in a run")
check(p.CameraMode == Enum.CameraMode.LockFirstPerson, "run camera mode is LockFirstPerson (" .. tostring(p.CameraMode) .. ")")
check(modal() ~= nil and not modalUp(), "the mouse-freeing button exists but is hidden while the mouse is locked")
check(dot(), "centre dot shows while the mouse is locked")

out("-- windows free the mouse (Tab / Q = the Upgrade book)")
call("client", function() UIKit.OpenWindow("Upgrades") end)
pump(0.3, G.frame)
check(UIKit.IsWindowOpen("Upgrades"), "Upgrades window is open")
check(modalUp(), "mouse-freeing button is up with a window open")
check(UIS.MouseBehavior == Enum.MouseBehavior.Default, "mouse behaviour is Default with a window open")
check(not dot(), "centre dot is hidden with a window open")
call("client", function() UIKit.CloseWindow() end)
pump(0.3, G.frame)
check(not modalUp(), "mouse locks again once the window is closed")
check(UIS.MouseBehavior == Enum.MouseBehavior.LockCenter, "mouse behaviour is LockCenter again (" .. tostring(UIS.MouseBehavior) .. ")")
check(dot(), "centre dot is back")

out("-- Alt / Ctrl hold frees the mouse")
for _, key in { Enum.KeyCode.LeftAlt, Enum.KeyCode.LeftControl } do
	G.holdKey(key, true)
	pump(0.3, G.frame)
	check(modalUp() and UIS.MouseBehavior == Enum.MouseBehavior.Default, tostring(key) .. " held: mouse is free")
	G.holdKey(key, false)
	pump(0.3, G.frame)
	check(not modalUp() and UIS.MouseBehavior == Enum.MouseBehavior.LockCenter, tostring(key) .. " released: mouse is locked")
end

out("-- pop-up cards are Modal, the HUD is not")
local popup, popupRoot
call("client", function()
	popup, popupRoot = UIKit.CreateScreen("ZTestPopup", 50)
	local b = Instance.new("TextButton")
	b.Name = "Go"
	b.Parent = popupRoot
	local hb = Instance.new("TextButton")
	hb.Name = "ZHudProbe"
	hb.Parent = screenOf("HUD") and screenOf("HUD"):FindFirstChildWhichIsA("Frame", true) or popupRoot
end)
check(popupRoot:FindFirstChild("Go").Modal == true, "a button on an ordinary screen is Modal")
local hudButton = 0
local hudModal = 0
for _, d in G.find(G.playerGui, "HUD"):GetDescendants() do
	if d.ClassName == "TextButton" or d.ClassName == "ImageButton" then
		hudButton += 1
		if d.Modal == true then hudModal += 1 end
	end
end
check(hudButton > 0 and hudModal == 0, "no HUD button is Modal (" .. hudModal .. " of " .. hudButton .. ")")
popup:Destroy()

out("-- the results screen frees the mouse (and stays first person)")
endRun()
check(CS.Run and CS.Run.Phase == "Complete", "results are up (" .. tostring(CS.Run and CS.Run.Phase) .. ")")
check(p.CameraMode == Enum.CameraMode.LockFirstPerson, "still first person on the results screen")
check(modalUp() and UIS.MouseBehavior == Enum.MouseBehavior.Default, "mouse is free on the results screen")
backToLobby()
check(CS.Run == nil, "back in the lobby")
check(p.CameraMode == Enum.CameraMode.Classic, "lobby camera mode is Classic again (" .. tostring(p.CameraMode) .. ")")
check(not modalUp() and not dot(), "no button and no dot in the lobby again")
check(UIS.MouseBehavior == Enum.MouseBehavior.Default, "mouse is free in the lobby")

out("-- watching someone else keeps the normal camera")
startRun(1)
check(p.CameraMode == Enum.CameraMode.LockFirstPerson, "first person in the new run")
local cam = G.workspace.CurrentCamera
local ownHum = p.Character:FindFirstChildOfClass("Humanoid")
cam.CameraSubject = G.victim.Character and G.victim.Character:FindFirstChildOfClass("Humanoid") or nil
pump(0.6, G.frame)
check(p.CameraMode == Enum.CameraMode.Classic, "camera on someone else: Classic (" .. tostring(p.CameraMode) .. ")")
cam.CameraSubject = ownHum
pump(0.6, G.frame)
check(p.CameraMode == Enum.CameraMode.LockFirstPerson, "camera back on you: first person again")

out("-- the view is turned toward the dishes")
cam.CFrame = CFrame.new(0, 5, 0) * CFrame.Angles(math.rad(-10), math.rad(90), 0)
local pitch0 = cam.CFrame.LookVector.Y
call("client", function() UIKit.FaceTowards(Vector3.new(0, 5, -50)) end)
local look = cam.CFrame.LookVector
check(look.Z < -0.95 and math.abs(look.X) < 0.05, string.format("FaceTowards turns the yaw (%.2f, %.2f, %.2f)", look.X, look.Y, look.Z))
check(math.abs(look.Y - pitch0) < 0.01, "FaceTowards keeps the pitch")

out("-- your own name tag hides in first person, other players' stay")
local function tagOf(plr)
	local head = plr.Character and plr.Character:FindFirstChild("Head")
	return head and head:FindFirstChild("NameTag")
end
local mine, theirs = tagOf(p), tagOf(G.victim)
if mine and theirs then
	cam.CFrame = CFrame.new(1000, 1000, 1000) -- (far from every head: only the first-person flag can hide the tag)
	pump(0.3, G.frame)
	check(mine.Enabled == false, "own name tag is hidden in first person")
	check(theirs.Enabled == true, "another player's name tag is still shown")
else
	out("(no name tags in this stand-in: skipped)")
end

out("-- reach: tops of tall plates are in reach from the rack, far-off things are not")
check(Config.ReachDistance(Vector3.zero, Vector3.new(0, 10, 0)) == 10 * Config.Round.UpReachScale, "10 studs straight up count as " .. 10 * Config.Round.UpReachScale)
check(Config.ReachDistance(Vector3.new(0, 10, 0), Vector3.zero) == 10, "10 studs straight down count in full")
check(math.abs(Config.ReachDistance(Vector3.zero, Vector3.new(3, 0, 4)) - 5) < 1e-6, "sideways counts in full")
local folder = RS.GetGrimeFolder(p)
local dirt
for _, d in (folder and folder:GetDescendants() or {}) do
	if d.Name == "Dirt" and d:GetAttribute("HP") then
		dirt = d
		break
	end
end
local root = p.Character.HumanoidRootPart
local stats = CS.Run.Stats
local function tryScrub(from)
	root.CFrame = CFrame.new(from)
	local hp0 = dirt:GetAttribute("HP")
	for _ = 1, 12 do
		call("client", function() scrub:FireServer(dirt.Position, true) end)
		pump(0.12, G.frame)
	end
	return (dirt:GetAttribute("HP") or 0) < (hp0 or 0)
end
-- 17 studs above and 3 to the side: 3 and 0.4 x 17 = 6.8 -> 7.4, inside Hands' 12
check(tryScrub(dirt.Position + Vector3.new(0, -17, 3)), "dirt 17 studs overhead (3 to the side) is cleaned")
-- 70 studs above: 0.4 x 70 = 28
dirt = (function()
	for _, d in folder:GetDescendants() do
		if d.Name == "Dirt" and d:GetAttribute("HP") and d ~= dirt then return d end
	end
end)()
check(not tryScrub(dirt.Position + Vector3.new(0, -70, 3)), "dirt 70 studs overhead is not cleaned")
backToLobby()

out("-- every level: dirt is in reach (bare Hands, " .. 12 .. " studs) from the rack beneath it")
for level = 1, #Config.Levels do
	call("server", RS.StartRound, { p }, level)
	pump(1, G.frame)
	local f = RS.GetGrimeFolder(p)
	local arena = f and f.Parent
	local origin = arena and arena:GetAttribute("Origin")
	local worst, worstSpot, over, total = 0, nil, 0, 0
	if origin then
		for _, d in f:GetDescendants() do
			if d.Name == "Dirt" and d:IsA("BasePart") then
				total += 1
				local rel = d.Position.Y - origin.Y
				local rackY = origin.Y + (if rel >= 40 then 50 else 4)
				local stand = Vector3.new(d.Position.X, rackY + 3.5, d.Position.Z - 3)
				local eff = Config.ReachDistance(stand, d.Position)
				if eff > worst then worst, worstSpot = eff, rel end
				if eff > 12 then over += 1 end
			end
		end
	end
	check(total > 0 and over == 0 and CS.Run and CS.Run.Level == level, string.format("level %d (run level %s): %d dirt spots, worst needs %.1f studs (spot %.1f above the floor), %d out of reach", level, tostring(CS.Run and CS.Run.Level), total, worst, worstSpot or 0, over))
	backToLobby()
end

out("-- phones")
UIS.TouchEnabled = true
UIS.KeyboardEnabled = false
UIS.MouseEnabled = false
call("client", function() UIKit.LayoutChanged:Fire() end)
startRun(1)
check(p.CameraMode == Enum.CameraMode.LockFirstPerson, "phone: first person in a run")
UIS.MouseBehavior = Enum.MouseBehavior.Default
call("client", function() UIKit.OpenWindow("Upgrades") end)
pump(0.3, G.frame)
check(not modalUp(), "phone: no mouse button toggled (there is no mouse)")
check(not dot(), "phone: no centre dot")
call("client", function() UIKit.CloseWindow() end)
backToLobby()
check(p.CameraMode == Enum.CameraMode.Classic, "phone: lobby is the normal camera")
UIS.TouchEnabled = false
UIS.KeyboardEnabled = true
UIS.MouseEnabled = true
call("client", function() UIKit.LayoutChanged:Fire() end)

out("-- the tutorial: Skip is always up and does not hold the mouse; its spotlight / skip box do")
DS.ResetFirstRun(p)
pump(1, G.frame)
startRun(1)
pump(8, G.frame)
check(CS.TutorialStep ~= nil, "tutorial running (step " .. tostring(CS.TutorialStep) .. ")")
local skip
for _, d in screenOf("Tutorial", "Hint"):GetDescendants() do
	if d.ClassName == "TextButton" and tostring(d.Text):find("Skip") then skip = d end
end
check(skip ~= nil and skip.Visible and skip.Modal ~= true, "the Skip tutorial button is up and not Modal")
check(not modalUp(), "the mouse stays locked while only the Skip button is up")
G.getSignal(skip, "Activated"):Fire()
pump(0.4, G.frame)
check(modalUp() and UIS.MouseBehavior == Enum.MouseBehavior.Default, "the skip box frees the mouse")
local keep
for _, d in screenOf("Tutorial", "SkipConfirm"):GetDescendants() do
	if d.ClassName == "TextButton" and tostring(d.Text):find("Keep") then keep = d end
end
G.getSignal(keep, "Activated"):Fire()
pump(0.4, G.frame)
check(not modalUp(), "the mouse locks again after Keep going")
out(fails == 0 and "ALL FIRST PERSON CHECKS PASSED" or ("FIRST PERSON FAILURES: " .. fails))
