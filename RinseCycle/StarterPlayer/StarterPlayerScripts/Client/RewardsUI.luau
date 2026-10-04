--[[
	RewardsUI - two small windows opened from the buttons on the left of the lobby HUD.

	  * "Codes" (🎟️): type a code (Config.Codes) and redeem it. "Look out for codes in the game's
	    description and our community!"
	  * "Free" (🎉 Free Rewards), one reward each (Config.Social):
	      - Join the community: JOIN opens Roblox's own join prompt in game
	        (GroupService:PromptJoinAsync); as soon as it closes, the server checks membership live
	        and pays out. No rejoin needed.
	      - Follow the dev / Favorite the game: the button checks straight away (SocialService). A
	        follow Roblox can't show yet says to leave and rejoin (it's re-checked on join).
]]

local AvatarEditorService = game:GetService("AvatarEditorService")
local ExperienceNotificationService = game:GetService("ExperienceNotificationService")
local GroupService = game:GetService("GroupService")
local SocialService = game:GetService("SocialService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Types = require(Shared:WaitForChild("Types"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local Colors = UIKit.Theme.Colors
local Fonts = UIKit.Theme.Fonts
local LocalPlayer = Players.LocalPlayer

local RewardsUI = {}

local initialized = false
local busy = false
local groupButton: TextButton
local groupStatus: TextLabel
local socialRows: { [string]: { Button: TextButton, Status: TextLabel } } = {}

----------------------------------------------------------------------------------------------------
-- Codes
----------------------------------------------------------------------------------------------------

local function buildCodes(screenRoot: Instance)
	local _window, content = UIKit.Window({
		Name = "Codes",
		Title = "Codes",
		Icon = "🎟️",
		Size = Vector2.new(560, 320),
		Parent = screenRoot,
	})
	UIKit.Label({
		Text = "Look out for codes in the game's description and in our community!",
		TextSize = 18,
		TextWrapped = true,
		TextColor3 = Colors.TextDim,
		Size = UDim2.new(1, -30, 0, 48),
		Position = UDim2.new(0.5, 0, 0, 4),
		AnchorPoint = Vector2.new(0.5, 0),
		Parent = content,
	})
	local boxFrame = UIKit.Card({
		Size = UDim2.new(1, -60, 0, 60),
		Position = UDim2.new(0.5, 0, 0, 62),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.PanelDark,
		Parent = content,
	})
	local box = Instance.new("TextBox")
	box.Name = "CodeBox"
	box.BackgroundTransparency = 1
	box.Size = UDim2.new(1, -24, 1, 0)
	box.Position = UDim2.fromOffset(12, 0)
	box.Font = Fonts.Title
	box.TextSize = 26
	box.TextColor3 = Colors.Text
	box.PlaceholderText = "Enter code..."
	box.PlaceholderColor3 = Colors.TextDim
	box.Text = ""
	box.ClearTextOnFocus = false
	box.Parent = boxFrame
	local function redeem()
		if busy then
			return
		end
		local text = box.Text
		if text == "" then
			box:CaptureFocus()
			return
		end
		busy = true
		local result = ClientState.MetaRequest("RedeemCode", text)
		busy = false
		if result.Ok then
			box.Text = ""
			UIKit.PlaySound("Sparkle")
			UIKit.Confetti(40)
			UIKit.Toast("Code redeemed: " .. (result.Message or "") .. "!", "Good")
		else
			UIKit.Toast(result.Error or "That code doesn't work.", "Bad")
		end
	end
	box.FocusLost:Connect(function(enterPressed)
		if enterPressed then
			task.spawn(redeem)
		end
	end)
	UIKit.Button({
		Text = "REDEEM",
		Size = UDim2.fromOffset(220, 56),
		Position = UDim2.new(0.5, 0, 0, 140),
		AnchorPoint = Vector2.new(0.5, 0),
		Color = Colors.Good,
		TextSize = 26,
		Parent = content,
		OnClick = function()
			task.spawn(redeem)
		end,
	})
	UIKit.RegisterWindow("Codes", {})
end

----------------------------------------------------------------------------------------------------
-- Free rewards
----------------------------------------------------------------------------------------------------

local function refreshGroup()
	local meta = ClientState.Meta :: Types.MetaState?
	local claimed = meta ~= nil and meta.GroupReward == true
	groupButton.Text = if claimed then "Claimed" else "JOIN & CLAIM"
	UIKit.SetButtonColor(groupButton, if claimed then Colors.Disabled else Colors.Good)
	groupStatus.Text = if claimed then "Thanks for joining!" else "Reward: " .. Config.RewardText(Config.Social.GroupReward)
end

local function refreshSocial()
	local meta = ClientState.Meta :: Types.MetaState?
	for kind, rowParts in socialRows do
		local state = if meta then (if kind == "Follow" then meta.FollowState else meta.LikeState) else ""
		local reward = if kind == "Follow" then Config.Social.FollowReward else Config.Social.LikeReward
		if state == "Claimed" then
			rowParts.Button.Text = "Claimed"
			UIKit.SetButtonColor(rowParts.Button, Colors.Disabled)
			rowParts.Status.Text = "Thank you!"
		elseif state == "Pending" then
			rowParts.Button.Text = "Check again"
			UIKit.SetButtonColor(rowParts.Button, Colors.Warning)
			rowParts.Status.Text = "Not working? Leave and rejoin."
		else
			rowParts.Button.Text = if kind == "Follow" then "I followed!" else "Favorite & Like"
			UIKit.SetButtonColor(rowParts.Button, Colors.Good)
			rowParts.Status.Text = "Reward: " .. Config.RewardText(reward :: any)
		end
	end
end

-- Favorite: is the game favorited on this account? If not, Roblox's own favorite prompt, then
-- check again. Returns true only when Roblox says it's favorited.
local function favoriteGame(): boolean
	local placeId = game.PlaceId
	if placeId == 0 then
		return false
	end
	local function isFavorited(): boolean
		local ok, result = pcall(function()
			return AvatarEditorService:GetFavorite(placeId, Enum.AvatarItemType.Asset)
		end)
		return ok and result == true
	end
	if isFavorited() then
		return true
	end
	local done = false
	local conn = AvatarEditorService.PromptSetFavoriteCompleted:Connect(function()
		done = true
	end)
	local ok = pcall(function()
		AvatarEditorService:PromptSetFavorite(placeId, Enum.AvatarItemType.Asset, true)
	end)
	local waited = 0
	while ok and not done and waited < 60 do
		waited += task.wait(0.2)
	end
	conn:Disconnect()
	task.wait(0.5)
	return isFavorited()
end

local function markDone(kind: string)
	local meta = ClientState.Meta :: Types.MetaState?
	local state = if meta then (if kind == "Follow" then meta.FollowState else meta.LikeState) else ""
	if busy or state == "Claimed" then
		return
	end
	busy = true
	local row = socialRows[kind]
	if row then
		row.Button.Text = "Checking..."
	end
	if kind == "Favorite" and not favoriteGame() then
		busy = false
		UIKit.Toast("Favorite and like the game to get this reward!", "Info")
		refreshSocial()
		return
	end
	local result = ClientState.MetaRequest("SocialDone", kind)
	busy = false
	if result.Ok then
		UIKit.PlaySound("Sparkle")
		UIKit.Confetti(50)
		UIKit.Toast(result.Message or "Reward claimed!", "Good")
	else
		UIKit.Toast(result.Error or "Couldn't do that.", "Info")
	end
	refreshSocial()
end

local function socialButton(parent: Frame, kind: string)
	local button = UIKit.Button({
		Text = "",
		Size = UDim2.fromOffset(210, 52),
		Position = UDim2.new(1, -14, 0.5, -10),
		AnchorPoint = Vector2.new(1, 0.5),
		Color = Colors.Good,
		TextSize = 20,
		Parent = parent,
		OnClick = function()
			task.spawn(markDone, kind)
		end,
	})
	local status = UIKit.Label({ Text = "", TextSize = 15, TextColor3 = Colors.Coin, Size = UDim2.fromOffset(230, 20), Position = UDim2.new(1, -4, 1, -8), AnchorPoint = Vector2.new(1, 1), Parent = parent })
	socialRows[kind] = { Button = button, Status = status }
end

local function joinGroup()
	local meta = ClientState.Meta :: Types.MetaState?
	if busy or (meta and meta.GroupReward) then
		return
	end
	local groupId = Config.GetGroupId()
	if groupId <= 0 then
		UIKit.Toast("The community isn't set up yet!", "Info")
		return
	end
	busy = true
	-- Already a member? Claim straight away. Otherwise Roblox's join prompt, in game; when it
	-- closes (joined or not), ask the server to check.
	local result = ClientState.MetaRequest("ClaimGroup")
	if not result.Ok then
		pcall(function()
			GroupService:PromptJoinAsync(groupId)
		end)
		result = ClientState.MetaRequest("ClaimGroup")
	end
	busy = false
	if result.Ok then
		UIKit.PlaySound("Sparkle")
		UIKit.Confetti(60)
		UIKit.Toast("Welcome to the community! " .. (result.Message or ""), "Good")
	else
		UIKit.Toast(result.Error or "Join the community first, then claim!", "Info")
	end
	refreshGroup()
end

local function card(parent: Instance, order: number, icon: string, title: string, body: string): Frame
	local c = UIKit.Card({
		Size = UDim2.new(1, -24, 0, 104),
		LayoutOrder = order,
		Color = Colors.PanelLight,
		Parent = parent,
	})
	UIKit.Label({ Text = icon, TextSize = 44, Size = UDim2.fromOffset(70, 70), Position = UDim2.new(0, 10, 0.5, 0), AnchorPoint = Vector2.new(0, 0.5), Stroke = false, Parent = c })
	UIKit.Label({ Name = "Title", Text = title, TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -330, 0, 30), Position = UDim2.fromOffset(88, 12), Parent = c })
	UIKit.Label({ Name = "Body", Text = body, TextSize = 16, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextColor3 = Colors.TextDim, Size = UDim2.new(1, -330, 0, 52), Position = UDim2.fromOffset(88, 44), Parent = c })
	return c
