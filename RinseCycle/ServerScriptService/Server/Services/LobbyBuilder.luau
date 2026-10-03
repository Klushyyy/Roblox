-- LobbyBuilder: builds the entire lobby world at boot. Nothing here is an uploaded asset: every part
-- is a primitive. The layout is deliberately compact (you can cross it in a few seconds):
--
--                         [ giant dishwasher building + title ]
--        [Soap Shop]         [egg]  [egg]  [egg]            [Pet Stand]
--   (pad 1)            [Fastest]  [How to Play]  [Dishes]            (pad 4)
--   (pad 2)                                                          (pad 5)
--   (pad 3)                        ( spawn )                         (pad 6)
--
-- A tiled plaza (floor top at Y = 0.2) sits on a lawn, ringed by a white picket fence with invisible
-- walls behind it. Party pads are flat circles with a world-sized sign ("0/4 / Touch to create a
-- party"), so signs never fill the screen or cover menus.
--
-- Build() is the only entry point that creates anything; GetLobby()/GetSpawnCFrame() just read back
-- what was built. No server-side dependencies (see DESIGN.md's dependency graph).

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local LobbyBuilder = {}

----------------------------------------------------------------------------------------------------
-- Types (mirrors DESIGN.md section 5)
----------------------------------------------------------------------------------------------------
export type PadGui = { Count: TextLabel, Title: TextLabel, Status: TextLabel, Privacy: TextLabel }
export type PadInfo = {
	Id: number,
	Model: Model,
	Zone: BasePart,
	Floor: BasePart,
	Inside: CFrame,
	Exit: CFrame,
	Barriers: { BasePart },
	Gui: PadGui,
}
export type BoardPage = { Title: TextLabel, List: ScrollingFrame }
-- Pages: one per level on a paged board (the Fastest Clean board); each client flips them locally
-- with the arrows (tag "BoardArrow"), so nobody changes the page for anyone else.
export type BoardInfo = { Part: BasePart, Title: TextLabel, List: ScrollingFrame, Pages: { BoardPage }? }
export type Lobby = {
	Model: Model,
	Pads: { PadInfo },
	Boards: { Times: BoardInfo, Dishes: BoardInfo },
}

----------------------------------------------------------------------------------------------------
-- Layout constants
----------------------------------------------------------------------------------------------------
local ORIGIN = Config.World.LobbyOrigin

local PLAZA_X = 96 -- plaza spans X -96..96
local PLAZA_Z0, PLAZA_Z1 = -100, 64
local FLOOR_Y = 0.2 -- top of the plaza tiles
local FENCE_MARGIN = 3

local SPAWN = Vector3.new(0, 0, 36)

local PAD_COUNT = Config.Party.PadCount
local PAD_RADIUS = 9
local PAD_X = 60
local PAD_Z = { -34, -6, 22 }
local PAD_WALL_HEIGHT = 8

local HATCHERY_Z = -76 -- front face of the dishwasher building (it faces +Z, toward the spawn)
local EGG_Z = -66
local SHOP_X = -40
local PETSTAND_X = 40

-- Colors
local WOOD_A = Color3.fromRGB(196, 146, 98) -- table-top planks
local WOOD_B = Color3.fromRGB(184, 134, 88)
local WOOD_DARK = Color3.fromRGB(128, 86, 56)
local CLOTH_RED = Color3.fromRGB(214, 70, 72)
local CLOTH_WHITE = Color3.fromRGB(250, 246, 238)
local ROOM_WALL = Color3.fromRGB(236, 222, 196)
local ROOM_FLOOR = Color3.fromRGB(150, 104, 70)
local LOW = Enum.Material.SmoothPlastic -- the lobby is flat-shaded, low-poly style

local function shadeColor(c: Color3, f: number): Color3
	return Color3.new(c.R * f, c.G * f, c.B * f)
end

-- The plaza is the top of a giant dining table; the room around it (floor far below).
local TABLE_MARGIN = 16 -- table top overhang past the plaza
local ROOM_FLOOR_Y = -130
local ROOM_X = 420
local ROOM_Z0, ROOM_Z1 = -560, 400
local ROOM_TOP = 330
local NAVY = Color3.fromRGB(18, 55, 100)

----------------------------------------------------------------------------------------------------
-- Build bookkeeping: yield every ~200 parts so the server never hitches.
----------------------------------------------------------------------------------------------------
local lobby: Lobby? = nil
local partsBuilt = 0

local function maybeYield()
	partsBuilt += 1
	if partsBuilt % 200 == 0 then
		task.wait()
	end
end

-- Creates a BasePart (or SpawnLocation), applies props, parents last, and counts toward the budget.
local function mkPart(className: string, props: { [string]: any }, parent: Instance): BasePart
	local inst = Instance.new(className) :: BasePart
	inst.Anchored = true
	if props.CanCollide == nil then
		inst.CanCollide = true
	end
	if props.CanTouch == nil then
		inst.CanTouch = false
	end
	inst.TopSurface = Enum.SurfaceType.Smooth
	inst.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(inst :: any)[k] = v
	end
	-- Solid, visible scenery is queryable so the camera bumps into it instead of clipping through.
	if props.CanQuery == nil then
		inst.CanQuery = inst.CanCollide and inst.Transparency < 0.25
	end
	inst.Parent = parent
	maybeYield()
	return inst :: BasePart
end

-- Non-part instances (GUIs, lights, particles, models, folders...).
local function mk(className: string, props: { [string]: any }?, parent: Instance?): Instance
	local inst = Instance.new(className)
	if props then
		for k, v in props do
			(inst :: any)[k] = v
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

local function at(x: number, y: number, z: number): CFrame
	return CFrame.new(ORIGIN.X + x, ORIGIN.Y + y, ORIGIN.Z + z)
end

-- Upright cylinder (axis = Y).
local function upright(x: number, y: number, z: number): CFrame
	return at(x, y, z) * CFrame.Angles(0, 0, math.rad(90))
end

local function decor(props: { [string]: any }): { [string]: any }
	props.CanCollide = false
	props.CastShadow = if props.CastShadow == nil then true else props.CastShadow
	return props
end

-- A world-sized floating sign (scales with distance like a real object; never fills the screen).
-- It hangs off its own unrotated, invisible anchor part placed `offsetY` above `parent`: cylinders
-- are rotated 90 degrees internally, and a BillboardGui's offset follows that rotation, which is
-- what used to push signs sideways into the floor.
local function worldSign(parent: BasePart, text: string, width: number, height: number, offsetY: number, color: Color3?): TextLabel
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
	local gui = mk("BillboardGui", {
		Name = "Sign",
		Size = UDim2.fromScale(width, height),
		LightInfluence = 0,
		MaxDistance = 140,
		AlwaysOnTop = false,
	}, anchor)
	local label = mk("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = text,
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = color or Color3.new(1, 1, 1),
	}, gui) :: TextLabel
	mk("UIStroke", { Thickness = 3, Color = Color3.fromRGB(12, 30, 60) }, label)
	return label
end

----------------------------------------------------------------------------------------------------
-- The dining room around the table: panelling, curtains, pictures, a fireplace, a bookcase, a sofa,
-- ceiling beams and plants. Everything that meets a wall or the floor overlaps into it (never a
-- face flush with another face), so nothing z-fights.
----------------------------------------------------------------------------------------------------
local function buildHouseDetail(parent: Instance, box: (string, number, number, number, number, number, number, Color3, { [string]: any }?) -> BasePart)
	local fy = ROOM_FLOOR_Y
	local white = Color3.fromRGB(250, 248, 242)
	local panel = Color3.fromRGB(222, 206, 178)
	local trim = Color3.fromRGB(244, 238, 226)
	local nc = { CanCollide = false, CastShadow = false }
	local winY0, winY1 = fy + 110, fy + 380
	local IN = 2 -- walls are 4 thick, centred on the room edge: inner faces are 2 in

	-- Floorboards: slightly darker seams (the rug covers the middle).
	for x = -ROOM_X + 40, ROOM_X - 40, 40 do
		box("FloorSeam", x - 0.6, x + 0.6, fy - 1, fy + 0.25, ROOM_Z0 + IN, ROOM_Z1 - IN, Color3.fromRGB(128, 86, 56), nc)
	end

	-- Window positions (the same maths as the walls): 3 per wall.
	local function spots(a0: number, a1: number): { number }
		local winW = 120
		local gap = (a1 - a0 - 3 * winW) / 4
		return { a0 + gap, a0 + 2 * gap + winW, a0 + 3 * gap + 2 * winW }
	end

	-- Along one wall. `along(a0, a1, y0, y1, d0, d1)` makes a box spanning a0..a1 along the wall,
	-- y0..y1 up, d0..d1 in from the wall's inner face.
	local function dress(along: (string, number, number, number, number, number, number, Color3, { [string]: any }?) -> (), a0: number, a1: number)
		-- wainscot (dado) panelling with a chair rail and raised panels
		along("Wainscot", a0, a1, fy + 6, fy + 100, -0.5, 1.5, panel)
		along("ChairRail", a0 + 0.3, a1 - 0.3, fy + 98, fy + 105, -0.8, 3, trim)
		local n = math.floor((a1 - a0) / 60)
		local step = (a1 - a0) / n
		for k = 0, n - 1 do
			local c = a0 + step * (k + 0.5)
			along("Panel", c - step / 2 + 7, c + step / 2 - 7, fy + 20, fy + 88, 1, 2.2, Color3.fromRGB(232, 218, 192))
		end
		-- crown moulding under the ceiling
		along("Crown", a0 + 0.6, a1 - 0.6, ROOM_TOP - 12, ROOM_TOP + 1, -1.1, 4, trim)
		-- curtains and rods at each window
		for _, w0 in spots(a0, a1) do
			local w1 = w0 + 120
			along("CurtainRod", w0 - 40, w1 + 40, winY1 + 16, winY1 + 20, 8, 12, Color3.fromRGB(150, 110, 60), nc)
			for _, e in { { w0 - 36, w0 - 4 }, { w1 + 4, w1 + 36 } } do
				along("Curtain", e[1], e[2], winY0 - 30, winY1 + 16, 6, 12, Color3.fromRGB(176, 60, 64), nc)
				along("CurtainTie", e[1] - 1, e[2] + 1, winY0 + 60, winY0 + 68, 5, 13, Color3.fromRGB(236, 196, 96), nc)
			end
		end
	end
	-- back and front walls (along X)
	for _, zw in { ROOM_Z0, ROOM_Z1 } do
		local inward = if zw < 0 then 1 else -1
		local face = zw + inward * IN
		dress(function(name, a0, a1, y0, y1, d0, d1, color, extra)
			box(name, a0, a1, y0, y1, face + inward * d0, face + inward * d1, color, extra)
		end, -ROOM_X + IN, ROOM_X - IN)
	end
	-- side walls (along Z)
	for _, xw in { -ROOM_X, ROOM_X } do
		local inward = if xw < 0 then 1 else -1
		local face = xw + inward * IN
		dress(function(name, a0, a1, y0, y1, d0, d1, color, extra)
			box(name, face + inward * d0, face + inward * d1, y0, y1, a0, a1, color, extra)
		end, ROOM_Z0 + IN, ROOM_Z1 - IN)
	end

	-- Pictures between the windows on the back wall (frame, mat, painting: each proud of the last).
	local backFace = ROOM_Z0 + IN
	local paintings = {
		{ -120, Color3.fromRGB(90, 150, 210), Color3.fromRGB(120, 190, 110) }, -- hills
		{ 120, Color3.fromRGB(250, 190, 110), Color3.fromRGB(230, 120, 90) }, -- sunset
	}
	for _, pnt in paintings do
		local cx = pnt[1]
		box("PictureFrame", cx - 40, cx + 40, fy + 190, fy + 290, backFace - 0.5, backFace + 3, Color3.fromRGB(160, 116, 60))
		box("PictureMat", cx - 33, cx + 33, fy + 197, fy + 283, backFace + 2, backFace + 3.6, white)
		box("PictureSky", cx - 28, cx + 28, fy + 230, fy + 278, backFace + 3, backFace + 4.2, pnt[2])
		box("PictureLand", cx - 28, cx + 28, fy + 202, fy + 231, backFace + 3, backFace + 4.4, pnt[3])
	end

	-- Fireplace on the left wall, between the first two windows.
	local lf = -ROOM_X + IN
	local fz0, fz1 = -275, -155
	box("ChimneyBreast", lf - 1.4, lf + 30, fy - 0.6, ROOM_TOP + 1.3, fz0, fz1, Color3.fromRGB(200, 120, 96))
	box("Hearth", lf + 28.4, lf + 60, fy - 1, fy + 6, fz0 - 10, fz1 + 10, Color3.fromRGB(120, 120, 128))
	box("FireSurround", lf + 29, lf + 40, fy + 4, fy + 120, fz0 - 6, fz1 + 6, white)
	box("Mantel", lf + 28, lf + 50, fy + 118, fy + 128, fz0 - 14, fz1 + 14, Color3.fromRGB(150, 104, 70))
	box("Firebox", lf + 36, lf + 41, fy + 6, fy + 80, fz0 + 18, fz1 - 18, Color3.fromRGB(34, 30, 30))
	for i, c in { Color3.fromRGB(255, 150, 40), Color3.fromRGB(255, 210, 90) } do
		local flame = box("Flame", lf + 41.5 - i, lf + 43.5 - i, fy + 8, fy + 40 - i * 8, fz0 + 34 + i * 8, fz1 - 34 - i * 8, c, { CanCollide = false, CastShadow = false, Material = Enum.Material.Neon })
		if i == 1 then
			mk("PointLight", { Range = 50, Brightness = 1.2, Color = Color3.fromRGB(255, 170, 90), Shadows = false }, flame)
		end
	end
	box("Log", lf + 41, lf + 49, fy + 6, fy + 14, fz0 + 26, fz1 - 26, Color3.fromRGB(110, 70, 40))
	-- a clock and two candlesticks on the mantel
	box("MantelClock", lf + 32, lf + 46, fy + 128, fy + 158, -222, -208, Color3.fromRGB(120, 80, 50))
	box("ClockFace", lf + 46, lf + 47, fy + 134, fy + 152, -220, -210, white)
	for _, cz in { fz0 + 4, fz1 - 4 } do
		box("Candlestick", lf + 36, lf + 42, fy + 128, fy + 134, cz - 3, cz + 3, Color3.fromRGB(236, 196, 96))
		box("Candle", lf + 37.5, lf + 40.5, fy + 134, fy + 150, cz - 1.5, cz + 1.5, white)
	end

	-- Bookcase on the right wall, between the first two windows.
	local rf = ROOM_X - IN
	local bz0, bz1 = -270, -160
	local wood = Color3.fromRGB(120, 80, 50)
	box("Bookcase", rf - 40, rf + 1.3, fy - 0.4, fy + 250, bz0, bz1, wood)
	local bookColors = { Color3.fromRGB(200, 60, 60), Color3.fromRGB(60, 110, 190), Color3.fromRGB(240, 200, 80), Color3.fromRGB(80, 160, 100), Color3.fromRGB(150, 90, 170), Color3.fromRGB(230, 130, 60) }
	for shelf = 0, 4 do
		local y0 = fy + 14 + shelf * 46
		box("BookShelfBack", rf - 38, rf - 36, y0, y0 + 40, bz0 + 6, bz1 - 6, Color3.fromRGB(90, 60, 38))
		local z = bz0 + 8
		local k = shelf * 3
		while z < bz1 - 14 do
			k += 1
			local thick = 5 + (k * 7) % 5
			local tall = 26 + (k * 11) % 12
			box("Book", rf - 44, rf - 36.5, y0, y0 + tall, z, z + thick, bookColors[(k % #bookColors) + 1])
			z += thick + 0.6
		end
	end

	-- A sofa by the front wall, facing the table, with cushions.
	local sz0 = ROOM_Z1 - IN - 64
	local sofa = Color3.fromRGB(90, 130, 110)
	box("SofaBase", -130, 130, fy, fy + 42, sz0, sz0 + 60, sofa)
	box("SofaBack", -130, 130, fy + 40, fy + 100, sz0 + 42, sz0 + 61.4, sofa)
	for _, sx in { -1, 1 } do
		box("SofaArm", sx * 130 - 12, sx * 130 + 12, fy, fy + 66, sz0 - 2, sz0 + 62, Color3.fromRGB(80, 118, 100))
	end
	for i = -1, 1 do
		box("SofaCushion", i * 80 - 38, i * 80 + 38, fy + 41, fy + 52, sz0 + 2, sz0 + 42, Color3.fromRGB(110, 152, 130))
	end
	box("Pillow", -100, -70, fy + 50, fy + 78, sz0 + 32, sz0 + 41.2, Color3.fromRGB(236, 196, 96))
	box("Pillow", 70, 100, fy + 50, fy + 78, sz0 + 32, sz0 + 41.2, Color3.fromRGB(200, 90, 90))

	-- Ceiling beams (they sink into the ceiling a little).
	for _, bz in { -330, -80, 170 } do
		box("CeilingBeam", -ROOM_X + IN + 1.5, ROOM_X - IN - 1.5, ROOM_TOP - 14, ROOM_TOP + 1.7, bz - 9, bz + 9, Color3.fromRGB(150, 104, 70))
	end

	-- Potted plants in the corners.
	for _, c in { { -370, -510 }, { 370, -510 }, { -370, 350 }, { 370, 350 } } do
		local px, pz = c[1], c[2]
		box("PlantPot", px - 18, px + 18, fy, fy + 40, pz - 18, pz + 18, Color3.fromRGB(190, 110, 70))
		box("PlantSoil", px - 15, px + 15, fy + 38, fy + 40.6, pz - 15, pz + 15, Color3.fromRGB(80, 56, 40))
		for i, leaf in { { 0, 70, 0, 44 }, { -14, 56, 8, 30 }, { 14, 60, -8, 30 }, { 4, 92, 4, 28 } } do
			mkPart("Part", {
				Name = "PlantLeaves",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(leaf[4], leaf[4], leaf[4]),
				CFrame = at(px + leaf[1], fy + leaf[2], pz + leaf[3]),
				Color = if i % 2 == 0 then Color3.fromRGB(70, 150, 80) else Color3.fromRGB(90, 170, 90),
				Material = LOW,
				CanCollide = false,
			}, parent)
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Ground: the plaza is the top of a giant wooden dining table (planks, a checked runner down the
-- middle), with invisible walls at its edges. The table stands in a dining room (buildRoom).
----------------------------------------------------------------------------------------------------
local function buildGround(parent: Instance)
	-- Safety floor just under the table top (invisible), so nothing ever falls through.
	mkPart("Part", {
		Name = "SafetyFloor",
		Size = Vector3.new(PLAZA_X * 2 + TABLE_MARGIN * 2, 2, PLAZA_Z1 - PLAZA_Z0 + TABLE_MARGIN * 2),
		CFrame = at(0, -3, (PLAZA_Z0 + PLAZA_Z1) / 2),
		Transparency = 1,
		CastShadow = false,
	}, parent)

	-- Table top: planks running along X, alternating two wood tones, over a thick slab.
	local x0, x1 = -PLAZA_X - TABLE_MARGIN, PLAZA_X + TABLE_MARGIN
	local z0, z1 = PLAZA_Z0 - TABLE_MARGIN, PLAZA_Z1 + TABLE_MARGIN
	mkPart("Part", {
		Name = "TableSlab",
		Size = Vector3.new(x1 - x0, 6, z1 - z0),
		CFrame = at(0, -3.2, (z0 + z1) / 2),
		Color = WOOD_DARK,
		Material = LOW,
	}, parent)
	local plank = 14
	local i = 0
	for z = z0, z1 - 0.01, plank do
		local zEnd = math.min(z + plank, z1)
		mkPart("Part", {
			Name = "Plank",
			Size = Vector3.new(x1 - x0, 0.4, zEnd - z - 0.3),
			CFrame = at(0, FLOOR_Y - 0.2, (z + zEnd) / 2),
			Color = if i % 2 == 0 then WOOD_A else WOOD_B,
			Material = LOW,
		}, parent)
		i += 1
	end
	-- Low-poly chamfer along the table's edges (wedges sloping down and out).
	for _, side in { -1, 1 } do
		mkPart("Part", {
			Name = "Chamfer",
			Size = Vector3.new(x1 - x0, 2, 2),
			CFrame = at(0, -1, if side < 0 then z0 - 1 else z1 + 1) * CFrame.Angles(0, if side < 0 then 0 else math.pi, 0),
			Color = WOOD_DARK,
			Material = LOW,
		}, parent)
		mkPart("Part", {
			Name = "Chamfer",
			Size = Vector3.new(z1 - z0, 2, 2),
			CFrame = at(if side < 0 then x0 - 1 else x1 + 1, -1, (z0 + z1) / 2) * CFrame.Angles(0, if side < 0 then -math.pi / 2 else math.pi / 2, 0),
			Color = WOOD_DARK,
			Material = LOW,
		}, parent)
	end
	-- Checked runner (the path) from the spawn to the dishwasher building.
	local cell = 7
	local rz0, rz1 = HATCHERY_Z + 2, SPAWN.Z - 14
	local row = 0
	for z = rz0, rz1 - cell, cell do
		for col = 0, 1 do
			mkPart("Part", {
				Name = "Runner",
				Size = Vector3.new(cell, 0.1, cell),
				CFrame = at(-cell / 2 + col * cell, FLOOR_Y + 0.05, z + cell / 2),
				Color = if (row + col) % 2 == 0 then CLOTH_RED else CLOTH_WHITE,
				Material = LOW,
				CanCollide = false,
				CastShadow = false,
			}, parent)
		end
		row += 1
	end

	-- Invisible walls at the plaza edges (nobody falls off the table).
	local fx0, fx1 = -PLAZA_X - FENCE_MARGIN, PLAZA_X + FENCE_MARGIN
	local fz0, fz1 = PLAZA_Z0 - FENCE_MARGIN, PLAZA_Z1 + FENCE_MARGIN
	local h = 80
	local w = 4
	for _, spec in {
		{ Vector3.new(fx1 - fx0 + w * 2, h, w), at(0, h / 2, fz0 - w / 2) },
		{ Vector3.new(fx1 - fx0 + w * 2, h, w), at(0, h / 2, fz1 + w / 2) },
		{ Vector3.new(w, h, fz1 - fz0), at(fx0 - w / 2, h / 2, (fz0 + fz1) / 2) },
		{ Vector3.new(w, h, fz1 - fz0), at(fx1 + w / 2, h / 2, (fz0 + fz1) / 2) },
	} do
		mkPart("Part", { Name = "Barrier", Size = spec[1], CFrame = spec[2], Transparency = 1, CastShadow = false }, parent)
	end
end

-- The dining room around the table: legs down to a floor far below, giant chairs, a sideboard, a
-- pendant lamp, and walls with big windows looking out at the back garden (buildGarden).
-- Walls and ceiling cast no shadows, so daylight still fills the room.
local function buildRoom(parent: Instance)
	local fy = ROOM_FLOOR_Y
	local shadowless = { CastShadow = false }
	local function box(name: string, ax0: number, ax1: number, ay0: number, ay1: number, az0: number, az1: number, color: Color3, extra: { [string]: any }?)
		local props: { [string]: any } = {
			Name = name,
			Size = Vector3.new(math.abs(ax1 - ax0), math.abs(ay1 - ay0), math.abs(az1 - az0)),
			CFrame = at((ax0 + ax1) / 2, (ay0 + ay1) / 2, (az0 + az1) / 2),
			Color = color,
			Material = LOW,
		}
		if extra then
			for k, v in extra do
				props[k] = v
			end
		end
		return mkPart("Part", props, parent)
	end

	-- Table legs (chunky, low-poly: a square leg with a wider foot and a collar).
	local tx0, tx1 = -PLAZA_X - TABLE_MARGIN, PLAZA_X + TABLE_MARGIN
	local tz0, tz1 = PLAZA_Z0 - TABLE_MARGIN, PLAZA_Z1 + TABLE_MARGIN
	box("TableApron", tx0 + 6, tx1 - 6, -16, -6.2, tz0 + 6, tz1 - 6, WOOD_DARK)
	for _, lx in { tx0 + 14, tx1 - 14 } do
		for _, lz in { tz0 + 14, tz1 - 14 } do
			box("TableLeg", lx - 8, lx + 8, fy, -16, lz - 8, lz + 8, WOOD_DARK)
			box("LegCollar", lx - 10, lx + 10, -30, -24, lz - 10, lz + 10, WOOD_A)
			box("LegFoot", lx - 10, lx + 10, fy, fy + 8, lz - 10, lz + 10, WOOD_A)
		end
	end

	-- Floor, walls with windows, ceiling.
	box("RoomFloor", -ROOM_X, ROOM_X, fy - 4, fy, ROOM_Z0, ROOM_Z1, ROOM_FLOOR)
	box("Rug", -200, 200, fy, fy + 0.9, -330, 170, Color3.fromRGB(70, 110, 150), { CanCollide = false })
	box("RugBorder", -210, 210, fy - 0.1, fy + 0.5, -340, 180, Color3.fromRGB(240, 200, 110), { CanCollide = false })
	box("Ceiling", -ROOM_X, ROOM_X, ROOM_TOP, ROOM_TOP + 4, ROOM_Z0, ROOM_Z1, Color3.fromRGB(250, 246, 238), shadowless)

	local winY0, winY1 = fy + 110, fy + 380
	-- A wall along X at z (from x = -ROOM_X to ROOM_X) with `n` windows.
	local function wallX(z: number, n: number)
		local span = ROOM_X * 2
		local winW = 120
		local gap = (span - n * winW) / (n + 1)
		box("Wall", -ROOM_X, ROOM_X, fy, winY0, z - 2, z + 2, ROOM_WALL, shadowless)
		box("Wall", -ROOM_X, ROOM_X, winY1, ROOM_TOP, z - 2, z + 2, ROOM_WALL, shadowless)
		box("Skirting", -ROOM_X - 1, ROOM_X + 1, fy, fy + 10, z - 3, z + 3, Color3.fromRGB(255, 255, 255), shadowless)
		local x = -ROOM_X
		for k = 0, n do
			box("Wall", x, x + gap, winY0, winY1, z - 2, z + 2, ROOM_WALL, shadowless)
			x += gap
			if k < n then
				box("WindowSill", x - 6, x + winW + 6, winY0 - 6, winY0 + 0.4, z - 8, z + 8, Color3.fromRGB(255, 255, 255), shadowless)
				box("WindowBar", x + winW / 2 - 2, x + winW / 2 + 2, winY0 - 1, winY1 + 1, z - 1, z + 1, Color3.fromRGB(255, 255, 255), { CanCollide = false, CastShadow = false })
				box("WindowBar", x - 1, x + winW + 1, (winY0 + winY1) / 2 - 2, (winY0 + winY1) / 2 + 2, z - 1, z + 1, Color3.fromRGB(255, 255, 255), { CanCollide = false, CastShadow = false })
				box("WindowGlass", x, x + winW, winY0, winY1, z - 0.3, z + 0.3, Color3.fromRGB(200, 230, 255), { Transparency = 0.85, Material = Enum.Material.Glass, CastShadow = false })
				x += winW
			end
		end
	end
	local function wallZ(xw: number, n: number)
		local span = ROOM_Z1 - ROOM_Z0
		local winW = 120
		local gap = (span - n * winW) / (n + 1)
		box("Wall", xw - 2, xw + 2, fy, winY0, ROOM_Z0, ROOM_Z1, ROOM_WALL, shadowless)
		box("Wall", xw - 2, xw + 2, winY1, ROOM_TOP, ROOM_Z0, ROOM_Z1, ROOM_WALL, shadowless)
		box("Skirting", xw - 3, xw + 3, fy, fy + 10, ROOM_Z0 - 1, ROOM_Z1 + 1, Color3.fromRGB(255, 255, 255), shadowless)
		local z = ROOM_Z0
		for k = 0, n do
			box("Wall", xw - 2, xw + 2, winY0, winY1, z, z + gap, ROOM_WALL, shadowless)
			z += gap
			if k < n then
				box("WindowSill", xw - 8, xw + 8, winY0 - 6, winY0 + 0.4, z - 6, z + winW + 6, Color3.fromRGB(255, 255, 255), shadowless)
				box("WindowBar", xw - 1, xw + 1, winY0 - 1, winY1 + 1, z + winW / 2 - 2, z + winW / 2 + 2, Color3.fromRGB(255, 255, 255), { CanCollide = false, CastShadow = false })
				box("WindowBar", xw - 1, xw + 1, (winY0 + winY1) / 2 - 2, (winY0 + winY1) / 2 + 2, z - 1, z + winW + 1, Color3.fromRGB(255, 255, 255), { CanCollide = false, CastShadow = false })
				box("WindowGlass", xw - 0.3, xw + 0.3, winY0, winY1, z, z + winW, Color3.fromRGB(200, 230, 255), { Transparency = 0.85, Material = Enum.Material.Glass, CastShadow = false })
				z += winW
			end
		end
	end
	wallX(ROOM_Z0, 3)
	wallX(ROOM_Z1, 3)
	wallZ(-ROOM_X, 3)
	wallZ(ROOM_X, 3)

	-- Giant chairs around the table: seat below the table top, tall back rising above it.
	local function chair(cx: number, cz: number, faceX: number, faceZ: number)
		-- (faceX, faceZ): unit direction from the chair toward the table.
		local seatY = -48
		local half = 38
		mkPart("Part", { Name = "ChairSeat", Size = Vector3.new(half * 2, 8, half * 2), CFrame = at(cx, seatY, cz), Color = WOOD_A, Material = LOW }, parent)
		mkPart("Part", { Name = "ChairCushion", Size = Vector3.new(half * 2 - 10, 3, half * 2 - 10), CFrame = at(cx, seatY + 5.5, cz), Color = CLOTH_RED, Material = LOW }, parent)
		local bx, bz = cx - faceX * (half - 4), cz - faceZ * (half - 4)
		local sx = if faceX ~= 0 then 8 else half * 2
		local sz = if faceZ ~= 0 then 8 else half * 2
		mkPart("Part", { Name = "ChairBack", Size = Vector3.new(sx, 110, sz), CFrame = at(bx, seatY + 59, bz), Color = WOOD_A, Material = LOW }, parent)
		-- The rail overhangs the back a little (side-by-side chairs stay well apart now).
		mkPart("Part", { Name = "ChairTopRail", Size = Vector3.new(if faceX ~= 0 then sx + 4 else sx + 2, 10, if faceZ ~= 0 then sz + 4 else sz + 2), CFrame = at(bx, seatY + 116, bz), Color = WOOD_DARK, Material = LOW }, parent)
		for _, dx in { -half + 5, half - 5 } do
			for _, dz in { -half + 5, half - 5 } do
				mkPart("Part", { Name = "ChairLeg", Size = Vector3.new(7, seatY - 4 - fy, 7), CFrame = at(cx + dx, (fy + seatY - 4) / 2, cz + dz), Color = WOOD_DARK, Material = LOW }, parent)
			end
		end
	end
	for _, cz in { -68, 28 } do
		chair(tx0 - 52, cz, 1, 0)
		chair(tx1 + 52, cz, -1, 0)
	end
	chair(0, tz0 - 52, 0, 1)

	-- Sideboard against the back wall with a stack of plates and a vase.
	box("Sideboard", -150, 150, fy, fy + 90, ROOM_Z0 + 4, ROOM_Z0 + 60, WOOD_DARK)
	box("SideboardTop", -156, 156, fy + 90, fy + 96, ROOM_Z0 + 2, ROOM_Z0 + 64, WOOD_A)
	for i = -2, 2 do
		box("SideboardDoor", i * 58 - 26, i * 58 + 26, fy + 12, fy + 82, ROOM_Z0 + 60, ROOM_Z0 + 62, WOOD_A)
		box("SideboardKnob", i * 58 - 2, i * 58 + 2, fy + 48, fy + 54, ROOM_Z0 + 62, ROOM_Z0 + 64, Color3.fromRGB(240, 200, 110))
	end

	-- Pendant lamp over the table (hexagonal-ish shade from two boxes, glowing bulb).
	local lampY = 150
	box("LampCord", -1, 1, lampY + 20, ROOM_TOP, -19, -17, Color3.fromRGB(40, 40, 44), { CanCollide = false })
	for k = 0, 2 do
		mkPart("Part", {
			Name = "LampShade",
			Size = Vector3.new(60, 20, 26),
			CFrame = at(0, lampY + 10, -18) * CFrame.Angles(0, k * math.pi / 3, 0),
			Color = Color3.fromRGB(60, 120, 110),
			Material = LOW,
			CanCollide = false,
			CastShadow = false,
		}, parent)
	end
	local bulb = mkPart("Part", { Name = "LampBulb", Shape = Enum.PartType.Ball, Size = Vector3.new(16, 16, 16), CFrame = at(0, lampY - 2, -18), Color = Color3.fromRGB(255, 240, 200), Material = Enum.Material.Neon, CanCollide = false, CastShadow = false }, parent)
	mk("PointLight", { Range = 60, Brightness = 0.6, Color = Color3.fromRGB(255, 230, 190), Shadows = false }, bulb)

	buildHouseDetail(parent, box)
end

----------------------------------------------------------------------------------------------------
-- Spawn: built FIRST so a player who spawns mid-build has a floor.
----------------------------------------------------------------------------------------------------
local function buildSpawn(parent: Instance)
	-- A stepped round platform: navy base, marble top, the game's emblem on it, and four bubble
	-- lamps around the edge. No two faces share a plane.
	mkPart("Part", {
		Name = "SpawnBase",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.7, 28, 28),
		CFrame = upright(SPAWN.X, 0.45, SPAWN.Z),
		Color = Color3.fromRGB(38, 78, 128),
		Material = Enum.Material.SmoothPlastic,
	}, parent)
	mkPart("Part", {
		Name = "SpawnTop",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.5, 24, 24),
		CFrame = upright(SPAWN.X, 0.9, SPAWN.Z),
		Color = Color3.fromRGB(236, 240, 244),
		Material = Enum.Material.Marble,
	}, parent)
	local emblem = mkPart("Part", {
		Name = "SpawnEmblem",
		Size = Vector3.new(18, 0.05, 18),
		-- A Top-face SurfaceGui's "up" is the part's -X, so turn the part a quarter so the text reads
		-- left-to-right for someone who just spawned (facing -Z, camera behind them).
		CFrame = at(SPAWN.X, 1.2, SPAWN.Z) * CFrame.Angles(0, -math.pi / 2, 0),
		Transparency = 1,
		CanCollide = false,
		CastShadow = false,
	}, parent)
	local gui = mk("SurfaceGui", { Face = Enum.NormalId.Top, CanvasSize = Vector2.new(600, 600), LightInfluence = 0.3 }, emblem)
	local circle = mk("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.96, 0.96),
		BackgroundColor3 = Color3.fromRGB(120, 200, 250),
		BackgroundTransparency = 0.35,
	}, gui)
	mk("UICorner", { CornerRadius = UDim.new(0.5, 0) }, circle)
	mk("UIStroke", { Thickness = 10, Color = Color3.fromRGB(255, 255, 255) }, circle)
	local title = mk("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.8, 0.36),
		BackgroundTransparency = 1,
		Text = string.upper(Config.GameName),
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
	}, gui)
	mk("UIStroke", { Thickness = 6, Color = Color3.fromRGB(20, 60, 110) }, title)
	for i = 1, 4 do
		local a = (i - 0.5) / 4 * math.pi * 2
		local px, pz = SPAWN.X + math.cos(a) * 12.5, SPAWN.Z + math.sin(a) * 12.5
		mkPart("Part", { Name = "LampPost", Shape = Enum.PartType.Cylinder, Size = Vector3.new(3, 0.8, 0.8), CFrame = upright(px, 2.3, pz), Color = Color3.fromRGB(230, 234, 240), Material = Enum.Material.Metal }, parent)
		local bulb = mkPart("Part", decor({ Name = "Bubble", Shape = Enum.PartType.Ball, Size = Vector3.new(2, 2, 2), CFrame = at(px, 4.6, pz), Color = if i % 2 == 0 then Color3.fromRGB(150, 220, 255) else Color3.fromRGB(255, 170, 215), Material = Enum.Material.Neon, Transparency = 0.2 }), parent)
		mk("PointLight", { Range = 12, Brightness = 0.8, Color = bulb.Color }, bulb)
	end
	for i = 1, 4 do
		local angle = (i - 1) / 4 * math.pi * 2 + math.pi / 4
		local pos = Vector3.new(SPAWN.X + math.cos(angle) * 6, 1.8, SPAWN.Z + math.sin(angle) * 6)
		mkPart("SpawnLocation", {
			Name = "Spawn" .. i,
			Size = Vector3.new(5, 1, 5),
			CFrame = at(pos.X, pos.Y, pos.Z),
			Neutral = true,
			Duration = 0,
			Transparency = 1,
			CanCollide = false,
		}, parent)
	end
