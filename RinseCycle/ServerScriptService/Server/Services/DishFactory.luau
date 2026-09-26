-- DishFactory: builds one dish (plate/bowl/cup/glass/fork/knife/spoon/pan/pot) out of primitive
-- parts, and covers a built dish in grime spots that sit on its real, raycast-checked surfaces.
--
-- Everything here works in the dish's own "anchor" frame: `cf` (a CFrame passed to BuildDish) whose
-- Position is the contact point where the dish touches the rack/basket, and whose axes we reuse as
-- a local coordinate system for the rest of the geometry:
--   local X = cf.RightVector   (sideways across the dish)
--   local Y = cf.UpVector      (straight up from the contact point)
--   local Z = cf.LookVector    (the direction a plate's face points; "forward" for everything else)
-- BuildDish stores that CFrame on the model (attribute "Anchor") so ApplyGrime can rebuild the same
-- local geometry later without needing the caller to pass it again.
--
-- This module owns no state that outlives a single Init() except the bowl template in
-- ServerStorage.DishTemplates, so it has no server dependencies (see DESIGN.md section 3's graph).

local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Util = require(Shared:WaitForChild("Util"))

local DishFactory = {}

----------------------------------------------------------------------------------------------------
-- Sizes (DESIGN.md section 5, ArenaBuilder/DishFactory), relative to a ~5 stud tall character.
----------------------------------------------------------------------------------------------------
local SIZE = {
	Plate = { Diameter = 11, Thickness = 0.6 },
	Bowl = { Diameter = 9, Depth = 4.5 },
	Cup = { Diameter = 5, Height = 6 },
	Glass = { Diameter = 4.5, Height = 8 },
	Fork = { Height = 13 },
	Knife = { Height = 13 },
	Spoon = { Height = 13 },
	Pan = { Diameter = 16, Depth = 3 },
	Pot = { Diameter = 14, Height = 10 },
}

local BRIGHT_COLORS = {
	Color3.fromRGB(255, 90, 90),
	Color3.fromRGB(90, 140, 255),
	Color3.fromRGB(90, 220, 120),
	Color3.fromRGB(255, 210, 60),
	Color3.fromRGB(255, 120, 200),
	Color3.fromRGB(255, 160, 60),
	Color3.fromRGB(170, 110, 255),
	Color3.fromRGB(90, 220, 220),
}

----------------------------------------------------------------------------------------------------
-- Template state (built once in Init)
----------------------------------------------------------------------------------------------------
local templatesFolder: Folder? = nil
local bowlShellTemplate: BasePart? = nil -- a hollowed-out PartOperation, or nil if GeometryService failed

----------------------------------------------------------------------------------------------------
-- Small geometry helpers, all working in an anchor CFrame's local axes.
----------------------------------------------------------------------------------------------------

-- Local (x = Right, y = Up, z = Look) -> world position.
local function localPos(anchor: CFrame, x: number, y: number, z: number): Vector3
	return anchor.Position + anchor.RightVector * x + anchor.UpVector * y + anchor.LookVector * z
end

-- Local (x, y, z) -> world direction (not normalized to a point, just a direction/offset).
local function localDir(anchor: CFrame, x: number, y: number, z: number): Vector3
	return anchor.RightVector * x + anchor.UpVector * y + anchor.LookVector * z
end

-- A part whose local X axis is `axisWorld` (used for Shape = Cylinder, where X is the axis).
local function axisCFrame(pos: Vector3, axisWorld: Vector3, hintWorld: Vector3): CFrame
	local ok, cf = pcall(CFrame.fromMatrix, pos, axisWorld.Unit, hintWorld.Unit)
	if ok then
		return cf
	end
	-- axisWorld and hintWorld were (nearly) parallel; fall back to a safe hint.
	return CFrame.fromMatrix(pos, axisWorld.Unit, Vector3.new(0, 1, 0))
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
	p.Anchored = true
	p.CanCollide = true
	p.CanTouch = false
	p.CanQuery = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function newWedge(size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): BasePart
	local p = Instance.new("WedgePart")
	p.Size = Vector3.new(math.max(size.X, 0.05), math.max(size.Y, 0.05), math.max(size.Z, 0.05))
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = true
	p.CanTouch = false
	p.CanQuery = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

-- A small "D" shaped handle bracket (three parts) attached to the side of a cylindrical body.
-- `attachY0`/`attachY1` are local heights of the two attach points; `out` is how far it pokes out.
local function buildHandle(anchor: CFrame, radius: number, attachY0: number, attachY1: number, out: number, thickness: number, color: Color3, material: Enum.Material?): { BasePart }
	local parts = {}
	local midY = (attachY0 + attachY1) / 2
	local armHeight = math.abs(attachY1 - attachY0)

	-- Outer vertical bar.
	local barCF = axisCFrame(localPos(anchor, 0, midY, radius + out / 2), anchor.UpVector, anchor.LookVector)
	table.insert(parts, newPart(nil, Vector3.new(thickness, armHeight, thickness), barCF, color, material))

	-- Top and bottom stubs connecting the bar to the body.
	for _, y in { attachY0, attachY1 } do
		local stubCF = axisCFrame(localPos(anchor, 0, y, radius + out / 2), anchor.LookVector, anchor.UpVector)
		table.insert(parts, newPart(nil, Vector3.new(out + thickness, thickness, thickness), stubCF, color, material))
	end
	return parts
end

----------------------------------------------------------------------------------------------------
-- Per-kind builders. Each returns (parts: {BasePart}, primaryIndex: number).
----------------------------------------------------------------------------------------------------

local function buildPlate(anchor: CFrame, theme, rng: Random)
	local s = SIZE.Plate
	local radius = s.Diameter / 2
	local center = localPos(anchor, 0, radius, 0)
	local cf = axisCFrame(center, anchor.LookVector, anchor.UpVector)
	-- The rim is the full thickness/diameter; the body sits inset (recessed) inside it, so both
	-- faces show a proud rim ring around a slightly recessed centre.
	local rim = newPart(Enum.PartType.Cylinder, Vector3.new(s.Thickness, s.Diameter, s.Diameter), cf, theme.PlateRim, Enum.Material.SmoothPlastic)
	local body = newPart(Enum.PartType.Cylinder, Vector3.new(s.Thickness * 0.65, s.Diameter * 0.82, s.Diameter * 0.82), cf, theme.Plate, Enum.Material.SmoothPlastic)
	return { rim, body }, 1
end

local function buildBowlFallback(anchor: CFrame, theme, rng: Random)
	local s = SIZE.Bowl
	local radius = s.Diameter / 2
	local parts = {}
	local base = newPart(Enum.PartType.Ball, Vector3.new(s.Diameter * 0.85, s.Depth * 0.7, s.Diameter * 0.85), CFrame.new(localPos(anchor, 0, s.Depth * 0.35, 0)) * anchor.Rotation, theme.Bowl)
	table.insert(parts, base)

	local wallCount = 10
	for i = 1, wallCount do
		local theta = (i - 1) / wallCount * math.pi * 2 + rng:NextNumber() * 0.15
		local out = Vector3.new(math.cos(theta), 0, math.sin(theta))
		local outWorld = localDir(anchor, out.X, 0, out.Z).Unit
		local pos = localPos(anchor, out.X * radius * 0.92, s.Depth * 0.55, out.Z * radius * 0.92)
		local cf = CFrame.lookAt(pos, pos + outWorld, anchor.UpVector) * CFrame.Angles(math.rad(18), 0, 0)
		local wall = newPart(nil, Vector3.new(radius * 0.72, s.Depth * 0.95, 0.5), cf, theme.Bowl)
		table.insert(parts, wall)
	end
	return parts, 1
end

local function buildBowl(anchor: CFrame, theme, rng: Random)
	if bowlShellTemplate then
		local ok, clone = pcall(function()
			return bowlShellTemplate:Clone()
		end)
		if ok and clone then
			local s = SIZE.Bowl
			clone.CFrame = CFrame.new(localPos(anchor, 0, s.Depth, 0)) * anchor.Rotation
			clone.Color = theme.Bowl
			clone.Anchored = true
			clone.CanCollide = true
			clone.CanTouch = false
			clone.CanQuery = true
			clone.Name = "Bowl"
			return { clone }, 1
		end
	end
	return buildBowlFallback(anchor, theme, rng)
end

-- Shared body for Cup/Glass/Pot: an upright (or upside-down) cylinder, contact point at local y=0.
local function buildCylinderBody(anchor: CFrame, diameter: number, height: number, color: Color3, material: Enum.Material?): BasePart
	local center = localPos(anchor, 0, height / 2, 0)
	local cf = axisCFrame(center, anchor.UpVector, anchor.LookVector)
	return newPart(Enum.PartType.Cylinder, Vector3.new(height, diameter, diameter), cf, color, material)
end

local function buildCup(anchor: CFrame, theme, rng: Random)
	local s = SIZE.Cup
	local body = buildCylinderBody(anchor, s.Diameter, s.Height, theme.Cup)
	local handle = buildHandle(anchor, s.Diameter / 2, s.Height * 0.28, s.Height * 0.72, 1.1, 0.5, theme.Cup)
	local parts = { body }
	for _, h in handle do
		table.insert(parts, h)
	end
	return parts, 1
end

local function buildGlass(anchor: CFrame, theme, rng: Random)
	local s = SIZE.Glass
	local body = buildCylinderBody(anchor, s.Diameter, s.Height, theme.Glass, Enum.Material.Glass)
	return { body }, 1
end

local function buildPan(anchor: CFrame, theme, rng: Random)
	local s = SIZE.Pan
	local body = buildCylinderBody(anchor, s.Diameter, s.Depth, theme.Metal, Enum.Material.Metal)
	local handleLen = 9
	local handleCF = axisCFrame(
		localPos(anchor, s.Diameter / 2 + handleLen / 2, s.Depth * 0.6, 0),
		anchor.RightVector,
		anchor.UpVector
	)
	local handle = newPart(Enum.PartType.Cylinder, Vector3.new(handleLen, 0.9, 0.9), handleCF, theme.Metal, Enum.Material.Metal)
	return { body, handle }, 1
end

local function buildPot(anchor: CFrame, theme, rng: Random)
	local s = SIZE.Pot
	local body = buildCylinderBody(anchor, s.Diameter, s.Height, theme.Metal, Enum.Material.Metal)
	local parts = { body }
	-- Two loop handles on opposite sides near the rim.
	for _, side in { 1, -1 } do
		local y0, y1 = s.Height * 0.72, s.Height * 0.92
		local mid = (y0 + y1) / 2
		local out = 1.4
		local barCF = axisCFrame(
			localPos(anchor, side * (s.Diameter / 2 + out * 0.5), mid, 0),
			anchor.LookVector,
			anchor.UpVector
		)
		table.insert(parts, newPart(nil, Vector3.new(0.5, math.abs(y1 - y0), 0.5), barCF, theme.Metal, Enum.Material.Metal))
		for _, y in { y0, y1 } do
			local stubCF = axisCFrame(
				localPos(anchor, side * (s.Diameter / 2 + out * 0.5) * 0.5, y, 0),
				anchor.RightVector,
				anchor.UpVector
			)
			table.insert(parts, newPart(nil, Vector3.new(out + 0.5, 0.5, 0.5), stubCF, theme.Metal, Enum.Material.Metal))
		end
	end
	return parts, 1
end

-- Cutlery: a handle standing up from the basket floor (local y=0), a head at the top.
local function buildFork(anchor: CFrame, theme, rng: Random)
	local total = SIZE.Fork.Height
	local handleH = total * 0.6
	local headH = total - handleH
	local handleCF = axisCFrame(localPos(anchor, 0, handleH / 2, 0), anchor.UpVector, anchor.LookVector)
	local handle = newPart(Enum.PartType.Cylinder, Vector3.new(handleH, 0.9, 0.6), handleCF, theme.Metal, Enum.Material.Metal)

	local neckCF = axisCFrame(localPos(anchor, 0, handleH + headH * 0.12, 0), anchor.UpVector, anchor.LookVector)
	local neck = newPart(nil, Vector3.new(headH * 0.24, 2.6, 1.4), neckCF, theme.Metal, Enum.Material.Metal)

	local parts = { handle, neck }
	local tineCount = 4
	local spread = 2.6
	for i = 1, tineCount do
		local x = (i - (tineCount + 1) / 2) * (spread / (tineCount - 1))
		local tineCF = axisCFrame(localPos(anchor, x, handleH + headH * 0.6, 0), anchor.UpVector, anchor.LookVector)
		table.insert(parts, newPart(Enum.PartType.Cylinder, Vector3.new(headH * 0.8, 0.32, 0.32), tineCF, theme.Metal, Enum.Material.Metal))
	end
	return parts, 1
end

local function buildKnife(anchor: CFrame, theme, rng: Random)
	local total = SIZE.Knife.Height
	local handleH = total * 0.45
	local bladeH = total - handleH
	local handleCF = axisCFrame(localPos(anchor, 0, handleH / 2, 0), anchor.UpVector, anchor.LookVector)
	local handle = newPart(Enum.PartType.Cylinder, Vector3.new(handleH, 1.0, 0.7), handleCF, Color3.fromRGB(60, 60, 65), Enum.Material.SmoothPlastic)

	-- Tapered blade: a wedge with its point up.
	local bladeCF = CFrame.new(localPos(anchor, 0, handleH, -0.35)) * anchor.Rotation * CFrame.Angles(math.rad(90), 0, 0)
	local blade = newWedge(Vector3.new(0.35, 1.8, bladeH), bladeCF, theme.Metal, Enum.Material.Metal)
	return { handle, blade }, 1
end

local function buildSpoon(anchor: CFrame, theme, rng: Random)
	local total = SIZE.Spoon.Height
	local handleH = total * 0.68
	local handleCF = axisCFrame(localPos(anchor, 0, handleH / 2, 0), anchor.UpVector, anchor.LookVector)
	local handle = newPart(Enum.PartType.Cylinder, Vector3.new(handleH, 0.9, 0.6), handleCF, theme.Metal, Enum.Material.Metal)

	local bowlCenter = localPos(anchor, 0, handleH + 1.6, 0)
	local bowl = Instance.new("Part")
	bowl.Shape = Enum.PartType.Ball
	bowl.Size = Vector3.new(2.0, 2.0, 2.0)
	bowl.CFrame = CFrame.new(bowlCenter) * anchor.Rotation
	bowl.Color = theme.Metal
	bowl.Material = Enum.Material.Metal
	bowl.Anchored = true
	bowl.CanCollide = true
	bowl.CanTouch = false
	bowl.CanQuery = true
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = Vector3.new(1.3, 1.9, 1.0)
	mesh.Parent = bowl
	return { handle, bowl }, 1
end

local BUILDERS: { [string]: (CFrame, any, Random) -> ({ BasePart }, number) } = {
	Plate = buildPlate,
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
-- Init: prebuild the hollow-bowl template. Falls back silently (see buildBowlFallback) on any error.
----------------------------------------------------------------------------------------------------
local function tryBuildBowlShell(): BasePart?
	local GeometryService = game:GetService("GeometryService")
	local s = SIZE.Bowl
	local farAway = Vector3.new(0, 4000, 0) -- keep it well clear of anything else being built

	local outer = Instance.new("Part")
	outer.Shape = Enum.PartType.Ball
	outer.Size = Vector3.new(s.Diameter, s.Diameter, s.Diameter)
	outer.CFrame = CFrame.new(farAway)
	outer.Anchored = true
	outer.Parent = ServerStorage

	local hollow = Instance.new("Part")
	hollow.Shape = Enum.PartType.Ball
	hollow.Size = Vector3.new(s.Diameter - 1, s.Diameter - 0.6, s.Diameter - 1)
	hollow.CFrame = CFrame.new(farAway + Vector3.new(0, 1.1, 0))
	hollow.Anchored = true
	hollow.Parent = ServerStorage

	local lid = Instance.new("Part")
	lid.Size = Vector3.new(s.Diameter + 4, s.Diameter, s.Diameter + 4)
	lid.CFrame = CFrame.new(farAway + Vector3.new(0, s.Diameter / 2 + s.Depth, 0))
	lid.Anchored = true
	lid.Parent = ServerStorage

	local ok, result = pcall(function()
		return GeometryService:SubtractAsync(outer, { hollow, lid }, { SplitApart = false })
	end)

	if hollow.Parent then
		hollow:Destroy()
	end
	if lid.Parent then
		lid:Destroy()
	end
	if outer.Parent then
		outer:Destroy()
	end

	if ok and type(result) == "table" and result[1] then
		local shell = result[1] :: BasePart
		shell.Name = "BowlShell"
		shell.Anchored = true
		shell.CanCollide = true
		shell.CanTouch = false
		shell.CanQuery = true
		shell.Parent = templatesFolder
		return shell
	end
	return nil
end

function DishFactory.Init()
	local folder = ServerStorage:FindFirstChild("DishTemplates")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "DishTemplates"
		folder.Parent = ServerStorage
	end
	templatesFolder = folder :: Folder

	local ok, shellOrErr = pcall(tryBuildBowlShell)
	if ok and shellOrErr then
		bowlShellTemplate = shellOrErr
	else
		bowlShellTemplate = nil
		if not ok then
			warn("[DishFactory] GeometryService bowl template failed, using fallback bowl: " .. tostring(shellOrErr))
		end
	end
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
-- Grime placement: per-kind candidate rays, in the dish's local (Right, Up, Look) axes.
-- Returns (localOrigin, localDirection); both get converted to world space before raycasting.
----------------------------------------------------------------------------------------------------
local function candidatePlate(rng: Random)
	local side = if rng:NextNumber() < 0.5 then 1 else -1
	local r = math.sqrt(rng:NextNumber()) * 4.2
	local theta = rng:NextNumber() * math.pi * 2
	local x, y = r * math.cos(theta), SIZE.Plate.Diameter / 2 + r * math.sin(theta)
	return Vector3.new(x, y, side * 3), Vector3.new(0, 0, -side)
end

local function candidateBowl(rng: Random)
	local s = SIZE.Bowl
	local theta = rng:NextNumber() * math.pi * 2
	local frac = rng:NextNumber()
	local r = (s.Diameter / 2 - 0.3) * frac
	local y = 0.3 + s.Depth * 0.85 * frac
	local x, z = r * math.cos(theta), r * math.sin(theta)
	local ox, oz = x * 1.6, z * 1.6
	local origin = Vector3.new(ox, y + 3, oz)
	local target = Vector3.new(x, y, z)
	return origin, (target - origin)
end

local function candidateCylinderSide(diameter: number, height: number, rng: Random)
	local theta = rng:NextNumber() * math.pi * 2
	local y = rng:NextNumber() * height
	local radius = diameter / 2
	local nx, nz = math.cos(theta), math.sin(theta)
	local x, z = nx * radius, nz * radius
	return Vector3.new(x + nx * 3, y, z + nz * 3), Vector3.new(-nx, 0, -nz)
end

local function candidateCylinderTop(diameter: number, height: number, rng: Random)
	local r = math.sqrt(rng:NextNumber()) * (diameter / 2 - 0.2)
	local theta = rng:NextNumber() * math.pi * 2
	local x, z = r * math.cos(theta), r * math.sin(theta)
	return Vector3.new(x, height + 3, z), Vector3.new(0, -1, 0)
end

local function candidateCupLike(diameter: number, height: number, rng: Random)
	if rng:NextNumber() < 0.75 then
		return candidateCylinderSide(diameter, height, rng)
	end
	return candidateCylinderTop(diameter, height, rng)
end

local function candidatePan(rng: Random)
	local s = SIZE.Pan
	local r = math.sqrt(rng:NextNumber()) * (s.Diameter / 2 - 0.5)
	local theta = rng:NextNumber() * math.pi * 2
	local x, z = r * math.cos(theta), r * math.sin(theta)
	return Vector3.new(x, s.Depth + 3, z), Vector3.new(0, -1, 0)
end

local function candidateCutlery(height: number, rng: Random)
	local side = if rng:NextNumber() < 0.5 then 1 else -1
	local y = height * (0.62 + rng:NextNumber() * 0.36)
	local z = (rng:NextNumber() - 0.5) * 1.0
	return Vector3.new(side * 3, y, z), Vector3.new(-side, 0, 0)
end

local CANDIDATES: { [string]: (Random) -> (Vector3, Vector3) } = {
	Plate = candidatePlate,
	Bowl = candidateBowl,
	Cup = function(rng)
		return candidateCupLike(SIZE.Cup.Diameter, SIZE.Cup.Height, rng)
	end,
	Glass = function(rng)
		return candidateCupLike(SIZE.Glass.Diameter, SIZE.Glass.Height, rng)
	end,
	Pan = candidatePan,
	Pot = function(rng)
		return candidateCupLike(SIZE.Pot.Diameter, SIZE.Pot.Height, rng)
	end,
	Fork = function(rng)
		return candidateCutlery(SIZE.Fork.Height, rng)
	end,
	Knife = function(rng)
		return candidateCutlery(SIZE.Knife.Height, rng)
	end,
	Spoon = function(rng)
		return candidateCutlery(SIZE.Spoon.Height, rng)
	end,
}

----------------------------------------------------------------------------------------------------
-- Grime shape builders. `cf` already has local X = outward normal, sitting ~0.05 studs proud.
----------------------------------------------------------------------------------------------------
local function shapeBlob(cf: CFrame, size: number, color: Color3, material: Enum.Material)
	local part = newPart(Enum.PartType.Cylinder, Vector3.new(0.12, size, size), cf, color, material)
	part.CanCollide = false
	return part, {}
end

local function shapeStreak(cf: CFrame, size: number, color: Color3, material: Enum.Material)
	local part = newPart(nil, Vector3.new(0.1, size * 1.7, size * 0.5), cf, color, material)
	part.CanCollide = false
	return part, {}
end

local function shapeCrumbs(cf: CFrame, size: number, color: Color3, material: Enum.Material, rng: Random)
	local part = newPart(Enum.PartType.Cylinder, Vector3.new(0.1, size * 0.7, size * 0.7), cf, color, material)
	part.CanCollide = false
	local bits = {}
	local n = rng:NextInteger(3, 5)
	for _ = 1, n do
		local dy = (rng:NextNumber() - 0.5) * size * 0.9
		local dz = (rng:NextNumber() - 0.5) * size * 0.9
		local s = size * rng:NextNumber(0.12, 0.22)
		local bit = Instance.new("Part")
		bit.Shape = Enum.PartType.Ball
		bit.Size = Vector3.new(s, s, s)
		bit.CFrame = cf * CFrame.new(0.04, dy, dz)
		bit.Color = color
		bit.Material = material
		bit.Anchored = true
		bit.CanCollide = false
		bit.CanTouch = false
		bit.CanQuery = false
		bit.CastShadow = false
		table.insert(bits, bit)
	end
	return part, bits
end

local function shapeSprinkles(cf: CFrame, size: number, color: Color3, material: Enum.Material, rng: Random)
	local part = newPart(Enum.PartType.Cylinder, Vector3.new(0.1, size * 0.8, size * 0.8), cf, color, material)
	part.CanCollide = false
	local sticks = {}
	local n = rng:NextInteger(6, 10)
	for _ = 1, n do
		local dy = (rng:NextNumber() - 0.5) * size * 0.8
		local dz = (rng:NextNumber() - 0.5) * size * 0.8
		local spin = rng:NextNumber() * math.pi * 2
		local stick = Instance.new("Part")
		stick.Shape = Enum.PartType.Cylinder
		stick.Size = Vector3.new(size * 0.35, 0.12, 0.12)
		stick.CFrame = cf * CFrame.new(0.03, dy, dz) * CFrame.Angles(spin, rng:NextNumber() * math.pi, 0)
		stick.Color = BRIGHT_COLORS[rng:NextInteger(1, #BRIGHT_COLORS)]
		stick.Material = Enum.Material.SmoothPlastic
		stick.Anchored = true
		stick.CanCollide = false
		stick.CanTouch = false
		stick.CanQuery = false
		stick.CastShadow = false
		table.insert(sticks, stick)
	end
	return part, sticks
end

----------------------------------------------------------------------------------------------------
-- ApplyGrime
----------------------------------------------------------------------------------------------------
local GOLDEN_COLOR = Color3.fromRGB(255, 213, 80)
local RAY_ATTEMPTS = 8

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
	count = math.max(1, count)

	for _ = 1, count do
		local hitPos, hitNormal = nil, nil
		for _attempt = 1, RAY_ATTEMPTS do
			local lo, ld = candidateFn(rng)
			if ld.Magnitude > 1e-4 then
				local originWorld = localPos(anchor, lo.X, lo.Y, lo.Z)
				local dirWorld = localDir(anchor, ld.X, ld.Y, ld.Z).Unit * 40
				local result = workspace:Raycast(originWorld, dirWorld, params)
				if result then
					hitPos, hitNormal = result.Position, result.Normal
					break
				end
			end
		end
		if hitPos and hitNormal then
			local entry = Util.WeightedPick(level.Grime, "Weight", rng)
			local grimeType = Config.GrimeTypes[entry.Type]
			if grimeType then
				local golden = rng:NextNumber() < goldenChance
				local size = rng:NextNumber(grimeType.Size[1], grimeType.Size[2])
				local hint = if math.abs(hitNormal:Dot(Vector3.new(0, 1, 0))) > 0.9 then anchor.RightVector else Vector3.new(0, 1, 0)
				local cf = axisCFrame(hitPos + hitNormal * 0.05, hitNormal, hint)
				cf = cf * CFrame.Angles(rng:NextNumber() * math.pi * 2, 0, 0)

				local color = if golden then GOLDEN_COLOR else grimeType.Color
				local material = grimeType.Material

				local part: BasePart, children: { BasePart }
				if grimeType.Shape == "Crumbs" then
					part, children = shapeCrumbs(cf, size, color, material, rng)
				elseif grimeType.Shape == "Sprinkles" then
					part, children = shapeSprinkles(cf, size, color, material, rng)
				elseif grimeType.Shape == "Streak" then
					part, children = shapeStreak(cf, size, color, material)
				else
					part, children = shapeBlob(cf, size, color, material)
				end

				part.CanTouch = false
				part.CanQuery = true
				part.CastShadow = false
				part.CollisionGroup = "NoCollide"

				local hp = math.max(1, math.floor(grimeType.HP * levelMult + 0.5))
				local units = math.max(1, math.floor(grimeType.Units * levelMult + 0.5))
				local minTool = grimeType.MinTool
				if golden then
					units = math.floor(units * Config.Round.GoldenUnitsMult + 0.5)
					minTool = 1
					part.Material = if rng:NextNumber() < 0.5 then Enum.Material.Neon else Enum.Material.Foil
					part.Color = GOLDEN_COLOR
					local attach = Instance.new("Attachment")
					attach.Parent = part
					local emitter = Instance.new("ParticleEmitter")
					emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
					emitter.Lifetime = NumberRange.new(0.5, 1.0)
					emitter.Rate = 6
					emitter.Speed = NumberRange.new(0.5, 1.5)
					emitter.Size = NumberSequence.new(0.4, 0)
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

				for _, child in children do
					child.Parent = part
					child:SetAttribute("BaseSize", child.Size)
				end

				part.Parent = folder
				table.insert(placed, part)
			end
		end
	end

	return placed
end

----------------------------------------------------------------------------------------------------
-- SetGrimeHealth: cheap per-frame-ish update while a spot is being scrubbed.
----------------------------------------------------------------------------------------------------
function DishFactory.SetGrimeHealth(part: BasePart, fraction: number)
	fraction = math.clamp(fraction, 0, 1)
	local shrink = 0.55 + 0.45 * fraction
	local transparency = (1 - fraction) * 0.85

	local baseSize = part:GetAttribute("BaseSize")
	if typeof(baseSize) == "Vector3" then
		part.Size = baseSize * shrink
	end
	part.Transparency = transparency

	for _, child in part:GetChildren() do
		if child:IsA("BasePart") then
			local childBase = child:GetAttribute("BaseSize")
			if typeof(childBase) == "Vector3" then
				child.Size = childBase * shrink
			end
			child.Transparency = transparency
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
		emitter.Speed = NumberRange.new(2, 6)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new(0.7, 0)
		emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
		emitter.Parent = attach
		emitter:Emit(24)
		Debris:AddItem(attach, 1.5)
	end)
	if not ok then
		warn("[DishFactory] Sparkle effect failed")
	end
end

return DishFactory
