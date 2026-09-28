local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local UIKit = M[R .. "StarterPlayer/StarterPlayerScripts/Client/UIKit.luau"]
local OUT = "/tmp/claude-0/-home-user-Roblox/67dd3176-afb1-5006-8add-987c78895cff/scratchpad/gui/"
local kinds = { "Coin", "Bubble", "Gem", "Drop", "Gift", "Ticket", "Heart", "Paw", "Cart", "Medal", "Shield", "Lock", "Pasta", "Pizza", "Crown" }
local sg = Instance.new("ScreenGui")
for i, kind in kinds do
	local col = (i - 1) % 8
	local row = (i - 1) // 8
	local x = 16 + col * 150
	local y = 16 + row * 210
	local big = UIKit.Icon(kind, 120)
	big.Position = UDim2.fromOffset(x, y)
	big.Parent = sg
	local mid = UIKit.Icon(kind, 48)
	mid.Position = UDim2.fromOffset(x + 4, y + 140)
	mid.Parent = sg
	local small = UIKit.Icon(kind, 28)
	small.Position = UDim2.fromOffset(x + 70, y + 150)
	small.Parent = sg
end
G.dumpGui(sg, OUT .. "icons.json")
out("dumped")
