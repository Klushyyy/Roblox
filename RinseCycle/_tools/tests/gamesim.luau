-- Runs AdminServer then AdminClient against a permissive Roblox stand-in, the way a Studio playtest
-- of an unpublished place would (DataStores throw), and reports whether the panel gets built.
-- Usage: lune run adminsim.luau [username] [userId] [studio=1|0]
local roblox = require("@lune/roblox")
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local serde = require("@lune/serde")

local ROOT = "/home/user/Roblox/RinseCycle"
local USERNAME = process.args[1] or "EnderBuilda"
local USERID = tonumber(process.args[2] or "2297538363")
local STUDIO = (process.args[3] or "1") == "1"

local Vector3, Vector2, Color3, Enum = roblox.Vector3, roblox.Vector2, roblox.Color3, roblox.Enum
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
local UDim, UDim2 = roblox.UDim, roblox.UDim2

local log = {}
local function out(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	local line = table.concat(parts, " ")
	table.insert(log, line)
	print(line)
end

----------------------------------------------------------------------------------------------------
-- Signals
local Signal = {}
Signal.__index = Signal
local function newSignal()
	return setmetatable({ handlers = {} }, Signal)
end
function Signal:Connect(fn)
	local side = _G.__side
	local inner = fn
	fn = function(...)
		local prev = _G.__side
		_G.__side = side
		inner(...)
		_G.__side = prev
	end
	table.insert(self.handlers, fn)
	local handlers = self.handlers
	local conn = { Connected = true }
	function conn.Disconnect()
		conn.Connected = false
		local i = table.find(handlers, fn)
		if i then
			table.remove(handlers, i)
		end
	end
	return conn
end
function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn.Disconnect()
		fn(...)
	end)
	return conn
end
function Signal:Fire(...)
	local waiting = self.waiting
	if waiting then
		self.waiting = nil
		for _, co in waiting do
			local prev = _G.__side
			_G.__side = _G.__coSide[co] or prev
			local ok, err = coroutine.resume(co, ...)
			_G.__side = prev
			if not ok then
				out("!! ERROR in waiter: " .. tostring(err) .. "\n" .. debug.traceback(co))
			end
		end
	end
	for _, fn in table.clone(self.handlers) do
		local co = coroutine.create(fn)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			out("!! ERROR in handler: " .. tostring(err) .. "\n" .. debug.traceback(co))
		end
	end
end
function Signal:Wait()
	self.waiting = self.waiting or {}
	table.insert(self.waiting, coroutine.running())
	_G.__coSide[coroutine.running()] = _G.__side
	return coroutine.yield()
end

----------------------------------------------------------------------------------------------------
-- Instances
local EVENTS = {
	Changed = true, ChildAdded = true, ChildRemoved = true, DescendantAdded = true, DescendantRemoving = true,
	AncestryChanged = true, Destroying = true,
	MouseButton1Click = true, MouseButton1Down = true, MouseButton1Up = true, MouseButton2Click = true,
	MouseEnter = true, MouseLeave = true, MouseMoved = true, MouseWheelForward = true, MouseWheelBackward = true,
	Activated = true, FocusLost = true, Focused = true, InputBegan = true, InputEnded = true, InputChanged = true,
	OnServerEvent = true, OnClientEvent = true, Event = true, Heartbeat = true, RenderStepped = true,
	Stepped = true, PreSimulation = true, PostSimulation = true, PreRender = true,
	PlayerAdded = true, PlayerRemoving = true, CharacterAdded = true, CharacterRemoving = true, CharacterAppearanceLoaded = true,
	Died = true, Touched = true, TouchEnded = true, Completed = true, StateChanged = true, Running = true,
	HealthChanged = true, Chatted = true, MessageReceived = true, SendingMessage = true, TextChanged = true,
	PromptGamePassPurchaseFinished = true, PromptProductPurchaseFinished = true, JumpRequest = true, TeleportInitFailed = true,
	TouchStarted = true, TouchTap = true, LastInputTypeChanged = true, WindowFocused = true, WindowFocusReleased = true,
	MouseHoverEnter = true, MouseHoverLeave = true, Triggered = true, TriggerEnded = true, PromptShown = true, PromptHidden = true, Seated = true, Loaded = true, Ended = true, Played = true, Stopped = true, GamepadConnected = true, GamepadDisconnected = true, MenuOpened = true, MenuClosed = true, TouchSwipe = true, MouseClick = true, SelectionGained = true, SelectionLost = true, Destroying = true, MouseButton1Down = true, RightMouseClick = true, Triggered = true, PromptTriggered = true, OnInvoke = false, ViewportSize = false,
}
local DEFAULTS = {
	Scale = 1, Text = "", Visible = true, Enabled = true, Transparency = 0, BackgroundTransparency = 0, TextTransparency = 0,
	ImageTransparency = 0, Size = UDim2.new(), Position = UDim2.new(), Rotation = 0, ZIndex = 1, LayoutOrder = 0,
	AbsoluteSize = Vector2.new(400, 300), AbsolutePosition = Vector2.new(10, 10), TextBounds = Vector2.new(120, 20),
	AbsoluteContentSize = Vector2.new(300, 500), CanvasSize = UDim2.new(), CanvasPosition = Vector2.new(0, 0),
	AbsoluteWindowSize = Vector2.new(300, 300), ViewportSize = Vector2.new(1280, 720), Health = 100, MaxHealth = 100,
	WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2, UseJumpPower = false, Anchored = false, CanCollide = true,
	CFrame = CFrame.new(), Value = nil, TextColor3 = Color3.new(1, 1, 1), BackgroundColor3 = Color3.new(0, 0, 0),
	Color = Color3.new(1, 1, 1), AutoRotate = true, PlatformStand = false, Sit = false, FieldOfView = 70,
	CameraType = Enum.CameraType.Custom, DisplayName = "", Brightness = 1, Selectable = true, Active = true,
	TouchEnabled = false, KeyboardEnabled = true, GamepadEnabled = false, MouseEnabled = true, CursorPosition = 0,
	TextFits = true, MouseBehavior = Enum.MouseBehavior.Default, Style = nil, PrimaryPart = nil,
}

