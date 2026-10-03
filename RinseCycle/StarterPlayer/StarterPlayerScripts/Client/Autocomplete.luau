--[[
	Autocomplete - Minecraft-style suggestions for a TextBox (the admin command line and name boxes).

	While the box is focused, a list of suggestions sits right above (or below) it: what the word
	you're typing can become, plus a usage line. Tab puts the highlighted suggestion in (and never
	types a tab character); Up / Down move the highlight; clicking one puts it in too. Enter does
	whatever the box normally does.

	Autocomplete.Attach(box, provider, options) -> detach()
	  provider(text) -> { Usage: string?, Items: { { Text: string, Hint: string? } }, Replace: number }
	    Items complete the word being typed: it starts at character Replace (1-based) and runs to the
	    end of the text. Return Items = {} when there's nothing to suggest.
	  options.Above: list above the box (default) or below; options.Parent: where the list lives
	  (default: the box's ScreenGui root), options.MaxItems (default 8).
]]

local UserInputService = game:GetService("UserInputService")

local Client = script.Parent
local UIKit = require(Client:WaitForChild("UIKit"))

local Autocomplete = {}

local Colors = UIKit.Theme.Colors
local Fonts = UIKit.Theme.Fonts

local ROW_H = 26

export type Item = { Text: string, Hint: string? }
export type Result = { Usage: string?, Items: { Item }, Replace: number }

-- The words of a command line, and where the last one starts (1-based). A trailing space starts a
-- new, empty word.
function Autocomplete.Split(text: string): ({ string }, number)
	local words = {}
	local lastStart = 1
	local i = 1
	while i <= #text do
		local s, e = string.find(text, "%S+", i)
		if not s then
			break
		end
		table.insert(words, string.sub(text, s, e))
		lastStart = s
		i = (e :: number) + 1
	end
	if #text == 0 or string.match(text, "%s$") then
		table.insert(words, "")
		lastStart = #text + 1
	end
	return words, lastStart
end

