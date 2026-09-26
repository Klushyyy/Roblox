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
local TweenService = game:GetService("TweenService")
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

local BOARD_Z = 56 -- behind the spawn, facing into the plaza, so they never hide the shops
local HATCHERY_Z = -76 -- front face of the dishwasher building (it faces +Z, toward the spawn)
local EGG_Z = -66
local SHOP_X = -40
local PETSTAND_X = 40

-- Colors
local TILE_A = Color3.fromRGB(226, 218, 204)
local TILE_B = Color3.fromRGB(182, 206, 222)
local GRASS = Color3.fromRGB(116, 170, 86)
local FENCE = Color3.fromRGB(252, 252, 250)
local STEEL = Color3.fromRGB(205, 210, 216)
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
	if props.CanQuery == nil then
		inst.CanQuery = false
	end
	inst.TopSurface = Enum.SurfaceType.Smooth
	inst.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(inst :: any)[k] = v
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
-- Ground: a lawn, the tiled plaza, a white picket fence and invisible walls.
----------------------------------------------------------------------------------------------------
local function buildGround(parent: Instance)
	-- Safety floor under everything (the real ground is Terrain, see buildTerrain).
	mkPart("Part", {
		Name = "SafetyFloor",
		Size = Vector3.new(700, 2, 700),
		CFrame = at(0, -3, -20),
		Color = GRASS,
		Transparency = 1,
		CastShadow = false,
	}, parent)

	-- Plaza: large two-tone tiles (few parts, still reads as a tiled floor).
	local tile = 16
	for x = -PLAZA_X, PLAZA_X - tile, tile do
		for z = PLAZA_Z0, PLAZA_Z1 - tile, tile do
			local ix, iz = (x + PLAZA_X) // tile, (z - PLAZA_Z0) // tile
			mkPart("Part", {
				Name = "Tile",
				Size = Vector3.new(tile, 0.4, tile),
				CFrame = at(x + tile / 2, FLOOR_Y - 0.2, z + tile / 2),
				Color = if (ix + iz) % 2 == 0 then TILE_A else TILE_B,
				Material = Enum.Material.SmoothPlastic,
			}, parent)
		end
	end

	-- A path from spawn to the dishwasher building.
	mkPart("Part", {
		Name = "Path",
		Size = Vector3.new(14, 0.1, 110),
		CFrame = at(0, FLOOR_Y + 0.05, -30),
		Color = Color3.fromRGB(150, 188, 212),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CastShadow = false,
	}, parent)

	-- Picket fence around the plaza.
	local fx0, fx1 = -PLAZA_X - FENCE_MARGIN, PLAZA_X + FENCE_MARGIN
	local fz0, fz1 = PLAZA_Z0 - FENCE_MARGIN, PLAZA_Z1 + FENCE_MARGIN
	local function fenceRun(x0: number, z0: number, x1: number, z1: number)
		local len = math.max(math.abs(x1 - x0), math.abs(z1 - z0))
		local alongX = math.abs(x1 - x0) > math.abs(z1 - z0)
		for _, y in { 1.6, 3.4 } do
			mkPart("Part", {
				Name = "FenceRail",
				Size = if alongX then Vector3.new(len, 0.5, 0.3) else Vector3.new(0.3, 0.5, len),
				CFrame = at((x0 + x1) / 2, y, (z0 + z1) / 2),
				Color = FENCE,
				CanCollide = false,
			}, parent)
		end
		local posts = math.floor(len / 3)
		for i = 0, posts do
			local t = i / posts
			local px, pz = x0 + (x1 - x0) * t, z0 + (z1 - z0) * t
			mkPart("Part", {
				Name = "Picket",
				Size = Vector3.new(0.6, 4.6, 0.6),
				CFrame = at(px, 2.3, pz),
				Color = FENCE,
				CanCollide = false,
			}, parent)
		end
	end
	fenceRun(fx0, fz0, fx1, fz0)
	fenceRun(fx0, fz1, fx1, fz1)
	fenceRun(fx0, fz0, fx0, fz1)
	fenceRun(fx1, fz0, fx1, fz1)

	-- Invisible walls just behind the fence.
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
		CFrame = at(SPAWN.X, 1.2, SPAWN.Z),
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
		Text = "🧼\n" .. string.upper(Config.GameName),
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

