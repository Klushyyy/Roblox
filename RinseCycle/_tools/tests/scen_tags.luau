pump(2, G.frame)
for _, p in { G.player, G.victim } do
	local head = p.Character and p.Character:FindFirstChild("Head")
	local tag = head and head:FindFirstChild("NameTag")
	local hum = p.Character and p.Character:FindFirstChild("Humanoid")
	local labels = {}
	if tag then
		for _, d in G.methods.GetDescendants(tag) do
			if d.ClassName == "TextLabel" then
				table.insert(labels, d.Name .. "=" .. tostring(d.Text))
			end
		end
	end
	out(p.Name, "tag", tostring(tag ~= nil), "enabled", tostring(tag and tag.Enabled), "display", tostring(hum and hum.DisplayDistanceType), table.concat(labels, " | "))
end
