-- The game's own player list: invisible admins are left out (staff see them marked hidden).
local me, other = G.player, G.victim
pump(1.5, G.frame)
local gui = G.find(G.playerGui, "PlayerList")
local function rows()
	local names = {}
	for _, d in G.find(gui, "List"):GetDescendants() do
		if d.ClassName == "TextLabel" and d.Position.X.Scale == 0 and d.Position.X.Offset == 6 then
			table.insert(names, (tostring(d.Text):gsub("<[^>]+>", "")))
		end
	end
	return table.concat(names, " | ")
end
out("everyone visible: " .. rows())
other:SetAttribute("AdminInvis", true)
pump(1.2, G.frame)
out("victim hidden, I'm staff: " .. rows())
local tag = me:GetAttribute("StaffTag")
me:SetAttribute("StaffTag", nil)
pump(1.2, G.frame)
out("victim hidden, I'm a normal player: " .. rows())
me:SetAttribute("StaffTag", tag)
other:SetAttribute("AdminInvis", nil)
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
pump(1.2, G.frame)
G.dumpGui(gui, OUT .. "plist.json")
-- admin serverlist
local got
G.getSignal(G.ReplicatedStorage:FindFirstChild("AdminServerList"), "OnClientEvent"):Connect(function(t, r, b) got = { t, r } end)
call("client", function() G.ReplicatedStorage:FindFirstChild("AdminCommand"):FireServer("serverlist", "", "") end)
pump(1, G.frame)
out("serverlist: " .. tostring(got and got[1]) .. " -> " .. tostring(got and got[2][1] and (got[2][1].Line1 .. " / " .. got[2][1].Line2)))