-- Terrain around the plaza: rolling grass, hills, and a ring of snowy mountains on the horizon.
-- Built in the background after the lobby (it's a lot of voxels), with small yields.
local function buildTerrain()
	local terrain = workspace.Terrain
	pcall(function()
		terrain:Clear()
	end)
	local o = ORIGIN
	-- Grass ground, top at Y = 0 (a voxel boundary).
	terrain:FillBlock(CFrame.new(o.X, o.Y - 8, o.Z - 20), Vector3.new(1600, 16, 1600), Enum.Material.Grass)
	task.wait()
	local rng = Random.new(7)
	-- Rolling hills just outside the fence.
	for i = 1, 22 do
		local a = i / 22 * math.pi * 2 + rng:NextNumber(-0.1, 0.1)
		local dist = rng:NextNumber(180, 290)
		local r = rng:NextNumber(35, 70)
		terrain:FillBall(Vector3.new(o.X + math.cos(a) * dist, o.Y - r * 0.55, o.Z - 20 + math.sin(a) * dist), r, Enum.Material.Grass)
		if i % 4 == 0 then
			task.wait()
		end
	end
	-- Mountains: rock bodies with snow on top, two ranges deep so the horizon has layers.
	for i = 1, 16 do
		local a = i / 16 * math.pi * 2 + rng:NextNumber(-0.08, 0.08)
		local dist = rng:NextNumber(520, 640)
		local r = rng:NextNumber(110, 170)
		local c = Vector3.new(o.X + math.cos(a) * dist, o.Y - r * 0.25, o.Z - 20 + math.sin(a) * dist)
		terrain:FillBall(c, r, Enum.Material.Rock)
		terrain:FillBall(c + Vector3.new(rng:NextNumber(-60, 60), -r * 0.2, rng:NextNumber(-60, 60)), r * 0.8, Enum.Material.Rock)
		terrain:FillBall(c + Vector3.new(0, r * 0.62, 0), r * 0.42, Enum.Material.Snow)
		-- Grassy foothill in front of it.
		terrain:FillBall(c - (c - Vector3.new(o.X, c.Y, o.Z)).Unit * r * 0.8 - Vector3.new(0, r * 0.3, 0), r * 0.6, Enum.Material.Grass)
		task.wait()
	end
	pcall(function()
		(terrain :: any).Decoration = true
	end)
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
	local countLbl = line("Count", 0.2, 0.42, "0/4", Color3.new(1, 1, 1), Enum.Font.FredokaOne)
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
	mkPart("Part", { Name = "Body", Size = Vector3.new(w, h, d), CFrame = at(0, h / 2, z), Color = STEEL, Material = Enum.Material.Metal }, parent)
	-- Door panel with a recessed window and handle.
	mkPart("Part", decor({ Name = "Door", Size = Vector3.new(w - 6, h - 16, 1), CFrame = at(0, (h - 16) / 2 + 3, HATCHERY_Z + 0.5), Color = Color3.fromRGB(225, 229, 234), Material = Enum.Material.Metal }), parent)
	local window = mkPart("Part", decor({ Name = "Window", Size = Vector3.new(w - 26, h - 30, 0.6), CFrame = at(0, (h - 16) / 2 + 3, HATCHERY_Z + 1.1), Color = Color3.fromRGB(120, 200, 245), Material = Enum.Material.Glass, Transparency = 0.2 }), parent)
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
	mkPart("Part", decor({ Name = "Handle", Size = Vector3.new(30, 2, 2), CFrame = at(0, h - 17, HATCHERY_Z + 2), Color = Color3.fromRGB(170, 176, 184), Material = Enum.Material.Metal }), parent)
	-- Control panel strip with the title and a few glowing buttons.
	local panel = mkPart("Part", { Name = "ControlPanel", Size = Vector3.new(w, 12, 2), CFrame = at(0, h - 6, HATCHERY_Z + 1), Color = Color3.fromRGB(40, 46, 58), Material = Enum.Material.SmoothPlastic }, parent)
	-- Back is the +Z face of an unrotated part, which is the side facing the spawn.
	local gui = mk("SurfaceGui", { Face = Enum.NormalId.Back, CanvasSize = Vector2.new(1400, 200), LightInfluence = 0 }, panel)
	local title = mk("TextLabel", {
		Size = UDim2.fromScale(0.7, 0.9),
		Position = UDim2.fromScale(0.03, 0.05),
		BackgroundTransparency = 1,
		Text = "🧼 " .. string.upper(Config.GameName),
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
	-- Feet.
	for _, x in { -w / 2 + 4, w / 2 - 4 } do
		mkPart("Part", decor({ Name = "Foot", Size = Vector3.new(6, 2, 6), CFrame = at(x, 1, HATCHERY_Z + 2), Color = Color3.fromRGB(60, 60, 66) }), parent)
	end
	-- Steam puffing out of the top.
	local vent = mkPart("Part", decor({ Name = "Vent", Size = Vector3.new(10, 1, 4), CFrame = at(-24, h + 0.5, z), Color = Color3.fromRGB(150, 155, 160), Material = Enum.Material.Metal }), parent)
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
	mkPart("Part", decor({ Name = "CounterTop", Size = Vector3.new(17, 0.6, 7), CFrame = at(x, 4.3, z), Color = Color3.fromRGB(120, 78, 48), Material = Enum.Material.Wood }), parent)
	for _, dx in { -7.5, 7.5 } do
		mkPart("Part", decor({ Name = "AwningPost", Size = Vector3.new(0.8, 12, 0.8), CFrame = at(x + dx, 6, z - 2.5), Color = Color3.fromRGB(250, 250, 250) }), parent)
	end
	for i = 0, 7 do
		mkPart("Part", decor({
			Name = "Awning",
			Size = Vector3.new(2.2, 0.6, 9),
			CFrame = at(x - 7.7 + i * 2.2, 12.5, z - 1) * CFrame.Angles(math.rad(-12), 0, 0),
			Color = if i % 2 == 0 then Color3.fromRGB(80, 190, 250) else Color3.new(1, 1, 1),
		}), parent)
	end
	-- Giant pump bottle behind the stall.
	mkPart("Part", { Name = "Bottle", Shape = Enum.PartType.Cylinder, Size = Vector3.new(16, 9, 9), CFrame = upright(x, 8, z - 8), Color = Color3.fromRGB(255, 150, 200), Material = Enum.Material.Glass, Transparency = 0.1 }, parent)
	mkPart("Part", decor({ Name = "BottleCap", Shape = Enum.PartType.Cylinder, Size = Vector3.new(3, 5, 5), CFrame = upright(x, 17.5, z - 8), Color = Color3.new(1, 1, 1) }), parent)
	mkPart("Part", decor({ Name = "PumpNeck", Size = Vector3.new(1.2, 4, 1.2), CFrame = at(x, 20.5, z - 8), Color = Color3.fromRGB(220, 220, 225), Material = Enum.Material.Metal }), parent)
	mkPart("Part", decor({ Name = "PumpHead", Size = Vector3.new(4.5, 1.2, 1.4), CFrame = at(x + 1.6, 22.8, z - 8), Color = Color3.new(1, 1, 1) }), parent)
	worldSign(counter, "🧴 SOAP SHOP", 14, 3, 16.5, Color3.fromRGB(255, 235, 140))
	worldSign(counter, "Perks", 8, 1.8, 14, Color3.fromRGB(220, 235, 255))

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
		worldSign(pedestal, "🧼 " .. tostring(egg.Cost), 7, 1.8, 16.3, Color3.fromRGB(255, 210, 120))
		if egg.RequiredLevel and egg.RequiredLevel > 1 then
			worldSign(pedestal, "🔒 Level " .. tostring(egg.RequiredLevel), 7, 1.5, 14.4, Color3.fromRGB(255, 160, 160))
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

local function buildPetStand(parent: Instance)
	local x, z = PETSTAND_X, EGG_Z
	local base = mkPart("Part", { Name = "PetStand", Shape = Enum.PartType.Cylinder, Size = Vector3.new(3, 12, 12), CFrame = upright(x, 1.5, z), Color = Color3.fromRGB(255, 205, 230), Material = Enum.Material.SmoothPlastic }, parent)
	-- A little doghouse.
	mkPart("Part", { Name = "Doghouse", Size = Vector3.new(7, 6, 6), CFrame = at(x, 6, z - 1), Color = Color3.fromRGB(240, 120, 150), Material = Enum.Material.WoodPlanks }, parent)
	for _, side in { -1, 1 } do
		mkPart("Part", decor({ Name = "Roof", Size = Vector3.new(5.2, 0.6, 7), CFrame = at(x + side * 2.1, 10.2, z - 1) * CFrame.Angles(0, 0, math.rad(side * -40)), Color = Color3.fromRGB(120, 60, 50) }), parent)
	end
	mkPart("Part", decor({ Name = "DoghouseDoor", Size = Vector3.new(3, 3.6, 0.3), CFrame = at(x, 4.8, z + 2.05), Color = Color3.fromRGB(40, 30, 30) }), parent)
	worldSign(base, "🐾 PETS", 10, 2.6, 13, Color3.fromRGB(255, 170, 210))
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
local function boardShell(parent: Instance, x: number, z: number, w: number, h: number, name: string): BasePart
	-- An unrotated part's Front face points -Z: toward the plaza from here.
	local boardPart = mkPart("Part", {
		Name = name,
		Size = Vector3.new(w, h, 1),
		CFrame = at(x, h / 2 + 3, z),
		Color = NAVY,
		Material = Enum.Material.SmoothPlastic,
	}, parent)
	mkPart("Part", decor({ Name = "Trim", Size = Vector3.new(w + 1.4, h + 1.4, 0.6), CFrame = at(x, h / 2 + 3, z + 0.7), Color = Color3.new(1, 1, 1) }), parent)
	for _, dx in { -w / 2 + 2, w / 2 - 2 } do
		mkPart("Part", { Name = "Leg", Size = Vector3.new(1.2, 3.2, 1.2), CFrame = at(x + dx, 1.6, z), Color = Color3.fromRGB(150, 155, 160), Material = Enum.Material.Metal }, parent)
	end
	return boardPart
end

local function buildBoard(parent: Instance, x: number, z: number, titleText: string): BoardInfo
	local boardPart = boardShell(parent, x, z, 22, 15, "Board")
	local gui = mk("SurfaceGui", { Face = Enum.NormalId.Front, CanvasSize = Vector2.new(700, 480), LightInfluence = 0 }, boardPart)
	mk("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, gui)
	local titleLbl = mk("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 64),
		BackgroundTransparency = 1,
		Text = titleText,
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
	}, gui) :: TextLabel
	mk("UIStroke", { Thickness = 3, Color = Color3.fromRGB(10, 30, 60) }, titleLbl)
	local list = mk("Frame", {
		Name = "List",
		Size = UDim2.new(1, 0, 1, -70),
		Position = UDim2.new(0, 0, 0, 70),
		BackgroundTransparency = 1,
	}, gui) :: Frame
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, list)
	return { Part = boardPart, Title = titleLbl, List = list }
end

local function buildHowToPlay(parent: Instance, x: number, z: number)
	local boardPart = boardShell(parent, x, z, 24, 15, "HowToPlayBoard")
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
		"Step on a party pad and pick a dishwasher.",
		"Aim at the dirt and HOLD to scrub it off.",
		"Stand in the drain to sell your tank for coins.",
		"Buy better tools and upgrades on the door.",
		"Clean every dish, earn 🧼 and hatch pets!",
	}
	for i, text in steps do
		mk("TextLabel", {
			Name = "Step" .. i,
			Size = UDim2.new(1, 0, 0, 62),
			BackgroundTransparency = 1,
			Text = tostring(i) .. ". " .. text,
			Font = Enum.Font.GothamBold,
			TextScaled = true,
			TextColor3 = Color3.fromRGB(20, 40, 70),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			LayoutOrder = i,
		}, list)
	end
end

----------------------------------------------------------------------------------------------------
-- Decorations: trees, hedges, soap bars, a giant sponge, floating bubbles.
----------------------------------------------------------------------------------------------------
local function tree(parent: Instance, x: number, z: number, scale: number)
	mkPart("Part", { Name = "Trunk", Shape = Enum.PartType.Cylinder, Size = Vector3.new(10 * scale, 2.4 * scale, 2.4 * scale), CFrame = upright(x, 5 * scale, z), Color = Color3.fromRGB(120, 85, 55), Material = Enum.Material.Wood }, parent)
	for i, off in { Vector3.new(0, 12, 0), Vector3.new(2.5, 10, 1.5), Vector3.new(-2.5, 10.5, -1) } do
		local s = (if i == 1 then 10 else 7) * scale
		mkPart("Part", decor({
			Name = "Leaves",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(s, s, s),
			CFrame = at(x + off.X * scale, off.Y * scale, z + off.Z * scale),
			Color = Color3.fromRGB(90 + i * 12, 170 + i * 6, 80),
			Material = Enum.Material.Grass,
		}), parent)
	end
end

-- Rank Shrine: a floating, spinning crystal over a pedestal. Opens the Ranks window.
local function buildRankShrine(parent: Instance)
	local x, z = -30, 30
	local base = mkPart("Part", { Name = "ShrineBase", Shape = Enum.PartType.Cylinder, Size = Vector3.new(1.6, 12, 12), CFrame = upright(x, 1, z), Color = Color3.fromRGB(60, 40, 110), Material = Enum.Material.SmoothPlastic }, parent)
	mkPart("Part", { Name = "ShrinePillar", Shape = Enum.PartType.Cylinder, Size = Vector3.new(4, 5, 5), CFrame = upright(x, 3.8, z), Color = Color3.fromRGB(235, 225, 250), Material = Enum.Material.Marble }, parent)
	mkPart("Part", decor({ Name = "ShrineRing", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 13, 13), CFrame = upright(x, 1.65, z), Color = Color3.fromRGB(255, 120, 200), Material = Enum.Material.Neon }), parent)
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
	worldSign(base, "💎 RANKS", 10, 2.6, 15.5, Color3.fromRGB(230, 190, 255))
	worldSign(base, string.format("Roll for %d 💎", Config.RankRoll.Cost), 8, 1.6, 13.4, Color3.fromRGB(255, 255, 255))
	local prompt = mk("ProximityPrompt", {
		ActionText = "Roll Ranks",
		ObjectText = "Rank Shrine",
		RequiresLineOfSight = false,
		HoldDuration = 0,
		MaxActivationDistance = 12,
	}, base) :: ProximityPrompt
	prompt:SetAttribute("OpenWindow", "Ranks")
