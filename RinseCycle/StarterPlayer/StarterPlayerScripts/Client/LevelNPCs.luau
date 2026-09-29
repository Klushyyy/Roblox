--[[
	LevelNPCs - the people from the cutscenes, living in the room around the dishwasher during a run.

	They're giants (you're dish-sized): classic R6 blocky figures at 50x scale, the same scale the
	room's furniture was built at, so a chair seat, a table top and a counter are exactly where their
	legs, hands and elbows expect them. Each level has its own cast and routines:

	  1 Family Dinner - Dad, Mum, the kid and Grandpa at the family table. Mum clears the plates,
	    washes them at the sink next to you and brings them back; the kid fetches a juice from the
	    fridge; Grandpa reads the paper, sips tea and nods off.
	  2 Pizza Party   - the chef slides a pizza into the brick oven, pulls it out and serves it; the
	    guests grab slices as he puts it down; the waiter sweeps, takes orders and brings drinks.
	  3 Royal Banquet - the king on his throne, the queen and nobles feasting and toasting, a
	    servant carrying the roast from the fire, a juggling jester who does cartwheels and guards
	    on duty.

	Everything is a pure function of time: the routines loop (every level has one loop length and
	every character's plan fills it exactly), and the loop clock is the server's clock, so everyone
	in a party sees the same thing at the same moment. Parts are client-only, anchored and
	non-colliding, and moved with one BulkMoveTo per frame.

	The rig: arms and legs are split at the elbow and knee (with a hidden joint block), so standing
	they look like one R6 limb, but they can sit on a chair with their feet down and lift a fork to
	their mouth. Arms can be posed directly (pitch / roll / elbow) or by where the hand should be
	(simple two-bone IK).

	Scene.Build(levelIndex, roomOrigin, parent) -> scene; scene:Update(t); scene:Destroy().
	LevelNPCs.Init() runs them for the local player's run.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LevelNPCs = {}

local S = 50 -- studs per rig unit (a 5-unit person is 250 studs tall)
local FLOOR = -24 -- the kitchen floor, in room space (matches ArenaBuilder)
local PI = math.pi

local SKIN = Color3.fromRGB(245, 205, 150)
local WHITE = Color3.fromRGB(250, 250, 248)
local INK = Color3.fromRGB(34, 34, 40)

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

local function lerp(a: number, b: number, k: number): number
	return a + (b - a) * k
end

local function angleDiff(a: number, b: number): number
	local d = (b - a) % (2 * PI)
	if d > PI then
		d -= 2 * PI
	end
	return d
end

-- Room space (ArenaBuilder's): +X right, +Z into the dishwasher, which is the arena's LookVector
-- (world -Z). W(x, y, z) is a room point as an arena-local CFrame; rootCF is a character standing at
-- room (x, z) facing phi (0 faces room +Z, i.e. towards the dishwasher; pi/2 faces +X).
local function W(x: number, y: number, z: number): CFrame
	return CFrame.new(x, y, -z)
end

local function rootCF(x: number, z: number, phi: number): CFrame
	return CFrame.new(x, FLOOR, -z) * CFrame.Angles(0, -phi, 0)
end

local function phiOf(dx: number, dz: number): number
	return math.atan2(dx, dz)
end

----------------------------------------------------------------------------------------------------
-- Parts
----------------------------------------------------------------------------------------------------

type Piece = { Part: BasePart, Bone: string, Offset: CFrame, Base: Vector3, Look: number }

local function newPart(name: string, size: Vector3, color: Color3, material: Enum.Material?, shape: string?): BasePart
	local p: BasePart
	if shape == "Wedge" then
		p = Instance.new("WedgePart")
	else
		local part = Instance.new("Part")
		if shape == "Ball" then
			part.Shape = Enum.PartType.Ball
		elseif shape == "Cylinder" then
			part.Shape = Enum.PartType.Cylinder
		end
		p = part
	end
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape == "Sphere" or shape == "Head" then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = if shape == "Head" then Enum.MeshType.Head else Enum.MeshType.Sphere
		if shape == "Head" then
			mesh.Scale = Vector3.new(1.25, 1.25, 1.25)
		end
		mesh.Parent = p
	end
	return p
end

----------------------------------------------------------------------------------------------------
-- Actors
----------------------------------------------------------------------------------------------------

type Look = { [string]: any }
type Pose = { [string]: any }

local Actor = {}
Actor.__index = Actor

-- piece(bone, size (rig units), offset (rig units, bone space), colour, material?, shape?)
function Actor:piece(bone: string, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material?, shape: string?): BasePart
	local s = self.S
	local p = newPart(self.Name .. bone, size * s, color, material, shape)
	p.Parent = self.Folder
	table.insert(self.Pieces, { Part = p, Bone = bone, Offset = CFrame.new(offset.Position * s) * offset.Rotation })
	return p
end

local function buildActor(name: string, look: Look, folder: Instance): any
	local self = setmetatable({}, Actor)
	self.Name = name
	self.S = S * (look.Scale or 1)
	self.Pieces = {} :: { any }
	self.Folder = folder
	self.Look = look
	local skin = look.Skin or SKIN
	local shirt = look.Shirt
	local sleeve = look.Sleeve or shirt
	local fore = if look.Sleeves == "short" then skin else sleeve
	local pants = look.Pants
	local shoes = look.Shoes or rgb(40, 34, 30)
	local I = CFrame.identity

	self:piece("Torso", Vector3.new(2, 2, 1), I, shirt, look.ShirtMat)
	local head = self:piece("Head", Vector3.new(2, 1, 1), I, skin, nil, "Head")
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Face = Enum.NormalId.Front
	face.Texture = "rbxasset://textures/face.png"
	face.Parent = head
	for _, side in { "L", "R" } do
		self:piece("Arm" .. side, Vector3.new(1, 1, 1), I, sleeve, look.ShirtMat)
		self:piece("Fore" .. side, Vector3.new(0.98, 0.96, 0.98), CFrame.new(0, -0.42, 0), fore, if fore == skin then nil else look.ShirtMat)
		self:piece("Fore" .. side, Vector3.new(0.94, 0.94, 0.94), I, sleeve, look.ShirtMat) -- elbow joint block
		self:piece("Fore" .. side, Vector3.new(1, 0.14, 1), CFrame.new(0, -0.93, 0), skin)
		self:piece("Thigh" .. side, Vector3.new(0.96, 1, 0.96), CFrame.new(0, -0.5, 0), pants, look.PantsMat)
		self:piece("Shin" .. side, Vector3.new(0.94, 0.94, 0.94), I, pants, look.PantsMat) -- knee joint block
		self:piece("Shin" .. side, Vector3.new(0.96, 0.78, 0.96), CFrame.new(0, -0.37, 0), pants, look.PantsMat)
		self:piece("Shin" .. side, Vector3.new(1, 0.24, 1.18), CFrame.new(0, -0.88, -0.09), shoes)
	end
	if look.Build then
		look.Build(self)
	end
	return self
end

-- Two-bone arm: shoulder pivot -> elbow (0.5) -> grip (1.0). Returns upper and forearm frames.
local UPPER, LOWER = 0.5, 1.0

local function armFK(pivot: CFrame, s: number, side: number, a: any): (CFrame, CFrame)
	local upper = pivot * CFrame.Angles(a.p or 0, (a.y or 0) * side, (a.r or 0) * side)
	local elbow = upper * CFrame.new(0, -UPPER * s, 0) * CFrame.Angles(a.e or 0, 0, 0)
	return upper, elbow
end

-- The hand's grip point goes to `target` (world); the elbow bends away from `pole`.
local function armIK(pivot: CFrame, s: number, target: Vector3, pole: Vector3): (CFrame, CFrame)
	local origin = pivot.Position
	local v = target - origin
	local a, b = UPPER * s, LOWER * s
	local d = math.clamp(v.Magnitude, math.abs(b - a) + 0.01 * s, (a + b) - 0.001 * s)
	local u = if v.Magnitude > 1e-6 then v.Unit else -pivot.UpVector
	local w = pole - u * pole:Dot(u)
	if w.Magnitude < 1e-4 then
		w = pivot.LookVector - u * pivot.LookVector:Dot(u)
	end
	w = w.Unit
	local cosA = math.clamp((a * a + d * d - b * b) / (2 * a * d), -1, 1)
	local sinA = math.sqrt(1 - cosA * cosA)
	local elbowPos = origin + (u * cosA + w * sinA) * a
	local grip = origin + u * d
	local du = (elbowPos - origin).Unit
	local df = (grip - elbowPos).Unit
	local n = u:Cross(w)
	if n.Magnitude < 1e-4 then
		n = pivot.RightVector
	end
	n = n.Unit
	-- Limb cross-sections stay square to the body (no roll about the bone), like a normal R6 limb.
	local function frame(pos: Vector3, dir: Vector3): CFrame
		local y = -dir
		local r = pivot.RightVector
		local x = (r - y * r:Dot(y))
		if x.Magnitude < 0.2 then
			x = (n - y * n:Dot(y))
		end
		x = x.Unit
		return CFrame.fromMatrix(pos, x, y)
	end
	return frame(origin, du), frame(elbowPos, df)
end

-- Poses the rig. root: feet on the floor, facing. Returns bone frames (world).
--   sit (0..1), seat (seat top above the floor, studs), lean, twist, bob (units), body (extra CFrame
--   at the hips, e.g. a cartwheel), head = { yaw, pitch, roll }, walk = phase, stride (0..1),
--   armL / armR = { p, r, y, e } (forward, out, twist, elbow) or { at = world point, pole = vector },
--   legs = { hipL, hipR, kneeL, kneeR } overrides.
function Actor:Pose(root: CFrame, pose: Pose): { [string]: CFrame }
	local s = self.S
	local sit = pose.sit or 0
	local seatUnits = (pose.seat or 0) / s
	local pelvisY = lerp(2, seatUnits + 0.37, sit) + (pose.bob or 0)
	local pelvis = root * CFrame.new(0, pelvisY * s, 0)
	if pose.body then
		pelvis = pelvis * pose.body
	end
	local hips = pelvis
	pelvis = pelvis * CFrame.Angles(-(pose.lean or 0), pose.twist or 0, pose.tilt or 0)
	local torso = pelvis * CFrame.new(0, s, 0)
	local bones: { [string]: CFrame } = { Torso = torso, Root = root, Pelvis = pelvis }
	local h = pose.head or {}
	local neck = torso * CFrame.new(0, s, 0) * CFrame.Angles(0, h.yaw or 0, 0) * CFrame.Angles(h.pitch or 0, 0, h.roll or 0)
	bones.Head = neck * CFrame.new(0, 0.5 * s, 0)

	-- Legs
	local walk = pose.walk
	local stride = pose.stride or 1
	local legs = pose.legs or {}
	for side, name in { [-1] = "L", [1] = "R" } do
		local swing, knee = 0, 0
		if walk then
			local ph = walk + (if side > 0 then PI else 0)
			swing = math.sin(ph) * 0.5 * stride
			knee = -math.max(0, math.cos(ph)) * 0.75 * stride
		end
		local hipA = lerp(swing, PI / 2, sit)
		local kneeA = lerp(knee, self.Look.SitKnee or (-PI / 2 + 0.2), sit)
		hipA = legs["hip" .. name] or hipA
		kneeA = legs["knee" .. name] or kneeA
		local out = legs["out" .. name] or ((self.Look.SitOut or 0) * sit)
		local hip = hips * CFrame.new(side * 0.5 * s, 0, 0) * CFrame.Angles(hipA, 0, out * side)
		bones["Thigh" .. name] = hip
		bones["Shin" .. name] = hip * CFrame.new(0, -s, 0) * CFrame.Angles(kneeA, 0, 0)
	end

	-- Arms
	for side, name in { [-1] = "L", [1] = "R" } do
		local pivot = torso * CFrame.new(side * 1.5 * s, 0.5 * s, 0)
		local a = pose["arm" .. name]
		local upper, elbow
		if a and a.at then
			local pole = a.pole or (pivot.RightVector * side * 0.25 - pivot.UpVector * 0.3 - pivot.LookVector * 0.8)
			local target = if type(a.at) == "function" then a.at(bones) else a.at
			upper, elbow = armIK(pivot, s, target, pole)
		else
			a = a or {}
			if walk and a.p == nil then
				local swing = -math.sin(walk + (if side > 0 then PI else 0)) * 0.45 * stride
				a = { p = swing, r = a.r or 0.04, e = a.e or (0.25 + math.max(0, swing) * 0.5) }
			elseif a.p == nil and a.e == nil and a.r == nil then
				a = { p = 0.02, r = 0.05, e = 0.12 }
			end
			upper, elbow = armFK(pivot, s, side, a)
		end
		bones["Arm" .. name] = upper
		bones["Fore" .. name] = elbow
		bones["Grip" .. name] = elbow * CFrame.new(0, -LOWER * s, 0)
	end
	self.Bones = bones
	return bones
end

-- Writes every piece's CFrame into the batch lists.
function Actor:Emit(parts: { BasePart }, cframes: { CFrame })
	local bones = self.Bones
	for _, pc in self.Pieces do
		local b = bones[pc.Bone]
		if b then
			table.insert(parts, pc.Part)
			table.insert(cframes, b * pc.Offset)
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Looks: hair, hats and outfits (all built with Actor:piece on the head / torso bones)
----------------------------------------------------------------------------------------------------

-- Hair is built like classic block hair: a crown slab the same shape as the (round) head, a
-- softened top, a back piece, a fringe and sideburns: clean edges, nothing mushroom-shaped.
local function hairCap(a: any, color: Color3)
	a:piece("Head", Vector3.new(0.4, 1.36, 1.36), CFrame.new(0, 0.49, 0.02) * CFrame.Angles(0, 0, PI / 2), color, nil, "Cylinder")
	a:piece("Head", Vector3.new(1.26, 0.2, 1.26), CFrame.new(0, 0.69, 0.02), color, nil, "Sphere")
	a:piece("Head", Vector3.new(1.3, 0.86, 0.3), CFrame.new(0, 0.12, 0.58), color)
	for _, sd in { -1, 1 } do
		a:piece("Head", Vector3.new(0.1, 0.34, 0.26), CFrame.new(sd * 0.64, 0.1, -0.1), color)
	end
end

local function hairShort(color: Color3)
	return function(a: any)
		hairCap(a, color)
		a:piece("Head", Vector3.new(1.1, 0.16, 0.12), CFrame.new(0, 0.34, -0.61), color)
	end
end

local function hairLong(color: Color3)
	return function(a: any)
		hairCap(a, color)
		a:piece("Head", Vector3.new(0.54, 0.2, 0.12), CFrame.new(-0.3, 0.33, -0.61) * CFrame.Angles(0, 0, 0.18), color)
		a:piece("Head", Vector3.new(0.54, 0.2, 0.12), CFrame.new(0.3, 0.33, -0.61) * CFrame.Angles(0, 0, -0.18), color)
		a:piece("Head", Vector3.new(1.34, 1.2, 0.3), CFrame.new(0, -0.22, 0.6), color)
		for _, sd in { -1, 1 } do
			a:piece("Head", Vector3.new(0.14, 1.0, 0.56), CFrame.new(sd * 0.66, -0.16, 0.22), color)
		end
	end
end

local function partyHat(a: any, c1: Color3, c2: Color3)
	for i = 0, 3 do
		local r = 0.5 - i * 0.12
		a:piece("Head", Vector3.new(0.26, r * 2, r * 2), CFrame.new(0, 0.72 + i * 0.24, 0) * CFrame.Angles(0, 0, PI / 2), if i % 2 == 0 then c1 else c2, nil, "Cylinder")
	end
	a:piece("Head", Vector3.new(0.22, 0.22, 0.22), CFrame.new(0, 1.66, 0), rgb(255, 230, 90), nil, "Ball")
end

local function crown(a: any, gem: Color3, small: boolean?)
	local k = if small then 0.8 else 1
	local gold = rgb(240, 196, 70)
	a:piece("Head", Vector3.new(0.32, 1.36 * k, 1.36 * k), CFrame.new(0, 0.74, 0) * CFrame.Angles(0, 0, PI / 2), gold, Enum.Material.Metal, "Cylinder")
	for i = 0, 5 do
		local ang = i / 6 * PI * 2
		a:piece("Head", Vector3.new(0.22, 0.36, 0.22) * k, CFrame.new(math.cos(ang) * 0.58 * k, 1.02, math.sin(ang) * 0.58 * k) * CFrame.Angles(0, -ang, 0), gold, Enum.Material.Metal)
		a:piece("Head", Vector3.new(0.16, 0.16, 0.16) * k, CFrame.new(math.cos(ang) * 0.58 * k, 1.24, math.sin(ang) * 0.58 * k), gold, Enum.Material.Metal, "Ball")
	end
	a:piece("Head", Vector3.new(0.24, 0.24, 0.1), CFrame.new(0, 0.76, -0.69 * k), gem, Enum.Material.Neon)
end

local function glasses(a: any)
	for _, x in { -0.25, 0.25 } do
		a:piece("Head", Vector3.new(0.34, 0.24, 0.05), CFrame.new(x, 0.1, -0.64), INK)
		a:piece("Head", Vector3.new(0.26, 0.16, 0.02), CFrame.new(x, 0.1, -0.665), rgb(200, 230, 245), Enum.Material.Glass)
	end
	a:piece("Head", Vector3.new(0.18, 0.05, 0.05), CFrame.new(0, 0.14, -0.64), INK)
end

local function beard(a: any, color: Color3)
	a:piece("Head", Vector3.new(1.0, 0.62, 0.34), CFrame.new(0, -0.44, -0.46), color, nil, "Sphere")
	a:piece("Head", Vector3.new(0.6, 0.14, 0.14), CFrame.new(0, -0.14, -0.62), color)
end

local function apron(a: any, color: Color3, strap: Color3?)
	a:piece("Torso", Vector3.new(1.7, 1.45, 0.06), CFrame.new(0, -0.3, -0.53), color, Enum.Material.Fabric)
	a:piece("Torso", Vector3.new(0.9, 0.5, 0.06), CFrame.new(0, 0.62, -0.53), color, Enum.Material.Fabric)
	a:piece("Torso", Vector3.new(2.04, 0.12, 1.04), CFrame.new(0, -0.32, 0), strap or color, Enum.Material.Fabric)
	-- the skirt of the apron, over the thighs
	a:piece("ThighL", Vector3.new(1.0, 0.7, 0.06), CFrame.new(0.4, -0.36, -0.52), color, Enum.Material.Fabric)
	a:piece("ThighR", Vector3.new(1.0, 0.7, 0.06), CFrame.new(-0.4, -0.36, -0.52), color, Enum.Material.Fabric)
end

local function belt(a: any, color: Color3, buckle: Color3?)
	a:piece("Torso", Vector3.new(2.04, 0.2, 1.04), CFrame.new(0, -0.86, 0), color)
	if buckle then
		a:piece("Torso", Vector3.new(0.34, 0.26, 0.06), CFrame.new(0, -0.86, -0.54), buckle, Enum.Material.Metal)
	end
end

local function collar(a: any, color: Color3)
	a:piece("Torso", Vector3.new(0.5, 0.3, 0.06), CFrame.new(-0.22, 0.86, -0.53) * CFrame.Angles(0, 0, -0.5), color)
	a:piece("Torso", Vector3.new(0.5, 0.3, 0.06), CFrame.new(0.22, 0.86, -0.53) * CFrame.Angles(0, 0, 0.5), color)
end

local LOOKS: { [string]: Look } = {}

LOOKS.Dad = {
	Shirt = rgb(70, 110, 190), Pants = rgb(60, 60, 80),
	Build = function(a)
		hairShort(rgb(92, 60, 36))(a)
		collar(a, rgb(90, 132, 210))
		belt(a, rgb(60, 40, 30), rgb(200, 200, 210))
	end,
}
LOOKS.Mum = {
	Shirt = rgb(220, 90, 110), Pants = rgb(70, 70, 90), Sleeves = "short",
	Build = function(a)
		hairLong(rgb(150, 86, 40))(a)
		apron(a, rgb(250, 240, 220), rgb(236, 220, 196))
	end,
}
LOOKS.Kid = {
	Shirt = rgb(110, 190, 110), Pants = rgb(90, 70, 60), Sleeves = "short", Scale = 0.72, Shoes = rgb(220, 60, 60), SitKnee = -0.25, SitOut = -0.12,
	Build = function(a)
		hairShort(rgb(240, 200, 90))(a)
		a:piece("Torso", Vector3.new(2.02, 0.3, 1.02), CFrame.new(0, 0.2, 0), rgb(250, 250, 250))
	end,
}
LOOKS.Grandpa = {
	Shirt = rgb(150, 110, 80), Sleeve = rgb(150, 110, 80), Pants = rgb(200, 190, 160), ShirtMat = Enum.Material.Fabric,
	Build = function(a)
		a:piece("Head", Vector3.new(1.36, 0.5, 1.32), CFrame.new(0, 0.2, 0.12), rgb(225, 225, 225), nil, "Sphere")
		glasses(a)
		a:piece("Head", Vector3.new(0.56, 0.14, 0.14), CFrame.new(0, -0.14, -0.62), rgb(225, 225, 225))
		a:piece("Torso", Vector3.new(0.7, 1.8, 0.04), CFrame.new(0, 0, -0.51), rgb(236, 230, 214))
		for i = 0, 3 do
			a:piece("Torso", Vector3.new(0.1, 0.1, 0.04), CFrame.new(0.42, 0.6 - i * 0.4, -0.52), rgb(90, 60, 40), nil, "Ball")
		end
	end,
}
LOOKS.Chef = {
	Shirt = rgb(246, 246, 244), Pants = rgb(40, 40, 46), ShirtMat = Enum.Material.Fabric,
	Build = function(a)
		hairShort(rgb(60, 40, 30))(a)
		-- moustache
		a:piece("Head", Vector3.new(0.7, 0.16, 0.16), CFrame.new(0, -0.16, -0.62), rgb(60, 40, 30), nil, "Sphere")
		-- toque
		a:piece("Head", Vector3.new(0.9, 1.3, 1.3), CFrame.new(0, 0.95, 0) * CFrame.Angles(0, 0, PI / 2), WHITE, Enum.Material.Fabric, "Cylinder")
		a:piece("Head", Vector3.new(1.6, 0.8, 1.6), CFrame.new(0, 1.45, 0), WHITE, Enum.Material.Fabric, "Sphere")
		a:piece("Head", Vector3.new(0.2, 1.34, 1.34), CFrame.new(0, 0.42, 0) * CFrame.Angles(0, 0, PI / 2), rgb(230, 230, 228), Enum.Material.Fabric, "Cylinder")
		-- red neckerchief and double-breasted buttons
		a:piece("Torso", Vector3.new(0.9, 0.3, 0.08), CFrame.new(0, 0.84, -0.53), rgb(210, 40, 40), Enum.Material.Fabric)
		a:piece("Torso", Vector3.new(0.34, 0.34, 0.08), CFrame.new(0, 0.62, -0.53) * CFrame.Angles(0, 0, PI / 4), rgb(210, 40, 40), Enum.Material.Fabric)
		for _, x in { -0.35, 0.35 } do
			for i = 0, 2 do
				a:piece("Torso", Vector3.new(0.13, 0.13, 0.05), CFrame.new(x, 0.3 - i * 0.36, -0.52), rgb(60, 60, 64), nil, "Ball")
			end
		end
		apron(a, rgb(236, 236, 232), rgb(220, 220, 216))
	end,
}
LOOKS.Waiter = {
	Shirt = rgb(200, 45, 45), Pants = rgb(30, 30, 36), Sleeves = "short",
	Build = function(a)
		hairShort(rgb(30, 24, 20))(a)
		a:piece("Head", Vector3.new(1.4, 0.6, 1.38), CFrame.new(0, 0.44, 0.02), rgb(30, 30, 36), nil, "Sphere")
		a:piece("Head", Vector3.new(0.9, 0.08, 0.6), CFrame.new(0, 0.3, -0.8), rgb(30, 30, 36))
		collar(a, rgb(240, 240, 240))
		a:piece("Torso", Vector3.new(1.7, 1.1, 0.06), CFrame.new(0, -0.45, -0.53), rgb(30, 30, 36), Enum.Material.Fabric)
		a:piece("ThighL", Vector3.new(1.0, 0.6, 0.06), CFrame.new(0.4, -0.3, -0.52), rgb(30, 30, 36), Enum.Material.Fabric)
		a:piece("ThighR", Vector3.new(1.0, 0.6, 0.06), CFrame.new(-0.4, -0.3, -0.52), rgb(30, 30, 36), Enum.Material.Fabric)
	end,
}
local function guest(shirt: Color3, pants: Color3, hair: Color3, long: boolean, hat1: Color3, hat2: Color3, scale: number?): Look
	return {
		Shirt = shirt, Pants = pants, Sleeves = "short", Scale = scale,
		Build = function(a)
			if long then
				hairLong(hair)(a)
			else
				hairShort(hair)(a)
			end
			partyHat(a, hat1, hat2)
		end,
	}
end
LOOKS.Guest1 = guest(rgb(255, 160, 40), rgb(50, 60, 90), rgb(40, 30, 24), false, rgb(255, 90, 160), rgb(90, 200, 255))
LOOKS.Guest2 = guest(rgb(120, 90, 220), rgb(60, 60, 60), rgb(200, 120, 60), true, rgb(90, 220, 140), rgb(255, 220, 80))
LOOKS.Guest3 = guest(rgb(40, 180, 200), rgb(80, 60, 100), rgb(240, 200, 90), false, rgb(255, 120, 60), rgb(160, 110, 255), 0.72)
LOOKS.King = {
	Shirt = rgb(150, 26, 40), Pants = rgb(230, 190, 90), ShirtMat = Enum.Material.Fabric,
	Build = function(a)
		hairShort(rgb(235, 235, 235))(a)
		beard(a, rgb(240, 240, 240))
		crown(a, rgb(220, 40, 60))
		belt(a, rgb(230, 190, 90), rgb(255, 230, 120))
		-- cape with an ermine collar
		a:piece("Torso", Vector3.new(2.2, 2.6, 0.14), CFrame.new(0, -0.35, 0.58), rgb(170, 30, 44), Enum.Material.Fabric)
		a:piece("Torso", Vector3.new(2.3, 0.36, 1.2), CFrame.new(0, 0.92, 0.04), rgb(248, 248, 244), Enum.Material.Fabric)
		for i = 0, 3 do
			a:piece("Torso", Vector3.new(0.1, 0.16, 0.04), CFrame.new(-0.9 + i * 0.6, 0.9, -0.57), INK)
		end
		a:piece("Torso", Vector3.new(0.12, 1.7, 0.06), CFrame.new(0, -0.05, -0.53), rgb(230, 190, 90), Enum.Material.Metal)
	end,
}
LOOKS.Queen = {
	Shirt = rgb(110, 50, 160), Pants = rgb(110, 50, 160), ShirtMat = Enum.Material.Fabric, PantsMat = Enum.Material.Fabric,
	Build = function(a)
		hairLong(rgb(90, 50, 30))(a)
		crown(a, rgb(60, 140, 255), true)
		a:piece("Torso", Vector3.new(2.04, 0.3, 1.04), CFrame.new(0, 0.2, 0), rgb(230, 190, 90), Enum.Material.Metal)
		a:piece("Torso", Vector3.new(0.6, 0.22, 0.06), CFrame.new(0, 0.7, -0.53), rgb(250, 250, 250), Enum.Material.Fabric)
		-- the skirt of the gown over the thighs
		a:piece("ThighL", Vector3.new(1.08, 1.06, 1.08), CFrame.new(0, -0.5, 0), rgb(96, 40, 144), Enum.Material.Fabric)
		a:piece("ThighR", Vector3.new(1.08, 1.06, 1.08), CFrame.new(0, -0.5, 0), rgb(96, 40, 144), Enum.Material.Fabric)
	end,
}
local function noble(shirt: Color3, pants: Color3, hair: Color3, long: boolean, trim: Color3): Look
	return {
		Shirt = shirt, Pants = pants, ShirtMat = Enum.Material.Fabric,
		Build = function(a)
			if long then
				hairLong(hair)(a)
			else
				hairShort(hair)(a)
			end
			belt(a, trim, trim)
			a:piece("Torso", Vector3.new(2.06, 0.18, 1.06), CFrame.new(0, 0.9, 0), trim, Enum.Material.Metal)
			a:piece("Torso", Vector3.new(0.14, 1.6, 0.05), CFrame.new(0, 0, -0.53), trim, Enum.Material.Metal)
		end,
	}
end
LOOKS.Noble1 = noble(rgb(30, 100, 70), rgb(40, 30, 60), rgb(60, 40, 30), false, rgb(230, 190, 90))
LOOKS.Noble2 = noble(rgb(70, 40, 140), rgb(50, 40, 30), rgb(230, 190, 120), true, rgb(210, 210, 220))
LOOKS.Servant = {
	Shirt = rgb(60, 110, 60), Pants = rgb(90, 70, 50), ShirtMat = Enum.Material.Fabric, Sleeves = "short",
	Build = function(a)
		hairShort(rgb(110, 70, 40))(a)
		belt(a, rgb(90, 60, 30))
		a:piece("Torso", Vector3.new(1.5, 1.3, 0.06), CFrame.new(0, -0.35, -0.53), rgb(236, 228, 208), Enum.Material.Fabric)
	end,
}
LOOKS.Guard = {
	Shirt = rgb(150, 26, 40), Pants = rgb(60, 60, 70), ShirtMat = Enum.Material.Fabric, Sleeve = rgb(170, 175, 185),
	Build = function(a)
		local steel = rgb(185, 190, 200)
		a:piece("Head", Vector3.new(1.46, 1.0, 1.46), CFrame.new(0, 0.3, 0.02), steel, Enum.Material.Metal, "Sphere")
		a:piece("Head", Vector3.new(1.46, 0.14, 1.46), CFrame.new(0, 0.14, 0) * CFrame.Angles(0, 0, PI / 2), steel, Enum.Material.Metal, "Cylinder")
		a:piece("Head", Vector3.new(0.12, 0.5, 0.12), CFrame.new(0, 0.05, -0.72), steel, Enum.Material.Metal)
		a:piece("Head", Vector3.new(0.2, 0.6, 0.9), CFrame.new(0, 0.95, 0.1), rgb(200, 30, 40), Enum.Material.Fabric, "Sphere")
		a:piece("Torso", Vector3.new(2.06, 1.5, 1.08), CFrame.new(0, 0.26, 0), steel, Enum.Material.Metal)
		a:piece("Torso", Vector3.new(1.0, 1.0, 0.06), CFrame.new(0, 0.2, -0.56), rgb(230, 190, 90), Enum.Material.Metal)
		for _, x in { -1.25, 1.25 } do
			a:piece("Torso", Vector3.new(0.9, 0.4, 1.12), CFrame.new(x, 0.9, 0), steel, Enum.Material.Metal)
		end
		belt(a, rgb(60, 40, 30), rgb(230, 190, 90))
	end,
}
LOOKS.Jester = {
	Shirt = rgb(220, 40, 60), Pants = rgb(250, 200, 40), Sleeve = rgb(250, 200, 40), ShirtMat = Enum.Material.Fabric,
	Build = function(a)
		a:piece("Torso", Vector3.new(1.02, 2.02, 1.02), CFrame.new(0.5, 0, 0), rgb(250, 200, 40), Enum.Material.Fabric)
		a:piece("ThighR", Vector3.new(1.0, 1.02, 1.0), CFrame.new(0, -0.5, 0), rgb(220, 40, 60), Enum.Material.Fabric)
		a:piece("ArmL", Vector3.new(1.02, 1.02, 1.02), CFrame.identity, rgb(220, 40, 60), Enum.Material.Fabric)
		-- zig-zag collar
		for i = -2, 2 do
			a:piece("Torso", Vector3.new(0.36, 0.36, 1.1), CFrame.new(i * 0.4, 0.95, 0) * CFrame.Angles(0, 0, PI / 4), if i % 2 == 0 then rgb(250, 200, 40) else rgb(220, 40, 60), Enum.Material.Fabric)
		end
		-- the hat: a cap with two floppy points and bells
		a:piece("Head", Vector3.new(1.4, 0.6, 1.36), CFrame.new(0, 0.4, 0.02), rgb(220, 40, 60), Enum.Material.Fabric, "Sphere")
		for _, sd in { -1, 1 } do
			a:piece("Head", Vector3.new(0.32, 1.2, 0.32), CFrame.new(sd * 0.72, 0.8, 0.05) * CFrame.Angles(0, 0, -sd * 0.9), if sd < 0 then rgb(250, 200, 40) else rgb(220, 40, 60), Enum.Material.Fabric)
			a:piece("Head", Vector3.new(0.3, 0.3, 0.3), CFrame.new(sd * 1.22, 1.1, 0.05), rgb(250, 220, 90), Enum.Material.Metal, "Ball")
		end
	end,
}

----------------------------------------------------------------------------------------------------
-- Props: small part groups that are held, placed or hidden
----------------------------------------------------------------------------------------------------

type PropDef = { [number]: any }

local Prop = {}
Prop.__index = Prop

local function buildProp(name: string, defs: { any }, folder: Instance): any
	local self = setmetatable({}, Prop)
	self.Name = name
	self.Pieces = {} :: { any }
	for _, d in defs do
		-- { size, offset, colour, material?, shape?, transparency? }
		local p = newPart(name, d[1], d[3], d[4], d[5])
		local look = d[6] or 0
		p.Transparency = 1
		p.Parent = folder
		table.insert(self.Pieces, { Part = p, Offset = d[2], Base = d[1], Look = look })
	end
	self.Visible = false
	self.Scale = 1
	return self
end

function Prop:SetVisible(v: boolean)
	if self.Visible == v then
		return
	end
	self.Visible = v
	for _, pc in self.Pieces do
		pc.Part.Transparency = if v then pc.Look else 1
	end
end

function Prop:SetScale(k: number)
	if math.abs(self.Scale - k) < 0.01 then
		return
	end
	self.Scale = k
	for _, pc in self.Pieces do
		pc.Part.Size = Vector3.new(pc.Base.X, pc.Base.Y, math.max(0.2, pc.Base.Z * k))
	end
end

function Prop:Emit(cf: CFrame, parts: { BasePart }, cframes: { CFrame })
	local k = self.Scale
	for _, pc in self.Pieces do
		table.insert(parts, pc.Part)
		local o = pc.Offset
		if k ~= 1 then
			o = CFrame.new(o.X, o.Y, o.Z * k) * o.Rotation
		end
		table.insert(cframes, cf * o)
	end
end

local V = Vector3.new
local C = CFrame.new
local ROT90Z = CFrame.Angles(0, 0, PI / 2)

-- Upright cylinder (axis Y) helper for prop defs.
local function disc(d: number, h: number, y: number, color: Color3, material: Enum.Material?, x: number?, z: number?): any
	return { V(h, d, d), C(x or 0, y, z or 0) * ROT90Z, color, material, "Cylinder" }
end

local PROPS: { [string]: () -> { any } } = {}

-- Furniture for the NPCs (placed at a character's root: forward is -Z, the back is +Z).
local function chairDefs(color: Color3, top: number, cushion: Color3?, tall: boolean?): { any }
	local t = {
		{ V(80, 8, 70), C(0, top - 4, 0), color, Enum.Material.Wood },
		{ V(80, if tall then 150 else 102, 6), C(0, top + (if tall then 75 else 51), 33), color, Enum.Material.Wood },
	}
	for _, x in { -34, 34 } do
		for _, z in { -29, 29 } do
			table.insert(t, { V(8, top - 8, 8), C(x, (top - 8) / 2, z), color, Enum.Material.Wood })
		end
	end
	if cushion then
		table.insert(t, { V(72, 6, 62), C(0, top + 3, -2), cushion, Enum.Material.Fabric })
		table.insert(t, { V(70, 80, 5), C(0, top + 60, 29), cushion, Enum.Material.Fabric })
	end
	return t
end
PROPS.FurnChair = function()
	return chairDefs(rgb(122, 82, 52), 98)
end
PROPS.FurnKidChair = function()
	local t = chairDefs(rgb(122, 82, 52), 98)
	table.insert(t, { V(70, 10, 60), C(0, 103, 0), rgb(230, 80, 80), Enum.Material.Fabric })
	return t
end
PROPS.FurnHighChair = function()
	return chairDefs(rgb(90, 58, 36), 92, rgb(70, 120, 90), true)
end
PROPS.FurnThrone = function()
	local gold = rgb(230, 190, 90)
	local t = chairDefs(rgb(110, 70, 40), 98, rgb(160, 26, 40), true)
	-- a gold frame and crown points on the tall back
	table.insert(t, { V(90, 8, 10), C(0, 98 + 150, 33), gold, Enum.Material.Metal })
	for _, x in { -36, 0, 36 } do
		table.insert(t, { V(12, 12, 8), C(x, 98 + 160, 33) * CFrame.Angles(0, 0, PI / 4), gold, Enum.Material.Metal })
	end
	for _, x in { -44, 44 } do
		table.insert(t, { V(8, 150, 10), C(x, 98 + 75, 33), gold, Enum.Material.Metal })
	end
	return t
end
PROPS.FurnSideTable = function()
	return {
		disc(56, 4, 126, rgb(110, 72, 44), Enum.Material.Wood),
		disc(10, 120, 64, rgb(90, 58, 36), Enum.Material.Wood),
		disc(40, 6, 3, rgb(90, 58, 36), Enum.Material.Wood),
	}
end

PROPS.FurnStool = function()
	return {
		disc(46, 8, 90, rgb(205, 45, 40)),
		disc(8, 84, 44, rgb(40, 40, 44), Enum.Material.Metal),
		disc(50, 4, 2, rgb(40, 40, 44), Enum.Material.Metal),
	}
end

PROPS.Plate = function()
	return {
		disc(46, 2, 1, WHITE),
		disc(36, 2.2, 1.2, rgb(235, 238, 242)),
	}
end
PROPS.Spaghetti = function()
	local t = PROPS.Plate()
	table.insert(t, { V(28, 9, 24), C(0, 5, 0), rgb(246, 214, 120), nil, "Sphere" })
	table.insert(t, { V(16, 5, 14), C(0, 9, 0), rgb(200, 50, 36), nil, "Sphere" })
	for i = 0, 2 do
		local a = i / 3 * PI * 2
		table.insert(t, { V(7, 7, 7), C(math.cos(a) * 6, 10, math.sin(a) * 6), rgb(120, 66, 40), nil, "Ball" })
	end
	return t
end
PROPS.PlateStack = function()
	local t = {}
	for i = 0, 3 do
		table.insert(t, disc(46, 2, 1 + i * 3.2, WHITE))
		table.insert(t, { V(10, 1, 8), C(-6 + i * 3, 2.3 + i * 3.2, 4 - i * 2), rgb(200, 60, 40), nil, "Sphere" })
	end
	return t
end
PROPS.CleanStack = function()
	local t = {}
	for i = 0, 3 do
		table.insert(t, disc(46, 2, 1 + i * 3.2, WHITE))
		table.insert(t, disc(40, 2.2, 1.2 + i * 3.2, rgb(160, 200, 240)))
	end
	return t
end
PROPS.WashPlate = function()
	return { { V(2, 44, 44), C(0, 0, 0) * ROT90Z, WHITE, nil, "Cylinder" } }
end
PROPS.Fork = function()
	return {
		{ V(2, 2, 22), C(0, 0, -6), rgb(200, 204, 210), Enum.Material.Metal },
		{ V(5, 1.4, 6), C(0, 0, -19), rgb(200, 204, 210), Enum.Material.Metal },
	}
end
PROPS.Glass = function()
	return {
		{ V(14, 20, 14), C(0, 8, 0), rgb(210, 235, 250), Enum.Material.Glass, "Cylinder", 0.35 },
		{ V(12, 12, 12), C(0, 5, 0), rgb(240, 150, 60), nil, "Cylinder" },
	}
end
PROPS.Juice = function()
	return {
		{ V(12, 18, 8), C(0, 7, 0), rgb(255, 170, 40) },
		{ V(12.2, 5, 8.2), C(0, 9, 0), rgb(80, 180, 80) },
		{ V(1.2, 7, 1.2), C(3, 19, 0) * CFrame.Angles(0, 0, 0.3), WHITE },
	}
end
PROPS.Newspaper = function()
	return {
		{ V(64, 44, 1.2), C(0, 0, 0), rgb(236, 234, 226) },
		{ V(50, 5, 0.4), C(0, 14, -0.8), rgb(40, 40, 44) },
		{ V(22, 16, 0.4), C(-12, -2, -0.8), rgb(150, 150, 156) },
		{ V(22, 3, 0.4), C(14, 0, -0.8), rgb(120, 120, 126) },
		{ V(22, 3, 0.4), C(14, -6, -0.8), rgb(120, 120, 126) },
		{ V(22, 3, 0.4), C(14, -12, -0.8), rgb(120, 120, 126) },
	}
end
PROPS.FlatPaper = function()
	return {
		{ V(44, 1.2, 32), C(0, 0.6, 0), rgb(236, 234, 226) },
		{ V(34, 1.3, 4), C(0, 0.7, -10), rgb(40, 40, 44) },
	}
end
PROPS.TeaCup = function()
	return {
		disc(16, 1.2, 0.6, WHITE),
		disc(10, 9, 5, WHITE),
		disc(8.6, 1, 9.2, rgb(150, 90, 50)),
		{ V(2, 6, 4), C(6, 5, 0), WHITE },
	}
end
-- A pizza served on a round tray, drawn as six slices that can be taken one by one.
PROPS.Tray = function()
	return { disc(76, 2, 1, rgb(190, 195, 200), Enum.Material.Metal) }
end
PROPS.Slice = function()
	-- The crust is at the origin and the tip points along +Z (34 long, 34 wide at the crust), so it
	-- can be held by the crust and shrink from the tip as it's eaten.
	local cheese = rgb(250, 206, 96)
	return {
		{ V(30, 2.4, 11), C(0, 1.2, 6), cheese },
		{ V(20, 2.4, 11), C(0, 1.2, 17), cheese },
		{ V(10, 2.4, 11), C(0, 1.2, 28), cheese },
		{ V(34, 5, 5), C(0, 2.5, 0), rgb(214, 150, 70) },
		{ V(8, 1, 8), C(-5, 2.9, 10), rgb(170, 36, 30), nil, "Cylinder" },
		{ V(7, 1, 7), C(4, 2.9, 20), rgb(170, 36, 30), nil, "Cylinder" },
	}
end
PROPS.Peel = function()
	-- Held by the handle; the blade points forward (-Z).
	return {
		{ V(5, 5, 120), C(0, 0, -30), rgb(170, 120, 70), Enum.Material.Wood },
		{ V(60, 2, 56), C(0, 0, -110), rgb(200, 150, 90), Enum.Material.Wood },
	}
end
PROPS.RawPizza = function()
	return {
		disc(52, 2, 2, rgb(240, 220, 170)),
		disc(44, 2.2, 2.3, rgb(210, 60, 40)),
	}
end
PROPS.HotPizza = function()
	local t = {
		disc(52, 2.4, 2, rgb(214, 150, 70)),
		disc(44, 2.6, 2.4, rgb(250, 206, 96)),
	}
	for i = 0, 5 do
		local a = i / 6 * PI * 2
		table.insert(t, disc(8, 1, 3.4, rgb(170, 36, 30), nil, math.cos(a) * 13, math.sin(a) * 13))
	end
	return t
end
PROPS.Broom = function()
	return {
		{ V(4, 170, 4), C(0, -40, 0), rgb(160, 110, 60), Enum.Material.Wood },
		{ V(46, 10, 12), C(0, -128, 0), rgb(60, 60, 64) },
		{ V(46, 16, 10), C(0, -140, 0), rgb(220, 180, 90), Enum.Material.Fabric },
	}
end
PROPS.Notepad = function()
	return {
		{ V(20, 28, 2), C(0, 0, 0), rgb(250, 250, 240) },
		{ V(20, 4, 2.4), C(0, 13, 0), rgb(200, 45, 45) },
	}
end
PROPS.Pencil = function()
	return { { V(2, 2, 18), C(0, 0, -5), rgb(250, 200, 40) } }
end
PROPS.DrinkTray = function()
	local t = { disc(60, 2, 0, rgb(60, 60, 66), Enum.Material.Metal) }
	for _, x in { -12, 12 } do
		table.insert(t, { V(14, 22, 14), C(x, 12, 0), rgb(220, 60, 50), nil, "Cylinder" })
		table.insert(t, { V(2, 12, 2), C(x + 3, 26, 0), WHITE })
	end
	for i, e in t do
		if e[5] == "Cylinder" and e[1].Y == 22 then
			t[i] = { V(22, 14, 14), C(e[2].X, 12, 0) * ROT90Z, rgb(220, 60, 50), nil, "Cylinder" }
		end
	end
	return t
end
PROPS.Soda = function()
	return {
		{ V(22, 14, 14), C(0, 11, 0) * ROT90Z, rgb(220, 60, 50), nil, "Cylinder" },
		{ V(2, 12, 2), C(3, 25, 0), WHITE },
	}
end
PROPS.Goblet = function()
	return {
		disc(12, 1.4, 0.7, rgb(230, 190, 90), Enum.Material.Metal),
		disc(3, 10, 6, rgb(230, 190, 90), Enum.Material.Metal),
		disc(11, 10, 15, rgb(230, 190, 90), Enum.Material.Metal),
		disc(9.4, 1, 19.6, rgb(120, 20, 40)),
	}
end
PROPS.TurkeyLeg = function()
	return {
		{ V(16, 12, 20), C(0, 0, -12), rgb(176, 100, 44), nil, "Sphere" },
		{ V(4, 4, 14), C(0, 0, 2), rgb(246, 238, 222), nil, "Cylinder" },
	}
end
PROPS.Roast = function()
	local t = {
		disc(70, 2.4, 1.2, rgb(215, 220, 228), Enum.Material.Metal),
		{ V(46, 28, 36), C(0, 15, 0), rgb(176, 104, 48), nil, "Sphere" },
	}
	for _, sd in { -1, 1 } do
		table.insert(t, { V(20, 13, 13), C(sd * 20, 11, -8) * CFrame.Angles(0, sd * 0.5, 0), rgb(166, 96, 44), nil, "Sphere" })
		table.insert(t, { V(11, 4, 4), C(sd * 29, 14, -13) * CFrame.Angles(0, sd * 0.5, 0), rgb(246, 238, 222), nil, "Cylinder" })
	end
	for i = 0, 5 do
		table.insert(t, { V(6, 6, 6), C(-24 + (i % 3) * 5, 5 + (i // 3) * 4, 18 + (i % 2) * 3), rgb(110, 40, 120), nil, "Ball" })
	end
	return t
end
PROPS.Spear = function()
	-- Held a third of the way up; points up (+Y).
	return {
		{ V(4.5, 300, 4.5), C(0, 60, 0), rgb(110, 76, 44), Enum.Material.Wood },
		{ V(10, 30, 3), C(0, 222, 0), rgb(200, 205, 214), Enum.Material.Metal },
		{ V(7, 7, 7), C(0, 238, 0) * CFrame.Angles(0, 0, PI / 4), rgb(200, 205, 214), Enum.Material.Metal },
		{ V(20, 3, 3), C(0, 205, 0), rgb(230, 190, 90), Enum.Material.Metal },
	}
end
PROPS.Scepter = function()
	return {
		{ V(3.5, 70, 3.5), C(0, 10, 0), rgb(230, 190, 90), Enum.Material.Metal },
		{ V(12, 12, 12), C(0, 48, 0), rgb(230, 190, 90), Enum.Material.Metal, "Ball" },
		{ V(6, 6, 6), C(0, 56, 0), rgb(220, 40, 60), Enum.Material.Neon, "Ball" },
	}
end
PROPS.Ball = function()
	return { { V(16, 16, 16), C(0, 0, 0), rgb(255, 255, 255), nil, "Ball" } }
end

----------------------------------------------------------------------------------------------------
-- Plans: each character's loop, as steps that each say where they are and how they're posed
----------------------------------------------------------------------------------------------------

type Step = { T0: number, Dur: number, Root: (number) -> (number, number, number), Pose: (number, any) -> Pose, Hold: { [string]: any }? }

local Plan = {}
Plan.__index = Plan

local WALK_SPEED = 115 -- studs a second
local TURN_SPEED = 3.2 -- radians a second

local function newPlan(actor: any, x: number, z: number, phi: number): any
	local self = setmetatable({}, Plan)
	self.Actor = actor
	self.X, self.Z, self.Phi = x, z, phi
	self.T = 0
	self.Steps = {} :: { Step }
	self.Sit = nil :: any -- the seat while sitting
	return self
end

function Plan:add(dur: number, root: (number) -> (number, number, number), pose: (number, any) -> Pose, hold: { [string]: any }?)
	table.insert(self.Steps, { T0 = self.T, Dur = dur, Root = root, Pose = pose, Hold = hold })
	self.T += dur
end

-- Stand (or sit, if seated) where we are for dur seconds.
function Plan:still(dur: number, pose: (number, any) -> Pose, hold: { [string]: any }?)
	local x, z, phi = self.X, self.Z, self.Phi
	local seat = self.Sit
	self:add(dur, function()
		return x, z, phi
	end, function(u, ctx)
		local p = pose(u, ctx)
		if seat then
			p.sit = p.sit or 1
			p.seat = seat.Top
		end
		return p
	end, hold)
	self.Steps[#self.Steps].Seated = seat ~= nil
end

-- Splits a step at `at` seconds; the second half carries `hold`.
function Plan:split(step: any, at: number, hold: { [string]: any }?)
	for i, st in self.Steps do
		if st == step then
			local root, pose = st.Root, st.Pose
			local rest = { T0 = st.T0 + at, Dur = st.Dur - at, Hold = hold, Seated = st.Seated, Offset = (st.Offset or 0) + at }
			rest.Root = function(u)
				return root(u + at)
			end
			rest.Pose = function(u, ctx)
				return pose(u + at, ctx)
			end
			st.Dur = at
			table.insert(self.Steps, i + 1, rest)
			return rest
		end
	end
	return nil
end

-- A still step whose held props change halfway (picking something up / putting it down).
function Plan:swap(dur: number, pose: (number, any) -> Pose, before: { [string]: any }?, after: { [string]: any }?)
	self:still(dur, pose, before)
	self:split(self.Steps[#self.Steps], dur / 2, after)
end

-- Turn on the spot to face phi (little steps while turning).
function Plan:turn(phi: number, hold: { [string]: any }?, carry: ((number, any) -> Pose)?)
	local from = self.Phi
	local d = angleDiff(from, phi)
	if math.abs(d) < 0.05 then
		self.Phi = phi
		return
	end
	local dur = math.max(0.3, math.abs(d) / TURN_SPEED)
	local x, z = self.X, self.Z
	self:add(dur, function(u)
		return x, z, from + d * smooth(u / dur)
	end, function(u, ctx)
		local p = if carry then carry(u, ctx) else {}
		p.walk = u / dur * PI * 2
		p.stride = 0.25
		return p
	end, hold)
	self.Phi = phi
end

-- Walk through points (room x, z), turning first to face the way.
function Plan:walk(points: { Vector2 }, hold: { [string]: any }?, carry: ((number, any) -> Pose)?, speed: number?, backwards: boolean?)
	local pts = { Vector2.new(self.X, self.Z) }
	for _, p in points do
		table.insert(pts, p)
	end
	local lens = {}
	local total = 0
	for i = 2, #pts do
		lens[i] = (pts[i] - pts[i - 1]).Magnitude
		total += lens[i]
	end
	if total < 1 then
		return
	end
	local first = pts[2] - pts[1]
	if not backwards then
		self:turn(phiOf(first.X, first.Y), hold, carry)
	end
	local v = speed or (if backwards then WALK_SPEED * 0.45 else WALK_SPEED)
	local dur = total / v
	local function at(d: number): Vector2
		d = math.clamp(d, 0, total)
		for i = 2, #pts do
			if d <= lens[i] or i == #pts then
				local k = if lens[i] > 0 then math.clamp(d / lens[i], 0, 1) else 1
				return pts[i - 1]:Lerp(pts[i], k)
			end
			d -= lens[i]
		end
		return pts[#pts]
	end
	local startPhi = self.Phi
	local stride = self.Actor.S * 0.95
	self:add(dur, function(u)
		local d = u * v
		local p = at(d)
		local ahead = at(d + 45) - at(d - 45)
		local phi = if ahead.Magnitude > 1 and not backwards then phiOf(ahead.X, ahead.Y) else startPhi
		return p.X, p.Y, phi
	end, function(u, ctx)
		local p = if carry then carry(u, ctx) else {}
		p.stride = math.clamp(math.min(u / 0.3, (dur - u) / 0.45), 0.15, 1) * (p.stride or 1)
		p.walk = (if backwards then -1 else 1) * u * v / stride * PI
		p.bob = math.abs(math.sin(u * v / stride * PI)) * 0.04
		return p
	end, hold)
	local last = pts[#pts]
	local lastDir = pts[#pts] - pts[#pts - 1]
	self.X, self.Z = last.X, last.Y
	if not backwards then
		self.Phi = phiOf(lastDir.X, lastDir.Y)
	end
end

-- While sitting down / standing up with something in both hands, keep it at chest height.
local function carryArms(p: any, ctx: any, hold: { [string]: any }?): any
	if not hold then
		return p
	end
	local both = false
	for _, h in hold do
		if type(h) == "table" and h[1] == "both" then
			both = true
		end
	end
	if not both then
		return p
	end
	local s = ctx.Actor.S
	local pelvis = lerp(2 * s, (p.seat or 0) + 0.37 * s, p.sit or 0)
	local h = pelvis + 1.65 * s
	local toWorld = ctx.Origin * rootCF(ctx.X, ctx.Z, ctx.Phi)
	p.armL = { at = (toWorld * CFrame.new(-0.42 * s, h, -0.85 * s)).Position }
	p.armR = { at = (toWorld * CFrame.new(0.42 * s, h, -0.85 * s)).Position }
	return p
end

-- From beside a seat: turn to the seat's facing and slide into it while sitting down.
function Plan:sitDown(seat: any, hold: { [string]: any }?, slide: boolean?)
	self:turn(seat.Phi, hold)
	local x0, z0 = self.X, self.Z
	local phi = seat.Phi
	local dur = 1.1
	-- step in front of the seat first, then sit (or, `slide`, sit while sliding on sideways)
	self:add(dur, function(u)
		if slide then
			local k = smooth(u / dur)
			return lerp(x0, seat.X, k), lerp(z0, seat.Z, k), phi
		end
		local k = smooth(u / (dur * 0.55))
		return lerp(x0, seat.X, k), lerp(z0, seat.Z, k), phi
	end, function(u, ctx)
		local p
		if slide then
			p = { sit = smooth(u / dur * 1.4), seat = seat.Top, legs = { kneeL = -PI / 2, kneeR = -PI / 2 }, armL = { p = 0.25, r = 0.08, e = 0.55 }, armR = { p = 0.25, r = 0.08, e = 0.55 } }
		else
			p = { sit = smooth((u / dur - 0.5) / 0.5), seat = seat.Top, walk = if u < dur * 0.55 then u / dur * 9 else nil, stride = 0.3, armL = { p = 0.25, r = 0.08, e = 0.55 }, armR = { p = 0.25, r = 0.08, e = 0.55 } }
		end
		return carryArms(p, ctx, hold)
	end, hold)
	self.X, self.Z, self.Phi = seat.X, seat.Z, phi
	self.Sit = seat
end

-- Stand up and slide out to the side point.
function Plan:standUp(to: Vector2, hold: { [string]: any }?, slide: boolean?)
	local seat = self.Sit
	local x1, z1 = to.X, to.Y
	local phi = self.Phi
	local dur = 1.1
	-- stand up in place first, then step out to the side (or, `slide`, slide off sideways)
	self:add(dur, function(u)
		if slide then
			local k = smooth(u / dur)
			return lerp(seat.X, x1, k), lerp(seat.Z, z1, k), phi
		end
		local k = smooth((u / dur - 0.45) / 0.55)
		return lerp(seat.X, x1, k), lerp(seat.Z, z1, k), phi
	end, function(u, ctx)
		local p
		if slide then
			p = { sit = 1 - smooth((u / dur - 0.3) / 0.7), seat = seat.Top, legs = { kneeL = -PI / 2 * (1 - smooth((u / dur - 0.3) / 0.7)), kneeR = -PI / 2 * (1 - smooth((u / dur - 0.3) / 0.7)) }, armL = { p = 0.25, r = 0.08, e = 0.55 }, armR = { p = 0.25, r = 0.08, e = 0.55 } }
		else
			p = { sit = 1 - smooth(u / dur / 0.5), seat = seat.Top, walk = if u > dur * 0.45 then u / dur * 9 else nil, stride = 0.3, armL = { p = 0.25, r = 0.08, e = 0.55 }, armR = { p = 0.25, r = 0.08, e = 0.55 } }
		end
		return carryArms(p, ctx, hold)
	end, hold)
	self.X, self.Z = x1, z1
	self.Sit = nil
end

-- Pads the plan with `fill` until it's exactly `period` long.
function Plan:finish(period: number, fill: (number, any) -> Pose)
	local left = period - self.T
	assert(left > -1e-6, "NPC plan for " .. self.Actor.Name .. " is " .. string.format("%.2f", self.T) .. "s, longer than the loop (" .. period .. "s)")
	if left > 1e-3 then
		self:still(left, fill)
	end
end

function Plan:eval(t: number, origin: CFrame?): (CFrame, Pose, { [string]: any }?, number, Step)
	local steps = self.Steps
	local lo, hi = 1, #steps
	while lo < hi do
		local mid = (lo + hi + 1) // 2
		if steps[mid].T0 <= t then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local st = steps[lo]
	local u = math.clamp(t - st.T0, 0, st.Dur)
	local x, z, phi = st.Root(u)
	local ctx = { T = t, U = u, Dur = st.Dur, X = x, Z = z, Phi = phi, Actor = self.Actor, Seated = st.Seated, Origin = origin or CFrame.identity }
	local pose = st.Pose(u, ctx)
	return rootCF(x, z, phi), pose, st.Hold, u, st
end

----------------------------------------------------------------------------------------------------
-- Pose helpers (u = seconds into the step; world points are built from ctx)
----------------------------------------------------------------------------------------------------

-- A point in front of the character: right (+x), up (y studs above the floor), forward.
local function local3(ctx: any, right: number, up: number, fwd: number): Vector3
	return (ctx.Origin * rootCF(ctx.X, ctx.Z, ctx.Phi) * CFrame.new(right, up, -fwd)).Position
end

local function breathe(u: number): number
	return math.sin(u * 1.7) * 0.012
end

local function lookAround(u: number, amp: number?): any
	local a = amp or 0.35
	return { yaw = math.sin(u * 0.45) * a + math.sin(u * 1.13) * a * 0.3, pitch = math.sin(u * 0.31) * 0.06 }
end

local P = {}

function P.idle(u: number, _ctx: any?): Pose
	return { bob = breathe(u), head = lookAround(u), armL = { p = 0.03, r = 0.06, e = 0.12 }, armR = { p = 0.03, r = 0.06, e = 0.12 } }
end

-- Seated at a table: hands resting on it.
function P.rest(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	return {
		bob = breathe(u),
		head = lookAround(u, 0.3),
		armL = { at = local3(ctx, -0.55 * s, 150 + 28, 1.25 * s) },
		armR = { at = local3(ctx, 0.55 * s, 150 + 28, 1.25 * s) },
	}
end

-- Eating with a fork: plate -> mouth, about every 3.4 s.
function P.eat(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local cyc = (u % 3.4) / 3.4
	local up = if cyc < 0.35 then 0 elseif cyc < 0.5 then smooth((cyc - 0.35) / 0.15) elseif cyc < 0.72 then 1 else 1 - smooth((cyc - 0.72) / 0.14)
	local plate = local3(ctx, 0.3 * s, 150 + 26, 1.5 * s)
	local chew = if cyc > 0.55 and cyc < 0.95 then math.sin(u * 14) * 0.03 else 0
	return {
		bob = breathe(u),
		lean = 0.08 + up * 0.08,
		head = { yaw = 0, pitch = -0.12 + up * 0.1 + chew, roll = 0 },
		armL = { at = local3(ctx, -0.6 * s, 150 + 28, 1.2 * s) },
		armR = {
			at = function(b)
				local mouth = (b.Head * CFrame.new(0.3 * s, -0.25 * s, -0.75 * s)).Position
				return plate:Lerp(mouth, up)
			end,
			pole = Vector3.new(0, -1, 0),
		},
	}
end


-- Seated / standing activities. Every function takes (u, ctx) and returns a pose.
local TABLE = 150 -- table top, studs above the floor


-- Eating something held in the right hand (a pizza slice, a turkey leg): hand to mouth every 3 s.
function P.bite(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local cyc = (u % 3) / 3
	local up = if cyc < 0.2 then smooth(cyc / 0.2) elseif cyc < 0.55 then 1 else 1 - smooth((cyc - 0.55) / 0.3)
	local chew = if cyc > 0.25 and cyc < 0.6 then math.sin(u * 16) * 0.035 else 0
	local low = local3(ctx, 0.5 * s, TABLE + 30, 1.1 * s)
	return {
		bob = breathe(u),
		lean = 0.05,
		head = { pitch = -0.05 + chew, yaw = math.sin(u * 0.4) * 0.15 },
		armL = { at = local3(ctx, -0.6 * s, TABLE + 24, 1.2 * s) },
		armR = {
			at = function(b)
				return low:Lerp((b.Head * CFrame.new(0.25 * s, -0.25 * s, -0.8 * s)).Position, up)
			end,
			pole = Vector3.new(0, -1, 0),
		},
	}
end

-- Drinking from a cup held in the right hand: a few sips.
function P.drink(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local cyc = (u % 4) / 4
	local up = if cyc < 0.25 then smooth(cyc / 0.25) elseif cyc < 0.7 then 1 else 1 - smooth((cyc - 0.7) / 0.25)
	local low = local3(ctx, 0.45 * s, TABLE + 30, 1.25 * s)
	return {
		bob = breathe(u),
		head = { pitch = up * 0.3 },
		armL = { at = local3(ctx, -0.6 * s, TABLE + 24, 1.2 * s) },
		armR = {
			at = function(b)
				return low:Lerp((b.Head * CFrame.new(0.15 * s, -0.3 * s, -0.85 * s)).Position, up)
			end,
			pole = Vector3.new(0, -1, 0),
		},
	}
end

-- Chatting: nodding, hands moving, turned towards `yaw`.
function P.talkTo(yaw: number): (number, any) -> Pose
	return function(u: number, ctx: any): Pose
		local s = ctx.Actor.S
		local g = math.sin(u * 2.3)
		return {
			bob = breathe(u),
			twist = yaw * 0.12,
			head = { yaw = yaw * 0.75 + math.sin(u * 0.9) * 0.08, pitch = math.sin(u * 3.1) * 0.06 },
			armL = { at = local3(ctx, -0.6 * s, TABLE + 24, 1.2 * s) },
			armR = { at = local3(ctx, 0.45 * s + math.sin(u * 1.7) * 8, (if ctx.Seated then 118 else 100) + 1.9 * s + g * 8, 0.95 * s) },
		}
	end
end

function P.laugh(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local shake = math.sin(u * 18) * 0.02
	return {
		bob = shake,
		lean = (if ctx.Seated then -0.04 else -0.12) + math.sin(u * 9) * 0.03,
		head = { pitch = 0.3 + shake },
		armL = { at = local3(ctx, -0.35 * s, (ctx.Seated and 120 or 100) + 1.8 * s, 0.6 * s) },
		armR = { at = local3(ctx, 0.35 * s, (ctx.Seated and 120 or 100) + 1.8 * s, 0.6 * s) },
	}
end

-- Waving at the players (they're in the dishwasher, at the origin).
function P.wave(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local dx, dz = -ctx.X, -60 - ctx.Z
	local yaw = angleDiff(ctx.Phi, phiOf(dx, dz))
	return {
		bob = breathe(u),
		head = { yaw = math.clamp(yaw, -1, 1), pitch = 0.1 },
		armL = if ctx.Seated then { at = local3(ctx, -0.6 * s, TABLE + 24, 1.2 * s) } else nil,
		armR = { p = 2.5, r = 0.12 + math.sin(u * 9) * 0.14, e = 0.55 + math.sin(u * 9) * 0.3 },
	}
end

-- The same wave with the left hand (for people whose right side is against a wall).
function P.waveLeft(u: number, ctx: any): Pose
	local p = P.wave(u, ctx)
	local s = ctx.Actor.S
	p.armL = p.armR
	p.armR = if ctx.Seated then { at = local3(ctx, 0.6 * s, TABLE + 32, 1.2 * s) } else nil
	return p
end

function P.clap(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local k = math.abs(math.sin(u * 7))
	local base = (ctx.Seated and 120 or 100) + 2.3 * s
	return {
		bob = breathe(u),
		head = { pitch = 0.1 },
		armL = { at = local3(ctx, -0.12 * s - k * 0.35 * s, base, 1.1 * s) },
		armR = { at = local3(ctx, 0.12 * s + k * 0.35 * s, base, 1.1 * s) },
	}
end

function P.stretch(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local k = smooth(math.min(u, 4 - u) / 1.2)
	local base = if ctx.Seated then 118 else 100
	return {
		lean = -0.03 * k,
		head = { pitch = 0.25 * k },
		armL = { at = local3(ctx, -0.6 * s, TABLE + 32, 1.2 * s):Lerp(local3(ctx, -0.55 * s, base + 5.2 * s, 0.25 * s), k) },
		armR = { at = local3(ctx, 0.6 * s, TABLE + 32, 1.2 * s):Lerp(local3(ctx, 0.55 * s, base + 5.2 * s, 0.25 * s), k) },
	}
end

-- Holding a newspaper open in front of the face.
function P.read(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local turn = math.sin(u * 0.5) * 0.08
	return {
		bob = breathe(u),
		lean = 0.04,
		head = { yaw = turn * 0.5, pitch = -0.3 },
		-- held at arm's length below the chin, so the paper never meets the face
		armL = { at = local3(ctx, -0.66 * s + turn * 20, (if ctx.Seated then 84 else 60) + 2.0 * s, 1.15 * s) },
		armR = { at = local3(ctx, 0.66 * s + turn * 20, (if ctx.Seated then 84 else 60) + 2.0 * s, 1.15 * s) },
	}
end

-- Dozing off at the table, then a start.
function P.doze(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local k = smooth(u / 2)
	return {
		bob = math.sin(u * 1.1) * 0.02,
		lean = 0.08 * k,
		head = { pitch = -0.55 * k + math.sin(u * 1.1) * 0.05, roll = 0.15 * k },
		armL = { at = local3(ctx, -0.55 * s, TABLE + 24, 1.15 * s) },
		armR = { at = local3(ctx, 0.55 * s, TABLE + 24, 1.15 * s) },
	}
end

function P.startle(u: number, ctx: any): Pose
	local k = 1 - smooth(u / 1.5)
	return {
		bob = math.sin(u * 20) * 0.02 * k,
		lean = (if ctx.Seated then -0.02 else -0.1) * k,
		head = { pitch = 0.2 * k, yaw = math.sin(u * 8) * 0.3 * k },
		armL = { p = 1.2 * k, r = 0.8 * k, e = 0.8 },
		armR = { p = 1.2 * k, r = 0.8 * k, e = 0.8 },
	}
end

-- Both hands reaching to (right, up, forward) points and back: pick up / put down over `dur`.
function P.reach(lr: number, lu: number, lf: number, rr: number, ru: number, rf: number, dur: number, lean: number?): (number, any) -> Pose
	return function(u: number, ctx: any): Pose
		local k = math.sin(math.clamp(u / dur, 0, 1) * PI)
		local s = ctx.Actor.S
		local restL = local3(ctx, -0.45 * s, 100 + 1.4 * s, 0.75 * s)
		local restR = local3(ctx, 0.45 * s, 100 + 1.4 * s, 0.75 * s)
		return {
			lean = (lean or 0.25) * k,
			head = { pitch = -0.35 * k },
			armL = { at = restL:Lerp(local3(ctx, lr, lu, lf), k) },
			armR = { at = restR:Lerp(local3(ctx, rr, ru, rf), k) },
		}
	end
end

-- Carrying something in both hands in front of the chest (used while walking too).
function P.carry(u: number, ctx: any): Pose
	local s = ctx.Actor.S
	local h = (if ctx.Seated then 118 else 100) + 1.65 * s
	return {
		head = { pitch = -0.08 },
		armL = { at = local3(ctx, -0.42 * s, h, 0.85 * s) },
		armR = { at = local3(ctx, 0.42 * s, h, 0.85 * s) },
	}
end

-- One hand reaching forward (to a fridge, a shelf, the fire).
function P.reachOne(fwd: number, up: number, dur: number): (number, any) -> Pose
	return function(u: number, ctx: any): Pose
		local s = ctx.Actor.S
		local k = math.sin(math.clamp(u / dur, 0, 1) * PI)
		return {
			lean = 0.15 * k,
			head = { pitch = -0.1 * k },
			armR = { at = local3(ctx, 0.5 * s, 100 + 1.2 * s, 0.4 * s):Lerp(local3(ctx, 0.3 * s, up, fwd), k) },
		}
	end
end

function P.point(target: Vector3): (number, any) -> Pose
	return function(u: number, ctx: any): Pose
		local s = ctx.Actor.S
		local dx, dz = target.X - ctx.X, target.Z - ctx.Z
		local yaw = angleDiff(ctx.Phi, phiOf(dx, dz))
		local k = smooth(math.min(u, 3 - u) / 0.5)
		return {
			bob = breathe(u),
			head = { yaw = math.clamp(yaw, -1, 1) * k, pitch = 0.1 * k },
			armL = if ctx.Seated then { at = local3(ctx, -0.6 * s, TABLE + 24, 1.2 * s) } else nil,
			armR = { p = 1.4 * k, y = -yaw * 0.6 * k, r = 0.1, e = 0.05 },
		}
	end
end


----------------------------------------------------------------------------------------------------
-- Scene
----------------------------------------------------------------------------------------------------

local Scene = {}
Scene.__index = Scene

local function newScene(origin: CFrame, parent: Instance): any
	local self = setmetatable({}, Scene)
	local folder = Instance.new("Folder")
	folder.Name = "LevelNPCs"
	folder.Parent = parent
	self.Folder = folder
	local actors = Instance.new("Folder")
	actors.Name = "Actors"
	actors.Parent = folder
	self.ActorFolder = actors
	self.CutsceneMode = false
	self.Origin = origin
	self.Actors = {} :: { any }
	self.Plans = {} :: { any }
	self.Props = {} :: { [string]: any }
	self.Placements = {} :: { [string]: { any } }
	self.Period = 60
	return self
end

function Scene:actor(name: string, lookName: string): any
	local a = buildActor(name, LOOKS[lookName], self.ActorFolder)
	table.insert(self.Actors, a)
	return a
end

function Scene:prop(name: string, kind: string): any
	local p = buildProp(name, PROPS[kind](), self.Folder)
	self.Props[name] = p
	self.Placements[name] = {}
	return p
end

-- The prop sits at `cf` (room space, or a function of the loop time giving one) from loop time t0
-- to t1 (wrapping round the loop).
function Scene:place(name: string, t0: number, t1: number, cf: CFrame | (number) -> CFrame)
	table.insert(self.Placements[name], { t0 % self.Period, t1 % self.Period, cf, t1 - t0 >= self.Period })
end

local function inRange(t: number, a: number, b: number, all: boolean): boolean
	if all then
		return true
	end
	if a <= b then
		return t >= a and t < b
	end
	return t >= a or t < b
end


function Scene:Update(clock: number)
	local t = clock % self.Period
	local parts, cframes = {}, {}
	local origin = self.Origin
	local held: { [string]: boolean } = {}
	-- While a story cutscene plays in this room, the room's people step out: only the furniture
	-- they brought stays (the cutscene brings its own cast).
	local still = self.CutsceneMode
	self.ActorFolder.Parent = if still then nil else self.Folder
	for _, plan in (if still then {} else self.Plans) do
		local root, pose, hold, u, step = plan:eval(t, origin)
		u += step.Offset or 0
		local a = plan.Actor
		a:Pose(origin * root, pose)
		a:Emit(parts, cframes)
		if hold then
			for name, how in hold do
				local prop = self.Props[name]
				if prop then
					held[name] = true
					local spec = if type(how) == "table" then how else { how }
					local where = spec[1]
					local b = a.Bones
					local base
					if where == "R" or where == "L" then
						local g = b["Grip" .. where]
						base = CFrame.new(g.Position) * (origin * root).Rotation
					elseif where == "both" then
						base = CFrame.new(b.GripL.Position:Lerp(b.GripR.Position, 0.5)) * (origin * root).Rotation
					elseif where == "Rhand" or where == "Lhand" then
						base = b["Grip" .. string.sub(where, 1, 1)]
					elseif where == "Head" then
						base = b.Head
					else
						base = origin * root
					end
					local off = spec.off or CFrame.identity
					if type(off) == "function" then
						off = off(u)
					end
					prop:SetScale(if spec.scale then spec.scale(u) else 1)
					prop:SetVisible(true)
					prop:Emit(base * off, parts, cframes)
				end
			end
		end
	end
	for name, prop in self.Props do
		if held[name] then
			continue
		end
		if still and (string.sub(name, 1, 4) ~= "Furn" or (self.CutsceneHide and self.CutsceneHide[name])) then
			prop:SetVisible(false)
			continue
		end
		local shown = false
		for _, pl in self.Placements[name] do
			if inRange(t, pl[1], pl[2], pl[4]) then
				local cf = pl[3]
				if type(cf) == "function" then
					cf = cf(t)
				end
				prop:SetScale(1)
				prop:SetVisible(true)
				prop:Emit(origin * cf, parts, cframes)
				shown = true
				break
			end
		end
		if not shown then
			prop:SetVisible(false)
		end
	end
	local ok = pcall(function()
		Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
	end)
	if not ok then
		for i, p in parts do
			p.CFrame = cframes[i]
		end
	end
end

function Scene:Destroy()
	self.Folder:Destroy()
end


----------------------------------------------------------------------------------------------------
-- The casts
----------------------------------------------------------------------------------------------------

local V2 = Vector2.new
local FORK_HOLD = { "Rhand", off = CFrame.Angles(PI / 2, 0, 0) }
local TOP = FLOOR + 150 -- table top (room y)

local function seat(x: number, z: number, phi: number, top: number): any
	return { X = x, Z = z, Phi = phi, Top = top }
end

local function seated(plan: any, st: any)
	plan.X, plan.Z, plan.Phi = st.X, st.Z, st.Phi
	plan.Sit = st
end


-- Level 1: Family Dinner ---------------------------------------------------------------------------
-- The room's four dining chairs are too close together for grown-ups this size, so the client hides
-- them and seats the family on its own chairs: Dad and the kid on the far side, Mum on the near
-- side (nearest the sink) and Grandpa in a tall chair at the end of the table.
local function buildFamily(scene: any)
	scene.Period = 60
	scene.Hide = { "TablePlate", "ChairSeat", "ChairBack", "ChairLeg" }
	-- Seats sit 5 studs in front of each chair's centre (people perch forward a little).
	local function place(name: string, kind: string, x: number, z: number, phi: number)
		scene:prop(name, kind)
		scene:place(name, 0, 60, rootCF(x, z, phi))
	end
	place("FurnChairDad", "FurnChair", -80, -455, 0)
	place("FurnChairKid", "FurnKidChair", 100, -468, 0)
	place("FurnChairMum", "FurnChair", 0, -205, PI)
	place("FurnChairGrandpa", "FurnHighChair", -340, -380, PI / 2)
	local dadSeat = seat(-80, -452, 0, 98)
	local kidSeat = seat(100, -463, 0, 108)
	local mumSeat = seat(0, -210, PI, 98)
	local gpSeat = seat(-328, -380, PI / 2, 98)

	-- Everyone's dinner, and what's on the table (placed from each seat: right, forward).
	local function atSeat(st: any, right: number, fwd: number, up: number?): CFrame
		local cf = rootCF(st.X, st.Z, st.Phi) * CFrame.new(right, 0, -fwd)
		return CFrame.new(cf.X, TOP + (up or 0), cf.Z) * cf.Rotation
	end
	for i, st in { dadSeat, kidSeat, mumSeat } do
		scene:prop("Meal" .. i, "Spaghetti")
		scene:place("Meal" .. i, 0, 60, atSeat(st, -4, 76))
		scene:prop("Fork" .. i, "Fork")
		scene:place("Fork" .. i, 0, 60, atSeat(st, 34, 72, 1) * CFrame.Angles(0, 0.2, 0))
	end

	-- Dad: stays at the table and enjoys it.
	local dad = scene:actor("Dad", "Dad")
	local pd = newPlan(dad, 0, 0, 0)
	seated(pd, dadSeat)
	scene:prop("DadGlass", "Glass")
	scene:place("DadGlass", 0, 60, atSeat(dadSeat, 30, 64))
	pd:still(9, P.eat, { Fork1 = FORK_HOLD })
	pd:still(6, P.talkTo(-0.9))
	pd:still(5, P.drink, { DadGlass = { "R", off = CFrame.new(0, -9, 0) } })
	pd:still(8, P.eat, { Fork1 = FORK_HOLD })
	pd:still(4, P.wave)
	pd:still(4, P.laugh)
	pd:still(9, P.eat, { Fork1 = FORK_HOLD })
	pd:still(4, P.stretch)
	pd:still(5, P.talkTo(0.8))
	pd:finish(60, P.rest)
	table.insert(scene.Plans, pd)

	-- Grandpa: in his armchair in the corner with the paper, a cup of tea and forty winks.
	local gp = scene:actor("Grandpa", "Grandpa")
	local pg = newPlan(gp, 0, 0, 0)
	seated(pg, gpSeat)
	scene:prop("FurnSideTable", "FurnSideTable")
	local side = rootCF(gpSeat.X, gpSeat.Z, gpSeat.Phi) * CFrame.new(108, 0, -42)
	scene:place("FurnSideTable", 0, 60, side)
	scene:prop("Paper", "Newspaper")
	scene:prop("Tea", "TeaCup")
	scene:place("Tea", 0, 60, side * CFrame.new(-10, 128, 0))
	local paperHold = { "both", off = CFrame.new(0, 10, -3) * CFrame.Angles(-0.35, 0, 0) }
	-- hands resting on the lap
	local function lap(u: number, ctx: any): Pose
		local s = ctx.Actor.S
		return {
			bob = breathe(u),
			head = lookAround(u, 0.3),
			armL = { at = local3(ctx, -0.45 * s, 150, 0.9 * s) },
			armR = { at = local3(ctx, 0.45 * s, 150, 0.9 * s) },
		}
	end
	local function sip(u: number, ctx: any): Pose
		local s = ctx.Actor.S
		local cyc = (u % 4) / 4
		local up = if cyc < 0.25 then smooth(cyc / 0.25) elseif cyc < 0.7 then 1 else 1 - smooth((cyc - 0.7) / 0.25)
		local low = (ctx.Origin * side * CFrame.new(-10, 140, 0)).Position
		return {
			bob = breathe(u),
			head = { pitch = up * 0.3, yaw = 0.2 * (1 - up) },
			armL = { at = local3(ctx, -0.45 * s, 150, 0.9 * s) },
			armR = {
				at = function(b)
					return low:Lerp((b.Head * CFrame.new(0.15 * s, -0.3 * s, -0.85 * s)).Position, up)
				end,
			},
		}
	end
	local function doze(u: number, ctx: any): Pose
		local p = lap(u, ctx)
		local k = smooth(u / 2)
		p.lean = 0.06 * k
		p.head = { pitch = -0.55 * k + math.sin(u * 1.1) * 0.05, roll = 0.15 * k }
		p.bob = math.sin(u * 1.1) * 0.02
		return p
	end
	pg:still(16, P.read, { Paper = paperHold })
	pg:still(1, lap, { Paper = { "both", off = CFrame.new(0, -2, -10) * CFrame.Angles(-PI / 2, 0, 0) } })
	pg:still(6, sip, { Tea = { "R", off = CFrame.new(0, -5, 0) } })
	pg:still(4, P.wave)
	pg:still(14, doze)
	pg:still(2, P.startle)
	pg:still(3, P.laugh)
	pg:finish(60, P.read)
	pg.Steps[#pg.Steps].Hold = { Paper = paperHold }
	for _, st in pg.Steps do
		if st.Hold == nil and st.T0 > 16 and st.T0 < 45 then
			st.Hold = { Paper = { "both", off = CFrame.new(0, -2, -10) * CFrame.Angles(-PI / 2, 0, 0) } }
		end
	end
	table.insert(scene.Plans, pg)

	-- The kid: eats, then fetches a juice from the fridge.
	local kid = scene:actor("Kid", "Kid")
	local pk = newPlan(kid, 0, 0, 0)
	seated(pk, kidSeat)
	scene:prop("Juice", "Juice")
	local juiceHold = { "R", off = CFrame.new(0, -8, 0) }
	local juiceSpot = atSeat(kidSeat, 20, 64)
	local grab = P.reachOne(64, TABLE + 30, 1)
	pk:still(10, P.eat, { Fork2 = FORK_HOLD })
	pk:still(5, P.talkTo(0.9))
	local pickT = pk.T
	pk:swap(1, grab, nil, { Juice = juiceHold })
	pk:standUp(V2(185, -447), { Juice = juiceHold }, true)
	pk:walk({ V2(222, -435), V2(222, -290), V2(220, -205) }, { Juice = juiceHold })
	pk:turn(PI / 2, { Juice = juiceHold })
	pk:still(2, P.reachOne(1.6 * kid.S, 120, 2), { Juice = juiceHold })
	pk:walk({ V2(222, -290), V2(222, -435), V2(185, -447) }, { Juice = juiceHold })
	pk:sitDown(kidSeat, { Juice = juiceHold }, true)
	pk:still(7, P.drink, { Juice = juiceHold })
	local putT = pk.T
	pk:swap(1, grab, { Juice = juiceHold }, nil)
	pk:still(4, P.wave)
	pk:finish(60, P.eat)
	pk.Steps[#pk.Steps].Hold = { Fork2 = FORK_HOLD }
	scene:place("Juice", putT + 0.5, pickT + 0.5 + 60, juiceSpot)
	table.insert(scene.Plans, pk)

	-- Mum: gathers up the spare plates, washes them at the sink right beside the dishwasher, brings
	-- them back and sits down to eat.
	local mum = scene:actor("Mum", "Mum")
	local pm = newPlan(mum, 0, 0, 0)
	seated(pm, mumSeat)
	scene:prop("Stack", "CleanStack")
	scene:prop("WashPlate", "WashPlate")
	local tableSpot = atSeat(mumSeat, 0, 92)
	local counterSpot = W(-222, 112, -32)
	local carry = { Stack = { "both", off = CFrame.new(0, -8, -4) } }
	local toTable = P.reach(-0.3 * S, TABLE + 38, 1.85 * S, 0.3 * S, TABLE + 38, 1.85 * S, 1.2, 0.12)
	local toCounter = P.reach(-1.6 * S, 172, 1.3 * S, -1.2 * S, 172, 1.3 * S, 1.2, 0.2)
	pm:still(7, P.eat, { Fork3 = FORK_HOLD })
	local t1 = pm.T
	pm:swap(1.2, toTable, nil, carry)
	pm:standUp(V2(-190, -205), carry)
	pm:walk({ V2(-200, -165), V2(-150, -165), V2(-150, -102) }, carry, P.carry)
	local t2 = pm.T
	pm:swap(1.2, toCounter, carry, nil)
	-- washing: leaning over the sink, one plate in the suds
	pm:still(9, function(u, ctx)
		local s = ctx.Actor.S
		local c = math.sin(u * 5)
		local d = math.cos(u * 5)
		local out = (rootCF(ctx.X, ctx.Z, ctx.Phi)).RightVector
		return {
			lean = 0.3,
			head = { pitch = -0.4, yaw = math.sin(u * 0.6) * 0.1 },
			armL = { at = local3(ctx, -0.05 * s + c * 6, 176, 1.7 * s), pole = (ctx.Origin.Rotation * -out) + Vector3.new(0, -0.3, 0) },
			armR = { at = local3(ctx, 0.35 * s + c * 12, 178 + d * 5, 1.65 * s + d * 8), pole = (ctx.Origin.Rotation * out) + Vector3.new(0, -0.3, 0) },
		}
	end, { WashPlate = { "Lhand", off = CFrame.new(0, -4, -6) * CFrame.Angles(0, 0, PI / 2) } })
	local t3 = pm.T
	pm:swap(1.2, toCounter, nil, carry)
	pm:walk({ V2(-150, -165) }, carry, P.carry, nil, true)
	pm:walk({ V2(-200, -165), V2(-190, -205) }, carry, P.carry)
	pm:sitDown(mumSeat, carry)
	local t4 = pm.T
	pm:swap(1.2, toTable, carry, nil)
	pm:still(6, P.eat, { Fork3 = FORK_HOLD })
	pm:still(5, P.talkTo(0.8))
	pm:finish(60, P.eat)
	pm.Steps[#pm.Steps].Hold = { Fork3 = FORK_HOLD }
	-- the plates: on the table, in her hands, on the counter, in her hands, on the table
	scene:place("Stack", t4 + 0.6, t1 + 0.6 + 60, tableSpot)
	scene:place("Stack", t2 + 0.6, t3 + 0.6, counterSpot)
	table.insert(scene.Plans, pm)
end

-- Level 2: Pizza Party -----------------------------------------------------------------------------
-- The chef works the brick oven from the open floor east of the right-hand table and serves that
-- table from its end with the peel; two guests at that table take the slices as they come. A kid at
-- the other table has their own pizza, and the waiter brings drinks from the fridges on the left.
local function buildPizzeria(scene: any)
	scene.Period = 48
	scene.Hide = { "Pizza", "PizzaSauce", "Pepperoni", "StoolSeat", "StoolPost" }
	scene.HideWhere = function(name: string, pos: Vector3): boolean
		-- the stools everywhere; the pizza only on the right-hand table (the chef serves that one)
		return name == "StoolSeat" or name == "StoolPost" or pos.X > 0
	end
	local tray = W(150, TOP + 0.4, -400)
	scene:prop("Tray", "Tray")
	scene:place("Tray", 0, 48, tray)
	local function stool(name: string, st: any)
		scene:prop(name, "FurnStool")
		scene:place(name, 0, 48, rootCF(st.X, st.Z, st.Phi) * CFrame.new(0, 0, 6))
	end
	local function atSeat(st: any, right: number, fwd: number, up: number?): CFrame
		local cf = rootCF(st.X, st.Z, st.Phi) * CFrame.new(right, 0, -fwd)
		return CFrame.new(cf.X, TOP + (up or 0.4), cf.Z) * cf.Rotation
	end

	-- The chef ---------------------------------------------------------------------------------
	local chef = scene:actor("Chef", "Chef")
	scene:prop("Peel", "Peel")
	scene:prop("Raw", "RawPizza")
	scene:prop("Hot", "HotPizza")
	local mouth = V2(250, -250)
	local home = V2(316, -425)
	local dir = (mouth - home).Unit
	local facing = phiOf(dir.X, dir.Y)
	local pushed = home + dir * 40
	local serveAt = V2(300, -384)
	local pc = newPlan(chef, home.X, home.Y, facing)
	local function peelPose(fwd: number, up: number)
		return function(u, ctx)
			local s = ctx.Actor.S
			return {
				bob = breathe(u),
				lean = 0.08,
				head = { pitch = -0.1 },
				armL = { at = local3(ctx, -0.22 * s, up, fwd - 0.4 * s) },
				armR = { at = local3(ctx, 0.22 * s, up, fwd) },
			}
		end
	end
	local peelOff = CFrame.new(0, 0, 0.2 * S) * CFrame.Angles(-0.06, 0, 0)
	local peelHold = { "both", off = peelOff }
	local onPeel = { "both", off = peelOff * CFrame.new(0, 3, -110) }
	local function slide(from: Vector2, to: Vector2, dur: number, fwdA: number, fwdB: number, hold: any)
		pc:add(dur, function(u)
			local p = from:Lerp(to, smooth(u / dur))
			return p.X, p.Y, facing
		end, function(u, ctx)
			local k = smooth(u / dur)
			local p = peelPose(lerp(fwdA, fwdB, k), 150)(u, ctx)
			p.walk = u / dur * PI * 2
			p.stride = 0.3
			return p
		end, hold)
		pc.X, pc.Z = to.X, to.Y
	end
	local pizzaIn = W(250, FLOOR + 113, -190)
	-- 1. slide the raw pizza in
	pc:still(1.5, peelPose(0.6 * S, 150), { Peel = peelHold, Raw = onPeel })
	slide(home, pushed, 1.6, 0.6 * S, 1.2 * S, { Peel = peelHold, Raw = onPeel })
	local tIn = pc.T
	slide(pushed, home, 1.4, 1.2 * S, 0.6 * S, { Peel = peelHold })
	-- 2. wait for it: wipe the brow, check on the guests, tap a foot
	pc:still(6.5, function(u, ctx)
		local s = ctx.Actor.S
		local wipe = if u > 2 and u < 3.6 then math.sin((u - 2) / 1.6 * PI) else 0
		return {
			bob = breathe(u),
			head = { yaw = if u > 4 then 0.9 else 0.1, pitch = 0.05 },
			armL = { at = local3(ctx, -0.3 * s, 100 + 1.3 * s, 0.8 * s) },
			armR = if wipe > 0 then { at = local3(ctx, 0.2 * s, 100 + 3.1 * s, 0.45 * s):Lerp(local3(ctx, -0.1 * s, 100 + 3.3 * s, 0.4 * s), (math.sin(u * 8) + 1) / 2) } else { at = local3(ctx, 0.3 * s, 100 + 1.3 * s, 0.8 * s) },
			legs = { kneeR = if u > 4.5 then -math.abs(math.sin(u * 7)) * 0.3 else nil },
		}
	end, { Peel = { "L", off = CFrame.Angles(-1.35, 0, 0) } })
	-- 3. pull it out, cooked
	slide(home, pushed, 1.4, 0.6 * S, 1.2 * S, { Peel = peelHold })
	local tOut = pc.T
	slide(pushed, home, 1.6, 1.2 * S, 0.6 * S, { Peel = peelHold, Hot = onPeel })
	scene:place("Raw", tIn, tOut, pizzaIn)
	-- 4. turn round and slide it onto the table
	local carrying = { Peel = peelHold, Hot = onPeel }
	pc:walk({ serveAt }, carrying, peelPose(0.6 * S, 150), 60)
	pc:turn(-PI / 2, carrying, peelPose(0.6 * S, 150))
	pc:swap(1.6, function(u, ctx)
		local k = math.sin(math.clamp(u / 1.6, 0, 1) * PI)
		return peelPose(lerp(0.6, 1.3, k) * S, lerp(150, 146, k))(u, ctx)
	end, carrying, { Peel = peelHold })
	local tServe = pc.T - 0.8
	pc:still(2.5, function(u, ctx)
		local p = peelPose(0.6 * S, 150)(u, ctx)
		p.head = { yaw = 0.3, pitch = -0.15 }
		return p
	end, { Peel = peelHold })
	pc:still(2.5, P.point(Vector3.new(0, 0, -40)), { Peel = { "L", off = CFrame.Angles(-1.35, 0, 0) } })
	pc:walk({ home }, { Peel = peelHold }, peelPose(0.6 * S, 150), 60)
	pc:turn(facing, { Peel = peelHold }, peelPose(0.6 * S, 150))
	-- 5. a breather, then dip the peel for the next pizza
	pc:still(4, P.laugh, { Peel = { "L", off = CFrame.Angles(-1.35, 0, 0) } })
	pc:still(4, P.idle, { Peel = { "L", off = CFrame.Angles(-1.35, 0, 0) } })
	pc:swap(2, peelPose(0.6 * S, 132), { Peel = peelHold }, { Peel = peelHold, Raw = onPeel })
	pc:finish(48, peelPose(0.6 * S, 150))
	pc.Steps[#pc.Steps].Hold = { Peel = peelHold, Raw = onPeel }
	table.insert(scene.Plans, pc)

	-- The guests at the right-hand table take the slices in turns --------------------------------
	local g1 = scene:actor("Guest1", "Guest1")
	local nearSeat = seat(122, -300, PI, 94)
		stool("FurnStool1", nearSeat)
	local slices = {}
	for i = 1, 6 do
		local name = "Slice" .. i
		scene:prop(name, "Slice")
		slices[i] = name
	end
	-- slice i: crust out at angle a, tip at the centre
	local function sliceSpot(i: number): CFrame
		local a = (i - 1) / 6 * PI * 2
		return tray * CFrame.new(0, 1.2, 0) * CFrame.Angles(0, a, 0) * CFrame.new(0, 0, -34) * CFrame.Angles(0, PI, 0)
	end
	local takes = { 2.0, 6.6, 11.2, 15.8, 20.4, 25.0 } -- after serving
	local eatDur = 3.4
	for gi, guest in { { a = g1, st = nearSeat, first = 1 } } do
		local pl = newPlan(guest.a, 0, 0, 0)
		seated(pl, guest.st)
		local sodaName = "Soda" .. gi
		scene:prop(sodaName, "Soda")
		scene:place(sodaName, 0, 48, atSeat(guest.st, 30, 64))
		local sodaHold = { "R", off = CFrame.new(0, -11, 0) }
		local before = tServe - 0.5
		local chunks = {
			{ 5, P.talkTo(if gi == 1 then 0.3 else -0.3) },
			{ 4, P.drink, { [sodaName] = sodaHold } },
			{ 3, P.laugh },
			{ 3, P.wave },
		}
		local t = 0
		local idx = gi
		while t < before - 0.01 do
			local c = chunks[(idx - 1) % #chunks + 1]
			local d = math.min(c[1], before - t)
			pl:still(d, c[2], c[3])
			t += d
			idx += 1
		end
		pl:still(1.5, P.clap)
		for k = guest.first, 6 do
			local takeAt = math.max(tServe + takes[k], pl.T)
			if takeAt - pl.T > 1e-3 then
				pl:still(takeAt - pl.T, P.rest)
			end
			local sliceName = slices[k]
			local off = CFrame.new(0, 0, 6) * CFrame.Angles(0.5, 0, 0)
			local s = guest.a.S
			pl:swap(1.2, function(u, ctx)
				local p = P.rest(u, ctx)
				local kk = math.sin(math.clamp(u / 1.2, 0, 1) * PI)
				local spot = (scene.Origin * sliceSpot(k) * CFrame.new(0, 26, 4)).Position
				p.armR = { at = local3(ctx, 0.5 * s, TABLE + 34, 1.1 * s):Lerp(spot, kk) }
				p.lean = 0.12 * kk
				return p
			end, nil, { [sliceName] = { "R", off = off } })
			pl:still(eatDur, P.bite, {
				[sliceName] = {
					"R",
					off = off,
					scale = function(u)
						return math.max(0.25, 1 - u / eatDur * 0.85)
					end,
				},
			})
			scene:place(sliceName, tServe, takeAt + 0.6, sliceSpot(k))
		end
		local rest = 48 - pl.T
		if rest > 0 then
			pl:still(math.min(3, rest), function(u, ctx)
				local s = ctx.Actor.S
				return {
					lean = -0.03,
					head = { pitch = 0.15 },
					armL = { at = local3(ctx, -0.25 * s, 118 + 1.3 * s, 0.62 * s + math.sin(u * 6) * 3) },
					armR = { at = local3(ctx, 0.25 * s, 118 + 1.3 * s, 0.62 * s) },
				}
			end)
		end
		pl:finish(48, P.talkTo(if gi == 1 then 0.3 else -0.3))
		table.insert(scene.Plans, pl)
	end

	-- A kid at the other table with their own pizza, and the waiter --------------------------------
	local g3 = scene:actor("Guest3", "Guest3")
	local kidSeat = seat(-250, -400, PI / 2, 94)
	stool("FurnStool3", kidSeat)
	local p3 = newPlan(g3, 0, 0, 0)
	seated(p3, kidSeat)
	scene:prop("KidSlice", "Slice")
	local kidSlice = {
		"R",
		off = CFrame.new(0, 0, 5) * CFrame.Angles(0.5, 0, 0),
		scale = function(u)
			return math.max(0.25, 1 - u / 9 * 0.8)
		end,
	}
	p3:still(9, P.bite, { KidSlice = kidSlice })
	p3:still(3, P.wave)
	p3:still(4, P.talkTo(-0.8))
	p3:still(9, P.bite, { KidSlice = kidSlice })
	p3:still(3, P.clap)
	p3:still(4, P.laugh)
	p3:still(9, P.bite, { KidSlice = kidSlice })
	p3:finish(48, P.rest)
	table.insert(scene.Plans, p3)

	local g2 = scene:actor("Guest2", "Guest2")
	local eastSeat = seat(-50, -400, -PI / 2, 94)
	stool("FurnStool2", eastSeat)
	local p2 = newPlan(g2, 0, 0, 0)
	seated(p2, eastSeat)
	scene:prop("G2Slice", "Slice")
	scene:prop("G2Soda", "Soda")
	scene:place("G2Soda", 0, 48, atSeat(eastSeat, 30, 64))
	local g2Slice = {
		"R",
		off = CFrame.new(0, 0, 5) * CFrame.Angles(0.5, 0, 0),
		scale = function(u)
			return math.max(0.25, 1 - u / 9 * 0.8)
		end,
	}
	p2:still(5, P.talkTo(0.4))
	p2:still(9, P.bite, { G2Slice = g2Slice })
	p2:still(4, P.drink, { G2Soda = { "R", off = CFrame.new(0, -11, 0) } })
	p2:still(3, P.laugh)
	p2:still(9, P.bite, { G2Slice = g2Slice })
	p2:still(3, P.wave)
	p2:still(4, P.clap)
	p2:finish(48, P.rest)
	table.insert(scene.Plans, p2)

	local waiter = scene:actor("Waiter", "Waiter")
	local fridge = V2(-148, -118)
	local serve = V2(-178, -268)
	local pw = newPlan(waiter, fridge.X, fridge.Y, 0)
	scene:prop("DrinkTray", "Tray")
	scene:prop("Pad", "Notepad")
	scene:prop("Pencil", "Pencil")
	scene:prop("SodaA", "Soda")
	scene:prop("SodaB", "Soda")
	local trayHold = { "both", off = CFrame.new(0, -3, -6) }
	local full = { DrinkTray = trayHold, SodaA = { "both", off = CFrame.new(-14, -2, -6) }, SodaB = { "both", off = CFrame.new(14, -2, -6) } }
	local empty = { DrinkTray = trayHold }
	local tucked = { DrinkTray = { "L", off = CFrame.new(0, 40, 14) * CFrame.Angles(PI / 2, 0, 0) } }
	local putDown = P.reach(-0.3 * S, TABLE + 34, 1.75 * S, 0.3 * S, TABLE + 34, 1.75 * S, 1.4, 0.2)
	-- fetch drinks from the fridge, step back from the counter and bring them over
	pw:swap(1.4, P.reachOne(1.25 * S, 160, 1.4), nil, full)
	pw:walk({ V2(-148, -165) }, full, P.carry, nil, true)
	pw:walk({ serve }, full, P.carry)
	pw:turn(PI, full, P.carry)
	local tPut = pw.T
	pw:swap(1.4, putDown, full, empty)
	-- take an order from the kid
	pw:still(5, function(u, ctx)
		local s = ctx.Actor.S
		local w = math.sin(u * 9) * 4
		return {
			bob = breathe(u),
			head = { yaw = -0.7, pitch = -0.15 + (if u % 2 < 1 then 0.2 else 0) },
			armL = { at = local3(ctx, -0.1 * s, 100 + 2 * s, 0.8 * s) },
			armR = { at = local3(ctx, 0.15 * s + w, 100 + 2.05 * s, 0.7 * s) },
		}
	end, { Pad = { "L", off = CFrame.new(4, 6, -4) * CFrame.Angles(-1.1, 0, 0) }, Pencil = { "R", off = CFrame.Angles(0.6, 0.4, 0) }, DrinkTray = tucked.DrinkTray })
	-- say hello to the tiny people in the dishwasher
	pw:walk({ V2(-178, -190) }, tucked, nil, nil, true)
	pw:turn(0.35, tucked)
	pw:still(3, P.wave, tucked)
	pw:still(3, P.laugh, tucked)
	-- clear the empties from the table
	pw:turn(PI, tucked)
	pw:walk({ serve }, empty, P.carry)
	local tClear = pw.T
	pw:swap(1.4, putDown, empty, full)
	pw:walk({ V2(-148, -165) }, full, P.carry, nil, true)
	pw:turn(0, full, P.carry)
	pw:walk({ fridge }, full, P.carry)
	pw:swap(1.4, P.reachOne(1.25 * S, 160, 1.4), full, nil)
	pw:finish(48, P.idle)
	scene:place("SodaA", tPut + 0.7, tClear + 0.7, W(-192, TOP + 0.4, -358))
	scene:place("SodaB", tPut + 0.7, tClear + 0.7, W(-150, TOP + 0.4, -358))
	table.insert(scene.Plans, pw)
end

-- Level 3: Royal Banquet ---------------------------------------------------------------------------
local function buildCastle(scene: any)
	scene.Period = 60

	-- The room's throne stands too close to the end of the table for a king this size, so on this
	-- client it's swapped for a throne at the head of the table on the right (in place of that chair).
	local kingSeat = seat(94, -414, -PI / 2, 98)
	scene.Hide = { "ThroneSeat", "ThroneBack", "ThroneSpike", "ChairSeat", "ChairBack", "ChairCrest", "ChairLeg", "PlatterOnTable", "GobletStem", "GobletCup", "CandelabraBase", "CandelabraStem", "CandelabraArm", "Candle", "Flame" }
	scene.HideWhere = function(name: string, pos: Vector3): boolean
		if string.sub(name, 1, 6) == "Throne" then
			return true
		end
		-- the chair the throne replaces, and the two places nobody uses at the near end (the
		-- servant's way to the table)
		if string.sub(name, 1, 5) == "Chair" or name == "PlatterOnTable" or string.sub(name, 1, 6) == "Goblet" then
			return true -- a feast for two: the other chairs and places are cleared away
		end
		if string.sub(name, 1, 6) == "Candel" or name == "Candle" or name == "Flame" then
			return pos.Z > -300 -- the candelabra at the near end (where the roast goes)
		end
		return false
	end
	scene:prop("FurnQueenChair", "FurnHighChair")
	scene:place("FurnQueenChair", 0, 60, rootCF(-116, -414, PI / 2))
	scene:prop("FurnThrone", "FurnThrone")
	scene:place("FurnThrone", 0, 60, rootCF(116, -414, -PI / 2))
	local function atKing(right: number, fwd: number, up: number?): CFrame
		local cf = rootCF(kingSeat.X, kingSeat.Z, kingSeat.Phi) * CFrame.new(right, 0, -fwd)
		return CFrame.new(cf.X, TOP + (up or 0), cf.Z) * cf.Rotation
	end

	-- The king on his throne.
	local king = scene:actor("King", "King")
	local pkg = newPlan(king, 0, 0, 0)
	seated(pkg, kingSeat)
	scene:prop("KingLeg", "TurkeyLeg")
	scene:prop("KingCup", "Goblet")
	scene:prop("Scepter", "Scepter")
	scene:place("KingCup", 0, 60, atKing(24, 60))
	local legHold = { "R", off = CFrame.new(0, 0, 4) * CFrame.Angles(0.9, 0, 0) }
	local cupHold = { "R", off = CFrame.new(0, -12, 0) }
	local scepterHold = { "L", off = CFrame.Angles(-0.25, 0, 0) }
	pkg:still(8, P.bite, { KingLeg = legHold, Scepter = scepterHold })
	pkg:still(5, P.drink, { KingCup = cupHold, Scepter = scepterHold })
	pkg:still(4, P.laugh)
	pkg:still(3, P.point(Vector3.new(0, 0, -40)), { Scepter = scepterHold })
	pkg:still(8, P.bite, { KingLeg = legHold, Scepter = scepterHold })
	pkg:still(4, P.clap)
	pkg:still(5, P.talkTo(-0.7), { Scepter = scepterHold })
	pkg:still(4, function(u, ctx) -- a royal toast
		local s = ctx.Actor.S
		local k = smooth(math.min(u, 4 - u) / 0.8)
		return { head = { pitch = 0.2 * k }, armR = { p = 2.6 * k, r = 0.3, e = 0.3 }, armL = { at = local3(ctx, -0.6 * s, TABLE + 24, 1.2 * s) } }
	end, { KingCup = cupHold, Scepter = scepterHold })
	pkg:still(8, P.bite, { KingLeg = legHold, Scepter = scepterHold })
	pkg:finish(60, P.rest)
	pkg.Steps[#pkg.Steps].Hold = { Scepter = scepterHold }
	scene:place("KingLeg", 0, 60, atKing(-6, 70, 5) * CFrame.Angles(0, 0.4, 0))
	table.insert(scene.Plans, pkg)

	-- The queen and two nobles along the sides.
	local diners = {
		{ "Queen", "Queen", seat(-94, -414, PI / 2, 98), 1 },
	}
	for _, d in diners do
		local a = scene:actor(d[1], d[2])
		local pl = newPlan(a, 0, 0, 0)
		local st = d[3]
		seated(pl, st)
		local cup = d[1] .. "Cup"
		scene:prop(cup, "Goblet")
		local function atSeat(right: number, fwd: number, up: number?): CFrame
			local cf = rootCF(st.X, st.Z, st.Phi) * CFrame.new(right, 0, -fwd)
			return CFrame.new(cf.X, TOP + (up or 0), cf.Z) * cf.Rotation
		end
		scene:place(cup, 0, 60, atSeat(24, 60))
		local hold = { [cup] = { "R", off = CFrame.new(0, -12, 0) } }
		local fork = d[1] .. "Fork"
		scene:prop(fork, "Fork")
		scene:place(fork, 0, 60, atSeat(40, 50, 1))
		local fh = { [fork] = FORK_HOLD }
		local order = {
			{ { 7, P.eat, fh }, { 4, P.drink, hold }, { 5, P.talkTo(0.7) }, { 4, P.laugh }, { 8, P.eat, fh }, { 4, P.clap }, { 6, P.talkTo(-0.5) } },
			{ { 5, P.talkTo(-0.6) }, { 8, P.eat, fh }, { 4, P.clap }, { 5, P.drink, hold }, { 4, P.laugh }, { 8, P.eat, fh }, { 4, P.wave } },
			{ { 8, P.eat, fh }, { 4, P.laugh }, { 5, P.drink, hold }, { 4, P.clap }, { 6, P.talkTo(0.8) }, { 8, P.eat, fh } },
			{ { 4, P.drink, hold }, { 8, P.eat, fh }, { 5, P.talkTo(0.7) }, { 4, P.clap }, { 4, P.wave }, { 8, P.eat, fh } },
		}
		for _, c in order[d[4]] do
			if pl.T + c[1] <= 60 then
				pl:still(c[1], c[2], c[3])
			end
		end
		pl:finish(60, P.rest)
		table.insert(scene.Plans, pl)
	end

	-- A servant carries the roast from the mantel over the fire to the end of the table, fetches it
	-- back later and puts it back to keep warm.
	local servant = scene:actor("Servant", "Servant")
	scene:prop("Roast", "Roast")
	local mantelSpot = W(378, FLOOR + 212, -240) * CFrame.Angles(0, PI / 2, 0)
	local tableEnd = W(0, TOP + 0.4, -266)
	scene:prop("ServTray", "Tray")
	local trayOnly = { ServTray = { "both", off = CFrame.new(0, -4, -12) } }
	local roast = { ServTray = trayOnly.ServTray, Roast = { "both", off = CFrame.new(0, -2, -12) } }
	local atMantel = P.reach(-0.3 * S, 222, 1.4 * S, 0.3 * S, 222, 1.4 * S, 1.6, 0)
	local atTable = P.reach(-0.3 * S, TABLE + 34, 1.55 * S, 0.3 * S, TABLE + 34, 1.55 * S, 1.4, 0.2)
	local back = V2(255, -240)
	local up = V2(290, -240)
	local toTable = { V2(250, -182), V2(12, -182), V2(0, -184) }
	local toFire = { V2(40, -182), V2(250, -182), back }
	local ps = newPlan(servant, back.X, back.Y, PI / 2)
	ps:still(2, P.carry, trayOnly)
	ps:walk({ up }, trayOnly, P.carry, 60)
	local tFire = ps.T
	ps:swap(1.6, atMantel, trayOnly, roast)
	ps:walk({ back }, roast, P.carry, nil, true)
	ps:walk(toTable, roast, P.carry, 95)
	ps:turn(PI, roast, P.carry)
	local tServe = ps.T
	ps:swap(1.4, atTable, roast, trayOnly)
	ps:still(1.2, function(u, ctx)
		local p = P.carry(u, ctx)
		p.lean = 0.3 * math.sin(math.clamp(u / 1.2, 0, 1) * PI) -- a bow
		return p
	end, trayOnly)
	ps:walk(toFire, trayOnly, P.carry, 95)
	ps:turn(PI / 2, trayOnly, P.carry)
	ps:still(6, function(u, ctx) -- a moment by the fire
		local p = P.carry(u, ctx)
		p.head = { yaw = math.sin(u * 0.5) * 0.5 }
		p.bob = breathe(u)
		return p
	end, trayOnly)
	ps:walk(toTable, trayOnly, P.carry, 95)
	ps:turn(PI, trayOnly, P.carry)
	local tTake = ps.T
	ps:swap(1.4, atTable, trayOnly, roast)
	ps:walk(toFire, roast, P.carry, 95)
	ps:turn(PI / 2, roast, P.carry)
	ps:walk({ up }, roast, P.carry, 60)
	local tBack = ps.T
	ps:swap(1.6, atMantel, roast, trayOnly)
	ps:walk({ back }, trayOnly, P.carry, nil, true)
	ps:finish(60, P.carry)
	ps.Steps[#ps.Steps].Hold = trayOnly
	table.insert(scene.Plans, ps)
	scene:place("Roast", tServe + 0.7, tTake + 0.7, tableEnd)
	scene:place("Roast", tBack + 0.8, tFire + 0.8 + 60, mantelSpot)

	-- The jester juggles for the king, bows, and cartwheels.
	local jester = scene:actor("Jester", "Jester")
	-- He plays to the players: always turned toward the dishwasher (the room origin).
	local JX, JZ = -205, -200
	local facePlayers = math.atan2(-JX, -JZ)
	local pj = newPlan(jester, JX, JZ, facePlayers)
	local balls = { "BallA", "BallB", "BallC" }
	local ballColors = { rgb(255, 80, 80), rgb(80, 180, 255), rgb(255, 220, 60) }
	for i, n in balls do
		local b = scene:prop(n, "Ball")
		for _, pc in b.Pieces do
			pc.Part.Color = ballColors[i]
		end
	end
	local function juggleHolds(): any
		local h = {}
		for i, n in balls do
			h[n] = {
				"root",
				off = function(u)
					local s = S
					local ph = (u * 1.4 + (i - 1) / 3) % 1
					local fromX = if ph < 0.5 then -0.45 else 0.45
					local x = lerp(fromX, -fromX, ph % 0.5 * 2) * s
					local y = 100 + 1.7 * s + math.sin((ph % 0.5) * 2 * PI) * 1.6 * s
					return CFrame.new(x, y, -0.9 * s)
				end,
			}
		end
		return h
	end
	local function juggle(u: number, ctx: any): Pose
		local s = ctx.Actor.S
		local l = math.sin(u * 1.4 * PI * 2)
		return {
			bob = math.abs(math.sin(u * 4)) * 0.03,
			head = { pitch = 0.3 + math.sin(u * 2.8 * PI) * 0.1 },
			armL = { at = local3(ctx, -0.45 * s, 100 + (1.7 + l * 0.15) * s, 0.85 * s) },
			armR = { at = local3(ctx, 0.45 * s, 100 + (1.7 - l * 0.15) * s, 0.85 * s) },
		}
	end
	local function bow(u: number, ctx: any): Pose
		local k = math.sin(math.clamp(u / 2.2, 0, 1) * PI)
		return { lean = 0.45 * k, head = { pitch = -0.3 * k }, armL = { p = -0.3 * k, r = 0.35 * k, e = 0.2 }, armR = { p = 0.5 * k, r = -0.1, e = 1.8 * k } }
	end
	-- Cartwheels run along the open lane parallel to the dishwasher wall (room X), squared up to the
	-- players, so the spinning arms and legs clear the pillars, the guards and the table.
	local function cartwheel(fromX: number, toX: number, dur: number)
		pj:add(dur, function(u)
			return lerp(fromX, toX, smooth(u / dur)), JZ, 0
		end, function(u, ctx)
			local s = ctx.Actor.S
			local k = math.clamp(u / dur, 0, 1)
			local th = smooth(k) * PI * 2 * (if toX > fromX then -1 else 1)
			local lift = math.sin(k * PI) * 0.7
			return {
				body = CFrame.new(0, (1.1 + lift) * s, 0) * CFrame.Angles(0, 0, th) * CFrame.new(0, -1.1 * s, 0),
				armL = { p = 0, r = 2.9, e = 0 },
				armR = { p = 0, r = 2.9, e = 0 },
				legs = { outL = 0.5 * math.sin(k * PI), outR = 0.5 * math.sin(k * PI) },
			}
		end)
		pj.X, pj.Z, pj.Phi = toX, JZ, 0
	end
	pj:still(9, juggle, juggleHolds())
	pj:still(2.2, bow)
	pj:turn(0)
	cartwheel(JX, JX + 16, 1.1)
	pj:still(1.2, function(u, ctx)
		local p = P.idle(u, ctx)
		p.armL = { p = 0.2, r = 2.6, e = 0.2 }
		p.armR = { p = 0.2, r = 2.6, e = 0.2 }
		return p
	end)
	cartwheel(JX + 16, JX + 34, 1.1)
	pj:still(1.2, P.laugh)
	cartwheel(JX + 34, JX, 1.6) -- and one big one back to his spot
	pj:turn(facePlayers)
	pj:still(9, juggle, juggleHolds())
	pj:still(2.2, bow)
	pj:still(4, P.wave)
	pj:finish(60, juggle)
	pj.Steps[#pj.Steps].Hold = juggleHolds()
	-- between juggling the balls are tucked away
	table.insert(scene.Plans, pj)

	-- Guards: one on duty by the right-hand pillars, one marching along the left side.
	local g1 = scene:actor("Guard1", "Guard")
	local g2 = scene:actor("Guard2", "Guard")
	scene:prop("Spear1", "Spear")
	scene:prop("Spear2", "Spear")
	local spear = function(name: string)
		return { [name] = { "R", off = CFrame.new(0, 0, 0) } }
	end
	local function attention(u: number, ctx: any): Pose
		return {
			bob = breathe(u) * 0.5,
			head = { yaw = math.sin(u * 0.25) * 0.25 },
			armR = { p = 0.35, r = 0.12, e = 1.2 },
			armL = { p = 0, r = 0.02, e = 0.05 },
		}
	end
	-- both stand their posts (a patrol would swing their arms into the armour and pillars)
	local function stomp(u: number, ctx: any): Pose
		local p = attention(u, ctx)
		p.walk = u * PI * 2
		p.stride = 0.25
		return p
	end
	local pa = newPlan(g1, 285, -400, 0)
	pa:still(18, attention, spear("Spear1"))
	pa:still(3, P.point(Vector3.new(0, 0, -40)), spear("Spear1"))
	pa:still(3, stomp, spear("Spear1"))
	pa:still(20, attention, spear("Spear1"))
	pa:still(3, stomp, spear("Spear1"))
	pa:finish(60, attention)
	pa.Steps[#pa.Steps].Hold = spear("Spear1")
	table.insert(scene.Plans, pa)

	local pb = newPlan(g2, -270, -400, 0)
	pb:still(9, attention, spear("Spear2"))
	pb:still(3, stomp, spear("Spear2"))
	pb:still(14, attention, spear("Spear2"))
	pb:still(3, P.laugh, spear("Spear2"))
	pb:still(12, attention, spear("Spear2"))
	pb:still(3, stomp, spear("Spear2"))
	pb:finish(60, attention)
	pb.Steps[#pb.Steps].Hold = spear("Spear2")
	table.insert(scene.Plans, pb)
end

local BUILDERS = { buildFamily, buildPizzeria, buildCastle }

function LevelNPCs.Build(levelIndex: number, origin: CFrame, parent: Instance): any
	local self = newScene(origin, parent)
	local build = BUILDERS[levelIndex] or BUILDERS[1]
	build(self)
	return self
end

-- A test lineup of every look in a few poses (for screenshots).
function LevelNPCs.Lineup(origin: CFrame, parent: Instance): any
	local self = newScene(origin, parent)
	local names = { "Dad", "Mum", "Kid", "Grandpa", "Chef", "Waiter", "Guest1", "Guest2", "King", "Queen", "Noble1", "Servant", "Guard", "Jester" }
	for i, n in names do
		local a = self:actor(n, n)
		local x = (i - 7.5) * 150
		local plan = newPlan(a, x, 0, 0)
		plan:still(10, P.idle)
		plan:finish(10, P.idle)
		table.insert(self.Plans, plan)
	end
	self.Period = 10
	return self
end

----------------------------------------------------------------------------------------------------
-- Runtime: the people for the dishwasher you're playing in
----------------------------------------------------------------------------------------------------

local initialized = false
local cutsceneMode = false
local cutsceneHide: { [string]: boolean } = {}

-- The story cutscene is playing in this room: hide the room's people (their furniture stays,
-- except the pieces named in `hide`, which the cutscene brings and moves itself).
function LevelNPCs.SetCutscene(on: boolean, hide: { string }?)
	cutsceneMode = on == true
	cutsceneHide = {}
	for _, n in (hide or {}) :: { string } do
		cutsceneHide[n] = true
	end
end

function LevelNPCs.Init()
	if initialized then
		return
	end
	initialized = true
	local ClientState = require(script.Parent:WaitForChild("ClientState")) :: any
	local current: any = nil
	local currentArena: Instance? = nil
	local hidden: { [BasePart]: boolean } = {}
	local added: RBXScriptConnection? = nil
	local failed = false

	-- Furniture the NPCs replace (and the right table's pizza in the pizzeria) is hidden on this
	-- client only; it can't be reached from the dishwasher anyway.
	local function hidePart(scene: any, part: Instance)
		if not part:IsA("BasePart") or not scene.HideSet[part.Name] then
			return
		end
		if scene.HideWhere then
			local p = scene.Origin:PointToObjectSpace(part.Position)
			if not scene.HideWhere(part.Name, Vector3.new(p.X, p.Y, -p.Z)) then
				return
			end
		end
		part.LocalTransparencyModifier = 1
		hidden[part] = true
	end

	local function teardown()
		if added then
			added:Disconnect()
			added = nil
		end
		if current then
			pcall(function()
				current:Destroy()
			end)
			current = nil
		end
		for part in hidden do
			if part.Parent then
				part.LocalTransparencyModifier = 0
			end
		end
		table.clear(hidden)
		currentArena = nil
	end

	RunService.Heartbeat:Connect(function()
		local arena = ClientState.GetArena()
		if arena ~= currentArena then
			teardown()
			local originPos = arena and arena:GetAttribute("Origin")
			if arena and typeof(originPos) == "Vector3" then
				currentArena = arena
				local level = tonumber(arena:GetAttribute("Level")) or 1
				local ok, scene = pcall(LevelNPCs.Build, level, CFrame.new(originPos), Workspace)
				if ok then
					current = scene
					scene.HideSet = {}
					for _, n in scene.Hide or {} do
						scene.HideSet[n] = true
					end
					for _, d in arena:GetDescendants() do
						hidePart(scene, d)
					end
					added = arena.DescendantAdded:Connect(function(d)
						hidePart(scene, d)
					end)
				elseif not failed then
					failed = true
					warn("[LevelNPCs] couldn't build the level's people: " .. tostring(scene))
				end
			end
		end
		if current then
			current.CutsceneMode = cutsceneMode
			current.CutsceneHide = cutsceneHide
			local okNow, now = pcall(function()
				return Workspace:GetServerTimeNow()
			end)
			local ok, err = pcall(current.Update, current, if okNow and type(now) == "number" then now else os.clock())
			if not ok and not failed then
				failed = true
				warn("[LevelNPCs] " .. tostring(err))
			end
		end
	end)
end

LevelNPCs.P = P
LevelNPCs.newPlan = newPlan
LevelNPCs.newScene = newScene
LevelNPCs.rootCF = rootCF

-- Everything the run-start cutscenes (CutsceneKit and the chapters) build their casts from: the
-- same rig, looks, props, plans and poses as the people in the rooms.
LevelNPCs.Kit = {
	S = S,
	FLOOR = FLOOR,
	TABLE = TABLE,
	P = P,
	LOOKS = LOOKS,
	PROPS = PROPS,
	newPlan = newPlan,
	newScene = newScene,
	newPart = newPart,
	rootCF = rootCF,
	W = W,
	seat = seat,
	seated = seated,
	smooth = smooth,
	lerp = lerp,
	local3 = local3,
	breathe = breathe,
	lookAround = lookAround,
	angleDiff = angleDiff,
	phiOf = phiOf,
	disc = disc,
	hairShort = hairShort,
	hairLong = hairLong,
	partyHat = partyHat,
	crown = crown,
	glasses = glasses,
	beard = beard,
	apron = apron,
	belt = belt,
	collar = collar,
	FORK_HOLD = FORK_HOLD,
}

return LevelNPCs