local Inst = {}
local InstMT = {}
local function isInst(v)
	return type(v) == "table" and getmetatable(v) == InstMT
end

local function newInstance(className, name)
	local self = setmetatable({}, InstMT)
	rawset(self, "__p", { ClassName = className, Name = name or className, Parent = nil })
	rawset(self, "__children", {})
	rawset(self, "__attrs", {})
	rawset(self, "__signals", {})
	if className == "Part" or className == "MeshPart" or className == "WedgePart" or className == "SpawnLocation" or className == "TrussPart" or className == "Seat" or className == "UnionOperation" or className == "CornerWedgePart" then
		local p = rawget(self, "__p")
		p.CFrame = CFrame.new()
		p.Position = Vector3.zero
		p.Size = Vector3.new(4, 1, 2)
		p.Orientation = Vector3.zero
		p.AssemblyLinearVelocity = Vector3.zero
		p.Velocity = Vector3.zero
		p.Anchored = false
	end
	return self
end

local function getSignal(self, key)
	local sigs = rawget(self, "__signals")
	if not sigs[key] then
		sigs[key] = newSignal()
	end
	return sigs[key]
end

local methods = {}
function methods:GetChildren()
	return table.clone(rawget(self, "__children"))
end
function methods:GetDescendants()
	local outList = {}
	local function walk(i)
		for _, c in rawget(i, "__children") do
			table.insert(outList, c)
			walk(c)
		end
	end
	walk(self)
	return outList
end
function methods:FindFirstChild(name, recursive)
	for _, c in rawget(self, "__children") do
		if rawget(c, "__p").Name == name then
			return c
		end
	end
	if recursive then
		for _, c in rawget(self, "__children") do
			local f = methods.FindFirstChild(c, name, true)
			if f then
				return f
			end
		end
	end
	return nil
end
function methods:WaitForChild(name, timeout)
	local c = methods.FindFirstChild(self, name)
	if c then
		return c
	end
	if timeout then
		out("   (WaitForChild " .. name .. " on " .. rawget(self, "__p").Name .. " timed out -> nil)")
		return nil
	end
	error("INFINITE YIELD: WaitForChild(\"" .. tostring(name) .. "\") on " .. rawget(self, "__p").Name)
end
function methods:FindFirstChildOfClass(cn)
	for _, c in rawget(self, "__children") do
		if rawget(c, "__p").ClassName == cn then
			return c
		end
	end
	return nil
end
function methods:FindFirstChildWhichIsA(cn)
	return methods.FindFirstChildOfClass(self, cn)
end
function methods:FindFirstAncestor(name)
	local p = rawget(self, "__p").Parent
	while p do
		if rawget(p, "__p").Name == name then
			return p
		end
		p = rawget(p, "__p").Parent
	end
	return nil
end
function methods:FindFirstAncestorOfClass(cn)
	local p = rawget(self, "__p").Parent
	while p do
		if rawget(p, "__p").ClassName == cn then
			return p
		end
		p = rawget(p, "__p").Parent
	end
	return nil
end
methods.FindFirstAncestorWhichIsA = methods.FindFirstAncestorOfClass
function methods:IsA(cn)
	local own = rawget(self, "__p").ClassName
	if own == cn or cn == "Instance" then
		return true
	end
	local gui = { GuiObject = { Frame = 1, TextLabel = 1, TextButton = 1, TextBox = 1, ImageLabel = 1, ImageButton = 1, ScrollingFrame = 1, CanvasGroup = 1 },
		GuiButton = { TextButton = 1, ImageButton = 1 }, BasePart = { Part = 1, MeshPart = 1, WedgePart = 1 },
		LuaSourceContainer = { Script = 1, LocalScript = 1, ModuleScript = 1 }, BaseScript = { Script = 1, LocalScript = 1 },
		LayerCollector = { ScreenGui = 1, BillboardGui = 1, SurfaceGui = 1 }, GuiBase2d = { ScreenGui = 1, Frame = 1, TextLabel = 1, TextButton = 1, TextBox = 1 } }
	return gui[cn] ~= nil and gui[cn][own] ~= nil
end
function methods:IsDescendantOf(anc)
	local p = rawget(self, "__p").Parent
	while p do
		if p == anc then
			return true
		end
		p = rawget(p, "__p").Parent
	end
	return false
end
function methods:IsAncestorOf(d)
	return methods.IsDescendantOf(d, self)
end
function methods:Destroy()
	self.Parent = nil
end
function methods:ClearAllChildren()
	for _, c in methods.GetChildren(self) do
		c.Parent = nil
	end
end
function methods:Clone()
	local c = newInstance(rawget(self, "__p").ClassName, rawget(self, "__p").Name)
	for k, v in rawget(self, "__p") do
		if k ~= "Parent" then
			rawget(c, "__p")[k] = v
		end
	end
	return c
end
_G.__tagged = {}
function methods:AddTag(a, b)
	local inst, t = if isInst(a) then a else self, if isInst(a) then b else a
	rawget(inst, "__attrs")["__tag_" .. t] = true
	_G.__tagged[t] = _G.__tagged[t] or {}
	_G.__tagged[t][inst] = true
end
function methods:RemoveTag(a, b)
	local inst, t = if isInst(a) then a else self, if isInst(a) then b else a
	rawget(inst, "__attrs")["__tag_" .. t] = nil
	if _G.__tagged[t] then
		_G.__tagged[t][inst] = nil
	end
