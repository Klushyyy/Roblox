local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local prof = DS.Get(G.player)
prof.Gems = 500
DS.PushMeta(G.player)
pump(1, G.frame)
call("client", function() UIKit.OpenWindow("Ranks") end)
pump(0.5, G.frame)
local ranksGui = G.find(G.playerGui, "RanksUI")
local rollBtn
for _, d in ranksGui:GetDescendants() do
	if d.ClassName == "TextButton" and tostring(d.Text):find("^ROLL") then rollBtn = d end
end
out("roll button: " .. tostring(rollBtn and rollBtn.Text))
local function roll(tag)
	G.getSignal(rollBtn, "Activated"):Fire()
	pump(0.9, G.frame)
	local pg = G.find(G.playerGui, "RankRollPopup")
	out(tag .. " popup enabled=" .. tostring(pg and pg.Enabled))
	G.dumpGui(pg, OUT .. "roll_" .. tag .. "_spin.json")
	pump(5, G.frame)
	local panel = G.find(pg, "Panel")
	local title = G.find(panel, "Title")
	local rarity = G.find(panel, "Rarity")
	local buttons = G.find(panel, "Buttons")
	out(tag .. " after: title=" .. tostring(title.Text) .. " | " .. tostring(rarity.Text) .. " buttons=" .. tostring(buttons.Visible) .. " gems=" .. prof.Gems .. " rank=" .. prof.Rank)
	G.dumpGui(pg, OUT .. "roll_" .. tag .. "_end.json")
end
roll("a")
-- roll again from the popup
local again
for _, d in G.find(G.playerGui, "RankRollPopup"):GetDescendants() do
	if d.ClassName == "TextButton" and tostring(d.Text):find("Roll again") then again = d end
end
out("again button " .. tostring(again ~= nil))
G.getSignal(again, "Activated"):Fire()
pump(8, G.frame)
local pg = G.find(G.playerGui, "RankRollPopup")
out("roll again: title=" .. tostring(G.find(pg, "Title").Text) .. " | " .. tostring(G.find(pg, "Rarity").Text) .. " rank=" .. prof.Rank .. " gems=" .. prof.Gems)
