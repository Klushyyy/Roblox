-- NameTags: the overhead tag every player wears: their name (with a ✨N badge once they've
-- rebirthed) and their rank underneath in its rarity colour ("🧽 Trainee" until they roll one).
--
-- Sizing is what makes or breaks overhead GUIs, so the rules are:
--   * the BillboardGui is sized in STUDS (UDim2 scale), so it behaves like a real object: it
--     shrinks with distance exactly like the character does and never covers the screen;
--   * text is TextScaled inside fixed rows, capped by UITextSizeConstraint, so zooming right in
--     can't blow it up, and a long name shrinks to fit instead of spilling;
--   * it sits a fixed height above the head in WORLD space (StudsOffsetWorldSpace), so head bobs,
--     emotes and ragdolls never swing it around;
--   * it fades out past MaxDistance, and Roblox's own name display is turned off so there's
--     never a second name.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local DataService = require(script.Parent:WaitForChild("DataService"))

local NameTags = {}

local TAG_WIDTH_STUDS = 7
local TAG_HEIGHT_STUDS = 1.9
local HEIGHT_ABOVE_HEAD = 2.1
local MAX_DISTANCE = 90
local NAME_MAX_TEXT = 30
local RANK_MAX_TEXT = 24
local DEFAULT_RANK = { Icon = "🧽", Name = "Trainee", Color = Color3.fromRGB(200, 205, 215) }

local function makeLabel(name: string, parent: Instance, y: number, h: number, maxText: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromScale(0, y)
	label.Size = UDim2.fromScale(1, h)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Text = ""
	local limit = Instance.new("UITextSizeConstraint")
	limit.MaxTextSize = maxText
	limit.MinTextSize = 1
	limit.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Color3.fromRGB(15, 25, 45)
	stroke.Transparency = 0.15
	stroke.Parent = label
	label.Parent = parent
	return label
end

local function textFor(player: Player): (string, string, Color3)
	local profile = DataService.Get(player)
	local rebirths = (profile and tonumber(profile.Rebirths)) or 0
	local name = player.DisplayName
	if rebirths > 0 then
		name = string.format("✨%d  %s", rebirths, name)
	end
	local rank = profile and Config.GetRank(profile.Rank)
	if rank then
		local rarity = Config.RankRarities[rank.Rarity]
		return name, rank.Icon .. " " .. rank.Name, if rarity then rarity.Color else DEFAULT_RANK.Color
	end
	return name, DEFAULT_RANK.Icon .. " " .. DEFAULT_RANK.Name, DEFAULT_RANK.Color
end

-- The player list shows everyone's rebirths (leaderstats).
local function updateLeaderstats(player: Player)
	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		stats = Instance.new("Folder")
		stats.Name = "leaderstats"
		stats.Parent = player
	end
	local value = stats:FindFirstChild("✨ Rebirths")
	if not value then
		value = Instance.new("IntValue")
		value.Name = "✨ Rebirths"
		value.Parent = stats
	end
	local profile = DataService.Get(player)
	;(value :: IntValue).Value = (profile and tonumber(profile.Rebirths)) or 0
end

local function refresh(player: Player)
	pcall(updateLeaderstats, player)
	local character = player.Character
	local head = character and character:FindFirstChild("Head")
	local tag = head and head:FindFirstChild("NameTag")
	if not tag then
		return
	end
	local nameText, rankText, rankColor = textFor(player)
	local nameLabel = tag:FindFirstChild("PlayerName", true)
	local rankLabel = tag:FindFirstChild("Rank", true)
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = nameText
	end
	if rankLabel and rankLabel:IsA("TextLabel") then
		rankLabel.Text = rankText
		rankLabel.TextColor3 = rankColor
	end
end

local function attach(player: Player, character: Model)
	local head = character:WaitForChild("Head", 10)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not head or not head:IsA("BasePart") or character.Parent == nil then
		return
	end
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	local old = head:FindFirstChild("NameTag")
	if old then
		old:Destroy()
	end
	local tag = Instance.new("BillboardGui")
	tag.Name = "NameTag"
	tag.Adornee = head
	tag.Size = UDim2.fromScale(TAG_WIDTH_STUDS, TAG_HEIGHT_STUDS)
	tag.StudsOffsetWorldSpace = Vector3.new(0, HEIGHT_ABOVE_HEAD, 0)
	tag.MaxDistance = MAX_DISTANCE
	tag.AlwaysOnTop = false
	tag.LightInfluence = 0
	makeLabel("PlayerName", tag, 0, 0.56, NAME_MAX_TEXT)
	makeLabel("Rank", tag, 0.56, 0.44, RANK_MAX_TEXT)
	tag.Parent = head
	refresh(player)
end

local function watch(player: Player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(attach, player, character)
	end)
	if player.Character then
		task.spawn(attach, player, player.Character)
	end
	player:GetPropertyChangedSignal("DisplayName"):Connect(function()
		refresh(player)
	end)
end

function NameTags.Init()
	-- Rank rolls and rebirths both fire PassesChanged (they change run stats too).
	DataService.PassesChanged:Connect(refresh)
	DataService.ProfileLoaded:Connect(function(player)
		refresh(player)
	end)
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
end

return NameTags
