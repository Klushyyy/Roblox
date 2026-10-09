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

-- The REFRESH plate under each board: anyone can press it (click, or the prompt) and redraw the boards; the same player has to
-- wait a few seconds before the next one.
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local toasts = {}
G.getSignal(Remotes.Event("Notify"), "OnClientEvent"):Connect(function(t, k) table.insert(toasts, tostring(t) .. " [" .. tostring(k) .. "]") end)
local plates = {}
for _, d in G.workspace:GetDescendants() do
	if d.Name == "BoardRefresh" and d:IsA("BasePart") then
		table.insert(plates, d)
	end
end
out("refresh plates under the boards: " .. #plates)
local plate = plates[1]
if plate then
	local det = plate:FindFirstChildOfClass("ClickDetector")
	local prompt = plate:FindFirstChildOfClass("ProximityPrompt")
	out("plate has a click detector: " .. tostring(det ~= nil) .. ", a prompt: " .. tostring(prompt ~= nil) .. " (" .. tostring(prompt and prompt.ActionText) .. ", key " .. tostring(prompt and prompt.KeyboardKeyCode) .. ")")
	if det then
		call("server", function() G.getSignal(det, "MouseClick"):Fire(p) end)
		pump(1, G.frame)
		out("1st press: " .. tostring(toasts[#toasts]))
		call("server", function() G.getSignal(det, "MouseClick"):Fire(p) end)
		pump(1, G.frame)
		out("2nd press right after: " .. tostring(toasts[#toasts]))
	end
	local other = plates[2]
	local prompt2 = other and other:FindFirstChildOfClass("ProximityPrompt")
	if prompt2 then
		local n = #toasts
		call("server", function() G.getSignal(prompt2, "Triggered"):Fire(G.victim) end)
		pump(1, G.frame)
		out("the other board's plate pressed by another player: nothing for us (their reply goes to their own screen): " .. tostring(#toasts == n))
	end
end
