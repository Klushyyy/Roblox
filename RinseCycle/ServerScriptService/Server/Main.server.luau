-- Rinse Cycle server entry point. Builds the world, then starts every service in order.
-- Each service module exposes Init() (set up state and remote handlers, no long yields)
-- and Start() (spawn loops). See DESIGN.md for what each one owns.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

-- Hold characters back until the lobby floor exists, or new players fall into the void.
Players.CharacterAutoLoads = false
Players.RespawnTime = 3

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local Config = require(Shared:WaitForChild("Config"))

local ServicesFolder = script.Parent:WaitForChild("Services")
local Characters = require(ServicesFolder:WaitForChild("Characters"))
local DataService = require(ServicesFolder:WaitForChild("DataService"))
local MarketService = require(ServicesFolder:WaitForChild("MarketService"))
local LobbyBuilder = require(ServicesFolder:WaitForChild("LobbyBuilder"))
local DishFactory = require(ServicesFolder:WaitForChild("DishFactory"))
local ArenaBuilder = require(ServicesFolder:WaitForChild("ArenaBuilder"))
local RoundService = require(ServicesFolder:WaitForChild("RoundService"))
local PetService = require(ServicesFolder:WaitForChild("PetService"))
local ShopService = require(ServicesFolder:WaitForChild("ShopService"))
local PartyService = require(ServicesFolder:WaitForChild("PartyService"))
local LeaderboardService = require(ServicesFolder:WaitForChild("LeaderboardService"))
local NameTags = require(ServicesFolder:WaitForChild("NameTags"))
local SocialService = require(ServicesFolder:WaitForChild("SocialService"))

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

step("Remotes", Remotes.Setup)
step("Characters", Characters.Setup)
step("DataService.Init", DataService.Init)
step("MarketService.Init", MarketService.Init)
step("LobbyBuilder.Build", function()
	LobbyBuilder.Build()
end)

-- Players can spawn now that the lobby exists.
Players.CharacterAutoLoads = true
for _, player in Players:GetPlayers() do
	if not player.Character then
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

local services = {
	{ "DishFactory", DishFactory },
	{ "ArenaBuilder", ArenaBuilder },
	{ "RoundService", RoundService },
	{ "PetService", PetService },
	{ "ShopService", ShopService },
	{ "PartyService", PartyService },
	{ "LeaderboardService", LeaderboardService },
	{ "NameTags", NameTags },
	{ "SocialService", SocialService },
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
