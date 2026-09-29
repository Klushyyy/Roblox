-- Bubbles: pooled, client-only 3D soap bubbles. Every bubble is an anchored ForceField sphere (the
-- shimmering, see-through film with a bright rim) plus a tiny glowing glint that always sits on
-- the camera-facing, upper-left side, like a real reflection.
--
-- A bubble pops in (grows from nothing), drifts upward with a gentle wobble, slows with drag, and
-- pops (a quick swell and vanish) at the end of its life. Nothing is physics-simulated or
-- replicated: one RenderStepped loop moves the whole pool with BulkMoveTo, so hundreds of bubbles
-- cost almost nothing and never fall like rocks.
--
-- Bubbles.Emit(position, options?) with options:
--   Count (1), Spread (radius, 0.5), Velocity (Vector3, (0, 3, 0)), Jitter (random speed added, 1.5),
--   Size ({ min, max }, { 0.35, 0.9 }), Life ({ min, max }, { 1.6, 2.8 }), Rise (buoyancy, 2.5)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Bubbles = {}

local POOL_SIZE = 200
local GROW_TIME = 0.14
local POP_TIME = 0.1
local DRAG = 1.6

local TINTS = {
	Color3.fromRGB(165, 225, 255),
	Color3.fromRGB(255, 195, 238),
	Color3.fromRGB(200, 255, 232),
	Color3.fromRGB(226, 208, 255),
	Color3.fromRGB(255, 240, 190),
}

type Bubble = {
	Shell: Part,
	Glint: Part,
	Active: boolean,
	Pos: Vector3,
	Vel: Vector3,
	Age: number,
	Life: number,
	Size: number,
	Rise: number,
	Phase: number,
	Wobble: number,
	ShownSize: number,
	Poppable: boolean,
}

local pool: { Bubble } = {}
local cursor = 0
local folder: Folder? = nil
local initialized = false
local FAR = CFrame.new(0, -10000, 0)

local function newPart(name: string): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = Vector3.one * 0.2
	p.CFrame = FAR
	p.Transparency = 1
	return p
end

local function ensurePool()
	if folder and folder.Parent then
		return
	end
	local f = Instance.new("Folder")
	f.Name = "ClientBubbles"
	f.Parent = workspace
	folder = f
	table.clear(pool)
	for i = 1, POOL_SIZE do
		local shell = newPart("Bubble")
		shell.Material = Enum.Material.ForceField
		local glint = newPart("Glint")
		glint.Material = Enum.Material.Neon
		glint.Color = Color3.new(1, 1, 1)
		shell.Parent = f
		glint.Parent = f
		pool[i] = {
			Shell = shell,
			Glint = glint,
			Active = false,
			Poppable = false,
			Pos = Vector3.zero,
			Vel = Vector3.zero,
			Age = 0,
			Life = 1,
			Size = 1,
			Rise = 2.5,
			Phase = 0,
			Wobble = 0,
			ShownSize = 0,
		}
	end
end

local function hide(b: Bubble)
	b.Active = false
	b.Shell.Transparency = 1
	b.Glint.Transparency = 1
	b.Shell.CFrame = FAR
	b.Glint.CFrame = FAR
end

local function range(r: { number }?, default: { number }): number
	local t = r or default
	return t[1] + math.random() * (t[2] - t[1])
end

