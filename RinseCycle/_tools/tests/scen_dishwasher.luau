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
