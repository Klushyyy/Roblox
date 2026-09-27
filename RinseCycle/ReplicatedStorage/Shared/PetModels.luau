-- PetModels: every pet (and egg) is built here from primitive parts, so the game ships with no
-- uploaded meshes. Shared: the client renders pets in the world and in ViewportFrames with it, and
-- the lobby can use the eggs for its displays.
--
-- Conventions (DESIGN.md "PetModels"):
--   * A pet is ~2.5-3.5 studs tall and faces -Z, so Model:GetPivot().LookVector is where it looks.
--   * PrimaryPart "Root" is an invisible 1x1x1 part at the centre (the pivot). Every other part is
--     placed relative to it, so PivotTo moves the whole pet. There are no welds.
--   * Every part is Anchored, Massless, CastShadow = false and CanCollide/CanQuery/CanTouch = false.
--   * Ellipsoids are Block parts with a SpecialMesh (Sphere), which stretches to the part's Size.
--   * The look is "soap commercial": clean SmoothPlastic, big shiny black eyes with a white
--     highlight, blush cheeks, and Neon/Glass accents. Each pet stays at or under ~25 parts.
--   * Models are built at the origin (Root.CFrame = identity), so "model space" = world space while
--     building. Each id is built once into a template; every call returns a fresh Clone.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local PetModels = {}

----------------------------------------------------------------------------------------------------
-- Palette and shared part options
----------------------------------------------------------------------------------------------------

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local EYE_COLOR = Color3.fromRGB(28, 24, 40)
local BLUSH_COLOR = Color3.fromRGB(255, 130, 165)
local MOUTH_COLOR = Color3.fromRGB(95, 35, 55)
local NOSE_COLOR = Color3.fromRGB(45, 35, 45)
local BEAK_COLOR = Color3.fromRGB(255, 165, 60)
local SPONGE_COLOR = Color3.fromRGB(255, 221, 87)
local GEM_COLOR = Color3.fromRGB(255, 70, 120)
local SPARKLE_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local RAINBOW = {
	Color3.fromRGB(255, 95, 95),
	Color3.fromRGB(255, 170, 70),
	Color3.fromRGB(255, 230, 90),
	Color3.fromRGB(110, 230, 130),
	Color3.fromRGB(90, 180, 255),
	Color3.fromRGB(190, 130, 255),
}
-- Used when an id is unknown (or a builder fails): a friendly blue-grey "mystery blob".
local PLACEHOLDER_BODY = Color3.fromRGB(185, 195, 215)
local PLACEHOLDER_ACCENT = Color3.fromRGB(120, 200, 255)
local PLACEHOLDER_KEY = "\0Placeholder" -- can never collide with a real pet id
local SHINY_REFLECTANCE = 0.12 -- extra gloss on the main body parts of Shiny pets

type Opts = {
	Material: Enum.Material?,
	Transparency: number?,
	Reflectance: number?,
	Glossy: boolean?, -- a main body part: picks up SHINY_REFLECTANCE on shiny pets
}

-- Frozen option tables shared by every builder (never mutated).
local GLOSSY: Opts = table.freeze({ Glossy = true })
local NEON: Opts = table.freeze({ Material = Enum.Material.Neon })
local SHINE: Opts = table.freeze({ Material = Enum.Material.Neon, Transparency = 0.3 })
local BUBBLE: Opts = table.freeze({ Material = Enum.Material.Glass, Transparency = 0.3, Reflectance = 0.25 })
local FIN: Opts = table.freeze({ Material = Enum.Material.Glass, Transparency = 0.15, Reflectance = 0.1 })
local EYE: Opts = table.freeze({ Reflectance = 0.15 })
local BLUSH: Opts = table.freeze({ Transparency = 0.2 })
local GOLD: Opts = table.freeze({ Reflectance = 0.3, Glossy = true })

type Ctx = {
	Model: Model,
	Root: Part,
	Shiny: boolean,
	Count: number, -- parts created (Root included); checked against the budget in Studio warnings
}

local PART_BUDGET = 26

local function tint(c: Color3, t: number): Color3
	return c:Lerp(WHITE, t)
end

local function shade(c: Color3, t: number): Color3
	return c:Lerp(BLACK, t)
end

----------------------------------------------------------------------------------------------------
-- Part factory
----------------------------------------------------------------------------------------------------