end
function methods:HasTag(a, b)
	local inst, t = if isInst(a) then a else self, if isInst(a) then b else a
	return rawget(inst, "__attrs")["__tag_" .. t] == true
end
function methods:GetTagged(t)
	local list = {}
	for inst in _G.__tagged[t] or {} do
		table.insert(list, inst)
	end
	return list
end
function methods:GetInstanceAddedSignal(t)
	return getSignal(self, "added:" .. t)
end
function methods:GetInstanceRemovedSignal(t)
	return getSignal(self, "removed:" .. t)
end
function methods:GetAttribute(k)
	return rawget(self, "__attrs")[k]
end
function methods:SetAttribute(k, v)
	local attrs = rawget(self, "__attrs")
	local old = attrs[k]
	attrs[k] = v
	if old ~= v then
		getSignal(self, "attr:" .. k):Fire()
	end
end
function methods:GetAttributes()
	return table.clone(rawget(self, "__attrs"))
end
function methods:GetAttributeChangedSignal(k)
	return getSignal(self, "attr:" .. k)
end
function methods:GetPropertyChangedSignal(k)
	return getSignal(self, "prop:" .. k)
end
function methods:GetFullName()
	local names = {}
	local i = self
	while i do
		table.insert(names, 1, rawget(i, "__p").Name)
		i = rawget(i, "__p").Parent
	end
	return table.concat(names, ".")
end
_G.__clientLog = {}
function methods:FireServer(...)
	local args = table.pack(...)
	local side = _G.__side
	_G.__side = "server"
	getSignal(self, "OnServerEvent"):Fire(_G.__localPlayer, table.unpack(args, 1, args.n))
	_G.__side = side
end
function methods:FireClient(plr, ...)
	local name = rawget(self, "__p").Name
	table.insert(_G.__clientLog, { Remote = name, To = plr and plr.Name, Args = table.pack(...) })
	if plr == _G.__localPlayer then
		local args = table.pack(...)
		local side = _G.__side
		_G.__side = "client"
		getSignal(self, "OnClientEvent"):Fire(table.unpack(args, 1, args.n))
		_G.__side = side
	end
end
function methods:FireAllClients(...)
	local name = rawget(self, "__p").Name
	table.insert(_G.__clientLog, { Remote = name, To = "*", Args = table.pack(...) })
	getSignal(self, "OnClientEvent"):Fire(...)
end
function methods:Fire(...)
	getSignal(self, "Event"):Fire(...)
end
function methods:InvokeServer(...)
	local cb = rawget(self, "__p").OnServerInvoke
	if not cb then
		error("InvokeServer with no OnServerInvoke on " .. rawget(self, "__p").Name)
	end
	return cb(_G.__localPlayer, ...)
end
function methods:Invoke(...)
	local cb = rawget(self, "__p").OnInvoke
	return cb and cb(...)
end
function methods:TakeDamage() end
function methods:ChangeState() end
function methods:GetState()
	return Enum.HumanoidStateType.Running
end
function methods:SetStateEnabled() end
function methods:MoveTo() end
function methods:Move() end
function methods:LoadAnimation()
	return setmetatable({ Play = function() end, Stop = function() end, Stopped = newSignal() }, {})
end
local PARTCLASS = { Part = true, MeshPart = true, WedgePart = true, SpawnLocation = true, TrussPart = true, Seat = true, UnionOperation = true, CornerWedgePart = true }
function methods:GetPivot()
	local p = rawget(self, "__p")
	if PARTCLASS[p.ClassName] then
		return p.CFrame
	end
	if p.PrimaryPart then
		return p.PrimaryPart.CFrame
	end
	local sum, n = Vector3.zero, 0
	for _, d in methods.GetDescendants(self) do
		if PARTCLASS[rawget(d, "__p").ClassName] then
			sum += d.CFrame.Position
			n += 1
		end
	end
	return if n > 0 then CFrame.new(sum / n) else CFrame.new()
end
function methods:PivotTo(cf)
	local p = rawget(self, "__p")
	if PARTCLASS[p.ClassName] then
		self.CFrame = cf
		return
	end
	local current = methods.GetPivot(self)
	local delta = cf * current:Inverse()
	for _, d in methods.GetDescendants(self) do
		if PARTCLASS[rawget(d, "__p").ClassName] then
			d.CFrame = delta * d.CFrame
		end
	end
	p.__pivot = cf
end
function methods:SetPrimaryPartCFrame(cf)
	methods.PivotTo(self, cf)
end

-- Spatial queries (ray vs box / cylinder / ball, and overlap by bounding sphere)
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


local function queryParts(params)
	local list = {}
	local filter = params and params.FilterDescendantsInstances or {}
	local include = params and params.FilterType == Enum.RaycastFilterType.Include
	local excluded = {}
	local roots
	if include then
		roots = filter
	else
		roots = { _G.__workspace }
		for _, f in filter do
			excluded[f] = true
		end
	end
	local function walk(inst)
		if excluded[inst] then
			return
		end
		if PARTCLASS[rawget(inst, "__p").ClassName] then
			table.insert(list, inst)
		end
		for _, c in rawget(inst, "__children") do
			walk(c)
		end
	end
	for _, r in roots do
		if isInst(r) then
			walk(r)
		end
	end
	return list
