--[[
	ClubsUI - the Clubs window (HUD "Clubs" button, C key). Three tabs, like other games' clans:

	  CLUB       Not in one: make a club (name, tag, public / private, requirements, costs Gems) or
	             join one with a club code. In one: its banner (tag, name, points, members x / 25,
	             requirements, the club code), the members (online ones lit), and for the owner the
	             settings and Kick buttons. Leave at the bottom.
	  TOP CLUBS  The top 25 by points. Each row: FULL, INVITE ONLY, JOIN (requirements met) or YOURS.
	  FIND       Search by name or club code.

	Everything goes through ClubRequest (ClubService); ClubState pushes changes (kicked, joined).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Remotes = require(Shared:WaitForChild("Remotes"))

local Client = script.Parent
local ClientState = require(Client:WaitForChild("ClientState"))
local UIKit = require(Client:WaitForChild("UIKit"))

local ClubsUI = {}

local Colors = UIKit.Theme.Colors
local Fonts = UIKit.Theme.Fonts
local LocalPlayer = Players.LocalPlayer

local initialized = false
local busy = false
local tab = "Club"
local myClub: any = nil
local pages: { [string]: Frame } = {}
local tabButtons: { [string]: TextButton } = {}
local render: () -> ()

local function request(action: string, value: any?): any
	if busy then
		return { Ok = false, Error = "One moment..." }
	end
	busy = true
	local ok, result = pcall(function()
		return Remotes.Function("ClubRequest"):InvokeServer(action, value)
	end)
	busy = false
	if not ok or type(result) ~= "table" then
		return { Ok = false, Error = "Couldn't reach the server." }
	end
	return result
end

local function clear(frame: Instance)
	for _, child in frame:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function reqText(club: any): string
	local parts = {}
	if (club.ReqLevel or 0) > 0 then
		table.insert(parts, "Beat level " .. club.ReqLevel)
	end
	if (club.ReqRebirths or 0) > 0 then
		table.insert(parts, club.ReqRebirths .. " rebirths")
	end
	return if #parts > 0 then table.concat(parts, ", ") else "Anyone can join"
end

local function meetsReq(club: any): boolean
	local meta = ClientState.Meta :: any
	if not meta then
		return false
	end
	return (tonumber(meta.LevelsBeaten) or 0) >= (club.ReqLevel or 0) and (tonumber(meta.Rebirths) or 0) >= (club.ReqRebirths or 0)
end

local function textBox(parent: Instance, placeholder: string, props: { [string]: any }): TextBox
	local frame = UIKit.Card({ Color = Colors.PanelDark, Parent = parent })
	for k, v in props do
		(frame :: any)[k] = v
	end
	local box = Instance.new("TextBox")
	box.BackgroundTransparency = 1
	box.Size = UDim2.new(1, -20, 1, 0)
	box.Position = UDim2.fromOffset(10, 0)
	box.Font = Fonts.Title
	box.TextSize = 20
	box.TextColor3 = Colors.Text
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Colors.TextDim
	box.Text = ""
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Parent = frame
	return box
end

local function toast(result: any, good: string?)
	if result.Ok then
		UIKit.PlaySound("Sparkle")
		if result.Message or good then
			UIKit.Toast(result.Message or good, "Good")
		end
	else
		UIKit.Toast(result.Error or "Couldn't do that.", "Info")
	end
end

----------------------------------------------------------------------------------------------------
-- Club rows (TOP CLUBS and FIND)
----------------------------------------------------------------------------------------------------

local function clubRow(parent: Instance, club: any, order: number)
	local row = UIKit.Card({ Name = "ClubRow", Size = UDim2.new(1, -10, 0, 64), LayoutOrder = order, Parent = parent })
	if club.Mine then
		UIKit.Stroke(row, Colors.Coin, 3, 0)
	end
	local rankColor = if club.Rank == 1 then Colors.Coin elseif club.Rank == 2 then Color3.fromRGB(210, 220, 235) elseif club.Rank == 3 then Color3.fromRGB(230, 150, 90) else Colors.TextDim
	UIKit.Label({ Text = if club.Rank then "#" .. club.Rank else "", TextSize = 22, TextColor3 = rankColor, Position = UDim2.fromOffset(6, 0), Size = UDim2.fromOffset(50, 64), Parent = row })
	UIKit.Label({
		Text = string.format("[%s] %s", club.Tag, club.Name),
		TextSize = 20,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(60, 6),
		Size = UDim2.new(1, -330, 0, 28),
		Parent = row,
	})
	UIKit.Label({
		Text = string.format("%s pts  •  %d/%d  •  %s", UIKit.Commas(club.Points or 0), club.Count or 0, club.Max or Config.Clubs.MaxMembers, reqText(club)),
		TextSize = 14,
		TextScaled = true,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(60, 36),
		Size = UDim2.new(1, -330, 0, 20),
		Parent = row,
	})
	local full = (club.Count or 0) >= (club.Max or Config.Clubs.MaxMembers)
	local label, color, enabled
	if club.Mine then
		label, color, enabled = "YOURS", Colors.Coin, false
	elseif full then
		label, color, enabled = "FULL", Colors.Bad, false
	elseif not club.Public and not club.ByCode then
		label, color, enabled = "INVITE ONLY", Colors.Disabled, false
	elseif not meetsReq(club) then
		label, color, enabled = "LOCKED", Colors.Disabled, false
	else
		label, color, enabled = "JOIN", Colors.Good, true
	end
	local button = UIKit.Button({
		Text = label,
		Color = color,
		TextSize = 16,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -10, 0.5, 0),
		Size = UDim2.fromOffset(140, 44),
		Parent = row,
		OnClick = function()
			if not enabled then
				if label == "LOCKED" then
					UIKit.Toast("You don't meet this club's requirements yet: " .. reqText(club), "Info")
				elseif label == "INVITE ONLY" then
					UIKit.Toast("This club is private. Ask a member for the club code!", "Info")
				end
				return
			end
			task.spawn(function()
				local result = if club.ByCode then request("JoinCode", club.Code or "") else request("Join", club.Id)
				toast(result)
				if result.Ok then
					myClub = result.Club
					tab = "Club"
					render()
				end
			end)
		end,
	})
	if not enabled then
		button:SetAttribute("Disabled", label ~= "YOURS" and label ~= "FULL")
	end
	return row
end

local function scrollList(parent: Instance, top: number): ScrollingFrame
	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(0, top)
	list.Size = UDim2.new(1, 0, 1, -top)
	list.ScrollBarThickness = 8
	list.ScrollBarImageColor3 = Colors.Primary
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.new()
	list.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 4)
	pad.Parent = list
	return list