local function applyStatic(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

local function newCtx(name: string, shiny: boolean): Ctx
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.one
	root.CFrame = CFrame.identity
	root.Transparency = 1
	applyStatic(root)
	root.Parent = model
	model.PrimaryPart = root

	return { Model = model, Root = root, Shiny = shiny, Count = 1 }
end

-- kind: "Ellipsoid" | "Ball" | "Block" | "Cylinder" (axis = local X) | "Wedge"
local function addPart(ctx: Ctx, name: string, kind: string, size: Vector3, cf: CFrame, color: Color3, opts: Opts?): BasePart
	local part: BasePart
	if kind == "Wedge" then
		part = Instance.new("WedgePart")
	else
		local p = Instance.new("Part")
		if kind == "Ball" then
			p.Shape = Enum.PartType.Ball
		elseif kind == "Cylinder" then
			p.Shape = Enum.PartType.Cylinder
		else
			p.Shape = Enum.PartType.Block
		end
		part = p
	end
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = (opts and opts.Material) or Enum.Material.SmoothPlastic
	part.Transparency = (opts and opts.Transparency) or 0
	local reflectance = (opts and opts.Reflectance) or 0
	if ctx.Shiny and opts and opts.Glossy then
		reflectance = math.max(reflectance, SHINY_REFLECTANCE)
	end
	part.Reflectance = reflectance
	applyStatic(part)
	if kind == "Ellipsoid" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere -- stretches to the part's Size: a true ellipsoid
		mesh.Parent = part
	end
	part.Parent = ctx.Model
	ctx.Count += 1
	return part
end

local function ellipsoid(ctx: Ctx, name: string, size: Vector3, cf: CFrame, color: Color3, opts: Opts?): BasePart
	return addPart(ctx, name, "Ellipsoid", size, cf, color, opts)
end

local function ball(ctx: Ctx, name: string, diameter: number, pos: Vector3, color: Color3, opts: Opts?): BasePart
	return addPart(ctx, name, "Ball", Vector3.one * diameter, CFrame.new(pos), color, opts)
end

----------------------------------------------------------------------------------------------------
-- Orientation and surface helpers
----------------------------------------------------------------------------------------------------

-- A CFrame at pos whose LookVector is dir. Flattened features (eyes, cheeks, spots) are thin along
-- their local Z, so this lays them flat on a surface whose outward normal is dir.
local function facing(pos: Vector3, dir: Vector3): CFrame
	local d = dir.Unit
	local up = if math.abs(d.Y) > 0.98 then Vector3.zAxis else Vector3.yAxis
	return CFrame.lookAt(pos, pos + d, up)
end

-- A CFrame at pos whose UpVector is dir (limbs, stalks, crystals).
local function upright(pos: Vector3, dir: Vector3): CFrame
	local y = dir.Unit
	local ref = if math.abs(y.Z) > 0.98 then Vector3.xAxis else Vector3.zAxis
	local x = y:Cross(ref).Unit
	local z = x:Cross(y)
	return CFrame.fromMatrix(pos, x, y, z)
end

-- A rounded limb: an ellipsoid stretched from a to b (slightly past both ends so joints overlap).
local function limb(ctx: Ctx, name: string, a: Vector3, b: Vector3, width: number, color: Color3, opts: Opts?): BasePart
	local length = (b - a).Magnitude
	return ellipsoid(ctx, name, Vector3.new(width, length + width * 0.35, width), upright((a + b) / 2, b - a), color, opts)
end

-- A thin cylinder from a to b (whiskers, eye stalks). Cylinders run along local X, hence the turn.
local function rod(ctx: Ctx, name: string, a: Vector3, b: Vector3, diameter: number, color: Color3, opts: Opts?): BasePart
	local length = (b - a).Magnitude
	local cf = upright((a + b) / 2, b - a) * CFrame.Angles(0, 0, math.pi / 2)
	return addPart(ctx, name, "Cylinder", Vector3.new(length, diameter, diameter), cf, color, opts)
end

-- The front (-Z) surface of an axis-aligned ellipsoid (centre c, full size s) at offset (x, y)
-- from its centre, plus the outward normal there.
local function front(c: Vector3, s: Vector3, x: number, y: number): (Vector3, Vector3)
	local a, b, d = s.X * 0.5, s.Y * 0.5, s.Z * 0.5
	local k = 1 - (x / a) ^ 2 - (y / b) ^ 2
	local z = -d * math.sqrt(math.max(k, 0.01))
	local n = Vector3.new(x / (a * a), y / (b * b), z / (d * d)).Unit
	return c + Vector3.new(x, y, z), n
end

-- The surface of an axis-aligned ellipsoid along `dir` from its centre, plus the outward normal.
local function surface(c: Vector3, s: Vector3, dir: Vector3): (Vector3, Vector3)
	local a, b, d = s.X * 0.5, s.Y * 0.5, s.Z * 0.5
	local u = dir.Unit
	local t = 1 / math.sqrt((u.X / a) ^ 2 + (u.Y / b) ^ 2 + (u.Z / d) ^ 2)
	local p = u * t
	local n = Vector3.new(p.X / (a * a), p.Y / (b * b), p.Z / (d * d)).Unit
	return c + p, n
end

-- A flattened ellipsoid lying on a surface point (p, n), its centre `lift` studs outward
-- (negative = sunk in, so only a soft dome shows).
local function decal(ctx: Ctx, name: string, p: Vector3, n: Vector3, size: Vector3, color: Color3, lift: number, opts: Opts?): BasePart
	return ellipsoid(ctx, name, size, facing(p + n * lift, n), color, opts)
end

----------------------------------------------------------------------------------------------------
-- Faces: eyes (+ highlight), blush cheeks, mouth, all laid on the front of one ellipsoid
----------------------------------------------------------------------------------------------------

type FaceSpec = {
	EyeX: number?, -- eyes at (+-EyeX, EyeY) from the ellipsoid's centre; nil = no eyes
	EyeY: number?,
	Eye: Vector3?, -- eye size (width, height, depth)
	EyeLift: number?, -- extra outward offset (eyes sitting on top of an owl's face discs)
	CheekX: number?,
	CheekY: number?,
	Cheek: Vector3?,
	CheekColor: Color3?,
	MouthY: number?,
	Mouth: Vector3?,
	MouthColor: Color3?,
}

local DEFAULT_EYE = Vector3.new(0.42, 0.54, 0.22)
local DEFAULT_CHEEK = Vector3.new(0.36, 0.21, 0.1)
local DEFAULT_MOUTH = Vector3.new(0.3, 0.17, 0.1)

local function face(ctx: Ctx, c: Vector3, s: Vector3, spec: FaceSpec)
	if spec.EyeX and spec.EyeY then
		local size = spec.Eye or DEFAULT_EYE
		for side = -1, 1, 2 do
			local p, n = front(c, s, side * spec.EyeX, spec.EyeY)
			-- Sink the eye a touch so its rim hides in the curved surface and only a glossy dome shows.
			local cf = facing(p + n * ((spec.EyeLift or 0) - size.Z * 0.15), n)
			ellipsoid(ctx, "Eye", size, cf, EYE_COLOR, EYE)
			-- Highlight up and to the viewer's left (local +X) on both eyes, half-sunk into the eye.
			local shine = cf * CFrame.new(size.X * 0.2, size.Y * 0.2, -size.Z * 0.35)
			addPart(ctx, "EyeShine", "Ball", Vector3.one * (size.X * 0.36), shine, WHITE, NEON)
		end
	end
	if spec.CheekX and spec.CheekY then
		for side = -1, 1, 2 do
			local p, n = front(c, s, side * spec.CheekX, spec.CheekY)
			decal(ctx, "Cheek", p, n, spec.Cheek or DEFAULT_CHEEK, spec.CheekColor or BLUSH_COLOR, -0.02, BLUSH)
		end
	end
	if spec.MouthY then
		local p, n = front(c, s, 0, spec.MouthY)
		decal(ctx, "Mouth", p, n, spec.Mouth or DEFAULT_MOUTH, spec.MouthColor or MOUTH_COLOR, -0.02)
	end
end

--[[
	A pointed ear from one WedgePart. size = (thickness, height, base width).
	A WedgePart's triangle lies in its local YZ plane, so the ear is turned 90 degrees about Y to
	face forward, mirrored per side, then leaned outward by tiltDeg. The inner ear is a smaller
	wedge in the same orientation, scaled about the triangle's centroid height and nudged just in
	front of the ear. Keeping its Z offset at 0 keeps it inside the triangle whichever way the
	slope runs.
]]
local function wedgeEar(ctx: Ctx, side: number, pos: Vector3, size: Vector3, tiltDeg: number, color: Color3, innerColor: Color3?)
	local cf = CFrame.new(pos) * CFrame.Angles(0, 0, -side * math.rad(tiltDeg)) * CFrame.Angles(0, -side * math.pi / 2, 0)
	addPart(ctx, "Ear", "Wedge", size, cf, color, GLOSSY)
	if innerColor then
		local scale = 0.55
		local inner = Vector3.new(size.X * 0.4, size.Y * scale, size.Z * scale)
		-- After the quarter turn, the ear's front face is local -X on the +X side, +X on the -X side.
		local x = -side * (size.X * 0.5 - inner.X * 0.5 + 0.02)
		local y = -size.Y / 6 * (1 - scale) - 0.03
		addPart(ctx, "EarInner", "Wedge", inner, cf * CFrame.new(x, y, 0), innerColor)
	end
end

-- One tentacle hanging from a mantle at angle `a` (radians around Y; 0 = +X, pi/2 = +Z).
-- tiltDeg: how far the tip swings outward (0 = straight down, over 90 = raised up and waving).
-- Returns the tip position.
local function tentacle(ctx: Ctx, a: number, radius: number, y: number, length: number, width: number, tiltDeg: number, color: Color3, curlColor: Color3?, curlSize: number?): Vector3
	local out = Vector3.new(math.cos(a), 0, math.sin(a))
	local t = math.rad(tiltDeg)
	local dir = Vector3.new(0, -math.cos(t), 0) + out * math.sin(t)
	local base = Vector3.new(out.X * radius, y, out.Z * radius)
	local tip = base + dir * length
	limb(ctx, "Tentacle", base, tip, width, color, GLOSSY)
	if curlColor and curlSize then
		-- A little curled-up tip, slightly outward and up so it reads as a curl.
		ball(ctx, "Curl", curlSize, tip + out * (curlSize * 0.25) + Vector3.new(0, curlSize * 0.2, 0), curlColor)
	end
	return tip
end

-- Gold sparkles around shiny pets (and the Sparkle egg). Emitted outward from the Root's surface
-- and slowed by drag, so they twinkle just outside the pet's silhouette.
local function addSparkles(root: BasePart, name: string)
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Texture = SPARKLE_TEXTURE
	e.Color = ColorSequence.new(Color3.fromRGB(255, 240, 150), Color3.fromRGB(255, 190, 40))
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.25, 0.38),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(0.7, 1.3)
	e.Rate = 7
	e.Speed = NumberRange.new(1.8, 3.2)
	e.Drag = 2.5
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-90, 90)
	e.Shape = Enum.ParticleEmitterShape.Sphere
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	e.ZOffset = 1
	e.Parent = root
end

----------------------------------------------------------------------------------------------------
-- Pet builders, keyed by Config.Pets[id].Model. Each gets (ctx, bodyColor, accentColor).
----------------------------------------------------------------------------------------------------

local BUILDERS: { [string]: (Ctx, Color3, Color3) -> () } = {}