end

-- The back garden seen through the windows: a lawn level with the room floor, a paved patio, a
-- wooden fence all round, low-poly trees and hedges. All plain parts (no Terrain), so nothing can
-- ever pop up on the table, and nothing unrealistic (no mountains) sits on the horizon.
local function buildGarden(parent: Instance)
	local fy = ROOM_FLOOR_Y
	local GX0, GX1 = -ROOM_X - 260, ROOM_X + 260
	local GZ0, GZ1 = ROOM_Z0 - 260, ROOM_Z1 + 260
	local lawn = Color3.fromRGB(110, 170, 90)
	-- The lawn runs far past the fence so the horizon is always grass, never empty sky.
	mkPart("Part", { Name = "Lawn", Size = Vector3.new(4000, 4, 4000), CFrame = at(0, fy - 2.6, (GZ0 + GZ1) / 2), Color = lawn, Material = LOW, CastShadow = false }, parent)
	mkPart("Part", { Name = "Patio", Size = Vector3.new(360, 1, 120), CFrame = at(0, fy - 0.9, ROOM_Z1 + 64), Color = Color3.fromRGB(200, 190, 175), Material = LOW }, parent)

	-- Fence: posts every 30 studs with two rails, along all four sides.
	local fenceColor = Color3.fromRGB(176, 128, 86)
	local function run(x0: number, z0: number, x1: number, z1: number)
		local len = math.max(math.abs(x1 - x0), math.abs(z1 - z0))
		local alongX = math.abs(x1 - x0) > math.abs(z1 - z0)
		for _, y in { 22, 44 } do
			mkPart("Part", { Name = "FenceRail", Size = if alongX then Vector3.new(len, 5, 2) else Vector3.new(2, 5, len), CFrame = at((x0 + x1) / 2, fy + y, (z0 + z1) / 2), Color = fenceColor, Material = LOW, CastShadow = false }, parent)
		end
		local n = math.floor(len / 30)
		for i = 0, n do
			local t = i / n
			mkPart("Part", { Name = "FencePost", Size = Vector3.new(4, 56, 4), CFrame = at(x0 + (x1 - x0) * t, fy + 28, z0 + (z1 - z0) * t), Color = shadeColor(fenceColor, 0.85), Material = LOW, CastShadow = false }, parent)
		end
	end
	local fx0, fx1, fz0, fz1 = GX0 + 40, GX1 - 40, GZ0 + 40, GZ1 - 40
	run(fx0, fz0, fx1, fz0)
	run(fx0, fz1, fx1, fz1)
	run(fx0, fz0, fx0, fz1)
	run(fx1, fz0, fx1, fz1)

	-- Low-poly trees: a hexagonal trunk and a stack of turned, faceted canopy blocks.
	local rng = Random.new(21)
	local function treeAt(x: number, z: number, scale: number)
		local trunkH = 70 * scale
		local tr = 9 * scale
		local side = tr / math.sqrt(3)
		for k = 0, 2 do
			mkPart("Part", { Name = "TreeTrunk", Size = Vector3.new(side, trunkH, tr), CFrame = at(x, fy + trunkH / 2, z) * CFrame.Angles(0, k * math.pi / 3, 0), Color = Color3.fromRGB(120, 84, 56), Material = LOW, CastShadow = false }, parent)
		end
		local greens = { Color3.fromRGB(86, 150, 78), Color3.fromRGB(104, 168, 86), Color3.fromRGB(74, 136, 70) }
		for i = 0, 2 do
			local size = (64 - i * 14) * scale
			mkPart("Part", {
				Name = "TreeCanopy",
				Size = Vector3.new(size, size * 0.8, size),
				CFrame = at(x, fy + trunkH + (i * 26 - 4) * scale, z) * CFrame.Angles(math.rad(12 * (i % 2 == 0 and 1 or -1)), math.rad(rng:NextNumber(0, 90)), math.rad(8)),
				Color = greens[i + 1],
				Material = LOW,
				CastShadow = false,
			}, parent)
		end
	end
	for _ = 1, 22 do
		-- Pick a spot in the ring between the house walls and the fence.
		local x, z
		repeat
			x = rng:NextNumber(fx0 + 50, fx1 - 50)
			z = rng:NextNumber(fz0 + 50, fz1 - 50)
		until x < -ROOM_X - 70 or x > ROOM_X + 70 or z < ROOM_Z0 - 70 or z > ROOM_Z1 + 150
		treeAt(x, z, rng:NextNumber(0.8, 1.25))
	end
	-- A thicker tree line beyond the fence (neighbours' gardens), so the view out ends in trees.
	for i = 1, 40 do
		local ang = i / 40 * math.pi * 2 + rng:NextNumber(-0.05, 0.05)
		local rx, rz = (GX1 - GX0) / 2 + rng:NextNumber(40, 160), (GZ1 - GZ0) / 2 + rng:NextNumber(40, 160)
		treeAt(math.cos(ang) * rx, (GZ0 + GZ1) / 2 + math.sin(ang) * rz, rng:NextNumber(1.2, 1.8))
	end
	-- Hedges hugging the house walls.
	for _, spec in { { -ROOM_X - 20, ROOM_Z0, -ROOM_X - 20, ROOM_Z1 }, { ROOM_X + 20, ROOM_Z0, ROOM_X + 20, ROOM_Z1 } } do
		mkPart("Part", { Name = "Hedge", Size = Vector3.new(24, 40, math.abs(spec[4] - spec[2]) - 40), CFrame = at(spec[1], fy + 20, (spec[2] + spec[4]) / 2), Color = Color3.fromRGB(80, 142, 72), Material = LOW, CastShadow = false }, parent)
	end
end

----------------------------------------------------------------------------------------------------
-- Party pads: flat circles with a low see-through ring (it only blocks party members, so they stay
-- put while waiting) and a floating world-sized sign.
----------------------------------------------------------------------------------------------------
local function padPosition(id: number): (number, number)
	local side = if id <= 3 then -1 else 1
	local row = ((id - 1) % 3) + 1
	return side * PAD_X, PAD_Z[row]
end

local function buildPad(parent: Instance, id: number): PadInfo
	local cx, cz = padPosition(id)
	local model = mk("Model", { Name = "Pad" .. id }, parent) :: Model

	local floor = mkPart("Part", {
		Name = "Floor",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.4, PAD_RADIUS * 2, PAD_RADIUS * 2),
		CFrame = upright(cx, FLOOR_Y + 0.2, cz),
		Color = Color3.fromRGB(125, 195, 255),
		Material = Enum.Material.SmoothPlastic,
	}, model)
	-- White rim ring: wider than the floor but lower (top at +0.2 vs the floor's +0.4), so no two
	-- faces share a plane.
	mkPart("Part", {
		Name = "Rim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, PAD_RADIUS * 2 + 1.2, PAD_RADIUS * 2 + 1.2),
		CFrame = upright(cx, FLOOR_Y + 0.05, cz),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
	}, model)
	-- A dishwasher spray arm lying on the pad: a hub and two arms with nozzle dots, spun by the
	-- client (tag SpinY). It floats a hair above the floor and never touches another face.
	local spinner = mkPart("Part", {
		Name = "SprayArm",
		Size = Vector3.new(PAD_RADIUS * 1.7, 0.2, 1.6),
		CFrame = at(cx, FLOOR_Y + 0.55, cz),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CastShadow = false,
	}, model)
	spinner:SetAttribute("SpinSpeed", 1.2)
	CollectionService:AddTag(spinner, "SpinY")
	local cross = mkPart("Part", {
		Name = "SprayArm",
		Size = Vector3.new(1.6, 0.18, PAD_RADIUS * 1.7),
		CFrame = at(cx, FLOOR_Y + 0.54, cz),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CastShadow = false,
	}, model)
	cross:SetAttribute("SpinSpeed", 1.2)
	CollectionService:AddTag(cross, "SpinY")
	mkPart("Part", {
		Name = "SprayHub",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.5, 3, 3),
		CFrame = upright(cx, FLOOR_Y + 0.6, cz),
		Color = Color3.fromRGB(120, 200, 250),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CastShadow = false,
	}, model)

	-- A ring of glass panels; CollisionGroup PadBarrier collides only with PartyMember.
	local barriers: { BasePart } = {}
	local panels = 14
	local panelW = 2 * math.pi * (PAD_RADIUS + 0.3) / panels + 0.2
	for i = 1, panels do
		local a = (i - 0.5) / panels * math.pi * 2
		local px, pz = cx + math.cos(a) * (PAD_RADIUS + 0.3), cz + math.sin(a) * (PAD_RADIUS + 0.3)
		local b = mkPart("Part", {
			Name = "Barrier",
			Size = Vector3.new(panelW, PAD_WALL_HEIGHT, 0.4),
			CFrame = CFrame.lookAt(at(px, PAD_WALL_HEIGHT / 2, pz).Position, at(cx, PAD_WALL_HEIGHT / 2, cz).Position),
			Color = Color3.fromRGB(200, 235, 255),
			Material = Enum.Material.Glass,
			Transparency = 0.85,
			CastShadow = false,
			CollisionGroup = "PadBarrier",
		}, model)
		table.insert(barriers, b)
	end
	-- A genuinely invisible, much taller ring behind the glass so party members can't jump out
	-- (PadBarrier only blocks party members; everyone else walks straight through).
	local tallWalls = 18
	for i = 1, tallWalls do
		local a = (i - 0.5) / tallWalls * math.pi * 2
		local px, pz = cx + math.cos(a) * (PAD_RADIUS + 0.9), cz + math.sin(a) * (PAD_RADIUS + 0.9)
		local wallW = 2 * math.pi * (PAD_RADIUS + 0.9) / tallWalls + 0.4
		local b = mkPart("Part", {
			Name = "InvisibleWall",
			Size = Vector3.new(wallW, 60, 0.6),
			CFrame = CFrame.lookAt(at(px, 30, pz).Position, at(cx, 30, cz).Position),
			Transparency = 1,
			CastShadow = false,
			CollisionGroup = "PadBarrier",
		}, model)
		table.insert(barriers, b)
	end
	-- And a lid, so nobody escapes by jumping straight up either.
	table.insert(barriers, mkPart("Part", {
		Name = "InvisibleLid",
		Size = Vector3.new(PAD_RADIUS * 2 + 3, 1, PAD_RADIUS * 2 + 3),
		CFrame = at(cx, 60.5, cz),
		Transparency = 1,
		CastShadow = false,
		CollisionGroup = "PadBarrier",
	}, model))

	-- The box a player's root must be in to count as "on the pad" (inscribed in the circle).
	local zoneHalf = PAD_RADIUS * 0.72
	local zone = mkPart("Part", {
		Name = "Zone",
		Size = Vector3.new(zoneHalf * 2, 12, zoneHalf * 2),
		CFrame = at(cx, 6, cz),
		Transparency = 1,
		CanCollide = false,
		CastShadow = false,
	}, model)

	-- Floating sign: world-sized, not AlwaysOnTop, so it looks the same size as the pad on every
	-- screen and never covers menus.
	local anchor = mkPart("Part", {
		Name = "SignAnchor",
		Size = Vector3.new(1, 1, 1),
		CFrame = at(cx, FLOOR_Y, cz),
		Transparency = 1,
		CanCollide = false,
		CastShadow = false,
	}, model)
	local billboard = mk("BillboardGui", {
		Name = "PadGui",
		Size = UDim2.fromScale(16, 8),
		StudsOffsetWorldSpace = Vector3.new(0, 11, 0),
		LightInfluence = 0,
		MaxDistance = 120,
		AlwaysOnTop = false,
	}, anchor)
	local function line(name: string, y: number, h: number, text: string, color: Color3, font: Enum.Font): TextLabel
		local lbl = mk("TextLabel", {
			Name = name,
			Size = UDim2.fromScale(1, h),
			Position = UDim2.fromScale(0, y),
			BackgroundTransparency = 1,
			Text = text,
			Font = font,
			TextScaled = true,
			TextColor3 = color,
		}, billboard) :: TextLabel
		mk("UIStroke", { Thickness = 2.5, Color = Color3.fromRGB(12, 30, 60) }, lbl)
		return lbl
	end
	local titleLbl = line("Title", 0, 0.2, "", Color3.fromRGB(255, 230, 140), Enum.Font.FredokaOne)
	local countLbl = line("Count", 0.2, 0.42, "0/" .. Config.Party.MaxPlayers, Color3.new(1, 1, 1), Enum.Font.FredokaOne)
	local statusLbl = line("Status", 0.63, 0.2, "Touch to create a party", Color3.new(1, 1, 1), Enum.Font.FredokaOne)
	local privacyLbl = line("Privacy", 0.84, 0.15, "", Color3.fromRGB(215, 230, 250), Enum.Font.GothamBold)

	-- Members stand in the middle facing the plaza centre; leavers are put outside, towards it.
	local toCentre = -math.sign(cx)
	local inside = at(cx, FLOOR_Y + 0.4, cz)
	local exitPos = at(cx + toCentre * (PAD_RADIUS + 6), FLOOR_Y, cz)
	return {
		Id = id,
		Model = model,
		Zone = zone,
		Floor = floor,
		Inside = CFrame.lookAt(inside.Position, inside.Position + Vector3.new(toCentre, 0, 0)),
		Exit = CFrame.lookAt(exitPos.Position, exitPos.Position + Vector3.new(toCentre, 0, 0)),
		Barriers = barriers,
		Gui = { Count = countLbl, Title = titleLbl, Status = statusLbl, Privacy = privacyLbl },
	}
