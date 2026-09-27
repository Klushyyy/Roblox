-- ToolModels: builds a model of each cleaning tool out of primitive parts. Used for the arena's tool
-- shelf (anchored, big) and for the tool in a player's hand (welded, small).
--
-- ToolModels.Build(toolIndex, scale) -> Model
--   * built around CFrame.identity: the model's base sits on Y = 0 and its business end points at -Z
--   * PrimaryPart is "Grip", an invisible 0.2 stud part at the origin
--   * every part is Anchored, CanCollide/CanQuery/CanTouch false, Massless, CastShadow false
--   * Bare Hands (index 1) is just the Grip
-- ToolModels.HoldOffset(toolIndex) -> CFrame: where the Grip sits relative to a RightHand (R15) so
-- the tool looks held.
--
-- Detail comes from a few helpers: rounded boxes (a core plus cylinders on the edges), rings and
-- curved runs of short bars (hoses, trigger guards, handles), ribbed knobs, and small trims and
-- fittings. No two coplanar faces overlap, so nothing flickers.

local ToolModels = {}

local DARK = Color3.fromRGB(40, 42, 50)
local RUBBER = Color3.fromRGB(58, 60, 68)
local WHITE = Color3.fromRGB(245, 247, 250)
local CHROME = Color3.fromRGB(210, 215, 224)
local BRASS = Color3.fromRGB(214, 170, 80)
local WOOD = Color3.fromRGB(170, 116, 72)
local WOOD_DARK = Color3.fromRGB(130, 86, 52)

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis -> up (Y)
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis -> front/back (Z)

local COLORS = {
	Color3.fromRGB(150, 210, 255),
	Color3.fromRGB(255, 221, 87),
	Color3.fromRGB(120, 230, 160),
	Color3.fromRGB(90, 200, 255),
	Color3.fromRGB(60, 140, 255),
	Color3.fromRGB(200, 150, 255),
}

type Ctx = { Model: Model, Scale: number }

local function shade(c: Color3, f: number): Color3
	return Color3.new(math.clamp(c.R * f, 0, 1), math.clamp(c.G * f, 0, 1), math.clamp(c.B * f, 0, 1))
end

-- A part at `cf` (model-local, unscaled studs).
local function partCF(ctx: Ctx, name: string, shape: Enum.PartType?, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, transparency: number?): Part
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
	local s = size * ctx.Scale
	p.Size = Vector3.new(math.max(s.X, 0.05), math.max(s.Y, 0.05), math.max(s.Z, 0.05))
	p.CFrame = CFrame.new(cf.Position * ctx.Scale) * cf.Rotation
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = ctx.Model
	return p
end

local function part(ctx: Ctx, name: string, shape: Enum.PartType?, size: Vector3, offset: Vector3, rot: CFrame?, color: Color3, material: Enum.Material?, transparency: number?): Part
	return partCF(ctx, name, shape, size, CFrame.new(offset) * (rot or CFrame.identity), color, material, transparency)
end

-- A cylinder running from a to b.
local function bar(ctx: Ctx, name: string, a: Vector3, b: Vector3, thickness: number, color: Color3, material: Enum.Material?): Part
	local dir = (b - a)
	local mid = (a + b) / 2
	local hint = if math.abs(dir.Unit.Y) > 0.95 then Vector3.new(1, 0, 0) else Vector3.new(0, 1, 0)
	local rot = CFrame.fromMatrix(Vector3.zero, dir.Unit, hint:Cross(dir.Unit).Unit:Cross(dir.Unit) * -1)
	return part(ctx, name, Enum.PartType.Cylinder, Vector3.new(dir.Magnitude, thickness, thickness), mid, rot, color, material)
end

-- A smooth run of bars through the given points, with a ball at every joint (hoses, curved handles).
local function tube(ctx: Ctx, name: string, points: { Vector3 }, thickness: number, color: Color3, material: Enum.Material?)
	for i = 1, #points - 1 do
		bar(ctx, name, points[i], points[i + 1], thickness, color, material)
		if i > 1 then
			part(ctx, name .. "Joint", Enum.PartType.Ball, Vector3.one * thickness, points[i], nil, color, material)
		end
	end
end

