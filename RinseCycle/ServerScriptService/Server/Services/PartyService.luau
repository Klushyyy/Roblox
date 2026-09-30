-- Party pads: walk-in matchmaking in the lobby. One party per pad, fully server-authoritative.
--
--   * A poll loop (Config.Party.PollInterval) tests every free player's HumanoidRootPart against each
--     pad's Zone box, in the Zone's own space so rotated pads work.
--   * Walking into an empty pad makes you host of a new party. Walking into a pad that has a party
--     joins it, unless it is full, about to launch, or Friends Only and you aren't the host's friend.
--     Then you're pushed out the front with a toast and can't re-enter for RejoinCooldown seconds.
--   * Members go into the "PartyMember" collision group (the pad's barrier walls block only that
--     group) and stand on a 2x2 grid inside the pad. A member found outside the pad is put back.
--   * The countdown is one timestamp (EndsAt, server time) set when the party is created. Clients
--     draw the timer from it; the server only rewrites the pad billboard every 0.25 s.
--   * At EndsAt (or Start Now) the party launches: RoundService.StartRound builds a dishwasher and
--     takes the players. If no dishwasher is free the countdown is pushed back and it tries again.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))
local Types = require(Shared:WaitForChild("Types"))
local Util = require(Shared:WaitForChild("Util"))

local Characters = require(script.Parent:WaitForChild("Characters"))
local DataService = require(script.Parent:WaitForChild("DataService"))
local LobbyBuilder = require(script.Parent:WaitForChild("LobbyBuilder"))
local RoundService = require(script.Parent:WaitForChild("RoundService"))
local RunServers = require(script.Parent:WaitForChild("RunServers"))

local PartyService = {}

----------------------------------------------------------------------------------------------------
-- Tuning (the gameplay numbers live in Config.Party)
----------------------------------------------------------------------------------------------------
local PARTY = Config.Party
local MAX_PLAYERS = PARTY.MaxPlayers
local LABEL_INTERVAL = 0.25 -- how often pad billboards are rewritten (the countdown text)
local RETRY_DELAY = 10 -- seconds added to the countdown when every dishwasher is busy

-- Seconds from Create to launch: a solo party (max 1) clearly just wants to play; a bigger one waits
-- long enough for people to wander over and join.
local function countdownFor(maxPlayers: number): number
	return if maxPlayers <= 1 then PARTY.SoloCountdown else PARTY.Countdown
