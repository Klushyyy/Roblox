-- Staff tiers: give / change / clear, what each tier can run, the tags, the staff list.
local me, other = G.player, G.victim
pump(1, G.frame)
local RSt = G.ReplicatedStorage
local cmd = RSt:FindFirstChild("AdminCommand")
local info = RSt:FindFirstChild("GetAdminInfo")
local feedback = {}
G.getSignal(RSt:FindFirstChild("AdminFeedback"), "OnClientEvent"):Connect(function(t) table.insert(feedback, t) end)
local function asMe(c, t, x) call("client", function() cmd:FireServer(c, t or "", x or "") end) pump(0.3, G.frame) end
local function asOther(c, t, x)
	local before = #feedback
	call("server", function() G.getSignal(cmd, "OnServerEvent"):Fire(other, c, t or "", x or "") end)
	pump(0.3, G.frame)
end
local function tierOf(p)
	local i
	call("server", function() i = G.getSignal(info, "OnServerInvoke") end)
	local fn = rawget(info, "OnServerInvoke") or info.OnServerInvoke
	local r = fn(p)
	return r and r.Tier, r and #r.Commands or 0
end
local infoChanged = 0
G.getSignal(RSt:FindFirstChild("AdminInfoChanged"), "OnClientEvent"):Connect(function() infoChanged += 1 end)
for _, t in { "Moderator", "Admin", "Developer", "clear" } do
	asMe("setadminrank", "Victim", t)
	local tier, n = tierOf(other)
	out(string.format("%-10s -> tier %s (%d commands), tag %s  | %s", t, tostring(tier), n, tostring(other:GetAttribute("StaffTag")), feedback[#feedback]))
end
asMe("setadminrank", "Victim", "Moderator")
out("owner tag: " .. tostring(me:GetAttribute("StaffTag")))
-- a Moderator can't use commands on the owner (they're above them)
asOther("kick", "EnderBuilda", "test")
out("owner still here after a Moderator's kick: " .. tostring(me.Parent ~= nil))
local list
G.getSignal(RSt:FindFirstChild("AdminStaffList"), "OnClientEvent"):Connect(function(title, rows) list = { title, rows } end)
asMe("stafflist")
out("staff list: " .. tostring(list and list[1]) .. " -> " .. tostring(list and list[2][1] and list[2][1].Line1))
call("server", function() G.getSignal(RSt:FindFirstChild("AdminStaffAction"), "OnServerEvent"):Fire(me, "Remove", other.UserId) end)
pump(0.5, G.frame)
out("after Remove: " .. tostring(list and list[1]) .. ", victim tier " .. tostring((tierOf(other))) .. ", tag " .. tostring(other:GetAttribute("StaffTag")))
