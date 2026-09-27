-- DishFactory: builds one dish (plate/bowl/cup/glass/fork/knife/spoon/pan/pot) and covers a built
-- dish in dirt spots that sit on its real, raycast-checked surfaces.
--
-- Everything here works in the dish's own "anchor" frame: `cf` (a CFrame passed to BuildDish) whose
-- Position is the contact point where the dish touches the rack/basket, and whose axes we reuse as
-- a local coordinate system for the rest of the geometry:
--   local X = cf.RightVector   (sideways across the dish)
--   local Y = cf.UpVector      (straight up from the contact point, "up" for the dish itself)
--   local Z = cf.LookVector    (the direction a plate's face points; "forward" for everything else)
-- The anchor may be tilted (ArenaBuilder leans bowls and pans toward the aisle like a real rack);
-- every builder and dirt ray only uses the anchor's own axes, so tilted dishes just work.
-- BuildDish stores that CFrame on the model (attribute "Anchor") so ApplyGrime can rebuild the same
-- local geometry later.
--
-- Hollow shapes (bowl, pan, pot, mug) are cut once in Init with GeometryService and cloned per dish.
-- If GeometryService fails, each kind falls back to a primitive-part version.
--
-- The dirt: every spot is ONE queryable disc (the thing RoundService damages) plus a few child
-- decoration parts (splats, drips, crumbs, sprinkles) that make it read as food, not a sticker.

local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local DishFactory = {}

----------------------------------------------------------------------------------------------------
-- Sizes, relative to a ~5 stud tall character. The dishwasher is sized so these look like a real
-- load: plates are four characters tall and stand close together in the rack.
----------------------------------------------------------------------------------------------------
local SIZE = {
	Plate = { Diameter = 20, Thickness = 1.2 },
	Tray = { Diameter = 23, Thickness = 0.8 },
	Bowl = { Diameter = 15, Depth = 7 },
	Cup = { Diameter = 8, Height = 10 },
	Glass = { Diameter = 7, Height = 12 },
	Fork = { Height = 18 },
	Knife = { Height = 18 },
	Spoon = { Height = 18 },
	Pan = { Diameter = 22, Depth = 4 },
	Pot = { Diameter = 18, Height = 14 },
}

local DIRT_SCALE = 1.6 -- Config.GrimeTypes sizes were tuned for the old, smaller dishes
local WALL = 0.8 -- wall thickness of hollow dishes

local SPRINKLE_COLORS = {
	Color3.fromRGB(255, 90, 90),
	Color3.fromRGB(90, 140, 255),
	Color3.fromRGB(90, 220, 120),
	Color3.fromRGB(255, 210, 60),
	Color3.fromRGB(255, 120, 200),
	Color3.fromRGB(255, 160, 60),
	Color3.fromRGB(170, 110, 255),
}

local STEEL = Color3.fromRGB(200, 205, 212)
local DARK_STEEL = Color3.fromRGB(70, 72, 78)
local HANDLE_BLACK = Color3.fromRGB(40, 40, 44)

----------------------------------------------------------------------------------------------------
-- Template state (built once in Init). Each template is a PartOperation plus the CFrame it sits at
-- relative to its build frame, so a clone can be placed without knowing how CSG chose its pivot.
----------------------------------------------------------------------------------------------------
type Template = { Part: BasePart, Rel: CFrame }

local templatesFolder: Folder? = nil
local templates: { [string]: Template } = {}
local BUILD_AT = CFrame.new(0, 4000, 0) -- far from everything while cutting

----------------------------------------------------------------------------------------------------
-- Small geometry helpers, all working in an anchor CFrame's local axes.
----------------------------------------------------------------------------------------------------

-- Local (x = Right, y = Up, z = Look) -> world position.
local function localPos(anchor: CFrame, x: number, y: number, z: number): Vector3
	return anchor.Position + anchor.RightVector * x + anchor.UpVector * y + anchor.LookVector * z
end

-- Local (x, y, z) -> world direction.
local function localDir(anchor: CFrame, x: number, y: number, z: number): Vector3
	return anchor.RightVector * x + anchor.UpVector * y + anchor.LookVector * z
end

-- A part whose local X axis is `axisWorld` (used for Shape = Cylinder, where X is the axis).
local function axisCFrame(pos: Vector3, axisWorld: Vector3, hintWorld: Vector3): CFrame
	local ok, cf = pcall(CFrame.fromMatrix, pos, axisWorld.Unit, hintWorld.Unit)
	if ok and cf == cf then
		return cf
	end
	return CFrame.fromMatrix(pos, axisWorld.Unit, Vector3.new(0, 1, 0))
end

-- The anchor rotated so a Cylinder's axis (X) points along the anchor's Up.
local function upright(anchor: CFrame, y: number): CFrame
	return CFrame.new(localPos(anchor, 0, y, 0)) * anchor.Rotation * CFrame.Angles(0, 0, math.rad(90))
end

local function setFlags(p: BasePart)
	p.Anchored = true
	p.CanCollide = true
	p.CanTouch = false
	p.CanQuery = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
end

local function newPart(shape: Enum.PartType?, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
	local p = Instance.new("Part")
	if shape then
		p.Shape = shape
	end
	p.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	setFlags(p)
	return p
end

-- Decoration that should never block aim, touch or movement.
local function decor(p: BasePart): BasePart
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

-- A rounded capsule-ish bar: a Cylinder along `axisWorld`, used for handles and cutlery.
local function bar(from: Vector3, to: Vector3, thickness: number, hint: Vector3, color: Color3, material: Enum.Material?): BasePart
	local mid = (from + to) / 2
	local len = (to - from).Magnitude
	return newPart(Enum.PartType.Cylinder, Vector3.new(len, thickness, thickness), axisCFrame(mid, to - from, hint), color, material)
end

-- Places a clone of a CSG template so its build frame lands on `frame`. Nil if there's no template.
local function placeTemplate(name: string, frame: CFrame, color: Color3, material: Enum.Material?): BasePart?
	local t = templates[name]
	if not t then
		return nil
	end
	local ok, clone = pcall(function()
		return t.Part:Clone()
	end)
	if not ok or not clone then
		return nil
	end
	local part = clone :: BasePart
	part.CFrame = frame * t.Rel
	part.Color = color
	if material then
		part.Material = material
	end
	setFlags(part)
	-- UsePartColor so the per-level theme colour shows instead of the template's.
	pcall(function()
		(part :: any).UsePartColor = true
	end)
	return part
end

-- Mug/pot style loop handle on the anchor's +X side (sideways from the dish).
local function loopHandle(anchor: CFrame, radius: number, y0: number, y1: number, out: number, thick: number, color: Color3, material: Enum.Material?, side: number): { BasePart }
	local x0 = side * (radius - 0.2)
	local x1 = side * (radius + out)
	local up = anchor.UpVector
	return {
		bar(localPos(anchor, x1, y0, 0), localPos(anchor, x1, y1, 0), thick, anchor.LookVector, color, material),
		bar(localPos(anchor, x0, y0, 0), localPos(anchor, x1 + side * thick * 0.4, y0, 0), thick, up, color, material),
		bar(localPos(anchor, x0, y1, 0), localPos(anchor, x1 + side * thick * 0.4, y1, 0), thick, up, color, material),
	}
end

----------------------------------------------------------------------------------------------------
-- Per-kind builders. Each returns (parts: {BasePart}, primaryIndex: number).
----------------------------------------------------------------------------------------------------

-- Plate standing on its edge, face (the dirty side) toward anchor.LookVector. With CSG: a white body
-- with a recessed well, a coloured stripe ring on the rim and a foot ring on the back. Without CSG:
-- a coloured edge band behind a thicker white face. No two faces share a plane either way.
local function buildPlate(anchor: CFrame, theme, _rng: Random)
	local s = SIZE.Plate
	local frame = CFrame.new(anchor.Position) * anchor.Rotation
	local body = placeTemplate("PlateBody", frame, theme.Plate)
	if body then
		local parts = { body }
		local stripe = placeTemplate("PlateStripe", frame, theme.PlateRim)
		if stripe then
			table.insert(parts, stripe)
		end
		local foot = placeTemplate("PlateFoot", frame, theme.Plate)
		if foot then
			table.insert(parts, foot)
		end
		return parts, 1
	end
	local r = s.Diameter / 2
	local cf = axisCFrame(localPos(anchor, 0, r, 0), anchor.LookVector, anchor.UpVector)
	local t = s.Thickness
	return {
		newPart(Enum.PartType.Cylinder, Vector3.new(t, s.Diameter, s.Diameter), cf, theme.PlateRim), -- edge band
		newPart(Enum.PartType.Cylinder, Vector3.new(t + 0.3, s.Diameter * 0.88, s.Diameter * 0.88), cf, theme.Plate), -- face
	}, 2
end

-- Serving tray (pizza pan / banquet platter) standing on its edge like a plate, face toward
-- anchor.LookVector: a flat face inside a thick rolled rim (a CSG ring, or 18 short bars without
-- CSG). The rim is thicker than the face on both sides, so no faces share a plane.
local function buildTray(anchor: CFrame, theme, _rng: Random)
	local s = SIZE.Tray
	local r = s.Diameter / 2
	local color = theme.Tray or theme.Metal
	local rimColor = Color3.new(color.R * 0.85, color.G * 0.85, color.B * 0.85)
	local center = localPos(anchor, 0, r, 0)
	local cf = axisCFrame(center, anchor.LookVector, anchor.UpVector)
	local parts = {
		newPart(Enum.PartType.Cylinder, Vector3.new(s.Thickness, s.Diameter * 0.9, s.Diameter * 0.9), cf, color, Enum.Material.Metal),
	}
	local rim = placeTemplate("TrayRim", CFrame.new(anchor.Position) * anchor.Rotation, rimColor, Enum.Material.Metal)
	if rim then
		table.insert(parts, rim)
	else
		local n = 18
		local rr = r * 0.94
		for i = 0, n - 1 do
			local a0, a1 = i / n * math.pi * 2, (i + 1.08) / n * math.pi * 2
			local p0 = center + anchor.RightVector * (math.cos(a0) * rr) + anchor.UpVector * (math.sin(a0) * rr)
			local p1 = center + anchor.RightVector * (math.cos(a1) * rr) + anchor.UpVector * (math.sin(a1) * rr)
			table.insert(parts, bar(p0, p1, s.Thickness + 1, anchor.LookVector, rimColor, Enum.Material.Metal))
		end
	end
	return parts, 1
end

-- Bowl, opening along anchor Up. CSG shell when available, otherwise a ring of angled slats.
local function buildBowl(anchor: CFrame, theme, _rng: Random)
	local s = SIZE.Bowl
	local shell = placeTemplate("Bowl", CFrame.new(anchor.Position) * anchor.Rotation, theme.Bowl)
	local parts = {}
	if shell then
		table.insert(parts, shell)
	else
		local r = s.Diameter / 2
		table.insert(parts, newPart(Enum.PartType.Cylinder, Vector3.new(0.8, r * 1.1, r * 1.1), upright(anchor, 0.4), theme.Bowl))
		local slats = 20
		for i = 1, slats do
			local theta = (i - 1) / slats * math.pi * 2
			local nx, nz = math.cos(theta), math.sin(theta)
			local pos = localPos(anchor, nx * r * 0.78, s.Depth * 0.5, nz * r * 0.78)
			local out = localDir(anchor, nx, 0, nz)
			local cf = CFrame.lookAt(pos, pos + out, anchor.UpVector) * CFrame.Angles(math.rad(28), 0, 0)
			table.insert(parts, newPart(nil, Vector3.new(r * 0.3, s.Depth * 1.05, WALL), cf, theme.Bowl))
		end
	end
	-- Foot ring, and a coloured band hugging the outside of the rim.
	table.insert(parts, newPart(Enum.PartType.Cylinder, Vector3.new(0.6, s.Diameter * 0.45, s.Diameter * 0.45), upright(anchor, 0.3), theme.Bowl))
	local stripe = placeTemplate("BowlStripe", CFrame.new(anchor.Position) * anchor.Rotation, theme.PlateRim)
	if stripe then
		table.insert(parts, stripe)
	end
	return parts, 1
end

-- Mug upside down on the rack: open end at the contact point, base on top, handle on the side.
local function buildCup(anchor: CFrame, theme, _rng: Random)
	local s = SIZE.Cup
	local r = s.Diameter / 2
	local body = placeTemplate("Cup", CFrame.new(anchor.Position) * anchor.Rotation, theme.Cup)
		or newPart(Enum.PartType.Cylinder, Vector3.new(s.Height, s.Diameter, s.Diameter), upright(anchor, s.Height / 2), theme.Cup)
	local parts = { body }
	-- A white band near the (upturned) base for a little detail.
	table.insert(parts, decor(newPart(Enum.PartType.Cylinder, Vector3.new(0.5, s.Diameter + 0.08, s.Diameter + 0.08), upright(anchor, s.Height - 1.4), Color3.new(1, 1, 1))))
	for _, h in loopHandle(anchor, r, s.Height * 0.25, s.Height * 0.72, 2.2, 0.9, theme.Cup, nil, 1) do
		table.insert(parts, h)
	end
	return parts, 1
end

-- Tumbler upside down: see-through glass with a thick base on top.
local function buildGlass(anchor: CFrame, theme, _rng: Random)
	local s = SIZE.Glass
	local body = newPart(Enum.PartType.Cylinder, Vector3.new(s.Height, s.Diameter, s.Diameter), upright(anchor, s.Height / 2), theme.Glass, Enum.Material.Glass)
	body.Transparency = 0.35
	body.Reflectance = 0.15
	local base = newPart(Enum.PartType.Cylinder, Vector3.new(1.2, s.Diameter * 0.96, s.Diameter * 0.96), upright(anchor, s.Height - 0.6), theme.Glass, Enum.Material.Glass)
	base.Transparency = 0.2
	local lip = decor(newPart(Enum.PartType.Cylinder, Vector3.new(0.3, s.Diameter + 0.1, s.Diameter + 0.1), upright(anchor, 0.15), Color3.new(1, 1, 1), Enum.Material.Glass))
	lip.Transparency = 0.4
	return { body, base, lip }, 1
end

-- Frying pan, cooking surface along anchor Up, long handle along +X.
local function buildPan(anchor: CFrame, theme, _rng: Random)
	local s = SIZE.Pan
	local r = s.Diameter / 2
	local body = placeTemplate("Pan", CFrame.new(anchor.Position) * anchor.Rotation, DARK_STEEL, Enum.Material.Metal)
	local parts = {}
	if body then
		table.insert(parts, body)
	else
		table.insert(parts, newPart(Enum.PartType.Cylinder, Vector3.new(s.Depth, s.Diameter, s.Diameter), upright(anchor, s.Depth / 2), DARK_STEEL, Enum.Material.Metal))
	end
	-- Outside of the pan in the theme metal colour, cooking surface darker.
	table.insert(parts, decor(newPart(Enum.PartType.Cylinder, Vector3.new(0.3, s.Diameter + 0.2, s.Diameter + 0.2), upright(anchor, 0.15), theme.Metal, Enum.Material.Metal)))
	local h0 = localPos(anchor, r - 0.5, s.Depth * 0.8, 0)
	local h1 = localPos(anchor, r + 12, s.Depth * 1.6, 0)
	table.insert(parts, bar(h0, h1, 1.3, anchor.UpVector, HANDLE_BLACK))
	return parts, 1
end

-- Stock pot, open top along anchor Up, two loop handles.
local function buildPot(anchor: CFrame, theme, _rng: Random)
	local s = SIZE.Pot
	local r = s.Diameter / 2
	local body = placeTemplate("Pot", CFrame.new(anchor.Position) * anchor.Rotation, theme.Metal, Enum.Material.Metal)
		or newPart(Enum.PartType.Cylinder, Vector3.new(s.Height, s.Diameter, s.Diameter), upright(anchor, s.Height / 2), theme.Metal, Enum.Material.Metal)
	local parts = { body }
	-- Rolled rim.
	table.insert(parts, decor(newPart(Enum.PartType.Cylinder, Vector3.new(0.6, s.Diameter + 0.5, s.Diameter + 0.5), upright(anchor, s.Height - 0.3), STEEL, Enum.Material.Metal)))
	for _, side in { 1, -1 } do
		for _, h in loopHandle(anchor, r, s.Height * 0.72, s.Height * 0.9, 1.8, 0.8, STEEL, Enum.Material.Metal, side) do
			table.insert(parts, h)
		end
	end
	return parts, 1
end

-- Cutlery stands handle-down in the basket. The flat side faces the anchor's Look.
local function cutleryHandle(anchor: CFrame, height: number, color: Color3, material: Enum.Material?): BasePart
	local handle = newPart(nil, Vector3.new(1.6, height, 0.7), CFrame.new(localPos(anchor, 0, height / 2, 0)) * anchor.Rotation, color, material)
	return handle
end

local function buildFork(anchor: CFrame, theme, _rng: Random)
	local total = SIZE.Fork.Height
	local handleH = total * 0.55
	local neckH = total * 0.12
	local tineH = total - handleH - neckH
	local rot = anchor.Rotation
	local parts = {
		cutleryHandle(anchor, handleH, theme.Metal, Enum.Material.Metal),
		newPart(nil, Vector3.new(2.2, neckH, 0.45), CFrame.new(localPos(anchor, 0, handleH + neckH / 2, 0)) * rot, theme.Metal, Enum.Material.Metal),
		newPart(nil, Vector3.new(3.6, 1.2, 0.45), CFrame.new(localPos(anchor, 0, handleH + neckH + 0.6, 0)) * rot, theme.Metal, Enum.Material.Metal),
	}
	for i = 1, 4 do
		local x = (i - 2.5) * 0.95
		table.insert(parts, newPart(nil, Vector3.new(0.45, tineH, 0.4), CFrame.new(localPos(anchor, x, handleH + neckH + tineH / 2, 0)) * rot, theme.Metal, Enum.Material.Metal))
	end
	return parts, 1
end

local function buildKnife(anchor: CFrame, theme, _rng: Random)
	local total = SIZE.Knife.Height
	local handleH = total * 0.42
	local bladeH = total - handleH
	local rot = anchor.Rotation
	local handle = newPart(nil, Vector3.new(1.4, handleH, 0.9), CFrame.new(localPos(anchor, 0, handleH / 2, 0)) * rot, HANDLE_BLACK)
	local bolster = newPart(nil, Vector3.new(1.6, 0.6, 1.0), CFrame.new(localPos(anchor, 0, handleH + 0.3, 0)) * rot, theme.Metal, Enum.Material.Metal)
	local blade = newPart(nil, Vector3.new(2.2, bladeH - 2.2, 0.3), CFrame.new(localPos(anchor, 0.3, handleH + 0.6 + (bladeH - 2.2) / 2, 0)) * rot, theme.Metal, Enum.Material.Metal)
	-- Tip: a wedge sloping from the spine down to the edge.
	local tip = Instance.new("WedgePart")
	tip.Size = Vector3.new(0.3, 2.2, 2.2)
	tip.CFrame = CFrame.new(localPos(anchor, 0.3, handleH + 0.6 + bladeH - 2.2 + 1.1, 0)) * rot * CFrame.Angles(0, math.rad(90), 0)
	tip.Color = theme.Metal
	tip.Material = Enum.Material.Metal
	setFlags(tip)
	return { handle, bolster, blade, tip }, 1
end

local function buildSpoon(anchor: CFrame, theme, _rng: Random)
	local total = SIZE.Spoon.Height
	local handleH = total * 0.66
	local parts = { cutleryHandle(anchor, handleH, theme.Metal, Enum.Material.Metal) }
	local bowl = newPart(nil, Vector3.new(4, 5.6, 1.4), CFrame.new(localPos(anchor, 0, handleH + 2.8, 0)) * anchor.Rotation, theme.Metal, Enum.Material.Metal)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = bowl
	table.insert(parts, bowl)
	return parts, 1
end

local BUILDERS: { [string]: (CFrame, any, Random) -> ({ BasePart }, number) } = {
	Plate = buildPlate,
	Tray = buildTray,
	Bowl = buildBowl,
	Cup = buildCup,
	Glass = buildGlass,
	Fork = buildFork,
	Knife = buildKnife,
	Spoon = buildSpoon,
	Pan = buildPan,
	Pot = buildPot,
}

----------------------------------------------------------------------------------------------------
-- Init: cut the hollow templates. Any failure just leaves that kind on its primitive fallback.
----------------------------------------------------------------------------------------------------

local function tempPart(shape: Enum.PartType?, size: Vector3, cf: CFrame): Part
	local p = Instance.new("Part")
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.Parent = ServerStorage
	return p
end

-- Upright cylinder (axis = world Y) centred at build-frame height y.
local function uprightAt(y: number): CFrame
	return BUILD_AT * CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.rad(90))
end

local function cut(name: string, outer: Part, cutters: { Part })
	local GeometryService = game:GetService("GeometryService")
	local ok, result = pcall(function()
		return GeometryService:SubtractAsync(outer, cutters, { SplitApart = false })
	end)
	for _, p in cutters do
		p:Destroy()
	end
	outer:Destroy()
	if ok and type(result) == "table" and result[1] then
		local part = result[1] :: BasePart
		part.Name = name .. "Template"
		part.Anchored = true
		part.Parent = templatesFolder
		templates[name] = { Part = part, Rel = BUILD_AT:ToObjectSpace(part.CFrame) }
	else
		warn(string.format("[DishFactory] Couldn't cut the %s template, using the simple version: %s", name, tostring(result)))
	end
end

-- Cylinder whose axis runs along the build frame's Z (the plate's facing), centred at (0, y, z).
local function alongZAt(y: number, z: number): CFrame
	return BUILD_AT * CFrame.new(0, y, z) * CFrame.Angles(0, math.rad(90), 0)