end

----------------------------------------------------------------------------------------------------
-- CLUB tab
----------------------------------------------------------------------------------------------------

-- A button that cycles through values: "Level: Anyone" -> "Level: Beat 1" -> ...
local function cycler(parent: Instance, values: { any }, format: (any) -> string, start: number, props: { [string]: any }): () -> any
	local index = start
	local button: TextButton
	button = UIKit.Button({
		Text = format(values[index]),
		Color = Colors.PanelLight,
		TextSize = 16,
		Parent = parent,
		OnClick = function()
			index = index % #values + 1
			local label = button:FindFirstChild("Label", true)
			if label and label:IsA("TextLabel") then
				label.Text = format(values[index])
			end
			button.Text = format(values[index])
		end,
	})
	for k, v in props do
		(button :: any)[k] = v
	end
	return function()
		return values[index]
	end
end

local function levelValues(): { number }
	local out = {}
	for i = 0, Config.Clubs.MaxLevelReq do
		table.insert(out, i)
	end
	return out
end

local REBIRTH_STEPS = { 0, 1, 2, 3, 5, 10, 15, 20, 30, 50 }

local function levelText(n: number): string
	return if n == 0 then "Level: anyone" else "Must beat level " .. n
end

local function rebirthText(n: number): string
	return if n == 0 then "Rebirths: any" else n .. "+ rebirths"
end

