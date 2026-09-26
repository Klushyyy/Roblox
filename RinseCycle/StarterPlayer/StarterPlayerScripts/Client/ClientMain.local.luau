-- Rinse Cycle client entry point. Starts the shared client state, then every UI / gameplay module.
-- Each module exposes Init(); anything that fails is reported without stopping the others.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))
local HUD = require(Client:WaitForChild("HUD"))
local PartyUI = require(Client:WaitForChild("PartyUI"))
local UpgradesUI = require(Client:WaitForChild("UpgradesUI"))
local ShopUI = require(Client:WaitForChild("ShopUI"))
local PetsUI = require(Client:WaitForChild("PetsUI"))
local SprayController = require(Client:WaitForChild("SprayController"))
local PetRenderer = require(Client:WaitForChild("PetRenderer"))
local Effects = require(Client:WaitForChild("Effects"))

local function step(name: string, fn: () -> ())
	local ok, err = xpcall(fn, debug.traceback)
	if not ok then
		warn(string.format("[%s] client %s FAILED:\n%s", Config.GameName, name, tostring(err)))
	end
end

step("ClientState", ClientState.Init)
step("UIKit", UIKit.Init)

ClientState.Notified:Connect(function(text, kind)
	UIKit.Toast(text, kind)
end)

step("HUD", HUD.Init)
step("PartyUI", PartyUI.Init)
step("UpgradesUI", UpgradesUI.Init)
step("ShopUI", ShopUI.Init)
step("PetsUI", PetsUI.Init)
step("SprayController", SprayController.Init)
step("PetRenderer", PetRenderer.Init)
step("Effects", Effects.Init)