end

-- A flat ring (annulus) cut from two cylinders.
local function ring(name: string, outerD: number, innerD: number, thickness: number, cf: CFrame)
	local outer = tempPart(Enum.PartType.Cylinder, Vector3.new(thickness, outerD, outerD), cf)
	local inner = tempPart(Enum.PartType.Cylinder, Vector3.new(thickness + 1, innerD, innerD), cf)
	cut(name, outer, { inner })
end

local function buildTemplates()
	-- Plate, standing on its edge at y = 0, face toward the build frame's -Z (its LookVector side).
	do
		local s = SIZE.Plate
		local d, t = s.Diameter, s.Thickness
		local r = d / 2
		local front = -t / 2 -- local Z of the front face
		local body = tempPart(Enum.PartType.Cylinder, Vector3.new(t, d, d), alongZAt(r, 0))
		-- A well 0.35 deep with a small bevel step around it.
		local well = tempPart(Enum.PartType.Cylinder, Vector3.new(1.4, d * 0.64, d * 0.64), alongZAt(r, front - 0.7 + 0.35))
		local bevel = tempPart(Enum.PartType.Cylinder, Vector3.new(1.4, d * 0.72, d * 0.72), alongZAt(r, front - 0.7 + 0.15))
		cut("PlateBody", body, { well, bevel })
		ring("PlateStripe", d * 0.93, d * 0.86, 0.1, alongZAt(r, front - 0.05))
		ring("PlateFoot", d * 0.6, d * 0.53, 0.3, alongZAt(r, t / 2 + 0.15))
	end
	-- Tray rim: a thick ring around the flat face.
	do
		local s = SIZE.Tray
		ring("TrayRim", s.Diameter, s.Diameter * 0.88, s.Thickness + 1, alongZAt(s.Diameter / 2, 0))
	end
	-- Bowl rim band.
	do
		local s = SIZE.Bowl
		ring("BowlStripe", s.Diameter + 0.4, s.Diameter - 0.8, 0.4, BUILD_AT * CFrame.new(0, s.Depth - 0.1, 0) * CFrame.Angles(0, 0, math.rad(90)))
	end
	-- Bowl: a ball, hollowed, with everything above the rim cut off. Contact point at y = 0.
	do
		local s = SIZE.Bowl
		local d = s.Diameter
		local outerH = s.Depth * 2
		local outer = tempPart(Enum.PartType.Ball, Vector3.new(d, d, d), BUILD_AT * CFrame.new(0, d / 2, 0))
		outer.Size = Vector3.new(d, d, d)
		local hollow = tempPart(Enum.PartType.Ball, Vector3.new(d - WALL * 2, d - WALL * 2, d - WALL * 2), BUILD_AT * CFrame.new(0, d / 2 + 0.2, 0))
		local lid = tempPart(nil, Vector3.new(d + 4, outerH, d + 4), BUILD_AT * CFrame.new(0, s.Depth + outerH / 2, 0))
		cut("Bowl", outer, { hollow, lid })
	end
	-- Mug (upside down): open at the bottom (y = 0), closed at the top.
	do
		local s = SIZE.Cup
		local outer = tempPart(Enum.PartType.Cylinder, Vector3.new(s.Height, s.Diameter, s.Diameter), uprightAt(s.Height / 2))
		local inner = tempPart(Enum.PartType.Cylinder, Vector3.new(s.Height, s.Diameter - WALL * 2, s.Diameter - WALL * 2), uprightAt(s.Height / 2 - WALL))
		cut("Cup", outer, { inner })
	end
	-- Pan: shallow dish, open on top.
	do
		local s = SIZE.Pan
		local outer = tempPart(Enum.PartType.Cylinder, Vector3.new(s.Depth, s.Diameter, s.Diameter), uprightAt(s.Depth / 2))
		local inner = tempPart(Enum.PartType.Cylinder, Vector3.new(s.Depth, s.Diameter - WALL * 2, s.Diameter - WALL * 2), uprightAt(s.Depth / 2 + WALL))
		cut("Pan", outer, { inner })
	end
	-- Pot: deep, open on top.
	do
		local s = SIZE.Pot
		local outer = tempPart(Enum.PartType.Cylinder, Vector3.new(s.Height, s.Diameter, s.Diameter), uprightAt(s.Height / 2))
		local inner = tempPart(Enum.PartType.Cylinder, Vector3.new(s.Height, s.Diameter - WALL * 2, s.Diameter - WALL * 2), uprightAt(s.Height / 2 + WALL))
		cut("Pot", outer, { inner })
	end
