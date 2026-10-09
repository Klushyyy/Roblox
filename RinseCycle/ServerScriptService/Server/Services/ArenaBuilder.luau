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
local TUB_HEIGHT = 100 -- (the Backyard sink is shallower: set per build)

local DOOR_Z_NEAR, DOOR_Z_FAR = -50, -121 -- the open door lies flat over this Z range, top at Y = 0
local DOOR_THICK = 4
local SPAWN_Z = -100

local KITCHEN_FLOOR_Y = -24
local COUNTER_TOP_Y = 112 -- (lower outdoors: set per build)
local ROOM_HALF_X = 420 -- (the castle hall is much wider: set per build)
local ROOM_Z_FRONT, ROOM_Z_BACK = -520, 76 -- (the castle hall is much deeper: set per build)
local ROOM_HEIGHT = 520 -- (and much taller)

local DRAIN_POS = Vector3.new(0, 0, -49) -- clear of the rack ramp (Z -41..-36)

local BOTTOM_RACK_Y = 4
local TOP_RACK_Y = 50
local RACK_HALF_X = 54
local BOTTOM_RACK_Z = { -36, 60 }
local TOP_RACK_Z = { -40, 60 }

-- Bottom rack: four columns by seven rows of plate slots facing the door, with a good gap between them (room to scrub
-- each plate, even on a phone). There are more slots than plates in the first levels, so some stay empty.
local PLATE_ROW_X = { -45, -15, 15, 45 }
local PLATE_Z = { -33, -22, -11, 0, 11, 22, 33 }
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

