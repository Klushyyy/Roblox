-- Phones: holding the jump button (Humanoid.Jump stays on) flies; letting go stops.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local p = G.player
local UIS = game:GetService("UserInputService")
UIS.TouchEnabled = true
UIS.KeyboardEnabled = false
call("server", RS.StartRound, { p }, 1)
pump(1, G.frame)
call("client", function() return M[R .. "ReplicatedStorage/Shared/Remotes.luau"].Function("RunRequest"):InvokeServer("Loaded") end)
pump(1, G.frame)
local hum = p.Character:FindFirstChildOfClass("Humanoid")
local root = p.Character.HumanoidRootPart
hum.FloorMaterial = Enum.Material.Air
root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
hum.Jump = true
pump(0.5, G.frame)
out(string.format("holding jump in the air: vy=%.1f fuel=%s", root.AssemblyLinearVelocity.Y, tostring(p:GetAttribute("JetFuel"))))
hum.Jump = false
root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
pump(0.5, G.frame)
out(string.format("let go: vy=%.1f", root.AssemblyLinearVelocity.Y))
