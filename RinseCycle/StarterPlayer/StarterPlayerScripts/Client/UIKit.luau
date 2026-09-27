--[[
	UIKit - Rinse Cycle's design system. Every screen, window, button and toast in the game is built
	with it, so the whole game shares one look: bright aqua, deep navy glass panels, chunky rounded
	buttons with a darker "lip" and a soap-bubble shine, white FredokaOne text with a dark outline.

	USAGE
		local UIKit = require(script.Parent:WaitForChild("UIKit"))
		local C = UIKit.Theme.Colors

		-- 1. A screen. `root` is a virtual ~1280x720 canvas: build in reference pixels and UIKit
		--    scales everything to the real screen (landscape phones get ~0.46, 4K gets up to 2).
		local gui, root = UIKit.CreateScreen("Shop", 10)

		-- 2. A window (hidden by default). The same name in Window and RegisterWindow links them:
		--    UIKit shows, animates and hides the frame itself, the handlers only refresh content.
		local window, content = UIKit.Window({ Name = "Shop", Title = "Soap Shop", Icon = "🛒",
			Size = Vector2.new(820, 520), Parent = root })
		UIKit.RegisterWindow("Shop", { Open = function(arg) refresh() end, Close = function() end })
		UIKit.ToggleWindow("Shop")        -- OpenWindow / CloseWindow / IsWindowOpen / WindowChanged
		window:SetAttribute("Title", "…") -- live title change (also "Icon")

		-- 3. Buttons. OnClick plays the click sound, respects the Disabled attribute and ignores new
		--    clicks while a previous OnClick is still yielding (no double purchases).
		local buy = UIKit.Button({ Text = "Buy", Size = UDim2.fromOffset(160, 56), Color = C.Good,
			Parent = content, OnClick = function() ... end })
		buy:SetAttribute("Disabled", true) -- greyed out, ignores clicks (a little wobble); false/nil re-enables
		buy.Text = "MAX"                   -- Text / TextColor3 / TextSize / BackgroundColor3 (= the face
		buy.BackgroundColor3 = C.Bad       -- colour) restyle a UIKit button live, tweens included

		-- 4. Everything else
		UIKit.Toast("Not enough coins!", "Bad")        -- "Info" | "Good" | "Bad"
		local bar = UIKit.ProgressBar({ Size = UDim2.fromOffset(300, 34), Parent = root })
		bar.Set(0.42, "42% clean")                     -- bar.SetColor(C.Bad) recolours the fill
		UIKit.LayoutChanged:Connect(relayout)          -- re-place things that use TopInset()/IsTouch()

	RULES OF THUMB
		* Anything near the top of the screen sits below UIKit.TopInset() (canvas units).
		* On touch (UIKit.IsTouch()) keep the bottom-left 420x320 and bottom-right 300x300 clear.
		* TextSize 18 minimum for anything important (the HUD must read at 0.46 scale).
		* UIKit.Label adds a dark text outline; pass Stroke = false to skip it.
		* Use OnClick, not button.Activated, or the Disabled attribute is not respected.
		* UIGradient tints everything its parent draws, text included. Put text in a child label.
]]

local ContentProvider = game:GetService("ContentProvider")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Format = require(Shared:WaitForChild("Format"))
local Util = require(Shared:WaitForChild("Util"))

local UIKit = {}

-- The reference canvas every screen is designed on.
local REF_W, REF_H = 1280, 720
local MIN_SCALE, MAX_SCALE = 0.4, 2
-- The topbar inset reads 0 for the first moments of a session, so it is re-read at these times.
local INSET_REREADS = { 0.25, 0.5, 1, 2, 3, 5 }

local WINDOW_MARGIN = 16
local WINDOW_TITLE_H = 56
local WINDOW_SHADOW_T = 0.55

local TOAST_MAX = 4
local TOAST_GAP = 8
local TOAST_TEXT_SIZE = 22
local TOAST_MAX_TEXT_W = 620

local SOUND_LOAD_TIMEOUT = 3 -- seconds before a sound that hasn't loaded is swapped for Fallback
local SOUND_MAX_VOICES = 8 -- simultaneous copies of one sound key
local SOUND_MIN_GAP = 0.03 -- the same key can't restart faster than this (20 pops in one frame = 1 pop)

----------------------------------------------------------------------------------------------------
-- Theme
----------------------------------------------------------------------------------------------------
local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

UIKit.Theme = {
	Colors = {
		Primary = rgb(56, 189, 248), -- #38BDF8 aqua
		PrimaryDark = rgb(2, 132, 199), -- #0284C7
		Accent = rgb(167, 139, 250), -- #A78BFA lavender soap
		Good = rgb(52, 211, 153), -- #34D399
		Bad = rgb(248, 113, 113), -- #F87171
		Warning = rgb(251, 146, 60), -- #FB923C
		Panel = rgb(19, 49, 92), -- #13315C
		PanelDark = rgb(11, 37, 69), -- #0B2545
		Text = rgb(255, 255, 255),
		TextDim = rgb(166, 196, 228),
		Coin = rgb(255, 200, 61), -- #FFC83D
		Bubble = rgb(255, 126, 182), -- #FF7EB6
		White = rgb(255, 255, 255),
		-- Extras (not in the DESIGN list, safe to use):
		PanelLight = rgb(30, 72, 128), -- inset cards and rows on a panel
		TextDark = rgb(11, 37, 69), -- navy text on light surfaces
		Stroke = rgb(6, 22, 46), -- text outlines
		Ink = rgb(5, 16, 36), -- the dark tone lips, outlines and shadows are mixed toward
		Disabled = rgb(128, 142, 162),
	},
	Fonts = {
		Title = Enum.Font.FredokaOne,
		Body = Enum.Font.GothamBold,
		Medium = Enum.Font.GothamMedium,
	},
	Corner = 12,
	CornerLarge = 16,
	StrokeThickness = 3,
}

local Colors = UIKit.Theme.Colors
local Fonts = UIKit.Theme.Fonts
local WHITE = Color3.new(1, 1, 1)

----------------------------------------------------------------------------------------------------
-- Small builders used everywhere below
----------------------------------------------------------------------------------------------------
local function lighten(color: Color3, t: number): Color3
	return color:Lerp(WHITE, t)
end

local function darken(color: Color3, t: number): Color3
	return color:Lerp(Colors.Ink, t)
end

-- Colour helpers for other modules (e.g. a hover tint or a darker outline of a rarity colour).
UIKit.Lighten = lighten
UIKit.Darken = darken

local function tween(
	inst: Instance,
	goal: { [string]: any },
	time: number?,
	style: Enum.EasingStyle?,
	direction: Enum.EasingDirection?
): Tween
	local info = TweenInfo.new(time or 0.25, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out)
	local tw = TweenService:Create(inst, info, goal)
	tw:Play()
	return tw
end

local function addCorner(parent: Instance, radius: UDim): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = radius
	c.Parent = parent
	return c
end

local function addStroke(
	parent: Instance,
	color: Color3,
	thickness: number,
	transparency: number?,
	mode: Enum.ApplyStrokeMode?
): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color
	s.Thickness = thickness
	s.Transparency = transparency or 0
	s.LineJoinMode = Enum.LineJoinMode.Round
	s.ApplyStrokeMode = mode or Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

-- Outline for text: thicker for big headings, lighter for small print so the letters stay open.
local function addTextStroke(label: Instance, textSize: number, color: Color3?, thickness: number?, transparency: number?): UIStroke
	local auto = if textSize >= 30 then 3 elseif textSize >= 18 then 2 else 1.5
	local autoT = if textSize < 16 then 0.3 else 0
	return addStroke(label, color or Colors.Stroke, thickness or auto, transparency or autoT, Enum.ApplyStrokeMode.Contextual)
end

local function addGradient(parent: Instance, top: Color3, bottom: Color3): UIGradient
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(top, bottom)
	g.Rotation = 90
	g.Parent = parent
	return g
end

-- The glossy highlight across the top of every button, bar and banner (the "soap bubble" shine).
-- strength = opacity at the top edge; it fades to nothing at the bottom.
local function addShine(parent: Instance, radius: UDim, inset: number, heightScale: number, strength: number): Frame
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.BackgroundColor3 = WHITE
	shine.BorderSizePixel = 0
	shine.Position = UDim2.fromOffset(inset, math.max(2, math.floor(inset * 0.6)))
	shine.Size = UDim2.new(1, -inset * 2, heightScale, 0)
	shine.ZIndex = 1
	addCorner(shine, radius)
	local fade = Instance.new("UIGradient")
	fade.Rotation = 90
	fade.Transparency = NumberSequence.new(1 - strength, 1)
	fade.Parent = shine
	shine.Parent = parent
	return shine
end

-- A faint soap bubble (ring + glint) used to decorate panels.
local function addDecorBubble(parent: Instance, position: UDim2, diameter: number, zIndex: number): Frame
	local bubble = Instance.new("Frame")
	bubble.Name = "Bubble"
	bubble.AnchorPoint = Vector2.new(0.5, 0.5)
	bubble.Position = position
	bubble.Size = UDim2.fromOffset(diameter, diameter)
	bubble.BackgroundColor3 = WHITE
	bubble.BackgroundTransparency = 0.95
	bubble.BorderSizePixel = 0
	bubble.ZIndex = zIndex
	addCorner(bubble, UDim.new(0.5, 0))
	addStroke(bubble, WHITE, 2, 0.8)
	local glint = Instance.new("Frame")
	glint.Name = "Glint"
	glint.AnchorPoint = Vector2.new(0.5, 0.5)
	glint.Position = UDim2.fromScale(0.3, 0.3)
	glint.Size = UDim2.fromScale(0.2, 0.2)
	glint.BackgroundColor3 = WHITE
	glint.BackgroundTransparency = 0.6
	glint.BorderSizePixel = 0
	glint.ZIndex = zIndex
	addCorner(glint, UDim.new(0.5, 0))
	glint.Parent = bubble
	bubble.Parent = parent
	return bubble
end

-- Copies props onto an instance, skipping the keys in `skip`. Returns the Parent (set it last).
local function assign(inst: Instance, props: { [string]: any }?, skip: { [string]: boolean }?): Instance?
	local parent = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			elseif type(key) == "string" and not (skip and skip[key]) then
				(inst :: any)[key] = value
			end
		end
	end
	return parent
end

local function safeCall(fn: (...any) -> ...any, ...: any)
	local ok, err = xpcall(fn, debug.traceback, ...)
	if not ok then
		warn("[UIKit] callback failed:\n" .. tostring(err))
	end
end