function Bubbles.Emit(position: Vector3, options: { [string]: any }?)
	ensurePool()
	local o = options or {}
	local count = math.clamp(math.floor(tonumber(o.Count) or 1), 1, 40)
	local spread = tonumber(o.Spread) or 0.5
	local velocity: Vector3 = if typeof(o.Velocity) == "Vector3" then o.Velocity else Vector3.new(0, 3, 0)
	local jitter = tonumber(o.Jitter) or 1.5
	for _ = 1, count do
		cursor = cursor % POOL_SIZE + 1
		local b = pool[cursor] -- the oldest slot gets recycled when the pool is full
		local offset = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 2 * spread
		b.Active = true
		b.Pos = position + offset
		b.Vel = velocity + Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 2 * jitter
		b.Age = 0
		b.Life = range(o.Life, { 1.6, 2.8 })
		b.Size = range(o.Size, { 0.35, 0.9 })
		b.Rise = tonumber(o.Rise) or 2.5
		b.Phase = math.random() * math.pi * 2
		b.Wobble = 0.25 + math.random() * 0.35
		b.ShownSize = -1
		b.Poppable = o.Poppable == true -- pops early when your character touches it
		b.Shell.Color = TINTS[math.random(1, #TINTS)]
		b.Shell.Transparency = 0
		b.Glint.Transparency = 0.15
	end
end

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}

local function step(dt: number)
	if not folder then
		return
	end
	local camera = workspace.CurrentCamera
	local camCF = if camera then camera.CFrame else CFrame.identity
	table.clear(moveParts)
	table.clear(moveCFrames)
	local character = Players.LocalPlayer and Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local rootPos = if root and root:IsA("BasePart") then root.Position else nil
	for _, b in pool do
		if not b.Active then
			continue
		end
		b.Age += dt
		-- Touched by your character (anywhere from feet to head): pop now.
		if b.Poppable and rootPos and b.Age < b.Life then
			local d = b.Pos - rootPos
			if math.abs(d.Y) < 3.5 + b.Size / 2 and Vector2.new(d.X, d.Z).Magnitude < 1.6 + b.Size / 2 then
				b.Life = b.Age
				b.Poppable = false
			end
		end
		if b.Age >= b.Life + POP_TIME then
			hide(b)
			continue
		end
		-- Motion: drag, buoyancy, and a sideways wobble.
		b.Vel = b.Vel * math.max(0, 1 - DRAG * dt) + Vector3.new(0, b.Rise * dt, 0)
		b.Pos += b.Vel * dt
		local t = b.Age * 2.2 + b.Phase
		local pos = b.Pos + Vector3.new(math.sin(t) * b.Wobble, 0, math.cos(t * 0.8) * b.Wobble)

		-- Size: pop in, hold with a faint breathing wobble, then swell and vanish.
		local size
		if b.Age < GROW_TIME then
			size = b.Size * (b.Age / GROW_TIME)
		elseif b.Age > b.Life then
			local k = (b.Age - b.Life) / POP_TIME
			size = b.Size * (1 + 0.35 * k)
			b.Shell.Transparency = k
			b.Glint.Transparency = 0.15 + 0.85 * k
		else
			size = b.Size * (1 + 0.04 * math.sin(t * 3))
		end
		size = math.max(size, 0.05)
		if math.abs(size - b.ShownSize) > 0.01 then
			b.ShownSize = size
			b.Shell.Size = Vector3.one * size
			b.Glint.Size = Vector3.one * math.max(size * 0.2, 0.05)
		end
		-- Glint on the camera-facing, upper-left side of the film.
		local toCam = (camCF.Position - pos)
		toCam = if toCam.Magnitude > 1e-3 then toCam.Unit else Vector3.zAxis
		local glintPos = pos + (toCam * 0.3 + camCF.UpVector * 0.25 - camCF.RightVector * 0.22) * size
		table.insert(moveParts, b.Shell)
		table.insert(moveCFrames, CFrame.new(pos))
		table.insert(moveParts, b.Glint)
		table.insert(moveCFrames, CFrame.new(glintPos))
	end
	if #moveParts > 0 then
		workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

function Bubbles.Init()
	if initialized then
		return
	end
	initialized = true
	ensurePool()
	RunService.RenderStepped:Connect(function(dt)
		local ok, err = pcall(step, math.min(dt, 0.1))
		if not ok then
			warn("[Bubbles] " .. tostring(err))
		end
	end)
end

return Bubbles
