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
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

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
local dishwasherFolder: Folder? = nil -- every part of the big dishwasher building (so the show can smash it)
local southWall: BasePart? = nil -- the table's south edge wall (opened while the obby stands)
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
		Font = Enum.Font.LuckiestGuy,
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
	for _, spec: { any } in {
		{ Vector3.new(fx1 - fx0 + w * 2, h, w), at(0, h / 2, fz0 - w / 2) },
		{ Vector3.new(fx1 - fx0 + w * 2, h, w), at(0, h / 2, fz1 + w / 2), true },
		{ Vector3.new(w, h, fz1 - fz0), at(fx0 - w / 2, h / 2, (fz0 + fz1) / 2) },
		{ Vector3.new(w, h, fz1 - fz0), at(fx1 + w / 2, h / 2, (fz0 + fz1) / 2) },
	} do
		local wall = mkPart("Part", { Name = "Barrier", Size = spec[1], CFrame = spec[2], Transparency = 1, CastShadow = false }, parent)
		if spec[3] then
			southWall = wall -- opened while the obby stands (see OpenObby)
		end
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
		Font = Enum.Font.LuckiestGuy,
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
	local titleLbl = line("Title", 0, 0.2, "", Color3.fromRGB(255, 230, 140), Enum.Font.LuckiestGuy)
	local countLbl = line("Count", 0.2, 0.42, "0/" .. Config.Party.MaxPlayers, Color3.new(1, 1, 1), Enum.Font.LuckiestGuy)
	local statusLbl = line("Status", 0.63, 0.2, "Touch to create a party", Color3.new(1, 1, 1), Enum.Font.LuckiestGuy)
	local privacyLbl = line("Privacy", 0.84, 0.15, "", Color3.fromRGB(215, 230, 250), Enum.Font.SourceSansBold)

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
local function buildDishwasherBuilding(lobbyParent: Instance)
	local parent = Instance.new("Folder")
	parent.Name = "DishwasherBuilding"
	parent.Parent = lobbyParent
	dishwasherFolder = parent
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
		Font = Enum.Font.LuckiestGuy,
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
	local signText = mk("TextLabel", { Size = UDim2.fromScale(0.94, 0.86), Position = UDim2.fromScale(0.03, 0.07), BackgroundTransparency = 1, Text = "PETS & EGGS", Font = Enum.Font.LuckiestGuy, TextScaled = true, TextColor3 = Color3.new(1, 1, 1) }, signGui)
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
			Font = Enum.Font.LuckiestGuy,
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
			Font = Enum.Font.LuckiestGuy,
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
		Font = Enum.Font.LuckiestGuy,
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
			Font = Enum.Font.SourceSansBold,
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

-- The Treasure Chest event (Config.ChestEvent): a big gold-banded chest on stone steps inside a glowing
-- ring on the floor, facing the spawn. Only built while the event runs (servers restart with updates,
-- so it goes when the event does). No prompt: stepping INTO the ring shows the Open buttons and the odds
-- (ChestUI, which finds the chest by its "EventChest" tag and animates the lid; the ring's radius is
-- the model's ZoneRadius attribute). Every piece has its own size and height, so nothing z-fights.
local CHEST_ZONE_RADIUS = 11
local function buildTreasureChest(parent: Instance)
	if not Config.ChestEventLive() then
		return
	end
	local x, z = 34, 12
	local wood = Color3.fromRGB(150, 90, 48)
	local gold = Color3.fromRGB(255, 200, 60)
	local stone = Color3.fromRGB(226, 214, 190)
	local model = Instance.new("Model")
	model.Name = "TreasureChest"
	model.Parent = parent
	local function disc(name: string, d: number, thickness: number, centerY: number, color: Color3, material: Enum.Material?)
		return mkPart("Part", decor({ Name = name, Shape = Enum.PartType.Cylinder, Size = Vector3.new(thickness, d, d), CFrame = upright(x, centerY, z), Color = color, Material = material or LOW, CastShadow = false }), parent)
	end
	-- The zone: a glowing gold ring, then a darker floor inside it.
	local ring = disc("ChestRing", CHEST_ZONE_RADIUS * 2 + 1.2, 0.3, FLOOR_Y + 0.15, gold, Enum.Material.Neon)
	ring.Transparency = 0.2
	disc("ChestFloor", CHEST_ZONE_RADIUS * 2 - 0.4, 0.3, FLOOR_Y + 0.2, Color3.fromRGB(40, 70, 90), LOW)
	-- Stone steps up to the chest.
	local y = FLOOR_Y + 0.35
	for k, step in { { 15, 0.5 }, { 12.5, 0.5 }, { 10, 0.6 } } do
		mkPart("Part", { Name = "ChestStep" .. k, Shape = Enum.PartType.Cylinder, Size = Vector3.new(step[2], step[1], step[1]), CFrame = upright(x, y + step[2] / 2, z), Color = stone, Material = Enum.Material.Marble }, parent)
		y += step[2]
	end
	-- Face the spawn: the chest's front (-Z, where the lock is) points at it.
	local look = CFrame.lookAt(Vector3.new(x, 0, z), Vector3.new(SPAWN.X, 0, SPAWN.Z))
	local base = CFrame.new(x, y, z) * (look - look.Position)
	local W, H, D = 8.4, 4.8, 5.4
	local box = mkPart("Part", { Name = "ChestBox", Size = Vector3.new(W, H, D), CFrame = base * CFrame.new(0, H / 2, 0), Color = wood, Material = Enum.Material.Wood }, model)
	-- The lid: a half-round (cylinder) a touch shorter than the box, hinged at the back.
	local lid = mkPart("Part", { Name = "ChestLid", Shape = Enum.PartType.Cylinder, Size = Vector3.new(W - 0.1, D, D), CFrame = base * CFrame.new(0, H, 0), Color = Color3.fromRGB(170, 104, 56), Material = Enum.Material.Wood }, model)
	CollectionService:AddTag(lid, "EventChestLid")
	-- Gold bands stand proud of every face (0.15 out), so they never share a plane with the wood.
	for _, dx in { -2.7, 2.7 } do
		mkPart("Part", decor({ Name = "ChestBand", Size = Vector3.new(0.7, H + 0.3, D + 0.3), CFrame = base * CFrame.new(dx, H / 2, 0), Color = gold, Material = Enum.Material.Metal }), model)
		local band = mkPart("Part", decor({ Name = "LidBand", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.7, D + 0.3, D + 0.3), CFrame = base * CFrame.new(dx, H, 0), Color = gold, Material = Enum.Material.Metal }), model)
		band:SetAttribute("LidPart", true)
	end
	mkPart("Part", decor({ Name = "ChestTrim", Size = Vector3.new(W + 0.4, 0.5, D + 0.4), CFrame = base * CFrame.new(0, 0.25, 0), Color = gold, Material = Enum.Material.Metal }), model)
	-- Corner studs on the base.
	for _, cx in { -1, 1 } do
		for _, cz in { -1, 1 } do
			mkPart("Part", decor({ Name = "ChestStud", Shape = Enum.PartType.Ball, Size = Vector3.new(0.9, 0.9, 0.9), CFrame = base * CFrame.new(cx * (W / 2 + 0.05), 0.6, cz * (D / 2 + 0.05)), Color = gold, Material = Enum.Material.Metal }), model)
		end
	end
	local lock = mkPart("Part", decor({ Name = "ChestLock", Size = Vector3.new(1.4, 1.7, 0.4), CFrame = base * CFrame.new(0, H - 0.6, -D / 2 - 0.15), Color = gold, Material = Enum.Material.Metal }), model)
	lock:SetAttribute("LidPart", true)
	mkPart("Part", decor({ Name = "Keyhole", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, 0.45, 0.45), CFrame = lock.CFrame * CFrame.new(0, 0.1, -0.22) * CFrame.Angles(0, math.rad(90), 0), Color = Color3.fromRGB(40, 25, 15), Material = LOW }), model):SetAttribute("LidPart", true)
	-- Spilled treasure on the steps: coin stacks and gems, all at their own heights.
	local rng = Random.new(77)
	for k = 1, 9 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(5.3, 6.0) -- on the second step (its top is FLOOR_Y + 1.35)
		local cx, cz = x + math.cos(a) * r, z + math.sin(a) * r
		local stack = rng:NextInteger(2, 4)
		for n = 1, stack do
			mkPart("Part", decor({ Name = "Coin", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.18, 1.1, 1.1), CFrame = upright(cx, FLOOR_Y + 1.35 + 0.09 + (n - 1) * 0.2 + k * 0.001, cz), Color = gold, Material = Enum.Material.Metal }), parent)
		end
	end
	for k, c in { Color3.fromRGB(255, 90, 140), Color3.fromRGB(90, 200, 255), Color3.fromRGB(150, 255, 150), Color3.fromRGB(190, 120, 255) } do
		local a = k * 1.57 + 0.5
		local gx, gz = x + math.cos(a) * 5.65, z + math.sin(a) * 5.65
		mkPart("Part", decor({ Name = "Gem", Size = Vector3.new(0.9, 1.2, 0.9), CFrame = CFrame.new(gx, FLOOR_Y + 1.35 + 0.6 + k * 0.01, gz) * CFrame.Angles(math.rad(20), a, math.rad(25)), Color = c, Material = Enum.Material.Neon, CastShadow = false }), parent)
	end
	-- Two lantern posts either side of the steps.
	for _, side in { -1, 1 } do
		local pxp = x + side * 9.2
		mkPart("Part", { Name = "LanternPost", Shape = Enum.PartType.Cylinder, Size = Vector3.new(6.5, 0.7, 0.7), CFrame = upright(pxp, FLOOR_Y + 3.6, z - 3), Color = Color3.fromRGB(80, 60, 50), Material = Enum.Material.Metal }, parent)
		local bulb = mkPart("Part", decor({ Name = "Lantern", Shape = Enum.PartType.Ball, Size = Vector3.new(1.6, 1.6, 1.6), CFrame = at(pxp, FLOOR_Y + 7.3, z - 3), Color = Color3.fromRGB(255, 190, 90), Material = Enum.Material.Neon, Transparency = 0.1 }), parent)
		mk("PointLight", { Range = 16, Brightness = 0.9, Color = Color3.fromRGB(255, 200, 120) }, bulb)
	end
	-- The glow inside, seen when the lid opens.
	local glow = mkPart("Part", decor({ Name = "ChestGlow", Size = Vector3.new(1, 1, 1), CFrame = base * CFrame.new(0, H + 1.8, 0), Transparency = 1, CastShadow = false }), model)
	mk("PointLight", { Range = 20, Brightness = 1.3, Color = Color3.fromRGB(255, 210, 120) }, glow)
	mk("ParticleEmitter", {
		Texture = "rbxasset://textures/particles/sparkles_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(255, 225, 120)),
		Size = NumberSequence.new(0.9, 0),
		Lifetime = NumberRange.new(0.9, 1.8),
		Rate = 16,
		Speed = NumberRange.new(2, 5),
		SpreadAngle = Vector2.new(60, 60),
	}, glow)
	model.PrimaryPart = box
	model:SetAttribute("ZoneRadius", CHEST_ZONE_RADIUS)
	CollectionService:AddTag(model, "EventChest")
	worldSign(box, "LIMITED TREASURE CHEST", 15, 2.8, 19, Color3.fromRGB(255, 215, 90))
	worldSign(box, "Sunken Treasure event", 9, 1.4, 16.2, Color3.fromRGB(190, 235, 255))
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
	local title = mk("TextLabel", { Name = "Title", Size = UDim2.fromScale(1, 0.45), BackgroundTransparency = 1, Text = "NEXT EVENT", Font = Enum.Font.LuckiestGuy, TextScaled = true, TextColor3 = Color3.fromRGB(255, 200, 230) }, gui)
	mk("UIStroke", { Thickness = 3, Color = Color3.fromRGB(12, 30, 60) }, title)
	local when = mk("TextLabel", { Name = "When", Position = UDim2.fromScale(0, 0.45), Size = UDim2.fromScale(1, 0.55), BackgroundTransparency = 1, Text = "", Font = Enum.Font.LuckiestGuy, TextScaled = true, TextColor3 = Color3.new(1, 1, 1) }, gui)
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
-- The obby (only exists while the Admin Abuse show has it open: LobbyBuilder.OpenObby builds it up
-- piece by piece, LobbyBuilder.BreakObby smashes it and the pieces fade away). Behind the spawn, off
-- the table's edge and out over the room toward the sofa: five checkpoints and seven stages, a
-- finish on a high platform. Falling or touching a spinner puts you on your last checkpoint.
----------------------------------------------------------------------------------------------------
local OBBY_COLORS = {
	Color3.fromRGB(86, 168, 255),
	Color3.fromRGB(255, 124, 178),
	Color3.fromRGB(255, 205, 80),
	Color3.fromRGB(110, 220, 160),
	Color3.fromRGB(176, 140, 255),
}
local OBBY_CHECKPOINTS = 5
local OBBY_BOX = { X0 = -30, X1 = 340, Z0 = 66, Z1 = 396 }