end

function DishFactory.Init()
	local folder = ServerStorage:FindFirstChild("DishTemplates")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DishTemplates"
		folder.Parent = ServerStorage
	end
	templatesFolder = folder :: Folder
	local ok, err = pcall(buildTemplates)
	if not ok then
		warn("[DishFactory] Template build failed, using simple dishes: " .. tostring(err))
	end
end

-- Footprint size of a kind, for ArenaBuilder's layout: (width across, height, depth).
function DishFactory.Size(kind: string): { [string]: number }
	return SIZE[kind] or {}
end

----------------------------------------------------------------------------------------------------
-- BuildDish
----------------------------------------------------------------------------------------------------
function DishFactory.BuildDish(kind: string, cf: CFrame, theme, rng: Random): Model
	local builder = BUILDERS[kind]
	local model = Instance.new("Model")
	model.Name = kind

	if not builder then
		warn("[DishFactory] Unknown dish kind " .. tostring(kind))
		local stub = newPart(nil, Vector3.new(1, 1, 1), cf, Color3.new(1, 0, 1))
		stub.Parent = model
		model.PrimaryPart = stub
		model:SetAttribute("Anchor", cf)
		model:SetAttribute("Kind", kind)
		return model
	end

	local parts, primaryIndex = builder(cf, theme, rng)
	for _, part in parts do
		part.Parent = model
	end
	model.PrimaryPart = parts[primaryIndex] or parts[1]
	model:SetAttribute("Anchor", cf)
	model:SetAttribute("Kind", kind)
	return model
