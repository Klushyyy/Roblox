-- The tool sounds: every key SprayController plays exists in Config.Sounds with a quiet volume, and playing them works.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local UK = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local keys = { "Hiss", "Rumble", "Squish", "Fwump", "Valve", "Equip", "Scrub", "Splash" }
local loud = {}
for _, k in keys do
	local def = Config.Sounds[k]
	if not def then
		out("MISSING sound key " .. k)
	elseif def.Volume > 0.4 and k ~= "Scrub" and k ~= "Splash" then
		table.insert(loud, k .. "=" .. def.Volume)
	end
end
out("tool sound keys present: " .. #keys .. "  louder than 0.4 (none expected): " .. table.concat(loud, " "))
for _, k in { "Valve", "Hiss", "Rumble", "Fwump", "Squish", "Equip" } do
	call("client", function() UK.PlaySound(k, 1.5) end)
end
pump(0.5, G.frame)
local folder = game:GetService("SoundService"):FindFirstChild("UIKitSounds")
local made = {}
for _, k in { "Valve", "Hiss", "Rumble", "Fwump", "Squish", "Equip" } do
	if folder and folder:FindFirstChild(k) then table.insert(made, k) end
end
out("sound templates created: " .. table.concat(made, " "))
