--[[
	AdminClient - Rinse Cycle's admin panel and the admin effects every player can see.

	Everyone:
	  * Notices from staff (a centred card with an OK button), announcements (a banner across the
	    top), and status chips under the top bar: 🧊 Frozen, 🔇 Muted (with time left; the chat bar
	    is switched off too), 🎮 Being controlled, 🕊️ Flying (tap it or press F to take off / land).
	  * The full-screen cover that hides admin teleports (jail, spectate, control).

	The owner only (the server's GetAdminInfo decides; nobody else gets any of the panel):
	  * A 🛡️ Admin button under Trade in the left column (HUD.AddAdminButton). It opens the Admin window,
	    built with the game's own UIKit window style.
	  * Left: every player in the server (search, tap to pick). Top: command groups. Middle: that
	    group's commands. Bottom: the picked command's options (reason, amount, duration, rank, pet,
	    pass...) and a RUN button. There's also a command line (":mute name reason") for speed.
	  * Ban / mute / warn lists, the command log and inventories open inside the window, with
	    Modify / Remove / View on each row.
	  * Spectate and Control Player show a bar at the bottom with a Stop button.

	The server checks every command again (tier, owner, Studio-only). This script only draws.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local Client = script.Parent:WaitForChild("Client")
local UIKit = require(Client:WaitForChild("UIKit"))
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Colors = UIKit.Theme.Colors
local Fonts = UIKit.Theme.Fonts

local function remote(name: string): any
	return ReplicatedStorage:WaitForChild(name)
end

local GetAdminInfo = remote("GetAdminInfo")
local AdminCommand = remote("AdminCommand")
local AdminNotice = remote("AdminNotice")
local AdminFeedback = remote("AdminFeedback")
local AdminWarningsList = remote("AdminWarningsList")
local AdminViewWarnings = remote("AdminViewWarnings")
local AdminRemoveWarning = remote("AdminRemoveWarning")
local AdminBanList = remote("AdminBanList")
local AdminMuteList = remote("AdminMuteList")
local AdminWarnList = remote("AdminWarnList")
local AdminModifyPunishment = remote("AdminModifyPunishment")
local AdminLogsList = remote("AdminLogsList")
local AdminScreenFade = remote("AdminScreenFade")
local AdminRemoveLogEntry = remote("AdminRemoveLogEntry")
local AdminAnnouncement = remote("AdminAnnouncement")
local AdminFreezeStatus = remote("AdminFreezeStatus")
local AdminMuteStatus = remote("AdminMuteStatus")
local AdminSetFlying = remote("AdminSetFlying")
local AdminSpectate = remote("AdminSpectate")
local AdminStopSpectating = remote("AdminStopSpectating")
local AdminControlPlayer = remote("AdminControlPlayer")
local AdminControlMove = remote("AdminControlMove")
local AdminStopControlling = remote("AdminStopControlling")
local AdminControlTargetStatus = remote("AdminControlTargetStatus")
local AdminInventoryList = remote("AdminInventoryList")
local AdminInventoryRemoveItem = remote("AdminInventoryRemoveItem")
-- Remotes added in later versions of AdminServer. They're never waited on up front: if the server
-- script is older (or hasn't made them yet) the panel and the Admin button still appear, and only
-- that one feature does nothing until it exists.
local function laterRemote(name: string): any
	return {
		FireServer = function(_, ...)
			local r = ReplicatedStorage:FindFirstChild(name)
			if r and r:IsA("RemoteEvent") then
				r:FireServer(...)
			end
		end,
		OnClientEvent = {
			Connect = function(_, fn)
				task.spawn(function()
					local r = ReplicatedStorage:WaitForChild(name)
					if r:IsA("RemoteEvent") then
						r.OnClientEvent:Connect(fn)
					end
				end)
			end,
		},
	}
end
local AdminLeaderboard = laterRemote("AdminLeaderboard")
local AdminPetList = laterRemote("AdminPetList")
local AdminPetAction = laterRemote("AdminPetAction")
local AdminStaffList = laterRemote("AdminStaffList")
local AdminStaffAction = laterRemote("AdminStaffAction")
local AdminServerList = laterRemote("AdminServerList")
local AdminServerAction = laterRemote("AdminServerAction")

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

local function formatDuration(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	local d = seconds // 86400
	local h = (seconds % 86400) // 3600
	local m = (seconds % 3600) // 60
	local s = seconds % 60
	if d > 0 then
		return string.format("%dd %dh", d, h)
	elseif h > 0 then
		return string.format("%dh %dm", h, m)
	elseif m > 0 then
		return string.format("%dm %ds", m, s)
	end
	return string.format("%ds", s)
end

local function textBox(props: { [string]: any }): TextBox
	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.BorderSizePixel = 0
	box.ClearTextOnFocus = false
	box.Font = Fonts.Body
	box.TextSize = 18
	box.TextColor3 = Colors.Text
	box.PlaceholderColor3 = Colors.TextDim
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Text = ""
	for k, v in props do
		(box :: any)[k] = v
	end
	return box
end

-- A dark rounded field holding a TextBox.
local function field(parent: Instance, size: UDim2, position: UDim2, placeholder: string): TextBox
	local card = UIKit.Card({ Size = size, Position = position, Color = Colors.PanelDark, Parent = parent })
	card.Name = "Field"
	return textBox({
		Name = "Box",
		Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		PlaceholderText = placeholder,
		Parent = card,
	})
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if not child:IsA("UIListLayout") and not child:IsA("UIGridLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local function listLayout(parent: Instance, padding: number, horizontal: boolean?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, padding)
	if horizontal then
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
	end
	layout.Parent = parent
	return layout
end

local function scroller(parent: Instance, size: UDim2, position: UDim2, horizontal: boolean?): ScrollingFrame
	local s = Instance.new("ScrollingFrame")
	s.BackgroundTransparency = 1
	s.BorderSizePixel = 0
	s.Size = size
	s.Position = position
	s.ScrollBarThickness = 6
	s.ScrollBarImageColor3 = Colors.Primary
	s.CanvasSize = UDim2.new()
	s.AutomaticCanvasSize = if horizontal then Enum.AutomaticSize.X else Enum.AutomaticSize.Y
	s.ScrollingDirection = if horizontal then Enum.ScrollingDirection.X else Enum.ScrollingDirection.Y
	s.Parent = parent
	return s
end

----------------------------------------------------------------------------------------------------
-- Everyone: notices, announcements, status chips, flying, the teleport cover
----------------------------------------------------------------------------------------------------

local _statusGui, statusRoot = UIKit.CreateScreen("AdminStatus", 40)

-- Notice card (from AdminNotice): one at a time, the newest replaces the old one.
local noticeFrame: Frame? = nil
local function showNotice(title: string?, body: string?, footnote: string?, buttonLabel: string?)
	if noticeFrame then
		noticeFrame:Destroy()
	end
	local dim = Instance.new("Frame")
	dim.Name = "AdminNotice"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = Colors.Ink
	dim.BackgroundTransparency = 0.45
	dim.BorderSizePixel = 0
	dim.Active = true
	dim.ZIndex = 50
	dim.Parent = statusRoot
	noticeFrame = dim
	local card = UIKit.Card({
		Size = UDim2.fromOffset(560, 300),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		Color = Colors.Panel,
		Parent = dim,
	})
	UIKit.Stroke(card, Colors.Ink, 4)
	UIKit.Label({
		Text = "🛡️ " .. tostring(title or "Message from staff"),
		TextSize = 32,
		Size = UDim2.new(1, -40, 0, 44),
		Position = UDim2.fromOffset(20, 18),
		TextColor3 = Colors.Primary,
		Parent = card,
	})
	UIKit.Label({
		Text = tostring(body or ""),
		TextSize = 22,
		TextWrapped = true,
		Font = Fonts.Body,
		TextYAlignment = Enum.TextYAlignment.Top,
		Size = UDim2.new(1, -48, 0, 120),
		Position = UDim2.fromOffset(24, 72),
		Parent = card,
	})
	if footnote and footnote ~= "" then
		UIKit.Label({
			Text = tostring(footnote),
			TextSize = 16,
			TextWrapped = true,
			TextColor3 = Colors.TextDim,
			Size = UDim2.new(1, -48, 0, 24),
			Position = UDim2.fromOffset(24, 196),
			Parent = card,
		})
	end
	UIKit.Button({
		Text = tostring(buttonLabel or "OKAY"),
		Color = Colors.Primary,
		Size = UDim2.fromOffset(200, 54),
		Position = UDim2.new(0.5, 0, 1, -18),
		AnchorPoint = Vector2.new(0.5, 1),
		Parent = card,
		OnClick = function()
			dim:Destroy()
			if noticeFrame == dim then
				noticeFrame = nil
			end
		end,
	})
end
AdminNotice.OnClientEvent:Connect(showNotice)

-- Announcement banner (from :announce).
local bannerToken = 0
AdminAnnouncement.OnClientEvent:Connect(function(message: string)
	bannerToken += 1
	local token = bannerToken
	local old = statusRoot:FindFirstChild("Announcement")
	if old then
		old:Destroy()
	end
	local banner = UIKit.Card({
		Size = UDim2.fromOffset(820, 116),
		Position = UDim2.new(0.5, 0, 0, -140),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Panel,
		Parent = statusRoot,
	})
	banner.Name = "Announcement"
	UIKit.Stroke(banner, Colors.Primary, 4)
	UIKit.Label({
		Text = "📢 ANNOUNCEMENT",
		TextSize = 20,
		TextColor3 = Colors.Primary,
		Size = UDim2.new(1, 0, 0, 28),
		Position = UDim2.fromOffset(0, 8),
		Parent = banner,
	})
	UIKit.Label({
		Text = tostring(message),
		TextSize = 26,
		TextWrapped = true,
		Size = UDim2.new(1, -40, 0, 70),
		Position = UDim2.fromOffset(20, 38),
		Parent = banner,
	})
	UIKit.PlaySound("Click")
	local shown = UDim2.new(0.5, 0, 0, UIKit.TopInset() + 12)
	TweenService:Create(banner, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = shown }):Play()
	task.delay(8, function()
		if token ~= bannerToken or not banner.Parent then
			return
		end
		TweenService:Create(banner, TweenInfo.new(0.3), { Position = UDim2.new(0.5, 0, 0, -140) }):Play()
		task.delay(0.35, function()
			banner:Destroy()
		end)
	end)
end)

-- Status chips under the top bar.
local chipRow = Instance.new("Frame")
chipRow.Name = "Chips"
chipRow.BackgroundTransparency = 1
chipRow.AnchorPoint = Vector2.new(0.5, 0)
chipRow.Size = UDim2.fromOffset(900, 44)
chipRow.Parent = statusRoot
local chipLayout = listLayout(chipRow, 10, true)
chipLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
local function placeChips()
	chipRow.Position = UDim2.new(0.5, 0, 0, UIKit.TopInset() + 70)
end
placeChips()
UIKit.LayoutChanged:Connect(placeChips)

local function makeChip(name: string, color: Color3, order: number): (TextButton, TextLabel)
	local chip = Instance.new("TextButton")
	chip.Name = name
	chip.AutoButtonColor = false
	chip.Text = ""
	chip.Size = UDim2.fromOffset(200, 40)
	chip.AutomaticSize = Enum.AutomaticSize.X
	chip.BackgroundColor3 = color
	chip.BorderSizePixel = 0
	chip.LayoutOrder = order
	chip.Visible = false
	UIKit.Corner(chip, 20)
	UIKit.Stroke(chip, Colors.Ink, 3)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = chip
	local label = UIKit.Label({
		Text = "",
		TextSize = 20,
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = chip,
	})
	chip.Parent = chipRow
	return chip, label
end

local frozenChip, frozenLabel = makeChip("Frozen", Color3.fromRGB(96, 165, 250), 1)
frozenLabel.Text = "🧊 Frozen by staff"
local mutedChip, mutedLabel = makeChip("Muted", Colors.Bad, 2)
local controlledChip, controlledLabel = makeChip("Controlled", Colors.Warning, 3)
controlledLabel.Text = "🎮 Being controlled by staff"
local flyChip, flyLabel = makeChip("Flying", Colors.Accent, 4)

-- While frozen or being controlled by staff, this player's own movement keys / thumbstick / jump
-- do nothing at all (Roblox's PlayerModule controls are switched off), so they can't fight it.
local controlLocks: { [string]: boolean? } = {}
local function applyControlLock()
	local locked = next(controlLocks) ~= nil
	pcall(function()
		local playerModule = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule") :: any) :: any
		local controls = playerModule:GetControls()
		if locked then
			controls:Disable()
		else
			controls:Enable()
		end
	end)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and locked then
		humanoid.Jump = false
	end
end
local function setControlLock(reason: string, on: boolean)
	controlLocks[reason] = if on then true else nil
	applyControlLock()
end

AdminFreezeStatus.OnClientEvent:Connect(function(frozen: boolean)
	frozenChip.Visible = frozen == true
	setControlLock("Frozen", frozen == true)
end)
AdminControlTargetStatus.OnClientEvent:Connect(function(controlled: boolean)
	controlledChip.Visible = controlled == true
	setControlLock("Controlled", controlled == true)
end)
-- A freeze only covers the character it was put on: a new character moves again.
player.CharacterAdded:Connect(function()
	if controlLocks.Frozen then
		frozenChip.Visible = false
		setControlLock("Frozen", false)
	end
end)

-- Muted: a chip with the time left, and the chat bar switched off (the server blocks the messages
-- themselves; this just makes it obvious).
local muteExpiresAt: number? = nil
local muted = false
local function setChatBar(enabled: boolean)
	pcall(function()
		local bar = TextChatService:FindFirstChildOfClass("ChatInputBarConfiguration")
		if bar then
			bar.Enabled = enabled
		end
	end)
end
local function refreshMuteChip()
	mutedChip.Visible = muted
	if not muted then
		return
	end
	if muteExpiresAt then
		mutedLabel.Text = "🔇 Muted · " .. formatDuration(muteExpiresAt - os.time()) .. " left"
	else
		mutedLabel.Text = "🔇 Muted"
	end
end
AdminMuteStatus.OnClientEvent:Connect(function(isMuted: boolean, expiresAt: number?)
	muted = isMuted == true
	muteExpiresAt = if muted and type(expiresAt) == "number" then expiresAt else nil
	setChatBar(not muted)
	refreshMuteChip()
end)
task.spawn(function()
	while true do
		task.wait(1)
		if muted and muteExpiresAt and os.time() >= muteExpiresAt then
			muted = false
			muteExpiresAt = nil
			setChatBar(true)
		end
		refreshMuteChip()
	end
end)

-- Flying (:fly). While allowed: F or the chip takes off / lands. Moves with the normal controls
-- in the camera's direction; Space rises, Left Ctrl / Q sinks, Shift is faster.
local FLY_SPEED = 60
local flyAllowed = false
local flying = false
local flyParts: { Instance } = {}
local flyConn: RBXScriptConnection? = nil
local controls: any = nil
pcall(function()
	controls = (require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule")) :: any):GetControls()
end)

local function moveVector(): Vector3
	local mv = Vector3.zero
	if controls then
		local ok, v = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and typeof(v) == "Vector3" then
			mv = v
		end
	end
	return mv
end

local function stopFlying()
	flying = false
	if flyConn then
		flyConn:Disconnect()
		flyConn = nil
	end
	for _, inst in flyParts do
		inst:Destroy()
	end
	table.clear(flyParts)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.PlatformStand = false
	end
end

local function startFlying()
	stopFlying()
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then
		return
	end
	flying = true
	local attachment = Instance.new("Attachment")
	attachment.Name = "AdminFly"
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.MaxForce = math.huge
	velocity.VectorVelocity = Vector3.zero
	velocity.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.RigidityEnabled = true
	align.Parent = root
	flyParts = { attachment, velocity, align }
	humanoid.PlatformStand = true
	flyConn = RunService.RenderStepped:Connect(function()
		local camera = workspace.CurrentCamera
		if not camera or not root.Parent then
			return
		end
		local mv = moveVector()
		local dir = camera.CFrame.RightVector * mv.X - camera.CFrame.LookVector * mv.Z
		if UserInputService:GetFocusedTextBox() == nil then
			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				dir += Vector3.yAxis
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
				dir -= Vector3.yAxis
			end
		end
		local speed = if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then FLY_SPEED * 2 else FLY_SPEED
		velocity.VectorVelocity = if dir.Magnitude > 1e-3 then dir.Unit * speed else Vector3.zero
		local look = camera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		align.CFrame = CFrame.lookAt(Vector3.zero, if flat.Magnitude > 1e-3 then flat else Vector3.new(0, 0, -1))
	end)
end

local function refreshFlyChip()
	flyChip.Visible = flyAllowed
	flyLabel.Text = if flying then "🕊️ Flying · F / tap to land" else "🕊️ Fly · F / tap to take off"
end

local function toggleFly()
	if not flyAllowed then
		return
	end
	if flying then
		stopFlying()
	else
		startFlying()
	end
	refreshFlyChip()
end
flyChip.MouseButton1Click:Connect(toggleFly)

AdminSetFlying.OnClientEvent:Connect(function(enabled: boolean)
	flyAllowed = enabled == true
	if flyAllowed then
		startFlying()
	else
		stopFlying()
	end
	refreshFlyChip()
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or input.KeyCode ~= Enum.KeyCode.F then
		return
	end
	toggleFly()
end)
player.CharacterAdded:Connect(function()
	if flying then
		task.wait(0.5)
		startFlying()
	end
end)

-- Full-screen cover that hides teleports (jail, spectate, control).
local cover = Instance.new("Frame")
cover.Name = "TeleportCover"
cover.Size = UDim2.fromScale(1, 1)
cover.BackgroundColor3 = Colors.PanelDark
cover.BackgroundTransparency = 1
cover.BorderSizePixel = 0
cover.ZIndex = 60
cover.Visible = false
cover.Parent = statusRoot
local coverToken = 0
local function coverScreen()
	coverToken += 1
	cover.Visible = true
	local tween = TweenService:Create(cover, TweenInfo.new(0.2), { BackgroundTransparency = 0 })
	tween:Play()
	task.wait(0.22)
end
local function revealScreen()
	coverToken += 1
	local token = coverToken
	local tween = TweenService:Create(cover, TweenInfo.new(0.3), { BackgroundTransparency = 1 })
	tween:Play()
	task.delay(0.32, function()
		if token == coverToken then
			cover.Visible = false
		end
	end)
end
-- Covers now and uncovers by itself after `timeout` if nothing else does.
local function coverFor(timeout: number)
	task.spawn(function()
		coverScreen()
		local token = coverToken
		task.wait(timeout)
		if token == coverToken then
			revealScreen()
		end
	end)
end
AdminScreenFade.OnClientEvent:Connect(function()
	task.spawn(function()
		coverScreen()
		task.wait(0.5)
		revealScreen()
	end)
end)

----------------------------------------------------------------------------------------------------
-- Owner panel
----------------------------------------------------------------------------------------------------

-- Every command the panel knows, grouped. Only the ones the server lists for you are shown.
--   Target: "player" (the picked player), "none", or "text" (typed into the first box).
--   Inputs: what goes after the name, in order: { Kind = "text"|"number"|"duration"|"choice", ... }
type Input = { Kind: string, Placeholder: string?, Required: boolean?, Options: (() -> { { Label: string, Value: string } })? }
type Command = { Name: string, Icon: string, Label: string, Desc: string, Group: string, Target: string, Inputs: { Input }?, Danger: boolean? }

local function opts(list: { string }): () -> { { Label: string, Value: string } }
	return function()
		local out = {}
		for _, v in list do
			table.insert(out, { Label = v, Value = v })
		end
		return out
	end
end


local REASON: Input = { Kind = "text", Placeholder = "Reason (optional)" }
local DURATION: Input = { Kind = "duration" }

local COMMANDS: { Command } = ({
	-- Punish
	{ Name = "kick", Icon = "👢", Label = "Kick", Desc = "Removes them from the server.", Group = "Punish", Target = "player", Inputs = { REASON }, Danger = true },
	{ Name = "ban", Icon = "🔨", Label = "Ban", Desc = "Bans them for good (undo it from the Ban list).", Group = "Punish", Target = "player", Inputs = { REASON }, Danger = true },
	{ Name = "tempban", Icon = "⏳", Label = "Temp ban", Desc = "Bans them for a set time.", Group = "Punish", Target = "player", Inputs = { DURATION, REASON }, Danger = true },
	{ Name = "mute", Icon = "🔇", Label = "Mute / unmute", Desc = "Stops their chat messages. Run it again to unmute.", Group = "Punish", Target = "player", Inputs = { REASON } },
	{ Name = "tempmute", Icon = "⏱️", Label = "Temp mute", Desc = "Mutes them for a set time.", Group = "Punish", Target = "player", Inputs = { DURATION, REASON } },
	{ Name = "warn", Icon = "⚠️", Label = "Warn", Desc = "Gives them a warning they have to read.", Group = "Punish", Target = "player", Inputs = { { Kind = "text", Placeholder = "Reason", Required = true } } },
	{ Name = "banlist", Icon = "📋", Label = "Ban list", Desc = "Everyone banned. Modify or unban from here.", Group = "Punish", Target = "none" },
	{ Name = "mutelist", Icon = "📋", Label = "Mute list", Desc = "Everyone muted. Modify or unmute from here.", Group = "Punish", Target = "none" },
	{ Name = "warnlist", Icon = "📋", Label = "Warn list", Desc = "Everyone with warnings.", Group = "Punish", Target = "none" },
	-- Control
	{ Name = "freeze", Icon = "🧊", Label = "Freeze / unfreeze", Desc = "Stops them moving. Run it again to thaw.", Group = "Control", Target = "player" },
	{ Name = "unfreeze", Icon = "🔥", Label = "Unfreeze", Desc = "Lets them move again.", Group = "Control", Target = "player" },
	{ Name = "kill", Icon = "💀", Label = "Kill", Desc = "Resets their character.", Group = "Control", Target = "player" },
	{ Name = "respawn", Icon = "🔄", Label = "Respawn", Desc = "Respawns them where they were.", Group = "Control", Target = "player" },
	{ Name = "jail", Icon = "🚔", Label = "Jail / free", Desc = "Locks them in the jail. Run it again to let them out.", Group = "Control", Target = "player" },
	{ Name = "god", Icon = "✨", Label = "God mode", Desc = "Can't be hurt. Run it again to turn off.", Group = "Control", Target = "player" },
	{ Name = "invis", Icon = "👻", Label = "Invisible", Desc = "Hides their character and name tag. Toggles.", Group = "Control", Target = "player" },
	{ Name = "fly", Icon = "🕊️", Label = "Fly", Desc = "Lets them fly (F to take off / land). Toggles.", Group = "Control", Target = "player" },
	{ Name = "msg", Icon = "💬", Label = "Message", Desc = "Pops a message up on their screen.", Group = "Control", Target = "player", Inputs = { { Kind = "text", Placeholder = "Message", Required = true } } },
	-- Move
	{ Name = "goto", Icon = "➡️", Label = "Go to", Desc = "Teleports you to them.", Group = "Move", Target = "player" },
	{ Name = "bring", Icon = "⬅️", Label = "Bring", Desc = "Teleports them to you.", Group = "Move", Target = "player" },
	{ Name = "spectate", Icon = "👁️", Label = "Spectate", Desc = "Watch them. Stop from the bar at the bottom.", Group = "Move", Target = "player" },
	{ Name = "controlplayer", Icon = "🎮", Label = "Control", Desc = "Move their character with your controls.", Group = "Move", Target = "player" },
	{ Name = "serverlist", Icon = "🌍", Label = "All servers", Desc = "Everyone in every server: Join them (you arrive invisible) or Bring them here.", Group = "Move", Target = "none" },
	{ Name = "joinserver", Icon = "🛰️", Label = "Join server", Desc = "Teleport to that player's server, wherever they are (type their username).", Group = "Move", Target = "text", Inputs = { { Kind = "text", Placeholder = "Username", Required = true } } },
	{ Name = "bringserver", Icon = "🧲", Label = "Bring (any server)", Desc = "Pull that player from their server into yours (type their username).", Group = "Move", Target = "text", Inputs = { { Kind = "text", Placeholder = "Username", Required = true } } },
	{ Name = "viewpets", Icon = "🐾", Label = "Pets", Desc = "See their pets. Remove any, or add new ones.", Group = "Game", Target = "player" },
	-- Game
	{ Name = "givecoins", Icon = "💰", Label = "Give coins", Desc = "Coins for their current run.", Group = "Game", Target = "player", Inputs = { { Kind = "number", Placeholder = "Amount", Required = true } } },
	{ Name = "setbubbles", Icon = "🧼", Label = "Set bubbles", Desc = "Sets their Bubbles to an amount.", Group = "Game", Target = "player", Inputs = { { Kind = "number", Placeholder = "Amount", Required = true } } },
	{ Name = "setgems", Icon = "💎", Label = "Set gems", Desc = "Sets their Gems to an amount.", Group = "Game", Target = "player", Inputs = { { Kind = "number", Placeholder = "Amount", Required = true } } },
	{ Name = "givepet", Icon = "🐾", Label = "Give pet", Desc = "Adds a pet to their pets.", Group = "Game", Target = "player", Inputs = {
		{ Kind = "choice", Required = true, Options = function()
			local out = {}
			for _, def in Config.Pets do
				table.insert(out, { Label = def.Name, Value = def.Name })
			end
			table.sort(out, function(a, b)
				return a.Label < b.Label
			end)
			return out
		end },
		{ Kind = "choice", Options = function()
			return { { Label = "Normal", Value = "" }, { Label = "Golden", Value = "golden" }, { Label = "Rainbow", Value = "rainbow" } }
		end },
	} },
	{ Name = "setrebirths", Icon = "🌀", Label = "Set rebirths", Desc = "Sets how many times they've rebirthed.", Group = "Game", Target = "player", Inputs = { { Kind = "number", Placeholder = "Rebirths", Required = true } } },
	{ Name = "unlockall", Icon = "🔓", Label = "Unlock levels", Desc = "Unlocks every level for them.", Group = "Game", Target = "player" },
	{ Name = "finishrun", Icon = "🏁", Label = "Finish run", Desc = "Cleans every dish in their current run.", Group = "Game", Target = "player" },
	{ Name = "daily", Icon = "📅", Label = "Daily streak", Desc = "Check or change their daily reward streak.", Group = "Game", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = function()
		local out = {
			{ Label = "Show", Value = "show" },
			{ Label = "Ready now", Value = "skip" },
			{ Label = "Break streak", Value = "break" },
			{ Label = "Reset", Value = "reset" },
		}
		for day = 1, #Config.DailyRewards do
			table.insert(out, { Label = "Day " .. day, Value = "day " .. day })
		end
		return out
	end } } },
	{ Name = "setrank", Icon = "🎖️", Label = "Set rank", Desc = "Gives them a rank and equips it.", Group = "Game", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = function()
		local out = {}
		for _, rank in Config.Ranks do
			table.insert(out, { Label = rank.Icon .. " " .. rank.Name, Value = rank.Name })
		end
		return out
	end } } },
	{ Name = "promote", Icon = "⬆️", Label = "Promote", Desc = "Next rarer rank.", Group = "Game", Target = "player" },
	{ Name = "demote", Icon = "⬇️", Label = "Demote", Desc = "Next more common rank.", Group = "Game", Target = "player" },
	-- Server
	{ Name = "announce", Icon = "📢", Label = "Announce", Desc = "A banner on everyone's screen.", Group = "Server", Target = "none", Inputs = { { Kind = "text", Placeholder = "Announcement", Required = true } } },
	{ Name = "globalannounce", Icon = "🌍", Label = "Global announce", Desc = "A banner on everyone's screen in EVERY server of the game.", Group = "Server", Target = "none", Inputs = { { Kind = "text", Placeholder = "Announcement", Required = true } } },
	{ Name = "leaderboards", Icon = "🏆", Label = "Leaderboards", Desc = "See everyone on every leaderboard; reset someone's spot (they keep their stats).", Group = "Server", Target = "none" },
	{ Name = "givegamepass", Icon = "🎟️", Label = "Gift pass", Desc = "Gives them a game pass for free (saved).", Group = "Server", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = function()
		local out = {}
		for _, pass in Config.GamePasses do
			table.insert(out, { Label = pass.Icon .. " " .. pass.Name, Value = pass.Key })
		end
		return out
	end } } },
	{ Name = "removegamepass", Icon = "✂️", Label = "Remove pass", Desc = "Takes back a gifted pass.", Group = "Server", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = function()
		local out = {}
		for _, pass in Config.GamePasses do
			table.insert(out, { Label = pass.Icon .. " " .. pass.Name, Value = pass.Key })
		end
		return out
	end } } },
	{ Name = "cmdlogs", Icon = "📜", Label = "Command log", Desc = "Every admin command used.", Group = "Server", Target = "none" },
	{ Name = "playerlogs", Icon = "🔎", Label = "Logs by admin", Desc = "Commands used by one admin (type their username).", Group = "Server", Target = "text", Inputs = { { Kind = "text", Placeholder = "Admin username", Required = true } } },
	{ Name = "wipelogs", Icon = "🧹", Label = "Wipe logs", Desc = "Deletes the whole command log.", Group = "Server", Target = "none", Danger = true },
	{ Name = "setadminrank", Icon = "🛡️", Label = "Staff tier", Desc = "Make them Moderator, Admin or Developer (saved, works straight away), or clear it.", Group = "Server", Target = "player", Inputs = { { Kind = "choice", Required = true, Options = opts({ "Moderator", "Admin", "Developer", "clear" }) } } },
	{ Name = "stafflist", Icon = "📋", Label = "Staff list", Desc = "Everyone with a staff rank, online or not. Remove anyone.", Group = "Server", Target = "none" },
}) :: any
local GROUPS = {
	{ Name = "Punish", Icon = "🔨" },
	{ Name = "Control", Icon = "🧊" },
	{ Name = "Move", Icon = "🧭" },
	{ Name = "Game", Icon = "🧼" },
	{ Name = "Server", Icon = "📢" },
}
local DURATIONS = { "1h", "6h", "24h", "3d", "7d", "30d" }
local PRESETS = {
	{ Label = "1 hour", Seconds = 3600 },
	{ Label = "24 hours", Seconds = 86400 },
	{ Label = "7 days", Seconds = 7 * 86400 },
	{ Label = "30 days", Seconds = 30 * 86400 },
	{ Label = "Permanent", Seconds = nil },
}