end
function methods:Raycast(origin, direction, params)
	local len = direction.Magnitude
	if len < 1e-6 then
		return nil
	end
	local dir = direction.Unit
	local bestT, bestN, bestP = nil, nil, nil
	for _, p in queryParts(params) do
		if p.CanQuery ~= false then
			local cf = p.CFrame
			local lo = cf:PointToObjectSpace(origin)
			local ld = cf:VectorToObjectSpace(dir)
			local t, n
			local shape = p.Shape
			if p.ClassName == "Part" and shape == Enum.PartType.Cylinder then
				t, n = rayCylinder(lo, ld, p.Size)
			elseif p.ClassName == "Part" and shape == Enum.PartType.Ball then
				t, n = raySphere(lo, ld, math.min(p.Size.X, p.Size.Y, p.Size.Z) / 2)
			else
				t, n = rayBox(lo, ld, p.Size / 2)
			end
			if t and t <= len and (not bestT or t < bestT) then
				bestT, bestN, bestP = t, cf:VectorToWorldSpace(n), p
			end
		end
	end
	if not bestT then
		return nil
	end
	return { Position = origin + dir * bestT, Normal = bestN, Instance = bestP, Distance = bestT, Material = Enum.Material.Plastic }
end
function methods:GetPartBoundsInRadius(pos, radius, params)
	local found = {}
	for _, p in queryParts(params) do
		if p.CanQuery ~= false and (p.Position - pos).Magnitude <= radius + p.Size.Magnitude / 2 then
			table.insert(found, p)
		end
	end
	return found
end
function methods:GetPartBoundsInBox(cf, size, params)
	return methods.GetPartBoundsInRadius(self, cf.Position, size.Magnitude / 2, params)
end
function methods:GetPartsInPart(part, params)
	return methods.GetPartBoundsInRadius(self, part.Position, part.Size.Magnitude / 2, params)
end
function methods:GetServerTimeNow()
	return _G.__now
end
function methods:GetRealPhysicsFPS()
	return 60
end
function methods:ViewportPointToRay(x, y)
	local cf = self.CFrame or CFrame.new()
	return { Origin = cf.Position, Direction = cf.LookVector, Unit = { Origin = cf.Position, Direction = cf.LookVector } }
end
methods.ScreenPointToRay = methods.ViewportPointToRay
function methods:WorldToViewportPoint(p)
	return Vector3.new(640, 360, 10), true
end
methods.WorldToScreenPoint = methods.WorldToViewportPoint
function methods:Emit() end
function methods:Clear() end
function methods:AddItem(inst, t)
	_G.__taskLib.delay(t or 10, function()
		if inst then
			inst.Parent = nil
		end
	end)
end
function methods:BulkMoveTo(parts, cfs)
	for i, part in parts do
		part.CFrame = cfs[i]
	end
end
function methods:GetBoundingBox()
	return CFrame.new(), Vector3.new(4, 5, 2)
end
function methods:GetExtentsSize()
	return Vector3.new(4, 5, 2)
end
function methods:CaptureFocus() end
function methods:ReleaseFocus() end
function methods:IsFocused()
	return false
end
function methods:TweenPosition() end
function methods:TweenSize() end
function methods:TweenSizeAndPosition() end
function methods:GetPlayerFromCharacter()
	return nil
end
function methods:Kick(reason)
	out("   Kick: " .. tostring(reason))
end
function methods:GetRankInGroup()
	return 0
end
function methods:IsInGroup()
	return false
end
function methods:IsInGroupAsync()
	return false
end
function methods:GetRoleInGroup()
	return "Guest"
end
function methods:LoadCharacter() end
function methods:GetNetworkPing()
	return 0.05
end
function methods:SetNetworkOwner() end
function methods:ApplyDescription() end
function methods:GetAppliedDescription()
	return newInstance("HumanoidDescription")
end
function methods:GetMouse()
	return newInstance("PlayerMouse")
end
function methods:Play() end
function methods:Stop() end
function methods:Pause() end
function methods:Cancel() end
function methods:SendAsync() end
function methods:DisplaySystemMessage() end
function methods:AddUserAsync()
	return true, nil
end

InstMT.__index = function(self, key)
	local p = rawget(self, "__p")
	if p.ClassName == "Attachment" and (key == "WorldPosition" or key == "WorldCFrame") then
		local parentCf = (p.Parent and rawget(p.Parent, "__p").CFrame) or CFrame.new()
		local local_ = p.CFrame or CFrame.new(p.Position or Vector3.zero)
		local world = parentCf * local_
		return if key == "WorldPosition" then world.Position else world
	end
	local v = p[key]
	if v ~= nil then
		return v
	end
	if methods[key] then
		return methods[key]
	end
	if EVENTS[key] then
		return getSignal(self, key)
	end
	local child = methods.FindFirstChild(self, key)
	if child then
		return child
	end
	if DEFAULTS[key] ~= nil then
		return DEFAULTS[key]
	end
	return nil
end
InstMT.__newindex = function(self, key, value)
	local p = rawget(self, "__p")
	if p.ClassName == "Attachment" and key == "WorldCFrame" then
		local parentCf = (p.Parent and rawget(p.Parent, "__p").CFrame) or CFrame.new()
		p.CFrame = parentCf:Inverse() * value
		p.Position = p.CFrame.Position
		return
	end
	if key == "Parent" then
		local old = p.Parent
		if old then
			local kids = rawget(old, "__children")
			local idx = table.find(kids, self)
			if idx then
				table.remove(kids, idx)
			end
		end
		p.Parent = value
		if value then
			if not isInst(value) then
				error("Parent set to non-Instance: " .. tostring(value))
			end
			table.insert(rawget(value, "__children"), self)
			getSignal(value, "ChildAdded"):Fire(self)
		end
		return
	end
	p[key] = value
	if key == "CFrame" and typeof(value) == "CFrame" and p.Position ~= nil and typeof(p.Position) == "Vector3" then
		p.Position = value.Position
	elseif key == "Position" and typeof(value) == "Vector3" and typeof(p.CFrame) == "CFrame" then
		p.CFrame = CFrame.new(value) * p.CFrame.Rotation
	end
	local sigs = rawget(self, "__signals")
	if sigs["prop:" .. key] then
		sigs["prop:" .. key]:Fire()
	end
end
InstMT.__tostring = function(self)
	return rawget(self, "__p").Name
end

