local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local Config = M[R .. "ReplicatedStorage/Shared/Config.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local p = G.player
local meta = Remotes.Function("MetaRequest")
local function req(action, value)
	local r = call("client", function()
		return meta:InvokeServer(action, value)
	end)
	pump(0.3, G.frame)
	local extra = ""
	if r and r.Message then
		extra = " msg=" .. tostring(r.Message)
	end
	out(string.format("%-12s %-18s -> ok=%s %s%s", action, tostring(type(value) == "table" and "{...}" or value), tostring(r and r.Ok), tostring(r and r.Error or ""), extra))
	return r
end
local prof = DS.Get(p)
out("start bubbles=" .. tostring(prof.Bubbles) .. " gems=" .. tostring(prof.Gems))
req("RedeemCode", "RELEASE")
req("RedeemCode", "release")
req("RedeemCode", "NOPE")
req("ClaimDaily")
req("ClaimDaily")
req("SocialDone", "Like")
req("SocialDone", "Like")
req("SocialDone", "Follow")
req("SocialDone", "Follow")
req("SocialDone", "Hack")
out("after rewards bubbles=" .. tostring(prof.Bubbles) .. " gems=" .. tostring(prof.Gems) .. " client meta bubbles=" .. tostring(CS.Meta and CS.Meta.Bubbles))
prof.Bubbles = 1e7
local eggId
for id in Config.Eggs do
	eggId = eggId or id
end
local egg = Config.Eggs[1] and 1 or eggId
for _, e in (Config.Eggs[1] and Config.Eggs or {}) do
	egg = e.Id
	break
end
req("Hatch", egg)
req("Hatch", { Egg = egg, Count = 2 })
req("Hatch", { Egg = "NoSuchEgg", Count = 1 })
for i = 1, 3 do
	req("Hatch", { Egg = egg, Count = 3 })
end
out("pets owned: " .. #prof.Pets)
req("EquipBest")
local uids = {}
for _, pet in prof.Pets do
	table.insert(uids, pet.Uid)
end
req("Equip", uids[1])
req("Unequip", uids[1])
-- merge three of the same kind if we have them
local byKind = {}
for _, pet in prof.Pets do
	local k = pet.Id .. "/" .. tostring(pet.Tier or 1)
	byKind[k] = byKind[k] or {}
	table.insert(byKind[k], pet.Uid)
end
local merged = false
for _, list in byKind do
	if #list >= 3 then
		req("Merge", { list[1], list[2], list[3] })
		merged = true
		break
	end
end
if not merged then
	req("Merge", { uids[1], uids[2], uids[3] })
end
req("Delete", uids[#uids])
req("RollRank")
req("RollRank")
out("rank now: " .. tostring(prof.Rank) .. " ranks owned: " .. #prof.Ranks)
req("Rebirth")
req("BuyPerk", "Nope")
req("Nonsense")
out("client meta pets: " .. tostring(CS.Meta and CS.Meta.Pets and #CS.Meta.Pets))
-- Party pads: stand on one, then Create / StartNow.
local LB = M[R .. "ServerScriptService/Server/Services/LobbyBuilder.luau"]
local lobby = LB.GetLobby()
local pad = lobby and lobby.Pads and lobby.Pads[1]
out("pads: " .. tostring(lobby and lobby.Pads and #lobby.Pads))
local root = p.Character.HumanoidRootPart
root.CFrame = CFrame.new(pad.Zone.Position)
pump(2, G.frame)
out("on pad: party status = " .. tostring(CS.Party and CS.Party.Status))
local party = Remotes.Event("PartyAction")
local function pa(action, value)
	call("client", function()
		party:FireServer(action, value)
	end)
	pump(0.5, G.frame)
	out(string.format("party %-10s -> status=%s level=%s max=%s", action, tostring(CS.Party and CS.Party.Status), tostring(CS.Party and CS.Party.Level), tostring(CS.Party and CS.Party.MaxPlayers)))
end
pa("Create", { Level = 3, MaxPlayers = 2, Privacy = "Public" })
pa("Create", { Level = 1, MaxPlayers = 2, Privacy = "Public" })
pa("SetMax", 4)
pa("SetPrivacy", "Friends")
pa("StartNow")
pump(15, G.frame)
out("after StartNow: in run = " .. tostring(CS.Run ~= nil) .. " level " .. tostring(CS.Run and CS.Run.Level) .. " phase " .. tostring(CS.Run and CS.Run.Phase))
