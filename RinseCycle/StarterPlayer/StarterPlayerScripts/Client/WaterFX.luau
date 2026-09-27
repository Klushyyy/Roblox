--[[
	WaterFX - the water coming out of your own hose and pressure washer, built from real parts so
	it looks solid from every angle (a camera-facing Beam flattens to nothing when you look straight
	down it, which is exactly the first-person view).

	  * Hose (Spray Nozzle): 20 thin see-through streams fanning out from the nozzle over the
	    cleaning circle, around one thicker core stream. The streams wobble a little every frame
	    so the spray looks alive.
	  * Pressure Washer: a flat see-through sheet of water from the lance tip to the cleaning line
	    (across or up and down, whichever way the line is turned), with bright streaks running
	    through it and a hard jet down the middle.

	SprayController says what to draw each Heartbeat (Spray / Fan / Hide). The parts are placed in
	a RenderStep after HoldPose has aimed the tool, from the nozzle's position that frame, so the
	water never lags behind or comes loose from the tip.
]]

local RunService = game:GetService("RunService")

local WaterFX = {}

local STREAMS = 20
local FAN_STREAKS = 9
local GOLDEN_ANGLE = math.pi * (3 - math.sqrt(5))
local WATER = Color3.fromRGB(190, 230, 255)
local WATER_DEEP = Color3.fromRGB(120, 195, 255)

local initialized = false
local folder: Folder? = nil
local streams: { BasePart } = {}
local core: BasePart? = nil
local fanA: BasePart? = nil
local fanB: BasePart? = nil
local fanStreaks: { BasePart } = {}
local jet: BasePart? = nil

-- What to draw: nil (nothing), "Spray" or "Fan", plus where.
local mode: string? = nil
local muzzle: BasePart? = nil
local target = Vector3.zero
local normal = Vector3.yAxis
local radius = 1
local lineA = Vector3.zero
local lineB = Vector3.zero

local function newPart(name: string, shape: Enum.PartType?, color: Color3, transparency: number): BasePart
	local p: BasePart
	if shape == nil then
		p = Instance.new("WedgePart")
	else
		local part = Instance.new("Part")
		part.Shape = shape
		p = part
	end
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = 1
	p:SetAttribute("Look", transparency)
	p.Size = Vector3.new(1, 0.1, 0.1)
	p.Parent = folder
	return p
end

local function build()
	if folder and folder.Parent then
		return
	end
	local f = Instance.new("Folder")
	f.Name = "WaterFX"
	f.Parent = workspace
	folder = f
	table.clear(streams)
	table.clear(fanStreaks)
	for i = 1, STREAMS do
		streams[i] = newPart("HoseStream", Enum.PartType.Cylinder, if i % 3 == 0 then WATER_DEEP else WATER, 0.45)
	end
	core = newPart("HoseCore", Enum.PartType.Cylinder, WATER, 0.3)
	fanA = newPart("WasherSheet", nil, WATER_DEEP, 0.62)
	fanB = newPart("WasherSheet", nil, WATER_DEEP, 0.62)
	for i = 1, FAN_STREAKS do
		fanStreaks[i] = newPart("WasherStreak", Enum.PartType.Cylinder, WATER, 0.35)
	end
	jet = newPart("WasherJet", Enum.PartType.Cylinder, Color3.fromRGB(235, 248, 255), 0.15)
end

local function show(p: BasePart, visible: boolean)
	p.Transparency = if visible then p:GetAttribute("Look") :: number else 1
end

-- A cylinder from `a` to `b`, `width` thick.
local function stretch(p: BasePart, a: Vector3, b: Vector3, width: number)
	local d = b - a
	local len = d.Magnitude
	if len < 1e-3 then
		show(p, false)
		return
	end
	p.Size = Vector3.new(len, width, width)
	p.CFrame = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.rad(90), 0)
	show(p, true)
end

