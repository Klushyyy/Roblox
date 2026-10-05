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

-- Punching the soap shop, the eggs and the pet stand: every prop near each target comes loose, and all return.
local targets = LB.GetSmashTargets()
local loose = 0
for _, t in targets do
	LB.SmashProps(t.Pos, t.Radius, Vector3.new(0, 20, 60))
end
for _, d in lobby.Model:GetDescendants() do
	if d:IsA("BasePart") and d.Anchored == false then
		loose += 1
	end
end
print("smash targets:", #targets, "loose parts after smashing:", loose)
LB.RestoreProps()
local still = 0
for _, d in lobby.Model:GetDescendants() do
	if d:IsA("BasePart") and d.Anchored == false then
		still += 1
	end
end
print("loose parts after restore (should be 0):", still)

-- Pads and prompts off for the show, and back.
LB.SetPadsEnabled(false)
LB.SetUiEnabled(false)
local padTouch, promptsOn = 0, 0
for _, d in lobby.Model:GetDescendants() do
	if d:IsA("BasePart") and d:IsDescendantOf(lobby.Model) and d.Parent and d.Parent.Name:sub(1, 3) == "Pad" and d.CanTouch then
		padTouch += 1
	elseif d:IsA("ProximityPrompt") and d.Enabled then
		promptsOn += 1
	end
end
print("pad parts still touchable (0):", padTouch, " prompts still on (0):", promptsOn)
LB.SetPadsEnabled(true)
LB.SetUiEnabled(true)
local back = 0
for _, d in lobby.Model:GetDescendants() do
	if d:IsA("ProximityPrompt") and d.Enabled then
		back += 1
	end
end
print("prompts back on:", back > 0)
