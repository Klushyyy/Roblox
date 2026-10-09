--[[
	LobbyFun - little things to do in the lobby between runs (Config.LobbyBubbles, Config.Ducks).

	* Poppable soap bubbles float over the plaza. Touch or click one to pop it for +1 Bubble (a rare
	  golden one pays more); it comes back somewhere else a few seconds later. Pops are capped per
	  player per minute so an autoclicker can't farm them.
	* Rubber ducks are hidden around the lobby. Each one pays once (saved in Profile.Ducks); finding
	  them all pays the big reward. Player attribute "DucksFound" (comma list) lets each client hide
	  the ducks it already found.

	The server owns every part (anchored, never moved); clients bob the bubbles locally and add
	their glint (Effects, tag "PopBubble") and play the pop / quack effects from RunFX "LobbyPop" / "Duck".
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Services = script.Parent
local DataService = require(Services:WaitForChild("DataService"))
local LobbyBuilder = require(Services:WaitForChild("LobbyBuilder"))

local LobbyFun = {}

local FLOOR_Y = 0.2
local BUBBLE_SIZE = 3.4
local GOLDEN_SIZE = 3.8

-- Spots the bubbles keep away from (x, z, radius): props they would sit inside of.
local AVOID = {
	{ -32, 40, 8 }, -- rank shrine
	{ 34, 44, 15 }, -- how-to-play board
	{ -11, -52, 3 },
	{ 11, -52, 3 },
	{ -11, -22, 3 },
	{ 11, -22, 3 }, -- path lamps
	{ -38, -46, 13 },
	{ -38, -20, 13 },
	{ -38, 6, 13 },
	{ 38, -46, 13 },
	{ 38, -20, 13 },
	{ 38, 6, 13 }, -- the six party pads
	{ -25, -20, 4 },
	{ 25, -20, 4 }, -- the posts of the arch over the walkway
}

-- Where each duck sits (feet position) and which way it faces (yaw, degrees; 0 = facing +Z).
local Layout = LobbyBuilder.Layout
local DUCK_SPOTS: { [string]: { Pos: Vector3, Yaw: number, Float: boolean? } } = {
	Fountain = { Pos = Vector3.new(Layout.Fountain.X, FLOOR_Y + 2.4, Layout.Fountain.Z + 4.6), Yaw = 70, Float = true },
	Doghouse = { Pos = Vector3.new(Layout.PetStand.X + 3.6, 3, Layout.PetStand.Z), Yaw = 90 }, -- (the stand faces the middle, +X)
	Sponge = { Pos = Vector3.new(-79, 6.7, 45), Yaw = 160 },
	Board = { Pos = Vector3.new(Layout.DishesBoard.X + 8, FLOOR_Y, Layout.DishesBoard.Z - 14), Yaw = 200 },
	Shakers = { Pos = Vector3.new(-44, 55.1, -101.5), Yaw = 130 }, -- on the building's roof, back corner
	Saucer = { Pos = Vector3.new(84.4, FLOOR_Y + 0.8, 56), Yaw = -60 },
}

local folder: Folder? = nil
local fxRemote: RemoteEvent? = nil
local rng = Random.new()
local alive: { [BasePart]: boolean } = {}
local aliveCount = 0
local popLog: { [Player]: { number } } = {}
local duckCooldown: { [Player]: number } = {}

local function fire(kind: string, data: any)
	if fxRemote then
		fxRemote:FireAllClients(kind, data)
	end
end

local function playerFromHit(hit: BasePart): Player?
	local model = hit:FindFirstAncestorOfClass("Model")
	while model and not model:FindFirstChildOfClass("Humanoid") do
		model = model:FindFirstAncestorOfClass("Model")
	end
	return if model then Players:GetPlayerFromCharacter(model) else nil
end

local function nearPlayer(player: Player, pos: Vector3, range: number): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return root ~= nil and root:IsA("BasePart") and (root.Position - pos).Magnitude <= range
end

-- Per-player pop cap: true if this pop is allowed (and records it).
local function allowPop(player: Player): boolean
	local now = os.clock()
	local log = popLog[player]
	if not log then
		log = {}
		popLog[player] = log
	end
	while log[1] and now - log[1] > 60 do
		table.remove(log, 1)
	end
	if #log >= Config.LobbyBubbles.PerMinute then
		return false
	end
	table.insert(log, now)
	return true
end

----------------------------------------------------------------------------------------------------
-- Bubbles
----------------------------------------------------------------------------------------------------
local spawnBubble: () -> ()

local function pickSpot(): Vector3?
	for _ = 1, 30 do
		local x, z = rng:NextNumber(-46, 46), rng:NextNumber(-48, 58)
		local ok = true
		for _, a in AVOID do
			if (x - a[1]) ^ 2 + (z - a[2]) ^ 2 < a[3] ^ 2 then
				ok = false
				break
			end
		end
		if ok then
			for part in alive do
				local p = part.Position
				if (p.X - x) ^ 2 + (p.Z - z) ^ 2 < 36 then
					ok = false
					break
				end
			end
		end
		if ok then
			return Vector3.new(x, FLOOR_Y + rng:NextNumber(3.6, 8.6), z)
		end
	end
	return nil
end

local function pop(bubble: BasePart, player: Player)
	if not alive[bubble] then
		return
	end
	if not allowPop(player) then
		return
	end
	alive[bubble] = nil
	aliveCount -= 1
	local golden = bubble:GetAttribute("Golden") == true
	local amount = if golden then Config.LobbyBubbles.GoldenReward else Config.LobbyBubbles.Reward
	local pos = bubble.Position
	bubble:Destroy()
	DataService.AddBubbles(player, amount, "LobbyBubble")
	DataService.Track(player, "fun.bubble")
	fire("LobbyPop", { Position = pos, Golden = golden, By = player.UserId, Amount = amount })
	local delay = Config.LobbyBubbles.RespawnDelay
	task.delay(rng:NextNumber(delay[1], delay[2]), spawnBubble)
end

spawnBubble = function()
	local parent = folder
	if not parent or aliveCount >= Config.LobbyBubbles.Max then
		return
	end
	local pos = pickSpot()
	if not pos then
		task.delay(3, spawnBubble)
		return
	end
	local golden = rng:NextNumber() < Config.LobbyBubbles.GoldenChance
	local size = if golden then GOLDEN_SIZE else BUBBLE_SIZE
	local bubble = Instance.new("Part")
	bubble.Name = if golden then "GoldenBubble" else "PopBubble"
	bubble.Shape = Enum.PartType.Ball
	bubble.Size = Vector3.one * size
	bubble.CFrame = CFrame.new(pos)
	bubble.Anchored = true
	bubble.CanCollide = false
	bubble.CanQuery = true -- clickable
	bubble.CanTouch = true
	bubble.CastShadow = false
	bubble.Material = Enum.Material.ForceField
	bubble.Color = if golden then Color3.fromRGB(255, 205, 70) else Color3.fromRGB(150, 215, 255)
	bubble:SetAttribute("Base", pos)
	bubble:SetAttribute("Golden", golden)
	if golden then
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 210, 90)
		light.Range = 10
		light.Brightness = 1.2
		light.Parent = bubble
	end
	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 24
	click.Parent = bubble
	click.MouseClick:Connect(function(player: Player)
		if nearPlayer(player, bubble.Position, 28) then
			pop(bubble, player)
		end
	end)
	bubble.Touched:Connect(function(hit: BasePart)
		local player = playerFromHit(hit)
		if player then
			pop(bubble, player)
		end
	end)
	CollectionService:AddTag(bubble, "PopBubble")
	alive[bubble] = true
	aliveCount += 1
	bubble.Parent = parent
end

-- The big soap bubbles floating over the table (tag "FloatBubble", placed by LobbyBuilder) pop too,
-- for anyone who manages to reach one: +1 Bubble, and it comes back in the same spot a bit later.
local function makeFloatPoppable(bubble: BasePart)
	bubble.CanTouch = true
	bubble.CanQuery = true
	local popped = false
	local click = Instance.new("ClickDetector")
	click.MaxActivationDistance = 24
	local function tryPop(player: Player)
		if popped or not allowPop(player) then
			return
		end
		popped = true
		local pos = bubble.Position
		local shown = bubble.Transparency
		bubble.Transparency = 1
		bubble.CanTouch = false
		click.Parent = nil
		DataService.AddBubbles(player, Config.LobbyBubbles.Reward, "LobbyBubble")
		DataService.Track(player, "fun.bubble")
		fire("LobbyPop", { Position = pos, Golden = false, By = player.UserId, Amount = Config.LobbyBubbles.Reward })
		task.delay(rng:NextNumber(8, 16), function()
			if bubble.Parent then
				bubble.Transparency = shown
				bubble.CanTouch = true
				click.Parent = bubble
				popped = false
			end
		end)
	end
	click.MouseClick:Connect(function(player: Player)
		if nearPlayer(player, bubble.Position, 28) then
			tryPop(player)
		end
	end)
	bubble.Touched:Connect(function(hit: BasePart)
		local player = playerFromHit(hit)
		if player then
			tryPop(player)
		end
	end)
	click.Parent = bubble
end

----------------------------------------------------------------------------------------------------
-- Ducks
----------------------------------------------------------------------------------------------------
local function duckPart(parent: Instance, name: string, oval: boolean, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if oval then
		-- Ball parts are always round; a sphere mesh stretches to the part's size (an ellipsoid).
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = p
	end
	p.Parent = parent
	return p
end

-- A classic yellow rubber duck, about 3.4 studs tall, feet at `feet`, looking along its -Z.
local function buildDuck(id: string, feet: CFrame, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "RubberDuck_" .. id
	local yellow = Color3.fromRGB(255, 212, 50)
	local shade = Color3.fromRGB(246, 192, 34)
	local orange = Color3.fromRGB(255, 140, 40)
	duckPart(model, "Body", true, Vector3.new(2.7, 2.1, 3.3), feet * CFrame.new(0, 1.05, 0.2), yellow)
	duckPart(model, "Tail", true, Vector3.new(1.3, 1.1, 1.3), feet * CFrame.new(0, 1.75, 1.55) * CFrame.Angles(math.rad(-40), 0, 0), yellow)
	for _, side in { -1, 1 } do
		duckPart(model, "Wing", true, Vector3.new(0.5, 1.2, 1.9), feet * CFrame.new(side * 1.12, 1.25, 0.4) * CFrame.Angles(math.rad(-12), 0, 0), shade)
	end
	local headCF = feet * CFrame.new(0, 2.45, -0.7)
	duckPart(model, "Head", true, Vector3.new(1.9, 1.85, 1.9), headCF, yellow)
	duckPart(model, "Beak", true, Vector3.new(1.1, 0.42, 1.0), headCF * CFrame.new(0, -0.18, -0.95), orange)
	for _, side in { -1, 1 } do
		duckPart(model, "Eye", true, Vector3.new(0.3, 0.38, 0.2), headCF * CFrame.new(side * 0.45, 0.25, -0.82) * CFrame.Angles(0, side * math.rad(25), 0), Color3.fromRGB(20, 20, 24))
		duckPart(model, "EyeShine", true, Vector3.new(0.1, 0.1, 0.06), headCF * CFrame.new(side * 0.45 + 0.05, 0.34, -0.91), Color3.new(1, 1, 1), Enum.Material.Neon)
	end
	-- Touch/click target (a bit bigger than the duck so it's easy to grab).
	local hit = Instance.new("Part")
	hit.Name = "Hitbox"
	hit.Size = Vector3.new(3.6, 3.6, 3.8)
	hit.CFrame = feet * CFrame.new(0, 1.6, 0)
	hit.Transparency = 1
	hit.Anchored = true
	hit.CanCollide = false
	hit.CanQuery = true
	hit.CanTouch = true
	hit.CastShadow = false
	hit.Parent = model
	model.PrimaryPart = hit
	model:SetAttribute("DuckId", id)
	CollectionService:AddTag(model, "RubberDuck")
	model.Parent = parent
	return model
end

local function foundList(player: Player): { string }
	local profile = DataService.Get(player)
	return if profile then (profile :: any).Ducks or {} else {}
end

local function syncAttribute(player: Player)
	player:SetAttribute("DucksFound", table.concat(foundList(player), ","))
end

local function giveReward(player: Player, reward: { Bubbles: number?, Gems: number? })
	DataService.Track(player, "fun.duck")
	if reward.Bubbles and reward.Bubbles > 0 then
		DataService.AddBubbles(player, reward.Bubbles, "Duck")
	end
	if reward.Gems and reward.Gems > 0 then
		DataService.AddGems(player, reward.Gems, "Duck")
	end
end

local function findDuck(player: Player, id: string, model: Model)
	local now = os.clock()
	if (duckCooldown[player] or 0) > now then
		return
	end
	duckCooldown[player] = now + 0.5
	local pos = (model.PrimaryPart :: BasePart).Position
	if not nearPlayer(player, pos, 30) then
		return
	end
	local isNew, count = DataService.FindDuck(player, id)
	local total = #Config.Ducks.List
	if not isNew then
		return -- already found: the client hides it, so this is only a stale touch
	end
	giveReward(player, Config.Ducks.Reward)
	local all = count >= total
	if all then
		giveReward(player, Config.Ducks.AllReward)
		DataService.Notice(player, "You found every rubber duck! +" .. Config.RewardText(Config.Ducks.AllReward), "Good")
	else
		DataService.Notice(player, string.format("Rubber duck %d/%d found! +%s", count, total, Config.RewardText(Config.Ducks.Reward)), "Good")
	end
	DataService.PushMeta(player)
	syncAttribute(player)
	if fxRemote then
		fxRemote:FireClient(player, "Duck", { Position = pos, Count = count, Total = total, All = all })
	end
end

local function buildDucks(parent: Instance)
	for _, entry in Config.Ducks.List do
		local spot = DUCK_SPOTS[entry.Id]
		if not spot then
			warn("[LobbyFun] no spot for duck " .. entry.Id)
			continue
		end
		-- Yaw 0 faces +Z (toward the spawn side); the duck model looks along its own -Z.
		local feet = CFrame.new(spot.Pos) * CFrame.Angles(0, math.rad(spot.Yaw) + math.pi, 0)
		local model = buildDuck(entry.Id, feet, parent)
		if spot.Float then
			model:SetAttribute("Float", true)
		end
		local hit = model.PrimaryPart :: BasePart
		local click = Instance.new("ClickDetector")
		click.MaxActivationDistance = 24
		click.Parent = hit
		click.MouseClick:Connect(function(player: Player)
			findDuck(player, entry.Id, model)
		end)
		hit.Touched:Connect(function(other: BasePart)
			local player = playerFromHit(other)
			if player then
				findDuck(player, entry.Id, model)
			end
		end)
	end
end

----------------------------------------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------------------------------------
function LobbyFun.Init()
	fxRemote = Remotes.Event("RunFX")
	Players.PlayerRemoving:Connect(function(player)
		popLog[player] = nil
		duckCooldown[player] = nil
	end)
end

function LobbyFun.Start()
	local lobby = LobbyBuilder.GetLobby()
	if not lobby then
		warn("[LobbyFun] no lobby; skipping")
		return
	end
	local f = Instance.new("Folder")
	f.Name = "LobbyFun"
	f.Parent = lobby.Model
	folder = f
	buildDucks(f)
	for _ = 1, Config.LobbyBubbles.Max do
		spawnBubble()
	end
	for _, inst in CollectionService:GetTagged("FloatBubble") do
		if inst:IsA("BasePart") and inst:IsDescendantOf(lobby.Model) then
			makeFloatPoppable(inst)
		end
	end
	local function onPlayer(player: Player)
		task.spawn(function()
			DataService.WaitFor(player, 60)
			if player.Parent then
				syncAttribute(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return LobbyFun