end

----------------------------------------------------------------------------------------------------
-- The giant dishwasher building at the back (the game's "barn"), with the title on its control panel.
----------------------------------------------------------------------------------------------------
local function buildDishwasherBuilding(parent: Instance)
	local w, h, d = 84, 52, 26
	local z = HATCHERY_Z - d / 2
	-- Low-poly body: flat white box on a navy plinth, a wooden worktop slab on top with an overhang,
	-- and chamfered front corners (wedges) so it reads chunky rather than boxy.
	mkPart("Part", { Name = "Body", Size = Vector3.new(w, h - 4, d), CFrame = at(0, (h - 4) / 2 + 4, z), Color = Color3.fromRGB(238, 242, 246), Material = LOW }, parent)
	mkPart("Part", { Name = "Plinth", Size = Vector3.new(w - 4, 4, d - 3), CFrame = at(0, 2, z - 1.5), Color = Color3.fromRGB(38, 60, 96), Material = LOW }, parent)
	mkPart("Part", { Name = "Worktop", Size = Vector3.new(w + 10, 3, d + 6), CFrame = at(0, h + 1.5, z + 1), Color = Color3.fromRGB(196, 146, 98), Material = LOW }, parent)
	mkPart("Part", { Name = "WorktopEdge", Size = Vector3.new(w + 10.4, 1.0, 1), CFrame = at(0, h + 0.7, z + d / 2 + 4.2), Color = Color3.fromRGB(150, 104, 70), Material = LOW }, parent)
	for _, side in { -1, 1 } do
		-- Vertical chamfer strips on the front corners.
		mkPart("Part", {
			Name = "CornerChamfer",
			Size = Vector3.new(4, h - 4.4, 4),
			CFrame = at(side * (w / 2 - 1.4), (h - 4.4) / 2 + 4, HATCHERY_Z - 1.4) * CFrame.Angles(0, math.rad(45), 0),
			Color = Color3.fromRGB(214, 222, 230),
			Material = LOW,
		}, parent)
	end
	-- One solid, invisible block over the whole front (door, window, frames, handle, panel), so the
	-- detail can't be jumped into: it all reads as the face of one big machine.
	mkPart("Part", { Name = "FrontCollider", Size = Vector3.new(w, h - 4, 4.4), CFrame = at(0, (h - 4) / 2 + 4, HATCHERY_Z + 2.2), Transparency = 1, CastShadow = false, CanQuery = false }, parent)
	-- Door panel with a recessed window and handle.
	mkPart("Part", decor({ Name = "Door", Size = Vector3.new(w - 6, h - 16, 1), CFrame = at(0, (h - 16) / 2 + 3, HATCHERY_Z + 0.5), Color = Color3.fromRGB(225, 229, 234), Material = LOW }), parent)
	-- The window shows a rack of plates behind the glass, like a real dishwasher.
	local winW, winH, winY = w - 26, h - 30, (h - 16) / 2 + 3
	mkPart("Part", decor({ Name = "WindowBack", Size = Vector3.new(winW, winH, 0.4), CFrame = at(0, winY, HATCHERY_Z + 1.2), Color = Color3.fromRGB(60, 80, 105), Material = LOW }), parent)
	for i = 0, 4 do
		local px = -winW / 2 + 6 + i * ((winW - 12) / 4)
		mkPart("Part", decor({ Name = "WindowPlate", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.4, 13, 13), CFrame = at(px, winY - 1, HATCHERY_Z + 2.2) * CFrame.Angles(0, math.rad(90), 0), Color = Color3.fromRGB(110, 170, 230), Material = Enum.Material.SmoothPlastic }), parent)
		mkPart("Part", decor({ Name = "WindowPlateFace", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.4, 11, 11), CFrame = at(px, winY - 1, HATCHERY_Z + 2.45) * CFrame.Angles(0, math.rad(90), 0), Color = Color3.fromRGB(250, 250, 248), Material = Enum.Material.SmoothPlastic }), parent)
	end
	mkPart("Part", decor({ Name = "WindowRack", Size = Vector3.new(winW - 2, 0.6, 2), CFrame = at(0, winY - 8, HATCHERY_Z + 2.3), Color = Color3.fromRGB(220, 225, 230), Material = LOW }), parent)
	local window = mkPart("Part", decor({ Name = "Window", Size = Vector3.new(winW, winH, 0.3), CFrame = at(0, winY, HATCHERY_Z + 3.2), Color = Color3.fromRGB(150, 215, 250), Material = Enum.Material.Glass, Transparency = 0.55 }), parent)
	for _, side in { -1, 1 } do
		mkPart("Part", decor({ Name = "WindowFrame", Size = Vector3.new(1.2, winH + 1.2, 3), CFrame = at(side * (winW / 2 + 0.6), winY, HATCHERY_Z + 2), Color = Color3.fromRGB(200, 205, 212), Material = LOW }), parent)
	end
	for _, side in { -1, 1 } do
		mkPart("Part", decor({ Name = "WindowFrame", Size = Vector3.new(winW + 2.4, 1.2, 3), CFrame = at(0, winY + side * (winH / 2 + 0.6), HATCHERY_Z + 2), Color = Color3.fromRGB(200, 205, 212), Material = LOW }), parent)
	end
	-- Suds sloshing behind the window.
	mk("ParticleEmitter", {
		Texture = "rbxasset://textures/particles/forcefield_glow_main.dds",
		Color = ColorSequence.new(Color3.new(1, 1, 1)),
		Size = NumberSequence.new(1.6, 0.6),
		Transparency = NumberSequence.new(0.2, 1),
		Lifetime = NumberRange.new(1.5, 3),
		Rate = 12,
		Speed = NumberRange.new(1, 3),
		SpreadAngle = Vector2.new(60, 60),
		EmissionDirection = Enum.NormalId.Top,
	}, window)
	mkPart("Part", decor({ Name = "Handle", Size = Vector3.new(30, 2, 2), CFrame = at(0, h - 17, HATCHERY_Z + 2), Color = Color3.fromRGB(170, 176, 184), Material = LOW }), parent)
	-- Control panel strip with the title and a few glowing buttons.
	local panel = mkPart("Part", { Name = "ControlPanel", Size = Vector3.new(w, 12, 2), CFrame = at(0, h - 6, HATCHERY_Z + 1), Color = Color3.fromRGB(40, 46, 58), Material = Enum.Material.SmoothPlastic }, parent)
	-- Back is the +Z face of an unrotated part, which is the side facing the spawn.
	local gui = mk("SurfaceGui", { Face = Enum.NormalId.Back, CanvasSize = Vector2.new(1400, 200), LightInfluence = 0 }, panel)
	local title = mk("TextLabel", {
		Size = UDim2.fromScale(0.7, 0.9),
		Position = UDim2.fromScale(0.03, 0.05),
		BackgroundTransparency = 1,
		Text = string.upper(Config.GameName),
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(120, 220, 255),
		TextXAlignment = Enum.TextXAlignment.Left,
	}, gui)
	mk("UIStroke", { Thickness = 4, Color = Color3.fromRGB(10, 30, 70) }, title)
	for i = 0, 3 do
		mkPart("Part", decor({
			Name = "PanelButton",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.6, 4, 4),
			CFrame = at(22 + i * 6, h - 6, HATCHERY_Z + 2.2) * CFrame.Angles(0, math.rad(90), 0),
			Color = if i == 0 then Color3.fromRGB(80, 230, 140) else Color3.fromRGB(120, 200, 255),
			Material = Enum.Material.Neon,
		}), parent)
	end
	-- Roof sign.
	local roofSign = mkPart("Part", { Name = "RoofSign", Size = Vector3.new(44, 9, 1), CFrame = at(0, h + 8.5, HATCHERY_Z - 4) * CFrame.Angles(0, math.pi, 0), Color = Color3.fromRGB(255, 120, 180), Material = Enum.Material.SmoothPlastic }, parent)
	local signGui = mk("SurfaceGui", { Face = Enum.NormalId.Front, CanvasSize = Vector2.new(880, 180), LightInfluence = 0 }, roofSign)
	local signText = mk("TextLabel", { Size = UDim2.fromScale(0.94, 0.86), Position = UDim2.fromScale(0.03, 0.07), BackgroundTransparency = 1, Text = "PETS & EGGS", Font = Enum.Font.FredokaOne, TextScaled = true, TextColor3 = Color3.new(1, 1, 1) }, signGui)
	mk("UIStroke", { Thickness = 5, Color = Color3.fromRGB(140, 40, 90) }, signText)
	for _, x in { -18, 18 } do
		mkPart("Part", { Name = "SignPost", Size = Vector3.new(0.8, 3, 0.8), CFrame = at(x, h + 3.5, HATCHERY_Z - 4), Color = Color3.fromRGB(200, 205, 212), Material = LOW }, parent)
	end
	-- Steam puffing out of the top.
	local vent = mkPart("Part", decor({ Name = "Vent", Size = Vector3.new(10, 1, 4), CFrame = at(-24, h + 3.5, z), Color = Color3.fromRGB(150, 155, 160), Material = LOW }), parent)
	mk("ParticleEmitter", {
		Texture = "rbxasset://textures/particles/smoke_main.dds",
		Color = ColorSequence.new(Color3.new(1, 1, 1)),
		Size = NumberSequence.new(3, 9),
		Transparency = NumberSequence.new(0.5, 1),
		Lifetime = NumberRange.new(2, 4),
		Rate = 4,
		Speed = NumberRange.new(4, 7),
		SpreadAngle = Vector2.new(15, 15),
	}, vent)