end

----------------------------------------------------------------------------------------------------
-- Dirt placement: per-kind candidate rays, in the dish's local (Right, Up, Look) axes.
-- Returns (localOrigin, localDirection); both get converted to world space before raycasting.
----------------------------------------------------------------------------------------------------
local function candidatePlate(rng: Random)
	local s = SIZE.Plate
	local side = 1 -- only the front (the side you can see) gets dirty
	local r = math.sqrt(rng:NextNumber()) * s.Diameter * 0.36
	local theta = rng:NextNumber() * math.pi * 2
	local x, y = r * math.cos(theta), s.Diameter / 2 + r * math.sin(theta)
	return Vector3.new(x, y, side * 4), Vector3.new(0, 0, -side)
end

-- Inside of an open-topped round dish (bowl, pan, pot): aim from above the opening at the inner wall
-- or floor.
local function candidateInside(diameter: number, depth: number, rng: Random)
	local theta = rng:NextNumber() * math.pi * 2
	local frac = rng:NextNumber() ^ 0.7
	local r = (diameter / 2 - WALL - 0.4) * frac
	local x, z = r * math.cos(theta), r * math.sin(theta)
	local origin = Vector3.new(-x * 0.3, depth + 6, -z * 0.3)
	local target = Vector3.new(x, WALL, z)
	return origin, (target - origin)