----------------------------------------------------------------------------------------------------
-- The DataModel
local game = newInstance("DataModel", "Game")
local services = {}
local function service(name)
	if not services[name] then
		local s = newInstance(name, name)
		s.Parent = game
		services[name] = s
	end
	return services[name]
end
local workspace = service("Workspace")
_G.__workspace = workspace
local camera = newInstance("Camera", "Camera")
camera.Parent = workspace
workspace.CurrentCamera = camera
rawget(game, "__p").Workspace = workspace

local Players = service("Players")
local RunService = service("RunService")
rawget(RunService, "__p").IsStudio = function()
	return STUDIO
end
rawget(RunService, "__p").IsServer = function()
	return _G.__side == "server"
end
rawget(RunService, "__p").IsClient = function()
	return _G.__side == "client"
end
rawget(RunService, "__p").IsRunning = function()
	return true
end
rawget(RunService, "__p").BindToRenderStep = function() end
rawget(RunService, "__p").UnbindFromRenderStep = function() end

local DataStoreService = service("DataStoreService")
rawget(DataStoreService, "__p").GetDataStore = function(_, name)
	if STUDIO then
		error("You must publish this place to the web to access DataStore.")
	end
	local data = {}
	return {
		GetAsync = function(_, k)
			return data[k]
		end,
		SetAsync = function(_, k, v)
			data[k] = v
		end,
		UpdateAsync = function(_, k, fn)
			data[k] = fn(data[k])
			return data[k]
		end,
		RemoveAsync = function(_, k)
			data[k] = nil
		end,
		ListKeysAsync = function()
			return { GetCurrentPage = function()
				return {}
			end, IsFinished = true, AdvanceToNextPageAsync = function() end }
		end,
	}
end

local TweenService = service("TweenService")
rawget(TweenService, "__p").Create = function(_, inst, info, props)
	local t = newInstance("Tween")
	local duration = (type(info) == "table" and tonumber(info[1])) or 0.25
	rawget(t, "__p").Play = function()
		_G.__taskLib.delay(duration, function()
			for k, v in props or {} do
				pcall(function()
					inst[k] = v
				end)
			end
			getSignal(t, "Completed"):Fire(Enum.PlaybackState.Completed)
		end)
	end
	return t
end
local UIS = service("UserInputService")
rawget(UIS, "__p").GetFocusedTextBox = function()
	return nil
end
rawget(UIS, "__p").GetLastInputType = function()
	return Enum.UserInputType.MouseMovement
end
rawget(UIS, "__p").GetConnectedGamepads = function()
	return {}
end
rawget(UIS, "__p").GetGamepadConnected = function()
	return false
end
rawget(UIS, "__p").GetNavigationGamepads = function()
	return {}
end
rawget(service("ContentProvider"), "__p").PreloadAsync = function() end
rawget(service("SoundService"), "__p").PlayLocalSound = function() end
rawget(service("BadgeService"), "__p").AwardBadge = function()
	return true
end
rawget(service("BadgeService"), "__p").UserHasBadgeAsync = function()
	return false
end
rawget(UIS, "__p").IsGamepadButtonDown = function()
	return false
end
rawget(UIS, "__p").IsKeyDown = function()
	return false
end
rawget(UIS, "__p").GetMouseLocation = function()
	return Vector2.new(0, 0)
end
local GuiService = service("GuiService")
rawget(GuiService, "__p").GetGuiInset = function()
	return Vector2.new(0, 58), Vector2.new(0, 0)
end
local StarterGui = service("StarterGui")
rawget(StarterGui, "__p").SetCore = function() end
rawget(StarterGui, "__p").GetCore = function()
	return nil
end
rawget(StarterGui, "__p").SetCoreGuiEnabled = function() end
rawget(StarterGui, "__p").GetCoreGuiEnabled = function()
	return true
end
local MarketplaceService = service("MarketplaceService")
rawget(MarketplaceService, "__p").UserOwnsGamePassAsync = function()
	return false
end
rawget(MarketplaceService, "__p").GetProductInfo = function()
	return { Name = "Pass", PriceInRobux = 99 }
end
rawget(MarketplaceService, "__p").PromptGamePassPurchase = function() end
local TextChatService = service("TextChatService")
local channels = newInstance("Folder", "TextChannels")
channels.Parent = TextChatService
local general = newInstance("TextChannel", "RBXGeneral")
general.Parent = channels
local chatBar = newInstance("ChatInputBarConfiguration", "ChatInputBarConfiguration")
chatBar.Enabled = true
chatBar.Parent = TextChatService
local ReplicatedStorage = service("ReplicatedStorage")
local ServerStorage = service("ServerStorage")
local ServerScriptService = service("ServerScriptService")
service("Lighting")

rawget(Players, "__p").GetPlayers = function()
	return methods.GetChildren(Players)
end
rawget(Players, "__p").GetPlayerByUserId = function(_, id)
	for _, p in methods.GetChildren(Players) do
		if p.UserId == id then
			return p
		end
	end
	return nil
end
rawget(Players, "__p").GetPlayerFromCharacter = function(_, ch)
	for _, p in methods.GetChildren(Players) do
		if p.Character == ch then
			return p
		end
	end
	return nil
end
rawget(Players, "__p").GetUserIdFromNameAsync = function(_, n)
	return 1
end
rawget(Players, "__p").GetNameFromUserIdAsync = function(_, id)
	return "User" .. id
end
rawget(Players, "__p").GetUserThumbnailAsync = function()
	return "rbxthumb://", true
end
rawget(Players, "__p").GetHumanoidDescriptionFromUserId = function()
	return newInstance("HumanoidDescription")
end
rawget(Players, "__p").BanAsync = function() end
rawget(Players, "__p").UnbanAsync = function() end

rawset(game, "GetService", nil)
rawget(game, "__p").GetService = function(_, name)
	return service(name)