-- In a party's own run server nobody else is playing (and the party is behind a loading screen),
-- so build in far bigger steps there: the dishwasher is ready sooner.
local YIELD_EVERY = if game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0 then 3000 else 200

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
	-- Solid, visible scenery is queryable so the camera bumps into it instead of sliding through
	-- walls and ovens (every gameplay query uses an Include filter, so this changes nothing else).
	if not (props and props.CanQuery ~= nil) then
		p.CanQuery = p.CanCollide and p.Transparency < 0.25
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
	label.Font = Enum.Font.LuckiestGuy
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
		Bench = "Home",
	},
	-- 2: Backyard pizza party: an outdoor kitchen counter of whitewashed wood under open sky.
	{
		Outdoor = true,
		Floor = Color3.fromRGB(176, 170, 160), FloorMat = Enum.Material.Slate,
		Wall = Color3.fromRGB(120, 112, 100), WallMat = Enum.Material.Cobblestone,
		Ceiling = Color3.fromRGB(190, 225, 255),
		Cabinet = Color3.fromRGB(150, 108, 72), CabinetDoor = Color3.fromRGB(176, 130, 90), CabMat = Enum.Material.WoodPlanks,
		Counter = Color3.fromRGB(190, 186, 178), CounterMat = Enum.Material.Slate,
		Tile = Color3.fromRGB(150, 142, 130), TileMat = Enum.Material.Cobblestone,
		Handle = Color3.fromRGB(60, 60, 66), HandleMat = Enum.Material.Metal,
		Kick = Color3.fromRGB(70, 56, 44),
		Lamp = Color3.fromRGB(255, 214, 150),
		Bench = "Garden",
	},
	-- (level 2 is the Backyard: see buildYard; this entry only supplies the outdoor kitchen counter)
	-- 3: Castle banquet hall: stone, dark wood, gold, a red carpet.
	{
		Floor = Color3.fromRGB(128, 122, 116), FloorMat = Enum.Material.Slate,
		Wall = Color3.fromRGB(150, 144, 136), WallMat = Enum.Material.Cobblestone,
		Ceiling = Color3.fromRGB(70, 52, 40),
		Cabinet = Color3.fromRGB(150, 144, 136), CabinetDoor = Color3.fromRGB(112, 72, 46), CabMat = Enum.Material.Cobblestone,
		Counter = Color3.fromRGB(104, 66, 40), CounterMat = Enum.Material.WoodPlanks,
		Tile = Color3.fromRGB(120, 112, 104), TileMat = Enum.Material.Slate,
		Handle = Color3.fromRGB(230, 190, 90), HandleMat = Enum.Material.Metal,
		Kick = Color3.fromRGB(50, 34, 24),
		Lamp = Color3.fromRGB(255, 205, 140),
		Bench = "Stone",
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
	label.Font = Enum.Font.LuckiestGuy
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
	if k.Outdoor then
		-- Open sky: no walls or ceiling, just invisible barriers (so nobody wanders or flies off
		-- the patio) at the old room's edges.
		local inv = { Transparency = 1, CastShadow = false }
		span(b, "BarrierBack", -ROOM_HALF_X - 4, ROOM_HALF_X + 4, fy, fy + ROOM_HEIGHT, 110, 114, k.Wall, nil, inv)
		span(b, "BarrierFront", -ROOM_HALF_X - 4, ROOM_HALF_X + 4, fy, fy + ROOM_HEIGHT, ROOM_Z_FRONT - 4, ROOM_Z_FRONT, k.Wall, nil, inv)
		for _, side in { -1, 1 } do
			span(b, "BarrierSide", side * ROOM_HALF_X, side * (ROOM_HALF_X + 4), fy, fy + ROOM_HEIGHT, ROOM_Z_FRONT, 114, k.Wall, nil, inv)
		end
		span(b, "BarrierTop", -ROOM_HALF_X, ROOM_HALF_X, fy + ROOM_HEIGHT, fy + ROOM_HEIGHT + 4, ROOM_Z_FRONT, 114, k.Wall, nil, inv)
	else
		span(b, "BackWall", -ROOM_HALF_X, ROOM_HALF_X, fy, fy + ROOM_HEIGHT, ROOM_Z_BACK, ROOM_Z_BACK + 4, k.Wall, k.WallMat, shadowless)
		span(b, "FrontWall", -ROOM_HALF_X, ROOM_HALF_X, fy, fy + ROOM_HEIGHT, ROOM_Z_FRONT - 4, ROOM_Z_FRONT, k.Wall, k.WallMat, shadowless)
		for _, side in { -1, 1 } do
			span(b, "SideWall", side * ROOM_HALF_X, side * (ROOM_HALF_X + 4), fy, fy + ROOM_HEIGHT, ROOM_Z_FRONT, ROOM_Z_BACK, k.Wall, k.WallMat, shadowless)
			span(b, "Skirting", side * (ROOM_HALF_X - 2), side * ROOM_HALF_X, fy, fy + 10, ROOM_Z_FRONT, ROOM_Z_BACK, k.Kick, nil, noCollide())
		end
		span(b, "Ceiling", -ROOM_HALF_X, ROOM_HALF_X, fy + ROOM_HEIGHT, fy + ROOM_HEIGHT + 4, ROOM_Z_FRONT, ROOM_Z_BACK, k.Ceiling, nil, shadowless)
	end

	-- The bench either side of the dishwasher. Same solid body and counter height in every level
	-- (players run along the top); what it's dressed as depends on the room.
	local cabFront = -54
	local bench = k.Bench or "Home"
	local backZ = if k.Outdoor then 110 else ROOM_Z_BACK -- outdoors the counter runs a little deeper (the tap stands there)
	for _, side in { -1, 1 } do
		local x0, x1 = side * 62, side * ROOM_HALF_X
		span(b, "Cabinets", x0, x1, fy + 12, COUNTER_TOP_Y - 6, cabFront, backZ, k.Cabinet, k.CabMat)
		span(b, "ToeKick", x0, x1, fy, fy + 12, cabFront + 8, backZ, k.Kick)
		local width = math.abs(x1 - x0)
		local doors = math.floor(width / 80)
		local doorW = width / doors
		for i = 0, doors - 1 do
			local cx = side * (62 + doorW * (i + 0.5))
			if bench == "Steel" then
				-- A commercial line: reach-in fridges with glass fronts and long bar handles.
				local steel = Color3.fromRGB(205, 210, 216)
				local y0, y1 = fy + 18, COUNTER_TOP_Y - 12
				box(b, "FridgeDoor", Vector3.new(doorW - 6, y1 - y0, 1.5), cx, (y0 + y1) / 2, cabFront - 0.75, steel, Enum.Material.Metal)
				local gy0, gy1 = y0 + 30, y1 - 14
				box(b, "FridgeInside", Vector3.new(doorW - 22, gy1 - gy0, 0.4), cx, (gy0 + gy1) / 2, cabFront - 1.6, Color3.fromRGB(40, 48, 58), nil, noCollide())
				for shelf = 0, 1 do
					local sy = gy0 + 6 + shelf * (gy1 - gy0) / 2
					box(b, "FridgeShelf", Vector3.new(doorW - 24, 1, 0.6), cx, sy - 4, cabFront - 1.9, Color3.fromRGB(180, 190, 200), Enum.Material.Metal, noCollide())
					local tubs = { Color3.fromRGB(210, 60, 45), Color3.fromRGB(250, 235, 200), Color3.fromRGB(90, 160, 80), Color3.fromRGB(245, 200, 80) }
					for t = 0, 3 do
						local tx = cx - (doorW - 30) / 2 + (doorW - 30) * (t + 0.5) / 4
						box(b, "FridgeTub", Vector3.new(10, 12, 0.6), tx, sy + 3, cabFront - 1.9, tubs[(t + shelf + i) % #tubs + 1], nil, noCollide())
					end
				end
				local glass = box(b, "FridgeGlass", Vector3.new(doorW - 20, gy1 - gy0, 0.4), cx, (gy0 + gy1) / 2, cabFront - 2.3, Color3.fromRGB(200, 230, 245), Enum.Material.Glass, noCollide())
				glass.Transparency = 0.55
				box(b, "BarHandle", Vector3.new(2.5, gy1 - gy0, 2.5), cx + side * -(doorW / 2 - 9), (gy0 + gy1) / 2, cabFront - 4, Color3.fromRGB(150, 155, 162), Enum.Material.Metal, noCollide())
				box(b, "Vent", Vector3.new(doorW - 20, 8, 0.6), cx, y0 + 12, cabFront - 1.8, Color3.fromRGB(70, 74, 80), Enum.Material.DiamondPlate, noCollide())
				cyl(b, "Foot", 12, 6, cx - doorW / 2 + 8, fy + 6, cabFront + 4, Color3.fromRGB(150, 155, 162), Enum.Material.Metal, noCollide())
			elseif bench == "Stone" then
				-- Carved stone arches with oak barrels resting in them.
				local ay0, ay1 = fy + 18, COUNTER_TOP_Y - 30
				local aw = doorW - 22
				box(b, "Alcove", Vector3.new(aw, ay1 - ay0 - aw / 2, 1.2), cx, ay0 + (ay1 - ay0 - aw / 2) / 2, cabFront - 0.6, Color3.fromRGB(34, 28, 24), Enum.Material.Slate, noCollide())
				local arch = cyl(b, "AlcoveArch", 1.2, aw, cx, ay1 - aw / 2, cabFront - 0.6, Color3.fromRGB(34, 28, 24), Enum.Material.Slate, noCollide())
				arch.CFrame = footprint(b.origin, cx, ay1 - aw / 2, cabFront - 0.6) * CFrame.Angles(0, math.rad(90), 0)
				-- A lighter stone ring just behind the dark alcove face (shows as a border round the arch).
				local rim = cyl(b, "ArchRim", 1.6, aw + 8, cx, ay1 - aw / 2, cabFront - 0.1, Color3.fromRGB(122, 116, 108), Enum.Material.Slate, noCollide())
				rim.CFrame = footprint(b.origin, cx, ay1 - aw / 2, cabFront - 0.1) * CFrame.Angles(0, math.rad(90), 0)
				local barrelD = math.min(aw - 8, 52)
				local by = ay0 + barrelD / 2
				local barrel = cyl(b, "Barrel", 30, barrelD, cx, by, cabFront - 14, Color3.fromRGB(128, 84, 48), Enum.Material.Wood, noCollide())
				barrel.CFrame = footprint(b.origin, cx, by, cabFront - 14) * CFrame.Angles(0, math.rad(90), 0)
				for _, dz in { -9, 9 } do
					local band = cyl(b, "BarrelBand", 3, barrelD + 1.2, cx, by, cabFront - 14 + dz, Color3.fromRGB(60, 56, 54), Enum.Material.Metal, noCollide())
					band.CFrame = footprint(b.origin, cx, by, cabFront - 14 + dz) * CFrame.Angles(0, math.rad(90), 0)
				end
				local lid = cyl(b, "BarrelLid", 0.6, barrelD - 6, cx, by, cabFront - 29.4, Color3.fromRGB(150, 104, 62), Enum.Material.Wood, noCollide())
				lid.CFrame = footprint(b.origin, cx, by, cabFront - 29.4) * CFrame.Angles(0, math.rad(90), 0)
			elseif bench == "Garden" then
				-- Outdoor kitchen: plain wooden cupboard doors with a recessed panel and a handle.
				local y0, y1 = fy + 16, COUNTER_TOP_Y - 10
				box(b, "GardenDoor", Vector3.new(doorW - 8, y1 - y0, 1.5), cx, (y0 + y1) / 2, cabFront - 0.75, k.CabinetDoor, k.CabMat)
				box(b, "GardenPanel", Vector3.new(doorW - 28, y1 - y0 - 14, 0.5), cx, (y0 + y1) / 2, cabFront - 1.7, k.Cabinet, k.CabMat, noCollide())
				box(b, "DoorHandle", Vector3.new(2.5, 14, 2.5), cx + side * -(doorW / 2 - 12), (y0 + y1) / 2, cabFront - 3.2, k.Handle, k.HandleMat, noCollide())
			else
				box(b, "Drawer", Vector3.new(doorW - 6, 26, 1.5), cx, COUNTER_TOP_Y - 24, cabFront - 0.75, k.CabinetDoor, k.CabMat)
				box(b, "DrawerHandle", Vector3.new(24, 2.5, 2.5), cx, COUNTER_TOP_Y - 24, cabFront - 2.5, k.Handle, k.HandleMat, noCollide())
				box(b, "Door", Vector3.new(doorW - 6, 66, 1.5), cx, fy + 12 + 38, cabFront - 0.75, k.CabinetDoor, k.CabMat)
				box(b, "DoorHandle", Vector3.new(2.5, 20, 2.5), cx + side * -(doorW / 2 - 12), fy + 12 + 55, cabFront - 2.5, k.Handle, k.HandleMat, noCollide())
			end
		end
	end

	-- Countertop across the whole run (including over the dishwasher) with a backsplash.
	if k.Outdoor or k.TroughHole then
		-- The basin is open at the top: the counter has a hole over it (butting against its rim).
		local hx, hz1 = TUB_HALF_X + 4, TUB_Z_MAX + 4
		span(b, "Countertop", -ROOM_HALF_X, -hx, COUNTER_TOP_Y - 6, COUNTER_TOP_Y, cabFront - 6, backZ, k.Counter, k.CounterMat, shadowless)
		span(b, "Countertop", hx, ROOM_HALF_X, COUNTER_TOP_Y - 6, COUNTER_TOP_Y, cabFront - 6, backZ, k.Counter, k.CounterMat, shadowless)
		span(b, "Countertop", -hx, hx, COUNTER_TOP_Y - 6, COUNTER_TOP_Y, hz1, backZ, k.Counter, k.CounterMat, shadowless)
		if k.Outdoor then
			return
		end
	else
		span(b, "Countertop", -ROOM_HALF_X, ROOM_HALF_X, COUNTER_TOP_Y - 6, COUNTER_TOP_Y, cabFront - 6, ROOM_Z_BACK, k.Counter, k.CounterMat, shadowless)
	end
	span(b, "Backsplash", -ROOM_HALF_X, ROOM_HALF_X, COUNTER_TOP_Y, COUNTER_TOP_Y + 70, ROOM_Z_BACK - 1, ROOM_Z_BACK, k.Tile, k.TileMat, noCollide())

	-- Up the wall, leaving a gap over the sink area for each room's centrepiece.
	local upperY0, upperY1 = COUNTER_TOP_Y + 120, COUNTER_TOP_Y + 270
	for _, seg in { { -ROOM_HALF_X, -220 }, { -40, ROOM_HALF_X } } do
		local w = seg[2] - seg[1]
		if bench == "Steel" then
			-- Open steel shelving (pizza pans, tins, oil) under a stainless extractor hood.
			local steel = Color3.fromRGB(196, 200, 206)
			for level, y in { upperY0 + 10, upperY0 + 90 } do
				span(b, "WallShelf", seg[1], seg[2], y - 3, y, ROOM_Z_BACK - 28, ROOM_Z_BACK, steel, Enum.Material.Metal, shadowless)
				for x = seg[1] + 30, seg[2] - 30, 60 do
					span(b, "ShelfBracket", x - 1.5, x + 1.5, y - 16, y - 3, ROOM_Z_BACK - 24, ROOM_Z_BACK, Color3.fromRGB(150, 155, 162), Enum.Material.Metal, noCollide())
				end
				local n = math.floor(w / 34)
				for i = 0, n - 1 do
					local x = seg[1] + w * (i + 0.5) / n
					local kind = (i + level) % 4
					if kind == 0 then
						local pan = cyl(b, "PizzaPan", 2, 30, x, y + 15, ROOM_Z_BACK - 8, Color3.fromRGB(150, 155, 162), Enum.Material.Metal, noCollide())
						pan.CFrame = footprint(b.origin, x, y + 15, ROOM_Z_BACK - 8) * CFrame.Angles(0, math.rad(90), 0)
					elseif kind == 1 then
						cyl(b, "TomatoTin", 18, 14, x, y + 9, ROOM_Z_BACK - 14, Color3.fromRGB(210, 50, 40), Enum.Material.Metal, noCollide())
					elseif kind == 2 then
						cyl(b, "OilBottle", 26, 9, x, y + 13, ROOM_Z_BACK - 14, Color3.fromRGB(215, 190, 70), Enum.Material.Glass, { CanCollide = false, CastShadow = false, Transparency = 0.2 })
					else
						cyl(b, "DoughTub", 14, 20, x, y + 7, ROOM_Z_BACK - 14, Color3.fromRGB(245, 245, 240), nil, noCollide())
					end
				end
			end
			span(b, "Hood", seg[1], seg[2], upperY1 - 20, upperY1 + 20, ROOM_Z_BACK - 70, ROOM_Z_BACK, steel, Enum.Material.Metal, shadowless)
			span(b, "HoodLip", seg[1], seg[2], upperY1 - 26, upperY1 - 20, ROOM_Z_BACK - 70, ROOM_Z_BACK - 64, Color3.fromRGB(150, 155, 162), Enum.Material.Metal, noCollide())
			span(b, "HoodDuct", seg[1] + w / 2 - 30, seg[1] + w / 2 + 30, upperY1 + 20, KITCHEN_FLOOR_Y + ROOM_HEIGHT, ROOM_Z_BACK - 50, ROOM_Z_BACK, steel, Enum.Material.Metal, shadowless)
		elseif bench == "Stone" then
			-- Oak plate racks holding pewter plates and tankards.
			local oak = Color3.fromRGB(92, 58, 38)
			span(b, "RackBack", seg[1] + 10, seg[2] - 10, upperY0, upperY1, ROOM_Z_BACK - 3, ROOM_Z_BACK, oak, Enum.Material.WoodPlanks, shadowless)
			for level, y in { upperY0 + 8, upperY0 + 82 } do
				span(b, "RackShelf", seg[1] + 11, seg[2] - 11, y - 5, y, ROOM_Z_BACK - 22, ROOM_Z_BACK, oak, Enum.Material.Wood, shadowless)
				span(b, "RackRail", seg[1] + 11, seg[2] - 11, y + 20, y + 23, ROOM_Z_BACK - 22, ROOM_Z_BACK - 19, oak, Enum.Material.Wood, noCollide())
				local n = math.floor(w / 36)
				for i = 0, n - 1 do
					local x = seg[1] + 20 + (w - 40) * (i + 0.5) / n
					if (i + level) % 3 == 0 then
						cyl(b, "Tankard", 20, 14, x, y + 10, ROOM_Z_BACK - 12, Color3.fromRGB(150, 152, 158), Enum.Material.Metal, noCollide())
					else
						local plate = cyl(b, "PewterPlate", 2, 30, x, y + 16, ROOM_Z_BACK - 8, Color3.fromRGB(165, 168, 174), Enum.Material.Metal, noCollide())
						plate.CFrame = footprint(b.origin, x, y + 16, ROOM_Z_BACK - 8) * CFrame.Angles(math.rad(8), math.rad(90), 0)
					end
				end
			end
			span(b, "RackTop", seg[1] + 6, seg[2] - 6, upperY1, upperY1 + 8, ROOM_Z_BACK - 26, ROOM_Z_BACK, oak, Enum.Material.Wood, shadowless)
		else
			span(b, "UpperCabinets", seg[1], seg[2], upperY0, upperY1, ROOM_Z_BACK - 40, ROOM_Z_BACK, k.Cabinet, k.CabMat, shadowless)
			local n = math.floor(w / 70)
			for i = 0, n - 1 do
				local cx = seg[1] + w / n * (i + 0.5)
				box(b, "UpperDoor", Vector3.new(w / n - 5, upperY1 - upperY0 - 8, 1.2), cx, (upperY0 + upperY1) / 2, ROOM_Z_BACK - 40.6, k.CabinetDoor, k.CabMat, noCollide())
				box(b, "UpperHandle", Vector3.new(2.5, 16, 2.5), cx + (w / n / 2 - 10), upperY0 + 16, ROOM_Z_BACK - 42, k.Handle, k.HandleMat, noCollide())
			end
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
		span(b, "WindowBar", x - 3, x + 3, wy0 + 0.5, wy1 - 0.5, ROOM_Z_BACK - 3, ROOM_Z_BACK, Color3.new(1, 1, 1), nil, noCollide())
	end
	for _, y in { wy0, (wy0 + wy1) / 2, wy1 } do
		span(b, "WindowBar", wx0 + 0.5, wx1 - 0.5, y - 3, y + 3, ROOM_Z_BACK - 3, ROOM_Z_BACK, Color3.new(1, 1, 1), nil, noCollide())
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
	box(b, "FridgeSeam", Vector3.new(1, 2, 139.6), 299.8, fy + 170, -190, Color3.fromRGB(180, 185, 190), nil, noCollide())

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

	if not k.Outdoor then
		-- Neon sign in the gap over the counter.
		span(b, "SignBack", -214, -46, COUNTER_TOP_Y + 110, COUNTER_TOP_Y + 240, ROOM_Z_BACK - 3, ROOM_Z_BACK, Color3.fromRGB(30, 26, 26), nil, noCollide())
		roomSign(b, "PIZZA", Vector3.new(150, 70, 2), -130, COUNTER_TOP_Y + 175, ROOM_Z_BACK - 4, Color3.fromRGB(30, 26, 26), Color3.fromRGB(255, 120, 70), Enum.NormalId.Back)
		for _, y in { COUNTER_TOP_Y + 132, COUNTER_TOP_Y + 218 } do
			span(b, "NeonStrip", -200, -60, y - 1.5, y + 1.5, ROOM_Z_BACK - 6, ROOM_Z_BACK - 4, Color3.fromRGB(255, 90, 60), Enum.Material.Neon, noCollide())
		end
	end

	-- Brick pizza oven on the right: a stone plinth and brick base, a barrel-vaulted chamber (a
	-- cylinder along Z), a flat front with an arched glowing mouth that lines up with it, a firewood
	-- alcove below, and a chimney. The mouth faces -Z, toward the picnic tables where the chef works.
	local ox, oz = 250, -170
	local stone = Color3.fromRGB(196, 186, 172)
	span(b, "OvenPlinth", ox - 97, ox + 97, fy, fy + 8, oz - 87, oz + 87, Color3.fromRGB(150, 144, 136), Enum.Material.Cobblestone)
	span(b, "OvenBase", ox - 92, ox + 92, fy + 8, fy + 100, oz - 82, oz + 82, brick, Enum.Material.Brick)
	span(b, "OvenLedge", ox - 62, ox + 62, fy + 100, fy + 106, oz - 98, oz - 82, stone, Enum.Material.Concrete)
	local vault = box(b, "OvenVault", Vector3.new(160, 170, 170), ox, fy + 100, oz, brick, Enum.Material.Brick)
	vault.Shape = Enum.PartType.Cylinder
	vault.CFrame = footprint(b.origin, ox, fy + 100, oz) * CFrame.Angles(0, math.rad(90), 0)
	for _, dz in { -55, -5, 45 } do
		local band = box(b, "OvenBand", Vector3.new(6, 176, 176), ox, fy + 100, oz + dz, stone, Enum.Material.Concrete, noCollide())
		band.Shape = Enum.PartType.Cylinder
		band.CFrame = footprint(b.origin, ox, fy + 100, oz + dz) * CFrame.Angles(0, math.rad(90), 0)
	end
	-- Chimney rising out of the back of the vault.
	span(b, "OvenChimney", ox - 15, ox + 15, fy + 175, fy + 300, oz + 20, oz + 50, Color3.fromRGB(120, 58, 44), Enum.Material.Brick)
	span(b, "ChimneyCollar", ox - 20, ox + 20, fy + 290, fy + 300, oz + 15, oz + 55, stone, Enum.Material.Concrete)
	-- The mouth, drawn on the vault's flat front (z = oz - 80): a dark stone frame, then the glowing
	-- opening: a rectangle with a half-round top.
	local mouthZ = oz - 80
	span(b, "MouthFrame", ox - 44, ox + 44, fy + 100, fy + 142, mouthZ - 0.6, mouthZ - 0.3, Color3.fromRGB(70, 60, 54), Enum.Material.Slate, noCollide())
	local frameArch = box(b, "MouthFrameArch", Vector3.new(0.3, 88, 88), ox, fy + 142, mouthZ - 0.45, Color3.fromRGB(70, 60, 54), Enum.Material.Slate, noCollide())
	frameArch.Shape = Enum.PartType.Cylinder
	frameArch.CFrame = footprint(b.origin, ox, fy + 142, mouthZ - 0.45) * CFrame.Angles(0, math.rad(90), 0)
	span(b, "OvenMouth", ox - 36, ox + 36, fy + 104, fy + 142, mouthZ - 1.2, mouthZ - 0.9, Color3.fromRGB(255, 130, 40), Enum.Material.Neon, noCollide())
	local arch = box(b, "OvenArch", Vector3.new(0.3, 72, 72), ox, fy + 142, mouthZ - 1.05, Color3.fromRGB(255, 150, 60), Enum.Material.Neon, noCollide())
	arch.Shape = Enum.PartType.Cylinder
	arch.CFrame = footprint(b.origin, ox, fy + 142, mouthZ - 1.05) * CFrame.Angles(0, math.rad(90), 0)
	-- Below the ledge, the firewood alcove with a stack of logs.
	span(b, "WoodAlcove", ox - 36, ox + 36, fy + 16, fy + 78, oz - 82.6, oz - 82.2, Color3.fromRGB(40, 32, 28), Enum.Material.Slate, noCollide())
	for row = 0, 2 do
		for i = 0, 3 - row do
			local lx = ox - 27 + row * 9 + i * 18
			local log = box(b, "Log", Vector3.new(14, 15, 15), lx, fy + 26 + row * 14, oz - 90, Color3.fromRGB(150, 104, 62), Enum.Material.Wood, noCollide())
			log.Shape = Enum.PartType.Cylinder
			log.CFrame = footprint(b.origin, lx, fy + 26 + row * 14, oz - 90) * CFrame.Angles(0, math.rad(90), 0)
		end
	end
	local glow = Instance.new("PointLight")
	glow.Color = Color3.fromRGB(255, 140, 60)
	glow.Brightness = 2
	glow.Range = 60
	glow.Parent = b.model:FindFirstChild("OvenMouth") or b.model
	-- A pizza peel leaning on the side of the oven: the round blade rests on the floor, flat against
	-- the brick, and the handle's tip touches the lip. Built along a tilted axis so nothing pokes
	-- into the oven.
	local lean = math.rad(17)
	local peelZ = oz - 30
	local peelX0 = ox - 92 - 2.6 - 120 * math.sin(lean)
	local function onPeel(sAlong: number): CFrame
		return footprint(b.origin, peelX0 + sAlong * math.sin(lean), fy + sAlong * math.cos(lean), peelZ) * CFrame.Angles(0, 0, -lean)
	end
	local peelWood = Color3.fromRGB(185, 135, 85)
	local blade = cyl(b, "PeelHead", 2.4, 44, 0, 0, 0, peelWood, Enum.Material.Wood, noCollide())
	blade.CFrame = onPeel(24)
	box(b, "PeelNeck", Vector3.new(2.4, 26, 22), 0, 0, 0, peelWood, Enum.Material.Wood, noCollide()).CFrame = onPeel(44)
	box(b, "PeelHandle", Vector3.new(5, 66, 5), 0, 0, 0, Color3.fromRGB(165, 115, 70), Enum.Material.Wood, noCollide()).CFrame = onPeel(86)
	box(b, "PeelGrip", Vector3.new(5.6, 10, 5.6), 0, 0, 0, Color3.fromRGB(120, 60, 40), Enum.Material.Wood, noCollide()).CFrame = onPeel(113)

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

	-- Wooden ceiling beams and strings of warm party lights across the room.
	for z = ROOM_Z_FRONT + 60, ROOM_Z_BACK - 40, 110 do
		if k.Outdoor then
			break
		end
		span(b, "Beam", -ROOM_HALF_X, ROOM_HALF_X, fy + ROOM_HEIGHT - 16, fy + ROOM_HEIGHT, z - 8, z + 8, Color3.fromRGB(110, 72, 44), Enum.Material.Wood, noCollide())
	end
	local bulbColors = { Color3.fromRGB(255, 200, 90), Color3.fromRGB(255, 120, 90), Color3.fromRGB(120, 220, 140), Color3.fromRGB(255, 240, 200) }
	for li, z in { -440, -300, -160 } do
		local n = 18
		for i = 0, n do
			local u = i / n
			local x = -ROOM_HALF_X + 20 + u * (ROOM_HALF_X * 2 - 40)
			local y = fy + 420 - math.sin(u * math.pi) * 60
			local bulb = box(b, "PartyBulb", Vector3.new(7, 9, 7), x, y, z, bulbColors[(i + li) % #bulbColors + 1], Enum.Material.Neon, noCollide())
			bulb.Shape = Enum.PartType.Ball
			if i < n then
				local nx = -ROOM_HALF_X + 20 + (i + 1) / n * (ROOM_HALF_X * 2 - 40)
				local ny = fy + 420 - math.sin((i + 1) / n * math.pi) * 60
				local len = math.sqrt((nx - x) ^ 2 + (ny - y) ^ 2)
				local wire = box(b, "LightWire", Vector3.new(len, 0.8, 0.8), (x + nx) / 2, (y + ny) / 2 + 5, z, Color3.fromRGB(40, 40, 40), nil, noCollide())
				wire.CFrame = footprint(b.origin, (x + nx) / 2, (y + ny) / 2 + 5, z) * CFrame.Angles(0, 0, math.atan2(ny - y, nx - x))
			end
		end
	end
	if not k.Outdoor then
		-- The front wall: a chalkboard menu, a neon OPEN sign and a glass door.
		local frontZ = ROOM_Z_FRONT + 3
		span(b, "MenuFrame", -150, 150, fy + 220, fy + 400, ROOM_Z_FRONT, ROOM_Z_FRONT + 2, Color3.fromRGB(120, 80, 50), Enum.Material.Wood, noCollide())
		roomSign(b, "MENU\nMargherita  •  Pepperoni\nFour Cheese  •  Hawaiian", Vector3.new(284, 164, 2), 0, fy + 310, frontZ, Color3.fromRGB(35, 40, 38), Color3.fromRGB(245, 240, 225), Enum.NormalId.Front, Enum.Material.Slate)
		roomSign(b, "OPEN", Vector3.new(110, 44, 2), 260, fy + 330, frontZ, Color3.fromRGB(30, 26, 26), Color3.fromRGB(255, 80, 120), Enum.NormalId.Front)
		span(b, "DoorFrame", -320, -200, fy, fy + 240, ROOM_Z_FRONT, ROOM_Z_FRONT + 3, Color3.fromRGB(120, 80, 50), Enum.Material.Wood, noCollide())
		local glass = span(b, "DoorGlass", -310, -210, fy + 10, fy + 230, ROOM_Z_FRONT + 3, ROOM_Z_FRONT + 4, Color3.fromRGB(190, 225, 255), Enum.Material.Neon, noCollide())
		glass.Transparency = 0.3
		-- Shelves of ingredients on the left wall: flour sacks, tomato tins, jars of basil.
		local sx = -ROOM_HALF_X + 3
		for level, y in { fy + 170, fy + 250 } do
			span(b, "Shelf", sx, sx + 40, y - 4, y, -460, -300, Color3.fromRGB(140, 95, 60), Enum.Material.Wood)
			for k = 0, 5 do
				local z = -450 + k * 26
				if (k + level) % 3 == 0 then
					local sack = box(b, "FlourSack", Vector3.new(26, 34, 20), sx + 20, y + 17, z, Color3.fromRGB(240, 232, 215), Enum.Material.Fabric, noCollide())
					sack.Shape = Enum.PartType.Ball
				elseif (k + level) % 3 == 1 then
					cyl(b, "TomatoTin", 22, 16, sx + 20, y + 11, z, Color3.fromRGB(210, 50, 40), Enum.Material.Metal, noCollide())
				else
					cyl(b, "BasilJar", 20, 14, sx + 20, y + 10, z, Color3.fromRGB(90, 170, 80), Enum.Material.Glass, noCollide())
				end
			end
		end
		-- Potted basil by the tables.
		for _, px in { -250, 250 } do
			cyl(b, "Pot", 30, 36, px, fy + 15, -470, Color3.fromRGB(190, 100, 60))
			for k = 0, 4 do
				local leaf = box(b, "Basil", Vector3.new(22, 22, 22), px + math.cos(k * 1.3) * 10, fy + 38 + (k % 2) * 8, -470 + math.sin(k * 1.3) * 10, Color3.fromRGB(80, 160, 70), nil, noCollide())
				leaf.Shape = Enum.PartType.Ball
			end
		end

		-- Hanging pendant lamps.
		for _, lx in { -200, 0, 200 } do
			span(b, "LampCord", lx - 0.8, lx + 0.8, fy + 330, fy + ROOM_HEIGHT, -260 - 0.8, -260 + 0.8, Color3.fromRGB(30, 30, 30), nil, noCollide())
			cyl(b, "LampShade", 26, 60, lx, fy + 330, -260, Color3.fromRGB(40, 40, 44), Enum.Material.Metal, noCollide())
			local bulb = cyl(b, "LampBulb", 2, 40, lx, fy + 316, -260, k.Lamp, Enum.Material.Neon, noCollide())
			bulb.CastShadow = false
		end
	else
		-- String lights hang from tall wooden poles at both ends of the lines.
		for _, z in { -440, -300, -160 } do
			for _, sx in { -1, 1 } do
				cyl(b, "LightPole", 440, 8, sx * (ROOM_HALF_X - 20), fy + 220, z, Color3.fromRGB(110, 72, 44), Enum.Material.Wood, noCollide())
			end
		end
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

	-- Pillars along both side walls, each with a banner between. The hall is long, so there are many;
	-- the fireplace takes the right wall around z -240.
	local pillarZs = {}
	for z = ROOM_Z_FRONT + 90, -100, 150 do
		table.insert(pillarZs, z)
	end
	local function atFireplace(z: number): boolean
		return z > -350 and z < -130
	end
	for _, side in { -1, 1 } do
		for _, z in pillarZs do
			if side == 1 and atFireplace(z) then
				continue
			end
			local x = side * (ROOM_HALF_X - 30)
			span(b, "Pillar", x - 24, x + 24, fy, fy + ROOM_HEIGHT, z - 24, z + 24, stone, Enum.Material.Cobblestone)
			span(b, "PillarBase", x - 32, x + 32, fy, fy + 22, z - 32, z + 32, Color3.fromRGB(130, 124, 116), Enum.Material.Slate)
			span(b, "PillarCap", x - 32, x + 32, fy + ROOM_HEIGHT - 30, fy + ROOM_HEIGHT, z - 32, z + 32, Color3.fromRGB(130, 124, 116), Enum.Material.Slate)
			local bz = z + 75
			local bx = side * (ROOM_HALF_X - 3)
			if bz < ROOM_Z_BACK - 40 and not (side == 1 and atFireplace(bz)) then
				span(b, "Banner", bx - 1, bx + 1, fy + 420, fy + 720, bz - 36, bz + 36, red, Enum.Material.Fabric, noCollide())
				span(b, "BannerTrim", bx - 1.4, bx + 1.4, fy + 414, fy + 422, bz - 38, bz + 38, gold, Enum.Material.Metal, noCollide())
				span(b, "BannerRod", bx - 3, bx + 3, fy + 720, fy + 728, bz - 44, bz + 44, gold, Enum.Material.Metal, noCollide())
				span(b, "BannerCrest", bx - 1.6, bx + 1.6, fy + 540, fy + 590, bz - 16, bz + 16, gold, Enum.Material.Metal, noCollide())
			end
		end
	end

	-- Ribbed vault: a stone arch across the hall above every pillar pair, springing from the wall tops
	-- and meeting the ceiling in the middle.
	do
		local rise = 190
		local springY = fy + ROOM_HEIGHT - rise
		local n = 16
		for _, z in pillarZs do
			local px, py = ROOM_HALF_X - 30, springY
			for i = 1, n do
				local th = i / n * math.pi
				local nx, ny = math.cos(th) * (ROOM_HALF_X - 30), springY + math.sin(th) * rise
				local len = math.sqrt((nx - px) ^ 2 + (ny - py) ^ 2) + 2
				local seg = box(b, "VaultRib", Vector3.new(len, 20, 26), (px + nx) / 2, (py + ny) / 2, z, Color3.fromRGB(150, 144, 136), Enum.Material.Cobblestone, noCollide())
				seg.CFrame = footprint(b.origin, (px + nx) / 2, (py + ny) / 2, z) * CFrame.Angles(0, 0, math.atan2(ny - py, nx - px))
				px, py = nx, ny
			end
		end
	end

	-- Tall stained-glass windows in the wall bays between the pillars, with a stone frame and a pointed top.
	do
		local glass = { Color3.fromRGB(80, 120, 230), Color3.fromRGB(220, 60, 70), Color3.fromRGB(250, 200, 70), Color3.fromRGB(80, 190, 120) }
		for _, side in { -1, 1 } do
			for zi, z in pillarZs do
				local wz = z + 75
				if wz > ROOM_Z_BACK - 70 or (side == 1 and atFireplace(wz)) then
					continue
				end
				local wx = side * (ROOM_HALF_X - 2)
				local w, y0, y1 = 70, fy + 250, fy + 600
				span(b, "WindowFrame", wx - 3, wx + 1, y0 - 10, y1 + 10, wz - w / 2 - 8, wz + w / 2 + 8, Color3.fromRGB(120, 114, 106), Enum.Material.Slate, noCollide())
				for gi = 0, 2 do
					for gj = 0, 6 do
						local zz0 = wz - w / 2 + gi * w / 3
						local yy0 = y0 + gj * (y1 - y0) / 7
						local pane = span(b, "StainedGlass", wx - 1, wx + 1.5, yy0 + 1, yy0 + (y1 - y0) / 7 - 1, zz0 + 1, zz0 + w / 3 - 1, glass[(gi + gj + zi) % 4 + 1], Enum.Material.Neon, noCollide())
						pane.Transparency = 0.25
						pane.CastShadow = false
					end
				end
				-- pointed top: two slanted bars meeting above the window
				for _, s2 in { -1, 1 } do
					local bar = box(b, "WindowPoint", Vector3.new(4, 4, w / 2 + 14), wx, y1 + 22, wz + s2 * (w / 4 + 4), Color3.fromRGB(120, 114, 106), Enum.Material.Slate, noCollide())
					bar.CFrame = footprint(b.origin, wx, y1 + 22, wz + s2 * (w / 4 + 4)) * CFrame.Angles(s2 * math.rad(24), 0, 0)
				end
			end
		end
	end

	-- A gallery along each side wall: a stone walkway on corbels with a balustrade.
	for _, side in { -1, 1 } do
		local gx0, gx1 = side * (ROOM_HALF_X - 70), side * ROOM_HALF_X
		span(b, "GalleryFloor", gx0, gx1, fy + 330, fy + 346, ROOM_Z_FRONT + 40, ROOM_Z_BACK - 40, Color3.fromRGB(128, 122, 116), Enum.Material.Slate, noCollide())
		span(b, "GalleryRail", gx0 - side * 2, gx0 + side * 2, fy + 346, fy + 366, ROOM_Z_FRONT + 40, ROOM_Z_BACK - 40, Color3.fromRGB(150, 144, 136), Enum.Material.Cobblestone, noCollide())
		for z = ROOM_Z_FRONT + 60, ROOM_Z_BACK - 60, 40 do
			span(b, "Baluster", gx0 - side * 3, gx0 + side * 3, fy + 346, fy + 398, z - 4, z + 4, Color3.fromRGB(176, 170, 162), Enum.Material.Marble, noCollide())
		end
		span(b, "GalleryHandrail", gx0 - side * 4, gx0 + side * 4, fy + 398, fy + 408, ROOM_Z_FRONT + 40, ROOM_Z_BACK - 40, Color3.fromRGB(92, 58, 38), Enum.Material.Wood, noCollide())
		for z = ROOM_Z_FRONT + 90, ROOM_Z_BACK - 60, 150 do
			span(b, "Corbel", gx0 + side * 10, gx1, fy + 290, fy + 332, z - 14, z + 14, Color3.fromRGB(150, 144, 136), Enum.Material.Cobblestone, noCollide())
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

	-- Wall torches on the pillars' room-facing sides, lighting the hall warmly.
	for _, side in { -1, 1 } do
		for _, z in pillarZs do
			if side == 1 and atFireplace(z) then
				continue
			end
			local x = side * (ROOM_HALF_X - 58)
			span(b, "TorchBracket", x - 3, x + 3, fy + 220, fy + 250, z - 3, z + 3, Color3.fromRGB(60, 50, 45), Enum.Material.Metal, noCollide())
			cyl(b, "TorchCup", 10, 14, x, fy + 254, z, Color3.fromRGB(60, 50, 45), Enum.Material.Metal, noCollide())
			local flame = box(b, "TorchFlame", Vector3.new(10, 18, 10), x, fy + 268, z, Color3.fromRGB(255, 160, 60), Enum.Material.Neon, noCollide())
			flame.Shape = Enum.PartType.Ball
			local light = Instance.new("PointLight")
			light.Color = Color3.fromRGB(255, 170, 90)
			light.Brightness = 1.2
			light.Range = 55
			light.Parent = flame
		end
	end
	-- Suits of armour guarding the front wall, and shields with crests.
	for _, ax in { -200, 200 } do
		local steel = Color3.fromRGB(175, 180, 188)
		span(b, "ArmourPlinth", ax - 30, ax + 30, fy, fy + 12, ROOM_Z_FRONT + 10, ROOM_Z_FRONT + 70, Color3.fromRGB(110, 104, 98), Enum.Material.Slate)
		for _, lx in { -9, 9 } do
			span(b, "ArmourLeg", ax + lx - 7, ax + lx + 7, fy + 12, fy + 92, ROOM_Z_FRONT + 33, ROOM_Z_FRONT + 47, steel, Enum.Material.Metal)
		end
		span(b, "ArmourBody", ax - 22, ax + 22, fy + 92, fy + 160, ROOM_Z_FRONT + 30, ROOM_Z_FRONT + 50, steel, Enum.Material.Metal)
		for _, lx in { -30, 30 } do
			span(b, "ArmourArm", ax + lx - 6, ax + lx + 6, fy + 100, fy + 158, ROOM_Z_FRONT + 34, ROOM_Z_FRONT + 46, steel, Enum.Material.Metal)
		end
		local helm = box(b, "ArmourHelm", Vector3.new(30, 34, 30), ax, fy + 178, ROOM_Z_FRONT + 40, steel, Enum.Material.Metal)
		helm.Shape = Enum.PartType.Ball
		span(b, "Visor", ax - 12, ax + 12, fy + 176, fy + 180, ROOM_Z_FRONT + 55, ROOM_Z_FRONT + 56, Color3.fromRGB(30, 30, 34), nil, noCollide())
		span(b, "Plume", ax - 3, ax + 3, fy + 194, fy + 222, ROOM_Z_FRONT + 36, ROOM_Z_FRONT + 44, red, Enum.Material.Fabric, noCollide())
		span(b, "Spear", ax + 40, ax + 44, fy + 12, fy + 250, ROOM_Z_FRONT + 38, ROOM_Z_FRONT + 42, Color3.fromRGB(120, 85, 55), Enum.Material.Wood, noCollide())
		cyl(b, "Shield", 4, 70, ax, fy + 300, ROOM_Z_FRONT + 3, red, Enum.Material.Metal, noCollide()).CFrame = footprint(b.origin, ax, fy + 300, ROOM_Z_FRONT + 3) * CFrame.Angles(0, math.rad(90), 0)
		cyl(b, "ShieldBoss", 5, 30, ax, fy + 300, ROOM_Z_FRONT + 4, gold, Enum.Material.Metal, noCollide()).CFrame = footprint(b.origin, ax, fy + 300, ROOM_Z_FRONT + 4) * CFrame.Angles(0, math.rad(90), 0)
	end
	-- A great tapestry on the front wall, and dark ceiling beams.
	span(b, "Tapestry", -110, 110, fy + 170, fy + 440, ROOM_Z_FRONT, ROOM_Z_FRONT + 2, Color3.fromRGB(40, 60, 130), Enum.Material.Fabric, noCollide())
	span(b, "TapestryTrim", -116, 116, fy + 164, fy + 172, ROOM_Z_FRONT, ROOM_Z_FRONT + 2.5, gold, Enum.Material.Metal, noCollide())
	span(b, "TapestryRod", -124, 124, fy + 440, fy + 448, ROOM_Z_FRONT, ROOM_Z_FRONT + 6, gold, Enum.Material.Metal, noCollide())
	span(b, "TapestryCrest", -40, 40, fy + 260, fy + 350, ROOM_Z_FRONT + 2, ROOM_Z_FRONT + 2.6, gold, Enum.Material.Metal, noCollide())
	for z = ROOM_Z_FRONT + 60, ROOM_Z_BACK - 40, 120 do
		span(b, "Beam", -ROOM_HALF_X, ROOM_HALF_X, fy + ROOM_HEIGHT - 20, fy + ROOM_HEIGHT, z - 10, z + 10, Color3.fromRGB(60, 40, 28), Enum.Material.Wood, noCollide())
	end

	-- Chandeliers down the length of the hall: a gold ring with glowing candles on a long chain.
	for cz = ROOM_Z_FRONT + 170, -120, 230 do
		local ringY = fy + ROOM_HEIGHT - 300
		span(b, "Chain", -1.2, 1.2, ringY, fy + ROOM_HEIGHT, cz - 1.2, cz + 1.2, gold, Enum.Material.Metal, noCollide())
		cyl(b, "ChandelierRing", 6, 150, 0, ringY, cz, gold, Enum.Material.Metal, noCollide())
		cyl(b, "ChandelierInner", 5, 80, 0, ringY - 8, cz, gold, Enum.Material.Metal, noCollide())
		for i = 0, 11 do
			local a = i / 12 * math.pi * 2
			local x, z = math.cos(a) * 71, cz + math.sin(a) * 71
			cyl(b, "ChCandle", 14, 5, x, ringY + 10, z, Color3.fromRGB(250, 245, 230), nil, noCollide())
			local flame = box(b, "ChFlame", Vector3.new(4, 6, 4), x, ringY + 20, z, Color3.fromRGB(255, 190, 70), Enum.Material.Neon, noCollide())
			flame.Shape = Enum.PartType.Ball
		end
		local glow = Instance.new("PointLight")
		glow.Color = Color3.fromRGB(255, 200, 130)
		glow.Brightness = 1.5
		glow.Range = 60
		glow.Parent = b.model:FindFirstChild("ChandelierRing") or b.model
	end
end

-- Level 2 scenery: the backyard around the patio. Lawn, a ring of hills and mountains that closes
-- the horizon all round, proper trees, the house, a picket fence, a BBQ, parasols and flower beds.
-- Everything here is out of reach (the patio is walled by invisible barriers) so it's non-colliding.
-- Arena slots are 2400 studs apart, so it all stays within +-1200 of the slot.
local function buildYard(b: Builder)
	local fy = KITCHEN_FLOOR_Y
	local scenery = noCollide()
	local function ball(name: string, sx: number, sy: number, sz: number, x: number, y: number, z: number, color: Color3, material: Enum.Material?)
		local p = box(b, name, Vector3.new(sx, sy, sz), x, y, z, color, material, scenery)
		p.Shape = Enum.PartType.Ball
		return p
	end
	local grass = Color3.fromRGB(104, 168, 76)
	local grassDark = Color3.fromRGB(84, 146, 64)
	local rng = Random.new(7)

	-- Lawn all round the patio, a step lower than it.
	span(b, "Lawn", -1000, 1000, fy - 10, fy - 0.6, -1000, 1000, grass, Enum.Material.Grass, scenery)
	span(b, "PatioEdgeFront", -424, 424, fy - 4, fy + 1.2, ROOM_Z_FRONT - 6, ROOM_Z_FRONT, Color3.fromRGB(150, 144, 136), Enum.Material.Cobblestone, scenery)
	for x = -ROOM_HALF_X + 60, ROOM_HALF_X - 1, 120 do
		span(b, "PaverJoint", x - 0.5, x + 0.5, fy, fy + 0.15, ROOM_Z_FRONT, -64, Color3.fromRGB(120, 114, 106), nil, scenery)
	end
	for z = ROOM_Z_FRONT + 60, -64, 120 do
		span(b, "PaverJoint", -ROOM_HALF_X, ROOM_HALF_X, fy, fy + 0.15, z - 0.5, z + 0.5, Color3.fromRGB(120, 114, 106), nil, scenery)
	end

	-- Mountains: a low-poly heightmap mesh in polar form around the yard (rolling green hills, then
	-- rock, then snow), drawn as triangles. Each triangle is two WedgeParts (the standard trick: split
	-- at the altitude from the vertex opposite the longest side). The ridge rises to 900-1500 studs,
	-- then falls away behind, so the view out is always mountain and sky, never a blank horizon.
	local MT_IN, MT_RIDGE, MT_OUT = 640, 1950, 2500
	local function smooth(a: number, b2: number, x: number): number
		local t = math.clamp((x - a) / (b2 - a), 0, 1)
		return t * t * (3 - 2 * t)
	end
	local function terrainH(x: number, z: number): number
		local r = math.sqrt(x * x + z * z)
		if r < MT_IN then
			return 0
		end
		local th = math.atan2(z, x)
		local t = math.clamp((r - MT_IN) / (MT_RIDGE - MT_IN), 0, 1)
		local rolling = (math.noise(x * 0.0032, z * 0.0032, 1.3) * 0.5 + 0.5) * 150 * smooth(MT_IN, 900, r)
		local ridge = 1 - math.abs(math.noise(th * 2.3, r * 0.0016, 4.1)) * 1.6
		local amp = 900 + 600 * (math.noise(th * 1.4, 7.7, 2.2) * 0.5 + 0.5)
		local peaks = (t ^ 1.7) * amp * math.clamp(0.5 + 0.75 * ridge, 0.15, 1.3)
		local fall = 1 - smooth(MT_RIDGE, MT_OUT, r)
		return (rolling + peaks) * fall
	end
	local function addTriangle(p1: Vector3, p2: Vector3, p3: Vector3, color: Color3)
		local a, bb, c = worldPoint(b.origin, p1.X, p1.Y, p1.Z), worldPoint(b.origin, p2.X, p2.Y, p2.Z), worldPoint(b.origin, p3.X, p3.Y, p3.Z)
		local ab, ac, bc = bb - a, c - a, c - bb
		local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
		if abd > acd and abd > bcd then
			c, a = a, c
		elseif acd > bcd and acd > abd then
			a, bb = bb, a
		end
		ab, ac, bc = bb - a, c - a, c - bb
		local rightV = ac:Cross(ab)
		if rightV.Magnitude < 1e-3 or bc.Magnitude < 1e-3 then
			return
		end
		rightV = rightV.Unit
		local upV = bc:Cross(rightV).Unit
		local back = bc.Unit
		local height = math.abs(ab:Dot(upV))
		local function wedge(size: Vector3, cf: CFrame)
			local w = Instance.new("WedgePart")
			w.Size = size
			w.CFrame = cf
			w.Color = color
			w.Material = Enum.Material.SmoothPlastic
			w.Anchored = true
			w.CanCollide = false
			w.CanTouch = false
			w.CanQuery = false
			w.CastShadow = false
			w.Parent = b.model
			b.count += 1
		end
		wedge(Vector3.new(0.05, height, math.abs(ab:Dot(back))), CFrame.fromMatrix((a + bb) / 2, rightV, upV, back))
		wedge(Vector3.new(0.05, height, math.abs(ac:Dot(back))), CFrame.fromMatrix((a + c) / 2, -rightV, upV, -back))
	end
	do
		local radii = { 640, 760, 900, 1060, 1250, 1460, 1700, 1950, 2200, 2500 }
		local steps = 36
		local baseY = fy - 0.3
		local grid = {}
		for i, r in radii do
			grid[i] = {}
			for j = 0, steps - 1 do
				-- jitter every vertex a little so the facets aren't a regular grid
				local th = (j + math.noise(i * 1.7, j * 2.3, 0.5) * 0.35) / steps * math.pi * 2
				local rr = r * (1 + (if i == 1 then 0 else math.noise(i * 3.1, j * 1.9, 9.2) * 0.07))
				local x, z = math.cos(th) * rr, math.sin(th) * rr
				grid[i][j] = Vector3.new(x, baseY + terrainH(x, z) + (if i == 1 then 0 else 0.3), z)
			end
		end
		local function shade(p: Vector3, q: Vector3, s: Vector3, jitterKey: number): Color3
			local top = (p.Y + q.Y + s.Y) / 3 - baseY
			local normal = (q - p):Cross(s - p)
			normal = if normal.Y < 0 then -normal else normal
			local steepness = 1 - math.clamp(normal.Unit.Y, 0, 1) -- 0 flat, 1 vertical
			local light = 0.82 + math.noise(jitterKey * 0.37, 1.1, 3.3) * 0.25
			local base: Color3
			if top < 130 then
				base = grassDark:Lerp(grass, math.clamp(top / 130, 0, 1))
			elseif top > 700 and steepness < 0.62 then
				base = Color3.fromRGB(240, 244, 250)
			elseif top > 330 then
				base = Color3.fromRGB(128, 122, 116):Lerp(Color3.fromRGB(104, 112, 128), steepness)
			else
				base = grassDark:Lerp(Color3.fromRGB(128, 122, 116), math.clamp((top - 130) / 200 + steepness * 0.5, 0, 1))
			end
			return Color3.new(math.min(base.R * light, 1), math.min(base.G * light, 1), math.min(base.B * light, 1))
		end
		for i = 1, #radii - 1 do
			for j = 0, steps - 1 do
				local j2 = (j + 1) % steps
				local p00, p01, p10, p11 = grid[i][j], grid[i][j2], grid[i + 1][j], grid[i + 1][j2]
				local key = i * 97 + j
				if (i + j) % 2 == 0 then
					addTriangle(p00, p01, p11, shade(p00, p01, p11, key))
					addTriangle(p00, p11, p10, shade(p00, p11, p10, key + 1))
				else
					addTriangle(p00, p01, p10, shade(p00, p01, p10, key))
					addTriangle(p01, p11, p10, shade(p01, p11, p10, key + 1))
				end
			end
		end
	end

	-- Trees, in the same low-poly style as the lobby's: a hexagonal trunk (three crossed boxes) and a
	-- stack of turned, faceted canopy blocks that overlap the trunk top, so nothing floats. Pines are
	-- tiers of turned blocks that narrow to a tip.
	local trunkColor = Color3.fromRGB(120, 84, 56)
	local greens = { Color3.fromRGB(86, 150, 78), Color3.fromRGB(104, 168, 86), Color3.fromRGB(74, 136, 70) }
	local function rotBox(name: string, size: Vector3, x: number, y: number, z: number, color: Color3, rx: number, ry: number, rz: number)
		local p = box(b, name, size, x, y, z, color, Enum.Material.SmoothPlastic, scenery)
		p.CFrame = footprint(b.origin, x, y, z) * CFrame.Angles(rx, ry, rz)
		return p
	end
	local function oak(x: number, z: number, scale: number)
		local gy = fy + math.max(terrainH(x, z) - 6, 0)
		local trunkH = 70 * scale
		local tr = 9 * scale
		local side = tr / math.sqrt(3)
		for k = 0, 2 do
			rotBox("TreeTrunk", Vector3.new(side, trunkH, tr), x, gy + trunkH / 2, z, trunkColor, 0, k * math.pi / 3, 0)
		end
		for i = 0, 2 do
			local size = (64 - i * 14) * scale
			rotBox("TreeCanopy", Vector3.new(size, size * 0.8, size), x, gy + trunkH + (i * 26 - 12) * scale, z, greens[i + 1], math.rad(12 * (if i % 2 == 0 then 1 else -1)), math.rad(rng:NextNumber(0, 90)), math.rad(8))
		end
	end
	local function pine(x: number, z: number, scale: number)
		local gy = fy + math.max(terrainH(x, z) - 6, 0)
		local trunkH = 40 * scale
		local tr = 6 * scale
		local side = tr / math.sqrt(3)
		for k = 0, 2 do
			rotBox("TreeTrunk", Vector3.new(side, trunkH, tr), x, gy + trunkH / 2, z, trunkColor, 0, k * math.pi / 3, 0)
		end
		for i = 0, 4 do
			local size = (56 - i * 10) * scale
			rotBox("PineTier", Vector3.new(size, 22 * scale, size), x, gy + trunkH * 0.7 + i * 17 * scale, z, if i % 2 == 0 then Color3.fromRGB(58, 120, 64) else Color3.fromRGB(46, 104, 58), 0, math.rad(45 * i + 10), 0)
		end
	end
	-- Slim pines line the patio fence (clear of the oven and the BBQ); oaks stand further out.
	for _, side in { -1, 1 } do
		for z = -480, 40, 130 do
			pine(side * 470, z, 3.2 + (z % 3) * 0.2)
		end
	end
	for _, t in { { -700, -300, 5.2 }, { 720, -260, 5.6 }, { -760, 100, 5.8 }, { 700, 160, 5.2 }, { -640, 420, 5.6 }, { 660, 460, 5.4 }, { -330, 760, 6 }, { 380, 800, 6 }, { -560, -720, 5.4 }, { 540, -700, 5.6 }, { -200, -820, 5.2 }, { 220, -860, 5.6 } } do
		oak(t[1], t[2], t[3])
	end
	for _, t in { { -820, -80, 4.4 }, { 820, 40, 4.2 }, { -420, 640, 4.2 }, { 470, 620, 4.4 } } do
		pine(t[1], t[2], t[3])
	end

	-- Picket fence round the patio (front and both sides; the counter closes the back).
	local fenceColor = Color3.fromRGB(246, 244, 238)
	local function fenceRun(x0: number, z0: number, x1: number, z1: number)
		local len = math.sqrt((x1 - x0) ^ 2 + (z1 - z0) ^ 2)
		local n = math.floor(len / 14)
		local along = Vector3.new(x1 - x0, 0, z1 - z0).Unit
		local horizontal = math.abs(x1 - x0) > math.abs(z1 - z0)
		for i = 0, n do
			local x, z = x0 + along.X * len * i / n, z0 + along.Z * len * i / n
			local sx, sz = if horizontal then 6 else 2.5, if horizontal then 2.5 else 6
			local pk = box(b, "Picket", Vector3.new(sx, 56, sz), x, fy + 28, z, fenceColor, Enum.Material.SmoothPlastic, scenery)
			if i % 6 == 0 then
				pk.Size = Vector3.new(sx + 2, 66, sz + 2)
			end
		end
		for _, y in { 16, 40 } do
			local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
			box(b, "FenceRail", Vector3.new(if horizontal then len else 3, 5, if horizontal then 3 else len), cx, fy + y, cz, fenceColor, Enum.Material.SmoothPlastic, scenery)
		end
	end
	fenceRun(-ROOM_HALF_X + 4, ROOM_Z_FRONT + 4, ROOM_HALF_X - 4, ROOM_Z_FRONT + 4)
	fenceRun(-ROOM_HALF_X + 4, ROOM_Z_FRONT + 4, -ROOM_HALF_X + 4, -70)
	fenceRun(ROOM_HALF_X - 4, ROOM_Z_FRONT + 4, ROOM_HALF_X - 4, -70)

	-- The BBQ on the left, a barrel grill on a cart, well clear of where the waiter walks.
	local gx, gz = -300, -130
	local steel = Color3.fromRGB(46, 48, 54)
	local chrome = Color3.fromRGB(190, 196, 204)
	for _, lx in { -62, 62 } do
		for _, lz in { -30, 30 } do
			cyl(b, "BbqLeg", 74, 6, gx + lx, fy + 37, gz + lz, steel, Enum.Material.Metal, scenery)
		end
	end
	span(b, "BbqShelf", gx - 70, gx + 70, fy + 36, fy + 40, gz - 36, gz + 36, chrome, Enum.Material.Metal, scenery)
	cyl(b, "PropaneTank", 52, 28, gx - 34, fy + 66, gz, Color3.fromRGB(235, 232, 226), Enum.Material.Metal, scenery)
	span(b, "BbqBase", gx - 78, gx + 78, fy + 74, fy + 124, gz - 40, gz + 40, steel, Enum.Material.Metal, scenery)
	local lid = box(b, "BbqLid", Vector3.new(148, 84, 84), gx, fy + 124, gz, Color3.fromRGB(34, 36, 42), Enum.Material.Metal, scenery)
	lid.Shape = Enum.PartType.Cylinder
	-- Handle: a bar held off the lid's front by two brackets (the lid's front is at gz - 42).
	span(b, "BbqHandle", gx - 50, gx + 50, fy + 150, fy + 154, gz - 56, gz - 52, chrome, Enum.Material.Metal, scenery)
	for _, hx in { -44, 44 } do
		span(b, "BbqHandleBracket", gx + hx - 1.5, gx + hx + 1.5, fy + 150, fy + 154, gz - 54, gz - 40, chrome, Enum.Material.Metal, scenery)
	end
	span(b, "BbqGlow", gx - 60, gx + 60, fy + 116, fy + 120, gz - 40.8, gz - 40.2, Color3.fromRGB(255, 120, 40), Enum.Material.Neon, scenery)
	cyl(b, "BbqStack", 40, 14, gx + 54, fy + 176, gz + 24, steel, Enum.Material.Metal, scenery)
	local smokeAnchor = box(b, "BbqSmoke", Vector3.new(2, 2, 2), gx + 54, fy + 200, gz + 24, chrome, nil, { Transparency = 1, CanCollide = false, CastShadow = false })
	local smoke = Instance.new("ParticleEmitter")
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Color = ColorSequence.new(Color3.fromRGB(210, 210, 214))
	smoke.Lifetime = NumberRange.new(4, 6)
	smoke.Speed = NumberRange.new(10, 18)
	smoke.Rate = 5
	smoke.Size = NumberSequence.new(10, 34)
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 1) })
	smoke.EmissionDirection = Enum.NormalId.Top
	smoke.SpreadAngle = Vector2.new(12, 12)
	smoke.Parent = smokeAnchor

	-- Beach parasols on the patio (clear of the chef's and the waiter's routes).
	for _, ux in { -370, 370 } do
		local uz = -330
		cyl(b, "ParasolPole", 280, 6, ux, fy + 140, uz, Color3.fromRGB(235, 232, 226), Enum.Material.Metal, scenery)
		ball("ParasolTop", 230, 80, 230, ux, fy + 280, uz, Color3.fromRGB(215, 60, 55), Enum.Material.Fabric)
		ball("ParasolStripe", 232, 40, 232, ux, fy + 296, uz, Color3.fromRGB(250, 246, 238), Enum.Material.Fabric)
		cyl(b, "ParasolBase", 10, 60, ux, fy + 5, uz, Color3.fromRGB(120, 114, 106), Enum.Material.Concrete, scenery)
	end

	-- Pizzas and pizza boxes on the benches: a wooden board, a crust, sauce, cheese, pepperoni, basil
	-- and cut lines. (Each layer is a little thicker than the one under it, so no faces share a plane.)
	local benchY = COUNTER_TOP_Y
	local function pizza(x: number, z: number, sliced: boolean)
		cyl(b, "PizzaBoard", 3, 88, x, benchY + 1.5, z, Color3.fromRGB(176, 128, 82), Enum.Material.Wood, scenery)
		cyl(b, "PizzaCrust", 4, 76, x, benchY + 5, z, Color3.fromRGB(226, 172, 92), Enum.Material.Sand, scenery)
		cyl(b, "PizzaSauce", 4.4, 66, x, benchY + 5.2, z, Color3.fromRGB(200, 60, 35), Enum.Material.SmoothPlastic, scenery)
		cyl(b, "PizzaCheese", 4.8, 60, x, benchY + 5.4, z, Color3.fromRGB(246, 214, 112), Enum.Material.SmoothPlastic, scenery)
		for k = 0, 7 do
			local a = k / 8 * math.pi * 2 + 0.3
			local r = if k % 2 == 0 then 20 else 10
			cyl(b, "Pepperoni", 5.2, 11, x + math.cos(a) * r, benchY + 5.6, z + math.sin(a) * r, Color3.fromRGB(160, 34, 34), Enum.Material.SmoothPlastic, scenery)
		end
		for k = 0, 4 do
			local a = k * 1.9 + 0.7
			local lf = box(b, "Basil", Vector3.new(7, 0.8, 4), x + math.cos(a) * 14, benchY + 8.4, z + math.sin(a) * 14, Color3.fromRGB(70, 150, 66), Enum.Material.SmoothPlastic, scenery)
			lf.CFrame = footprint(b.origin, x + math.cos(a) * 14, benchY + 8.4, z + math.sin(a) * 14) * CFrame.Angles(0, a, 0)
		end
		if sliced then
			for k = 0, 2 do
				local ln = box(b, "PizzaCut", Vector3.new(66, 0.5, 0.8), x, benchY + 8.2, z, Color3.fromRGB(150, 100, 50), Enum.Material.SmoothPlastic, scenery)
				ln.CFrame = footprint(b.origin, x, benchY + 8.2, z) * CFrame.Angles(0, k * math.pi / 3, 0)
			end
		end
	end
	local function boxStack(x: number, z: number, n: number)
		for j = 0, n - 1 do
			local y = benchY + 2.6 + j * 5.2
			local bx = box(b, "PizzaBox", Vector3.new(66, 5, 66), x + (j % 2) * 1.5, y, z - (j % 2) * 1.2, Color3.fromRGB(246, 238, 220), Enum.Material.Cardboard, scenery)
			bx.CFrame = footprint(b.origin, x + (j % 2) * 1.5, y, z - (j % 2) * 1.2) * CFrame.Angles(0, j * 0.12, 0)
		end
		cyl(b, "PizzaBoxLogo", 0.4, 26, x, benchY + 5.2 * n + 2.7, z, Color3.fromRGB(205, 45, 40), Enum.Material.SmoothPlastic, scenery)
	end
	-- (Where they stand: each side of the sink is a counter 358 long and 170 deep. A pizza board is 88 across and a box
-- stack up to about 92 across (the boxes are turned a little), so three fit along a side with room between them; there
-- used to be seven, which overlapped (a stack of boxes sunk into a pizza). Every prop keeps at least 10 studs from the
-- next and from the counter's edge; the check is _tools/tests/overlapcheck.py.)
boxStack(-114, 4, 5)
pizza(-250, 44, true)
pizza(-362, -4, false)
boxStack(114, 6, 4)
pizza(240, 14, true)
boxStack(366, 30, 3)

	-- The house behind the yard: two storeys, a gabled roof, a porch and flower beds.
	local hz0, hz1 = 520, 740
	local siding = Color3.fromRGB(246, 232, 196)
	local trim = Color3.fromRGB(252, 250, 246)
	span(b, "HouseWalls", -280, 280, fy - 4, fy + 400, hz0, hz1, siding, Enum.Material.WoodPlanks, scenery)
	span(b, "HouseBase", -284, 284, fy - 4, fy + 30, hz0 - 3, hz1 + 3, Color3.fromRGB(150, 144, 136), Enum.Material.Cobblestone, scenery)
	span(b, "HouseBelt", -284, 284, fy + 196, fy + 204, hz0 - 3, hz1 + 3, trim, nil, scenery)
	for floor = 0, 1 do
		local wy0, wy1 = fy + 70 + floor * 200, fy + 160 + floor * 200
		for _, wx in { -200, -100, 100, 200 } do
			span(b, "WindowFrame", wx - 30, wx + 30, wy0 - 6, wy1 + 6, hz0 - 3, hz0, trim, nil, scenery)
			local glass = span(b, "WindowGlass", wx - 24, wx + 24, wy0, wy1, hz0 - 3.4, hz0 - 3, Color3.fromRGB(150, 205, 240), Enum.Material.Glass, scenery)
			glass.Transparency = 0.25
			span(b, "WindowBar", wx - 2, wx + 2, wy0, wy1, hz0 - 3.8, hz0 - 3.4, trim, nil, scenery)
			span(b, "WindowBar", wx - 24, wx + 24, (wy0 + wy1) / 2 - 2, (wy0 + wy1) / 2 + 2, hz0 - 3.8, hz0 - 3.4, trim, nil, scenery)
			for _, sx in { -1, 1 } do
				span(b, "Shutter", wx + sx * 34 - 6, wx + sx * 34 + 6, wy0 - 6, wy1 + 6, hz0 - 3.4, hz0 - 3, Color3.fromRGB(70, 120, 150), nil, scenery)
			end
		end
	end
	span(b, "DoorFrame", -42, 42, fy + 30, fy + 180, hz0 - 3, hz0, trim, nil, scenery)
	span(b, "FrontDoor", -34, 34, fy + 30, fy + 174, hz0 - 3.6, hz0 - 3, Color3.fromRGB(190, 52, 48), Enum.Material.Wood, scenery)
	cyl(b, "DoorKnob", 8, 8, 22, fy + 100, hz0 - 6, Color3.fromRGB(230, 190, 90), Enum.Material.Metal, scenery)
	span(b, "PorchSlab", -90, 90, fy - 2, fy + 10, hz0 - 70, hz0 - 3, Color3.fromRGB(176, 170, 160), Enum.Material.Slate, scenery)
	span(b, "PorchStep", -60, 60, fy - 2, fy + 4, hz0 - 100, hz0 - 70, Color3.fromRGB(176, 170, 160), Enum.Material.Slate, scenery)
	span(b, "PorchRoof", -100, 100, fy + 196, fy + 204, hz0 - 80, hz0, Color3.fromRGB(150, 70, 56), Enum.Material.Slate, scenery)
	for _, px in { -90, 90 } do
		cyl(b, "PorchPost", 176, 10, px, fy + 103, hz0 - 76, trim, Enum.Material.SmoothPlastic, scenery)
	end
	local roofRed = Color3.fromRGB(150, 70, 56)
	local slope = math.rad(34)
	local roofCZ = (hz0 + hz1) / 2
	for _, side in { -1, 1 } do
		local half = (hz1 - hz0) / 2 + 28
		local rise = math.sin(slope) * half / 2
		local run = math.cos(slope) * half / 2
		local slab = box(b, "Roof", Vector3.new(600, 10, half), 0, fy + 400 + rise, roofCZ + side * run, roofRed, Enum.Material.Slate, scenery)
		slab.CFrame = footprint(b.origin, 0, fy + 400 + rise, roofCZ + side * run) * CFrame.Angles(-side * slope, 0, 0)
	end
	for step = 0, 5 do
		local halfZ = (hz1 - hz0) / 2 * (1 - step / 6)
		for _, sx in { -1, 1 } do
			span(b, "Gable", sx * 278, sx * 282, fy + 400 + step * 18, fy + 418 + step * 18, roofCZ - halfZ, roofCZ + halfZ, siding, Enum.Material.WoodPlanks, scenery)
		end
	end
	span(b, "Chimney", 170, 220, fy + 380, fy + 600, roofCZ + 20, roofCZ + 70, Color3.fromRGB(150, 70, 52), Enum.Material.Brick, scenery)
	span(b, "ChimneyCap", 164, 226, fy + 600, fy + 610, roofCZ + 14, roofCZ + 76, Color3.fromRGB(190, 180, 170), Enum.Material.Concrete, scenery)
	local blooms = { Color3.fromRGB(235, 80, 110), Color3.fromRGB(250, 200, 60), Color3.fromRGB(180, 110, 230), Color3.fromRGB(250, 250, 250) }
	for bi, bx in { -200, -130, 130, 200 } do
		span(b, "FlowerBed", bx - 40, bx + 40, fy - 0.6, fy + 12, hz0 - 40, hz0 - 10, Color3.fromRGB(96, 66, 46), Enum.Material.Ground, scenery)
		for i = 0, 3 do
			ball("Flower", 14, 14, 14, bx - 28 + i * 19, fy + 20, hz0 - 25, blooms[(i + bi) % 4 + 1], Enum.Material.SmoothPlastic)
			cyl(b, "Stem", 10, 2, bx - 28 + i * 19, fy + 12, hz0 - 25, Color3.fromRGB(70, 140, 60), nil, scenery)
		end
	end
	for z = 130, hz0 - 110, 56 do
		span(b, "StepStone", -26, 26, fy - 0.6, fy + 1, z, z + 40, Color3.fromRGB(176, 170, 160), Enum.Material.Slate, scenery)
	end
end

-- Level 2's tap over the sink: a chrome gooseneck on the back of the counter with hot and cold
-- handles; the water is a thin falling particle stream (no solid parts to look odd).
local function buildFaucet(b: Builder)
	local chrome = Color3.fromRGB(205, 210, 218)
	local base = COUNTER_TOP_Y
	local tz = 88
	cyl(b, "FaucetBase", 6, 22, 0, base + 3, tz, chrome, Enum.Material.Metal, noCollide())
	cyl(b, "FaucetPipe", 56, 8, 0, base + 34, tz, chrome, Enum.Material.Metal, noCollide())
	local elbow = box(b, "FaucetElbow", Vector3.new(11, 11, 11), 0, base + 62, tz, chrome, Enum.Material.Metal, noCollide())
	elbow.Shape = Enum.PartType.Ball
	span(b, "FaucetSpout", -3.5, 3.5, base + 56.5, base + 67.5, 28, tz, chrome, Enum.Material.Metal, noCollide())
	cyl(b, "FaucetNozzle", 9, 9, 0, base + 53, 28, chrome, Enum.Material.Metal, noCollide())
	local handles: { { any } } = { { -22, Color3.fromRGB(70, 130, 220) }, { 22, Color3.fromRGB(220, 70, 60) } }
	for _, h in handles do
		cyl(b, "TapStem", 9, 5, h[1], base + 4.5, tz - 2, chrome, Enum.Material.Metal, noCollide())
		span(b, "TapLever", h[1] - 8, h[1] + 8, base + 9, base + 11.5, tz - 3.2, tz - 0.8, chrome, Enum.Material.Metal, noCollide())
		for _, side in { -1, 1 } do
			cyl(b, "TapCap", 3, 5, h[1] + side * 8, base + 11.5, tz - 2, chrome, Enum.Material.Metal, noCollide())
		end
		cyl(b, "TapDot", 0.6, 3, h[1], base + 12, tz - 2, h[2], Enum.Material.SmoothPlastic, noCollide())
	end
	-- Water: a thin particle stream from the nozzle down into the basin.
	local anchor = box(b, "FaucetWater", Vector3.new(2, 2, 2), 0, base + 48, 28, chrome, nil, { Transparency = 1, CanCollide = false, CastShadow = false })
	local drops = Instance.new("ParticleEmitter")
	drops.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	drops.Color = ColorSequence.new(Color3.fromRGB(170, 215, 255))
	drops.LightEmission = 0.3
	drops.Lifetime = NumberRange.new(1.5, 1.7)
	drops.Speed = NumberRange.new(50, 56)
	drops.Rate = 40
	drops.Size = NumberSequence.new(2.4, 1.8)
	drops.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0.7) })
	drops.SpreadAngle = Vector2.new(2, 2)
	drops.EmissionDirection = Enum.NormalId.Bottom
	drops.Parent = anchor
