-- ToolModels: builds a model of each cleaning tool out of primitive parts. Used for the arena's tool
-- shelf (anchored, big) and for the tool in a player's hand (welded, small).
--
-- ToolModels.Build(toolIndex, scale) -> Model
--   * built around CFrame.identity: the model's base sits on Y = 0 and its business end points at -Z
--   * PrimaryPart is "Grip", an invisible 0.2 stud part at the origin
--   * every part is Anchored, CanCollide/CanQuery/CanTouch false, Massless, CastShadow false
--   * Bare Hands (index 1) is just the Grip
-- ToolModels.HoldOffset(toolIndex) -> CFrame: where the Grip sits relative to a RightHand (R15) so
-- the tool looks held.

local ToolModels = {}

local DARK = Color3.fromRGB(45, 45, 52)
local WHITE = Color3.fromRGB(245, 247, 250)
local CHROME = Color3.fromRGB(205, 210, 218)
local WOOD = Color3.fromRGB(160, 110, 70)

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis -> up
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis -> front/back

local COLORS = {
	Color3.fromRGB(150, 210, 255),
	Color3.fromRGB(255, 221, 87),
	Color3.fromRGB(120, 230, 160),
	Color3.fromRGB(90, 200, 255),
	Color3.fromRGB(60, 140, 255),
	Color3.fromRGB(200, 150, 255),
}

type Ctx = { Model: Model, Scale: number }

local function part(ctx: Ctx, name: string, shape: Enum.PartType?, size: Vector3, offset: Vector3, rot: CFrame?, color: Color3, material: Enum.Material?, transparency: number?): Part
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
	p.Size = size * ctx.Scale
	p.CFrame = CFrame.new(offset * ctx.Scale) * (rot or CFrame.identity)
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Transparency = transparency or 0
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = ctx.Model
	return p
end

-- A cylinder running from a to b (model-local studs, before scaling).
local function bar(ctx: Ctx, name: string, a: Vector3, b: Vector3, thickness: number, color: Color3, material: Enum.Material?): Part
	local dir = (b - a)
	local mid = (a + b) / 2
	local hint = if math.abs(dir.Unit.Y) > 0.95 then Vector3.new(1, 0, 0) else Vector3.new(0, 1, 0)
	local rot = CFrame.fromMatrix(Vector3.zero, dir.Unit, hint:Cross(dir.Unit).Unit:Cross(dir.Unit) * -1)
	return part(ctx, name, Enum.PartType.Cylinder, Vector3.new(dir.Magnitude, thickness, thickness), mid, rot, color, material)
end

local BUILDERS: { [number]: (Ctx, Color3) -> () } = {}

-- Sponge: yellow foam with rounded ends, a green scrubber layer, a few pores.
BUILDERS[2] = function(ctx, _color)
	local yellow = Color3.fromRGB(255, 214, 80)
	part(ctx, "Foam", nil, Vector3.new(2.8, 1.6, 2.2), Vector3.new(0, 0.8, 0), nil, yellow, Enum.Material.Sand)
	for _, x in { -1.4, 1.4 } do
		part(ctx, "FoamEnd", Enum.PartType.Cylinder, Vector3.new(2.2, 1.6, 1.6), Vector3.new(x, 0.8, 0), ALONG_Z, yellow, Enum.Material.Sand)
	end
	part(ctx, "Scrubber", nil, Vector3.new(3.6, 0.5, 2.2), Vector3.new(0, 1.85, 0), nil, Color3.fromRGB(70, 165, 80), Enum.Material.Fabric)
	for _, o in { Vector3.new(-0.9, 0.6, -1.08), Vector3.new(0.3, 1.1, -1.08), Vector3.new(1.0, 0.45, -1.08), Vector3.new(-0.2, 0.35, -1.08) } do
		part(ctx, "Pore", Enum.PartType.Ball, Vector3.new(0.34, 0.34, 0.34), o, nil, Color3.fromRGB(215, 172, 50), Enum.Material.Sand)
	end
end

