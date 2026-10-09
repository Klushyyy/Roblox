-- Phones: a finger on the dirt sprays there (no SPRAY button, no centre dot); lifting it stops.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local p = G.player
local UIS = game:GetService("UserInputService")
UIS.TouchEnabled = true
UIS.KeyboardEnabled = false
UIS.MouseEnabled = false
call("server", RS.StartRound, { p }, 1)
pump(1, G.frame)
call("client", function() return M[R .. "ReplicatedStorage/Shared/Remotes.luau"].Function("RunRequest"):InvokeServer("Loaded") end)
pump(1, G.frame)
local folder = RS.GetGrimeFolder(p)
local dirt
for _, d in (folder and folder:GetDescendants() or {}) do
	if d.Name == "Dirt" and d:GetAttribute("HP") then
		dirt = d
		break
	end
end
local root = p.Character.HumanoidRootPart
root.CFrame = CFrame.new(dirt.Position + Vector3.new(0, 2, 4))
local cam = G.workspace.CurrentCamera
-- (the camera hangs over the dirt looking straight down: every finger position gives the same ray in this stand-in)
cam.CFrame = CFrame.new(dirt.Position + Vector3.new(0, 6, 0)) * CFrame.Angles(-math.pi / 2, 0, 0)
out("camera looks " .. tostring(cam.CFrame.LookVector))
local hp0 = dirt:GetAttribute("HP")
pump(1, G.frame)
local sprayBtn = G.find(p.PlayerGui, "SprayButton")
out("phase=" .. tostring(CS.Run and CS.Run.Phase) .. " spray button visible=" .. tostring(sprayBtn and sprayBtn.Visible) .. " hp before=" .. tostring(hp0))
local act = G.cas["RinseScrubTouch"]
out("touch action bound: " .. tostring(act ~= nil) .. "  viewport: " .. tostring(cam.ViewportSize))
local function touch(x, y)
	return { UserInputType = Enum.UserInputType.Touch, KeyCode = Enum.KeyCode.Unknown, Position = Vector3.new(x, y, 0), UserInputState = Enum.UserInputState.Begin }
end
-- (the game moves the camera every frame, so it is put over the dirt again right before each finger lands)
local function down(f)
	return call("client", function()
		cam.CFrame = CFrame.new(dirt.Position + Vector3.new(0, 6, 0)) * CFrame.Angles(-math.pi / 2, 0, 0)
		return act("RinseScrubTouch", Enum.UserInputState.Begin, f)
	end)
end
local function up(f)
	f.UserInputState = Enum.UserInputState.End
	return call("client", function() return act("RinseScrubTouch", Enum.UserInputState.End, f) end)
end
-- a finger on the dirt in the middle of the view sprays and is kept from turning the camera (the action sinks it, and so
-- does its lifting)
local finger = touch(640, 300)
out("finger on the dirt: Begin -> " .. tostring(down(finger)) .. " (Sink), End -> " .. tostring(up(finger)) .. " (Sink)")
-- The walking thumb (the thumbstick's corner, lower left) never sprays, even with dirt right under it in the view, and is
-- passed on untouched so the thumbstick can walk; the same spot on the right side of the screen does spray.
local walker = touch(140, 600)
out("walking thumb in the thumbstick corner: " .. tostring(down(walker)) .. " (Pass)")
up(walker)
local aimer = touch(900, 600)
out("finger on the right side, low: " .. tostring(down(aimer)) .. " (Sink)")
up(aimer)
local upperLeft = touch(140, 150)
out("finger on the upper left: " .. tostring(down(upperLeft)) .. " (Sink)")
up(upperLeft)
