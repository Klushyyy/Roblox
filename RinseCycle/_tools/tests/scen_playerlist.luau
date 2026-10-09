-- The player list: always at most four rows tall (scrolls beyond), the HUD's right column keeps a fixed space under it and does
-- not move with the number of players, Tab toggles it, and it steps aside in a run.
local p = G.player
local UIS = game:GetService("UserInputService")
call("client", function()
	UIS.TouchEnabled = false
	UIS.KeyboardEnabled = true
	UIS.MouseEnabled = true
end)
pump(1.5, G.frame)
local list = G.find(G.find(p.PlayerGui, "PlayerList"), "Panel")
local column = G.find(p.PlayerGui, "RightColumn")
local function status(tag)
	local rows = 0
	local scroll = list and list:FindFirstChild("List")
	for _, d in (scroll and scroll:GetChildren() or {}) do
		if d.Name == "Row" then rows += 1 end
	end
	out(string.format("%s: players %d, rows %d, panel visible %s, panel height %s, list height %s, right column y %s, reserve %s, roblox list off flag %s",
		tag, #G.Players:GetPlayers(), rows, tostring(list and list.Visible), tostring(list and list.Size.Y.Offset), tostring(scroll and scroll.Size.Y.Offset),
		tostring(column and column.Position.Y.Offset), tostring(p:GetAttribute("PlayerListHeight")), tostring(p:GetAttribute("CustomPlayerList"))))
end
status("2 players")
for i = 1, 8 do
	local d = Instance.new("Player")
	d.Name = "Guest" .. i
	d.UserId = 9000 + i
	d.Parent = G.Players
end
pump(1.5, G.frame)
status("10 players")
-- Tab closes and opens it
local function tab()
	call("client", function() G.getSignal(UIS, "InputBegan"):Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.Tab, UserInputState = Enum.UserInputState.Begin }, false) end)
	pump(1, G.frame)
end
tab()
status("after Tab (closed)")
tab()
status("after Tab again (open)")
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
G.dumpGui(G.find(p.PlayerGui, "PlayerList"), OUT .. "playerlist.json")
G.dumpGui(G.find(p.PlayerGui, "HUD"), OUT .. "playerlist_hud.json")