----------------------------------------------------------------------------------------------------
-- Screen scaling
----------------------------------------------------------------------------------------------------
type Screen = { Gui: ScreenGui, Root: Frame, Scale: UIScale }

local initialized = false
local scale = 1
local viewport = Vector2.new(REF_W, REF_H)
local insetPx = 0
local lastTouch = false
local lastGamepad = false
local safePx = Vector3.zero -- device safe-area insets in real pixels: (left, right, bottom)
local safeProbes: { Full: ScreenGui, Safe: ScreenGui }? = nil
local screens: { Screen } = {}
-- Internal re-layout steps (windows, toasts) that must run before LayoutChanged listeners do.
local layoutHooks: { () -> () } = {}

-- Fired (no arguments) when the viewport, scale, top inset, safe insets or preferred input type
-- changes. Windows and toasts have already been re-laid out when it fires.
UIKit.LayoutChanged = Util.Signal.new()

-- Console text boost: TVs are read from the sofa, so text is 20% bigger with a gamepad (boxes keep
-- their size; scaled text still fits because it shrinks to its box). Every label made through
-- UIKit.Label / UIKit.Button registers here with its design size.
local GAMEPAD_TEXT_BOOST = 1.2
type TextEntry = { Base: number, Limit: UITextSizeConstraint? }
local textEntries: { [TextLabel]: TextEntry } = setmetatable({}, { __mode = "k" }) :: any
local textBoost = 1

local function applyTextBoost(label: TextLabel, entry: TextEntry)
	local size = math.clamp(math.floor(entry.Base * textBoost + 0.5), 1, 100)
	label.TextSize = size
	if entry.Limit then
		entry.Limit.MaxTextSize = size
	end
end

local function registerText(label: TextLabel, base: number, limit: UITextSizeConstraint?)
	local entry = { Base = base, Limit = limit }
	textEntries[label] = entry
	if textBoost ~= 1 then
		applyTextBoost(label, entry)
	end
end

local function readViewport(): Vector2
	-- The truth is the size of a full-screen ScreenGui (ScreenInsets None, IgnoreGuiInset): that is
	-- exactly the space every Root lives in. The camera's ViewportSize can disagree with it on some
	-- phones (iOS), which used to leave the canvas narrower than the screen - side buttons ended up
	-- towards the middle and windows off-centre.
	local probes = safeProbes
	if probes and probes.Full.Parent then
		local abs = probes.Full.AbsoluteSize
		if abs.X >= 2 and abs.Y >= 2 then
			return abs
		end
	end
	for _, s in screens do
		local abs = s.Gui.AbsoluteSize
		if abs.X >= 2 and abs.Y >= 2 then
			return abs
		end
	end
	local camera = workspace.CurrentCamera
	if camera then
		local size = camera.ViewportSize
		if size.X >= 2 and size.Y >= 2 then
			return size
		end
	end
	-- Very early the camera can report 1x1; any of our full-screen guis knows the real size.
	for _, s in screens do
		local abs = s.Gui.AbsoluteSize
		if abs.X >= 2 and abs.Y >= 2 then
			return abs
		end
	end
	return Vector2.new(REF_W, REF_H)
end

-- Height of the Roblox topbar in real pixels (58 on PC, taller on consoles).
local function readInsetPx(): number
	local px = 0
	local okRect, rect = pcall(function()
		return GuiService.TopbarInset
	end)
	if okRect and typeof(rect) == "Rect" then
		px = math.max(px, rect.Max.Y, rect.Height)
	end
	local okInset, topLeft = pcall(function()
		return (GuiService:GetGuiInset())
	end)
	if okInset and typeof(topLeft) == "Vector2" then
		px = math.max(px, topLeft.Y)
	end
	return px
end

local function preferredInput(): EnumItem?
	local ok, value = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and typeof(value) == "EnumItem" then
		return value
	end
	return nil
end

function UIKit.IsTouch(): boolean
	local pref = preferredInput()
	if pref then
		return pref == (Enum :: any).PreferredInput.Touch
	end
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

function UIKit.IsGamepad(): boolean
	local pref = preferredInput()
	if pref then
		local enum = (Enum :: any).PreferredInput
		return pref == enum.Gamepad or pref == enum.MicroGamepad
	end
	return string.sub(UserInputService:GetLastInputType().Name, 1, 7) == "Gamepad"
end

-- Notch / home-bar insets, measured by comparing two empty probe guis (full screen vs device-safe)
-- so the result doesn't depend on which coordinate space AbsolutePosition uses.
local function readSafePx(): Vector3
	local probes = safeProbes
	if not probes or not probes.Full.Parent or not probes.Safe.Parent then
		return Vector3.zero
	end
	local fp, fs = probes.Full.AbsolutePosition, probes.Full.AbsoluteSize
	local sp, ss = probes.Safe.AbsolutePosition, probes.Safe.AbsoluteSize
	if fs.X < 2 or fs.Y < 2 or ss.X < 2 or ss.Y < 2 then
		return Vector3.zero
	end
	local maxSide = fs.X * 0.25
	local left = math.clamp(sp.X - fp.X, 0, maxSide)
	local right = math.clamp((fp.X + fs.X) - (sp.X + ss.X), 0, maxSide)
	local bottom = math.clamp((fp.Y + fs.Y) - (sp.Y + ss.Y), 0, fs.Y * 0.25)
	return Vector3.new(math.floor(left), math.floor(right), math.floor(bottom))
end

local function canvasSize(): Vector2
	-- ceil so the scaled canvas always covers the last pixel column/row
	return Vector2.new(math.ceil(viewport.X / scale), math.ceil(viewport.Y / scale))
end

local function applyLayout(force: boolean)
	local vp = readViewport()
	local newScale = math.clamp(math.min(vp.X / REF_W, vp.Y / REF_H), MIN_SCALE, MAX_SCALE)
	local newInset = readInsetPx()
	local touch = UIKit.IsTouch()
	local pad = UIKit.IsGamepad()
	local newSafe = readSafePx()
	if
		not force
		and vp == viewport
		and newScale == scale
		and newInset == insetPx
		and touch == lastTouch
		and pad == lastGamepad
		and newSafe == safePx
	then
		return
	end
	viewport, scale, insetPx, lastTouch, lastGamepad, safePx = vp, newScale, newInset, touch, pad, newSafe
	local boost = if pad then GAMEPAD_TEXT_BOOST else 1
	if boost ~= textBoost then
		textBoost = boost
		for label, entry in textEntries do
			if label.Parent then
				applyTextBoost(label, entry)
			end
		end
	end

	for _, s in screens do
		s.Root.Size = UDim2.fromScale(1 / scale, 1 / scale)
		s.Scale.Scale = scale
	end
	for _, hook in layoutHooks do
		safeCall(hook)
	end
	UIKit.LayoutChanged:Fire()
end

-- Viewport drags fire ViewportSize many times per frame; coalesce into one layout pass.
local refreshQueued = false
local function queueRefresh()
	if refreshQueued then
		return
	end
	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		applyLayout(false)
	end)
end

-- Two empty ScreenGuis whose AbsolutePosition/AbsoluteSize reveal the device safe area. They also
-- tell us when it moves (a phone flipped 180 degrees swaps the notch side without a size change).
local function ensureSafeProbes(playerGui: Instance?)
	if safeProbes and safeProbes.Full.Parent and safeProbes.Safe.Parent then
		return
	end
	if not playerGui then
		return
	end
	if safeProbes then
		safeProbes.Full:Destroy()
		safeProbes.Safe:Destroy()
	end
	local function probe(name: string, insets: Enum.ScreenInsets): ScreenGui
		local g = Instance.new("ScreenGui")
		g.Name = name
		g.IgnoreGuiInset = true
		g.ResetOnSpawn = false
		g.ScreenInsets = insets
		g:GetPropertyChangedSignal("AbsoluteSize"):Connect(queueRefresh)
		g:GetPropertyChangedSignal("AbsolutePosition"):Connect(queueRefresh)
		g.Parent = playerGui
		return g
	end
	safeProbes = {
		Full = probe("UIKitProbeFull", Enum.ScreenInsets.None),
		Safe = probe("UIKitProbeSafe", Enum.ScreenInsets.DeviceSafeInsets),
	}
	queueRefresh()
end

local function ensureInit()
	if not initialized then
		UIKit.Init()
	end
end

function UIKit.GetScale(): number
	ensureInit()
	return scale
end

-- Roblox topbar height in canvas units. Keep anything near the top of the screen below this.
function UIKit.TopInset(): number
	ensureInit()
	return insetPx / scale
end