end

----------------------------------------------------------------------------------------------------
-- Soap Shop stall (perks): striped awning, counter, a giant pump bottle, and the prompt.
----------------------------------------------------------------------------------------------------
local function buildSoapShop(parent: Instance)
	local x, z = SHOP_X, EGG_Z
	local counter = mkPart("Part", { Name = "Counter", Size = Vector3.new(16, 4, 6), CFrame = at(x, 2, z), Color = Color3.fromRGB(165, 112, 70), Material = Enum.Material.Wood }, parent)
	mkPart("Part", ({ Name = "CounterTop", Size = Vector3.new(17, 0.6, 7), CFrame = at(x, 4.3, z), Color = Color3.fromRGB(120, 78, 48), Material = Enum.Material.Wood }), parent)
	for _, dx in { -7.5, 7.5 } do
		mkPart("Part", ({ Name = "AwningPost", Size = Vector3.new(0.8, 12, 0.8), CFrame = at(x + dx, 6, z - 2.5), Color = Color3.fromRGB(250, 250, 250) }), parent)
	end
	for i = 0, 7 do
		mkPart("Part", ({
			Name = "Awning",
			Size = Vector3.new(2.2, 0.6, 9),
			CFrame = at(x - 7.7 + i * 2.2, 12.5, z - 1) * CFrame.Angles(math.rad(-12), 0, 0),
			Color = if i % 2 == 0 then Color3.fromRGB(80, 190, 250) else Color3.new(1, 1, 1),
		}), parent)
	end
	worldSign(counter, "SOAP SHOP", 14, 3, 16.5, Color3.fromRGB(255, 235, 140))
	worldSign(counter, "Perks", 8, 1.8, 14, Color3.fromRGB(220, 235, 255))

	local prompt = mk("ProximityPrompt", {
		ActionText = "Open Shop",
		ObjectText = "Soap Shop",
		RequiresLineOfSight = false,
		HoldDuration = 0,
		MaxActivationDistance = 12,
	}, counter) :: ProximityPrompt
	prompt:SetAttribute("OpenWindow", "Shop")
	prompt:SetAttribute("WindowArg", "Perks") -- the Soap Shop always opens on its perks