local obbyModel: Model? = nil
local obbyOpen = false -- built and playable
local obbyBeat: RBXScriptConnection? = nil
local obbyProgress: { [number]: number } = {} -- userId -> highest checkpoint reached
local obbySpawnAt: { [number]: CFrame } = {}
local obbyLastPrize: { [number]: number } = {}

local function playerOfPart(hit: BasePart): Player?
	local character = hit:FindFirstAncestorOfClass("Model")
	return if character then Players:GetPlayerFromCharacter(character) else nil
end

local function onTouch(part: BasePart, fn: (BasePart) -> ())
	pcall(function()
		part.Touched:Connect(fn)
	end)
end

local function notifyPlayer(player: Player, text: string, kind: string)
	pcall(function()
		Remotes.Event("Notify"):FireClient(player, text, kind)
	end)
end

local function sendToLobbySpawn(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local angle = math.random() * math.pi * 2
	local pos = Vector3.new(ORIGIN.X + SPAWN.X + math.cos(angle) * 6, ORIGIN.Y + 4, ORIGIN.Z + SPAWN.Z + math.sin(angle) * 6)
	;(character :: Model):PivotTo(CFrame.lookAt(pos, pos + Vector3.new(0, 0, -10)))
	root.AssemblyLinearVelocity = Vector3.zero
end

local function sendToCheckpoint(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local cf = obbySpawnAt[player.UserId]
	if not root then
		return
	end
	if not obbyOpen or not cf then
		-- no checkpoint yet: the start pad
		local pad = if obbyModel then obbyModel:FindFirstChild("Start") :: BasePart? else nil
		if pad and obbyOpen then
			cf = pad.CFrame
		else
			sendToLobbySpawn(player)
			return
		end
	end
	;(character :: Model):PivotTo((cf :: CFrame) + Vector3.new(0, 4, 0))
	root.AssemblyLinearVelocity = Vector3.zero
end

local function constructObby(parent: Instance): { Model: Model, Parts: { BasePart } }
	local model = mk("Model", { Name = "Obby" }, parent) :: Model
	local colorIndex = 0
	local function nextColor(): Color3
		colorIndex = colorIndex % #OBBY_COLORS + 1
		return OBBY_COLORS[colorIndex]
	end
	-- A chunky platform: a coloured slab with a darker underside (top surface at yTop). extra.Bare:
	-- no underside (parts that move or vanish).
	local function plat(name: string, cx: number, yTop: number, cz: number, sx: number, sz: number, color: Color3?, extra: { [string]: any }?): BasePart
		local c = color or nextColor()
		local top = mkPart("Part", {
			Name = name,
			Size = Vector3.new(sx, 2, sz),
			CFrame = at(cx, yTop - 1, cz),
			Color = c,
			Material = LOW,
			CanTouch = true,
		}, model)
		if extra then
			for k, v in extra do
				if k ~= "Bare" then
					(top :: any)[k] = v
				end
			end
		end
		if not (extra and extra.Bare) then
			mkPart("Part", { Name = "Underside", Size = Vector3.new(sx - 1.2, 1.2, sz - 1.2), CFrame = at(cx, yTop - 2.7, cz), Color = shadeColor(c, 0.55), Material = LOW, CanCollide = false, CanQuery = false, CastShadow = false }, model)
		end
		return top
	end
	local killParts: { BasePart } = {}
	local function kill(name: string, size: Vector3, cf: CFrame, color: Color3): BasePart
		local part = mkPart("Part", {
			Name = name,
			Size = size,
			CFrame = cf,
			Color = color,
			Material = Enum.Material.Neon,
			CanTouch = true,
			CanCollide = false,
			CastShadow = false,
		}, model)
		table.insert(killParts, part)
		return part
	end
	local checkpointPads: { BasePart } = {}
	local function checkpoint(index: number, cx: number, yTop: number, cz: number)
		local pad = plat("Checkpoint" .. index, cx, yTop, cz, 20, 20, Color3.fromRGB(70, 205, 130))
		pad:SetAttribute("Index", index)
		-- A glowing flag so it reads from far away (pole and flag don't share any face).
		mkPart("Part", decor({ Name = "FlagPole", Size = Vector3.new(0.6, 12, 0.6), CFrame = at(cx - 8, yTop + 6.2, cz - 8), Color = Color3.fromRGB(240, 240, 240), Material = LOW }), model)
		mkPart("Part", decor({ Name = "Flag", Size = Vector3.new(0.3, 4, 6), CFrame = at(cx - 8, yTop + 10, cz - 4.8), Color = Color3.fromRGB(255, 255, 255), Material = Enum.Material.Neon }), model)
		worldSign(pad, "CHECKPOINT " .. index, 22, 4, 16, Color3.fromRGB(150, 255, 190))
		table.insert(checkpointPads, pad)
	end

	local Y = 0.2

	-- Start: a wide pad on the table's edge with a gate and a sign (the sign hangs ABOVE the gate beam).
	local startPad = plat("Start", 0, Y, 92.4, 28, 24, Color3.fromRGB(255, 255, 255))
	for _, sx in { -13, 13 } do
		mkPart("Part", decor({ Name = "GatePost", Size = Vector3.new(2, 22, 2), CFrame = at(sx, Y + 11, 92.4), Color = Color3.fromRGB(255, 205, 80), Material = LOW }), model)
	end
	local gateBeam = mkPart("Part", decor({ Name = "GateBeam", Size = Vector3.new(31, 5, 3.4), CFrame = at(0, Y + 23.5, 92.4), Color = Color3.fromRGB(255, 124, 178), Material = LOW }), model)
	worldSign(gateBeam, "OBBY", 26, 7, 8, Color3.fromRGB(255, 255, 255))
	worldSign(startPad, "Reach the top for a prize!", 24, 3, 9, Color3.fromRGB(255, 232, 140))

	-- Stage 1: hops (6 platforms, 6-stud gaps).
	do
		local dx = { 0, -7, 0, 7, 0, -6 }
		local dy = { 0, 0, 1.5, 3, 3, 1.5 }
		for i = 1, 6 do
			plat("Hop" .. i, dx[i], Y + dy[i], 113 + (i - 1) * 15, 9, 9)
		end
	end
	checkpoint(1, -2, Y + 1.5, 210)

	-- Stage 2: stepping stones over the drop (a fall puts you back).
	do
		local dx = { 0, -8, 0, 8, 0 }
		for i = 1, 5 do
			plat("Stone" .. i, dx[i], Y + 1.5, 226 + (i - 1) * 14, 7, 7)
		end
	end
	checkpoint(2, 0, Y + 1.5, 298)

	-- Stage 3: the spinner deck (jump the bars), running along +X.
	plat("SpinnerDeck", 66, Y + 1.5, 300, 104, 16, Color3.fromRGB(255, 255, 255))
	local spinners: { { Part: BasePart, Speed: number, Center: Vector3 } } = {}
	for i, x in { 38, 66, 94 } do
		local center = at(x, Y + 1.5 + 2.2, 300).Position
		local bar = kill("Spinner" .. i, Vector3.new(26, 3, 2.4), CFrame.new(center), if i % 2 == 0 then Color3.fromRGB(255, 70, 90) else Color3.fromRGB(255, 190, 50))
		mkPart("Part", decor({ Name = "SpinnerHub", Size = Vector3.new(4, 4.4, 4), CFrame = CFrame.new(center), Color = Color3.fromRGB(60, 64, 78), Material = LOW }), model)
		table.insert(spinners, { Part = bar, Speed = (if i % 2 == 0 then -1 else 1) * (1.1 + i * 0.35), Center = center })
	end
	checkpoint(3, 134, Y + 1.5, 300)

	-- Stage 4: three sliders crossing the way (they carry you).
	local sliders: { { Part: BasePart, Base: Vector3, Phase: number, Speed: number } } = {}
	for i, x in { 156, 171, 186 } do
		local p = plat("Slider" .. i, x, Y + 1.5, 300, 8, 8, nil, { Bare = true })
		table.insert(sliders, { Part = p, Base = p.Position, Phase = i * 1.7, Speed = 0.9 + i * 0.12 })
	end
	checkpoint(4, 206, Y + 1.5, 300)

	-- Stage 5: vanishing tiles (they go almost the moment you touch them).
	local tiles: { BasePart } = {}
	for col = 1, 4 do
		for row = -1, 1 do
			table.insert(tiles, plat("Tile", 226 + (col - 1) * 11, Y + 1.5, 300 + row * 11, 8.5, 8.5, Color3.fromRGB(255, 228, 120), { Bare = true }))
		end
	end

	-- Stage 6: a conveyor belt that runs against you.
	local conveyor = plat("Conveyor", 285, Y + 1.5, 300, 30, 12, Color3.fromRGB(70, 74, 92), { Bare = true })
	for i = -2, 2 do
		mkPart("Part", decor({ Name = "ConveyorStripe", Size = Vector3.new(1.4, 0.2, 11), CFrame = at(285 + i * 6, Y + 1.6, 300), Color = Color3.fromRGB(255, 205, 60), Material = LOW }), model)
	end
	plat("Landing", 312, Y + 1.5, 300, 12, 12, nil)

	-- Stage 7: balance beams (round the corner and back over the sofa): thin ones.
	plat("Beam1", 312, Y + 3, 322, 0.8, 32, Color3.fromRGB(255, 255, 255), { Bare = true })
	plat("Corner", 312, Y + 3, 345, 10, 10, nil)
	plat("Beam2a", 275.5, Y + 3, 345, 51, 0.8, Color3.fromRGB(255, 255, 255), { Bare = true })
	plat("Beam2b", 220, Y + 3, 345, 48, 0.8, Color3.fromRGB(255, 255, 255), { Bare = true })
	checkpoint(5, 180, Y + 3, 345)

	-- Stage 8: the climb: stairs of small platforms up to the finish.
	for i = 1, 8 do
		plat("Stair" .. i, 180 - 10 - i * 11, Y + 3 + i * 3.5, 345 + (if i % 2 == 0 then 3 else -3), 7, 7)
	end
	local finishTop = Y + 3 + 8 * 3.5 + 3
	local finish = plat("Finish", 56, finishTop, 345, 24, 24, Color3.fromRGB(255, 205, 60))
	for _, dz in { -10, 10 } do
		mkPart("Part", decor({ Name = "FinishPost", Size = Vector3.new(2, 18, 2), CFrame = at(56, finishTop + 9, 345 + dz), Color = Color3.fromRGB(255, 124, 178), Material = LOW }), model)
	end
	local arch = mkPart("Part", decor({ Name = "FinishArch", Size = Vector3.new(3.4, 4, 22.6), CFrame = at(56, finishTop + 19.5, 345), Color = Color3.fromRGB(255, 124, 178), Material = LOW }), model)
	worldSign(arch, "FINISH", 24, 7, 8, Color3.fromRGB(255, 255, 255))
	-- The trophy: a gold cup of stacked blocks.
	mkPart("Part", decor({ Name = "TrophyBase", Size = Vector3.new(6, 2, 6), CFrame = at(56, finishTop + 1, 345), Color = Color3.fromRGB(120, 80, 50), Material = LOW }), model)
	mkPart("Part", decor({ Name = "TrophyStem", Size = Vector3.new(2, 4, 2), CFrame = at(56, finishTop + 4, 345), Color = Color3.fromRGB(255, 205, 60), Material = Enum.Material.Metal }), model)
	mkPart("Part", decor({ Name = "TrophyCup", Size = Vector3.new(6.4, 5, 6.4), CFrame = at(56, finishTop + 8.6, 345), Color = Color3.fromRGB(255, 215, 80), Material = Enum.Material.Metal }), model)

	-- ----- Runtime ----------------------------------------------------------------------------
	-- Flying (the admin fly, or the one the show offers) doesn't count: no checkpoint or finish while in the air.
	local function flyingNow(player: Player): boolean
		local ch = player.Character
		local root = ch and ch:FindFirstChild("HumanoidRootPart")
		if not root then
			return false
		end
		return root:FindFirstChildWhichIsA("LinearVelocity") ~= nil or root:FindFirstChildWhichIsA("BodyVelocity") ~= nil or root:FindFirstChildWhichIsA("BodyPosition") ~= nil
	end
	for _, pad in checkpointPads do
		onTouch(pad, function(hit)
			local player = playerOfPart(hit)
			local index = pad:GetAttribute("Index")
			if obbyOpen and player and not flyingNow(player) and type(index) == "number" and (obbyProgress[player.UserId] or 0) < index then
				obbyProgress[player.UserId] = index
				obbySpawnAt[player.UserId] = pad.CFrame + Vector3.new(0, 1, 0)
				notifyPlayer(player, string.format("Checkpoint %d of %d!", index, OBBY_CHECKPOINTS), "Good")
			end
		end)
	end
	local lastHit: { [number]: number } = {}
	for _, part in killParts do
		onTouch(part, function(hit)
			local player = playerOfPart(hit)
			if obbyOpen and player and os.clock() - (lastHit[player.UserId] or 0) > 0.6 then
				lastHit[player.UserId] = os.clock()
				sendToCheckpoint(player)
			end
		end)
	end
	onTouch(finish, function(hit)
		local player = playerOfPart(hit)
		if not obbyOpen or not player or flyingNow(player) or (obbyProgress[player.UserId] or 0) < OBBY_CHECKPOINTS then
			return
		end
		obbyProgress[player.UserId] = 0
		obbySpawnAt[player.UserId] = nil
		local show = ReplicatedStorage:GetAttribute("AbuseObbyOpen") == true
		local last = obbyLastPrize[player.UserId] or -1e9
		local gems = if show then Config.Obby.ShowGems else Config.Obby.Gems
		if show or os.clock() - last > Config.Obby.Cooldown then
			obbyLastPrize[player.UserId] = os.clock()
			task.spawn(function()
				local okData, DataService = pcall(function()
					return require(script.Parent:WaitForChild("DataService"))
				end)
				local okGift, GiftService = pcall(function()
					return require(script.Parent:WaitForChild("GiftService"))
				end)
				if okData then
					DataService.AddGems(player, gems)
				end
				if okGift and not show then
					-- (during the show the director shows ONE popup for it: first finisher or not)
					(GiftService :: any).Celebrate(player, "You beat the obby!", string.format("You got %d Gems!", gems), "@Gem")
				end
			end)
			-- The show hears who finished (it announces and rewards the first one in every server).
			ReplicatedStorage:SetAttribute("AbuseObbyFinish", player.Name .. ":" .. tostring(os.clock()))
		else
			notifyPlayer(player, "You finished! (Prize again in a few minutes)", "Info")
		end
		-- Back to the lobby spawn (a moment later, so the popup isn't fighting the teleport).
		task.delay(0.8, function()
			sendToLobbySpawn(player)
		end)
	end)

	local tileBusy: { [BasePart]: boolean } = {}
	for _, t in tiles do
		onTouch(t, function(hit)
			if tileBusy[t] or not obbyOpen or not playerOfPart(hit) then
				return
			end
			tileBusy[t] = true
			task.delay(0.1, function()
				TweenService:Create(t, TweenInfo.new(0.12), { Transparency = 1 }):Play()
				task.wait(0.12)
				t.CanCollide = false
				task.wait(2.4)
				if t.Parent then
					t.CanCollide = true
					TweenService:Create(t, TweenInfo.new(0.25), { Transparency = 0 }):Play()
				end
				tileBusy[t] = false
			end)
		end)
	end
	pcall(function()
		conveyor.AssemblyLinearVelocity = Vector3.new(-15, 0, 0) -- anchored parts still carry whoever stands on them
	end)

	-- The moving parts, once a frame. Sliders carry the players standing on them.
	local beat: any = RunService.Heartbeat
	local clock, fallClock = 0, 0
	if beat then
		obbyBeat = beat:Connect(function(dt)
			clock += dt
			fallClock += dt
			for _, s in spinners do
				s.Part.CFrame = CFrame.new(s.Center) * CFrame.Angles(0, clock * s.Speed, 0)
			end
			for _, s in sliders do
				-- The platform is moved by position AND given its velocity: the Humanoid carries whoever
				-- stands on it by the floor's velocity (moving the character from the server fights the
				-- player's own physics and rubber-bands).
				local p = s.Part
				local phase = clock * s.Speed + s.Phase
				p.Position = s.Base + Vector3.new(0, 0, 13 * math.sin(phase))
				p.AssemblyLinearVelocity = Vector3.new(0, 0, 13 * s.Speed * math.cos(phase))
			end
			if fallClock > 0.3 then
				fallClock = 0
				for _, player in Players:GetPlayers() do
					local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if root and obbyOpen then
						local p = root.Position - ORIGIN
						if p.Y < -35 and p.Y > -125 and p.X > OBBY_BOX.X0 and p.X < OBBY_BOX.X1 and p.Z > OBBY_BOX.Z0 and p.Z < OBBY_BOX.Z1 then
							sendToCheckpoint(player)
						end
					end
				end
			end
		end)
	end

	local parts: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	return { Model = model, Parts = parts }
end

-- Builds the obby up piece by piece (about 10 seconds), then it is playable. The gate in the table's
-- edge wall opens.
function LobbyBuilder.OpenObby()
	if obbyModel or not lobby then
		return
	end
	local built = constructObby(lobby.Model)
	obbyModel = built.Model
	local n = #built.Parts
	for i, part in built.Parts do
		local finalCF, finalT, finalCollide = part.CFrame, part.Transparency, part.CanCollide
		if finalT < 0.95 and not rawget(_G, "__RINSE_NO_ANIM") then
			part.Transparency = 1
			part.CanCollide = false
			part.CFrame = finalCF - Vector3.new(0, 45, 0)
			task.delay((i / n) * 9, function()
				if not part.Parent or not obbyModel then
					return
				end
				local tween = TweenService:Create(part, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = finalT, CFrame = finalCF })
				tween.Completed:Connect(function()
					if part.Parent then
						part.CanCollide = finalCollide
					end
				end)
				tween:Play()
			end)
		end
	end
	task.delay(10, function()
		if obbyModel == built.Model then
			obbyOpen = true
			local wall = southWall
			if wall then
				wall.CanCollide = false
			end
		end
	end)
end

function LobbyBuilder.ObbyExists(): boolean
	return obbyModel ~= nil
end

-- Smashes it: every piece drops to the floor, then fades away; the table's edge wall closes again.
function LobbyBuilder.BreakObby()
	local model = obbyModel
	if not model then
		return
	end
	obbyOpen = false
	obbyModel = nil
	if obbyBeat then
		obbyBeat:Disconnect()
		obbyBeat = nil
	end
	table.clear(obbyProgress)
	table.clear(obbySpawnAt)
	local wall = southWall
	if wall then
		wall.CanCollide = true
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if d.Transparency >= 0.95 then
				d:Destroy()
			else
				task.delay(math.random() * 2, function()
					if not d.Parent then
						return
					end
					d.Anchored = false
					d.CanCollide = true
					d.CanTouch = false
					d.AssemblyLinearVelocity = Vector3.new(math.random(-30, 30), math.random(5, 35), math.random(-30, 30))
					d.AssemblyAngularVelocity = Vector3.new(math.random(-6, 6), math.random(-6, 6), math.random(-6, 6))
				end)
			end
		end
	end
	task.delay(6, function()
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				TweenService:Create(d, TweenInfo.new(2.4), { Transparency = 1 }):Play()
			end
		end
	end)
	task.delay(9, function()
		model:Destroy()
	end)
end

----------------------------------------------------------------------------------------------------
-- Holes in the table (Admin Abuse). Config.AbuseShow.Holes = { { x, z, radius } }. The table top,
-- slab and the invisible floor under it are cut into small tiles around the spot: the tiles inside
-- the circle fall away, the ones on the rim tilt and crack, things standing there fall too, and
-- HealHoles puts it all back (the hole closes in from the rim, the props return).
----------------------------------------------------------------------------------------------------
type Tile = { Part: BasePart, Flat: CFrame, D: number, Fall: boolean, Transparency: number }
type HoleRec = {
	Hidden: { BasePart },
	Pieces: { Instance },
	Tiles: { Tile },
	Props: { { Part: BasePart, CF: CFrame, Anchored: boolean, Collide: boolean } },
	Cracks: { BasePart },
	Center: Vector3,
	Radius: number,
}
local holes: { [number]: HoleRec } = {}
local pieceFolderRoof: { [Instance]: boolean } = {} -- which hole folders hold ceiling pieces and which table pieces
-- (TableApron is the slab under the planks: it has to be cut too, or a "hole" has a floor and nobody can fall through it)
local TABLE_PART_NAMES = { SafetyFloor = true, TableSlab = true, Plank = true, Chamfer = true, TableApron = true }
local TILE = 5.5

local function worldBox(part: BasePart): (Vector3, Vector3)
	local cf, s = part.CFrame, part.Size
	local ex = (math.abs(cf.RightVector.X) * s.X + math.abs(cf.UpVector.X) * s.Y + math.abs(cf.LookVector.X) * s.Z) / 2
	local ey = (math.abs(cf.RightVector.Y) * s.X + math.abs(cf.UpVector.Y) * s.Y + math.abs(cf.LookVector.Y) * s.Z) / 2
	local ez = (math.abs(cf.RightVector.Z) * s.X + math.abs(cf.UpVector.Z) * s.Y + math.abs(cf.LookVector.Z) * s.Z) / 2
	return cf.Position, Vector3.new(ex, ey, ez)
end

-- Makes `clone` the box [x0,x1] x [y0,y1] x [z0,z1] in world space (the source part's own turn kept).
local function setBox(clone: BasePart, source: BasePart, x0: number, x1: number, y0: number, y1: number, z0: number, z1: number)
	local rot = source.CFrame.Rotation
	local swapped = math.abs(rot.RightVector.X) < 0.5
	local wx, wy, wz = x1 - x0, y1 - y0, z1 - z0
	clone.Size = if swapped then Vector3.new(wz, wy, wx) else Vector3.new(wx, wy, wz)
	clone.CFrame = CFrame.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2) * rot
end

local ROOF_PART_NAMES = { Ceiling = true, CeilingBeam = true, Crown = true }

-- Cuts a round hole (tiles fall, rim tilts) in the named parts around (x, z). opts.Roof: the ceiling
-- (bigger tiles, no props / cracks / glow, and the falling tiles never collide with anyone).
-- Prompts and floating labels belong to the thing they sit on: when it is smashed or falls into a hole they go
-- off with it (and come back when it is put back).
local function switchOffUiOn(part: BasePart, store: { Instance })
	for _, d in part:GetDescendants() do
		if (d:IsA("ProximityPrompt") or d:IsA("BillboardGui")) and d.Enabled then
			table.insert(store, d)
			d.Enabled = false
		end
	end
end
local function cutDisc(index: number, holeX: number, holeZ: number, R: number, names: { [string]: boolean }, opts: { Roof: boolean?, Launch: Vector3? })
	local model = lobby and lobby.Model
	if not model or holes[index] then
		return
	end
	local roof = opts.Roof == true
	local TILE = if roof then 11 elseif R >= 30 then 9 else TILE -- (big holes: bigger tiles, so a half-table crater is not thousands of parts)
	local cx, cz = ORIGIN.X + holeX, ORIGIN.Z + holeZ
	local S = R + 10
	local rec: HoleRec = { Hidden = {}, Pieces = {}, Tiles = {}, Props = {}, Cracks = {}, Center = Vector3.new(cx, ORIGIN.Y, cz), Radius = R }
	holes[index] = rec
	local holeUi: { Instance } = {}
	(rec :: any).Ui = holeUi
	local folder = mk("Folder", { Name = "HolePieces" .. index }, Workspace) :: Folder
	table.insert(rec.Pieces, folder)

	-- Anyone close to it is moved clear first.
	for _, player in Players:GetPlayers() do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local offset = Vector3.new(root.Position.X - cx, 0, root.Position.Z - cz)
			if offset.Magnitude < R + 6 and root.Position.Y < 60 then
				local dir = if offset.Magnitude > 0.5 then offset.Unit else Vector3.new(0, 0, 1)
				local out = Vector3.new(cx, 0, cz) + dir * (R + 18)
				;(player.Character :: Model):PivotTo(CFrame.new(out.X, root.Position.Y + 2, out.Z))
			end
		end
	end

	local sources: { BasePart } = {}
	for _, p in model:GetChildren() do
		if p:IsA("BasePart") and names[p.Name] then
			local c, e = worldBox(p)
			if c.X + e.X > cx - S and c.X - e.X < cx + S and c.Z + e.Z > cz - S and c.Z - e.Z < cz + S then
				table.insert(sources, p)
			end
		end
	end
	-- Pieces left standing by EARLIER holes are cut too (the originals are gone from the model by then: without
	-- this a second hole next to or inside the first only had its props and glow, and the table stayed whole).
	local fromPieces: { [BasePart]: boolean } = {}
	for _, f in Workspace:GetChildren() do
		if f:IsA("Folder") and pieceFolderRoof[f] == roof then
			for _, p in f:GetChildren() do
				if p:IsA("BasePart") and p.Name == "HolePiece" and p.Anchored then
					local c, e = worldBox(p)
					if c.X + e.X > cx - S and c.X - e.X < cx + S and c.Z + e.Z > cz - S and c.Z - e.Z < cz + S then
						table.insert(sources, p)
						fromPieces[p] = true
					end
				end
			end
		end
	end
	pieceFolderRoof[folder] = roof
	local rng = Random.new(index * 97 + 5)
	for _, p in sources do
		local c, e = worldBox(p)
		local invisible = p.Transparency >= 0.95
		local px0, px1, pz0, pz1 = c.X - e.X, c.X + e.X, c.Z - e.Z, c.Z + e.Z
		local y0, y1 = c.Y - e.Y, c.Y + e.Y
		local ix0, ix1 = math.max(px0, cx - S), math.min(px1, cx + S)
		local iz0, iz1 = math.max(pz0, cz - S), math.min(pz1, cz + S)
		local function piece(x0: number, x1: number, z0: number, z1: number): BasePart
			local clone = p:Clone() :: BasePart
			clone.Name = "HolePiece"
			setBox(clone, p, x0, x1, y0, y1, z0, z1)
			clone.Parent = folder
			return clone
		end
		if px0 < ix0 - 0.01 then
			piece(px0, ix0, pz0, pz1)
		end
		if px1 > ix1 + 0.01 then
			piece(ix1, px1, pz0, pz1)
		end
		if pz0 < iz0 - 0.01 then
			piece(ix0, ix1, pz0, iz0)
		end
		if pz1 > iz1 + 0.01 then
			piece(ix0, ix1, iz1, pz1)
		end
		local x = ix0
		while x < ix1 - 0.01 do
			local x1 = math.min(x + TILE, ix1)
			local z = iz0
			while z < iz1 - 0.01 do
				local z1 = math.min(z + TILE, iz1)
				local tcx, tcz = (x + x1) / 2, (z + z1) / 2
				local d = math.sqrt((tcx - cx) ^ 2 + (tcz - cz) ^ 2) + (rng:NextNumber() - 0.5) * 6
				if d < R then
					if not invisible then
						local tile = piece(x, x1, z, z1)
						local flat = tile.CFrame
						tile.Anchored = false
						tile.CanCollide = not roof
						table.insert(rec.Tiles, { Part = tile, Flat = flat, D = d, Fall = true, Transparency = tile.Transparency })
						tile.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(-4, 6), rng:NextNumber(-8, 8))
						tile.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-3, 3), rng:NextNumber(-3, 3), rng:NextNumber(-3, 3))
					end
				else
					local tile = piece(x, x1, z, z1)
					if d < R + 9 and not invisible then
						-- the broken rim: crooked, a little sunk
						local flat = tile.CFrame
						local axis = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
						axis = if axis.Magnitude > 0.1 then axis.Unit else Vector3.xAxis
						tile.CFrame = flat * CFrame.fromAxisAngle(flat:VectorToObjectSpace(axis), math.rad(rng:NextNumber(3, 9))) - Vector3.new(0, rng:NextNumber(0.1, 0.7), 0)
						table.insert(rec.Tiles, { Part = tile, Flat = flat, D = d, Fall = false, Transparency = tile.Transparency })
					end
				end
				z = z1
			end
			x = x1
		end
		p.Parent = nil
		if not fromPieces[p] then
			table.insert(rec.Hidden, p)
		else
			p:Destroy() -- (a piece of an earlier hole: replaced by the smaller pieces cut from it)
		end
	end

	if not roof then
		-- (no crack lines on the table: they just looked like black scribbles)
		-- A glow and smoke from below.
		local glow = mkPart("Part", { Name = "HoleGlow", Size = Vector3.new(2, 2, 2), CFrame = CFrame.new(cx, ORIGIN.Y - 14, cz), Transparency = 1, CanCollide = false, CastShadow = false }, folder)
		mk("PointLight", { Color = Color3.fromRGB(255, 120, 50), Range = 70, Brightness = 3, Shadows = false }, glow)
		mk("ParticleEmitter", {
			Texture = "rbxasset://textures/particles/smoke_main.dds",
			Color = ColorSequence.new(Color3.fromRGB(60, 50, 46)),
			Lifetime = NumberRange.new(2, 3.5),
			Speed = NumberRange.new(10, 22),
			SpreadAngle = Vector2.new(20, 20),
			Rate = 14,
			Size = NumberSequence.new(6, 16),
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }),
			EmissionDirection = Enum.NormalId.Top,
		}, glow)
		mk("ParticleEmitter", {
			Texture = "rbxasset://textures/particles/sparkles_main.dds",
			Color = ColorSequence.new(Color3.fromRGB(255, 170, 70)),
			Lifetime = NumberRange.new(1, 2),
			Speed = NumberRange.new(20, 40),
			SpreadAngle = Vector2.new(35, 35),
			Rate = 18,
			Size = NumberSequence.new(1.6, 0),
			LightEmission = 1,
			EmissionDirection = Enum.NormalId.Top,
		}, glow)

		-- Whatever stands in it falls with it (boards, cups, sponge, shakers...).
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Anchored and d.Transparency < 0.95 and d.Name ~= "Barrier" and not string.find(d.Name, "^Bubble") and not TABLE_PART_NAMES[d.Name] and d.Size.Y < 70 then
				local dx, dz = d.Position.X - cx, d.Position.Z - cz
				local y = d.Position.Y - ORIGIN.Y
				if math.sqrt(dx * dx + dz * dz) < R + 4 and y > -1 and y < 60 and not d:IsDescendantOf(folder) then
					table.insert(rec.Props, { Part = d, CF = d.CFrame, Anchored = d.Anchored :: boolean, Collide = d.CanCollide })
					switchOffUiOn(d, holeUi)
				end
			end
		end
		for _, prop in rec.Props do
			task.delay(rng:NextNumber(0.1, 0.9), function()
				prop.Part.Anchored = false
				prop.Part.CanCollide = true
				prop.Part.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-2, 2), rng:NextNumber(-2, 2), rng:NextNumber(-2, 2))
				if opts.Launch then
					-- punched: it flies off in the direction of the punch
					prop.Part.AssemblyLinearVelocity = opts.Launch + Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(0, 25), rng:NextNumber(-12, 12))
					prop.Part.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-9, 9), rng:NextNumber(-9, 9), rng:NextNumber(-9, 9))
				end
			end)
		end
		-- Chunks flung out of it.
		for i = 1, 20 do
			local size = rng:NextNumber(1.2, 3.6)
			local chunk = mkPart("Part", {
				Name = "HoleChunk",
				Size = Vector3.new(size, size * 0.6, size * 1.3),
				CFrame = CFrame.new(cx + rng:NextNumber(-R * 0.6, R * 0.6), ORIGIN.Y + 2, cz + rng:NextNumber(-R * 0.6, R * 0.6)),
				Color = if i % 3 == 0 then WOOD_DARK else WOOD_A,
				Material = LOW,
				Anchored = false,
			}, folder)
			chunk.AssemblyLinearVelocity = Vector3.new(rng:NextNumber(-40, 40), rng:NextNumber(40, 90), rng:NextNumber(-40, 40))
			chunk.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8))
			task.delay(7, function()
				if chunk.Parent then
					TweenService:Create(chunk, TweenInfo.new(1.5), { Transparency = 1 }):Play()
					task.wait(1.6)
					chunk:Destroy()
				end
			end)
		end
	end
	-- The fallen tiles lie on the floor a while, then fade (kept for the repair).
	task.delay(7, function()
		for _, tile in rec.Tiles do
			if tile.Fall and tile.Part.Parent then
				TweenService:Create(tile.Part, TweenInfo.new(1.5), { Transparency = 1 }):Play()
			end
		end
		task.wait(1.6)
		for _, tile in rec.Tiles do
			if tile.Fall then
				tile.Part.Anchored = true
				tile.Part.Parent = nil
			end
		end
	end)