-- Items from a list of candidates that start with `prefix` (any case), A to Z.
-- `keepOrder`: leave them in the order given (durations, numbered options) instead of A to Z.
function Autocomplete.Match(prefix: string, candidates: { Item }, keepOrder: boolean?): { Item }
	local lower = string.lower(prefix)
	local out = {}
	for _, c in candidates do
		if string.sub(string.lower(c.Text), 1, #lower) == lower and string.lower(c.Text) ~= lower then
			table.insert(out, c)
		end
	end
	if not keepOrder then
		table.sort(out, function(a, b)
			return string.lower(a.Text) < string.lower(b.Text)
		end)
	end
	return out
end

function Autocomplete.Attach(box: TextBox, provider: (string) -> Result, options: { [string]: any }?): () -> ()
	local opts: any = options or {}
	local maxItems = opts.MaxItems or 8
	local above = opts.Above ~= false
	local connections: { RBXScriptConnection } = {}

	local list = Instance.new("Frame")
	list.Name = "Suggestions"
	list.BackgroundColor3 = Colors.Ink
	list.BackgroundTransparency = 0.1
	list.BorderSizePixel = 0
	list.Visible = false
	list.ZIndex = 200
	list.AutomaticSize = Enum.AutomaticSize.Y
	UIKit.Corner(list, 8)
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = list

	local items: { Item } = {}
	local replaceAt = 1
	local selected = 1
	local applying = false
	local appliedAt = 0

	local function place()
		local parent = list.Parent :: GuiObject?
		if not parent or not parent:IsA("GuiObject") then
			return
		end
		local scale = UIKit.GetScale()
		local boxPos = (box.AbsolutePosition - parent.AbsolutePosition) / scale
		local boxSize = box.AbsoluteSize / scale
		list.Size = UDim2.fromOffset(math.max(260, boxSize.X), 0)
		if above then
			list.AnchorPoint = Vector2.new(0, 1)
			list.Position = UDim2.fromOffset(boxPos.X - 10, boxPos.Y - 8)
		else
			list.AnchorPoint = Vector2.new(0, 0)
			list.Position = UDim2.fromOffset(boxPos.X - 10, boxPos.Y + boxSize.Y + 8)
		end
	end

	local function apply(item: Item?)
		local pick = item or items[selected]
		if not pick then
			return
		end
		applying = true
		local text = string.gsub(box.Text, "\t", "")
		local before = string.sub(text, 1, replaceAt - 1)
		box.Text = before .. pick.Text .. " "
		box.CursorPosition = #box.Text + 1
		applying = false
		appliedAt = os.clock()
	end

	local function redraw(usage: string?)
		for _, c in list:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local order = 0
		local function row(text: string, hint: string?, isSelected: boolean, item: Item?)
			order += 1
			local r = Instance.new("TextButton")
			r.Name = "Row"
			r.AutoButtonColor = false
			r.Text = ""
			r.LayoutOrder = order
			r.Size = UDim2.new(1, 0, 0, ROW_H)
			r.BackgroundColor3 = Colors.Primary
			r.BackgroundTransparency = if isSelected then 0.55 else 1
			r.ZIndex = 201
			UIKit.Corner(r, 6)
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.new(1, -8, 1, 0)
			label.Position = UDim2.fromOffset(4, 0)
			label.Font = Fonts.Body
			label.TextSize = 16
			label.RichText = true
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.TextTruncate = Enum.TextTruncate.AtEnd
			label.TextColor3 = if item then Colors.Text else Colors.TextDim
			local safe = string.gsub(string.gsub(string.gsub(text, "&", "&amp;"), "<", "&lt;"), ">", "&gt;")
			local safeHint = if hint then string.gsub(string.gsub(string.gsub(hint, "&", "&amp;"), "<", "&lt;"), ">", "&gt;") else nil
			label.Text = if safeHint then string.format('%s  <font color="#%s">%s</font>', safe, Colors.TextDim:ToHex(), safeHint) else safe
			label.ZIndex = 202
			label.Parent = r
			if item then
				r.Activated:Connect(function()
					apply(item)
					box:CaptureFocus()
				end)
			end
			r.Parent = list
		end
		if usage and usage ~= "" then
			row(usage, nil, false, nil)
		end
		for i = 1, math.min(#items, maxItems) do
			row(items[i].Text, items[i].Hint, i == selected, items[i])
		end
		if #items > maxItems then
			row(string.format("... and %d more (keep typing)", #items - maxItems), nil, false, nil)
		end
		list.Visible = box:IsFocused() and order > 0
		place()
	end

	local function refresh()
		local ok, result = pcall(provider, box.Text)
		if not ok or type(result) ~= "table" then
			items = {}
			redraw(nil)
			return
		end
		items = result.Items or {}
		replaceAt = result.Replace or (#box.Text + 1)
		selected = math.clamp(selected, 1, math.max(1, math.min(#items, maxItems)))
		redraw(result.Usage)
	end

	table.insert(connections, box:GetPropertyChangedSignal("Text"):Connect(function()
		if applying then
			return
		end
		-- Tab: complete, and never leave a tab character behind.
		if string.find(box.Text, "\t", 1, true) then
			applying = true
			box.Text = string.gsub(box.Text, "\t", "")
			applying = false
			-- Suggestions for exactly what's typed now, then complete with the top one.
			selected = 1
			refresh()
			if #items > 0 then
				apply(nil)
			end
			selected = 1
			refresh()
			return
		end
		selected = 1
		refresh()
	end))
	table.insert(connections, box.Focused:Connect(function()
		if list.Parent == nil then
			local screen = box:FindFirstAncestorWhichIsA("ScreenGui")
			local root = opts.Parent or (screen and screen:FindFirstChild("Root")) or screen
			list.Parent = root
		end
		selected = 1
		refresh()
	end))
	table.insert(connections, box.FocusLost:Connect(function()
		-- A moment later, so a click on a suggestion still lands.
		task.delay(0.15, function()
			if not box:IsFocused() then
				list.Visible = false
			end
		end)
	end))
	table.insert(connections, UserInputService.InputBegan:Connect(function(input)
		if not box:IsFocused() or #items == 0 then
			return
		end
		local shown = math.min(#items, maxItems)
		if input.KeyCode == Enum.KeyCode.Down then
			selected = selected % shown + 1
			refresh()
		elseif input.KeyCode == Enum.KeyCode.Up then
			selected = (selected - 2) % shown + 1
			refresh()
		elseif input.KeyCode == Enum.KeyCode.Tab then
			-- Some platforms don't type the tab into the box: complete here instead.
			task.defer(function()
				if os.clock() - appliedAt > 0.1 and not string.find(box.Text, "\t", 1, true) and #items > 0 then
					apply(nil)
					selected = 1
					refresh()
				end
			end)
		end
	end))

	return function()
		for _, c in connections do
			c:Disconnect()
		end
		list:Destroy()
	end
end

return Autocomplete
