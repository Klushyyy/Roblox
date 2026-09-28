local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local function state(tag)
	local run = CS.Run
	out(string.format("[%s] client Run=%s phase=%s clockAt=%s coins=%s tool=%s held=%s", tag, tostring(run ~= nil), run and run.Phase or "-", run and tostring(run.ClockAt) or "-", run and tostring(run.Coins) or "-", run and tostring(run.Stats and run.Stats.ToolIndex) or "-", tostring(p.Character and p.Character:GetAttribute("HeldToolIndex"))))
end
_G.__side = "server"
local ok, err = call("server", RS.StartRound, { p }, 1)
out("StartRound: " .. tostring(ok) .. " " .. tostring(err))
pump(1, G.frame)
state("started")
pump(3, G.frame)
state("3s, no Loaded yet")
_G.__side = "client"
local rf = Remotes.Function("RunRequest")
local res = call("client", function() return rf:InvokeServer("Loaded") end)
out("Loaded -> " .. tostring(res and res.Ok))
pump(1, G.frame)
state("after Loaded")
_G.__side = "server"
call("server", RS.AddCoins, p, 100000)
pump(0.5, G.frame)
_G.__side = "client"
for _, req in { { "BuyTool", 3 }, { "EquipTool", 1 }, { "EquipTool", 3 }, { "BuyTool", 3 }, { "BuyUpgrade", "ScrubPower" }, { "BuyUpgrade", "Nope" }, { "BuyTool", 99 } } do
	local r = call("client", function() return rf:InvokeServer(req[1], req[2]) end)
	out(string.format("%s %s -> ok=%s %s", req[1], tostring(req[2]), tostring(r and r.Ok), tostring(r and r.Error)))
	pump(0.3, G.frame)
end
state("after buying")
local held = p.Character:FindFirstChild("HeldTool")
out("HeldTool model: " .. tostring(held ~= nil) .. " muzzle: " .. tostring(held and held:FindFirstChild("Muzzle", true) ~= nil))
_G.__side = "server"
local cleaned = call("server", RS.DebugFinish, p)
out("DebugFinish cleaned: " .. tostring(cleaned))
pump(8, G.frame)
state("after finish")
local prof = DS.Get(p)
out(string.format("profile: bubbles=%s runs=%s unlocked=%s", tostring(prof.Bubbles), tostring(prof.Stats and prof.Stats.Runs), tostring(prof.Unlocked)))
_G.__side = "client"
local r = call("client", function() return rf:InvokeServer("ReturnToLobby") end)
out("ReturnToLobby -> " .. tostring(r and r.Ok) .. " " .. tostring(r and r.Error))
pump(3, G.frame)
state("back in lobby")
-- Real scrubbing: a new run, fire Scrub at dirt, check HP / tank, then sell at the drain.
_G.__side = "server"
local RS2 = RS
local ok2 = call("server", RS2.StartRound, { p }, 1)
pump(1, G.frame)
call("client", function() return rf:InvokeServer("Loaded") end)
local folder = RS2.GetGrimeFolder(p)
local dirt
for _, d in (folder and folder:GetDescendants() or {}) do
	if d.Name == "Dirt" and d:GetAttribute("HP") then
		dirt = d
		break
	end
end
out("grime folder: " .. tostring(folder ~= nil) .. " dirt: " .. tostring(dirt ~= nil) .. " hp=" .. tostring(dirt and dirt:GetAttribute("HP")))
if dirt then
	-- stand next to it and scrub
	local root = p.Character.HumanoidRootPart
	root.CFrame = CFrame.new(dirt.Position + Vector3.new(0, 0, 4))
	local scrub = Remotes.Event("Scrub")
	for i = 1, 40 do
		call("client", function()
			scrub:FireServer(dirt.Position, true)
		end)
		pump(0.12, G.frame)
	end
	out("after scrubbing hp=" .. tostring(dirt:GetAttribute("HP")) .. " alive=" .. tostring(dirt.Parent ~= nil) .. " tank=" .. tostring(CS.Run and CS.Run.Tank) .. "/" .. tostring(CS.Run and CS.Run.TankMax))
	local drain = RS2.GetDrainPart(p)
	out("drain: " .. tostring(drain ~= nil))
	if drain then
		local coinsBefore = CS.Run and CS.Run.Coins
		root.CFrame = CFrame.new(drain.Position + Vector3.new(0, 3, 0))
		pump(2, G.frame)
		out("sold: coins " .. tostring(coinsBefore) .. " -> " .. tostring(CS.Run and CS.Run.Coins) .. ", tank " .. tostring(CS.Run and CS.Run.Tank))
	end
end
