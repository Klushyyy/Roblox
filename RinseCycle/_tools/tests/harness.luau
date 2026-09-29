-- Runs the real Rinse Cycle builders outside Roblox with a small Instance stand-in, then dumps every
-- part to JSON so a Python renderer can draw it. Usage: lune run harness.luau <what> <out.json>
--   what = "arena1".."arena5" | "lobby"
local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ROOT = "/home/user/Roblox/RinseCycle"
local Vector3, Color3, Enum = roblox.Vector3, roblox.Color3, roblox.Enum
-- Lune's CFrame.lookAt faces the opposite way to Roblox's; wrap CFrame with a correct one.
local RCF = roblox.CFrame
local CFrame = setmetatable({
	lookAt = function(pos, target, up)
		up = up or Vector3.new(0, 1, 0)
		local look = (target - pos).Unit
		local right = look:Cross(up)
		if right.Magnitude < 1e-6 then
			right = look:Cross(Vector3.new(1, 0, 0))
		end
		right = right.Unit
		local up2 = right:Cross(look)
		return RCF.fromMatrix(pos, right, up2, -look)
	end,
}, { __index = RCF })

----------------------------------------------------------------------------------------------------
-- Random
----------------------------------------------------------------------------------------------------
local Random = {}
Random.__index = Random
function Random.new(seed)
	return setmetatable({ s = (seed or 12345) % 2147483647 + 1 }, Random)
end
function Random:_next()
	self.s = (self.s * 48271) % 2147483647
	return self.s / 2147483647
end
function Random:NextNumber(a, b)
	local r = self:_next()
	if a then
		return a + (b - a) * r
	end
	return r
end
function Random:NextInteger(a, b)
	return math.floor(a + (b - a + 1) * self:_next())
end

----------------------------------------------------------------------------------------------------
-- Instance stand-in
----------------------------------------------------------------------------------------------------
local PART_CLASSES = { Part = true, WedgePart = true, TrussPart = true, SpawnLocation = true, CornerWedgePart = true, PartOperation = true }
local Inst = {}
local instMeta = {}
local methods = {}

local function isA(self, class)
	local c = rawget(self, "_class")
	if c == class or class == "Instance" then
		return true
	end
	if class == "BasePart" then
		return PART_CLASSES[c] == true
	end
	if class == "GuiObject" then
		return c == "Frame" or c == "TextLabel" or c == "TextButton" or c == "ImageLabel"
	end
	if class == "Light" then
		return c == "PointLight" or c == "SurfaceLight" or c == "SpotLight"
	end
	if class == "Part" then
		return c == "Part" or c == "SpawnLocation"
	end
	return false
end

function Inst.new(class)
	local self = setmetatable({ _class = class, _props = {}, _children = {}, _attrs = {}, _tags = {} }, instMeta)
	local p = self._props
	p.Name = class
	if PART_CLASSES[class] then
		p.Size = Vector3.new(4, 1, 2)
		p.CFrame = CFrame.new()
		p.Color = Color3.fromRGB(163, 162, 165)
		p.Transparency = 0
		p.Shape = Enum.PartType.Block
		p.Material = Enum.Material.Plastic
		p.CanCollide = true
		p.CanQuery = true
		p.Anchored = false
	end
	return self
end

instMeta.__index = function(self, key)
	local m = methods[key]
	if m then
		return m
	end
	if key == "ClassName" then
		return rawget(self, "_class")
	end
	local p = rawget(self, "_props")
	if key == "Position" and p.CFrame and PART_CLASSES[rawget(self, "_class")] then
		return p.CFrame.Position
	end
	if key == "Rotation" and p.CFrame then
		return p.CFrame.Rotation
	end
	if key == "LookVector" and p.CFrame then
		return p.CFrame.LookVector
	end
	local v = p[key]
	if v ~= nil then
		return v
	end
	for _, c in rawget(self, "_children") do
		if c._props.Name == key then
			return c
		end
	end
	return nil