end
rawget(game, "__p").FindService = function(_, name)
	return services[name]
end
rawget(game, "__p").BindToClose = function() end
rawget(game, "__p").PlaceId = 0
rawget(game, "__p").JobId = "studio"
rawget(game, "__p").GameId = 0
rawget(game, "__p").CreatorId = USERID
rawget(game, "__p").PrivateServerId = ""

-- The player and character.
_G.__profiles = {}
local player = newInstance("Player", USERNAME)
player.UserId = USERID
player.DisplayName = "Klushy"
player.AccountAge = 1000
player.MembershipType = Enum.MembershipType.None
local playerGui = newInstance("PlayerGui", "PlayerGui")
playerGui.Parent = player
local playerScripts = newInstance("PlayerScripts", "PlayerScripts")
playerScripts.Parent = player
local backpack = newInstance("Backpack", "Backpack")
backpack.Parent = player
local character = newInstance("Model", USERNAME)
local hum = newInstance("Humanoid", "Humanoid")
hum.Parent = character
local hrp = newInstance("Part", "HumanoidRootPart")
hrp.Parent = character
hrp.CFrame = CFrame.new(0, 5, 0)
hrp.Position = Vector3.new(0, 5, 0)
hrp.Size = Vector3.new(2, 2, 1)
local head = newInstance("Part", "Head")
head.Parent = character
local torso = newInstance("Part", "UpperTorso")
torso.Size = Vector3.new(2, 1.6, 1)
torso.CFrame = CFrame.new(0, 5.5, 0)
torso.Parent = character
character.PrimaryPart = hrp
character.Parent = workspace
player.Character = character
player.Parent = Players
-- A second player to aim commands at, with a character.
local victim = newInstance("Player", "Victim")
victim.UserId = 555
victim.DisplayName = "Victim"
local vgui = newInstance("PlayerGui", "PlayerGui")
vgui.Parent = victim
local vbackpack = newInstance("Backpack", "Backpack")
vbackpack.Parent = victim
local vchar = newInstance("Model", "Victim")
local vhum = newInstance("Humanoid", "Humanoid")
vhum.Parent = vchar
local vroot = newInstance("Part", "HumanoidRootPart")
vroot.CFrame = CFrame.new(10, 5, 0)
vroot.Position = Vector3.new(10, 5, 0)
vroot.Size = Vector3.new(2, 2, 1)
vroot.Parent = vchar
local vhead = newInstance("Part", "Head")
vhead.Parent = vchar
local vtorso = newInstance("Part", "UpperTorso")
vtorso.Size = Vector3.new(2, 1.6, 1)
vtorso.Parent = vchar
vchar.PrimaryPart = vroot
vchar.Parent = workspace
victim.Character = vchar
victim.Parent = Players
local vtool = newInstance("Tool", "Btools")
vtool.Parent = vbackpack
-- Chat sources (what Roblox makes per player per channel).
for _, plr in { player, victim } do
	local src = newInstance("TextSource", plr.Name)
	src.UserId = plr.UserId
	src.CanSend = true
	src.Parent = general
end
rawget(Players, "__p").LocalPlayer = nil
_G.__localPlayer = player

----------------------------------------------------------------------------------------------------
-- task / scheduler (virtual clock)
_G.__now = 1000
_G.__coSide = setmetatable({}, { __mode = "k" })
local sleepers = {}
local taskLib = {}
local function report(co, ok, err)
	if not ok then
		out("!! ERROR in task: " .. tostring(err) .. "\n" .. debug.traceback(co))
	end
end
function taskLib.spawn(fn, ...)
	local co = type(fn) == "thread" and fn or coroutine.create(fn)
	report(co, coroutine.resume(co, ...))
	return co
end
function taskLib.defer(fn, ...)
	local co = type(fn) == "thread" and fn or coroutine.create(fn)
	table.insert(sleepers, { co = co, wake = _G.__now, side = _G.__side, args = table.pack(...) })
	return co
end
function taskLib.delay(t, fn, ...)
	local co = type(fn) == "thread" and fn or coroutine.create(fn)
	table.insert(sleepers, { co = co, wake = _G.__now + (tonumber(t) or 0), side = _G.__side, args = table.pack(...) })
	return co
end
function taskLib.wait(t)
	if coroutine.running() == _G.__noYieldCo or not coroutine.isyieldable() then
		return 0
	end
	local wait = math.max(tonumber(t) or 0, 1 / 60)
	table.insert(sleepers, { co = coroutine.running(), wake = _G.__now + wait, side = _G.__side, args = table.pack(wait) })
	coroutine.yield()
	return wait
end
_G.__pump = function(seconds, frame)
	local stop = _G.__now + seconds
	while _G.__now < stop do
		_G.__now += 1 / 30
		if frame then
			frame(1 / 30)
		end
		local due = {}
		local keep = {}
		for _, s in sleepers do
			if s.wake <= _G.__now then
				table.insert(due, s)
			else
				table.insert(keep, s)
			end
		end
		sleepers = keep
		for _, s in due do
			if coroutine.status(s.co) == "suspended" then
				local prev = _G.__side
				_G.__side = s.side or prev
				report(s.co, coroutine.resume(s.co, table.unpack(s.args, 1, s.args.n)))
				_G.__side = prev
			end
		end
	end
end
_G.__taskLib = taskLib
function taskLib.cancel() end
function taskLib.synchronize() end
function taskLib.desynchronize() end

----------------------------------------------------------------------------------------------------
-- Globals
local function typeofMock(v)
	if isInst(v) then
		return "Instance"
	end
	if getmetatable(v) == Signal then
		return "RBXScriptSignal"
	end
	return typeof(v)
end

local function newInstanceGlobal(className, parent)
	local i = newInstance(className, className)
	if parent then
		i.Parent = parent
	end
	return i