end

function LobbyBuilder.OpenHole(index: number, launch: Vector3?)
	local def = (Config.AbuseShow :: any).Holes[index]
	if def then
		cutDisc(index, def[1], def[2], def[3], TABLE_PART_NAMES, { Launch = launch })
	end
end

-- A bomb crater: a real hole through the whole table (index 10 and up), mended by HealHoles.
function LobbyBuilder.OpenCrater(index: number, x: number, z: number, radius: number)
	cutDisc(index, x, z, radius, TABLE_PART_NAMES, {})
end

-- A hole in the ceiling (the giant's exit). It heals with HealRoof (or HealHoles).
function LobbyBuilder.OpenRoofHole(x: number, z: number, radius: number)
	cutDisc(100, x, z, radius, ROOF_PART_NAMES, { Roof = true })
end

-- Everything comes back: the hole closes in from its rim over `seconds`, cracks fade, props return.
local function healRec(index: number, rec: HoleRec, total: number)
	do
		holes[index] = nil
		-- The glow from below and its smoke fade away over the repair (not "on, then suddenly gone").
		for _, piece in rec.Pieces do
			for _, d in piece:GetDescendants() do
				if d:IsA("PointLight") then
					TweenService:Create(d, TweenInfo.new(total * 0.85), { Brightness = 0 }):Play()
				elseif d:IsA("ParticleEmitter") then
					d.Enabled = false
				end
			end
		end
		for _, inst in ((rec :: any).Ui or {}) :: { Instance } do
			(inst :: any).Enabled = true
		end
		local folder = rec.Pieces[1]
		for _, crack in rec.Cracks do
			TweenService:Create(crack, TweenInfo.new(total * 0.6), { Transparency = 1 }):Play()
		end
		-- the fallen tiles reappear (outer ones first)
		local fallen = {}
		for _, tile in rec.Tiles do
			if tile.Fall then
				table.insert(fallen, tile)
			end
		end
		table.sort(fallen, function(a, b)
			return a.D > b.D
		end)
		for i, tile in fallen do
			task.delay((i / math.max(1, #fallen)) * total * 0.7, function()
				local part = tile.Part
				part.Anchored = true
				part.CanCollide = true
				part.AssemblyLinearVelocity = Vector3.zero
				part.AssemblyAngularVelocity = Vector3.zero
				part.CFrame = tile.Flat
				part.Transparency = 1
				part.Parent = folder
				TweenService:Create(part, TweenInfo.new(0.9), { Transparency = tile.Transparency }):Play()
			end)
		end
		-- the broken rim straightens out too, in the same sweep (outer ring first), not all at once
		local rim = {}
		for _, tile in rec.Tiles do
			if not tile.Fall then
				table.insert(rim, tile)
			end
		end
		table.sort(rim, function(a, b)
			return a.D > b.D
		end)
		for i, tile in rim do
			task.delay((i / math.max(1, #rim)) * total * 0.7, function()
				TweenService:Create(tile.Part, TweenInfo.new(math.max(0.6, total * 0.12), Enum.EasingStyle.Quad), { CFrame = tile.Flat }):Play()
			end)
		end
		task.delay(total * 0.8, function()
			for _, prop in rec.Props do
				prop.Part.Anchored = true
				prop.Part.AssemblyLinearVelocity = Vector3.zero
				prop.Part.AssemblyAngularVelocity = Vector3.zero
				prop.Part.CFrame = prop.CF
				prop.Part.CanCollide = prop.Collide
			end
		end)
		-- Finally the original parts go back (they are exactly what the pieces looked like).
		task.delay(total + 1.5, function()
			local model = lobby and lobby.Model
			for _, p in rec.Hidden do
				p.Parent = model
			end
			if folder then
				folder:Destroy()
			end
			for _, prop in rec.Props do
				prop.Part.Anchored = prop.Anchored
			end
		end)
	end
end

-- Is (x, z) in or near a hole in the table (not the ceiling)? Things that run about on the table keep clear of them.
function LobbyBuilder.IsHoleAt(x: number, z: number, margin: number): boolean
	for index, rec in holes do
		if index ~= 100 then
			local dx, dz = x - (rec.Center.X - ORIGIN.X), z - (rec.Center.Z - ORIGIN.Z)
			if math.sqrt(dx * dx + dz * dz) < rec.Radius + margin then
				return true
			end
		end
	end
	return false
end

function LobbyBuilder.HealHoles(seconds: number?)
	for index, rec in holes do
		healRec(index, rec, seconds or 8)
	end
end

-- The show smashes the big dishwasher: every part goes invisible and non-solid and flies apart as
-- chunks of the same colours; RepairDishwasher puts it all back.
local dishwasherSaved: { [BasePart]: { number | boolean } }? = nil
local dishwasherChunks: { BasePart } = {}
local dishwasherGuis: { [SurfaceGui]: boolean } = {}
local dishwasherSavedCF: { [BasePart]: CFrame } = {}
function LobbyBuilder.DishwasherBroken(): boolean
	return dishwasherSaved ~= nil
end
function LobbyBuilder.BreakDishwasher(impact: Vector3)
	local folder = dishwasherFolder
	if not folder or dishwasherSaved then
		return
	end
	local saved: { [BasePart]: { number | boolean } } = {}
	dishwasherSaved = saved
	local rng = Random.new()
	local budget = 190
	-- (the roof ladder is a separate set of parts: it goes too, and its climbing truss moves far away)
	local pieces: { Instance } = folder:GetDescendants()
	local model = lobby and lobby.Model
	if model then
		for _, d in model:GetChildren() do
			if string.sub(d.Name, 1, 6) == "Ladder" then
				table.insert(pieces, d)
			end
		end
	end
	for _, d in pieces do
		if d:IsA("SurfaceGui") then
			-- (a SurfaceGui draws even when its part is invisible: the title text and the roof sign)
			dishwasherGuis[d] = d.Enabled
			d.Enabled = false
		elseif d:IsA("BasePart") then
			if d:IsA("TrussPart") then
				dishwasherSavedCF[d] = d.CFrame
				d.CFrame = d.CFrame - Vector3.new(0, 3000, 0)
			end
			saved[d] = { d.Transparency, d.CanCollide, d.CanQuery }
			if d.Transparency < 0.9 and budget > 0 then
				local vol = d.Size.X * d.Size.Y * d.Size.Z
				local n = math.clamp(math.floor(vol / 1800), 1, 40)
				n = math.min(n, budget)
				for _ = 1, n do
					local chunk = Instance.new("Part")
					local big = math.max(d.Size.X, d.Size.Y, d.Size.Z)
					local sz = math.clamp(big / 4, 1.5, 7)
					chunk.Size = Vector3.new(sz * rng:NextNumber(0.6, 1.4), sz * rng:NextNumber(0.6, 1.4), sz * rng:NextNumber(0.6, 1.4))
					chunk.Color = d.Color
					chunk.Material = d.Material
					chunk.TopSurface = Enum.SurfaceType.Smooth
					chunk.BottomSurface = Enum.SurfaceType.Smooth
					local local_ = Vector3.new(rng:NextNumber(-0.5, 0.5) * d.Size.X, rng:NextNumber(-0.5, 0.5) * d.Size.Y, rng:NextNumber(-0.5, 0.5) * d.Size.Z)
					chunk.CFrame = d.CFrame * CFrame.new(local_) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), rng:NextNumber(0, 6))
					chunk.CanTouch = false
					chunk.Parent = Workspace
					local away = chunk.Position - impact
					local dir = if away.Magnitude > 0.1 then away.Unit else Vector3.new(0, 0, 1)
					chunk.AssemblyLinearVelocity = dir * rng:NextNumber(40, 130) + Vector3.new(rng:NextNumber(-25, 25), rng:NextNumber(40, 130), rng:NextNumber(-25, 25))
					chunk.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12))
					table.insert(dishwasherChunks, chunk)
					budget -= 1
				end
			end
			d.Transparency = 1
			d.CanCollide = false
			d.CanQuery = false
		elseif d:IsA("ParticleEmitter") then
			d.Enabled = false
		end
	end
end
function LobbyBuilder.RepairDishwasher()
	local saved = dishwasherSaved
	if not saved then
		return
	end
	dishwasherSaved = nil
	local chunks = dishwasherChunks
	dishwasherChunks = {}
	for _, c in chunks do
		TweenService:Create(c, TweenInfo.new(1.5), { Transparency = 1 }):Play()
		c.CanCollide = false
		task.delay(1.6, function()
			c:Destroy()
		end)
	end
	for gui, enabled in dishwasherGuis do
		gui.Enabled = enabled
	end
	dishwasherGuis = {}
	for part, cf in dishwasherSavedCF do
		part.CFrame = cf
	end
	dishwasherSavedCF = {}
	for part, orig in saved do
		if part.Parent then
			TweenService:Create(part, TweenInfo.new(1.5), { Transparency = orig[1] :: number }):Play()
			part.CanCollide = orig[2] :: boolean
			part.CanQuery = orig[3] :: boolean
		end
	end
	if dishwasherFolder then
		for _, e in dishwasherFolder:GetDescendants() do
			if e:IsA("ParticleEmitter") then
				e.Enabled = true
			end
		end
	end
end

-- What the giant punches off the table (the soap shop, the eggs, the pet stand): every loose prop near a
-- point is unanchored and flung; RestoreProps puts it all back. Nothing here is a Humanoid.
type Smashed = { Part: BasePart, CF: CFrame, Anchored: boolean, Collide: boolean, Transparency: number }
local smashedProps: { Smashed } = {}
local smashedSet: { [BasePart]: boolean } = {}
local smashedPrompts: { [ProximityPrompt]: boolean } = {}
local smashedUi: { Instance } = {}
local smashedInvisible: { BasePart } = {} -- invisible solid parts (hit boxes) near what was smashed: made non-solid
function LobbyBuilder.GetSmashTargets(): { { Name: string, Pos: Vector3, Radius: number } }
	local list = { { Name = "Soap shop", Pos = Vector3.new(SHOP_X, 0, EGG_Z), Radius = 15 } }
	local eggs = Config.Eggs
	local n = #eggs
	for i, egg in eggs do
		table.insert(list, { Name = tostring(egg.Name or ("Egg " .. i)), Pos = Vector3.new((i - (n + 1) / 2) * 20, 0, EGG_Z), Radius = 9 })
	end
	table.insert(list, { Name = "Pet stand", Pos = Vector3.new(PETSTAND_X, 0, EGG_Z), Radius = 11 })
	return list
end
function LobbyBuilder.SmashProps(center: Vector3, radius: number, launch: Vector3)
	local model = lobby and lobby.Model
	if not model then
		return
	end
	local cx, cz = ORIGIN.X + center.X, ORIGIN.Z + center.Z
	local rng = Random.new()
	local mine: { Smashed } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and not smashedSet[d] and d.Anchored and d.Transparency < 0.95 and d.Name ~= "Barrier" and not TABLE_PART_NAMES[d.Name] and d.Size.Y < 70 and not (dishwasherFolder and d:IsDescendantOf(dishwasherFolder)) and not d:IsA("SpawnLocation") then
			local dx, dz = d.Position.X - cx, d.Position.Z - cz
			local y = d.Position.Y - ORIGIN.Y
			if math.sqrt(dx * dx + dz * dz) < radius and y > -1 and y < 45 then
				local rec: Smashed = { Part = d, CF = d.CFrame, Anchored = true, Collide = d.CanCollide, Transparency = d.Transparency }
				smashedSet[d] = true
				table.insert(smashedProps, rec)
				table.insert(mine, rec)
			end
		elseif d:IsA("BasePart") and d.Transparency >= 0.95 and d.CanCollide and d.Anchored and d.Name ~= "Barrier" and not TABLE_PART_NAMES[d.Name] and not d:IsA("SpawnLocation") and not (dishwasherFolder and d:IsDescendantOf(dishwasherFolder)) then
			-- (an invisible block left standing where the shop or the eggs were: anyone could jump onto it)
			local dx, dz = d.Position.X - cx, d.Position.Z - cz
			local y = d.Position.Y - ORIGIN.Y
			if math.sqrt(dx * dx + dz * dz) < radius + 4 and y > -1 and y < 60 and d.Size.X < 60 and d.Size.Z < 60 then
				table.insert(smashedInvisible, d)
				d.CanCollide = false
				d.CanQuery = false
			end
		elseif (d:IsA("SurfaceGui") or d:IsA("BillboardGui")) and d.Enabled then
			-- The title of what is being hit ("SOAP SHOP", "BUBBLE EGG 50 BUBBLES", the pet stand's name...): it goes
			-- the moment its thing is hit, even when it sits on an invisible part that does not fall.
			local anchorPart = (if d:IsA("BillboardGui") then d.Adornee else nil) or d.Parent
			if anchorPart and anchorPart:IsA("BasePart") and not (dishwasherFolder and anchorPart:IsDescendantOf(dishwasherFolder)) then
				local dx, dz = anchorPart.Position.X - cx, anchorPart.Position.Z - cz
				local y = anchorPart.Position.Y - ORIGIN.Y
				if math.sqrt(dx * dx + dz * dz) < radius + 2 and y > -1 and y < 70 then
					table.insert(smashedUi, d)
					d.Enabled = false
				end
			end
		elseif d:IsA("ProximityPrompt") and d.Enabled then
			local part = d.Parent
			if part and part:IsA("BasePart") then
				local dx, dz = part.Position.X - cx, part.Position.Z - cz
				if math.sqrt(dx * dx + dz * dz) < radius then
					smashedPrompts[d] = true
					d.Enabled = false
				end
			end
		end
	end
	for _, rec in mine do
		switchOffUiOn(rec.Part, smashedUi)
	end
	for _, d in model:GetDescendants() do
		-- (a label that floats over a smashed part, but belongs to something else)
		if d:IsA("BillboardGui") and d.Enabled and d.Adornee and d.Adornee:IsA("BasePart") and smashedSet[d.Adornee] then
			table.insert(smashedUi, d)
			d.Enabled = false
		end
	end
	for _, rec in mine do
		local part = rec.Part
		part.Anchored = false
		part.CanCollide = true
		part.AssemblyLinearVelocity = launch + Vector3.new(rng:NextNumber(-25, 25), rng:NextNumber(0, 40), rng:NextNumber(-25, 25))
		part.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-10, 10), rng:NextNumber(-10, 10), rng:NextNumber(-10, 10))
		task.delay(6, function()
			if part.Parent and smashedSet[part] then
				TweenService:Create(part, TweenInfo.new(1.5), { Transparency = 1 }):Play()
			end
		end)
	end
