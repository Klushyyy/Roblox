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

-- The chips: near a board "Next page" and "Refresh" sit side by side at a fixed place on the screen (Next page: F, X on a controller;
-- Refresh: X, D-pad up on a controller; a tap on a phone) and fade in / out with the distance; there is no plate or proximity prompt
-- on the boards any more. The same player has to wait between Refresh presses.
local Remotes = M[R .. "ReplicatedStorage/Shared/Remotes.luau"]
local toasts = {}
G.getSignal(Remotes.Event("Notify"), "OnClientEvent"):Connect(function(t, k) table.insert(toasts, tostring(t) .. " [" .. tostring(k) .. "]") end)
local leftover = 0
for _, d in G.workspace:GetDescendants() do
	if d.Name == "BoardRefresh" and d:IsA("BasePart") then leftover += 1 end
	if d:IsA("ProximityPrompt") and (d.ActionText == "Refresh" or d.ActionText == "Next page") then leftover += 1 end
end
out("refresh plates / prompts left on the boards (should be 0): " .. leftover)
local CS = game:GetService("CollectionService")
local board = CS:GetTagged("LeaderboardBoard")[1]
local UIS = game:GetService("UserInputService")
local function chipGui() return G.find(p.PlayerGui, "Chips") end
local UK = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
call("client", function() UK.CloseWindow() end) -- (a window that opened by itself, like the daily reward, hides the chips: it would cover them)
local function chipState(label)
	local chip = chipGui()
	out(string.format("%s: visible=%s groupTransparency=%.2f", label, tostring(chip and chip.Visible), chip and chip.GroupTransparency or -1))
end
p.Character.HumanoidRootPart.CFrame = CFrame.new(1000, 5, 1000)
pump(40, G.frame)
chipState("far from the boards (hidden)")
p.Character.HumanoidRootPart.CFrame = board.CFrame * CFrame.new(0, -5, 37)
pump(60, G.frame)
chipState("37 studs from a board (half faded)")
p.Character.HumanoidRootPart.CFrame = board.CFrame * CFrame.new(0, -5, 15)
pump(60, G.frame)
chipState("15 studs from a board (all the way in)")
local chip = chipGui()
local refreshButton, nextButton
for _, d in (chip and chip:GetDescendants() or {}) do
	if d.ClassName == "TextButton" and d.Text == "Refresh" then refreshButton = d end
	if d.ClassName == "TextButton" and d.Text == "Next page" then nextButton = d end
end
out("both chips there: refresh=" .. tostring(refreshButton ~= nil) .. " next=" .. tostring(nextButton ~= nil))
if refreshButton and nextButton then
	local rx, nx = refreshButton.Parent.Position.X.Offset, nextButton.Parent.Position.X.Offset
	out(string.format("next page at x=%d, refresh at x=%d (side by side, next on the left: %s)", nx, rx, tostring(nx < rx and rx - nx >= nextButton.Parent.Size.X.Offset)))
end
-- which page of the board is showing
local boardGui
for _, g in p.PlayerGui:GetChildren() do
	if g:IsA("SurfaceGui") and g.Adornee == board then boardGui = g end
end
local function shownPage()
	for i = 1, 5 do
		local page = boardGui and boardGui:FindFirstChild("Page" .. i)
		if page and page.Visible then return i end
	end
	return 0
end
out("board page before: " .. shownPage())
if nextButton then
	G.getSignal(nextButton, "Activated"):Fire()
	pump(1, G.frame)
	out("tap on Next page -> page " .. shownPage())
end
call("client", function() G.getSignal(UIS, "InputBegan"):Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.F, UserInputState = Enum.UserInputState.Begin }, false) end)
pump(1, G.frame)
out("F key -> page " .. shownPage())
call("client", function() G.getSignal(UIS, "InputBegan"):Fire({ UserInputType = Enum.UserInputType.Gamepad1, KeyCode = Enum.KeyCode.ButtonX, UserInputState = Enum.UserInputState.Begin }, false) end)
pump(1, G.frame)
out("controller X -> page " .. shownPage())
if refreshButton then
	G.getSignal(refreshButton, "Activated"):Fire()
	pump(1, G.frame)
	out("tap on Refresh: " .. tostring(toasts[#toasts]) .. "  button now reads: " .. tostring(refreshButton.Text))
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
-- walking away fades them out again, and the keys do nothing once they are gone
p.Character.HumanoidRootPart.CFrame = CFrame.new(1000, 5, 1000)
pump(80, G.frame)
chipState("walked away (hidden again)")
local before = shownPage()
call("client", function() G.getSignal(UIS, "InputBegan"):Fire({ UserInputType = Enum.UserInputType.Keyboard, KeyCode = Enum.KeyCode.F, UserInputState = Enum.UserInputState.Begin }, false) end)
pump(1, G.frame)
out("F key far away leaves the page alone: " .. tostring(shownPage() == before))
