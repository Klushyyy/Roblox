-- Admin panel > Global: poll (vote, results banner), give everyone, pass drop, x2 boost.
local M = G.modules
local R = "/home/user/Roblox/RinseCycle/"
local DS = M[R .. "ServerScriptService/Server/Services/DataService.luau"]
local me, other = G.player, G.victim
pump(1, G.frame)
local RSt = G.ReplicatedStorage
local cmd = RSt:FindFirstChild("AdminCommand")
local feedback, banners = {}, {}
G.getSignal(RSt:FindFirstChild("AdminFeedback"), "OnClientEvent"):Connect(function(t) table.insert(feedback, t) end)
G.getSignal(RSt:FindFirstChild("AdminAnnouncement"), "OnClientEvent"):Connect(function(t) table.insert(banners, t) end)
local function asMe(c, t, x) call("client", function() cmd:FireServer(c, t or "", x or "") end) pump(0.5, G.frame) end
local function last() return feedback[#feedback] end
-- poll
asMe("globalpoll", "30", "Best level? | Pizzeria | Castle | Both")
out("poll: " .. tostring(last()))
local card = G.find(me.PlayerGui, "Poll")
out("poll card visible: " .. tostring(card and card.Visible))
local vote = RSt:FindFirstChild("GlobalPollVote")
local pollId
for _, d in card:GetDescendants() do end
-- vote as me (through the card's 2nd button) and as the other player directly
local answers = card:FindFirstChild("Answers")
local btns = {}
for _, b in answers:GetChildren() do if b:IsA("TextButton") then table.insert(btns, b) end end
table.sort(btns, function(a, b) return a.LayoutOrder < b.LayoutOrder end)
G.getSignal(btns[2], "Activated"):Fire()
pump(0.5, G.frame)
pump(40, G.frame)
out("card after end: " .. tostring(card.Visible))
out("results banner: " .. tostring(banners[#banners]))
out("admin got: " .. tostring(last()))
-- give everyone
local b0 = DS.Get(me).Bubbles
asMe("globalgive", "Bubbles", "250")
out(string.format("give: %s | bubbles %d -> %d (other %s)", tostring(last()), b0, DS.Get(me).Bubbles, tostring(DS.Get(other) and DS.Get(other).Bubbles)))
asMe("globalgive", "Rubies", "5")
out("bad give: " .. tostring(last()))
-- boost
asMe("globalboost", "10", "")
out(string.format("boost: %s | left %d s", tostring(last()), DS.Get(me).BoostUntil - os.time()))
-- pass drop
asMe("globalpassdrop", "2", "DoubleCoins")
pump(1, G.frame)
out("pass drop: " .. tostring(last()))
out("banner: " .. tostring(banners[#banners]))
out("me has DoubleCoins: " .. tostring(DS.GetPasses(me).DoubleCoins) .. ", other: " .. tostring(DS.Get(other) and DS.GetPasses(other).DoubleCoins))