end
local PICK_SECONDS = 60 -- a host who hasn't pressed Create by then is walked out of the pad
local ACTIONS_PER_SECOND = 5 -- PartyAction rate limit per player
local FRIEND_CACHE_TTL = 300 -- seconds a friends answer is trusted
local FRIEND_FAIL_TTL = 5 -- a failed friends lookup counts as "no" for this long, then it retries
local PUT_BACK_COOLDOWN = 0.75 -- min seconds between "you escaped the pad" teleports per member
-- Members are held to a looser box than the entry check, so hugging a wall or jumping never counts
-- as escaping (and a slightly-off LobbyBuilder Zone can't cause a teleport loop).
local HOLD_MARGIN_XZ = 1.5
local HOLD_MARGIN_BELOW = 3
local HOLD_MARGIN_ABOVE = 12

local FLOOR_COLORS = {
	Idle = Color3.fromRGB(125, 195, 255), -- soft blue: walk in to start a party
	Open = Color3.fromRGB(70, 225, 145), -- green: public party with room
	Friends = Color3.fromRGB(180, 125, 255), -- purple: friends only
	Full = Color3.fromRGB(255, 165, 60), -- orange: full, or launching
}
local PRIVACY_TEXT = {
	Public = "Public",
	Friends = "Friends Only",
}
local IDLE_TITLE = "Party Pad"
local IDLE_STATUS = "Touch to create a party"
local LAUNCH_STATUS = "Launching!"

local FLOOR_TWEEN = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PULSE_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

----------------------------------------------------------------------------------------------------
-- Types
----------------------------------------------------------------------------------------------------
type PadGui = { Count: TextLabel?, Title: TextLabel?, Status: TextLabel?, Privacy: TextLabel? }

-- LobbyBuilder's PadInfo (DESIGN.md §5). Read-only here, except the Floor colour.
type PadInfo = {
	Id: number,
	Model: Model,
	Zone: BasePart,
	Floor: BasePart?,
	Inside: CFrame,
	Exit: CFrame,
	Barriers: { BasePart }?,
	Gui: PadGui?,
}

type Privacy = "Public" | "Friends"
-- Picking: the host is choosing a dishwasher and party size; nobody else can join yet.
-- Waiting: created, counting down, open to joiners. Launching: handed to RoundService.
type Status = "Picking" | "Waiting" | "Launching"

type Party = {
	PadId: number,
	Pad: Pad,
	Host: Player,
	Members: { Player }, -- join order; Members[1] is next in line to be host
	MaxPlayers: number,
	Privacy: Privacy,
	Level: number,
	LevelChosen: boolean, -- the host picked a level, so don't overwrite it when their profile loads
	EndsAt: number, -- server time (Util.Now) when the countdown hits 0 (Picking: when it's cancelled)
	Status: Status,
	Slots: { [Player]: number }, -- standing spot per member (see slotCFrame)
	Dead: boolean, -- dissolved or launched: anything still holding this table must stop using it
	FlushQueued: boolean, -- a PartyState push is already scheduled for this frame
}

type Pad = {
	Info: PadInfo,
	Party: Party?,
	FloorColor: Color3?, -- colour the floor is tweening towards
	Sounds: { [string]: Sound },
}

-- How a member is let go:
--   "Exit" : teleport out the front of the pad and start the rejoin cooldown (left or removed)
--   "Stay" : leave the character where it is (died, launched into a run, or already in a run)
--   "Gone" : they left the game, so touch nothing on the Player
type ReleaseMode = "Exit" | "Stay" | "Gone"

----------------------------------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------------------------------
local pads: { Pad } = {}
local padsLoaded = false
local memberOf: { [Player]: Party } = {}
local memberConns: { [Player]: { RBXScriptConnection } } = {}
local pendingJoin: { [Player]: boolean } = {} -- friends check in flight: the poll skips them
local launching: { [Player]: boolean } = {} -- handed to StartRound, which hasn't returned yet
local cooldownUntil: { [Player]: number } = {} -- os.clock() before which they can't enter a pad
-- Just sent out of a pad (Back, ejected, cancelled): that pad is ignored for them until the poll
-- sees them outside it once. No timer, so walking straight back in starts a new party at once, but
-- a character still reporting its old spot right after the teleport can't re-trigger it.
local mustLeave: { [Player]: { Pad: any, Since: number } } = {}
local MUST_LEAVE_MAX = 4 -- seconds: if the teleport out somehow never lands, stop waiting
-- The character's own late position updates can put it back in the pad for a moment right after the
-- teleport out, so "outside" only counts once this long has passed.
local MUST_LEAVE_SETTLE = 0.6
local lastPutBack: { [Player]: number } = {}
local actionWindow: { [Player]: { Start: number, Count: number } } = {}
-- friendCache[candidate][hostUserId] = the answer to candidate:IsFriendsWithAsync(hostUserId)
local friendCache: { [Player]: { [number]: { Value: boolean, Expires: number } } } = {}

local partyStateRemote: RemoteEvent
local notifyRemote: RemoteEvent

local lastWarnAt = -math.huge

----------------------------------------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------------------------------------

-- At most one warning every 10 s, so a bug inside the poll loop can't flood the output.
local function warnThrottled(message: string)
	local now = os.clock()
	if now - lastWarnAt >= 10 then
		lastWarnAt = now
		warn("[PartyService] " .. message)
	end
end

local function notify(player: Player, text: string, kind: string?)
	if player.Parent == Players then
		notifyRemote:FireClient(player, text, kind or "Info")
	end
end

local function isInRun(player: Player): boolean
	return RoundService.IsInRun(player) == true
end

-- Highest level this player may pick (1 while their profile is still loading).
local function unlockedOf(player: Player): number
	local ok, profile = pcall(DataService.Get, player)
	local unlocked = ok and profile and (profile :: any).Unlocked
	if type(unlocked) ~= "number" or unlocked ~= unlocked then
		return 1
	end
	return math.clamp(math.floor(unlocked), 1, #Config.Levels)
end

local function isInteger(value: any): boolean
	return type(value) == "number" and value == value and value == math.floor(value)
end

-- True if this request fits in the player's PartyAction budget (ACTIONS_PER_SECOND per 1 s window).
local function allowAction(player: Player): boolean
	local now = os.clock()
	local window = actionWindow[player]
	if not window or now - window.Start >= 1 then
		window = { Start = now, Count = 0 }
		actionWindow[player] = window
	end
	window.Count += 1
	return window.Count <= ACTIONS_PER_SECOND
end

-- Characters.Teleport may yield (streaming requests), so it never runs on the poll loop's thread.
local function teleport(player: Player, cframe: CFrame)
	task.spawn(function()
		pcall(Characters.Teleport, player, cframe)
	end)
end

----------------------------------------------------------------------------------------------------
-- Pad geometry
----------------------------------------------------------------------------------------------------

-- `position` in the Zone's own space (so rotated pads work), and the Zone's half size.
local function toZoneSpace(zone: BasePart, position: Vector3): (Vector3, Vector3)
	return zone.CFrame:PointToObjectSpace(position), zone.Size / 2
end

-- Strict point-in-box: is a free player standing in this pad?
local function isInsideZone(zone: BasePart, position: Vector3): boolean
	local p, half = toZoneSpace(zone, position)
	return math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z
end

-- Loose point-in-box: is a member still (near enough) inside their pad?
local function isHeldInZone(zone: BasePart, position: Vector3): boolean
	local p, half = toZoneSpace(zone, position)
	return math.abs(p.X) <= half.X + HOLD_MARGIN_XZ
		and math.abs(p.Z) <= half.Z + HOLD_MARGIN_XZ
		and p.Y >= -half.Y - HOLD_MARGIN_BELOW
		and p.Y <= half.Y + HOLD_MARGIN_ABOVE
end

-- Where member slot `slot` stands: a 2x2 grid around the pad centre (a bigger MaxPlayers would
-- simply fill more grid cells). Spacing scales with the pad so nobody is placed inside a wall.
local function slotCFrame(pad: Pad, slot: number): CFrame
	local info = pad.Info
	local cols = math.max(2, math.ceil(math.sqrt(MAX_PLAYERS)))
	local rows = math.max(1, math.ceil(MAX_PLAYERS / cols))
	local size = info.Zone.Size
	local spacing = math.clamp(math.min(size.X, size.Z) / (cols + 1.5), 1.5, 3.5)
	local index = math.max(slot, 1) - 1
	local col = index % cols
	local row = (index // cols) % rows
	local dx = (col - (cols - 1) / 2) * spacing
	local dz = (row - (rows - 1) / 2) * spacing
	return info.Inside * CFrame.new(dx, 0, dz)
end

local function freeSlot(party: Party): number
	local used = {}
	for _, slot in party.Slots do
		used[slot] = true
	end
	local slot = 1
	while used[slot] do
		slot += 1
	end
	return slot
end

----------------------------------------------------------------------------------------------------
-- Pad visuals (billboard text, floor colour, sounds)
----------------------------------------------------------------------------------------------------

local function setText(label: TextLabel?, text: string)
	-- Only write real changes: identical writes are free, but this runs 4x a second per pad.
	if label and label.Parent and label.Text ~= text then
		label.Text = text
	end
end

local function floorColorFor(party: Party?): Color3
	if not party then
		return FLOOR_COLORS.Idle
	end
	if party.Status ~= "Waiting" or #party.Members >= party.MaxPlayers then
		return FLOOR_COLORS.Full
	end
	if party.Privacy == "Friends" then
		return FLOOR_COLORS.Friends
	end
	return FLOOR_COLORS.Open
end

local function statusText(party: Party?, now: number): string
	if not party then
		return IDLE_STATUS
	end
	if party.Status == "Launching" then
		return LAUNCH_STATUS
	end
	if party.Status == "Picking" then
		return party.Host.DisplayName .. " is picking a level..."
	end
	local left = math.ceil(party.EndsAt - now)
	if left <= 0 then
		return LAUNCH_STATUS
	end
	return "Starting in " .. left
end

-- Tweens the floor (and any light parented to it) to `color`. `pulse` flashes it bright first,
-- which reads as "someone just joined".
local function tweenFloor(pad: Pad, color: Color3, pulse: boolean?)
	local floor = pad.Info.Floor
	if not floor or not floor.Parent then
		return
	end
	if not pulse and pad.FloorColor == color then
		return
	end
	pad.FloorColor = color
	local info = FLOOR_TWEEN
	if pulse then
		floor.Color = color:Lerp(Color3.new(1, 1, 1), 0.6)
		info = PULSE_TWEEN
	end
	TweenService:Create(floor, info, { Color = color }):Play()
	for _, child in floor:GetChildren() do
		if child:IsA("Light") then
			TweenService:Create(child, info, { Color = color }):Play()
		end
	end
end

-- A positional sound at the pad (a Sound in the workspace plays for everyone nearby).
local function playPadSound(pad: Pad, key: string)
	local def = (Config.Sounds :: any)[key]
	local floor = pad.Info.Floor
	if not def or not floor or not floor.Parent then
		return
	end
	local sound = pad.Sounds[key]
	if not sound or sound.Parent ~= floor then
		sound = Instance.new("Sound")
		sound.Name = "Party" .. key
		sound.SoundId = def.Id
		sound.Volume = def.Volume
		sound.RollOffMode = Enum.RollOffMode.InverseTapered
		sound.RollOffMinDistance = 10
		sound.RollOffMaxDistance = 90
		sound.Parent = floor
		pad.Sounds[key] = sound
	end
	sound:Play()
end

local function refreshPad(pad: Pad, pulse: boolean?)
	local party = pad.Party
	local gui = pad.Info.Gui
	if gui then
		if party then
			local level = Config.GetLevel(party.Level)
			setText(gui.Count, #party.Members .. "/" .. party.MaxPlayers)
			setText(gui.Title, level.Name)
			setText(gui.Privacy, PRIVACY_TEXT[party.Privacy])
		else
			setText(gui.Count, "0/" .. MAX_PLAYERS)
			setText(gui.Title, IDLE_TITLE)
			setText(gui.Privacy, PRIVACY_TEXT.Public)
		end
		setText(gui.Status, statusText(party, Util.Now()))
	end
	tweenFloor(pad, floorColorFor(party), pulse)
end

----------------------------------------------------------------------------------------------------
-- PartyState pushes
----------------------------------------------------------------------------------------------------

local function buildState(party: Party): Types.PartyState
	local members: { Types.PartyMember } = {}
	for _, member in party.Members do
		table.insert(members, { UserId = member.UserId, Name = member.Name, DisplayName = member.DisplayName })
	end
	return {
		PadId = party.PadId,
		HostUserId = party.Host.UserId,
		IsHost = false,
		Members = members,
		MaxPlayers = party.MaxPlayers,
		Privacy = party.Privacy,
		Level = party.Level,
		HostUnlocked = unlockedOf(party.Host),
		EndsAt = party.EndsAt,
		Status = party.Status,
	}
end

-- Sends every member their own copy (IsHost differs per recipient).
local function pushNow(party: Party)
	if party.Dead or #party.Members == 0 then
		return
	end
	local base = buildState(party)
	for _, member in party.Members do
		if member.Parent == Players then
			local state: Types.PartyState = table.clone(base)
			state.IsHost = member == party.Host
			partyStateRemote:FireClient(member, state)
		end
	end
end

-- Coalesces every change made to a party in the same frame into one push per member.
-- (A member who is removed gets PartyState(nil) immediately, not through here.)
local function markDirty(party: Party)
	if party.Dead or party.FlushQueued then
		return
	end
	party.FlushQueued = true
	task.defer(function()
		party.FlushQueued = false
		pushNow(party)
	end)
end

----------------------------------------------------------------------------------------------------
-- Membership
----------------------------------------------------------------------------------------------------

local function unhookMember(player: Player)
	local conns = memberConns[player]
	if conns then
		for _, conn in conns do
			conn:Disconnect()
		end
		memberConns[player] = nil
	end
end

-- Back to the normal "Players" group so the pad walls stop blocking them. RoundService already does
-- this for launched players; it's only redone if the character is still in PartyMember (or has no
-- root right now, e.g. dead, so the next character spawns in the right group).
local function releaseGroup(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and root.CollisionGroup ~= Characters.Groups.PartyMember then
		return
	end
	Characters.SetGroup(player, Characters.Groups.Players)
end

-- Forgets a member's per-player bookkeeping. Does not touch party.Members (callers do).
local function releaseMember(party: Party, player: Player, mode: ReleaseMode)
	memberOf[player] = nil
	party.Slots[player] = nil
	lastPutBack[player] = nil
	unhookMember(player)
	if mode == "Gone" or player.Parent ~= Players then
		return
	end
	player:SetAttribute("InParty", false)
	releaseGroup(player)
	if mode == "Exit" then
		mustLeave[player] = { Pad = party.Pad, Since = os.clock() }
		if not isInRun(player) then
			teleport(player, party.Pad.Info.Exit)
		end
	end
	partyStateRemote:FireClient(player, nil)
end

local function dissolve(party: Party)
	party.Dead = true
	local pad = party.Pad
	if pad.Party == party then
		pad.Party = nil
	end
	refreshPad(pad)
end

-- The longest-waiting member becomes host. They may not have unlocked the level the old host
-- picked, so the level is clamped to what they can play.
local function promoteHost(party: Party)
	local newHost = party.Members[1]
	if not newHost then
		return
	end
	party.Host = newHost
	party.Level = math.clamp(party.Level, 1, unlockedOf(newHost))
	notify(newHost, "You're the party host now!", "Good")
end

local function removeMember(player: Player, mode: ReleaseMode, message: string?)
	local party = memberOf[player]
	if not party then
		return
	end
	local index = table.find(party.Members, player)
	if index then
		table.remove(party.Members, index)
	end
	releaseMember(party, player, mode)
	if message then
		notify(player, message, "Info")
	end

	if #party.Members == 0 then
		dissolve(party)
		return
	end
	if party.Host == player then
		promoteHost(party)
	end
	markDirty(party)
	refreshPad(party.Pad)
end

-- Death (Humanoid.Died) or losing the character (CharacterRemoving, e.g. a respawn) ends membership.
-- They respawn in the lobby as normal.
local function hookMember(player: Player)
	unhookMember(player)
	local function onLost()
		if memberOf[player] then
			removeMember(player, "Stay", "You left the party.")
		end
	end
	local conns = {}
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		table.insert(conns, humanoid.Died:Connect(onLost))
	end
	table.insert(conns, player.CharacterRemoving:Connect(onLost))
	memberConns[player] = conns
end

local function joinParty(party: Party, player: Player)
	local pad = party.Pad
	table.insert(party.Members, player)
	memberOf[player] = party
	local slot = freeSlot(party)
	party.Slots[player] = slot
	cooldownUntil[player] = nil
	mustLeave[player] = nil
	lastPutBack[player] = os.clock()

	Characters.SetGroup(player, Characters.Groups.PartyMember)
	player:SetAttribute("InParty", true)
	hookMember(player)
	teleport(player, slotCFrame(pad, slot))

	markDirty(party)
	refreshPad(pad, true)
	playPadSound(pad, "Pop")
end

local function createParty(pad: Pad, host: Player)
	local party: Party = {
		PadId = pad.Info.Id,
		Pad = pad,
		Host = host,
		Members = {},
		MaxPlayers = MAX_PLAYERS,
		Privacy = "Public",
		Level = unlockedOf(host), -- default to their best dishwasher
		LevelChosen = false,
		EndsAt = Util.Now() + PICK_SECONDS, -- replaced by the real countdown when they press Create
		Status = "Picking",
		Slots = {},
		Dead = false,
		FlushQueued = false,
	}
	pad.Party = party
	joinParty(party, host)
end

----------------------------------------------------------------------------------------------------
-- Walking into a pad
----------------------------------------------------------------------------------------------------

-- Joins and leaves are refused this close to launch (and while launching).
local function inLockWindow(party: Party): boolean
	if party.Status == "Picking" then
		return false
	end
	return party.Status ~= "Waiting" or Util.Now() >= party.EndsAt - PARTY.LockSeconds
end

-- Pushes a free player out the front of a pad they may not join.
local function eject(player: Player, pad: Pad, message: string)
	mustLeave[player] = { Pad = pad, Since = os.clock() }
	teleport(player, pad.Info.Exit)
	notify(player, message, "Bad")
end

local function cachedFriendship(candidate: Player, host: Player): boolean?
	local byHost = friendCache[candidate]
	local entry = byHost and byHost[host.UserId]
	if entry and os.clock() < entry.Expires then
		return entry.Value
	end
	return nil
end

local function storeFriendship(candidate: Player, hostUserId: number, value: boolean, ttl: number)
	local byHost = friendCache[candidate]
	if not byHost then
		byHost = {}
		friendCache[candidate] = byHost
	end
	byHost[hostUserId] = { Value = value, Expires = os.clock() + ttl }
end

-- A player the poll loop should look at: not busy with a party, run or pending check, and not on
-- the rejoin cooldown.
local function canEnterPads(player: Player, clock: number): boolean
	if player.Parent ~= Players or memberOf[player] or pendingJoin[player] or launching[player] then
		return false
	end
	-- On their way to a run server (still standing on the pad, frozen, screen black): hands off.
	if player:GetAttribute("Teleporting") == true then
		return false
	end
	local cooldown = cooldownUntil[player]
	if cooldown then
		if clock < cooldown then
			return false
		end
		cooldownUntil[player] = nil
	end
	return not isInRun(player)
end

local admit: (player: Player, pad: Pad) -> ()

-- Asks Roblox whether `player` is friends with the host, then runs admit() again. Everything is
-- re-checked after the yield: the party may have filled up, started launching, changed host or
-- privacy, or the player may have walked off or left.
local function startFriendCheck(player: Player, pad: Pad, party: Party)
	local host = party.Host
	pendingJoin[player] = true
	task.spawn(function()
		local ok, result = false, nil
		if player.Parent == Players and host.Parent == Players then
			ok, result = pcall(player.IsFriendsWithAsync, player, host.UserId)
		end
		pendingJoin[player] = nil
		if player.Parent ~= Players then
			return
		end
		if ok then
			storeFriendship(player, host.UserId, result == true, FRIEND_CACHE_TTL)
		else
			-- The web call failed: count it as "no" briefly so they get a clear answer, then retry.
			storeFriendship(player, host.UserId, false, FRIEND_FAIL_TTL)
		end

		-- Same party, same host, player still free and standing in the pad? Otherwise the next poll
		-- simply starts over with whatever is true now.
		if party.Dead or pad.Party ~= party or party.Host ~= host then
			return
		end
		if not canEnterPads(player, os.clock()) then
			return
		end
		local root = Characters.GetRoot(player)
		if not root or not isInsideZone(pad.Info.Zone, root.Position) then
			return
		end
		admit(player, pad) -- the answer is cached now, so this doesn't yield again
	end)
end

-- Decides what happens to a free player standing in `pad`.
function admit(player: Player, pad: Pad)
	local party = pad.Party
	if not party then
		createParty(pad, player)
		return
	end
	if party.Status == "Picking" then
		eject(player, pad, party.Host.DisplayName .. " is picking a level. Try another pad!")
		return
	end
	if inLockWindow(party) then
		eject(player, pad, "That party is launching! Try another pad.")
		return
	end
	if #party.Members >= party.MaxPlayers then
		eject(player, pad, "This party is full!")
		return
	end
	if party.Privacy == "Friends" then
		local isFriend = cachedFriendship(player, party.Host)
		if isFriend == nil then
			startFriendCheck(player, pad, party)
			return
		elseif not isFriend then
			eject(player, pad, "Friends only!")
			return
		end
	end
	joinParty(party, player)
end

----------------------------------------------------------------------------------------------------
-- Launch
----------------------------------------------------------------------------------------------------

local function launch(party: Party)
	local pad = party.Pad
	party.Status = "Launching"

	-- Only take members who can actually play right now; drop the rest.
	local roster: { Player } = {}
	for _, member in table.clone(party.Members) do
		if member.Parent ~= Players then
			removeMember(member, "Gone")
		elseif isInRun(member) then
			removeMember(member, "Stay")
		elseif not Characters.IsAlive(member) then
			removeMember(member, "Stay", "You left the party.")
		else
			table.insert(roster, member)
		end
	end
	if party.Dead or #roster == 0 then
		return -- removeMember dissolved it
	end

	for _, member in roster do
		launching[member] = true
	end
	markDirty(party)
	refreshPad(pad)
	playPadSound(pad, "Splash")

	local level = party.Level
	task.spawn(function()
		-- Give every member's screen time to fade to black (Cutscene.Cover on "Launching") before
		-- anyone is moved, so the teleport into the dishwasher is never seen.
		task.wait(0.25)
		-- In the live game the party plays in its own private server; otherwise (Studio, or the
		-- teleport can't start) StartRound builds the dishwasher here. It yields while it builds.
		-- Pass a copy: it's RoundService's now.
		local ok, started, err
		-- Anyone whose teleport fails later is unfrozen by RunServers and walked out of the pad here.
		local teleported = RunServers.Launch(table.clone(roster), level, function(member: Player)
			if member.Parent == Players and not memberOf[member] then
				mustLeave[member] = { Pad = pad, Since = os.clock() }
				teleport(member, pad.Info.Exit)
			end
		end)
		if teleported then
			ok, started = true, true
		else
			ok, started, err = pcall(RoundService.StartRound, table.clone(roster), level)
		end
		for _, member in roster do
			launching[member] = nil
		end
		if not ok then
			warn("[PartyService] StartRound errored: " .. tostring(started))
		end
		if party.Dead then
			return -- everyone left or died while the dishwasher was being built
		end

		if ok and started == true then
			-- RoundService has already moved everyone into the dishwasher (and sent RunState), so just
			-- let go of them here without teleporting. Anyone it didn't take is walked out of the pad.
			party.Dead = true
			for _, member in party.Members do
				releaseMember(party, member, if teleported or isInRun(member) then "Stay" else "Exit")
			end
			table.clear(party.Members)
			if pad.Party == party then
				pad.Party = nil
			end
			refreshPad(pad)
		else
			if ok and err then
				warn("[PartyService] StartRound refused pad " .. party.PadId .. ": " .. tostring(err))
			end
			party.Status = "Waiting"
			party.EndsAt = math.max(party.EndsAt, Util.Now()) + RETRY_DELAY
			for _, member in party.Members do
				notify(member, "All dishwashers are busy, trying again...", "Bad")
			end
			markDirty(party)
			refreshPad(pad)
		end
	end)
end

----------------------------------------------------------------------------------------------------
-- Poll loop
----------------------------------------------------------------------------------------------------

-- Keeps one member honest: still here, not in a run, alive, and inside their pad.
local function validateMember(party: Party, player: Player, clock: number)
	if memberOf[player] ~= party then
		return
	end
	if player.Parent ~= Players then
		removeMember(player, "Gone")
		return
	end
	if isInRun(player) then
		removeMember(player, "Stay")
		return
	end
	local root = Characters.GetRoot(player)
	if not root then
		-- Dead or no character. The Died / CharacterRemoving hooks normally get here first.
		removeMember(player, "Stay", "You left the party.")
		return
	end
	if not isHeldInZone(party.Pad.Info.Zone, root.Position) then
		-- Glitched or exploited out through a wall: put them back on their spot.
		if clock - (lastPutBack[player] or 0) >= PUT_BACK_COOLDOWN then
			lastPutBack[player] = clock
			Characters.SetGroup(player, Characters.Groups.PartyMember)
			teleport(player, slotCFrame(party.Pad, party.Slots[player] or 1))
		end
	end
end

local function loadPads(): boolean
	if padsLoaded then
		return true
	end
	local ok, lobby = pcall(LobbyBuilder.GetLobby)
	local padList = ok and lobby and (lobby :: any).Pads
	if type(padList) ~= "table" then
		return false
	end
	for _, raw in padList do
		local info = raw :: PadInfo
		local zone = (info :: any).Zone
		if typeof(zone) == "Instance" and zone:IsA("BasePart") and typeof(info.Inside) == "CFrame" and typeof(info.Exit) == "CFrame" then
			-- The walls must only block party members (LobbyBuilder sets this; make sure of it).
			local barriers: { BasePart } = info.Barriers or {}
			for _, barrier in barriers do
				if typeof(barrier) == "Instance" and barrier:IsA("BasePart") and barrier.CollisionGroup ~= Characters.Groups.PadBarrier then
					barrier.CollisionGroup = Characters.Groups.PadBarrier
				end
			end
			local pad: Pad = { Info = info, Party = nil, FloorColor = nil, Sounds = {} }
			table.insert(pads, pad)
			refreshPad(pad)
		else
			warn("[PartyService] pad " .. tostring(info.Id) .. " has no Zone/Inside/Exit, skipped")
		end
	end
	padsLoaded = true
	return true
end

local function tick()
	if not padsLoaded and not loadPads() then
		warnThrottled("waiting for LobbyBuilder.GetLobby() to return the pads")
		return
	end
	local now = Util.Now()
	local clock = os.clock()

	-- 1) Existing parties: hold members in, drop invalid ones, launch when the countdown is over.
	--    Members of a launching party are left alone: RoundService is busy moving them.
	for _, pad in pads do
		local party = pad.Party
		if party and (party.Status == "Waiting" or party.Status == "Picking") then
			for _, member in table.clone(party.Members) do
				validateMember(party, member, clock)
			end
			if not party.Dead and party.Status == "Waiting" and now >= party.EndsAt then
				launch(party)
			elseif not party.Dead and party.Status == "Picking" and now >= party.EndsAt then
				removeMember(party.Host, "Exit", "Party cancelled: you didn't pick a level in time.")
			end
		end
	end

	-- 2) Free players standing in a pad.
	for _, player in Players:GetPlayers() do
		if canEnterPads(player, clock) then
			local root = Characters.GetRoot(player)
			if root then
				local position = root.Position
				local leaving = mustLeave[player]
				if leaving then
					local zone = leaving.Pad.Info.Zone
					local settled = clock - leaving.Since > MUST_LEAVE_SETTLE
					if not zone.Parent or (settled and not isInsideZone(zone, position)) or clock - leaving.Since > MUST_LEAVE_MAX then
						mustLeave[player] = nil
						leaving = nil
					end
				end
				for _, pad in pads do
					local zone = pad.Info.Zone
					if zone.Parent and (not leaving or leaving.Pad ~= pad) and isInsideZone(zone, position) then
						admit(player, pad)
						break
					end
				end
			end
		end
	end
end

----------------------------------------------------------------------------------------------------
-- PartyAction (client requests)
----------------------------------------------------------------------------------------------------

local function onPartyAction(player: Player, action: any, value: any)
	if not allowAction(player) or type(action) ~= "string" then
		return
	end
	local party = memberOf[player]
	if not party or party.Dead then
		return
	end

	if action == "Leave" then
		if inLockWindow(party) then
			notify(player, "Too late to leave, the dishwasher is starting!", "Bad")
			return
		end
		removeMember(player, "Exit")
		return
	end

	-- Everything else is a host setting, and settings freeze once the party is launching.
	if party.Host ~= player then
		notify(player, "Only the host can change that.", "Bad")
		return
	end
	if party.Status == "Launching" then
		return
	end

	if action == "Create" then
		-- The host confirms the Create Party screen: { Level, MaxPlayers, Privacy }.
		if party.Status ~= "Picking" or type(value) ~= "table" then
			return
		end
		local level, max, privacy = value.Level, value.MaxPlayers, value.Privacy
		if not isInteger(level) or level < 1 or level > #Config.Levels then
			return
		end
		if level > unlockedOf(player) then
			notify(player, "That level is still locked!", "Bad")
			return
		end
		if not isInteger(max) or max < 1 or max > MAX_PLAYERS then
			return
		end
		if privacy ~= "Public" and privacy ~= "Friends" then
			return
		end
		party.Level = level
		party.LevelChosen = true
		party.MaxPlayers = max
		party.Privacy = privacy
		party.Status = "Waiting"
		party.EndsAt = Util.Now() + countdownFor(max)
		markDirty(party)
		refreshPad(party.Pad, true)
		playPadSound(party.Pad, "Pop")
		return
	end

	if action == "SetMax" then
		if not isInteger(value) or value < 1 or value > MAX_PLAYERS then
			return
		end
		if value < #party.Members then
			notify(player, "There are already " .. #party.Members .. " players in the party.", "Bad")
			return
		end
		local was = party.MaxPlayers
		party.MaxPlayers = value
		if party.Status == "Waiting" and value ~= was and (value == 1 or was == 1) then
			-- a party of one goes almost straight away; opening it up gives others time to join
			party.EndsAt = Util.Now() + countdownFor(value)
		end
	elseif action == "SetPrivacy" then
		if value ~= "Public" and value ~= "Friends" then
			return
		end
		party.Privacy = value
	elseif action == "SetLevel" then
		if not isInteger(value) or value < 1 or value > #Config.Levels then
			return
		end
		if value > unlockedOf(player) then
			notify(player, "That level is still locked!", "Bad")
			return
		end
		party.Level = value
		party.LevelChosen = true
	elseif action == "StartNow" then
		if party.Status ~= "Waiting" then
			return
		end
		party.EndsAt = math.min(party.EndsAt, Util.Now()) -- the poll loop launches it next tick
	else
		return
	end
	markDirty(party)
	refreshPad(party.Pad)
end

----------------------------------------------------------------------------------------------------
-- Players joining and leaving the server
----------------------------------------------------------------------------------------------------

local function onPlayerRemoving(player: Player)
	removeMember(player, "Gone")
	unhookMember(player)
	pendingJoin[player] = nil
	launching[player] = nil
	cooldownUntil[player] = nil
	mustLeave[player] = nil
	lastPutBack[player] = nil
	actionWindow[player] = nil
	friendCache[player] = nil
	local userId = player.UserId
	for _, byHost in friendCache do
		byHost[userId] = nil
	end
end

-- A host whose profile finished loading after they made the party: default the level to their best
-- dishwasher (unless they already picked one) and send the new HostUnlocked.
local function onProfileLoaded(player: Player)
	local party = memberOf[player]
	if not party or party.Dead then
		return
	end
	if party.Host == player and not party.LevelChosen and party.Status ~= "Launching" then
		party.Level = unlockedOf(player)
	end
	markDirty(party)
	refreshPad(party.Pad)
end

----------------------------------------------------------------------------------------------------
-- Public API
----------------------------------------------------------------------------------------------------

function PartyService.Init()
	partyStateRemote = Remotes.Event("PartyState")
	notifyRemote = Remotes.Event("Notify")

	if not loadPads() then
		warn("[PartyService] lobby pads not ready at Init; will keep trying")
	end

	Remotes.Event("PartyAction").OnServerEvent:Connect(onPartyAction)

	Players.PlayerAdded:Connect(function(player)
		player:SetAttribute("InParty", false)
	end)
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("InParty") == nil then
			player:SetAttribute("InParty", false)
		end
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	local profileLoaded = DataService.ProfileLoaded
	if profileLoaded then
		profileLoaded:Connect(onProfileLoaded)
	end

	-- Party members are removed the moment they die, so a respawning player is never in a party and
	-- this resolver has no opinion (the lobby spawn or RoundService decides).
	Characters.AddRespawnResolver(function(_player: Player): CFrame?
		return nil
	end)
end

function PartyService.Start()
	task.spawn(function()
		while true do
			local ok, err = xpcall(tick, debug.traceback)
			if not ok then
				warnThrottled("poll error: " .. tostring(err))
			end
			task.wait(PARTY.PollInterval)
		end
	end)

	-- Billboards: the countdown text changes once a second, so 4 checks a second keeps it crisp.
	task.spawn(function()
		while true do
			task.wait(LABEL_INTERVAL)
			for _, pad in pads do
				local ok, err = pcall(refreshPad, pad)
				if not ok then
					warnThrottled("pad refresh error: " .. tostring(err))
				end
			end
		end
	end)
end

function PartyService.IsInParty(player: Player): boolean
	return memberOf[player] ~= nil
end

-- Takes a player out of their party right now (ignores the launch lock), walking them out of the
-- pad unless they're in a run.
function PartyService.RemovePlayer(player: Player)
	removeMember(player, "Exit")
end

return PartyService
