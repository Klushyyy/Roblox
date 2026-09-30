local hud = G.find(G.playerGui, "HUD")
local col = G.find(hud, "RightColumn")
pump(1, G.frame)
for _, c in G.methods.GetChildren(col) do
	if c.ClassName == "TextButton" then
		out(string.format("%s visible=%s order=%s size=%s", c.Name, tostring(c.Visible), tostring(c.LayoutOrder), tostring(c.Size)))
	end
end
out("column visible " .. tostring(col.Visible) .. " pos " .. tostring(col.Position))