end

local modulesCache = {}
local loadScript

local function makeEnv(scriptInst)
	local env = {
		game = game,
		workspace = workspace,
		Workspace = workspace,
		script = scriptInst,
		task = taskLib,
		wait = taskLib.wait,
		spawn = taskLib.spawn,
		delay = taskLib.delay,
		tick = function()
			return _G.__now
		end,
		time = function()
			return _G.__now
		end,
		os = setmetatable({ clock = function()
			return _G.__now
		end }, { __index = os }),
		Instance = { new = newInstanceGlobal },
		Vector3 = Vector3,
		Vector2 = Vector2,
		CFrame = CFrame,
		Color3 = Color3,
		UDim = UDim,
		UDim2 = UDim2,
		Enum = Enum,
		BrickColor = roblox.BrickColor,
		ColorSequence = {
			new = function(a, b)
				-- Lune's two-colour form repeats the first colour; build the keypoints instead.
				if typeof(a) == "Color3" and typeof(b) == "Color3" then
					return roblox.ColorSequence.new({ roblox.ColorSequenceKeypoint.new(0, a), roblox.ColorSequenceKeypoint.new(1, b) })
				end
				return roblox.ColorSequence.new(a, b)
			end,
		},
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		NumberRange = roblox.NumberRange,
		Rect = roblox.Rect,
		Font = roblox.Font,
		TweenInfo = { new = function(...)
			return { ... }
		end },
		RaycastParams = { new = function()
			local rp = { FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude, IgnoreWater = false, RespectCanCollide = false, CollisionGroup = "Default" }
			function rp:AddToFilter(x)
				if type(x) == "table" and not isInst(x) then
					for _, i in x do
						table.insert(self.FilterDescendantsInstances, i)
					end
				else
					table.insert(self.FilterDescendantsInstances, x)
				end
			end
			return rp
		end },
		OverlapParams = { new = function()
			local op = { FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude, MaxParts = 0, CollisionGroup = "Default", RespectCanCollide = false }
			function op:AddToFilter(x)
				table.insert(self.FilterDescendantsInstances, x)
			end
			return op
		end },
		PhysicalProperties = roblox.PhysicalProperties,
		Random = { new = function(seed)
			local r = {}
			function r:NextNumber(a, b)
				a = a or 0
				b = b or 1
				return a + math.random() * (b - a)
			end
			function r:NextInteger(a, b)
				return math.random(a, b)
			end
			return r
		end },
		DateTime = { now = function()
			return { UnixTimestamp = os.time(), UnixTimestampMillis = os.time() * 1000, FormatLocalTime = function()
				return "date"
			end, FormatUniversalTime = function()
				return "date"
			end, ToIsoDate = function()
				return "date"
			end }
		end, fromUnixTimestamp = function(t)
			return { UnixTimestamp = t, FormatLocalTime = function()
				return "date"
			end, FormatUniversalTime = function()
				return "date"
			end }
		end },
		typeof = typeofMock,
		print = function(...)
			out(...)
		end,
		warn = function(...)
			out("WARN", ...)
		end,
		error = error,
		pcall = pcall,
		xpcall = xpcall,
		select = select,
		type = type,
		tostring = tostring,
		tonumber = tonumber,
		pairs = pairs,
		ipairs = ipairs,
		next = next,
		unpack = table.unpack,
		rawget = rawget,
		rawset = rawset,
		rawequal = rawequal,
		rawlen = rawlen,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		assert = assert,
		math = math,
		string = string,
		table = table,
		coroutine = coroutine,
		utf8 = utf8,
		debug = debug,
		buffer = buffer,
		bit32 = bit32,
		_G = {},
		shared = {},
	}
	env.require = function(target)
		if isInst(target) then
			local path = rawget(target, "__p").__source
			if not path then
				-- A service module or other thing we stub out: accept any call.
				local stub
				local profiles = _G.__profiles
				stub = setmetatable({}, {
					__index = function(_, k)
						if k == "PassesChanged" or k == "ProfileLoaded" or k == "Changed" then
							return newSignal()
						end
						if k == "Get" then
							return function(plr)
								profiles[plr] = profiles[plr] or { Bubbles = 0, Gems = 0, Rebirths = 0, DailyLast = 0, DailyStreak = 0, Ranks = {}, Unlocked = { 1 }, Pets = {} }
								return profiles[plr]
							end
						end
						if k == "SetRank" then
							return function(plr, id)
								_G.__profiles[plr].Rank = id
								return true
							end
						end
						if k == "AddRank" then
							return function(plr, id)
								table.insert(_G.__profiles[plr].Ranks, id)
								return true
							end
						end
						if k == "AddCoins" or k == "GivePet" or k == "SetPass" or k == "WaitFor" then
							return function()
								return true
							end
						end
						if k == "DebugFinish" then
							return function()
								return 7
							end
						end
						return function(...)
							return nil
						end
					end,
				})
				return stub
			end
			if modulesCache[path] == nil then
				modulesCache[path] = loadScript(path, target)
			end
			return modulesCache[path]
		end
		error("require of non-instance " .. tostring(target))
	end
	return env
end

local sourceCache = {}
local function preload(dir)
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			preload(full)
		elseif entry:match("%.luau$") then
			sourceCache[full] = fs.readFile(full)
		end
	end
end
for _, d in { "ReplicatedStorage", "ServerScriptService", "StarterPlayer" } do
	preload(ROOT .. "/" .. d)
end
loadScript = function(path, scriptInst)
	local src = sourceCache[path] or error("not preloaded: " .. path)
	local bytecode = luau.compile(src)
	local fn = luau.load(bytecode, { debugName = path, environment = makeEnv(scriptInst) })
	return fn()
end

