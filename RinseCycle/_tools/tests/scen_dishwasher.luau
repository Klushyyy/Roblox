-- The show can smash the big dishwasher and put it back.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local LB = M[R .. "ServerScriptService/Server/Services/LobbyBuilder.luau"]
pump(1, G.frame)
local function chunks()
	local n = 0
	for _, d in game:GetService("Workspace"):GetChildren() do
		if d:IsA("BasePart") and d.Anchored == false then
			n += 1
		end
	end
	return n
end
print("broken before:", LB.DishwasherBroken())
LB.BreakDishwasher(Vector3.new(0, 28, -78))
print("broken after:", LB.DishwasherBroken(), "chunks:", chunks())
LB.RepairDishwasher()
pump(2, G.frame)
print("repaired:", not LB.DishwasherBroken())

-- A bomb crater is a real hole through the whole table (the apron under the planks is cut too) and heals.
local apronBefore = 0
local lobby = LB.GetLobby()
for _, d in lobby.Model:GetChildren() do
	if d.Name == "TableApron" then
		apronBefore += 1
	end
end
LB.OpenCrater(10, 0, 0, 9)
pump(1, G.frame)
local apronAfter = 0
for _, d in lobby.Model:GetChildren() do
	if d.Name == "TableApron" then
		apronAfter += 1
	end
end
print("apron parts before/after crater (after should be 0):", apronBefore, apronAfter)
LB.OpenHole(1, Vector3.new(100, 50, 0))
pump(1, G.frame)
LB.HealHoles(1)
pump(3, G.frame)
print("holes healed")
