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
cam.CFrame = CFrame.lookAt(dirt.Position + Vector3.new(0, 4, 4), dirt.Position)
local hp0 = dirt:GetAttribute("HP")
pump(1, G.frame)
local sprayBtn = G.find(p.PlayerGui, "SprayButton")
out("phase=" .. tostring(CS.Run and CS.Run.Phase) .. " spray button visible=" .. tostring(sprayBtn and sprayBtn.Visible) .. " hp before=" .. tostring(hp0))
local finger = { UserInputType = Enum.UserInputType.Touch, KeyCode = Enum.KeyCode.Unknown, Position = Vector3.new(640, 360, 0), UserInputState = Enum.UserInputState.Begin }
call("client", function() G.getSignal(UIS, "InputBegan"):Fire(finger, false) end)
pump(3, G.frame)
local hp1 = dirt.Parent and dirt:GetAttribute("HP") or 0
call("client", function() G.getSignal(UIS, "InputEnded"):Fire(finger, false) end)
pump(1, G.frame)
local hp2 = dirt.Parent and dirt:GetAttribute("HP") or 0
pump(2, G.frame)
local hp3 = dirt.Parent and dirt:GetAttribute("HP") or 0
out(string.format("held 3s: hp %s -> %s; after lifting: %s -> %s (should stay)", tostring(hp0), tostring(hp1), tostring(hp2), tostring(hp3)))