local panelBuilt = false
local allowed: { [string]: boolean } = {}
local canRemoveLogs = false

local function buildPanel(info: any)
	if type(info) ~= "table" then
		return
	end
	local HUD = require(Client:WaitForChild("HUD")) :: any
	if not info.Tier then
		-- Not staff (any more): the panel and its button go away straight away.
		table.clear(allowed)
		if panelBuilt then
			if UIKit.IsWindowOpen("Admin") then
				UIKit.CloseWindow("Admin")
			end
			HUD.SetAdminButtonVisible(false)
		end
		return
	end
	allowed = {}
	for _, name in info.Commands or {} do
		allowed[string.lower(tostring(name))] = true
	end
	canRemoveLogs = info.CanRemoveLogs == true
	if panelBuilt then
		-- Already built (a new or changed rank): the button comes back and the commands are the
		-- new rank's the next time the window opens.
		HUD.SetAdminButtonVisible(true)
		if UIKit.IsWindowOpen("Admin") then
			UIKit.CloseWindow("Admin")
			UIKit.OpenWindow("Admin")
		end
		return
	end
	panelBuilt = true

	local _gui, panelRoot = UIKit.CreateScreen("AdminPanel", 12)
	local window, content = UIKit.Window({
		Name = "Admin",
		Title = "Admin",
		Icon = "🛡️",
		Size = Vector2.new(1000, 620),
		Parent = panelRoot,
	})

	-- The HUD button first, so it's there even if anything below goes wrong.
	HUD.AddAdminButton(function()
		UIKit.ToggleWindow("Admin")
	end)

	local selectedPlayer: Player? = nil
	local selectedGroup = GROUPS[1].Name
	local selectedCommand: Command? = nil

	------------------------------------------------------------------ players (left)
	local left = UIKit.Card({ Size = UDim2.new(0, 250, 1, -64), Color = Colors.PanelDark, Parent = content })
	left.Name = "Players"
	UIKit.Label({ Text = "PLAYERS", TextSize = 20, Size = UDim2.new(1, 0, 0, 30), Position = UDim2.fromOffset(0, 8), Parent = left })
	local search = field(left, UDim2.new(1, -20, 0, 38), UDim2.fromOffset(10, 42), "🔍 Search")
	local playerList = scroller(left, UDim2.new(1, -12, 1, -94), UDim2.fromOffset(6, 88))
	listLayout(playerList, 6)
	local playerRows: { [Player]: TextButton } = {}

	local formTitle: TextLabel
	local refreshForm: () -> ()

	local function paintRows()
		for plr, row in playerRows do
			row.BackgroundColor3 = if plr == selectedPlayer then Colors.Primary else Colors.PanelLight
		end
	end

	local function refreshPlayers()
		clear(playerList)
		table.clear(playerRows)
		local filter = string.lower(search.Text)
		local list = Players:GetPlayers()
		table.sort(list, function(a, b)
			return a.Name:lower() < b.Name:lower()
		end)
		if selectedPlayer and selectedPlayer.Parent ~= Players then
			selectedPlayer = nil
		end
		for i, plr in list do
			if filter ~= "" and not (plr.Name:lower():find(filter, 1, true) or plr.DisplayName:lower():find(filter, 1, true)) then
				continue
			end
			local row = Instance.new("TextButton")
			row.Name = plr.Name
			row.AutoButtonColor = true
			row.Text = ""
			row.Size = UDim2.new(1, -8, 0, 56)
			row.LayoutOrder = i
			row.BorderSizePixel = 0
			row.BackgroundColor3 = Colors.PanelLight
			UIKit.Corner(row, 10)
			local head = Instance.new("ImageLabel")
			head.Size = UDim2.fromOffset(44, 44)
			head.Position = UDim2.fromOffset(6, 6)
			head.BackgroundColor3 = Colors.Panel
			head.BorderSizePixel = 0
			UIKit.Corner(head, 22)
			head.Parent = row
			task.spawn(function()
				local ok, image = pcall(function()
					return Players:GetUserThumbnailAsync(plr.UserId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48)
				end)
				if ok and head.Parent then
					head.Image = image
				end
			end)
			UIKit.Label({
				Text = plr.DisplayName,
				TextSize = 18,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -64, 0, 24),
				Position = UDim2.fromOffset(58, 6),
				Parent = row,
			})
			UIKit.Label({
				Text = "@" .. plr.Name .. (if plr == player then " (you)" else ""),
				TextSize = 14,
				TextColor3 = Colors.TextDim,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
				Size = UDim2.new(1, -64, 0, 20),
				Position = UDim2.fromOffset(58, 30),
				Parent = row,
			})
			row.MouseButton1Click:Connect(function()
				selectedPlayer = if selectedPlayer == plr then nil else plr
				paintRows()
				refreshForm()
			end)
			row.Parent = playerList
			playerRows[plr] = row
		end
		paintRows()
	end
	search:GetPropertyChangedSignal("Text"):Connect(refreshPlayers)

	------------------------------------------------------------------ groups + commands (right)
	local right = Instance.new("Frame")
	right.Name = "Right"
	right.BackgroundTransparency = 1
	right.Position = UDim2.fromOffset(262, 0)
	right.Size = UDim2.new(1, -262, 1, -64)
	right.Parent = content

	local tabs = Instance.new("Frame")
	tabs.Name = "Groups"
	tabs.BackgroundTransparency = 1
	tabs.Size = UDim2.new(1, 0, 0, 48)
	tabs.Parent = right
	listLayout(tabs, 8, true)
	local tabButtons: { [string]: TextButton } = {}

	local grid = scroller(right, UDim2.new(1, 0, 1, -236), UDim2.fromOffset(0, 56))
	grid.Name = "Commands"
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.fromOffset(170, 64)
	gridLayout.CellPadding = UDim2.fromOffset(10, 10)
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid
	local gridPad = Instance.new("UIPadding")
	gridPad.PaddingTop = UDim.new(0, 4)
	gridPad.PaddingLeft = UDim.new(0, 4)
	gridPad.Parent = grid

	-- The options for the picked command, and RUN.
	local form = UIKit.Card({
		Size = UDim2.new(1, 0, 0, 170),
		Position = UDim2.new(0, 0, 1, -170),
		Color = Colors.PanelDark,
		Parent = right,
	})
	form.Name = "Form"
	formTitle = UIKit.Label({
		Text = "",
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -200, 0, 30),
		Position = UDim2.fromOffset(16, 10),
		Parent = form,
	})
	local formDesc = UIKit.Label({
		Text = "",
		TextSize = 15,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Size = UDim2.new(1, -200, 0, 20),
		Position = UDim2.fromOffset(16, 40),
		Parent = form,
	})
	local inputsFrame = Instance.new("Frame")
	inputsFrame.Name = "Inputs"
	inputsFrame.BackgroundTransparency = 1
	inputsFrame.Size = UDim2.new(1, -200, 0, 96)
	inputsFrame.Position = UDim2.fromOffset(12, 66)
	inputsFrame.Parent = form
	listLayout(inputsFrame, 6)
	local runButton = UIKit.Button({
		Name = "Run",
		Text = "RUN",
		Icon = "▶",
		Color = Colors.Good,
		Size = UDim2.fromOffset(160, 64),
		Position = UDim2.new(1, -16, 0.5, 0),
		AnchorPoint = Vector2.new(1, 0.5),
		Parent = form,
	})

	-- Current values of the form's inputs, in order.
	local values: { string } = {}

	------------------------------------------------------------------ bottom: command line + feedback
	local bottom = Instance.new("Frame")
	bottom.Name = "Bottom"
	bottom.BackgroundTransparency = 1
	bottom.Size = UDim2.new(1, 0, 0, 52)
	bottom.Position = UDim2.new(0, 0, 1, -52)
	bottom.Parent = content
	local commandLine = field(bottom, UDim2.new(0.5, -6, 1, 0), UDim2.fromOffset(0, 0), "Type a command: :mute name reason   (Enter to run)")
	commandLine.Name = "CommandLine"
	local feedbackCard = UIKit.Card({ Size = UDim2.new(0.5, -6, 1, 0), Position = UDim2.new(0.5, 6, 0, 0), Color = Colors.PanelDark, Parent = bottom })
	local feedback = UIKit.Label({
		Name = "Feedback",
		Text = "Pick a player, then a command.",
		TextSize = 16,
		TextColor3 = Colors.TextDim,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, -20, 1, 0),
		Position = UDim2.fromOffset(10, 0),
		Parent = feedbackCard,
	})

	local function say(text: string, isError: boolean?)
		feedback.Text = text
		feedback.TextColor3 = if isError then Colors.Bad else Colors.Good
		if not window.Visible then
			UIKit.Toast(text, if isError then "Bad" else "Good")
		end
	end

	local function send(command: string, target: string, extra: string)
		if command == "spectate" or command == "controlplayer" then
			if target ~= "" and target:lower() ~= player.Name:lower() then
				coverFor(3)
			end
		end
		AdminCommand:FireServer(command, target, extra)
	end

	------------------------------------------------------------------ the form
	local function inputRow(): Frame
		local row = Instance.new("Frame")
		row.BackgroundTransparency = 1
		row.Size = UDim2.new(1, 0, 0, 42)
		row.LayoutOrder = #inputsFrame:GetChildren()
		row.Parent = inputsFrame
		return row
	end

	local function choiceRow(index: number, choices: { { Label: string, Value: string } }, default: string?)
		local row = inputRow()
		local strip = scroller(row, UDim2.fromScale(1, 1), UDim2.new(), true)
		strip.ScrollBarThickness = 4
		listLayout(strip, 6, true)
		local buttons: { [TextButton]: string } = {}
		local function paint()
			for b, v in buttons do
				b.BackgroundColor3 = if values[index] == v then Colors.Primary else Colors.PanelLight
			end
		end
		values[index] = default or ""
		if #choices == 0 then
			UIKit.Label({ Text = "Nothing to pick.", TextSize = 15, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 1, 0), Parent = strip })
		end
		for i, choice in choices do
			local b = Instance.new("TextButton")
			b.AutoButtonColor = true
			b.Size = UDim2.fromOffset(0, 36)
			b.AutomaticSize = Enum.AutomaticSize.X
			b.LayoutOrder = i
			b.BorderSizePixel = 0
			b.Font = Fonts.Body
			b.TextSize = 16
			b.TextColor3 = Colors.Text
			b.Text = "  " .. choice.Label .. "  "
			UIKit.Corner(b, 10)
			b.MouseButton1Click:Connect(function()
				values[index] = choice.Value
				paint()
			end)
			b.Parent = strip
			buttons[b] = choice.Value
		end
		paint()
	end

	refreshForm = function()
		clear(inputsFrame)
		table.clear(values)
		local cmd = selectedCommand
		if not cmd then
			formTitle.Text = "Pick a command"
			formDesc.Text = "Pick a player on the left, then a command above."
			runButton.Visible = false
			return
		end
		runButton.Visible = true
		local who = if cmd.Target == "player" then (if selectedPlayer then " → @" .. selectedPlayer.Name else " → pick a player") else ""
		formTitle.Text = cmd.Icon .. " " .. cmd.Label .. who
		formDesc.Text = cmd.Desc
		for i, input in cmd.Inputs or {} do
			if input.Kind == "choice" and input.Options then
				local choices = input.Options()
				choiceRow(i, choices, if input.Required then nil else (choices[1] and choices[1].Value))
			elseif input.Kind == "duration" then
				local list = {}
				for _, d in DURATIONS do
					table.insert(list, { Label = d, Value = d })
				end
				choiceRow(i, list, "24h")
			else
				local row = inputRow()
				local box = field(row, UDim2.fromScale(1, 1), UDim2.new(), input.Placeholder or "")
				if input.Kind == "number" then
					box.PlaceholderText = (input.Placeholder or "Number") .. " (numbers only)"
				end
				values[i] = ""
				box:GetPropertyChangedSignal("Text"):Connect(function()
					values[i] = box.Text
				end)
			end
		end
	end

	local function runSelected()
		local cmd = selectedCommand
		if not cmd then
			return
		end
		local target = ""
		local firstInput = 1
		if cmd.Target == "player" then
			if not selectedPlayer then
				say("Pick a player on the left first.", true)
				return
			end
			target = selectedPlayer.Name
		elseif cmd.Target == "text" then
			target = (values[1] or ""):match("^%s*(.-)%s*$") or ""
			firstInput = 2
			if target == "" then
				say("Type a name first.", true)
				return
			end
		end
		local parts = {}
		for i, input in cmd.Inputs or {} do
			if i < firstInput then
				continue
			end
			local v = ((values[i] or ""):match("^%s*(.-)%s*$")) or ""
			if input.Required and v == "" then
				say("Fill in: " .. (input.Placeholder or "pick an option"), true)
				return
			end
			if input.Kind == "number" and v ~= "" and not tonumber(v) then
				say((input.Placeholder or "That") .. " has to be a number.", true)
				return
			end
			if v ~= "" then
				table.insert(parts, v)
			end
		end
		send(cmd.Name, target, table.concat(parts, " "))
		say("Sent :" .. cmd.Name .. (if target ~= "" then " " .. target else ""), false)
		feedback.TextColor3 = Colors.TextDim
	end
	runButton.MouseButton1Click:Connect(runSelected)

	------------------------------------------------------------------ command grid
	local function drawGroup()
		clear(grid)
		for name, b in tabButtons do
			b.BackgroundColor3 = if name == selectedGroup then Colors.Primary else Colors.PanelLight
		end
		local order = 0
		for _, cmd in COMMANDS do
			if cmd.Group ~= selectedGroup or not allowed[cmd.Name] then
				continue
			end
			order += 1
			local cell = Instance.new("TextButton")
			cell.Name = "Cmd_" .. cmd.Name
			cell.AutoButtonColor = true
			cell.Text = ""
			cell.LayoutOrder = order
			cell.BorderSizePixel = 0
			cell.BackgroundColor3 = if selectedCommand == cmd then Colors.Primary elseif cmd.Danger then Color3.fromRGB(120, 40, 60) else Colors.PanelLight
			UIKit.Corner(cell, 12)
			UIKit.Stroke(cell, Colors.Ink, 2)
			UIKit.Label({ Text = cmd.Icon, TextSize = 26, Size = UDim2.fromOffset(40, 64), Position = UDim2.fromOffset(6, 0), Parent = cell })
			UIKit.Label({
				Text = cmd.Label,
				TextSize = 17,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, -52, 1, 0),
				Position = UDim2.fromOffset(48, 0),
				Parent = cell,
			})
			cell.MouseButton1Click:Connect(function()
				selectedCommand = cmd
				refreshForm()
				drawGroup()
				-- Nothing to fill in and no one to pick: just run it.
				if cmd.Target == "none" and not cmd.Inputs and not cmd.Danger then
					runSelected()
				end
			end)
			cell.Parent = grid
		end
		if order == 0 then
			UIKit.Label({ Text = "No commands here for your rank.", TextSize = 18, TextColor3 = Colors.TextDim, Size = UDim2.fromOffset(400, 40), Parent = grid })
		end
	end

	for i, group in GROUPS do
		local b = UIKit.Button({
			Name = group.Name,
			Text = group.Name,
			Icon = group.Icon,
			Color = Colors.PanelLight,
			Size = UDim2.fromOffset(134, 44),
			TextSize = 18,
			LayoutOrder = i,
			Parent = tabs,
			OnClick = function()
				selectedGroup = group.Name
				selectedCommand = nil
				refreshForm()
				drawGroup()
			end,
		})
		tabButtons[group.Name] = b
	end

	------------------------------------------------------------------ lists (ban / mute / warn / logs / inventory)
	local overlay = Instance.new("Frame")
	overlay.Name = "ListView"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = Colors.Panel
	overlay.BorderSizePixel = 0
	overlay.Visible = false
	overlay.ZIndex = 10
	overlay.Active = true
	overlay.Parent = content
	UIKit.Corner(overlay, 12)
	local overlayTitle = UIKit.Label({ Text = "", TextSize = 24, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -440, 0, 44), Position = UDim2.fromOffset(150, 4), Parent = overlay })
	UIKit.Button({
		Text = "Back",
		Icon = "◀",
		Color = Colors.PanelLight,
		Size = UDim2.fromOffset(130, 44),
		TextSize = 18,
		Position = UDim2.fromOffset(4, 4),
		Parent = overlay,
		OnClick = function()
			overlay.Visible = false
		end,
	})
	local listSearch = field(overlay, UDim2.fromOffset(270, 40), UDim2.new(1, -274, 0, 6), "🔍 Filter")
	-- ◀ ▶ to flip between pages of a list that has several (the Leaderboards view).
	local listNav: { Prev: () -> (), Next: () -> () }? = nil
	local navPrev = UIKit.Button({
		Text = "◀",
		Color = Colors.Primary,
		Size = UDim2.fromOffset(48, 40),
		TextSize = 20,
		Position = UDim2.new(1, -384, 0, 6),
		Parent = overlay,
		OnClick = function()
			if listNav then
				listNav.Prev()
			end
		end,
	})
	local navNext = UIKit.Button({
		Text = "▶",
		Color = Colors.Primary,
		Size = UDim2.fromOffset(48, 40),
		TextSize = 20,
		Position = UDim2.new(1, -330, 0, 6),
		Parent = overlay,
		OnClick = function()
			if listNav then
				listNav.Next()
			end
		end,
	})
	navPrev.Visible = false
	navNext.Visible = false
	-- An extra button in the list's header (the Pets view's "Add pet").
	local headerAction: (() -> ())? = nil
	local headerButton = UIKit.Button({
		Text = "",
		Color = Colors.Good,
		Size = UDim2.fromOffset(140, 40),
		TextSize = 18,
		Position = UDim2.new(1, -420, 0, 6),
		Parent = overlay,
		OnClick = function()
			if headerAction then
				headerAction()
			end
		end,
	})
	headerButton.Visible = false
	local listScroll = scroller(overlay, UDim2.new(1, -8, 1, -60), UDim2.fromOffset(4, 56))
	listLayout(listScroll, 6)

	local detail = Instance.new("Frame")
	detail.Name = "Detail"
	detail.Size = UDim2.fromScale(1, 1)
	detail.BackgroundColor3 = Colors.Panel
	detail.BorderSizePixel = 0
	detail.Visible = false
	detail.ZIndex = 20
	detail.Active = true
	detail.Parent = overlay
	UIKit.Corner(detail, 12)

	type Row = { Id: any, Line1: string?, Line2: string?, [string]: any }
	local currentRows: { Row } = {}
	local currentAction: string? = nil
	local currentOnAction: ((Row) -> ())? = nil
	-- An optional second button on each row (the All servers list: Join + Bring).
	local currentAction2: string? = nil
	local currentOnAction2: ((Row) -> ())? = nil

	local function drawRows()
		clear(listScroll)
		local filter = string.lower(listSearch.Text)
		local shown = 0
		for i, entry in currentRows do
			local line1 = tostring(entry.Line1 or "")
			local line2 = tostring(entry.Line2 or "")
			if filter ~= "" and not (line1:lower():find(filter, 1, true) or line2:lower():find(filter, 1, true)) then
				continue
			end
			shown += 1
			if shown > 300 then
				break
			end
			local row = UIKit.Card({ Size = UDim2.new(1, -10, 0, 64), Color = Colors.PanelLight, Parent = listScroll })
			row.LayoutOrder = i
			local textRoom = if currentAction2 then -310 else -170
			UIKit.Label({ Text = line1, TextSize = 18, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, textRoom, 0, 26), Position = UDim2.fromOffset(14, 6), Parent = row })
			UIKit.Label({ Text = line2, TextSize = 14, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.new(1, textRoom, 0, 22), Position = UDim2.fromOffset(14, 34), Parent = row })
			if currentAction2 and currentOnAction2 then
				local onAction2 = currentOnAction2
				UIKit.Button({
					Text = currentAction2,
					Color = Colors.Warning,
					Size = UDim2.fromOffset(130, 44),
					TextSize = 18,
					Position = UDim2.new(1, -152, 0.5, 0),
					AnchorPoint = Vector2.new(1, 0.5),
					Parent = row,
					OnClick = function()
						onAction2(entry)
					end,
				})
			end
			if currentAction and currentOnAction then
				local onAction = currentOnAction
				UIKit.Button({
					Text = currentAction,
					Color = if currentAction == "Remove" then Colors.Bad else Colors.Primary,
					Size = UDim2.fromOffset(130, 44),
					TextSize = 18,
					Position = UDim2.new(1, -12, 0.5, 0),
					AnchorPoint = Vector2.new(1, 0.5),
					Parent = row,
					OnClick = function()
						onAction(entry)
					end,
				})
			end
		end
		if shown == 0 then
			UIKit.Label({ Text = "Nothing here.", TextSize = 20, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 60), Parent = listScroll })
		end
	end
	listSearch:GetPropertyChangedSignal("Text"):Connect(drawRows)

	local function showList(title: string, rows: { Row }, action: string?, onAction: ((Row) -> ())?, nav: { Prev: () -> (), Next: () -> () }?, extra: { Text: string, OnClick: () -> () }?)
		listNav = nav
		navPrev.Visible = nav ~= nil
		navNext.Visible = nav ~= nil
		currentAction2 = nil
		currentOnAction2 = nil
		headerAction = if extra then extra.OnClick else nil
		headerButton.Visible = extra ~= nil
		if extra then
			headerButton.Text = extra.Text
		end
		overlayTitle.Size = if nav or extra then UDim2.new(1, -580, 0, 44) else UDim2.new(1, -440, 0, 44)
		overlayTitle.Text = title
		currentRows = if type(rows) == "table" then rows else {}
		currentAction = action
		currentOnAction = onAction
		detail.Visible = false
		overlay.Visible = true
		drawRows()
		if not window.Visible then
			UIKit.OpenWindow("Admin")
		end
	end

	local function detailPage(title: string): Frame
		clear(detail)
		detail.Visible = true
		UIKit.Button({
			Text = "Back",
			Icon = "◀",
			Color = Colors.PanelLight,
			Size = UDim2.fromOffset(130, 44),
			TextSize = 18,
			Position = UDim2.fromOffset(4, 4),
			Parent = detail,
			OnClick = function()
				detail.Visible = false
			end,
		})
		UIKit.Label({ Text = title, TextSize = 24, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -170, 0, 44), Position = UDim2.fromOffset(150, 4), Parent = detail })
		local body = Instance.new("Frame")
		body.BackgroundTransparency = 1
		body.Size = UDim2.new(1, -40, 1, -70)
		body.Position = UDim2.fromOffset(20, 64)
		body.Parent = detail
		return body
	end

	-- Ban / mute: change the reason or the length, or lift it.
	local function modifyPunishment(kind: string, entry: Row)
		local body = detailPage((if kind == "ban" then "🔨 Ban · " else "🔇 Mute · ") .. tostring(entry.Name or entry.Line1 or "?"))
		UIKit.Label({ Text = "REASON", TextSize = 16, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 22), Parent = body })
		local reason = field(body, UDim2.new(1, -160, 0, 46), UDim2.fromOffset(0, 26), "Reason")
		reason.Text = tostring(entry.Reason or "")
		UIKit.Button({
			Text = "Save",
			Color = Colors.Primary,
			Size = UDim2.fromOffset(140, 46),
			Position = UDim2.new(1, 0, 0, 26),
			AnchorPoint = Vector2.new(1, 0),
			Parent = body,
			OnClick = function()
				AdminModifyPunishment:FireServer(kind, entry.Id, "reason", reason.Text)
				detail.Visible = false
			end,
		})
		UIKit.Label({ Text = "LENGTH · now " .. tostring(entry.DurationText or "Permanent"), TextSize = 16, TextColor3 = Colors.TextDim, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 22), Position = UDim2.fromOffset(0, 92), Parent = body })
		local presetRow = Instance.new("Frame")
		presetRow.BackgroundTransparency = 1
		presetRow.Size = UDim2.new(1, 0, 0, 50)
		presetRow.Position = UDim2.fromOffset(0, 118)
		presetRow.Parent = body
		listLayout(presetRow, 8, true)
		for i, preset in PRESETS do
			UIKit.Button({
				Text = preset.Label,
				Color = Colors.PanelLight,
				Size = UDim2.fromOffset(150, 46),
				TextSize = 18,
				LayoutOrder = i,
				Parent = presetRow,
				OnClick = function()
					AdminModifyPunishment:FireServer(kind, entry.Id, "duration", preset.Seconds)
					detail.Visible = false
				end,
			})
		end
		UIKit.Button({
			Text = if kind == "ban" then "UNBAN" else "UNMUTE",
			Color = Colors.Bad,
			Size = UDim2.fromOffset(260, 60),
			Position = UDim2.new(0.5, 0, 0, 210),
			AnchorPoint = Vector2.new(0.5, 0),
			Parent = body,
			OnClick = function()
				AdminModifyPunishment:FireServer(kind, entry.Id, "remove")
				detail.Visible = false
			end,
		})
	end

	local function logDetail(entry: Row)
		local body = detailPage("📜 :" .. tostring(entry.Command or "?"))
		local lines = {
			"Admin: " .. tostring(entry.Admin or "?") .. (if entry.Tier then " (" .. tostring(entry.Tier) .. ")" else ""),
			"Target: " .. tostring(entry.Target or "-"),
			"Details: " .. tostring(entry.Extra or "-"),
			"When: " .. (if type(entry.Timestamp) == "number" then os.date("%Y-%m-%d %H:%M:%S", entry.Timestamp) else "?"),
			"",
			tostring(entry.Description or ""),
		}
		UIKit.Label({
			Text = table.concat(lines, "\n"),
			TextSize = 20,
			Font = Fonts.Body,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Size = UDim2.new(1, 0, 1, -80),
			Parent = body,
		})
		if canRemoveLogs then
			UIKit.Button({
				Text = "Remove from log",
				Color = Colors.Bad,
				Size = UDim2.fromOffset(240, 54),
				Position = UDim2.new(0.5, 0, 1, -6),
				AnchorPoint = Vector2.new(0.5, 1),
				Parent = body,
				OnClick = function()
					AdminRemoveLogEntry:FireServer(entry.Id)
					detail.Visible = false
				end,
			})
		end
	end

	AdminBanList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "Modify", function(entry)
			modifyPunishment("ban", entry)
		end)
	end)
	AdminMuteList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "Modify", function(entry)
			modifyPunishment("mute", entry)
		end)
	end)
	AdminWarnList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "View", function(entry)
			AdminViewWarnings:FireServer(entry.Id)
		end)
	end)
	local lastWarningsName = "?"
	AdminWarningsList.OnClientEvent:Connect(function(targetName, targetUserId, warnings)
		if targetName then
			lastWarningsName = tostring(targetName)
		end
		local rows = {}
		for i, w in warnings or {} do
			table.insert(rows, {
				Id = i,
				Line1 = "#" .. i .. ": " .. tostring(w.Reason),
				Line2 = "by " .. tostring(w.By) .. " · " .. os.date("%Y-%m-%d %H:%M", w.Timestamp or 0),
			})
		end
		showList("⚠️ Warnings · " .. lastWarningsName .. " (" .. #rows .. ")", rows, "Remove", function(entry)
			AdminRemoveWarning:FireServer(targetUserId, entry.Id)
		end)
	end)
	AdminInventoryList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "Remove", function(entry)
			AdminInventoryRemoveItem:FireServer(entry.Id)
		end)
	end)
	AdminLogsList.OnClientEvent:Connect(function(title, entries)
		showList(title, entries, "View", logDetail)
	end)

	-- Pets: every pet a player owns, Remove on each, "Add pet" to give one (pick pet + tier).
	local petTarget: number? = nil
	local function addPetPage()
		local body = detailPage("🐾 Add a pet")
		local tier = 1
		local tierRow = Instance.new("Frame")
		tierRow.BackgroundTransparency = 1
		tierRow.Size = UDim2.new(1, 0, 0, 48)
		tierRow.Parent = body
		listLayout(tierRow, 8, true)
		local tierButtons = {}
		local function paintTiers()
			for t, b in tierButtons do
				UIKit.SetButtonColor(b, if t == tier then Colors.Primary else Colors.PanelLight)
			end
		end
		for t, label in { "Normal", "Golden", "Rainbow" } do
			tierButtons[t] = UIKit.Button({
				Text = label,
				Color = Colors.PanelLight,
				Size = UDim2.fromOffset(150, 44),
				TextSize = 18,
				LayoutOrder = t,
				Parent = tierRow,
				OnClick = function()
					tier = t
					paintTiers()
				end,
			})
		end
		paintTiers()
		local list = scroller(body, UDim2.new(1, 0, 1, -60), UDim2.fromOffset(0, 58))
		local grid = Instance.new("UIGridLayout")
		grid.CellSize = UDim2.fromOffset(200, 50)
		grid.CellPadding = UDim2.fromOffset(8, 8)
		grid.SortOrder = Enum.SortOrder.LayoutOrder
		grid.Parent = list
		local ids = {}
		for id in Config.Pets do
			table.insert(ids, id)
		end
		table.sort(ids, function(a, b)
			return Config.Pets[a].Name < Config.Pets[b].Name
		end)
		for i, id in ids do
			UIKit.Button({
				Text = Config.Pets[id].Name,
				Color = Colors.Good,
				TextSize = 16,
				LayoutOrder = i,
				Parent = list,
				OnClick = function()
					if petTarget then
						AdminPetAction:FireServer("Add", petTarget, id, tier)
					end
				end,
			})
		end
	end
	-- All servers: one row per server (its players underneath) with a single Join (arrive invisible).
	AdminServerList.OnClientEvent:Connect(function(title, entries, busiestJobId)
		local extra = nil
		if type(busiestJobId) == "string" then
			extra = {
				Text = "Busiest server",
				OnClick = function()
					AdminServerAction:FireServer("Join", busiestJobId)
				end,
			}
		end
		showList(tostring(title), entries, "Join", function(entry)
			AdminServerAction:FireServer("Join", entry.JobId, entry.Id)
		end, nil, extra)
	end)

	AdminStaffList.OnClientEvent:Connect(function(title, entries)
		showList(tostring(title), entries, "Remove", function(entry)
			AdminStaffAction:FireServer("Remove", entry.Id)
		end)
	end)

	AdminPetList.OnClientEvent:Connect(function(targetUserId, title, entries)
		petTarget = tonumber(targetUserId)
		local keepDetail = detail.Visible
		showList(tostring(title), entries, "Remove", function(entry)
			if petTarget then
				AdminPetAction:FireServer("Remove", petTarget, entry.Id)
			end
		end, nil, { Text = "+ Add pet", OnClick = addPetPage })
		-- Adding several pets in a row: stay on the picker.
		if keepDetail then
			detail.Visible = true
		end
	end)

	-- Leaderboards: one board at a time, ◀ ▶ to flip, Reset on each row (with a confirm step).
	local boardIndex, boardCount = 1, 1
	-- Pages already seen show straight away (then refresh); a reply for a page you've already
	-- flipped past is ignored, so fast clicking never jumps back.
	local boardCache: { [number]: { Count: number, Title: string, Entries: { any } } } = {}
	local showBoard: (number, number, string, { any }) -> () = nil :: any
	local pendingBoard: number? = nil
	local function requestBoard(index: number)
		boardIndex = ((index - 1) % math.max(boardCount, 1)) + 1
		pendingBoard = boardIndex
		local cached = boardCache[boardIndex]
		if cached then
			showBoard(boardIndex, cached.Count, cached.Title, cached.Entries)
		end
		AdminLeaderboard:FireServer("View", boardIndex)
	end
	local function confirmReset(entry: Row)
		local body = detailPage("Reset " .. tostring(entry.Name))
		UIKit.Label({
			Text = string.format("Take %s off \"%s\"?\n\nThey keep all their real stats. Only this leaderboard starts again from zero for them.", tostring(entry.Name), tostring(entry.Board)),
			TextSize = 20,
			Font = Fonts.Body,
			TextWrapped = true,
			Size = UDim2.new(1, 0, 0, 120),
			Parent = body,
		})
		UIKit.Button({
			Text = "RESET",
			Color = Colors.Bad,
			Size = UDim2.fromOffset(260, 60),
			Position = UDim2.new(0.5, 0, 0, 150),
			AnchorPoint = Vector2.new(0.5, 0),
			Parent = body,
			OnClick = function()
				detail.Visible = false
				AdminLeaderboard:FireServer("Reset", boardIndex, entry.Id)
			end,
		})
	end
	showBoard = function(index: number, count: number, title: string, entries: { any })
		boardIndex = index
		boardCount = count
		local rows = {}
		for i, e in entries do
			table.insert(rows, {
				Id = e.UserId,
				Name = e.Name,
				Board = title,
				Line1 = string.format("#%d  %s", i, tostring(e.Name)),
				Line2 = tostring(e.Text) .. "  ·  UserId " .. tostring(e.UserId),
			})
		end
		showList(string.format("%s (%d/%d)", title, boardIndex, boardCount), rows, "Reset", confirmReset, {
			Prev = function()
				requestBoard(boardIndex - 1)
			end,
			Next = function()
				requestBoard(boardIndex + 1)
			end,
		})
	end
	AdminLeaderboard.OnClientEvent:Connect(function(index, count, title, entries)
		local i = tonumber(index) or 1
		local data = { Count = tonumber(count) or 1, Title = tostring(title), Entries = if type(entries) == "table" then entries else {} }
		boardCache[i] = data
		boardCount = data.Count
		-- A slow reply for a page you've already flipped past is only cached, not drawn.
		if pendingBoard == nil or i == pendingBoard then
			pendingBoard = nil
			showBoard(i, data.Count, data.Title, data.Entries)
		end
	end)

	AdminFeedback.OnClientEvent:Connect(function(text, isError)
		say(tostring(text), isError == true)
		if isError then
			revealScreen()
		end
	end)

	------------------------------------------------------------------ command line
	commandLine.FocusLost:Connect(function(enterPressed)
		if not enterPressed then
			return
		end
		local text = commandLine.Text
		commandLine.Text = ""
		local command, after = text:match("^%s*:?(%S*)%s*(.*)$")
		command = string.lower(command or "")
		if command == "" then
			return
		end
		local target, rest = (after or ""):match("^(%S*)%s*(.*)$")
		for _, cmd in COMMANDS do
			if cmd.Name == command and cmd.Target == "none" then
				-- These take no name: everything after the command is the text.
				rest = ((target or "") .. " " .. (rest or "")):match("^%s*(.-)%s*$")
				target = ""
				break
			end
		end
		send(command, target or "", rest or "")
		feedback.Text = "Sent :" .. command
		feedback.TextColor3 = Colors.TextDim
	end)

	------------------------------------------------------------------ window
	UIKit.RegisterWindow("Admin", {
		Open = function()
			refreshPlayers()
			refreshForm()
			drawGroup()
		end,
	})
	Players.PlayerAdded:Connect(function()
		if window.Visible then
			refreshPlayers()
		end
	end)
	Players.PlayerRemoving:Connect(function(plr)
		if plr == selectedPlayer then
			selectedPlayer = nil
		end
		task.defer(function()
			if window.Visible then
				refreshPlayers()
				refreshForm()
			end
		end)
	end)