end

local function buildFree(screenRoot: Instance)
	local _window, content = UIKit.Window({
		Name = "Free",
		Title = "Free Rewards",
		Icon = "🎉",
		Size = Vector2.new(720, 470),
		Parent = screenRoot,
	})
	-- Scrolls: five reward cards don't all fit at once.
	local list = Instance.new("ScrollingFrame")
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Size = UDim2.new(1, 0, 1, 0)
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollBarThickness = 8
	list.ScrollBarImageColor3 = Colors.Primary
	list.Parent = content
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = list
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 12)
	layout.Parent = list

	-- Community (the real reward).
	local group = card(list, 1, "👥", "Join our community", "Join the Rinse Cycle community for a free reward, news and codes!")
	groupButton = UIKit.Button({
		Text = "JOIN & CLAIM",
		Size = UDim2.fromOffset(210, 52),
		Position = UDim2.new(1, -14, 0.5, -10),
		AnchorPoint = Vector2.new(1, 0.5),
		Color = Colors.Good,
		TextSize = 20,
		Parent = group,
		OnClick = function()
			task.spawn(joinGroup)
		end,
	})
	groupStatus = UIKit.Label({ Text = "", TextSize = 15, TextColor3 = Colors.Coin, Size = UDim2.fromOffset(230, 20), Position = UDim2.new(1, -4, 1, -8), AnchorPoint = Vector2.new(1, 1), Parent = group })

	-- "Favorite & Like the game". Only the favorite is checked (on this device); likes can't be
	-- checked by any game, so the text asks for both.
	if Config.Social.LikeReward then
		local fav = card(list, 2, "⭐", "Favorite & Like the game", "Favorite and like the game, then tap the button. We check it straight away.")
		socialButton(fav, "Favorite")
	end

	-- Follow the dev (their headshot and name): follow, tap the button, rejoin (checked on join).
	local creatorId = Config.Social.CreatorUserId
	local follow = card(list, 3, "", "Follow the dev", "Follow on their Roblox profile, then tap the button to check.")
	local shot = Instance.new("ImageLabel")
	shot.BackgroundTransparency = 1
	shot.Size = UDim2.fromOffset(70, 70)
	shot.Position = UDim2.new(0, 10, 0.5, 0)
	shot.AnchorPoint = Vector2.new(0, 0.5)
	shot.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", creatorId)
	shot.Parent = follow
	UIKit.Corner(shot, 35)
	socialButton(follow, "Follow")
	task.spawn(function()
		local ok, name = pcall(function()
			return Players:GetNameFromUserIdAsync(creatorId)
		end)
		if ok and type(name) == "string" then
			local title = follow:FindFirstChild("Title")
			if title and title:IsA("TextLabel") then
				title.Text = "Follow @" .. name
			end
		end
	end)

	-- Invite friends (Roblox's invite prompt; the invite carries your UserId so the game knows who
	-- brought them in: SocialService pays you both when a NEW player joins through it).
	local referral = Config.Social.ReferralReward
	local invite = card(list, 4, "🤝", "Invite friends", string.format("A friend who's new joins from your invite: you get %s, they get %s.", Config.RewardText(referral), Config.RewardText(Config.Social.ReferredReward)))
	UIKit.Button({
		Text = "INVITE",
		Size = UDim2.fromOffset(210, 52),
		Position = UDim2.new(1, -14, 0.5, -10),
		AnchorPoint = Vector2.new(1, 0.5),
		Color = Colors.Good,
		TextSize = 20,
		Parent = invite,
		OnClick = function()
			RewardsUI.Invite()
		end,
	})
	local inviteStatus = UIKit.Label({ Text = "", TextSize = 15, TextColor3 = Colors.Coin, Size = UDim2.fromOffset(230, 20), Position = UDim2.new(1, -4, 1, -8), AnchorPoint = Vector2.new(1, 1), Parent = invite })
	local function refreshInvite()
		local meta = ClientState.Meta :: any
		local n = meta and tonumber(meta.Referrals) or 0
		inviteStatus.Text = if n > 0 then string.format("Friends joined: %d", n) else ""
	end

	-- Notifications: Roblox's own opt-in prompt (experience notifications, e.g. "your daily reward is
	-- ready"). Roblox decides when it may be shown again.
	local notify = card(list, 5, "🔔", "Turn on notifications", "Get a Roblox notification when your next daily reward is ready.")
	UIKit.Button({
		Text = "NOTIFY ME",
		Size = UDim2.fromOffset(210, 52),
		Position = UDim2.new(1, -14, 0.5, -10),
		AnchorPoint = Vector2.new(1, 0.5),
		Color = Colors.Primary,
		TextSize = 20,
		Parent = notify,
		OnClick = function()
			task.spawn(function()
				if RewardsUI.PromptNotifications() == "AlreadyOn" then
					UIKit.Toast("Notifications are already on!", "Info")
				end
			end)
		end,
	})

	UIKit.RegisterWindow("Free", {
		Open = function()
			refreshGroup()
			refreshSocial()
			refreshInvite()
		end,
	})
	ClientState.Changed:Connect(function(kind)
		if kind == "Meta" and UIKit.IsWindowOpen("Free") then
			refreshGroup()
			refreshSocial()
			refreshInvite()
		end
	end)