-- Scrub brush: rounded coloured head, white bristle rows, angled wooden handle with a knob.
BUILDERS[3] = function(ctx, color)
	part(ctx, "Head", nil, Vector3.new(2.6, 0.9, 1.6), Vector3.new(0, 1.0, 0), nil, color)
	for _, x in { -1.3, 1.3 } do
		part(ctx, "HeadEnd", Enum.PartType.Cylinder, Vector3.new(0.9, 1.6, 1.6), Vector3.new(x, 1.0, 0), UPRIGHT, color)
	end
	for i = -2, 2 do
		part(ctx, "Bristles", nil, Vector3.new(0.4, 0.7, 1.3), Vector3.new(i * 0.6, 0.35, 0), nil, WHITE, Enum.Material.Fabric)
	end
	-- Handle: an angled wooden bar rising from the back of the head, with a knob on the end.
	bar(ctx, "Handle", Vector3.new(0, 1.3, 0.5), Vector3.new(0, 2.9, 3.0), 0.6, WOOD, Enum.Material.Wood)
	part(ctx, "Knob", Enum.PartType.Ball, Vector3.new(0.9, 0.9, 0.9), Vector3.new(0, 2.95, 3.1), nil, WOOD, Enum.Material.Wood)
	part(ctx, "Ferrule", Enum.PartType.Cylinder, Vector3.new(0.5, 0.8, 0.8), Vector3.new(0, 1.45, 0.75), CFrame.Angles(math.rad(-58), 0, 0) * UPRIGHT, CHROME, Enum.Material.Metal)
end

-- Spray nozzle: pistol grip, barrel, chrome tip, trigger, a stub of green hose.
BUILDERS[4] = function(ctx, color)
	part(ctx, "Grip", nil, Vector3.new(0.8, 2, 1), Vector3.new(0, 1.1, 0.7), CFrame.Angles(math.rad(-15), 0, 0), DARK)
	part(ctx, "Barrel", Enum.PartType.Cylinder, Vector3.new(3.2, 1, 1), Vector3.new(0, 2.3, -0.4), ALONG_Z, color)
	part(ctx, "Collar", Enum.PartType.Cylinder, Vector3.new(0.3, 1.2, 1.2), Vector3.new(0, 2.3, -1.9), ALONG_Z, CHROME, Enum.Material.Metal)
	part(ctx, "Tip", Enum.PartType.Cylinder, Vector3.new(0.9, 0.6, 0.6), Vector3.new(0, 2.3, -2.4), ALONG_Z, CHROME, Enum.Material.Metal)
	part(ctx, "Trigger", nil, Vector3.new(0.3, 0.8, 0.3), Vector3.new(0, 1.6, -0.2), nil, DARK)
	part(ctx, "Hose", Enum.PartType.Cylinder, Vector3.new(2, 0.45, 0.45), Vector3.new(0, 0.3, 1.9), ALONG_Z, Color3.fromRGB(60, 140, 70))
end

-- Pressure washer: rounded body, wheels, push handle, gun and chrome wand.
BUILDERS[5] = function(ctx, color)
	part(ctx, "Body", nil, Vector3.new(2.8, 1.6, 3.2), Vector3.new(0, 1.4, 0.4), nil, color)
	part(ctx, "Top", Enum.PartType.Cylinder, Vector3.new(3.2, 2.8, 2.8), Vector3.new(0, 2.2, 0.4), ALONG_Z, color)
	part(ctx, "Badge", nil, Vector3.new(1.4, 0.6, 0.1), Vector3.new(0, 1.6, -1.25), nil, WHITE)
	for _, x in { -1.5, 1.5 } do
		part(ctx, "Wheel", Enum.PartType.Cylinder, Vector3.new(0.5, 1.4, 1.4), Vector3.new(x, 0.7, 1.3), nil, DARK)
		part(ctx, "HandlePost", nil, Vector3.new(0.3, 2.4, 0.3), Vector3.new(x * 0.75, 3.4, 1.9), nil, DARK)
	end
	part(ctx, "HandleBar", nil, Vector3.new(2.6, 0.35, 0.35), Vector3.new(0, 4.6, 1.9), nil, DARK)
	part(ctx, "Gun", nil, Vector3.new(0.6, 1, 0.9), Vector3.new(1.9, 1.3, -0.3), nil, DARK)
	part(ctx, "Wand", Enum.PartType.Cylinder, Vector3.new(3.6, 0.3, 0.3), Vector3.new(1.9, 1.7, -2.4), ALONG_Z, CHROME, Enum.Material.Metal)