end
function LobbyBuilder.RestoreProps()
	for _, rec in smashedProps do
		local part = rec.Part
		if part.Parent then
			part.Anchored = true
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
			part.CFrame = rec.CF
			part.Transparency = rec.Transparency
			part.CanCollide = rec.Collide
			part.Anchored = rec.Anchored
		end
	end
	for prompt in smashedPrompts do
		prompt.Enabled = true
	end
	for _, inst in smashedUi do
		(inst :: any).Enabled = true
	end
	for _, part in smashedInvisible do
		if part.Parent then
			part.CanCollide = true
			part.CanQuery = false
		end
	end
	smashedProps, smashedSet, smashedPrompts, smashedUi, smashedInvisible = {}, {}, {}, {}, {}
end

-- While the show runs the party pads do nothing at all: nothing on them is solid or touchable, and
-- their prompts are off (the "0/8" signs stay). Everything is put back afterwards.
local padSaved: { [BasePart]: { boolean } } = {}
function LobbyBuilder.SetPadsEnabled(on: boolean)
	local model = lobby and lobby.Model
	if not model then
		return
	end
	if on then
		for part, orig in padSaved do
			if part.Parent then
				part.CanCollide = orig[1]
				part.CanTouch = orig[2]
			end
		end
		padSaved = {}
		return
	end
	for _, child in model:GetChildren() do
		if child:IsA("Model") and string.sub(child.Name, 1, 3) == "Pad" then
			for _, d in child:GetDescendants() do
				if d:IsA("BasePart") and not padSaved[d] then
					padSaved[d] = { d.CanCollide, d.CanTouch }
					d.CanTouch = false
					if d.CollisionGroup == "PadBarrier" or d.Name:find("Barrier") or d.Name:find("Wall") or d.Name:find("Gate") then
						d.CanCollide = false
					end
				end
			end
		end
	end
