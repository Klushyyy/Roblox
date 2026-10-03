-- Lobby leaderboards: scrollable lists, each player's "you" row, the admin viewer's cache.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local LBS = M[R .. "ServerScriptService/Server/Services/LeaderboardService.luau"]
local p = G.player
local prof = DS.Get(p)
prof.Stats.DishesCleaned = 42
prof.BestTimes[1] = 75.3
pump(15, G.frame)
for _, id in { "D1", "D2", "D3", "T1", "T2" } do
	out(id .. " attr: " .. tostring(p:GetAttribute("Lb_" .. id)))
end
local gui = p.PlayerGui:FindFirstChild("SurfaceGui")
local moved = 0
for _, g in p.PlayerGui:GetChildren() do
	if g:IsA("SurfaceGui") then
		moved += 1
	end
end
out("board guis in PlayerGui: " .. moved)
for _, g in p.PlayerGui:GetChildren() do
	if g:IsA("SurfaceGui") then
		local page = g:FindFirstChild("Page1")
		local you = page and page:FindFirstChild("YouRow")
		local list = page and page:FindFirstChild("List")
		out(string.format("  %s adornee=%s list=%s rows=%d you=[%s | %s | %s]", g.Name, tostring(g.Adornee and g.Adornee.Name), list and list.ClassName or "-", list and #list:GetChildren() or 0,
			you and you.Rank.Text or "-", you and you.Player.Text or "-", you and you.Value.Text or "-"))
		local mine = list and list:FindFirstChild("Row1")
		out("  own row lit: " .. tostring(mine and mine.BackgroundTransparency))
	end
end
local t = os.clock()
local rows = LBS.ListBoard(1, 100)
out(string.format("admin ListBoard rows=%d first=%s in %.3fs", #rows, rows[1] and rows[1].Name or "-", os.clock() - t))
