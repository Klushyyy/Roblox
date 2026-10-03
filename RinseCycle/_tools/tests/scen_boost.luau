local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local meta = Remotes.Function("MetaRequest")
local function req(action)
	local r = call("client", function()
		return meta:InvokeServer(action)
	end)
	pump(0.3, G.frame)
	out(string.format("%-16s -> ok=%s %s %s", action, tostring(r and r.Ok), tostring(r and r.Error or ""), tostring(r and r.Message or "")))
	return r
end
local prof = DS.Get(p)
out("ready before: " .. tostring(CS.Meta and CS.Meta.StayBoostReady))
req("ClaimStayBoost")
out("boost left s: " .. tostring((tonumber(prof.BoostUntil) or 0) - os.time()) .. " client BoostUntil set: " .. tostring((CS.Meta and CS.Meta.BoostUntil or 0) > 0) .. " ready after: " .. tostring(CS.Meta and CS.Meta.StayBoostReady))
req("ClaimStayBoost")
out("L1 toughness " .. Config.Levels[1].Toughness .. " start coins L1 " .. tostring(Config.StartCoins(1)) .. " L2 " .. tostring(Config.StartCoins(2)))
out("music lists: " .. #Config.Music.Lobby .. " / " .. #Config.Music.Run)
