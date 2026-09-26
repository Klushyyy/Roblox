-- ArenaBuilder: builds one dishwasher ("arena") for a run, entirely out of primitive parts, and
-- lays out the load of dirty dishes inside it. RoundService calls Build(slot, levelIndex, options)
-- once per run and Destroy(arena) when the run ends; nothing else touches workspace.Arenas directly.
--
-- Coordinate convention ("arena space"): every builder helper below works in local offsets
-- (x = sideways, y = up, z = depth) measured from `origin` (the tub floor centre, see SlotOrigin).
-- `origin.LookVector` is defined to point from the door toward the back wall (DESIGN.md section 5),
-- so +z is "into the tub". `worldPoint`/`worldCFrame` convert those offsets to world space.
--
-- Performance: the whole build (static geometry + every dish + every grime spot) yields with
-- task.wait() every ~200 parts, per DESIGN.md section 3, so a big load never hitches the server.

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DishFactory = require(script.Parent:WaitForChild("DishFactory"))

local ArenaBuilder = {}

----------------------------------------------------------------------------------------------------
-- Layout numbers (DESIGN.md section 5, ArenaBuilder). Arena-space units unless noted.
----------------------------------------------------------------------------------------------------
local TUB_HALF_X = 60
local TUB_Z_MIN, TUB_Z_MAX = -50, 50
local TUB_HEIGHT = 80

local DOOR_Z_FAR, DOOR_Z_NEAR = -120, -50 -- door spans this Z range, top at Y = 0
local SPAWN_Z = -95

local DRAIN_POS = Vector3.new(0, 0, -38)
local STATION_OFFSET = Vector3.new(14, 0, -38)

local RACK_HALF_X = 56
local RACK_Z_MIN, RACK_Z_MAX = -28, 46
local BOTTOM_RACK_Y = 3
local TOP_RACK_Y = 34

local PLATE_LINE_X = { -48, -32, -16, 0, 16, 32, 48 } -- spacing 16, matches "line spacing >= 16"
local PLATE_SLOT_Z = { -20, -12, -4, 4, 12, 20, 28, 36 } -- spacing 8, matches "plate spacing >= 8"

local PANPOT_X = { -40, -20, 0, 20, 40 }
local PANPOT_Z = 44

local BASKET_POS = Vector3.new(48, 0, -16) -- front-right, per DESIGN.md
local BASKET_HALF = Vector3.new(7, 5, 7)
local BASKET_RIM_Y = 10
local BASKET_DX = { -5, -2.5, 0, 2.5, 5 }
local BASKET_DZ = { -5, -1.7, 1.7, 5 }

local BOWL_X = { -48, -32, -16, 0, 16, 32, 48 }
local BOWL_Z = { -26, -18, -10, -2 }
local CUP_X = { -48, -24, 0, 24, 48 }
local CUP_Z = { 6, 14 }
local GLASS_X = { -48, -24, 0, 24, 48 }
local GLASS_Z = { 22, 30, 38 }

local TRUSS_X = { -TUB_HALF_X + 2, TUB_HALF_X - 2 }
local TRUSS_Z = -30
local LIFT_X = { -50, 50 }
local LIFT_Z = -34

local YIELD_EVERY = 200

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