end

----------------------------------------------------------------------------------------------------
-- Egg Hatchery (one pedestal per Config.Eggs entry, in front of the dishwasher) and the Pet Stand.
----------------------------------------------------------------------------------------------------
local function fallbackEggModel(egg: any): Model
	local m = Instance.new("Model")
	m.Name = "Egg_" .. tostring(egg.Id)
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(6, 8, 6)
	root.Color = egg.Color
	root.Material = Enum.Material.SmoothPlastic
	root.Anchored = true
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = root
	root.Parent = m
	m.PrimaryPart = root
	return m
end

local function buildEggHatchery(parent: Instance)
	local petModelsOk, PetModels = pcall(function()
		return require(Shared:WaitForChild("PetModels"))
	end)

	local eggs = Config.Eggs
	local n = #eggs
	for i, egg in eggs do
		local ex = (i - (n + 1) / 2) * 20
		local pedestal = mkPart("Part", {
			Name = "EggPedestal" .. i,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(3, 9, 9),
			CFrame = upright(ex, 1.5, EGG_Z),
			Color = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
		}, parent)
		mkPart("Part", decor({
			Name = "EggPedestalRing",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.6, 9.6, 9.6),
			CFrame = upright(ex, 3, EGG_Z),
			Color = egg.Color,
			Material = Enum.Material.Neon,
		}), parent)

		local eggModel: Model? = nil
		if petModelsOk then
			local ok2, result = pcall((PetModels :: any).Egg, egg.Id)
			if ok2 and typeof(result) == "Instance" then
				eggModel = result :: Model
			end
		end
		local model = eggModel or fallbackEggModel(egg)
		model.Parent = parent
		pcall(function()
			model:ScaleTo(2)
		end)
		pcall(function()
			model:PivotTo(at(ex, 8.5, EGG_Z))
		end)
		-- The egg model is decor; one invisible capsule-ish block keeps players from walking into it.
		mkPart("Part", { Name = "EggCollider", Size = Vector3.new(5, 7.5, 5), CFrame = at(ex, 8, EGG_Z), Transparency = 1, CastShadow = false, CanQuery = false }, parent)
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
				maybeYield()
			end
		end

		local label = worldSign(pedestal, egg.Name, 10, 2.2, 18.5)
		label.Name = "EggName"
		worldSign(pedestal, tostring(egg.Cost) .. " Bubbles", 7, 1.8, 16.3, Color3.fromRGB(255, 210, 120))
		if egg.RequiredLevel and egg.RequiredLevel > 1 then
			worldSign(pedestal, "Locked: level " .. tostring(egg.RequiredLevel), 7, 1.5, 14.4, Color3.fromRGB(255, 160, 160))
		end

		local prompt = mk("ProximityPrompt", {
			ActionText = "Hatch",
			ObjectText = egg.Name,
			RequiresLineOfSight = false,
			HoldDuration = 0,
			MaxActivationDistance = 12,
		}, pedestal) :: ProximityPrompt
		prompt:SetAttribute("OpenWindow", "Eggs")
		prompt:SetAttribute("EggId", egg.Id)
	end
end

