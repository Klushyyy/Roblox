-- Admin command line: Minecraft-style suggestions, Tab completes, no tab character left.
local p = G.player
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
pump(2, G.frame)
call("client", function()
	UIKit.OpenWindow("Admin")
end)
pump(1, G.frame)
local line
for _, d in p.PlayerGui:GetDescendants() do
	if d.Name == "CommandLine" then
		line = d
	end
end
out("command line: " .. tostring(line ~= nil))
G.getSignal(line, "Focused"):Fire()
local function show(label)
	pump(0.3, G.frame)
	local rows = {}
	for _, d in p.PlayerGui:GetDescendants() do
		if d.Name == "Suggestions" then
			for _, r in d:GetChildren() do
				if r.Name == "Row" then
					local l = r:FindFirstChildWhichIsA("TextLabel")
					table.insert(rows, (string.gsub(l.Text, "<[^>]+>", "")))
				end
			end
		end
	end
	out(string.format("%-16s text=%q -> %s", label, line.Text, table.concat(rows, " / ")))
end
line.Text = "glo"
show("typed glo")
line.Text = "glo\t"
show("tab")
line.Text = "ki"
show("typed ki")
line.Text = "kick "
show("kick + space")
line.Text = "kick V\t"
show("kick V + tab")
line.Text = "tempban Victim "
show("tempban arg 2")
line.Text = "globalgive G"
show("globalgive G")