-- Rubber Duck / Golden Duck: round bath toy with a two-piece bill, stubby wings and a curl on top.
BUILDERS.Duck = function(ctx, body, accent)
	ellipsoid(ctx, "Body", Vector3.new(2.5, 1.8, 2.9), CFrame.new(0, -0.5, 0.2), body, GLOSSY)
	-- Perky tail: tipped up and back (a negative X turn swings local +Z upward).
	ellipsoid(ctx, "Tail", Vector3.new(0.9, 0.55, 1.1), CFrame.new(0, 0.02, 1.4) * CFrame.Angles(math.rad(-35), 0, 0), body, GLOSSY)

	local headC, headS = Vector3.new(0, 0.7, -0.55), Vector3.new(1.75, 1.75, 1.75)
	ellipsoid(ctx, "Head", headS, CFrame.new(headC), body, GLOSSY)
	ellipsoid(ctx, "Bill", Vector3.new(0.95, 0.32, 0.8), CFrame.new(0, 0.5, -1.42), accent)
	ellipsoid(ctx, "BillLower", Vector3.new(0.72, 0.22, 0.58), CFrame.new(0, 0.36, -1.33), shade(accent, 0.12))
	face(ctx, headC, headS, {
		EyeX = 0.36,
		EyeY = 0.24,
		Eye = Vector3.new(0.36, 0.46, 0.2),
		CheekX = 0.6,
		CheekY = 0,
		Cheek = Vector3.new(0.32, 0.18, 0.1),
	})

	for side = -1, 1, 2 do
		local wing = CFrame.new(side * 1.2, -0.4, 0.3) * CFrame.Angles(0, 0, -side * math.rad(22))
		ellipsoid(ctx, "Wing", Vector3.new(0.32, 0.85, 1.3), wing, shade(body, 0.06), GLOSSY)
	end
	ellipsoid(ctx, "Tuft", Vector3.new(0.22, 0.52, 0.22), CFrame.new(0.06, 1.62, -0.52) * CFrame.Angles(0, 0, math.rad(-18)), body, GLOSSY)
	ellipsoid(ctx, "Tuft", Vector3.new(0.17, 0.38, 0.17), CFrame.new(-0.13, 1.56, -0.46) * CFrame.Angles(0, 0, math.rad(24)), body, GLOSSY)
end

-- Soap Slime: a jelly blob (glass shell over a solid core) with a drip on top and soap bubbles.
BUILDERS.Slime = function(ctx, body, accent)
	local shellC, shellS = Vector3.new(0, -0.15, 0), Vector3.new(2.7, 2.3, 2.6)
	ellipsoid(ctx, "Core", Vector3.new(2.25, 1.9, 2.15), CFrame.new(0, -0.2, 0.05), shade(body, 0.05))
	ellipsoid(ctx, "Body", shellS, CFrame.new(shellC), body, { Material = Enum.Material.Glass, Transparency = 0.35, Reflectance = 0.1 })
	ellipsoid(ctx, "Base", Vector3.new(3.1, 0.6, 3.0), CFrame.new(0, -1.15, 0.05), body, GLOSSY)
	ellipsoid(ctx, "Drip", Vector3.new(0.7, 0.95, 0.7), CFrame.new(0.12, 1.02, 0.1) * CFrame.Angles(0, 0, math.rad(-18)), body, {
		Material = Enum.Material.Glass,
		Transparency = 0.2,
		Reflectance = 0.1,
	})

	ball(ctx, "Bubble", 0.5, Vector3.new(1.45, 0.45, -0.25), accent, BUBBLE)
	ball(ctx, "Bubble", 0.34, Vector3.new(-1.5, 0.85, 0.2), accent, BUBBLE)
	ball(ctx, "Bubble", 0.28, Vector3.new(1.15, 1.2, 0.35), accent, BUBBLE)

	-- Soft window-light streak on the shell, above the viewer-left eye.
	local p, n = front(shellC, shellS, 0.75, 0.62)
	ellipsoid(ctx, "Shine", Vector3.new(0.3, 0.55, 0.08), facing(p + n * 0.02, n) * CFrame.Angles(0, 0, math.rad(-30)), WHITE, SHINE)

	face(ctx, shellC, shellS, {
		EyeX = 0.46,
		EyeY = 0.05,
		Eye = Vector3.new(0.44, 0.58, 0.22),
		CheekX = 0.86,
		CheekY = -0.28,
		MouthY = -0.3,
		Mouth = Vector3.new(0.34, 0.2, 0.1),
	})
end

-- Sponge Pup: the body is a kitchen sponge (yellow block with a green scrubber layer and pores),
-- with a round puppy head, floppy scrubber-green ears and a little tongue.
BUILDERS.Pup = function(ctx, body, accent)
	addPart(ctx, "Body", "Block", Vector3.new(2.0, 1.3, 2.5), CFrame.new(0, -0.55, 0.35), body, GLOSSY)
	addPart(ctx, "Scrubber", "Block", Vector3.new(2.06, 0.34, 2.56), CFrame.new(0, 0.26, 0.35), accent)
	local pore = shade(body, 0.2)
	for side = -1, 1, 2 do
		ellipsoid(ctx, "Pore", Vector3.new(0.1, 0.3, 0.36), CFrame.new(side * 1.0, -0.4, 0.15), pore)
		ellipsoid(ctx, "Pore", Vector3.new(0.1, 0.22, 0.26), CFrame.new(side * 1.0, -0.85, 0.95), pore)
	end

	local headC, headS = Vector3.new(0, 0.6, -0.85), Vector3.new(1.85, 1.7, 1.7)
	ellipsoid(ctx, "Head", headS, CFrame.new(headC), body, GLOSSY)
	ellipsoid(ctx, "Snout", Vector3.new(0.95, 0.62, 0.62), CFrame.new(0, 0.28, -1.66), tint(body, 0.5))
	ellipsoid(ctx, "Nose", Vector3.new(0.34, 0.24, 0.2), CFrame.new(0, 0.46, -1.93), NOSE_COLOR, EYE)
	ellipsoid(ctx, "Tongue", Vector3.new(0.26, 0.1, 0.34), CFrame.new(0, -0.05, -1.82) * CFrame.Angles(math.rad(-25), 0, 0), Color3.fromRGB(255, 120, 140))
	face(ctx, headC, headS, {
		EyeX = 0.38,
		EyeY = 0.22,
		Eye = Vector3.new(0.4, 0.52, 0.22),
		CheekX = 0.66,
		CheekY = -0.12,
	})

	for side = -1, 1, 2 do
		-- Floppy ears: the tops lean in, so the bottoms swing out.
		ellipsoid(ctx, "Ear", Vector3.new(0.4, 1.0, 0.62), CFrame.new(side * 0.98, 0.45, -0.8) * CFrame.Angles(0, 0, side * math.rad(22)), accent)
		for _, z in { -0.4, 1.1 } do
			ellipsoid(ctx, "Leg", Vector3.new(0.6, 0.55, 0.62), CFrame.new(side * 0.62, -1.3, z), shade(body, 0.08), GLOSSY)
		end
	end
	ellipsoid(ctx, "Tail", Vector3.new(0.28, 0.7, 0.28), CFrame.new(0, 0.55, 1.62) * CFrame.Angles(math.rad(35), 0, 0), accent)
end

