--[[
	CutsceneScene - the set, actors and timeline for the run-start cutscene (played by Cutscene).

	The story (no words, just implied): a family finishes a meal, Mum stacks the dirty plates,
	loads them into the dishwasher, shuts the door and presses Start... and the camera pushes into
	the dishwasher, where (cut to the game) it turns out the cleaning is done by us.

	Everything is a pure function of time: Scene.Build(levelIndex, origin, parent) makes the parts
	(client-only, far from the map) and returns a scene; scene:Update(t) poses every actor and prop
	for time t; scene:Camera(t) returns the camera CFrame and field of view. Skipping is just "stop
	calling Update". Three flavours by level: family dinner (spaghetti), pizza party (pizza, party
	hats, balloons) and royal banquet (gold plates, crowns, roast, candles).

	Scene space: +X right, +Y up, +Z toward the back wall; the camera mostly looks down +Z.
]]

local Scene = {}
Scene.__index = Scene

Scene.Duration = 20.5

local SKIN = Color3.fromRGB(245, 205, 150)
local WHITE = Color3.fromRGB(250, 250, 248)

-- Level flavours.
local THEMES = {
	{ -- 1: Family Dinner
		Wall = Color3.fromRGB(236, 222, 196), Floor = Color3.fromRGB(176, 128, 86), FloorMat = Enum.Material.WoodPlanks,
		Table = Color3.fromRGB(150, 104, 70), Cloth = nil, PlateRim = Color3.fromRGB(120, 175, 230), PlateBody = WHITE,
		Counter = Color3.fromRGB(240, 238, 232), CounterTop = Color3.fromRGB(215, 215, 220),
		Shirts = { Color3.fromRGB(70, 110, 190), Color3.fromRGB(220, 90, 110), Color3.fromRGB(110, 190, 110) },
		Pants = { Color3.fromRGB(60, 60, 80), Color3.fromRGB(70, 70, 90), Color3.fromRGB(90, 70, 60) },
		Food = "Spaghetti", Mess = { Color3.fromRGB(190, 45, 35), Color3.fromRGB(120, 75, 40) },
	},
	{ -- 2: Pizza Party
		Wall = Color3.fromRGB(250, 226, 200), Floor = Color3.fromRGB(235, 235, 230), FloorMat = Enum.Material.SmoothPlastic,
		Table = Color3.fromRGB(120, 80, 50), Cloth = { Color3.fromRGB(214, 60, 55), WHITE }, PlateRim = Color3.fromRGB(220, 60, 50), PlateBody = WHITE,
		Counter = Color3.fromRGB(200, 205, 212), CounterTop = Color3.fromRGB(176, 124, 78),
		Shirts = { Color3.fromRGB(255, 160, 40), Color3.fromRGB(120, 90, 220), Color3.fromRGB(40, 180, 200) },
		Pants = { Color3.fromRGB(50, 60, 90), Color3.fromRGB(60, 60, 60), Color3.fromRGB(80, 60, 100) },
		Food = "Pizza", Mess = { Color3.fromRGB(214, 58, 34), Color3.fromRGB(255, 200, 60) }, Party = true,
	},
	{ -- 3: Royal Banquet
		Wall = Color3.fromRGB(150, 144, 136), WallMat = Enum.Material.Cobblestone, Floor = Color3.fromRGB(120, 25, 35), FloorMat = Enum.Material.Fabric,
		Table = Color3.fromRGB(92, 58, 38), Cloth = nil, PlateRim = Color3.fromRGB(230, 190, 90), PlateBody = Color3.fromRGB(245, 215, 120),
		Counter = Color3.fromRGB(92, 58, 38), CounterTop = Color3.fromRGB(238, 232, 222),
		Shirts = { Color3.fromRGB(140, 30, 50), Color3.fromRGB(70, 40, 140), Color3.fromRGB(30, 100, 70) },
		Pants = { Color3.fromRGB(230, 190, 90), Color3.fromRGB(40, 30, 60), Color3.fromRGB(50, 40, 30) },
		Food = "Roast", Mess = { Color3.fromRGB(110, 70, 40), Color3.fromRGB(240, 235, 220) }, Royal = true,
	},
}

-- Layout (scene space).
local TABLE_C = Vector3.new(-4, 0, 7)
local TABLE_TOP = 3
local DW = Vector3.new(15.5, 0, 13.5) -- dishwasher centre on the floor
local DW_FRONT_Z = 12 -- its door's plane
local SEAT_Y = 1.6

----------------------------------------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------------------------------------

local function smooth(x: number): number
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- 0 before a, 1 after b, smooth in between.
local function phase(t: number, a: number, b: number): number
	return smooth((t - a) / (b - a))
end

function Scene:part(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	-- A Ball part is always perfectly round (Roblox uses its smallest side), so a squashed ball
	-- (a pasta mound, a roast, a balloon) is a block wearing a sphere mesh instead.
	local stretched = shape == Enum.PartType.Ball and (math.abs(size.X - size.Y) > 1e-3 or math.abs(size.Y - size.Z) > 1e-3)
	if shape and not stretched then
		p.Shape = shape
	end
	if stretched then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
	end
	p.Size = size
	p.CFrame = self.Origin * cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = self.Folder
	return p
end

function Scene:box(name: string, x0: number, x1: number, y0: number, y1: number, z0: number, z1: number, color: Color3, material: Enum.Material?): Part
	return self:part(name, Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)), CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2), color, material)
end

-- Upright cylinder centred at (x, y, z).
function Scene:disc(name: string, h: number, d: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?): Part
	return self:part(name, Vector3.new(h, d, d), CFrame.new(x, y, z) * CFrame.Angles(0, 0, math.rad(90)), color, material, Enum.PartType.Cylinder)
end

-- Places a part at a scene-space CFrame (used by Update, every frame).
function Scene:place(p: BasePart, cf: CFrame)
	p.CFrame = self.Origin * cf
end

----------------------------------------------------------------------------------------------------
-- Actors: a classic blocky figure with a real Roblox head and smile.
----------------------------------------------------------------------------------------------------

type Actor = { Parts: { [string]: BasePart }, Hat: { { Part: BasePart, Offset: CFrame } }, Scale: number }