-- Mount the real Shared modules (Config + Remotes + whatever they require) under ReplicatedStorage.
local function mount(dir, parent)
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			local f = newInstance("Folder", entry)
			f.Parent = parent
			mount(full, f)
		elseif entry:match("%.luau$") and not entry:match("%.server%.luau$") and not entry:match("%.local%.luau$") then
			local m = newInstance("ModuleScript", (entry:gsub("%.luau$", "")))
			rawget(m, "__p").__source = full
			m.Parent = parent
		end
	end
end
local shared = newInstance("Folder", "Shared")
shared.Parent = ReplicatedStorage
mount(ROOT .. "/ReplicatedStorage/Shared", shared)
-- The real server services.
local serverFolder = newInstance("Folder", "Server")
serverFolder.Parent = ServerScriptService
local servicesFolder = newInstance("Folder", "Services")
servicesFolder.Parent = serverFolder
mount(ROOT .. "/ServerScriptService/Server/Services", servicesFolder)
local adminFolder = newInstance("Folder", "Admin")
adminFolder.Parent = ServerScriptService
local playerModule = newInstance("ModuleScript", "PlayerModule")
playerModule.Parent = playerScripts

----------------------------------------------------------------------------------------------------

-- Frame events each tick.
local function frame(dt)
	_G.__side = "server"
	getSignal(RunService, "Stepped"):Fire(_G.__now, dt)
	getSignal(RunService, "Heartbeat"):Fire(dt)
	_G.__side = "client"
	getSignal(RunService, "RenderStepped"):Fire(dt)
	for _, fn in _G.__renderSteps or {} do
		local ok, err = pcall(fn, dt)
		if not ok then
			out("!! ERROR in RenderStep: " .. tostring(err))
		end
	end
end
rawget(RunService, "__p").BindToRenderStep = function(_, name, _, fn)
	_G.__renderSteps = _G.__renderSteps or {}
	_G.__renderSteps[name] = fn
end

local function runScript(path, parent, name, side)
	local sc = newInstance(if side == "client" then "LocalScript" else "Script", name)
	sc.Parent = parent
	_G.__side = side
	local co = coroutine.create(function()
		loadScript(path, sc)
	end)
	_G.__coSide[co] = side
	if _G.__noYieldMain then
		_G.__noYieldCo = co
	end
	local ok, err = coroutine.resume(co)
	if not ok then
		out("!! " .. name .. " DIED: " .. tostring(err) .. "\n" .. debug.traceback(co))
	end
	if coroutine.status(co) == "suspended" then
		out("(" .. name .. " yielded at: " .. debug.traceback(co) .. ")")
	end
end

out("=== SERVER MAIN")
_G.__noYieldMain = true -- Lune can't pause Main inside its xpcall steps; Roblox can (they're just slow builds)
runScript(ROOT .. "/ServerScriptService/Server/Main.server.luau", serverFolder, "Main", "server")
_G.__noYieldMain = false
runScript(ROOT .. "/ServerScriptService/Admin/AdminServer.server.luau", adminFolder, "AdminServer", "server")
_G.__side = "server"
getSignal(Players, "PlayerAdded"):Fire(player)
getSignal(Players, "PlayerAdded"):Fire(victim)
_G.__pump(3, frame)

out("=== CLIENT MAIN")
rawget(Players, "__p").LocalPlayer = player
local clientFolder = newInstance("Folder", "Client")
clientFolder.Parent = playerScripts
mount(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client", clientFolder)
runScript(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/ClientMain.local.luau", clientFolder, "ClientMain", "client")
runScript(ROOT .. "/StarterPlayer/StarterPlayerScripts/AdminClient.local.luau", playerScripts, "AdminClient", "client")
_G.__pump(5, frame)
local names = {}
for _, g in methods.GetChildren(playerGui) do
	table.insert(names, g.Name)
end
out("PlayerGui: " .. table.concat(names, ", "))
_G.GAME = { modules = modulesCache, player = player, victim = victim, playerGui = playerGui, frame = frame, find = function(r, n) return methods.FindFirstChild(r, n, true) end, methods = methods, getSignal = getSignal, ReplicatedStorage = ReplicatedStorage, workspace = workspace, Players = Players }
do
	local okDump, dumpFn = pcall(require, "./guidump")
	if okDump then
		_G.GAME.dumpGui = function(inst, path)
			fs.writeFile(path, serde.encode("json", dumpFn(inst, methods)))
		end
	end
end
local extra = process.env.GAMESIM_EXTRA
if extra then
	local src = fs.readFile(extra)
	local function call(side, fn, ...)
		local args = table.pack(...)
		local result = nil
		local co = coroutine.create(function()
			result = table.pack(fn(table.unpack(args, 1, args.n)))
		end)
		_G.__coSide[co] = side
		local prev = _G.__side
		_G.__side = side
		local ok, err = coroutine.resume(co)
		_G.__side = prev
		if not ok then
			out("!! call failed: " .. tostring(err) .. "\n" .. debug.traceback(co))
			return nil
		end
		local waited = 0
		while coroutine.status(co) ~= "dead" and waited < 120 do
			_G.__pump(1 / 30, frame)
			waited += 1 / 30
		end
		if coroutine.status(co) ~= "dead" then
			out("!! call still waiting after 120s: " .. debug.traceback(co))
			return nil
		end
		return table.unpack(result, 1, result.n)
	end
	local fn = luau.load(luau.compile(src), { debugName = extra, environment = setmetatable({ out = out, G = _G.GAME, pump = _G.__pump, call = call, CFrame = CFrame, Vector3 = Vector3, Enum = Enum, game = game, Instance = { new = newInstanceGlobal }, UDim2 = UDim2, UDim = UDim, Color3 = Color3, Vector2 = Vector2, task = makeEnv(nil).task, RaycastParams = makeEnv(nil).RaycastParams }, { __index = _G }) })
	fn()
end
out("=== DONE")