----------------------------------------------------------------------------------------------------
-- A ladder up the right side of the dishwasher building, so players can climb onto its roof.
----------------------------------------------------------------------------------------------------
local function buildRoofLadder(parent: Instance)
	-- One invisible TrussPart does the climbing; rails and rungs are the looks.
	local lx, lz = 48.2, -84
	mkPart("TrussPart", { Name = "LadderClimb", Size = Vector3.new(2, 56, 2), CFrame = at(lx, 28, lz), Transparency = 1, CastShadow = false }, parent)
	local wood = Color3.fromRGB(196, 146, 98)
	for _, dz in { -1.4, 1.4 } do
		mkPart("Part", decor({ Name = "LadderRail", Size = Vector3.new(0.5, 58, 0.5), CFrame = at(lx + 0.6, 29, lz + dz), Color = wood, Material = LOW }), parent)
	end
	for y = 2, 56, 2 do
		mkPart("Part", decor({ Name = "LadderRung", Size = Vector3.new(0.4, 0.4, 2.8), CFrame = at(lx + 0.6, y, lz), Color = Color3.fromRGB(170, 120, 78), Material = LOW }), parent)
	end
end

local function buildPetStand(parent: Instance)
	local x, z = PETSTAND_X, EGG_Z
	local base = mkPart("Part", { Name = "PetStand", Shape = Enum.PartType.Cylinder, Size = Vector3.new(3, 12, 12), CFrame = upright(x, 1.5, z), Color = Color3.fromRGB(255, 205, 230), Material = Enum.Material.SmoothPlastic }, parent)
	-- A little doghouse.
	mkPart("Part", { Name = "Doghouse", Size = Vector3.new(7, 6, 6), CFrame = at(x, 6, z - 1), Color = Color3.fromRGB(240, 120, 150), Material = Enum.Material.WoodPlanks }, parent)
	-- A proper gable roof: two wedges close the triangle over the body (front and back), two planks
	-- rest on the slopes with a little overhang, and a cap covers the ridge where they meet.
	local pitch = math.rad(38)
	local half, top, zc = 3.5, 9, z - 1
	local rise = half * math.tan(pitch)
	local roofColor = Color3.fromRGB(150, 62, 58)
	for _, side in { -1, 1 } do
		mkPart("WedgePart", {
			Name = "Gable",
			Size = Vector3.new(6, rise, half),
			CFrame = at(x + side * half / 2, top + rise / 2, zc) * CFrame.Angles(0, math.rad(-side * 90), 0),
			Color = Color3.fromRGB(240, 120, 150),
			Material = Enum.Material.WoodPlanks,
		}, parent)
		-- plank: from the ridge down the slope and 0.9 past the eave, sitting on the slope
		local length = half / math.cos(pitch) + 0.9
		local down = Vector3.new(side * math.cos(pitch), -math.sin(pitch), 0)
		local outward = Vector3.new(side * math.sin(pitch), math.cos(pitch), 0)
		local ridge = Vector3.new(0, top + rise, 0)
		local c = ridge + down * (length / 2) + outward * 0.25
		mkPart("Part", {
			Name = "Roof",
			Size = Vector3.new(length, 0.6, 7.2),
			CFrame = at(x + c.X, c.Y, zc) * CFrame.Angles(0, 0, -side * pitch),
			Color = roofColor,
			Material = LOW,
		}, parent)
	end
	mkPart("Part", {
		Name = "RoofRidge",
		Size = Vector3.new(0.9, 0.9, 7.6),
		CFrame = at(x, top + rise + 0.35, zc) * CFrame.Angles(0, 0, math.rad(45)),
		Color = Color3.fromRGB(120, 48, 46),
		Material = LOW,
	}, parent)
	mkPart("Part", decor({ Name = "DoghouseDoor", Size = Vector3.new(3, 3.6, 0.3), CFrame = at(x, 4.8, z + 2.05), Color = Color3.fromRGB(40, 30, 30) }), parent)
	worldSign(base, "PETS", 10, 2.6, 13, Color3.fromRGB(255, 170, 210))
	local prompt = mk("ProximityPrompt", {
		ActionText = "My Pets",
		ObjectText = "Pet Stand",
		RequiresLineOfSight = false,
		HoldDuration = 0,
		MaxActivationDistance = 12,
	}, base) :: ProximityPrompt
	prompt:SetAttribute("OpenWindow", "Pets")
end

----------------------------------------------------------------------------------------------------
-- Boards: two leaderboards and How to Play, facing the spawn (+Z).
----------------------------------------------------------------------------------------------------
-- A board on legs at (x, z), its front (the side with the SurfaceGui, the part's Front face) turned
-- toward (faceX, faceZ). Trim and legs follow the rotation.
local function boardShell(parent: Instance, x: number, z: number, w: number, h: number, name: string, faceX: number, faceZ: number): BasePart
	local centre = at(x, h / 2 + 3, z).Position
	local facing = CFrame.lookAt(centre, Vector3.new(ORIGIN.X + faceX, centre.Y, ORIGIN.Z + faceZ))
	local boardPart = mkPart("Part", {
		Name = name,
		Size = Vector3.new(w, h, 1),
		CFrame = facing,
		Color = NAVY,
		Material = Enum.Material.SmoothPlastic,
	}, parent)
	mkPart("Part", decor({ Name = "Trim", Size = Vector3.new(w + 1.4, h + 1.4, 0.6), CFrame = facing * CFrame.new(0, 0, 0.7), Color = Color3.fromRGB(40, 90, 150) }), parent)
	for _, dx in { -w / 2 + 2, w / 2 - 2 } do
		mkPart("Part", { Name = "Leg", Size = Vector3.new(1.2, 3.2, 1.2), CFrame = facing * CFrame.new(dx, -h / 2 - 1.4, 0.3), Color = Color3.fromRGB(150, 155, 160), Material = Enum.Material.Metal }, parent)
	end
	return boardPart
end

local function buildBoard(parent: Instance, x: number, z: number, titleText: string, faceX: number, faceZ: number, pageCount: number?): BoardInfo
	local boardPart = boardShell(parent, x, z, 22, 15, "Board", faceX, faceZ)
	-- MaxDistance: readable from anywhere in the lobby, not only up close.
	local gui = mk("SurfaceGui", { Face = Enum.NormalId.Front, CanvasSize = Vector2.new(700, 480), LightInfluence = 0, MaxDistance = 5000 }, boardPart)
	mk("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, gui)
	local paged = pageCount and pageCount > 1
	local function page(i: number, parentGui: Instance): BoardPage
		local root = mk("Frame", { Name = "Page" .. i, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = i == 1 }, parentGui)
		local titleLbl = mk("TextLabel", {
			Name = "Title",
			Size = if paged then UDim2.new(1, -150, 0, 64) else UDim2.new(1, 0, 0, 64),
			Position = if paged then UDim2.fromOffset(75, 0) else UDim2.new(),
			BackgroundTransparency = 1,
			Text = titleText,
			Font = Enum.Font.FredokaOne,
			TextScaled = true,
			TextColor3 = Color3.new(1, 1, 1),
		}, root) :: TextLabel
		mk("UIStroke", { Thickness = 3, Color = Color3.fromRGB(10, 30, 60) }, titleLbl)
		-- The top 100, scrollable (the client moves this SurfaceGui into PlayerGui so it takes the
		-- mouse wheel / a finger: BoardView). The 46 px under it are for each player's own row.
		local list = mk("ScrollingFrame", {
			Name = "List",
			Size = UDim2.new(1, 0, 1, if paged then -150 else -116),
			Position = UDim2.new(0, 0, 0, 70),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			ScrollBarThickness = 10,
			ScrollBarImageColor3 = Color3.fromRGB(255, 205, 70),
			ElasticBehavior = Enum.ElasticBehavior.Never,
		}, root) :: ScrollingFrame
		mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, list)
		if paged then
			-- Page dots along the bottom, this page's dot lit.
			local dots = mk("Frame", { Name = "PageDots", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -2), Size = UDim2.fromOffset(200, 22), BackgroundTransparency = 1 }, root)
			mk("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Center, VerticalAlignment = Enum.VerticalAlignment.Center, Padding = UDim.new(0, 12) }, dots)
			for d = 1, pageCount :: number do
				local dot = mk("Frame", { Name = "Dot" .. d, LayoutOrder = d, Size = if d == i then UDim2.fromOffset(34, 16) else UDim2.fromOffset(16, 16), BackgroundColor3 = if d == i then Color3.fromRGB(255, 205, 70) else Color3.fromRGB(70, 110, 160) }, dots)
				mk("UICorner", { CornerRadius = UDim.new(1, 0) }, dot)
			end
		end
		return { Title = titleLbl, List = list }
	end

	if not paged then
		local only = page(1, gui)
		return { Part = boardPart, Title = only.Title, List = only.List }
	end

	local pages = {}
	for i = 1, pageCount :: number do
		pages[i] = page(i, gui)
	end
	-- Round arrow buttons drawn in the board's own SurfaceGui (crisp, same resolution as the board),
	-- either side of the title, with an invisible click target over each (click or tap), plus a
	-- prompt for controllers. The client flips the pages locally and lights a button on hover
	-- (Effects).
	local w, h = boardPart.Size.X, boardPart.Size.Y
	local canvas = Vector2.new(700, 480)
	local pxPerStud = canvas.X / w
	local btn = 60
	for _, dir in { -1, 1 } do
		local name = if dir < 0 then "ArrowLeft" else "ArrowRight"
		local frame = mk("Frame", {
			Name = name,
			AnchorPoint = Vector2.new(if dir < 0 then 0 else 1, 0),
			Position = if dir < 0 then UDim2.fromOffset(0, 2) else UDim2.new(1, 0, 0, 2),
			Size = UDim2.fromOffset(btn, btn),
			BackgroundColor3 = Color3.fromRGB(255, 205, 70),
			ZIndex = 5,
		}, gui)
		mk("UICorner", { CornerRadius = UDim.new(1, 0) }, frame)
		mk("UIStroke", { Thickness = 4, Color = Color3.fromRGB(255, 245, 200) }, frame)
		mk("UIGradient", {
			Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(200, 200, 200)),
			Rotation = 90,
		}, frame)
		mk("TextLabel", {
			Size = UDim2.fromScale(1, 1),
			Position = UDim2.fromOffset(if dir < 0 then -2 else 2, -1),
			BackgroundTransparency = 1,
			Text = if dir < 0 then "◀" else "▶",
			Font = Enum.Font.FredokaOne,
			TextSize = 34,
			TextColor3 = Color3.fromRGB(60, 40, 10),
			ZIndex = 6,
		}, frame)
		-- Click target over the drawn button (board padding: 12 px left/right, 10 px top).
		local cx = if dir < 0 then 12 + btn / 2 else canvas.X - 12 - btn / 2
		local cy = 10 + 2 + btn / 2
		local arrow = mkPart("Part", {
			Name = "BoardArrow",
			Size = Vector3.new(btn / pxPerStud + 0.3, btn / pxPerStud + 0.3, 0.3),
			CFrame = boardPart.CFrame * CFrame.new(cx / pxPerStud - w / 2, h / 2 - cy / pxPerStud, -0.7),
			Transparency = 1,
			CanCollide = false,
			CanQuery = true, -- ClickDetectors need the mouse ray to hit the part
			CastShadow = false,
		}, boardPart)
		arrow:SetAttribute("Dir", dir)
		arrow:SetAttribute("Button", name)
		CollectionService:AddTag(arrow, "BoardArrow")
		mk("ClickDetector", { MaxActivationDistance = 70 }, arrow)
	end
	local prompt = mk("ProximityPrompt", {
		ActionText = "Next page",
		ObjectText = titleText,
		RequiresLineOfSight = false,
		HoldDuration = 0,
		MaxActivationDistance = 14,
		KeyboardKeyCode = Enum.KeyCode.F,
	}, boardPart) :: ProximityPrompt
	prompt:SetAttribute("BoardNext", true)
	return { Part = boardPart, Title = pages[1].Title, List = pages[1].List, Pages = pages }
end

local function buildHowToPlay(parent: Instance, x: number, z: number, faceX: number, faceZ: number)
	local boardPart = boardShell(parent, x, z, 24, 15, "HowToPlayBoard", faceX, faceZ)
	boardPart.Color = Color3.fromRGB(255, 255, 255)
	local gui = mk("SurfaceGui", { Face = Enum.NormalId.Front, CanvasSize = Vector2.new(760, 480), LightInfluence = 0 }, boardPart)
	mk("UIPadding", {
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 18),
		PaddingRight = UDim.new(0, 18),
	}, gui)
	mk("TextLabel", {
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundTransparency = 1,
		Text = "How to Play",
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(20, 110, 190),
	}, gui)
	local list = mk("Frame", {
		Size = UDim2.new(1, 0, 1, -60),
		Position = UDim2.new(0, 0, 0, 60),
		BackgroundTransparency = 1,
	}, gui)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, list)
	local steps = {
		"Step on a party pad and pick a level.",
		"Aim at dirt and hold to scrub it off.",
		"Stand in the drain to sell your dirt for coins.",
		"Buy better tools and upgrades.",
		"Clean every dish, earn Bubbles and hatch pets!",
	}
	for i, text in steps do
		mk("TextLabel", {
			Name = "Step" .. i,
			Size = UDim2.new(1, 0, 0, 66),
			BackgroundTransparency = 1,
			Text = tostring(i) .. ". " .. text,
			Font = Enum.Font.GothamBold,
			-- one fixed size for every step (scaled text made each line a different size)
			TextSize = 31,
			TextColor3 = Color3.fromRGB(20, 40, 70),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			LayoutOrder = i,
		}, list)
	end
end