end
instMeta.__newindex = function(self, key, value)
	local p = rawget(self, "_props")
	if key == "Parent" then
		local old = p.Parent
		if old then
			local list = rawget(old, "_children")
			local i = table.find(list, self)
			if i then
				table.remove(list, i)
			end
		end
		p.Parent = value
		if value then
			table.insert(rawget(value, "_children"), self)
		end
		return
	end
	if key == "Position" and PART_CLASSES[rawget(self, "_class")] then
		p.CFrame = CFrame.new(value) * (p.CFrame and p.CFrame.Rotation or CFrame.new())
		return
	end
	if key == "Shape" and value == Enum.PartType.Ball then
		p.Shape = value
		return
	end
	p[key] = value
end
instMeta.__tostring = function(self)
	return self._props.Name
end

function methods.IsA(self, c)
	return isA(self, c)
end
function methods.GetChildren(self)
	return table.clone(self._children)
end
function methods.GetDescendants(self)
	local out = {}
	local function walk(n)
		for _, c in n._children do
			table.insert(out, c)
			walk(c)
		end
	end
	walk(self)
	return out
end
function methods.FindFirstChild(self, name)
	for _, c in self._children do
		if c._props.Name == name then
			return c
		end
	end
	return nil
end
methods.WaitForChild = methods.FindFirstChild
function methods.FindFirstChildOfClass(self, class)
	for _, c in self._children do
		if c._class == class then
			return c
		end
	end
	return nil
end
function methods.FindFirstChildWhichIsA(self, class)
	for _, c in self._children do
		if isA(c, class) then
			return c
		end
	end
	return nil
end
function methods.IsDescendantOf(self, other)
	local p = self._props.Parent
	while p do
		if p == other then
			return true
		end
		p = p._props.Parent
	end
	return false
end
function methods.SetAttribute(self, k, v)
	self._attrs[k] = v
end
function methods.GetAttribute(self, k)
	return self._attrs[k]
end
function methods.GetAttributeChangedSignal()
	return { Connect = function() return { Disconnect = function() end } end }
end
function methods.GetPropertyChangedSignal()
	return { Connect = function() return { Disconnect = function() end } end }
end
function methods.AddTag(self, t)
	self._tags[t] = true
end
function methods.Destroy(self)
	self.Parent = nil
end
function methods.ClearAllChildren(self)
	for _, c in table.clone(self._children) do
		c.Parent = nil
	end
end
function methods.Clone(self)
	local c = Inst.new(self._class)
	for k, v in self._props do
		if k ~= "Parent" then
			c._props[k] = v
		end
	end
	for k, v in self._attrs do
		c._attrs[k] = v
	end
	for _, ch in self._children do
		ch:Clone().Parent = c
	end
	return c
end
local function parts(self)
	local out = {}
	if isA(self, "BasePart") then
		table.insert(out, self)
	end
	for _, d in methods.GetDescendants(self) do
		if isA(d, "BasePart") then
			table.insert(out, d)
		end
	end
	return out
