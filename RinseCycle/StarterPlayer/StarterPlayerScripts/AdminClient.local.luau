--!nocheck
-- AdminClient (LocalScript, StarterPlayerScripts) - Rinse Cycle's admin panel.
--
-- Ported from the owner's admin system for another game: the command panel (owner only - the
-- server decides who gets one, see AdminServer) plus the notice popup (warn/mute/freeze) and the
-- list popups (warnlist/banlist/mutelist/logs + the detail popups), which every player listens
-- for since the target of e.g. a :warn is not an admin.
--
-- Visual style follows Rinse Cycle's own UI (UIKit's theme): navy panels with a dark outline,
-- lighter navy rows, aqua accents, FredokaOne headings and GothamBold body text, rounded corners.
-- Open it with the ` / ~ key, or the small shield button at the top-left (owner only).
--
-- Commands are typed into this panel's own input box rather than the
-- real chat bar. Intercepting/hiding messages in Roblox's real chat is
-- fragile and differs between the legacy Chat system and TextChatService
-- - a dedicated console avoids that entirely and is what the "command
-- box" in the spec's autocomplete requirements describes anyway.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local UIS = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
-- For GetGuiInset: the real height of Roblox's own topbar, which is not
-- the same on a PC, a console and a phone.
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local playerGui = player:WaitForChild("PlayerGui")

-- Roblox's own default character controller (the PlayerModule that ships
-- in StarterPlayerScripts) reads raw WASD/Shift input directly and drives
-- movement/animation independently of the Humanoid's own state -
-- disabling it is the officially supported way to hand movement over to
-- something else entirely, whether that's this script's own fly
-- controller (on THIS client) or the server puppeting this same
-- character via :controlplayer (on the CONTROLLED TARGET's client) -
-- both need it, so it's set up once, shared, here rather than in either
-- section separately.
local playerControls = nil
do
	local ok, controls = pcall(function()
		local module = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
		return module:GetControls()
	end)
	if ok then
		playerControls = controls
	else
		warn("[AdminClient] Could not access the default PlayerModule controls")
	end
end

-- Rinse Cycle's theme (UIKit.Theme.Colors): Panel / PanelLight / Primary / Text / TextDim.
local BG_DARK    = Color3.fromRGB(19, 49, 92)
local BG_ROW     = Color3.fromRGB(30, 72, 128)
local BG_HOVER   = Color3.fromRGB(44, 94, 158)
local ACCENT     = Color3.fromRGB(56, 189, 248)
local ERROR_RED  = Color3.fromRGB(248, 113, 113)
local INK        = Color3.fromRGB(5, 16, 36)
local TEXT_MAIN  = Color3.fromRGB(255, 255, 255)
local TEXT_DIM   = Color3.fromRGB(166, 196, 228)
local TITLE_FONT = Enum.Font.FredokaOne
-- Only used by the frozen indicator icon - see its own note further down.
local FREEZE_BLUE = Color3.fromRGB(120, 205, 255)
local BODY_FONT  = Enum.Font.GothamBold
local RADIUS_PANEL = UDim.new(0, 16)
local RADIUS_CTRL  = UDim.new(0, 12)

-- The game's windows have a dark outline; every admin panel and popup gets the same.
local function outline(guiObject)
	local stroke = Instance.new("UIStroke")
	stroke.Color = INK
	stroke.Thickness = 3
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = guiObject
	return stroke
end

local GetAdminInfo = ReplicatedStorage:WaitForChild("GetAdminInfo")
local AdminCommand = ReplicatedStorage:WaitForChild("AdminCommand")
local AdminNotice = ReplicatedStorage:WaitForChild("AdminNotice")
local AdminFeedback = ReplicatedStorage:WaitForChild("AdminFeedback")
local AdminWarningsList = ReplicatedStorage:WaitForChild("AdminWarningsList")
local AdminViewWarnings = ReplicatedStorage:WaitForChild("AdminViewWarnings")
local AdminRemoveWarning = ReplicatedStorage:WaitForChild("AdminRemoveWarning")
local AdminBanList = ReplicatedStorage:WaitForChild("AdminBanList")
local AdminMuteList = ReplicatedStorage:WaitForChild("AdminMuteList")
local AdminWarnList = ReplicatedStorage:WaitForChild("AdminWarnList")
local AdminModifyPunishment = ReplicatedStorage:WaitForChild("AdminModifyPunishment")
local AdminLogsList = ReplicatedStorage:WaitForChild("AdminLogsList")
local AdminScreenFade = ReplicatedStorage:WaitForChild("AdminScreenFade")
local AdminRemoveLogEntry = ReplicatedStorage:WaitForChild("AdminRemoveLogEntry")

-- Shared by every popup below (notice/list/detail) - none of them
-- previously scaled at all (the notice popup even had a UIScale
-- instance, but its Scale was hardcoded to 1 and never actually
-- computed), so on a phone-sized viewport they rendered at their full
-- desktop pixel size, badly overflowing the screen. Same
-- reference-resolution formula buildPanel() below already uses for the
-- admin panel itself.
local POPUP_REFERENCE_WIDTH = 1280
local POPUP_REFERENCE_HEIGHT = 720
local POPUP_MIN_SCALE = 0.5
local POPUP_MAX_SCALE = 1.6

local function attachAutoScale(guiObject)
	local uiScale = Instance.new("UIScale")
	uiScale.Scale = 1
	uiScale.Parent = guiObject

	local function apply()
		local camera = workspace.CurrentCamera
		if not camera then return end
		local viewport = camera.ViewportSize
		if viewport.X <= 0 or viewport.Y <= 0 then return end
		local scale = math.clamp(math.min(viewport.X / POPUP_REFERENCE_WIDTH, viewport.Y / POPUP_REFERENCE_HEIGHT), POPUP_MIN_SCALE, POPUP_MAX_SCALE)
		uiScale.Scale = scale
	end
	apply()

	-- Disconnected by the caller when the popup closes, since a fresh
	-- one of these gets created every time a popup opens - left
	-- connected forever, they'd pile up for as long as the session runs.
	local connection = nil
	if workspace.CurrentCamera then
		connection = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(apply)
	end
	return function()
		if connection then connection:Disconnect() end
	end
end

-- =====================================================================
-- Notice popup - covers the warn, mute, and freeze notices, all drawn
-- by this one component (title + body + optional footnote + an OK
-- button) instead of three near-identical UI builders. Every player's
-- client listens for this, not just staff, since the target of e.g. a
-- :warn is often not staff at all.
-- =====================================================================
-- Rises into place while the backdrop and blur fade up behind it, and
-- reverses on the way out. The panel itself stays fully opaque
-- throughout - fading a Frame doesn't fade its children, so a
-- transparency fade would leave the title, body and button hanging in
-- mid-air over a vanishing panel. Moving it instead reads as one solid
-- object. Kept in step with TopBar.lua's respawn-warning modal, which
-- uses the same timings for the same reason.
local NOTICE_RISE = 40
local NOTICE_OPEN_TWEEN = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local NOTICE_CLOSE_TWEEN = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local NOTICE_CENTER_POS = UDim2.new(0.5, 0, 0.5, 0)
local NOTICE_OFFSCREEN_POS = UDim2.new(0.5, 0, 0.5, NOTICE_RISE)

local function showNoticePopup(title, body, footnote, buttonLabel)
	local existing = playerGui:FindFirstChild("AdminNoticeGui")
	if existing then existing:Destroy() end
	local existingBlur = Lighting:FindFirstChild("AdminNoticeBlur")
	if existingBlur then existingBlur:Destroy() end

	-- Starts at 0 and is tweened up alongside the popup's own entrance
	-- animation below, rather than snapping to full strength the instant
	-- the notice fires.
	local blur = Instance.new("BlurEffect")
	blur.Name = "AdminNoticeBlur"
	blur.Size = 0
	blur.Parent = Lighting

	local gui = Instance.new("ScreenGui")
	gui.Name = "AdminNoticeGui"
	gui.IgnoreGuiInset = true
	-- IgnoreGuiInset only bypasses Roblox's own topbar strip.
	-- ScreenInsets is a SEPARATE, additive property defaulting to
	-- CoreUISafeInsets, which on a console reserves a TV-safe
	-- border and on a phone the notch. Without this, "1" on the Y
	-- scale is that inset edge rather than the real bottom of the
	-- screen - which is how a panel parked off the bottom ended up
	-- with its header showing on PS5.
	gui.ScreenInsets = Enum.ScreenInsets.None
	-- Deliberately ABOVE every panel (Shop/Settings at 10, Admin Panel at
	-- 20) and even the announcement banner (30) - this is a personal,
	-- blocking "you were muted/banned/warned" interrupt with its own full-
	-- screen backdrop and blur, not an ambient status reminder. A player
	-- (or an admin self-testing) should see this the instant it fires
	-- regardless of what they had open, the same way a mainstream game's
	-- moderation-action screen always takes over. It was briefly lowered
	-- to 5 (behind panels, alongside the passive status icons below) to
	-- fix an earlier complaint about it covering an open Admin Panel, but
	-- on reflection that conflated "urgent, needs-attention modal" with
	-- "ambient status pill" - only the latter belongs behind an open
	-- panel.
	gui.DisplayOrder = 35
	gui.Parent = playerGui

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.new(1, 0, 1, 0)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 1 -- tweened up to 0.5 on open, below
	backdrop.BorderSizePixel = 0
	-- Active=true so this backdrop actually catches clicks instead of
	-- letting them fall through - a Frame defaults Active to false
	-- (unlike a TextButton), which only blocks NOTHING: it renders on
	-- top but a click at that screen position keeps looking for the
	-- next interactive object underneath and finds it, which is why the
	-- admin panel's sidebar commands were still clickable right through
	-- a popup visibly covering them.
	backdrop.Active = true
	backdrop.Parent = gui

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = NOTICE_OFFSCREEN_POS -- tweened to centre on open, below
	panel.Size = UDim2.new(0, 420, 0, footnote and 250 or 210)
	panel.BackgroundColor3 = BG_DARK
	panel.BorderSizePixel = 0
	panel.Parent = gui
	Instance.new("UICorner", panel).CornerRadius = RADIUS_PANEL
	outline(panel)
	local disconnectScale = attachAutoScale(panel)

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -40, 0, 32)
	titleLabel.Position = UDim2.new(0, 20, 0, 20)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = TITLE_FONT
	titleLabel.TextColor3 = ACCENT
	titleLabel.TextSize = 22
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextWrapped = true
	titleLabel.Text = title
	titleLabel.Parent = panel

	local bodyLabel = Instance.new("TextLabel")
	bodyLabel.Size = UDim2.new(1, -40, 0, 90)
	bodyLabel.Position = UDim2.new(0, 20, 0, 62)
	bodyLabel.BackgroundTransparency = 1
	bodyLabel.Font = BODY_FONT
	bodyLabel.TextColor3 = TEXT_MAIN
	bodyLabel.TextSize = 15
	bodyLabel.TextWrapped = true
	bodyLabel.TextXAlignment = Enum.TextXAlignment.Left
	bodyLabel.TextYAlignment = Enum.TextYAlignment.Top
	bodyLabel.Text = body
	bodyLabel.Parent = panel

	if footnote then
		local footnoteLabel = Instance.new("TextLabel")
		footnoteLabel.Size = UDim2.new(1, -40, 0, 30)
		footnoteLabel.Position = UDim2.new(0, 20, 0, 150)
		footnoteLabel.BackgroundTransparency = 1
		footnoteLabel.Font = BODY_FONT
		footnoteLabel.TextColor3 = TEXT_DIM
		footnoteLabel.TextSize = 11
		footnoteLabel.TextWrapped = true
		footnoteLabel.TextXAlignment = Enum.TextXAlignment.Left
		footnoteLabel.Text = footnote
		footnoteLabel.Parent = panel
	end

	local okBtn = Instance.new("TextButton")
	okBtn.Size = UDim2.new(0, 160, 0, 40)
	okBtn.Position = UDim2.new(0.5, 0, 1, -20)
	okBtn.AnchorPoint = Vector2.new(0.5, 1)
	okBtn.BackgroundColor3 = ACCENT
	okBtn.AutoButtonColor = false
	okBtn.Text = buttonLabel or "I UNDERSTAND"
	okBtn.Font = BODY_FONT
	okBtn.TextColor3 = TEXT_MAIN
	okBtn.TextSize = 13
	okBtn.Parent = panel
	Instance.new("UICorner", okBtn).CornerRadius = RADIUS_CTRL

	TweenService:Create(panel, NOTICE_OPEN_TWEEN, {Position = NOTICE_CENTER_POS}):Play()
	TweenService:Create(backdrop, NOTICE_OPEN_TWEEN, {BackgroundTransparency = 0.5}):Play()
	TweenService:Create(blur, NOTICE_OPEN_TWEEN, {Size = 24}):Play()

	local dismissed = false
	okBtn.MouseButton1Click:Connect(function()
		-- Guarded because the close animation leaves the button clickable
		-- for its duration - without this, a second click part-way through
		-- would start the whole teardown again.
		if dismissed then return end
		dismissed = true

		TweenService:Create(panel, NOTICE_CLOSE_TWEEN, {Position = NOTICE_OFFSCREEN_POS}):Play()
		TweenService:Create(backdrop, NOTICE_CLOSE_TWEEN, {BackgroundTransparency = 1}):Play()
		TweenService:Create(blur, NOTICE_CLOSE_TWEEN, {Size = 0}):Play()

		task.delay(NOTICE_CLOSE_TWEEN.Time, function()
			disconnectScale()
			gui:Destroy()
			blur:Destroy()
		end)
	end)
end

AdminNotice.OnClientEvent:Connect(function(title, body, footnote, buttonLabel)
	showNoticePopup(title, body, footnote, buttonLabel)
end)

-- =====================================================================
-- Announcement banner - a top-of-screen bar for :announce, distinct
-- from the centered/blurred notice popup above (:warn/:mute/:freeze/
-- :msg). Slides down, holds long enough to read, slides back up and
-- removes itself - no manual dismiss needed for a short broadcast.
-- =====================================================================
local AdminAnnouncement = ReplicatedStorage:WaitForChild("AdminAnnouncement")

local function showAnnouncementBanner(message)
	local existing = playerGui:FindFirstChild("AdminAnnouncementGui")
	if existing then existing:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AdminAnnouncementGui"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	-- Deliberately ABOVE every panel (Shop/Settings at 10, Admin Panel at
	-- 20) - this is a brief (6s, auto-dismissing), non-blocking, server-
	-- wide broadcast meant for every player to see, so it should still
	-- peek in over whatever panel someone happens to have open rather
	-- than being silently missed - it doesn't demand a click or cover the
	-- center of the screen, so it isn't "annoying" the way a modal would
	-- be. Below AdminNoticeGui (35), a personal moderation notice, since
	-- that's about the individual player specifically and takes priority
	-- over a generic broadcast.
	gui.DisplayOrder = 30
	gui.Parent = playerGui

	local CLOSED_POS = UDim2.new(0.5, 0, 0, -90)
	local OPEN_POS = UDim2.new(0.5, 0, 0, 0)

	local bar = Instance.new("Frame")
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Size = UDim2.new(1, 0, 0, 70)
	bar.Position = CLOSED_POS
	bar.BackgroundColor3 = BG_DARK
	bar.BorderSizePixel = 0
	bar.Parent = gui

	local accentBar = Instance.new("Frame")
	accentBar.Size = UDim2.new(1, 0, 0, 3)
	accentBar.Position = UDim2.new(0, 0, 1, -3)
	accentBar.BackgroundColor3 = ACCENT
	accentBar.BorderSizePixel = 0
	accentBar.Parent = bar

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -80, 1, 0)
	label.Position = UDim2.new(0.5, 0, 0.5, 0)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.BackgroundTransparency = 1
	label.Font = BODY_FONT
	label.TextColor3 = TEXT_MAIN
	label.TextSize = 18
	label.TextWrapped = true
	label.Text = "ANNOUNCEMENT: " .. message
	label.Parent = bar

	TweenService:Create(bar, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position = OPEN_POS}):Play()

	task.delay(6, function()
		if not bar.Parent then return end
		local tween = TweenService:Create(bar, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = CLOSED_POS})
		tween:Play()
		tween.Completed:Wait()
		gui:Destroy()
	end)
end

AdminAnnouncement.OnClientEvent:Connect(showAnnouncementBanner)

-- Rinse Cycle has no loading screen or main menu to hide behind, so nothing is ever blocked; the
-- hooks are kept so the rest of the panel code reads the same.
local sceneBlocked = false
local onSceneBlockedChanged

-- =====================================================================
-- Frozen/mute indicators - small persistent top-of-screen icons for as
-- long as the server says frozen/muted is true, separate from the
-- one-shot AdminNotice popup (which only fires once, at the moment
-- :freeze/:mute happens, and is easy to dismiss and forget about while
-- still actually frozen/muted). Both stay hidden while sceneBlocked is
-- true (loading screen / main menu) even if the underlying state is
-- true - a muted player rejoining shouldn't see the muted icon until
-- they're actually back in the game.
-- =====================================================================
local AdminFreezeStatus = ReplicatedStorage:WaitForChild("AdminFreezeStatus")
local AdminMuteStatus = ReplicatedStorage:WaitForChild("AdminMuteStatus")

-- Redesigned from a vertically-stacked list of wide text pills into a
-- single horizontally-centered row of small square icons - as full-width
-- text bars, more than one or two showing at once (fly + frozen + muted,
-- say) ate a lot of screen space. A shared UIListLayout (horizontal,
-- center-aligned) handles the centering/spacing automatically as icons
-- show and hide (toggled via Visible below), rather than this script
-- computing each one's position by hand - "start in the middle and
-- spread out across" is just what a centered horizontal list does
-- natively.
-- 44, up from 36, to make room for a 30-cell glyph instead of a 22-cell
-- one. One cell is one pixel, so the grid size IS the detail available -
-- and 22 was simply too few for the chat bubble's tail and outline to
-- survive, which is why it read as a vague crossed-out square.
--
-- Enlarging was the wrong call while these ran across the top in a row,
-- where they had to stay small next to everything else. In a left-hand
-- column of their own there's nothing to stay small for.
local INDICATOR_ICON_SIZE = 44
-- Down the LEFT edge, below the Roblox menu button and this game's own
-- topbar row, stacking downwards as more statuses apply.
--
-- They used to run across the top centre, which put them in the single
-- most valuable strip of screen - the one place a "what are you doing
-- right now" readout wants to be. Moving them frees that up, and a
-- vertical stack suits them better anyway: each status simply appears
-- under the last instead of the whole group shuffling sideways every
-- time one shows or hides.
-- Measured from Roblox's own topbar rather than guessed at.
--
-- This was a flat 60px from the true top of the screen, which cleared
-- the topbar on a PC and landed INSIDE it on a PS5 - the fly and freeze
-- icons came out tucked behind the Roblox menu button in the corner.
-- Roblox's topbar is not one height: a console's is taller and sits in
-- a TV-safe border, and a phone adds a notch on top of that.
--
-- GetGuiInset reports what it actually is on the device in hand. This
-- ScreenGui sets IgnoreGuiInset, so its coordinates start at the true
-- top of the screen and the inset has to be added back by hand - which
-- is the whole reason a hardcoded number was wrong here.
local INDICATOR_TOP_GAP = 14
local INDICATOR_LEFT_MARGIN = 14

local function indicatorTopOffset()
	local inset = GuiService:GetGuiInset()
	return inset.Y + INDICATOR_TOP_GAP
end

local indicatorGui = Instance.new("ScreenGui")
indicatorGui.Name = "IndicatorGui"
indicatorGui.ResetOnSpawn = false
-- True - this stack is meant to sit at the true top of the screen
-- (confirmed: pushing it below the topbar's reserved strip instead
-- looked worse) alongside the native topbar row, not underneath it - the
-- Spectating/Controlling bars colliding with the Admin button was fixed
-- by shrinking those bars to fit the gap instead (see createActionIndicator
-- below), not by relocating this whole row.
indicatorGui.IgnoreGuiInset = true
indicatorGui.ScreenInsets = Enum.ScreenInsets.None
-- Below every openable panel (Shop/Settings at 10, Admin Panel at 20) -
-- this used to be 40 (above all of them), which is why these indicators
-- rendered right over the top of an open panel instead of staying
-- tucked behind it. Still above the base game world/topbar/overhead
-- tags (all well under 10) so they're still visible during normal play.
-- Deliberately lower than AdminNoticeGui (35) and AdminAnnouncementGui
-- (30) though - unlike those two, this is just an ambient "here's your
-- current status" reminder, not something urgent enough to justify
-- covering an admin's own open panel.
indicatorGui.DisplayOrder = 5
indicatorGui.Parent = playerGui

local indicatorRow = Instance.new("Frame")
indicatorRow.Name = "Row"
indicatorRow.AnchorPoint = Vector2.new(0, 0)
indicatorRow.Position = UDim2.new(0, INDICATOR_LEFT_MARGIN, 0, indicatorTopOffset())
indicatorRow.Size = UDim2.new(0, INDICATOR_ICON_SIZE, 0, 0)
-- Height fits exactly whatever is currently visible, so the column grows
-- downwards as statuses appear and collapses again as they clear -
-- nothing has to be repositioned by hand, and a hidden one leaves no gap
-- behind it.
indicatorRow.AutomaticSize = Enum.AutomaticSize.Y
indicatorRow.BackgroundTransparency = 1
indicatorRow.Parent = indicatorGui

local indicatorLayout = Instance.new("UIListLayout")
indicatorLayout.FillDirection = Enum.FillDirection.Vertical
indicatorLayout.HorizontalAlignment = Enum.HorizontalAlignment.Left
indicatorLayout.VerticalAlignment = Enum.VerticalAlignment.Top
indicatorLayout.Padding = UDim.new(0, 8)
indicatorLayout.SortOrder = Enum.SortOrder.LayoutOrder
indicatorLayout.Parent = indicatorRow

-- Re-measured when the viewport changes, and again a moment after start.
-- GetGuiInset can report 0 for the first frames before the topbar has
-- laid itself out, and on a console it settles later than on a PC.
local function realignIndicators()
	indicatorRow.Position = UDim2.new(0, INDICATOR_LEFT_MARGIN, 0, indicatorTopOffset())
end

task.spawn(function()
	for _ = 1, 3 do
		task.wait(1)
		realignIndicators()
	end
end)

task.spawn(function()
	local camera = workspace.CurrentCamera
	if camera then
		camera:GetPropertyChangedSignal("ViewportSize"):Connect(realignIndicators)
	end
end)

-- =====================================================================
-- Icon glyphs, drawn from plain Frames.
--
-- Uploaded decals were the obvious way to do these, but never rendered
-- in-game no matter what was tried (three separate uploads, plus known-
-- good third-party assets, all invisible while the ImageLabel itself was
-- provably drawing - a lime test background showed up fine). Rather than
-- keep fighting that, each glyph is TRACED from reference artwork into
-- horizontal runs, and every run becomes one Frame. Frames are the one
-- primitive that has never failed to draw here.
--
-- Each entry is {startColumn, row, widthInCells, alphaLevel}, zero-
-- indexed from the glyph's top-left, generated by sampling a source
-- PNG's alpha channel - so the silhouettes match real artwork rather
-- than being eyeballed (which is what made the earliest hand-built
-- attempts read as a dagger rather than a plane).
--
-- Two properties of this grid matter, and both were learned the hard
-- way:
--
-- * ONE CELL IS EXACTLY ONE PIXEL. An earlier pass traced at 48x48 for
--   smoother edges, which put cells at roughly half a pixel - and
--   sub-pixel Frames render so faintly that the mute glyph vanished
--   entirely. A later pass fixed the size but left cells at fractional
--   pixel widths (1.2375 and the like), and Roblox rounding each Frame's
--   position and size independently then opened periodic 1px gaps, which
--   showed up as lines slicing through the plane. Whole-pixel cells make
--   both problems structurally impossible: every position and size below
--   is an integer, so rows tile exactly with no gaps and no overlap.
--
-- * RESOLUTION COMES FROM THE GRID, AND ONLY FROM THERE. One cell is
--   one pixel, so the grid size IS the icon's pixel size - a 20-cell
--   glyph has 20 steps of detail and no re-trace can give it a 21st.
--   That ceiling is what every "it looks jagged" / "it looks blurry"
--   round came back to: a sharper trace showed the staircase, a smoother
--   one (finer alpha, area-averaged sampling) smeared it, and neither
--   added a single pixel. Alpha levels anti-alias what's there; they
--   don't create detail.
--
--   All three are traced at 22 so they render at exactly the same size.
--   They were briefly on mixed grids to compensate for a solid shape
--   reading heavier than a spindly one, but that was chasing perceived
--   weight rather than fixing it - the real cause was the chat bubble
--   having been a heavy crossed-out box. Now that it is line art like
--   the snowflake, one shared grid is both simpler and correct.
--
--   Changing a grid is a RE-TRACE, not a constant edit - the data below
--   is baked at whatever grid it was generated on.
--
-- * EDGE CONTRAST IS APPLIED AT TRACE TIME, AND ONLY TO SOLID SHAPES.
--   Area-averaging leaves part-covered edge cells at mid coverage, and a
--   line of mid-tone cells is exactly what "blurry around the lines"
--   was. Pushing coverage away from the middle before quantising
--   (c' = (c - 0.5) * 1.9 + 0.5, clamped) narrows the transition band so
--   edges resolve toward on or off.
--
--   The rule turned out to be about the ARTWORK, not the icon. Contrast
--   helps a SOLID shape, where nearly every cell is either fully inside
--   or fully outside and only the outline is partial. It wrecks LINE
--   ART, where the strokes are a couple of pixels wide so most cells are
--   partial coverage by nature - hardening those fattens some strokes
--   and erases others outright. That's exactly what happened when it was
--   applied to the snowflake: the fine branches vanished.
--
--   So the plane (solid silhouette) is traced at 1.9, while the chat
--   bubble and the snowflake (both line art) are traced flat.
--
-- Every glyph is cropped to its own artwork bounds before tracing, and
-- buildIconGlyph then measures and centres from those bounds - so each
-- one can sit on a different grid without any special handling, and each
-- draws at exactly as many pixels as its grid has cells.
--
-- Current traces: all three at 22, so they render at identical size.
-- =====================================================================
local ICON_CELL = 1
local ICON_ALPHA_LEVELS = 8

local PLANE_GLYPH = {
	{26,0,1,3},{27,0,2,8},{29,0,1,2},{25,1,5,8},{11,2,3,8},{23,2,1,1},
	{24,2,6,8},{4,3,1,1},{5,3,1,3},{10,3,4,8},{22,3,1,4},{23,3,6,8},{29,3,1,3},
	{3,4,1,3},{4,4,10,8},{21,4,1,6},{22,4,7,8},{2,5,1,6},{3,5,12,8},{15,5,1,6},
	{16,5,1,4},{17,5,1,1},{20,5,8,8},{2,6,1,1},{3,6,1,7},{4,6,23,8},{27,6,1,1},
	{5,7,1,7},{6,7,20,8},{26,7,1,4},{7,8,1,6},{8,8,17,8},{25,8,1,6},{9,9,1,4},
	{10,9,15,8},{11,10,1,3},{12,10,12,8},{13,11,1,3},{14,11,10,8},{13,12,11,8},
	{24,12,1,1},{12,13,1,6},{13,13,11,8},{24,13,1,4},{11,14,1,4},{12,14,12,8},
	{24,14,1,6},{10,15,1,2},{11,15,14,8},{10,16,8,8},{18,16,1,3},{19,16,9,8},
	{9,17,7,8},{16,17,1,6},{19,17,9,8},{8,18,1,7},{9,18,6,8},{15,18,1,4},
	{19,18,1,3},{20,18,8,8},{7,19,1,5},{8,19,6,8},{14,19,1,2},{20,19,7,8},
	{1,20,1,8},{2,20,1,7},{3,20,1,4},{4,20,1,2},{6,20,1,4},{7,20,6,8},
	{20,20,1,4},{21,20,5,8},{0,21,1,6},{1,21,10,8},{11,21,1,7},{21,21,5,8},
	{1,22,1,7},{2,22,8,8},{10,22,1,5},{21,22,1,6},{22,22,4,8},{2,23,1,7},
	{3,23,6,8},{9,23,1,4},{22,23,4,8},{3,24,1,7},{4,24,5,8},{22,24,1,7},
	{23,24,3,8},{26,24,1,3},{4,25,1,6},{5,25,4,8},{9,25,1,2},{23,25,3,8},
	{26,25,1,1},{5,26,1,7},{6,26,3,8},{9,26,1,4},{23,26,1,7},{24,26,1,8},
	{25,26,1,3},{6,27,1,7},{7,27,2,8},{9,27,1,7},{23,27,1,1},{24,27,1,6},
	{7,28,1,7},{8,28,2,8},{8,29,1,6},
}

local MUTE_GLYPH = {
	{27,0,1,2},{28,0,1,7},{29,0,1,5},{26,1,1,1},{27,1,1,7},{28,1,1,8},
	{29,1,1,7},{4,2,1,2},{5,2,21,3},{26,2,1,7},{27,2,1,8},{28,2,1,7},
	{29,2,1,2},{2,3,1,1},{3,3,1,7},{4,3,23,8},{27,3,1,7},{28,3,1,1},{2,4,1,6},
	{3,4,1,8},{4,4,1,7},{5,4,18,6},{23,4,1,7},{24,4,3,8},{27,4,1,6},{1,5,1,1},
	{2,5,2,8},{4,5,1,1},{22,5,1,1},{23,5,1,7},{24,5,1,8},{25,5,1,7},{26,5,2,8},
	{28,5,1,1},{1,6,1,1},{2,6,2,8},{21,6,1,2},{22,6,1,7},{23,6,1,8},{24,6,1,7},
	{25,6,1,2},{26,6,2,8},{28,6,1,1},{1,7,1,1},{2,7,2,8},{20,7,1,2},{21,7,1,7},
	{22,7,1,8},{23,7,1,7},{24,7,1,1},{26,7,2,8},{28,7,1,1},{1,8,1,1},{2,8,2,8},
	{19,8,1,1},{20,8,1,7},{21,8,1,8},{22,8,1,7},{23,8,1,2},{26,8,2,8},
	{28,8,1,1},{1,9,1,1},{2,9,2,8},{18,9,1,1},{19,9,1,7},{20,9,1,8},{21,9,1,7},
	{22,9,1,2},{26,9,2,8},{28,9,1,1},{1,10,1,1},{2,10,2,8},{17,10,1,1},
	{18,10,1,7},{19,10,1,8},{20,10,1,7},{21,10,1,1},{26,10,2,8},{28,10,1,1},
	{1,11,1,1},{2,11,2,8},{16,11,1,1},{17,11,1,7},{18,11,1,8},{19,11,1,7},
	{20,11,1,2},{26,11,2,8},{28,11,1,1},{1,12,1,1},{2,12,2,8},{15,12,1,1},
	{16,12,1,7},{17,12,1,8},{18,12,1,7},{19,12,1,1},{26,12,2,8},{28,12,1,1},
	{1,13,1,1},{2,13,2,8},{14,13,1,2},{15,13,1,7},{16,13,1,8},{17,13,1,7},
	{18,13,1,2},{26,13,2,8},{28,13,1,1},{1,14,1,1},{2,14,2,8},{13,14,1,2},
	{14,14,1,7},{15,14,1,8},{16,14,1,7},{17,14,1,1},{26,14,2,8},{28,14,1,1},
	{1,15,1,1},{2,15,2,8},{12,15,1,1},{13,15,1,7},{14,15,1,8},{15,15,1,7},
	{16,15,1,2},{26,15,2,8},{28,15,1,1},{1,16,1,1},{2,16,2,8},{11,16,1,1},
	{12,16,1,7},{13,16,1,8},{14,16,1,7},{15,16,1,2},{26,16,2,8},{28,16,1,1},
	{1,17,1,1},{2,17,2,8},{10,17,1,1},{11,17,1,7},{12,17,1,8},{13,17,1,7},
	{14,17,1,1},{26,17,2,8},{28,17,1,1},{1,18,1,1},{2,18,2,8},{9,18,1,1},
	{10,18,1,7},{11,18,1,8},{12,18,1,7},{13,18,1,2},{26,18,2,8},{28,18,1,1},
	{1,19,1,1},{2,19,2,8},{8,19,1,1},{9,19,1,7},{10,19,1,8},{11,19,1,7},
	{12,19,1,1},{26,19,2,8},{28,19,1,1},{2,20,2,8},{4,20,1,2},{7,20,1,2},
	{8,20,1,7},{9,20,1,8},{10,20,1,7},{11,20,1,2},{25,20,1,2},{26,20,2,8},
	{28,20,1,1},{2,21,1,6},{3,21,2,8},{5,21,2,7},{7,21,4,8},{11,21,2,7},
	{13,21,1,6},{14,21,1,1},{18,21,1,2},{19,21,6,7},{25,21,2,8},{27,21,1,6},
	{2,22,1,1},{3,22,1,6},{4,22,10,8},{14,22,1,7},{15,22,1,1},{18,22,1,3},
	{19,22,7,8},{26,22,1,6},{27,22,1,1},{4,23,1,3},{5,23,2,8},{7,23,1,7},
	{8,23,1,3},{9,23,4,2},{13,23,1,7},{14,23,1,8},{15,23,1,7},{16,23,1,1},
	{18,23,1,3},{19,23,1,8},{20,23,1,6},{21,23,4,2},{25,23,1,1},{3,24,1,1},
	{4,24,1,7},{5,24,1,8},{6,24,1,7},{7,24,1,1},{13,24,1,1},{14,24,1,7},
	{15,24,1,8},{16,24,1,7},{17,24,1,1},{18,24,1,3},{19,24,1,8},{20,24,1,5},
	{2,25,1,1},{3,25,1,7},{4,25,1,8},{5,25,1,7},{6,25,1,2},{14,25,1,1},
	{15,25,1,6},{16,25,1,8},{17,25,1,7},{18,25,1,5},{19,25,1,8},{20,25,1,5},
	{1,26,1,1},{2,26,1,7},{3,26,1,8},{4,26,1,7},{5,26,1,1},{15,26,1,1},
	{16,26,1,6},{17,26,3,8},{20,26,1,5},{0,27,1,2},{1,27,1,7},{2,27,1,8},
	{3,27,1,7},{4,27,1,2},{16,27,1,1},{17,27,1,6},{18,27,2,8},{20,27,1,5},
	{0,28,1,7},{1,28,1,8},{2,28,1,7},{3,28,1,1},{17,28,1,1},{18,28,1,6},
	{19,28,1,8},{20,28,1,5},{0,29,1,5},{1,29,1,7},{2,29,1,2},{18,29,1,1},
	{19,29,1,4},{20,29,1,2},
}

-- Traced from a snowflake rendered specifically for this, rather than
-- the "*" text glyph this used to be - a text character can't be centred
-- reliably (fonts carry their own bearing/baseline offsets, so it sat
-- visibly off-centre) and there's no way to match its size to the traced
-- glyphs beside it.
local FREEZE_GLYPH = {
	{13,0,1,1},{14,0,2,6},{16,0,1,1},{10,1,1,2},{11,1,1,6},{12,1,1,4},
	{13,1,1,2},{14,1,2,8},{16,1,1,2},{17,1,1,3},{18,1,1,6},{19,1,1,2},
	{10,2,1,3},{11,2,2,8},{13,2,1,5},{14,2,2,8},{16,2,1,5},{17,2,2,8},
	{19,2,1,3},{11,3,1,5},{12,3,6,8},{18,3,1,5},{4,4,1,1},{12,4,1,6},
	{13,4,4,8},{17,4,1,6},{25,4,1,1},{3,5,1,3},{4,5,1,8},{5,5,1,5},{12,5,1,1},
	{13,5,1,6},{14,5,2,8},{16,5,1,6},{17,5,1,1},{24,5,1,4},{25,5,1,8},
	{26,5,1,4},{3,6,1,4},{4,6,2,8},{13,6,1,2},{14,6,2,8},{16,6,1,2},{24,6,2,8},
	{26,6,1,4},{0,7,1,1},{1,7,1,7},{2,7,1,6},{3,7,1,3},{4,7,2,8},{6,7,1,3},
	{13,7,1,2},{14,7,2,8},{16,7,1,2},{23,7,1,3},{24,7,2,8},{26,7,1,3},
	{27,7,1,6},{28,7,1,7},{29,7,1,2},{0,8,1,2},{1,8,5,8},{6,8,1,6},{13,8,1,2},
	{14,8,2,8},{16,8,1,2},{23,8,1,6},{24,8,5,8},{29,8,1,2},{1,9,1,1},{2,9,1,6},
	{3,9,4,8},{7,9,1,2},{13,9,1,2},{14,9,2,8},{16,9,1,2},{22,9,1,2},{23,9,4,8},
	{27,9,1,6},{28,9,1,1},{0,10,1,4},{1,10,1,7},{2,10,6,8},{8,10,1,5},
	{9,10,1,1},{13,10,1,2},{14,10,2,8},{16,10,1,2},{20,10,1,1},{21,10,1,5},
	{22,10,6,8},{28,10,1,7},{29,10,1,4},{0,11,1,7},{1,11,3,8},{4,11,1,6},
	{5,11,1,5},{6,11,1,6},{7,11,3,8},{10,11,1,5},{11,11,1,1},{13,11,1,2},
	{14,11,2,8},{16,11,1,2},{18,11,1,1},{19,11,1,5},{20,11,3,8},{23,11,1,6},
	{24,11,1,5},{25,11,1,6},{26,11,3,8},{29,11,1,7},{0,12,1,1},{1,12,1,2},
	{2,12,1,1},{7,12,1,3},{8,12,1,6},{9,12,3,8},{12,12,1,4},{13,12,1,2},
	{14,12,2,8},{16,12,1,2},{17,12,1,4},{18,12,3,8},{21,12,1,6},{22,12,1,3},
	{27,12,1,1},{28,12,1,2},{29,12,1,1},{9,13,1,3},{10,13,1,6},{11,13,8,8},
	{19,13,1,6},{20,13,1,3},{11,14,1,3},{12,14,1,7},{13,14,4,8},{17,14,1,7},
	{18,14,1,3},{11,15,1,3},{12,15,1,7},{13,15,4,8},{17,15,1,7},{18,15,1,3},
	{9,16,1,2},{10,16,1,6},{11,16,8,8},{19,16,1,6},{20,16,1,2},{0,17,1,1},
	{1,17,1,2},{2,17,1,1},{7,17,1,2},{8,17,1,6},{9,17,3,8},{12,17,1,4},
	{13,17,1,3},{14,17,2,8},{16,17,1,3},{17,17,1,4},{18,17,3,8},{21,17,1,6},
	{22,17,1,2},{27,17,1,1},{28,17,1,2},{29,17,1,1},{0,18,1,7},{1,18,2,8},
	{3,18,1,7},{4,18,1,6},{5,18,1,5},{6,18,1,6},{7,18,3,8},{10,18,1,5},
	{11,18,1,1},{13,18,1,2},{14,18,2,8},{16,18,1,2},{18,18,1,1},{19,18,1,5},
	{20,18,3,8},{23,18,1,6},{24,18,1,5},{25,18,1,6},{26,18,1,7},{27,18,2,8},
	{29,18,1,7},{0,19,1,4},{1,19,1,7},{2,19,6,8},{8,19,1,5},{9,19,1,1},
	{13,19,1,2},{14,19,2,8},{16,19,1,2},{20,19,1,1},{21,19,1,5},{22,19,6,8},
	{28,19,1,7},{29,19,1,4},{1,20,1,1},{2,20,1,6},{3,20,4,8},{7,20,1,2},
	{13,20,1,2},{14,20,2,8},{16,20,1,2},{22,20,1,2},{23,20,4,8},{27,20,1,6},
	{28,20,1,1},{0,21,1,2},{1,21,5,8},{6,21,1,6},{13,21,1,2},{14,21,2,8},
	{16,21,1,2},{23,21,1,6},{24,21,5,8},{29,21,1,2},{0,22,1,2},{1,22,1,7},
	{2,22,1,6},{3,22,1,3},{4,22,2,8},{6,22,1,3},{13,22,1,2},{14,22,2,8},
	{16,22,1,2},{23,22,1,3},{24,22,2,8},{26,22,1,3},{27,22,1,6},{28,22,1,7},
	{29,22,1,2},{3,23,1,4},{4,23,2,8},{13,23,1,2},{14,23,2,8},{16,23,1,2},
	{24,23,2,8},{26,23,1,4},{3,24,1,4},{4,24,1,8},{5,24,1,5},{13,24,1,6},
	{14,24,2,8},{16,24,1,6},{17,24,1,1},{24,24,1,5},{25,24,1,8},{26,24,1,4},
	{4,25,1,1},{12,25,1,6},{13,25,4,8},{17,25,1,6},{25,25,1,1},{11,26,1,5},
	{12,26,6,8},{18,26,1,5},{10,27,1,3},{11,27,2,8},{13,27,1,5},{14,27,2,8},
	{16,27,1,5},{17,27,2,8},{19,27,1,3},{10,28,1,2},{11,28,1,6},{12,28,1,4},
	{13,28,1,2},{14,28,2,8},{16,28,1,2},{17,28,1,4},{18,28,1,6},{19,28,1,2},
	{13,29,1,1},{14,29,2,7},{16,29,1,1},
}

-- Returns the Frames it created so their color can be changed together
-- later (the fly glyph dims when flight is paused). Only the color is
-- ever changed afterwards - each piece keeps the transparency it was
-- built with, which is what preserves the anti-aliased edges.
local function buildIconGlyph(parent, glyph, color)
	-- Centred from the glyph's own bounding box rather than the grid, so
	-- it stays centred even if a glyph doesn't quite reach every edge of
	-- its grid. Rounded to whole pixels to keep every Frame on the pixel
	-- lattice - see the note about rounding gaps above.
	local minX, maxX = math.huge, -math.huge
	local minY, maxY = math.huge, -math.huge
	for _, run in ipairs(glyph) do
		minX = math.min(minX, run[1])
		maxX = math.max(maxX, run[1] + run[3])
		minY = math.min(minY, run[2])
		maxY = math.max(maxY, run[2] + 1)
	end
	local originX = math.round((INDICATOR_ICON_SIZE - (maxX - minX) * ICON_CELL) / 2 - minX * ICON_CELL)
	local originY = math.round((INDICATOR_ICON_SIZE - (maxY - minY) * ICON_CELL) / 2 - minY * ICON_CELL)

	local pieces = {}
	for _, run in ipairs(glyph) do
		local px = Instance.new("Frame")
		px.BorderSizePixel = 0
		px.BackgroundColor3 = color
		px.BackgroundTransparency = 1 - (run[4] / ICON_ALPHA_LEVELS)
		px.Position = UDim2.new(0, originX + run[1] * ICON_CELL, 0, originY + run[2] * ICON_CELL)
		px.Size = UDim2.new(0, run[3] * ICON_CELL, 0, ICON_CELL)
		px.Parent = parent
		table.insert(pieces, px)
	end
	return pieces
end

-- Printed on join so "is Studio actually running the latest paste?" is
-- answerable from the Output window instead of by staring at the UI and
-- guessing. That question has cost several rounds of chasing bugs that
-- turned out to be a stale copy rather than a real fault, and the glyph
-- counts are the giveaway for the icons specifically: at the current
-- current traces they read plane=109 mute=261 freeze=279.
local BUILD_STAMP = "2026-09-16-c"
print(string.format(
	"[AdminClient] build %s | glyph runs: plane=%d mute=%d freeze=%d",
	BUILD_STAMP, #PLANE_GLYPH, #MUTE_GLYPH, #FREEZE_GLYPH
))

-- Fly gets LayoutOrder 1 (leftmost) per the existing "fly always takes
-- the topmost slot" preference carried over from the old vertical stack -
-- the rest keep their previous relative order, just reading left-to-
-- right instead of top-to-bottom now. Still a TextButton (not a plain
-- Frame like the others) since clicking it toggles fly on/off - see the
-- Fly section further down.
local flyIcon = Instance.new("TextButton")
flyIcon.Name = "FlyIcon"
flyIcon.Size = UDim2.new(0, INDICATOR_ICON_SIZE, 0, INDICATOR_ICON_SIZE)
flyIcon.BackgroundColor3 = BG_DARK
flyIcon.AutoButtonColor = false
flyIcon.Text = ""
flyIcon.LayoutOrder = 1
flyIcon.Visible = false
flyIcon.Parent = indicatorRow
Instance.new("UICorner", flyIcon).CornerRadius = RADIUS_CTRL

-- Traced from the plane artwork - see PLANE_GLYPH/buildIconGlyph above.
-- Colour reflects flyActive (bright while flying, dimmed while paused-
-- but-permitted), applied across every piece at once by
-- updateFlyIconState further down.
local flyGlyphPieces = buildIconGlyph(flyIcon, PLANE_GLYPH, ACCENT)

local freezeIcon = Instance.new("Frame")
freezeIcon.Name = "FreezeIcon"
freezeIcon.Size = UDim2.new(0, INDICATOR_ICON_SIZE, 0, INDICATOR_ICON_SIZE)
freezeIcon.BackgroundColor3 = BG_DARK
freezeIcon.LayoutOrder = 2
freezeIcon.Visible = false
freezeIcon.Parent = indicatorRow
Instance.new("UICorner", freezeIcon).CornerRadius = RADIUS_CTRL

-- Ice blue rather than the shared ACCENT red every other indicator uses -
-- "frozen" reads better cold, and it's the one status here that isn't a
-- moderation action, so it's worth telling apart at a glance.
buildIconGlyph(freezeIcon, FREEZE_GLYPH, FREEZE_BLUE)

-- An uploaded image rather than Frame shapes, same as the fly plane
-- above. Losing the old indicator's live "MUTED FOR: 6d 23h" countdown
-- text is a deliberate trade for the smaller footprint - the muted
-- player already heard the duration once, in the AdminNoticeGui popup at
-- the moment :mute happens; this is just a persistent "you're currently
-- muted" reminder, not a timer.
local muteIcon = Instance.new("Frame")
muteIcon.Name = "MuteIcon"
muteIcon.BackgroundColor3 = BG_DARK
muteIcon.Size = UDim2.new(0, INDICATOR_ICON_SIZE, 0, INDICATOR_ICON_SIZE)
muteIcon.LayoutOrder = 3
muteIcon.Visible = false
muteIcon.Parent = indicatorRow
Instance.new("UICorner", muteIcon).CornerRadius = RADIUS_CTRL

-- Traced from the crossed-out CHAT BUBBLE artwork - see MUTE_GLYPH/
-- buildIconGlyph above. A chat bubble, deliberately, not a microphone:
-- :mute silences typed chat, and this game has no voice chat at all, so
-- a crossed-out mic would be describing a feature that does not exist.
-- Drawn in ACCENT so it matches the other indicators; the source art is
-- black line work, invisible against BG_DARK if used as-is.
buildIconGlyph(muteIcon, MUTE_GLYPH, ACCENT)

-- Target-facing :controlplayer indicator - informational only (no
-- button on this side; only the controlling admin can stop it), same
-- small icon style as freeze/mute/fly.
local controlledIcon = Instance.new("Frame")
controlledIcon.Name = "ControlledIcon"
controlledIcon.Size = UDim2.new(0, INDICATOR_ICON_SIZE, 0, INDICATOR_ICON_SIZE)
controlledIcon.BackgroundColor3 = BG_DARK
controlledIcon.LayoutOrder = 4
controlledIcon.Visible = false
controlledIcon.Parent = indicatorRow
Instance.new("UICorner", controlledIcon).CornerRadius = RADIUS_CTRL

local controlledGlyph = Instance.new("TextLabel")
controlledGlyph.Name = "Glyph"
controlledGlyph.Size = UDim2.new(1, 0, 1, 0)
controlledGlyph.BackgroundTransparency = 1
controlledGlyph.Font = BODY_FONT
controlledGlyph.Text = "\u{21C4}" -- crossed arrows - your movement is being overridden
controlledGlyph.TextColor3 = ACCENT
controlledGlyph.TextSize = 16
controlledGlyph.Parent = controlledIcon

-- Admin-facing "Spectating: X" / "Controlling: X" bars - wider than the
-- plain icons above since they carry a name and a Stop button, but part
-- of the exact same centered row (parented straight into indicatorRow,
-- no separate ScreenGui of their own anymore). Declared here (well
-- before the Spectate/Control sections further down that actually wire
-- them up) so refreshIndicatorLayout below can fold them into the same
-- layout as freeze/mute/fly/controlled.
local function createActionIndicator(stopLabel, layoutOrder)
	-- Shrunk (420x40 down to 260x30) to actually fit the gap next to the
	-- native topbar row at the true top of the screen, rather than
	-- pushing this whole row below it - a wider bar was overlapping the
	-- Admin button. Labels below are set to short text ("Spectating: X",
	-- "Controlling: X") and TextTruncate handles anything still too long
	-- for a very long player name.
	local bar = Instance.new("Frame")
	bar.Size = UDim2.new(0, 260, 0, 30)
	bar.BackgroundColor3 = BG_DARK
	bar.BorderSizePixel = 0
	bar.LayoutOrder = layoutOrder
	bar.Visible = false
	bar.Parent = indicatorRow
	Instance.new("UICorner", bar).CornerRadius = RADIUS_CTRL

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -76, 1, 0)
	label.Position = UDim2.new(0, 10, 0, 0)
	label.BackgroundTransparency = 1
	label.Font = BODY_FONT
	label.TextColor3 = ACCENT
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = bar

	local stopBtn = Instance.new("TextButton")
	stopBtn.Size = UDim2.new(0, 60, 0, 22)
	stopBtn.Position = UDim2.new(1, -6, 0.5, 0)
	stopBtn.AnchorPoint = Vector2.new(1, 0.5)
	stopBtn.BackgroundColor3 = ACCENT
	stopBtn.AutoButtonColor = false
	stopBtn.Text = stopLabel
	stopBtn.Font = BODY_FONT
	stopBtn.TextColor3 = TEXT_MAIN
	stopBtn.TextSize = 10
	stopBtn.Parent = bar
	Instance.new("UICorner", stopBtn).CornerRadius = RADIUS_CTRL

	return bar, label, stopBtn
end

local spectateBar, spectateLabel, spectateStopBtn = createActionIndicator("STOP", 5)
local controlBar, controlLabel, controlStopBtn = createActionIndicator("STOP", 6)

-- Hover tooltip for the small icons above - they carry no text of their
-- own, so this is what actually says which is which. One shared floating
-- label (rather than one per icon) positioned fresh under whichever icon
-- is currently hovered, since only one can be hovered at a time anyway.
local tooltipLabel = Instance.new("TextLabel")
tooltipLabel.Name = "Tooltip"
-- Anchored to its own left edge, vertically centred: the icons run down
-- the left of the screen now, so the tooltip sits BESIDE the hovered one
-- rather than below it. Under a vertical stack it would have covered the
-- next icon down.
tooltipLabel.AnchorPoint = Vector2.new(0, 0.5)
tooltipLabel.BackgroundColor3 = BG_DARK
tooltipLabel.BorderSizePixel = 0
tooltipLabel.Font = BODY_FONT
tooltipLabel.TextColor3 = TEXT_MAIN
tooltipLabel.TextSize = 12
tooltipLabel.AutomaticSize = Enum.AutomaticSize.X
tooltipLabel.Size = UDim2.new(0, 0, 0, 22)
tooltipLabel.Visible = false
tooltipLabel.ZIndex = 10
-- Parented to whichever icon is hovered (see wireTooltip), not left
-- sitting in the ScreenGui. Starts with no parent so it isn't drawn
-- anywhere until something asks for it.
Instance.new("UICorner", tooltipLabel).CornerRadius = RADIUS_CTRL

local tooltipPadding = Instance.new("UIPadding")
tooltipPadding.PaddingLeft = UDim.new(0, 8)
tooltipPadding.PaddingRight = UDim.new(0, 8)
tooltipPadding.Parent = tooltipLabel

-- Reparented onto the hovered icon and positioned in THAT icon's own
-- coordinate space, rather than placed by absolute screen pixels.
--
-- The absolute-pixel version put the label tens of pixels above the icon
-- it belonged to. Mixing AbsolutePosition (which is measured against the
-- viewport) with a Position set inside a ScreenGui is a coordinate space
-- confusion waiting to happen, and it happened. Relative placement can't
-- drift: "my right edge, vertically centred" is true wherever the icon
-- ends up, so this keeps working if the column moves again.
local function wireTooltip(icon, text)
	icon.MouseEnter:Connect(function()
		tooltipLabel.Text = text
		tooltipLabel.Parent = icon
		tooltipLabel.Position = UDim2.new(1, 8, 0.5, 0)
		tooltipLabel.Visible = true
	end)
	icon.MouseLeave:Connect(function()
		-- Only hide if this icon still owns it - moving the mouse
		-- straight from one icon to the next fires the new icon's
		-- MouseEnter before the old one's MouseLeave, and without this
		-- check that stale leave would blank the tooltip that had just
		-- been claimed.
		if tooltipLabel.Parent ~= icon then return end
		tooltipLabel.Visible = false
	end)
end

wireTooltip(flyIcon, "Fly")
wireTooltip(freezeIcon, "Frozen")
wireTooltip(muteIcon, "Muted")
wireTooltip(controlledIcon, "Being controlled by staff")

-- Raw state from the server, independent of sceneBlocked - kept separate
-- so the underlying frozen/muted/flying/controlled truth doesn't get
-- lost just because the indicator is temporarily hidden behind a menu.
local isFrozen = false
local isMuted = false
local isControlled = false
-- True once :fly has granted flight - stays true even while the actual
-- flight mechanic is paused via the button below, since that's only a
-- local pause, not the server revoking the permission (see the Fly
-- section's own comment for why that distinction matters).
local flyPermission = false
-- nil while not muted; a unix timestamp for a timed mute; the string
-- "permanent" for a mute with no expiry - three distinct states, rather
-- than overloading nil/false, since "not muted" and "muted with no
-- expiry" both need to be told apart from an actual timestamp.
local muteExpiresAt = nil

-- Shows/hides however many of freeze/mute/fly/controlled/spectating/
-- controlling currently apply - the UIListLayout on indicatorRow (see
-- above) handles the actual centering/ordering by itself from each
-- icon's Visible flag and fixed LayoutOrder, so this only ever needs to
-- decide true/false per icon, never compute a position. spectateBar/
-- controlBar aren't gated on sceneBlocked - an admin mid-spectate/
-- control who opens the main menu should still see (and be able to hit)
-- Stop, rather than it silently vanishing.
local function refreshIndicatorLayout()
	-- Frozen/muted/fly all describe the ADMIN's own real character -
	-- while spectating or controlling someone else, that character is
	-- invisible and parked out of the way, so these would be describing
	-- (and the fly button would be controlling) something the admin
	-- isn't even looking at right now. Hidden for the duration, not
	-- cleared - the underlying frozen/muted/fly-permission state itself
	-- is untouched, so they reappear exactly as they were the moment
	-- spectating/controlling actually stops.
	local hiddenForSpectateOrControl = spectateBar.Visible or controlBar.Visible
	local showFreeze = isFrozen and not sceneBlocked and not hiddenForSpectateOrControl
	local showMute = isMuted and not sceneBlocked and not hiddenForSpectateOrControl
	local showFly = flyPermission and not sceneBlocked and not hiddenForSpectateOrControl
	-- "being controlled by staff" describes whichever OTHER player is
	-- being controlled right now, not the admin's own state - never
	-- hidden by the admin's own spectate/control activity.
	local showControlled = isControlled and not sceneBlocked
	freezeIcon.Visible = showFreeze
	muteIcon.Visible = showMute
	flyIcon.Visible = showFly
	controlledIcon.Visible = showControlled
end

onSceneBlockedChanged = refreshIndicatorLayout

AdminFreezeStatus.OnClientEvent:Connect(function(frozen)
	isFrozen = frozen
	refreshIndicatorLayout()
end)

local AdminControlTargetStatus = ReplicatedStorage:WaitForChild("AdminControlTargetStatus")
AdminControlTargetStatus.OnClientEvent:Connect(function(controlled)
	isControlled = controlled
	refreshIndicatorLayout()
	-- Belt-and-suspenders alongside the server's own god-mode protection
	-- while controlled - removes the Reset Character option entirely so
	-- there's no way to respawn out from under an active control
	-- session (which previously left the controlling admin's camera
	-- stuck looking at/driving a now-destroyed character).
	pcall(function()
		StarterGui:SetCore("ResetButtonCallback", not controlled)
	end)
	-- Disables this player's OWN default character controller for the
	-- duration - without this, the target could still walk themselves
	-- around with their own WASD at the same time as the admin's
	-- Humanoid:Move calls, which is both a "why can I still move while
	-- controlled" bug and very likely the cause of the reported
	-- animation stutter ("arms spasming")/input delay: two independent
	-- sources both calling Humanoid:Move on the same character every
	-- frame fight each other for which one's MoveDirection actually
	-- sticks. Same mechanism (and same PlayerModule) this script already
	-- uses to hand its OWN movement over to the fly controller above.
	if playerControls then
		if controlled then
			playerControls:Disable()
		else
			playerControls:Enable()
		end
	end
end)

AdminMuteStatus.OnClientEvent:Connect(function(muted, expiresAt)
	isMuted = muted
	muteExpiresAt = muted and (expiresAt or "permanent") or nil
	refreshIndicatorLayout()
end)

-- Ticks once a second purely to clear isMuted the moment a timed mute's
-- expiry passes - the icon itself has no live countdown text to refresh
-- (see muteIcon above), so this only ever needs to check, not redraw
-- anything, on the seconds where nothing has expired yet. Checks isMuted
-- (not muteIcon.Visible) so an expiry occurring while the icon happens
-- to be hidden behind a menu still clears isMuted correctly instead of
-- leaving it stuck true.
task.spawn(function()
	while true do
		task.wait(1)
		if isMuted and muteExpiresAt and muteExpiresAt ~= "permanent" and os.time() >= muteExpiresAt then
			isMuted = false
			muteExpiresAt = nil
			refreshIndicatorLayout()
		end
	end
end)

-- =====================================================================
-- Fly - :fly's actual flight control. This has to live in this
-- always-running, unconditional part of the script (not inside
-- buildPanel, which only ever builds for confirmed staff) because :fly
-- can target ANY player, not just admins. A real Tool with its own
-- LocalScript can't be built from a running server script (Source isn't
-- scriptable at runtime), so this reuses AdminClient.lua itself instead:
-- PlatformStand stops the normal walk/jump state machine, and a
-- BodyVelocity + BodyGyro on the HumanoidRootPart get driven every
-- RenderStepped frame from WASD (camera-relative) plus Space/Ctrl for
-- up/down.
-- =====================================================================
local AdminSetFlying = ReplicatedStorage:WaitForChild("AdminSetFlying")

local FLY_SPEED = 60
local flyConnection = nil
local flyBodyVelocity = nil
local flyBodyGyro = nil
-- Captured right before flight starts, restored when it stops. WalkSpeed
-- has no effect on the BodyVelocity-driven movement below anyway
-- (PlatformStand takes the Humanoid out of its normal ground-based state
-- machine entirely) - this is just about leaving it exactly as it was
-- found once flight ends.
local flyPreWalkSpeed = 16

-- playerControls (shared with the :controlplayer target-status handler
-- above) is set up once near the top of this script - reads raw
-- Shift/WASD key state directly and plays its own run animation + a
-- slight camera zoom whenever Shift is held, entirely independent of the
-- Humanoid's PlatformStand state, which is exactly what a WalkSpeed lock
-- alone can't fix while flying (it isn't reacting to WalkSpeed at all).

local function stopFlying()
	if flyConnection then
		flyConnection:Disconnect()
		flyConnection = nil
	end
	if flyBodyVelocity then
		flyBodyVelocity:Destroy()
		flyBodyVelocity = nil
	end
	if flyBodyGyro then
		flyBodyGyro:Destroy()
		flyBodyGyro = nil
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.WalkSpeed = flyPreWalkSpeed
	end
	if playerControls then
		playerControls:Enable()
	end
end

local function startFlying()
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	-- Captured BEFORE stopFlying's own cleanup below (which itself resets
	-- WalkSpeed to flyPreWalkSpeed) - otherwise a stale flyPreWalkSpeed
	-- left over from an earlier flight (or its default of 16) would get
	-- written over the character's TRUE current speed before this ever
	-- got a chance to read it, permanently losing whatever their real
	-- WalkSpeed actually was (e.g. from a speed-boost gamepass).
	if humanoid then
		flyPreWalkSpeed = humanoid.WalkSpeed
	end
	stopFlying()
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or not hrp then return end

	humanoid.PlatformStand = true
	if playerControls then
		playerControls:Disable()
	end

	flyBodyVelocity = Instance.new("BodyVelocity")
	flyBodyVelocity.MaxForce = Vector3.new(1e5, 1e5, 1e5)
	flyBodyVelocity.Velocity = Vector3.new(0, 0, 0)
	flyBodyVelocity.Parent = hrp

	flyBodyGyro = Instance.new("BodyGyro")
	flyBodyGyro.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
	flyBodyGyro.D = 100
	flyBodyGyro.CFrame = hrp.CFrame
	flyBodyGyro.Parent = hrp

	flyConnection = RunService.RenderStepped:Connect(function()
		if not flyBodyVelocity or not hrp.Parent then return end
		local camera = workspace.CurrentCamera
		if not camera then return end

		humanoid.WalkSpeed = flyPreWalkSpeed

		local moveVector = Vector3.new(0, 0, 0)
		if UIS:IsKeyDown(Enum.KeyCode.W) then moveVector += camera.CFrame.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.S) then moveVector -= camera.CFrame.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.A) then moveVector -= camera.CFrame.RightVector end
		if UIS:IsKeyDown(Enum.KeyCode.D) then moveVector += camera.CFrame.RightVector end
		-- Space/Ctrl only for up/down - Shift is deliberately NOT bound to
		-- anything here any more (it used to double as "descend"), which
		-- is exactly what was fighting with holding Shift out of habit to
		-- run faster while flying.
		if UIS:IsKeyDown(Enum.KeyCode.Space) then moveVector += Vector3.new(0, 1, 0) end
		if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then moveVector -= Vector3.new(0, 1, 0) end

		if moveVector.Magnitude > 0 then
			moveVector = moveVector.Unit * FLY_SPEED
		end
		flyBodyVelocity.Velocity = moveVector
		flyBodyGyro.CFrame = camera.CFrame
	end)
end

-- flyActive tracks the ACTUAL flight mechanic (started/stopped by the
-- indicator button below, independent of the server-granted permission);
-- flyPermission (declared earlier, alongside isFrozen/isMuted, so
-- refreshIndicatorLayout can read it) tracks whether :fly currently
-- grants flight at all. Clicking "Disable Fly" only ever touches
-- flyActive - the admin's permission stays on until :fly is run again,
-- which is what lets "Enable Fly" instantly turn it back on with no
-- server round-trip needed.
local flyActive = false

-- No room for "ENABLE"/"DISABLE FLY" text on a small square icon -
-- bright ACCENT while actually flying, dimmed TEXT_DIM while paused-but-
-- permitted, same on/off distinction the old text swap made.
local function updateFlyIconState()
	-- ACCENT while actually flying, TEXT_DIM while paused-but-permitted -
	-- same on/off distinction the old "ENABLE/DISABLE FLY" text made,
	-- applied across every traced piece of the glyph at once.
	local color = flyActive and ACCENT or TEXT_DIM
	for _, piece in ipairs(flyGlyphPieces) do
		piece.BackgroundColor3 = color
	end
end

flyIcon.MouseButton1Click:Connect(function()
	if not flyPermission then return end
	flyActive = not flyActive
	if flyActive then startFlying() else stopFlying() end
	updateFlyIconState()
end)

AdminSetFlying.OnClientEvent:Connect(function(enabled)
	flyPermission = enabled
	flyActive = enabled
	if enabled then
		startFlying()
	else
		stopFlying()
	end
	updateFlyIconState()
	refreshIndicatorLayout()
end)

-- Rebuilds the fly constraints on a respawn if still actively flying
-- (paused-but-permitted doesn't get rebuilt - flyConnection is already
-- nil in that case, same as if flying had never started), rather than
-- silently doing nothing because they were parented to the OLD
-- (now-destroyed) HumanoidRootPart.
player.CharacterAdded:Connect(function()
	if flyConnection then
		startFlying()
	end
end)

-- =====================================================================
-- Teleport cover - a plain full-screen black fade, used by both Spectate
-- and Control Player below to hide the moment their character actually
-- gets teleported to/from the server's out-of-the-way "limbo" spot
-- (AdminServer.lua's SPECTATE_LIMBO_CFRAME). Without this, that teleport
-- (and the camera cutting to/from it) showed up as a brief flash of
-- void, plus a beat of noticeably off lighting right after (dynamic
-- lighting/shadows needing a moment to settle after a huge instant
-- jump) - both fully hidden behind this cover instead.
-- =====================================================================
local teleportCoverGui = Instance.new("ScreenGui")
teleportCoverGui.Name = "AdminTeleportCoverGui"
teleportCoverGui.ResetOnSpawn = false
teleportCoverGui.IgnoreGuiInset = true
teleportCoverGui.ScreenInsets = Enum.ScreenInsets.None
teleportCoverGui.DisplayOrder = 60
teleportCoverGui.Enabled = false
teleportCoverGui.Parent = playerGui

-- The cover is a SLIDING PANEL, not a fade to black - the same
-- transition the main menu plays when you press Play (MainScript.lua's
-- Transition): a BG_DARK panel, oversized so no edge is ever visible,
-- sliding in from above and then continuing out through the bottom.
--
-- EVERYTHING that hides a teleport uses this one panel - :jail and its
-- release, :spectate, :controlplayer. They used to differ: a wipe for
-- the menu, a hard cut to black for the jail, a fade for spectate. Three
-- different ways of taking the screen away made one game feel like
-- three.
--
-- The overscan matters: the panel is larger than the screen on both
-- axes, and its start position is pushed up by its own overscan so its
-- bottom edge begins flush with the top of the screen instead of already
-- hanging into view. Same reasoning as the comment on MainScript's copy.
local TRANSITION_OVERSCAN = 80
local TRANSITION_SLIDE_TIME = 0.6
local TRANSITION_TWEEN = TweenInfo.new(TRANSITION_SLIDE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

local TRANSITION_ABOVE = UDim2.new(0.5, 0, -1, -TRANSITION_OVERSCAN * 2)
local TRANSITION_COVER = UDim2.new(0.5, 0, 0, -TRANSITION_OVERSCAN)
local TRANSITION_BELOW = UDim2.new(0.5, 0, 1, 0)

local transitionPanel = Instance.new("Frame")
transitionPanel.Name = "TransitionPanel"
transitionPanel.Size = UDim2.new(1, TRANSITION_OVERSCAN * 2, 1, TRANSITION_OVERSCAN * 2)
transitionPanel.AnchorPoint = Vector2.new(0.5, 0)
transitionPanel.Position = TRANSITION_ABOVE
transitionPanel.BackgroundColor3 = BG_DARK
transitionPanel.BorderSizePixel = 0
transitionPanel.Parent = teleportCoverGui

-- Roblox rebuilds its lighting around wherever the camera is, and after
-- an instant jump of hundreds or thousands of studs that rebuild takes
-- a beat. Until it finishes, the world renders with the lighting from
-- where the camera USED to be - which is why coming back from the jail
-- (a sealed box 300 studs underground, so as dark as it gets) or from
-- spectate limbo arrived with every shadow far too dark, then visibly
-- snapped correct a second or two later.
--
-- There's no event for "lighting has caught up", so the cover just
-- stays down long enough to outlast it. This has to finish BEFORE the
-- reveal starts, not during it, or the shadow snap happens in plain
-- sight partway through the slide.
--
-- Note this is measured from when the panel finishes sliding IN, not
-- from when the teleport lands - and the server deliberately holds the
-- teleport back until the panel is down (AdminServer.lua's
-- JAIL_COVER_TIME). So the time actually spent covered AFTER the move is
-- this value minus that hold, which is why 1.2 wasn't enough even though
-- it sounded like it should be: it only bought about a second of cover
-- on the far side of the teleport, and the rebuild takes closer to two.
--
-- This is the single dial for how long every transition holds. Raising
-- it hides more of the lighting rebuild at the cost of a longer
-- transition; a beat of held transition reads as deliberate, while a
-- shadow snap reads as the game breaking.
local LIGHTING_SETTLE_TIME = 1.8

local teleportCoverGeneration = 0
-- Whether the panel is currently over the screen (or on its way there).
-- revealScreen checks this so a reveal that arrives without a matching
-- cover doesn't sweep a panel across a screen that never needed hiding.
local screenCovered = false

-- Slides the panel down over the screen and returns once it's fully
-- covered. Call right before sending :spectate/:controlplayer (or
-- clicking Stop), so the screen is already hidden by the time the
-- server's teleport lands rather than reacting to it afterwards.
local function coverScreen()
	teleportCoverGeneration += 1
	local myGeneration = teleportCoverGeneration
	screenCovered = true
	teleportCoverGui.Enabled = true
	transitionPanel.Position = TRANSITION_ABOVE
	local tween = TweenService:Create(transitionPanel, TRANSITION_TWEEN, {Position = TRANSITION_COVER})
	tween:Play()
	tween.Completed:Wait()
	-- A newer cover/reveal may have taken over while this one was
	-- mid-slide (Stop clicked again, a second spectate started) - a stale
	-- call must not fight over the panel or the Gui.
	if myGeneration ~= teleportCoverGeneration then return end
end

-- Holds the cover while lighting settles, then slides the panel the rest
-- of the way out through the bottom of the screen. Call once whatever
-- was being hidden (the teleport, the camera cut) is actually done.
local function revealScreen()
	teleportCoverGeneration += 1
	local myGeneration = teleportCoverGeneration

	if not screenCovered then
		-- Nothing was covering the screen - a reveal without a cover,
		-- e.g. the safety timeout firing after a refused command that
		-- never got as far as hiding anything. Sliding from wherever the
		-- panel sits would wipe across a perfectly visible screen.
		transitionPanel.Position = TRANSITION_ABOVE
		teleportCoverGui.Enabled = false
		return
	end

	task.wait(LIGHTING_SETTLE_TIME)
	if myGeneration ~= teleportCoverGeneration then return end
	local tween = TweenService:Create(transitionPanel, TRANSITION_TWEEN, {Position = TRANSITION_BELOW})
	tween:Play()
	tween.Completed:Wait()
	if myGeneration ~= teleportCoverGeneration then return end
	screenCovered = false
	transitionPanel.Position = TRANSITION_ABOVE
	teleportCoverGui.Enabled = false
end

-- :spectate/:controlplayer fade the screen out the moment the command is
-- SENT, before the server has said whether it'll actually happen - that's
-- deliberate, so the teleport is already hidden by the time it lands. The
-- catch is that a rejected command produces no confirmation at all, and
-- with nothing left to trigger the fade back in the screen just stayed
-- black permanently. That's reachable from several directions: targeting
-- yourself, a name that matches nobody, a target whose character isn't
-- loaded, or the server simply never answering.
--
-- So a fade started that way is tracked as "pending" until something
-- resolves it - the confirmation, an error, or the timeout as a last
-- resort. Whichever gets there first wins; the rest no-op.
local TELEPORT_FADE_TIMEOUT = 5
local teleportFadePending = false

-- BLOCKS until the screen is fully covered, then returns.
--
-- It used to task.spawn the cover and return immediately, so the command
-- went to the server while the panel was still sliding - and with a
-- 0.6s slide against a round trip measured in frames, the server won
-- every time. You watched yourself teleport and the camera cut, and THEN
-- the black panel came down over the aftermath. Exactly backwards.
--
-- The timeout is armed before the wait rather than after, so the five
-- seconds covers the slide as well as the round trip.
local function beginTeleportFade()
	teleportFadePending = true
	task.delay(TELEPORT_FADE_TIMEOUT, function()
		if not teleportFadePending then return end
		teleportFadePending = false
		task.spawn(revealScreen)
	end)
	coverScreen()
end

-- reveal = true when nothing else is going to fade the screen back in
-- (i.e. the command failed). On the success path the caller does its own
-- reveal once the camera is in place, so this only clears the flag.
local function clearTeleportFade(reveal)
	if not teleportFadePending then return end
	teleportFadePending = false
	if reveal then
		task.spawn(revealScreen)
	end
end

-- Fired by the server at a player it has just teleported a long way
-- without them asking - :jail, and the release back to spawn. That's the
-- opposite situation to :spectate/:controlplayer: there, the fade starts
-- when the admin SENDS the command, so it's already covering the screen
-- before the teleport lands. Here the move has already happened by the
-- time this arrives, so the cover snaps straight to opaque instead of
-- tweening - a quarter-second fade-out would just show the inside of the
-- jail first, which is the thing being hidden.
--
-- Everything after that is the normal reveal, which is what puts the
-- lighting rebuild (see LIGHTING_SETTLE_TIME) behind the cover as well.
-- Runs for every player, not just staff: being jailed is something that
-- happens TO someone, and this whole cover section sits outside
-- buildPanel for exactly that reason.
-- Fired by the server at a player it has just teleported a long way
-- without them asking - :jail, and the release back to spawn. The
-- server holds the teleport back until the panel is down (see
-- JAIL_COVER_TIME there), so the move happens behind the wipe rather
-- than in front of it - otherwise the panel would slide in over a jail
-- the player had already seen, and the reveal would show them nothing
-- new.
--
-- Runs for every player, not just staff: being jailed is something that
-- happens TO someone, which is why this whole cover section sits
-- outside buildPanel.
AdminScreenFade.OnClientEvent:Connect(function()
	-- Clears any pending spectate/control fade so its safety timeout
	-- can't fire mid-jail and reveal the screen early.
	teleportFadePending = false
	task.spawn(function()
		coverScreen()
		revealScreen()
	end)
end)

-- =====================================================================
-- Spectate - the spectating admin's OWN camera locks onto the target;
-- the server separately makes them invisible and frozen for the
-- duration and restores their exact previous position/invis/frozen
-- state the moment they stop (see AdminServer.lua's startSpectating/
-- stopSpectatingServer) - this only ever applies to whichever client
-- this script happens to be running on, since the server already
-- verified the firer was a permitted admin before ever sending this.
-- =====================================================================
local AdminSpectate = ReplicatedStorage:WaitForChild("AdminSpectate")
local AdminStopSpectating = ReplicatedStorage:WaitForChild("AdminStopSpectating")

local function stopSpectatingCamera()
	local camera = workspace.CurrentCamera
	if not camera then return end
	camera.CameraType = Enum.CameraType.Custom
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
end

AdminSpectate.OnClientEvent:Connect(function(target)
	if not target then
		clearTeleportFade(false)
		stopSpectatingCamera()
		spectateBar.Visible = false
		refreshIndicatorLayout()
		task.spawn(revealScreen)
		return
	end
	local camera = workspace.CurrentCamera
	local character = target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not camera or not humanoid then
		-- Nothing to lock the camera onto, so there's no spectate to
		-- reveal - but the screen is still covered from the send, and
		-- bailing out silently here is another way it used to be left
		-- black for good.
		clearTeleportFade(true)
		return
	end
	clearTeleportFade(false)
	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = humanoid
	spectateLabel.Text = "Spectating: " .. target.Name
	spectateBar.Visible = true
	refreshIndicatorLayout()
	task.spawn(revealScreen)
end)

spectateStopBtn.MouseButton1Click:Connect(function()
	-- Fades to black FIRST (blocking this click handler's own coroutine,
	-- not the rest of the script) so the restore-teleport that follows
	-- never becomes visible at all, rather than reacting after the fact.
	coverScreen()
	-- Hidden immediately client-side rather than waiting on the server's
	-- own AdminSpectate(nil) echo - gives instant feedback that the click
	-- actually registered even if that round trip is ever slow, and the
	-- server's echo (which also resets the camera) still arrives right
	-- after to finish the job.
	stopSpectatingCamera()
	spectateBar.Visible = false
	refreshIndicatorLayout()
	AdminStopSpectating:FireServer()
end)

-- =====================================================================
-- Control player - :controlplayer locks the admin's camera onto the
-- target (same idea as spectate) and forwards the admin's own WASD to
-- the server every Heartbeat as a camera-relative direction, since only
-- the server can actually move another player's character. Ends via the
-- "Stop Controlling" button, which the server also falls back to if the
-- admin or the target disconnects mid-control.
-- =====================================================================
local AdminControlPlayer = ReplicatedStorage:WaitForChild("AdminControlPlayer")
local AdminControlMove = ReplicatedStorage:WaitForChild("AdminControlMove")
local AdminStopControlling = ReplicatedStorage:WaitForChild("AdminStopControlling")

local controlMoveConnection = nil

local function stopControllingCamera()
	if controlMoveConnection then
		controlMoveConnection:Disconnect()
		controlMoveConnection = nil
	end
	local camera = workspace.CurrentCamera
	if not camera then return end
	camera.CameraType = Enum.CameraType.Custom
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
end

AdminControlPlayer.OnClientEvent:Connect(function(target)
	if not target then
		clearTeleportFade(false)
		stopControllingCamera()
		controlBar.Visible = false
		refreshIndicatorLayout()
		task.spawn(revealScreen)
		return
	end
	local camera = workspace.CurrentCamera
	local character = target.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not camera or not humanoid then
		-- Same as spectate above - nothing to control, but the screen is
		-- still covered from the send, so it has to be revealed here.
		clearTeleportFade(true)
		return
	end
	clearTeleportFade(false)
	camera.CameraType = Enum.CameraType.Custom
	camera.CameraSubject = humanoid
	controlLabel.Text = "Controlling: " .. target.Name
	controlBar.Visible = true
	refreshIndicatorLayout()
	task.spawn(revealScreen)

	if controlMoveConnection then controlMoveConnection:Disconnect() end
	-- RenderStepped (not Heartbeat) - fires as early as possible each
	-- frame, shaving a little more perceived input delay off on top of
	-- AdminControlMove's own switch to an UnreliableRemoteEvent.
	controlMoveConnection = RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		if not cam then return end
		local moveVector = Vector3.new(0, 0, 0)
		if UIS:IsKeyDown(Enum.KeyCode.W) then moveVector += cam.CFrame.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.S) then moveVector -= cam.CFrame.LookVector end
		if UIS:IsKeyDown(Enum.KeyCode.A) then moveVector -= cam.CFrame.RightVector end
		if UIS:IsKeyDown(Enum.KeyCode.D) then moveVector += cam.CFrame.RightVector end
		moveVector = Vector3.new(moveVector.X, 0, moveVector.Z)
		if moveVector.Magnitude > 0 then
			moveVector = moveVector.Unit
		end
		local jumpRequested = UIS:IsKeyDown(Enum.KeyCode.Space)
		AdminControlMove:FireServer(moveVector, jumpRequested)
	end)
end)

controlStopBtn.MouseButton1Click:Connect(function()
	-- Same teleport-cover + immediate client-side feedback as the
	-- spectate Stop button above.
	coverScreen()
	stopControllingCamera()
	controlBar.Visible = false
	refreshIndicatorLayout()
	AdminStopControlling:FireServer()
end)

-- AdminInventoryList's own listener is declared further down, right
-- after showListPopup itself (a local function, only visible from its
-- own declaration onward) - alongside every other master-list listener
-- that also calls it.
local AdminInventoryList = ReplicatedStorage:WaitForChild("AdminInventoryList")
local AdminInventoryRemoveItem = ReplicatedStorage:WaitForChild("AdminInventoryRemoveItem")

-- Tracked at the top level (not inside buildPanel) since showListPopup
-- is also top-level and both need to read/write it: true while any
-- master list (:warnlist/:banlist/:mutelist) or the per-user warnings
-- detail is on screen, so the admin panel's own Close button can be
-- disabled for as long as one of these is open - closing the whole
-- panel out from under an open list was easy to do by accident and
-- lost your place in it.
local listPopupOpen = false

-- Bumped every time showListPopup runs, and captured by each call's own
-- closeListPopup closure as myGeneration. closeListPopup's close tween
-- is a blocking coroutine (tween:Play() + Completed:Wait()) - if a
-- second list command was clicked while an older list's close was still
-- mid-animation, that older coroutine would eventually wake back up and
-- stomp listPopupOpen back to false even though a newer popup had since
-- taken over, wrongly re-enabling the admin panel's Close button (which
-- only checks listPopupOpen) while a list was still visibly open. This
-- was the cause of the reported "click a new command and it flashes
-- shut" - the panel's Close button was firing even though what looked
-- like a single click landed. The token lets a superseded close no-op
-- instead of touching state that no longer belongs to it.
local listPopupGeneration = 0

-- =====================================================================
-- List popup - covers the per-user warnings detail and the three
-- master lists (:warnlist/:banlist/:mutelist), all drawn by this one
-- scrollable component (title + rows of Line1/Line2 + an optional
-- per-row action button) instead of four near-identical UI builders.
-- onAction, if given, is called with that row's full entry table when
-- its action button is clicked - each caller below wires that to
-- whatever that button should actually do (remove a warning, or open
-- the ban/mute detail-edit popup, or drill into one user's warnings).
-- searchable adds a live username filter box above the list - only
-- meaningful for the three master lists, which otherwise have no way
-- to jump straight to one name in a long list.
-- =====================================================================
-- How many rows one page of a paginated list shows. Only the command
-- logs pass paginate=true - the ban/mute/warn lists are short enough to
-- scroll, and breaking a 12-entry ban list across pages would be worse
-- than leaving it alone.
local LIST_PAGE_SIZE = 100
local LIST_PAGER_HEIGHT = 34

local function showListPopup(title, entries, actionLabel, onAction, searchable, searchSuggestions, paginate)
	-- A Modify save/duration change closes the detail popup and the
	-- server re-fires the list to refresh it - this call re-enters here
	-- with the list gui already open. Replaying the slide-up entrance
	-- for that case looked like the list had closed and reopened, when
	-- really it never went anywhere - so a refresh while already open
	-- rebuilds in place at the open position with no animation, and
	-- only a genuine fresh :banlist/:mutelist/:warnlist gets the tween.
	local wasAlreadyOpen = playerGui:FindFirstChild("AdminListGui") ~= nil
	local existing = playerGui:FindFirstChild("AdminListGui")
	if existing then existing:Destroy() end
	listPopupOpen = true
	listPopupGeneration += 1
	local myGeneration = listPopupGeneration

	local gui = Instance.new("ScreenGui")
	gui.Name = "AdminListGui"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.DisplayOrder = 45
	gui.Parent = playerGui

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.new(1, 0, 1, 0)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.5
	backdrop.BorderSizePixel = 0
	-- Active=true so this backdrop actually catches clicks instead of
	-- letting them fall through - a Frame defaults Active to false
	-- (unlike a TextButton), which only blocks NOTHING: it renders on
	-- top but a click at that screen position keeps looking for the
	-- next interactive object underneath and finds it, which is why the
	-- admin panel's sidebar commands were still clickable right through
	-- a popup visibly covering them.
	backdrop.Active = true
	backdrop.Parent = gui

	-- Slides up from off-screen like the admin panel itself, rather than
	-- just appearing instantly.
	local PANEL_CLOSED_POS = UDim2.new(0.5, 0, 1.4, 0)
	local PANEL_OPEN_POS = UDim2.new(0.5, 0, 0.5, 0)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = wasAlreadyOpen and PANEL_OPEN_POS or PANEL_CLOSED_POS
	panel.Size = UDim2.new(0, 440, 0, 360)
	panel.BackgroundColor3 = BG_DARK
	panel.BorderSizePixel = 0
	panel.Parent = gui
	Instance.new("UICorner", panel).CornerRadius = RADIUS_PANEL
	outline(panel)
	local disconnectScale = attachAutoScale(panel)
	if not wasAlreadyOpen then
		TweenService:Create(panel, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position = PANEL_OPEN_POS}):Play()
	end

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -100, 0, 28)
	titleLabel.Position = UDim2.new(0, 20, 0, 16)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = BODY_FONT
	titleLabel.TextColor3 = ACCENT
	titleLabel.TextSize = 17
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.Text = title
	titleLabel.Parent = panel

	local function closeListPopup()
		-- If a newer showListPopup call has since taken over (bumping
		-- listPopupGeneration), this close belongs to an already-
		-- superseded popup - back out without touching listPopupOpen or
		-- destroying anything, since gui here isn't the current popup
		-- any more. See the listPopupGeneration comment above for why.
		if myGeneration ~= listPopupGeneration then return end
		listPopupOpen = false
		disconnectScale()
		local tween = TweenService:Create(panel, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = PANEL_CLOSED_POS})
		tween:Play()
		tween.Completed:Wait()
		if myGeneration == listPopupGeneration then
			gui:Destroy()
		end
	end

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0, 70, 0, 28)
	closeBtn.Position = UDim2.new(1, -20, 0, 16)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.BackgroundColor3 = ACCENT
	closeBtn.AutoButtonColor = false
	closeBtn.Text = "Close"
	closeBtn.Font = BODY_FONT
	closeBtn.TextColor3 = TEXT_MAIN
	closeBtn.TextSize = 12
	closeBtn.Parent = panel
	Instance.new("UICorner", closeBtn).CornerRadius = RADIUS_CTRL
	closeBtn.MouseButton1Click:Connect(closeListPopup)

	local hasSuggestions = searchSuggestions and #searchSuggestions > 0
	local searchBox = nil
	local searchDropdown = nil
	if searchable then
		local searchHolder = Instance.new("Frame")
		searchHolder.Size = UDim2.new(1, -32, 0, 32)
		searchHolder.Position = UDim2.new(0, 16, 0, 52)
		searchHolder.BackgroundColor3 = BG_ROW
		searchHolder.BorderSizePixel = 0
		searchHolder.Parent = panel
		Instance.new("UICorner", searchHolder).CornerRadius = RADIUS_CTRL

		searchBox = Instance.new("TextBox")
		searchBox.Size = UDim2.new(1, -20, 1, 0)
		searchBox.Position = UDim2.new(0, 10, 0, 0)
		searchBox.BackgroundTransparency = 1
		searchBox.Font = BODY_FONT
		searchBox.TextColor3 = TEXT_MAIN
		searchBox.TextSize = 13
		searchBox.TextXAlignment = Enum.TextXAlignment.Left
		searchBox.PlaceholderText = hasSuggestions and "Search by command, e.g. bring..." or "Search by username..."
		searchBox.PlaceholderColor3 = TEXT_DIM
		searchBox.ClearTextOnFocus = false
		searchBox.Text = ""
		searchBox.Parent = searchHolder

		-- Autocomplete for the command names actually present in this
		-- log, same scrollable-dropdown pattern as the admin command
		-- input's own suggestions - only built at all when the caller
		-- passed a suggestion list (the master ban/mute/warn lists don't,
		-- since a partial username has no fixed list to suggest from).
		if hasSuggestions then
			searchDropdown = Instance.new("ScrollingFrame")
			searchDropdown.Position = UDim2.new(0, 16, 0, 86)
			searchDropdown.Size = UDim2.new(1, -32, 0, 0)
			searchDropdown.BackgroundColor3 = BG_HOVER
			searchDropdown.BorderSizePixel = 0
			searchDropdown.ClipsDescendants = true
			searchDropdown.Visible = false
			searchDropdown.ZIndex = 5
			searchDropdown.ScrollBarThickness = 5
			searchDropdown.CanvasSize = UDim2.new(0, 0, 0, 0)
			searchDropdown.AutomaticCanvasSize = Enum.AutomaticSize.Y
			searchDropdown.Parent = panel
			Instance.new("UICorner", searchDropdown).CornerRadius = RADIUS_CTRL

			local searchDropdownLayout = Instance.new("UIListLayout")
			searchDropdownLayout.SortOrder = Enum.SortOrder.LayoutOrder
			searchDropdownLayout.Parent = searchDropdown
		end
	end

	-- Room carved out of the list's height for the pager row, when there
	-- is one. Reserved whether or not the pager is currently showing
	-- itself, so a search that narrows the results down to one page
	-- doesn't make the list jump taller and then shorter again.
	local listBottomInset = paginate and (LIST_PAGER_HEIGHT + 12) or 0

	local list = Instance.new("ScrollingFrame")
	list.Size = searchable and UDim2.new(1, -32, 1, -110 - listBottomInset) or UDim2.new(1, -32, 1, -70 - listBottomInset)
	list.Position = searchable and UDim2.new(0, 16, 0, 96) or UDim2.new(0, 16, 0, 56)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 5
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.Parent = panel

	local listLayout = Instance.new("UIListLayout")
	listLayout.Padding = UDim.new(0, 6)
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Parent = list

	-- Forward-declared, NOT `local function renderRows` further down. The
	-- pager buttons built just below need to call it, and a `local
	-- function` declared later would create a second, different local
	-- that those click handlers never see - they'd capture nil and the
	-- buttons would silently do nothing. Declaring the name up here and
	-- assigning to it later is what makes them refer to the same thing.
	local renderRows

	local currentPage = 1
	local pageCount = 1
	local updatePager = nil

	if paginate then
		local pager = Instance.new("Frame")
		pager.Name = "Pager"
		pager.AnchorPoint = Vector2.new(0.5, 1)
		pager.Position = UDim2.new(0.5, 0, 1, -12)
		pager.Size = UDim2.new(1, -32, 0, LIST_PAGER_HEIGHT)
		pager.BackgroundTransparency = 1
		pager.Parent = panel

		local function pagerButton(text, alignRight)
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(0, 78, 1, 0)
			btn.AnchorPoint = Vector2.new(alignRight and 1 or 0, 0)
			btn.Position = UDim2.new(alignRight and 1 or 0, 0, 0, 0)
			btn.BackgroundColor3 = BG_ROW
			btn.AutoButtonColor = false
			btn.Font = BODY_FONT
			btn.TextColor3 = TEXT_MAIN
			btn.TextSize = 12
			btn.Text = text
			btn.Parent = pager
			Instance.new("UICorner", btn).CornerRadius = RADIUS_CTRL
			return btn
		end

		local prevBtn = pagerButton("\u{2039} Prev", false)
		local nextBtn = pagerButton("Next \u{203A}", true)

		local pageLabel = Instance.new("TextLabel")
		pageLabel.AnchorPoint = Vector2.new(0.5, 0)
		pageLabel.Position = UDim2.new(0.5, 0, 0, 0)
		pageLabel.Size = UDim2.new(1, -180, 1, 0)
		pageLabel.BackgroundTransparency = 1
		pageLabel.Font = BODY_FONT
		pageLabel.TextColor3 = TEXT_DIM
		pageLabel.TextSize = 12
		pageLabel.Parent = pager

		updatePager = function(total)
			-- The whole row hides itself when everything fits on one
			-- page - a lone "Page 1 / 1" next to two dead buttons is
			-- just noise. The space it occupied stays reserved (see
			-- listBottomInset) so nothing shifts.
			pager.Visible = pageCount > 1
			pageLabel.Text = string.format("Page %d / %d  -  %d entries", currentPage, pageCount, total)
			-- Dimmed rather than hidden at the ends, so the buttons keep
			-- their positions instead of appearing and disappearing.
			prevBtn.TextTransparency = (currentPage > 1) and 0 or 0.6
			nextBtn.TextTransparency = (currentPage < pageCount) and 0 or 0.6
		end

		local function step(delta)
			local target = math.clamp(currentPage + delta, 1, pageCount)
			if target == currentPage then return end
			currentPage = target
			renderRows(searchBox and searchBox.Text or "")
		end

		prevBtn.MouseButton1Click:Connect(function() step(-1) end)
		nextBtn.MouseButton1Click:Connect(function() step(1) end)
	end

	local function buildRow(entry, order)
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 54)
		row.BackgroundColor3 = BG_ROW
		row.LayoutOrder = order
		row.Parent = list
		Instance.new("UICorner", row).CornerRadius = RADIUS_CTRL

		local line1Label = Instance.new("TextLabel")
		line1Label.Size = UDim2.new(1, -100, 0, 20)
		line1Label.Position = UDim2.new(0, 10, 0, 6)
		line1Label.BackgroundTransparency = 1
		line1Label.Font = BODY_FONT
		line1Label.TextColor3 = TEXT_MAIN
		line1Label.TextSize = 13
		line1Label.TextXAlignment = Enum.TextXAlignment.Left
		line1Label.TextTruncate = Enum.TextTruncate.AtEnd
		line1Label.Text = entry.Line1
		line1Label.Parent = row

		local line2Label = Instance.new("TextLabel")
		line2Label.Size = UDim2.new(1, -100, 0, 14)
		line2Label.Position = UDim2.new(0, 10, 0, 32)
		line2Label.BackgroundTransparency = 1
		line2Label.Font = BODY_FONT
		line2Label.TextColor3 = TEXT_DIM
		line2Label.TextSize = 10
		line2Label.TextXAlignment = Enum.TextXAlignment.Left
		line2Label.Text = entry.Line2 or ""
		line2Label.Parent = row

		if onAction then
			local actionBtn = Instance.new("TextButton")
			actionBtn.Size = UDim2.new(0, 80, 0, 30)
			actionBtn.Position = UDim2.new(1, -10, 0.5, 0)
			actionBtn.AnchorPoint = Vector2.new(1, 0.5)
			actionBtn.BackgroundColor3 = ACCENT
			actionBtn.AutoButtonColor = false
			actionBtn.Text = actionLabel or "Remove"
			actionBtn.Font = BODY_FONT
			actionBtn.TextColor3 = TEXT_MAIN
			actionBtn.TextSize = 11
			actionBtn.Parent = row
			Instance.new("UICorner", actionBtn).CornerRadius = RADIUS_CTRL

			actionBtn.MouseButton1Click:Connect(function()
				onAction(entry)
			end)
		end
	end

	-- Assignment, not a fresh `local function` - see the forward
	-- declaration above.
	renderRows = function(filterText)
		for _, child in ipairs(list:GetChildren()) do
			if child:IsA("Frame") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		local lowerFilter = string.lower(filterText or "")
		local matching = {}
		for _, entry in ipairs(entries) do
			local nameForFilter = string.lower(entry.Name or entry.Line1 or "")
			if lowerFilter == "" or string.find(nameForFilter, lowerFilter, 1, true) then
				table.insert(matching, entry)
			end
		end

		-- Paging applies to what the SEARCH left behind, not to the raw
		-- list. Narrowing 400 entries down to six therefore collapses to
		-- a single page, rather than leaving you stranded on page 4 of a
		-- result that no longer has one.
		local firstIndex, lastIndex = 1, #matching
		if paginate then
			pageCount = math.max(1, math.ceil(#matching / LIST_PAGE_SIZE))
			currentPage = math.clamp(currentPage, 1, pageCount)
			firstIndex = (currentPage - 1) * LIST_PAGE_SIZE + 1
			lastIndex = math.min(#matching, currentPage * LIST_PAGE_SIZE)
		end

		for i = firstIndex, lastIndex do
			buildRow(matching[i], i - firstIndex + 1)
		end

		if #matching == 0 then
			local emptyLabel = Instance.new("TextLabel")
			emptyLabel.Size = UDim2.new(1, 0, 0, 30)
			emptyLabel.BackgroundTransparency = 1
			emptyLabel.Font = BODY_FONT
			emptyLabel.TextColor3 = TEXT_DIM
			emptyLabel.TextSize = 13
			emptyLabel.Text = (#entries == 0) and "Nothing on record." or "No matches."
			emptyLabel.Parent = list
		end

		if updatePager then
			updatePager(#matching)
		end
		-- Back to the top on every re-render. Turning to page 2 while
		-- still scrolled to the bottom of page 1 would otherwise drop you
		-- into the middle of the new page.
		list.CanvasPosition = Vector2.new(0, 0)
	end

	renderRows("")

	if searchDropdown then
		local SUGGEST_ROW_HEIGHT = 26
		local MAX_VISIBLE_SUGGESTIONS = 5

		-- Same reasoning as the dropdown's own hoveringDropdown flag in
		-- buildPanel below: a click on a suggestion button blurs
		-- searchBox first, and if FocusLost hid the dropdown immediately
		-- the button would vanish out from under the click.
		local hoveringSearchDropdown = false
		searchDropdown.MouseEnter:Connect(function() hoveringSearchDropdown = true end)
		searchDropdown.MouseLeave:Connect(function() hoveringSearchDropdown = false end)

		local function hideSearchDropdown()
			searchDropdown.Visible = false
			searchDropdown.Size = UDim2.new(1, -32, 0, 0)
			searchDropdown.ScrollBarThickness = 0
		end

		local function updateSearchDropdown()
			for _, child in ipairs(searchDropdown:GetChildren()) do
				if child:IsA("TextButton") then child:Destroy() end
			end

			local lowerQuery = string.lower(searchBox.Text)
			local matches = {}
			for _, name in ipairs(searchSuggestions) do
				if lowerQuery == "" or string.sub(string.lower(name), 1, #lowerQuery) == lowerQuery then
					table.insert(matches, name)
				end
			end
			if #matches == 0 or (#matches == 1 and string.lower(matches[1]) == lowerQuery) then
				hideSearchDropdown()
				return
			end

			local visibleRows = math.min(#matches, MAX_VISIBLE_SUGGESTIONS)
			searchDropdown.Size = UDim2.new(1, -32, 0, visibleRows * SUGGEST_ROW_HEIGHT)
			searchDropdown.ScrollBarThickness = (#matches > MAX_VISIBLE_SUGGESTIONS) and 5 or 0
			searchDropdown.CanvasPosition = Vector2.new(0, 0)
			searchDropdown.Visible = true

			for i, name in ipairs(matches) do
				local btn = Instance.new("TextButton")
				btn.Size = UDim2.new(1, 0, 0, SUGGEST_ROW_HEIGHT)
				btn.LayoutOrder = i
				btn.BackgroundColor3 = BG_HOVER
				btn.AutoButtonColor = false
				btn.Font = BODY_FONT
				btn.TextColor3 = TEXT_MAIN
				btn.TextSize = 13
				btn.Text = ":" .. name
				btn.ZIndex = 6
				btn.Parent = searchDropdown
				btn.MouseButton1Click:Connect(function()
					searchBox.Text = name
					hideSearchDropdown()
				end)
			end
		end

		searchBox.Focused:Connect(updateSearchDropdown)
		searchBox.FocusLost:Connect(function()
			if hoveringSearchDropdown then return end
			hideSearchDropdown()
		end)
		searchBox:GetPropertyChangedSignal("Text"):Connect(updateSearchDropdown)
	end

	if searchBox then
		searchBox:GetPropertyChangedSignal("Text"):Connect(function()
			-- Back to page 1 whenever the search changes: the page you
			-- were on belonged to the previous set of results and means
			-- nothing for the new one.
			currentPage = 1
			renderRows(searchBox.Text)
		end)
	end
end

-- =====================================================================
-- Ban/mute detail-edit popup - reached via "Modify" on a :banlist or
-- :mutelist row. Shows the reason (editable) and duration (a few quick
-- presets, since a full custom duration input isn't worth the extra UI
-- complexity for what's realistically always "an hour", "a day", "a
-- week", or permanent), plus the Unban/Unmute button.
-- =====================================================================
local DURATION_PRESETS = {
	{Label = "1 Hour", Seconds = 3600},
	{Label = "24 Hours", Seconds = 24 * 3600},
	{Label = "7 Days", Seconds = 7 * 24 * 3600},
	{Label = "Permanent", Seconds = nil},
}

local function showPunishmentDetailPopup(kind, entry)
	local existing = playerGui:FindFirstChild("AdminDetailGui")
	if existing then existing:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AdminDetailGui"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.DisplayOrder = 46
	gui.Parent = playerGui

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.new(1, 0, 1, 0)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.5
	backdrop.BorderSizePixel = 0
	-- Active=true so this backdrop actually catches clicks instead of
	-- letting them fall through - a Frame defaults Active to false
	-- (unlike a TextButton), which only blocks NOTHING: it renders on
	-- top but a click at that screen position keeps looking for the
	-- next interactive object underneath and finds it, which is why the
	-- admin panel's sidebar commands were still clickable right through
	-- a popup visibly covering them.
	backdrop.Active = true
	backdrop.Parent = gui

	-- Same slide-up-from-off-screen entrance as the list popup, rather
	-- than just appearing/disappearing instantly.
	local PANEL_CLOSED_POS = UDim2.new(0.5, 0, 1.4, 0)
	local PANEL_OPEN_POS = UDim2.new(0.5, 0, 0.5, 0)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = PANEL_CLOSED_POS
	panel.Size = UDim2.new(0, 420, 0, 330)
	panel.BackgroundColor3 = BG_DARK
	panel.BorderSizePixel = 0
	panel.Parent = gui
	Instance.new("UICorner", panel).CornerRadius = RADIUS_PANEL
	outline(panel)
	local disconnectScale = attachAutoScale(panel)
	TweenService:Create(panel, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position = PANEL_OPEN_POS}):Play()

	local function closeDetailPopup()
		disconnectScale()
		local tween = TweenService:Create(panel, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = PANEL_CLOSED_POS})
		tween:Play()
		tween.Completed:Wait()
		gui:Destroy()
	end

	local kindLabel = (kind == "ban") and "Ban" or "Mute"

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, -100, 0, 26)
	titleLabel.Position = UDim2.new(0, 20, 0, 16)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = BODY_FONT
	titleLabel.TextColor3 = ACCENT
	titleLabel.TextSize = 16
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.Text = kindLabel .. " - " .. entry.Name
	titleLabel.Parent = panel

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0, 70, 0, 26)
	closeBtn.Position = UDim2.new(1, -20, 0, 16)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.BackgroundColor3 = ACCENT
	closeBtn.AutoButtonColor = false
	closeBtn.Text = "Close"
	closeBtn.Font = BODY_FONT
	closeBtn.TextColor3 = TEXT_MAIN
	closeBtn.TextSize = 12
	closeBtn.Parent = panel
	Instance.new("UICorner", closeBtn).CornerRadius = RADIUS_CTRL
	closeBtn.MouseButton1Click:Connect(closeDetailPopup)

	local reasonLabel = Instance.new("TextLabel")
	reasonLabel.Size = UDim2.new(1, -40, 0, 16)
	reasonLabel.Position = UDim2.new(0, 20, 0, 54)
	reasonLabel.BackgroundTransparency = 1
	reasonLabel.Font = BODY_FONT
	reasonLabel.TextColor3 = TEXT_DIM
	reasonLabel.TextSize = 11
	reasonLabel.TextXAlignment = Enum.TextXAlignment.Left
	reasonLabel.Text = "REASON"
	reasonLabel.Parent = panel

	local reasonHolder = Instance.new("Frame")
	reasonHolder.Size = UDim2.new(1, -40, 0, 32)
	reasonHolder.Position = UDim2.new(0, 20, 0, 72)
	reasonHolder.BackgroundColor3 = BG_ROW
	reasonHolder.BorderSizePixel = 0
	reasonHolder.Parent = panel
	Instance.new("UICorner", reasonHolder).CornerRadius = RADIUS_CTRL

	local reasonBox = Instance.new("TextBox")
	reasonBox.Size = UDim2.new(1, -90, 1, 0)
	reasonBox.Position = UDim2.new(0, 10, 0, 0)
	reasonBox.BackgroundTransparency = 1
	reasonBox.Font = BODY_FONT
	reasonBox.TextColor3 = TEXT_MAIN
	reasonBox.TextSize = 13
	reasonBox.TextXAlignment = Enum.TextXAlignment.Left
	reasonBox.ClearTextOnFocus = false
	reasonBox.Text = entry.Reason or ""
	reasonBox.Parent = reasonHolder

	local saveReasonBtn = Instance.new("TextButton")
	saveReasonBtn.Size = UDim2.new(0, 70, 0, 24)
	saveReasonBtn.Position = UDim2.new(1, -8, 0.5, 0)
	saveReasonBtn.AnchorPoint = Vector2.new(1, 0.5)
	saveReasonBtn.BackgroundColor3 = BG_ROW
	saveReasonBtn.AutoButtonColor = false
	saveReasonBtn.Text = "Save"
	saveReasonBtn.Font = BODY_FONT
	saveReasonBtn.TextColor3 = TEXT_MAIN
	saveReasonBtn.TextSize = 11
	saveReasonBtn.Parent = reasonHolder
	Instance.new("UICorner", saveReasonBtn).CornerRadius = RADIUS_CTRL
	saveReasonBtn.MouseButton1Click:Connect(function()
		-- Closes immediately rather than flashing red and waiting first -
		-- that artificial pause (on top of the close tween itself) was
		-- exactly the "modifying a reason feels delayed" complaint. The
		-- server refreshes the list underneath with the new reason once
		-- its response arrives, same as before.
		AdminModifyPunishment:FireServer(kind, entry.Id, "reason", reasonBox.Text)
		closeDetailPopup()
	end)

	local durationLabel = Instance.new("TextLabel")
	durationLabel.Size = UDim2.new(1, -40, 0, 16)
	durationLabel.Position = UDim2.new(0, 20, 0, 118)
	durationLabel.BackgroundTransparency = 1
	durationLabel.Font = BODY_FONT
	durationLabel.TextColor3 = TEXT_DIM
	durationLabel.TextSize = 11
	durationLabel.TextXAlignment = Enum.TextXAlignment.Left
	durationLabel.Text = "DURATION - " .. (entry.DurationText or "Permanent")
	durationLabel.Parent = panel

	local durationRow = Instance.new("Frame")
	durationRow.Size = UDim2.new(1, -40, 0, 34)
	durationRow.Position = UDim2.new(0, 20, 0, 136)
	durationRow.BackgroundTransparency = 1
	durationRow.Parent = panel

	local durationLayout = Instance.new("UIListLayout")
	durationLayout.FillDirection = Enum.FillDirection.Horizontal
	durationLayout.Padding = UDim.new(0, 6)
	durationLayout.SortOrder = Enum.SortOrder.LayoutOrder
	durationLayout.Parent = durationRow

	for i, preset in ipairs(DURATION_PRESETS) do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(0, 90, 1, 0)
		btn.LayoutOrder = i
		btn.BackgroundColor3 = BG_ROW
		btn.AutoButtonColor = false
		btn.Font = BODY_FONT
		btn.TextColor3 = TEXT_MAIN
		btn.TextSize = 11
		btn.Text = preset.Label
		btn.Parent = durationRow
		Instance.new("UICorner", btn).CornerRadius = RADIUS_CTRL
		btn.MouseButton1Click:Connect(function()
			-- Closes immediately - same reasoning as saveReasonBtn above.
			AdminModifyPunishment:FireServer(kind, entry.Id, "duration", preset.Seconds)
			closeDetailPopup()
		end)
	end

	local removeBtn = Instance.new("TextButton")
	removeBtn.Size = UDim2.new(0, 200, 0, 40)
	removeBtn.Position = UDim2.new(0.5, 0, 1, -20)
	removeBtn.AnchorPoint = Vector2.new(0.5, 1)
	removeBtn.BackgroundColor3 = ACCENT
	removeBtn.AutoButtonColor = false
	removeBtn.Text = (kind == "ban") and "UNBAN" or "UNMUTE"
	removeBtn.Font = BODY_FONT
	removeBtn.TextColor3 = TEXT_MAIN
	removeBtn.TextSize = 13
	removeBtn.Parent = panel
	Instance.new("UICorner", removeBtn).CornerRadius = RADIUS_CTRL
	removeBtn.MouseButton1Click:Connect(function()
		AdminModifyPunishment:FireServer(kind, entry.Id, "remove")
		closeDetailPopup()
	end)
end

-- Days-from-civil-date (Howard Hinnant's algorithm) - a portable way to
-- turn a Y/M/D into a linear day count without calling os.time() on a
-- table. That matters here because os.time(table) turned out NOT to
-- apply real local-timezone math in Roblox's Luau sandbox - it treated
-- every table the same regardless of where it came from, which is why
-- comparing os.time(localTable) against os.time(utcTable) always came
-- back 0 (shown as "GMT+0" for every viewer, no matter their real
-- timezone), even though os.date() itself (epoch -> table, the other
-- direction) DOES correctly reflect the viewer's real local clock.
local function daysFromCivil(y, m, d)
	local a = math.floor((14 - m) / 12)
	local y2 = y + 4800 - a
	local m2 = m + 12 * a - 3
	return d + math.floor((153 * m2 + 2) / 5) + 365 * y2 + math.floor(y2 / 4) - math.floor(y2 / 100) + math.floor(y2 / 400) - 32045
end

-- Computes the viewing admin's own local UTC offset by comparing local
-- and UTC broken-down time for the same instant, entirely via os.date()
-- (confirmed correct in both directions) rather than os.time() (see
-- daysFromCivil above for why that doesn't work here). This runs on the
-- client (each admin's own device), which is what makes the result
-- THEIR local time/zone rather than the server's - the server's clock
-- is whatever Roblox's cloud infrastructure uses (effectively UTC),
-- not any particular admin's own timezone.
local function getLocalTimezoneLabel()
	local now = os.time()
	local localT = os.date("*t", now)
	local utcT = os.date("!*t", now)

	local localMinutes = daysFromCivil(localT.year, localT.month, localT.day) * 1440 + localT.hour * 60 + localT.min
	local utcMinutes = daysFromCivil(utcT.year, utcT.month, utcT.day) * 1440 + utcT.hour * 60 + utcT.min
	local diffMinutes = localMinutes - utcMinutes

	local sign = diffMinutes >= 0 and "+" or "-"
	local absMinutes = math.abs(diffMinutes)
	local hours = math.floor(absMinutes / 60)
	local minutes = absMinutes % 60
	if minutes == 0 then
		return "GMT" .. sign .. tostring(hours)
	end
	return "GMT" .. sign .. tostring(hours) .. ":" .. string.format("%02d", minutes)
end

local function formatLocalTimestamp(timestamp)
	return os.date("%Y-%m-%d %H:%M:%S", timestamp) .. " (Your Local Time " .. getLocalTimezoneLabel() .. ")"
end

-- Whether this player may delete command-log entries. Comes straight
-- from the server's GetAdminInfo response (buildPanel sets it), and is
-- a DISPLAY hint only - it decides whether the Remove button is drawn,
-- while the server re-checks who's asking before it deletes anything.
-- Lives at the top level because the log detail popup below is built
-- outside buildPanel and so can't see anything scoped to it.
local canRemoveLogs = false

-- =====================================================================
-- Log detail popup - reached via "View" on a :cmdlogs/:playerlogs row.
-- Every field it needs (Admin/Tier/Command/Target/Extra/Timestamp) is
-- already on the entry the list itself received - buildLogEntries in
-- AdminServer.lua sends those alongside the Line1/Line2 the list row
-- displays - so this is a pure client-side reformat, no extra remote
-- round trip needed just to view one entry.
-- =====================================================================
local function showLogDetailPopup(entry)
	local existing = playerGui:FindFirstChild("AdminDetailGui")
	if existing then existing:Destroy() end

	local gui = Instance.new("ScreenGui")
	gui.Name = "AdminDetailGui"
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.DisplayOrder = 46
	gui.Parent = playerGui

	local backdrop = Instance.new("Frame")
	backdrop.Size = UDim2.new(1, 0, 1, 0)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.5
	backdrop.BorderSizePixel = 0
	-- Active=true so this backdrop actually catches clicks instead of
	-- letting them fall through - a Frame defaults Active to false
	-- (unlike a TextButton), which only blocks NOTHING: it renders on
	-- top but a click at that screen position keeps looking for the
	-- next interactive object underneath and finds it, which is why the
	-- admin panel's sidebar commands were still clickable right through
	-- a popup visibly covering them.
	backdrop.Active = true
	backdrop.Parent = gui

	local PANEL_CLOSED_POS = UDim2.new(0.5, 0, 1.4, 0)
	local PANEL_OPEN_POS = UDim2.new(0.5, 0, 0.5, 0)

	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = PANEL_CLOSED_POS
	panel.Size = UDim2.new(0, 420, 0, 360)
	panel.BackgroundColor3 = BG_DARK
	panel.BorderSizePixel = 0
	panel.Parent = gui
	Instance.new("UICorner", panel).CornerRadius = RADIUS_PANEL
	outline(panel)
	local disconnectScale = attachAutoScale(panel)
	TweenService:Create(panel, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Position = PANEL_OPEN_POS}):Play()

	local function closeLogDetailPopup()
		disconnectScale()
		local tween = TweenService:Create(panel, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {Position = PANEL_CLOSED_POS})
		tween:Play()
		tween.Completed:Wait()
		gui:Destroy()
	end

	-- The Remove button only exists for the owner, so the title gets the
	-- width back when it isn't there rather than leaving a permanent gap.
	local showRemove = canRemoveLogs and entry.Id ~= nil

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Size = UDim2.new(1, showRemove and -190 or -100, 0, 26)
	titleLabel.Position = UDim2.new(0, 20, 0, 16)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Font = BODY_FONT
	titleLabel.TextColor3 = ACCENT
	titleLabel.TextSize = 16
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextTruncate = Enum.TextTruncate.AtEnd
	titleLabel.Text = ":" .. entry.Command
	titleLabel.Parent = panel

	local closeBtn = Instance.new("TextButton")
	closeBtn.Size = UDim2.new(0, 70, 0, 26)
	closeBtn.Position = UDim2.new(1, -20, 0, 16)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.BackgroundColor3 = ACCENT
	closeBtn.AutoButtonColor = false
	closeBtn.Text = "Close"
	closeBtn.Font = BODY_FONT
	closeBtn.TextColor3 = TEXT_MAIN
	closeBtn.TextSize = 12
	closeBtn.Parent = panel
	Instance.new("UICorner", closeBtn).CornerRadius = RADIUS_CTRL
	closeBtn.MouseButton1Click:Connect(closeLogDetailPopup)

	-- Owner-only deletion of this one entry. Sits left of Close, and is
	-- two-step on purpose: the first click arms it, the second commits.
	-- There's no undo - the entry is gone from the DataStore too - and
	-- it's one button away from Close, so a single misclick shouldn't be
	-- able to destroy a record.
	if showRemove then
		local removeBtn = Instance.new("TextButton")
		removeBtn.Size = UDim2.new(0, 84, 0, 26)
		removeBtn.Position = UDim2.new(1, -98, 0, 16)
		removeBtn.AnchorPoint = Vector2.new(1, 0)
		removeBtn.BackgroundColor3 = BG_ROW
		removeBtn.AutoButtonColor = false
		removeBtn.Text = "Remove"
		removeBtn.Font = BODY_FONT
		removeBtn.TextColor3 = TEXT_MAIN
		removeBtn.TextSize = 12
		removeBtn.Parent = panel
		Instance.new("UICorner", removeBtn).CornerRadius = RADIUS_CTRL

		local armed = false
		removeBtn.MouseButton1Click:Connect(function()
			if not armed then
				armed = true
				removeBtn.Text = "Sure?"
				removeBtn.BackgroundColor3 = ACCENT
				-- Disarms itself if it's left sitting there, so an armed
				-- button can't be inherited by a later, unrelated click.
				task.delay(4, function()
					if not armed or removeBtn.Parent == nil then return end
					armed = false
					removeBtn.Text = "Remove"
					removeBtn.BackgroundColor3 = BG_ROW
				end)
				return
			end
			AdminRemoveLogEntry:FireServer(entry.Id)
			-- The server refires the log list once it's done, which
			-- rebuilds the list underneath - this just gets the detail
			-- popup for a now-deleted entry off the screen.
			task.spawn(closeLogDetailPopup)
		end)
	end

	local function buildFieldRow(key, value, y)
		local keyLabel = Instance.new("TextLabel")
		keyLabel.Size = UDim2.new(1, -40, 0, 14)
		keyLabel.Position = UDim2.new(0, 20, 0, y)
		keyLabel.BackgroundTransparency = 1
		keyLabel.Font = BODY_FONT
		keyLabel.TextColor3 = TEXT_DIM
		keyLabel.TextSize = 11
		keyLabel.TextXAlignment = Enum.TextXAlignment.Left
		keyLabel.Text = key
		keyLabel.Parent = panel

		-- Wrapped (not truncated) and given room for 2 lines - the local
		-- time string with its "(Your Local Time GMT+N)" suffix runs
		-- long enough to not reliably fit on one line at every viewport
		-- scale, and truncating it would cut off the timezone label,
		-- which is the whole point of showing it.
		local valueLabel = Instance.new("TextLabel")
		valueLabel.Size = UDim2.new(1, -40, 0, 32)
		valueLabel.Position = UDim2.new(0, 20, 0, y + 15)
		valueLabel.BackgroundTransparency = 1
		valueLabel.Font = BODY_FONT
		valueLabel.TextColor3 = TEXT_MAIN
		valueLabel.TextSize = 14
		valueLabel.TextWrapped = true
		valueLabel.TextXAlignment = Enum.TextXAlignment.Left
		valueLabel.TextYAlignment = Enum.TextYAlignment.Top
		valueLabel.Text = value
		valueLabel.Parent = panel
	end

	-- "ADMIN" plain, not "ADMIN - CURRENT RANK AT THE TIME" - the old
	-- wording read as if "Admin" were itself a rank being displayed
	-- (e.g. "why does it say Admin, not Founder?") when it was just a
	-- verbose field label; the value line already states the tier
	-- clearly on its own ("EnderBuilda (Founder)").
	buildFieldRow("ADMIN", entry.Admin .. " (" .. (entry.Tier or "?") .. ")", 56)
	buildFieldRow("TARGET", entry.Target or "-", 104)
	buildFieldRow("TIME", formatLocalTimestamp(entry.Timestamp or 0), 152)

	local detailsLabel = Instance.new("TextLabel")
	detailsLabel.Size = UDim2.new(1, -40, 0, 14)
	detailsLabel.Position = UDim2.new(0, 20, 0, 200)
	detailsLabel.BackgroundTransparency = 1
	detailsLabel.Font = BODY_FONT
	detailsLabel.TextColor3 = TEXT_DIM
	detailsLabel.TextSize = 11
	detailsLabel.TextXAlignment = Enum.TextXAlignment.Left
	detailsLabel.Text = "DESCRIPTION"
	detailsLabel.Parent = panel

	-- Scrollable rather than a fixed-height label - :announce/:msg
	-- messages can run to hundreds of characters, and this needs to show
	-- the full text rather than truncating it.
	local detailsHolder = Instance.new("ScrollingFrame")
	detailsHolder.Size = UDim2.new(1, -40, 1, -234)
	detailsHolder.Position = UDim2.new(0, 20, 0, 218)
	detailsHolder.BackgroundColor3 = BG_ROW
	detailsHolder.BorderSizePixel = 0
	detailsHolder.ScrollBarThickness = 5
	detailsHolder.AutomaticCanvasSize = Enum.AutomaticSize.Y
	detailsHolder.CanvasSize = UDim2.new(0, 0, 0, 0)
	detailsHolder.Parent = panel
	Instance.new("UICorner", detailsHolder).CornerRadius = RADIUS_CTRL

	local detailsPadding = Instance.new("UIPadding")
	detailsPadding.PaddingTop = UDim.new(0, 8)
	detailsPadding.PaddingLeft = UDim.new(0, 10)
	detailsPadding.PaddingRight = UDim.new(0, 10)
	detailsPadding.PaddingBottom = UDim.new(0, 8)
	detailsPadding.Parent = detailsHolder

	local detailsText = Instance.new("TextLabel")
	-- -10, not 0 - detailsHolder's ScrollBarThickness (5px) reserves a
	-- strip on its right edge for the scrollbar whenever the content
	-- actually needs to scroll, but that reservation is independent of
	-- UIPadding and doesn't shrink a Scale-sized child's width on its
	-- own - so a full-width line of text ran right up under the
	-- scrollbar and had its last few pixels visually clipped by it. This
	-- keeps the text comfortably clear of that whole area regardless of
	-- whether a given entry is long enough to actually need scrolling.
	detailsText.Size = UDim2.new(1, -10, 0, 0)
	detailsText.AutomaticSize = Enum.AutomaticSize.Y
	detailsText.BackgroundTransparency = 1
	detailsText.Font = BODY_FONT
	detailsText.TextColor3 = TEXT_MAIN
	detailsText.TextSize = 13
	detailsText.TextWrapped = true
	detailsText.TextXAlignment = Enum.TextXAlignment.Left
	detailsText.TextYAlignment = Enum.TextYAlignment.Top
	-- A plain, grammatical sentence (AdminServer.lua's logCommand builds
	-- this per call site) rather than a ":command target extra"
	-- reconstruction - that read badly for anything that isn't a command
	-- someone actually typed (:unban/:unmute/:unwarn, a reason/duration
	-- edit from the Modify popup), since those aren't commands at all.
	-- Falls back to a reconstruction only for an old log entry saved
	-- before this field existed - that reconstruction still includes
	-- Extra (the reason/duration text those entries DID capture, just in
	-- the old raw "reason (warning #3)" / "24h - reason" style rather
	-- than a full sentence) rather than dropping it, since a legacy warn
	-- entry with no reason shown at all was worse than an imperfectly
	-- phrased one that at least says why.
	detailsText.Text = entry.Description
		or (entry.Admin .. " used :" .. entry.Command
			.. (entry.Target and entry.Target ~= "" and (" on " .. entry.Target) or "")
			.. (entry.Extra and entry.Extra ~= "" and (" - " .. entry.Extra) or ""))
	detailsText.Parent = detailsHolder
end

-- Keeps the target's name across a refresh after a removal - the server
-- resends with targetName == nil then, since it doesn't track that name
-- itself once it's just working off a UserId.
local lastWarningsTargetName = nil

AdminWarningsList.OnClientEvent:Connect(function(targetName, targetUserId, warnings)
	if targetName then
		lastWarningsTargetName = targetName
	end
	local displayName = targetName or lastWarningsTargetName or "?"

	local entries = {}
	for i, w in ipairs(warnings) do
		table.insert(entries, {
			Id = i,
			Line1 = "#" .. i .. ": " .. tostring(w.Reason),
			Line2 = "by " .. tostring(w.By) .. " - " .. os.date("%Y-%m-%d %H:%M", w.Timestamp or 0),
		})
	end

	showListPopup("Warnings - " .. displayName .. " (" .. #warnings .. ")", entries, "Remove", function(entry)
		AdminRemoveWarning:FireServer(targetUserId, entry.Id)
	end)
end)

AdminBanList.OnClientEvent:Connect(function(title, entries)
	showListPopup(title, entries, "Modify", function(entry)
		showPunishmentDetailPopup("ban", entry)
	end, true)
end)

AdminMuteList.OnClientEvent:Connect(function(title, entries)
	showListPopup(title, entries, "Modify", function(entry)
		showPunishmentDetailPopup("mute", entry)
	end, true)
end)

AdminWarnList.OnClientEvent:Connect(function(title, entries)
	showListPopup(title, entries, "Modify", function(entry)
		AdminViewWarnings:FireServer(entry.Id)
	end, true)
end)

-- :viewinv/:checkinv's result - purely informational (no per-row action,
-- no search - a single player's inventory is normally short), unlike
-- the punishment lists above.
AdminInventoryList.OnClientEvent:Connect(function(title, entries)
	showListPopup(title, entries, "Remove", function(entry)
		AdminInventoryRemoveItem:FireServer(entry.Id)
	end, false)
end)

-- Search filters against Line1 (":command - target"), so searching a
-- command name like "bring" already matches every entry for that
-- command with no special-case filtering logic needed. The suggestion
-- list is derived from whichever commands actually appear in THIS log
-- (rather than a hardcoded list) so it can never suggest a command that
-- has zero entries anyway, and it picks up :unwarn/:unban/:unmute for
-- free alongside the typed commands. Clicking a row opens the
-- read-only detail popup above rather than acting on the entry, since a
-- log entry isn't something to modify.
local function collectLoggedCommands(entries)
	local seen = {}
	local names = {}
	for _, entry in ipairs(entries) do
		if entry.Command and not seen[entry.Command] then
			seen[entry.Command] = true
			table.insert(names, entry.Command)
		end
	end
	table.sort(names)
	return names
end

AdminLogsList.OnClientEvent:Connect(function(title, entries)
	showListPopup(title, entries, "View", function(entry)
		showLogDetailPopup(entry)
	-- Paginated: the logs are the one list with no cap on how long they
	-- can get, now that buildLogEntries returns everything rather than
	-- stopping at 100.
	end, true, collectLoggedCommands(entries), true)
end)

-- =====================================================================
-- Everything below only builds if the server confirms a staff tier -
-- never trust a client-side guess, the server is asked directly.
--
-- Wrapped in a function (rather than running once at the top level) so
-- it can also be triggered later by AdminInfoChanged - the Studio-only
-- testing override in AdminServer.lua can be set well after this script
-- already ran its first GetAdminInfo check (in practice it always is,
-- since it takes real time to reach the Command Bar), so a single
-- check-once-at-startup could never pick it up. panelBuilt guards
-- against building twice if both the initial check and a later
-- AdminInfoChanged both resolve to a tier.
-- =====================================================================
local panelBuilt = false

-- Assigned by buildPanel once the sidebar exists, so a later
-- AdminInfoChanged can swap the command list for a new tier's without
-- re-entering buildPanel and duplicating everything it creates.
local refreshPanelCommands = nil
local currentPanelTier = nil

local function buildPanel(info)
	-- Recorded BEFORE the guards below. The panel itself only builds
	-- once, but AdminInfoChanged can arrive again later (the Studio tier
	-- override), and this flag should follow the latest answer either
	-- way - behind the panelBuilt guard it would be stuck at whatever the
	-- very first check said.
	canRemoveLogs = (info ~= nil) and info.CanRemoveLogs == true

	if panelBuilt then
		-- Already built, so this is a LATER answer - the Studio tier
		-- override changing, in practice. Swap the command list for the
		-- new tier's rather than rebuilding the panel (see
		-- populateCommands for why rebuilding is not an option).
		if info and info.Tier and info.Tier ~= currentPanelTier and refreshPanelCommands then
			currentPanelTier = info.Tier
			refreshPanelCommands(info.Commands or {}, info.Tier)
		end
		return
	end
	if not info or not info.Tier then return end
	panelBuilt = true

	local myTier = info.Tier
	local myCommands = info.Commands or {}
	print("[AdminClient] Staff tier confirmed: " .. myTier .. " (" .. #myCommands .. " commands)")

	-- Used by the autocomplete dropdown below, to only offer player
	-- suggestions once a command this tier can actually use has been typed.
	local myCommandsSet = {}
	for _, commandName in ipairs(myCommands) do
		myCommandsSet[commandName] = true
	end

	-- Created immediately, before anything below that waits on ClosePanels -
	-- TopBar.lua also waits for THIS event before its Admin icon is fully
	-- wired. Creating each event before waiting on the other script's event
	-- (rather than after) is what avoids a deadlock: an earlier version had
	-- both scripts waiting on each other's event before creating their own,
	-- so both sat stuck for the full WaitForChild timeout and neither event
	-- ever got created in time - which is why the Admin topbar button
	-- stopped opening anything.
	local toggleAdminPanelEvent = Instance.new("BindableEvent")
	toggleAdminPanelEvent.Name = "ToggleAdminPanel"
	toggleAdminPanelEvent.Parent = ReplicatedStorage

	local REFERENCE_WIDTH = 1280
	local REFERENCE_HEIGHT = 720
	local MIN_SCALE = 0.5
	local MAX_SCALE = 1.6

	local PANEL_WIDTH = 320
	local PANEL_HEIGHT = 420

	local gui = Instance.new("ScreenGui")
	gui.Name = "AdminPanel"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.DisplayOrder = 20
	gui.Parent = playerGui

	-- Opened via the "Admin" topbar icon in TopBar.lua (a separate script -
	-- see the ToggleAdminPanel BindableEvent below) rather than a standalone
	-- corner button, so it matches Menu/Shop's placement and its
	-- hidden-on-the-main-menu/shown-during-gameplay visibility exactly.
	-- Slides up from off-screen at the bottom / back down, same tween
	-- pattern TopBar.lua already uses for the Shop panel.
	--
	-- Kept byte-for-byte in step with TopBar.lua's Shop/Settings panels so
	-- all three in-game panels open in exactly the same spot - see the
	-- longer explanation there. Short version: the Inventory hotbar
	-- (PlayerInfo.lua) owns a fixed 106px strip at the bottom of the
	-- screen (INV_BOTTOM_MARGIN 16 + INV_COLLAPSED_HEIGHT 90), and each
	-- panel is centred in the space ABOVE that strip rather than on the
	-- whole screen. Pinning a fixed distance above the hotbar instead
	-- (what this used to do) kept the GAP equal between panels but left
	-- panels of different heights sitting at visibly different heights.
	-- With a CENTRE anchor the panel's own height never enters the
	-- calculation, so this lands identically to Shop/Settings despite
	-- being a different width.
	local INVENTORY_FOOTPRINT = 106
	local PANEL_OPEN_POS = UDim2.new(0.5, 0, 0.5, -INVENTORY_FOOTPRINT / 2)
	-- Closed = fully off the bottom. With a CENTRE anchor the panel
	-- straddles the point, so this clears by half its own height plus a
	-- margin, in offset pixels so it scales with the panel's own UIScale.
	local PANEL_CLOSED_POS = UDim2.new(0.5, 0, 1, PANEL_HEIGHT / 2 + 40)
	local OPEN_TWEEN_INFO = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local CLOSE_TWEEN_INFO = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = PANEL_CLOSED_POS
	panel.Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT)
	panel.BackgroundColor3 = BG_DARK
	panel.BorderSizePixel = 0
	panel.Parent = gui
	Instance.new("UICorner", panel).CornerRadius = RADIUS_PANEL
	outline(panel)

	local panelScale = Instance.new("UIScale")
	panelScale.Scale = 1
	panelScale.Parent = panel

	local function applyScale()
		local camera = workspace.CurrentCamera
		if not camera then return end
		local viewport = camera.ViewportSize
		if viewport.X <= 0 or viewport.Y <= 0 then return end
		local scale = math.clamp(math.min(viewport.X / REFERENCE_WIDTH, viewport.Y / REFERENCE_HEIGHT), MIN_SCALE, MAX_SCALE)
		panelScale.Scale = scale
	end
	applyScale()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		if workspace.CurrentCamera then
			workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
			applyScale()
		end
	end)

	local header = Instance.new("TextLabel")
	header.Size = UDim2.new(1, -110, 0, 28)
	header.Position = UDim2.new(0, 16, 0, 14)
	header.BackgroundTransparency = 1
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Font = TITLE_FONT
	header.TextColor3 = TEXT_MAIN
	header.TextSize = 20
	header.Text = "🛡️ Admin Panel"
	header.Parent = panel

	local closeButton = Instance.new("TextButton")
	closeButton.Size = UDim2.new(0, 70, 0, 28)
	closeButton.Position = UDim2.new(1, -16, 0, 14)
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.BackgroundColor3 = ERROR_RED
	closeButton.AutoButtonColor = false
	closeButton.Text = "Close"
	closeButton.Font = BODY_FONT
	closeButton.TextColor3 = TEXT_MAIN
	closeButton.TextSize = 12
	closeButton.Parent = panel
	Instance.new("UICorner", closeButton).CornerRadius = RADIUS_CTRL

	-- Command input
	local inputHolder = Instance.new("Frame")
	inputHolder.Size = UDim2.new(1, -32, 0, 36)
	inputHolder.Position = UDim2.new(0, 16, 0, 48)
	inputHolder.BackgroundColor3 = BG_ROW
	inputHolder.BorderSizePixel = 0
	inputHolder.ZIndex = 2
	-- Without this, text longer than the box wasn't clipped to its
	-- rounded rectangle at all - it just rendered straight past the
	-- edge, spilling outside the panel entirely instead of scrolling
	-- within the box the way a single-line text field normally does.
	inputHolder.ClipsDescendants = true
	inputHolder.Parent = panel
	Instance.new("UICorner", inputHolder).CornerRadius = RADIUS_CTRL

	local inputBox = Instance.new("TextBox")
	inputBox.Size = UDim2.new(1, -20, 1, 0)
	inputBox.Position = UDim2.new(0, 10, 0, 0)
	inputBox.BackgroundTransparency = 1
	inputBox.Font = BODY_FONT
	inputBox.TextColor3 = TEXT_MAIN
	inputBox.TextSize = 14
	inputBox.TextXAlignment = Enum.TextXAlignment.Left
	inputBox.PlaceholderText = ":kick partialname reason"
	inputBox.PlaceholderColor3 = TEXT_DIM
	inputBox.ClearTextOnFocus = false
	inputBox.Text = ""
	inputBox.ZIndex = 2
	inputBox.Parent = inputHolder

	-- Ghost-text field hint ("[player]", then "[reason]", etc.) - sits
	-- behind inputBox at the same position/font/size. Rendered via
	-- RichText as "already-typed text in a color matching the box's own
	-- background (invisible) + the hint text in a dim, visible color"
	-- immediately after, which is what lines the hint up right where the
	-- cursor currently is without needing to know its actual pixel
	-- position (Roblox doesn't expose that for a TextBox).
	local hintLabel = Instance.new("TextLabel")
	hintLabel.Size = UDim2.new(1, -20, 1, 0)
	hintLabel.Position = UDim2.new(0, 10, 0, 0)
	hintLabel.BackgroundTransparency = 1
	hintLabel.Font = BODY_FONT
	hintLabel.TextSize = 14
	hintLabel.TextXAlignment = Enum.TextXAlignment.Left
	hintLabel.RichText = true
	hintLabel.Text = ""
	hintLabel.ZIndex = 1
	hintLabel.Parent = inputHolder

	-- Autocomplete dropdown - sits just under the input box, above the
	-- sidebar/status area (higher ZIndex so it isn't clipped behind them).
	-- ZIndex is set above every other element in the panel (status line,
	-- sidebar header, sidebar itself all default to 1) so the dropdown
	-- visually overlays them while open, rather than rendering underneath
	-- since it happens to be an earlier sibling.
	-- ScrollingFrame, not a plain Frame - a match list longer than
	-- MAX_VISIBLE_MATCHES needs somewhere for the rest to go. The old
	-- Frame version only ever created buttons for the first
	-- MAX_VISIBLE_MATCHES matches at all (see renderDropdownMatches
	-- below) and silently dropped everything past that - which is why
	-- ":setrank"'s rank list (6 entries) never showed "Site Manager"
	-- (6th/last) unless a typed filter had already narrowed the list
	-- under 5. AutomaticCanvasSize handles sizing the scrollable content
	-- to however many rows actually exist; dropdown.Size below only
	-- caps how much of that is visible before it scrolls.
	local dropdown = Instance.new("ScrollingFrame")
	dropdown.Position = UDim2.new(0, 16, 0, 86)
	dropdown.Size = UDim2.new(1, -32, 0, 0)
	dropdown.BackgroundColor3 = BG_HOVER
	dropdown.BorderSizePixel = 0
	dropdown.ClipsDescendants = true
	dropdown.Visible = false
	dropdown.ZIndex = 5
	dropdown.ScrollBarThickness = 5
	dropdown.CanvasSize = UDim2.new(0, 0, 0, 0)
	dropdown.AutomaticCanvasSize = Enum.AutomaticSize.Y
	dropdown.Parent = panel

	-- Clicking a match button first blurs inputBox (moving focus off the
	-- TextBox is what a click on any other GuiObject does), which fires
	-- FocusLost before the click's release is processed. If FocusLost hides
	-- the dropdown immediately, the button vanishes out from under the
	-- click and MouseButton1Click never fires on it - this tracks whether
	-- the mouse is over the dropdown so FocusLost can skip hiding it in
	-- that case and let the button's own click handler run first.
	local hoveringDropdown = false
	dropdown.MouseEnter:Connect(function() hoveringDropdown = true end)
	dropdown.MouseLeave:Connect(function() hoveringDropdown = false end)
	Instance.new("UICorner", dropdown).CornerRadius = RADIUS_CTRL

	local dropdownLayout = Instance.new("UIListLayout")
	dropdownLayout.SortOrder = Enum.SortOrder.LayoutOrder
	dropdownLayout.Parent = dropdown

	local MATCH_ROW_HEIGHT = 26
	local MAX_VISIBLE_MATCHES = 5

	-- Status line - shows the server's response to the last command run.
	-- Wraps to 2 lines rather than truncating, since some feedback (an
	-- ambiguous-match error, an early longer warn summary) didn't fit on
	-- one line and was getting cut off. The 14px this adds is taken back
	-- from the sidebar below (its start position moves down 14px and its
	-- height shrinks by the same 14px) so the panel's overall size is
	-- unchanged.
	local status = Instance.new("TextLabel")
	status.Size = UDim2.new(1, -32, 0, 32)
	status.Position = UDim2.new(0, 16, 0, 92)
	status.BackgroundTransparency = 1
	status.Font = BODY_FONT
	status.TextSize = 12
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.TextYAlignment = Enum.TextYAlignment.Top
	status.TextWrapped = true
	status.TextColor3 = TEXT_DIM
	status.Text = "Type a command above, or click one from below."
	status.Parent = panel

	-- Sidebar: every command this tier can use, grouped under
	-- subheadings by category, click a row to populate the input.
	local sidebarLabel = Instance.new("TextLabel")
	sidebarLabel.Size = UDim2.new(1, -32, 0, 18)
	sidebarLabel.Position = UDim2.new(0, 16, 0, 124)
	sidebarLabel.BackgroundTransparency = 1
	sidebarLabel.Font = BODY_FONT
	sidebarLabel.TextColor3 = ACCENT
	sidebarLabel.TextSize = 12
	sidebarLabel.TextXAlignment = Enum.TextXAlignment.Left
	sidebarLabel.Text = "COMMANDS"
	sidebarLabel.Parent = panel

	local sidebar = Instance.new("ScrollingFrame")
	sidebar.Size = UDim2.new(1, -32, 1, -164)
	sidebar.Position = UDim2.new(0, 16, 0, 146)
	sidebar.BackgroundTransparency = 1
	sidebar.BorderSizePixel = 0
	sidebar.ScrollBarThickness = 5
	sidebar.AutomaticCanvasSize = Enum.AutomaticSize.Y
	sidebar.CanvasSize = UDim2.new(0, 0, 0, 0)
	sidebar.Parent = panel

	local sidebarLayout = Instance.new("UIListLayout")
	sidebarLayout.Padding = UDim.new(0, 6)
	sidebarLayout.SortOrder = Enum.SortOrder.LayoutOrder
	sidebarLayout.Parent = sidebar

	local COMMAND_USAGE = {
		kick = ":kick [player] [reason]",
		mute = ":mute [player] [reason]",
		tempmute = ":tempmute [player] [duration] [reason]",
		warn = ":warn [player] [reason]",
		msg = ":msg [player] [message]",
		["goto"] = ":goto [player]", -- bracket form since "goto" is a Luau keyword and unsafe as a bare table-constructor key
		ban = ":ban [player] [reason]",
		tempban = ":tempban [player] [duration] [reason]",
		freeze = ":freeze [player]",
		unfreeze = ":unfreeze [player]",
		bring = ":bring [player]",
		warnlist = ":warnlist",
		banlist = ":banlist",
		mutelist = ":mutelist",
		setrank = ":setrank [player] [rank name]",
		promote = ":promote [player] (next rarer rank)",
		demote = ":demote [player] (next commoner rank)",
		announce = ":announce [message]",
		cmdlogs = ":cmdlogs",
		setadminrank = ":setadminrank [player] [rank]",
		setbubbles = ":setbubbles [player] [amount]",
		setgems = ":setgems [player] [amount]",
		wipelogs = ":wipelogs",
		givegamepass = ":givegamepass [player] [pass]",
		removegamepass = ":removegamepass [player] [pass]",
		daily = ":daily [player] [option]",
		finishrun = ":finishrun [player]",
		givecoins = ":givecoins [player] [amount]",
		givepet = ":givepet [player] [pet]",
		unlockall = ":unlockall [player]",
		setrebirths = ":setrebirths [player] [count]",
		playerlogs = ":playerlogs [admin]",
		kill = ":kill [player]",
		jail = ":jail [player] (toggles on/off)",
		god = ":god [player] (toggles on/off)",
		invis = ":invis [player] (toggles on/off)",
		respawn = ":respawn [player]",
		spectate = ":spectate [player]",
		controlplayer = ":controlplayer [player]",
		viewinv = ":viewinv [player]",
		clearinv = ":clearinv [player]",
		fly = ":fly [player] (toggles on/off)",
		give = ":give [player] [item name]",
	}

	-- Groups the sidebar into named subheadings rather than one flat
	-- list, so e.g. every punishment command sits together separately
	-- from the movement commands. A command with no listed category
	-- (future-proofing) falls into a trailing "Other" group instead of
	-- silently vanishing from the sidebar.
	local COMMAND_CATEGORY = {
		kick = "Punishments",
		mute = "Punishments",
		tempmute = "Punishments",
		warn = "Punishments",
		ban = "Punishments",
		tempban = "Punishments",
		warnlist = "Punishments",
		banlist = "Punishments",
		mutelist = "Punishments",
		["goto"] = "Movement",
		bring = "Movement",
		freeze = "Movement",
		unfreeze = "Movement",
		setrank = "Ranks",
		promote = "Ranks",
		demote = "Ranks",
		msg = "Messaging",
		announce = "Messaging",
		cmdlogs = "Logs",
		playerlogs = "Logs",
		setbubbles = "Currency",
		setgems = "Currency",
		givecoins = "Currency",
		givepet = "Game",
		unlockall = "Game",
		setrebirths = "Game",
		finishrun = "Game",
		daily = "Game",
		setadminrank = "Owner Tools",
		wipelogs = "Owner Tools",
		givegamepass = "Owner Tools",
		removegamepass = "Owner Tools",
		-- Ad-hoc control actions against a target's character, kept
		-- separate from "Punishments" above - those are all formal,
		-- logged-with-a-reason records (kick/mute/warn/ban); these are
		-- more immediate/situational.
		kill = "Moderation",
		jail = "Moderation",
		god = "Moderation",
		invis = "Moderation",
		respawn = "Movement",
		spectate = "Movement",
		controlplayer = "Movement",
		viewinv = "Inventory",
		clearinv = "Inventory",
		fly = "Utility",
		give = "Utility",
	}

	-- :warnlist/:banlist/:mutelist/:cmdlogs/:announce don't target a
	-- player - they're either plain commands (the lists, cmdlogs) or take
	-- free text instead of a name (announce), so the player-name dropdown
	-- (and Tab-to-complete) should never engage for them the way it does
	-- for e.g. :kick. :playerlogs is deliberately NOT in here - it takes
	-- an admin's name as its target and gets normal player suggestions.
	local NO_TARGET_COMMANDS = {warnlist = true, banlist = true, mutelist = true, cmdlogs = true, announce = true,
		wipelogs = true}

	-- Genuinely zero-argument commands - clicking these in the sidebar
	-- runs them immediately instead of just populating the input box,
	-- since there's nothing left for the admin to type. :announce is
	-- deliberately NOT in here even though it's also in
	-- NO_TARGET_COMMANDS above - it still needs a message typed in.
	local INSTANT_EXECUTE_COMMANDS = {warnlist = true, banlist = true, mutelist = true, cmdlogs = true,
		wipelogs = true}
	local CATEGORY_ORDER = {"Punishments", "Moderation", "Ranks", "Messaging", "Movement", "Inventory", "Currency", "Game", "Utility", "Logs", "Owner Tools", "Other"}

	local function focusInputWithText(text)
		inputBox.Text = text
		inputBox:CaptureFocus()
		inputBox.CursorPosition = #text + 1
	end

	-- Roblox's own TextBox inserts a literal tab character when Tab is
	-- pressed while it's focused, on top of whatever this script sets the
	-- text to for the actual autofill - that stray "\t" is what was
	-- rendering as a gap, not anything this script was doing on purpose.
	-- Stripping it out unconditionally, every time, is simpler and more
	-- reliable than trying to guess how many frames Roblox needs to finish
	-- inserting it: a tab character has no legitimate reason to ever be in
	-- a command box, so there's no case where removing it is wrong.
	inputBox:GetPropertyChangedSignal("Text"):Connect(function()
		if inputBox.Text:find("\t") then
			local cursor = inputBox.CursorPosition
			local _, tabCount = inputBox.Text:sub(1, cursor - 1):gsub("\t", "")
			inputBox.Text = inputBox.Text:gsub("\t", "")
			inputBox.CursorPosition = math.max(cursor - tabCount, 1)
		end
	end)

	local function buildCommandRow(commandName, order)
		local row = Instance.new("TextButton")
		row.Name = "Cmd_" .. commandName
		row.Size = UDim2.new(1, 0, 0, 40)
		row.BackgroundColor3 = BG_ROW
		row.AutoButtonColor = false
		row.Text = ""
		row.LayoutOrder = order
		row.Parent = sidebar
		Instance.new("UICorner", row).CornerRadius = RADIUS_CTRL

		local nameLabel = Instance.new("TextLabel")
		nameLabel.Size = UDim2.new(1, -16, 0, 18)
		nameLabel.Position = UDim2.new(0, 10, 0, 4)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Font = BODY_FONT
		nameLabel.TextColor3 = TEXT_MAIN
		nameLabel.TextSize = 13
		nameLabel.TextXAlignment = Enum.TextXAlignment.Left
		nameLabel.Text = ":" .. commandName
		nameLabel.Parent = row

		local usageLabel = Instance.new("TextLabel")
		usageLabel.Size = UDim2.new(1, -16, 0, 14)
		usageLabel.Position = UDim2.new(0, 10, 0, 21)
		usageLabel.BackgroundTransparency = 1
		usageLabel.Font = BODY_FONT
		usageLabel.TextColor3 = TEXT_DIM
		usageLabel.TextSize = 10
		usageLabel.TextXAlignment = Enum.TextXAlignment.Left
		usageLabel.TextTruncate = Enum.TextTruncate.AtEnd
		usageLabel.Text = COMMAND_USAGE[commandName] or (":" .. commandName)
		usageLabel.Parent = row

		row.MouseButton1Click:Connect(function()
			if INSTANT_EXECUTE_COMMANDS[commandName] then
				AdminCommand:FireServer(commandName, "", "")
				inputBox.Text = ""
			else
				focusInputWithText(":" .. commandName .. " ")
			end
		end)
		row.MouseEnter:Connect(function() row.BackgroundColor3 = BG_HOVER end)
		row.MouseLeave:Connect(function() row.BackgroundColor3 = BG_ROW end)
	end

	local function buildCategoryHeader(name, order)
		local subheader = Instance.new("TextLabel")
		subheader.Size = UDim2.new(1, 0, 0, 20)
		subheader.BackgroundTransparency = 1
		subheader.Font = BODY_FONT
		subheader.TextColor3 = TEXT_DIM
		subheader.TextSize = 11
		subheader.TextXAlignment = Enum.TextXAlignment.Left
		subheader.Text = string.upper(name)
		subheader.LayoutOrder = order
		subheader.Parent = sidebar
	end

	-- Explicit display order within the Punishments group - server order
	-- (the order TIER_COMMANDS lists them in) isn't the order they
	-- should actually appear in the sidebar. Movement isn't in here
	-- since it wasn't asked to be reordered - it keeps whatever order it
	-- already had.
	local PUNISHMENT_ORDER = {
		warn = 1, mute = 2, kick = 3, ban = 4, tempmute = 5, tempban = 6,
		warnlist = 7, mutelist = 8, banlist = 9,
	}

	-- Wrapped in a function so the sidebar can be rebuilt in place when
	-- the tier changes, rather than only once at startup. The Studio
	-- :setadminrank tool makes that a real case: dropping yourself to
	-- Moderator has to actually take the higher-tier commands away, or
	-- there's no way to check the gating works.
	--
	-- Only the LIST is rebuilt, never the whole panel. buildPanel also
	-- creates the ClosePanels event that TopBar.lua waits on, plus a pile
	-- of input connections - re-running it would duplicate every one of
	-- them and leave the old panel's handlers still firing.
	local function populateCommands(commands)
		-- Headers and rows only; the UIListLayout has to survive, or the
		-- rebuilt rows would stack on top of each other at position 0.
		for _, child in ipairs(sidebar:GetChildren()) do
			if child:IsA("TextButton") or child:IsA("TextLabel") then
				child:Destroy()
			end
		end

		-- Emptied and refilled rather than reassigned: the autocomplete
		-- closures below captured THIS table, and pointing the local at a
		-- new one would leave them reading the old command set forever.
		for key in pairs(myCommandsSet) do
			myCommandsSet[key] = nil
		end
		for _, commandName in ipairs(commands) do
			myCommandsSet[commandName] = true
		end

		local grouped = {}
		for _, commandName in ipairs(commands) do
			local category = COMMAND_CATEGORY[commandName] or "Other"
			if not grouped[category] then grouped[category] = {} end
			table.insert(grouped[category], commandName)
		end

		if grouped["Punishments"] then
			table.sort(grouped["Punishments"], function(a, b)
				local orderA = PUNISHMENT_ORDER[a] or math.huge
				local orderB = PUNISHMENT_ORDER[b] or math.huge
				if orderA == orderB then return a < b end
				return orderA < orderB
			end)
		end

		local layoutOrder = 0
		for _, category in ipairs(CATEGORY_ORDER) do
			local commandsInCategory = grouped[category]
			if commandsInCategory and #commandsInCategory > 0 then
				layoutOrder += 1
				buildCategoryHeader(category, layoutOrder)
				for _, commandName in ipairs(commandsInCategory) do
					layoutOrder += 1
					buildCommandRow(commandName, layoutOrder)
				end
			end
		end
	end

	populateCommands(myCommands)

	-- Published to the top-level hook so a later AdminInfoChanged can
	-- reach it without re-entering buildPanel.
	currentPanelTier = myTier
	refreshPanelCommands = function(commands, tier)
		populateCommands(commands)
		header.Text = "🛡️ Admin Panel"
		print("[AdminClient] Tier changed to " .. tier .. " (" .. #commands .. " commands)")
	end

	-- =================================================================
	-- Parsing + autocomplete
	-- =================================================================
	local function parseInput(text)
		local command, afterCommand = text:match("^:?(%S*)%s*(.*)$")
		command = command and string.lower(command) or ""
		local target, rest = afterCommand:match("^(%S*)%s*(.*)$")
		return command, (target or ""), (rest or "")
	end

	-- Shared by the dropdown and the Tab handler below, so Tab always
	-- computes matches fresh from the current text rather than depending on
	-- whatever the dropdown last cached - that dependency was the bug: if a
	-- Tab press causes Roblox to momentarily drop the TextBox's focus before
	-- this script's handler runs, a cached match list could already have
	-- been cleared by hideDropdown() by the time Tab was actually processed.
	-- An empty partial naturally matches every online player here (any
	-- string's first zero characters equal ""), which is what makes the
	-- dropdown able to show the full player list right after a command
	-- name, before any name has been typed yet.
	local function computeMatches(partial)
		local lowerPartial = string.lower(partial)
		local matches = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			if string.sub(string.lower(plr.Name), 1, #lowerPartial) == lowerPartial then
				table.insert(matches, plr.Name)
			end
		end
		table.sort(matches)
		return matches
	end

	local function hideDropdown()
		dropdown.Visible = false
		dropdown.Size = UDim2.new(1, -32, 0, 0)
		dropdown.ScrollBarThickness = 0
	end

	-- General command-name autocomplete - typing any partial command
	-- (":k", not just ":un...") shows every command this tier can use
	-- that starts with it, alphabetically, refining as more letters are
	-- typed. Matches are stored with their leading ":" so the dropdown
	-- row itself reads like a real command (":kick") rather than a bare
	-- word, matching the style the search-suggestion dropdowns elsewhere
	-- in this file already use.
	local function computeCommandMatches(partial)
		local lowerPartial = string.lower(partial)
		local matches = {}
		for _, commandName in ipairs(myCommands) do
			if string.sub(commandName, 1, #lowerPartial) == lowerPartial then
				table.insert(matches, ":" .. commandName)
			end
		end
		table.sort(matches)
		return matches
	end

	local function acceptCommandMatch(value)
		local commandName = value:sub(2)
		focusInputWithText(":" .. commandName .. " ")
		hideDropdown()
	end

	local function acceptMatch(fullName)
		local command, _, rest = parseInput(inputBox.Text)
		local newText = ":" .. command .. " " .. fullName .. " " .. rest
		newText = newText:gsub("%s+$", "") .. " "
		focusInputWithText(newText)
		hideDropdown()
	end

	-- :tempban/:tempmute take a THIRD field (duration) after the player
	-- name, and :setrank takes a rank name there instead - both need
	-- their own fixed-list suggestions rather than the player-name
	-- dropdown, once that field is "closed off" (a space typed right
	-- after the player name).
	local TEMP_DURATION_COMMANDS = {tempban = true, tempmute = true}
	local DURATION_SUGGESTIONS = {"1h", "6h", "12h", "24h", "3 days", "7 days", "2 weeks"}

	local RANK_SUGGEST_COMMANDS = {setrank = true}
	-- Keep in sync by hand with AdminServer.lua's IN_GAME_RANKS labels
	-- (and MainScript.lua's RANKS table, which those were copied from).
	-- Straight from Config.Ranks, so it never needs hand-syncing.
	local RANK_SUGGESTIONS = {}
	for _, rank in ipairs(GameConfig.Ranks) do
		table.insert(RANK_SUGGESTIONS, rank.Name)
	end

	-- :give's item-name suggestions - unlike RANK_SUGGESTIONS above, this
	-- doesn't need hand-syncing: info.GiveableItems came straight from
	-- GetAdminInfo, which reads ServerStorage.AdminGiveableItems live, so
	-- adding/removing a Tool there and rejoining is all it takes to
	-- update this list.
	local GIVE_SUGGEST_COMMANDS = {give = true}
	local GIVE_SUGGESTIONS = info.GiveableItems or {}

	-- Suggestions for commands whose FIRST argument is a fixed set of
	-- values rather than a player name. The three lists above all cover
	-- the field AFTER the player, which is no help to a command that
	-- never takes a player at all.
	--
	-- Without this, :tier fell through to the player-name dropdown and
	-- pressing Enter would swap the typed value for whichever player
	-- matched - so ":tier Admin" arrived at the server as ":tier
	-- EnderBuilda" and came back as a usage error that looked like the
	-- command was broken.
	--
	-- Only commands with a genuinely closed set of answers belong here.
	-- Free text - a ban reason, an announcement, a points figure - has
	-- nothing to suggest, and a dropdown over it would be in the way.
	local FIRST_ARG_SUGGESTIONS = {}

	-- :setadminrank takes a PLAYER first and the rank second, so its
	-- suggestions belong in the third field alongside :setrank's, not in
	-- the first-argument table above.
	local ADMIN_RANK_SUGGEST_COMMANDS = {setadminrank = true}
	local ADMIN_RANK_SUGGESTIONS = {"Moderator", "Admin", "Developer", "Founder", "clear"}

	-- :givegamepass and :removegamepass take a PLAYER first and the pass
	-- second, so the pass names go in the third field too. Hand-synced
	-- with GAMEPASS_IDS in AdminServer.lua.
	local GAMEPASS_SUGGEST_COMMANDS = {givegamepass = true, removegamepass = true}
	local GAMEPASS_SUGGESTIONS = {}
	for _, pass in ipairs(GameConfig.GamePasses) do
		table.insert(GAMEPASS_SUGGESTIONS, string.lower(pass.Key))
	end

	-- :daily takes a PLAYER first and the mode second, so its modes go in
	-- the third field too. "day" wants a number after it, which no closed
	-- list can offer - the usage line under the box carries that.
	-- :givepet takes a PLAYER first and the pet second (pet names, from Config.Pets).
	local PET_SUGGEST_COMMANDS = {givepet = true}
	local PET_SUGGESTIONS = {}
	for _, def in pairs(GameConfig.Pets) do
		table.insert(PET_SUGGESTIONS, def.Name)
	end
	table.sort(PET_SUGGESTIONS)

	local DAILY_SUGGEST_COMMANDS = {daily = true}
	local DAILY_SUGGESTIONS = {"skip", "break", "day", "reset", "show"}

	-- One place deciding which list a command's third field uses, rather
	-- than the same or-chain written out at both the dropdown and the Tab
	-- handler - they drifted apart the moment a fourth list was added.
	local function thirdFieldList(command)
		if TEMP_DURATION_COMMANDS[command] then return DURATION_SUGGESTIONS end
		if RANK_SUGGEST_COMMANDS[command] then return RANK_SUGGESTIONS end
		if ADMIN_RANK_SUGGEST_COMMANDS[command] then return ADMIN_RANK_SUGGESTIONS end
		if GAMEPASS_SUGGEST_COMMANDS[command] then return GAMEPASS_SUGGESTIONS end
		if GIVE_SUGGEST_COMMANDS[command] then return GIVE_SUGGESTIONS end
		if DAILY_SUGGEST_COMMANDS[command] then return DAILY_SUGGESTIONS end
		if PET_SUGGEST_COMMANDS[command] then return PET_SUGGESTIONS end
		return nil
	end

	-- True once the raw text has a command, a target, AND at least one
	-- more space after the target - i.e. the admin has moved on to
	-- typing something past the player name. rest=="" from parseInput
	-- can't distinguish "still typing the target" from "target is done,
	-- nothing typed for the next field yet" (both give an empty rest),
	-- so this checks the raw text directly instead.
	local function hasStartedThirdField(text)
		return text:match("^:?%S+%s+%S+%s") ~= nil
	end

	-- Unlike a player name (never contains a space), a suggestion value
	-- here can ("3 days", "Service Attendant") - splitting at the first
	-- space like a plain token (the old approach) chopped a multi-word
	-- value down to just its first word, so the exact-match check below
	-- could never recognize the full value as "done": after clicking
	-- "Service Attendant" the text became "...Service Attendant ", but
	-- this parsed that back as thirdPartial="Service", which isn't
	-- "Service Attendant" - so the dropdown never hid and kept re-
	-- showing the very suggestion just clicked. This instead treats the
	-- whole remainder as the third field unless/until it stops looking
	-- like the start of any known suggestion, at which point whatever's
	-- left over is genuine trailing content (only relevant for
	-- :tempban/:tempmute, where a reason follows the duration -
	-- :setrank has nothing after the rank name at all).
	local function splitThirdField(afterTarget, suggestions)
		local trimmed = afterTarget:gsub("%s+$", "")
		local lowerTrimmed = string.lower(trimmed)
		for _, suggestion in ipairs(suggestions) do
			if lowerTrimmed == string.lower(suggestion) then
				local afterMatch = afterTarget:sub(#trimmed + 1)
				return trimmed, (afterMatch:gsub("^%s+", ""))
			end
		end
		for _, suggestion in ipairs(suggestions) do
			if #lowerTrimmed > 0 and string.sub(string.lower(suggestion), 1, #lowerTrimmed) == lowerTrimmed then
				return trimmed, ""
			end
		end
		-- Neither an exact match nor still a prefix of one - but a
		-- multi-word suggestion ("3 days", "2 weeks") that's ALREADY been
		-- fully typed/accepted, with something else typed straight after
		-- it (starting the reason - "3 days too many warnings"), looks
		-- exactly like this too, since "3 days t" is neither "3 days"
		-- exactly nor a prefix of any suggestion. Without this check, the
		-- word-split fallback below chopped it down to just "3", which
		-- matched "3 days" as a fresh prefix all over again - reopening
		-- the dropdown for a duration already picked, and duplicating it
		-- into the input ("3 days days ...") if clicked again. Checking
		-- for "suggestion + a space" specifically (not just any prefix)
		-- distinguishes "done, now typing something new" from "still
		-- typing this suggestion".
		for _, suggestion in ipairs(suggestions) do
			local lowerSuggestion = string.lower(suggestion)
			if string.sub(lowerTrimmed, 1, #lowerSuggestion + 1) == lowerSuggestion .. " " then
				local remainder = trimmed:sub(#suggestion + 1):gsub("^%s+", "")
				return trimmed:sub(1, #suggestion), remainder
			end
		end
		local firstWord, rest = afterTarget:match("^(%S*)%s*(.*)$")
		return firstWord or "", rest or ""
	end

	local function parseThirdField(text)
		local command, afterCommand = text:match("^:?(%S*)%s*(.*)$")
		command = command and string.lower(command) or ""
		local target, afterTarget = afterCommand:match("^(%S*)%s*(.*)$")
		target = target or ""
		afterTarget = afterTarget or ""
		local list = TEMP_DURATION_COMMANDS[command] and DURATION_SUGGESTIONS
			or (RANK_SUGGEST_COMMANDS[command] and RANK_SUGGESTIONS)
			or (GIVE_SUGGEST_COMMANDS[command] and GIVE_SUGGESTIONS)
			or (PET_SUGGEST_COMMANDS[command] and PET_SUGGESTIONS)
			or {}
		local thirdPartial, remainder = splitThirdField(afterTarget, list)
		return command, target, thirdPartial, remainder
	end

	local function computeSuggestionMatches(list, partial)
		local lowerPartial = string.lower(partial)
		local matches = {}
		for _, suggestion in ipairs(list) do
			if lowerPartial == "" or string.sub(string.lower(suggestion), 1, #lowerPartial) == lowerPartial then
				table.insert(matches, suggestion)
			end
		end
		return matches
	end

	local function acceptThirdFieldMatch(value)
		local command, target, _, remainder = parseThirdField(inputBox.Text)
		local newText = ":" .. command .. " " .. target .. " " .. value
		if RANK_SUGGEST_COMMANDS[command] or GIVE_SUGGEST_COMMANDS[command] or PET_SUGGEST_COMMANDS[command] then
			-- The rank/item name is the LAST field :setrank/:give has -
			-- nothing follows it, so no trailing space is added here.
			-- Leaving one (the old behavior, same as every other field)
			-- meant the server received "Service Attendant " with a
			-- trailing space as extraText, which findRank's exact-match
			-- check doesn't match against the stored "Service Attendant"
			-- label - so it always reported "No rank found" even though
			-- the right name had just been picked from the dropdown.
			-- Same failure mode would hit :give's own exact-match lookup.
			newText = newText:gsub("%s+$", "")
		else
			newText = (newText .. " " .. remainder):gsub("%s+$", "") .. " "
		end
		focusInputWithText(newText)
		hideDropdown()
	end

	-- Builds a row for every match, not just the first MAX_VISIBLE_MATCHES
	-- - the dropdown itself now scrolls once there's more content than
	-- that (see the ScrollingFrame comment above), rather than never
	-- creating the rest at all. Only shows a scrollbar when the list
	-- actually overflows the visible area - a short list that already
	-- fits stays exactly as before, no scroll affordance for no reason.
	local function renderDropdownMatches(matches, onAccept)
		local visibleRows = math.min(#matches, MAX_VISIBLE_MATCHES)
		dropdown.Size = UDim2.new(1, -32, 0, visibleRows * MATCH_ROW_HEIGHT)
		dropdown.ScrollBarThickness = (#matches > MAX_VISIBLE_MATCHES) and 5 or 0
		dropdown.CanvasPosition = Vector2.new(0, 0)
		dropdown.Visible = true

		for i, value in ipairs(matches) do
			local btn = Instance.new("TextButton")
			btn.Size = UDim2.new(1, 0, 0, MATCH_ROW_HEIGHT)
			btn.LayoutOrder = i
			btn.BackgroundColor3 = BG_HOVER
			btn.AutoButtonColor = false
			btn.Font = BODY_FONT
			btn.TextColor3 = TEXT_MAIN
			btn.TextSize = 13
			btn.Text = value
			btn.ZIndex = 6
			btn.Parent = dropdown
			btn.MouseButton1Click:Connect(function()
				onAccept(value)
			end)
		end
	end

	local function updateDropdown()
		for _, child in ipairs(dropdown:GetChildren()) do
			if child:IsA("TextButton") then child:Destroy() end
		end

		-- Still typing the command name itself (no space after it yet) -
		-- suggest matching command names instead of falling through to the
		-- player-name/third-field logic below, which all assume the
		-- command portion is already finished.
		local hasSpaceAfterCommand = inputBox.Text:match("^:?%S+%s") ~= nil
		if not hasSpaceAfterCommand then
			local commandPartial = inputBox.Text:match("^:?(%S*)$") or ""
			if commandPartial == "" then
				hideDropdown()
				return
			end
			local commandMatches = computeCommandMatches(commandPartial)
			if #commandMatches == 0 or (#commandMatches == 1 and commandMatches[1] == ":" .. string.lower(commandPartial)) then
				hideDropdown()
				return
			end
			renderDropdownMatches(commandMatches, acceptCommandMatch)
			return
		end

		-- Requires a command this tier can actually use (not just any
		-- non-empty text) before showing suggestions - typing gibberish
		-- shouldn't pop up the full player list. Once that's satisfied,
		-- suggestions show immediately, even before any name has been typed
		-- (targetPartial == "" matches everyone) - previously this required
		-- at least one character of a name first, so typing ":kick " and
		-- stopping there showed nothing until you started typing a name.
		local command, targetPartial = parseInput(inputBox.Text)

		-- Checked BEFORE the no-target bail-out below: these commands are
		-- in NO_TARGET_COMMANDS (they take a value, not a player), so that
		-- check would otherwise hide the dropdown before they ever got a
		-- chance to offer their own suggestions.
		local firstArgList = FIRST_ARG_SUGGESTIONS[command]
		if firstArgList and myCommandsSet[command] then
			local matches = computeSuggestionMatches(firstArgList, targetPartial)
			if #matches == 0 or (#matches == 1 and string.lower(matches[1]) == string.lower(targetPartial)) then
				hideDropdown()
				return
			end
			-- acceptMatch fills the target field, which is exactly where
			-- a first argument goes - the same slot a player name uses.
			renderDropdownMatches(matches, acceptMatch)
			return
		end

		if not myCommandsSet[command] or NO_TARGET_COMMANDS[command] then
			hideDropdown()
			return
		end

		local dropdownThirdList = thirdFieldList(command)
		if dropdownThirdList and hasStartedThirdField(inputBox.Text) then
			local _, _, thirdPartial = parseThirdField(inputBox.Text)
			local matches = computeSuggestionMatches(dropdownThirdList, thirdPartial)
			if #matches == 0 or (#matches == 1 and string.lower(matches[1]) == string.lower(thirdPartial)) then
				hideDropdown()
				return
			end
			renderDropdownMatches(matches, acceptThirdFieldMatch)
			return
		end

		local matches = computeMatches(targetPartial)

		-- If the only match is already an exact (case-insensitive) match for
		-- what's typed, the name is already complete - showing a dropdown
		-- offering to "complete" it to itself is just noise, and without this
		-- check the dropdown would briefly reopen right after accepting a
		-- match, since Text changes (even ones this script makes) run back
		-- through this same function.
		if #matches == 1 and string.lower(matches[1]) == string.lower(targetPartial) then
			hideDropdown()
			return
		end

		if #matches == 0 then
			hideDropdown()
			return
		end

		renderDropdownMatches(matches, acceptMatch)
	end

	inputBox:GetPropertyChangedSignal("Text"):Connect(updateDropdown)

	-- Ghost-text field hint ("[player]", then "[reason]", etc.) - shows
	-- what to type next, and disappears the moment that field gets any
	-- text. Pulls the field list straight out of COMMAND_USAGE's bracket
	-- placeholders, so it works for every command generically instead of
	-- needing a hand-written hint sequence per command.
	local function extractFieldHints(usage)
		local fields = {}
		for field in usage:gmatch("%[[^%]]*%]") do
			table.insert(fields, field)
		end
		return fields
	end

	local function escapeRichText(text)
		text = text:gsub("&", "&amp;")
		text = text:gsub("<", "&lt;")
		text = text:gsub(">", "&gt;")
		text = text:gsub("\"", "&quot;")
		return text
	end

	-- Matches BG_ROW (inputHolder's background) - the "already typed"
	-- spacer text is rendered in this color so it blends invisibly into
	-- the background, leaving only the hint text visible right after it.
	local INPUT_BG_HEX = "#1E4880" -- BG_ROW

	local function updateInputHint()
		local text = inputBox.Text
		local command = parseInput(text)
		local usage = COMMAND_USAGE[command]
		if not usage or not myCommandsSet[command] then
			hintLabel.Text = ""
			return
		end

		local fields = extractFieldHints(usage)
		if #fields == 0 then
			hintLabel.Text = ""
			return
		end

		-- How many fields are "closed" (a space typed after them),
		-- capped at #fields since the last field can itself contain
		-- spaces (a reason/message) that shouldn't count as closing
		-- further fields beyond the last one.
		local closedCount = 0
		for _ in text:gmatch("%S+%s+") do
			closedCount += 1
			if closedCount >= #fields then
				closedCount = #fields
				break
			end
		end
		if closedCount == 0 then
			hintLabel.Text = ""
			return
		end

		local afterCommand = text:match("^:?%S*%s*(.*)$") or ""
		local remaining = afterCommand
		for i = 1, closedCount - 1 do
			local _, rest = remaining:match("^(%S*)%s*(.*)$")
			remaining = rest or ""
		end
		local currentFieldText = (closedCount == #fields) and remaining or (remaining:match("^(%S*)") or "")

		if currentFieldText ~= "" then
			hintLabel.Text = ""
			return
		end

		hintLabel.Text = "<font color=\"" .. INPUT_BG_HEX .. "\">" .. escapeRichText(text) .. "</font><font color=\"#8C8C8C\">" .. fields[closedCount] .. "</font>"
	end

	inputBox:GetPropertyChangedSignal("Text"):Connect(updateInputHint)

	-- Global (not gated on gameProcessed, unlike the ; shortcut below) so
	-- this still fires even if Roblox marks Tab as "game processed" while a
	-- TextBox has focus - checking IsFocused() directly is what scopes it to
	-- only fire while typing in this box, instead of the processed flag.
	-- Only completes player names, not durations/ranks - Tab picking "the
	-- first suggestion" isn't an obviously-right guess for those the way
	-- "the first matching player" is, so those stay click-only.
	UIS.InputBegan:Connect(function(input)
		if input.KeyCode ~= Enum.KeyCode.Tab then return end
		if not inputBox:IsFocused() then return end

		-- Still typing the command word itself (no space after it yet) -
		-- complete THAT first, same as Minecraft's own chat autocomplete
		-- (":f" + Tab -> ":fly ", not straight to a player name, which
		-- previously happened because this handler only ever knew how to
		-- complete the player-name field). A second Tab press, once the
		-- command is complete, falls through to the player-name
		-- completion below exactly as before.
		if not inputBox.Text:match("^:?%S+%s") then
			local commandPartial = inputBox.Text:match("^:?(%S*)$") or ""
			if commandPartial == "" then return end
			local commandMatches = computeCommandMatches(commandPartial)
			if #commandMatches > 0 then
				-- commandMatches entries already come back as ":kick"
				-- (computeCommandMatches' own format) - acceptCommandMatch
				-- expects exactly that, same as the dropdown's own click
				-- handler uses.
				local chosenMatch = commandMatches[1]
				task.defer(function()
					acceptCommandMatch(chosenMatch)
				end)
			end
			return
		end

		local command, targetPartial = parseInput(inputBox.Text)

		-- Same ordering reason as in the dropdown: these live in
		-- NO_TARGET_COMMANDS, so the bail-out below would stop Tab
		-- completing them before their own list was ever consulted.
		local firstArgList = FIRST_ARG_SUGGESTIONS[command]
		if firstArgList then
			local matches = computeSuggestionMatches(firstArgList, targetPartial)
			if #matches > 0 then
				local chosenValue = matches[1]
				task.defer(function()
					acceptMatch(chosenValue)
				end)
			end
			return
		end

		if NO_TARGET_COMMANDS[command] then return end

		-- Once past the player-name field, a command with its own
		-- third-field suggestions (:tempban/:tempmute's duration,
		-- :setrank's rank, :give's item) completes THAT via Tab too now,
		-- same as the command name and player name already do - the admin
		-- asked for every field with an auto-suggestion to fill on Tab,
		-- not just player names.
		local tabThirdList = thirdFieldList(command)
		if tabThirdList and hasStartedThirdField(inputBox.Text) then
			local _, _, thirdPartial = parseThirdField(inputBox.Text)
			local matches = computeSuggestionMatches(tabThirdList, thirdPartial)
			if #matches > 0 then
				local chosenValue = matches[1]
				task.defer(function()
					acceptThirdFieldMatch(chosenValue)
				end)
			end
			return
		end

		local matches = computeMatches(targetPartial)
		if #matches > 0 then
			-- Deferred rather than called inline - Roblox's own TextBox
			-- can still be mid-way through its own handling of this same
			-- Tab keypress when this fires, and if that's still pending
			-- when focusInputWithText below sets the text/cursor, it can
			-- land a moment later and land right where the cursor now
			-- is, showing up as a stray gap between the name it just
			-- filled in and wherever the reason is about to be typed.
			-- Deferring to the next resumption point lets whatever
			-- Roblox itself does happen first, so this always has the
			-- last word on the text.
			local chosenName = matches[1]
			task.defer(function()
				acceptMatch(chosenName)
			end)
		end
	end)

	inputBox.FocusLost:Connect(function(enterPressed)
		-- Skipped while hovering the dropdown - see the comment by
		-- hoveringDropdown above. acceptMatch() (called from the button's own
		-- click handler) hides the dropdown itself once the click is done.
		if hoveringDropdown then return end
		hideDropdown()
		if not enterPressed then return end
		local command, target, rest = parseInput(inputBox.Text)
		if command == "" then return end

		if command == "cmds" then
			inputBox.Text = ""
			return
		end

		-- Starts the teleport cover fading in right away, rather than
		-- reacting once AdminSpectate/AdminControlPlayer's own confirmation
		-- arrives - by the time that confirmation (and the actual server-
		-- side teleport it follows) lands, the screen should already be
		-- black, hiding the jump instead of revealing it mid-transition.
		--
		-- Skipped entirely for the two cases the server is certain to
		-- refuse: no name typed at all, and targeting yourself. Neither
		-- produces a teleport to hide, so fading out only to immediately
		-- fade back in on the error was a pointless flash of black.
		-- Self-matching is deliberately conservative - it only skips when
		-- the typed name resolves to exactly one player and that player is
		-- us, so an ambiguous partial still behaves exactly as before.
		-- Blanked the moment a command is sent, so the PREVIOUS command's
		-- result can't sit here looking like this one's. It used to stay
		-- put for the whole server round trip, which read as the status
		-- line flashing green (the last success) before turning red with
		-- the actual answer. Nothing needs to be shown in its place - the
		-- reply lands within a frame or two, and a real "running..."
		-- message would just be its own flicker.
		status.Text = ""

		-- Cleared BEFORE the cover wait below, not after the send.
		-- beginTeleportFade blocks for the length of the slide, and
		-- leaving the typed command sitting in the box for that long
		-- reads as the click not having registered.
		inputBox.Text = ""

		if command == "spectate" or command == "controlplayer" then
			local matches = computeMatches(target)
			local willBeRefused = target == ""
				or (#matches == 1 and matches[1] == player.Name)
			if not willBeRefused then
				-- Yields until the panel has fully covered the screen, so
				-- the server is not asked to teleport anyone until there
				-- is nothing to see. `target` and `rest` were captured
				-- above and are unaffected by the box being cleared.
				beginTeleportFade()
			end
		end

		AdminCommand:FireServer(command, target, rest)
	end)

	AdminFeedback.OnClientEvent:Connect(function(text, isError)
		status.TextColor3 = isError and ERROR_RED or Color3.fromRGB(52, 211, 153)
		status.Text = text
		-- An error here means a command was refused, which for
		-- :spectate/:controlplayer is the case where no confirmation is
		-- ever coming - so this is what reveals the screen again after a
		-- rejected one (see beginTeleportFade). Harmless for every other
		-- command, since nothing is pending in those cases.
		if isError then
			clearTeleportFade(true)
		end
	end)

	-- =================================================================
	-- Open/close - same centered slide-up-from-the-bottom tween TopBar.lua
	-- already uses for the Shop panel.
	-- =================================================================
	local isOpen = false

	-- Shop and this panel close each other when either opens - TopBar.lua
	-- creates the actual BindableEvent and also fires it when Shop opens or
	-- the respawn-warning popup shows. Resolved in the background
	-- (task.spawn below) rather than waited on synchronously here: this
	-- panel needs to stay fully usable even if that event is ever slow to
	-- show up, and a synchronous wait here previously produced a real
	-- deadlock against TopBar.lua doing the equivalent wait for THIS
	-- script's own ToggleAdminPanel event - both scripts sat stuck for the
	-- full WaitForChild timeout and neither event got created in time,
	-- which is why the Admin topbar button stopped opening anything.
	local closePanelsEvent = nil

	-- The ScreenGui itself is switched off while the panel is closed.
	--
	-- Positioning it off the bottom was not enough. ScreenInsets defaults
	-- to CoreUISafeInsets, which on a console reserves a TV-safe border -
	-- so "1" on the Y scale is the inset edge, well above the real bottom
	-- of the screen, and the panel's header sat visible below it over the
	-- loading screen and over gameplay. Disabling the Gui cannot be
	-- defeated by any amount of inset, whatever device this runs on.
	local function setPanelShown(shown)
		if shown then
			gui.Enabled = true
		else
			-- After the close tween, so the slide is still visible.
			task.delay(CLOSE_TWEEN_INFO.Time + 0.05, function()
				if not isOpen then gui.Enabled = false end
			end)
		end
	end

	gui.Enabled = false

	local function openPanel()
		if isOpen then return end
		-- This is the one choke point every way of opening the panel goes
		-- through - the topbar icon, the ~ shortcut below, and the
		-- forceState==true branch below - so gating it here (rather than
		-- at each caller) is what actually guarantees the admin panel
		-- can't appear over the loading screen or main menu no matter
		-- which of those triggers it.
		if sceneBlocked then return end
		if closePanelsEvent then closePanelsEvent:Fire("admin") end
		isOpen = true
		setPanelShown(true)
		panel.Position = PANEL_CLOSED_POS
		TweenService:Create(panel, OPEN_TWEEN_INFO, {Position = PANEL_OPEN_POS}):Play()
		inputBox:CaptureFocus()
	end

	local function closePanel()
		if not isOpen then return end
		isOpen = false
		hideDropdown()
		TweenService:Create(panel, CLOSE_TWEEN_INFO, {Position = PANEL_CLOSED_POS}):Play()
		setPanelShown(false)
	end

	local function toggle()
		if isOpen then closePanel() else openPanel() end
	end

	-- Belt-and-suspenders: if the scene ever becomes blocked again while
	-- the panel happens to be open (e.g. forced back to the main menu),
	-- force it shut rather than leaving it up over a screen it shouldn't
	-- be visible on. Chains onto whatever onSceneBlockedChanged already
	-- did (refreshIndicatorLayout, assigned earlier) rather than replacing
	-- it.
	do
		local previousOnSceneBlockedChanged = onSceneBlockedChanged
		onSceneBlockedChanged = function()
			if previousOnSceneBlockedChanged then previousOnSceneBlockedChanged() end
			if sceneBlocked then closePanel() end
		end
	end

	-- Ignored while a master list or the per-user warnings detail is open
	-- (listPopupOpen) - closing the whole admin panel out from under one
	-- of those was easy to do by accident and lost your place in it.
	closeButton.MouseButton1Click:Connect(function()
		if listPopupOpen then return end
		closePanel()
	end)

	-- Rinse Cycle has no top bar script making this, so the panel makes its own.
	if not ReplicatedStorage:FindFirstChild("ClosePanels") then
		local closePanels = Instance.new("BindableEvent")
		closePanels.Name = "ClosePanels"
		closePanels.Parent = ReplicatedStorage
	end
	task.spawn(function()
		local event = ReplicatedStorage:WaitForChild("ClosePanels", 10)
		if not event then
			warn("[AdminClient] ClosePanels event not found - Admin panel won't close Shop or be closed by it")
			return
		end
		closePanelsEvent = event
		-- Ignores its own broadcast (source == "admin") - under Roblox's
		-- deferred signal behavior this listener can run after openPanel()
		-- has already finished and set isOpen = true, so without the source
		-- check it would immediately close the panel that just opened.
		closePanelsEvent.Event:Connect(function(source)
			if source ~= "admin" then
				closePanel()
			end
		end)
	end)

	-- TopBar.lua's "Admin" icon fires this with no argument to toggle; the
	-- same event is fired with `false` when returning to the main menu, to
	-- force the panel shut rather than potentially toggling it back open.
	toggleAdminPanelEvent.Event:Connect(function(forceState)
		if forceState == nil then
			toggle()
		elseif forceState == false then
			closePanel()
		else
			openPanel()
		end
	end)

	-- ~ (backquote/tilde key) still works as a quick keyboard shortcut
	-- alongside the topbar icon. Was previously bound to ";", but that's
	-- the same physical key as ":" (shift+;), which every command needs
	-- to type - typing ":kick" was re-triggering this shortcut on its own
	-- leading colon. ~ doesn't collide with anything commands need.
	-- Checking inputBox:IsFocused() directly (same pattern as the Tab
	-- handler above) rather than relying only on gameProcessed - while the
	-- command box is focused (the normal state whenever this panel is
	-- open), Roblox marks this key as processed by that box, so a
	-- gameProcessed-only check would silently swallow the shortcut and let
	-- the box type a literal "`"/"~" instead, forcing the admin to click
	-- off the box first before it would close.
	UIS.InputBegan:Connect(function(input, gameProcessed)
		if input.KeyCode ~= Enum.KeyCode.Backquote then return end
		local wasInputFocused = inputBox:IsFocused()
		if not wasInputFocused and gameProcessed then return end
		toggle()
		if wasInputFocused then
			-- Roblox still inserts the literal "`"/"~" into the box as
			-- normal text input even though this same key just closed the
			-- panel - strip it back out a tick later instead of leaving a
			-- stray character sitting in whatever the admin had typed.
			task.defer(function()
				inputBox.Text = inputBox.Text:gsub("[`~]", "")
			end)
		end
	end)

	-- A small shield button at the top-left for the owner (phones and consoles have no ` key).
	-- Only built here, after the server confirmed a tier, so nobody else ever sees it.
	do
		local buttonGui = Instance.new("ScreenGui")
		buttonGui.Name = "AdminButton"
		buttonGui.ResetOnSpawn = false
		buttonGui.IgnoreGuiInset = true
		buttonGui.ScreenInsets = Enum.ScreenInsets.None
		buttonGui.DisplayOrder = 6
		buttonGui.Parent = playerGui
		local shield = Instance.new("TextButton")
		shield.Name = "OpenAdmin"
		shield.Size = UDim2.new(0, 44, 0, 44)
		shield.AnchorPoint = Vector2.new(0, 0.5)
		shield.BackgroundColor3 = BG_DARK
		shield.AutoButtonColor = true
		shield.Text = "🛡️"
		shield.TextSize = 22
		shield.Font = TITLE_FONT
		shield.TextColor3 = TEXT_MAIN
		shield.Parent = buttonGui
		Instance.new("UICorner", shield).CornerRadius = UDim.new(1, 0)
		outline(shield).Thickness = 2
		local function place()
			local inset = GuiService:GetGuiInset()
			-- In the top bar row, just right of Roblox's own menu and chat buttons.
			shield.Position = UDim2.new(0, 116, 0, math.max(inset.Y, 44) / 2 + 2)
		end
		place()
		task.delay(1, place)
		shield.MouseButton1Click:Connect(toggle)
	end

	print("[AdminClient] Panel ready")
end

buildPanel(GetAdminInfo:InvokeServer())
if not panelBuilt then
	print("[AdminClient] No staff tier on initial check - waiting for AdminInfoChanged (:setadminrank)")
end

task.spawn(function()
	local AdminInfoChanged = ReplicatedStorage:WaitForChild("AdminInfoChanged", 10)
	if not AdminInfoChanged then return end
	AdminInfoChanged.OnClientEvent:Connect(buildPanel)
end)
