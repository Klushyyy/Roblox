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

-- The Refresh chip: near a board a small "Refresh" button sits at a fixed place on the screen (key X, D-pad up on a controller,
-- a tap on a phone); there is no plate or second prompt on the board any more. The same player has to wait between presses.
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local toasts = {}
G.getSignal(Remotes.Event("Notify"), "OnClientEvent"):Connect(function(t, k) table.insert(toasts, tostring(t) .. " [" .. tostring(k) .. "]") end)
local leftover = 0
for _, d in G.workspace:GetDescendants() do
	if d.Name == "BoardRefresh" and d:IsA("BasePart") then leftover += 1 end
	if d:IsA("ProximityPrompt") and d.ActionText == "Refresh" then leftover += 1 end
end
out("refresh plates / prompts left on the boards (should be 0): " .. leftover)
local board = G.find(G.workspace, "Board")
local UIS = game:GetService("UserInputService")
local function chipGui() return G.find(p.PlayerGui, "RefreshChip") end
local UK = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
call("client", function() UK.CloseWindow() end) -- (a window that opened by itself, like the daily reward, hides the chip: it would cover it)
p.Character.HumanoidRootPart.CFrame = CFrame.new(1000, 5, 1000)
pump(1, G.frame)
out("chip far from a board visible (false): " .. tostring(chipGui() and chipGui().Visible))
p.Character.HumanoidRootPart.CFrame = board.CFrame * CFrame.new(0, -5, 15)
pump(1, G.frame)
local chip = chipGui()
out("chip near a board visible (true): " .. tostring(chip and chip.Visible))
local button
for _, d in (chip and chip:GetDescendants() or {}) do
	if d.ClassName == "TextButton" and d.Text == "Refresh" then button = d end
end
if button then
	G.getSignal(button, "Activated"):Fire()
	pump(1, G.frame)
	out("tap on the chip: " .. tostring(toasts[#toasts]) .. "  button now reads: " .. tostring(button.Text))
end
-- X (and D-pad up) press it too, after the client's own short pause
pump(4, G.frame)
local n = #toasts
call("client", function() G.getSignal(UIS, "InputBegan"):Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.X, UserInputState = Enum.UserInputState.Begin }, false) end)
pump(1, G.frame)
out("X key: " .. tostring(toasts[#toasts]) .. "  (new reply: " .. tostring(#toasts > n) .. ")")
pump(4, G.frame)
n = #toasts
call("client", function() G.getSignal(UIS, "InputBegan"):Fire({ UserInputType = Enum.UserInputType.Gamepad1, KeyCode = Enum.KeyCode.DPadUp, UserInputState = Enum.UserInputState.Begin }, false) end)
pump(1, G.frame)
out("D-pad up: " .. tostring(toasts[#toasts]) .. "  (new reply: " .. tostring(#toasts > n) .. ")")