end
function methods.GetPivot(self)
	if isA(self, "BasePart") then
		return self._props.CFrame
	end
	local pp = self._props.PrimaryPart
	if pp then
		return pp._props.CFrame
	end
	local ps = parts(self)
	if #ps == 0 then
		return CFrame.new()
	end
	local sum = Vector3.zero
	for _, p in ps do
		sum += p._props.CFrame.Position
	end
	return CFrame.new(sum / #ps)
end
function methods.PivotTo(self, cf)
	local delta = cf * methods.GetPivot(self):Inverse()
	for _, p in parts(self) do
		p._props.CFrame = delta * p._props.CFrame
	end
end
function methods.ScaleTo(self, s)
	local pivot = methods.GetPivot(self)
	for _, p in parts(self) do
		local rel = pivot:ToObjectSpace(p._props.CFrame)
		p._props.CFrame = pivot * (CFrame.new(rel.Position * s) * rel.Rotation)
		p._props.Size = p._props.Size * s
	end
end
function methods.Play() end
function methods.Emit() end
function methods.Connect()
	return { Disconnect = function() end }
end

----------------------------------------------------------------------------------------------------
-- Raycasting against boxes, cylinders and balls (enough for DishFactory's dirt placement)
----------------------------------------------------------------------------------------------------
local function rayBox(o, d, half)
	local tmin, tmax, nAxis, nSign = -math.huge, math.huge, nil, 0
	for _, axis in { "X", "Y", "Z" } do
		local oo, dd, h = o[axis], d[axis], half[axis]
		if math.abs(dd) < 1e-9 then
			if oo < -h or oo > h then
				return nil
			end
		else
			local t1, t2 = (-h - oo) / dd, (h - oo) / dd
			local s = -1
			if t1 > t2 then
				t1, t2 = t2, t1
				s = 1
			end
			if t1 > tmin then
				tmin, nAxis, nSign = t1, axis, s
			end
			tmax = math.min(tmax, t2)
			if tmin > tmax then
				return nil
			end
		end
	end
	if tmin < 0 or not nAxis then
		return nil
	end
	local n = Vector3.new(nAxis == "X" and nSign or 0, nAxis == "Y" and nSign or 0, nAxis == "Z" and nSign or 0)
	return tmin, n
end

local function rayCylinder(o, d, size)
	-- Axis = local X, radius = min(Y, Z)/2, half length = X/2.
	local r = math.min(size.Y, size.Z) / 2
	local hx = size.X / 2
	local best, bn = nil, nil
	-- Side.
	local a = d.Y * d.Y + d.Z * d.Z
	local b = 2 * (o.Y * d.Y + o.Z * d.Z)
	local c = o.Y * o.Y + o.Z * o.Z - r * r
	local disc = b * b - 4 * a * c
	if a > 1e-12 and disc >= 0 then
		local t = (-b - math.sqrt(disc)) / (2 * a)
		if t >= 0 then
			local x = o.X + d.X * t
			if math.abs(x) <= hx then
				best = t
				local p = o + d * t
				bn = Vector3.new(0, p.Y, p.Z).Unit
			end
		end
	end
	-- Caps.
	for _, s in { -1, 1 } do
		if math.abs(d.X) > 1e-12 then
			local t = (s * hx - o.X) / d.X
			if t >= 0 and (not best or t < best) then
				local p = o + d * t
				if p.Y * p.Y + p.Z * p.Z <= r * r then
					best, bn = t, Vector3.new(s, 0, 0)
				end
			end
		end
	end
	return best, bn
end

local function raySphere(o, d, r)
	local b = 2 * o:Dot(d)
	local c = o:Dot(o) - r * r
	local a = d:Dot(d)
	local disc = b * b - 4 * a * c
	if disc < 0 then
		return nil
	end
	local t = (-b - math.sqrt(disc)) / (2 * a)
	if t < 0 then
		return nil
	end
	return t, (o + d * t).Unit
end

local function raycast(_, origin, direction, params)
	local include = params and params.FilterDescendantsInstances or {}
	local candidates = {}
	for _, root in include do
		for _, p in parts(root) do
			if p._props.CanQuery ~= false then
				table.insert(candidates, p)
			end
		end
	end
	local len = direction.Magnitude
	local dir = direction.Unit
	local bestT, bestN, bestP = nil, nil, nil
	for _, p in candidates do
		local cf = p._props.CFrame
		local lo = cf:PointToObjectSpace(origin)
		local ld = cf:VectorToObjectSpace(dir)
		local t, n
		local shape = p._props.Shape
		if p._class == "Part" and shape == Enum.PartType.Cylinder then
			t, n = rayCylinder(lo, ld, p._props.Size)
		elseif p._class == "Part" and shape == Enum.PartType.Ball then
			t, n = raySphere(lo, ld, math.min(p._props.Size.X, p._props.Size.Y, p._props.Size.Z) / 2)
		else
			t, n = rayBox(lo, ld, p._props.Size / 2)
		end
		if t and t <= len and (not bestT or t < bestT) then
			bestT, bestN, bestP = t, cf:VectorToWorldSpace(n), p
		end
	end
	if not bestT then
		return nil
	end
	return { Position = origin + dir * bestT, Normal = bestN, Instance = bestP, Distance = bestT }
end

----------------------------------------------------------------------------------------------------
-- Services and environment
----------------------------------------------------------------------------------------------------
local game = Inst.new("DataModel")
local workspace = Inst.new("Workspace")
workspace.Name = "Workspace"
workspace.Parent = game
rawset(workspace, "Raycast", raycast)
local terrainCalls = 0
local terrain = Inst.new("Terrain")
terrain.Name = "Terrain"
terrain.Parent = workspace
rawset(terrain, "FillBlock", function() terrainCalls += 1 end)
rawset(terrain, "FillBall", function() terrainCalls += 1 end)
rawset(terrain, "Clear", function() end)

local services = {
	Workspace = workspace,
	ReplicatedStorage = Inst.new("ReplicatedStorage"),
	ServerStorage = Inst.new("ServerStorage"),
	Lighting = Inst.new("Lighting"),
	CollectionService = { AddTag = function(_, inst, tag) inst:AddTag(tag) end },
	TweenService = {
		Create = function()
			return { Play = function() end, Completed = { Wait = function() coroutine.yield() end } }
		end,
	},
	Debris = { AddItem = function() end },
	GeometryService = {
		SubtractAsync = function()
			error("no CSG outside Roblox")
		end,
	},
	RunService = { IsStudio = function() return true end, BindToRenderStep = function(_, _, _, fn) _G.__renderStep = fn end },
	Players = { GetPlayers = function() return {} end },
}
for name, s in services do
	if type(s) == "table" and getmetatable(s) == instMeta then
		s.Name = name
		s.Parent = game
	end
end
rawset(game, "GetService", function(_, name)
	return services[name] or error("service " .. name)
end)

-- Module tokens: script.Parent:WaitForChild("X") -> module file.
local cache = {}
local loadModule
local function tokenFor(path)
	return setmetatable({ _path = path }, {
		__index = function(t, k)
			if k == "Parent" then
				return tokenFor(string.match(t._path, "^(.*)/[^/]+$"))
			elseif k == "WaitForChild" or k == "FindFirstChild" then
				return function(self, name)
					return tokenFor(self._path .. "/" .. name)
				end
			end
			return nil
		end,
	})
end
services.ReplicatedStorage.WaitForChild = nil
rawset(services.ReplicatedStorage, "WaitForChild", function(_, name)
	return tokenFor(ROOT .. "/ReplicatedStorage/" .. name)
end)

local function requireToken(token)
	if type(token) == "table" and token._path then
		return loadModule(token._path)
	end
	error("require of unknown thing")
end

local taskLib = {
	wait = function() end,
	spawn = function(fn, ...)
		local co = coroutine.create(fn)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			print("task error: " .. tostring(err))
		end
	end,
	defer = function() end,
	delay = function() end,
}

local InstanceLib = { new = Inst.new }

function loadModule(path)
	if cache[path] then
		return cache[path]
	end
	local src = fs.readFile(path .. ".luau")
	local env = setmetatable({
		game = game,
		workspace = workspace,
		script = tokenFor(path),
		require = requireToken,
		task = taskLib,
		Instance = InstanceLib,
		Random = Random,
		CFrame = CFrame,
		Vector3 = Vector3,
		Vector2 = roblox.Vector2,
		Color3 = Color3,
		Enum = Enum,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		ColorSequence = roblox.ColorSequence,
		TweenInfo = { new = function() return {} end },
		RaycastParams = { new = function() return { FilterDescendantsInstances = {} } end },
		OverlapParams = { new = function() return {} end },
		warn = function(...) print("WARN", ...) end,
		typeof = function(v)
			if type(v) == "table" and getmetatable(v) == instMeta then
				return "Instance"
			end
			return typeof(v)
		end,
	}, { __index = _G })
	local chunk = luau.load(src, { debugName = path, environment = env })
	local result = chunk()
	cache[path] = result
	return result
end

----------------------------------------------------------------------------------------------------
-- Build and dump
----------------------------------------------------------------------------------------------------
local what = process.args[1] or "arena1"
local out = process.args[2] or "parts.json"
local SVC = ROOT .. "/ServerScriptService/Server/Services/"

local rootInst
if string.sub(what, 1, 5) == "arena" then
	local level = tonumber(string.sub(what, 6)) or 1
	local DishFactory = loadModule(SVC .. "DishFactory")
	DishFactory.Init()
	local ArenaBuilder = loadModule(SVC .. "ArenaBuilder")
	ArenaBuilder.Init()
	-- Put the arena at the origin for easy cameras.
	ArenaBuilder.SlotOrigin = function()
		return CFrame.new()
	end
	local arena = ArenaBuilder.Build(1, level, { GrimeScale = 1, GoldenChance = 0.05 })
	rootInst = arena.Model
	print("arena parts", #parts(rootInst), "dirt", #arena.GrimeFolder:GetChildren(), "total", arena.TotalGrime)
elseif what == "npclineup" then
	local NPC = loadModule(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/LevelNPCs")
	rootInst = Inst.new("Model")
	local scene = NPC.Lineup(CFrame.new(0, 24, 0), rootInst)
	scene:Update(tonumber(process.env.T or "1"))
	local floor = Inst.new("Part")
	floor.Size = Vector3.new(2400, 2, 600)
	floor.CFrame = CFrame.new(0, -1, 0)
	floor.Color = Color3.fromRGB(200, 190, 175)
	floor.Parent = rootInst
elseif string.sub(what, 1, 7) == "npcscan" then
	-- npcscan<level>: the room once, then every NPC part every 0.25 s over the loop
	local level = tonumber(string.sub(what, 8))
	local DishFactory = loadModule(SVC .. "DishFactory")
	DishFactory.Init()
	local ArenaBuilder = loadModule(SVC .. "ArenaBuilder")
	ArenaBuilder.Init()
	ArenaBuilder.SlotOrigin = function()
		return CFrame.new()
	end
	local arena = ArenaBuilder.Build(1, level, { GrimeScale = 0.02, GoldenChance = 0.05 })
	local function dumpList(root)
		local l = {}
		for _, p in parts(root) do
			local pr = p._props
			local shape = if p._class == "Part" or p._class == "SpawnLocation" then pr.Shape.Name else p._class
			table.insert(l, { n = pr.Name, s = shape, sz = { pr.Size.X, pr.Size.Y, pr.Size.Z }, cf = { pr.CFrame:GetComponents() }, t = pr.Transparency or 0, cc = pr.CanCollide })
		end
		return l
	end
	local static = dumpList(arena.Model)
	local NPC = loadModule(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/LevelNPCs")
	local holder = Inst.new("Model")
	local scene = NPC.Build(level, CFrame.new(), holder)
	-- mark the room parts this client would hide (same rule as LevelNPCs.Init)
	local hideSet = {}
	for _, n in scene.Hide or {} do
		hideSet[n] = true
	end
	for _, e in static do
		if hideSet[e.n] then
			local pos = Vector3.new(e.cf[1], e.cf[2], -e.cf[3])
			e.hidden = if scene.HideWhere then scene.HideWhere(e.n, pos) else true
		end
	end
	local frames = {}
	local actors = {}
	for _, a in scene.Actors do
		table.insert(actors, a.Name)
	end
	local t = 0
	while t < scene.Period - 1e-6 do
		scene:Update(t)
		local l = {}
		for _, p in parts(holder) do
			local pr = p._props
			if (pr.Transparency or 0) < 0.95 then
				local m = p:FindFirstChildOfClass("SpecialMesh")
				table.insert(l, { n = pr.Name, s = if p._class == "Part" then pr.Shape.Name else p._class, sz = { pr.Size.X, pr.Size.Y, pr.Size.Z }, cf = { pr.CFrame:GetComponents() }, mt = m and m.MeshType and m.MeshType.Name or nil })
			end
		end
		table.insert(frames, { t = t, p = l })
		t += 0.25
	end
	fs.writeFile(out, serde.encode("json", { static = static, frames = frames, actors = actors, period = scene.Period, hide = scene.Hide or {} }))
	print("frames", #frames)
	return
elseif string.sub(what, 1, 3) == "npc" then
	-- npc<level>@<t>: the arena room plus that level's NPCs at loop time t
	local level, tt = string.match(what, "^npc(%d)@([%d%.]+)$")
	level = tonumber(level)
	local DishFactory = loadModule(SVC .. "DishFactory")
	DishFactory.Init()
	local ArenaBuilder = loadModule(SVC .. "ArenaBuilder")
	ArenaBuilder.Init()
	ArenaBuilder.SlotOrigin = function()
		return CFrame.new()
	end
	local arena = ArenaBuilder.Build(1, level, { GrimeScale = 0.05, GoldenChance = 0.05 })
	rootInst = arena.Model
	local NPC = loadModule(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/LevelNPCs")
	local scene = NPC.Build(level, CFrame.new(), rootInst)
	scene:Update(tonumber(tt))
elseif string.sub(what, 1, 7) == "cutscan" then
	-- cutscan<level>: every part of the cutscene every 0.1 s, for collision checks.
	local level = tonumber(string.sub(what, 8))
	local SceneMod = loadModule(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/CutsceneScene")
	local holder = Inst.new("Model")
	local scene = SceneMod.Build(level, CFrame.new(), holder)
	local frames = {}
	local t = 0
	while t <= SceneMod.Duration + 1e-6 do
		scene:Update(t)
		local list = {}
		for _, p in parts(holder) do
			local pr = p._props
			local shape = if p._class == "Part" then pr.Shape.Name else p._class
			table.insert(list, { n = pr.Name, s = shape, sz = { pr.Size.X, pr.Size.Y, pr.Size.Z }, cf = { pr.CFrame:GetComponents() }, t = pr.Transparency or 0 })
		end
		table.insert(frames, { t = t, p = list })
		t += 0.1
	end
	fs.writeFile(out, serde.encode("json", frames))
	print("frames", #frames)
	return
elseif string.sub(what, 1, 5) == "story" then
	-- story<level>@<t>: the level's story chapter, staged in its arena room with the room's own
	-- furniture (LevelNPCs in cutscene mode) and tiny players on the door; prints the camera.
	local level, tt = string.match(what, "^story(%d)@([%d%.]+)$")
	level = tonumber(level)
	local t = tonumber(tt)
	local DishFactory = loadModule(SVC .. "DishFactory")
	DishFactory.Init()
	local ArenaBuilder = loadModule(SVC .. "ArenaBuilder")
	ArenaBuilder.Init()
	ArenaBuilder.SlotOrigin = function()
		return CFrame.new()
	end
	local arena = ArenaBuilder.Build(1, level, { GrimeScale = 0.3, GoldenChance = 0.05 })
	rootInst = arena.Model
	local NPC = loadModule(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/LevelNPCs")
	local npcs = NPC.Build(level, CFrame.new(), rootInst)
	local Story = loadModule(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/Story")
	local ctx = Story.Build(level, CFrame.new(), rootInst)
	npcs.CutsceneMode = true
	local hideFurn = {}
	for _, n in ctx.HideFurn or {} do
		hideFurn[n] = true
	end
	npcs.CutsceneHide = hideFurn
	-- the room parts this client hides (LevelNPCs.Init's rule)
	local hideSet = {}
	for _, n in npcs.Hide or {} do
		hideSet[n] = true
	end
	for _, p in parts(arena.Model) do
		local pr = p._props
		if hideSet[pr.Name] then
			local pos = pr.CFrame.Position
			if not npcs.HideWhere or npcs.HideWhere(pr.Name, Vector3.new(pos.X, pos.Y, -pos.Z)) then
				p.Transparency = 1
			end
		end
	end
	npcs:Update(0)
	-- tiny players standing on the door
	for i, x in { -14, 0, 14, -7, 7 } do
		local z = if i <= 3 then 100 else 108
		for _, e in { { "Legs", Vector3.new(2, 2, 1), 1 }, { "Body", Vector3.new(2, 2, 1), 3 }, { "Head", Vector3.new(1.2, 1.2, 1.2), 4.6 } } do
			local d = Inst.new("Part")
			d.Name = "Player" .. e[1]
			d.Size = e[2]
			d.CFrame = CFrame.new(x, e[3], z)
			d.Color = if e[1] == "Head" then Color3.fromRGB(245, 205, 150) elseif e[1] == "Body" then Color3.fromRGB(60 + i * 30, 120, 220 - i * 25) else Color3.fromRGB(50, 60, 90)
			d.Parent = rootInst
		end
	end
	ctx:Update(t)
	local cf, fov = ctx:Camera(t)
	local p, l = cf.Position, cf.Position + cf.LookVector * 10
	print(string.format("CAM %.2f %.2f %.2f %.2f %.2f %.2f %.1f", p.X, p.Y, p.Z, l.X, l.Y, l.Z, fov))
	print("DUR", ctx.Duration, "BUBBLES", ctx.BubbleStart)
	local line = ctx:Line(t)
	if line then
		print("LINE", line.Who, line.Text)
	end
	if require("@lune/process").env.SHOTS then
		for _, sh in ctx.Shots do
			print(string.format("SHOT %.2f %.2f", sh.T0, sh.T1))
		end
	end
elseif string.sub(what, 1, 4) == "chap" then
	-- chap<level><chapter>@<t>: a story chapter at time t; prints the camera for render.py
	local level, ch, tt = string.match(what, "^chap(%d)(%d)@([%d%.]+)$")
	local Mod = loadModule(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/CutsceneChapters")
	rootInst = Inst.new("Model")
	local ctx = Mod.Build(tonumber(level), tonumber(ch), CFrame.new(), rootInst)
	ctx:Update(tonumber(tt))
	local cf, fov = ctx:Camera(tonumber(tt))
	local p, l = cf.Position, cf.Position + cf.LookVector * 10
	print(string.format("CAM %.2f %.2f %.2f %.2f %.2f %.2f %.1f", p.X, p.Y, p.Z, l.X, l.Y, l.Z, fov))
	print("DUR", ctx.Duration, "BUBBLES", ctx.BubbleStart)
	if require("@lune/process").env.SHOTS then
		for _, sh in ctx.Shots do
			print(string.format("SHOT %.2f %.2f", sh.T0, sh.T1))
		end
	end
elseif string.sub(what, 1, 3) == "cut" then
	-- cut<level>@<t>: the cutscene set at time t; prints the camera for render.py
	local level, tt = string.match(what, "^cut(%d)@([%d%.]+)$")
	local SceneMod = loadModule(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/CutsceneScene")
	rootInst = Inst.new("Model")
	local scene = SceneMod.Build(tonumber(level), CFrame.new(), rootInst)
	scene:Update(tonumber(tt))
	local cf, fov = scene:Camera(tonumber(tt))
	local p, l = cf.Position, cf.Position + cf.LookVector * 10
	print(string.format("CAM %.2f %.2f %.2f %.2f %.2f %.2f %.1f", p.X, p.Y, p.Z, l.X, l.Y, l.Z, fov))
elseif what == "pets" then
	local PetModels = loadModule(ROOT .. "/ReplicatedStorage/Shared/PetModels")
	local Cfg = loadModule(ROOT .. "/ReplicatedStorage/Shared/Config")
	rootInst = Inst.new("Model")
	local ids = {}
	for id in Cfg.Pets do
		if require("@lune/process").env.PET == nil or require("@lune/process").env.PET == id then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for i, id in ids do
		local m = PetModels.Build(id)
		local col, row = (i - 1) % 5, (i - 1) // 5
		m:PivotTo(CFrame.new(col * 5 - 10, 2, row * 5) * CFrame.Angles(0, math.rad(20), 0))
		m.Parent = rootInst
		print(i, id)
	end
elseif what == "held" then
	local ToolModels = loadModule(ROOT .. "/ReplicatedStorage/Shared/ToolModels")
	rootInst = Inst.new("Model")
	local m = ToolModels.Build(4, 1, true)
	m:PivotTo(CFrame.new(0, 3, 0) * CFrame.Angles(0, math.rad(-60), 0))
	m.Parent = rootInst
elseif what == "water1" or what == "water2" then
	-- The held hose (3) or washer (4) aimed down at a plate, with WaterFX's water drawn.
	local ToolModels = loadModule(ROOT .. "/ReplicatedStorage/Shared/ToolModels")
	local WaterFX = loadModule(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/WaterFX")
	rootInst = Inst.new("Model")
	local idx = if what == "water1" then 3 else 4
	local m = ToolModels.Build(idx, 0.42, true)
	m:PivotTo(CFrame.new(0.8, 4, 0) * CFrame.Angles(math.rad(-25), 0, 0))
	m.Parent = rootInst
	local muzzle = m:FindFirstChild("Muzzle", true)
	local plate = Inst.new("Part")
	plate.Shape = Enum.PartType.Cylinder
	plate.Size = Vector3.new(0.2, 9, 9)
	plate.CFrame = CFrame.new(0, 0, -12) * CFrame.Angles(0, 0, math.rad(90))
	plate.Color = Color3.fromRGB(240, 240, 235)
	plate.Parent = rootInst
	WaterFX.Init()
	local target = Vector3.new(0, 0.1, -12)
	if idx == 3 then
		WaterFX.Spray(muzzle, target, Vector3.yAxis, 3)
	else
		local vertical = process.env.VERT == "1"
		local dir = if vertical then Vector3.zAxis else Vector3.xAxis
		WaterFX.Fan(muzzle, target - dir * 3, target + dir * 3, Vector3.yAxis)
	end
	_G.__renderStep()
	workspace:FindFirstChild("WaterFX").Parent = rootInst
	print("muzzle", muzzle.Position)
elseif what == "tools" then
	local ToolModels = loadModule(ROOT .. "/ReplicatedStorage/Shared/ToolModels")
	rootInst = Inst.new("Model")
	for i = 2, 6 do
		local m = ToolModels.Build(i, 1)
		m:PivotTo(CFrame.new((i - 4) * 7, 0, 0) * CFrame.Angles(0, math.rad(-35), 0))
		m.Parent = rootInst
	end
	local floor = Inst.new("Part")
	floor.Size = Vector3.new(50, 0.2, 14)
	floor.CFrame = CFrame.new(0, -0.1, 0)
	floor.Color = Color3.fromRGB(235, 230, 220)
	floor.Parent = rootInst
else
	local LobbyBuilder = loadModule(SVC .. "LobbyBuilder")
	LobbyBuilder.Build()
	rootInst = workspace:FindFirstChild("Lobby")
	print("lobby parts", #parts(rootInst), "terrain calls", terrainCalls)
end

local list = {}
for _, p in parts(rootInst) do
	local pr = p._props
	local cf = pr.CFrame
	local shape = if p._class == "Part" or p._class == "SpawnLocation" then pr.Shape.Name else p._class
	local c = pr.Color
	-- Effective transparency: a part is "hidden" if it or an ancestor model says so (not modelled).
	table.insert(list, {
		n = pr.Name,
		s = shape,
		sz = { pr.Size.X, pr.Size.Y, pr.Size.Z },
		cf = { cf:GetComponents() },
		c = { c.R, c.G, c.B },
		t = pr.Transparency or 0,
		m = pr.Material and pr.Material.Name or "Plastic",
		mesh = (p:FindFirstChildOfClass("SpecialMesh") ~= nil),
		cc = pr.CanCollide,
		mt = (function()
			local m = p:FindFirstChildOfClass("SpecialMesh")
			return m and m.MeshType and m.MeshType.Name or nil
		end)(),
	})
end
-- Face decals: two eyes and a smile, so renders show which way heads face.
for _, p in parts(rootInst) do
	local face = p:FindFirstChild("face")
	if face then
		local pr = p._props
		local k = pr.Size.Y
		for _, e in { { -0.2, 0.12, 0.09, 0.2 }, { 0.2, 0.12, 0.09, 0.2 }, { 0, -0.2, 0.34, 0.06 } } do
			local cf = pr.CFrame * CFrame.new(e[1] * k, e[2] * k, -0.64 * k)
			table.insert(list, { n = "Eye", s = "Block", sz = { e[3] * k, e[4] * k, 0.02 * k }, cf = { cf:GetComponents() }, c = { 0.1, 0.1, 0.12 }, t = 0, m = "Plastic" })
		end
	end
end
fs.writeFile(out, serde.encode("json", list))
print("wrote", #list, "parts to", out)