-- A flat triangle a-b-c made of two wedges (the usual right-angle split).
local function triangle(w1: BasePart, w2: BasePart, a: Vector3, b: Vector3, c: Vector3, thickness: number)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local cross = ac:Cross(ab)
	if cross.Magnitude < 1e-4 or bc.Magnitude < 1e-4 then
		show(w1, false)
		show(w2, false)
		return
	end
	local right = cross.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	w1.Size = Vector3.new(thickness, height, math.abs(ab:Dot(back)))
	w1.CFrame = CFrame.fromMatrix((a + b) / 2, right, up, back)
	w2.Size = Vector3.new(thickness, height, math.abs(ac:Dot(back)))
	w2.CFrame = CFrame.fromMatrix((a + c) / 2, -right, up, -back)
	show(w1, true)
	show(w2, true)
end

local function hideAll()
	for _, p in streams do
		show(p, false)
	end
	for _, p in fanStreaks do
		show(p, false)
	end
	for _, p in { core, fanA, fanB, jet } do
		if p then
			show(p, false)
		end
	end
end

local function render()
	if not folder then
		return
	end
	local m = muzzle
	if mode == nil or not m or not m.Parent then
		hideAll()
		return
	end
	local from = m.Position
	local t = os.clock()
	if mode == "Spray" then
		for _, p in fanStreaks do
			show(p, false)
		end
		for _, p in { fanA, fanB, jet } do
			if p then
				show(p, false)
			end
		end
		-- Spread the stream ends evenly over the cleaning circle (sunflower pattern), each
		-- wobbling on its own so the spray shimmers.
		local u = normal:Cross(if math.abs(normal.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis).Unit
		local v = normal:Cross(u).Unit
		for i, p in streams do
			local a = i * GOLDEN_ANGLE + math.sin(t * 7 + i * 1.7) * 0.12
			local r = radius * 0.9 * math.sqrt((i - 0.5) / STREAMS) * (1 + 0.08 * math.sin(t * 11 + i))
			local tip = target + (u * math.cos(a) + v * math.sin(a)) * r + normal * 0.05
			stretch(p, from, tip, 0.08 + 0.03 * (0.5 + 0.5 * math.sin(t * 13 + i * 2.3)))
		end
		if core then
			stretch(core, from, target + normal * 0.05, 0.2)
		end
	else
		for _, p in streams do
			show(p, false)
		end
		if core then
			show(core, false)
		end
		if fanA and fanB then
			triangle(fanA, fanB, from, lineA, lineB, 0.03)
		end
		for i, p in fanStreaks do
			local k = (i - 1) / (FAN_STREAKS - 1) + math.sin(t * 9 + i * 1.3) * 0.025
			stretch(p, from, lineA:Lerp(lineB, math.clamp(k, 0, 1)) + normal * 0.04, 0.045)
		end
		if jet then
			stretch(jet, from, lineA:Lerp(lineB, 0.5) + normal * 0.04, 0.1 + 0.02 * math.sin(t * 20))
		end
	end
end

-- The hose: from `nozzle` over the circle of `size` radius at `at` (surface `facing`).
function WaterFX.Spray(nozzle: BasePart, at: Vector3, facing: Vector3, size: number)
	mode = "Spray"
	muzzle = nozzle
	target = at
	normal = facing
	radius = size
end

-- The pressure washer: a sheet from `nozzle` to the line a-b on a surface facing `facing`.
function WaterFX.Fan(nozzle: BasePart, a: Vector3, b: Vector3, facing: Vector3)
	mode = "Fan"
	muzzle = nozzle
	lineA = a
	lineB = b
	normal = facing
end

function WaterFX.Hide()
	mode = nil
end

function WaterFX.Init()
	if initialized then
		return
	end
	initialized = true
	build()
	-- After the camera (Camera) and HoldPose's tool aim (Camera + 1).
	RunService:BindToRenderStep("RinseCycleWater", Enum.RenderPriority.Camera.Value + 2, function()
		build()
		render()
	end)
end

return WaterFX