end

local function candidateCylinderSide(diameter: number, height: number, rng: Random)
	local theta = rng:NextNumber() * math.pi * 2
	local y = (0.12 + rng:NextNumber() * 0.8) * height
	local radius = diameter / 2
	local nx, nz = math.cos(theta), math.sin(theta)
	return Vector3.new(nx * (radius + 4), y, nz * (radius + 4)), Vector3.new(-nx, 0, -nz)
end

local function candidateCylinderTop(diameter: number, height: number, rng: Random)
	local r = math.sqrt(rng:NextNumber()) * (diameter / 2 - 0.4)
	local theta = rng:NextNumber() * math.pi * 2
	return Vector3.new(r * math.cos(theta), height + 4, r * math.sin(theta)), Vector3.new(0, -1, 0)
end

local function candidateUpsideDown(diameter: number, height: number, rng: Random)
	if rng:NextNumber() < 0.8 then
		return candidateCylinderSide(diameter, height, rng)
	end
	return candidateCylinderTop(diameter, height, rng)
end

local function candidatePot(rng: Random)
	local s = SIZE.Pot
	if rng:NextNumber() < 0.6 then
		return candidateCylinderSide(s.Diameter, s.Height, rng)
	end
	return candidateInside(s.Diameter, s.Height, rng)