-- Box with rounded edges along its local Y axis (a stadium/rounded-rectangle prism), placed at
-- `cf`. Two crossing cores plus four corner cylinders.
local function roundedBox(ctx: Ctx, name: string, size: Vector3, cf: CFrame, r: number, color: Color3, material: Enum.Material?, transparency: number?)
	r = math.min(r, size.X / 2, size.Z / 2)
	-- (A core with no width left is skipped: two zero-width slabs would share faces and flicker.)
	if size.X - 2 * r > 0.06 then
		partCF(ctx, name, nil, Vector3.new(size.X - 2 * r, size.Y, size.Z), cf, color, material, transparency)
	end
	if size.Z - 2 * r > 0.06 then
		partCF(ctx, name, nil, Vector3.new(size.X, size.Y, size.Z - 2 * r), cf, color, material, transparency)
	end
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			partCF(ctx, name .. "Edge", Enum.PartType.Cylinder, Vector3.new(size.Y, 2 * r, 2 * r), cf * CFrame.new(sx * (size.X / 2 - r), 0, sz * (size.Z / 2 - r)) * UPRIGHT, color, material, transparency)
		end
	end
end

-- A ring of `n` short bars in the XY plane of `cf` (so its axis is cf's Z).
local function ring(ctx: Ctx, name: string, cf: CFrame, radius: number, thickness: number, color: Color3, material: Enum.Material?, n: number?, fromAngle: number?, toAngle: number?)
	local count = n or 14
	local a0, a1 = fromAngle or 0, toAngle or math.pi * 2
	local pts = {}
	for i = 0, count do
		local a = a0 + (a1 - a0) * i / count
		table.insert(pts, (cf * CFrame.new(math.cos(a) * radius, math.sin(a) * radius, 0)).Position)
	end
	tube(ctx, name, pts, thickness, color, material)
end

-- A ribbed knob: a cylinder with small ridges around it. Axis along cf's X.
local function knob(ctx: Ctx, name: string, cf: CFrame, length: number, diameter: number, color: Color3, ridgeColor: Color3)
	partCF(ctx, name, Enum.PartType.Cylinder, Vector3.new(length, diameter, diameter), cf, color)
	for i = 0, 9 do
		local a = i / 10 * math.pi * 2
		partCF(ctx, name .. "Ridge", nil, Vector3.new(length * 0.9, diameter * 0.12, diameter * 0.12), cf * CFrame.Angles(a, 0, 0) * CFrame.new(0, diameter / 2, 0), ridgeColor)
	end
end

local BUILDERS: { [number]: (Ctx, Color3) -> () } = {}

-- Sponge: a rounded block of yellow foam with dimpled pores, a glue line, and a green scouring pad
-- on top with a lighter fleck pattern. A bead of soap suds rides on the pad.
BUILDERS[2] = function(ctx, _color)
	local yellow = Color3.fromRGB(255, 212, 76)
	local foamCF = CFrame.new(0, 0.85, 0)
	roundedBox(ctx, "Foam", Vector3.new(3.4, 1.7, 2.3), foamCF, 0.55, yellow, Enum.Material.SmoothPlastic)
	-- Slightly darker lower lip, so the block reads rounded.
	roundedBox(ctx, "FoamBase", Vector3.new(3.6, 0.3, 2.5), CFrame.new(0, 0.12, 0), 0.6, shade(yellow, 0.85))
	partCF(ctx, "Glue", nil, Vector3.new(3.36, 0.08, 2.26), CFrame.new(0, 1.74, 0), Color3.fromRGB(255, 240, 190))
	roundedBox(ctx, "Pad", Vector3.new(3.4, 0.5, 2.3), CFrame.new(0, 2.03, 0), 0.55, Color3.fromRGB(64, 160, 80), Enum.Material.Fabric)
	-- Flecks on top of the pad.
	local rng = Random.new(3)
	for _ = 1, 10 do
		part(ctx, "Fleck", nil, Vector3.new(0.35, 0.05, 0.12), Vector3.new(rng:NextNumber(-1.3, 1.3), 2.3, rng:NextNumber(-0.8, 0.8)), CFrame.Angles(0, rng:NextNumber(0, math.pi), 0), Color3.fromRGB(110, 200, 120))
	end
	-- Pores: little dimples on the front, back and sides.
	for _ = 1, 9 do
		local x, y = rng:NextNumber(-1.3, 1.3), rng:NextNumber(0.35, 1.45)
		part(ctx, "Pore", Enum.PartType.Ball, Vector3.one * rng:NextNumber(0.22, 0.36), Vector3.new(x, y, -1.13), nil, Color3.fromRGB(214, 168, 46))
		part(ctx, "Pore", Enum.PartType.Ball, Vector3.one * rng:NextNumber(0.22, 0.36), Vector3.new(-x, y, 1.13), nil, Color3.fromRGB(214, 168, 46))
	end
	for _ = 1, 3 do
		part(ctx, "Pore", Enum.PartType.Ball, Vector3.one * 0.28, Vector3.new(1.68, rng:NextNumber(0.4, 1.4), rng:NextNumber(-0.5, 0.5)), nil, Color3.fromRGB(214, 168, 46))
		part(ctx, "Pore", Enum.PartType.Ball, Vector3.one * 0.28, Vector3.new(-1.68, rng:NextNumber(0.4, 1.4), rng:NextNumber(-0.5, 0.5)), nil, Color3.fromRGB(214, 168, 46))
	end
	-- Suds.
	for _, b in { { Vector3.new(0.7, 2.45, -0.3), 0.55 }, { Vector3.new(1.1, 2.4, 0.2), 0.4 }, { Vector3.new(0.35, 2.4, 0.3), 0.35 } } do
		part(ctx, "Suds", Enum.PartType.Ball, Vector3.one * b[2], b[1], nil, WHITE, nil, 0.1)
	end
end

-- Scrub brush: an oval coloured block with a lighter top rim, tufts of bristles in rows underneath,
-- and a curved wooden handle with a rubber grip, a chrome ferrule and a hanging ring.
BUILDERS[3] = function(ctx, color)
	roundedBox(ctx, "Head", Vector3.new(3.2, 0.8, 1.6), CFrame.new(0, 1.15, 0), 0.8, color)
	roundedBox(ctx, "HeadTop", Vector3.new(3.0, 0.25, 1.4), CFrame.new(0, 1.68, 0), 0.7, shade(color, 1.18))
	roundedBox(ctx, "HeadBase", Vector3.new(3.0, 0.15, 1.5), CFrame.new(0, 0.7, 0), 0.75, shade(color, 0.75))
	-- Bristle tufts: 7 x 3 grid, alternating lengths, white with pale tips.
	for i = -3, 3 do
		for j = -1, 1 do
			if math.abs(i) == 3 and j ~= 0 then
				continue -- rounded ends of the head
			end
			local len = if (i + j) % 2 == 0 then 0.65 else 0.55
			local pos = Vector3.new(i * 0.42, 0.65 - len / 2, j * 0.42)
			part(ctx, "Tuft", Enum.PartType.Cylinder, Vector3.new(len, 0.3, 0.3), pos, UPRIGHT, Color3.fromRGB(240, 238, 228), Enum.Material.Fabric)
			part(ctx, "TuftTip", Enum.PartType.Cylinder, Vector3.new(0.06, 0.32, 0.32), pos - Vector3.new(0, len / 2, 0), UPRIGHT, Color3.fromRGB(255, 250, 235), Enum.Material.Fabric)
		end
	end
	-- Handle: rises from the back of the head and curves over it.
	part(ctx, "Ferrule", Enum.PartType.Cylinder, Vector3.new(0.45, 0.72, 0.72), Vector3.new(0, 1.85, 0.55), CFrame.Angles(math.rad(-35), 0, 0) * UPRIGHT, CHROME, Enum.Material.Metal)
	local pts = { Vector3.new(0, 1.8, 0.45), Vector3.new(0, 2.35, 1.05), Vector3.new(0, 2.8, 1.9), Vector3.new(0, 3.05, 2.8), Vector3.new(0, 3.15, 3.5) }
	tube(ctx, "Handle", pts, 0.55, WOOD, Enum.Material.Wood)
	-- Rubber grip wrap near the end, and the end cap with a hanging ring.
	bar(ctx, "GripWrap", Vector3.new(0, 2.95, 2.35), Vector3.new(0, 3.12, 3.25), 0.66, RUBBER)
	for _, t in { 0.25, 0.5, 0.75 } do
		local p = Vector3.new(0, 2.95, 2.35):Lerp(Vector3.new(0, 3.12, 3.25), t)
		part(ctx, "GripRib", Enum.PartType.Cylinder, Vector3.new(0.1, 0.72, 0.72), p, CFrame.Angles(math.rad(-80), 0, 0) * UPRIGHT, shade(RUBBER, 1.3))
	end
	part(ctx, "EndCap", Enum.PartType.Ball, Vector3.one * 0.66, Vector3.new(0, 3.15, 3.5), nil, WOOD_DARK, Enum.Material.Wood)
	ring(ctx, "HangRing", CFrame.new(0, 3.2, 3.95) * CFrame.Angles(0, math.rad(90), 0), 0.3, 0.1, CHROME, Enum.Material.Metal, 10)
end

-- Spray nozzle: a pistol spray gun. Coloured body with a chrome barrel that steps down to the tip,
-- an adjustable spray-pattern dial, a rubber pistol grip with finger ridges, a curved trigger inside
-- a guard, a brass hose fitting, and a coil of hose.
BUILDERS[4] = function(ctx, color)
	local y = 2.3
	-- Body.
	roundedBox(ctx, "Body", Vector3.new(0.9, 1.1, 2.2), CFrame.new(0, y, 0.2) * CFrame.Angles(0, 0, math.rad(90)), 0.45, color)
	partCF(ctx, "BodyStripe", nil, Vector3.new(0.95, 0.18, 1.6), CFrame.new(0, y + 0.3, 0.2), shade(color, 0.7))
	-- Barrel stepping down to the tip.
	part(ctx, "Barrel", Enum.PartType.Cylinder, Vector3.new(1.2, 0.72, 0.72), Vector3.new(0, y, -1.4), ALONG_Z, CHROME, Enum.Material.Metal)
	part(ctx, "BarrelCollar", Enum.PartType.Cylinder, Vector3.new(0.25, 0.9, 0.9), Vector3.new(0, y, -0.9), ALONG_Z, shade(color, 0.8))
	-- Spray-pattern dial at the front.
	local dialCF = CFrame.new(0, y, -2.15) * ALONG_Z
	knob(ctx, "Dial", dialCF, 0.45, 1.05, color, shade(color, 0.7))
	part(ctx, "Tip", Enum.PartType.Cylinder, Vector3.new(0.2, 0.45, 0.45), Vector3.new(0, y, -2.45), ALONG_Z, CHROME, Enum.Material.Metal)
	part(ctx, "TipHole", Enum.PartType.Cylinder, Vector3.new(0.05, 0.18, 0.18), Vector3.new(0, y, -2.56), ALONG_Z, DARK)
	-- Pistol grip with finger ridges.
	local gripCF = CFrame.new(0, 1.2, 0.85) * CFrame.Angles(math.rad(-14), 0, 0)
	roundedBox(ctx, "Grip", Vector3.new(0.8, 2.0, 0.95), gripCF, 0.38, RUBBER)
	for i = 0, 2 do
		partCF(ctx, "FingerRidge", Enum.PartType.Cylinder, Vector3.new(0.82, 0.26, 0.26), gripCF * CFrame.new(0, 0.55 - i * 0.45, -0.47), shade(RUBBER, 1.35))
	end
	partCF(ctx, "GripCap", nil, Vector3.new(0.9, 0.2, 1.05), gripCF * CFrame.new(0, -1.02, 0), color)
	-- Trigger and guard.
	tube(ctx, "Trigger", { Vector3.new(0, 1.75, -0.2), Vector3.new(0, 1.35, -0.3), Vector3.new(0, 1.0, -0.2) }, 0.26, color)
	tube(ctx, "Guard", { Vector3.new(0, 1.75, -0.65), Vector3.new(0, 1.15, -0.7), Vector3.new(0, 0.75, -0.4), Vector3.new(0, 0.62, 0.25) }, 0.14, DARK)
	-- Hose fitting and a coil of green hose trailing back.
	part(ctx, "Fitting", Enum.PartType.Cylinder, Vector3.new(0.5, 0.55, 0.55), Vector3.new(0, 0.1, 1.05), UPRIGHT, BRASS, Enum.Material.Metal)
	local hose = Color3.fromRGB(70, 160, 80)
	tube(ctx, "Hose", { Vector3.new(0, 0.05, 1.1), Vector3.new(0, 0.2, 1.8), Vector3.new(0.6, 0.25, 2.2), Vector3.new(1.2, 0.25, 1.9) }, 0.4, hose)
	ring(ctx, "HoseCoil", CFrame.new(1.35, 0.2, 1.2) * CFrame.Angles(math.rad(90), 0, 0), 0.75, 0.4, hose, nil, 12)
end

-- Pressure washer: a two-tone rounded body on a dark chassis, big wheels with chrome hubs, a hose
-- reel with coils on the side, a gauge, vents, a telescopic handle with foam grips, and the spray
-- gun with its long chrome lance clipped to the side.
BUILDERS[5] = function(ctx, color)
	local bodyCF = CFrame.new(0, 1.9, 0.3)
	roundedBox(ctx, "Body", Vector3.new(2.6, 2.1, 3.0), bodyCF, 0.7, color)
	roundedBox(ctx, "BodyTop", Vector3.new(2.3, 0.4, 2.7), CFrame.new(0, 3.1, 0.3), 0.6, shade(color, 1.2))
	roundedBox(ctx, "Chassis", Vector3.new(2.8, 0.5, 3.2), CFrame.new(0, 0.75, 0.3), 0.5, DARK)
	-- Front face: vents and a badge.
	for i = 0, 3 do
		part(ctx, "Vent", nil, Vector3.new(1.4, 0.12, 0.08), Vector3.new(0, 1.35 + i * 0.25, -1.23), nil, shade(color, 0.55))
	end
	part(ctx, "Badge", nil, Vector3.new(1.1, 0.4, 0.06), Vector3.new(0, 2.55, -1.22), nil, WHITE)
	part(ctx, "BadgeStripe", nil, Vector3.new(0.9, 0.1, 0.05), Vector3.new(0, 2.55, -1.26), nil, Color3.fromRGB(255, 200, 60))
	-- Gauge on top.
	part(ctx, "Gauge", Enum.PartType.Cylinder, Vector3.new(0.2, 0.8, 0.8), Vector3.new(0.6, 3.4, -0.5), UPRIGHT, CHROME, Enum.Material.Metal)
	part(ctx, "GaugeFace", Enum.PartType.Cylinder, Vector3.new(0.06, 0.65, 0.65), Vector3.new(0.6, 3.52, -0.5), UPRIGHT, WHITE)
	part(ctx, "GaugeNeedle", nil, Vector3.new(0.05, 0.04, 0.3), Vector3.new(0.6, 3.56, -0.58), CFrame.Angles(0, math.rad(30), 0), Color3.fromRGB(220, 40, 40))
	-- Power switch.
	part(ctx, "Switch", nil, Vector3.new(0.35, 0.2, 0.5), Vector3.new(-0.6, 3.38, -0.6), nil, Color3.fromRGB(230, 50, 50))
	-- Wheels with hubcaps.
	for _, x in { -1.5, 1.5 } do
		part(ctx, "Wheel", Enum.PartType.Cylinder, Vector3.new(0.55, 1.5, 1.5), Vector3.new(x, 0.75, 1.2), nil, DARK)
		part(ctx, "Tread", Enum.PartType.Cylinder, Vector3.new(0.45, 1.56, 1.56), Vector3.new(x, 0.75, 1.2), nil, RUBBER)
		part(ctx, "Hub", Enum.PartType.Cylinder, Vector3.new(0.6, 0.7, 0.7), Vector3.new(x, 0.75, 1.2), nil, CHROME, Enum.Material.Metal)
		part(ctx, "HubCap", Enum.PartType.Cylinder, Vector3.new(0.72, 0.3, 0.3), Vector3.new(x, 0.75, 1.2), nil, shade(color, 0.8))
	end
	-- Front foot.
	part(ctx, "Foot", nil, Vector3.new(1.8, 0.35, 0.4), Vector3.new(0, 0.18, -0.9), nil, RUBBER)
	-- Telescopic handle.
	for _, x in { -0.95, 0.95 } do
		bar(ctx, "HandleTube", Vector3.new(x, 2.6, 1.65), Vector3.new(x, 5.0, 1.95), 0.28, CHROME, Enum.Material.Metal)
		bar(ctx, "HandleSleeve", Vector3.new(x, 2.5, 1.63), Vector3.new(x, 3.4, 1.73), 0.36, DARK)
	end
	bar(ctx, "HandleBar", Vector3.new(-1.1, 5.0, 1.95), Vector3.new(1.1, 5.0, 1.95), 0.3, CHROME, Enum.Material.Metal)
	bar(ctx, "HandleFoam", Vector3.new(-0.75, 5.0, 1.95), Vector3.new(0.75, 5.0, 1.95), 0.45, RUBBER)
	-- Hose reel on the right side.
	part(ctx, "Reel", Enum.PartType.Cylinder, Vector3.new(0.5, 1.5, 1.5), Vector3.new(1.55, 2.0, 0.6), nil, shade(color, 0.8))
	for i = 0, 2 do
		part(ctx, "ReelCoil", Enum.PartType.Cylinder, Vector3.new(0.12, 1.25 - i * 0.12, 1.25 - i * 0.12), Vector3.new(1.84 + i * 0.035, 2.0, 0.6), nil, if i % 2 == 0 then DARK else RUBBER)
	end
	part(ctx, "ReelCrank", nil, Vector3.new(0.12, 0.7, 0.14), Vector3.new(2.04, 2.3, 0.6), nil, CHROME, Enum.Material.Metal)
	-- Spray gun clipped on the left side, lance pointing forward.
	local gx = -1.6
	roundedBox(ctx, "GunBody", Vector3.new(0.45, 0.6, 1.1), CFrame.new(gx, 2.35, 0.5), 0.22, DARK)
	part(ctx, "GunTrigger", nil, Vector3.new(0.14, 0.45, 0.14), Vector3.new(gx, 1.95, 0.35), nil, Color3.fromRGB(255, 200, 60))
	bar(ctx, "GunGrip", Vector3.new(gx, 2.1, 0.8), Vector3.new(gx, 1.5, 1.0), 0.4, DARK)
	bar(ctx, "Lance", Vector3.new(gx, 2.35, -0.05), Vector3.new(gx, 2.35, -2.9), 0.22, CHROME, Enum.Material.Metal)
	part(ctx, "LanceTip", Enum.PartType.Cylinder, Vector3.new(0.35, 0.36, 0.36), Vector3.new(gx, 2.35, -3.0), ALONG_Z, Color3.fromRGB(255, 200, 60))
	part(ctx, "Clip", nil, Vector3.new(0.4, 0.3, 0.3), Vector3.new(-1.4, 2.35, -0.3), nil, DARK)
	-- Hose from the reel round the back to the gun.
	tube(ctx, "Hose", { Vector3.new(1.55, 1.3, 1.1), Vector3.new(1.0, 0.9, 1.9), Vector3.new(-0.6, 0.9, 2.0), Vector3.new(-1.5, 1.2, 1.4), Vector3.new(gx, 1.5, 1.0) }, 0.2, Color3.fromRGB(30, 32, 38))
end

-- Foam cannon: a sleek blaster. White rounded body with colour stripes, a see-through soap tank on
-- top (pink soap, a cap), a brass adjuster knob, a stepped chrome-and-white bell, a rubber pistol
-- grip and trigger, and a burst of foam from the front.
BUILDERS[6] = function(ctx, color)
	local y = 2.6
	roundedBox(ctx, "Body", Vector3.new(1.1, 1.3, 3.2), CFrame.new(0, y, 0.6) * CFrame.Angles(0, 0, math.rad(90)), 0.55, WHITE)
	for _, dz in { -0.4, 0.2 } do
		partCF(ctx, "Stripe", nil, Vector3.new(1.16, 1.36, 0.18), CFrame.new(0, y, 0.6 + dz), color)
	end
	partCF(ctx, "TopRail", nil, Vector3.new(0.4, 0.2, 2.6), CFrame.new(0, y + 0.72, 0.8), shade(color, 0.75))
	-- Bell: stepped cylinders widening toward the front, with a coloured rim.
	part(ctx, "Neck", Enum.PartType.Cylinder, Vector3.new(0.8, 0.95, 0.95), Vector3.new(0, y, -1.3), ALONG_Z, CHROME, Enum.Material.Metal)
	part(ctx, "Bell1", Enum.PartType.Cylinder, Vector3.new(0.5, 1.4, 1.4), Vector3.new(0, y, -1.9), ALONG_Z, WHITE)
	part(ctx, "Bell2", Enum.PartType.Cylinder, Vector3.new(0.5, 1.9, 1.9), Vector3.new(0, y, -2.35), ALONG_Z, WHITE)
	part(ctx, "Bell3", Enum.PartType.Cylinder, Vector3.new(0.4, 2.35, 2.35), Vector3.new(0, y, -2.75), ALONG_Z, WHITE)
	ring(ctx, "BellRim", CFrame.new(0, y, -2.97), 1.2, 0.2, color, nil, 16)
	part(ctx, "BellMouth", Enum.PartType.Cylinder, Vector3.new(0.05, 2.1, 2.1), Vector3.new(0, y, -2.96), ALONG_Z, Color3.fromRGB(230, 235, 245))
	-- Soap tank on top: glass with soap inside, a cap and a brass adjuster.
	part(ctx, "TankSeat", Enum.PartType.Cylinder, Vector3.new(0.25, 1.35, 1.35), Vector3.new(0, y + 0.78, 0.5), UPRIGHT, shade(color, 0.75))
	part(ctx, "Tank", Enum.PartType.Cylinder, Vector3.new(1.7, 1.25, 1.25), Vector3.new(0, y + 1.75, 0.5), UPRIGHT, Color3.fromRGB(230, 245, 255), Enum.Material.Glass, 0.45)
	part(ctx, "Soap", Enum.PartType.Cylinder, Vector3.new(1.05, 1.05, 1.05), Vector3.new(0, y + 1.45, 0.5), UPRIGHT, Color3.fromRGB(255, 140, 210), nil, 0.1)
	part(ctx, "SoapBubble", Enum.PartType.Ball, Vector3.one * 0.3, Vector3.new(0.2, y + 2.05, 0.4), nil, WHITE, nil, 0.3)
	part(ctx, "TankCap", Enum.PartType.Cylinder, Vector3.new(0.3, 1.35, 1.35), Vector3.new(0, y + 2.73, 0.5), UPRIGHT, color)
	knob(ctx, "Adjuster", CFrame.new(0.72, y, -0.5), 0.5, 0.6, BRASS, shade(BRASS, 0.8))
	-- Pistol grip, trigger and guard.
	local gripCF = CFrame.new(0, 1.35, 1.55) * CFrame.Angles(math.rad(-14), 0, 0)
	roundedBox(ctx, "Grip", Vector3.new(0.85, 2.1, 1.0), gripCF, 0.4, RUBBER)
	for i = 0, 2 do
		partCF(ctx, "FingerRidge", Enum.PartType.Cylinder, Vector3.new(0.87, 0.26, 0.26), gripCF * CFrame.new(0, 0.55 - i * 0.45, -0.5), shade(RUBBER, 1.35))
	end
	tube(ctx, "Trigger", { Vector3.new(0, 1.95, 0.75), Vector3.new(0, 1.55, 0.65), Vector3.new(0, 1.2, 0.75) }, 0.26, color)
	tube(ctx, "Guard", { Vector3.new(0, 1.95, 0.2), Vector3.new(0, 1.3, 0.2), Vector3.new(0, 0.85, 0.55), Vector3.new(0, 0.75, 1.15) }, 0.14, DARK)
	-- Foam burst.
	for _, f in { { Vector3.new(0, y, -3.3), 1.3 }, { Vector3.new(0.6, y + 0.5, -3.6), 0.9 }, { Vector3.new(-0.55, y + 0.45, -3.55), 0.85 }, { Vector3.new(0.3, y - 0.55, -3.5), 0.75 }, { Vector3.new(-0.3, y + 1.0, -3.9), 0.55 }, { Vector3.new(0.15, y + 0.2, -4.1), 0.6 } } do
		part(ctx, "Foam", Enum.PartType.Ball, Vector3.one * f[2], f[1], nil, WHITE, nil, 0.05)
	end
end

function ToolModels.Build(toolIndex: number, scale: number?): Model
	local model = Instance.new("Model")
	model.Name = "Tool_" .. tostring(toolIndex)
	local ctx: Ctx = { Model = model, Scale = scale or 1 }
	local grip = part(ctx, "Grip", nil, Vector3.new(0.2, 0.2, 0.2) / ctx.Scale, Vector3.zero, nil, WHITE)
	grip.Transparency = 1
	model.PrimaryPart = grip
	local builder = BUILDERS[toolIndex]
	if builder then
		builder(ctx, COLORS[toolIndex] or WHITE)
	end
	return model
end

-- Grip placement relative to an R15 RightHand (R6 Right Arm is handled by the caller's offset).
-- The tool sits just in front of the hand, business end pointing forward.
function ToolModels.HoldOffset(toolIndex: number): CFrame
	local lift = if toolIndex == 5 then -1.6 else -0.9
	return CFrame.new(0, lift, -0.6)
end

return ToolModels