local function renderNoClub(page: Frame)
	local rules = Config.Clubs
	-- Create.
	local create = UIKit.Card({ Name = "Create", Color = Colors.PanelDark, Size = UDim2.new(0.6, -8, 1, 0), Parent = page })
	UIKit.Label({ Text = "MAKE A CLUB", TextSize = 22, TextColor3 = Colors.Coin, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 28), Parent = create })
	local nameBox = textBox(create, string.format("Club name (%d-%d letters)", rules.NameLength[1], rules.NameLength[2]), {
		Position = UDim2.fromOffset(16, 46),
		Size = UDim2.new(1, -32, 0, 48),
	})
	local tagBox = textBox(create, string.format("Tag (%d-%d)", rules.TagLength[1], rules.TagLength[2]), {
		Position = UDim2.fromOffset(16, 104),
		Size = UDim2.new(0.5, -22, 0, 48),
	})
	local getPublic = cycler(create, { true, false }, function(v)
		return if v then "Public" else "Private (code)"
	end, 1, { Position = UDim2.new(0.5, 6, 0, 104), Size = UDim2.new(0.5, -22, 0, 48) })
	local getLevel = cycler(create, levelValues(), levelText, 1, { Position = UDim2.fromOffset(16, 162), Size = UDim2.new(0.5, -22, 0, 48) })
	local getRebirths = cycler(create, REBIRTH_STEPS, rebirthText, 1, { Position = UDim2.new(0.5, 6, 0, 162), Size = UDim2.new(0.5, -22, 0, 48) })
	UIKit.Label({
		Text = string.format("Up to %d members. Members earn points for the club with every Bubble they collect.", rules.MaxMembers),
		TextSize = 14,
		TextWrapped = true,
		TextColor3 = Colors.TextDim,
		Position = UDim2.fromOffset(16, 220),
		Size = UDim2.new(1, -32, 0, 40),
		Parent = create,
	})
	UIKit.Button({
		Text = string.format("CREATE  (%d Gems)", rules.CreateCost),
		Color = Colors.Good,
		TextSize = 22,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.new(1, -32, 0, 56),
		Parent = create,
		OnClick = function()
			local meta = ClientState.Meta :: any
			if meta and (meta.Gems or 0) < rules.CreateCost then
				UIKit.Toast(string.format("You need %d Gems to make a club. Get more here!", rules.CreateCost), "Info")
				UIKit.OpenWindow("Shop", "Gems")
				return
			end
			task.spawn(function()
				local result = request("Create", {
					Name = nameBox.Text,
					Tag = tagBox.Text,
					Public = getPublic(),
					ReqLevel = getLevel(),
					ReqRebirths = getRebirths(),
				})
				toast(result)
				if result.Ok then
					UIKit.Confetti(80)
					myClub = result.Club
					render()
				end
			end)
		end,
	})

	-- Join with a code.
	local join = UIKit.Card({
		Name = "JoinCode",
		Color = Colors.PanelDark,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.4, -8, 0, 210),
		Parent = page,
	})
	UIKit.Label({ Text = "HAVE A CODE?", TextSize = 22, TextColor3 = Colors.Primary, Position = UDim2.fromOffset(0, 8), Size = UDim2.new(1, 0, 0, 28), Parent = join })
	UIKit.Label({ Text = "Private clubs are joined with their club code.", TextSize = 14, TextWrapped = true, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(12, 40), Size = UDim2.new(1, -24, 0, 36), Parent = join })
	local codeBox = textBox(join, "Club code", { Position = UDim2.fromOffset(16, 82), Size = UDim2.new(1, -32, 0, 48) })
	UIKit.Button({
		Text = "JOIN",
		Color = Colors.Primary,
		TextSize = 22,
		Position = UDim2.fromOffset(16, 142),
		Size = UDim2.new(1, -32, 0, 52),
		Parent = join,
		OnClick = function()
			task.spawn(function()
				local result = request("JoinCode", codeBox.Text)
				toast(result)
				if result.Ok then
					myClub = result.Club
					render()
				end
			end)
		end,
	})
	local browse = UIKit.Card({
		Name = "Browse",
		Color = Colors.PanelDark,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.fromScale(1, 1),
		Size = UDim2.new(0.4, -8, 1, -222),
		Parent = page,
	})
	UIKit.Label({ Text = "Or join a public club from TOP CLUBS or FIND.", TextSize = 15, TextWrapped = true, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(12, 10), Size = UDim2.new(1, -24, 0, 44), Parent = browse })
	UIKit.Button({
		Text = "TOP CLUBS",
		Color = Colors.Accent,
		TextSize = 18,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -12),
		Size = UDim2.new(1, -32, 0, 46),
		Parent = browse,
		OnClick = function()
			tab = "Top"
			render()
		end,
	})
