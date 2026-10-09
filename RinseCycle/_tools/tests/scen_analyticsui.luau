-- The analytics reports in the admin window: a tab per report, a days button, summary cards, bars and big numbers. The rows are
-- made up here (the real ones are built by Analytics.BuildReport, see scen_analytics); dumps for guirender.py.
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local p = G.player
local RS = game:GetService("ReplicatedStorage")
local function size(w, h)
	local probe = p.PlayerGui:FindFirstChild("UIKitProbeFull")
	call("client", function()
		probe.AbsoluteSize = Vector2.new(w, h)
		G.getSignal(probe, "AbsoluteSize"):Fire()
	end)
	pump(1.5, G.frame)
end
size(1280, 720)
local tabs = { "Overview", "New players", "Coming back", "Leaving", "Runs", "Features", "Money", "Devices", "Show" }
local rows = {
	{ Line1 = "New players who joined for the first time in the last 7 days", Line2 = "Each bar is how many players got to that step, compared with the first step.", Kind = "head" },
	{ Line1 = "412 players started, 131 got all the way to the end (32%)", Line2 = 'Biggest drop: step 4, "Walked into a party pad". Only 54% of the players before it got there (108 lost).', Kind = "note", Tone = "bad" },
	{ Line1 = "1. Joined the game", Line2 = "Everyone starts here", Right = "412", RightSub = "100% of the first", Bar = 1, Tone = "good" },
	{ Line1 = "2. Screen finished loading", Line2 = "96% of the step before  -  16 lost", Right = "396", RightSub = "96% of the first", Bar = 0.96, Tone = "good" },
	{ Line1 = "3. Moved or pressed a control", Line2 = "91% of the step before  -  36 lost", Right = "360", RightSub = "87% of the first", Bar = 0.87, Tone = "good" },
	{ Line1 = "4. Walked into a party pad   <- biggest drop", Line2 = "54% of the step before  -  108 lost", Right = "252", RightSub = "61% of the first", Bar = 0.61, Tone = "bad" },
	{ Line1 = "5. Party launched", Line2 = "81% of the step before  -  48 lost", Right = "204", RightSub = "50% of the first", Bar = 0.5, Tone = "good" },
	{ Line1 = "6. Cleared a dishwasher", Line2 = "64% of the step before  -  73 lost", Right = "131", RightSub = "32% of the first", Bar = 0.32, Tone = "warn" },
}
local sent = {}
G.getSignal(RS:FindFirstChild("AdminServerAction"), "OnServerEvent"):Connect(function(_, action, a) table.insert(sent, tostring(action) .. ":" .. tostring(a)) end)
call("server", function() RS:FindFirstChild("AdminReport"):FireClient(p, "What new players do  (last 7 days)", rows, 2, 9, 7, tabs) end)
pump(2, G.frame)
local panel = p.PlayerGui:FindFirstChild("AdminPanel")
local lv = G.find(panel, "ListView")
local tabsRow = G.find(lv, "Tabs")
local names = {}
for _, d in (tabsRow and tabsRow:GetDescendants() or {}) do if d.ClassName == "TextButton" and d.Text ~= "" then table.insert(names, d.Text) end end
out("list view visible=" .. tostring(lv and lv.Visible) .. "  tabs: " .. table.concat(names, " | "))
local days
for _, d in lv:GetDescendants() do if d.ClassName == "TextButton" and (d.Text == "7 days" or d.Text == "30 days" or d.Text == "Today") then days = d end end
out("days button: " .. tostring(days and days.Text))
local retentionTab
for _, d in (tabsRow and tabsRow:GetDescendants() or {}) do if d.ClassName == "TextButton" and d.Text == "Coming back" then retentionTab = d end end
if retentionTab then G.getSignal(retentionTab, "Activated"):Fire(); pump(1, G.frame) end
if days then G.getSignal(days, "Activated"):Fire(); pump(1, G.frame) end
out("tapped Coming back, then the days button: " .. table.concat(sent, ", "))
call("server", function() RS:FindFirstChild("AdminReport"):FireClient(p, "What new players do  (last 7 days)", rows, 2, 9, 7, tabs) end)
pump(2, G.frame)
G.dumpGui(panel, OUT .. "analytics_funnel_pc.json")
size(844, 390)
G.dumpGui(panel, OUT .. "analytics_funnel_land.json")
