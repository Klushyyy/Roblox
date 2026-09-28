local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
call("server", RS.StartRound, { p }, 1)
pump(1, G.frame)
local rf = Remotes.Function("RunRequest")
call("client", function() return rf:InvokeServer("Loaded") end)
call("server", RS.AddCoins, p, 1e6)
pump(24, G.frame) -- let the intro cutscene finish (it drives the camera)
local folder = RS.GetGrimeFolder(p)
local dirt
for _, d in folder:GetDescendants() do
	if d.Name == "Dirt" then
		dirt = d
		break
	end
end
local root = p.Character.HumanoidRootPart
local stand = dirt.Position + Vector3.new(0, 2, 8)
root.CFrame = CFrame.new(stand)
root.Position = stand
local cam = G.workspace.CurrentCamera
local UIS = game:GetService("UserInputService")
out("arena pivot: " .. tostring(G.workspace:FindFirstChild("Arenas"):GetChildren()[1]:GetPivot().Position) .. "  dirt " .. tostring(dirt.Position) .. "  camType " .. tostring(cam.CameraType))
local function aimAndHold(seconds)
	cam.CFrame = CFrame.lookAt(stand + Vector3.new(0, 1.5, 0), dirt.Position)
	out("cam set to " .. tostring(cam.CFrame.Position))
	G.getSignal(UIS, "InputBegan"):Fire({ UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown }, false)
	pump(seconds, G.frame)
end
local function water(tag)
	local fx = G.workspace:FindFirstChild("WaterFX")
	local shown = {}
	for _, part in (fx and fx:GetChildren() or {}) do
		if part.Transparency < 1 then
			shown[part.Name] = (shown[part.Name] or 0) + 1
		end
	end
	local list = {}
	for k, v in shown do
		table.insert(list, k .. " x" .. v)
	end
	table.sort(list)
	out(tag .. ": " .. (if #list > 0 then table.concat(list, ", ") else "no water"))
end
for _, tool in { 3, 4 } do
	local r = call("client", function() return rf:InvokeServer("BuyTool", tool) end)
	pump(0.5, G.frame)
	out("tool " .. tool .. " bought: " .. tostring(r and r.Ok) .. " " .. tostring(r and r.Error or ""))
	aimAndHold(0.6)
	water("tool " .. tool .. " while holding")
	local ring = G.workspace:FindFirstChild("ScrubRing")
	local line = G.workspace:FindFirstChild("WasherLine")
	out("  ring=" .. tostring(ring and ring.Transparency) .. " line=" .. tostring(line and line.Transparency) .. " waterFolder=" .. tostring(G.workspace:FindFirstChild("WaterFX") ~= nil) .. " renderSteps=" .. tostring(_G.__renderSteps and _G.__renderSteps.RinseCycleWater ~= nil))
	local hit = G.workspace:Raycast(cam.CFrame.Position, cam.CFrame.LookVector * 250, (function()
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Include
		local arena = G.workspace:FindFirstChild("Arenas"):GetChildren()[1]
		rp.FilterDescendantsInstances = { arena:FindFirstChild("Dishes"), arena:FindFirstChild("Grime") }
		return rp
	end)())
	out("  scenario raycast hit: " .. tostring(hit and hit.Instance and hit.Instance.Name) .. " at dist " .. tostring(hit and hit.Distance))
	G.getSignal(UIS, "InputEnded"):Fire({ UserInputType = Enum.UserInputType.MouseButton1, KeyCode = Enum.KeyCode.Unknown }, false)
	pump(0.3, G.frame)
	water("tool " .. tool .. " after release")
end
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local arena = CS.GetArena and CS.GetArena()
out("debug: run phase=" .. tostring(CS.Run and CS.Run.Phase) .. " arena=" .. tostring(arena) .. " mode=" .. tostring(CS.Run and CS.Run.Stats.Mode) .. " reach=" .. tostring(CS.Run and CS.Run.Stats.Reach))
if arena then
	local targets = {}
	for _, n in { "Dishes", "Grime" } do
		local f = arena:FindFirstChild(n)
		if f then
			table.insert(targets, f)
		end
	end
	out("debug: aim folders=" .. #targets)
	local rp = RaycastParams and RaycastParams.new()
end
local ray = cam:ViewportPointToRay(0, 0)
out("debug: cam at " .. tostring(cam.CFrame.Position) .. " look " .. tostring(ray.Direction) .. " dirt at " .. tostring(dirt.Position) .. " dirt parent " .. tostring(dirt.Parent and dirt.Parent.Name) .. "/" .. tostring(dirt.Parent and dirt.Parent.Parent and dirt.Parent.Parent.Name))
local held = p.Character:FindFirstChild("HeldTool")
out("debug: held muzzle=" .. tostring(held and held:FindFirstChild("Muzzle", true)))