end

-- Roblox's notification opt-in prompt, if Roblox allows it right now. `fromButton`: say so when
-- it can't be shown (already on, or asked too recently).
-- Shows Roblox's notification opt-in. Returns "Asked" (the pop-up was shown) or "AlreadyOn" (can't
-- ask: they're on already, or Roblox won't ask again yet). The CALLER says something about it, once.
-- Opens Roblox's invite prompt; the invite carries your UserId so a new friend who joins through it
-- counts for you (rewards in Free, and +luck in Ranks).
function RewardsUI.Invite()
	task.spawn(function()
		local okCan, can = pcall(function()
			return SocialService:CanSendGameInviteAsync(LocalPlayer)
		end)
		if okCan and can == false then
			UIKit.Toast("Invites aren't available on this account.", "Info")
			return
		end
		local ok = pcall(function()
			local options = Instance.new("ExperienceInviteOptions")
			options.PromptMessage = "Come clean dishes with me in Rinse Cycle!"
			options.LaunchData = tostring(LocalPlayer.UserId)
			SocialService:PromptGameInvite(LocalPlayer, options)
		end)
		if not ok then
			UIKit.Toast("Couldn't open the invite. Try again!", "Info")
		end
	end)
end

function RewardsUI.PromptNotifications(): string
	local okCan, can = pcall(function()
		return ExperienceNotificationService:CanPromptOptInAsync()
	end)
	if okCan and can then
		pcall(function()
			ExperienceNotificationService:PromptOptIn()
		end)
		return "Asked"
	end
	return "AlreadyOn"
end

function RewardsUI.Init()
	if initialized then
		return
	end
	initialized = true
	local _gui, screenRoot = UIKit.CreateScreen("RewardsUI", 11)
	buildCodes(screenRoot)
	buildFree(screenRoot)
end

return RewardsUI
