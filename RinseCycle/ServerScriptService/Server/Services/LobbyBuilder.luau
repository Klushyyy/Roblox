-- LobbyBuilder: builds the entire lobby world at boot (a giant, bright kitchen seen from the point
-- of view of a tiny water-person). Nothing here is an uploaded asset: every part is primitives.
--
-- Layout (floor top at Y = 0, centred on Config.World.LobbyOrigin):
--   CENTRE  a round spawn plaza with the SpawnLocations (built FIRST) and a fountain/tap centrepiece
--   NORTH   a giant stainless dishwasher facade built into the cabinet run, with the game's title
--   (row)   the party pads, in front of the dishwasher
--   WEST    the Soap Shop (perks)
--   EAST    the Egg Hatchery (pets) + a Pet Stand
--   SOUTH   the two leaderboard boards + a How to Play board
-- A perimeter of giant kitchen cabinets (with invisible barrier walls behind them) rings the floor.
--
-- Build() is the only entry point that creates anything; GetLobby()/GetSpawnCFrame() just read back
-- what was built. It has no server-side dependencies (see DESIGN.md's dependency graph), so other
-- services require it, never the other way around.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local LobbyBuilder = {}

----------------------------------------------------------------------------------------------------
-- Types (mirrors DESIGN.md section 5; other services copy these shapes rather than requiring us for
-- them, but exporting is harmless and helps anyone who does).
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
export type BoardInfo = { Part: BasePart, Title: TextLabel, List: Frame }
export type Lobby = {
	Model: Model,
	Pads: { PadInfo },
	Boards: { Times: BoardInfo, Dishes: BoardInfo },
}

----------------------------------------------------------------------------------------------------
-- Layout constants
----------------------------------------------------------------------------------------------------
local ORIGIN = Config.World.LobbyOrigin

local FLOOR_X, FLOOR_Z = 300, 260
local TILE = 20
local NORTH_Z = ORIGIN.Z - FLOOR_Z / 2 -- -130
local SOUTH_Z = ORIGIN.Z + FLOOR_Z / 2 -- 130
local WEST_X = ORIGIN.X - FLOOR_X / 2 -- -150
local EAST_X = ORIGIN.X + FLOOR_X / 2 -- 150

local BARRIER_HEIGHT = 150
local MAIN_FLOOR_Y = 0 -- top of the main checkered floor

local PAD_COUNT = Config.Party.PadCount
local PAD_SIZE = 16
local PAD_Z = -85
local PAD_SPACING = 40
local PAD_WALL_HEIGHT = 10
local PAD_FLOOR_Y = 0.3 -- top of a pad's glowing floor

local DISHWASHER_WIDTH = 150
local DISHWASHER_HEIGHT = 70

-- Colors
local TILE_A = Color3.fromRGB(255, 255, 255)
local TILE_B = Color3.fromRGB(203, 233, 238)
local CABINET_BODY = Color3.fromRGB(232, 243, 248)
local CABINET_DOOR = Color3.fromRGB(207, 224, 235)
local CABINET_HANDLE = Color3.fromRGB(214, 218, 222)
local COUNTER_COLOR = Color3.fromRGB(255, 255, 255)
local STEEL = Color3.fromRGB(198, 203, 209)

----------------------------------------------------------------------------------------------------
-- Build bookkeeping: a soft ~2500-part budget, yielding every ~200 parts so the server never hitches.
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
	local inst = Instance.new(className)
	inst.Anchored = true
	if props.CanCollide == nil then
		inst.CanCollide = true
	end
	if props.CanTouch == nil then
		inst.CanTouch = false
	end
	if props.CastShadow == nil then
		inst.CastShadow = true
	end
	for k, v in props do
		(inst :: any)[k] = v
	end
	inst.Parent = parent
	maybeYield()
	return inst :: BasePart
end

-- Non-part instances (GUIs, lights, particles, models, folders...) don't count toward the budget.
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

----------------------------------------------------------------------------------------------------
-- Floor: a checkerboard of ~20-stud CeramicTiles in two soft tones.
----------------------------------------------------------------------------------------------------
local function buildFloor(parent: Instance)
	local tilesX = math.floor(FLOOR_X / TILE)
	local tilesZ = math.floor(FLOOR_Z / TILE)
	for ix = 0, tilesX - 1 do
		for iz = 0, tilesZ - 1 do
			local cx = WEST_X + TILE * (ix + 0.5)
			local cz = NORTH_Z + TILE * (iz + 0.5)
			local light = (ix + iz) % 2 == 0
			mkPart("Part", {
				Name = "Tile",
				Size = Vector3.new(TILE, 1, TILE),
				CFrame = CFrame.new(cx, MAIN_FLOOR_Y - 0.5, cz),
				Color = light and TILE_A or TILE_B,
				Material = Enum.Material.CeramicTiles,
				CanQuery = false,
			}, parent)
		end
	end
end

----------------------------------------------------------------------------------------------------
-- Perimeter kitchen cabinets: a run of modules (body + door + handle) along a wall, a countertop
-- slab with overhang, and a tiled backsplash above. `skip` cuts a gap for something built into the
-- wall (only the north wall's dishwasher needs this).
----------------------------------------------------------------------------------------------------
type Skip = { min: number, max: number }

local MODULE = 10
local CABINET_DEPTH = 6
local CABINET_HEIGHT = 34
local COUNTER_HEIGHT = 2
local COUNTER_OVERHANG = 1.5
local BACKSPLASH_HEIGHT = 6

-- wallZ: the outer Z of the wall. faceDir: +1 or -1, the direction the cabinets face into the room.
local function buildWallNS(parent: Instance, wallZ: number, faceDir: number, length: number, skip: Skip?)
	local innerZ = wallZ + faceDir * CABINET_DEPTH / 2
	local startX = ORIGIN.X - length / 2
	local count = math.floor(length / MODULE)

	local function inSkip(x: number): boolean
		return skip ~= nil and x > skip.min and x < skip.max
	end

	for i = 0, count - 1 do
		local cx = startX + MODULE * (i + 0.5)
		if not inSkip(cx) then
			mkPart("Part", {
				Name = "CabinetBody",
				Size = Vector3.new(MODULE - 0.4, CABINET_HEIGHT, CABINET_DEPTH),
				CFrame = CFrame.new(cx, CABINET_HEIGHT / 2, innerZ),
				Color = CABINET_BODY,
				Material = Enum.Material.SmoothPlastic,
			}, parent)
			mkPart("Part", {
				Name = "CabinetDoor",
				Size = Vector3.new(MODULE - 1.2, CABINET_HEIGHT - 4, 0.3),
				CFrame = CFrame.new(cx, CABINET_HEIGHT / 2, innerZ + faceDir * (CABINET_DEPTH / 2 + 0.16)),
				Color = CABINET_DOOR,
				Material = Enum.Material.SmoothPlastic,
				CanCollide = false,
				CanQuery = false,
			}, parent)
			mkPart("Part", {
				Name = "Handle",
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(3, 0.4, 0.4),
				CFrame = CFrame.new(cx + MODULE * 0.28, CABINET_HEIGHT / 2, innerZ + faceDir * (CABINET_DEPTH / 2 + 0.35))
					* CFrame.Angles(0, 0, math.rad(90)),
				Color = CABINET_HANDLE,
				Material = Enum.Material.Metal,
				CanCollide = false,
				CanQuery = false,
			}, parent)
		end
	end

	local segments: { { number } } = {}
	if skip then
		if skip.min > startX then
			table.insert(segments, { startX, skip.min })
		end
		if skip.max < startX + length then
			table.insert(segments, { skip.max, startX + length })
		end
	else
		table.insert(segments, { startX, startX + length })
	end
	for _, seg in segments do
		local segLen = seg[2] - seg[1]
		local segCenter = (seg[1] + seg[2]) / 2
		if segLen > 1 then
			mkPart("Part", {
				Name = "Countertop",
				Size = Vector3.new(segLen + COUNTER_OVERHANG, COUNTER_HEIGHT, CABINET_DEPTH + COUNTER_OVERHANG),
				CFrame = CFrame.new(segCenter, CABINET_HEIGHT + COUNTER_HEIGHT / 2, innerZ + faceDir * (COUNTER_OVERHANG / 2)),
				Color = COUNTER_COLOR,
				Material = Enum.Material.Marble,
			}, parent)
			mkPart("Part", {
				Name = "Backsplash",
				Size = Vector3.new(segLen, BACKSPLASH_HEIGHT, 0.4),
				CFrame = CFrame.new(segCenter, CABINET_HEIGHT + COUNTER_HEIGHT + BACKSPLASH_HEIGHT / 2, innerZ),
				Color = TILE_A,
				Material = Enum.Material.CeramicTiles,
				CanQuery = false,
			}, parent)
		end
	end
end

-- wallX: the outer X of the wall. faceDir: +1 or -1, the direction the cabinets face into the room.
local function buildWallEW(parent: Instance, wallX: number, faceDir: number, length: number)
	local innerX = wallX + faceDir * CABINET_DEPTH / 2
	local startZ = ORIGIN.Z - length / 2
	local count = math.floor(length / MODULE)

	for i = 0, count - 1 do
		local cz = startZ + MODULE * (i + 0.5)
		mkPart("Part", {
			Name = "CabinetBody",
			Size = Vector3.new(CABINET_DEPTH, CABINET_HEIGHT, MODULE - 0.4),
			CFrame = CFrame.new(innerX, CABINET_HEIGHT / 2, cz),
			Color = CABINET_BODY,
			Material = Enum.Material.SmoothPlastic,
		}, parent)
		mkPart("Part", {
			Name = "CabinetDoor",
			Size = Vector3.new(0.3, CABINET_HEIGHT - 4, MODULE - 1.2),
			CFrame = CFrame.new(innerX + faceDir * (CABINET_DEPTH / 2 + 0.16), CABINET_HEIGHT / 2, cz),
			Color = CABINET_DOOR,
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
			CanQuery = false,
		}, parent)
		mkPart("Part", {
			Name = "Handle",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(3, 0.4, 0.4),
			CFrame = CFrame.new(innerX + faceDir * (CABINET_DEPTH / 2 + 0.35), CABINET_HEIGHT / 2, cz + MODULE * 0.28)
				* CFrame.Angles(math.rad(90), 0, 0),
			Color = CABINET_HANDLE,
			Material = Enum.Material.Metal,
			CanCollide = false,
			CanQuery = false,
		}, parent)
	end

	mkPart("Part", {
		Name = "Countertop",
		Size = Vector3.new(CABINET_DEPTH + COUNTER_OVERHANG, COUNTER_HEIGHT, length + COUNTER_OVERHANG),
		CFrame = CFrame.new(innerX + faceDir * (COUNTER_OVERHANG / 2), CABINET_HEIGHT + COUNTER_HEIGHT / 2, ORIGIN.Z),
		Color = COUNTER_COLOR,
		Material = Enum.Material.Marble,
	}, parent)
	mkPart("Part", {
		Name = "Backsplash",
		Size = Vector3.new(0.4, BACKSPLASH_HEIGHT, length),
		CFrame = CFrame.new(innerX, CABINET_HEIGHT + COUNTER_HEIGHT + BACKSPLASH_HEIGHT / 2, ORIGIN.Z),
		Color = TILE_A,
		Material = Enum.Material.CeramicTiles,
		CanQuery = false,
	}, parent)
end

----------------------------------------------------------------------------------------------------
-- Invisible barrier walls up to Y = 150, just past the cabinet run, so nobody can leave.
----------------------------------------------------------------------------------------------------
local function buildBarriers(parent: Instance)
	local thickness = 4
	local margin = CABINET_DEPTH + 2
	mkPart("Part", {
		Name = "BarrierNorth",
		Size = Vector3.new(FLOOR_X + thickness * 2, BARRIER_HEIGHT, thickness),
		CFrame = CFrame.new(ORIGIN.X, BARRIER_HEIGHT / 2, NORTH_Z - margin),
		Transparency = 1,
		CanQuery = false,
	}, parent)
	mkPart("Part", {
		Name = "BarrierSouth",
		Size = Vector3.new(FLOOR_X + thickness * 2, BARRIER_HEIGHT, thickness),
		CFrame = CFrame.new(ORIGIN.X, BARRIER_HEIGHT / 2, SOUTH_Z + margin),
		Transparency = 1,
		CanQuery = false,
	}, parent)
	mkPart("Part", {
		Name = "BarrierWest",
		Size = Vector3.new(thickness, BARRIER_HEIGHT, FLOOR_Z + thickness * 2),
		CFrame = CFrame.new(WEST_X - margin, BARRIER_HEIGHT / 2, ORIGIN.Z),
		Transparency = 1,
		CanQuery = false,
	}, parent)
	mkPart("Part", {
		Name = "BarrierEast",
		Size = Vector3.new(thickness, BARRIER_HEIGHT, FLOOR_Z + thickness * 2),
		CFrame = CFrame.new(EAST_X + margin, BARRIER_HEIGHT / 2, ORIGIN.Z),
		Transparency = 1,
		CanQuery = false,
	}, parent)
end

----------------------------------------------------------------------------------------------------
-- NORTH: the giant stainless dishwasher facade, built into the cabinet run's gap, with a glowing
-- control strip and the big "RINSE CYCLE" title sign.
----------------------------------------------------------------------------------------------------
local function buildDishwasherFacade(parent: Instance)
	local z = NORTH_Z + 0.15
	local cx, cy = ORIGIN.X, DISHWASHER_HEIGHT / 2

	mkPart("Part", {
		Name = "DishwasherFace",
		Size = Vector3.new(DISHWASHER_WIDTH, DISHWASHER_HEIGHT, 3),
		CFrame = CFrame.new(cx, cy, z),
		Color = STEEL,
		Material = Enum.Material.Metal,
	}, parent)
	mkPart("Part", {
		Name = "DoorTrim",
		Size = Vector3.new(DISHWASHER_WIDTH - 6, DISHWASHER_HEIGHT - 10, 0.4),
		CFrame = CFrame.new(cx, cy, z + 1.7),
		Color = Color3.fromRGB(168, 174, 180),
		Material = Enum.Material.DiamondPlate,
		CanCollide = false,
		CanQuery = false,
	}, parent)

	-- Control strip: a housing plus a row of glowing buttons.
	mkPart("Part", {
		Name = "ControlStrip",
		Size = Vector3.new(DISHWASHER_WIDTH * 0.7, 6, 1.5),
		CFrame = CFrame.new(cx, DISHWASHER_HEIGHT * 0.78, z + 1.2),
		Color = Color3.fromRGB(58, 63, 68),
		Material = Enum.Material.Metal,
		CanCollide = false,
		CanQuery = false,
	}, parent)
	local buttonColors = {
		Color3.fromRGB(120, 220, 255),
		Color3.fromRGB(255, 210, 90),
		Color3.fromRGB(120, 255, 150),
		Color3.fromRGB(255, 120, 150),
	}
	for i, color in buttonColors do
		local bx = cx - DISHWASHER_WIDTH * 0.32 + (i - 1) * 16
		mkPart("Part", {
			Name = "ControlButton",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.2, 3, 3),
			CFrame = CFrame.new(bx, DISHWASHER_HEIGHT * 0.78, z + 1.95) * CFrame.Angles(0, 0, math.rad(90)),
			Color = color,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
		}, parent)
	end

	-- Title sign, mounted above the control strip.
	local signPart = mkPart("Part", {
		Name = "TitleSign",
		Size = Vector3.new(DISHWASHER_WIDTH * 0.62, DISHWASHER_HEIGHT * 0.34, 0.6),
		CFrame = CFrame.new(cx, DISHWASHER_HEIGHT * 0.88, z + 1.9),
		Color = Color3.fromRGB(40, 122, 192),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
	}, parent)
	local gui = mk("SurfaceGui", {
		Name = "TitleGui",
		Face = Enum.NormalId.Front,
		CanvasSize = Vector2.new(1024, 512),
		LightInfluence = 0,
	}, signPart)
	local titleLabel = mk("TextLabel", {
		Name = "Title",
		Size = UDim2.fromScale(1, 0.66),
		Position = UDim2.fromScale(0, 0.04),
		BackgroundTransparency = 1,
		Text = "RINSE CYCLE",
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(255, 255, 255),
	}, gui) :: TextLabel
	mk("UIStroke", { Thickness = 8, Color = Color3.fromRGB(18, 58, 108) }, titleLabel)
	mk("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(190, 230, 255)),
		Rotation = 90,
	}, titleLabel)
	local subLabel = mk("TextLabel", {
		Name = "Subtitle",
		Size = UDim2.fromScale(1, 0.22),
		Position = UDim2.fromScale(0, 0.74),
		BackgroundTransparency = 1,
		Text = "Walk into a pad to start a party!",
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(255, 255, 255),
	}, gui) :: TextLabel
	mk("UIStroke", { Thickness = 3, Color = Color3.fromRGB(18, 58, 108) }, subLabel)