----------------------------------------------------------------------------------------------------
-- Decorations: giant tableware on the table (salt and pepper, a flower vase, a coffee cup, cutlery),
-- a sponge and soap bars, floating bubbles. Low-poly: hexagonal prisms, flat colours.
----------------------------------------------------------------------------------------------------

-- Hexagonal prism (flat-to-flat width d, height h) with its base at y0: three boxes at 0/60/120.
local function hex(parent: Instance, name: string, x: number, y0: number, z: number, d: number, h: number, color: Color3, collide: boolean?)
	local side = d / math.sqrt(3)
	for k = 0, 2 do
		mkPart("Part", {
			Name = name,
			Size = Vector3.new(side, h, d),
			CFrame = at(x, y0 + h / 2, z) * CFrame.Angles(0, k * math.pi / 3, 0),
			Color = color,
			Material = LOW,
			CanCollide = collide ~= false,
		}, parent)
	end
end

local function shaker(parent: Instance, x: number, z: number, body: Color3, holes: Color3)
	hex(parent, "Shaker", x, FLOOR_Y, z, 6, 11, body)
	hex(parent, "ShakerCap", x, FLOOR_Y + 11, z, 6.4, 2.6, Color3.fromRGB(200, 205, 212))
	for k = 0, 2 do
		local a = k / 3 * math.pi * 2
		mkPart("Part", decor({ Name = "ShakerHole", Size = Vector3.new(0.7, 0.1, 0.7), CFrame = at(x + math.cos(a) * 1.4, FLOOR_Y + 13.63, z + math.sin(a) * 1.4), Color = holes, Material = LOW }), parent)
	end
end

local function flowerVase(parent: Instance, x: number, z: number)
	hex(parent, "Vase", x, FLOOR_Y, z, 7, 9, Color3.fromRGB(90, 150, 220))
	hex(parent, "VaseNeck", x, FLOOR_Y + 9, z, 4.4, 2, Color3.fromRGB(70, 125, 200))
	local petals = { Color3.fromRGB(255, 120, 150), Color3.fromRGB(255, 200, 80), Color3.fromRGB(190, 130, 255), Color3.fromRGB(255, 255, 255) }
	for k = 0, 3 do
		local a = k / 4 * math.pi * 2
		local fx, fz = x + math.cos(a) * 2.6, z + math.sin(a) * 2.6
		local top = FLOOR_Y + 17 + (k % 2) * 2.5
		mkPart("Part", decor({ Name = "Stem", Size = Vector3.new(0.5, top - FLOOR_Y - 8, 0.5), CFrame = at((x + fx) / 2, (FLOOR_Y + 8 + top) / 2, (z + fz) / 2) * CFrame.Angles(math.sin(a) * 0.2, 0, -math.cos(a) * 0.2), Color = Color3.fromRGB(80, 160, 80), Material = LOW }), parent)
		hex(parent, "Petals", fx, top, fz, 3.4, 0.8, petals[k + 1], false)
		mkPart("Part", decor({ Name = "FlowerMiddle", Size = Vector3.new(1.2, 0.9, 1.2), CFrame = at(fx, top + 0.55, fz), Color = Color3.fromRGB(255, 220, 90), Material = LOW }), parent)
	end
end

local function coffeeCup(parent: Instance, x: number, z: number)
	mkPart("Part", { Name = "Saucer", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.8, 13, 13), CFrame = upright(x, FLOOR_Y + 0.4, z), Color = Color3.fromRGB(245, 245, 240), Material = LOW }, parent)
	hex(parent, "Cup", x, FLOOR_Y + 0.8, z, 8, 8, Color3.fromRGB(245, 245, 240))
	hex(parent, "Coffee", x, FLOOR_Y + 8.7, z, 6.6, 0.2, Color3.fromRGB(110, 70, 45))
	mkPart("Part", { Name = "CupHandle", Size = Vector3.new(3, 5, 1.2), CFrame = at(x + 5.3, FLOOR_Y + 4.8, z), Color = Color3.fromRGB(245, 245, 240), Material = LOW }, parent)
	hex(parent, "CupBand", x, FLOOR_Y + 5.8, z, 8.3, 1.2, Color3.fromRGB(90, 170, 230))
end

-- Cutlery lying flat in the table's margin (outside the invisible walls, just to look at).
local function cutlery(parent: Instance, x: number, z: number, kind: string)
	local steel = Color3.fromRGB(205, 210, 218)
	mkPart("Part", decor({ Name = "CutleryHandle", Size = Vector3.new(3, 1, 26), CFrame = at(x, FLOOR_Y + 0.5, z + 14), Color = steel, Material = Enum.Material.Metal }), parent)
	if kind == "Fork" then
		mkPart("Part", decor({ Name = "ForkHead", Size = Vector3.new(6, 1, 5), CFrame = at(x, FLOOR_Y + 0.5, z - 1.5), Color = steel, Material = Enum.Material.Metal }), parent)
		for k = 0, 3 do
			mkPart("Part", decor({ Name = "ForkTine", Size = Vector3.new(0.9, 1, 10), CFrame = at(x - 2.55 + k * 1.7, FLOOR_Y + 0.5, z - 9), Color = steel, Material = Enum.Material.Metal }), parent)
		end
	else
		mkPart("Part", decor({ Name = "KnifeBlade", Size = Vector3.new(4.5, 0.8, 18), CFrame = at(x + 0.7, FLOOR_Y + 0.4, z - 8), Color = steel, Material = Enum.Material.Metal }), parent)
	end
end

local function buildDecorations(parent: Instance)
	shaker(parent, -91, -94, Color3.fromRGB(250, 250, 250), Color3.fromRGB(60, 60, 60))
	shaker(parent, -83, -96, Color3.fromRGB(70, 70, 76), Color3.fromRGB(220, 220, 220))
	flowerVase(parent, -90, 58)
	coffeeCup(parent, 90, 58)
	cutlery(parent, -PLAZA_X - TABLE_MARGIN / 2 - 1, -20, "Fork")
	cutlery(parent, PLAZA_X + TABLE_MARGIN / 2 + 1, -20, "Knife")

	-- Giant sponge and soap bars around the spawn.
	mkPart("Part", { Name = "GiantSponge", Size = Vector3.new(12, 5, 8), CFrame = at(-78, 2.7, 44) * CFrame.Angles(0, math.rad(20), 0), Color = Color3.fromRGB(255, 215, 90), Material = LOW }, parent)
	mkPart("Part", ({ Name = "SpongeScrub", Size = Vector3.new(12.2, 1.6, 8.2), CFrame = at(-78, 5.9, 44) * CFrame.Angles(0, math.rad(20), 0), Color = Color3.fromRGB(80, 180, 100), Material = LOW }), parent)
	mkPart("Part", { Name = "SoapBar", Size = Vector3.new(10, 3.5, 6), CFrame = at(78, 2, 44) * CFrame.Angles(0, math.rad(-15), 0), Color = Color3.fromRGB(190, 230, 255), Material = LOW }, parent)
	mkPart("Part", { Name = "SoapBar", Size = Vector3.new(8, 3, 5), CFrame = at(79, 5.3, 44) * CFrame.Angles(0, math.rad(10), 0), Color = Color3.fromRGB(255, 190, 220), Material = LOW }, parent)

	-- Big floating soap bubbles over the table. The server only places them (tag "FloatBubble");
	-- every client bobs them locally (Effects), so they move smoothly with no network traffic.
	local bubbleFolder = mk("Folder", { Name = "Bubbles" }, parent)
	local tints = { Color3.fromRGB(165, 225, 255), Color3.fromRGB(255, 195, 238), Color3.fromRGB(200, 255, 232), Color3.fromRGB(226, 208, 255) }
	local rng = Random.new(11)
	for i = 1, 14 do
		local pos = at(rng:NextNumber(-85, 85), rng:NextNumber(12, 30), rng:NextNumber(-85, 50)).Position
		local size = rng:NextNumber(2.2, 4.2)
		local bubble = mkPart("Part", {
			Name = "Bubble" .. i,
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(size, size, size),
			CFrame = CFrame.new(pos),
			Color = tints[(i - 1) % #tints + 1],
			Material = Enum.Material.ForceField,
			CanCollide = false,
			CastShadow = false,
		}, bubbleFolder)
		CollectionService:AddTag(bubble, "FloatBubble")
	end
end

-- Rebirth Fountain: a low-poly stone fountain with glowing water and a spinning gold star; bubbles
-- stream up from its spout (tag "BubbleSpout", client). Opens the Rebirth window.
local function buildRebirthFountain(parent: Instance)
	local x, z = -34, 14
	local stone = Color3.fromRGB(236, 232, 224)
	local water = Color3.fromRGB(120, 200, 255)
	hex(parent, "FountainBasin", x, FLOOR_Y, z, 13, 2.2, stone)
	hex(parent, "FountainWater", x, FLOOR_Y + 2.2, z, 11.6, 0.2, water, false)
	hex(parent, "FountainPillar", x, FLOOR_Y + 2.2, z, 2.6, 5, stone)
	hex(parent, "FountainBowl", x, FLOOR_Y + 7.2, z, 6.5, 1.2, stone)
	hex(parent, "FountainBowlWater", x, FLOOR_Y + 8.4, z, 5.4, 0.2, water, false)
	local spout = mkPart("Part", decor({ Name = "BubbleSpout", Size = Vector3.new(1, 1, 1), CFrame = at(x, FLOOR_Y + 9, z), Transparency = 1, CastShadow = false }), parent)
	CollectionService:AddTag(spout, "BubbleSpout")
	local star = mkPart("Part", decor({
		Name = "RebirthStar",
		Size = Vector3.new(3, 3, 0.8),
		CFrame = at(x, FLOOR_Y + 14, z) * CFrame.Angles(0, 0, math.rad(45)),
		Color = Color3.fromRGB(255, 210, 80),
		Material = Enum.Material.Neon,
		CastShadow = false,
	}), parent)
	star:SetAttribute("SpinSpeed", 1.2)
	CollectionService:AddTag(star, "SpinY")
	mk("PointLight", { Range = 16, Brightness = 0.8, Color = Color3.fromRGB(255, 220, 140) }, star)
	local base = mkPart("Part", { Name = "FountainPrompt", Size = Vector3.new(1, 1, 1), CFrame = at(x, FLOOR_Y + 2, z), Transparency = 1, CanCollide = false, CastShadow = false }, parent)
	worldSign(base, "REBIRTH", 10, 2.6, 16, Color3.fromRGB(255, 225, 130))
	local prompt = mk("ProximityPrompt", {
		ActionText = "Rebirth",
		ObjectText = "Rebirth Fountain",
		RequiresLineOfSight = false,
		HoldDuration = 0,
		MaxActivationDistance = 12,
	}, base) :: ProximityPrompt
	prompt:SetAttribute("OpenWindow", "Rebirth")
end

-- Rank Shrine: a floating, spinning crystal over a pedestal. Opens the Ranks window.
local function buildRankShrine(parent: Instance)
	local x, z = -32, 40
	local base = mkPart("Part", { Name = "ShrineBase", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.6, 12, 12), CFrame = upright(x, 1, z), Color = Color3.fromRGB(60, 40, 110), Material = Enum.Material.SmoothPlastic }, parent)
	mkPart("Part", { Name = "ShrinePillar", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4, 5, 5), CFrame = upright(x, 3.8, z), Color = Color3.fromRGB(235, 225, 250), Material = Enum.Material.Marble }, parent)
	local crystal = mkPart("Part", decor({
		Name = "Crystal",
		Size = Vector3.new(4, 4, 4),
		CFrame = at(x, 10, z) * CFrame.Angles(math.rad(45), 0, math.rad(45)),
		Color = Color3.fromRGB(190, 120, 255),
		Material = Enum.Material.Glass,
		Transparency = 0.15,
		CastShadow = false,
	}), parent)
	crystal:SetAttribute("SpinSpeed", 0.8)
	CollectionService:AddTag(crystal, "SpinY")
	mk("PointLight", { Range = 16, Brightness = 1, Color = Color3.fromRGB(200, 140, 255) }, crystal)
	mk("ParticleEmitter", {
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(230, 190, 255)),
		Size = NumberSequence.new(0.6, 0),
		Lifetime = NumberRange.new(0.8, 1.4),
		Rate = 8,
		Speed = NumberRange.new(1, 3),
		SpreadAngle = Vector2.new(180, 180),
	}, crystal)
	worldSign(base, "RANKS", 10, 2.6, 15.5, Color3.fromRGB(230, 190, 255))
	worldSign(base, string.format("Roll for %d Gems", Config.RankRoll.Cost), 8, 1.6, 13.4, Color3.fromRGB(255, 255, 255))
	local prompt = mk("ProximityPrompt", {
		ActionText = "Roll Ranks",
		ObjectText = "Rank Shrine",
		RequiresLineOfSight = false,
		HoldDuration = 0,
		MaxActivationDistance = 12,
	}, base) :: ProximityPrompt
	prompt:SetAttribute("OpenWindow", "Ranks")
end