function Scene:actor(name: string, shirt: Color3, pants: Color3, scale: number?): Actor
	local sc = scale or 1
	local parts: { [string]: BasePart } = {}
	parts.Torso = self:part(name .. "Torso", Vector3.new(2, 2, 1) * sc, CFrame.new(), shirt)
	parts.LeftArm = self:part(name .. "LeftArm", Vector3.new(1, 2, 1) * sc, CFrame.new(), shirt)
	parts.RightArm = self:part(name .. "RightArm", Vector3.new(1, 2, 1) * sc, CFrame.new(), shirt)
	-- Legs a touch narrower than half the torso, so their outer sides never line up with its sides.
	parts.LeftLeg = self:part(name .. "LeftLeg", Vector3.new(0.9, 2, 0.9) * sc, CFrame.new(), pants)
	parts.RightLeg = self:part(name .. "RightLeg", Vector3.new(0.9, 2, 0.9) * sc, CFrame.new(), pants)
	local head = self:part(name .. "Head", Vector3.new(2, 1, 1) * sc, CFrame.new(), SKIN)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = Vector3.new(1.25, 1.25, 1.25)
	mesh.Parent = head
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Face = Enum.NormalId.Front
	face.Texture = "rbxasset://textures/face.png"
	face.Parent = head
	parts.Head = head
	for _, limb in { "LeftArm", "RightArm" } do
		-- Hands in skin tone.
		parts[limb .. "Hand"] = self:part(name .. limb .. "Hand", Vector3.new(1.1, 0.5, 1.1) * sc, CFrame.new(), SKIN)
	end
	return { Parts = parts, Hat = {}, Scale = sc }
end

-- Something worn on the head (party hat, crown), placed relative to the head.
function Scene:hat(actor: Actor, p: BasePart, offset: CFrame)
	table.insert(actor.Hat, { Part = p, Offset = offset })
end

-- Pose an actor. root = feet position + facing (LookVector = where they face). sit bends the legs
-- forward (sitK blends between standing, 0, and sitting, 1, for getting up); walk is a phase
-- (radians) for the stride; armL / armR raise the arms forward (radians). Returns the right hand's
-- CFrame (scene space) so props can be held.
function Scene:pose(a: Actor, root: CFrame, pose: { sit: boolean?, sitK: number?, walk: number?, armL: number?, armR: number?, bob: number? }): CFrame
	local p = a.Parts
	local sc = a.Scale
	local sitK = pose.sitK or (if pose.sit then 1 else 0)
	local hip = (SEAT_Y + 0.5 * sc) * sitK + 2 * sc * (1 - sitK) -- seated: thighs rest on the seat
	local base = root * CFrame.new(0, hip - 2 * sc + (pose.bob or 0), 0)
	local swing = if pose.walk then math.sin(pose.walk) * 0.65 else 0
	local rightHand = base
	self:place(p.Torso, base * CFrame.new(0, 3 * sc, 0))
	self:place(p.Head, base * CFrame.new(0, 4.5 * sc, 0))
	for _, h in a.Hat do
		self:place(h.Part, base * CFrame.new(0, 4.5 * sc, 0) * h.Offset)
	end
	for side, name in { [-1] = "Left", [1] = "Right" } do
		local legAngle = math.rad(90) * sitK + swing * side * (1 - sitK)
		self:place(p[name .. "Leg"], base * CFrame.new(side * 0.5 * sc, 2 * sc, 0) * CFrame.Angles(legAngle, 0, 0) * CFrame.new(0, -sc, 0))
		local armAngle = (if side < 0 then pose.armL else pose.armR) or (-swing * side * 0.8)
		local shoulder = base * CFrame.new(side * 1.5 * sc, 3.9 * sc, 0) * CFrame.Angles(armAngle, 0, 0)
		self:place(p[name .. "Arm"], shoulder * CFrame.new(0, -0.9 * sc, 0))
		self:place(p[name .. "ArmHand"], shoulder * CFrame.new(0, -1.75 * sc, 0))
		if side > 0 then
			rightHand = shoulder * CFrame.new(0, -1.75 * sc, 0)
		end
	end
	return rightHand
end

----------------------------------------------------------------------------------------------------
-- Build
----------------------------------------------------------------------------------------------------