end

-- Foam cannon: pistol grip and trigger, a see-through soap bottle hanging under a white barrel, a
-- wide bell, and foam spilling out of the front.
BUILDERS[6] = function(ctx, color)
	part(ctx, "Grip", nil, Vector3.new(0.8, 2.2, 1.1), Vector3.new(0, 1.3, 1.6), CFrame.Angles(math.rad(-12), 0, 0), DARK)
	part(ctx, "Trigger", nil, Vector3.new(0.3, 0.9, 0.35), Vector3.new(0, 1.7, 0.9), nil, DARK)
	part(ctx, "TriggerGuard", nil, Vector3.new(0.25, 0.25, 1.2), Vector3.new(0, 1.15, 0.8), nil, DARK)
	part(ctx, "Body", nil, Vector3.new(1.2, 1.2, 2.6), Vector3.new(0, 2.7, 0.9), nil, WHITE)
	part(ctx, "Barrel", Enum.PartType.Cylinder, Vector3.new(2.6, 1.1, 1.1), Vector3.new(0, 2.7, -1.0), ALONG_Z, WHITE)
	part(ctx, "Band", Enum.PartType.Cylinder, Vector3.new(0.35, 1.25, 1.25), Vector3.new(0, 2.7, -0.4), ALONG_Z, color)
	part(ctx, "Bell", Enum.PartType.Cylinder, Vector3.new(0.9, 2.1, 2.1), Vector3.new(0, 2.7, -2.6), ALONG_Z, WHITE)
	part(ctx, "BellRim", Enum.PartType.Cylinder, Vector3.new(0.25, 2.3, 2.3), Vector3.new(0, 2.7, -3.1), ALONG_Z, color)
	-- The soap bottle screws on underneath the front.
	part(ctx, "BottleNeck", Enum.PartType.Cylinder, Vector3.new(0.6, 0.7, 0.7), Vector3.new(0, 1.9, -0.9), nil, WHITE)
	part(ctx, "Bottle", Enum.PartType.Cylinder, Vector3.new(1.7, 1.8, 1.8), Vector3.new(0, 0.85, -0.9), UPRIGHT, color, Enum.Material.Glass, 0.3)
	part(ctx, "Soap", Enum.PartType.Cylinder, Vector3.new(1.0, 1.6, 1.6), Vector3.new(0, 0.55, -0.9), UPRIGHT, Color3.fromRGB(255, 150, 220), nil, 0.15)
	for _, f in { { Vector3.new(0, 2.7, -3.6), 1.5 }, { Vector3.new(0.7, 3.3, -4.0), 1.0 }, { Vector3.new(-0.6, 3.2, -3.9), 0.9 }, { Vector3.new(0.2, 2.1, -3.9), 0.8 }, { Vector3.new(-0.3, 3.8, -4.3), 0.6 } } do
		part(ctx, "Foam", Enum.PartType.Ball, Vector3.new(f[2], f[2], f[2]), f[1], nil, WHITE)
	end
end

function ToolModels.Build(toolIndex: number, scale: number?): Model
	local model = Instance.new("Model")
	model.Name = "Tool_" .. tostring(toolIndex)
	local ctx: Ctx = { Model = model, Scale = scale or 1 }
	local grip = part(ctx, "Grip", nil, Vector3.new(0.2, 0.2, 0.2) / ctx.Scale, Vector3.zero, nil, WHITE)
	grip.Transparency = 1
	model.PrimaryPart = grip
	local builder = BUILDERS[toolIndex]
	if builder then
		builder(ctx, COLORS[toolIndex] or WHITE)
	end
	return model
end

-- Grip placement relative to an R15 RightHand (R6 Right Arm is handled by the caller's offset).
-- The tool sits just in front of the hand, business end pointing forward.
function ToolModels.HoldOffset(toolIndex: number): CFrame
	local lift = if toolIndex == 5 then -1.6 else -0.9
	return CFrame.new(0, lift, -0.6)
end

return ToolModels