-- Bubble Fish: a round puffy fish with a white band, a V tail, fins, and bubbles from its "o" mouth.
BUILDERS.Fish = function(ctx, body, accent)
	local bodyC, bodyS = Vector3.new(0, 0.05, 0), Vector3.new(1.8, 2.3, 2.8)
	ellipsoid(ctx, "Body", bodyS, CFrame.new(bodyC), body, GLOSSY)
	ellipsoid(ctx, "Belly", Vector3.new(1.62, 1.35, 2.1), CFrame.new(0, -0.45, -0.15), tint(body, 0.55))
	-- Band: the body's cross-section at dz, blown up 8% so a stripe stands proud of the body.
	local dz = 0.45
	local f = math.sqrt(1 - (dz / (bodyS.Z * 0.5)) ^ 2) * 1.08
	ellipsoid(ctx, "Stripe", Vector3.new(bodyS.X * f, bodyS.Y * f, 0.5), CFrame.new(bodyC + Vector3.new(0, 0, dz)), accent)

	local finColor = accent:Lerp(body, 0.3)
	ellipsoid(ctx, "Tail", Vector3.new(0.18, 1.15, 0.95), CFrame.new(0, 0.5, 1.6) * CFrame.Angles(math.rad(40), 0, 0), finColor, FIN)
	ellipsoid(ctx, "Tail", Vector3.new(0.18, 1.15, 0.95), CFrame.new(0, -0.4, 1.6) * CFrame.Angles(math.rad(-40), 0, 0), finColor, FIN)
	ellipsoid(ctx, "Fin", Vector3.new(0.16, 0.8, 1.2), CFrame.new(0, 1.12, 0.25) * CFrame.Angles(math.rad(25), 0, 0), finColor, FIN)
	for side = -1, 1, 2 do
		local cf = CFrame.new(side * 0.92, -0.3, 0.2) * CFrame.Angles(0, 0, -side * math.rad(40)) * CFrame.Angles(math.rad(20), 0, 0)
		ellipsoid(ctx, "SideFin", Vector3.new(0.12, 0.5, 0.8), cf, finColor, FIN)
	end

	face(ctx, bodyC, bodyS, {
		EyeX = 0.42,
		EyeY = 0.35,
		Eye = Vector3.new(0.42, 0.54, 0.22),
		CheekX = 0.6,
		CheekY = -0.08,
		MouthY = -0.32,
		Mouth = Vector3.new(0.3, 0.26, 0.12),
		MouthColor = Color3.fromRGB(235, 95, 130),
	})
	ball(ctx, "Bubble", 0.4, Vector3.new(-0.95, 0.75, -1.25), accent, BUBBLE)
	ball(ctx, "Bubble", 0.28, Vector3.new(-1.15, 1.25, -1.1), accent, BUBBLE)
end

-- Scrub Bunny: chubby bunny with one floppier ear, pink inner ears, buck teeth and a pom tail.
BUILDERS.Bunny = function(ctx, body, accent)
	ellipsoid(ctx, "Body", Vector3.new(2.0, 1.5, 2.0), CFrame.new(0, -0.85, 0.2), body, GLOSSY)
	local headC, headS = Vector3.new(0, 0.3, -0.25), Vector3.new(1.95, 1.65, 1.7)
	ellipsoid(ctx, "Head", headS, CFrame.new(headC), body, GLOSSY)

	for side = -1, 1, 2 do
		local tilt = if side == 1 then 10 else 26 -- one ear flops a little more
		local ear = CFrame.new(side * 0.42, 1.3, -0.2) * CFrame.Angles(0, 0, -side * math.rad(tilt))
		ellipsoid(ctx, "Ear", Vector3.new(0.46, 1.25, 0.3), ear, body, GLOSSY)
		ellipsoid(ctx, "EarInner", Vector3.new(0.26, 0.9, 0.1), ear * CFrame.new(0, -0.02, -0.12), accent)
		ellipsoid(ctx, "Foot", Vector3.new(0.55, 0.32, 0.8), CFrame.new(side * 0.5, -1.5, -0.5), body, GLOSSY)
		ellipsoid(ctx, "Paw", Vector3.new(0.38, 0.34, 0.4), CFrame.new(side * 0.42, -0.72, -0.72), body, GLOSSY)
	end
	ball(ctx, "Tail", 0.7, Vector3.new(0, -0.95, 1.2), tint(body, 0.4))

	local np, nn = front(headC, headS, 0, -0.05)
	decal(ctx, "Nose", np, nn, Vector3.new(0.22, 0.15, 0.14), accent, 0)
	local tp, tn = front(headC, headS, 0, -0.3)
	addPart(ctx, "Teeth", "Block", Vector3.new(0.22, 0.2, 0.06), facing(tp, tn), WHITE)
	face(ctx, headC, headS, {
		EyeX = 0.4,
		EyeY = 0.15,
		Eye = Vector3.new(0.4, 0.5, 0.22),
		CheekX = 0.66,
		CheekY = -0.18,
	})
end

type SudsSpec = { Dir: Vector3, D: number }
local CRAB_SUDS: { SudsSpec } = {
	{ Dir = Vector3.new(0.3, 1, 0.3), D = 0.62 },
	{ Dir = Vector3.new(-0.35, 1, 0.45), D = 0.5 },
	{ Dir = Vector3.new(0.05, 1, 0.85), D = 0.44 },
}

-- Suds Crab: wide shell topped with soap suds, eyes on stalks, big raised claws, little legs.
BUILDERS.Crab = function(ctx, body, accent)
	local bodyC, bodyS = Vector3.new(0, -0.35, 0.05), Vector3.new(2.9, 1.5, 2.1)
	ellipsoid(ctx, "Body", bodyS, CFrame.new(bodyC), body, GLOSSY)
	local limbColor = shade(body, 0.08)

	for side = -1, 1, 2 do
		rod(ctx, "Stalk", Vector3.new(side * 0.45, 0.1, -0.45), Vector3.new(side * 0.5, 0.85, -0.55), 0.18, body)
		local eyePos = Vector3.new(side * 0.5, 1.0, -0.58)
		ball(ctx, "Eye", 0.62, eyePos, EYE_COLOR, EYE)
		ball(ctx, "EyeShine", 0.2, eyePos + Vector3.new(0.12, 0.13, -0.23), WHITE, NEON)

		limb(ctx, "Arm", Vector3.new(side * 1.25, -0.3, -0.35), Vector3.new(side * 1.75, 0, -0.8), 0.32, limbColor)
		local clawPos = Vector3.new(side * 1.85, 0.2, -0.9)
		ellipsoid(ctx, "Claw", Vector3.new(0.85, 0.72, 0.72), CFrame.new(clawPos) * CFrame.Angles(0, 0, side * math.rad(-15)), body, GLOSSY)
		local thumb = CFrame.new(clawPos + Vector3.new(-side * 0.22, 0.42, -0.05)) * CFrame.Angles(0, 0, side * math.rad(25))
		ellipsoid(ctx, "Pincer", Vector3.new(0.28, 0.5, 0.42), thumb, body, GLOSSY)

		for _, z in { 0.1, 0.65 } do
			limb(ctx, "Leg", Vector3.new(side * 1.15, -0.65, z), Vector3.new(side * 1.65, -1.3, z + 0.1), 0.2, limbColor)
		end
	end

	face(ctx, bodyC, bodyS, {
		CheekX = 0.75,
		CheekY = -0.05,
		CheekColor = Color3.fromRGB(255, 190, 205),
		MouthY = -0.2,
		Mouth = Vector3.new(0.34, 0.16, 0.1),
	})
	for _, s in CRAB_SUDS do
		local p, n = surface(bodyC, bodyS, s.Dir)
		ball(ctx, "Suds", s.D, p + n * (s.D * 0.12), accent)
	end
end

