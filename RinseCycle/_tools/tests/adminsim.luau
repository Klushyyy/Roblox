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

local Vector3, Vector2, Color3, Enum, CFrame = roblox.Vector3, roblox.Vector2, roblox.Color3, roblox.Enum, roblox.CFrame
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
	table.insert(self.handlers, fn)
	return { Disconnect = function() end, Connected = true }
end
Signal.Once = Signal.Connect
function Signal:Fire(...)
	for _, fn in self.handlers do
		local co = coroutine.create(fn)
		local ok, err = coroutine.resume(co, ...)
		if not ok then
			out("!! ERROR in handler: " .. tostring(err) .. "\n" .. debug.traceback(co))
		end
	end
end
function Signal:Wait()
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
	PromptGamePassPurchaseFinished = true, PromptProductPurchaseFinished = true, JumpRequest = true,
	TouchStarted = true, TouchTap = true, LastInputTypeChanged = true, WindowFocused = true, WindowFocusReleased = true,
	Loaded = true, Ended = true, Played = true, Stopped = true, GamepadConnected = true, GamepadDisconnected = true, MenuOpened = true, MenuClosed = true, TouchSwipe = true, MouseClick = true, SelectionGained = true, SelectionLost = true, Destroying = true, MouseButton1Down = true, RightMouseClick = true, Triggered = true, PromptTriggered = true, OnInvoke = false, ViewportSize = false,
}
local DEFAULTS = {
	Text = "", Visible = true, Enabled = true, Transparency = 0, BackgroundTransparency = 0, TextTransparency = 0,
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
function methods:GetAttribute(k)
	return rawget(self, "__attrs")[k]
end
function methods:SetAttribute(k, v)
	rawget(self, "__attrs")[k] = v
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
function methods:PivotTo(cf)
	rawget(self, "__p").__pivot = cf
end
function methods:GetPivot()
	return rawget(self, "__p").__pivot or CFrame.new()
end
function methods:SetPrimaryPartCFrame(cf)
	rawget(self, "__p").__pivot = cf
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
rawget(TweenService, "__p").Create = function()
	local t = newInstance("Tween")
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
-- task / scheduler
local pending = {}
local taskLib = {}
function taskLib.spawn(fn, ...)
	local co = type(fn) == "thread" and fn or coroutine.create(fn)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		out("!! ERROR in task: " .. tostring(err) .. "\n" .. debug.traceback(co))
	end
	return co
end
taskLib.defer = taskLib.spawn
function taskLib.delay(t, fn, ...)
	table.insert(pending, { fn = fn, args = table.pack(...) })
end
function taskLib.wait(t)
	if coroutine.isyieldable() then
		coroutine.yield()
	end
	return t or 0
end
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
		tick = os.clock,
		time = os.clock,
		os = os,
		Instance = { new = newInstanceGlobal },
		Vector3 = Vector3,
		Vector2 = Vector2,
		CFrame = CFrame,
		Color3 = Color3,
		UDim = UDim,
		UDim2 = UDim2,
		Enum = Enum,
		BrickColor = roblox.BrickColor,
		ColorSequence = roblox.ColorSequence,
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
			return {}
		end },
		OverlapParams = { new = function()
			return {}
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

loadScript = function(path, scriptInst)
	local src = fs.readFile(path)
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
-- Server services exist by name, but load as stubs (their behaviour isn't what's under test).
local serverFolder = newInstance("Folder", "Server")
serverFolder.Parent = ServerScriptService
local servicesFolder = newInstance("Folder", "Services")
servicesFolder.Parent = serverFolder
for _, entry in fs.readDir(ROOT .. "/ServerScriptService/Server/Services") do
	local m = newInstance("ModuleScript", (entry:gsub("%.luau$", "")))
	m.Parent = servicesFolder
end
local playerModule = newInstance("ModuleScript", "PlayerModule")
playerModule.Parent = playerScripts

----------------------------------------------------------------------------------------------------
-- Run the server.
out(("=== SERVER (studio=%s, player=%s/%d)"):format(tostring(STUDIO), USERNAME, USERID))
_G.__side = "server"
local serverScript = newInstance("Script", "AdminServer")
local ok, err = pcall(loadScript, ROOT .. "/ServerScriptService/Admin/AdminServer.server.luau", serverScript)
if not ok then
	out("!! SERVER SCRIPT DIED: " .. tostring(err))
end
-- Fire PlayerAdded for the player already in the server (scripts also loop GetPlayers()).
getSignal(Players, "PlayerAdded"):Fire(player)

local remotes = {}
for _, c in methods.GetChildren(ReplicatedStorage) do
	if rawget(c, "__p").ClassName ~= "Folder" then
		table.insert(remotes, c.Name)
	end
end
out("Remotes in ReplicatedStorage: " .. #remotes)

----------------------------------------------------------------------------------------------------
-- Run the client (the real Client modules are mounted so UIKit / HUD load for real).
local clientFolder = newInstance("Folder", "Client")
clientFolder.Parent = playerScripts
mount(ROOT .. "/StarterPlayer/StarterPlayerScripts/Client", clientFolder)
out("=== CLIENT")
_G.__side = "client"
rawget(Players, "__p").LocalPlayer = player
local clientScript = newInstance("LocalScript", "AdminClient")
clientScript.Parent = playerScripts
local cok, cerr = pcall(loadScript, ROOT .. "/StarterPlayer/StarterPlayerScripts/AdminClient.local.luau", clientScript)
if not cok then
	out("!! CLIENT SCRIPT DIED: " .. tostring(cerr))
end
local guis = {}
for _, g in methods.GetChildren(playerGui) do
	table.insert(guis, g.Name)
end
out("PlayerGui: " .. table.concat(guis, ", "))
local panelGui = methods.FindFirstChild(playerGui, "AdminPanel")
out("RESULT: panel=" .. tostring(panelGui ~= nil))
if not panelGui then
	-- An exploiter firing the remote by hand must get nothing done.
	for _, c in { { "kick", "Victim" }, { "ban", "Victim" }, { "givegamepass", "SomeoneElse", "DoubleCoins" }, { "setbubbles", "SomeoneElse", "999999" }, { "announce", "", "hacked" } } do
		local since = #_G.__clientLog
		getSignal(methods.FindFirstChild(ReplicatedStorage, "AdminCommand"), "OnServerEvent"):Fire(player, c[1], c[2], c[3] or "")
		local fb
		for i = #_G.__clientLog, since + 1, -1 do
			if _G.__clientLog[i].Remote == "AdminFeedback" then
				fb = _G.__clientLog[i].Args[1]
				break
			end
		end
		out(string.format("exploit :%s -> %s (other traffic: %d)", c[1], tostring(fb), #_G.__clientLog - since - (fb and 1 or 0)))
	end
	out("victim still here: " .. tostring(victim.Parent ~= nil) .. ", bubbles: " .. tostring(_G.__profiles[player] and _G.__profiles[player].Bubbles))
	return
end

local function find(root, name)
	return methods.FindFirstChild(root, name, true)
end
local function click(btn)
	getSignal(btn, "Activated"):Fire()
	getSignal(btn, "MouseButton1Click"):Fire()
end
local function lastFeedback(since)
	for i = #_G.__clientLog, since + 1, -1 do
		local e = _G.__clientLog[i]
		if e.Remote == "AdminFeedback" then
			return tostring(e.Args[1]), e.Args[2]
		end
	end
	return nil
end
local function sentSince(since)
	local names = {}
	for i = since + 1, #_G.__clientLog do
		local e = _G.__clientLog[i]
		if e.Remote ~= "AdminFeedback" then
			table.insert(names, e.Remote .. "->" .. tostring(e.To))
		end
	end
	return table.concat(names, ",")
end

-- The HUD hook got the click handler; use UIKit to open the window like the button would.
local UIKit = modulesCache[ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local HUDmod = modulesCache[ROOT .. "/StarterPlayer/StarterPlayerScripts/Client/HUD.luau"]
out("HUD module loaded: " .. tostring(HUDmod ~= nil))
UIKit.OpenWindow("Admin")
local window = find(panelGui, "Admin")
out("Window visible: " .. tostring(window and window.Visible))
local list = find(panelGui, "Players")
local victimRow = list and find(list, "Victim")
out("Victim row: " .. tostring(victimRow ~= nil))
click(victimRow)

-- Values to fill per input kind / command.
local FILL = {
	givecoins = { "500" }, giant = { "8" }, abuse = { "15" }, setbubbles = { "1234" }, setgems = { "77" }, setrebirths = { "2" },
	warn = { "spamming" }, msg = { "hello there" }, announce = { "Server restart soon" },
	playerlogs = { "EnderBuilda" }, kick = { "bye" }, ban = { "test ban" },
	globalpoll = { "Best? | Yes | No" }, globalgive = { "100" }, globalpassdrop = { "1" }, globalboost = { "5" },
}
local SKIP = { kick = true, ban = true, tempban = true, spectate = true, controlplayer = true, wipelogs = false }
local results = {}
local groupsFrame = find(panelGui, "Groups")
local runBtn = find(panelGui, "Run")
local inputs = find(panelGui, "Inputs")
for _, groupBtn in methods.GetChildren(groupsFrame) do
	if rawget(groupBtn, "__p").ClassName ~= "TextButton" then
		continue
	end
	click(groupBtn)
	local grid = find(panelGui, "Commands")
	local cells = {}
	for _, c in methods.GetChildren(grid) do
		if tostring(c.Name):sub(1, 4) == "Cmd_" then
			table.insert(cells, c)
		end
	end
	for _, cell in cells do
		local name = tostring(cell.Name):sub(5)
		-- cells get rebuilt on click, so look the current one up again
		local live = find(find(panelGui, "Commands"), cell.Name)
		local since = #_G.__clientLog
		click(live)
		if not SKIP[name] then
			-- fill text boxes and pick the first choice where nothing is picked yet
			local fill = FILL[name] or {}
			local fi = 0
			for _, row in methods.GetChildren(inputs) do
				if rawget(row, "__p").ClassName ~= "Frame" then
					continue
				end
				local box = find(row, "Box")
				if box then
					fi += 1
					box.Text = fill[fi] or "test"
				else
					local strip = methods.FindFirstChildOfClass(row, "ScrollingFrame")
					local btns = {}
					for _, b in (strip and methods.GetChildren(strip) or {}) do
						if rawget(b, "__p").ClassName == "TextButton" then
							table.insert(btns, b)
						end
					end
					if #btns > 0 then
						click(btns[math.min(2, #btns)])
					end
				end
			end
			since = #_G.__clientLog
			click(runBtn)
		end
		local fb, isErr = lastFeedback(since)
		table.insert(results, string.format("%-14s %s %s  [%s]", name, if SKIP[name] then "SKIP" elseif fb == nil then "NO-FEEDBACK" elseif isErr then "ERR " else "ok  ", tostring(fb), sentSince(since)))
	end
end
out("=== COMMAND RESULTS")
for _, r in results do
	out(r)
end
out("Victim TextSource.CanSend after mute toggles: " .. tostring(find(general, "Victim").CanSend))
-- lists
local lv = find(panelGui, "ListView")
out("List view open: " .. tostring(lv and lv.Visible))
-- mute again (should mute), then mutelist and modify
local since = #_G.__clientLog
getSignal(find(ReplicatedStorage, "AdminCommand"), "OnServerEvent"):Fire(player, "mute", "Victim", "rude")
out("mute -> " .. tostring(lastFeedback(since)) .. "  CanSend=" .. tostring(find(general, "Victim").CanSend))
since = #_G.__clientLog
getSignal(find(ReplicatedStorage, "AdminCommand"), "OnServerEvent"):Fire(player, "tempmute", "Victim", "1h being loud")
out("tempmute -> " .. tostring(lastFeedback(since)) .. "  CanSend=" .. tostring(find(general, "Victim").CanSend))
-- the delivery filter should block Victim's message
local cb = find(general, "RBXGeneral") or general
local deliver = rawget(general, "__p").ShouldDeliverCallback
if deliver then
	out("filter delivers Victim msg: " .. tostring(deliver({ TextSource = { UserId = 555 }, MessageId = "m1" })))
	out("filter delivers owner msg: " .. tostring(deliver({ TextSource = { UserId = USERID }, MessageId = "m2" })))
end
since = #_G.__clientLog
click(find(panelGui, "Cmd_mutelist") or runBtn)
getSignal(find(ReplicatedStorage, "AdminCommand"), "OnServerEvent"):Fire(player, "mutelist", "", "")
local rows = find(lv, "ScrollingFrame")
local modify
for _, d in methods.GetDescendants(lv) do
	if rawget(d, "__p").ClassName == "TextButton" and d.Text == "Modify" then
		modify = d
	end
end
out("mutelist rows have Modify: " .. tostring(modify ~= nil))
if modify then
	click(modify)
	local unmute
	for _, d in methods.GetDescendants(find(lv, "Detail")) do
		if rawget(d, "__p").ClassName == "TextButton" and d.Text == "UNMUTE" then
			unmute = d
		end
	end
	out("detail has UNMUTE: " .. tostring(unmute ~= nil))
	if unmute then
		since = #_G.__clientLog
		click(unmute)
		out("unmute -> " .. tostring(lastFeedback(since)) .. "  CanSend=" .. tostring(find(general, "Victim").CanSend))
	end
end
-- command line
local cl = find(panelGui, "CommandLine")
since = #_G.__clientLog
cl.Text = ":announce hi everyone"
getSignal(cl, "FocusLost"):Fire(true)
out("command line :announce -> " .. tostring(lastFeedback(since)) .. " " .. sentSince(since))
out("Announcement banner shown: " .. tostring(find(playerGui, "Announcement") ~= nil))

out("=== SPECTATE / CONTROL / KICK / BAN")
local AC = find(ReplicatedStorage, "AdminCommand")
local function run(cmd, target, extra)
	local since = #_G.__clientLog
	getSignal(AC, "OnServerEvent"):Fire(player, cmd, target, extra or "")
	local fb, isErr = lastFeedback(since)
	out(string.format("%-14s %s %s  [%s]", cmd, if isErr then "ERR " else "ok  ", tostring(fb), sentSince(since)))
end
run("spectate", "Victim")
local bar = find(playerGui, "AdminActionBar")
out("action bar visible: " .. tostring(bar and bar.Visible))
local stop
for _, d in methods.GetDescendants(bar) do
	if rawget(d, "__p").ClassName == "TextButton" and tostring(d.Text):find("Stop") then
		stop = d
	end
end
if stop then
	local since = #_G.__clientLog
	click(stop)
	out("stop spectate -> bar visible " .. tostring(bar.Visible) .. " [" .. sentSince(since) .. "]")
end
run("controlplayer", "Victim")
out("action bar visible: " .. tostring(bar.Visible))
if stop then
	local since = #_G.__clientLog
	click(stop)
	out("stop control -> bar visible " .. tostring(bar.Visible) .. " [" .. sentSince(since) .. "]")
end
run("spectate", "EnderBuilda")
run("tempban", "Victim", "3d griefing")
run("banlist", "", "")
run("kick", "Victim", "bye")
run("ban", "Victim", "cheating")
run("nonsense", "Victim", "")

out("=== SELF STATUS (what a muted / frozen / flying player sees)")
local statusGui = find(playerGui, "AdminStatus")
run("mute", "EnderBuilda", "testing")
out("muted chip: " .. tostring(find(statusGui, "Muted").Visible) .. "  chat bar enabled: " .. tostring(chatBar.Enabled))
run("mute", "EnderBuilda", "")
out("after unmute chip: " .. tostring(find(statusGui, "Muted").Visible) .. "  chat bar enabled: " .. tostring(chatBar.Enabled))
run("freeze", "EnderBuilda", "")
out("frozen chip: " .. tostring(find(statusGui, "Frozen").Visible))
run("freeze", "EnderBuilda", "")
out("frozen chip after 2nd freeze: " .. tostring(find(statusGui, "Frozen").Visible))
run("fly", "EnderBuilda", "")
out("fly chip: " .. tostring(find(statusGui, "Flying").Visible) .. "  LinearVelocity on root: " .. tostring(methods.FindFirstChildOfClass(hrp, "LinearVelocity") ~= nil))
run("fly", "EnderBuilda", "")
out("fly chip after 2nd fly: " .. tostring(find(statusGui, "Flying").Visible) .. "  LinearVelocity on root: " .. tostring(methods.FindFirstChildOfClass(hrp, "LinearVelocity") ~= nil))
run("msg", "EnderBuilda", "hi me")
out("notice shown: " .. tostring(find(statusGui, "AdminNotice") ~= nil))
