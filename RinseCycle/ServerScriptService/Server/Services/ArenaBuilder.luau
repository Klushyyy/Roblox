-- ArenaBuilder: builds one dishwasher ("arena") for a run, sitting in a family kitchen, and lays out
-- the load of dirty dishes inside it. RoundService calls Build(slot, levelIndex, options) once per
-- run and Destroy(arena) when the run ends; nothing else touches workspace.Arenas directly.
--
-- Coordinate convention ("arena space"): every builder helper below works in local offsets
-- (x = sideways, y = up, z = depth) measured from `origin` (the tub floor centre, see SlotOrigin).
-- `origin.LookVector` points from the door toward the back wall, so +z is "into the tub" and the
-- open door and the rest of the kitchen are at -z.
--
-- The dishwasher is sized so a ~5 stud character is a tiny person inside a real machine:
--   * tub interior X +-56, Z -50..62, 100 tall; the open door lies flat in front (Z -50..-121)
--   * bottom rack floor at Y 4: three rows of standing plates, pans/pots and a cutlery basket
--   * top rack floor at Y 50: tilted bowls, upturned mugs and glasses
--   * bubble-lift pads (tag "LiftPad", attribute LiftTo) carry you up; the client does the
--     teleport (Effects). Hold jump in the air to fly on bubble jets (BubbleJets, client).
--   * the kitchen floor is 24 studs below the tub; falling off the door teleports you back.
--
-- Everything the spray can hit lives in two folders on the arena Model: "Dishes" and "Grime" (dirt).
-- Nothing else is aimable (SprayController only raycasts those), so walls never block a scrub.
--
-- Performance: the build yields with task.wait() every ~200 parts.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Format = require(Shared:WaitForChild("Format"))

local DishFactory = require(script.Parent:WaitForChild("DishFactory"))
local ToolModels = require(Shared:WaitForChild("ToolModels"))

local ArenaBuilder = {}

----------------------------------------------------------------------------------------------------
-- Layout numbers (arena space).
----------------------------------------------------------------------------------------------------
local TUB_HALF_X = 56
local TUB_Z_MIN, TUB_Z_MAX = -50, 62
local TUB_HEIGHT = 100

local DOOR_Z_NEAR, DOOR_Z_FAR = -50, -121 -- the open door lies flat over this Z range, top at Y = 0
local DOOR_THICK = 4
local SPAWN_Z = -100

local KITCHEN_FLOOR_Y = -24
local COUNTER_TOP_Y = 112
local ROOM_HALF_X = 420
local ROOM_Z_FRONT, ROOM_Z_BACK = -520, 76
local ROOM_HEIGHT = 520

local DRAIN_POS = Vector3.new(0, 0, -49) -- clear of the rack ramp (Z -41..-36)

local BOTTOM_RACK_Y = 4
local TOP_RACK_Y = 50
local RACK_HALF_X = 54
local BOTTOM_RACK_Z = { -36, 60 }
local TOP_RACK_Z = { -40, 60 }

-- Bottom rack: three rows of plates facing the door, spaced so a character fits between them.
local PLATE_ROW_X = { -34, 0, 34 }
local PLATE_Z = { -28, -21, -14, -7, 0, 7, 14, 21, 28 }
local PAN_SLOTS = { { x = -43, z = 47 }, { x = 43, z = 47 } }
local POT_SLOTS = { { x = -22, z = 47 }, { x = 22, z = 47 } }
local BASKET_CENTER = Vector3.new(0, 0, 47)
local BASKET_HALF = Vector3.new(10, 8, 9)
local BASKET_X = { -7.5, -2.5, 2.5, 7.5 }
local BASKET_Z = { 40.5, 44, 47.5, 51, 54.5 }

-- Top rack.
local BOWL_X = { -30, -15, 0, 15, 30 }
local BOWL_Z = { -24, -6 }
local CUP_X = { -40, -24, -8, 8, 24, 40 }
local CUP_Z = { 10, 24 }
local GLASS_X = { -42, -30, -18, -6, 6, 18, 30, 42 }
local GLASS_Z = { 38, 52 }

local BOWL_TILT = math.rad(50)
local PAN_TILT = math.rad(55)

-- Lifts (tub floor front corners -> top rack). Coming down, you just jump off (or fly with bubble jets).
local LIFTS = {
	{ from = Vector3.new(-47, 0, -45), to = Vector3.new(-47, TOP_RACK_Y, -34) },
	{ from = Vector3.new(47, 0, -45), to = Vector3.new(47, TOP_RACK_Y, -34) },
}

-- Tool shop counter on the left of the open door.
local SHOP_X = -49
local SHOP_Z = { -112, -60 }

local YIELD_EVERY = 200

-- Kitchen palette (theme-independent: every level is the same family kitchen).
local K = {
	Floor = Color3.fromRGB(196, 158, 116),
	Wall = Color3.fromRGB(214, 230, 238),
	Cabinet = Color3.fromRGB(244, 241, 234),
	CabinetDoor = Color3.fromRGB(236, 232, 224),
	Counter = Color3.fromRGB(235, 235, 238),
	Tile = Color3.fromRGB(250, 250, 250),
	Handle = Color3.fromRGB(170, 175, 182),
	Kick = Color3.fromRGB(70, 66, 62),
	Wood = Color3.fromRGB(150, 105, 70),
	Steel = Color3.fromRGB(200, 205, 212),
	Frame = Color3.fromRGB(230, 232, 235),
}

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

local function getArenasFolder(): Folder
	local folder = workspace:FindFirstChild("Arenas")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Arenas"
		folder.Parent = workspace
	end
	return folder :: Folder
end

-- Local (x, y, z) -> world position, in the arena's own space (see file header).
local function worldPoint(origin: CFrame, x: number, y: number, z: number): Vector3
	return origin.Position + origin.RightVector * x + Vector3.new(0, y, 0) + origin.LookVector * z
end

-- A CFrame at local (x, y, z), axis-aligned with the arena (LookVector = into the tub), optionally
-- facing `lookDir` instead. Used both for plain parts and as DishFactory's footprint.
local function footprint(origin: CFrame, x: number, y: number, z: number, lookDir: Vector3?): CFrame
	local pos = worldPoint(origin, x, y, z)
	local look = (lookDir or origin.LookVector)
	if look.Magnitude < 1e-4 then
		look = origin.LookVector
	end
	return CFrame.lookAt(pos, pos + look, Vector3.new(0, 1, 0))
end

type Builder = {
	model: Model,
	origin: CFrame,
	count: number,
}

-- A decoration/structure part in arena space. Static, no touch, not aimable. Box centred at (x,y,z).
local function box(b: Builder, name: string, size: Vector3, x: number, y: number, z: number, color: Color3, material: Enum.Material?, props: { [string]: any }?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = footprint(b.origin, x, y, z)
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanTouch = false
	p.CanQuery = false
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if props then
		for k, v in props do
			(p :: any)[k] = v
		end
	end
	p.Parent = b.model
	b.count += 1
	return p
end

-- Box from min/max corners (arena space). Handy for walls and cabinets.
local function span(b: Builder, name: string, x0: number, x1: number, y0: number, y1: number, z0: number, z1: number, color: Color3, material: Enum.Material?, props: { [string]: any }?): Part
	return box(b, name, Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0)), (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2, color, material, props)
end

-- Upright cylinder (axis = world Y) centred at (x, y, z).
local function cyl(b: Builder, name: string, height: number, diameter: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?, props: { [string]: any }?): Part
	local p = box(b, name, Vector3.new(height, diameter, diameter), x, y, z, color, material, props)
	p.Shape = Enum.PartType.Cylinder
	p.CFrame = footprint(b.origin, x, y, z) * CFrame.Angles(0, 0, math.rad(90))
	return p
end

local function noCollide(): { [string]: any }
	return { CanCollide = false, CastShadow = false }
end

-- A world-sized sign (it scales with distance like a real object, so it never fills the screen).
-- It hangs off its own unrotated, invisible anchor `offsetY` above `parent`: cylinders are rotated
-- 90 degrees internally and a BillboardGui's offset follows that rotation, which is what used to
-- bury signs in the floor.
local function sign(parent: BasePart, text: string, widthStuds: number, heightStuds: number, offsetY: number, color: Color3?): TextLabel
	local anchor = Instance.new("Part")
	anchor.Name = "SignAnchor"
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.CFrame = CFrame.new(parent.Position + Vector3.new(0, offsetY, 0))
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Parent = parent.Parent
	local gui = Instance.new("BillboardGui")
	gui.Name = "Sign"
	gui.Size = UDim2.fromScale(widthStuds, heightStuds)
	gui.LightInfluence = 0
	gui.MaxDistance = 160
	gui.AlwaysOnTop = false
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = color or Color3.new(1, 1, 1)
	label.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(12, 30, 60)
	stroke.Parent = label
	label.Parent = gui
	gui.Parent = anchor
	return label
end

----------------------------------------------------------------------------------------------------
-- The kitchen around the dishwasher
----------------------------------------------------------------------------------------------------