end

-- The whole room for a level: shell + that room's props.
local function buildRoom(b: Builder, levelIndex: number)
	local style = ROOM_STYLES[levelIndex] or ROOM_STYLES[1]
	buildKitchen(b, style)
	if levelIndex == 2 then
		pizzeriaProps(b, style)
		buildYard(b)
		buildFaucet(b)
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
	-- Level 2's basin is a white porcelain sink, open to the sky (no ceiling), with a rolled rim.
	local sink = theme.Sink == true
	-- Level 3's basin is an olden-day oak wash trough bound with iron hoops, also open at the top.
	local trough = theme.Trough == true
	local open = sink
	local tubMat = if sink then Enum.Material.SmoothPlastic elseif trough then Enum.Material.WoodPlanks else Enum.Material.Metal

	-- Tub floor and walls. They don't cast shadows, so the room's daylight still reaches inside.
	span(b, "TubFloor", -TUB_HALF_X - 2, TUB_HALF_X + 2, -2, 0, TUB_Z_MIN, TUB_Z_MAX, steel, tubMat)
	for _, side in { -1, 1 } do
		span(b, "TubWall", side * TUB_HALF_X, side * (TUB_HALF_X + 2), 0, TUB_HEIGHT, TUB_Z_MIN, TUB_Z_MAX, steel, tubMat)
		-- Pressed ribs and rack rails on the side walls.
		for i = 1, (if open then 0 else 6) do
			local y = i * (TUB_HEIGHT / 7)
			span(b, "Rib", side * (TUB_HALF_X - 0.3), side * TUB_HALF_X, y - 0.4, y + 0.4, TUB_Z_MIN + 4, TUB_Z_MAX - 4, theme.Metal, Enum.Material.Metal, noCollide())
		end
		local railYs: { number } = if sink then { BOTTOM_RACK_Y - 1 } else { BOTTOM_RACK_Y - 1, TOP_RACK_Y - 1 }
		for _, y in railYs do
			span(b, "RackRail", side * (TUB_HALF_X - 1.6), side * TUB_HALF_X, y - 0.8, y + 0.8, TUB_Z_MIN + 2, TUB_Z_MAX - 2, theme.Rack, Enum.Material.Metal, noCollide())
		end
	end
	-- The tub casts shadows (it's a closed box, like a real machine): the inside is lit by the
	-- interior lights below rather than blasted by daylight.
	span(b, "TubBack", -TUB_HALF_X - 2, TUB_HALF_X + 2, 0, TUB_HEIGHT, TUB_Z_MAX, TUB_Z_MAX + 2, steel, tubMat)
	if open then
		if sink then
			-- The top rack is a dish drainer standing over the sink on four chrome posts, one under each
			-- corner of its frame (the frame's bars are centred on x = +-RACK_HALF_X and z = TOP_RACK_Z).
			for _, px in { -RACK_HALF_X, RACK_HALF_X } do
				for _, pz in { TOP_RACK_Z[1], TOP_RACK_Z[2] } do
					cyl(b, "DrainerPost", TOP_RACK_Y + 1.8, 2.4, px, (TOP_RACK_Y + 1.8) / 2, pz, Color3.fromRGB(205, 210, 218), Enum.Material.Metal)
				end
			end
		end
		-- Invisible fence round the whole basin area, up to a lid high overhead: nobody can climb onto the
		-- counter or anything above it, however they jump or fly.
		local fenceTop = if sink then 420 else 800
		local inv = { Transparency = 1, CastShadow = false }
		for _, side in { -1, 1 } do
			span(b, "SinkFence", side * (TUB_HALF_X + 0.5), side * (TUB_HALF_X + 10), TUB_HEIGHT, fenceTop, DOOR_Z_FAR - 14, TUB_Z_MAX + 10, Color3.new(1, 1, 1), nil, inv)
		end
		span(b, "SinkFence", -TUB_HALF_X, TUB_HALF_X, TUB_HEIGHT, fenceTop, TUB_Z_MAX + 0.5, TUB_Z_MAX + 10, Color3.new(1, 1, 1), nil, inv)
		-- Rim round the opening, level with the counter top: rolled porcelain, or a thick dark oak cap.
		local rim = if sink then Color3.fromRGB(250, 250, 248) else Color3.fromRGB(70, 50, 34)
		local rimMat = if sink then tubMat else Enum.Material.Wood
		span(b, "SinkRim", -TUB_HALF_X - 4, -TUB_HALF_X + 3, TUB_HEIGHT, COUNTER_TOP_Y, TUB_Z_MIN - 3, TUB_Z_MAX + 4, rim, rimMat)
		span(b, "SinkRim", TUB_HALF_X - 3, TUB_HALF_X + 4, TUB_HEIGHT, COUNTER_TOP_Y, TUB_Z_MIN - 3, TUB_Z_MAX + 4, rim, rimMat)
		span(b, "SinkRim", -TUB_HALF_X - 4, TUB_HALF_X + 4, TUB_HEIGHT, COUNTER_TOP_Y, TUB_Z_MAX - 3, TUB_Z_MAX + 4, rim, rimMat)
		if sink then
			span(b, "OverflowSlot", -12, 12, TUB_HEIGHT - 14, TUB_HEIGHT - 6, TUB_Z_MAX - 0.6, TUB_Z_MAX, Color3.fromRGB(120, 130, 140), nil, noCollide())
		end
	else
		span(b, "TubCeiling", -TUB_HALF_X - 2, TUB_HALF_X + 2, TUB_HEIGHT, TUB_HEIGHT + 2, TUB_Z_MIN, TUB_Z_MAX, steel, if trough then Enum.Material.WoodPlanks else Enum.Material.Metal)
		if trough then
			-- Iron hoops round the outside of the oak chest, iron corner straps and a banded lid.
			local iron = Color3.fromRGB(52, 50, 54)
			for _, y in { 16, 50, 84 } do
				for _, side in { -1, 1 } do
					span(b, "IronHoop", side * (TUB_HALF_X + 2), side * (TUB_HALF_X + 3.6), y - 3, y + 3, TUB_Z_MIN - 1, TUB_Z_MAX + 3.6, iron, Enum.Material.Metal, noCollide())
				end
				span(b, "IronHoop", -TUB_HALF_X - 3.6, TUB_HALF_X + 3.6, y - 3, y + 3, TUB_Z_MAX + 2, TUB_Z_MAX + 3.6, iron, Enum.Material.Metal, noCollide())
			end
			for _, side in { -1, 1 } do
				for _, z in { TUB_Z_MIN + 6, TUB_Z_MAX - 6 } do
					span(b, "IronStrap", side * (TUB_HALF_X + 2), side * (TUB_HALF_X + 4), 0, TUB_HEIGHT + 3, z - 3, z + 3, iron, Enum.Material.Metal, noCollide())
					span(b, "LidStrap", side * (TUB_HALF_X - 1), side * (TUB_HALF_X + 4), TUB_HEIGHT + 2, TUB_HEIGHT + 4.5, z - 4, z + 4, iron, Enum.Material.Metal, noCollide())
				end
			end
			for _, z in { TUB_Z_MIN + 20, (TUB_Z_MIN + TUB_Z_MAX) / 2, TUB_Z_MAX - 20 } do
				span(b, "LidBand", -TUB_HALF_X - 1, TUB_HALF_X + 1, TUB_HEIGHT + 2, TUB_HEIGHT + 4, z - 3, z + 3, iron, Enum.Material.Metal, noCollide())
			end
		end
	end

	-- Filter cup in the floor at the back, heating element loop.
	cyl(b, "Filter", 0.4, 14, 0, 0.2, 30, Color3.fromRGB(120, 125, 130), Enum.Material.DiamondPlate, noCollide())
	for _, x in { -40, 40 } do
		span(b, "Heater", x - 0.6, x + 0.6, 0.4, 1.4, -10, 50, Color3.fromRGB(90, 90, 95), Enum.Material.Metal, noCollide())
	end
	span(b, "Heater", -40, 40, 0.4, 1.4, 49.4, 50.6, Color3.fromRGB(90, 90, 95), Enum.Material.Metal, noCollide())

	-- Front frame around the opening, the machine's side panels, and the toe kick under the door.
	-- (Offsets of 0.2 keep every face off its neighbours' planes, so nothing flickers.)
	local frameColor = if trough then Color3.fromRGB(96, 66, 42) else K.Frame
	local frameMat = if trough then Enum.Material.Wood else Enum.Material.Metal
	if not sink then
		span(b, "FrameTop", -TUB_HALF_X - 6.2, TUB_HALF_X + 6.2, TUB_HEIGHT - 0.2, COUNTER_TOP_Y - 6, TUB_Z_MIN - 3.2, TUB_Z_MIN + 2, frameColor, frameMat)
	end
	for _, side in { -1, 1 } do
		span(b, "FrameSide", side * (TUB_HALF_X - 0.2), side * (TUB_HALF_X + 6), KITCHEN_FLOOR_Y, TUB_HEIGHT, TUB_Z_MIN - 3, TUB_Z_MIN + 2, frameColor, frameMat)
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
	-- The invisible walls and lid: as tall as the tub on a dishwasher, far taller over the open sink.
	local open = theme.Sink == true
	local oak = theme.Trough == true
	local wallTop = if open then 420 else TUB_HEIGHT
	-- Inner panel (the floor you stand on) and the outer skin below it.
	span(b, "DoorInner", -TUB_HALF_X, TUB_HALF_X, -1, 0, DOOR_Z_FAR, DOOR_Z_NEAR, theme.Tub, if theme.Trough then Enum.Material.WoodPlanks else Enum.Material.Metal)
	span(b, "DoorOuter", -TUB_HALF_X - 4, TUB_HALF_X + 4, -DOOR_THICK, -1, DOOR_Z_FAR - 6, DOOR_Z_NEAR, if theme.Sink then Color3.fromRGB(176, 130, 90) elseif oak then Color3.fromRGB(96, 66, 42) else K.Frame, if open or oak then Enum.Material.WoodPlanks else Enum.Material.Metal)
	if open or oak then
		-- Standing on four legs: wooden for the drainboard, stone piers for the drawbridge.
		for _, lx in { -TUB_HALF_X, TUB_HALF_X } do
			for _, lz in { DOOR_Z_FAR - 2, DOOR_Z_NEAR - 6 } do
				if theme.Sink then
					cyl(b, "DrainboardLeg", -DOOR_THICK - KITCHEN_FLOOR_Y, 8, lx, (-DOOR_THICK + KITCHEN_FLOOR_Y) / 2, lz, Color3.fromRGB(150, 104, 62), Enum.Material.Wood)
				else
					span(b, "BridgePier", lx - 7, lx + 7, KITCHEN_FLOOR_Y, -DOOR_THICK, lz - 7, lz + 7, Color3.fromRGB(128, 122, 116), Enum.Material.Cobblestone)
				end
			end
		end
		for gx = -TUB_HALF_X + 10, TUB_HALF_X - 10, 10 do
			span(b, "Groove", gx - 0.6, gx + 0.6, 0, 0.12, DOOR_Z_FAR + 4, DOOR_Z_NEAR - 4, if theme.Sink then Color3.fromRGB(170, 178, 186) else Color3.fromRGB(60, 40, 26), nil, noCollide())
		end
		if theme.Trough then
			-- Drawbridge: iron cross-bands and studs, and an iron torch stand at each side of the far end.
			local iron = Color3.fromRGB(52, 50, 54)
			for z = DOOR_Z_FAR + 12, DOOR_Z_NEAR - 8, 20 do
				span(b, "BridgeBand", -TUB_HALF_X, TUB_HALF_X, 0, 0.18, z - 1.5, z + 1.5, iron, Enum.Material.Metal, noCollide())
			end
			for _, tx in { -TUB_HALF_X - 10, TUB_HALF_X + 10 } do
				cyl(b, "TorchStand", 80, 4, tx, 40, DOOR_Z_FAR + 14, iron, Enum.Material.Metal, noCollide())
				cyl(b, "TorchBowl", 6, 14, tx, 82, DOOR_Z_FAR + 14, iron, Enum.Material.Metal, noCollide())
				local flame = box(b, "TorchFire", Vector3.new(9, 16, 9), tx, 92, DOOR_Z_FAR + 14, Color3.fromRGB(255, 160, 60), Enum.Material.Neon, noCollide())
				flame.Shape = Enum.PartType.Ball
				local fl = Instance.new("PointLight")
				fl.Color = Color3.fromRGB(255, 170, 90)
				fl.Brightness = 1.4
				fl.Range = 55
				fl.Parent = flame
			end
		end
	end
	-- Raised edges down the sides of the inner panel.
	for _, side in { -1, 1 } do
		span(b, "DoorEdge", side * (TUB_HALF_X - 2), side * TUB_HALF_X, 0, 2, DOOR_Z_FAR, DOOR_Z_NEAR, theme.Metal, Enum.Material.Metal)
		-- Invisible safety wall so nobody walks off the side.
		-- Invisible safety wall, as tall as the tub, so nobody can jump off the door.
		span(b, "SafetyWall", side * TUB_HALF_X, side * (TUB_HALF_X + 8), 0, wallTop, DOOR_Z_FAR - 14, DOOR_Z_NEAR, Color3.new(1, 1, 1), nil, { Transparency = 1, CastShadow = false })
	end
	span(b, "SafetyWall", -TUB_HALF_X - 8, TUB_HALF_X + 8, 0, wallTop, DOOR_Z_FAR - 14, DOOR_Z_FAR - 6, Color3.new(1, 1, 1), nil, { Transparency = 1, CastShadow = false })
	-- A lid over the door area as well, level with the tub ceiling.
	span(b, "SafetyLid", -TUB_HALF_X - 8, TUB_HALF_X + 8, wallTop, wallTop + 8, DOOR_Z_FAR - 14, if open then TUB_Z_MAX + 10 else DOOR_Z_NEAR - 3.2, Color3.new(1, 1, 1), nil, { Transparency = 1, CastShadow = false })

	-- Control strip along the far edge (the top of the door when it's closed), with buttons.
	if open or oak then
		return
	end
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
		pad("BubbleLift", lift.from, lift.to, "Bubble Lift", TOP_RACK_Y)
	end
end

-- A real-looking sink drain: a chrome rim round a dark gap, a brushed steel strainer with a
-- centre hole, a ring of 6 holes and an outer ring of 12 (no spinning piece on top of it: a drain doesn't have one).
local function buildDrain(b: Builder, _theme): Vector3
	local x, z = DRAIN_POS.X, DRAIN_POS.Z
	local chrome = Color3.fromRGB(196, 202, 210)
	local steel = Color3.fromRGB(165, 172, 180)
	local hole = Color3.fromRGB(18, 20, 24)
	local rim = cyl(b, "DrainGrate", 0.5, 15, x, 0.25, z, chrome, Enum.Material.Metal)
	rim.Reflectance = 0.25
	cyl(b, "DrainGap", 0.1, 12.4, x, 0.53, z, Color3.fromRGB(40, 44, 50), Enum.Material.SmoothPlastic, noCollide())
	local plate = cyl(b, "DrainStrainer", 0.12, 10.6, x, 0.6, z, steel, Enum.Material.Metal, noCollide())
	plate.Reflectance = 0.15
	cyl(b, "DrainHole", 0.04, 1.5, x, 0.68, z, hole, Enum.Material.SmoothPlastic, noCollide())
	for i = 1, 6 do
		local a = math.rad(i * 60)
		cyl(b, "DrainHole", 0.04, 1.3, x + math.cos(a) * 2.3, 0.68, z + math.sin(a) * 2.3, hole, Enum.Material.SmoothPlastic, noCollide())
	end
	for i = 1, 12 do
		local a = math.rad(i * 30 + 15)
		cyl(b, "DrainHole", 0.04, 1.05, x + math.cos(a) * 4.1, 0.68, z + math.sin(a) * 4.1, hole, Enum.Material.SmoothPlastic, noCollide())
	end
	local post = box(b, "DrainSign", Vector3.new(0.6, 0.6, 0.6), DRAIN_POS.X, 1, DRAIN_POS.Z, Color3.new(1, 1, 1), nil, { Transparency = 1, CanCollide = false })
	sign(post, "DRAIN\nstand here to sell", 16, 5, 8, Color3.fromRGB(150, 230, 255))
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
	label.Font = Enum.Font.LuckiestGuy
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
-- left of the open door, facing the players. One shelf holding every tool, a price tag on the front
-- lip of each spot, a sign on top. Buy any tool in any order with the prompt.
local function buildShop(b: Builder, theme, levelIndex: number): Vector3
	local z0, z1 = SHOP_Z[1], SHOP_Z[2]
	local depth = 9
	local x0, x1 = SHOP_X - depth / 2, SHOP_X + depth / 2 -- x1 is the front, facing the players
	local toPlayers = b.origin.RightVector
	local chrome = Color3.fromRGB(215, 220, 228)
	-- One waist-high display shelf for a ~5 stud character, with the unit's top just above head height.
	local shelfYs = { 4 }
	local topY = 13.5
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
	guiText(headerGui, "Title", "TOOL SHOP  •  any tool, any order", UDim2.fromScale(0.03, 0.1), UDim2.fromScale(0.94, 0.8), Color3.new(1, 1, 1))

	-- Every tool you can buy stands on the waist-high shelf (easy to reach and read from the door).
	-- Spots run from the front of the unit to the back.
	local buyable = #Config.Tools - 1
	local gap = (z1 - z0) / buyable
	local spots = {}
	for k = 1, buyable do
		spots[k + 1] = { y = shelfYs[1], z = z1 - gap * (k - 0.5) }
	end
	for i = 2, #Config.Tools do
		local tool = Config.Tools[i]
		local spot = spots[i]
		if not spot then
			break
		end
		-- Pedestal and glow sit a hair above the see-through shelf board, and the glow's faces never
		-- share a plane with the board or pedestal (that used to flicker as you moved).
		local riser = 0.4
		local pedestal = cyl(b, "Pedestal", riser, 6.4, SHOP_X - 0.5, spot.y + 0.03 + riser / 2, spot.z, Color3.new(1, 1, 1), nil, noCollide())
		pedestal.Name = "ToolDisplay_" .. i
		cyl(b, "PedestalGlow", 0.12, 7, SHOP_X - 0.5, spot.y + 0.2, spot.z, tool.Color, Enum.Material.Neon, noCollide())
		local okModel, model = pcall(ToolModels.Build, i, TOOL_SCALE)
		if okModel and model then
			local basePos = worldPoint(b.origin, SHOP_X - 0.5, spot.y + 0.03 + riser, spot.z)
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
		guiText(card, "Price", Format.Short(cost) .. " coins", UDim2.fromScale(0.05, 0.5), UDim2.fromScale(0.9, 0.44), Color3.fromRGB(255, 210, 60))

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Buy"
		prompt.ObjectText = string.format("%s  (%s coins)", tool.Name, Format.Short(cost))
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

-- The plate slots in the order they are filled: scattered over the whole rack (not front to back), so a small load of
-- plates is spread out among empty slots instead of crowding the front. (Trays and boards fill from the other end.)
local function plateSlots(): { Slot }
	local all = {}
	for _, z in PLATE_Z do
		for _, x in PLATE_ROW_X do
			table.insert(all, { x = x, y = BOTTOM_RACK_Y, z = z })
		end
	end
	local slots = {}
	local n = #all
	for k = 0, n - 1 do
		table.insert(slots, all[(k * 11) % n + 1]) -- (11 and 28 share no factor: every slot is used once)
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

-- Trays share the plate rows, filling from the back (Plate + Tray must fit the 28 plate slots).
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
	Goblet = function()
		-- A goblet's cup is nearly as wide as the columns are apart (12), so they first take every other column, the second row
		-- shifted along (24 apart in a row, 18 corner to corner), and only the remaining ones fill the gaps.
		local slots, rest = {}, {}
		for zi, z in GLASS_Z do
			for xi, x in GLASS_X do
				local slot = { x = x, y = TOP_RACK_Y, z = z }
				table.insert(if (xi + zi) % 2 == 0 then slots else rest, slot)
			end
		end
		for _, slot in rest do
			table.insert(slots, slot)
		end
		return slots
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
	-- Pizza boards stand in the plate rows (from the back, around the trays); pizza cutters go in
	-- the cutlery basket's spare slots from the far end.
	Board = traySlots,
	Cutter = function()
		-- A cutter's wheel is 8 across and the basket's columns are 5 apart, so two in neighbouring columns of one row
		-- overlapped. They take every other column (10 apart; the next row is shifted along), from the far end.
		local slots = {}
		local row = 0
		for k = #BASKET_Z, 1, -1 do
			local xs = if row % 2 == 0 then { BASKET_X[4], BASKET_X[2] } else { BASKET_X[3], BASKET_X[1] }
			for _, x in xs do
				table.insert(slots, { x = x, y = BOTTOM_RACK_Y + 0.6, z = BASKET_Z[k] })
			end
			row += 1
		end
		return slots
	end,
}

-- The CFrame DishFactory builds a dish at: contact point + orientation for that kind.
local function dishFrame(origin: CFrame, kind: string, slot: Slot, rng: Random): CFrame
	local toDoor = -origin.LookVector
	if kind == "Plate" or kind == "Tray" or kind == "Board" then
		-- Plates face the door, with a tiny random lean so the rows don't look copy-pasted.
		return footprint(origin, slot.x, slot.y, slot.z, toDoor) * CFrame.Angles(math.rad(rng:NextNumber(-4, 4)), 0, 0)
	elseif kind == "Bowl" then
		-- Lean the opening toward the door so the inside is visible and reachable.
		local r = DishFactory.Size("Bowl").Diameter / 2
		local lift = r * (1 - math.cos(BOWL_TILT)) + 0.2
		return footprint(origin, slot.x, slot.y + lift, slot.z) * CFrame.Angles(BOWL_TILT, 0, 0)
	elseif kind == "Pot" then
		-- (the handles point front and back, not whichever way the dice said: sideways they stuck out into the pan beside it)
		return footprint(origin, slot.x, slot.y, slot.z, toDoor) * CFrame.Angles(0, math.pi / 2, 0)
	elseif kind == "Pan" then
		local r = DishFactory.Size("Pan").Diameter / 2
		local lift = r * math.sin(PAN_TILT) + 0.2
		-- Spin about the pan's own axis so the handle points up and back, away from the pots.
		return footprint(origin, slot.x, slot.y + lift, slot.z) * CFrame.Angles(PAN_TILT, 0, 0) * CFrame.Angles(0, math.pi / 2, 0)
	elseif kind == "Fork" or kind == "Knife" or kind == "Spoon" or kind == "Cutter" then
		return footprint(origin, slot.x, slot.y, slot.z, toDoor) * CFrame.Angles(0, math.rad(rng:NextNumber(-12, 12)), math.rad(rng:NextNumber(-6, 6))) -- (turned a little, not enough for neighbouring ones to cross)
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
	-- A grid, four to a row: the Backyard's mountains reach well past its own patio, so neighbours
	-- are far apart (x by ArenaSpacing.X, the second row by ArenaSpacing.Z).
	local w = Config.World
	local col, row = (slot - 1) % 4, (slot - 1) // 4
	local pos = w.ArenaRowStart + Vector3.new(w.ArenaSpacing.X * col, 0, w.ArenaSpacing.Z * row)
	return CFrame.new(pos)
end

function ArenaBuilder.Build(slot: number, levelIndex: number, options: { GrimeScale: number, GoldenChance: number, HpScale: number? }): any
	assert(type(slot) == "number", "ArenaBuilder.Build: slot must be a number")
	local level = Config.GetLevel(levelIndex)
	-- The dishwasher is the same machine in every level (one steel tub, white racks, blue glow);
	-- only the room around it changes. The level's own theme still colours the dishes.
	local dishTheme = level.Theme
	local theme = setmetatable({
		Tub = Color3.fromRGB(172, 178, 187),
		Rack = Color3.fromRGB(235, 240, 245),
		Metal = Color3.fromRGB(190, 195, 200),
		Accent = Color3.fromRGB(80, 170, 255),
		Light = Color3.fromRGB(215, 235, 255),
		Sink = false,
	}, { __index = dishTheme }) :: any
	if levelIndex == 3 then
		-- The Royal Banquet's "machine" is an olden-day oak wash trough with iron racks.
		theme.Tub = Color3.fromRGB(112, 78, 50)
		theme.Rack = Color3.fromRGB(58, 56, 62)
		theme.Metal = Color3.fromRGB(70, 68, 74)
		theme.Accent = Color3.fromRGB(255, 205, 90)
		theme.Light = Color3.fromRGB(255, 220, 160)
		theme.Trough = true
	end
	if levelIndex == 2 then
		-- The Backyard's basin is a white porcelain sink.
		theme.Tub = Color3.fromRGB(238, 240, 242)
		theme.Rack = Color3.fromRGB(205, 215, 225)
		theme.Sink = true
	end
	-- The Backyard (level 2) is a shallow sink in a low outdoor counter; the others are full dishwashers.
	ROOM_HALF_X = if levelIndex == 3 then 780 else 420
	ROOM_Z_FRONT = if levelIndex == 3 then -1000 else -520
	ROOM_HEIGHT = if levelIndex == 3 then 860 else 520
	TUB_HEIGHT = if levelIndex == 2 then 34 else 100
	COUNTER_TOP_Y = if levelIndex == 2 then 40 else 112
	local origin = ArenaBuilder.SlotOrigin(slot)
	local rng = Random.new()
	local grimeScale = (options and options.GrimeScale) or 1
	local hpScale = (options and (options :: any).HpScale) or 1
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
	local takenSlots: { [string]: boolean } = {} -- slots already holding a dish (kinds can share rows)
	local nextId = 0
	local totalGrime = 0
	for _, kind in Config.DishKinds do
		local wantCount = level.Dishes[kind] or 0
		local slotsFn = KIND_SLOTS[kind]
		if wantCount > 0 and slotsFn then
			local spotsPerDish = math.max(1, math.floor((level.Spots[kind] or 1) * grimeScale + 0.5))
			local slots = {}
			for _, candidate in slotsFn() do
				local key = candidate.x .. "," .. candidate.y .. "," .. candidate.z
				if not takenSlots[key] then
					table.insert(slots, candidate)
				end
			end
			if wantCount > #slots then
				warn(string.format("[ArenaBuilder] Only %d slots for %d %s; filling what fits", #slots, wantCount, kind))
			end
			for i = 1, math.min(wantCount, #slots) do
				takenSlots[slots[i].x .. "," .. slots[i].y .. "," .. slots[i].z] = true
				local cf = dishFrame(origin, kind, slots[i], rng)
				local dish = DishFactory.BuildDish(kind, cf, dishTheme, rng)
				dish.Parent = dishesFolder

				nextId += 1
				local grime = DishFactory.ApplyGrime(dish, nextId, spotsPerDish, levelIndex, rng, goldenChance, grimeFolder, hpScale)
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
	model:SetAttribute("Origin", origin.Position) -- where the room is (LevelNPCs puts the giants in it)
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