end

------------------------------------------------------------------ spectate / control bars (sent only to admins)
local actionBar = UIKit.Card({
	Size = UDim2.fromOffset(520, 70),
	Position = UDim2.new(0.5, 0, 1, -130),
	AnchorPoint = Vector2.new(0.5, 1),
	Color = Colors.Panel,
	Parent = statusRoot,
})
actionBar.Name = "AdminActionBar"
actionBar.Visible = false
UIKit.Stroke(actionBar, Colors.Primary, 3)
local actionLabel = UIKit.Label({ Text = "", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -170, 1, 0), Position = UDim2.fromOffset(18, 0), Parent = actionBar })
local actionStop: (() -> ())? = nil
UIKit.Button({
	Text = "Stop",
	Icon = "⏹",
	Color = Colors.Bad,
	Size = UDim2.fromOffset(140, 50),
	Position = UDim2.new(1, -12, 0.5, 0),
	AnchorPoint = Vector2.new(1, 0.5),
	Parent = actionBar,
	OnClick = function()
		if actionStop then
			actionStop()
		end
	end,
})

local function cameraToSelf()
	local camera = workspace.CurrentCamera
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

AdminSpectate.OnClientEvent:Connect(function(target: Player?)
	if not target then
		actionBar.Visible = false
		cameraToSelf()
		revealScreen()
		return
	end
	local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	local camera = workspace.CurrentCamera
	if humanoid and camera then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end
	actionLabel.Text = "👁️ Spectating @" .. target.Name
	actionStop = function()
		coverFor(1.5) -- hides the teleport back to where you were
		actionBar.Visible = false
		cameraToSelf()
		AdminStopSpectating:FireServer()
	end
	actionBar.Visible = true
	revealScreen()
end)

