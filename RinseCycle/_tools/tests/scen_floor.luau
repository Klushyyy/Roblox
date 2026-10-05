-- Touching the room floor (or anywhere below the table) always sends you back to the spawn, show or not.
pump(1, G.frame)
local root = G.player.Character and G.player.Character:FindFirstChild("HumanoidRootPart")
if not root then
	print("floor test: no character")
else
	root.CFrame = CFrame.new(120, -127, -300) -- standing on the room floor
	pump(1.5, G.frame)
	print("after touching the floor: y =", math.floor(root.Position.Y), "(should be near the table, > -20)")
end
