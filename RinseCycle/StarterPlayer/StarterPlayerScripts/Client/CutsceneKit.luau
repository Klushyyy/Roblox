--[[
	CutsceneKit - the toolbox the run-start cutscene chapters are built with.

	A chapter is a little film: a set (built here from primitives, client-only, far from the map), a
	cast from LevelNPCs (the same rig, looks, props, plans and poses as the people in the rooms), a
	shot list for the camera, and a mood for the lighting. Every chapter ends the same way: somebody
	loads the giant dishwasher, shuts it, presses Start, and the camera pushes in through the door's
	window into the bubbles, which is where the run begins.

	Coordinates are LevelNPCs' room space: +X right, +Y up, +Z away from the camera's usual side
	(world -Z), in studs; a person is 250 tall (S = 50). Heights given to the set builders are above
	the floor. Actors face `phi` (0 = +Z, pi = back toward the camera, pi/2 = +X).

	    local ctx = Kit.new(origin, parent, duration)
	    ctx:box(...), Kit.room(ctx, ...), Kit.dishwasher(ctx, ...), ...
	    ctx:shot(t0, t1, { eye = { a, b }, look = { a, b }, fov = { f0, f1 } })
	    -- then ctx:Update(t), ctx:Camera(t) every frame, ctx:Destroy() at the end
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local LevelNPCs = require(script.Parent:WaitForChild("LevelNPCs"))

local R = LevelNPCs.Kit

-- Moves many parts at once (with a plain fallback where BulkMoveTo isn't available).
local function moveAll(parts: { BasePart }, cfs: { CFrame })
	local ok = pcall(function()
		Workspace:BulkMoveTo(parts, cfs, Enum.BulkMoveMode.FireCFrameChanged)
	end)
	if not ok then
		for i, p in parts do
			p.CFrame = cfs[i]
		end
	end
end
local FLOOR = R.FLOOR
local PI = math.pi

local Kit = {}
Kit.Rig = R

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end
Kit.rgb = rgb

local smooth = R.smooth
local lerp = R.lerp

-- Eases for shots and keyed motion.
local EASES = {
	linear = function(k: number): number
		return k
	end,
	smooth = smooth,
	out = function(k: number): number
		return 1 - (1 - k) ^ 3
	end,
	inout = function(k: number): number
		return if k < 0.5 then 4 * k * k * k else 1 - (-2 * k + 2) ^ 3 / 2
	end,
	["in"] = function(k: number): number
		return k * k * k
	end,
}
Kit.Eases = EASES

----------------------------------------------------------------------------------------------------
-- The context: one chapter's parts, cast, camera and clock
----------------------------------------------------------------------------------------------------

local Ctx = {}
Ctx.__index = Ctx

function Kit.new(origin: CFrame, parent: Instance, duration: number): any
	local self = setmetatable({}, Ctx)
	self.Origin = origin
	local model = Instance.new("Model")
	model.Name = "Cutscene"
	model.Parent = parent
	self.Model = model
	local set = Instance.new("Folder")
	set.Name = "Set"
	set.Parent = model
	self.Set = set
	self.Scene = R.newScene(origin, model)
	self.Scene.Period = 1e5 -- a film, not a loop
	self.Shots = {} :: { any }
	self.Updaters = {} :: { (number) -> () }
	self.Inside = {} :: { Vector3 }
	self.Duration = duration
	self.BubbleStart = duration
	self.Title = ""
	self.Subtitle = ""
	self.MoodProps = nil :: { [string]: any }?
	self.SavedMood = nil :: { [string]: any }?
	return self
end

-- A room-space CFrame at (x, h above the floor, z) turned to `yaw` (like an actor's phi).
function Ctx:at(x: number, h: number, z: number, yaw: number?): CFrame
	return CFrame.new(x, FLOOR + h, -z) * CFrame.Angles(0, -(yaw or 0), 0)
end

-- A world point from room coordinates (h above the floor).
function Ctx:R(x: number, h: number, z: number): Vector3
	return (self.Origin * CFrame.new(x, FLOOR + h, -z)).Position
end

-- A room point (h above the floor) from a world point.
function Ctx:toRoom(p: Vector3): Vector3
	local l = self.Origin:PointToObjectSpace(p)
	return Vector3.new(l.X, l.Y - FLOOR, -l.Z)
end

-- One set part. cf is room space (from ctx:at). shape: "Ball", "Cylinder", "Wedge", "Sphere" (an
-- ellipsoid), or nil for a block.
function Ctx:box(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: string?, transparency: number?): BasePart
	local p = R.newPart(name, size, color, material, shape)
	p.CFrame = self.Origin * cf
	p.CastShadow = (transparency or 0) < 0.5
	if transparency then
		p.Transparency = transparency
	end
	p.Parent = self.Set
	return p
end

-- An upright cylinder (axis Y) standing on h: diameter d, height ht.
function Ctx:post(name: string, d: number, ht: number, x: number, h: number, z: number, color: Color3, material: Enum.Material?): BasePart
	return self:box(name, Vector3.new(ht, d, d), self:at(x, h + ht / 2, z) * CFrame.Angles(0, 0, PI / 2), color, material, "Cylinder")
end

-- A glowing bulb with a light.
function Ctx:light(x: number, h: number, z: number, color: Color3, range: number, brightness: number?, size: number?): BasePart
	local bulb = self:box("Bulb", Vector3.one * (size or 12), self:at(x, h, z), color, Enum.Material.Neon, "Ball")
	bulb.CastShadow = false
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = math.min(range, 60)
	l.Brightness = brightness or 1.5
	l.Shadows = false
	l.Parent = bulb
	return bulb
end

function Ctx:onUpdate(fn: (number) -> ())
	table.insert(self.Updaters, fn)
end

-- Lighting for this chapter (Lighting properties); applied by the player, restored on Destroy.
function Ctx:mood(props: { [string]: any })
	self.MoodProps = props
end

function Ctx:ApplyMood()
	local props = self.MoodProps
	if not props or self.SavedMood then
		return
	end
	local saved = {}
	for k, v in props do
		local ok, old = pcall(function()
			return (Lighting :: any)[k]
		end)
		if ok then
			saved[k] = old
			pcall(function()
				(Lighting :: any)[k] = v
			end)
		end
	end
	self.SavedMood = saved
end

function Ctx:RestoreMood()
	local saved = self.SavedMood
	if not saved then
		return
	end
	self.SavedMood = nil
	for k, v in saved do
		pcall(function()
			(Lighting :: any)[k] = v
		end)
	end
end

-- A camera shot from t0 to t1. spec.eye / spec.look: { from, to } world points (ctx:R), or a
-- function(t) -> world point. spec.fov: { from, to } (default 50). spec.ease: EASES key.
-- spec.shake: handheld wobble in studs. Shots are hard cuts: the latest shot started wins.
function Ctx:shot(t0: number, t1: number, spec: { [string]: any })
	table.insert(self.Shots, { T0 = t0, T1 = t1, Spec = spec })
	table.sort(self.Shots, function(a, b)
		return a.T0 < b.T0
	end)
end

local function sample(v: any, k: number, t: number): Vector3
	if type(v) == "function" then
		return v(t)
	end
	if typeof(v) == "Vector3" then
		return v
	end
	return (v[1] :: Vector3):Lerp(v[2] or v[1], k)
end

function Ctx:Camera(t: number): (CFrame, number)
	local shot = self.Shots[1]
	for _, s in self.Shots do
		if s.T0 <= t then
			shot = s
		end
	end
	if not shot then
		return self.Origin, 50
	end
	local spec = shot.Spec
	local ease = EASES[spec.ease or "smooth"] or smooth
	local k = ease(math.clamp((t - shot.T0) / math.max(shot.T1 - shot.T0, 1e-3), 0, 1))
	local eye = sample(spec.eye, k, t)
	local look = sample(spec.look, k, t)
	local fov = spec.fov
	local f = if type(fov) == "table" then lerp(fov[1], fov[2] or fov[1], k) elseif type(fov) == "number" then fov else 50
	if spec.shake then
		local a = spec.shake
		eye += Vector3.new(math.sin(t * 1.7) * a, math.sin(t * 2.3 + 1) * a * 0.6, math.cos(t * 1.3) * a * 0.5)
	end
	if (look - eye).Magnitude < 1e-3 then
		look = eye + Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(eye, look), f
end

function Ctx:Update(t: number)
	self.Scene:Update(t)
	for _, fn in self.Updaters do
		fn(t)
	end
end

function Ctx:InsidePoints(): { Vector3 }
	return self.Inside
end

function Ctx:Destroy()
	self:RestoreMood()
	self.Model:Destroy()
end

-- A world point that follows an actor's bone (for tracking shots): offset in the bone's space.
function Kit.follow(actor: any, bone: string, offset: Vector3?): (number) -> Vector3
	return function(_t: number): Vector3
		local b = actor.Bones and actor.Bones[bone]
		if not b then
			return Vector3.zero
		end
		return (b * CFrame.new(offset or Vector3.zero)).Position
	end
end

-- Keyed values: keys = { { t, value }, ... } sorted by t, smooth between keys.
function Kit.keyed(keys: { { number } }, ease: string?): (number) -> number
	local e = EASES[ease or "smooth"] or smooth
	return function(t: number): number
		if t <= keys[1][1] then
			return keys[1][2]
		end
		for i = 2, #keys do
			local a, b = keys[i - 1], keys[i]
			if t <= b[1] then
				return lerp(a[2], b[2], e((t - a[1]) / math.max(b[1] - a[1], 1e-3)))
			end
		end
		return keys[#keys][2]
	end
end

-- Moves a group of parts as one: each part keeps its offset from `pivot` (a room CFrame) and the
-- group follows fn(t) -> room CFrame. Returns the updater.
function Kit.group(ctx: any, parts: { BasePart }, pivot: CFrame, fn: (number) -> CFrame)
	local offsets = {}
	local world = ctx.Origin * pivot
	for i, p in parts do
		offsets[i] = world:ToObjectSpace(p.CFrame)
	end
	ctx:onUpdate(function(t)
		local base = ctx.Origin * fn(t)
		local cfs = {}
		for i, _ in parts do
			cfs[i] = base * offsets[i]
		end
		moveAll(parts, cfs)
	end)
end

----------------------------------------------------------------------------------------------------
-- Rooms
----------------------------------------------------------------------------------------------------

-- A floor slab from (x0, z0) to (x1, z1); planks = board width for a wood floor's seams.
function Kit.floor(ctx: any, x0: number, x1: number, z0: number, z1: number, color: Color3, material: Enum.Material?, planks: number?)
	local w, d = x1 - x0, z1 - z0
	ctx:box("Floor", Vector3.new(w, 10, d), ctx:at((x0 + x1) / 2, -5, (z0 + z1) / 2), color, material)
	if planks then
		local seam = Color3.new(color.R * 0.8, color.G * 0.8, color.B * 0.8)
		local x = x0 + planks
		while x < x1 - 1 do
			ctx:box("Seam", Vector3.new(1.2, 0.4, d), ctx:at(x, 0.2, (z0 + z1) / 2), seam, material)
			x += planks
		end
	end
end

-- A wall along a line (x0, z0) -> (x1, z1), `h` tall, with a skirting board and a top trim.
function Kit.wall(ctx: any, x0: number, z0: number, x1: number, z1: number, h: number, color: Color3, material: Enum.Material?, trim: Color3?)
	local dx, dz = x1 - x0, z1 - z0
	local len = math.sqrt(dx * dx + dz * dz)
	local yaw = math.atan2(dx, dz) - PI / 2 -- wall runs along its local X
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	ctx:box("Wall", Vector3.new(len, h, 16), ctx:at(cx, h / 2, cz, yaw), color, material)
	local t = trim or rgb(250, 248, 242)
	ctx:box("Skirting", Vector3.new(len, 22, 20), ctx:at(cx, 11, cz, yaw), t)
	ctx:box("TopTrim", Vector3.new(len, 14, 22), ctx:at(cx, h - 7, cz, yaw), t)
end

-- A room: floor, back wall at z1 and side walls at x0 / x1 (the front, toward the camera, stays
-- open). Returns nothing; decorate with the other builders.
function Kit.room(ctx: any, spec: { [string]: any })
	local x0, x1, z0, z1 = spec.X0, spec.X1, spec.Z0, spec.Z1
	local h = spec.H or 720
	Kit.floor(ctx, x0 - 8, x1 + 8, z0, z1 + 8, spec.Floor, spec.FloorMat, spec.Planks)
	Kit.wall(ctx, x0, z1, x1, z1, h, spec.Wall, spec.WallMat, spec.Trim)
	if spec.Left ~= false then
		Kit.wall(ctx, x0, z0, x0, z1, h, spec.SideWall or spec.Wall, spec.WallMat, spec.Trim)
	end
	if spec.Right ~= false then
		Kit.wall(ctx, x1, z0, x1, z1, h, spec.SideWall or spec.Wall, spec.WallMat, spec.Trim)
	end
	if spec.Stripe then
		-- a dado rail / wainscot band along the back wall
		ctx:box("Dado", Vector3.new(x1 - x0, spec.StripeH or 220, 18), ctx:at((x0 + x1) / 2, (spec.StripeH or 220) / 2, z1 - 1), spec.Stripe, spec.StripeMat)
	end
end

-- A window drawn on a wall facing the camera (-Z): sky, frame, sill, optional curtains.
-- view: "day" | "dusk" | "night".
function Kit.window(ctx: any, x: number, h: number, z: number, w: number, hh: number, view: string?, curtain: Color3?)
	local zf = z - 9
	local sky = if view == "night" then rgb(30, 42, 90) elseif view == "dusk" then rgb(255, 170, 120) else rgb(150, 210, 255)
	local low = if view == "night" then rgb(60, 70, 130) elseif view == "dusk" then rgb(255, 214, 150) else rgb(210, 240, 255)
	ctx:box("Sky", Vector3.new(w, hh * 0.55, 2), ctx:at(x, h + hh * 0.225, zf), sky, Enum.Material.Neon)
	ctx:box("SkyLow", Vector3.new(w, hh * 0.45, 2), ctx:at(x, h - hh * 0.275, zf), low, Enum.Material.Neon)
	if view == "night" then
		ctx:box("Moon", Vector3.new(2, hh * 0.18, hh * 0.18), ctx:at(x + w * 0.25, h + hh * 0.28, zf - 1.5) * CFrame.Angles(0, PI / 2, 0), rgb(255, 250, 220), Enum.Material.Neon, "Cylinder")
		for i = 1, 7 do
			local sx = x - w * 0.42 + ((i * 37) % 100) / 100 * w * 0.6
			local sy = h + hh * 0.05 + ((i * 53) % 100) / 100 * hh * 0.38
			ctx:box("Star", Vector3.new(3, 3, 1), ctx:at(sx, sy, zf - 1.5), rgb(255, 255, 230), Enum.Material.Neon)
		end
	else
		-- a hill and a couple of trees outside
		ctx:box("Hill", Vector3.new(2, w * 0.9, w * 0.9), ctx:at(x - w * 0.15, h - hh * 0.5 - w * 0.3, zf - 1) * CFrame.Angles(0, PI / 2, 0), rgb(120, 190, 110), Enum.Material.SmoothPlastic, "Cylinder")
	end
	local frame = rgb(250, 250, 246)
	ctx:box("WinFrame", Vector3.new(w + 20, 10, 12), ctx:at(x, h + hh / 2 + 5, zf - 2), frame)
	ctx:box("WinFrame", Vector3.new(w + 20, 10, 12), ctx:at(x, h - hh / 2 - 5, zf - 2), frame)
	ctx:box("WinFrame", Vector3.new(10, hh, 12), ctx:at(x - w / 2 - 5, h, zf - 2), frame)
	ctx:box("WinFrame", Vector3.new(10, hh, 12), ctx:at(x + w / 2 + 5, h, zf - 2), frame)
	ctx:box("WinBar", Vector3.new(6, hh, 8), ctx:at(x, h, zf - 2), frame)
	ctx:box("WinBar", Vector3.new(w, 6, 8), ctx:at(x, h + hh * 0.1, zf - 2), frame)
	ctx:box("Sill", Vector3.new(w + 36, 8, 26), ctx:at(x, h - hh / 2 - 12, zf - 8), frame)
	if curtain then
		for _, side in { -1, 1 } do
			ctx:box("Curtain", Vector3.new(w * 0.22, hh + 60, 6), ctx:at(x + side * (w / 2 + 6), h + 10, zf - 12), curtain, Enum.Material.Fabric)
			ctx:box("CurtainTie", Vector3.new(w * 0.24, 8, 8), ctx:at(x + side * (w / 2 + 6), h - hh * 0.15, zf - 14), Color3.new(curtain.R * 0.7, curtain.G * 0.7, curtain.B * 0.7), Enum.Material.Fabric)
		end
		ctx:box("CurtainRod", Vector3.new(w + 90, 6, 6), ctx:at(x, h + hh / 2 + 40, zf - 12), rgb(120, 90, 60), Enum.Material.Wood)
	end
end

-- A framed picture on a wall facing the camera.
function Kit.picture(ctx: any, x: number, h: number, z: number, w: number, hh: number, colors: { Color3 })
	local zf = z - 9
	ctx:box("PicFrame", Vector3.new(w + 14, hh + 14, 4), ctx:at(x, h, zf - 1), rgb(140, 96, 56), Enum.Material.Wood)
	ctx:box("Pic", Vector3.new(w, hh, 2), ctx:at(x, h, zf - 3), colors[1])
	if colors[2] then
		ctx:box("Pic", Vector3.new(w, hh * 0.45, 2), ctx:at(x, h - hh * 0.275, zf - 3.4), colors[2])
	end
	if colors[3] then
		ctx:box("Pic", Vector3.new(2, hh * 0.35, hh * 0.35), ctx:at(x + w * 0.2, h + hh * 0.18, zf - 3.8) * CFrame.Angles(0, PI / 2, 0), colors[3], nil, "Cylinder")
	end
end

-- A potted plant.
function Kit.plant(ctx: any, x: number, z: number, h: number?)
	local ht = h or 160
	ctx:post("Pot", 60, 50, x, 0, z, rgb(200, 110, 70))
	ctx:post("Soil", 52, 4, x, 48, z, rgb(80, 56, 40))
	for i = 0, 4 do
		local a = i / 5 * PI * 2
		ctx:box("Leaf", Vector3.new(40, ht * 0.55, 40), ctx:at(x + math.cos(a) * 18, 50 + ht * 0.3 + (i % 2) * 20, z + math.sin(a) * 18) * CFrame.Angles(math.sin(a) * 0.3, 0, math.cos(a) * 0.3), rgb(70, 160 + i * 8, 80), nil, "Sphere")
	end
end

-- A rug on the floor.
function Kit.rug(ctx: any, x: number, z: number, w: number, d: number, color: Color3, border: Color3?)
	ctx:box("Rug", Vector3.new(w, 1.2, d), ctx:at(x, 0.6, z), border or color, Enum.Material.Fabric)
	if border then
		ctx:box("Rug", Vector3.new(w - 30, 1.4, d - 30), ctx:at(x, 0.7, z), color, Enum.Material.Fabric)
	end
end

-- A table with four legs; top = height of its top surface. Returns the top height.
function Kit.table(ctx: any, x: number, z: number, w: number, d: number, top: number, color: Color3, cloth: Color3?, material: Enum.Material?): number
	local mat = material or Enum.Material.Wood
	ctx:box("TableTop", Vector3.new(w, 10, d), ctx:at(x, top - 5, z), color, mat)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			ctx:box("TableLeg", Vector3.new(12, top - 10, 12), ctx:at(x + sx * (w / 2 - 14), (top - 10) / 2, z + sz * (d / 2 - 14)), color, mat)
		end
	end
	if cloth then
		ctx:box("Cloth", Vector3.new(w + 10, 1.5, d + 10), ctx:at(x, top + 0.8, z), cloth, Enum.Material.Fabric)
		ctx:box("ClothDrop", Vector3.new(w + 12, 40, 1.5), ctx:at(x, top - 18, z - d / 2 - 5.5), cloth, Enum.Material.Fabric)
	end
	return top
end

-- A chair prop (from LevelNPCs) placed for the whole film. Returns the seat for plan:sitDown.
function Kit.chair(ctx: any, name: string, x: number, z: number, phi: number, kind: string?): any
	ctx.Scene:prop(name, kind or "FurnChair")
	ctx.Scene:place(name, 0, 1e5 - 1, R.rootCF(x, z, phi))
	local top = if kind == "FurnHighChair" then 92 elseif kind == "FurnKidChair" then 108 else 98
	-- people perch a little in front of the chair's centre
	return R.seat(x + math.sin(phi) * 4, z + math.cos(phi) * 4, phi, top)
end

-- Kitchen cabinets along the back: fronts at zf, `depth` deep, top at h (default 170), from x0 to
-- x1, leaving `gaps` ({ { a, b } }) open for appliances. Returns the counter-top height.
function Kit.counter(ctx: any, x0: number, x1: number, zf: number, spec: { [string]: any }?): number
	local sp = spec or {}
	local h = sp.H or 170
	local depth = sp.Depth or 130
	local body = sp.Body or rgb(245, 243, 236)
	local top = sp.Top or rgb(200, 204, 210)
	local knob = sp.Knob or rgb(150, 150, 158)
	local gaps = sp.Gaps or {}
	local cz = zf + depth / 2
	-- cabinet runs between the gaps
	local runs = {}
	local cur = x0
	table.sort(gaps, function(a, b)
		return a[1] < b[1]
	end)
	for _, g in gaps do
		if g[1] > cur then
			table.insert(runs, { cur, g[1] })
		end
		cur = math.max(cur, g[2])
	end
	if x1 > cur then
		table.insert(runs, { cur, x1 })
	end
	for _, r in runs do
		local a, b = r[1], r[2]
		local w = b - a
		ctx:box("Cabinet", Vector3.new(w, h - 22, depth - 8), ctx:at((a + b) / 2, 12 + (h - 22) / 2, cz + 4), body, sp.BodyMat)
		ctx:box("ToeKick", Vector3.new(w, 12, depth - 20), ctx:at((a + b) / 2, 6, cz + 10), rgb(60, 60, 66))
		-- doors with a gap line and a knob each
		local n = math.max(1, math.floor(w / 62 + 0.5))
		local dw = w / n
		for i = 0, n - 1 do
			local cx = a + dw * (i + 0.5)
			ctx:box("CabDoor", Vector3.new(dw - 6, h - 40, 3), ctx:at(cx, 12 + (h - 22) / 2 - 4, zf - 1), sp.Door or body, sp.BodyMat)
			ctx:box("Knob", Vector3.new(4, 16, 4), ctx:at(cx + (if i % 2 == 0 then dw / 2 - 14 else -dw / 2 + 14), h - 50, zf - 4), knob, Enum.Material.Metal)
		end
	end
	-- one continuous worktop over everything (appliances included)
	ctx:box("Worktop", Vector3.new(x1 - x0 + 8, 10, depth + 10), ctx:at((x0 + x1) / 2, h - 5, cz - 1), top, sp.TopMat or Enum.Material.Marble)
	ctx:box("Splash", Vector3.new(x1 - x0, 60, 4), ctx:at((x0 + x1) / 2, h + 30, zf + depth + 2), sp.Splash or rgb(225, 235, 240), sp.SplashMat)
	return h
end

-- Wall cupboards above the worktop.
function Kit.upper(ctx: any, x0: number, x1: number, zWall: number, bottom: number, spec: { [string]: any }?)
	local sp = spec or {}
	local body = sp.Body or rgb(245, 243, 236)
	local h = sp.H or 150
	local depth = 70
	local w = x1 - x0
	ctx:box("Upper", Vector3.new(w, h, depth), ctx:at((x0 + x1) / 2, bottom + h / 2, zWall - depth / 2 - 8), body, sp.BodyMat)
	local n = math.max(1, math.floor(w / 64 + 0.5))
	local dw = w / n
	for i = 0, n - 1 do
		local cx = x0 + dw * (i + 0.5)
		ctx:box("UpperDoor", Vector3.new(dw - 6, h - 12, 3), ctx:at(cx, bottom + h / 2, zWall - depth - 9), sp.Door or body, sp.BodyMat)
		ctx:box("Knob", Vector3.new(4, 14, 4), ctx:at(cx + (if i % 2 == 0 then dw / 2 - 12 else -dw / 2 + 12), bottom + 18, zWall - depth - 12), rgb(150, 150, 158), Enum.Material.Metal)
	end
end

-- A sink in the worktop at x (fronts at zf), with a tap.
function Kit.sink(ctx: any, x: number, zf: number, h: number)
	ctx:box("SinkRim", Vector3.new(96, 3, 70), ctx:at(x, h + 1.5, zf + 55), rgb(210, 214, 220), Enum.Material.Metal)
	ctx:box("SinkBowl", Vector3.new(84, 2, 58), ctx:at(x, h + 3, zf + 55), rgb(120, 126, 136), Enum.Material.Metal)
	ctx:post("TapBase", 10, 30, x, h, zf + 100, rgb(210, 214, 220), Enum.Material.Metal)
	ctx:box("TapSpout", Vector3.new(6, 6, 34), ctx:at(x, h + 32, zf + 86), rgb(210, 214, 220), Enum.Material.Metal)
	ctx:box("TapKnob", Vector3.new(16, 5, 5), ctx:at(x, h + 22, zf + 100), rgb(210, 214, 220), Enum.Material.Metal)
end

-- A cooker at x: oven door, hob with burners (optionally glowing).
function Kit.stove(ctx: any, x: number, zf: number, h: number, hot: boolean?)
	ctx:box("Oven", Vector3.new(124, h - 14, 124), ctx:at(x, 12 + (h - 14) / 2 - 4, zf + 64), rgb(60, 62, 70), Enum.Material.Metal)
	ctx:box("OvenDoor", Vector3.new(100, 80, 3), ctx:at(x, 70, zf + 1), rgb(40, 40, 46), Enum.Material.Glass)
	ctx:box("OvenHandle", Vector3.new(90, 5, 6), ctx:at(x, 120, zf - 3), rgb(200, 204, 210), Enum.Material.Metal)
	ctx:box("Hob", Vector3.new(124, 4, 124), ctx:at(x, h + 2, zf + 64), rgb(30, 30, 34), Enum.Material.Glass)
	for _, bx in { -28, 28 } do
		for _, bz in { 36, 90 } do
			ctx:box("Burner", Vector3.new(2, 36, 36), ctx:at(x + bx, h + 4.5, zf + bz) * CFrame.Angles(0, 0, PI / 2), if hot then rgb(255, 90, 40) else rgb(70, 70, 76), if hot then Enum.Material.Neon else nil, "Cylinder")
		end
	end
end

-- A tall fridge at x with its door facing the camera.
function Kit.fridge(ctx: any, x: number, zf: number, color: Color3?)
	local c = color or rgb(236, 240, 244)
	ctx:box("Fridge", Vector3.new(130, 380, 130), ctx:at(x, 190, zf + 65), c)
	ctx:box("FridgeLine", Vector3.new(130, 3, 3), ctx:at(x, 250, zf - 1), rgb(190, 196, 204))
	ctx:box("FridgeHandle", Vector3.new(6, 90, 8), ctx:at(x + 50, 300, zf - 5), rgb(200, 204, 210), Enum.Material.Metal)
	ctx:box("FridgeHandle", Vector3.new(6, 70, 8), ctx:at(x + 50, 200, zf - 5), rgb(200, 204, 210), Enum.Material.Metal)
	-- a couple of magnets / a drawing
	ctx:box("Drawing", Vector3.new(40, 50, 1), ctx:at(x - 20, 290, zf - 1), rgb(255, 255, 250))
	ctx:box("Drawing", Vector3.new(20, 20, 1), ctx:at(x - 26, 296, zf - 1.8), rgb(255, 200, 60), nil, "Ball")
	ctx:box("Drawing", Vector3.new(30, 6, 1), ctx:at(x - 16, 276, zf - 1.8), rgb(80, 180, 90))
end

----------------------------------------------------------------------------------------------------
-- Outdoors
----------------------------------------------------------------------------------------------------

function Kit.grass(ctx: any, x0: number, x1: number, z0: number, z1: number, color: Color3?)
	ctx:box("Grass", Vector3.new(x1 - x0, 10, z1 - z0), ctx:at((x0 + x1) / 2, -5, (z0 + z1) / 2), color or rgb(96, 170, 80), Enum.Material.Grass)
end

-- A white picket fence along x at z.
function Kit.fence(ctx: any, x0: number, x1: number, z: number, color: Color3?)
	local c = color or rgb(250, 250, 246)
	local x = x0
	while x <= x1 do
		ctx:box("Picket", Vector3.new(18, 150, 6), ctx:at(x, 75, z), c)
		ctx:box("PicketTip", Vector3.new(12.7, 12.7, 6), ctx:at(x, 150, z) * CFrame.Angles(0, 0, PI / 4), c)
		x += 32
	end
	for _, h in { 45, 115 } do
		ctx:box("Rail", Vector3.new(x1 - x0 + 30, 12, 6), ctx:at((x0 + x1) / 2, h, z + 6), c)
	end
end

-- A cartoon tree: trunk and three leafy blobs. k scales it.
function Kit.tree(ctx: any, x: number, z: number, k: number?)
	local s = k or 1
	ctx:post("Trunk", 40 * s, 300 * s, x, 0, z, rgb(120, 84, 56), Enum.Material.Wood)
	local leaf = rgb(80, 160, 70)
	ctx:box("Leaves", Vector3.new(260, 220, 260) * s, ctx:at(x, 380 * s, z), leaf, nil, "Sphere")
	ctx:box("Leaves", Vector3.new(180, 160, 180) * s, ctx:at(x - 90 * s, 320 * s, z + 20 * s), Color3.new(leaf.R * 0.9, leaf.G * 0.9, leaf.B * 0.9), nil, "Sphere")
	ctx:box("Leaves", Vector3.new(180, 160, 180) * s, ctx:at(x + 100 * s, 330 * s, z - 10 * s), Color3.new(leaf.R * 1.05, leaf.G * 1.05, leaf.B * 1.05), nil, "Sphere")
end

function Kit.bush(ctx: any, x: number, z: number, k: number?)
	local s = k or 1
	ctx:box("Bush", Vector3.new(120, 80, 100) * s, ctx:at(x, 30 * s, z), rgb(70, 150, 70), nil, "Sphere")
	ctx:box("Bush", Vector3.new(90, 70, 80) * s, ctx:at(x + 50 * s, 26 * s, z + 10 * s), rgb(84, 164, 76), nil, "Sphere")
end

-- A balloon on a string, bobbing.
function Kit.balloon(ctx: any, x: number, h: number, z: number, color: Color3)
	local b = ctx:box("Balloon", Vector3.new(44, 54, 44), ctx:at(x, h, z), color, Enum.Material.SmoothPlastic, "Sphere")
	local s = ctx:box("String", Vector3.new(1, 120, 1), ctx:at(x, h - 87, z), rgb(240, 240, 240))
	b.CastShadow = false
	s.CastShadow = false
	local ph = (x * 0.013 + z * 0.007) % (2 * PI)
	Kit.group(ctx, { b, s }, ctx:at(x, h, z), function(t)
		return ctx:at(x + math.sin(t * 0.8 + ph) * 4, h + math.sin(t * 1.3 + ph) * 6, z) * CFrame.Angles(0, 0, math.sin(t * 0.9 + ph) * 0.05)
	end)
end

----------------------------------------------------------------------------------------------------
-- The dishwasher (every chapter ends here)
----------------------------------------------------------------------------------------------------

local DW_W, DW_H, DW_D = 130, 166, 132
local DOOR_H = 150
local HINGE_Y = 14
local RACK_Y = 62

-- A built-in dishwasher whose front is at (x, zf), facing -Z (the camera) turned by yaw.
-- Returns an object:
--   dw:Keys({ { t, door (0 shut .. 1 open), rack (0 in .. 1 out) }, ... })
--   dw.LoadedAt = t (the loaded plates appear), dw.StartAt = t (the lights come on, it hums)
--   dw:Handle(t), dw:RackFront(t), dw:Button() -> world points for hands
--   dw:Local(x, y, z) -> world point in the dishwasher's own frame (+Z out of the front)
function Kit.dishwasher(ctx: any, x: number, zf: number, yaw: number?, spec: { [string]: any }?): any
	local sp = spec or {}
	local steel = sp.Steel or rgb(214, 219, 226)
	local dark = rgb(70, 76, 88)
	local base = ctx.Origin * CFrame.new(x, FLOOR, -zf) * CFrame.Angles(0, -(yaw or 0), 0)
	local dw = { Base = base, LoadedAt = math.huge, StartAt = math.huge, Door = function(_t)
		return 0
	end, Rack = function(_t)
		return 0
	end }

	local function part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: string?): BasePart
		local p = R.newPart(name, size, color, material, shape)
		p.CFrame = base * cf
		p.Parent = ctx.Set
		return p
	end

	-- The tub: a hollow box so the inside shows when the door opens.
	local inner = rgb(150, 158, 170)
	part("DWSide", Vector3.new(6, DW_H - 16, DW_D), CFrame.new(-DW_W / 2 + 3, 16 + (DW_H - 16) / 2, -DW_D / 2 - 4), steel, Enum.Material.Metal)
	part("DWSide", Vector3.new(6, DW_H - 16, DW_D), CFrame.new(DW_W / 2 - 3, 16 + (DW_H - 16) / 2, -DW_D / 2 - 4), steel, Enum.Material.Metal)
	part("DWBack", Vector3.new(DW_W, DW_H - 16, 6), CFrame.new(0, 16 + (DW_H - 16) / 2, -DW_D - 1), inner, Enum.Material.Metal)
	part("DWFloor", Vector3.new(DW_W - 12, 6, DW_D), CFrame.new(0, 17, -DW_D / 2 - 4), inner, Enum.Material.Metal)
	part("DWTop", Vector3.new(DW_W, 6, DW_D), CFrame.new(0, DW_H - 3, -DW_D / 2 - 4), inner, Enum.Material.Metal)
	part("DWToe", Vector3.new(DW_W - 4, 13, 6), CFrame.new(0, 6.5, -6), rgb(50, 52, 58))
	-- spray arm and the fixed top rack with cups
	part("DWSpray", Vector3.new(90, 3, 10), CFrame.new(0, 30, -DW_D / 2), dark, Enum.Material.Metal)
	part("DWTopRack", Vector3.new(DW_W - 20, 3, DW_D - 20), CFrame.new(0, 118, -DW_D / 2 - 4), rgb(190, 196, 206), Enum.Material.Metal)
	for i = 0, 3 do
		part("DWCup", Vector3.new(16, 22, 16), CFrame.new(-39 + i * 26, 131, -DW_D / 2 + 10) * CFrame.Angles(PI, 0, 0), rgb(240, 240, 236), nil, "Cylinder")
	end
	-- inside glow once it runs
	local glow = part("DWGlow", Vector3.new(DW_W - 24, 90, 2), CFrame.new(0, 80, -DW_D + 2), rgb(120, 200, 255), Enum.Material.Neon)
	glow.Transparency = 1
	glow.CastShadow = false
	local glowLight = Instance.new("PointLight")
	glowLight.Color = rgb(140, 210, 255)
	glowLight.Range = 40
	glowLight.Brightness = 0
	glowLight.Parent = glow

	-- The door, hinged along its bottom front edge; its parts are placed in the door's own frame
	-- (origin at the hinge, +Y up the door, +Z out of the front).
	local doorParts: { { any } } = {}
	local function doorPart(name: string, size: Vector3, off: CFrame, color: Color3, material: Enum.Material?, transparency: number?): BasePart
		local p = R.newPart(name, size, color, material)
		if transparency then
			p.Transparency = transparency
		end
		p.Parent = ctx.Set
		table.insert(doorParts, { p, off })
		return p
	end
	local wy, ww, wh = 70, 76, 54 -- window centre (up the door), size
	doorPart("DoorLow", Vector3.new(DW_W, wy - wh / 2, 8), CFrame.new(0, (wy - wh / 2) / 2, -4), steel, Enum.Material.Metal)
	doorPart("DoorHigh", Vector3.new(DW_W, DOOR_H - wy - wh / 2, 8), CFrame.new(0, (DOOR_H + wy + wh / 2) / 2, -4), steel, Enum.Material.Metal)
	doorPart("DoorSide", Vector3.new((DW_W - ww) / 2, wh, 8), CFrame.new(-(DW_W + ww) / 4, wy, -4), steel, Enum.Material.Metal)
	doorPart("DoorSide", Vector3.new((DW_W - ww) / 2, wh, 8), CFrame.new((DW_W + ww) / 4, wy, -4), steel, Enum.Material.Metal)
	doorPart("DoorGlass", Vector3.new(ww, wh, 2), CFrame.new(0, wy, -3), rgb(150, 215, 245), Enum.Material.Glass, 0.45)
	doorPart("DoorRim", Vector3.new(ww + 8, 4, 3), CFrame.new(0, wy + wh / 2 + 2, 0.5), dark)
	doorPart("DoorRim", Vector3.new(ww + 8, 4, 3), CFrame.new(0, wy - wh / 2 - 2, 0.5), dark)
	doorPart("DoorRim", Vector3.new(4, wh, 3), CFrame.new(-ww / 2 - 2, wy, 0.5), dark)
	doorPart("DoorRim", Vector3.new(4, wh, 3), CFrame.new(ww / 2 + 2, wy, 0.5), dark)
	doorPart("DoorInner", Vector3.new(DW_W - 14, DOOR_H - 14, 2), CFrame.new(0, DOOR_H / 2, -9), inner, Enum.Material.Metal)
	doorPart("Handle", Vector3.new(84, 6, 6), CFrame.new(0, DOOR_H - 30, 7), rgb(185, 190, 198), Enum.Material.Metal)
	for _, hx in { -40, 40 } do
		doorPart("HandleFoot", Vector3.new(5, 5, 7), CFrame.new(hx, DOOR_H - 30, 3), rgb(185, 190, 198), Enum.Material.Metal)
	end
	doorPart("Panel", Vector3.new(DW_W, 16, 1.5), CFrame.new(0, DOOR_H - 9, 0.4), rgb(40, 44, 56))
	local display = doorPart("Display", Vector3.new(30, 8, 1), CFrame.new(-36, DOOR_H - 9, 1.3), rgb(40, 60, 70), Enum.Material.Neon)
	local button = doorPart("StartButton", Vector3.new(10, 10, 2), CFrame.new(44, DOOR_H - 9, 1.4), rgb(90, 90, 96), Enum.Material.Neon)
	for i = 0, 2 do
		doorPart("Dot", Vector3.new(5, 5, 1), CFrame.new(4 + i * 10, DOOR_H - 9, 1.2), rgb(120, 130, 150), Enum.Material.Neon)
	end

	-- The bottom rack (slides out along +Z) with its plates.
	local rackParts: { { any } } = {}
	local function rackPart(name: string, size: Vector3, off: CFrame, color: Color3, material: Enum.Material?, shape: string?): BasePart
		local p = R.newPart(name, size, color, material, shape)
		p.Parent = ctx.Set
		table.insert(rackParts, { p, off })
		return p
	end
	local wire = rgb(196, 200, 210)
	rackPart("Rack", Vector3.new(DW_W - 22, 3, DW_D - 24), CFrame.new(0, 0, 0), wire, Enum.Material.Metal)
	for _, sx in { -1, 1 } do
		rackPart("RackSide", Vector3.new(3, 22, DW_D - 24), CFrame.new(sx * (DW_W - 22) / 2, 10, 0), wire, Enum.Material.Metal)
	end
	rackPart("RackFront", Vector3.new(DW_W - 22, 22, 3), CFrame.new(0, 10, (DW_D - 24) / 2), wire, Enum.Material.Metal)
	rackPart("RackBack", Vector3.new(DW_W - 22, 22, 3), CFrame.new(0, 10, -(DW_D - 24) / 2), wire, Enum.Material.Metal)
	for i = -3, 3 do
		rackPart("Tine", Vector3.new(2, 16, DW_D - 30), CFrame.new(i * 14, 9, 0), wire, Enum.Material.Metal)
	end
	local plates: { BasePart } = {}
	local plateColor = sp.Plate or rgb(250, 250, 248)
	local mess = sp.Mess or rgb(200, 70, 50)
	for i = 0, 5 do
		local p = rackPart("RackPlate", Vector3.new(2.5, 46, 46), CFrame.new(-40 + i * 16, 24, 6), plateColor, nil, "Cylinder")
		table.insert(plates, p)
		local m = rackPart("RackMess", Vector3.new(3, 14, 18), CFrame.new(-40 + i * 16 + 0.6, 30 - (i % 3) * 6, 2 + (i % 2) * 8), mess, nil, "Sphere")
		table.insert(plates, m)
	end

	local doorOpen: (number) -> number = function()
		return 0
	end
	local rackOut: (number) -> number = function()
		return 0
	end
	function dw:Keys(keys: { { number } })
		local dk, rk = {}, {}
		for _, k in keys do
			table.insert(dk, { k[1], k[2] })
			table.insert(rk, { k[1], k[3] })
		end
		doorOpen = Kit.keyed(dk, "inout")
		rackOut = Kit.keyed(rk, "inout")
	end
	local function doorFrame(t: number): CFrame
		return base * CFrame.new(0, HINGE_Y, 0) * CFrame.Angles(doorOpen(t) * PI * 0.5, 0, 0)
	end
	local function rackFrame(t: number): CFrame
		return base * CFrame.new(0, RACK_Y, -DW_D / 2 - 4 + rackOut(t) * (DW_D - 10))
	end
	function dw:Local(lx: number, ly: number, lz: number): Vector3
		return (base * CFrame.new(lx, ly, lz)).Position
	end
	function dw:Handle(t: number): Vector3
		return (doorFrame(t) * CFrame.new(0, DOOR_H - 30, 10)).Position
	end
	function dw:RackFront(t: number): Vector3
		return (rackFrame(t) * CFrame.new(0, 14, (DW_D - 24) / 2 + 2)).Position
	end
	function dw:Button(): Vector3
		return (base * CFrame.new(44, HINGE_Y + DOOR_H - 9, 3)).Position
	end
	function dw:WindowCentre(): Vector3
		return (base * CFrame.new(0, HINGE_Y + wy, 0)).Position
	end

	local loadedShown: boolean? = nil
	ctx:onUpdate(function(t: number)
		local parts, cfs = {}, {}
		local running = t >= dw.StartAt
		local hum = if running then CFrame.new(math.sin(t * 40) * 0.25, 0, 0) else CFrame.identity
		local df = doorFrame(t) * hum
		for _, e in doorParts do
			table.insert(parts, e[1])
			table.insert(cfs, df * e[2])
		end
		local rf = rackFrame(t)
		for _, e in rackParts do
			table.insert(parts, e[1])
			table.insert(cfs, rf * e[2])
		end
		moveAll(parts, cfs)
		local loaded = t >= dw.LoadedAt
		if loaded ~= loadedShown then
			loadedShown = loaded
			for _, p in plates do
				p.Transparency = if loaded then 0 else 1
			end
		end
		local k = if running then math.clamp((t - dw.StartAt) / 0.4, 0, 1) else 0
		button.Color = if running then rgb(80, 255, 140) else rgb(90, 90, 96)
		display.Color = if running then rgb(90, 230, 255) else rgb(40, 60, 70)
		glow.Transparency = 1 - 0.55 * k * (0.8 + 0.2 * math.sin(t * 9))
		glowLight.Brightness = 3 * k
	end)

	-- where the cutscene player blows bubbles once it runs
	for _, lx in { -36, 0, 36 } do
		for _, ly in { 50, 85, 115 } do
			table.insert(ctx.Inside, (base * CFrame.new(lx, ly, -DW_D * 0.45)).Position)
		end
	end
	dw.Width, dw.Height, dw.Depth = DW_W, DW_H, DW_D
	return dw
end

----------------------------------------------------------------------------------------------------
-- The loading routine: somebody standing in front of the dishwasher (facing it, empty-handed or
-- carrying `stack` in both hands) opens it, pulls the rack out, puts the dishes in, closes it and
-- presses Start. Adds the steps to `plan`, keys the dishwasher, and returns the times of the beats:
-- { Open, Load, Close, Press, Done }.
----------------------------------------------------------------------------------------------------

-- The resting spot of the right hand in front of the chest (for reaches that start from rest).
local function chestPoint(plan: any, bones: any?): Vector3
	local s = plan.Actor.S
	local b = bones or plan.Actor.Bones
	if b and b.Torso then
		return (b.Torso * CFrame.new(0.6 * s, -0.6 * s, -0.7 * s)).Position
	end
	return Vector3.zero
end

-- The loading routine. The loader stands in front of the dishwasher, a little to its left, facing
-- it, carrying `stack` (a prop) in both hands, or nothing. The stack moves to the left hand (like a
-- waiter), the right hand opens the door and pulls the rack, the left hand lowers the dishes in,
-- then the rack goes back, the door shuts and Start is pressed. Adds the steps to `plan`, keys the
-- dishwasher and returns the beat times { Open, Load, Close, Press, Done }.
function Kit.loadDishwasher(ctx: any, plan: any, dw: any, stack: string?): { [string]: number }
	local s = plan.Actor.S
	local beats = {}
	local right = dw.Base.RightVector
	local out = dw.Base.LookVector * -1 -- out of the dishwasher's front (world)
	local function crouch(k: number): any
		return { sit = 0.6 * k, seat = 30, lean = 0.42 * k, head = { pitch = -0.45 * k } }
	end
	local leftHold = if stack then { [stack] = { "L", off = CFrame.new(0, 2, 0) } } else nil
	local function leftArm(b: any): Vector3
		return (b.Torso * CFrame.new(-0.95 * s, -0.25 * s, -0.95 * s)).Position
	end
	-- shift the stack onto the left hand
	local t0 = plan.T
	plan:still(0.35, function(u)
		return { armL = { at = leftArm }, armR = { p = 0.2, r = 0.1, e = 0.5 } }
	end, leftHold)
	-- open the door (the right hand rides the handle down)
	local t = plan.T
	beats.Open = t
	plan:still(1.2, function(u)
		local p = crouch(smooth(u / 0.45))
		p.armR = { at = dw:Handle(t + u) }
		p.armL = { at = leftArm }
		return p
	end, leftHold)
	-- pull the rack out
	local tr = plan.T
	plan:still(0.8, function(u)
		local p = crouch(1)
		p.armR = { at = dw:RackFront(tr + u) }
		p.armL = { at = leftArm }
		return p
	end, leftHold)
	-- lower the dishes into the rack
	local tl = plan.T
	local LOAD = 1.1
	local into = dw:RackFront(tl) - out * 45 + Vector3.new(0, 18, 0) - right * 8
	plan:still(LOAD, function(u)
		local k = u / LOAD
		local p = crouch(1)
		p.armL = { at = function(b)
			return leftArm(b):Lerp(into, math.sin(math.clamp(k / 0.75, 0, 1) * PI * 0.5))
		end }
		p.armR = { p = 0.35, r = 0.12, e = 0.9 }
		return p
	end, leftHold)
	if stack then
		plan:split(plan.Steps[#plan.Steps], LOAD * 0.75, nil)
	end
	beats.Load = tl + LOAD * 0.75
	dw.LoadedAt = beats.Load
	-- push the rack back in
	local tp = plan.T
	plan:still(0.7, function(u)
		local p = crouch(1)
		p.armR = { at = dw:RackFront(tp + u) }
		p.armL = { p = 0.3, r = 0.12, e = 0.8 }
		return p
	end)
	-- close the door
	local tc = plan.T
	beats.Close = tc
	plan:still(1.0, function(u)
		local p = crouch(1 - smooth((u - 0.45) / 0.55))
		p.armR = { at = dw:Handle(tc + u) }
		p.armL = { p = 0.3, r = 0.12, e = 0.8 }
		return p
	end)
	-- press Start
	local tb = plan.T
	beats.Press = tb + 0.5
	plan:still(1.0, function(u)
		local k = math.sin(math.clamp(u / 1.0, 0, 1) * PI)
		return {
			lean = 0.2 * k,
			head = { pitch = -0.4 * k },
			armR = { at = function(b)
				return chestPoint(plan, b):Lerp(dw:Button() - out * 3, k)
			end },
			armL = { p = 0.05, r = 0.08, e = 0.2 },
		}
	end)
	dw.StartAt = beats.Press
	-- step back and aside to admire it (clear of the camera's push-in)
	local aside = ctx:toRoom(dw:Local(-215, 0, 175))
	plan:walk({ Vector2.new(aside.X, aside.Z) }, nil, nil, 120)
	local face = ctx:toRoom(dw:Local(0, 0, 0))
	plan:turn(R.phiOf(face.X - aside.X, face.Z - aside.Z))
	beats.Done = plan.T
	beats.Start = t0
	dw:Keys({
		{ 0, 0, 0 },
		{ beats.Open + 0.1, 0, 0 },
		{ beats.Open + 1.15, 1, 0 },
		{ tr + 0.05, 1, 0 },
		{ tr + 0.75, 1, 1 },
		{ tp + 0.05, 1, 1 },
		{ tp + 0.65, 1, 0 },
		{ tc + 0.1, 1, 0 },
		{ tc + 0.95, 0, 0 },
	})
	return beats
end

-- The shots for the ending, framed on the dishwasher: a side view of the loading, a close-up of
-- the door shutting, a macro of the Start button, and the push-in through the window.
-- `side` = +1 / -1 picks which side the camera stands on.
function Kit.endingShots(ctx: any, dw: any, beats: { [string]: number }, side: number?)
	local sd = side or 1
	local function L(x: number, y: number, z: number): Vector3
		return dw:Local(x * sd, y, z)
	end
	ctx:shot(beats.Open - 0.6, beats.Close, { eye = { L(330, 260, 330), L(290, 220, 280) }, look = { L(0, 120, 60), L(0, 90, 40) }, fov = { 46, 44 } })
	ctx:shot(beats.Close, beats.Press - 0.35, { eye = { L(190, 40, 150), L(170, 46, 130) }, look = { L(0, 80, 0), L(0, 90, 0) }, fov = { 42, 40 } })
	ctx:shot(beats.Press - 0.35, beats.Press + 1.2, { eye = { L(140, 190, 30), L(130, 186, 26) }, look = { L(44, HINGE_Y + DOOR_H - 9, 0), L(44, HINGE_Y + DOOR_H - 9, 0) }, fov = { 32, 28 } })
	ctx.Duration = beats.Press + 3.9 -- the film ends a few seconds into the wash
	local push = beats.Press + 1.2
	ctx:shot(push, ctx.Duration + 0.5, { eye = { L(0, 95, 260), L(0, 84, 8) }, look = { L(0, 84, 0), L(0, 84, -60) }, fov = { 44, 30 }, ease = "in" })
	ctx.BubbleStart = beats.Press + 0.3
end

-- A title card timing helper: chapters say which lines to show.
function Kit.title(ctx: any, chapter: number, name: string)
	ctx.Title = "Chapter " .. chapter
	ctx.Subtitle = name
end

return Kit
