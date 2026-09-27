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

Scene.Duration = 19.5

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
local SEAT_Y = 1.8

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
	if shape then
		p.Shape = shape
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
	parts.LeftLeg = self:part(name .. "LeftLeg", Vector3.new(1, 2, 1) * sc, CFrame.new(), pants)
	parts.RightLeg = self:part(name .. "RightLeg", Vector3.new(1, 2, 1) * sc, CFrame.new(), pants)
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
		parts[limb .. "Hand"] = self:part(name .. limb .. "Hand", Vector3.new(1.02, 0.5, 1.02) * sc, CFrame.new(), SKIN)
	end
	return { Parts = parts, Hat = {}, Scale = sc }
end

-- Something worn on the head (party hat, crown), placed relative to the head.
function Scene:hat(actor: Actor, p: BasePart, offset: CFrame)
	table.insert(actor.Hat, { Part = p, Offset = offset })
end

-- Pose an actor. root = feet position + facing (LookVector = where they face). sit bends the legs
-- forward; walk is a phase (radians) for the stride; armL / armR raise the arms forward (radians).
function Scene:pose(a: Actor, root: CFrame, pose: { sit: boolean?, walk: number?, armL: number?, armR: number?, bob: number? })
	local p = a.Parts
	local sc = a.Scale
	local hip = if pose.sit then SEAT_Y else 2 * sc
	local base = root * CFrame.new(0, hip - 2 * sc + (pose.bob or 0), 0)
	local swing = if pose.walk then math.sin(pose.walk) * 0.65 else 0
	self:place(p.Torso, base * CFrame.new(0, 3 * sc, 0))
	self:place(p.Head, base * CFrame.new(0, 4.5 * sc, 0))
	for _, h in a.Hat do
		self:place(h.Part, base * CFrame.new(0, 4.5 * sc, 0) * h.Offset)
	end
	for side, name in { [-1] = "Left", [1] = "Right" } do
		local legAngle = if pose.sit then math.rad(90) else swing * side
		self:place(p[name .. "Leg"], base * CFrame.new(side * 0.5 * sc, 2 * sc, 0) * CFrame.Angles(legAngle, 0, 0) * CFrame.new(0, -sc, 0))
		local armAngle = (if side < 0 then pose.armL else pose.armR) or (-swing * side * 0.8)
		local shoulder = base * CFrame.new(side * 1.5 * sc, 3.9 * sc, 0) * CFrame.Angles(armAngle, 0, 0)
		self:place(p[name .. "Arm"], shoulder * CFrame.new(0, -0.9 * sc, 0))
		self:place(p[name .. "ArmHand"], shoulder * CFrame.new(0, -1.75 * sc, 0))
	end
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
	add(self:disc("Plate", 0.1, 1.9, x, TABLE_TOP + 0.05, z, th.PlateRim), "Plate")
	add(self:disc("PlateFace", 0.12, 1.6, x, TABLE_TOP + 0.06, z, th.PlateBody), "Plate")
	-- Food (visible while eating).
	if th.Food == "Spaghetti" then
		add(self:part("Noodles", Vector3.new(1.1, 0.35, 1.0), CFrame.new(x, TABLE_TOP + 0.25, z), Color3.fromRGB(245, 205, 110), nil, Enum.PartType.Ball), "Food")
		for i = 0, 2 do
			local a = i / 3 * math.pi * 2
			add(self:part("Meatball", Vector3.one * 0.3, CFrame.new(x + math.cos(a) * 0.25, TABLE_TOP + 0.45, z + math.sin(a) * 0.25), Color3.fromRGB(120, 60, 35), nil, Enum.PartType.Ball), "Food")
		end
		add(self:part("Sauce", Vector3.new(0.7, 0.2, 0.6), CFrame.new(x, TABLE_TOP + 0.36, z), Color3.fromRGB(200, 50, 35), nil, Enum.PartType.Ball), "Food")
	elseif th.Food == "Pizza" then
		for i = 0, 1 do
			local slice = Instance.new("WedgePart")
			slice.Name = "PizzaSlice"
			slice.Size = Vector3.new(0.12, 0.7, 1.1)
			slice.Color = Color3.fromRGB(245, 200, 90)
			slice.Anchored = true
			slice.CanCollide = false
			slice.CanQuery = false
			slice.CanTouch = false
			slice.CFrame = self.Origin * CFrame.new(x - 0.25 + i * 0.5, TABLE_TOP + 0.2, z) * CFrame.Angles(0, 0, math.rad(90)) * CFrame.Angles(0, math.rad(i * 180), 0)
			slice.Parent = self.Folder
			add(slice, "Food")
			add(self:part("Pepperoni", Vector3.new(0.05, 0.22, 0.22), CFrame.new(x - 0.25 + i * 0.5, TABLE_TOP + 0.27, z + 0.1) * CFrame.Angles(0, 0, math.rad(90)), Color3.fromRGB(170, 30, 30), nil, Enum.PartType.Cylinder), "Food")
		end
	else
		add(self:part("Roast", Vector3.new(0.9, 0.6, 0.7), CFrame.new(x, TABLE_TOP + 0.4, z), Color3.fromRGB(150, 85, 40), nil, Enum.PartType.Ball), "Food")
		add(self:part("Drumstick", Vector3.new(0.7, 0.18, 0.18), CFrame.new(x + 0.45, TABLE_TOP + 0.3, z - 0.2) * CFrame.Angles(0, math.rad(30), 0), Color3.fromRGB(245, 235, 215), nil, Enum.PartType.Cylinder), "Food")
		add(self:part("Greens", Vector3.new(0.4, 0.2, 0.4), CFrame.new(x - 0.45, TABLE_TOP + 0.22, z + 0.2), Color3.fromRGB(80, 160, 70), nil, Enum.PartType.Ball), "Food")
	end
	-- Mess (visible once the meal's eaten).
	local mess = th.Mess
	add(self:disc("Smear", 0.02, 0.9, x - 0.15, TABLE_TOP + 0.13, z + 0.1, mess[1]), "Mess")
	add(self:disc("Smear", 0.02, 0.5, x + 0.3, TABLE_TOP + 0.135, z - 0.25, mess[2]), "Mess")
	add(self:part("Crumb", Vector3.one * 0.15, CFrame.new(x + 0.1, TABLE_TOP + 0.18, z - 0.35), mess[2], nil, Enum.PartType.Ball), "Mess")
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
	self:box("Skirting", -20, 23, 0, 0.6, 17.8, 18, Color3.new(1, 1, 1))
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
	chair(tx - 2, tz + 3.4, 1)
	chair(tx + 2, tz + 3.4, 1)

	-- Kitchen: counter run with the dishwasher in it.
	self:box("Counter", 11, 23, 0, 3.4, 12.2, 18, th.Counter)
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
	for i, c in { Color3.fromRGB(255, 200, 60), Color3.fromRGB(90, 170, 255), Color3.fromRGB(255, 110, 150) } do
		local w = self:actor("Worker" .. i, c, Color3.fromRGB(50, 60, 90), 0.22)
		local sponge = self:part("WorkerSponge", Vector3.new(0.18, 0.1, 0.12), CFrame.new(), Color3.fromRGB(255, 215, 80))
		table.insert(self.Workers, { Actor = w, Sponge = sponge, X = DW.X - 0.8 + (i - 1) * 0.8 })
	end
	self.Door = self:part("DWDoor", Vector3.new(3.1, 2.75, 0.25), CFrame.new(), Color3.fromRGB(225, 229, 234), Enum.Material.Metal)
	self.DoorHandle = self:part("DWHandle", Vector3.new(1.6, 0.15, 0.2), CFrame.new(), Color3.fromRGB(150, 155, 162), Enum.Material.Metal)
	self.Panel = self:box("DWPanel", DW.X - 1.55, DW.X + 1.55, 3.1, 3.38, DW_FRONT_Z - 0.05, DW_FRONT_Z + 0.25, Color3.fromRGB(40, 44, 52))
	self.StartLight = self:part("StartLight", Vector3.new(0.3, 0.12, 0.05), CFrame.new(DW.X + 1, 3.24, DW_FRONT_Z - 0.08), Color3.fromRGB(90, 95, 105))
	-- A few plates already inside, and a pot on the hob for flavour.
	self:disc("Pot", 1.2, 1.6, 20, 4.3, 15, Color3.fromRGB(190, 195, 200), Enum.Material.Metal)

	-- Party / royal dressing.
	if th.Party then
		self:box("PizzaBox", tx - 1, tx + 1, TABLE_TOP + 0.02, TABLE_TOP + 0.12, tz - 0.6, tz + 1.4, Color3.fromRGB(240, 230, 210), Enum.Material.Cardboard)
		self:disc("BigPizza", 0.1, 1.8, tx, TABLE_TOP + 0.17, tz + 0.4, Color3.fromRGB(230, 170, 80))
		for i, c in { Color3.fromRGB(255, 90, 110), Color3.fromRGB(90, 170, 255), Color3.fromRGB(255, 210, 60) } do
			local bx = tx - 6 + i * 1.2
			self:part("Balloon", Vector3.new(1.1, 1.4, 1.1), CFrame.new(bx, 8 + i * 0.4, tz + 5), c, nil, Enum.PartType.Ball)
			self:box("String", bx - 0.02, bx + 0.02, 3, 7.3 + i * 0.4, tz + 4.98, tz + 5.02, Color3.fromRGB(240, 240, 240))
		end
		self:box("Banner", -15, 7, 12.5, 13.5, 17.7, 17.8, Color3.fromRGB(255, 120, 60))
	elseif th.Royal then
		for _, cx in { tx - 0.7, tx + 0.7 } do
			self:disc("CandleBase", 0.2, 0.6, cx, TABLE_TOP + 0.1, tz + 0.2, Color3.fromRGB(230, 190, 90), Enum.Material.Metal)
			self:disc("Candle", 1.2, 0.25, cx, TABLE_TOP + 0.8, tz + 0.2, Color3.fromRGB(250, 245, 230))
			self:part("Flame", Vector3.new(0.2, 0.35, 0.2), CFrame.new(cx, TABLE_TOP + 1.55, tz + 0.2), Color3.fromRGB(255, 190, 70), Enum.Material.Neon, Enum.PartType.Ball)
		end
		for _, bx in { -16, 8 } do
			self:box("Banner", bx, bx + 3, 6, 14, 17.6, 17.8, Color3.fromRGB(150, 25, 35), Enum.Material.Fabric)
			self:box("BannerTrim", bx, bx + 3, 5.8, 6.1, 17.55, 17.8, Color3.fromRGB(230, 190, 90), Enum.Material.Metal)
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
		self:plate(tx - 3.2, tz - 0.6),
	}
	return self