end

----------------------------------------------------------------------------------------------------
-- CENTRE: the spawn plaza (a giant plate) with the SpawnLocations. Built before anything else in
-- Build() so a player who spawns while the rest of the lobby is still going up has a floor.
----------------------------------------------------------------------------------------------------
local function buildSpawnPlaza(parent: Instance): { SpawnLocation }
	mkPart("Part", {
		Name = "SpawnPlate",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2, 80, 80),
		CFrame = CFrame.new(ORIGIN.X, 0.5, ORIGIN.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(250, 250, 248),
		Material = Enum.Material.SmoothPlastic,
	}, parent)
	mkPart("Part", {
		Name = "SpawnPlateRim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.7, 82, 82),
		CFrame = CFrame.new(ORIGIN.X, 1.35, ORIGIN.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(130, 190, 235),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
	}, parent)

	local spawns: { SpawnLocation } = {}
	local count = 6
	local radius = 26
	for i = 1, count do
		local angle = (i - 1) / count * math.pi * 2
		local pos = Vector3.new(ORIGIN.X + math.cos(angle) * radius, 1.6, ORIGIN.Z + math.sin(angle) * radius)
		local sp = mkPart("SpawnLocation", {
			Name = "Spawn" .. i,
			Size = Vector3.new(6, 1, 6),
			CFrame = CFrame.new(pos, pos + Vector3.new(0, 0, -10)),
			Neutral = true,
			Duration = 0,
			Transparency = 1,
			CanCollide = true,
			CanQuery = false,
		}, parent) :: SpawnLocation
		table.insert(spawns, sp)
	end
	return spawns
end

----------------------------------------------------------------------------------------------------
-- Centrepiece: a giant chrome tap arching over a basin, with a translucent water column and rising
-- bubbles (a cheap ParticleEmitter, not physics).
----------------------------------------------------------------------------------------------------
local function buildFountain(parent: Instance)
	local cx, cz = ORIGIN.X, ORIGIN.Z
	local tapColor = Color3.fromRGB(226, 229, 233)

	mkPart("Part", {
		Name = "Basin",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(3, 22, 22),
		CFrame = CFrame.new(cx, 1.5, cz) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(225, 240, 250),
		Material = Enum.Material.Marble,
	}, parent)
	mkPart("Part", {
		Name = "BasinRim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.5, 23, 23),
		CFrame = CFrame.new(cx, 3, cz) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
	}, parent)
	mkPart("Part", {
		Name = "Pedestal",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(20, 6, 6),
		CFrame = CFrame.new(cx, 13, cz) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(210, 215, 220),
		Material = Enum.Material.Metal,
	}, parent)

	-- The arch: a chain of small cylinder segments tracing a semicircle from the pedestal up and over.
	local archRadius = 9
	local segs = 8
	for i = 0, segs do
		local t = i / segs
		local angle = math.rad(180 * t)
		local px = cx - archRadius * math.cos(angle)
		local py = 16 + archRadius * math.sin(angle)
		mkPart("Part", {
			Name = "TapSeg" .. i,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(1.6, 1.6, 1.6),
			CFrame = CFrame.new(px, py, cz),
			Color = tapColor,
			Material = Enum.Material.Metal,
			CanCollide = false,
			CanQuery = false,
		}, parent)
	end
	local spoutPos = Vector3.new(cx + archRadius, 16, cz)
	mkPart("Part", {
		Name = "Spout",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2, 1.4, 1.4),
		CFrame = CFrame.new(spoutPos) * CFrame.Angles(0, 0, math.rad(90)),
		Color = tapColor,
		Material = Enum.Material.Metal,
		CanCollide = false,
		CanQuery = false,
	}, parent)

	local waterTop, waterBottom = 15.5, 3.2
	local water = mkPart("Part", {
		Name = "WaterColumn",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(waterTop - waterBottom, 3, 3),
		CFrame = CFrame.new(spoutPos.X, (waterTop + waterBottom) / 2, spoutPos.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(150, 220, 255),
		Material = Enum.Material.Glass,
		Transparency = 0.35,
		CanCollide = false,
		CanQuery = false,
		CastShadow = false,
	}, parent)

	mk("ParticleEmitter", {
		Texture = "rbxasset://textures/particles/forcefield_glow_main.dds",
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255)),
		Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(1, 0.1),
		}),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = NumberRange.new(1.5, 2.5),
		Rate = 12,
		Speed = NumberRange.new(1, 2),
		SpreadAngle = Vector2.new(20, 20),
		Acceleration = Vector3.new(0, 4, 0),
		EmissionDirection = Enum.NormalId.Top,
	}, water)