end

-- Cutlery: the head (tines, blade, spoon bowl) on either flat side.
local function candidateCutlery(height: number, lowFrac: number, rng: Random)
	local side = if rng:NextNumber() < 0.5 then 1 else -1
	local y = height * (lowFrac + rng:NextNumber() * (0.95 - lowFrac))
	local x = (rng:NextNumber() - 0.5) * 2.4
	return Vector3.new(x, y, side * 4), Vector3.new(0, 0, -side)
end

local function candidateTray(rng: Random)
	local s = SIZE.Tray
	local r = math.sqrt(rng:NextNumber()) * s.Diameter * 0.36
	local theta = rng:NextNumber() * math.pi * 2
	local x, y = r * math.cos(theta), s.Diameter / 2 + r * math.sin(theta)
	return Vector3.new(x, y, 4), Vector3.new(0, 0, -1)
end

local CANDIDATES: { [string]: (Random) -> (Vector3, Vector3) } = {
	Plate = candidatePlate,
	Tray = candidateTray,
	Bowl = function(rng)
		return candidateInside(SIZE.Bowl.Diameter, SIZE.Bowl.Depth, rng)
	end,
	Cup = function(rng)
		return candidateUpsideDown(SIZE.Cup.Diameter, SIZE.Cup.Height, rng)
	end,
	Glass = function(rng)
		return candidateUpsideDown(SIZE.Glass.Diameter, SIZE.Glass.Height, rng)
	end,
	Pan = function(rng)
		return candidateInside(SIZE.Pan.Diameter, SIZE.Pan.Depth, rng)
	end,
	Pot = candidatePot,
	Fork = function(rng)
		return candidateCutlery(SIZE.Fork.Height, 0.5, rng)
	end,
	Knife = function(rng)
		return candidateCutlery(SIZE.Knife.Height, 0.45, rng)
	end,
	Spoon = function(rng)
		return candidateCutlery(SIZE.Spoon.Height, 0.68, rng)
	end,
}

----------------------------------------------------------------------------------------------------
-- Dirt shapes. `cf` has local X = outward surface normal and sits just proud of the surface; local
-- Y/Z span the surface. Each returns (main disc, decoration children).
----------------------------------------------------------------------------------------------------

local function disc(cf: CFrame, diameter: number, thickness: number, color: Color3, material: Enum.Material): BasePart
	local p = newPart(Enum.PartType.Cylinder, Vector3.new(thickness, diameter, diameter), cf, color, material)
	p.CanCollide = false
	p.CastShadow = false
	return p
end

-- Child splats are thinner than the main disc and centred slightly lower, so their top faces sit
-- 0.04+ studs under the main disc's (no two faces share a plane, so nothing flickers).
local function childDisc(cf: CFrame, dy: number, dz: number, diameter: number, thickness: number, color: Color3, material: Enum.Material): BasePart
	return decor(disc(cf * CFrame.new(-0.02, dy, dz), diameter, math.min(thickness, 0.12), color, material))
end

local function darker(c: Color3, f: number): Color3
	return Color3.new(c.R * f, c.G * f, c.B * f)
end

-- Sauce splat: a round blob with smaller splats and droplets around its edge.
local function shapeBlob(cf: CFrame, size: number, color: Color3, material: Enum.Material, rng: Random)
	local main = disc(cf, size, 0.2, color, material)
	main.Reflectance = 0.08
	local kids = {}
	for _ = 1, rng:NextInteger(3, 5) do
		local a = rng:NextNumber() * math.pi * 2
		local d = size * rng:NextNumber(0.3, 0.45)
		table.insert(kids, childDisc(cf, math.cos(a) * d, math.sin(a) * d, size * rng:NextNumber(0.35, 0.6), 0.18, color, material))
	end
	for _ = 1, rng:NextInteger(2, 4) do
		local a = rng:NextNumber() * math.pi * 2
		local d = size * rng:NextNumber(0.65, 0.9)
		table.insert(kids, childDisc(cf, math.cos(a) * d, math.sin(a) * d, size * rng:NextNumber(0.1, 0.18), 0.16, color, material))
	end
	-- A slightly darker centre makes it read as a thick dollop.
	table.insert(kids, decor(disc(cf * CFrame.new(0.08, 0, 0), size * 0.45, 0.2, darker(color, 0.85), material)))
	return main, kids
end

-- Smear: a chain of overlapping blobs that thin out in one direction.
local function shapeStreak(cf: CFrame, size: number, color: Color3, material: Enum.Material, rng: Random)
	local main = disc(cf, size * 0.8, 0.18, color, material)
	local kids = {}
	local a = rng:NextNumber() * math.pi * 2
	local dy, dz = math.cos(a), math.sin(a)
	local n = rng:NextInteger(3, 5)
	for i = 1, n do
		local t = i / n
		local along = size * 0.45 * i
		local wobble = (rng:NextNumber() - 0.5) * size * 0.15
		table.insert(kids, childDisc(cf, dy * along - dz * wobble, dz * along + dy * wobble, size * (0.75 - 0.4 * t), 0.16, color, material))
	end
	return main, kids