-- Room styles: every level uses the same dishwasher, set in a different room.
type RoomStyle = { [string]: any }
local ROOM_STYLES: { RoomStyle } = {
	-- 1: Family kitchen.
	{
		Floor = K.Floor, FloorMat = Enum.Material.WoodPlanks,
		Wall = K.Wall, WallMat = Enum.Material.SmoothPlastic,
		Ceiling = Color3.fromRGB(248, 248, 246),
		Cabinet = K.Cabinet, CabinetDoor = K.CabinetDoor, CabMat = Enum.Material.SmoothPlastic,
		Counter = K.Counter, CounterMat = Enum.Material.Marble,
		Tile = K.Tile, TileMat = Enum.Material.CeramicTiles,
		Handle = K.Handle, HandleMat = Enum.Material.Metal,
		Kick = K.Kick,
		Lamp = Color3.fromRGB(255, 248, 225),
	},
	-- 2: Pizzeria: brick walls, black and white floor, steel cabinets, butcher-block counter.
	{
		Floor = Color3.fromRGB(240, 238, 232), Floor2 = Color3.fromRGB(38, 38, 42), FloorMat = Enum.Material.SmoothPlastic,
		Wall = Color3.fromRGB(165, 78, 58), WallMat = Enum.Material.Brick,
		Ceiling = Color3.fromRGB(60, 50, 46),
		Cabinet = Color3.fromRGB(188, 193, 200), CabinetDoor = Color3.fromRGB(205, 210, 216), CabMat = Enum.Material.Metal,
		Counter = Color3.fromRGB(176, 124, 78), CounterMat = Enum.Material.Wood,
		Tile = Color3.fromRGB(245, 245, 240), TileMat = Enum.Material.CeramicTiles,
		Handle = Color3.fromRGB(60, 60, 66), HandleMat = Enum.Material.Metal,
		Kick = Color3.fromRGB(40, 40, 44),
		Lamp = Color3.fromRGB(255, 214, 150),
	},
	-- 3: Castle banquet hall: stone, dark wood, gold, a red carpet.
	{
		Floor = Color3.fromRGB(128, 122, 116), FloorMat = Enum.Material.Slate,
		Wall = Color3.fromRGB(150, 144, 136), WallMat = Enum.Material.Cobblestone,
		Ceiling = Color3.fromRGB(70, 52, 40),
		Cabinet = Color3.fromRGB(92, 58, 38), CabinetDoor = Color3.fromRGB(112, 72, 46), CabMat = Enum.Material.Wood,
		Counter = Color3.fromRGB(238, 232, 222), CounterMat = Enum.Material.Marble,
		Tile = Color3.fromRGB(120, 112, 104), TileMat = Enum.Material.Slate,
		Handle = Color3.fromRGB(230, 190, 90), HandleMat = Enum.Material.Metal,
		Kick = Color3.fromRGB(50, 34, 24),
		Lamp = Color3.fromRGB(255, 205, 140),
	},
}