end

local function renderMyClub(page: Frame, club: any)
	local isOwner = club.Owner == LocalPlayer.UserId
	-- Banner.
	local banner = UIKit.Card({ Name = "Banner", Size = UDim2.new(1, 0, 0, 112), Color = Colors.PanelDark, Parent = page })
	UIKit.Gradient(banner, Color3.fromRGB(40, 120, 200), Color3.fromRGB(14, 40, 90))
	local crest = UIKit.Icon("Club", 84, { Position = UDim2.fromOffset(14, 14) })
	crest.Parent = banner
	UIKit.Label({
		Text = string.format("[%s] %s", club.Tag, club.Name),
		TextSize = 28,
		TextScaled = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(110, 10),
		Size = UDim2.new(1, -330, 0, 34),
		Parent = banner,
	})
	UIKit.Label({
		Text = string.format("%s points  •  %d/%d members  •  %s", UIKit.Commas(club.Points or 0), club.Count or 0, club.Max, if club.Public then "Public" else "Private"),
		TextSize = 16,
		TextScaled = true,
		TextColor3 = Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(110, 48),
		Size = UDim2.new(1, -330, 0, 22),
		Parent = banner,
	})
	UIKit.Label({
		Text = "Requirements: " .. reqText(club),
		TextSize = 15,
		TextScaled = true,
		TextColor3 = Colors.Coin,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(110, 76),
		Size = UDim2.new(1, -330, 0, 20),
		Parent = banner,
	})
	-- The code, top right.
	local codeCard = UIKit.Card({
		Name = "Code",
		Color = Colors.PanelDark,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(200, 88),
		Parent = banner,
	})
	UIKit.Label({ Text = "CLUB CODE", TextSize = 14, TextColor3 = Colors.TextDim, Position = UDim2.fromOffset(0, 4), Size = UDim2.new(1, 0, 0, 18), Parent = codeCard })
	local codeText = Instance.new("TextBox") -- a read-only box, so it can be selected and copied
	codeText.Name = "CodeText"
	codeText.BackgroundTransparency = 1
	codeText.TextEditable = false
	codeText.ClearTextOnFocus = false
	codeText.Font = Fonts.Title
	codeText.TextSize = 28
	codeText.TextColor3 = Colors.Coin
	codeText.Text = club.Code or "------"
	codeText.Position = UDim2.fromOffset(0, 22)
	codeText.Size = UDim2.new(1, 0, 0, 32)
	codeText.Parent = codeCard
	if isOwner then
		UIKit.Button({
			Text = "New code",
			Color = Colors.PanelLight,
			TextSize = 13,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -4),
			Size = UDim2.fromOffset(110, 26),
			Parent = codeCard,
			OnClick = function()
				task.spawn(function()
					local result = request("NewCode")
					toast(result, "New club code made. The old one stops working.")
					if result.Ok then
						myClub = result.Club
						render()
					end
				end)
			end,
		})
	end

	-- Members.
	local membersCard = UIKit.Card({
		Name = "Members",
		Color = Colors.PanelDark,
		Position = UDim2.fromOffset(0, 124),
		Size = UDim2.new(if isOwner then 0.62 else 1, if isOwner then -8 else 0, 1, -124),
		Parent = page,
	})
	UIKit.Label({ Text = "MEMBERS", TextSize = 18, Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 22), Parent = membersCard })
	local list = scrollList(membersCard, 34)
	list.Size = UDim2.new(1, -12, 1, -94)
	list.Position = UDim2.fromOffset(6, 34)
	for i, m in club.Members or {} do
		local row = UIKit.Card({ Name = "Member", Size = UDim2.new(1, -10, 0, 40), LayoutOrder = i, Parent = list })
		local dot = Instance.new("Frame")
		dot.Size = UDim2.fromOffset(12, 12)
		dot.Position = UDim2.fromOffset(10, 14)
		dot.BackgroundColor3 = if m.Online then Colors.Good else Colors.Disabled
		UIKit.Corner(dot, 6)
		dot.Parent = row
		UIKit.Label({
			Text = m.Name .. (if m.Role == "Owner" then "  (Owner)" else ""),
			TextSize = 17,
			TextColor3 = if m.Role == "Owner" then Colors.Coin else Colors.Text,
			TextXAlignment = Enum.TextXAlignment.Left,
			Position = UDim2.fromOffset(30, 0),
			Size = UDim2.new(1, -130, 1, 0),
			Parent = row,
		})
		if isOwner and m.UserId ~= LocalPlayer.UserId then
			UIKit.Button({
				Text = "Kick",
				Color = Colors.Bad,
				TextSize = 14,
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -6, 0.5, 0),
				Size = UDim2.fromOffset(80, 30),
				Parent = row,
				OnClick = function()
					task.spawn(function()
						local result = request("Kick", m.UserId)
						toast(result, m.Name .. " was removed.")
						if result.Ok then
							myClub = result.Club
							render()
						end
					end)
				end,
			})
		end
	end
	UIKit.Button({
		Text = if isOwner and (club.Count or 0) <= 1 then "Close club" else "Leave club",
		Color = Colors.Bad,
		TextSize = 16,
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.fromOffset(180, 44),
		Parent = membersCard,
		OnClick = function()
			task.spawn(function()
				local result = request("Leave")
				toast(result)
				if result.Ok then
					myClub = nil
					render()
				end
			end)
		end,
	})

	-- Owner settings.
	if isOwner then
		local settings = UIKit.Card({
			Name = "Settings",
			Color = Colors.PanelDark,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, 0, 0, 124),
			Size = UDim2.new(0.38, -8, 1, -124),
			Parent = page,
		})
		UIKit.Label({ Text = "SETTINGS", TextSize = 18, Position = UDim2.fromOffset(0, 6), Size = UDim2.new(1, 0, 0, 22), Parent = settings })
		local function startIndex(values: { any }, current: any): number
			return table.find(values, current) or 1
		end
		local getPublic = cycler(settings, { true, false }, function(v)
			return if v then "Public" else "Private (code)"
		end, if club.Public then 1 else 2, { Position = UDim2.fromOffset(12, 38), Size = UDim2.new(1, -24, 0, 44) })
		local levels = levelValues()
		local getLevel = cycler(settings, levels, levelText, startIndex(levels, club.ReqLevel), { Position = UDim2.fromOffset(12, 90), Size = UDim2.new(1, -24, 0, 44) })
		local getRebirths = cycler(settings, REBIRTH_STEPS, rebirthText, startIndex(REBIRTH_STEPS, club.ReqRebirths), { Position = UDim2.fromOffset(12, 142), Size = UDim2.new(1, -24, 0, 44) })
		UIKit.Button({
			Text = "SAVE",
			Color = Colors.Good,
			TextSize = 18,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -10),
			Size = UDim2.new(1, -24, 0, 44),
			Parent = settings,
			OnClick = function()
				task.spawn(function()
					local result = request("Settings", { Public = getPublic(), ReqLevel = getLevel(), ReqRebirths = getRebirths() })
					toast(result, "Club settings saved.")
					if result.Ok then
						myClub = result.Club
						render()
					end
				end)
			end,
		})
	end
