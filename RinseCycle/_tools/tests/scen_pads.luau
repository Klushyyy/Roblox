local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local CS = M[R .. "StarterPlayer/StarterPlayerScripts/Client/ClientState.luau"]
local LB = M[R .. "ServerScriptService/Server/Services/LobbyBuilder.luau"]
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local pad = LB.GetLobby().Pads[1]
local me, other = G.player, G.victim
local myRoot, otherRoot = me.Character.HumanoidRootPart, other.Character.HumanoidRootPart
local function put(root, cf)
	root.CFrame = cf
end
local function status(tag)
	out(string.format("[%5.2fs] %-34s my party: %-8s  other in party: %s", _G.__now - 1000, tag, tostring(CS.Party and CS.Party.Status), tostring(other:GetAttribute("InParty"))))
end
local party = Remotes.Event("PartyAction")
local function act(a, v)
	call("client", function()
		party:FireServer(a, v)
	end)
end
local t0 = _G.__now
put(myRoot, CFrame.new(pad.Zone.Position))
local waited = 0
while not (CS.Party and CS.Party.Status == "Picking") and waited < 3 do
	pump(1 / 30, G.frame)
	waited += 1 / 30
end
out(string.format("menu opened after %.2fs", waited))
status("host stepped in")
put(otherRoot, CFrame.new(pad.Zone.Position + Vector3.new(2, 0, 0)))
pump(0.5, G.frame)
status("other walked in while picking")
out("other pushed out: " .. tostring((otherRoot.Position - pad.Zone.Position).Magnitude > 4))
act("Create", { Level = 1, MaxPlayers = 4, Privacy = "Public" })
pump(0.3, G.frame)
status("after Create")
put(otherRoot, CFrame.new(pad.Zone.Position + Vector3.new(2, 0, 0)))
pump(0.5, G.frame)
status("other walked in after create")
-- Back: out, and straight back in.
act("Leave")
pump(0.15, G.frame)
status("host pressed Back")
out("host outside the pad: " .. tostring((myRoot.Position - pad.Zone.Position).Magnitude > 4))
-- simulate the character still reporting its old spot for a moment after the teleport
put(myRoot, CFrame.new(pad.Zone.Position))
pump(0.3, G.frame)
status("stale position right after Back")
put(myRoot, CFrame.new(pad.Zone.Position + Vector3.new(40, 0, 0)))
pump(0.5, G.frame)
status("walked away")
put(myRoot, CFrame.new(pad.Zone.Position))
waited = 0
while not (CS.Party and CS.Party.Status) and waited < 3 do
	pump(1 / 30, G.frame)
	waited += 1 / 30
end
out(string.format("walked back in: party again after %.2fs", waited))
status("re-entered")
-- Walking about inside the pad: the whole round floor is theirs. (The old held box was the entry square plus 1.5, smaller
-- than the circle along its sides, so walking toward the wall along an axis sent you back to the middle.)
local center = pad.Zone.Position
local rad = pad.Radius or 9
local function flatFrom(v)
	return math.sqrt((v.X - center.X) ^ 2 + (v.Z - center.Z) ^ 2)
end
local function xzDist(a, b)
	return math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
end
status("before walking about")
for _, spot in { Vector3.new(rad - 0.7, 0, 0), Vector3.new(-(rad - 0.7), 0, 0), Vector3.new(0, 0, rad - 0.7), Vector3.new(0, 0, -(rad - 0.7)) } do
	put(myRoot, CFrame.new(center + spot))
	pump(2, G.frame)
	out(string.format("near the wall at (%+.1f, %+.1f): moved %.1f studs (should be 0), still in my party: %s", spot.X, spot.Z, xzDist(myRoot.Position, center + spot), tostring(CS.Party ~= nil)))
end
-- Through the wall: put back at the nearest bit of the floor (about 2 studs in from the edge), not the middle
put(myRoot, CFrame.new(center + Vector3.new(rad + 6, 0, 0)))
pump(2, G.frame)
out(string.format("outside the walls: now %.1f studs from the middle (radius %.1f; near the edge, not 0)", flatFrom(myRoot.Position), rad))
status("after being put back")

-- Launch: the screen must be black before the character is teleported into the dishwasher.
local Cutscene = M[R .. "StarterPlayer/StarterPlayerScripts/Client/Cutscene.luau"]
act("Leave")
pump(1, G.frame)
put(myRoot, CFrame.new(pad.Zone.Position + Vector3.new(40, 0, 0)))
pump(1, G.frame)
put(myRoot, CFrame.new(LB.GetLobby().Pads[2].Zone.Position))
pump(0.4, G.frame)
act("Create", { Level = 1, MaxPlayers = 2, Privacy = "Public" })
pump(0.2, G.frame)
act("StartNow")
local startPos = myRoot.Position
local coverAtMove = nil
local fadeGui = G.find(G.playerGui, "Cutscene")
local fade = fadeGui and G.find(fadeGui, "Fade")
for i = 1, 30 * 12 do
	pump(1 / 30, G.frame)
	if coverAtMove == nil and (myRoot.Position - startPos).Magnitude > 50 then
		coverAtMove = fade and fade.BackgroundTransparency
		out(string.format("teleported into the run at %.2fs; fade transparency then = %s (0 = fully black), covered=%s", i / 30, tostring(coverAtMove), tostring(Cutscene.IsCovered() or Cutscene.IsPlaying())))
	end
end
out("in run: " .. tostring(CS.Run ~= nil) .. "  cutscene playing: " .. tostring(Cutscene.IsPlaying()))