-- Mop Cat: pointed wedge ears, white muzzle and whiskers, white paws, and a tail ending in a mop.
BUILDERS.Cat = function(ctx, body, accent)
	ellipsoid(ctx, "Body", Vector3.new(1.9, 1.5, 2.3), CFrame.new(0, -0.8, 0.35), body, GLOSSY)
	local headC, headS = Vector3.new(0, 0.35, -0.4), Vector3.new(2.1, 1.75, 1.75)
	ellipsoid(ctx, "Head", headS, CFrame.new(headC), body, GLOSSY)

	local mp, mn = front(headC, headS, 0, -0.3)
	decal(ctx, "Muzzle", mp, mn, Vector3.new(0.95, 0.55, 0.4), accent, -0.06)
	local np, nn = front(headC, headS, 0, -0.08)
	decal(ctx, "Nose", np, nn, Vector3.new(0.22, 0.14, 0.12), Color3.fromRGB(255, 140, 170), 0.1)

	local whisker = shade(body, 0.45)
	for side = -1, 1, 2 do
		wedgeEar(ctx, side, Vector3.new(side * 0.56, 1.28, -0.35), Vector3.new(0.24, 0.72, 0.62), 12, body, Color3.fromRGB(255, 175, 195))
		for _, dy in { 0.07, -0.08 } do
			local a = mp + mn * 0.1 + Vector3.new(side * 0.36, dy, 0)
			rod(ctx, "Whisker", a, a + Vector3.new(side * 0.55, dy * 1.6, 0.08), 0.035, whisker)
		end
		ellipsoid(ctx, "Paw", Vector3.new(0.5, 0.32, 0.6), CFrame.new(side * 0.45, -1.5, -0.45), accent)
	end

	local tailTip = Vector3.new(0.6, 0.05, 1.85)
	limb(ctx, "Tail", Vector3.new(0.3, -0.95, 1.4), tailTip, 0.34, body, GLOSSY)
	ball(ctx, "Mop", 0.78, tailTip + Vector3.new(0.05, 0.2, 0.05), accent)
	ball(ctx, "Mop", 0.55, tailTip + Vector3.new(0.3, 0.02, 0.2), accent)

	face(ctx, headC, headS, {
		EyeX = 0.42,
		EyeY = 0.12,
		Eye = Vector3.new(0.42, 0.56, 0.22),
		CheekX = 0.72,
		CheekY = -0.2,
	})
end

local OCTO_SPOTS = { Vector3.new(0.55, 0.8, 0.3), Vector3.new(-0.6, 0.6, 0.45), Vector3.new(0.1, 0.95, 0.55) }

-- Octo-Scrubber: round mantle with spots, five curly tentacles and one raised, waving a sponge.
BUILDERS.Octopus = function(ctx, body, accent)
	local mantleC, mantleS = Vector3.new(0, 0.35, 0.05), Vector3.new(2.4, 2.3, 2.3)
	ellipsoid(ctx, "Body", mantleS, CFrame.new(mantleC), body, GLOSSY)
	for i = 0, 5 do
		local a = math.rad(30 + i * 60)
		if i == 5 then
			-- 330 degrees = front, +X side: raised high (tilt > 90) holding up a sponge.
			local tip = tentacle(ctx, a, 0.85, -0.3, 1.05, 0.46, 125, body)
			local sponge = CFrame.new(tip + Vector3.new(0.05, 0.2, 0)) * CFrame.Angles(0, -a, math.rad(20))
			addPart(ctx, "Sponge", "Block", Vector3.new(0.62, 0.4, 0.46), sponge, SPONGE_COLOR)
		else
			tentacle(ctx, a, 0.72, -0.45, 0.95, 0.46, 28, body, accent, 0.42)
		end
	end
	for _, dir in OCTO_SPOTS do
		local p, n = surface(mantleC, mantleS, dir)
		decal(ctx, "Spot", p, n, Vector3.new(0.45, 0.45, 0.1), accent, -0.02)
	end
	face(ctx, mantleC, mantleS, {
		EyeX = 0.45,
		EyeY = -0.05,
		Eye = Vector3.new(0.5, 0.62, 0.24),
		CheekX = 0.82,
		CheekY = -0.38,
		MouthY = -0.42,
		Mouth = Vector3.new(0.34, 0.2, 0.1),
	})
end

-- Rainbow Jelly: glass bell around a glowing core, a rainbow frill and four wavy glowing ribbons.
BUILDERS.Jelly = function(ctx, body, accent)
	local bellC, bellS = Vector3.new(0, 0.5, 0), Vector3.new(2.8, 1.9, 2.8)
	ellipsoid(ctx, "Core", Vector3.new(1.7, 1.15, 1.7), CFrame.new(0, 0.55, 0.1), accent, { Material = Enum.Material.Neon, Transparency = 0.25 })
	ellipsoid(ctx, "Body", bellS, CFrame.new(bellC), body, { Material = Enum.Material.Glass, Transparency = 0.3, Reflectance = 0.15, Glossy = true })

	-- Frill: rainbow beads on the bell at ringY, offset 30 degrees so none sits under the mouth.
	local ringY = 0.05
	local ringR = bellS.X * 0.5 * math.sqrt(1 - ((ringY - bellC.Y) / (bellS.Y * 0.5)) ^ 2)
	for i, color in RAINBOW do
		local a = math.rad(-60 + (i - 1) * 60)
		ball(ctx, "Frill", 0.5, Vector3.new(math.cos(a) * ringR, ringY, math.sin(a) * ringR), color, NEON)
	end

	local ribbon: Opts = { Material = Enum.Material.Neon, Transparency = 0.15 }
	for i = 0, 3 do
		local a = math.rad(45 + i * 90)
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		local across = Vector3.new(-out.Z, 0, out.X) -- tangent to the ring, for the wiggle
		local top = out * 0.55 + Vector3.new(0, -0.2, 0)
		local mid = out * 0.6 + across * 0.22 + Vector3.new(0, -0.85, 0)
		local bottom = out * 0.55 - across * 0.05 + Vector3.new(0, -1.45, 0)
		local color = if i % 2 == 0 then accent else tint(body, 0.25)
		limb(ctx, "Tentacle", top, mid, 0.2, color, ribbon)
		limb(ctx, "Tentacle", mid, bottom, 0.18, color, ribbon)
	end

	local sp, sn = front(bellC, bellS, 0.85, 0.55)
	ellipsoid(ctx, "Shine", Vector3.new(0.3, 0.52, 0.08), facing(sp + sn * 0.01, sn) * CFrame.Angles(0, 0, math.rad(-25)), WHITE, SHINE)
	face(ctx, bellC, bellS, {
		EyeX = 0.45,
		EyeY = 0.18,
		Eye = Vector3.new(0.46, 0.58, 0.22),
		CheekX = 0.85,
		CheekY = -0.15,
		CheekColor = Color3.fromRGB(255, 80, 140),
		MouthY = -0.2,
		Mouth = Vector3.new(0.32, 0.18, 0.1),
	})
end

-- Foam Fox: white chest and muzzle, pointed ears, dark paws, and a huge tail tipped with foam.
BUILDERS.Fox = function(ctx, body, accent)
	ellipsoid(ctx, "Body", Vector3.new(1.8, 1.45, 2.3), CFrame.new(0, -0.8, 0.4), body, GLOSSY)
	ellipsoid(ctx, "Chest", Vector3.new(1.1, 1.0, 0.8), CFrame.new(0, -0.72, -0.55), accent)
	local headC, headS = Vector3.new(0, 0.35, -0.45), Vector3.new(2.0, 1.65, 1.7)
	ellipsoid(ctx, "Head", headS, CFrame.new(headC), body, GLOSSY)
	ellipsoid(ctx, "Muzzle", Vector3.new(1.25, 0.75, 0.9), CFrame.new(0, -0.05, -1.05), accent)
	ellipsoid(ctx, "Nose", Vector3.new(0.3, 0.22, 0.2), CFrame.new(0, 0.12, -1.47), NOSE_COLOR, EYE)

	for side = -1, 1, 2 do
		wedgeEar(ctx, side, Vector3.new(side * 0.55, 1.35, -0.35), Vector3.new(0.24, 0.9, 0.68), 16, body, accent)
		ellipsoid(ctx, "Paw", Vector3.new(0.45, 0.32, 0.55), CFrame.new(side * 0.42, -1.5, -0.35), shade(body, 0.35))
	end

	local tailTip = Vector3.new(0.5, 0.05, 2.05)
	limb(ctx, "Tail", Vector3.new(0.15, -0.95, 1.35), tailTip, 0.85, body, GLOSSY)
	ball(ctx, "Foam", 0.72, tailTip + Vector3.new(0.05, 0.12, 0.1), accent)
	ball(ctx, "Foam", 0.5, tailTip + Vector3.new(0.32, 0.3, 0.05), accent)
	ball(ctx, "Foam", 0.4, tailTip + Vector3.new(-0.2, 0.4, 0.2), accent)

	face(ctx, headC, headS, {
		EyeX = 0.4,
		EyeY = 0.2,
		Eye = Vector3.new(0.4, 0.52, 0.22),
		CheekX = 0.72,
		CheekY = -0.08,
	})