-- A footprint CFrame usable as DishFactory.BuildDish's `cf`: Position is the contact point,
-- LookVector is the "face" direction (defaults to the arena's own forward), UpVector is world up.
local function footprint(origin: CFrame, x: number, y: number, z: number, lookDir: Vector3?): CFrame
	local pos = worldPoint(origin, x, y, z)
	local look = (lookDir or origin.LookVector)
	if look.Magnitude < 1e-4 then
		look = origin.LookVector
	end
	return CFrame.lookAt(pos, pos + look, Vector3.new(0, 1, 0))
end

local function newPart(props: { [string]: any }): BasePart
	local p = Instance.new("Part")
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Anchored = true
	return p
end

----------------------------------------------------------------------------------------------------
-- Static geometry builders. Each takes (model, origin, theme) and parents its parts into `model`
-- (which is already live under workspace.Arenas, so raycasts against dishes work once they're
-- parented too). They return how many parts they added, for the yield budget.
----------------------------------------------------------------------------------------------------

local function buildTub(model: Model, origin: CFrame, theme): number
	local depth = TUB_Z_MAX - TUB_Z_MIN
	local floor = newPart({
		Size = Vector3.new(TUB_HALF_X * 2 + 4, 2, depth),
		CFrame = footprint(origin, 0, -1, (TUB_Z_MIN + TUB_Z_MAX) / 2),
		Color = theme.Tub,
		Material = Enum.Material.Metal,
		CanCollide = true,
		CanQuery = false,
		CanTouch = false,
	})
	floor.Parent = model

	local count = 1
	for _, side in { -1, 1 } do
		local wall = newPart({
			Size = Vector3.new(2, TUB_HEIGHT, depth),
			CFrame = footprint(origin, side * (TUB_HALF_X + 1), TUB_HEIGHT / 2, (TUB_Z_MIN + TUB_Z_MAX) / 2),
			Color = theme.Tub,
			Material = Enum.Material.Metal,
			CanCollide = true,
			CanQuery = false,
			CanTouch = false,
		})
		wall.Parent = model
		count += 1
		-- A few horizontal ribs for a stainless-steel look.
		for i = 1, 5 do
			local ry = i * (TUB_HEIGHT / 6)
			local rib = newPart({
				Size = Vector3.new(0.4, 0.6, depth),
				CFrame = footprint(origin, side * (TUB_HALF_X + 2.1), ry, (TUB_Z_MIN + TUB_Z_MAX) / 2),
				Color = theme.Metal,
				Material = Enum.Material.Metal,
				CanCollide = false,
				CanQuery = false,
				CanTouch = false,
			})
			rib.Parent = model
			count += 1
		end
	end

	local back = newPart({
		Size = Vector3.new(TUB_HALF_X * 2 + 4, TUB_HEIGHT, 2),
		CFrame = footprint(origin, 0, TUB_HEIGHT / 2, TUB_Z_MAX + 1),
		Color = theme.Tub,
		Material = Enum.Material.Metal,
		CanCollide = true,
		CanQuery = false,
		CanTouch = false,
	})
	back.Parent = model
	count += 1

	local ceiling = newPart({
		Size = Vector3.new(TUB_HALF_X * 2 + 4, 2, depth + (DOOR_Z_NEAR - DOOR_Z_FAR)),
		CFrame = footprint(origin, 0, TUB_HEIGHT, (TUB_Z_MIN + DOOR_Z_FAR) / 2),
		Color = theme.Tub,
		Material = Enum.Material.Metal,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		Transparency = 0.15,
	})
	ceiling.Parent = model
	count += 1

	-- Interior mood lighting.
	for _, z in { -10, 30 } do
		local fixture = newPart({
			Size = Vector3.new(6, 1, 2),
			CFrame = footprint(origin, 0, TUB_HEIGHT - 3, z),
			Color = theme.Light,
			Material = Enum.Material.Neon,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
		})
		local light = Instance.new("PointLight")
		light.Color = theme.Light
		light.Brightness = 2
		light.Range = 45
		light.Parent = fixture
		fixture.Parent = model
		count += 1
	end

	-- A little floating-bubble mood ambience.
	local bubbleAnchor = newPart({
		Size = Vector3.new(1, 1, 1),
		CFrame = footprint(origin, 0, TUB_HEIGHT / 2, 10),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	local attach = Instance.new("Attachment")
	attach.Parent = bubbleAnchor
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/forcefield_glow_main.dds"
	emitter.Color = ColorSequence.new(theme.Accent)
	emitter.Lifetime = NumberRange.new(4, 7)
	emitter.Speed = NumberRange.new(2, 4)
	emitter.Rate = 1.5
	emitter.Size = NumberSequence.new(0.6, 0.1)
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.VelocitySpread = 40
	emitter.Parent = attach
	bubbleAnchor.Parent = model
	count += 1

	return count
end

local function buildDoorAndBackdrop(model: Model, origin: CFrame, theme): number
	local count = 0
	local doorLen = DOOR_Z_NEAR - DOOR_Z_FAR
	local doorFloor = newPart({
		Size = Vector3.new(TUB_HALF_X * 2, 2, doorLen),
		CFrame = footprint(origin, 0, -1, (DOOR_Z_FAR + DOOR_Z_NEAR) / 2),
		Color = theme.Rack,
		Material = Enum.Material.Metal,
		CanCollide = true,
		CanQuery = false,
		CanTouch = false,
	})
	doorFloor.Parent = model
	count += 1

	-- Inner panel details: a detergent cup, the rim, and a hinge line at the tub edge.
	local cup = newPart({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(1.5, 5, 5),
		CFrame = footprint(origin, -20, 0.8, DOOR_Z_NEAR - 12) * CFrame.Angles(0, 0, math.rad(90)),
		Color = theme.Accent,
		Material = Enum.Material.Plastic,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	cup.Parent = model
	count += 1

	local rim = newPart({
		Size = Vector3.new(TUB_HALF_X * 2, 0.4, 1.2),
		CFrame = footprint(origin, 0, 0.2, DOOR_Z_NEAR),
		Color = theme.Metal,
		Material = Enum.Material.Metal,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	rim.Parent = model
	count += 1

	for _, x in { -TUB_HALF_X + 6, TUB_HALF_X - 6 } do
		local hinge = newPart({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(4, 1, 1),
			CFrame = footprint(origin, x, 0.5, DOOR_Z_NEAR) * CFrame.Angles(0, math.rad(90), 0),
			Color = theme.Metal,
			Material = Enum.Material.Metal,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
		})
		hinge.Parent = model
		count += 1
	end

	-- A low lip at the far end plus invisible safety walls down both sides of the door.
	local lip = newPart({
		Size = Vector3.new(TUB_HALF_X * 2, 3, 2),
		CFrame = footprint(origin, 0, 1.5, DOOR_Z_FAR),
		Color = theme.Rack,
		Material = Enum.Material.Metal,
		CanCollide = true,
		CanQuery = false,
		CanTouch = false,
	})
	lip.Parent = model
	count += 1

	for _, side in { -1, 1 } do
		local wall = newPart({
			Size = Vector3.new(1, 10, doorLen),
			CFrame = footprint(origin, side * TUB_HALF_X, 5, (DOOR_Z_FAR + DOOR_Z_NEAR) / 2),
			Transparency = 1,
			CanCollide = true,
			CanQuery = false,
			CanTouch = false,
		})
		wall.Parent = model
		count += 1
	end

	-- Giant-kitchen backdrop beyond the door, so there's no void: a tiled floor far below,
	-- cabinet-front wall, and a bright window. Pure decoration, kept far from any collidable area.
	local farZ = DOOR_Z_FAR - 45
	local tiles = newPart({
		Size = Vector3.new(400, 2, 300),
		CFrame = footprint(origin, 0, -140, farZ - 80),
		Color = Color3.fromRGB(225, 225, 230),
		Material = Enum.Material.Concrete,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	tiles.Parent = model
	count += 1

	local cabinets = newPart({
		Size = Vector3.new(400, 260, 6),
		CFrame = footprint(origin, 0, -10, farZ - 20),
		Color = Color3.fromRGB(120, 82, 55),
		Material = Enum.Material.Wood,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	cabinets.Parent = model
	count += 1

	for i = -3, 3 do
		local seam = newPart({
			Size = Vector3.new(0.6, 260, 6.2),
			CFrame = footprint(origin, i * 55, -10, farZ - 20),
			Color = Color3.fromRGB(90, 60, 40),
			Material = Enum.Material.Wood,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
		})
		seam.Parent = model
		count += 1
	end

	local window = newPart({
		Size = Vector3.new(90, 60, 2),
		CFrame = footprint(origin, 120, 80, farZ - 17),
		Color = Color3.fromRGB(255, 250, 210),
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	local windowLight = Instance.new("SurfaceLight")
	windowLight.Face = Enum.NormalId.Front
	windowLight.Color = Color3.fromRGB(255, 250, 220)
	windowLight.Brightness = 3
	windowLight.Range = 200
	windowLight.Parent = window
	window.Parent = model
	count += 1

	return count
end

local function buildDrainAndStation(model: Model, origin: CFrame, theme): (number, Vector3, Vector3)
	local count = 0
	local radius = Config.Round.DrainRadius

	local grate = newPart({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, radius * 2, radius * 2),
		CFrame = footprint(origin, DRAIN_POS.X, 0.3, DRAIN_POS.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(70, 75, 80),
		Material = Enum.Material.DiamondPlate,
		CanCollide = true,
		CanQuery = false,
		CanTouch = false,
	})
	grate.Parent = model
	count += 1

	local ring = newPart({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, radius * 1.6, radius * 1.6),
		CFrame = footprint(origin, DRAIN_POS.X, 0.65, DRAIN_POS.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = theme.Accent,
		Material = Enum.Material.ForceField,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	ring.Parent = model
	ring:SetAttribute("SpinSpeed", 2.4)
	CollectionService:AddTag(ring, "SpinY")
	count += 1

	local signPost = newPart({
		Size = Vector3.new(0.6, 6, 0.6),
		CFrame = footprint(origin, DRAIN_POS.X, 3, DRAIN_POS.Z - radius - 1),
		Color = theme.Metal,
		Material = Enum.Material.Metal,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(220, 44)
	billboard.StudsOffset = Vector3.new(0, 3.4, 0)
	billboard.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0
	label.TextScaled = true
	label.Text = "🌀 DRAIN — stand here to sell"
	label.Parent = billboard
	billboard.Parent = signPost
	signPost.Parent = model
	count += 1

	local stationPos = DRAIN_POS + STATION_OFFSET
	local kioskBase = newPart({
		Size = Vector3.new(4, 4, 4),
		CFrame = footprint(origin, stationPos.X, 2, stationPos.Z),
		Color = theme.Rack,
		Material = Enum.Material.SmoothPlastic,
		CanCollide = true,
		CanQuery = false,
		CanTouch = false,
	})
	local kioskTop = newPart({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.6, 3.2, 3.2),
		CFrame = footprint(origin, stationPos.X, 4.3, stationPos.Z) * CFrame.Angles(0, 0, math.rad(90)),
		Color = theme.Accent,
		Material = Enum.Material.Neon,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
	})
	kioskTop.Parent = model
	count += 1

	local prompt = Instance.new("ProximityPrompt")
	prompt.ObjectText = "Upgrade Station"
	prompt.ActionText = "Open"
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt:SetAttribute("OpenWindow", "Upgrades")
	prompt.Parent = kioskBase
	kioskBase.Parent = model
	count += 1

	return count, worldPoint(origin, DRAIN_POS.X, 0, DRAIN_POS.Z), worldPoint(origin, stationPos.X, 0, stationPos.Z)
end

-- A walkable rack floor (invisible collidable plate + a visible thin wire grid) at height `y`.
local function buildRackFloor(model: Model, origin: CFrame, theme, y: number): number
	local width = RACK_HALF_X * 2
	local depth = RACK_Z_MAX - RACK_Z_MIN
	local plate = newPart({
		Size = Vector3.new(width, 1, depth),
		CFrame = footprint(origin, 0, y - 0.5, (RACK_Z_MIN + RACK_Z_MAX) / 2),
		Transparency = 1,
		CanCollide = true,
		CanQuery = false,
		CanTouch = false,
	})
	plate.Parent = model
	local count = 1

	for _, x in { -48, -32, -16, 0, 16, 32, 48 } do
		local bar = newPart({
			Size = Vector3.new(0.3, 0.3, depth),
			CFrame = footprint(origin, x, y, (RACK_Z_MIN + RACK_Z_MAX) / 2),
			Color = theme.Rack,
			Material = Enum.Material.Metal,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
		})
		bar.Parent = model
		count += 1
	end
	for i = 0, 6 do
		local z = RACK_Z_MIN + (depth / 6) * i
		local bar = newPart({
			Size = Vector3.new(width, 0.3, 0.3),
			CFrame = footprint(origin, 0, y, z),
			Color = theme.Rack,
			Material = Enum.Material.Metal,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
		})
		bar.Parent = model
		count += 1
	end

	return count
end

local function buildRamp(model: Model, origin: CFrame, theme): number
	local ramp = newPart({
		Size = Vector3.new(RACK_HALF_X * 2, 1, 8),
		CFrame = footprint(origin, 0, BOTTOM_RACK_Y / 2 - 0.3, RACK_Z_MIN - 3) * CFrame.Angles(math.rad(-19), 0, 0),
		Color = theme.Rack,
		Material = Enum.Material.Metal,
		CanCollide = true,
		CanQuery = false,
		CanTouch = false,
	})
	ramp.Parent = model
	return 1
end

local function buildCutleryBasket(model: Model, origin: CFrame, theme): number
	local count = 0
	local wallColor = theme.Metal
	local base = newPart({
		Size = Vector3.new(BASKET_HALF.X * 2, 1, BASKET_HALF.Z * 2),
		CFrame = footprint(origin, BASKET_POS.X, BOTTOM_RACK_Y + 0.5, BASKET_POS.Z),
		Color = wallColor,
		Material = Enum.Material.Metal,
		CanCollide = true,
		CanQuery = false,
		CanTouch = false,
	})
	base.Parent = model
	count += 1

	local wallY = BASKET_RIM_Y - BOTTOM_RACK_Y
	for _, offset in {
		{ dx = -BASKET_HALF.X, dz = 0, size = Vector3.new(0.4, wallY, BASKET_HALF.Z * 2) },
		{ dx = BASKET_HALF.X, dz = 0, size = Vector3.new(0.4, wallY, BASKET_HALF.Z * 2) },
		{ dx = 0, dz = -BASKET_HALF.Z, size = Vector3.new(BASKET_HALF.X * 2, wallY, 0.4) },
		{ dx = 0, dz = BASKET_HALF.Z, size = Vector3.new(BASKET_HALF.X * 2, wallY, 0.4) },
	} do
		local wall = newPart({
			Size = offset.size,
			CFrame = footprint(origin, BASKET_POS.X + offset.dx, BOTTOM_RACK_Y + wallY / 2, BASKET_POS.Z + offset.dz),
			Color = wallColor,
			Material = Enum.Material.DiamondPlate,
			Transparency = 0.35,
			CanCollide = true,
			CanQuery = false,
			CanTouch = false,
		})
		wall.Parent = model
		count += 1
	end

	return count
end

local function buildTrussAndLifts(model: Model, origin: CFrame, theme): number
	local count = 0
	for _, x in TRUSS_X do
		local segments = 3
		local segHeight = TOP_RACK_Y / segments
		for i = 1, segments do
			local truss = Instance.new("TrussPart")
			truss.Size = Vector3.new(2, segHeight, 2)
			truss.CFrame = footprint(origin, x, segHeight * (i - 0.5), TRUSS_Z)
			truss.Anchored = true
			truss.Color = theme.Metal
			truss.Material = Enum.Material.Metal
			truss.Parent = model
			count += 1
		end
	end

	for _, x in LIFT_X do
		local lift = newPart({
			Size = Vector3.new(6, TOP_RACK_Y + 2, 6),
			CFrame = footprint(origin, x, (TOP_RACK_Y + 2) / 2, LIFT_Z),
			Color = theme.Accent,
			Material = Enum.Material.ForceField,
			Transparency = 0.75,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
		})
		lift:SetAttribute("LiftSpeed", 45)
		CollectionService:AddTag(lift, "BubbleLift")

		local attach = Instance.new("Attachment")
		attach.Position = Vector3.new(0, -(TOP_RACK_Y + 2) / 2 + 1, 0)
		attach.Parent = lift
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = "rbxasset://textures/particles/forcefield_glow_main.dds"
		emitter.Color = ColorSequence.new(Color3.new(1, 1, 1))
		emitter.Lifetime = NumberRange.new(1.4, 2.2)
		emitter.Speed = NumberRange.new(6, 10)
		emitter.Rate = 8
		emitter.Size = NumberSequence.new(0.9, 0.2)
		emitter.SpreadAngle = Vector2.new(8, 8)
		emitter.Parent = attach

		lift.Parent = model
		count += 1
	end

	return count
end

local function buildSprayArms(model: Model, origin: CFrame, theme): number
	local count = 0
	for _, y in { 1.5, 31 } do
		local speed = 0.8 + (y > 20 and 0.3 or 0)
		for _, axis in { "X", "Z" } do
			local size = if axis == "X" then Vector3.new(RACK_HALF_X * 2 - 4, 0.8, 0.8) else Vector3.new(0.8, 0.8, RACK_Z_MAX - RACK_Z_MIN - 4)
			local arm = newPart({
				Size = size,
				CFrame = footprint(origin, 0, y, (RACK_Z_MIN + RACK_Z_MAX) / 2),
				Color = theme.Metal,
				Material = Enum.Material.Metal,
				CanCollide = false,
				CanQuery = false,
				CanTouch = false,
			})
			arm:SetAttribute("SpinSpeed", speed)
			CollectionService:AddTag(arm, "SpinY")
			arm.Parent = model
			count += 1

			-- Nozzle holes along the arm.
			local length = if axis == "X" then size.X else size.Z
			for i = 1, 5 do
				local t = (i - 3) * (length / 6)
				local nozzlePos = if axis == "X" then footprint(origin, t, y + 0.5, (RACK_Z_MIN + RACK_Z_MAX) / 2) else footprint(origin, 0, y + 0.5, (RACK_Z_MIN + RACK_Z_MAX) / 2 + t)
				local nozzle = newPart({
					Shape = Enum.PartType.Cylinder,
					Size = Vector3.new(0.5, 0.3, 0.3),
					CFrame = nozzlePos * CFrame.Angles(0, 0, math.rad(90)),
					Color = theme.Metal,
					Material = Enum.Material.Metal,
					CanCollide = false,
					CanQuery = false,
					CanTouch = false,
				})
				nozzle.Parent = model
				count += 1
			end
		end
	end
	return count
end

----------------------------------------------------------------------------------------------------
-- Dish layout: turns level.Dishes / level.Spots into placed dishes + grime.
----------------------------------------------------------------------------------------------------

type PlacedDish = {
	Id: number,
	Kind: string,
	Model: Model,
	Grime: { BasePart },
	Center: Vector3,
}

-- Builds a flat list of footprint specs { x, y, z, look } for a kind, capped to however many fit.
local function plateSlots(): { { x: number, y: number, z: number, look: string } }
	local slots = {}
	for li, x in PLATE_LINE_X do
		local look = if li % 2 == 0 then "forward" else "backward"
		for _, z in PLATE_SLOT_Z do
			table.insert(slots, { x = x, y = BOTTOM_RACK_Y, z = z, look = look })
		end
	end
	return slots
end

local function gridSlots(xs: { number }, zs: { number }, y: number): { { x: number, y: number, z: number } }
	local slots = {}
	for _, x in xs do
		for _, z in zs do
			table.insert(slots, { x = x, y = y, z = z })
		end
	end
	return slots
end

local function panPotSlots(): { { x: number, y: number, z: number } }
	local slots = {}
	for _, x in PANPOT_X do
		table.insert(slots, { x = x, y = BOTTOM_RACK_Y, z = PANPOT_Z })
	end
	return slots
end

local function basketSlots(): { { x: number, y: number, z: number } }
	local slots = {}
	for _, dx in BASKET_DX do
		for _, dz in BASKET_DZ do
			table.insert(slots, { x = BASKET_POS.X + dx, y = BOTTOM_RACK_Y, z = BASKET_POS.Z + dz })
		end
	end
	return slots
end

local KIND_SLOTS = {
	Plate = plateSlots,
	Bowl = function()
		return gridSlots(BOWL_X, BOWL_Z, TOP_RACK_Y)
	end,
	Cup = function()
		return gridSlots(CUP_X, CUP_Z, TOP_RACK_Y)
	end,
	Glass = function()
		return gridSlots(GLASS_X, GLASS_Z, TOP_RACK_Y)
	end,
	Pan = panPotSlots,
	Pot = panPotSlots,
	Fork = basketSlots,
	Knife = basketSlots,
	Spoon = basketSlots,
}

-- Builds every dish of one kind, applies grime, and appends to `dishes`/yield bookkeeping.
local function buildKind(
	model: Model,
	origin: CFrame,
	theme,
	kind: string,
	wantCount: number,
	spotsPerDish: number,
	levelIndex: number,
	rng: Random,
	grimeFolder: Folder,
	dishes: { [number]: PlacedDish },
	nextId: () -> number,
	yieldTick: (number) -> ()
): number
	if wantCount <= 0 then
		return 0
	end
	local slotsFn = KIND_SLOTS[kind]
	if not slotsFn then
		warn("[ArenaBuilder] No layout for dish kind " .. tostring(kind))
		return 0
	end
	local slots = slotsFn()
	-- Shared slot pools (Pan/Pot share panPotSlots, Fork/Knife/Spoon share basketSlots): offset by
	-- kind so different kinds sharing a pool don't stack on the same spots.
	local shift = 0
	if kind == "Pot" then
		shift = 2 -- Pan takes the first slots, Pot continues after (both counts are small)
	elseif kind == "Knife" then
		shift = 6
	elseif kind == "Spoon" then
		shift = 12
	end

	local placed = 0
	local totalGrime = 0
	for i = 1, wantCount do
		local slot = slots[i + shift]
		if not slot then
			warn(string.format("[ArenaBuilder] Only %d/%d slots available for %s; skipping the rest", math.max(0, #slots - shift), wantCount, kind))
			break
		end
		local lookDir = nil
		if slot.look == "backward" then
			lookDir = -origin.LookVector
		elseif slot.look == "forward" then
			lookDir = origin.LookVector
		end
		local cf = footprint(origin, slot.x, slot.y, slot.z, lookDir)
		local dish = DishFactory.BuildDish(kind, cf, theme, rng)
		dish.Parent = model -- must be live under workspace before ApplyGrime raycasts against it

		local id = nextId()
		local grime = DishFactory.ApplyGrime(dish, id, spotsPerDish, levelIndex, rng, 0, grimeFolder)
		-- Golden chance is applied per-arena by the caller via `spotsPerDish`'s sibling call below;
		-- see Build(), which passes the real GoldenChance through a closure-captured value instead.
		dishes[id] = {
			Id = id,
			Kind = kind,
			Model = dish,
			Grime = grime,
			Center = dish:GetPivot().Position,
		}
		placed += 1
		totalGrime += #grime
		yieldTick(1 + #dish:GetChildren() + #grime)
	end
	return totalGrime
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

	local grimeFolder = Instance.new("Folder")
	grimeFolder.Name = "Grime"
	grimeFolder.Parent = model

	local pending = 0
	local function yieldTick(n: number)
		pending += n
		if pending >= YIELD_EVERY then
			pending = 0
			task.wait()
		end
	end

	yieldTick(buildTub(model, origin, theme))
	yieldTick(buildDoorAndBackdrop(model, origin, theme))
	local drainCount, drainPos, stationPos = buildDrainAndStation(model, origin, theme)
	yieldTick(drainCount)
	yieldTick(buildRackFloor(model, origin, theme, BOTTOM_RACK_Y))
	yieldTick(buildRackFloor(model, origin, theme, TOP_RACK_Y))
	yieldTick(buildRamp(model, origin, theme))
	yieldTick(buildCutleryBasket(model, origin, theme))
	yieldTick(buildTrussAndLifts(model, origin, theme))
	yieldTick(buildSprayArms(model, origin, theme))

	local dishes: { [number]: PlacedDish } = {}
	local dishIdCounter = 0
	local function nextId(): number
		dishIdCounter += 1
		return dishIdCounter
	end

	-- ApplyGrime takes a single goldenChance; wrap it so buildKind's call site stays simple while
	-- still using the real per-run chance computed above.
	local totalGrime = 0
	for _, kind in Config.DishKinds do
		local wantCount = level.Dishes[kind] or 0
		if wantCount > 0 then
			local spotsPerDish = math.max(1, math.floor((level.Spots[kind] or 1) * grimeScale + 0.5))
			local slotsFn = KIND_SLOTS[kind]
			if slotsFn then
				local shift = 0
				if kind == "Pot" then
					shift = 2
				elseif kind == "Knife" then
					shift = 6
				elseif kind == "Spoon" then
					shift = 12
				end
				local slots = slotsFn()
				for i = 1, wantCount do
					local slotSpec = slots[i + shift]
					if not slotSpec then
						warn(string.format("[ArenaBuilder] Only %d slots available for %s; filling what fits", math.max(0, #slots - shift), kind))
						break
					end
					local lookDir = nil
					if slotSpec.look == "backward" then
						lookDir = -origin.LookVector
					elseif slotSpec.look == "forward" then
						lookDir = origin.LookVector
					end
					local cf = footprint(origin, slotSpec.x, slotSpec.y, slotSpec.z, lookDir)
					local dish = DishFactory.BuildDish(kind, cf, theme, rng)
					dish.Parent = model

					local id = nextId()
					local grime = DishFactory.ApplyGrime(dish, id, spotsPerDish, levelIndex, rng, goldenChance, grimeFolder)
					dishes[id] = {
						Id = id,
						Kind = kind,
						Model = dish,
						Grime = grime,
						Center = dish:GetPivot().Position,
					}
					totalGrime += #grime
					yieldTick(1 + #dish:GetChildren() + #grime)
				end
			end
		end
	end

	model:SetAttribute("Level", levelIndex)
	model:SetAttribute("Total", totalGrime)
	model:SetAttribute("Cleaned", 0)

	local spawns: { CFrame } = {}
	for _, x in { -9, -3, 3, 9 } do
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
		KillY = origin.Position.Y - 60,
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