end

----------------------------------------------------------------------------------------------------
-- Party pads: 6 in a row in front of the dishwasher. Each is a glowing floor, 4 glass walls with an
-- entrance arch on the +Z side (which faces the lobby centre), a billboard, and an invisible Zone.
-- Inside faces +Z; Exit is further along +Z, out past the archway.
----------------------------------------------------------------------------------------------------
local function buildPad(parent: Instance, id: number): PadInfo
	local totalWidth = (PAD_COUNT - 1) * PAD_SPACING
	local cx = ORIGIN.X - totalWidth / 2 + (id - 1) * PAD_SPACING
	local cz = PAD_Z
	local half = PAD_SIZE / 2

	local model = mk("Model", { Name = "Pad" .. id }, parent) :: Model

	local floor = mkPart("Part", {
		Name = "Floor",
		Size = Vector3.new(PAD_SIZE, 0.3, PAD_SIZE),
		CFrame = CFrame.new(cx, 0.15, cz),
		Color = Color3.fromRGB(125, 195, 255),
		Material = Enum.Material.Neon,
		CanQuery = false,
	}, model)
	mkPart("Part", {
		Name = "Rim",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, PAD_SIZE + 1, PAD_SIZE + 1),
		CFrame = CFrame.new(cx, 0.05, cz) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.Neon,
		Transparency = 0.35,
		CanCollide = false,
		CanQuery = false,
	}, model)

	local barriers: { BasePart } = {}
	local wallSpecs = {
		{ name = "BarrierBack", size = Vector3.new(PAD_SIZE, PAD_WALL_HEIGHT, 0.6), offset = Vector3.new(0, 0, -half) },
		{ name = "BarrierLeft", size = Vector3.new(0.6, PAD_WALL_HEIGHT, PAD_SIZE), offset = Vector3.new(-half, 0, 0) },
		{ name = "BarrierRight", size = Vector3.new(0.6, PAD_WALL_HEIGHT, PAD_SIZE), offset = Vector3.new(half, 0, 0) },
		-- The +Z (entrance) side is two stub walls either side of an archway, not a full wall.
		{ name = "BarrierFrontL", size = Vector3.new(PAD_SIZE * 0.32, PAD_WALL_HEIGHT, 0.6), offset = Vector3.new(-half * 0.68, 0, half) },
		{ name = "BarrierFrontR", size = Vector3.new(PAD_SIZE * 0.32, PAD_WALL_HEIGHT, 0.6), offset = Vector3.new(half * 0.68, 0, half) },
	}
	for _, spec in wallSpecs do
		local b = mkPart("Part", {
			Name = spec.name,
			Size = spec.size,
			CFrame = CFrame.new(cx + spec.offset.X, PAD_WALL_HEIGHT / 2, cz + spec.offset.Z),
			Material = Enum.Material.Glass,
			Color = Color3.fromRGB(200, 230, 255),
			Transparency = 0.8,
			CanCollide = true,
			CanTouch = false,
			CollisionGroup = "PadBarrier",
		}, model)
		table.insert(barriers, b)
	end
	-- Arch frame + corner posts over the entrance.
	mkPart("Part", {
		Name = "ArchFrame",
		Size = Vector3.new(PAD_SIZE * 0.72, 1, 1),
		CFrame = CFrame.new(cx, PAD_WALL_HEIGHT, cz + half),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
	}, model)
	for _, sx in { -1, 1 } do
		mkPart("Part", {
			Name = "Post",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(PAD_WALL_HEIGHT, 1, 1),
			CFrame = CFrame.new(cx + sx * half, PAD_WALL_HEIGHT / 2, cz + half) * CFrame.Angles(0, 0, math.rad(90)),
			Color = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.SmoothPlastic,
			CanCollide = false,
			CanQuery = false,
		}, model)
	end

	local zone = mkPart("Part", {
		Name = "Zone",
		Size = Vector3.new(PAD_SIZE - 1, 12, PAD_SIZE - 1),
		CFrame = CFrame.new(cx, 6, cz),
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
	}, model)

	-- Billboard, floating over the pad.
	local guiAnchor = mkPart("Part", {
		Name = "GuiAnchor",
		Size = Vector3.new(1, 1, 1),
		CFrame = CFrame.new(cx, PAD_WALL_HEIGHT + 3, cz),
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
		CanQuery = false,
	}, model)
	local billboard = mk("BillboardGui", {
		Name = "PadGui",
		Size = UDim2.fromOffset(220, 112),
		StudsOffset = Vector3.new(0, 2, 0),
		MaxDistance = 160,
		AlwaysOnTop = true,
	}, guiAnchor)
	local bg = mk("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(11, 37, 69),
		BackgroundTransparency = 0.25,
	}, billboard) :: Frame
	mk("UICorner", { CornerRadius = UDim.new(0, 12) }, bg)
	mk("UIStroke", { Thickness = 2, Color = Color3.fromRGB(255, 255, 255), Transparency = 0.4 }, bg)
	local titleLbl = mk("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.new(0, 0, 0, 4),
		BackgroundTransparency = 1,
		Text = "Party Pad",
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
	}, bg) :: TextLabel
	local countLbl = mk("TextLabel", {
		Name = "Count",
		Size = UDim2.new(1, 0, 0, 32),
		Position = UDim2.new(0, 0, 0, 32),
		BackgroundTransparency = 1,
		Text = "0/4",
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(255, 230, 120),
	}, bg) :: TextLabel
	local statusLbl = mk("TextLabel", {
		Name = "Status",
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.new(0, 0, 0, 64),
		BackgroundTransparency = 1,
		Text = "Walk in to start a party!",
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextWrapped = true,
		TextColor3 = Color3.fromRGB(220, 235, 255),
	}, bg) :: TextLabel
	local privacyLbl = mk("TextLabel", {
		Name = "Privacy",
		Size = UDim2.new(1, 0, 0, 18),
		Position = UDim2.new(0, 0, 0, 92),
		BackgroundTransparency = 1,
		Text = "",
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(190, 210, 230),
	}, bg) :: TextLabel

	local insidePos = Vector3.new(cx, PAD_FLOOR_Y, cz)
	local exitPos = Vector3.new(cx, MAIN_FLOOR_Y, cz + 14)

	return {
		Id = id,
		Model = model,
		Zone = zone,
		Floor = floor,
		Inside = CFrame.new(insidePos, insidePos + Vector3.new(0, 0, 1)),
		Exit = CFrame.new(exitPos, exitPos + Vector3.new(0, 0, 1)),
		Barriers = barriers,
		Gui = { Count = countLbl, Title = titleLbl, Status = statusLbl, Privacy = privacyLbl },
	}
