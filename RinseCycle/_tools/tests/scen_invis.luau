local p = G.player
local AC = G.find(G.ReplicatedStorage, "AdminCommand")
G.workspace.CurrentCamera.CFrame = CFrame.new(0, 20, 30)
local function tagInfo(label)
	local tagObj = G.find(p.Character, "NameTag")
	if not tagObj then
		out(label .. ": no NameTag")
		return
	end
	local head = p.Character:FindFirstChild("Head")
	out(string.format("%s: tag Enabled=%s hidden-attr=%s head-transparency=%s", label, tostring(tagObj.Enabled), tostring(p.Character:GetAttribute("AdminHidden")), tostring(head.Transparency)))
end
local function invis()
	call("server", function() G.getSignal(AC, "OnServerEvent"):Fire(p, "invis", p.Name, "") end)
	pump(1, G.frame)
end
pump(1, G.frame)
tagInfo("before")
invis()
tagInfo("invisible")
invis()
tagInfo("visible again")
-- invisible, then respawn (going into a run / back to the lobby)
invis()
tagInfo("invisible (2)")
local newChar = Instance.new("Model")
newChar.Name = p.Name
local h = Instance.new("Humanoid"); h.Parent = newChar
local root = Instance.new("Part"); root.Name = "HumanoidRootPart"; root.Parent = newChar
local head = Instance.new("Part"); head.Name = "Head"; head.Transparency = 0; head.Parent = newChar
newChar.PrimaryPart = root
newChar.Parent = G.workspace
p.Character = newChar
call("server", function() G.getSignal(p, "CharacterAdded"):Fire(newChar) end)
pump(2, G.frame)
tagInfo("after respawn")
invis()
tagInfo("toggled after respawn")
invis()
tagInfo("toggled again")
