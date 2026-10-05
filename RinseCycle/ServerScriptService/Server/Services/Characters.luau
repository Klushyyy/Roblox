-- Character helpers shared by every server service: collision groups, teleporting,
-- walk speed that survives respawns, and "where should this player respawn".

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local Characters = {}

Characters.Groups = {
	Players = "Players", -- every character by default (players never collide with each other)
	PartyMember = "PartyMember", -- characters waiting inside a party pad (the pad's walls block them)
	PadBarrier = "PadBarrier", -- pad walls: only block PartyMember
	NoCollide = "NoCollide", -- decoration / grime / effects: collide with nothing
}

local groupOf: { [Player]: string } = {}
local walkSpeedOf: { [Player]: number? } = {}
local respawnResolvers: { (Player) -> CFrame? } = {}

local function registerGroup(name: string)
	local ok = pcall(function()
		if not workspace:IsCollisionGroupRegistered(name) then
			workspace:RegisterCollisionGroup(name)
		end
	end)
	if not ok then
		-- Older engines: collision groups still live on PhysicsService.
		pcall(function()
			if not PhysicsService:IsCollisionGroupRegistered(name) then
				PhysicsService:RegisterCollisionGroup(name)
			end
		end)
	end
end

local function setCollidable(a: string, b: string, collidable: boolean)
	local ok = pcall(function()
		workspace:CollisionGroupSetCollidable(a, b, collidable)
	end)
	if not ok then
		pcall(function()
			PhysicsService:CollisionGroupSetCollidable(a, b, collidable)
		end)
	end
end

local function applyGroup(character: Model, group: string)
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = group
		end
	end
end

local function onCharacterAdded(player: Player, character: Model)
	applyGroup(character, groupOf[player] or Characters.Groups.Players)
	-- Accessories and tools arrive after CharacterAdded; keep them in the same group.
	character.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = groupOf[player] or Characters.Groups.Players
		end
	end)

	local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
	local speed = walkSpeedOf[player]
	if humanoid and speed then
		humanoid.WalkSpeed = speed
	end

	-- A fresh character that hangs in the air (spawned a bit high, or held there while things load) is put
	-- on the ground straight away instead of floating for a second.
	task.spawn(function()
		local root = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?
		if not humanoid or not root then
			return
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { character }
		for _ = 1, 30 do
			task.wait(0.1)
			if not character.Parent or humanoid.Health <= 0 then
				return
			end
			if humanoid.FloorMaterial == Enum.Material.Air and math.abs(root.AssemblyLinearVelocity.Y) < 1 and not root:FindFirstChildOfClass("LinearVelocity") then
				local hit = workspace:Raycast(root.Position, Vector3.new(0, -40, 0), params)
				if hit then
					local gap = root.Position.Y - hit.Position.Y - (humanoid.HipHeight + root.Size.Y / 2)
					if gap > 0.4 then
						character:PivotTo(character:GetPivot() - Vector3.new(0, gap, 0))
						root.AssemblyLinearVelocity = Vector3.zero
					end
				end
			end
		end
	end)

	-- Let services decide where this player should be (party pad, dishwasher, lobby).
	task.defer(function()
		for _, resolve in respawnResolvers do
			local ok, cf = pcall(resolve, player)
			if ok and cf then
				Characters.Teleport(player, cf)
				break
			end
		end
	end)
end

-- Call once from Main before anything else touches characters.
function Characters.Setup()
	for _, name in Characters.Groups :: { [string]: string } do
		registerGroup(name)
	end
	local g = Characters.Groups
	setCollidable(g.Players, g.Players, false)
	setCollidable(g.Players, g.PartyMember, false)
	setCollidable(g.PartyMember, g.PartyMember, false)
	setCollidable(g.PadBarrier, "Default", false)
	setCollidable(g.PadBarrier, g.Players, false)
	setCollidable(g.PadBarrier, g.PartyMember, true)
	setCollidable(g.PadBarrier, g.NoCollide, false)
	for _, other in { "Default", g.Players, g.PartyMember, g.NoCollide } do
		setCollidable(g.NoCollide, other, false)
	end

	local function hook(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacterAdded(player, character)
		end)
		if player.Character then
			onCharacterAdded(player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in Players:GetPlayers() do
		hook(p)
	end
	Players.PlayerRemoving:Connect(function(p)
		groupOf[p] = nil
		walkSpeedOf[p] = nil
	end)
end

-- Put a player's character (now and after every respawn) into a collision group.
function Characters.SetGroup(player: Player, group: string)
	groupOf[player] = group
	if player.Character then
		applyGroup(player.Character, group)
	end
end

function Characters.GetRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

function Characters.IsAlive(player: Player): boolean
	return Characters.GetRoot(player) ~= nil
end

-- Moves a character to stand at `cframe` (feet roughly at cframe.Position). Returns false if the
-- player has no living character. Velocity is cleared so nobody keeps flying after a teleport.
function Characters.Teleport(player: Player, cframe: CFrame): boolean
	local character = player.Character
	local root = Characters.GetRoot(player)
	if not character or not root then
		return false
	end
	if workspace.StreamingEnabled then
		pcall(function()
			player:RequestStreamAroundAsync(cframe.Position, 2)
		end)
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local lift = (humanoid and humanoid.HipHeight or 2) + root.Size.Y / 2 + 0.5
	character:PivotTo(cframe + Vector3.new(0, lift, 0))
	for _, d in character:GetDescendants() do
		if d:IsA("BasePart") then
			d.AssemblyLinearVelocity = Vector3.zero
			d.AssemblyAngularVelocity = Vector3.zero
		end
	end
	return true
end

-- Walk speed that is re-applied after every respawn. nil resets to the lobby default
-- (StarterPlayer.CharacterWalkSpeed, which Main sets from Config.World.LobbyWalkSpeed).
function Characters.SetWalkSpeed(player: Player, speed: number?)
	walkSpeedOf[player] = speed
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.WalkSpeed = speed or game:GetService("StarterPlayer").CharacterWalkSpeed
	end
end

--[[
	Register a function that says where a player should appear after (re)spawning.
	It returns a CFrame to teleport them there, or nil to let the next resolver (or the
	normal SpawnLocation) decide. Resolvers are asked in the order they were added.
]]
function Characters.AddRespawnResolver(resolver: (Player) -> CFrame?)
	table.insert(respawnResolvers, resolver)
end

return Characters