end

----------------------------------------------------------------------------------------------------
-- WEST: the Soap Shop. A giant pump-bottle "building" behind a counter with the perks prompt.
----------------------------------------------------------------------------------------------------
local function buildSoapShop(parent: Instance)
	local x = WEST_X + 22
	local z = ORIGIN.Z - 10

	local counter = mkPart("Part", {
		Name = "Counter",
		Size = Vector3.new(14, 4, 8),
		CFrame = CFrame.new(x, 2, z),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
	}, parent)
	mkPart("Part", {
		Name = "CounterTop",
		Size = Vector3.new(15, 0.6, 9),
		CFrame = CFrame.new(x, 4.3, z),
		Color = Color3.fromRGB(120, 200, 255),
		Material = Enum.Material.Neon,
		CanQuery = false,
	}, parent)

	local bottleX, bottleZ = x, z - 10
	mkPart("Part", {
		Name = "BottleBody",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(26, 10, 10),
		CFrame = CFrame.new(bottleX, 13, bottleZ) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(150, 220, 255),
		Material = Enum.Material.Glass,
		Transparency = 0.15,
	}, parent)
	mkPart("Part", {
		Name = "BottleCap",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(6, 6, 6),
		CFrame = CFrame.new(bottleX, 26, bottleZ) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
	}, parent)
	mkPart("Part", {
		Name = "PumpNeck",
		Size = Vector3.new(1.4, 6, 1.4),
		CFrame = CFrame.new(bottleX + 1, 30, bottleZ),
		Color = Color3.fromRGB(220, 220, 225),
		Material = Enum.Material.Metal,
		CanCollide = false,
		CanQuery = false,
	}, parent)
	mkPart("Part", {
		Name = "PumpHead",
		Size = Vector3.new(4, 1.4, 1.4),
		CFrame = CFrame.new(bottleX + 3, 33.5, bottleZ),
		Color = Color3.fromRGB(255, 120, 170),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
	}, parent)

	local signPart = mkPart("Part", {
		Name = "ShopSign",
		Size = Vector3.new(20, 6, 0.6),
		CFrame = CFrame.new(x, 22, z + 5),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
	}, parent)
	local gui = mk("SurfaceGui", { Face = Enum.NormalId.Front, CanvasSize = Vector2.new(512, 150), LightInfluence = 0 }, signPart)
	local signLbl = mk("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "🧴 SOAP SHOP",
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(20, 110, 190),
	}, gui) :: TextLabel
	mk("UIStroke", { Thickness = 4, Color = Color3.fromRGB(255, 255, 255) }, signLbl)

	local prompt = mk("ProximityPrompt", {
		ActionText = "Open Shop",
		ObjectText = "Soap Shop",
		RequiresLineOfSight = false,
		HoldDuration = 0,
		MaxActivationDistance = 12,
	}, counter) :: ProximityPrompt
	prompt:SetAttribute("OpenWindow", "Shop")