-- A plate with its meal on it; returns { Plate, Food = {parts}, Mess = {parts} } (scene-space
-- offsets remembered so the whole stack can be moved as one).
function Scene:plate(x: number, z: number)
	local th = self.Theme
	local items = {}
	local function add(p: BasePart, kind: string)
		table.insert(items, { Part = p, Kind = kind, Offset = (CFrame.new(x, TABLE_TOP, z)):ToObjectSpace(self.Origin:ToObjectSpace(p.CFrame)) })
	end
	-- Rim 0 to 0.08, face 0.03 to 0.12: no face of one ever lies on (or right next to) the other's.
	add(self:disc("Plate", 0.08, 1.9, x, TABLE_TOP + 0.04, z, th.PlateRim), "Plate")
	add(self:disc("PlateFace", 0.09, 1.6, x, TABLE_TOP + 0.075, z, th.PlateBody), "Plate")
	-- Food (visible while eating): a proper plated meal for each theme.
	local top = TABLE_TOP + 0.12 -- the plate's surface
	local function ball(name: string, size: Vector3, dx: number, dy: number, dz: number, color: Color3, kind: string)
		add(self:part(name, size, CFrame.new(x + dx, top + dy, z + dz), color, nil, Enum.PartType.Ball), kind)
	end
	local function flat(name: string, h: number, d: number, dx: number, dy: number, dz: number, color: Color3, kind: string)
		add(self:disc(name, h, d, x + dx, top + dy, z + dz, color), kind)
	end
	if th.Food == "Spaghetti" then
		-- Spaghetti and meatballs: a low, wide nest of noodles (a flat base with swirled strands on
		-- top, not a ball), a pool of tomato sauce, and three meatballs sitting down in the sauce,
		-- with parmesan and a basil leaf.
		local noodle = Color3.fromRGB(245, 212, 130)
		flat("Pasta", 0.08, 1.3, 0, 0.04, 0, Color3.fromRGB(238, 202, 118), "Food")
		ball("PastaNest", Vector3.new(1.15, 0.34, 1.1), 0, 0.14, 0, noodle, "Food")
		ball("PastaTop", Vector3.new(0.8, 0.26, 0.76), -0.04, 0.22, 0.03, Color3.fromRGB(250, 220, 145), "Food")
		ball("TomatoSauce", Vector3.new(0.74, 0.14, 0.68), 0.02, 0.33, -0.02, Color3.fromRGB(196, 42, 30), "Food")
		for i = 0, 2 do
			local a = i / 3 * math.pi * 2 + 0.4
			ball("Meatball", Vector3.one * 0.24, math.cos(a) * 0.17, 0.38, math.sin(a) * 0.17, Color3.fromRGB(115, 58, 36), "Food")
		end
		for i = 0, 3 do
			ball("Parmesan", Vector3.one * 0.05, (i % 2 - 0.5) * 0.36, 0.39, (i // 2 - 0.5) * 0.3, Color3.fromRGB(252, 248, 230), "Food")
		end
		add(self:part("Basil", Vector3.new(0.22, 0.03, 0.13), CFrame.new(x + 0.05, top + 0.51, z - 0.05) * CFrame.Angles(0, math.rad(35), 0), Color3.fromRGB(60, 150, 60)), "Food")
	elseif th.Food == "Pizza" then
		-- A personal pepperoni pizza cut into quarters: crust, cheese, pepperoni, cut lines.
		flat("PizzaCrust", 0.1, 1.5, 0, 0.05, 0, Color3.fromRGB(214, 160, 90), "Food")
		flat("PizzaSauce", 0.04, 1.34, 0, 0.12, 0, Color3.fromRGB(200, 55, 35), "Food")
		flat("PizzaCheese", 0.04, 1.26, 0, 0.15, 0, Color3.fromRGB(252, 212, 110), "Food")
		-- One pepperoni in the middle of each quarter (never on a cut line).
		for i = 0, 3 do
			local a = math.rad(45 + i * 90)
			flat("Pepperoni", 0.03, 0.26, math.cos(a) * 0.36, 0.19, math.sin(a) * 0.36, Color3.fromRGB(170, 35, 30), "Food")
		end
		add(self:part("PizzaCut", Vector3.new(1.28, 0.02, 0.03), CFrame.new(x, top + 0.2, z), Color3.fromRGB(150, 100, 55)), "Food")
		add(self:part("PizzaCut", Vector3.new(0.03, 0.02, 1.28), CFrame.new(x, top + 0.2, z), Color3.fromRGB(150, 100, 55)), "Food")
	else
		-- Royal roast: a chicken leg, a scoop of mashed potato with gravy, peas and carrots.
		ball("ChickenLeg", Vector3.new(0.72, 0.42, 0.52), -0.18, 0.2, 0.08, Color3.fromRGB(176, 104, 48), "Food")
		add(self:part("LegBone", Vector3.new(0.4, 0.1, 0.1), CFrame.new(x + 0.28, top + 0.2, z + 0.2) * CFrame.Angles(0, math.rad(-25), 0), Color3.fromRGB(246, 238, 222), nil, Enum.PartType.Cylinder), "Food")
		ball("BoneKnob", Vector3.one * 0.14, 0.47, 0.2, 0.29, Color3.fromRGB(246, 238, 222), "Food")
		ball("Mash", Vector3.new(0.5, 0.3, 0.5), 0.28, 0.15, -0.32, Color3.fromRGB(250, 238, 200), "Food")
		ball("Gravy", Vector3.new(0.3, 0.1, 0.3), 0.28, 0.29, -0.32, Color3.fromRGB(120, 72, 36), "Food")
		for i = 0, 3 do
			ball("Pea", Vector3.one * 0.1, -0.35 + i * 0.1, 0.05, -0.42 + (i % 2) * 0.08, Color3.fromRGB(100, 180, 60), "Food")
		end
		for i = 0, 2 do
			add(self:part("Carrot", Vector3.new(0.22, 0.08, 0.08), CFrame.new(x - 0.4 + i * 0.12, top + 0.05, z - 0.18 + i * 0.03) * CFrame.Angles(0, math.rad(30 * i), 0), Color3.fromRGB(240, 130, 40), nil, Enum.PartType.Cylinder), "Food")
		end
	end
	-- Mess (visible once the meal's eaten): what's left on a finished plate.
	local mess = th.Mess
	-- Smears float a hair above the plate (and each other), never sharing its surface.
	flat("Smear", 0.02, 0.9, -0.15, 0.02, 0.1, mess[1], "Mess")
	flat("Smear", 0.02, 0.5, 0.3, 0.06, -0.25, mess[2], "Mess")
	if th.Food == "Pizza" then
		for i = 0, 1 do
			add(self:part("CrustEnd", Vector3.new(0.45, 0.06, 0.12), CFrame.new(x - 0.2 + i * 0.35, top + 0.11, z + 0.3 - i * 0.5) * CFrame.Angles(0, math.rad(40 + i * 60), 0), Color3.fromRGB(214, 160, 90)), "Mess")
		end
	elseif th.Royal then
		add(self:part("CleanBone", Vector3.new(0.5, 0.1, 0.1), CFrame.new(x + 0.1, top + 0.06, z + 0.2) * CFrame.Angles(0, math.rad(20), 0), Color3.fromRGB(246, 238, 222), nil, Enum.PartType.Cylinder), "Mess")
	else
		add(self:part("Noodle", Vector3.new(0.5, 0.04, 0.04), CFrame.new(x + 0.1, top + 0.04, z - 0.1) * CFrame.Angles(0, math.rad(25), 0), Color3.fromRGB(245, 212, 130), nil, Enum.PartType.Cylinder), "Mess")
	end
	ball("Crumb", Vector3.one * 0.12, -0.45, 0.06, -0.3, mess[2], "Mess")
	return { X = x, Z = z, Items = items }
end

function Scene.Build(levelIndex: number, origin: CFrame, parent: Instance)
	local self = setmetatable({}, Scene)
	self.Theme = THEMES[levelIndex] or THEMES[1]
	self.Origin = origin
	local folder = Instance.new("Folder")
	folder.Name = "CutsceneScene"
	folder.Parent = parent
	self.Folder = folder
	local th = self.Theme

	-- Room.
	self:box("Floor", -20, 24, -1, 0, -16, 19, th.Floor, th.FloorMat)
	self:box("BackWall", -20, 24, 0, 16, 18, 19, th.Wall, th.WallMat)
	self:box("LeftWall", -21, -20, 0, 16, -16, 19, th.Wall, th.WallMat)
	self:box("RightWall", 23, 24, 0, 16, -16, 19, th.Wall, th.WallMat)
	self:box("Skirting", -20, 10.9, 0, 0.6, 17.8, 18, Color3.new(1, 1, 1)) -- stops where the counter starts
	-- Window with daylight.
	self:box("Window", -12, -2, 6, 12, 17.9, 18.1, Color3.fromRGB(190, 225, 255), Enum.Material.Neon)
	self:box("WindowBar", -7.1, -6.9, 6, 12, 17.7, 17.9, Color3.new(1, 1, 1))
	self:box("WindowBar", -12, -2, 8.9, 9.1, 17.7, 17.9, Color3.new(1, 1, 1))
	self:box("Sill", -12.5, -1.5, 5.7, 6, 17.3, 18, Color3.new(1, 1, 1))

	-- Table (and a checked cloth for the party).
	local tx, tz = TABLE_C.X, TABLE_C.Z
	self:box("TableTop", tx - 4.2, tx + 4.2, TABLE_TOP - 0.3, TABLE_TOP, tz - 2.4, tz + 2.4, th.Table, Enum.Material.Wood)
	for _, lx in { tx - 3.8, tx + 3.8 } do
		for _, lz in { tz - 2, tz + 2 } do
			self:box("TableLeg", lx - 0.2, lx + 0.2, 0, TABLE_TOP - 0.3, lz - 0.2, lz + 0.2, th.Table, Enum.Material.Wood)
		end
	end
	if th.Cloth then
		for i = 0, 7 do
			for j = 0, 4 do
				self:box("Cloth", tx - 4.2 + i * 1.05, tx - 4.2 + (i + 1) * 1.05, TABLE_TOP, TABLE_TOP + 0.02, tz - 2.4 + j * 0.96, tz - 2.4 + (j + 1) * 0.96, th.Cloth[(i + j) % 2 + 1], Enum.Material.Fabric)
			end
		end
	end
	-- Chairs.
	local function chair(x: number, z: number, faceZ: number)
		self:box("Seat", x - 1, x + 1, SEAT_Y - 0.3, SEAT_Y, z - 1, z + 1, th.Table, Enum.Material.Wood)
		self:box("ChairBack", x - 1, x + 1, SEAT_Y, SEAT_Y + 2.6, z + faceZ * 0.9, z + faceZ * 1.05, th.Table, Enum.Material.Wood)
		for _, lx in { x - 0.8, x + 0.8 } do
			for _, lz in { z - 0.8, z + 0.8 } do
				self:box("ChairLeg", lx - 0.12, lx + 0.12, 0, SEAT_Y - 0.3, lz - 0.12, lz + 0.12, th.Table, Enum.Material.Wood)
			end
		end
	end
	chair(tx - 2.1, tz + 3.4, 1)
	chair(tx + 2.1, tz + 3.4, 1)
	-- Mum's chair at the left end, its back on the far (-X) side.
	local mx, mz = tx - 6, tz - 0.8
	self:box("Seat", mx - 1, mx + 1, SEAT_Y - 0.3, SEAT_Y, mz - 1, mz + 1, th.Table, Enum.Material.Wood)
	self:box("ChairBack", mx - 1.05, mx - 0.9, SEAT_Y, SEAT_Y + 2.6, mz - 1, mz + 1, th.Table, Enum.Material.Wood)
	for _, lx in { mx - 0.8, mx + 0.8 } do
		for _, lz in { mz - 0.8, mz + 0.8 } do
			self:box("ChairLeg", lx - 0.12, lx + 0.12, 0, SEAT_Y - 0.3, lz - 0.12, lz + 0.12, th.Table, Enum.Material.Wood)
		end
	end

	-- Kitchen: counter run with the dishwasher in it.
	-- The cupboards stop either side of the dishwasher so its open front really is open.
	self:box("Counter", 11, DW.X - 1.62, 0, 3.4, 12.2, 18, th.Counter)
	self:box("Counter", DW.X + 1.62, 23, 0, 3.4, 12.2, 18, th.Counter)
	self:box("Kickboard", DW.X - 1.62, DW.X + 1.62, 0, 0.2, 12.4, 18, Color3.fromRGB(60, 62, 68))
	self:box("CounterTop", 10.8, 23, 3.4, 3.7, 11.9, 18, th.CounterTop, Enum.Material.Marble)
	-- The dishwasher is hollow (panels, not a block) so the camera can go inside at the end.
	local steel = Color3.fromRGB(170, 176, 184)
	local x0, x1, z0, z1 = DW.X - 1.6, DW.X + 1.6, DW_FRONT_Z + 0.25, 17.5
	self:box("DWSide", x0, x0 + 0.15, 0.2, 3.1, z0, z1, steel, Enum.Material.Metal)
	self:box("DWSide", x1 - 0.15, x1, 0.2, 3.1, z0, z1, steel, Enum.Material.Metal)
	self:box("DWTop", x0, x1, 2.95, 3.1, z0, z1, steel, Enum.Material.Metal)
	self:box("DWFloor", x0, x1, 0.2, 0.35, z0, z1, steel, Enum.Material.Metal)
	self:box("DWBack", x0, x1, 0.2, 3.1, z1 - 0.15, z1, steel, Enum.Material.Metal)
	self:box("DWRack", x0 + 0.2, x1 - 0.2, 0.9, 0.96, z0 + 0.1, z1 - 0.2, Color3.fromRGB(235, 238, 242), Enum.Material.Metal)
	self.InnerLight = Instance.new("PointLight")
	self.InnerLight.Color = Color3.fromRGB(150, 220, 255)
	self.InnerLight.Range = 6
	self.InnerLight.Brightness = 0
	self.InnerLight.Parent = self:box("DWLamp", DW.X - 0.3, DW.X + 0.3, 2.85, 2.95, 14.6, 15.2, Color3.fromRGB(220, 240, 255), Enum.Material.Neon)
	-- The twist: tiny workers already waiting on the rack, sponges in hand (that's us).
	self.Workers = {}
	-- A crew: matching caps, their own shirts, a sponge each.
	local wsc = 0.22
	for i, c in { Color3.fromRGB(255, 200, 60), Color3.fromRGB(90, 170, 255), Color3.fromRGB(255, 110, 150) } do
		local w = self:actor("Worker" .. i, c, Color3.fromRGB(50, 60, 90), wsc)
		local cap = self:part("WorkerCap", Vector3.new(0.35, 1.3, 1.3) * wsc, CFrame.new(), Color3.fromRGB(40, 150, 230), nil, Enum.PartType.Cylinder)
		self:hat(w, cap, CFrame.new(0, 0.62 * wsc, 0) * CFrame.Angles(0, 0, math.rad(90)))
		local brim = self:part("WorkerCapBrim", Vector3.new(0.9, 0.08, 0.5) * wsc, CFrame.new(), Color3.fromRGB(40, 150, 230))
		self:hat(w, brim, CFrame.new(0, 0.5 * wsc, -0.65 * wsc))
		local sponge = self:part("WorkerSponge", Vector3.new(0.2, 0.12, 0.14), CFrame.new(), Color3.fromRGB(255, 215, 80))
		local scrubby = self:part("WorkerSpongeScrub", Vector3.new(0.2, 0.04, 0.14), CFrame.new(), Color3.fromRGB(70, 170, 90))
		table.insert(self.Workers, { Actor = w, Sponge = sponge, Scrubby = scrubby, X = DW.X - 0.9 + (i - 1) * 0.9 })
	end
	self.Door = self:part("DWDoor", Vector3.new(3.1, 2.75, 0.25), CFrame.new(), Color3.fromRGB(225, 229, 234), Enum.Material.Metal)
	self.DoorHandle = self:part("DWHandle", Vector3.new(1.6, 0.15, 0.2), CFrame.new(), Color3.fromRGB(150, 155, 162), Enum.Material.Metal)
	self.Panel = self:box("DWPanel", DW.X - 1.55, DW.X + 1.55, 3.1, 3.38, DW_FRONT_Z - 0.05, DW_FRONT_Z + 0.25, Color3.fromRGB(40, 44, 52))
	self.StartLight = self:part("StartLight", Vector3.new(0.3, 0.12, 0.05), CFrame.new(DW.X + 1, 3.24, DW_FRONT_Z - 0.08), Color3.fromRGB(90, 95, 105))
	-- A few plates already inside, and a pot on the hob for flavour.
	self:disc("Pot", 1.2, 1.6, 20, 4.3, 15, Color3.fromRGB(190, 195, 200), Enum.Material.Metal)

	-- Table dressing per theme, kept to the middle of the table: clear of the paths the plates slide
	-- along (x = tx +- 2) and of everyone's hands.
	if th.Party then
		-- An open pizza box with the rest of the big pizza.
		self:box("PizzaBox", tx - 1, tx + 1, TABLE_TOP + 0.02, TABLE_TOP + 0.1, tz - 0.6, tz + 1.4, Color3.fromRGB(240, 230, 210), Enum.Material.Cardboard)
		self:disc("BigPizzaCrust", 0.08, 1.8, tx, TABLE_TOP + 0.14, tz + 0.4, Color3.fromRGB(214, 160, 90))
		self:disc("BigPizzaCheese", 0.04, 1.6, tx, TABLE_TOP + 0.2, tz + 0.4, Color3.fromRGB(252, 212, 110))
		for i = 0, 6 do
			local a = i / 7 * math.pi * 2
			local r = if i == 0 then 0 else 0.5
			self:disc("BigPepperoni", 0.03, 0.3, tx + math.cos(a) * r, TABLE_TOP + 0.235, tz + 0.4 + math.sin(a) * r, Color3.fromRGB(170, 35, 30))
		end
		for i, c in { Color3.fromRGB(255, 90, 110), Color3.fromRGB(90, 170, 255), Color3.fromRGB(255, 210, 60) } do
			local bx = tx - 6 + i * 1.2
			self:part("Balloon", Vector3.new(1.1, 1.4, 1.1), CFrame.new(bx, 8 + i * 0.4, tz + 5), c, nil, Enum.PartType.Ball)
			self:box("String", bx - 0.02, bx + 0.02, 0.3, 7.3 + i * 0.4, tz + 4.98, tz + 5.02, Color3.fromRGB(240, 240, 240))
			self:box("BalloonWeight", bx - 0.2, bx + 0.2, 0, 0.3, tz + 4.8, tz + 5.2, Color3.fromRGB(255, 215, 90), Enum.Material.Metal)
		end
		self:box("Banner", -15, 7, 12.5, 13.5, 17.7, 17.8, Color3.fromRGB(255, 120, 60))
	elseif th.Royal then
		-- A roast turkey on a silver platter with grapes, and a gold candelabra by the table.
		self:disc("Platter", 0.08, 2.0, tx, TABLE_TOP + 0.04, tz + 0.3, Color3.fromRGB(215, 220, 228), Enum.Material.Metal)
		self:part("Turkey", Vector3.new(1.3, 0.8, 1.0), CFrame.new(tx, TABLE_TOP + 0.45, tz + 0.3), Color3.fromRGB(176, 104, 48), nil, Enum.PartType.Ball)
		for _, side in { -1, 1 } do
			self:part("TurkeyLeg", Vector3.new(0.55, 0.36, 0.36), CFrame.new(tx + side * 0.55, TABLE_TOP + 0.4, tz - 0.05) * CFrame.Angles(0, math.rad(side * 30), 0), Color3.fromRGB(166, 96, 44), nil, Enum.PartType.Ball)
			self:part("TurkeyBone", Vector3.new(0.3, 0.09, 0.09), CFrame.new(tx + side * 0.72, TABLE_TOP + 0.45, tz - 0.3) * CFrame.Angles(0, math.rad(90 + side * 30), 0), Color3.fromRGB(246, 238, 222), nil, Enum.PartType.Cylinder)
		end
		for i = 0, 4 do
			self:part("Grape", Vector3.one * 0.16, CFrame.new(tx - 0.8 + (i % 3) * 0.13, TABLE_TOP + 0.14 + (i // 3) * 0.1, tz + 1.0 + (i % 2) * 0.1), Color3.fromRGB(110, 40, 120), nil, Enum.PartType.Ball)
		end
		-- A tall gold candelabra standing beside the table (clear of everyone's arms and paths).
		local gold = Color3.fromRGB(230, 190, 90)
		local cx, cz = tx + 6, tz + 2.5
		self:disc("CandelabraFoot", 0.2, 1.0, cx, 0.1, cz, gold, Enum.Material.Metal)
		self:disc("CandelabraStem", 4.2, 0.18, cx, 2.3, cz, gold, Enum.Material.Metal)
		self:box("CandelabraArm", cx - 0.9, cx + 0.9, 4.3, 4.42, cz - 0.07, cz + 0.07, gold, Enum.Material.Metal)
		for _, dx in { -0.9, 0, 0.9 } do
			self:disc("CandleCup", 0.12, 0.34, cx + dx, 4.48, cz, gold, Enum.Material.Metal)
			self:disc("Candle", 0.9, 0.2, cx + dx, 4.99, cz, Color3.fromRGB(250, 245, 230))
			self:part("Flame", Vector3.new(0.18, 0.3, 0.18), CFrame.new(cx + dx, 5.6, cz), Color3.fromRGB(255, 190, 70), Enum.Material.Neon, Enum.PartType.Ball)
		end
		for _, bx in { -16, 8 } do
			self:box("Banner", bx, bx + 3, 6, 14, 17.6, 17.8, Color3.fromRGB(150, 25, 35), Enum.Material.Fabric)
			self:box("BannerTrim", bx - 0.05, bx + 3.05, 5.8, 6.1, 17.55, 17.8, Color3.fromRGB(230, 190, 90), Enum.Material.Metal)
		end
	end

	-- Family: Dad and a kid behind the table, Mum at the left end (she does the dishes).
	local s, p = th.Shirts, th.Pants
	self.Dad = self:actor("Dad", s[1], p[1])
	self.Kid = self:actor("Kid", s[3], p[3])
	self.Mum = self:actor("Mum", s[2], p[2])
	for _, a in { self.Dad, self.Kid, self.Mum } do
		if th.Party then
			for i = 0, 2 do
				local r = 0.55 - i * 0.18
				local cone = self:part("PartyHat", Vector3.new(0.3, r * 2, r * 2), CFrame.new(), if i % 2 == 0 then Color3.fromRGB(255, 90, 160) else Color3.fromRGB(90, 200, 255), nil, Enum.PartType.Cylinder)
				self:hat(a, cone, CFrame.new(0, 0.75 + i * 0.3, 0) * CFrame.Angles(0, 0, math.rad(90)))
			end
		elseif th.Royal and a ~= self.Kid then
			local band = self:part("Crown", Vector3.new(0.35, 1.3, 1.3), CFrame.new(), Color3.fromRGB(240, 200, 80), Enum.Material.Metal, Enum.PartType.Cylinder)
			self:hat(a, band, CFrame.new(0, 0.75, 0) * CFrame.Angles(0, 0, math.rad(90)))
			for k = 0, 4 do
				local ang = k / 5 * math.pi * 2
				local spike = self:part("CrownPoint", Vector3.new(0.18, 0.3, 0.18), CFrame.new(), Color3.fromRGB(240, 200, 80), Enum.Material.Metal)
				self:hat(a, spike, CFrame.new(math.cos(ang) * 0.55, 1.05, math.sin(ang) * 0.55))
			end
		end
	end

	-- Plates: in front of each diner.
	self.Plates = {
		self:plate(tx - 2, tz + 1.2),
		self:plate(tx + 2, tz + 1.2),
		self:plate(tx - 3.3, tz - 0.8),
	}
	return self
end

----------------------------------------------------------------------------------------------------
-- Timeline
----------------------------------------------------------------------------------------------------

-- Mum's route: get up from her chair, walk round the front of the table (never through it), pick
-- up the plates Dad and the kid slid over, carry them round the open door to the dishwasher, load
-- it, close it, step up and press Start. Every leg is walked along waypoints at an even pace,
-- always facing the way she's going.
local MUM_SEAT = CFrame.new(TABLE_C.X - 6, 0, TABLE_C.Z - 0.8) * CFrame.Angles(0, math.rad(-90), 0) -- faces +X (the table)
local MUM_UP = Vector3.new(TABLE_C.X - 6, 0, TABLE_C.Z - 3.0) -- stood up, slid out to the chair's side
local PICK_POS = Vector3.new(TABLE_C.X - 0.5, 0, TABLE_C.Z - 3.5) -- in front of the table
local LOAD_POS = Vector3.new(DW.X - 3.5, 0, DW_FRONT_Z - 3.0) -- left of the open door, clear of it and of the counter
local PRESS_POS = Vector3.new(DW.X - 0.5, 0, DW_FRONT_Z - 2.2) -- left of the Start button once it's shut (left hand on it)
local TO_PICK = { MUM_UP, Vector3.new(TABLE_C.X - 6, 0, TABLE_C.Z - 3.5), PICK_POS }
local WALK_OFF = { PRESS_POS, Vector3.new(DW.X - 3, 0, DW_FRONT_Z - 3.5), Vector3.new(DW.X - 7, 0, DW_FRONT_Z - 6) }
local TO_DW = { PICK_POS, Vector3.new(TABLE_C.X + 7, 0, TABLE_C.Z - 4.2), Vector3.new(DW.X - 3.6, 0, DW_FRONT_Z - 5), LOAD_POS }

local function yawCF(pos: Vector3, dir: Vector3): CFrame
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if flat.Magnitude < 1e-3 then
		return CFrame.new(pos)
	end
	return CFrame.lookAt(pos, pos + flat.Unit)
end

-- Position along a polyline at fraction k (by distance).
local function along(points: { Vector3 }, k: number): Vector3
	local total = 0
	for i = 1, #points - 1 do
		total += (points[i + 1] - points[i]).Magnitude
	end
	local d = math.clamp(k, 0, 1) * total
	for i = 1, #points - 1 do
		local seg = (points[i + 1] - points[i]).Magnitude
		if d <= seg or i == #points - 1 then
			return points[i]:Lerp(points[i + 1], if seg > 0 then math.clamp(d / seg, 0, 1) else 1)
		end
		d -= seg
	end
	return points[#points]
end

-- Walking pose along a path between times a and b: eased start and stop, facing the direction of
-- travel (looked up a little ahead, so corners turn smoothly).
local function walkPath(points: { Vector3 }, t: number, a: number, b: number): (CFrame, number)
	local k = phase(t, a, b)
	local pos = along(points, k)
	local ahead = along(points, math.min(k + 0.08, 1))
	local behind = along(points, math.max(k - 0.08, 0))
	return yawCF(pos, ahead - behind), (t - a) * 9
end

local function faceTo(pos: Vector3, target: Vector3): CFrame
	return yawCF(pos, target - pos)
end

function Scene:Update(t: number)
	local eat = t < 6.2

	-- Diners: eating (fork hand going to the plate and back, always above the table top), then
	-- sliding their plates to the front for Mum and sitting back happy.
	local chew = math.sin(t * 5)
	local dadRoot = CFrame.new(TABLE_C.X - 2.1, 0, TABLE_C.Z + 3.4) -- faces -Z (camera side)
	local kidRoot = CFrame.new(TABLE_C.X + 2.1, 0, TABLE_C.Z + 3.4)
	local slide = phase(t, 7.3, 8.1)
	local reach = math.sin(slide * math.pi) -- arms out while sliding the plate
	-- Seated arms stay at 1.38 rad or more: forearms resting on the table, never swinging through
	-- its edge.
	local rest = 1.38 + reach * 0.2
	local dadArm = if eat then 1.5 + chew * 0.1 else rest
	local kidArm = if eat then 1.5 - chew * 0.1 else rest
	self:pose(self.Dad, dadRoot, { sit = true, armR = dadArm, armL = if eat then 1.38 else rest })
	self:pose(self.Kid, kidRoot, { sit = true, armL = kidArm, armR = if eat then 1.38 else rest })

	-- Mum.
	local mum: CFrame
	local pose: { [string]: any } = {}
	local mumPick = faceTo(PICK_POS, PICK_POS + Vector3.new(0, 0, 1))
	local mumLoad = faceTo(LOAD_POS, Vector3.new(DW.X, 0, DW_FRONT_Z + 1.5))
	if t < 7 then
		mum = MUM_SEAT
		local lift = phase(t, 6.6, 7)
		pose = { sit = true, armR = if eat then 1.5 + math.sin(t * 5 + 1) * 0.1 else 1.38 + lift * 0.12, armL = 1.38 + lift * 0.12 }
	elseif t < 7.6 then
		-- Getting up with her own plate: slide out to the side of the chair while the legs straighten.
		local out = phase(t, 7, 7.3)
		local rise = phase(t, 7.3, 7.6)
		mum = CFrame.new(MUM_SEAT.Position:Lerp(MUM_UP, out)) * MUM_SEAT.Rotation
		pose = { sitK = 1 - rise, armL = 1.5, armR = 1.5 }
	elseif t < 9 then
		local cf, stride = walkPath(TO_PICK, t, 7.6, 9)
		mum = cf
		pose = { walk = stride, armL = 1.5, armR = 1.5 }
	elseif t < 9.8 then
		mum = mumPick
		pose = { armL = 1.55, armR = 1.55, bob = -0.15 * math.sin(phase(t, 9, 9.8) * math.pi) }
	elseif t < 13 then
		local cf, stride = walkPath(TO_DW, t, 9.8, 13)
		mum = cf
		pose = { walk = stride, armL = 1.5, armR = 1.5 }
	elseif t < 15.4 then
		-- Loads the rack facing the dishwasher, then turns square to it and swings the door shut
		-- (standing clear of the door's sweep).
		local turn = phase(t, 14.2, 14.6)
		mum = CFrame.new(LOAD_POS) * mumLoad.Rotation:Lerp(CFrame.lookAt(Vector3.zero, Vector3.new(0, 0, 1)).Rotation, turn)
		local out = 1 - phase(t, 13.2, 14.2) -- arms come down as the plates go in
		local shut = math.sin(phase(t, 14.6, 15.4) * math.pi)
		pose = { armL = 0.6 + out * 0.9 + shut * 0.4, armR = 0.6 + out * 0.9 + shut * 0.4, bob = -0.15 * shut }
	elseif t < 15.9 then
		local k = phase(t, 15.4, 15.9)
		local pos = LOAD_POS:Lerp(PRESS_POS, k)
		mum = yawCF(pos, (PRESS_POS - LOAD_POS):Lerp(Vector3.new(0, 0, 1), k))
		pose = { walk = (t - 15.4) * 9 * (1 - k), armL = 0.3, armR = 0.3 }
	elseif t < 16.5 then
		mum = faceTo(PRESS_POS, PRESS_POS + Vector3.new(0, 0, 1))
		local press = phase(t, 15.9, 16.15) - phase(t, 16.25, 16.5)
		pose = { armR = 0.2, armL = 0.4 + press * 0.8 }
	else
		-- Job done: she walks off out of shot, leaving the camera a clear way in.
		local cf, stride = walkPath(WALK_OFF, t, 16.5, 17.6)
		mum = cf
		pose = { walk = stride, armL = 0.3, armR = 0.3 }
	end
	self:pose(self.Mum, mum, pose)

	-- Plates: Mum lifts her own as she gets up; Dad and the kid slide theirs to the front, and she
	-- stacks them on hers. At the dishwasher they're stood up in the rack side by side (resting on
	-- it, facing sideways like real plates).
	local hipDrop = if t < 7.6 then (2 - (SEAT_Y + 0.5)) * (1 - phase(t, 7.3, 7.6)) else 0
	for i, plate in self.Plates do
		local own = i == 3
		local stack = if own then 1 else i + 1
		local frontZ = TABLE_C.Z - 1.5
		local slid = if own then 0 else phase(t, 7.3, 8.1)
		local tableCF = CFrame.new(plate.X, TABLE_TOP, plate.Z + (frontZ - plate.Z) * slid)
		local handCF = mum * CFrame.new(0, 4.3 - hipDrop + (stack - 1) * 0.3, -1.6) -- resting on her hands
		local rackCF = CFrame.new(DW.X - 0.6 + (stack - 1) * 0.6, 0.96 + 0.96, 16.2) * CFrame.Angles(0, 0, math.rad(90))
		local pickA, pickB = if own then 6.7 else 9.5, if own then 7 else 9.8
		local base: CFrame
		if t < pickA then
			base = tableCF
		elseif t < 13.2 then
			base = tableCF:Lerp(handCF, phase(t, pickA, pickB))
		else
			-- Two moves so nothing passes through the counter: out of her hands to just in front of
			-- the opening (turning upright on the way), then straight in onto the rack.
			local t0 = 13.2 + (3 - stack) * 0.25
			local entryCF = CFrame.new(rackCF.X, rackCF.Y + 0.05, DW_FRONT_Z - 1.2) * rackCF.Rotation
			-- (First off the top of the stack sideways, so it never passes through the plates under it.)
			local sideCF = handCF * CFrame.new(-2.1, 0.3, 0)
			if t < t0 + 0.2 then
				base = handCF:Lerp(sideCF, phase(t, t0, t0 + 0.2))
			elseif t < t0 + 0.4 then
				base = sideCF:Lerp(entryCF, phase(t, t0 + 0.2, t0 + 0.4))
			else
				base = entryCF:Lerp(rackCF, phase(t, t0 + 0.4, t0 + 0.65))
			end
		end
		for _, item in plate.Items do
			local visible = item.Kind == "Plate" or (item.Kind == "Food" and eat) or (item.Kind == "Mess" and not eat)
			item.Part.Transparency = if visible then 0 else 1
			self:place(item.Part, base * item.Offset)
		end
	end

	-- Dishwasher door: open (flat, towards the camera) until Mum shuts it, then the Start light.
	-- When the camera pushes in, the door dissolves instead of the lens passing through metal.
	local close = phase(t, 14.6, 15.4)
	local hinge = CFrame.new(DW.X, 0.25, DW_FRONT_Z) * CFrame.Angles(math.rad(-90 * (1 - close)), 0, 0)
	local on = t >= 16.2
	local shake = if on then math.sin(t * 60) * 0.015 else 0
	self:place(self.Door, hinge * CFrame.new(shake, 1.375, 0))
	self:place(self.DoorHandle, hinge * CFrame.new(shake, 2.4, -0.22))
	local dissolve = phase(t, 17.1, 17.45)
	self.Door.Transparency = dissolve
	self.DoorHandle.Transparency = dissolve
	self.StartLight.Color = if on then Color3.fromRGB(90, 255, 140) else Color3.fromRGB(90, 95, 105)
	self.StartLight.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic

	-- Inside: the crew waits facing the plates. The lights come on, they turn round to face us,
	-- raise their sponges together (a salute, one after another), then turn back and get scrubbing.
	self.InnerLight.Brightness = if on then 2 else 0
	for i, w in self.Workers do
		local delay = (i - 1) * 0.12
		local turn = phase(t, 17.6 + delay, 18.1 + delay) - phase(t, 19.1 + delay, 19.5 + delay)
		local yaw = math.rad(180) * (1 - turn) -- 180 = facing the plates (+Z), 0 = facing us
		local root = CFrame.new(w.X, 0.96, 14.6) * CFrame.Angles(0, yaw, 0)
		local salute = phase(t, 18.2 + delay, 18.5 + delay) * (1 - phase(t, 18.85, 19.1))
		local scrubbing = t > 19.5 + delay
		local armR = 0.25 + salute * 2.6
		if scrubbing then
			armR = 1.35 + math.sin(t * 11 + i) * 0.25
		end
		local breathe = math.sin(t * 2 + i) * 0.004
		local hand = self:pose(w.Actor, root, { armL = 0.2 + salute * 0.2, armR = armR, bob = breathe })
		-- Nobody's inside while the door's open (keeps the reveal a surprise).
		local shown = if close >= 1 then 0 else 1
		for _, part in w.Actor.Parts do
			part.Transparency = shown
		end
		for _, h in w.Actor.Hat do
			h.Part.Transparency = shown
		end
		w.Sponge.Transparency = shown
		w.Scrubby.Transparency = shown
		local spongeCF = hand * CFrame.new(0, -0.07, 0)
		self:place(w.Sponge, spongeCF)
		self:place(w.Scrubby, spongeCF * CFrame.new(0, -0.08, 0))
	end
end

-- Camera path (scene space) with gentle eases between keys: { time, eye, look, fov }.
local KEYS = {
	{ 0, Vector3.new(-1, 6, -9), Vector3.new(-4, 3.2, 8), 52 },
	{ 3.2, Vector3.new(-3, 5.6, 0.2), Vector3.new(-4, 3.1, 7.5), 46 },
	{ 5.8, Vector3.new(-4.2, 7.4, 4.2), Vector3.new(-4, 3, 7.4), 44 },
	{ 7.2, Vector3.new(-2, 6, -3), Vector3.new(-5, 2.8, 6), 50 },
	{ 10.2, Vector3.new(2, 7, -6), Vector3.new(8, 2.5, 6), 54 },
	{ 13, Vector3.new(20, 6.5, 4), Vector3.new(14.5, 1.8, 12), 50 },
	{ 15.4, Vector3.new(22, 5.2, 5.5), Vector3.new(16, 2.5, 11.5), 48 },
	{ 16.4, Vector3.new(21, 4.6, 6.6), Vector3.new(16, 2.6, 11.7), 44 },
	{ 17.0, Vector3.new(15.8, 2.6, 9.3), Vector3.new(15.5, 2.0, 12.4), 50 },
	{ 17.8, Vector3.new(15.5, 1.9, 12.7), Vector3.new(15.5, 1.3, 16), 62 },
	{ 20.5, Vector3.new(15.5, 1.75, 13.1), Vector3.new(15.5, 1.25, 16), 58 },
}

function Scene:Camera(t: number): (CFrame, number)
	local a, b = KEYS[1], KEYS[#KEYS]
	for i = 1, #KEYS - 1 do
		if t >= KEYS[i][1] and t <= KEYS[i + 1][1] then
			a, b = KEYS[i], KEYS[i + 1]
			break
		end
	end
	if t >= KEYS[#KEYS][1] then
		a, b = KEYS[#KEYS], KEYS[#KEYS]
	end
	local k = if b[1] > a[1] then smooth((t - a[1]) / (b[1] - a[1])) else 1
	local eye = (a[2] :: Vector3):Lerp(b[2] :: Vector3, k)
	local look = (a[3] :: Vector3):Lerp(b[3] :: Vector3, k)
	local fov = (a[4] :: number) + ((b[4] :: number) - (a[4] :: number)) * k
	local cf = self.Origin * CFrame.lookAt(eye, look)
	return cf, fov
end

-- World positions inside the running dishwasher, for the client's bubble effect.
function Scene:InsidePoints(): { Vector3 }
	local pts = {}
	for i = -1, 1 do
		table.insert(pts, (self.Origin * CFrame.new(DW.X + i * 0.8, 1.4, 15)).Position)
	end
	return pts
end

function Scene:Destroy()
	self.Folder:Destroy()
end

return Scene
