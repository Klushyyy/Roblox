local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local p = G.player
local ws = game:GetService("Workspace")
pump(1, G.frame)
local fun
for _, d in ws:GetDescendants() do
	if d.Name == "LobbyFun" then fun = d end
end
out("LobbyFun folder: " .. tostring(fun ~= nil))
local bubbles, ducks = {}, {}
for _, c in fun:GetChildren() do
	if c.Name == "PopBubble" or c.Name == "GoldenBubble" then table.insert(bubbles, c) else table.insert(ducks, c) end
end
out("bubbles=" .. #bubbles .. " ducks=" .. #ducks)
local prof = DS.Get(p)
local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
out("root " .. tostring(root))
local before = prof.Bubbles
-- touch 3 bubbles
for i = 1, 3 do
	local b = bubbles[i]
	root.CFrame = CFrame.new(b.Position)
	b.Touched:Fire(root)
	b.Touched:Fire(root) -- double touch must not double pay
end
pump(0.5, G.frame)
out("bubbles gained " .. (prof.Bubbles - before))
local n = 0
for _, c in fun:GetChildren() do if c.Name:find("Bubble") then n += 1 end end
out("alive now " .. n)
pump(8, G.frame)
n = 0
for _, c in fun:GetChildren() do if c.Name:find("Bubble") then n += 1 end end
out("alive after respawn " .. n)
-- ducks
before = prof.Bubbles
local gems = prof.Gems
for i, d in ducks do
	local hit = d.PrimaryPart
	root.CFrame = CFrame.new(hit.Position)
	hit.Touched:Fire(root)
	pump(0.6, G.frame)
	if i == 1 then
		hit.Touched:Fire(root)
		pump(0.6, G.frame)
	end
end
out("duck bubbles +" .. (prof.Bubbles - before) .. " gems +" .. (prof.Gems - gems) .. " ducks=" .. table.concat(prof.Ducks, ",") .. " attr=" .. tostring(p:GetAttribute("DucksFound")))
local hidden = 0
for _, d in ducks do
	for _, x in d:GetDescendants() do
		if x.ClassName == "Part" and x.LocalTransparencyModifier == 1 then hidden += 1 break end
	end
end
out("ducks hidden client-side: " .. hidden)

-- the rooftop obby: finish pad pays once
do
	local CSx = game:GetService("CollectionService")
	local pad = CSx:GetTagged("ObbyFinish")[1]
	local root2 = G.player.Character.HumanoidRootPart
	local before = DS.Get(G.player).Bubbles
	pad.Touched:Fire(root2)
	pump(0.2, G.frame)
	local mid = DS.Get(G.player).Bubbles
	pump(3.5, G.frame)
	pad.Touched:Fire(root2)
	pump(0.2, G.frame)
	out(string.format("obby: +%d first, +%d second, done=%s", mid - before, DS.Get(G.player).Bubbles - mid, tostring(DS.Get(G.player).ObbyDone)))
end