-- Size of the virtual canvas (= every Root's size) in reference pixels. One side is ~1280 or ~720.
function UIKit.CanvasSize(): Vector2
	ensureInit()
	return canvasSize()
end

-- Extra (not in DESIGN): notch / home-indicator insets in canvas units. Every Root spans the whole
-- screen (ScreenInsets None), so add Left/Right to margins of anything hugging a side edge on phones.
-- All zeros on devices without cutouts. LayoutChanged fires when they change.
function UIKit.SafeInsets(): { Left: number, Right: number, Bottom: number }
	ensureInit()
	return { Left = safePx.X / scale, Right = safePx.Y / scale, Bottom = safePx.Z / scale }
end

function UIKit.CreateScreen(name: string, displayOrder: number?): (ScreenGui, Frame)
	ensureInit()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	ensureSafeProbes(playerGui)

	local gui = Instance.new("ScreenGui")
	gui.Name = tostring(name)
	gui.DisplayOrder = displayOrder or 0
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.ClipToDeviceSafeArea = false -- the canvas covers the whole screen, so don't clip it either
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Root is the virtual canvas: viewport / scale in size, scaled back up by its UIScale.
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Position = UDim2.fromOffset(0, 0)
	-- Scale-based so the (UIScale'd) root always covers its ScreenGui exactly, whatever the
	-- device reports elsewhere; canvasSize() is only used for layout maths.
	root.Size = UDim2.fromScale(1 / scale, 1 / scale)
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = scale
	uiScale.Parent = root
	root.Parent = gui

	local entry: Screen = { Gui = gui, Root = root, Scale = uiScale }
	table.insert(screens, entry)
	gui.Destroying:Connect(function()
		local i = table.find(screens, entry)
		if i then
			table.remove(screens, i)
		end
	end)

	gui.Parent = playerGui
	return gui, root
end

----------------------------------------------------------------------------------------------------
-- Primitives
----------------------------------------------------------------------------------------------------

-- Instance.new + props + children, Parent set last. GuiObjects default to BorderSizePixel = 0.
function UIKit.New(className: string, props: { [string]: any }?, children: { Instance }?): Instance
	local inst = Instance.new(className :: any)
	if inst:IsA("GuiObject") then
		inst.BorderSizePixel = 0
	end
	local parent = assign(inst, props)
	if children then
		for _, child in children do
			child.Parent = inst
		end
	end
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- radius in canvas px (default 12). Pass something huge (999) for a pill / circle.
function UIKit.Corner(parent: Instance, radius: number?): UICorner
	return addCorner(parent, UDim.new(0, radius or UIKit.Theme.Corner))
end

-- On a TextLabel the stroke outlines the text; on anything else (frames, buttons, text boxes) it
-- outlines the border. Set .ApplyStrokeMode on the result to override.
function UIKit.Stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	local mode = if parent:IsA("TextLabel") then Enum.ApplyStrokeMode.Contextual else Enum.ApplyStrokeMode.Border
	return addStroke(parent, color or Colors.Stroke, thickness or UIKit.Theme.StrokeThickness, transparency, mode)
end

function UIKit.Padding(parent: Instance, px: number): UIPadding
	local p = Instance.new("UIPadding")
	local u = UDim.new(0, px or 8)
	p.PaddingTop = u
	p.PaddingBottom = u
	p.PaddingLeft = u
	p.PaddingRight = u
	p.Parent = parent
	return p
end

-- Top-to-bottom gradient. Sets the parent's BackgroundColor3 to white so the colours come out exactly.
function UIKit.Gradient(parent: Instance, top: Color3, bottom: Color3): UIGradient
	if parent:IsA("GuiObject") then
		parent.BackgroundColor3 = WHITE
	end
	return addGradient(parent, top, bottom)
end

local LABEL_SKIP = { Text = true, Stroke = true, StrokeColor = true, StrokeThickness = true, StrokeTransparency = true }

--[[
	Text label with the house style: transparent background, white text, dark outline.
	props: any TextLabel property (Text, Size, Position, AnchorPoint, TextSize, Font, TextColor3,
	TextXAlignment, TextWrapped, ZIndex, LayoutOrder, Parent...) plus:
	  Stroke = false            no outline
	  StrokeColor / StrokeThickness / StrokeTransparency
	Font defaults to FredokaOne for TextSize >= 18 and GothamBold for smaller print.
	With TextScaled = true, TextSize becomes the maximum size.
]]
function UIKit.Label(props: { [string]: any }?): TextLabel
	local p: { [string]: any } = props or {}
	local textSize = tonumber(p.TextSize) or 22
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Size = UDim2.fromOffset(200, textSize + 10)
	label.Font = if textSize >= 18 then Fonts.Title else Fonts.Body
	label.TextSize = textSize
	label.TextColor3 = Colors.Text
	label.Text = if p.Text ~= nil then tostring(p.Text) else ""
	local parent = assign(label, p, LABEL_SKIP)
	local labelLimit: UITextSizeConstraint? = nil
	if label.TextScaled then
		local limit = Instance.new("UITextSizeConstraint")
		limit.MaxTextSize = math.clamp(math.floor(textSize), 1, 100)
		limit.MinTextSize = math.clamp(math.min(12, math.floor(textSize)), 1, 100)
		limit.Parent = label
		labelLimit = limit
	end
	registerText(label, textSize, labelLimit)
	if p.Stroke ~= false then
		addTextStroke(label, textSize, p.StrokeColor, p.StrokeThickness, p.StrokeTransparency)
	end
	if parent then
		label.Parent = parent
	end
	return label
end

-- A rounded inset card for rows and tiles inside a window (lighter navy with a soft rim).
-- props: any Frame property plus Color, CornerRadius, StrokeColor.
local CARD_SKIP = { Color = true, CornerRadius = true, StrokeColor = true }
function UIKit.Card(props: { [string]: any }?): Frame
	local p: { [string]: any } = props or {}
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.Size = UDim2.fromOffset(200, 100)
	card.BackgroundColor3 = p.Color or Colors.PanelLight
	card.BorderSizePixel = 0
	addCorner(card, UDim.new(0, p.CornerRadius or UIKit.Theme.Corner))
	addStroke(card, p.StrokeColor or lighten(Colors.PanelLight, 0.2), 2, 0.25)
	local parent = assign(card, p, CARD_SKIP)
	if parent then
		card.Parent = parent
	end
	return card
end

----------------------------------------------------------------------------------------------------
-- Sounds
----------------------------------------------------------------------------------------------------
local soundFolder: Folder? = nil
local templates: { [string]: Sound } = {}
local failedKeys: { [string]: boolean } = {}
local voices: { [string]: number } = {}
local lastPlayedAt: { [string]: number } = {}

local function getSoundFolder(): Folder
	if soundFolder and soundFolder.Parent then
		return soundFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "UIKitSounds"
	folder.Parent = SoundService
	soundFolder = folder
	return folder
end

-- One cached template Sound per Config.Sounds key. Plays use short-lived clones so the same sound
-- can overlap itself (pop combos, rapid clicks).
local function getTemplate(key: string): Sound?
	local existing = templates[key]
	if existing and existing.Parent then
		return existing
	end
	local def = (Config.Sounds :: any)[key]
	if type(def) ~= "table" or type(def.Id) ~= "string" then
		return nil
	end
	local sound = Instance.new("Sound")
	sound.Name = key
	sound.SoundId = def.Id
	sound.Volume = tonumber(def.Volume) or 0.5
	sound.Parent = getSoundFolder()
	templates[key] = sound

	if key ~= "Fallback" and not sound.IsLoaded then
		-- If it hasn't loaded after a few seconds (deleted / private asset), play Fallback instead.
		-- A late load clears the flag again.
		sound.Loaded:Once(function()
			failedKeys[key] = nil
		end)
		task.delay(SOUND_LOAD_TIMEOUT, function()
			if templates[key] == sound and not sound.IsLoaded then
				failedKeys[key] = true
			end
		end)
	end
	return sound
end

local function preloadSounds()
	local list = {}
	for key in Config.Sounds do
		local sound = getTemplate(tostring(key))
		if sound then
			table.insert(list, sound)
		end
	end
	pcall(function()
		ContentProvider:PreloadAsync(list, function(contentId: string, status: Enum.AssetFetchStatus)
			if status ~= Enum.AssetFetchStatus.Failure then
				return
			end
			for key, sound in templates do
				if key ~= "Fallback" and sound.SoundId == contentId then
					failedKeys[key] = true
				end
			end
		end)
	end)
end

-- Plays Config.Sounds[key] (no-op for unknown keys). pitch = PlaybackSpeed, default 1.
function UIKit.PlaySound(key: string, pitch: number?)
	if type(key) ~= "string" then
		return
	end
	local template = getTemplate(key)
	if not template then
		return
	end
	local now = os.clock()
	if now - (lastPlayedAt[key] or 0) < SOUND_MIN_GAP or (voices[key] or 0) >= SOUND_MAX_VOICES then
		return
	end
	lastPlayedAt[key] = now

	local source = template
	if failedKeys[key] then
		source = getTemplate("Fallback") or template
	end
	local speed = tonumber(pitch) or 1
	if speed ~= speed then
		speed = 1
	end

	local voice = source:Clone()
	voice.PlaybackSpeed = math.clamp(speed, 0.2, 4)
	voice.Parent = getSoundFolder()
	voices[key] = (voices[key] or 0) + 1

	local done = false
	local function finish()
		if done then
			return
		end
		done = true
		voices[key] = math.max(0, (voices[key] or 1) - 1)
		voice:Destroy()
	end
	voice.Ended:Once(finish)
	task.delay(10, finish) -- safety net: a clone that never loads never fires Ended
	voice:Play()
end

----------------------------------------------------------------------------------------------------
-- Buttons
----------------------------------------------------------------------------------------------------
type Chunky = {
	Visual: Frame,
	Press: UIScale,
	Lip: Frame,
	LipStroke: UIStroke,
	Face: Frame,
	FaceGradient: UIGradient,
	Shine: Frame,
}

-- One shared rounded highlight for gamepad selection instead of Roblox's square default.
local selectionImage: Frame? = nil
local function getSelectionImage(): Frame
	if selectionImage then
		return selectionImage
	end
	local frame = Instance.new("Frame")
	frame.Name = "UIKitSelection"
	frame.BackgroundTransparency = 1
	frame.Position = UDim2.fromOffset(-4, -4)
	frame.Size = UDim2.new(1, 8, 1, 8)
	addCorner(frame, UDim.new(0, 16))
	addStroke(frame, WHITE, 4)
	selectionImage = frame
	return frame
end

--[[
	The chunky look. The TextButton itself is an invisible hitbox; inside it:
	  Visual (centred, carries the hover/press UIScale so it grows from the middle)
	    Lip   the full silhouette in a darker tone, with the outline
	    Face  `lip` px shorter, gradient + shine, so a darker band shows along the bottom
]]
local function buildChunky(button: GuiButton, radius: UDim, lip: number): Chunky
	local visual = Instance.new("Frame")
	visual.Name = "Visual"
	visual.AnchorPoint = Vector2.new(0.5, 0.5)
	visual.Position = UDim2.fromScale(0.5, 0.5)
	visual.Size = UDim2.fromScale(1, 1)
	visual.BackgroundTransparency = 1
	visual.BorderSizePixel = 0

	local press = Instance.new("UIScale")
	press.Name = "PressScale"
	press.Parent = visual

	local lipFrame = Instance.new("Frame")
	lipFrame.Name = "Lip"
	lipFrame.Size = UDim2.fromScale(1, 1)
	lipFrame.BorderSizePixel = 0
	lipFrame.ZIndex = 1
	addCorner(lipFrame, radius)
	local lipStroke = addStroke(lipFrame, Colors.Ink, UIKit.Theme.StrokeThickness)
	lipFrame.Parent = visual

	local face = Instance.new("Frame")
	face.Name = "Face"
	face.Size = UDim2.new(1, 0, 1, -lip)
	face.BackgroundColor3 = WHITE
	face.BorderSizePixel = 0
	face.ZIndex = 2
	addCorner(face, radius)
	local gradient = addGradient(face, WHITE, WHITE)
	local shineRadius = if radius.Scale > 0 then radius else UDim.new(0, math.max(4, radius.Offset - 4))
	local shine = addShine(face, shineRadius, 5, 0.42, 0.5)
	face.Parent = visual

	visual.Parent = button
	return {
		Visual = visual,
		Press = press,
		Lip = lipFrame,
		LipStroke = lipStroke,
		Face = face,
		FaceGradient = gradient,
		Shine = shine,
	}
end

local function paintChunky(parts: Chunky, color: Color3, disabled: boolean)
	local base = if disabled then Colors.Disabled else color
	parts.FaceGradient.Color = ColorSequence.new(lighten(base, 0.32), base)
	parts.Lip.BackgroundColor3 = darken(base, 0.4)
	parts.LipStroke.Color = darken(base, 0.7)
	parts.Shine.Visible = not disabled
end

local function isPressInput(input: InputObject): boolean
	local t = input.UserInputType
	return t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch or input.KeyCode == Enum.KeyCode.ButtonA
end

-- Hover / press / click behaviour shared by Button and IconButton. Every connection here is on the
-- button's own signals, so it all goes away when the button is destroyed.
local function wireButton(
	button: TextButton,
	parts: Chunky,
	restyle: () -> (),
	onClick: any,
	soundKey: string?
)
	local hovered = false
	local pressed = false
	local busySince: number? = nil

	local function isDisabled(): boolean
		return button:GetAttribute("Disabled") == true
	end

	local function settle()
		local disabled = isDisabled()
		local target = 1
		if not disabled and pressed then
			target = 0.95
		elseif not disabled and hovered then
			target = 1.05
		end
		tween(parts.Press, { Scale = target }, if pressed then 0.06 else 0.14)
		-- The pressed face also loses a little of its shine, like the light shifting on a real key.
		parts.Shine.BackgroundTransparency = if pressed and not disabled then 0.35 else 0
	end

	button.MouseEnter:Connect(function()
		hovered = true
		settle()
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		pressed = false
		settle()
	end)
	button.SelectionGained:Connect(function()
		hovered = true
		settle()
	end)
	button.SelectionLost:Connect(function()
		hovered = false
		pressed = false
		settle()
	end)
	button.InputBegan:Connect(function(input)
		if isPressInput(input) then
			pressed = true
			settle()
		end
	end)
	button.InputEnded:Connect(function(input)
		if isPressInput(input) then
			pressed = false
			-- Touch has no MouseLeave after a tap; don't leave the button stuck at hover size.
			if input.UserInputType == Enum.UserInputType.Touch then
				hovered = false
			end
			settle()
		end
	end)

	button.Activated:Connect(function()
		if isDisabled() then
			-- A little "nope" wobble instead of silently doing nothing.
			parts.Visual.Rotation = 5
			tween(parts.Visual, { Rotation = 0 }, 0.45, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out)
			return
		end
		-- Ignore clicks while the previous OnClick is still yielding (e.g. waiting on the server),
		-- with a safety timeout so a lost request can't lock the button forever.
		if busySince and os.clock() - busySince < 8 then
			return
		end
		if soundKey then
			UIKit.PlaySound(soundKey)
		end
		if type(onClick) == "function" then
			busySince = os.clock()
			safeCall(onClick)
			busySince = nil
		end
	end)

	button:GetAttributeChangedSignal("Disabled"):Connect(function()
		restyle()
		settle()
	end)
	button:GetPropertyChangedSignal("BackgroundColor3"):Connect(restyle)
	button:GetPropertyChangedSignal("TextColor3"):Connect(restyle)
end

local BUTTON_SKIP = {
	Text = true,
	Icon = true,
	Color = true,
	TextColor3 = true,
	TextSize = true,
	Font = true,
	Size = true,
	OnClick = true,
	Sound = true,
	Disabled = true,
	CornerRadius = true,
}

--[[
	Chunky rounded button: gradient face, darker lip, outline, shine. Hover grows 1.05, press 0.95.
	props: Text, Size, Position, AnchorPoint, Color, TextColor3, TextSize, Parent, OnClick, plus
	  Icon (emoji put before Text), Font, Name, LayoutOrder, ZIndex, Visible (any TextButton property),
	  Disabled (initial), Sound (Config.Sounds key, default "Click"; false = silent),
	  CornerRadius (px, default 12; 999 = pill/circle).
	Disabled state: button:SetAttribute("Disabled", true) greys it out and ignores clicks.
	Live restyle: setting button.Text / TextColor3 / TextSize / BackgroundColor3 updates the visuals
	(the TextButton's own text and background are kept invisible).
]]
function UIKit.Button(props: { [string]: any }?): TextButton
	local p: { [string]: any } = props or {}
	local size: UDim2 = p.Size or UDim2.fromOffset(180, 56)
	local height = if size.Y.Scale == 0 and size.Y.Offset > 0 then size.Y.Offset else 56
	local lip = if height >= 40 then 4 else 3
	local textSize = tonumber(p.TextSize) or math.clamp(math.floor(height * 0.44), 16, 34)
	local radiusPx = tonumber(p.CornerRadius) or math.min(UIKit.Theme.Corner, math.floor(height / 2))
	local text = tostring(p.Text or "")
	if p.Icon then
		text = tostring(p.Icon) .. (if text ~= "" then " " .. text else "")
	end

	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.Size = size
	button.AutoButtonColor = false
	button.BackgroundTransparency = 1
	button.BackgroundColor3 = p.Color or Colors.Primary
	button.BorderSizePixel = 0
	button.Text = text
	button.TextTransparency = 1
	button.TextSize = textSize
	button.TextColor3 = p.TextColor3 or Colors.Text
	button.Font = p.Font or Fonts.Title
	button.SelectionImageObject = getSelectionImage()
	local parent = assign(button, p, BUTTON_SKIP)
	if p.Disabled then
		button:SetAttribute("Disabled", true)
	end

	local parts = buildChunky(button, UDim.new(0, radiusPx), lip)

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Size = UDim2.new(1, -14, 1, -6)
	label.BackgroundTransparency = 1
	label.FontFace = button.FontFace
	label.RichText = button.RichText
	label.Text = button.Text
	label.TextSize = textSize
	label.TextScaled = true -- shrinks long text to fit; TextSize is the cap
	label.TextWrapped = true
	label.ZIndex = 2
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = math.clamp(math.floor(textSize), 1, 100)
	limit.MinTextSize = 10
	registerText(label, textSize, limit)
	limit.Parent = label
	addTextStroke(label, textSize)
	label.Parent = parts.Face

	local function restyle()
		local disabled = button:GetAttribute("Disabled") == true
		paintChunky(parts, button.BackgroundColor3, disabled)
		label.TextColor3 = if disabled then Color3.fromRGB(228, 234, 242) else button.TextColor3
	end
	restyle()

	button:GetPropertyChangedSignal("Text"):Connect(function()
		label.Text = button.Text
	end)
	button:GetPropertyChangedSignal("RichText"):Connect(function()
		label.RichText = button.RichText
	end)
	button:GetPropertyChangedSignal("FontFace"):Connect(function()
		label.FontFace = button.FontFace
	end)
	button:GetPropertyChangedSignal("TextSize"):Connect(function()
		limit.MaxTextSize = math.clamp(math.floor(button.TextSize), 1, 100)
	end)
	button:GetPropertyChangedSignal("TextTransparency"):Connect(function()
		if button.TextTransparency ~= 1 then
			button.TextTransparency = 1 -- the visible text is the inner label
		end
	end)

	local soundKey = if p.Sound == false then nil elseif type(p.Sound) == "string" then p.Sound else "Click"
	wireButton(button, parts, restyle, p.OnClick, soundKey)

	if parent then
		button.Parent = parent
	end
	return button
end

local ICON_SKIP = {
	Icon = true,
	Label = true,
	Color = true,
	Size = true,
	OnClick = true,
	Sound = true,
	Disabled = true,
	TextSize = true,
}

--[[
	Square HUD button: a big emoji with a small caption along the bottom.
	props: Icon (emoji), Label (caption, optional), Color, Size (default 84x84), OnClick, plus
	  Position, AnchorPoint, Name, LayoutOrder, ZIndex..., Disabled, Sound (as Button).
	Live changes: button.Text sets the caption, button:SetAttribute("Icon", "🛒") the emoji,
	BackgroundColor3 the colour, SetAttribute("Disabled", true) disables it.
]]
function UIKit.IconButton(props: { [string]: any }?): TextButton
	local p: { [string]: any } = props or {}
	local size: UDim2 = p.Size or UDim2.fromOffset(84, 84)
	local height = if size.Y.Scale == 0 and size.Y.Offset > 0 then size.Y.Offset else 84
	local lip = if height >= 70 then 5 else 4
	local radius = UDim.new(0, math.min(UIKit.Theme.CornerLarge, math.floor(height / 2)))
	local captionSize = math.max(16, math.floor(height * 0.22))

	local button = Instance.new("TextButton")
	button.Name = "IconButton"
	button.Size = size
	button.AutoButtonColor = false
	button.BackgroundTransparency = 1
	button.BackgroundColor3 = p.Color or Colors.Primary
	button.BorderSizePixel = 0
	button.Text = tostring(p.Label or "")
	button.TextTransparency = 1
	button.TextColor3 = Colors.Text
	button.SelectionImageObject = getSelectionImage()
	button:SetAttribute("Icon", tostring(p.Icon or ""))
	local parent = assign(button, p, ICON_SKIP)
	if p.Disabled then
		button:SetAttribute("Disabled", true)
	end

	local parts = buildChunky(button, radius, lip)

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0.5, 0.5)
	icon.BackgroundTransparency = 1
	icon.Font = Fonts.Title
	icon.TextColor3 = WHITE
	icon.ZIndex = 2
	icon.Parent = parts.Face

	local caption = Instance.new("TextLabel")
	caption.Name = "Label"
	caption.AnchorPoint = Vector2.new(0.5, 1)
	caption.Position = UDim2.new(0.5, 0, 1, -3)
	caption.Size = UDim2.new(1, -8, 0, captionSize + 4)
	caption.BackgroundTransparency = 1
	caption.Font = Fonts.Title
	caption.TextSize = captionSize
	caption.TextScaled = true
	caption.ZIndex = 3
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = captionSize
	limit.MinTextSize = 10
	limit.Parent = caption
	addTextStroke(caption, captionSize)
	caption.Parent = parts.Face

	-- The emoji sits higher when there is a caption under it.
	local function layoutContent()
		local text = button.Text
		local hasCaption = text ~= ""
		caption.Text = text
		caption.Visible = hasCaption
		icon.Text = tostring(button:GetAttribute("Icon") or "")
		icon.Position = UDim2.fromScale(0.5, if hasCaption then 0.4 else 0.5)
		icon.Size = UDim2.fromScale(1, if hasCaption then 0.62 else 0.9)
		icon.TextSize = math.floor(height * (if hasCaption then 0.42 else 0.52))
	end
	layoutContent()
	button:GetPropertyChangedSignal("Text"):Connect(layoutContent)
	button:GetAttributeChangedSignal("Icon"):Connect(layoutContent)

	local function restyle()
		local disabled = button:GetAttribute("Disabled") == true
		paintChunky(parts, button.BackgroundColor3, disabled)
		caption.TextColor3 = if disabled then Color3.fromRGB(228, 234, 242) else button.TextColor3
		icon.TextTransparency = if disabled then 0.35 else 0
	end
	restyle()

	local soundKey = if p.Sound == false then nil elseif type(p.Sound) == "string" then p.Sound else "Click"
	wireButton(button, parts, restyle, p.OnClick, soundKey)

	if parent then
		button.Parent = parent
	end
	return button
end

-- Convenience wrappers for the attribute/property conventions above.
function UIKit.SetDisabled(button: Instance, disabled: boolean)
	button:SetAttribute("Disabled", disabled == true)
end

function UIKit.SetButtonColor(button: GuiObject, color: Color3)
	button.BackgroundColor3 = color
end

----------------------------------------------------------------------------------------------------
-- Windows
----------------------------------------------------------------------------------------------------
type WindowRecord = {
	Name: string,
	Frame: Frame,
	Content: Frame,
	Scale: UIScale,
	Veil: Frame,
	Shadow: Frame,
	CloseButton: TextButton,
	BaseSize: Vector2,
	Fit: number,
	Token: number,
	Animating: boolean,
	Closing: boolean,
	AutoPlace: boolean,
	PlacedAt: UDim2?,
	LinkedName: string?,
	OnClose: any,
}

type WindowHandlers = {
	Open: ((arg: any?) -> ())?,
	Close: (() -> ())?,
	Frame: GuiObject?, -- optional: the frame to show/hide if it isn't a UIKit.Window of the same name
}

local windowRecords: { [string]: WindowRecord } = {} -- by UIKit.Window Name
local linkedRecords: { [string]: WindowRecord } = {} -- registered name -> window it turned out to show
local registry: { [string]: WindowHandlers } = {}
local openName: string? = nil

-- Fired with the open window's name, or nil when every window is closed.
UIKit.WindowChanged = Util.Signal.new()

local function toVector2(value: any, fallback: Vector2): Vector2
	if typeof(value) == "Vector2" then
		return value
	end
	if typeof(value) == "UDim2" then
		-- Scale parts are resolved against the reference canvas.
		return Vector2.new(value.X.Offset + value.X.Scale * REF_W, value.Y.Offset + value.Y.Scale * REF_H)
	end
	return fallback
end

-- Centre the window in the area below the topbar and shrink it (never grow) until it fits.
local function layoutWindow(rec: WindowRecord)
	local canvas = canvasSize()
	local inset = insetPx / scale
	local availW = canvas.X - WINDOW_MARGIN * 2
	local availH = canvas.Y - inset - WINDOW_MARGIN * 2
	rec.Fit = math.clamp(math.min(availW / rec.BaseSize.X, availH / rec.BaseSize.Y), 0.35, 1)
	if rec.AutoPlace then
		if rec.PlacedAt and rec.Frame.Position ~= rec.PlacedAt then
			-- The owner moved it themselves: stop managing its position.
			rec.AutoPlace = false
		else
			local pos = UDim2.new(0.5, 0, 0.5, math.floor(inset / 2 + 0.5))
			rec.Frame.Position = pos
			rec.PlacedAt = pos
		end
	end
	if not rec.Animating then
		rec.Scale.Scale = rec.Fit
	end
end

table.insert(layoutHooks, function()
	for _, rec in windowRecords do
		layoutWindow(rec)
	end
end)

-- Open: pop from 0.9 to full size (Back ease) while a panel-coloured veil over the contents fades
-- away, so the window "materialises" instead of blinking in.
local function showRecord(rec: WindowRecord)
	rec.Token += 1
	local token = rec.Token
	layoutWindow(rec)
	rec.Closing = false
	rec.Animating = true
	rec.Frame.Visible = true
	rec.Scale.Scale = rec.Fit * 0.9
	rec.Veil.Visible = true
	rec.Veil.BackgroundTransparency = 0
	rec.Shadow.BackgroundTransparency = 1
	local pop = tween(rec.Scale, { Scale = rec.Fit }, 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	tween(rec.Veil, { BackgroundTransparency = 1 }, 0.22)
	tween(rec.Shadow, { BackgroundTransparency = WINDOW_SHADOW_T }, 0.25)
	pop.Completed:Once(function()
		if rec.Token ~= token then
			return
		end
		rec.Animating = false
		rec.Veil.Visible = false
		rec.Scale.Scale = rec.Fit -- the layout may have changed mid-animation
	end)
end

-- Close: a quick shrink, then hide. Re-opening mid-animation cancels the hide (token check).
local function hideRecord(rec: WindowRecord)
	rec.Token += 1
	local token = rec.Token
	if not rec.Frame.Visible then
		rec.Animating = false
		rec.Closing = false
		rec.Veil.Visible = false
		rec.Scale.Scale = rec.Fit
		return
	end
	rec.Closing = true
	rec.Animating = true
	rec.Veil.Visible = true
	local shrink = tween(rec.Scale, { Scale = rec.Fit * 0.9 }, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tween(rec.Veil, { BackgroundTransparency = 0.2 }, 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	tween(rec.Shadow, { BackgroundTransparency = 1 }, 0.12)
	shrink.Completed:Once(function()
		if rec.Token ~= token then
			return
		end
		rec.Frame.Visible = false
		rec.Closing = false
		rec.Animating = false
		rec.Veil.Visible = false
		rec.Scale.Scale = rec.Fit
	end)
end

local function callHandler(name: string, key: string, arg: any?)
	local handlers = registry[name]
	local fn = handlers and (handlers :: any)[key]
	if type(fn) ~= "function" then
		return
	end
	local ok, err = xpcall(fn, debug.traceback, arg)
	if not ok then
		warn(string.format("[UIKit] window %s %s() failed:\n%s", name, key, tostring(err)))
	end
end

local function explicitFrame(name: string): GuiObject?
	local handlers = registry[name]
	local frame = handlers and handlers.Frame
	if typeof(frame) == "Instance" and frame:IsA("GuiObject") then
		return frame
	end
	return nil
end

local function recordFor(name: string): WindowRecord?
	local frame = explicitFrame(name)
	if frame then
		for _, rec in windowRecords do
			if rec.Frame == frame then
				return rec
			end
		end
	end
	return windowRecords[name] or linkedRecords[name]
end

local function selectFirstButton(rec: WindowRecord)
	if not UIKit.IsGamepad() then
		return
	end
	local target: GuiObject = rec.CloseButton
	for _, d in rec.Content:GetDescendants() do
		if d:IsA("GuiButton") and d.Visible and d.Selectable then
			target = d
			break
		end
	end
	pcall(function()
		GuiService.SelectedObject = target
	end)
end

local function clearSelectionInside(frame: GuiObject)
	pcall(function()
		local selected = GuiService.SelectedObject
		if selected and selected:IsDescendantOf(frame) then
			GuiService.SelectedObject = nil
		end
	end)
end

local function closeOpenWindow(fireSignal: boolean)
	local name = openName
	if not name then
		return
	end
	openName = nil
	callHandler(name, "Close")
	local rec = recordFor(name)
	if rec then
		clearSelectionInside(rec.Frame)
		hideRecord(rec)
		if type(rec.OnClose) == "function" then
			task.spawn(safeCall, rec.OnClose)
		end
	else
		local frame = explicitFrame(name)
		if frame then
			frame.Visible = false
		end
	end
	if fireSignal then
		UIKit.WindowChanged:Fire(nil)
	end
end

--[[
	handlers = { Open = function(arg) end, Close = function() end, Frame = optionalGuiObject }
	If a UIKit.Window has the same Name (or is handlers.Frame), UIKit shows/animates/hides it for you.
	Keep Open quick: it runs before the open animation starts. task.spawn anything slow.
]]
function UIKit.RegisterWindow(name: string, handlers: WindowHandlers)
	if type(name) ~= "string" or type(handlers) ~= "table" then
		warn("[UIKit] RegisterWindow needs (name: string, handlers: table)")
		return
	end
	registry[name] = handlers
end

-- Closes any other open window first, then runs Open(arg) and plays the open animation.
-- Opening the window that is already open just calls Open(arg) again (e.g. switching eggs).
function UIKit.OpenWindow(name: string, arg: any?)
	ensureInit()
	if type(name) ~= "string" then
		return
	end
	if not registry[name] and not windowRecords[name] then
		warn("[UIKit] OpenWindow: no window called " .. name)
		return
	end
	if openName == name then
		callHandler(name, "Open", arg)
		return
	end
	closeOpenWindow(false)
	openName = name

	-- Note which windows are visible now, so a window that the Open handler shows itself (registered
	-- under a different name than its UIKit.Window) still gets linked and animated.
	local wasVisible: { [WindowRecord]: boolean } = {}
	for _, rec in windowRecords do
		wasVisible[rec] = rec.Frame.Visible
	end
	callHandler(name, "Open", arg)
	if openName ~= name then
		return -- the handler closed it or opened something else
	end

	local rec = recordFor(name)
	if not rec then
		for _, candidate in windowRecords do
			if candidate.Frame.Visible and not wasVisible[candidate] then
				rec = candidate
				candidate.LinkedName = name
				linkedRecords[name] = candidate
				break
			end
		end
	end
	if rec then
		showRecord(rec)
		selectFirstButton(rec)
	else
		local frame = explicitFrame(name)
		if frame then
			frame.Visible = true
		end
	end
	UIKit.WindowChanged:Fire(name)
end

-- nil closes whatever is open; a name only closes that window if it is the open one.
function UIKit.CloseWindow(name: string?)
	if openName == nil or (name ~= nil and name ~= openName) then
		return
	end
	closeOpenWindow(true)
end

function UIKit.ToggleWindow(name: string, arg: any?)
	if openName ~= nil and openName == name then
		UIKit.CloseWindow(name)
	else
		UIKit.OpenWindow(name, arg)
	end
end

-- nil = is any window open?
function UIKit.IsWindowOpen(name: string?): boolean
	if name == nil then
		return openName ~= nil
	end
	return openName == name
end

local function onCloseClicked(rec: WindowRecord)
	local current = openName
	if current and (current == rec.Name or current == rec.LinkedName or recordFor(current) == rec) then
		UIKit.CloseWindow()
	else
		-- Not driven by the window system (or already closing): just hide it.
		clearSelectionInside(rec.Frame)
		hideRecord(rec)
		if type(rec.OnClose) == "function" then
			task.spawn(safeCall, rec.OnClose)
		end
	end
end

local WINDOW_SKIP = {
	Name = true,
	Title = true,
	Icon = true,
	Size = true,
	OnClose = true,
	Position = true,
	AnchorPoint = true,
}

--[[
	Window chrome: navy glass panel, aqua title banner with icon + title, round red X, padded content.
	props: Name, Title, Icon (emoji), Size (Vector2 in canvas px, default 760x500), Parent (a Root),
	  OnClose (called after the window closes, however it was closed), optional Position/AnchorPoint
	  (turns off auto-centring), any other Frame property.
	Returns (window, content). Hidden by default. Auto-centred below TopInset and scaled down to fit
	small canvases. window:SetAttribute("Title" / "Icon", ...) updates the banner.
]]
function UIKit.Window(props: { [string]: any }?): (Frame, Frame)
	ensureInit()
	local p: { [string]: any } = props or {}
	local name = tostring(p.Name or "Window")
	local baseSize = toVector2(p.Size, Vector2.new(760, 500))
	baseSize = Vector2.new(math.max(160, baseSize.X), math.max(120, baseSize.Y))

	local window = Instance.new("Frame")
	window.Name = name
	window.AnchorPoint = p.AnchorPoint or Vector2.new(0.5, 0.5)
	window.Size = UDim2.fromOffset(baseSize.X, baseSize.Y)
	window.BackgroundTransparency = 1
	window.BorderSizePixel = 0
	window.ZIndex = 20
	window.Visible = false
	window:SetAttribute("Title", tostring(p.Title or name))
	window:SetAttribute("Icon", tostring(p.Icon or ""))

	local winScale = Instance.new("UIScale")
	winScale.Name = "WindowScale"
	winScale.Parent = window

	local shadow = Instance.new("Frame")
	shadow.Name = "Shadow"
	shadow.Position = UDim2.fromOffset(0, 8)
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.BackgroundColor3 = Colors.Ink
	shadow.BackgroundTransparency = WINDOW_SHADOW_T
	shadow.BorderSizePixel = 0
	shadow.ZIndex = 1
	addCorner(shadow, UDim.new(0, UIKit.Theme.CornerLarge + 2))
	shadow.Parent = window

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = WHITE
	panel.BorderSizePixel = 0
	panel.Active = true -- swallow clicks so they never reach the world (or the spray) behind it
	panel.ZIndex = 2
	addCorner(panel, UDim.new(0, UIKit.Theme.CornerLarge))
	addGradient(panel, Colors.Panel, Colors.PanelDark)
	addStroke(panel, Colors.Ink, UIKit.Theme.StrokeThickness)
	panel.Parent = window

	-- A faint inner rim makes the panel read as glossy glass rather than a flat box.
	local rim = Instance.new("Frame")
	rim.Name = "Rim"
	rim.Position = UDim2.fromOffset(3, 3)
	rim.Size = UDim2.new(1, -6, 1, -6)
	rim.BackgroundTransparency = 1
	rim.ZIndex = 1
	addCorner(rim, UDim.new(0, UIKit.Theme.CornerLarge - 3))
	addStroke(rim, WHITE, 1.5, 0.84)
	rim.Parent = panel

	addDecorBubble(panel, UDim2.new(1, -48, 1, -46), 66, 1)
	addDecorBubble(panel, UDim2.new(1, -100, 1, -26), 24, 1)
	addDecorBubble(panel, UDim2.new(0, 34, 1, -36), 40, 1)

	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Position = UDim2.fromOffset(10, 10)
	titleBar.Size = UDim2.new(1, -20, 0, WINDOW_TITLE_H)
	titleBar.BackgroundColor3 = WHITE
	titleBar.BorderSizePixel = 0
	titleBar.ZIndex = 3
	addCorner(titleBar, UDim.new(0, UIKit.Theme.Corner))
	addGradient(titleBar, lighten(Colors.Primary, 0.28), Colors.Primary:Lerp(Colors.PrimaryDark, 0.3))
	addStroke(titleBar, darken(Colors.PrimaryDark, 0.55), 2.5)
	addShine(titleBar, UDim.new(0, UIKit.Theme.Corner - 3), 6, 0.45, 0.45)
	titleBar.Parent = panel

	local badge = Instance.new("Frame")
	badge.Name = "IconBadge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Position = UDim2.new(0, 8, 0.5, 0)
	badge.Size = UDim2.fromOffset(42, 42)
	badge.BackgroundColor3 = WHITE
	badge.BackgroundTransparency = 0.25
	badge.BorderSizePixel = 0
	badge.ZIndex = 2
	addCorner(badge, UDim.new(0.5, 0))
	addStroke(badge, darken(Colors.PrimaryDark, 0.35), 2)
	badge.Parent = titleBar

	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "Icon"
	iconLabel.Size = UDim2.fromScale(1, 1)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Font = Fonts.Title
	iconLabel.TextSize = 26
	iconLabel.ZIndex = 2
	iconLabel.Parent = badge

	local titleLabel = UIKit.Label({
		Name = "Title",
		AnchorPoint = Vector2.new(0, 0.5),
		TextSize = 30,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 2,
		StrokeThickness = 2.5,
		Parent = titleBar,
	})

	local rec: WindowRecord
	local closeButton = UIKit.Button({
		Name = "Close",
		Text = "X",
		Size = UDim2.fromOffset(42, 42),
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -7, 0.5, 0),
		Color = Colors.Bad,
		CornerRadius = 999,
		TextSize = 26,
		ZIndex = 3,
		Parent = titleBar,
		OnClick = function()
			if rec then
				onCloseClicked(rec)
			end
		end,
	})

	local function applyTitle()
		local icon = tostring(window:GetAttribute("Icon") or "")
		local hasIcon = icon ~= ""
		badge.Visible = hasIcon
		iconLabel.Text = icon
		local left = if hasIcon then 60 else 16
		titleLabel.Position = UDim2.new(0, left, 0.5, 0)
		titleLabel.Size = UDim2.new(1, -(left + 58), 0, 38)
		titleLabel.Text = tostring(window:GetAttribute("Title") or "")
	end
	applyTitle()
	window:GetAttributeChangedSignal("Title"):Connect(applyTitle)
	window:GetAttributeChangedSignal("Icon"):Connect(applyTitle)
	-- If the owner resizes the window later, fit against the new size.
	window:GetPropertyChangedSignal("Size"):Connect(function()
		if rec then
			local size = toVector2(window.Size, rec.BaseSize)
			rec.BaseSize = Vector2.new(math.max(160, size.X), math.max(120, size.Y))
			layoutWindow(rec)
		end
	end)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Position = UDim2.fromOffset(0, WINDOW_TITLE_H + 16)
	content.Size = UDim2.new(1, 0, 1, -(WINDOW_TITLE_H + 16))
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.ZIndex = 4
	local padding = UIKit.Padding(content, 16)
	padding.PaddingTop = UDim.new(0, 4)
	content.Parent = panel

	local veil = Instance.new("Frame")
	veil.Name = "Veil"
	veil.Size = UDim2.fromScale(1, 1)
	veil.BackgroundColor3 = Colors.Panel
	veil.BackgroundTransparency = 1
	veil.BorderSizePixel = 0
	veil.Visible = false
	veil.ZIndex = 50
	addCorner(veil, UDim.new(0, UIKit.Theme.CornerLarge))
	veil.Parent = window

	rec = {
		Name = name,
		Frame = window,
		Content = content,
		Scale = winScale,
		Veil = veil,
		Shadow = shadow,
		CloseButton = closeButton,
		BaseSize = baseSize,
		Fit = 1,
		Token = 0,
		Animating = false,
		Closing = false,
		AutoPlace = p.Position == nil,
		PlacedAt = nil,
		LinkedName = nil,
		OnClose = p.OnClose,
	}
	if p.Position ~= nil then
		window.Position = p.Position
	end

	local previous = windowRecords[name]
	if previous and previous.Frame.Parent ~= nil then
		warn("[UIKit] two windows are named " .. name .. "; the newest one wins")
	end
	windowRecords[name] = rec

	window.Destroying:Connect(function()
		if windowRecords[name] == rec then
			windowRecords[name] = nil
		end
		for key, linked in linkedRecords do
			if linked == rec then
				linkedRecords[key] = nil
			end
		end
		if openName and (openName == rec.Name or openName == rec.LinkedName) then
			openName = nil
			UIKit.WindowChanged:Fire(nil)
		end
	end)

	local parent = assign(window, p, WINDOW_SKIP)
	layoutWindow(rec)
	if parent then
		window.Parent = parent
	end
	return window, content
end

-- Convenience for window:SetAttribute("Title"/"Icon", ...).
function UIKit.SetWindowTitle(window: Instance, title: string, icon: string?)
	window:SetAttribute("Title", tostring(title))
	if icon ~= nil then
		window:SetAttribute("Icon", tostring(icon))
	end
end

----------------------------------------------------------------------------------------------------
-- Toasts
----------------------------------------------------------------------------------------------------
type ToastFade = { Inst: Instance, Prop: string, Shown: number }
type ToastRecord = {
	Frame: Frame,
	Text: string,
	Kind: string,
	Height: number,
	Alive: boolean,
	Token: number,
	Duration: number,
	Fades: { ToastFade },
}

local TOAST_STYLES = {
	Info = { Color = Colors.Primary, Icon = "🧼" },
	Good = { Color = Colors.Good, Icon = "✨" },
	Bad = { Color = Colors.Bad, Icon = "⚠️" },
	Warning = { Color = Colors.Warning, Icon = "⚠️" },
}

local toastHolder: Frame? = nil
local toasts: { ToastRecord } = {} -- newest first

local function toastTop(): number
	return math.floor(insetPx / scale + 12)
end

local function getToastHolder(): Frame
	if toastHolder and toastHolder:IsDescendantOf(game) then
		return toastHolder
	end
	table.clear(toasts) -- anything from a lost holder is gone with it
	local _, root = UIKit.CreateScreen("UIKitToasts", 100)
	local holder = Instance.new("Frame")
	holder.Name = "Toasts"
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, toastTop())
	holder.Size = UDim2.fromOffset(10, 10)
	holder.BackgroundTransparency = 1
	holder.Parent = root
	toastHolder = holder
	return holder
end

table.insert(layoutHooks, function()
	if toastHolder then
		toastHolder.Position = UDim2.new(0.5, 0, 0, toastTop())
	end
end)

local function fadeToast(t: ToastRecord, hidden: boolean, time: number)
	for _, f in t.Fades do
		tween(f.Inst, { [f.Prop] = if hidden then 1 else f.Shown }, time)
	end
end

local function stackToasts()
	local y = 0
	for _, t in toasts do
		tween(t.Frame, { Position = UDim2.new(0.5, 0, 0, y) }, 0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		y += t.Height + TOAST_GAP
	end
end

local function dismissToast(t: ToastRecord, fast: boolean)
	if not t.Alive then
		return
	end
	t.Alive = false
	local i = table.find(toasts, t)
	if i then
		table.remove(toasts, i)
	end
	local time = if fast then 0.12 else 0.25
	fadeToast(t, true, time)
	tween(t.Frame, { Position = t.Frame.Position - UDim2.fromOffset(0, 14) }, time)
	task.delay(time + 0.05, function()
		t.Frame:Destroy()
	end)
	stackToasts()
end

local function armToast(t: ToastRecord)
	t.Token += 1
	local token = t.Token
	task.delay(t.Duration, function()
		if t.Alive and t.Token == token then
			dismissToast(t, false)
		end
	end)
end

-- A burst of confetti across the whole screen (a pass bought, something big unlocked). Purely
-- cosmetic; every piece cleans itself up after it lands.
local CONFETTI_COLORS = {
	Color3.fromRGB(255, 90, 110),
	Color3.fromRGB(255, 200, 60),
	Color3.fromRGB(90, 220, 140),
	Color3.fromRGB(80, 170, 255),
	Color3.fromRGB(190, 120, 255),
	Color3.fromRGB(255, 255, 255),
}
function UIKit.Confetti(pieces: number?)
	local player = Players.LocalPlayer
	local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "Confetti"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100
	gui.Parent = playerGui
	local count = pieces or 90
	for _ = 1, count do
		local piece = Instance.new("Frame")
		local w = math.random(8, 14)
		piece.Size = UDim2.fromOffset(w, math.floor(w * (0.5 + math.random())))
		piece.AnchorPoint = Vector2.new(0.5, 0.5)
		piece.Position = UDim2.new(math.random(), 0, 0, -math.random(10, 200))
		piece.Rotation = math.random(0, 360)
		piece.BackgroundColor3 = CONFETTI_COLORS[math.random(1, #CONFETTI_COLORS)]
		piece.BorderSizePixel = 0
		piece.Parent = gui
		local fall = 1.6 + math.random() * 1.6
		TweenService:Create(piece, TweenInfo.new(fall, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = UDim2.new(piece.Position.X.Scale + (math.random() - 0.5) * 0.25, 0, 1.1, 0),
			Rotation = piece.Rotation + math.random(-540, 540),
		}):Play()
	end
	task.delay(3.5, function()
		gui:Destroy()
	end)
	UIKit.PlaySound("Sparkle")
end

-- Pill notification, top-centre below the topbar. Newest on top, max 4, ~3 s each (longer for long
-- messages). Repeating a message that is still showing restarts its timer instead of stacking.
function UIKit.Toast(text: string, kind: string?)
	ensureInit()
	local message = tostring(if text == nil then "" else text)
	if message == "" then
		return
	end
	local kindName = if type(kind) == "string" and (TOAST_STYLES :: any)[kind] then kind else "Info"
	local style = (TOAST_STYLES :: any)[kindName]

	for _, t in toasts do
		if t.Alive and t.Text == message and t.Kind == kindName then
			armToast(t)
			UIKit.Bounce(t.Frame)
			return
		end
	end

	local holder = getToastHolder()
	local okSize, bounds = pcall(function()
		return TextService:GetTextSize(message, TOAST_TEXT_SIZE, Fonts.Title, Vector2.new(TOAST_MAX_TEXT_W, 1000))
	end)
	local textW, textH
	if okSize and typeof(bounds) == "Vector2" then
		textW, textH = math.ceil(bounds.X) + 8, math.ceil(bounds.Y)
	else
		textW, textH = math.min(TOAST_MAX_TEXT_W, #message * 11), TOAST_TEXT_SIZE
	end
	local height = math.max(50, textH + 22)
	local width = 16 + 30 + 10 + textW + 22
	local multiline = textH > TOAST_TEXT_SIZE * 1.5

	local frame = Instance.new("Frame")
	frame.Name = "Toast"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, -height - TOAST_GAP)
	frame.Size = UDim2.fromOffset(width, height)
	frame.BackgroundColor3 = WHITE
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	local radius = UDim.new(0, if multiline then 18 else math.floor(height / 2))
	addCorner(frame, radius)
	addGradient(frame, lighten(style.Color, 0.25), style.Color)
	local stroke = addStroke(frame, darken(style.Color, 0.6), UIKit.Theme.StrokeThickness, 1)
	local shine = addShine(frame, if multiline then UDim.new(0, 14) else radius, 10, 0.45, 0.45)
	shine.BackgroundTransparency = 1

	local icon = Instance.new("TextLabel")
	icon.Name = "Icon"
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.new(0, 16, 0.5, 0)
	icon.Size = UDim2.fromOffset(30, 30)
	icon.BackgroundTransparency = 1
	icon.Font = Fonts.Title
	icon.Text = style.Icon
	icon.TextSize = 26
	icon.TextTransparency = 1
	icon.ZIndex = 2
	icon.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.Position = UDim2.new(0, 56, 0.5, 0)
	label.Size = UDim2.fromOffset(textW, textH + 4)
	label.BackgroundTransparency = 1
	label.Font = Fonts.Title
	label.Text = message
	label.TextSize = TOAST_TEXT_SIZE
	label.TextColor3 = Colors.Text
	label.TextWrapped = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTransparency = 1
	label.ZIndex = 2
	local labelStroke = addTextStroke(label, TOAST_TEXT_SIZE, nil, nil, 1)
	label.Parent = frame

	local t: ToastRecord = {
		Frame = frame,
		Text = message,
		Kind = kindName,
		Height = height,
		Alive = true,
		Token = 0,
		Duration = math.clamp(3 + (utf8.len(message) or #message) / 40, 3, 6),
		Fades = {
			{ Inst = frame, Prop = "BackgroundTransparency", Shown = 0 },
			{ Inst = stroke, Prop = "Transparency", Shown = 0 },
			{ Inst = shine, Prop = "BackgroundTransparency", Shown = 0 },
			{ Inst = icon, Prop = "TextTransparency", Shown = 0 },
			{ Inst = label, Prop = "TextTransparency", Shown = 0 },
			{ Inst = labelStroke, Prop = "Transparency", Shown = 0 },
		},
	}
	frame.Parent = holder

	table.insert(toasts, 1, t)
	while #toasts > TOAST_MAX do
		dismissToast(toasts[#toasts], true)
	end
	fadeToast(t, false, 0.2)
	stackToasts()
	armToast(t)
end

----------------------------------------------------------------------------------------------------
-- Motion
----------------------------------------------------------------------------------------------------

-- TweenService:Create + Play. Defaults: 0.25 s, Quad, Out.
function UIKit.Tween(
	inst: Instance,
	props: { [string]: any },
	time: number?,
	style: Enum.EasingStyle?,
	dir: Enum.EasingDirection?
): Tween
	return tween(inst, props, time, style, dir)
end

-- Quick 1 -> 1.15 -> 1 pop. Uses the gui's UIScale (or creates "BounceScale") and returns to
-- whatever scale it had, so bouncing a scaled element is safe. Spamming it restarts the pop.
function UIKit.Bounce(gui: GuiObject)
	if typeof(gui) ~= "Instance" or not gui:IsA("GuiObject") then
		return
	end
	local found = gui:FindFirstChild("BounceScale")
	if not (found and found:IsA("UIScale")) then
		found = gui:FindFirstChildOfClass("UIScale")
	end
	local uiScale: UIScale
	if found and found:IsA("UIScale") then
		uiScale = found
	else
		uiScale = Instance.new("UIScale")
		uiScale.Name = "BounceScale"
		uiScale.Parent = gui
	end

	local base = uiScale:GetAttribute("BounceBase")
	if type(base) ~= "number" then
		base = uiScale.Scale
		uiScale:SetAttribute("BounceBase", base)
	end
	local baseScale = base :: number
	local token = (tonumber(uiScale:GetAttribute("BounceToken")) or 0) + 1
	uiScale:SetAttribute("BounceToken", token)

	local up = tween(uiScale, { Scale = baseScale * 1.15 }, 0.08)
	up.Completed:Once(function()
		if uiScale:GetAttribute("BounceToken") ~= token then
			return
		end
		local down = tween(uiScale, { Scale = baseScale }, 0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		down.Completed:Once(function()
			if uiScale:GetAttribute("BounceToken") == token then
				uiScale:SetAttribute("BounceBase", nil)
			end
		end)
	end)
end

----------------------------------------------------------------------------------------------------
-- Progress bar
----------------------------------------------------------------------------------------------------
export type ProgressBar = {
	Frame: Frame,
	Fill: Frame,
	Label: TextLabel,
	Set: (fraction: number, text: string?) -> (),
	SetColor: (color: Color3) -> (),
}

local BAR_SKIP = { Size = true, Color = true, Text = true, TextSize = true, Value = true, BackColor = true }

--[[
	Rounded pill bar with a glossy gradient fill and centred outlined text.
	props: Size, Position, AnchorPoint, Color, Parent, plus Text, TextSize, Value (initial 0..1),
	  BackColor (track colour), Name, ZIndex, LayoutOrder...
	Returns { Frame, Fill, Label, Set = (fraction, text?) -> (), SetColor = (Color3) -> () }.
	Set animates the fill; text nil keeps the current text. bar:Set(...) works too.
]]
function UIKit.ProgressBar(props: { [string]: any }?): ProgressBar
	local p: { [string]: any } = props or {}
	local size: UDim2 = p.Size or UDim2.fromOffset(300, 34)
	local height = if size.Y.Scale == 0 and size.Y.Offset > 0 then size.Y.Offset else 34
	local color: Color3 = p.Color or Colors.Primary

	local track = Instance.new("Frame")
	track.Name = "ProgressBar"
	track.Size = size
	track.BackgroundColor3 = p.BackColor or Colors.PanelDark
	track.BorderSizePixel = 0
	addCorner(track, UDim.new(0.5, 0))
	addStroke(track, Colors.Ink, UIKit.Theme.StrokeThickness)
	local parent = assign(track, p, BAR_SKIP)

	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.Position = UDim2.fromOffset(3, 3)
	inner.Size = UDim2.new(1, -6, 1, -6)
	inner.BackgroundTransparency = 1
	inner.BorderSizePixel = 0
	inner.ZIndex = 1
	inner.Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = WHITE
	fill.BorderSizePixel = 0
	fill.Visible = false
	addCorner(fill, UDim.new(0.5, 0))
	local fillGradient = addGradient(fill, lighten(color, 0.3), color)
	addShine(fill, UDim.new(0.5, 0), 4, 0.45, 0.55)
	fill.Parent = inner

	local label = UIKit.Label({
		Name = "Text",
		Text = p.Text or "",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -16, 1, 0),
		TextSize = tonumber(p.TextSize) or math.max(16, math.floor(height * 0.56)),
		ZIndex = 2,
		Parent = track,
	})

	-- A pill narrower than it is tall squashes into an oval, so the fill never gets narrower than
	-- a circle: width = minFrac + (1 - minFrac) * fraction, where minFrac = height / width.
	local current = 0
	local hideToken = 0
	local lastRatio = -1
	local function widthScale(f: number): number
		local abs = inner.AbsoluteSize
		local minFrac = if abs.X > 0 then math.clamp(abs.Y / abs.X, 0, 1) else 0
		return minFrac + (1 - minFrac) * f
	end
	local function render(animate: boolean)
		hideToken += 1
		local token = hideToken
		local shown = current > 0.0005
		local goal = UDim2.fromScale(widthScale(current), 1)
		if not animate then
			fill.Size = goal
			fill.Visible = shown
			return
		end
		if shown and not fill.Visible then
			fill.Size = UDim2.fromScale(widthScale(0), 1) -- grow out of a dot, not from a stale width
			fill.Visible = true
		end
		local tw = tween(fill, { Size = goal }, 0.25)
		if not shown then
			tw.Completed:Once(function()
				if token == hideToken then
					fill.Visible = false
				end
			end)
		end
	end
	inner:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		local abs = inner.AbsoluteSize
		local ratio = if abs.X > 0 then abs.Y / abs.X else 0
		if math.abs(ratio - lastRatio) > 0.001 then
			lastRatio = ratio
			render(false)
		end
	end)

	local bar = {} :: any
	bar.Frame = track
	bar.Fill = fill
	bar.Label = label
	bar.Set = function(a: any, b: any, c: any)
		local fraction, text = a, b
		if a == bar then -- called as bar:Set(...)
			fraction, text = b, c
		end
		local f = tonumber(fraction) or 0
		if f ~= f then
			f = 0
		end
		current = math.clamp(f, 0, 1)
		render(true)
		if text ~= nil then
			label.Text = tostring(text)
		end
	end
	bar.SetColor = function(a: any, b: any)
		local c = if a == bar then b else a
		if typeof(c) == "Color3" then
			fillGradient.Color = ColorSequence.new(lighten(c, 0.3), c)
		end
	end

	local initial = tonumber(p.Value) or 0
	current = if initial ~= initial then 0 else math.clamp(initial, 0, 1)
	render(false)
	if parent then
		track.Parent = parent
	end
	return bar :: ProgressBar
end

----------------------------------------------------------------------------------------------------
-- 3D previews (ViewportFrame)
----------------------------------------------------------------------------------------------------
type ViewState = {
	Camera: Camera,
	Model: Instance?,
	Center: Vector3,
	Radius: number,
	Yaw: number,
	Pitch: number,
	Zoom: number,
	SpinSpeed: number,
}

local viewStates: { [ViewportFrame]: ViewState } = {}
local spinning: { [ViewportFrame]: ViewState } = {}
local spinConnection: RBXScriptConnection? = nil

-- Orbit the camera around the model's bounding sphere so it always fits, whatever the frame's
-- aspect ratio. Yaw 0 looks at the model's front (-Z, the way pets face).
local function frameCamera(vpf: ViewportFrame, st: ViewState)
	local abs = vpf.AbsoluteSize
	local aspect = if abs.X > 0 and abs.Y > 0 then abs.X / abs.Y else 1
	local halfV = math.rad(st.Camera.FieldOfView) / 2
	local halfH = math.atan(math.tan(halfV) * aspect)
	local half = math.min(halfV, halfH)
	local distance = st.Radius / math.sin(half) * st.Zoom
	local rotation = CFrame.Angles(0, st.Yaw, 0) * CFrame.Angles(st.Pitch, 0, 0)
	local eye = st.Center + rotation:VectorToWorldSpace(Vector3.new(0, 0, -distance))
	st.Camera.CFrame = CFrame.lookAt(eye, st.Center)
end

-- One RenderStepped connection drives every spinning viewport; it exists only while one does.
local function updateSpinLoop()
	if next(spinning) == nil then
		if spinConnection then
			spinConnection:Disconnect()
			spinConnection = nil
		end
		return
	end
	if spinConnection then
		return
	end
	spinConnection = RunService.RenderStepped:Connect(function(dt: number)
		for vpf, st in spinning do
			if vpf.Visible and vpf.Parent then
				st.Yaw = (st.Yaw + dt * st.SpinSpeed) % (math.pi * 2)
				frameCamera(vpf, st)
			end
		end
	end)
end

-- Swap the model shown in a UIKit.Viewport (cloned unless noClone). nil clears it.
function UIKit.SetViewportModel(vpf: ViewportFrame, model: Instance?, noClone: boolean?)
	local st = viewStates[vpf]
	if not st then
		return
	end
	if st.Model then
		st.Model:Destroy()
		st.Model = nil
	end
	if typeof(model) ~= "Instance" then
		return
	end
	local instance: Instance? = model
	if not noClone then
		local ok, clone = pcall(function()
			return model:Clone()
		end)
		instance = if ok then clone else nil
	end
	if not instance then
		return
	end

	local center, radius = Vector3.zero, 2
	if instance:IsA("Model") then
		local ok, cf, size = pcall(function()
			return (instance :: Model):GetBoundingBox()
		end)
		if ok and typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
			center, radius = cf.Position, math.max(size.Magnitude / 2, 0.25)
		end
	elseif instance:IsA("BasePart") then
		center, radius = instance.Position, math.max(instance.Size.Magnitude / 2, 0.25)
	end
	st.Center = center
	st.Radius = radius
	st.Model = instance
	instance.Parent = vpf
	frameCamera(vpf, st)
end

function UIKit.SetViewportSpin(vpf: ViewportFrame, spin: boolean)
	local st = viewStates[vpf]
	if not st then
		return
	end
	if spin then
		spinning[vpf] = st
	else
		spinning[vpf] = nil
	end
	updateSpinLoop()
end

local VIEWPORT_SKIP = {
	Model = true,
	Spin = true,
	SpinSpeed = true,
	Yaw = true,
	Pitch = true,
	Zoom = true,
	NoClone = true,
	FieldOfView = true,
}

--[[
	A 3D preview. props: Model (cloned in), Size, Position, Parent, Spin (slow turntable), plus
	  AnchorPoint, ZIndex, LayoutOrder, Name..., SpinSpeed (rad/s, default 0.8), Yaw / Pitch
	  (radians, default a friendly 3/4 view), Zoom (< 1 = closer, default 0.9), FieldOfView,
	  NoClone (use Model itself instead of a copy).
	Cleans itself up (spin loop entry, model) when the frame is destroyed.
]]
function UIKit.Viewport(props: { [string]: any }?): ViewportFrame
	local p: { [string]: any } = props or {}
	local vpf = Instance.new("ViewportFrame")
	vpf.Name = "Viewport"
	vpf.Size = UDim2.fromOffset(120, 120)
	vpf.BackgroundTransparency = 1
	vpf.BorderSizePixel = 0
	vpf.Ambient = Color3.fromRGB(190, 198, 212)
	vpf.LightColor = Color3.fromRGB(255, 250, 240)
	vpf.LightDirection = Vector3.new(-0.4, -1, 0.5)

	local camera = Instance.new("Camera")
	camera.FieldOfView = math.clamp(tonumber(p.FieldOfView) or 32, 5, 90)
	camera.Parent = vpf
	vpf.CurrentCamera = camera

	local st: ViewState = {
		Camera = camera,
		Model = nil,
		Center = Vector3.zero,
		Radius = 2,
		Yaw = tonumber(p.Yaw) or math.rad(-25),
		Pitch = tonumber(p.Pitch) or math.rad(12),
		Zoom = math.clamp(tonumber(p.Zoom) or 0.9, 0.2, 5),
		SpinSpeed = tonumber(p.SpinSpeed) or 0.8,
	}
	viewStates[vpf] = st

	vpf:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if not spinning[vpf] then
			frameCamera(vpf, st)
		end
	end)
	vpf.Destroying:Connect(function()
		viewStates[vpf] = nil
		if spinning[vpf] then
			spinning[vpf] = nil
			updateSpinLoop()
		end
	end)

	local parent = assign(vpf, p, VIEWPORT_SKIP)
	UIKit.SetViewportModel(vpf, p.Model, p.NoClone == true)
	frameCamera(vpf, st)
	if p.Spin then
		spinning[vpf] = st
		updateSpinLoop()
	end
	if parent then
		vpf.Parent = parent
	end
	return vpf
end

----------------------------------------------------------------------------------------------------
-- Formatting and colours
----------------------------------------------------------------------------------------------------
UIKit.Short = Format.Short
UIKit.Time = Format.Time
UIKit.Commas = Format.Commas

function UIKit.RarityColor(rarity: string): Color3
	local def = (Config.Rarities :: any)[rarity]
	if def and typeof(def.Color) == "Color3" then
		return def.Color
	end
	return Config.Rarities.Common.Color
end

----------------------------------------------------------------------------------------------------
-- Init
----------------------------------------------------------------------------------------------------
local cameraConnection: RBXScriptConnection? = nil

local function hookCamera()
	if cameraConnection then
		cameraConnection:Disconnect()
		cameraConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(queueRefresh)
	end
	queueRefresh()
end

-- Escape (keyboard) and B (gamepad) close the open window.
local function onInputBegan(input: InputObject, _processed: boolean)
	local key = input.KeyCode
	if key ~= Enum.KeyCode.Escape and key ~= Enum.KeyCode.ButtonB then
		return
	end
	if openName == nil or UserInputService:GetFocusedTextBox() ~= nil then
		return
	end
	UIKit.CloseWindow()
end

-- Safe to call more than once; every other entry point calls it lazily too.
function UIKit.Init()
	if initialized then
		return
	end
	initialized = true

	hookCamera()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
	pcall(function()
		GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(queueRefresh)
	end)
	local hasPreferredInput = pcall(function()
		UserInputService:GetPropertyChangedSignal("PreferredInput" :: any):Connect(queueRefresh)
	end)
	if not hasPreferredInput then
		-- Older engines: infer the input type from the last input and device capabilities.
		UserInputService.LastInputTypeChanged:Connect(queueRefresh)
	end
	for _, seconds in INSET_REREADS do
		task.delay(seconds, queueRefresh)
	end
	UserInputService.InputBegan:Connect(onInputBegan)
	task.spawn(preloadSounds)
	ensureSafeProbes(Players.LocalPlayer:FindFirstChildOfClass("PlayerGui"))

	applyLayout(true)
end

return UIKit