end

----------------------------------------------------------------------------------------------------
-- Timeline
----------------------------------------------------------------------------------------------------

-- Mum's route: stand up, collect the plates, carry them to the dishwasher, load, close, press.
local MUM_SEAT = CFrame.new(TABLE_C.X - 5.3, 0, TABLE_C.Z - 0.6) * CFrame.Angles(0, math.rad(-90), 0) -- faces +X (the table)
local MUM_PICK = CFrame.new(TABLE_C.X, 0, TABLE_C.Z - 3.4) * CFrame.Angles(0, math.rad(180), 0) -- front of the table, facing +Z
local MUM_DW = CFrame.new(DW.X + 2.1, 0, DW_FRONT_Z - 2.6) * CFrame.Angles(0, math.rad(160), 0) -- beside the door, by the Start button

local function lerpCF(a: CFrame, b: CFrame, k: number): CFrame
	return a:Lerp(b, k)
end

function Scene:Update(t: number)
	local eat = t < 6.2

	-- Diners: eating (forks up and down), then leaning back happy.
	local chew = math.sin(t * 5)
	local dadRoot = CFrame.new(TABLE_C.X - 2, 0, TABLE_C.Z + 3.4) * CFrame.Angles(0, 0, 0) -- faces -Z (camera side)
	local kidRoot = CFrame.new(TABLE_C.X + 2, 0, TABLE_C.Z + 3.4)
	local dadArm = if eat then 1.1 + chew * 0.35 else 0.2
	local kidArm = if eat then 1.1 - chew * 0.35 else 0.2
	self:pose(self.Dad, dadRoot, { sit = true, armR = dadArm, armL = 0.6 })
	self:pose(self.Kid, kidRoot, { sit = true, armL = kidArm, armR = 0.6 })

	-- Mum.
	local mum: CFrame
	local pose: { [string]: any } = { sit = false }
	local carrying = false
	if t < 7 then
		mum = MUM_SEAT
		pose = { sit = true, armR = if eat then 1.1 + math.sin(t * 5 + 1) * 0.35 else 0.3, armL = 0.6 }
	elseif t < 9 then
		local k = phase(t, 7, 9)
		mum = lerpCF(MUM_SEAT, MUM_PICK, k)
		pose = { walk = t * 9, armL = 0.3, armR = 0.3 }
	elseif t < 9.8 then
		mum = MUM_PICK
		pose = { armL = 1.2, armR = 1.2, bob = -0.3 * math.sin(phase(t, 9, 9.8) * math.pi) }
	elseif t < 13 then
		local k = phase(t, 9.8, 13)
		local mid = CFrame.new(TABLE_C.X + 8, 0, TABLE_C.Z - 4) * CFrame.Angles(0, math.rad(-120), 0)
		mum = if k < 0.5 then lerpCF(MUM_PICK, mid, k * 2) else lerpCF(mid, MUM_DW, (k - 0.5) * 2)
		pose = { walk = t * 9, armL = 1.35, armR = 1.35 }
		carrying = true
	elseif t < 15 then
		mum = MUM_DW
		local k = phase(t, 13, 14.2)
		pose = { armL = 1.35 + k * 0.4, armR = 1.35 + k * 0.4, bob = -0.8 * math.sin(k * math.pi) }
		carrying = t < 14.2
	else
		mum = MUM_DW
		local press = phase(t, 15.6, 16.1) - phase(t, 16.3, 16.8)
		pose = { armL = 0.2, armR = 0.6 + press * 1.4 }
	end
	self:pose(self.Mum, mum, pose)

	-- Plates: on the table, then stacked in Mum's hands, then into the rack.
	for i, plate in self.Plates do
		local tableCF = CFrame.new(plate.X, TABLE_TOP, plate.Z)
		local handCF = mum * CFrame.new(0, 3.1 + i * 0.16, -1.6)
		local rackCF = CFrame.new(DW.X - 1.2 + i * 0.6, 0.97, 16.3) * CFrame.Angles(math.rad(90), 0, 0)
		local base: CFrame
		if t < 9.5 then
			base = tableCF
		elseif carrying then
			base = if t < 9.8 then tableCF:Lerp(handCF, phase(t, 9.5, 9.8)) else handCF
		else
			base = handCF:Lerp(rackCF, phase(t, 13.4, 14.2))
			if t >= 14.2 then
				base = rackCF
			end
		end
		for _, item in plate.Items do
			local visible = item.Kind == "Plate" or (item.Kind == "Food" and eat) or (item.Kind == "Mess" and not eat)
			item.Part.Transparency = if visible then 0 else 1
			self:place(item.Part, base * item.Offset)
		end
	end

	-- Dishwasher door: open (flat, towards the camera) until Mum shuts it, then the Start light.
	local close = phase(t, 14.6, 15.4)
	local hinge = CFrame.new(DW.X, 0.25, DW_FRONT_Z) * CFrame.Angles(math.rad(-90 * (1 - close)), 0, 0)
	self:place(self.Door, hinge * CFrame.new(0, 1.375, 0))
	self:place(self.DoorHandle, hinge * CFrame.new(0, 2.4, -0.22))
	local on = t >= 16.2
	self.StartLight.Color = if on then Color3.fromRGB(90, 255, 140) else Color3.fromRGB(90, 95, 105)
	self.StartLight.Material = if on then Enum.Material.Neon else Enum.Material.SmoothPlastic
	-- Inside: the workers stand ready, then cheer when the lights come on.
	self.InnerLight.Brightness = if on then 2 else 0
	for i, w in self.Workers do
		local cheer = if on then math.abs(math.sin(t * 6 + i)) else 0
		local root = CFrame.new(w.X, 0.96, 14.3)
		self:pose(w.Actor, root, { armL = 0.4 + cheer * 2.2, armR = 1.2 + cheer * 1.6, bob = cheer * 0.06 })
		self:place(w.Sponge, root * CFrame.new(0.33, 0.62 + cheer * 0.18, -0.25))
	end
	-- Once it's running, it hums (a tiny shake).
	if on then
		local shake = math.sin(t * 60) * 0.015
		self:place(self.Door, hinge * CFrame.new(shake, 1.375, 0))
	end