end

local OWL_CHEVRONS = { { X = -0.25, Y = -0.45 }, { X = 0.25, Y = -0.45 }, { X = 0, Y = -0.8 } }

-- Steam Owl: egg-shaped owl with pale face discs, huge eyes, ear tufts, and puffs of steam.
BUILDERS.Owl = function(ctx, body, accent)
	local bodyC, bodyS = Vector3.new(0, -0.25, 0.05), Vector3.new(2.3, 2.5, 2.2)
	local feather = shade(body, 0.12)
	ellipsoid(ctx, "Body", bodyS, CFrame.new(bodyC), body, GLOSSY)

	local bp, bn = front(bodyC, bodyS, 0, -0.55)
	decal(ctx, "Belly", bp, bn, Vector3.new(1.45, 1.45, 0.5), tint(accent, 0.35), -0.14)
	for _, c in OWL_CHEVRONS do
		local p, n = front(bodyC, bodyS, c.X, c.Y)
		decal(ctx, "Chevron", p, n, Vector3.new(0.26, 0.12, 0.08), shade(accent, 0.25), 0.09)
	end

	for side = -1, 1, 2 do
		local p, n = front(bodyC, bodyS, side * 0.44, 0.3)
		decal(ctx, "FaceDisc", p, n, Vector3.new(0.95, 0.95, 0.3), accent, -0.06)
		ellipsoid(ctx, "Tuft", Vector3.new(0.34, 0.7, 0.3), CFrame.new(side * 0.7, 0.98, -0.1) * CFrame.Angles(0, 0, -side * math.rad(28)), feather, GLOSSY)
		ellipsoid(ctx, "Wing", Vector3.new(0.38, 1.5, 1.2), CFrame.new(side * 1.12, -0.35, 0.15) * CFrame.Angles(0, 0, side * math.rad(8)), feather, GLOSSY)
		ellipsoid(ctx, "Foot", Vector3.new(0.5, 0.25, 0.45), CFrame.new(side * 0.42, -1.5, -0.55), BEAK_COLOR)
	end
	face(ctx, bodyC, bodyS, {
		EyeX = 0.44,
		EyeY = 0.3,
		Eye = Vector3.new(0.5, 0.56, 0.24),
		EyeLift = 0.1, -- sit on the face discs, not the body
		CheekX = 0.78,
		CheekY = -0.32,
	})
	local kp, kn = front(bodyC, bodyS, 0, 0.02)
	ellipsoid(ctx, "Beak", Vector3.new(0.3, 0.45, 0.32), facing(kp + kn * 0.08, kn) * CFrame.Angles(math.rad(-15), 0, 0), BEAK_COLOR)

	ball(ctx, "Steam", 0.5, Vector3.new(0.45, 1.3, 0.3), WHITE, { Transparency = 0.3 })
	ball(ctx, "Steam", 0.34, Vector3.new(0.72, 1.66, 0.4), WHITE, { Transparency = 0.45 })
end

type CrystalSpec = { Dir: Vector3, Size: Vector3, Spin: number }
local TURTLE_CRYSTALS: { CrystalSpec } = {
	{ Dir = Vector3.new(0, 1, 0.1), Size = Vector3.new(0.42, 0.95, 0.42), Spin = 45 },
	{ Dir = Vector3.new(0.55, 0.8, 0.35), Size = Vector3.new(0.34, 0.7, 0.34), Spin = 20 },
	{ Dir = Vector3.new(-0.55, 0.8, 0.1), Size = Vector3.new(0.34, 0.75, 0.34), Spin = 65 },
	{ Dir = Vector3.new(-0.1, 0.75, 0.75), Size = Vector3.new(0.28, 0.55, 0.28), Spin = 30 },
}

-- Crystal Turtle: a glassy shell (glass over a solid core) with glowing crystals growing from it.
BUILDERS.Turtle = function(ctx, body, accent)
	local shellC, shellS = Vector3.new(0, 0.2, 0.25), Vector3.new(2.7, 1.7, 2.9)
	ellipsoid(ctx, "ShellCore", shellS - Vector3.new(0.3, 0.26, 0.3), CFrame.new(shellC), shade(body, 0.12))
	ellipsoid(ctx, "Shell", shellS, CFrame.new(shellC), accent:Lerp(body, 0.45), {
		Material = Enum.Material.Glass,
		Transparency = 0.2,
		Reflectance = 0.2,
		Glossy = true,
	})
	ellipsoid(ctx, "Rim", Vector3.new(3.0, 0.32, 3.2), CFrame.new(0, -0.35, 0.25), shade(body, 0.2), GLOSSY)

	local crystalColor = accent:Lerp(body, 0.25)
	for _, c in TURTLE_CRYSTALS do
		local p, n = surface(shellC, shellS, c.Dir)
		-- Grow mostly upward (not straight out of the curve), spun for variety, 80% above the shell.
		local cf = upright(p, n:Lerp(Vector3.yAxis, 0.4)) * CFrame.Angles(0, math.rad(c.Spin), 0) * CFrame.new(0, c.Size.Y * 0.3, 0)
		addPart(ctx, "Crystal", "Block", c.Size, cf, crystalColor, NEON)
	end

	local headC, headS = Vector3.new(0, -0.05, -1.45), Vector3.new(1.25, 1.15, 1.3)
	ellipsoid(ctx, "Head", headS, CFrame.new(headC), body, GLOSSY)
	face(ctx, headC, headS, {
		EyeX = 0.27,
		EyeY = 0.12,
		Eye = Vector3.new(0.3, 0.4, 0.18),
		CheekX = 0.43,
		CheekY = -0.14,
		Cheek = Vector3.new(0.24, 0.15, 0.08),
		MouthY = -0.22,
		Mouth = Vector3.new(0.22, 0.1, 0.08),
	})
	for side = -1, 1, 2 do
		for _, z in { -0.6, 1.1 } do
			ellipsoid(ctx, "Leg", Vector3.new(0.75, 0.5, 0.75), CFrame.new(side * 1.05, -0.75, z), tint(body, 0.08), GLOSSY)
		end
	end
	ellipsoid(ctx, "Tail", Vector3.new(0.3, 0.25, 0.55), CFrame.new(0, -0.45, 1.8), body)
end

-- Tidal Dragon: chibi dragon with horns, translucent fin-wings, back spikes and a finned tail.
BUILDERS.Dragon = function(ctx, body, accent)
	ellipsoid(ctx, "Body", Vector3.new(1.8, 1.6, 2.2), CFrame.new(0, -0.75, 0.35), body, GLOSSY)
	ellipsoid(ctx, "Belly", Vector3.new(1.2, 1.15, 0.55), CFrame.new(0, -0.85, -0.6), accent)
	local headC, headS = Vector3.new(0, 0.4, -0.45), Vector3.new(1.85, 1.6, 1.7)
	ellipsoid(ctx, "Head", headS, CFrame.new(headC), body, GLOSSY)
	ellipsoid(ctx, "Snout", Vector3.new(1.05, 0.65, 0.78), CFrame.new(0, 0.12, -1.27), tint(body, 0.12), GLOSSY)

	for side = -1, 1, 2 do
		-- Horns lean back (X turn) and slightly outward (Z turn).
		local horn = CFrame.new(side * 0.42, 1.25, -0.15) * CFrame.Angles(0, 0, -side * math.rad(15)) * CFrame.Angles(math.rad(30), 0, 0)
		ellipsoid(ctx, "Horn", Vector3.new(0.22, 0.62, 0.22), horn, accent, GLOSSY)
		-- Two-lobed wing: the inner lobe touches the body, the outer one continues from its top.
		local inner = CFrame.new(side * 0.85, 0.15, 0.85) * CFrame.Angles(0, 0, -side * math.rad(40)) * CFrame.Angles(math.rad(-15), 0, 0)
		ellipsoid(ctx, "Wing", Vector3.new(0.12, 0.95, 1.25), inner, accent, FIN)
		local outer = CFrame.new(side * 1.4, 0.6, 1.0) * CFrame.Angles(0, 0, -side * math.rad(55)) * CFrame.Angles(math.rad(-15), 0, 0)
		ellipsoid(ctx, "Wing", Vector3.new(0.1, 0.7, 0.9), outer, accent, FIN)
		ellipsoid(ctx, "Foot", Vector3.new(0.5, 0.35, 0.6), CFrame.new(side * 0.5, -1.5, -0.3), shade(body, 0.1), GLOSSY)
	end

	local t1, t2, t3 = Vector3.new(0, -1.15, 1.3), Vector3.new(0.2, -0.95, 2.0), Vector3.new(0.35, -0.5, 2.45)
	limb(ctx, "Tail", t1, t2, 0.55, body, GLOSSY)
	limb(ctx, "Tail", t2, t3, 0.4, body, GLOSSY)
	ellipsoid(ctx, "TailFin", Vector3.new(0.12, 0.62, 0.55), CFrame.new(t3 + Vector3.new(0.02, 0.28, 0.12)) * CFrame.Angles(math.rad(20), 0, 0), accent, FIN)
	ellipsoid(ctx, "Spike", Vector3.new(0.12, 0.38, 0.4), CFrame.new(0, 0.1, 0.55) * CFrame.Angles(math.rad(25), 0, 0), accent, GLOSSY)
	ellipsoid(ctx, "Spike", Vector3.new(0.12, 0.34, 0.36), CFrame.new(0, -0.06, 1.0) * CFrame.Angles(math.rad(25), 0, 0), accent, GLOSSY)

	face(ctx, headC, headS, {
		EyeX = 0.38,
		EyeY = 0.25,
		Eye = Vector3.new(0.4, 0.52, 0.22),
		CheekX = 0.68,
		CheekY = -0.06,
	})