end

-- The lobby's own prompts ("Open Shop", the chest, the eggs...) and floating labels are switched off for the
-- show (so nothing offers to open something that has just been smashed); the pad signs stay.
local uiOff: { Instance } = {}
function LobbyBuilder.SetUiEnabled(on: boolean)
	local model = lobby and lobby.Model
	if not model then
		return
	end
	if on then
		for _, inst in uiOff do
			if inst.Parent then
				(inst :: any).Enabled = true
			end
		end
		uiOff = {}
		return
	end
	for _, d in model:GetDescendants() do
		if (d:IsA("ProximityPrompt") or d:IsA("BillboardGui")) and d.Enabled then
			local inPad = false
			local anc = d.Parent
			while anc and anc ~= model do
				if anc:IsA("Model") and string.sub(anc.Name, 1, 3) == "Pad" then
					inPad = true
					break
				end
				anc = anc.Parent
			end
			if not inPad and d.Name ~= "PadGui" then
				table.insert(uiOff, d)
				d.Enabled = false
			end
		end
	end
end

function LobbyBuilder.HealRoof(seconds: number?)
	local rec = holes[100]
	if rec then
		healRec(100, rec, seconds or 4)
	end
end

-- The invisible walls round the table: open (no collision) for the whole Admin Abuse show, then closed
-- again; anyone left outside when they close is put back at the spawn.
function LobbyBuilder.SetBarriers(open: boolean)
	local model = lobby and lobby.Model
	if not model then
		return
	end
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") and d.Name == "Barrier" then
			d.CanCollide = not open
		end
	end
	if not open then
		for _, player in Players:GetPlayers() do
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local p = root.Position - ORIGIN
				if math.abs(p.X) > PLAZA_X + FENCE_MARGIN or p.Z < PLAZA_Z0 - FENCE_MARGIN or p.Z > PLAZA_Z1 + FENCE_MARGIN or p.Y < -20 then
					sendToLobbySpawn(player)
				end
			end
		end
	end
end

-- While the show runs: anyone who ends up below the table (fell off an edge, into a hole...) is put
-- back at the spawn. Inside the obby's area they go to their checkpoint instead (see the obby).
local rescueBeat: RBXScriptConnection? = nil
function LobbyBuilder.SetRescue(on: boolean)
	if rescueBeat then
		rescueBeat:Disconnect()
		rescueBeat = nil
	end
	local beat: any = RunService.Heartbeat
	if not on or not beat then
		return
	end
	local clock = 0
	rescueBeat = beat:Connect(function(dt)
		clock += dt
		if clock < 0.4 then
			return
		end
		clock = 0
		for _, player in Players:GetPlayers() do
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local p = root.Position - ORIGIN
				local inObbyBox = p.X > OBBY_BOX.X0 and p.X < OBBY_BOX.X1 and p.Z > OBBY_BOX.Z0 and p.Z < OBBY_BOX.Z1
				local inTable = math.abs(p.X) < 150 and p.Z > -150 and p.Z < OBBY_BOX.Z1
				if p.Y < -30 and p.Y > -125 and (inTable or inObbyBox) and not (inObbyBox and obbyOpen) then
					sendToLobbySpawn(player)
				end
			end
		end
	end)
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
