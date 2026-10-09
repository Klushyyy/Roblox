-- Dish spacing in every level: no two dishes may poke into each other, and no dish may sink into the scenery of its rack.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local RS = M[R .. "ServerScriptService/Server/Services/RoundService.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local p = G.player

local function boxOf(model)
	-- world bounds of every part of a dish (rotated parts included)
	local x0, x1, y0, y1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
	local n = 0
	local list = if model:IsA("BasePart") then { model } else model:GetDescendants()
	for _, d in list do
		if d:IsA("BasePart") and d.Transparency < 0.95 then
			local cf, s = d.CFrame, d.Size
			local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
			local ex, ey, ez
			local shape = d.ClassName == "Part" and d.Shape or nil
			if shape == Enum.PartType.Cylinder then
				-- a round part (axis = its X): the reach along a world axis is half the length times how much the axis points
				-- that way, plus the radius times how much it does not (a plain box would count the corners of its square)
				local rad = math.min(s.Y, s.Z) / 2
				ex = math.abs(r.X) * s.X / 2 + math.sqrt(math.max(0, 1 - r.X * r.X)) * rad
				ey = math.abs(r.Y) * s.X / 2 + math.sqrt(math.max(0, 1 - r.Y * r.Y)) * rad
				ez = math.abs(r.Z) * s.X / 2 + math.sqrt(math.max(0, 1 - r.Z * r.Z)) * rad
			elseif shape == Enum.PartType.Ball then
				ex = s.X / 2
				ey, ez = ex, ex
			else
				ex = (math.abs(r.X) * s.X + math.abs(u.X) * s.Y + math.abs(l.X) * s.Z) / 2
				ey = (math.abs(r.Y) * s.X + math.abs(u.Y) * s.Y + math.abs(l.Y) * s.Z) / 2
				ez = (math.abs(r.Z) * s.X + math.abs(u.Z) * s.Y + math.abs(l.Z) * s.Z) / 2
			end
			x0, x1 = math.min(x0, cf.X - ex), math.max(x1, cf.X + ex)
			y0, y1 = math.min(y0, cf.Y - ey), math.max(y1, cf.Y + ey)
			z0, z1 = math.min(z0, cf.Z - ez), math.max(z1, cf.Z + ez)
			n += 1
		end
	end
	return n > 0 and { x0, x1, y0, y1, z0, z1 } or nil
end

local cutlery = { Fork = true, Knife = true, Spoon = true }
for level = 1, #Config.Levels do
	call("server", RS.StartRound, { p }, level)
	pump(1, G.frame)
	local folder = RS.GetGrimeFolder(p)
	local arena = folder and folder.Parent
	local dishes = arena and arena:FindFirstChild("Dishes")
	local list = {}
	for _, d in (dishes and dishes:GetChildren() or {}) do
		local b = boxOf(d)
		if b then
			table.insert(list, { name = tostring(d:GetAttribute("Kind") or d.Name), b = b, at = d:GetPivot().Position })
		end
	end
	local bad, worst = {}, 0
	for i = 1, #list do
		for j = i + 1, #list do
			local a, c = list[i].b, list[j].b
			-- how far the two boxes sink into each other on each axis (positive on all three = they overlap)
			local px = math.min(a[2], c[2]) - math.max(a[1], c[1])
			local py = math.min(a[4], c[4]) - math.max(a[3], c[3])
			local pz = math.min(a[6], c[6]) - math.max(a[5], c[5])
			local depth = math.min(px, py, pz)
			-- (forks, knives and spoons lean in the basket, and a box round a leaning thin thing is much bigger than it is: more room is allowed)
			local jumble = cutlery[list[i].name] and cutlery[list[j].name]
			if depth > (if jumble then 2.0 else 1.0) then
				table.insert(bad, string.format("%s/%s %.1f [x %.1f..%.1f / %.1f..%.1f, size %.1fx%.1f vs %.1fx%.1f]", list[i].name, list[j].name, depth, a[1], a[2], c[1], c[2], a[2] - a[1], a[6] - a[5], c[2] - c[1], c[6] - c[5]))
				worst = math.max(worst, depth)
			end
		end
	end
	out(string.format("level %d (%s): %d dishes, %d overlapping pair(s), worst %.1f studs%s", level, tostring(Config.Levels[level].Name), #list, #bad, worst, if #bad > 0 then "  e.g. " .. table.concat(bad, ", ", 1, math.min(#bad, 6)) else ""))
	call("server", RS.RemoveFromRun, p, "test")
	pump(1, G.frame)
end