end

-- Kraken King: a big octopus with six curled tentacles and a tilted gold crown with a gem.
BUILDERS.Kraken = function(ctx, body, accent)
	local mantleC, mantleS = Vector3.new(0, 0.2, 0.05), Vector3.new(2.5, 2.2, 2.4)
	ellipsoid(ctx, "Body", mantleS, CFrame.new(mantleC), body, GLOSSY)
	local curl = tint(body, 0.35)
	for i = 0, 5 do
		tentacle(ctx, math.rad(30 + i * 60), 0.78, -0.55, 1.05, 0.55, 32, body, curl, 0.48)
	end

	local crown = CFrame.new(0.12, 1.3, 0.1) * CFrame.Angles(0, 0, math.rad(-10))
	addPart(ctx, "Crown", "Cylinder", Vector3.new(0.4, 1.25, 1.25), crown * CFrame.Angles(0, 0, math.pi / 2), accent, GOLD)
	for _, deg in { 210, 330, 90 } do
		local r = math.rad(deg)
		ellipsoid(ctx, "CrownPoint", Vector3.new(0.24, 0.5, 0.24), crown * CFrame.new(math.cos(r) * 0.5, 0.35, math.sin(r) * 0.5), accent, GOLD)
	end
	ball(ctx, "Gem", 0.3, (crown * CFrame.new(0, 0, -0.63)).Position, GEM_COLOR, NEON)

	face(ctx, mantleC, mantleS, {
		EyeX = 0.46,
		EyeY = -0.02,
		Eye = Vector3.new(0.52, 0.64, 0.24),
		CheekX = 0.88,
		CheekY = -0.36,
	})
end

-- Unknown ids (or a failed builder): a friendly blob with an antenna, never an error.
local function buildPlaceholder(ctx: Ctx, body: Color3, accent: Color3)
	local c, s = Vector3.new(0, -0.1, 0), Vector3.new(2.4, 2.2, 2.3)
	ellipsoid(ctx, "Body", s, CFrame.new(c), body, GLOSSY)
	ellipsoid(ctx, "Base", Vector3.new(2.7, 0.5, 2.6), CFrame.new(0, -1.05, 0), shade(body, 0.08))
	rod(ctx, "Antenna", Vector3.new(0, 0.9, 0.1), Vector3.new(0.15, 1.45, 0.15), 0.08, shade(body, 0.2))
	ball(ctx, "AntennaTip", 0.36, Vector3.new(0.16, 1.5, 0.15), accent, NEON)
	face(ctx, c, s, {
		EyeX = 0.44,
		EyeY = 0.1,
		Eye = Vector3.new(0.44, 0.56, 0.22),
		CheekX = 0.82,
		CheekY = -0.2,
		MouthY = -0.3,
	})
end

----------------------------------------------------------------------------------------------------
-- Eggs. The shell is the union of a wide lower ellipsoid and a narrower, taller upper one, which
-- reads as a real egg (fat bottom, pointier top). Patterns follow the egg id:
--   Bubble  -> a pale band and bubble dots        Suds -> a zigzag ribbon of diamonds and dots
--   Sparkle -> a glowing gold band, star glints and gold sparkles       unknown -> plain grey egg
----------------------------------------------------------------------------------------------------

local EGG_LOWER_C, EGG_LOWER_S = Vector3.new(0, -0.25, 0), Vector3.new(2.3, 2.5, 2.3)
local EGG_UPPER_C, EGG_UPPER_S = Vector3.new(0, 0.05, 0), Vector3.new(1.95, 2.9, 1.95)
local EGG_PLAIN = Color3.fromRGB(200, 205, 215)

-- Where a ray from inside an ellipsoid leaves it: (distance, outward normal).
local function exitRay(origin: Vector3, dir: Vector3, c: Vector3, s: Vector3): (number, Vector3)
	local h = s * 0.5
	local u = dir.Unit
	local p = (origin - c) / h
	local d = u / h
	local A = d:Dot(d)
	local B = 2 * p:Dot(d)
	local C = p:Dot(p) - 1
	local t = (-B + math.sqrt(math.max(B * B - 4 * A * C, 0))) / (2 * A)
	local q = origin + u * t - c
	return t, Vector3.new(q.X / (h.X * h.X), q.Y / (h.Y * h.Y), q.Z / (h.Z * h.Z)).Unit
end

-- The egg's outer surface along dir from its centre: the farther of the two shells wins.
local function eggSurface(dir: Vector3): (Vector3, Vector3)
	local t1, n1 = exitRay(Vector3.zero, dir, EGG_LOWER_C, EGG_LOWER_S)
	local t2, n2 = exitRay(Vector3.zero, dir, EGG_UPPER_C, EGG_UPPER_S)
	if t1 >= t2 then
		return dir.Unit * t1, n1
	end
	return dir.Unit * t2, n2
end

-- Radius of the lower shell at height y (the bands sit where it is the outer, near-vertical shell).
local function eggRadiusAt(y: number): number
	local h = EGG_LOWER_S * 0.5
	local dy = (y - EGG_LOWER_C.Y) / h.Y
	return h.X * math.sqrt(math.max(1 - dy * dy, 0))
end

local function eggBand(ctx: Ctx, y: number, height: number, color: Color3, opts: Opts?)
	local d = eggRadiusAt(y) * 2 + 0.06
	addPart(ctx, "Band", "Cylinder", Vector3.new(height, d, d), CFrame.new(0, y, 0) * CFrame.Angles(0, 0, math.pi / 2), color, opts)
end

type DotSpec = { Dir: Vector3, D: number }
-- Kept clear of the band (y near -0.1) and of the shine (upper front, +X).
local EGG_DOTS: { DotSpec } = {
	{ Dir = Vector3.new(-0.6, 0.5, -0.65), D = 0.46 },
	{ Dir = Vector3.new(0.15, 0.8, -0.55), D = 0.32 },
	{ Dir = Vector3.new(-0.2, -0.45, -0.85), D = 0.4 },
	{ Dir = Vector3.new(0.75, -0.5, -0.4), D = 0.34 },
	{ Dir = Vector3.new(-0.9, 0.3, 0.3), D = 0.42 },
	{ Dir = Vector3.new(0.85, 0.3, 0.45), D = 0.38 },
	{ Dir = Vector3.new(0.1, 0.4, 0.9), D = 0.44 },
	{ Dir = Vector3.new(-0.4, -0.6, 0.7), D = 0.34 },
}

