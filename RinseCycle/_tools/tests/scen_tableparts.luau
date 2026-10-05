-- Lists every lobby part under the point where hole 1 is (to find the layers a hole must cut).
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local LB = M[R .. "ServerScriptService/Server/Services/LobbyBuilder.luau"]
pump(1, G.frame)
local model = LB.GetLobby().Model
local px, pz = 40, -30
for _, d in game:GetService("Workspace"):GetDescendants() do
	if d:IsA("BasePart") then
		local p, s = d.Position, d.Size
		if d.Name ~= "Terrain" and math.abs(p.X - px) < s.X / 2 + 1 and math.abs(p.Z - pz) < s.Z / 2 + 1 and p.Y < 3 and p.Y > -200 then
			print("LAYER", d.Name, d.ClassName, string.format("y=%.1f..%.1f size=%.0f,%.0f,%.0f collide=%s transp=%.1f", p.Y - s.Y / 2, p.Y + s.Y / 2, s.X, s.Y, s.Z, tostring(d.CanCollide), d.Transparency), d.Parent and d.Parent.Name)
		end
	end
end