end

local function buildDecorations(parent: Instance)
	for _, spot in { { -85, -90, 1.3 }, { 85, -90, 1.3 }, { -88, 52, 1 }, { 88, 52, 1 }, { -130, -30, 1.6 }, { 130, -30, 1.6 }, { -120, 70, 1.4 }, { 120, 70, 1.4 }, { 0, -140, 1.8 } } do
		tree(parent, spot[1], spot[2], spot[3])
	end
	-- Hedges along the back fence, either side of the building.
	for _, x in { -70, 70 } do
		mkPart("Part", decor({ Name = "Hedge", Size = Vector3.new(40, 5, 5), CFrame = at(x, 2.5, PLAZA_Z0 + 3), Color = Color3.fromRGB(80, 150, 70), Material = Enum.Material.Grass }), parent)
	end
	-- Giant sponge and soap bars around the spawn.
	mkPart("Part", { Name = "GiantSponge", Size = Vector3.new(12, 5, 8), CFrame = at(-80, 2.7, 46) * CFrame.Angles(0, math.rad(20), 0), Color = Color3.fromRGB(255, 215, 90), Material = Enum.Material.Sand }, parent)
	mkPart("Part", decor({ Name = "SpongeScrub", Size = Vector3.new(12.2, 1.6, 8.2), CFrame = at(-80, 5.9, 46) * CFrame.Angles(0, math.rad(20), 0), Color = Color3.fromRGB(80, 180, 100), Material = Enum.Material.Fabric }), parent)
	mkPart("Part", { Name = "SoapBar", Size = Vector3.new(10, 3.5, 6), CFrame = at(30, 2, 30) * CFrame.Angles(0, math.rad(-15), 0), Color = Color3.fromRGB(190, 230, 255), Material = Enum.Material.SmoothPlastic }, parent)
	mkPart("Part", { Name = "SoapBar", Size = Vector3.new(8, 3, 5), CFrame = at(31, 5.3, 30) * CFrame.Angles(0, math.rad(10), 0), Color = Color3.fromRGB(255, 190, 220), Material = Enum.Material.SmoothPlastic }, parent)

	-- Floating soap bubbles bobbing on cheap tween loops.
	local bubbleFolder = mk("Folder", { Name = "Bubbles" }, parent)
	for i = 1, 12 do
		local pos = at(math.random(-80, 80), 14 + math.random(0, 16), math.random(-80, 50)).Position
		local size = 2 + math.random() * 2
		local bubble = mkPart("Part", {
			Name = "Bubble" .. i,
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(size, size, size),
			CFrame = CFrame.new(pos),
			Color = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.ForceField,
			Transparency = 0.4,
			CanCollide = false,
			CastShadow = false,
		}, bubbleFolder)
		task.spawn(function()
			local base = bubble.Position
			while bubble.Parent do
				local tw = TweenService:Create(
					bubble,
					TweenInfo.new(3 + math.random() * 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ Position = base + Vector3.new(math.random(-3, 3), math.random(-2, 5), math.random(-3, 3)) }
				)
				tw:Play()
				tw.Completed:Wait()
			end
		end)
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

	local pads: { PadInfo } = {}
	for i = 1, PAD_COUNT do
		pads[i] = buildPad(model, i)
	end

	buildDishwasherBuilding(model)
	buildEggHatchery(model)
	buildSoapShop(model)
	buildPetStand(model)

	local timesBoard = buildBoard(model, -28, BOARD_Z, "Fastest Clean")
	local dishesBoard = buildBoard(model, 28, BOARD_Z, "Most Dishes Cleaned")
	buildHowToPlay(model, 0, BOARD_Z + 3)

	buildRankShrine(model)
	buildDecorations(model)
	setupLighting()

	local built: Lobby = {
		Model = model,
		Pads = pads,
		Boards = { Times = timesBoard, Dishes = dishesBoard },
	}
	lobby = built
	task.spawn(function()
		local ok, err = pcall(buildTerrain)
		if not ok then
			warn("[LobbyBuilder] terrain failed: " .. tostring(err))
		end
	end)
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
	return CFrame.new(pos, pos + Vector3.new(0, 0, -10))
end

return LobbyBuilder