end

----------------------------------------------------------------------------------------------------
-- EAST: the Egg Hatchery (one pedestal per Config.Eggs entry) and a small Pet Stand.
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
	root.CanCollide = false
	root.CanTouch = false
	root.CanQuery = false
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = Vector3.new(1, 1.35, 1)
	mesh.Parent = root
	root.Parent = m
	m.PrimaryPart = root
	return m
end

local function buildEggHatchery(parent: Instance)
	local x = EAST_X - 22

	mkPart("Part", {
		Name = "CartonBase",
		Size = Vector3.new(10, 2, 60),
		CFrame = CFrame.new(x, 1, ORIGIN.Z),
		Color = Color3.fromRGB(220, 195, 150),
		Material = Enum.Material.WoodPlanks,
	}, parent)
	mkPart("Part", {
		Name = "CartonBackWall",
		Size = Vector3.new(2, 8, 60),
		CFrame = CFrame.new(x + 5, 5, ORIGIN.Z),
		Color = Color3.fromRGB(220, 195, 150),
		Material = Enum.Material.WoodPlanks,
		CanCollide = false,
		CanQuery = false,
	}, parent)

	local petModelsOk, PetModels = pcall(function()
		return require(Shared:WaitForChild("PetModels"))
	end)

	local eggs = Config.Eggs
	local n = #eggs
	local spacing = 55 / math.max(n, 1)
	for i, egg in eggs do
		local ez = ORIGIN.Z - 27.5 + (i - 1) * spacing + spacing / 2

		mkPart("Part", {
			Name = "EggCup" .. i,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(3, 5, 5),
			CFrame = CFrame.new(x - 3, 4.5, ez) * CFrame.Angles(0, 0, math.rad(90)),
			Color = egg.Color,
			Material = Enum.Material.SmoothPlastic,
		}, parent)

		local eggModel: Model? = nil
		if petModelsOk then
			local ok2, result = pcall((PetModels :: any).Egg, egg.Id)
			if ok2 and typeof(result) == "Instance" then
				eggModel = result :: Model
			end
		end
		if not eggModel then
			eggModel = fallbackEggModel(egg)
		end
		local model = eggModel :: Model
		model.Parent = parent
		pcall(function()
			model:PivotTo(CFrame.new(x - 3, 10, ez))
		end)
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
				d.CanTouch = false
				d.CanQuery = false
				maybeYield()
			end
		end

		local anchor = mkPart("Part", {
			Name = "EggGuiAnchor" .. i,
			Size = Vector3.new(1, 1, 1),
			CFrame = CFrame.new(x - 3, 16, ez),
			Transparency = 1,
			CanCollide = false,
			CanTouch = false,
			CanQuery = false,
		}, parent)
		local billboard = mk("BillboardGui", {
			Size = UDim2.fromOffset(200, 96),
			StudsOffset = Vector3.new(0, 1, 0),
			MaxDistance = 100,
			AlwaysOnTop = true,
		}, anchor)
		local bg = mk("Frame", {
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.fromRGB(11, 37, 69),
			BackgroundTransparency = 0.25,
		}, billboard)
		mk("UICorner", { CornerRadius = UDim.new(0, 10) }, bg)
		mk("TextLabel", {
			Size = UDim2.new(1, 0, 0, 26),
			BackgroundTransparency = 1,
			Text = egg.Name,
			Font = Enum.Font.FredokaOne,
			TextScaled = true,
			TextColor3 = Color3.new(1, 1, 1),
		}, bg)
		mk("TextLabel", {
			Size = UDim2.new(1, 0, 0, 24),
			Position = UDim2.new(0, 0, 0, 28),
			BackgroundTransparency = 1,
			Text = "🫧 " .. tostring(egg.Cost),
			Font = Enum.Font.GothamBold,
			TextScaled = true,
			TextColor3 = Color3.fromRGB(255, 210, 120),
		}, bg)
		if egg.RequiredLevel and egg.RequiredLevel > 1 then
			mk("TextLabel", {
				Size = UDim2.new(1, 0, 0, 20),
				Position = UDim2.new(0, 0, 0, 56),
				BackgroundTransparency = 1,
				Text = "Unlocks at Level " .. tostring(egg.RequiredLevel),
				Font = Enum.Font.GothamBold,
				TextScaled = true,
				TextColor3 = Color3.fromRGB(255, 150, 150),
			}, bg)
		end

		local promptPart = mkPart("Part", {
			Name = "EggPromptPart" .. i,
			Size = Vector3.new(4, 1, 4),
			CFrame = CFrame.new(x - 3, 7.2, ez),
			Transparency = 1,
			CanCollide = false,
			CanTouch = false,
		}, parent)
		local prompt = mk("ProximityPrompt", {
			ActionText = "Hatch",
			ObjectText = egg.Name,
			RequiresLineOfSight = false,
			HoldDuration = 0,
			MaxActivationDistance = 12,
		}, promptPart) :: ProximityPrompt
		prompt:SetAttribute("OpenWindow", "Eggs")
		prompt:SetAttribute("EggId", egg.Id)
	end

	local standX, standZ = x, ORIGIN.Z + 34
	mkPart("Part", {
		Name = "PetStandBase",
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(4, 8, 8),
		CFrame = CFrame.new(standX, 2, standZ) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(255, 220, 240),
		Material = Enum.Material.SmoothPlastic,
	}, parent)
	local standSign = mkPart("Part", {
		Name = "PetStandSign",
		Size = Vector3.new(6, 4, 0.4),
		CFrame = CFrame.new(standX, 8, standZ),
		Color = Color3.fromRGB(255, 255, 255),
		CanCollide = false,
		CanQuery = false,
	}, parent)
	local sgui = mk("SurfaceGui", { Face = Enum.NormalId.Front, CanvasSize = Vector2.new(200, 120), LightInfluence = 0 }, standSign)
	mk("TextLabel", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "🐾 Pet Stand",
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(255, 120, 180),
	}, sgui)
	local standPromptPart = mkPart("Part", {
		Name = "PetStandPromptPart",
		Size = Vector3.new(4, 1, 4),
		CFrame = CFrame.new(standX, 4.5, standZ),
		Transparency = 1,
		CanCollide = false,
		CanTouch = false,
	}, parent)
	local standPrompt = mk("ProximityPrompt", {
		ActionText = "My Pets",
		ObjectText = "Pet Stand",
		RequiresLineOfSight = false,
		HoldDuration = 0,
		MaxActivationDistance = 12,
	}, standPromptPart) :: ProximityPrompt
	standPrompt:SetAttribute("OpenWindow", "Pets")
end