end

----------------------------------------------------------------------------------------------------
-- Tabs
----------------------------------------------------------------------------------------------------

local function loading(page: Frame)
	UIKit.Label({ Name = "Loading", Text = "Loading...", TextSize = 22, TextColor3 = Colors.TextDim, Size = UDim2.fromScale(1, 1), Parent = page })
end

local renderToken = 0

render = function()
	renderToken += 1
	local token = renderToken
	for name, b in tabButtons do
		UIKit.SetButtonColor(b, if name == tab then Colors.Primary else Colors.PanelLight)
	end
	for name, page in pages do
		page.Visible = name == tab
	end
	local page = pages[tab]
	clear(page)
	if tab == "Club" then
		if myClub then
			renderMyClub(page, myClub)
		else
			renderNoClub(page)
		end
	elseif tab == "Top" then
		loading(page)
		task.spawn(function()
			local result = request("Top")
			if token ~= renderToken then
				return
			end
			clear(page)
			local list = scrollList(page, 0)
			if not result.Ok or #(result.Clubs or {}) == 0 then
				UIKit.Label({ Text = if result.Ok then "No clubs yet. Be the first to make one!" else (result.Error or "Couldn't load clubs."), TextSize = 20, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 60), Parent = list })
				return
			end
			for i, club in result.Clubs do
				clubRow(list, club, i)
			end
		end)
	elseif tab == "Find" then
		local box = textBox(page, "Club name or code", { Size = UDim2.new(1, -160, 0, 50) })
		local results = scrollList(page, 62)
		local function search()
			task.spawn(function()
				clear(results)
				local result = request("Find", box.Text)
				if token ~= renderToken then
					return
				end
				if not result.Ok then
					UIKit.Toast(result.Error or "Couldn't search.", "Info")
					return
				end
				if #(result.Clubs or {}) == 0 then
					UIKit.Label({ Text = "No clubs found.", TextSize = 20, TextColor3 = Colors.TextDim, Size = UDim2.new(1, 0, 0, 60), Parent = results })
				end
				for i, club in result.Clubs do
					clubRow(results, club, i)
				end
			end)
		end
		box.FocusLost:Connect(function(enter)
			if enter then
				search()
			end
		end)
		UIKit.Button({
			Text = "FIND",
			Color = Colors.Primary,
			TextSize = 20,
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			Size = UDim2.fromOffset(148, 50),
			Parent = page,
			OnClick = search,
		})
	end