local function eggDot(ctx: Ctx, name: string, dir: Vector3, size: Vector3, color: Color3, opts: Opts?, spinDeg: number?)
	local p, n = eggSurface(dir)
	local cf = facing(p + n * (-size.Z * 0.15), n) * CFrame.Angles(0, 0, math.rad(spinDeg or 0))
	if name == "Diamond" or name == "Glint" then
		addPart(ctx, name, "Block", size, cf, color, opts)
	else
		ellipsoid(ctx, name, size, cf, color, opts)
	end
end

local function buildEgg(ctx: Ctx, eggId: string, color: Color3)
	ellipsoid(ctx, "Shell", EGG_LOWER_S, CFrame.new(EGG_LOWER_C), color, { Reflectance = 0.05 })
	ellipsoid(ctx, "Shell", EGG_UPPER_S, CFrame.new(EGG_UPPER_C), color, { Reflectance = 0.05 })

	if eggId == "Bubble" then
		eggBand(ctx, -0.1, 0.28, tint(color, 0.6))
		for _, dot in EGG_DOTS do
			eggDot(ctx, "Dot", dot.Dir, Vector3.new(dot.D, dot.D, 0.1), tint(color, 0.75), { Transparency = 0.1 })
		end
	elseif eggId == "Suds" then
		-- Zigzag ribbon: diamonds edge to edge around the egg just above its widest point.
		for i = 0, 11 do
			local a = math.rad(i * 30)
			eggDot(ctx, "Diamond", Vector3.new(math.cos(a), 0.13, math.sin(a)), Vector3.new(0.42, 0.42, 0.08), WHITE, nil, 45)
		end
		for i = 1, #EGG_DOTS, 2 do
			local dot = EGG_DOTS[i]
			eggDot(ctx, "Dot", dot.Dir, Vector3.new(dot.D * 0.7, dot.D * 0.7, 0.1), shade(color, 0.12))
		end
	elseif eggId == "Sparkle" then
		eggBand(ctx, -0.1, 0.3, Color3.fromRGB(255, 200, 60), NEON)
		for i, dot in EGG_DOTS do
			local glint = if i % 2 == 0 then WHITE else Color3.fromRGB(255, 240, 170)
			eggDot(ctx, "Glint", dot.Dir, Vector3.new(0.2, 0.2, 0.06), glint, NEON, 45)
		end
		addSparkles(ctx.Root, "EggSparkle")
	end

	-- Subtle shine: a soft streak and a dot on the upper front, toward the viewer's left (+X).
	eggDot(ctx, "Shine", Vector3.new(0.5, 0.55, -0.75), Vector3.new(0.3, 0.75, 0.1), WHITE, SHINE, -25)
	eggDot(ctx, "Shine", Vector3.new(0.62, 0.22, -0.75), Vector3.new(0.14, 0.14, 0.08), WHITE, SHINE)
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

local templates: { [string]: Model } = {}

-- Runs a builder into a fresh context. A builder that errors is logged once and replaced by the
-- placeholder, so a typo can never break the UI or the renderer.
local function make(name: string, shiny: boolean, build: (Ctx) -> ()): Model
	local ctx = newCtx(name, shiny)
	local ok, err = pcall(build, ctx)
	if not ok then
		warn(string.format("[PetModels] building %s failed: %s", name, tostring(err)))
		ctx.Model:Destroy()
		ctx = newCtx(name, false)
		buildPlaceholder(ctx, PLACEHOLDER_BODY, PLACEHOLDER_ACCENT)
	elseif ctx.Count > PART_BUDGET then
		warn(string.format("[PetModels] %s uses %d parts (budget %d)", name, ctx.Count, PART_BUDGET))
	end
	return ctx.Model
end

local function makePet(petId: string): Model
	local def = Config.Pets[petId]
	if not def then
		local model = make("Pet", false, function(ctx)
			buildPlaceholder(ctx, PLACEHOLDER_BODY, PLACEHOLDER_ACCENT)
		end)
		model:SetAttribute("PetId", "")
		return model
	end

	local colors = def.Colors or {}
	local body: Color3 = colors.Body or PLACEHOLDER_BODY
	local accent: Color3 = colors.Accent or PLACEHOLDER_ACCENT
	local shiny = def.Shiny == true
	local builder = BUILDERS[def.Model]
	local model = make(petId, shiny, function(ctx)
		if builder then
			builder(ctx, body, accent)
		else
			buildPlaceholder(ctx, body, accent)
		end
		if shiny then
			addSparkles(ctx.Root, "ShinySparkle")
		end
	end)
	model:SetAttribute("PetId", petId)
	model:SetAttribute("Rarity", def.Rarity)
	model:SetAttribute("Shiny", shiny)
	return model
end

-- A cute pet model for Config.Pets[petId] (a placeholder for unknown ids). Unparented; the caller
-- parents it and moves it with PivotTo. Facing -Z, PrimaryPart "Root" at the centre.
-- Tier looks (Config.PetTiers): Golden turns the body gold and glinting, Rainbow paints each part a
-- different pastel hue; both get a sparkle. Eyes and shines keep their colours.
local KEEP = { Eye = true, EyeShine = true, Shine = true }
local function applyTier(model: Model, tier: number)
	if tier <= 1 then
		return
	end
	local parts = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and not KEEP[d.Name] and d.Transparency < 1 then
			table.insert(parts, d)
		end
	end
	table.sort(parts, function(a, b)
		return a.Position.Y < b.Position.Y
	end)
	for i, part in parts do
		if tier == 2 then
			local h, _, v = part.Color:ToHSV()
			part.Color = Color3.fromHSV(0.12 + (h - 0.12) * 0.1, 0.75, math.max(v, 0.85))
			part.Reflectance = 0.15
		else
			part.Color = Color3.fromHSV((i / math.max(#parts, 1) * 0.85) % 1, 0.45, 1)
		end
	end
	local root = model.PrimaryPart or parts[1]
	if root then
		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Name = "TierSparkle"
		sparkle.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		sparkle.Color = ColorSequence.new(if tier == 2 then Color3.fromRGB(255, 220, 110) else Color3.fromRGB(255, 170, 240))
		sparkle.LightEmission = 0.6
		sparkle.Size = NumberSequence.new(0.35, 0)
		sparkle.Lifetime = NumberRange.new(0.6, 1)
		sparkle.Rate = if tier == 2 then 4 else 7
		sparkle.Speed = NumberRange.new(0.5, 1.5)
		sparkle.SpreadAngle = Vector2.new(180, 180)
		sparkle.Parent = root
	end
end

function PetModels.Build(petId: string, tier: number?): Model
	local key = if type(petId) == "string" and Config.Pets[petId] then petId else PLACEHOLDER_KEY
	local template = templates[key]
	if not template then
		template = makePet(key)
		templates[key] = template
	end
	local model = template:Clone()
	applyTier(model, math.floor(tonumber(tier) or 1))
	return model
end

-- An egg model for Config.Eggs (by Id) for UI and lobby displays; a plain grey egg for unknown ids.
function PetModels.Egg(eggId: string): Model
	local egg = if type(eggId) == "string" then Config.GetEgg(eggId) else nil
	local key = "\0Egg:" .. (if egg then egg.Id else "?")
	local template = templates[key]
	if not template then
		local id = if egg then egg.Id else ""
		local color = if egg then egg.Color else EGG_PLAIN
		template = make(if egg then egg.Id .. "Egg" else "Egg", false, function(ctx)
			buildEgg(ctx, id, color)
		end)
		template:SetAttribute("EggId", id)
		templates[key] = template
	end
	return template:Clone()
end

-- True when petId has its own builder (false = it would render as the placeholder).
function PetModels.Has(petId: string): boolean
	if type(petId) ~= "string" then
		return false
	end
	local def = Config.Pets[petId]
	return def ~= nil and BUILDERS[def.Model] ~= nil
end

return PetModels