-- A flat SurfaceGui text sign on a box. `face` is the side the text is on.
local function roomSign(b: Builder, text: string, size: Vector3, x: number, y: number, z: number, bg: Color3, fg: Color3, face: Enum.NormalId, material: Enum.Material?)
	local p = box(b, "RoomSign", size, x, y, z, bg, material, noCollide())
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 8
	gui.Parent = p
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(0.9, 0.8)
	label.Position = UDim2.fromScale(0.05, 0.1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = fg
	label.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Color = Color3.fromRGB(20, 16, 14)
	stroke.Parent = label
	label.Parent = gui
	return p
end

-- Floor, walls, ceiling, base and upper cabinets and the counter over the dishwasher.
local function buildKitchen(b: Builder, k: RoomStyle)
	local fy = KITCHEN_FLOOR_Y
	local shadowless = { CastShadow = false }

	-- Floor: one slab, or a big checkerboard when the style has a second colour.
	if k.Floor2 then
		span(b, "KitchenFloor", -ROOM_HALF_X, ROOM_HALF_X, fy - 4, fy - 0.2, ROOM_Z_FRONT, ROOM_Z_BACK, k.Floor2, k.FloorMat)
		local tile = 60
		local ix = 0
		for x = -ROOM_HALF_X, ROOM_HALF_X - 1, tile do
			local iz = 0
			for z = ROOM_Z_FRONT, ROOM_Z_BACK - 1, tile do
				if (ix + iz) % 2 == 0 then
					span(b, "FloorTile", x, math.min(x + tile, ROOM_HALF_X), fy - 0.2, fy, z, math.min(z + tile, ROOM_Z_BACK), k.Floor, k.FloorMat)
				end
				iz += 1
			end
			ix += 1
		end
	else
		span(b, "KitchenFloor", -ROOM_HALF_X, ROOM_HALF_X, fy - 4, fy, ROOM_Z_FRONT, ROOM_Z_BACK, k.Floor, k.FloorMat)
	end
	span(b, "BackWall", -ROOM_HALF_X, ROOM_HALF_X, fy, fy + ROOM_HEIGHT, ROOM_Z_BACK, ROOM_Z_BACK + 4, k.Wall, k.WallMat, shadowless)
	span(b, "FrontWall", -ROOM_HALF_X, ROOM_HALF_X, fy, fy + ROOM_HEIGHT, ROOM_Z_FRONT - 4, ROOM_Z_FRONT, k.Wall, k.WallMat, shadowless)
	for _, side in { -1, 1 } do
		span(b, "SideWall", side * ROOM_HALF_X, side * (ROOM_HALF_X + 4), fy, fy + ROOM_HEIGHT, ROOM_Z_FRONT, ROOM_Z_BACK, k.Wall, k.WallMat, shadowless)
		span(b, "Skirting", side * (ROOM_HALF_X - 2), side * ROOM_HALF_X, fy, fy + 10, ROOM_Z_FRONT, ROOM_Z_BACK, k.Kick, nil, noCollide())
	end
	span(b, "Ceiling", -ROOM_HALF_X, ROOM_HALF_X, fy + ROOM_HEIGHT, fy + ROOM_HEIGHT + 4, ROOM_Z_FRONT, ROOM_Z_BACK, k.Ceiling, nil, shadowless)

	-- Base cabinets either side of the dishwasher, with doors, handles and a toe kick.
	local cabFront = -54
	for _, side in { -1, 1 } do
		local x0, x1 = side * 62, side * ROOM_HALF_X
		span(b, "Cabinets", x0, x1, fy + 12, COUNTER_TOP_Y - 6, cabFront, ROOM_Z_BACK, k.Cabinet, k.CabMat)
		span(b, "ToeKick", x0, x1, fy, fy + 12, cabFront + 8, ROOM_Z_BACK, k.Kick)
		local width = math.abs(x1 - x0)
		local doors = math.floor(width / 80)
		local doorW = width / doors
		for i = 0, doors - 1 do
			local cx = side * (62 + doorW * (i + 0.5))
			box(b, "Drawer", Vector3.new(doorW - 6, 26, 1.5), cx, COUNTER_TOP_Y - 24, cabFront - 0.75, k.CabinetDoor, k.CabMat)
			box(b, "DrawerHandle", Vector3.new(24, 2.5, 2.5), cx, COUNTER_TOP_Y - 24, cabFront - 2.5, k.Handle, k.HandleMat, noCollide())
			box(b, "Door", Vector3.new(doorW - 6, 66, 1.5), cx, fy + 12 + 38, cabFront - 0.75, k.CabinetDoor, k.CabMat)
			box(b, "DoorHandle", Vector3.new(2.5, 20, 2.5), cx + side * -(doorW / 2 - 12), fy + 12 + 55, cabFront - 2.5, k.Handle, k.HandleMat, noCollide())
		end
	end

	-- Countertop across the whole run (including over the dishwasher) with a backsplash.
	span(b, "Countertop", -ROOM_HALF_X, ROOM_HALF_X, COUNTER_TOP_Y - 6, COUNTER_TOP_Y, cabFront - 6, ROOM_Z_BACK, k.Counter, k.CounterMat, shadowless)
	span(b, "Backsplash", -ROOM_HALF_X, ROOM_HALF_X, COUNTER_TOP_Y, COUNTER_TOP_Y + 70, ROOM_Z_BACK - 1, ROOM_Z_BACK, k.Tile, k.TileMat, noCollide())

	-- Upper cabinets, leaving a gap over the sink area for each room's centrepiece.
	local upperY0, upperY1 = COUNTER_TOP_Y + 120, COUNTER_TOP_Y + 270
	for _, seg in { { -ROOM_HALF_X, -220 }, { -40, ROOM_HALF_X } } do
		span(b, "UpperCabinets", seg[1], seg[2], upperY0, upperY1, ROOM_Z_BACK - 40, ROOM_Z_BACK, k.Cabinet, k.CabMat, shadowless)
		local w = seg[2] - seg[1]
		local n = math.floor(w / 70)
		for i = 0, n - 1 do
			local cx = seg[1] + w / n * (i + 0.5)
			box(b, "UpperDoor", Vector3.new(w / n - 5, upperY1 - upperY0 - 8, 1.2), cx, (upperY0 + upperY1) / 2, ROOM_Z_BACK - 40.6, k.CabinetDoor, k.CabMat, noCollide())
			box(b, "UpperHandle", Vector3.new(2.5, 16, 2.5), cx + (w / n / 2 - 10), upperY0 + 16, ROOM_Z_BACK - 42, k.Handle, k.HandleMat, noCollide())
		end
	end
end

-- A table (top + 4 legs) with chairs either side, in room space.
local function diningSet(b: Builder, tz: number, halfW: number, color: Color3, material: Enum.Material, chairsPerSide: number, chairColor: Color3?)
	local fy = KITCHEN_FLOOR_Y
	local tyTop = fy + 150
	span(b, "TableTop", -halfW, halfW, tyTop - 8, tyTop, tz - 90, tz + 90, color, material)
	for _, lx in { -halfW + 15, halfW - 15 } do
		for _, lz in { tz - 75, tz + 75 } do
			span(b, "TableLeg", lx - 6, lx + 6, fy, tyTop - 8, lz - 6, lz + 6, color, material)
		end
	end
	local cc = chairColor or color
	for i = 1, chairsPerSide do
		local cx = -halfW + (2 * halfW) * (i - 0.5) / chairsPerSide
		for _, dir in { -1, 1 } do
			local cz = tz + dir * 125
			span(b, "ChairSeat", cx - 40, cx + 40, fy + 90, fy + 98, cz - 35, cz + 35, cc, material)
			span(b, "ChairBack", cx - 40, cx + 40, fy + 98, fy + 200, cz + dir * 30, cz + dir * 36, cc, material)
			for _, lx in { cx - 34, cx + 34 } do
				for _, lz in { cz - 29, cz + 29 } do
					span(b, "ChairLeg", lx - 4, lx + 4, fy, fy + 90, lz - 4, lz + 4, cc, material)
				end
			end
		end
	end
	return tyTop
end

-- Level 1: window over the sink, kettle, fruit, fridge, family table.
local function familyProps(b: Builder, k: RoomStyle)
	local fy = KITCHEN_FLOOR_Y
	local lamp = cyl(b, "CeilingLamp", 4, 70, 0, fy + ROOM_HEIGHT - 4, -200, k.Lamp, Enum.Material.Neon, noCollide())
	lamp.CastShadow = false

	local wx0, wx1 = -210, -50
	local wy0, wy1 = COUNTER_TOP_Y + 90, COUNTER_TOP_Y + 260
	local sky = span(b, "WindowSky", wx0, wx1, wy0, wy1, ROOM_Z_BACK - 0.5, ROOM_Z_BACK + 0.5, Color3.fromRGB(190, 225, 255), Enum.Material.Neon, noCollide())
	sky.CastShadow = false
	span(b, "WindowSill", wx0 - 8, wx1 + 8, wy0 - 6, wy0, ROOM_Z_BACK - 10, ROOM_Z_BACK, Color3.new(1, 1, 1), nil, noCollide())
	for _, x in { wx0, (wx0 + wx1) / 2, wx1 } do
		span(b, "WindowBar", x - 3, x + 3, wy0, wy1, ROOM_Z_BACK - 3, ROOM_Z_BACK, Color3.new(1, 1, 1), nil, noCollide())
	end
	for _, y in { wy0, (wy0 + wy1) / 2, wy1 } do
		span(b, "WindowBar", wx0, wx1, y - 3, y + 3, ROOM_Z_BACK - 3, ROOM_Z_BACK, Color3.new(1, 1, 1), nil, noCollide())
	end

	local sinkX = (wx0 + wx1) / 2
	span(b, "Sink", sinkX - 60, sinkX + 60, COUNTER_TOP_Y - 0.4, COUNTER_TOP_Y + 0.2, -10, 50, K.Steel, Enum.Material.Metal, noCollide())
	span(b, "SinkBasin", sinkX - 54, sinkX + 54, COUNTER_TOP_Y - 0.2, COUNTER_TOP_Y + 0.4, -4, 44, Color3.fromRGB(120, 125, 132), Enum.Material.Metal, noCollide())
	cyl(b, "FaucetBase", 6, 10, sinkX, COUNTER_TOP_Y + 3, 60, K.Steel, Enum.Material.Metal, noCollide())
	cyl(b, "FaucetPipe", 60, 5, sinkX, COUNTER_TOP_Y + 33, 60, K.Steel, Enum.Material.Metal, noCollide())
	box(b, "FaucetSpout", Vector3.new(5, 5, 40), sinkX, COUNTER_TOP_Y + 62, 42, K.Steel, Enum.Material.Metal, noCollide())
	cyl(b, "SoapBottle", 40, 16, sinkX + 90, COUNTER_TOP_Y + 20, 40, Color3.fromRGB(80, 200, 120), Enum.Material.Glass, { CanCollide = false, Transparency = 0.15 })
	cyl(b, "SoapCap", 8, 9, sinkX + 90, COUNTER_TOP_Y + 44, 40, Color3.new(1, 1, 1), nil, noCollide())

	cyl(b, "Kettle", 40, 34, 230, COUNTER_TOP_Y + 20, 30, K.Steel, Enum.Material.Metal, noCollide())
	box(b, "KettleHandle", Vector3.new(26, 5, 5), 230, COUNTER_TOP_Y + 44, 30, Color3.fromRGB(40, 40, 44), nil, noCollide())
	cyl(b, "FruitBowl", 14, 60, 330, COUNTER_TOP_Y + 7, 20, Color3.fromRGB(230, 120, 80), nil, noCollide())
	for i, c in { Color3.fromRGB(230, 50, 50), Color3.fromRGB(255, 200, 40), Color3.fromRGB(120, 200, 60) } do
		local ball = box(b, "Fruit", Vector3.new(18, 18, 18), 318 + i * 7, COUNTER_TOP_Y + 20, 14 + (i % 2) * 10, c, nil, noCollide())
		ball.Shape = Enum.PartType.Ball
	end

	span(b, "Fridge", 300, ROOM_HALF_X, fy, fy + 380, -260, -120, Color3.fromRGB(235, 238, 242), Enum.Material.SmoothPlastic)
	box(b, "FridgeHandle", Vector3.new(3, 90, 3), 297, fy + 230, -150, K.Handle, Enum.Material.Metal, noCollide())
	box(b, "FridgeHandle", Vector3.new(3, 60, 3), 297, fy + 110, -150, K.Handle, Enum.Material.Metal, noCollide())
	box(b, "FridgeSeam", Vector3.new(1, 2, 140), 299.8, fy + 170, -190, Color3.fromRGB(180, 185, 190), nil, noCollide())

	local tz = -330
	local tyTop = diningSet(b, tz, 150, K.Wood, Enum.Material.Wood, 2)
	for i = 0, 2 do
		cyl(b, "TablePlate", 2, 60, -80 + i * 80, tyTop + 1, tz, Color3.new(1, 1, 1), nil, noCollide())
	end
end

-- Level 2: a pizzeria. Brick pizza oven with a glowing mouth, a neon PIZZA sign over the counter,
-- stacks of pizza boxes, red-and-white checked tables and hanging lamps.
local function pizzeriaProps(b: Builder, k: RoomStyle)
	local fy = KITCHEN_FLOOR_Y
	local brick = Color3.fromRGB(150, 70, 52)
	local red = Color3.fromRGB(205, 45, 40)
	local cream = Color3.fromRGB(250, 244, 230)

	-- Neon sign in the gap over the counter.
	span(b, "SignBack", -214, -46, COUNTER_TOP_Y + 110, COUNTER_TOP_Y + 240, ROOM_Z_BACK - 3, ROOM_Z_BACK, Color3.fromRGB(30, 26, 26), nil, noCollide())
	roomSign(b, "🍕 PIZZA", Vector3.new(150, 70, 2), -130, COUNTER_TOP_Y + 175, ROOM_Z_BACK - 4, Color3.fromRGB(30, 26, 26), Color3.fromRGB(255, 120, 70), Enum.NormalId.Back)
	for _, y in { COUNTER_TOP_Y + 132, COUNTER_TOP_Y + 218 } do
		span(b, "NeonStrip", -200, -60, y - 1.5, y + 1.5, ROOM_Z_BACK - 6, ROOM_Z_BACK - 4, Color3.fromRGB(255, 90, 60), Enum.Material.Neon, noCollide())
	end

	-- Brick pizza oven standing on the floor on the right: a box base and a stepped dome, with a
	-- glowing arched mouth facing the players.
	local ox, oz = 250, -170
	span(b, "OvenBase", ox - 90, ox + 90, fy, fy + 110, oz - 80, oz + 80, brick, Enum.Material.Brick)
	for i, w in { 86, 74, 58, 38 } do
		local y0 = fy + 110 + (i - 1) * 34
		span(b, "OvenDome", ox - w, ox + w, y0, y0 + 34, oz - w * 0.9, oz + w * 0.9, brick, Enum.Material.Brick)
	end
	span(b, "OvenChimney", ox - 14, ox + 14, fy + 246, fy + ROOM_HEIGHT, oz - 14, oz + 14, Color3.fromRGB(120, 58, 44), Enum.Material.Brick)
	span(b, "OvenMouth", ox - 44, ox + 44, fy + 124, fy + 184, oz - 80.5, oz - 76, Color3.fromRGB(255, 130, 40), Enum.Material.Neon, noCollide())
	cyl(b, "OvenArch", 5, 88, ox, fy + 184, oz - 78.5, Color3.fromRGB(255, 150, 60), Enum.Material.Neon, noCollide()).CFrame = footprint(b.origin, ox, fy + 184, oz - 78.5) * CFrame.Angles(0, math.rad(90), 0)
	span(b, "OvenLedge", ox - 60, ox + 60, fy + 110, fy + 118, oz - 100, oz - 80, Color3.fromRGB(190, 180, 170), Enum.Material.Concrete)
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 140, 60)
	glow.Brightness = 2
	glow.Range = 60
	glow.Parent = b.model:FindFirstChild("OvenMouth") or b.model
	-- A pizza peel leaning on the oven.
	span(b, "PeelHandle", ox - 110, ox - 104, fy, fy + 190, oz - 60, oz - 54, Color3.fromRGB(170, 120, 70), Enum.Material.Wood, noCollide())
	cyl(b, "PeelHead", 3, 50, ox - 107, fy + 30, oz - 57, Color3.fromRGB(185, 135, 85), Enum.Material.Wood, noCollide()).CFrame = footprint(b.origin, ox - 107, fy + 30, oz - 57) * CFrame.Angles(0, math.rad(90), 0)

	-- Stacks of pizza boxes on the left.
	for _, stack in { { -260, -200, 7 }, { -300, -150, 5 }, { -230, -130, 4 } } do
		for j = 0, stack[3] - 1 do
			local y = fy + 4 + j * 8
			span(b, "PizzaBox", stack[1] - 30, stack[1] + 30, y - 4, y + 3.6, stack[2] - 30, stack[2] + 30, cream, Enum.Material.Cardboard)
			span(b, "PizzaBoxLogo", stack[1] - 12, stack[1] + 12, y + 3.6, y + 3.8, stack[2] - 12, stack[2] + 12, red, nil, noCollide())
		end
	end

	-- Two square tables with red-and-white checked cloths and a pizza on each, plus stools.
	for _, tx in { -150, 150 } do
		local tz = -400
		local top = fy + 150
		span(b, "TableLeg", tx - 5, tx + 5, fy, top - 6, tz - 5, tz + 5, Color3.fromRGB(40, 40, 44), Enum.Material.Metal)
		cyl(b, "TableFoot", 4, 60, tx, fy + 2, tz, Color3.fromRGB(40, 40, 44), Enum.Material.Metal)
		span(b, "TableTop", tx - 66, tx + 66, top - 6, top, tz - 66, tz + 66, Color3.fromRGB(120, 80, 50), Enum.Material.Wood)
		local n, cell = 5, 26
		for i = 0, n - 1 do
			for j = 0, n - 1 do
				local cx = tx - cell * n / 2 + cell * (i + 0.5)
				local cz = tz - cell * n / 2 + cell * (j + 0.5)
				box(b, "Cloth", Vector3.new(cell, 0.4, cell), cx, top + 0.2, cz, if (i + j) % 2 == 0 then red else cream, Enum.Material.Fabric, noCollide())
			end
		end
		cyl(b, "Pizza", 3, 70, tx, top + 1.9, tz, Color3.fromRGB(230, 170, 80), Enum.Material.Sand, noCollide())
		cyl(b, "PizzaSauce", 3.2, 60, tx, top + 2, tz, Color3.fromRGB(200, 60, 35), nil, noCollide())
		for i = 0, 6 do
			local a = i / 7 * math.pi * 2
			cyl(b, "Pepperoni", 3.4, 11, tx + math.cos(a) * 18, top + 2.1, tz + math.sin(a) * 18, Color3.fromRGB(160, 30, 30), nil, noCollide())
		end
		for _, dz in { -95, 95 } do
			cyl(b, "StoolSeat", 8, 44, tx, fy + 90, tz + dz, red)
			span(b, "StoolPost", tx - 3, tx + 3, fy, fy + 86, tz + dz - 3, tz + dz + 3, Color3.fromRGB(40, 40, 44), Enum.Material.Metal)
		end
	end

	-- Hanging pendant lamps.
	for _, lx in { -200, 0, 200 } do
		span(b, "LampCord", lx - 0.8, lx + 0.8, fy + 330, fy + ROOM_HEIGHT, -260 - 0.8, -260 + 0.8, Color3.fromRGB(30, 30, 30), nil, noCollide())
		cyl(b, "LampShade", 26, 60, lx, fy + 330, -260, Color3.fromRGB(40, 40, 44), Enum.Material.Metal, noCollide())
		local bulb = cyl(b, "LampBulb", 2, 40, lx, fy + 316, -260, k.Lamp, Enum.Material.Neon, noCollide())
		bulb.CastShadow = false
	end