local controlConn: RBXScriptConnection? = nil
local jumpQueued = false
UserInputService.JumpRequest:Connect(function()
	jumpQueued = true
end)
AdminControlPlayer.OnClientEvent:Connect(function(target: Player?)
	if controlConn then
		controlConn:Disconnect()
		controlConn = nil
	end
	if not target then
		actionBar.Visible = false
		cameraToSelf()
		revealScreen()
		return
	end
	local humanoid = target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	local camera = workspace.CurrentCamera
	if humanoid and camera then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end
	actionLabel.Text = "🎮 Controlling @" .. target.Name
	actionStop = function()
		coverFor(1.5) -- hides the teleport back to where you were
		if controlConn then
			controlConn:Disconnect()
			controlConn = nil
		end
		actionBar.Visible = false
		cameraToSelf()
		AdminStopControlling:FireServer()
	end
	actionBar.Visible = true
	revealScreen()
	controlConn = RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local mv = moveVector()
		local look = cam.CFrame.LookVector
		local flatLook = Vector3.new(look.X, 0, look.Z)
		flatLook = if flatLook.Magnitude > 1e-3 then flatLook.Unit else Vector3.new(0, 0, -1)
		local rightV = cam.CFrame.RightVector
		local flatRight = Vector3.new(rightV.X, 0, rightV.Z)
		flatRight = if flatRight.Magnitude > 1e-3 then flatRight.Unit else Vector3.new(1, 0, 0)
		local dir = flatRight * mv.X - flatLook * mv.Z
		if dir.Magnitude > 1 then
			dir = dir.Unit
		end
		local jump = jumpQueued or (UserInputService:GetFocusedTextBox() == nil and UserInputService:IsKeyDown(Enum.KeyCode.Space))
		jumpQueued = false
		AdminControlMove:FireServer(dir, jump)
	end)
end)

----------------------------------------------------------------------------------------------------
-- Start: ask the server who we are. The owner and staff get a tier (and so a panel); a rank given or
-- taken away later arrives through AdminInfoChanged.
----------------------------------------------------------------------------------------------------
local ok, info = pcall(function()
	return GetAdminInfo:InvokeServer()
end)
if ok then
	buildPanel(info)
end
task.spawn(function()
	local changed = ReplicatedStorage:WaitForChild("AdminInfoChanged", 30)
	if changed then
		(changed :: any).OnClientEvent:Connect(buildPanel)
	end
end)