-- The Treasure Chest event (Config.ChestEvent): a big gold-banded chest on a sandy mound, facing
-- the spawn. Only built while the event runs (servers restart with updates, so it goes when the
-- event does). There's no prompt: walking up to it shows the Open buttons and the odds (ChestUI,
-- which finds the chest by its "EventChest" tag and animates the lid).
-- Every piece is a separate size (no two faces in the same plane), so nothing z-fights.
local function buildTreasureChest(parent: Instance)
	if not Config.ChestEventLive() then
		return
	end
	local x, z = 34, 12
	local wood = Color3.fromRGB(150, 90, 48)
	local gold = Color3.fromRGB(255, 200, 60)
	hex(parent, "ChestSand", x, FLOOR_Y, z, 15, 0.8, Color3.fromRGB(240, 214, 150))
	local y = FLOOR_Y + 0.8
	-- Face the spawn: the chest's front (-Z, where the lock is) points at it.
	local look = CFrame.lookAt(Vector3.new(x, 0, z), Vector3.new(SPAWN.X, 0, SPAWN.Z))
	local base = CFrame.new(x, y, z) * (look - look.Position)
	local model = Instance.new("Model")
	model.Name = "TreasureChest"
	model.Parent = parent
	local W, H, D = 7, 4, 4.6
	local box = mkPart("Part", { Name = "ChestBox", Size = Vector3.new(W, H, D), CFrame = base * CFrame.new(0, H / 2, 0), Color = wood, Material = Enum.Material.Wood }, model)
	-- The lid: a half-round (cylinder) a touch shorter than the box, hinged at the back.
	local lid = mkPart("Part", { Name = "ChestLid", Shape = Enum.PartType.Cylinder, Size = Vector3.new(W - 0.1, D, D), CFrame = base * CFrame.new(0, H, 0), Color = Color3.fromRGB(170, 104, 56), Material = Enum.Material.Wood }, model)
	CollectionService:AddTag(lid, "EventChestLid")
	-- Gold bands stand proud of every face (0.15 out), so they never share a plane with the wood.
	for _, dx in { -2.3, 2.3 } do
		mkPart("Part", decor({ Name = "ChestBand", Size = Vector3.new(0.6, H + 0.3, D + 0.3), CFrame = base * CFrame.new(dx, H / 2, 0), Color = gold, Material = Enum.Material.Metal }), model)
		local band = mkPart("Part", decor({ Name = "LidBand", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.6, D + 0.3, D + 0.3), CFrame = base * CFrame.new(dx, H, 0), Color = gold, Material = Enum.Material.Metal }), model)
		band:SetAttribute("LidPart", true)
	end
	mkPart("Part", decor({ Name = "ChestTrim", Size = Vector3.new(W + 0.4, 0.4, D + 0.4), CFrame = base * CFrame.new(0, 0.2, 0), Color = gold, Material = Enum.Material.Metal }), model)
	local lock = mkPart("Part", decor({ Name = "ChestLock", Size = Vector3.new(1.2, 1.5, 0.4), CFrame = base * CFrame.new(0, H - 0.6, -D / 2 - 0.15), Color = gold, Material = Enum.Material.Metal }), model)
	lock:SetAttribute("LidPart", true)
	mkPart("Part", decor({ Name = "Keyhole", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, 0.4, 0.4), CFrame = lock.CFrame * CFrame.new(0, 0.1, -0.22) * CFrame.Angles(0, math.rad(90), 0), Color = Color3.fromRGB(40, 25, 15), Material = LOW }), model):SetAttribute("LidPart", true)
	-- The glow inside, seen when the lid opens.
	local glow = mkPart("Part", decor({ Name = "ChestGlow", Size = Vector3.new(1, 1, 1), CFrame = base * CFrame.new(0, H + 1.5, 0), Transparency = 1, CastShadow = false }), model)
	mk("PointLight", { Range = 18, Brightness = 1.2, Color = Color3.fromRGB(255, 210, 120) }, glow)
	mk("ParticleEmitter", {
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(255, 225, 120)),
		Size = NumberSequence.new(0.8, 0),
		Lifetime = NumberRange.new(0.8, 1.6),
		Rate = 14,
		Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(60, 60),
	}, glow)
	model.PrimaryPart = box
	CollectionService:AddTag(model, "EventChest")
	worldSign(box, "TREASURE CHEST", 12, 2.4, 14.5, Color3.fromRGB(255, 215, 90))
end

-- The Next Event spot: a glowing ring on the floor with a sign. Walk in and the client
-- (EventZone) shows what's coming next, with Roblox's Notify Me (Config.UpcomingEvents).
local function buildEventZone(parent: Instance)
	local x, z = 34, -18
	local ring = mkPart("Part", decor({
		Name = "EventRing",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 16, 16),
		CFrame = upright(x, FLOOR_Y + 0.15, z),
		Color = Color3.fromRGB(255, 120, 160),
		Material = Enum.Material.Neon,
		Transparency = 0.25,
	}), parent)
	mkPart("Part", decor({ Name = "EventFloor", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.34, 14, 14), CFrame = upright(x, FLOOR_Y + 0.17, z), Color = Color3.fromRGB(60, 40, 90), Material = LOW }), parent)
	local zone = mkPart("Part", {
		Name = "NextEventZone",
		Size = Vector3.new(14, 8, 14),
		CFrame = at(x, FLOOR_Y + 4, z),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	}, parent)
	CollectionService:AddTag(zone, "NextEventZone")
	-- Two posts and a banner across the back.
	for _, dx in { -6.5, 6.5 } do
		mkPart("Part", { Name = "EventPost", Shape = Enum.PartType.Cylinder, Size = Vector3.new(11, 0.8, 0.8), CFrame = upright(x + dx, FLOOR_Y + 5.5, z - 6.5), Color = Color3.fromRGB(240, 240, 250), Material = Enum.Material.Metal }, parent)
	end
	local banner = mkPart("Part", { Name = "EventBanner", Size = Vector3.new(13, 4, 0.4), CFrame = at(x, FLOOR_Y + 9, z - 6.5), Color = Color3.fromRGB(70, 40, 120), Material = LOW }, parent)
	local gui = mk("SurfaceGui", { Name = "Sign", Face = Enum.NormalId.Back, CanvasSize = Vector2.new(650, 200), LightInfluence = 0 }, banner) -- faces the spawn (+Z)
	local title = mk("TextLabel", { Name = "Title", Size = UDim2.fromScale(1, 0.45), BackgroundTransparency = 1, Text = "NEXT EVENT", Font = Enum.Font.FredokaOne, TextScaled = true, TextColor3 = Color3.fromRGB(255, 200, 230) }, gui)
	mk("UIStroke", { Thickness = 3, Color = Color3.fromRGB(12, 30, 60) }, title)
	local when = mk("TextLabel", { Name = "When", Position = UDim2.fromScale(0, 0.45), Size = UDim2.fromScale(1, 0.55), BackgroundTransparency = 1, Text = "", Font = Enum.Font.FredokaOne, TextScaled = true, TextColor3 = Color3.new(1, 1, 1) }, gui)
	mk("UIStroke", { Thickness = 3, Color = Color3.fromRGB(12, 30, 60) }, when)
	CollectionService:AddTag(when, "NextEventCountdown")
	mk("PointLight", { Range = 16, Brightness = 0.8, Color = Color3.fromRGB(255, 150, 200) }, ring)
end

-- Bubble lamps and bushy planters along the central path.
local function buildPathDressing(parent: Instance)
	for _, z in { -52, -22, 8 } do
		for _, side in { -1, 1 } do
			local x = side * 11
			mkPart("Part", { Name = "PathLampPost", Shape = Enum.PartType.Cylinder, Size = Vector3.new(7, 0.8, 0.8), CFrame = upright(x, 3.7, z), Color = Color3.fromRGB(230, 234, 240), Material = Enum.Material.Metal }, parent)
			local bulb = mkPart("Part", decor({ Name = "PathLamp", Shape = Enum.PartType.Ball, Size = Vector3.new(2.2, 2.2, 2.2), CFrame = at(x, 8.3, z), Color = if (z / 30) % 2 < 1 then Color3.fromRGB(150, 220, 255) else Color3.fromRGB(255, 180, 220), Material = Enum.Material.Neon, Transparency = 0.15 }), parent)
			mk("PointLight", { Range = 14, Brightness = 0.7, Color = bulb.Color }, bulb)
			mkPart("Part", { Name = "Planter", Size = Vector3.new(4, 2, 8), CFrame = at(x + side * 4, 1.2, z + 7), Color = Color3.fromRGB(230, 234, 240), Material = Enum.Material.SmoothPlastic }, parent)
			for k = -1, 1 do
				local d = 3 + (k + 1) % 2
				local bush = mkPart("Part", decor({ Name = "Bush", Size = Vector3.new(d, d, d), CFrame = at(x + side * 4, 2.6, z + 7 + k * 2.4) * CFrame.Angles(math.rad(35), math.rad(45 + k * 20), 0), Color = Color3.fromRGB(80 + k * 10, 160, 80), Material = LOW }), parent)
				bush.CastShadow = true
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Lighting: a soft, natural afternoon. Much gentler than before (no blown-out whites).
----------------------------------------------------------------------------------------------------
local function getOrMake(className: string): Instance
	return Lighting:FindFirstChildOfClass(className) or mk(className, nil, Lighting)
end

local function setupLighting()
	Lighting.ClockTime = 15
	Lighting.Brightness = 1.3
	Lighting.ExposureCompensation = -0.35
	Lighting.Ambient = Color3.fromRGB(80, 84, 94)
	Lighting.OutdoorAmbient = Color3.fromRGB(100, 104, 116)
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.45
	Lighting.EnvironmentSpecularScale = 0.35

	local atmo = getOrMake("Atmosphere") :: Atmosphere
	atmo.Density = 0.3
	atmo.Offset = 0.1
	atmo.Color = Color3.fromRGB(199, 218, 240)
	atmo.Decay = Color3.fromRGB(120, 150, 190)
	atmo.Glare = 0
	atmo.Haze = 1

	local bloom = getOrMake("BloomEffect") :: BloomEffect
	bloom.Intensity = 0.15
	bloom.Size = 20
	bloom.Threshold = 2

	local cc = getOrMake("ColorCorrectionEffect") :: ColorCorrectionEffect
	cc.Saturation = 0.1
	cc.Contrast = 0.08
	cc.Brightness = -0.02

	local rays = getOrMake("SunRaysEffect") :: SunRaysEffect
	rays.Intensity = 0.03
	rays.Spread = 0.4
end

----------------------------------------------------------------------------------------------------
-- Build() / GetLobby() / GetSpawnCFrame()
----------------------------------------------------------------------------------------------------

-- Builds the whole lobby under workspace.Lobby. Safe to call once; a second call just returns the
-- existing Lobby table without building anything again.
function LobbyBuilder.Build(): Lobby
	if lobby then
		return lobby
	end

	local oldBase = Workspace:FindFirstChild("Baseplate")
	if oldBase then
		oldBase:Destroy()
	end
	local oldSpawn = Workspace:FindFirstChild("SpawnLocation")
	if oldSpawn and oldSpawn:IsA("BasePart") then
		oldSpawn:Destroy()
	end

	local model = Instance.new("Model")
	model.Name = "Lobby"
	model.Parent = Workspace

	-- Spawn first, so a player who spawns mid-build has a floor under them.
	buildSpawn(model)
	buildGround(model)
	buildRoom(model)

	local pads: { PadInfo } = {}
	for i = 1, PAD_COUNT do
		pads[i] = buildPad(model, i)
	end

	buildDishwasherBuilding(model)
	buildEggHatchery(model)
	buildSoapShop(model)
	buildPetStand(model)
	buildRoofLadder(model)

	-- Leaderboards in the back corners, angled at the middle of the plaza; How to Play beside the
	-- spawn, facing it. Nothing stands behind the spawn, so the default camera has a clear view.
	local timesBoard = buildBoard(model, -80, -74, "Fastest Clean", 0, 0, #Config.Levels)
	local dishesBoard = buildBoard(model, 80, -74, "Top Players", 0, 0, 3) -- dishes / rebirths / bubbles
	buildHowToPlay(model, 34, 44, SPAWN.X, SPAWN.Z)

	buildRankShrine(model)
	buildRebirthFountain(model)
	buildTreasureChest(model)
	buildEventZone(model)
	buildPathDressing(model)
	buildDecorations(model)
	setupLighting()

	local built: Lobby = {
		Model = model,
		Pads = pads,
		Boards = { Times = timesBoard, Dishes = dishesBoard },
	}
	lobby = built
	-- No Terrain anywhere (it used to cover the table with grass); wipe any saved in the place.
	pcall(function()
		workspace.Terrain:Clear()
	end)
	buildGarden(model)
	return built
end

function LobbyBuilder.GetLobby(): Lobby?
	return lobby
end

-- A random spot on the spawn pad, facing north toward the boards and pads.
function LobbyBuilder.GetSpawnCFrame(): CFrame
	local angle = math.random() * math.pi * 2
	local radius = 2 + math.random() * 8
	local pos = Vector3.new(ORIGIN.X + SPAWN.X + math.cos(angle) * radius, ORIGIN.Y + 3, ORIGIN.Z + SPAWN.Z + math.sin(angle) * radius)
	return CFrame.lookAt(pos, pos + Vector3.new(0, 0, -10))
end

return LobbyBuilder