end

-- Level 3: a castle banquet hall. Stone pillars, red banners with gold trim, a red carpet, a long
-- banquet table with candelabras and goblets, a fireplace, a stained-glass window and chandeliers.
local function castleProps(b: Builder, k: RoomStyle)
	local fy = KITCHEN_FLOOR_Y
	local gold = Color3.fromRGB(230, 190, 90)
	local red = Color3.fromRGB(150, 25, 35)
	local stone = Color3.fromRGB(170, 164, 156)

	-- Red carpet from the door to the far wall.
	span(b, "Carpet", -70, 70, fy, fy + 0.4, ROOM_Z_FRONT, -125, red, Enum.Material.Fabric, noCollide())
	for _, x in { -72, 72 } do
		span(b, "CarpetTrim", x - 3, x + 3, fy, fy + 0.5, ROOM_Z_FRONT, -125, gold, Enum.Material.Fabric, noCollide())
	end

	-- Stained-glass window in the gap over the counter.
	local wx0, wx1 = -210, -50
	local wy0, wy1 = COUNTER_TOP_Y + 90, COUNTER_TOP_Y + 260
	local colors = { Color3.fromRGB(80, 120, 230), Color3.fromRGB(220, 60, 70), Color3.fromRGB(250, 200, 70), Color3.fromRGB(80, 190, 120) }
	local cols, rows = 4, 5
	for i = 0, cols - 1 do
		for j = 0, rows - 1 do
			local x0 = wx0 + (wx1 - wx0) * i / cols
			local y0 = wy0 + (wy1 - wy0) * j / rows
			local pane = span(b, "StainedGlass", x0, x0 + (wx1 - wx0) / cols, y0, y0 + (wy1 - wy0) / rows, ROOM_Z_BACK - 0.5, ROOM_Z_BACK + 0.5, colors[(i + j) % #colors + 1], Enum.Material.Neon, noCollide())
			pane.Transparency = 0.25
			pane.CastShadow = false
		end
	end
	for _, x in { wx0, wx0 + 40, wx0 + 80, wx0 + 120, wx1 } do
		span(b, "Leading", x - 2, x + 2, wy0, wy1, ROOM_Z_BACK - 2.5, ROOM_Z_BACK - 0.5, Color3.fromRGB(40, 36, 34), nil, noCollide())
	end
	span(b, "WindowArch", wx0 - 10, wx1 + 10, wy1, wy1 + 16, ROOM_Z_BACK - 6, ROOM_Z_BACK, stone, Enum.Material.Cobblestone, noCollide())

	-- Pillars along both side walls, each with a banner between.
	for _, side in { -1, 1 } do
		for i, z in { -460, -340, -220, -100 } do
			-- The fireplace takes the right wall around z -240.
			if side == 1 and (z == -220 or z == -340) then
				continue
			end
			local x = side * (ROOM_HALF_X - 30)
			span(b, "Pillar", x - 20, x + 20, fy, fy + ROOM_HEIGHT, z - 20, z + 20, stone, Enum.Material.Cobblestone)
			span(b, "PillarBase", x - 26, x + 26, fy, fy + 18, z - 26, z + 26, Color3.fromRGB(130, 124, 116), Enum.Material.Slate)
			span(b, "PillarCap", x - 26, x + 26, fy + ROOM_HEIGHT - 24, fy + ROOM_HEIGHT, z - 26, z + 26, Color3.fromRGB(130, 124, 116), Enum.Material.Slate)
			if i < 4 then
				local bz = z + 60
				local bx = side * (ROOM_HALF_X - 3)
				span(b, "Banner", bx - 1, bx + 1, fy + 220, fy + 440, bz - 30, bz + 30, red, Enum.Material.Fabric, noCollide())
				span(b, "BannerTrim", bx - 1.4, bx + 1.4, fy + 216, fy + 222, bz - 32, bz + 32, gold, Enum.Material.Metal, noCollide())
				span(b, "BannerRod", bx - 3, bx + 3, fy + 440, fy + 446, bz - 36, bz + 36, gold, Enum.Material.Metal, noCollide())
				span(b, "BannerCrest", bx - 1.6, bx + 1.6, fy + 320, fy + 350, bz - 12, bz + 12, gold, Enum.Material.Metal, noCollide())
			end
		end
	end

	-- Fireplace on the right, with a glowing fire.
	local fx = ROOM_HALF_X - 30
	span(b, "Hearth", fx - 30, ROOM_HALF_X, fy, fy + 200, -300, -180, stone, Enum.Material.Cobblestone)
	span(b, "FireBox", fx - 31, fx - 6, fy, fy + 110, -275, -205, Color3.fromRGB(30, 22, 18), Enum.Material.Slate)
	local fire = span(b, "Fire", fx - 26, fx - 16, fy, fy + 50, -262, -218, Color3.fromRGB(255, 140, 40), Enum.Material.Neon, noCollide())
	local fireLight = Instance.new("PointLight")
	fireLight.Color = Color3.fromRGB(255, 150, 70)
	fireLight.Brightness = 2
	fireLight.Range = 60
	fireLight.Parent = fire
	span(b, "Mantel", fx - 40, ROOM_HALF_X, fy + 200, fy + 212, -310, -170, Color3.fromRGB(92, 58, 38), Enum.Material.Wood)

	-- Long banquet table down the carpet (lengthwise, so the chairs never block the view from the
	-- door), with a gold runner, candelabras, platters and goblets. Chairs with tall red backs.
	local wood = Color3.fromRGB(92, 58, 38)
	local tz0, tz1, thx = -490, -230, 55
	local tyTop = fy + 150
	span(b, "TableTop", -thx, thx, tyTop - 8, tyTop, tz0, tz1, wood, Enum.Material.Wood)
	for _, lx in { -thx + 10, thx - 10 } do
		for _, lz in { tz0 + 12, (tz0 + tz1) / 2, tz1 - 12 } do
			span(b, "TableLeg", lx - 6, lx + 6, fy, tyTop - 8, lz - 6, lz + 6, wood, Enum.Material.Wood)
		end
	end
	span(b, "Runner", -16, 16, tyTop, tyTop + 0.3, tz0 + 8, tz1 - 8, gold, Enum.Material.Fabric, noCollide())
	for i = 0, 4 do
		local cz = tz0 + 26 + i * 52
		for _, side in { -1, 1 } do
			local cx = side * (thx + 45)
			span(b, "ChairSeat", cx - 32, cx + 32, fy + 90, fy + 98, cz - 20, cz + 20, red, Enum.Material.Fabric)
			span(b, "ChairBack", cx + side * 28, cx + side * 34, fy + 98, fy + 210, cz - 20, cz + 20, wood, Enum.Material.Wood)
			span(b, "ChairCrest", cx + side * 27.6, cx + side * 28, fy + 170, fy + 200, cz - 10, cz + 10, gold, Enum.Material.Metal, noCollide())
			for _, lx in { cx - 27, cx + 27 } do
				for _, lz in { cz - 15, cz + 15 } do
					span(b, "ChairLeg", lx - 3, lx + 3, fy, fy + 90, lz - 3, lz + 3, wood, Enum.Material.Wood)
				end
			end
			cyl(b, "PlatterOnTable", 2, 34, side * 32, tyTop + 1, cz, gold, Enum.Material.Metal, noCollide())
			cyl(b, "GobletStem", 12, 3, side * 32, tyTop + 6, cz + 22, gold, Enum.Material.Metal, noCollide())
			cyl(b, "GobletCup", 10, 11, side * 32, tyTop + 17, cz + 22, gold, Enum.Material.Metal, noCollide())
		end
	end
	for _, cz in { tz0 + 50, (tz0 + tz1) / 2, tz1 - 50 } do
		cyl(b, "CandelabraBase", 4, 20, 0, tyTop + 2, cz, gold, Enum.Material.Metal, noCollide())
		span(b, "CandelabraStem", -2, 2, tyTop, tyTop + 40, cz - 2, cz + 2, gold, Enum.Material.Metal, noCollide())
		span(b, "CandelabraArm", -2, 2, tyTop + 38, tyTop + 42, cz - 22, cz + 22, gold, Enum.Material.Metal, noCollide())
		for _, dz in { -20, 0, 20 } do
			cyl(b, "Candle", 18, 5, 0, tyTop + 51, cz + dz, Color3.fromRGB(250, 245, 230), nil, noCollide())
			local flame = box(b, "Flame", Vector3.new(3, 5, 3), 0, tyTop + 63, cz + dz, Color3.fromRGB(255, 190, 70), Enum.Material.Neon, noCollide())
			flame.Shape = Enum.PartType.Ball
		end
	end
	-- A throne at the head of the table.
	span(b, "ThroneSeat", -40, 40, fy, fy + 100, tz0 - 28, tz0 - 4, red, Enum.Material.Fabric)
	span(b, "ThroneBack", -44, 44, fy, fy + 260, tz0 - 30, tz0 - 22, gold, Enum.Material.Metal)
	for _, x in { -30, 0, 30 } do
		local spike = box(b, "ThroneSpike", Vector3.new(14, 14, 8), x, fy + 268, tz0 - 26, gold, Enum.Material.Metal, noCollide())
		spike.Shape = Enum.PartType.Ball
	end

	-- Two chandeliers: a gold ring with glowing candles on a chain.
	for _, cz in { -400, -230 } do
		span(b, "Chain", -1, 1, fy + 360, fy + ROOM_HEIGHT, cz - 1, cz + 1, gold, Enum.Material.Metal, noCollide())
		cyl(b, "ChandelierRing", 6, 120, 0, fy + 360, cz, gold, Enum.Material.Metal, noCollide())
		for i = 0, 9 do
			local a = i / 10 * math.pi * 2
			local x, z = math.cos(a) * 56, cz + math.sin(a) * 56
			cyl(b, "ChCandle", 14, 5, x, fy + 370, z, Color3.fromRGB(250, 245, 230), nil, noCollide())
			local flame = box(b, "ChFlame", Vector3.new(4, 6, 4), x, fy + 380, z, Color3.fromRGB(255, 190, 70), Enum.Material.Neon, noCollide())
			flame.Shape = Enum.PartType.Ball
		end
	end
end

-- The whole room for a level: shell + that room's props.
local function buildRoom(b: Builder, levelIndex: number)
	local style = ROOM_STYLES[levelIndex] or ROOM_STYLES[1]
	buildKitchen(b, style)
	if levelIndex == 2 then
		pizzeriaProps(b, style)
	elseif levelIndex == 3 then
		castleProps(b, style)
	else
		familyProps(b, style)
	end
end

----------------------------------------------------------------------------------------------------
-- The dishwasher body, tub and door
----------------------------------------------------------------------------------------------------

local function buildTub(b: Builder, theme)
	local steel = theme.Tub
	local zMid = (TUB_Z_MIN + TUB_Z_MAX) / 2

	-- Tub floor and walls. They don't cast shadows, so the room's daylight still reaches inside.
	span(b, "TubFloor", -TUB_HALF_X - 2, TUB_HALF_X + 2, -2, 0, TUB_Z_MIN, TUB_Z_MAX, steel, Enum.Material.Metal)
	for _, side in { -1, 1 } do
		span(b, "TubWall", side * TUB_HALF_X, side * (TUB_HALF_X + 2), 0, TUB_HEIGHT, TUB_Z_MIN, TUB_Z_MAX, steel, Enum.Material.Metal)
		-- Pressed ribs and rack rails on the side walls.
		for i = 1, 6 do
			local y = i * (TUB_HEIGHT / 7)
			span(b, "Rib", side * (TUB_HALF_X - 0.3), side * TUB_HALF_X, y - 0.4, y + 0.4, TUB_Z_MIN + 4, TUB_Z_MAX - 4, theme.Metal, Enum.Material.Metal, noCollide())
		end
		for _, y in { BOTTOM_RACK_Y - 1, TOP_RACK_Y - 1 } do
			span(b, "RackRail", side * (TUB_HALF_X - 1.6), side * TUB_HALF_X, y - 0.8, y + 0.8, TUB_Z_MIN + 2, TUB_Z_MAX - 2, theme.Rack, Enum.Material.Metal, noCollide())
		end
	end
	-- The tub casts shadows (it's a closed box, like a real machine): the inside is lit by the
	-- interior lights below rather than blasted by daylight.
	span(b, "TubBack", -TUB_HALF_X - 2, TUB_HALF_X + 2, 0, TUB_HEIGHT, TUB_Z_MAX, TUB_Z_MAX + 2, steel, Enum.Material.Metal)
	span(b, "TubCeiling", -TUB_HALF_X - 2, TUB_HALF_X + 2, TUB_HEIGHT, TUB_HEIGHT + 2, TUB_Z_MIN, TUB_Z_MAX, steel, Enum.Material.Metal)

	-- Filter cup in the floor at the back, heating element loop.
	cyl(b, "Filter", 0.4, 14, 0, 0.2, 30, Color3.fromRGB(120, 125, 130), Enum.Material.DiamondPlate, noCollide())
	for _, x in { -40, 40 } do
		span(b, "Heater", x - 0.6, x + 0.6, 0.4, 1.4, -10, 50, Color3.fromRGB(90, 90, 95), Enum.Material.Metal, noCollide())
	end
	span(b, "Heater", -40, 40, 0.4, 1.4, 49.4, 50.6, Color3.fromRGB(90, 90, 95), Enum.Material.Metal, noCollide())

	-- Front frame around the opening, the machine's side panels, and the toe kick under the door.
	-- (Offsets of 0.2 keep every face off its neighbours' planes, so nothing flickers.)
	span(b, "FrameTop", -TUB_HALF_X - 6.2, TUB_HALF_X + 6.2, TUB_HEIGHT - 0.2, COUNTER_TOP_Y - 6, TUB_Z_MIN - 3.2, TUB_Z_MIN + 2, K.Frame, Enum.Material.Metal)
	for _, side in { -1, 1 } do
		span(b, "FrameSide", side * (TUB_HALF_X - 0.2), side * (TUB_HALF_X + 6), KITCHEN_FLOOR_Y, TUB_HEIGHT, TUB_Z_MIN - 3, TUB_Z_MIN + 2, K.Frame, Enum.Material.Metal)
		span(b, "Gasket", side * (TUB_HALF_X - 0.4), side * TUB_HALF_X, 0, TUB_HEIGHT - 0.4, TUB_Z_MIN - 0.5, TUB_Z_MIN + 1, Color3.fromRGB(50, 50, 55), nil, noCollide())
	end
	span(b, "UnderTub", -TUB_HALF_X - 5.8, TUB_HALF_X + 5.8, KITCHEN_FLOOR_Y + 12, -2.2, TUB_Z_MIN + 1, TUB_Z_MAX, Color3.fromRGB(90, 90, 95), Enum.Material.Metal)
	span(b, "ToeKick", -TUB_HALF_X, TUB_HALF_X, KITCHEN_FLOOR_Y, KITCHEN_FLOOR_Y + 12, TUB_Z_MIN + 6, TUB_Z_MAX, K.Kick)

	-- Interior lights so the load is easy to see (PointLight range tops out at 60 studs).
	for _, spot in { { -30, 90, -20 }, { 30, 90, -20 }, { -30, 90, 35 }, { 30, 90, 35 }, { -30, 44, 0 }, { 30, 44, 0 }, { 0, 44, 40 } } do
		local lightPart = box(b, "InteriorLight", Vector3.new(1, 1, 1), spot[1], spot[2], spot[3], theme.Light, nil, { Transparency = 1, CanCollide = false, CastShadow = false })
		local light = Instance.new("PointLight")
		light.Color = theme.Light
		light.Brightness = if spot[2] > 60 then 0.45 else 0.6
		light.Range = 60
		light.Shadows = false
		light.Parent = lightPart
	end

	-- Drifting bubbles for mood.
	local bubbleAnchor = box(b, "BubbleAnchor", Vector3.new(80, 1, 80), 0, 30, zMid, theme.Accent, nil, { Transparency = 1, CanCollide = false })
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/forcefield_glow_main.dds"
	emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
	emitter.LightEmission = 0.3
	emitter.Lifetime = NumberRange.new(5, 8)
	emitter.Speed = NumberRange.new(1, 3)
	emitter.Rate = 3
	emitter.Size = NumberSequence.new(0.8, 0.3)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.SpreadAngle = Vector2.new(30, 30)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Parent = bubbleAnchor
end

local function buildDoor(b: Builder, theme)
	-- Inner panel (the floor you stand on) and the outer skin below it.
	span(b, "DoorInner", -TUB_HALF_X, TUB_HALF_X, -1, 0, DOOR_Z_FAR, DOOR_Z_NEAR, theme.Tub, Enum.Material.Metal)
	span(b, "DoorOuter", -TUB_HALF_X - 4, TUB_HALF_X + 4, -DOOR_THICK, -1, DOOR_Z_FAR - 6, DOOR_Z_NEAR, K.Frame, Enum.Material.Metal)
	-- Raised edges down the sides of the inner panel.
	for _, side in { -1, 1 } do
		span(b, "DoorEdge", side * (TUB_HALF_X - 2), side * TUB_HALF_X, 0, 2, DOOR_Z_FAR, DOOR_Z_NEAR, theme.Metal, Enum.Material.Metal)
		-- Invisible safety wall so nobody walks off the side.
		-- Invisible safety wall, as tall as the tub, so nobody can jump off the door.
		span(b, "SafetyWall", side * TUB_HALF_X, side * (TUB_HALF_X + 1), 0, TUB_HEIGHT, DOOR_Z_FAR - 6, DOOR_Z_NEAR, Color3.new(1, 1, 1), nil, { Transparency = 1, CastShadow = false })
	end
	span(b, "SafetyWall", -TUB_HALF_X - 1, TUB_HALF_X + 1, 0, TUB_HEIGHT, DOOR_Z_FAR - 7, DOOR_Z_FAR - 6, Color3.new(1, 1, 1), nil, { Transparency = 1, CastShadow = false })
	-- A lid over the door area as well, level with the tub ceiling.
	span(b, "SafetyLid", -TUB_HALF_X - 1, TUB_HALF_X + 1, TUB_HEIGHT, TUB_HEIGHT + 1, DOOR_Z_FAR - 7, DOOR_Z_NEAR - 3.2, Color3.new(1, 1, 1), nil, { Transparency = 1, CastShadow = false })

	-- Control strip along the far edge (the top of the door when it's closed), with buttons.
	span(b, "ControlStrip", -TUB_HALF_X - 4.3, TUB_HALF_X + 4.3, -DOOR_THICK - 0.3, 3, DOOR_Z_FAR - 6.3, DOOR_Z_FAR, Color3.fromRGB(40, 44, 52), Enum.Material.SmoothPlastic)
	for i = -3, 3 do
		local lit = i == 0
		box(b, "Button", Vector3.new(4, 0.6, 3), i * 9, 3.3, DOOR_Z_FAR - 3, if lit then theme.Accent else Color3.fromRGB(90, 95, 105), if lit then Enum.Material.Neon else nil, noCollide())
	end

end

----------------------------------------------------------------------------------------------------
-- Racks
----------------------------------------------------------------------------------------------------

-- A walkable rack floor: invisible collidable plate + a visible wire grid, frame and wheels.
local function buildRack(b: Builder, theme, y: number, zRange: { number }, wheels: boolean)
	local z0, z1 = zRange[1], zRange[2]
	local width = RACK_HALF_X * 2
	local depth = z1 - z0
	span(b, "RackFloor", -RACK_HALF_X, RACK_HALF_X, y - 1, y, z0, z1, Color3.new(1, 1, 1), nil, { Transparency = 1, CastShadow = false })

	local wire = { CanCollide = false }
	for x = -RACK_HALF_X, RACK_HALF_X, 4 do
		box(b, "Wire", Vector3.new(0.3, 0.3, depth), x, y - 0.15, (z0 + z1) / 2, theme.Rack, Enum.Material.SmoothPlastic, wire)
	end
	for z = z0, z1, 4 do
		box(b, "Wire", Vector3.new(width, 0.3, 0.3), 0, y - 0.45, z, theme.Rack, Enum.Material.SmoothPlastic, wire)
	end
	-- Chunky frame around the edge.
	for _, side in { -1, 1 } do
		box(b, "RackFrame", Vector3.new(0.9, 2.4, depth), side * RACK_HALF_X, y + 0.6, (z0 + z1) / 2, theme.Rack, nil, wire)
		if wheels then
			for _, z in { z0 + 8, z1 - 8 } do
				cyl(b, "Wheel", 3, 1, side * (RACK_HALF_X + 0.8), y - 1.2, z, Color3.fromRGB(60, 60, 64), nil, noCollide()).CFrame = footprint(b.origin, side * (RACK_HALF_X + 0.8), y - 1.2, z)
			end
		end
	end
	for _, z in { z0, z1 } do
		box(b, "RackFrame", Vector3.new(width, 2.4, 0.9), 0, y + 0.6, z, theme.Rack, nil, wire)
	end
end

-- Tines: the rows of little prongs plates stand in. Pure decoration.
local function buildTines(b: Builder, theme)
	local props = { CanCollide = false, CastShadow = false }
	for _, x in PLATE_ROW_X do
		for _, dx in { -9, 9 } do
			for _, z in PLATE_Z do
				box(b, "Tine", Vector3.new(0.35, 5, 0.35), x + dx, BOTTOM_RACK_Y + 2.5, z + 3.5, theme.Rack, nil, props)
			end
		end
	end
end

-- Ramp from the tub floor up onto the bottom rack.
local function buildRamp(b: Builder, theme)
	local z0, z1 = BOTTOM_RACK_Z[1] - 5, BOTTOM_RACK_Z[1]
	local wedge = Instance.new("WedgePart")
	wedge.Name = "Ramp"
	wedge.Size = Vector3.new(RACK_HALF_X * 2 - 20, BOTTOM_RACK_Y, z1 - z0)
	-- A wedge slopes down toward its LookVector, so point that at the door: low end by the drain,
	-- high end at the rack.
	wedge.CFrame = footprint(b.origin, 0, BOTTOM_RACK_Y / 2, (z0 + z1) / 2, -b.origin.LookVector)
	wedge.Color = theme.Rack
	wedge.Material = Enum.Material.DiamondPlate
	wedge.Anchored = true
	wedge.CanTouch = false
	wedge.CanQuery = false
	wedge.Parent = b.model
	b.count += 1
end

local function buildCutleryBasket(b: Builder, theme)
	local c, h = BASKET_CENTER, BASKET_HALF
	local y0 = BOTTOM_RACK_Y
	span(b, "BasketBase", c.X - h.X, c.X + h.X, y0, y0 + 0.6, c.Z - h.Z, c.Z + h.Z, theme.Rack)
	local props = { CanCollide = true, Transparency = 0.2 }
	span(b, "BasketWall", c.X - h.X - 0.5, c.X - h.X, y0, y0 + h.Y, c.Z - h.Z, c.Z + h.Z, theme.Rack, Enum.Material.DiamondPlate, props)
	span(b, "BasketWall", c.X + h.X, c.X + h.X + 0.5, y0, y0 + h.Y, c.Z - h.Z, c.Z + h.Z, theme.Rack, Enum.Material.DiamondPlate, props)
	span(b, "BasketWall", c.X - h.X, c.X + h.X, y0, y0 + h.Y, c.Z - h.Z - 0.5, c.Z - h.Z, theme.Rack, Enum.Material.DiamondPlate, props)
	span(b, "BasketWall", c.X - h.X, c.X + h.X, y0, y0 + h.Y, c.Z + h.Z, c.Z + h.Z + 0.5, theme.Rack, Enum.Material.DiamondPlate, props)
	-- Handle arching over the middle.
	span(b, "BasketHandle", c.X - 0.4, c.X + 0.4, y0 + h.Y, y0 + h.Y + 5, c.Z - h.Z, c.Z - h.Z + 0.8, theme.Rack, nil, noCollide())
	span(b, "BasketHandle", c.X - 0.4, c.X + 0.4, y0 + h.Y, y0 + h.Y + 5, c.Z + h.Z - 0.8, c.Z + h.Z, theme.Rack, nil, noCollide())
	span(b, "BasketHandle", c.X - 0.4, c.X + 0.4, y0 + h.Y + 4.2, y0 + h.Y + 5, c.Z - h.Z, c.Z + h.Z, theme.Rack, nil, noCollide())
end

local function sprayEmitter(parent: Instance, rate: number, speed: number, direction: Enum.NormalId)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Spray"
	emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	emitter.Color = ColorSequence.new(Color3.fromRGB(200, 235, 255))
	emitter.LightEmission = 0.25
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.28), NumberSequenceKeypoint.new(1, 0.12) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(0.8, 0.5), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(0.9, 1.4)
	emitter.Rate = rate
	emitter.Speed = NumberRange.new(speed * 0.8, speed)
	emitter.SpreadAngle = Vector2.new(18, 18)
	emitter.Acceleration = Vector3.new(0, -45, 0)
	emitter.EmissionDirection = direction
	emitter.Parent = parent
end

-- The spray arms spin (client side, tag SpinY) and throw arcs of droplets up into the load. A thin
-- drizzle falls from the ceiling. Kept light so it never gets in the way of aiming.
local function buildSprayArms(b: Builder, theme)
	for _, y in { 2, TOP_RACK_Y - 3 } do
		cyl(b, "ArmHub", 1.5, 5, 0, y, 10, theme.Metal, Enum.Material.Metal, noCollide())
		local length = RACK_HALF_X * 1.6
		local arm = box(b, "SprayArm", Vector3.new(length, 0.9, 3), 0, y, 10, theme.Metal, Enum.Material.Metal, noCollide())
		arm:SetAttribute("SpinSpeed", if y > 10 then 1.1 else 0.8)
		CollectionService:AddTag(arm, "SpinY")
		for _, f in { -0.42, -0.2, 0.2, 0.42 } do
			local attach = Instance.new("Attachment")
			attach.Position = Vector3.new(length * f, 0.5, 0)
			attach.Parent = arm
			sprayEmitter(attach, 5, if y > 10 then 22 else 30, Enum.NormalId.Top)
		end
	end
	local drizzle = box(b, "Drizzle", Vector3.new(TUB_HALF_X * 1.8, 1, (TUB_Z_MAX - TUB_Z_MIN) * 0.9), 0, TUB_HEIGHT - 2, (TUB_Z_MIN + TUB_Z_MAX) / 2, theme.Light, nil, { Transparency = 1, CanCollide = false, CastShadow = false })
	sprayEmitter(drizzle, 14, 4, Enum.NormalId.Bottom)
end

-- Bubble lifts and the drain chute. The client teleports whoever steps on a pad (Effects).
local function buildLifts(b: Builder, theme)
	local function pad(name: string, from: Vector3, to: Vector3, label: string, columnHeight: number)
		local p = cyl(b, name, 0.4, 8, from.X, from.Y + 0.2, from.Z, theme.Accent, Enum.Material.Neon, noCollide())
		p:SetAttribute("LiftTo", worldPoint(b.origin, to.X, to.Y + 3, to.Z))
		CollectionService:AddTag(p, "LiftPad")
		local ring = cyl(b, name .. "Ring", 0.2, 10, from.X, from.Y + 0.1, from.Z, Color3.new(1, 1, 1), Enum.Material.Neon, noCollide())
		ring.Transparency = 0.4
		if columnHeight > 0 then
			local column = cyl(b, name .. "Column", columnHeight, 7, from.X, from.Y + columnHeight / 2, from.Z, theme.Accent, Enum.Material.ForceField, noCollide())
			column.Transparency = 0.6
		end
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxasset://textures/particles/forcefield_glow_main.dds"
		emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
		emitter.Lifetime = NumberRange.new(1.2, 2)
		emitter.Speed = NumberRange.new(8, 14)
		emitter.Rate = 10
		emitter.Size = NumberSequence.new(0.9, 0.3)
		emitter.SpreadAngle = Vector2.new(10, 10)
		emitter.EmissionDirection = if to.Y > from.Y then Enum.NormalId.Right else Enum.NormalId.Left
		emitter.Parent = p
		sign(p, label, 12, 2.6, 7)
	end
	for _, lift in LIFTS do
		pad("BubbleLift", lift.from, lift.to, "⬆️ Bubble Lift", TOP_RACK_Y)
	end
end

local function buildDrain(b: Builder, theme): Vector3
	cyl(b, "DrainGrate", 0.5, 15, DRAIN_POS.X, 0.25, DRAIN_POS.Z, Color3.fromRGB(70, 75, 80), Enum.Material.DiamondPlate)
	local ring = cyl(b, "DrainSwirl", 0.2, 13, DRAIN_POS.X, 0.6, DRAIN_POS.Z, theme.Accent, Enum.Material.ForceField, noCollide())
	ring:SetAttribute("SpinSpeed", 2.4)
	CollectionService:AddTag(ring, "SpinY")
	local post = box(b, "DrainSign", Vector3.new(0.6, 0.6, 0.6), DRAIN_POS.X, 1, DRAIN_POS.Z, Color3.new(1, 1, 1), nil, { Transparency = 1, CanCollide = false })
	sign(post, "🌀 DRAIN\nstand here to sell", 16, 5, 8, Color3.fromRGB(150, 230, 255))
	return worldPoint(b.origin, DRAIN_POS.X, 0, DRAIN_POS.Z)
end

----------------------------------------------------------------------------------------------------
-- Tool shop on the door (walk up to a tool and press the prompt to buy it) and the upgrade book.
----------------------------------------------------------------------------------------------------

-- A SurfaceGui sign on a real part, facing `facing` (so it never floats, sinks or flickers).
local function signBoard(b: Builder, name: string, size: Vector3, pos: Vector3, facing: Vector3, color: Color3): (Part, SurfaceGui)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = CFrame.lookAt(pos, pos + facing)
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Parent = b.model
	b.count += 1
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 60
	gui.Parent = p
	return p, gui
end

local function guiText(parent: Instance, name: string, text: string, pos: UDim2, size: UDim2, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = pos
	label.Size = size
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = color
	label.Text = text
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(12, 30, 60)
	stroke.Parent = label
	label.Parent = parent
	return label
end

-- The Tool Shop: a chrome wire shelving unit (it matches the dishwasher racks) standing on the
-- left of the open door, facing the players. Two shelves, the tools on the upper ones, a price tag
-- on the front lip of each spot, a sign on top. Buy any tool in any order with the prompt.
local function buildShop(b: Builder, theme, levelIndex: number): Vector3
	local z0, z1 = SHOP_Z[1], SHOP_Z[2]
	local depth = 9
	local x0, x1 = SHOP_X - depth / 2, SHOP_X + depth / 2 -- x1 is the front, facing the players
	local toPlayers = b.origin.RightVector
	local chrome = Color3.fromRGB(215, 220, 228)
	-- Two display shelves at waist and head height for a ~5 stud character (anything higher can't be
	-- seen from the floor).
	local shelfYs = { 4, 13.5 }
	local topY = 25
	local TOOL_SCALE = 1.45

	-- Four corner posts plus a middle pair, floor to top, with little feet.
	for _, x in { x0, x1 } do
		for _, z in { z0, (z0 + z1) / 2, z1 } do
			cyl(b, "ShelfPost", topY, 0.7, x, topY / 2, z, chrome, Enum.Material.Metal)
			cyl(b, "ShelfFoot", 0.4, 1.3, x, 0.2, z, Color3.fromRGB(60, 62, 70), nil, noCollide())
		end
	end
	-- Shelves: a solid (invisible-ish) board so things rest on something, plus wire detail.
	for _, y in shelfYs do
		span(b, "ShelfBoard", x0, x1, y - 0.25, y, z0, z1, Color3.fromRGB(235, 238, 242), Enum.Material.DiamondPlate, { Transparency = 0.25 })
		for _, x in { x0, x1 } do
			span(b, "ShelfRail", x - 0.2, x + 0.2, y, y + 0.9, z0, z1, chrome, Enum.Material.Metal, noCollide())
		end
		for z = z0 + 3, z1 - 3, 3 do
			span(b, "ShelfWire", x0, x1, y + 0.01, y + 0.07, z - 0.08, z + 0.08, chrome, Enum.Material.Metal, noCollide())
		end
	end
	span(b, "ShelfTop", x0 - 0.3, x1 + 0.3, topY, topY + 0.4, z0 - 0.3, z1 + 0.3, chrome, Enum.Material.Metal)

	-- Sign across the top.
	local _, headerGui = signBoard(b, "ShopSign", Vector3.new(z1 - z0 - 4, 4, 0.5), worldPoint(b.origin, x1 - 0.5, topY + 2.6, (z0 + z1) / 2), toPlayers, theme.Accent)
	guiText(headerGui, "Title", "🧽 TOOL SHOP  •  any tool, any order", UDim2.fromScale(0.03, 0.1), UDim2.fromScale(0.94, 0.8), Color3.new(1, 1, 1))

	-- Tools 2..6: the tall ones (sponge, nozzle, washer) on the middle shelf, the short ones on top.
	local third = (z1 - z0) / 3
	local spots = {
		[2] = { y = shelfYs[1], z = z1 - third / 2 },
		[4] = { y = shelfYs[1], z = (z0 + z1) / 2 - 3 },
		[5] = { y = shelfYs[1], z = z0 + third / 2 },
		[3] = { y = shelfYs[2], z = z1 - third * 0.8 },
		[6] = { y = shelfYs[2], z = z0 + third * 0.8 },
	}
	for i = 2, #Config.Tools do
		local tool = Config.Tools[i]
		local spot = spots[i]
		if not spot then
			break
		end
		-- Upper-shelf tools stand on a short riser so they show above the shelf lip from the floor
		-- (and the tallest, the foam cannon, still clears the top of the unit).
		local riser = if spot.y > shelfYs[1] then 1.0 else 0.4
		local pedestal = cyl(b, "Pedestal", riser, 6.4, SHOP_X - 0.5, spot.y + riser / 2, spot.z, Color3.new(1, 1, 1), nil, noCollide())
		pedestal.Name = "ToolDisplay_" .. i
		cyl(b, "PedestalGlow", 0.12, 7, SHOP_X - 0.5, spot.y + 0.06, spot.z, tool.Color, Enum.Material.Neon, noCollide())
		local okModel, model = pcall(ToolModels.Build, i, TOOL_SCALE)
		if okModel and model then
			local basePos = worldPoint(b.origin, SHOP_X - 0.5, spot.y + riser, spot.z)
			model:PivotTo(CFrame.lookAt(basePos, basePos + toPlayers) * CFrame.Angles(0, math.rad(25), 0))
			model.Parent = b.model
			b.count += #model:GetChildren()
		end

		local cost = Config.ToolCost(i, levelIndex) or 0
		-- Price tag: a camera-facing card floating just in front of the tool's own shelf, at the same
		-- height above the shelf on both shelves, so each tag clearly belongs to the tool above it.
		local tagY = spot.y + 1.3
		local tag = box(b, "PriceTag_" .. i, Vector3.new(0.2, 0.2, 0.2), x1 + 1.6, tagY, spot.z, Color3.new(1, 1, 1), nil, { Transparency = 1, CanCollide = false, CastShadow = false })
		tag:SetAttribute("ToolIndex", i)
		local card = Instance.new("BillboardGui")
		card.Name = "Tag"
		card.Size = UDim2.fromScale(6.4, 2.3)
		card.LightInfluence = 0
		card.MaxDistance = 70
		card.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		card.Parent = tag
		local bg = Instance.new("Frame")
		bg.Size = UDim2.fromScale(1, 1)
		bg.BackgroundColor3 = Color3.fromRGB(22, 44, 78)
		bg.BackgroundTransparency = 0.1
		bg.ZIndex = 0
		bg.Parent = card
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.25, 0)
		corner.Parent = bg
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 2
		stroke.Color = tool.Color
		stroke.Parent = bg
		guiText(card, "Title", tool.Icon .. " " .. tool.Name, UDim2.fromScale(0.05, 0.06), UDim2.fromScale(0.9, 0.46), Color3.new(1, 1, 1))
		guiText(card, "Price", "💰 " .. Format.Short(cost), UDim2.fromScale(0.05, 0.5), UDim2.fromScale(0.9, 0.44), Color3.fromRGB(255, 210, 60))

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Buy"
		prompt.ObjectText = string.format("%s  💰%s", tool.Name, Format.Short(cost))
		prompt.HoldDuration = 0
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 14
		prompt:SetAttribute("BuyTool", i)
		prompt.Parent = pedestal
	end

	return worldPoint(b.origin, SHOP_X + depth, 0, (z0 + z1) / 2)
end

----------------------------------------------------------------------------------------------------
-- Dish layout
----------------------------------------------------------------------------------------------------

type PlacedDish = {
	Id: number,
	Kind: string,
	Model: Model,
	Grime: { BasePart },
	Center: Vector3,
}

type Slot = { x: number, y: number, z: number }

local function grid(xs: { number }, zs: { number }, y: number): { Slot }
	local slots = {}
	for _, z in zs do
		for _, x in xs do
			table.insert(slots, { x = x, y = y, z = z })
		end
	end
	return slots
end

-- Front-to-back, filling every row a little before moving back, so small loads still look spread out.
local function plateSlots(): { Slot }
	local slots = {}
	for _, z in PLATE_Z do
		for _, x in PLATE_ROW_X do
			table.insert(slots, { x = x, y = BOTTOM_RACK_Y, z = z })
		end
	end
	return slots
end

local function listSlots(list: { { x: number, z: number } }): { Slot }
	local slots = {}
	for _, s in list do
		table.insert(slots, { x = s.x, y = BOTTOM_RACK_Y, z = s.z })
	end
	return slots
end

-- Cutlery shares one basket: each kind takes every third slot so the basket looks mixed.
local function basketSlots(offset: number): { Slot }
	local all = grid(BASKET_X, BASKET_Z, BOTTOM_RACK_Y + 0.6)
	local slots = {}
	for i = offset, #all, 3 do
		table.insert(slots, all[i])
	end
	return slots
end

-- Trays share the plate rows, filling from the back (Plate + Tray must fit the 27 plate slots).
local function traySlots(): { Slot }
	local all = plateSlots()
	local slots = {}
	for i = #all, 1, -1 do
		table.insert(slots, all[i])
	end
	return slots
end

local KIND_SLOTS: { [string]: () -> { Slot } } = {
	Plate = plateSlots,
	Tray = traySlots,
	Bowl = function()
		return grid(BOWL_X, BOWL_Z, TOP_RACK_Y)
	end,
	Cup = function()
		return grid(CUP_X, CUP_Z, TOP_RACK_Y)
	end,
	Glass = function()
		return grid(GLASS_X, GLASS_Z, TOP_RACK_Y)
	end,
	Pan = function()
		return listSlots(PAN_SLOTS)
	end,
	Pot = function()
		return listSlots(POT_SLOTS)
	end,
	Fork = function()
		return basketSlots(1)
	end,
	Knife = function()
		return basketSlots(2)
	end,
	Spoon = function()
		return basketSlots(3)
	end,
}

-- The CFrame DishFactory builds a dish at: contact point + orientation for that kind.
local function dishFrame(origin: CFrame, kind: string, slot: Slot, rng: Random): CFrame
	local toDoor = -origin.LookVector
	if kind == "Plate" or kind == "Tray" then
		-- Plates face the door, with a tiny random lean so the rows don't look copy-pasted.
		return footprint(origin, slot.x, slot.y, slot.z, toDoor) * CFrame.Angles(math.rad(rng:NextNumber(-4, 4)), 0, 0)
	elseif kind == "Bowl" then
		-- Lean the opening toward the door so the inside is visible and reachable.
		local r = DishFactory.Size("Bowl").Diameter / 2
		local lift = r * (1 - math.cos(BOWL_TILT)) + 0.2
		return footprint(origin, slot.x, slot.y + lift, slot.z) * CFrame.Angles(BOWL_TILT, 0, 0)
	elseif kind == "Pan" then
		local r = DishFactory.Size("Pan").Diameter / 2
		local lift = r * math.sin(PAN_TILT) + 0.2
		-- Spin about the pan's own axis so the handle points up and back, away from the pots.
		return footprint(origin, slot.x, slot.y + lift, slot.z) * CFrame.Angles(PAN_TILT, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
	elseif kind == "Fork" or kind == "Knife" or kind == "Spoon" then
		return footprint(origin, slot.x, slot.y, slot.z, toDoor) * CFrame.Angles(0, math.rad(rng:NextNumber(-20, 20)), math.rad(rng:NextNumber(-6, 6)))
	end
	return footprint(origin, slot.x, slot.y, slot.z, toDoor) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

function ArenaBuilder.Init()
	getArenasFolder()
end

function ArenaBuilder.SlotOrigin(slot: number): CFrame
	local w = Config.World
	local pos = w.ArenaRowStart + w.ArenaSpacing * (slot - 1)
	return CFrame.new(pos)
end

function ArenaBuilder.Build(slot: number, levelIndex: number, options: { GrimeScale: number, GoldenChance: number }): any
	assert(type(slot) == "number", "ArenaBuilder.Build: slot must be a number")
	local level = Config.GetLevel(levelIndex)
	local theme = level.Theme
	local origin = ArenaBuilder.SlotOrigin(slot)
	local rng = Random.new()
	local grimeScale = (options and options.GrimeScale) or 1
	local goldenChance = (options and options.GoldenChance) or level.GoldenChance

	local arenasFolder = getArenasFolder()
	local name = "Arena_" .. slot
	local existing = arenasFolder:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end

	local model = Instance.new("Model")
	model.Name = name
	model.Parent = arenasFolder -- live in workspace now, so dish raycasts work as we build

	local dishesFolder = Instance.new("Folder")
	dishesFolder.Name = "Dishes"
	dishesFolder.Parent = model

	local grimeFolder = Instance.new("Folder")
	grimeFolder.Name = "Grime"
	grimeFolder.Parent = model

	local b: Builder = { model = model, origin = origin, count = 0 }
	local pending = 0
	local function yieldTick()
		if b.count - pending >= YIELD_EVERY then
			pending = b.count
			task.wait()
		end
	end

	buildRoom(b, levelIndex)
	yieldTick()
	buildTub(b, theme)
	buildDoor(b, theme)
	yieldTick()
	buildRack(b, theme, BOTTOM_RACK_Y, BOTTOM_RACK_Z, true)
	yieldTick()
	buildRack(b, theme, TOP_RACK_Y, TOP_RACK_Z, true)
	yieldTick()
	buildTines(b, theme)
	buildRamp(b, theme)
	buildCutleryBasket(b, theme)
	buildSprayArms(b, theme)
	buildLifts(b, theme)
	local drainPos = buildDrain(b, theme)
	local stationPos = buildShop(b, theme, levelIndex)
	yieldTick()

	local dishes: { [number]: PlacedDish } = {}
	local nextId = 0
	local totalGrime = 0
	for _, kind in Config.DishKinds do
		local wantCount = level.Dishes[kind] or 0
		local slotsFn = KIND_SLOTS[kind]
		if wantCount > 0 and slotsFn then
			local spotsPerDish = math.max(1, math.floor((level.Spots[kind] or 1) * grimeScale + 0.5))
			local slots = slotsFn()
			if wantCount > #slots then
				warn(string.format("[ArenaBuilder] Only %d slots for %d %s; filling what fits", #slots, wantCount, kind))
			end
			for i = 1, math.min(wantCount, #slots) do
				local cf = dishFrame(origin, kind, slots[i], rng)
				local dish = DishFactory.BuildDish(kind, cf, theme, rng)
				dish.Parent = dishesFolder

				nextId += 1
				local grime = DishFactory.ApplyGrime(dish, nextId, spotsPerDish, levelIndex, rng, goldenChance, grimeFolder)
				dishes[nextId] = {
					Id = nextId,
					Kind = kind,
					Model = dish,
					Grime = grime,
					Center = dish:GetPivot().Position,
				}
				totalGrime += #grime
				b.count += #dish:GetChildren() + #grime * 5
				yieldTick()
			end
		end
	end

	model:SetAttribute("Level", levelIndex)
	model:SetAttribute("Total", totalGrime)
	model:SetAttribute("Cleaned", 0)

	local spawns: { CFrame } = {}
	for _, x in { -14, -10, -6, -2, 2, 6, 10, 14 } do -- one spot per party member (up to 8)
		table.insert(spawns, footprint(origin, x, 0.5, SPAWN_Z))
	end

	local arena = {
		Slot = slot,
		Name = name,
		Model = model,
		Origin = origin,
		Spawns = spawns,
		DrainPosition = drainPos,
		DrainRadius = Config.Round.DrainRadius,
		StationPosition = stationPos,
		GrimeFolder = grimeFolder,
		Dishes = dishes,
		TotalGrime = totalGrime,
		KillY = origin.Position.Y - 14, -- the kitchen floor is at -24
	}
	return arena
end

function ArenaBuilder.Destroy(arena: any)
	if not arena then
		return
	end
	if typeof(arena.Model) == "Instance" and arena.Model.Parent then
		arena.Model:Destroy()
	end
end

return ArenaBuilder