end

function ClubsUI.Init()
	if initialized then
		return
	end
	initialized = true

	local _gui, screenRoot = UIKit.CreateScreen("ClubsUI", 10)
	local _window, content = UIKit.Window({
		Name = "Clubs",
		Title = "Clubs",
		Size = Vector2.new(900, 580),
		Parent = screenRoot,
	})
	local tabsRow = Instance.new("Frame")
	tabsRow.Name = "Tabs"
	tabsRow.BackgroundTransparency = 1
	tabsRow.Size = UDim2.new(1, 0, 0, 46)
	tabsRow.Parent = content
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 10)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabsRow
	for i, def in { { "Club", "CLUB" }, { "Top", "TOP CLUBS" }, { "Find", "FIND" } } do
		tabButtons[def[1]] = UIKit.Button({
			Text = def[2],
			Color = Colors.PanelLight,
			TextSize = 18,
			Size = UDim2.fromOffset(170, 44),
			LayoutOrder = i,
			Parent = tabsRow,
			OnClick = function()
				tab = def[1]
				render()
			end,
		})
		local page = Instance.new("Frame")
		page.Name = def[1] .. "Page"
		page.BackgroundTransparency = 1
		page.Position = UDim2.fromOffset(0, 58)
		page.Size = UDim2.new(1, 0, 1, -58)
		page.Visible = false
		page.Parent = content
		pages[def[1]] = page
	end

	UIKit.RegisterWindow("Clubs", {
		Open = function()
			render()
			-- Then the real state from the server (it may have changed elsewhere).
			task.spawn(function()
				local result = request("Mine")
				if result.Ok then
					local changed = (myClub == nil) ~= (result.Club == nil)
					myClub = result.Club
					if changed or tab == "Club" then
						render()
					end
				end
			end)
		end,
	})
	Remotes.Event("ClubState").OnClientEvent:Connect(function(club)
		myClub = club
		if UIKit.IsWindowOpen("Clubs") and tab == "Club" then
			render()
		end
	end)
end

return ClubsUI
