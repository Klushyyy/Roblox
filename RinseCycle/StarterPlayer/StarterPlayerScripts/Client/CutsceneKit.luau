--[[
	CutsceneKit - the toolbox the story chapters (Story) are built with.

	A chapter is a little film staged in the room the level is played in: a cast from LevelNPCs
	(the same rig, looks, props, plans and poses as the people in the rooms), a few extra props,
	subtitles, and a shot list for the camera.

	Coordinates are LevelNPCs' room space: +X right, +Y up, +Z towards the dishwasher (world -Z),
	in studs; a person is 250 tall (S = 50). Heights (h) are above the kitchen floor. Actors face
	`phi` (0 = +Z, pi/2 = +X).

	    local ctx = Kit.new(origin, parent, duration)
	    ctx:box(...), ctx:say(t0, t1, who, text), ctx:shot(t0, t1, { eye = { a, b }, look = { a, b }, fov = { f0, f1 } })
	    -- then ctx:Update(t), ctx:Camera(t), ctx:Line(t) every frame, ctx:Destroy() at the end
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

-- A subtitle: `who` says `text` from t0 to t1 (shown by the cutscene player).
function Ctx:say(t0: number, t1: number, who: string, text: string, color: Color3?)
	self.Lines = self.Lines or {}
	table.insert(self.Lines, { T0 = t0, T1 = t1, Who = who, Text = text, Color = color })
end

-- The subtitle showing at time t, if any.
function Ctx:Line(t: number): any
	for _, l in self.Lines or {} do
		if t >= l.T0 and t < l.T1 then
			return l
		end
	end
	return nil
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
-- Set dressing
----------------------------------------------------------------------------------------------------

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

-- A title card timing helper: chapters say which lines to show.
function Kit.title(ctx: any, chapter: number, name: string)
	ctx.Title = "Chapter " .. chapter
	ctx.Subtitle = name
end

return Kit