end

-- Crumbs: a faint greasy patch covered in little chunky bits.
local function shapeCrumbs(cf: CFrame, size: number, color: Color3, material: Enum.Material, rng: Random)
	local main = disc(cf, size * 0.9, 0.12, darker(color, 0.9), material)
	main.Transparency = 0.25
	local kids = {}
	for _ = 1, rng:NextInteger(5, 8) do
		local a = rng:NextNumber() * math.pi * 2
		local d = size * 0.4 * math.sqrt(rng:NextNumber())
		local s = size * rng:NextNumber(0.12, 0.24)
		local bit = decor(newPart(nil, Vector3.new(s * 0.7, s, s * rng:NextNumber(0.7, 1.2)), cf * CFrame.new(s * 0.3, math.cos(a) * d, math.sin(a) * d) * CFrame.Angles(rng:NextNumber() * 6, rng:NextNumber() * 6, rng:NextNumber() * 6), color, material))
		table.insert(kids, bit)
	end
	return main, kids
end

-- Frosting with sprinkles on top.
local function shapeSprinkles(cf: CFrame, size: number, color: Color3, material: Enum.Material, rng: Random)
	local main, kids = shapeBlob(cf, size, Color3.fromRGB(255, 235, 245), material, rng)
	for _ = 1, rng:NextInteger(7, 11) do
		local a = rng:NextNumber() * math.pi * 2
		local d = size * 0.4 * math.sqrt(rng:NextNumber())
		local stick = decor(newPart(nil, Vector3.new(0.15, size * 0.22, 0.15), cf * CFrame.new(0.2, math.cos(a) * d, math.sin(a) * d) * CFrame.Angles(rng:NextNumber() * math.pi, 0, 0), SPRINKLE_COLORS[rng:NextInteger(1, #SPRINKLE_COLORS)], Enum.Material.SmoothPlastic))
		table.insert(kids, stick)
	end
	return main, kids
end

----------------------------------------------------------------------------------------------------
-- ApplyGrime (dirt)
----------------------------------------------------------------------------------------------------
local GOLDEN_COLOR = Color3.fromRGB(255, 213, 80)
local RAY_ATTEMPTS = 14
local MIN_SPACING = 1.2 -- spots on the same dish don't pile on top of each other
local FIT_TOLERANCE = 0.35 -- how far the dish surface may drift from a spot's plane at its edge

-- The dish surface under `pos` along `normal` (a short ray back down onto the dish), or nil.
local function surfaceAt(params: RaycastParams, pos: Vector3, normal: Vector3): RaycastResult?
	return workspace:Raycast(pos + normal * 1.2, -normal * 2.6, params)
end

-- Does a flat spot of `radius` at `center` sit on the dish all the way round? (No overhang off an
-- edge, and not floating over a curve.)
local function fits(params: RaycastParams, center: Vector3, normal: Vector3, radius: number): boolean
	local cf = axisCFrame(center, normal, if math.abs(normal.Y) > 0.9 then Vector3.new(1, 0, 0) else Vector3.new(0, 1, 0))
	for i = 1, 8 do
		local a = i / 8 * math.pi * 2
		local p = (cf * CFrame.new(0, math.cos(a) * radius, math.sin(a) * radius)).Position
		local hit = surfaceAt(params, p, normal)
		if not hit or math.abs((hit.Position - p):Dot(normal)) > FIT_TOLERANCE then
			return false
		end
	end
	return true
end

-- Glues a decoration part onto the dish surface under it, keeping its height above the surface.
-- Returns false (and the caller drops it) when there's no dish underneath: that's what used to leave
-- splats hanging off plate edges and cutlery.
local function snapToSurface(params: RaycastParams, child: BasePart, basePos: Vector3, baseNormal: Vector3): boolean
	local c = child.CFrame
	local lift = (c.Position - basePos):Dot(baseNormal)
	local hit = surfaceAt(params, c.Position - baseNormal * lift, baseNormal)
	if not hit then
		return false
	end
	local ok, rot = pcall(CFrame.fromRotationBetweenVectors, baseNormal, hit.Normal)
	local turn = if ok and rot then rot else CFrame.identity
	child.CFrame = CFrame.new(hit.Position + hit.Normal * lift) * turn * c.Rotation
	return true
end

function DishFactory.ApplyGrime(dish: Model, dishId: number, count: number, levelIndex: number, rng: Random, goldenChance: number, folder: Folder): { BasePart }
	local kind = dish:GetAttribute("Kind")
	local anchor = dish:GetAttribute("Anchor")
	if typeof(anchor) ~= "CFrame" or typeof(kind) ~= "string" then
		warn("[DishFactory] ApplyGrime: dish is missing its Anchor/Kind attributes")
		return {}
	end
	local candidateFn = CANDIDATES[kind]
	if not candidateFn then
		return {}
	end

	local level = Config.GetLevel(levelIndex)
	local levelMult = level.Mult

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { dish }

	local placed: { BasePart } = {}
	local used: { Vector3 } = {}
	count = math.max(1, count)

	for _ = 1, count do
		local entry = Util.WeightedPick(level.Grime, "Weight", rng)
		local grimeType = Config.GrimeTypes[entry.Type]
		if not grimeType then
			continue
		end
		local size = rng:NextNumber(grimeType.Size[1], grimeType.Size[2]) * DIRT_SCALE

		-- Find a spot where the whole splat sits on the dish; shrink it if it only just misses.
		local hitPos, hitNormal = nil, nil
		for attempt = 1, RAY_ATTEMPTS do
			local lo, ld = candidateFn(rng)
			if ld.Magnitude > 1e-4 then
				local originWorld = localPos(anchor, lo.X, lo.Y, lo.Z)
				local dirWorld = localDir(anchor, ld.X, ld.Y, ld.Z).Unit * 40
				local result = workspace:Raycast(originWorld, dirWorld, params)
				if result then
					local crowded = false
					for _, p in used do
						if (p - result.Position).Magnitude < MIN_SPACING then
							crowded = true
							break
						end
					end
					if not crowded then
						if fits(params, result.Position, result.Normal, size * 0.5) then
							hitPos, hitNormal = result.Position, result.Normal
							break
						elseif attempt > RAY_ATTEMPTS / 2 and fits(params, result.Position, result.Normal, size * 0.32) then
							size *= 0.65
							hitPos, hitNormal = result.Position, result.Normal
							break
						end
					end
				end
			end
		end
		if hitPos and hitNormal then
			table.insert(used, hitPos)
			local golden = rng:NextNumber() < goldenChance
			local hint = if math.abs(hitNormal:Dot(Vector3.new(0, 1, 0))) > 0.9 then anchor.RightVector else Vector3.new(0, 1, 0)
			local cf = axisCFrame(hitPos + hitNormal * 0.08, hitNormal, hint)
			cf = cf * CFrame.Angles(rng:NextNumber() * math.pi * 2, 0, 0)

			local color = if golden then GOLDEN_COLOR else grimeType.Color
			local material = grimeType.Material

			local part: BasePart, children: { BasePart }
			if grimeType.Shape == "Crumbs" then
				part, children = shapeCrumbs(cf, size, color, material, rng)
			elseif grimeType.Shape == "Sprinkles" then
				part, children = shapeSprinkles(cf, size, color, material, rng)
			elseif grimeType.Shape == "Streak" then
				part, children = shapeStreak(cf, size, color, material, rng)
			else
				part, children = shapeBlob(cf, size, color, material, rng)
			end

			part.Name = "Dirt"
			part.CanTouch = false
			part.CanQuery = true
			part.CanCollide = false
			part.CastShadow = false
			-- Stay in the Default collision group: spatial queries (the server's scrub overlap,
			-- raycasts) skip parts whose group can't collide with the query's group, so a
			-- "collides with nothing" group would make dirt impossible to clean.

			local hp = math.max(1, math.floor(grimeType.HP * levelMult + 0.5))
			local units = math.max(1, math.floor(grimeType.Units * levelMult + 0.5))
			local minTool = grimeType.MinTool
			if golden then
				units = math.floor(units * Config.Round.GoldenUnitsMult + 0.5)
				minTool = 1
				part.Material = Enum.Material.Neon
				part.Color = GOLDEN_COLOR
				for _, child in children do
					child.Color = GOLDEN_COLOR
					child.Material = Enum.Material.Foil
				end
				local attach = Instance.new("Attachment")
				attach.Parent = part
				local emitter = Instance.new("ParticleEmitter")
				emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
				emitter.Lifetime = NumberRange.new(0.5, 1.0)
				emitter.Rate = 6
				emitter.Speed = NumberRange.new(0.5, 1.5)
				emitter.Size = NumberSequence.new(0.5, 0)
				emitter.Color = ColorSequence.new(GOLDEN_COLOR)
				emitter.Parent = attach
			end

			part:SetAttribute("HP", hp)
			part:SetAttribute("MaxHP", hp)
			part:SetAttribute("Units", units)
			part:SetAttribute("Type", entry.Type)
			part:SetAttribute("DishId", dishId)
			part:SetAttribute("Golden", golden)
			part:SetAttribute("MinTool", minTool)
			part:SetAttribute("BaseSize", part.Size)
			part:SetAttribute("BaseTransparency", part.Transparency)

			for _, child in children do
				if snapToSurface(params, child, hitPos, hitNormal) then
					child:SetAttribute("BaseSize", child.Size)
					child.Parent = part
				else
					child:Destroy()
				end
			end

			part.Parent = folder
			table.insert(placed, part)
		end
	end

	return placed
end

----------------------------------------------------------------------------------------------------
-- SetGrimeHealth: cheap per-frame-ish update while a spot is being scrubbed. The splat shrinks and
-- fades toward nothing as it's cleaned.
----------------------------------------------------------------------------------------------------
function DishFactory.SetGrimeHealth(part: BasePart, fraction: number)
	fraction = math.clamp(fraction, 0, 1)
	local shrink = 0.45 + 0.55 * fraction
	local baseT = part:GetAttribute("BaseTransparency")
	local fade = (1 - fraction) * 0.8
	local baseSize = part:GetAttribute("BaseSize")
	if typeof(baseSize) == "Vector3" then
		part.Size = Vector3.new(baseSize.X, baseSize.Y * shrink, baseSize.Z * shrink)
	end
	part.Transparency = math.min(1, (if type(baseT) == "number" then baseT else 0) + fade)

	for _, child in part:GetChildren() do
		if child:IsA("BasePart") then
			local childBase = child:GetAttribute("BaseSize")
			if typeof(childBase) == "Vector3" then
				child.Size = childBase * shrink
			end
			child.Transparency = fade
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Sparkle: the finished-dish effect. Server-side so every client sees the same thing.
----------------------------------------------------------------------------------------------------
function DishFactory.Sparkle(dish: Model)
	if not dish or not dish.Parent then
		return
	end
	local root = dish.PrimaryPart or dish:FindFirstChildWhichIsA("BasePart")
	if not root then
		return
	end

	local ok = pcall(function()
		local highlight = Instance.new("Highlight")
		highlight.FillColor = Color3.new(1, 1, 1)
		highlight.FillTransparency = 0.3
		highlight.OutlineTransparency = 1
		highlight.Adornee = dish
		highlight.Parent = dish
		Debris:AddItem(highlight, 0.5)

		local attach = Instance.new("Attachment")
		attach.Parent = root
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		emitter.Lifetime = NumberRange.new(0.4, 0.9)
		emitter.Rate = 0
		emitter.Speed = NumberRange.new(3, 8)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new(1, 0)
		emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
		emitter.Parent = attach
		emitter:Emit(30)
		Debris:AddItem(attach, 1.5)
	end)
	if not ok then
		warn("[DishFactory] Sparkle effect failed")
	end
end

return DishFactory