end

-- Camera path (scene space) with gentle eases between keys: { time, eye, look, fov }.
local KEYS = {
	{ 0, Vector3.new(-1, 6, -9), Vector3.new(-4, 3.2, 8), 52 },
	{ 3.2, Vector3.new(-3, 5.6, 0.2), Vector3.new(-4, 3.1, 7.5), 46 },
	{ 5.8, Vector3.new(-4.2, 7.4, 4.2), Vector3.new(-4, 3, 7.4), 44 },
	{ 7.2, Vector3.new(-2, 6, -3), Vector3.new(-5, 2.8, 6), 50 },
	{ 10.2, Vector3.new(4, 6, -3), Vector3.new(9, 2.6, 8), 54 },
	{ 13, Vector3.new(20.5, 5.4, 6.4), Vector3.new(15.3, 1.8, 11.8), 50 },
	{ 15.4, Vector3.new(13.2, 4.3, 8.9), Vector3.new(16.3, 3.3, 12), 38 },
	{ 16.6, Vector3.new(15.5, 2.3, 9.8), Vector3.new(15.5, 2.1, 12.4), 50 },
	{ 17.6, Vector3.new(15.5, 1.9, 12.7), Vector3.new(15.5, 1.3, 16), 62 },
	{ 19.5, Vector3.new(15.5, 1.75, 13.1), Vector3.new(15.5, 1.25, 16), 58 },
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
