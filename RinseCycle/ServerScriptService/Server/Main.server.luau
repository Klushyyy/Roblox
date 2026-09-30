-- Rinse Cycle server entry point. Builds the world, then starts every service in order.
-- Each service module exposes Init() (set up state and remote handlers, no long yields)
-- and Start() (spawn loops). See DESIGN.md for what each one owns.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

-- Hold characters back until the lobby floor exists, or new players fall into the void.
Players.CharacterAutoLoads = false
Players.RespawnTime = 3

-- Spawning must NEVER stay off. Whatever happens below (a service erroring or hanging while the
-- server starts), players get their characters: the normal path turns spawning on once the lobby
-- is built; this safety net does it after SPAWN_FAILSAFE seconds no matter what, and a watchdog
-- keeps spawning anyone still without a character after that (it logs why it had to).
local SPAWN_FAILSAFE = 15
local spawnsReleased = false
local function spawnMissing(reason: string)
	for _, player in Players:GetPlayers() do
		if not player.Character and player.Parent == Players then
			warn(string.format("[Rinse Cycle] spawning %s (%s)", player.Name, reason))
			task.spawn(function()
				local ok = pcall(function()
					player:LoadCharacterAsync()
				end)
				if not ok then
					pcall(function()
						player:LoadCharacter()
					end)
				end
			end)
		end
	end
end
local function releaseSpawns(reason: string)
	if spawnsReleased then
		return
	end
	spawnsReleased = true
	Players.CharacterAutoLoads = true
	spawnMissing(reason)
end
task.delay(SPAWN_FAILSAFE, function()
	if not spawnsReleased then
		warn("[Rinse Cycle] server start took too long: spawning players anyway")
		releaseSpawns("start-up failsafe")
	end
end)
local joinedAt: { [Player]: number } = {}
Players.PlayerAdded:Connect(function(player)
	joinedAt[player] = os.clock()
end)
Players.PlayerRemoving:Connect(function(player)
	joinedAt[player] = nil
end)
task.spawn(function()
	while true do
		task.wait(5)
		if spawnsReleased then
			for _, player in Players:GetPlayers() do
				local at = joinedAt[player] or 0
				if not player.Character and os.clock() - at > SPAWN_FAILSAFE then
					spawnMissing("had no character after joining")
					break
				end
			end
		end
	end
end)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))

local ServicesFolder = script.Parent:WaitForChild("Services")

-- Loads one service. A missing or broken one is reported and skipped (an empty table) instead of
-- stopping this whole script - which would leave everything after it, spawning included, undone.
local function need(name: string): any
	local module = ServicesFolder:WaitForChild(name, 10)
	if not module or not module:IsA("ModuleScript") then
		warn(string.format("[Rinse Cycle] service %s is missing (it must be a ModuleScript in Server > Services)", name))
		return {}
	end
	local ok, result = pcall(require, module)
	if not ok then
		warn(string.format("[Rinse Cycle] service %s failed to load: %s", name, tostring(result)))
		return {}
	end
	return result
end
local Characters = need("Characters")
local DataService = need("DataService")
local MarketService = need("MarketService")
local LobbyBuilder = need("LobbyBuilder")
local DishFactory = need("DishFactory")
local ArenaBuilder = need("ArenaBuilder")
local RoundService = need("RoundService")
local PetService = need("PetService")
local ShopService = need("ShopService")
local PartyService = need("PartyService")
local LeaderboardService = need("LeaderboardService")
local NameTags = need("NameTags")
local SocialService = need("SocialService")
local LobbyFun = need("LobbyFun")
local RunServers = need("RunServers")
local GiftService = need("GiftService")
local TradeService = need("TradeService")

local function step(name: string, fn: () -> ())
	local started = os.clock()
	local ok, err = xpcall(fn, debug.traceback)
	if not ok then
		warn(string.format("[%s] %s FAILED:\n%s", Config.GameName, name, tostring(err)))
	elseif os.clock() - started > 5 then
		print(string.format("[%s] %s took %.1fs", Config.GameName, name, os.clock() - started))
	end
end

-- Camera and movement defaults (apply to characters spawned after this point).
StarterPlayer.CameraMaxZoomDistance = 60
StarterPlayer.CameraMinZoomDistance = 0.5 -- scroll all the way in for first person
StarterPlayer.CharacterWalkSpeed = Config.World.LobbyWalkSpeed

-- The dishwashers are built deep under the lobby; make sure the kill plane is below them even if the
-- place file didn't set it (scripts may not be allowed to, hence the pcall).
pcall(function()
	if workspace.FallenPartsDestroyHeight > -10000 then
		workspace.FallenPartsDestroyHeight = -20000
	end
end)
step("Remotes", Remotes.Setup)
step("Characters", Characters.Setup)
step("DataService.Init", DataService.Init)
step("MarketService.Init", MarketService.Init)
step("LobbyBuilder.Build", function()
	LobbyBuilder.Build()
end)

-- Players can spawn now that the lobby exists.
releaseSpawns("lobby ready")

local services = {
	{ "DishFactory", DishFactory },
	{ "ArenaBuilder", ArenaBuilder },
	{ "RoundService", RoundService },
	{ "RunServers", RunServers },
	{ "PetService", PetService },
	{ "ShopService", ShopService },
	{ "PartyService", PartyService },
	{ "LeaderboardService", LeaderboardService },
	{ "NameTags", NameTags },
	{ "SocialService", SocialService },
	{ "LobbyFun", LobbyFun },
	{ "GiftService", GiftService },
	{ "TradeService", TradeService },
}

for _, entry in services do
	local name, service = entry[1], entry[2] :: any
	if type(service.Init) == "function" then
		step(name .. ".Init", service.Init)
	end
end
for _, entry in services do
	local name, service = entry[1], entry[2] :: any
	if type(service.Start) == "function" then
		step(name .. ".Start", service.Start)
	end
end
if type((MarketService :: any).Start) == "function" then
	step("MarketService.Start", (MarketService :: any).Start)
end
if type((DataService :: any).Start) == "function" then
	step("DataService.Start", (DataService :: any).Start)
end

print(string.format("[%s] v%s server ready", Config.GameName, Config.Version))
