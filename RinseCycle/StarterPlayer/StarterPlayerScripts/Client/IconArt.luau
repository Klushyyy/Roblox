--[[
	IconArt - the game's own drawn icons (no emoji, no uploaded images), built from plain Frames so
	they stay crisp at any size.

	Every icon is a list of shapes on a 1 x 1 canvas (y down). Shapes marked `o = true` are part of
	the silhouette: they are first drawn a little bigger in dark ink (the outline pass), then every
	shape is drawn on top in colour (the fill pass). Overlapping shapes therefore share one clean
	outline instead of each getting its own ring.

	Shapes
	  disc     centre + diameter
	  rect     centre + size, optional corner radius (fraction of the short side) and rotation
	  diamond  a square turned 45 degrees (centre + half-diagonal), optionally clipped to a box:
	           clipped diamonds give the triangles and trapezoids (gem facets, roof points, crown
	           spikes, the drop's tip)
	  line     a rounded bar from one point to another
	  glyph    a text character (the star), outlined with a text stroke

	Fills are a Color3, or { top, bottom } for a gradient down the shape, or { a, b, rot = deg }.

	IconArt.Draw(kind, px) returns the icon's root Frame (px by px, transparent).
]]

local IconArt = {}

local INK = Color3.fromRGB(5, 16, 36)
local WHITE = Color3.new(1, 1, 1)
local SQRT2 = math.sqrt(2)

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

type Shape = { [any]: any }

local function gradient(parent: Instance, fill: any, shapeRotation: number)
	if typeof(fill) == "Color3" then
		return
	end
	local g = Instance.new("UIGradient")
	if typeof(fill[1]) == "Color3" and typeof(fill[2]) == "Color3" and fill[3] == nil then
		g.Color = ColorSequence.new(fill[1], fill[2])
	else
		local keys = {}
		local n = 0
		for _, c in fill do
			if typeof(c) == "Color3" then
				n += 1
			end
		end
		local i = 0
		for _, c in fill do
			if typeof(c) == "Color3" then
				table.insert(keys, ColorSequenceKeypoint.new(if n > 1 then i / (n - 1) else 0, c))
				i += 1
			end
		end
		g.Color = ColorSequence.new(keys)
	end
	-- Gradients run down the screen whatever the shape's own rotation.
	g.Rotation = (fill.rot or 90) - shapeRotation
	g.Parent = parent
end

local function baseColor(fill: any): Color3
	return if typeof(fill) == "Color3" then fill else WHITE
end

local function corner(f: GuiObject, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = f
end

local function frame(parent: Instance, cx: number, cy: number, w: number, h: number, rot: number, color: Color3, transparency: number): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(cx, cy)
	f.Size = UDim2.fromOffset(w, h)
	f.Rotation = rot
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency
	f.Parent = parent
	return f
end

-- Draws one shape. `grow` > 0 draws the ink outline version (every edge pushed out by `grow` px).
local function draw(parent: Instance, s: Shape, px: number, grow: number)
	local fill = if grow > 0 then INK else s.fill
	local transparency = if grow > 0 then 0 else (s.t or 0)
	local color = baseColor(fill)
	local kind = s[1]
	if kind == "disc" then
		local d = s.d * px + grow * 2
		local f = frame(parent, s.x * px, s.y * px, d, d, 0, color, transparency)
		corner(f, 0.5)
		if grow == 0 then
			gradient(f, fill, 0)
		end
	elseif kind == "rect" then
		local rot = s.rot or 0
		local w, h = s.w * px + grow * 2, s.h * px + grow * 2
		local f = frame(parent, s.x * px, s.y * px, w, h, rot, color, transparency)
		if s.r then
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, s.r * math.min(s.w, s.h) * px + grow)
			c.Parent = f
		end
		if grow == 0 then
			gradient(f, fill, rot)
		end
	elseif kind == "diamond" then
		local hd = s.hd * px + grow * SQRT2
		local side = hd * SQRT2
		local holder: Instance = parent
		local ox, oy = 0, 0
		if s.clip then
			local c = s.clip
			local x0, y0, x1, y1 = c[1] * px - grow, c[2] * px - grow, c[3] * px + grow, c[4] * px + grow
			local clip = Instance.new("Frame")
			clip.Name = "Clip"
			clip.BackgroundTransparency = 1
			clip.BorderSizePixel = 0
			clip.ClipsDescendants = true
			clip.Position = UDim2.fromOffset(x0, y0)
			clip.Size = UDim2.fromOffset(x1 - x0, y1 - y0)
			clip.Parent = parent
			holder = clip
			ox, oy = x0, y0
		end
		local f = frame(holder, s.x * px - ox, s.y * px - oy, side, side, 45, color, transparency)
		if s.r and grow == 0 then
			corner(f, s.r)
		elseif s.r then
			corner(f, s.r)
		end
		if grow == 0 then
			gradient(f, fill, 45)
		end
	elseif kind == "line" then
		local dx, dy = (s.x2 - s.x1) * px, (s.y2 - s.y1) * px
		local len = math.sqrt(dx * dx + dy * dy)
		local w = s.w * px + grow * 2
		local f = frame(parent, (s.x1 + s.x2) / 2 * px, (s.y1 + s.y2) / 2 * px, len + w, w, math.deg(math.atan2(dy, dx)), color, transparency)
		corner(f, 0.5)
		if grow == 0 then
			gradient(f, fill, math.deg(math.atan2(dy, dx)))
		end
	elseif kind == "glyph" then
		if grow > 0 then
			return
		end
		local size = s.size * px
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.AnchorPoint = Vector2.new(0.5, 0.5)
		label.Position = UDim2.fromOffset(s.x * px, s.y * px)
		label.Size = UDim2.fromOffset(size * 1.3, size * 1.3)
		label.Text = s.text
		label.Font = s.font or Enum.Font.GothamBlack
		label.TextSize = size
		label.TextColor3 = color
		label.TextTransparency = transparency
		label.Parent = parent
		if s.stroke ~= false then
			local st = Instance.new("UIStroke")
			st.Color = s.strokeColor or INK
			st.Thickness = math.max(1, (s.stroke or 0.05) * px)
			st.LineJoinMode = Enum.LineJoinMode.Round
			st.Parent = label
		end
		gradient(label, fill, 0)
	end
end

----------------------------------------------------------------------------------------------------
-- The icons
----------------------------------------------------------------------------------------------------
local ART: { [string]: { any } } = {}

-- Gold coin standing slightly tilted: a darker edge under the face, a stamped inner disc and a star.
ART.Coin = {
	{ "disc", x = 0.5, y = 0.56, d = 0.86, fill = { rgb(222, 136, 26), rgb(160, 84, 10) }, o = true },
	{ "disc", x = 0.5, y = 0.47, d = 0.86, fill = { rgb(255, 240, 150), rgb(248, 180, 40) }, o = true },
	{ "disc", x = 0.5, y = 0.47, d = 0.66, fill = rgb(214, 136, 24) },
	{ "disc", x = 0.5, y = 0.485, d = 0.6, fill = { rgb(240, 166, 34), rgb(255, 226, 112) } },
	{ "glyph", x = 0.5, y = 0.49, size = 0.46, text = "★", fill = { rgb(255, 250, 214), rgb(255, 214, 90) }, strokeColor = rgb(176, 100, 12), stroke = 0.045 },
	{ "rect", x = 0.3, y = 0.24, w = 0.22, h = 0.09, r = 0.5, rot = -38, fill = WHITE, t = 0.25 },
	{ "disc", x = 0.19, y = 0.38, d = 0.06, fill = WHITE, t = 0.35 },
}

-- Soap bubbles: one big, two small, pale in the middle with a coloured rim and a bright glint.
local BUBBLE_FILL = { rgb(190, 246, 255), rgb(206, 196, 255), rgb(255, 150, 214), rot = 45 }
ART.Bubble = {
	{ "disc", x = 0.43, y = 0.44, d = 0.76, fill = BUBBLE_FILL, o = true },
	{ "disc", x = 0.41, y = 0.42, d = 0.58, fill = WHITE, t = 0.55 },
	{ "rect", x = 0.28, y = 0.26, w = 0.26, h = 0.1, r = 0.5, rot = -42, fill = WHITE, t = 0.05 },
	{ "disc", x = 0.19, y = 0.43, d = 0.07, fill = WHITE, t = 0.1 },
	{ "line", x1 = 0.56, y1 = 0.7, x2 = 0.66, y2 = 0.6, w = 0.045, fill = WHITE, t = 0.45 },
	"|",
	{ "disc", x = 0.8, y = 0.77, d = 0.32, fill = BUBBLE_FILL, o = true },
	{ "disc", x = 0.79, y = 0.76, d = 0.22, fill = WHITE, t = 0.55 },
	{ "disc", x = 0.74, y = 0.7, d = 0.06, fill = WHITE, t = 0.1 },
	"|",
	{ "disc", x = 0.18, y = 0.86, d = 0.2, fill = BUBBLE_FILL, o = true },
	{ "disc", x = 0.155, y = 0.83, d = 0.05, fill = WHITE, t = 0.15 },
}

-- A cut gem seen from the side: table on top, crown facets, pavilion down to the point.
do
	local cy, top = 0.47, 0.25 -- girdle line and the flat top
	local hd = 0.42
	ART.Gem = {
		{ "diamond", x = 0.5, y = cy, hd = hd, clip = { 0, top, 1, 1 }, fill = rgb(128, 196, 255), o = true },
		{ "diamond", x = 0.5, y = cy, hd = hd, clip = { 0, top, 0.5, cy }, fill = rgb(176, 236, 255) },
		{ "diamond", x = 0.5, y = cy, hd = hd, clip = { 0.5, top, 1, cy }, fill = rgb(118, 168, 252) },
		{ "diamond", x = 0.5, y = cy, hd = hd, clip = { 0.5, cy, 1, 1 }, fill = rgb(108, 88, 232) },
		{ "diamond", x = 0.5, y = top, hd = 0.2, clip = { 0, top, 1, 1 }, fill = rgb(230, 250, 255) },
		{ "line", x1 = 0.1, y1 = cy, x2 = 0.9, y2 = cy, w = 0.03, fill = WHITE, t = 0.35 },
		{ "line", x1 = 0.3, y1 = cy, x2 = 0.5, y2 = cy + hd - 0.02, w = 0.025, fill = WHITE, t = 0.55 },
		{ "line", x1 = 0.7, y1 = cy, x2 = 0.5, y2 = cy + hd - 0.02, w = 0.025, fill = WHITE, t = 0.7 },
		"|",
		{ "diamond", x = 0.14, y = 0.16, hd = 0.08, fill = WHITE, o = true },
	}
end

-- A water drop: round bottom, pointed top (a diamond whose sides touch the circle).
do
	local r = 0.31
	local cx, cy = 0.5, 0.58
	local tipY = cy - r / SQRT2
	local hd = r / SQRT2
	ART.Drop = {
		{ "diamond", x = cx, y = tipY, hd = hd, fill = { rgb(200, 242, 255), rgb(92, 178, 250) }, o = true },
		{ "disc", x = cx, y = cy, d = r * 2, fill = { rgb(168, 230, 255), rgb(38, 128, 234) }, o = true },
		{ "rect", x = 0.37, y = 0.6, w = 0.08, h = 0.22, r = 0.5, rot = 18, fill = WHITE, t = 0.2 },
		{ "disc", x = 0.43, y = 0.43, d = 0.06, fill = WHITE, t = 0.3 },
		{ "line", x1 = 0.62, y1 = 0.8, x2 = 0.7, y2 = 0.7, w = 0.05, fill = WHITE, t = 0.55 },
	}
end

-- A present: box, lid, ribbon and a two-loop bow.
ART.Gift = {
	{ "rect", x = 0.36, y = 0.19, w = 0.28, h = 0.17, r = 0.5, rot = 28, fill = { rgb(255, 232, 110), rgb(242, 170, 36) }, o = true },
	{ "rect", x = 0.64, y = 0.19, w = 0.28, h = 0.17, r = 0.5, rot = -28, fill = { rgb(255, 232, 110), rgb(242, 170, 36) }, o = true },
	{ "rect", x = 0.36, y = 0.19, w = 0.13, h = 0.06, r = 0.5, rot = 28, fill = rgb(196, 118, 14), t = 0.35 },
	{ "rect", x = 0.64, y = 0.19, w = 0.13, h = 0.06, r = 0.5, rot = -28, fill = rgb(196, 118, 14), t = 0.35 },
	"|",
	{ "rect", x = 0.5, y = 0.67, w = 0.72, h = 0.46, r = 0.1, fill = { rgb(255, 104, 146), rgb(206, 44, 98) }, o = true },
	{ "rect", x = 0.5, y = 0.67, w = 0.16, h = 0.46, fill = { rgb(255, 232, 110), rgb(236, 160, 30) } },
	"|",
	{ "rect", x = 0.5, y = 0.4, w = 0.86, h = 0.2, r = 0.2, fill = { rgb(255, 150, 180), rgb(240, 84, 128) }, o = true },
	{ "rect", x = 0.5, y = 0.4, w = 0.16, h = 0.2, fill = { rgb(255, 240, 150), rgb(246, 186, 50) } },
	{ "rect", x = 0.24, y = 0.36, w = 0.14, h = 0.05, r = 0.5, fill = WHITE, t = 0.35 },
	"|",
	{ "disc", x = 0.5, y = 0.26, d = 0.14, fill = { rgb(255, 232, 110), rgb(242, 170, 36) }, o = true },
}

-- A ticket with a torn-off stub, tipped at an angle.
ART.Ticket = {
	{ "rect", x = 0.5, y = 0.5, w = 0.9, h = 0.54, r = 0.16, rot = -16, fill = { rgb(255, 226, 104), rgb(246, 158, 34) }, o = true },
	{ "disc", x = 0.5 + 0.43 * math.cos(math.rad(-16)), y = 0.5 + 0.43 * math.sin(math.rad(-16)), d = 0.16, fill = INK, t = 0 },
	{ "disc", x = 0.5 - 0.43 * math.cos(math.rad(-16)), y = 0.5 - 0.43 * math.sin(math.rad(-16)), d = 0.16, fill = INK, t = 0 },
	{ "rect", x = 0.44, y = 0.52, w = 0.5, h = 0.34, r = 0.14, rot = -16, fill = { rgb(255, 244, 196), rgb(255, 214, 110) } },
	{ "glyph", x = 0.44, y = 0.52, size = 0.3, text = "★", fill = rgb(242, 120, 60), strokeColor = rgb(170, 70, 20), stroke = 0.03 },
	{ "line", x1 = 0.75, y1 = 0.3, x2 = 0.745, y2 = 0.32, w = 0.05, fill = rgb(176, 96, 10), t = 0.1 },
	{ "line", x1 = 0.77, y1 = 0.41, x2 = 0.765, y2 = 0.43, w = 0.05, fill = rgb(176, 96, 10), t = 0.1 },
	{ "line", x1 = 0.79, y1 = 0.52, x2 = 0.785, y2 = 0.54, w = 0.05, fill = rgb(176, 96, 10), t = 0.1 },
	{ "line", x1 = 0.81, y1 = 0.63, x2 = 0.805, y2 = 0.65, w = 0.05, fill = rgb(176, 96, 10), t = 0.1 },
}

-- A big outlined star with two sparkles (free rewards).
ART.Star = {
	{ "glyph", x = 0.5, y = 0.54, size = 0.98, text = "★", fill = { rgb(255, 246, 170), rgb(255, 196, 40), rgb(246, 142, 20) }, stroke = 0.07 },
	"|",
	{ "diamond", x = 0.87, y = 0.16, hd = 0.1, fill = WHITE, o = true },
	{ "diamond", x = 0.12, y = 0.8, hd = 0.07, fill = WHITE, o = true },
}

-- A medal on a ribbon (ranks).
ART.Medal = {
	{ "rect", x = 0.37, y = 0.22, w = 0.2, h = 0.44, r = 0.1, rot = -22, fill = { rgb(120, 170, 255), rgb(70, 110, 240) }, o = true },
	{ "rect", x = 0.63, y = 0.22, w = 0.2, h = 0.44, r = 0.1, rot = 22, fill = { rgb(255, 120, 140), rgb(220, 60, 90) }, o = true },
	"|",
	{ "disc", x = 0.5, y = 0.63, d = 0.62, fill = { rgb(255, 240, 150), rgb(236, 160, 30) }, o = true },
	{ "disc", x = 0.5, y = 0.63, d = 0.46, fill = rgb(206, 128, 20) },
	{ "disc", x = 0.5, y = 0.64, d = 0.42, fill = { rgb(240, 170, 40), rgb(255, 226, 120) } },
	{ "glyph", x = 0.5, y = 0.645, size = 0.34, text = "★", fill = { rgb(255, 252, 220), rgb(255, 220, 100) }, strokeColor = rgb(176, 100, 12), stroke = 0.035 },
	{ "rect", x = 0.33, y = 0.47, w = 0.14, h = 0.06, r = 0.5, rot = -40, fill = WHITE, t = 0.3 },
}

-- A shield with a star (admin).
do
	local top, mid = 0.1, 0.5
	ART.Shield = {
		{ "rect", x = 0.5, y = (top + mid) / 2 + 0.02, w = 0.76, h = mid - top + 0.04, r = 0.16, fill = { rgb(236, 244, 255), rgb(170, 190, 220) }, o = true },
		{ "diamond", x = 0.5, y = mid - 0.02, hd = 0.38 * SQRT2 / SQRT2 * 1.0, clip = { 0.12, mid - 0.02, 0.88, 1 }, r = 0.12, fill = { rgb(190, 206, 232), rgb(140, 160, 196) }, o = true },
		{ "rect", x = 0.5, y = (top + mid) / 2 + 0.06, w = 0.56, h = mid - top - 0.04, r = 0.12, fill = { rgb(94, 150, 255), rgb(56, 100, 230) } },
		{ "diamond", x = 0.5, y = mid + 0.02, hd = 0.28, clip = { 0.22, mid + 0.02, 0.78, 1 }, r = 0.12, fill = { rgb(60, 106, 236), rgb(40, 76, 200) } },
		{ "glyph", x = 0.5, y = 0.47, size = 0.4, text = "★", fill = { rgb(255, 250, 220), rgb(255, 214, 90) }, stroke = 0.04 },
		{ "rect", x = 0.3, y = 0.24, w = 0.06, h = 0.16, r = 0.5, fill = WHITE, t = 0.4 },
	}
end

----------------------------------------------------------------------------------------------------
-- Level emblems (level select and the run banner)
----------------------------------------------------------------------------------------------------

-- Spaghetti and meatballs on a plate, seen from above.
do
	local shapes: { any } = {
		{ "disc", x = 0.5, y = 0.52, d = 0.94, fill = { rgb(255, 255, 255), rgb(200, 212, 232) }, o = true },
		{ "disc", x = 0.5, y = 0.52, d = 0.72, fill = rgb(214, 224, 240) },
		{ "rect", x = 0.26, y = 0.22, w = 0.2, h = 0.06, r = 0.5, rot = -40, fill = WHITE, t = 0.2 },
		"|",
		{ "disc", x = 0.5, y = 0.5, d = 0.62, fill = rgb(236, 186, 80), o = true },
	}
	-- a nest of noodles: short strokes at many angles, light over dark
	local strands = {
		{ 0.3, 0.4, 0.55, 0.28 }, { 0.26, 0.55, 0.5, 0.36 }, { 0.3, 0.68, 0.62, 0.42 }, { 0.44, 0.76, 0.74, 0.5 },
		{ 0.58, 0.28, 0.76, 0.46 }, { 0.36, 0.3, 0.72, 0.7 }, { 0.24, 0.48, 0.46, 0.74 }, { 0.54, 0.24, 0.3, 0.5 },
		{ 0.66, 0.74, 0.76, 0.56 }, { 0.4, 0.26, 0.66, 0.3 },
	}
	for i, st in strands do
		table.insert(shapes, { "line", x1 = st[1], y1 = st[2], x2 = st[3], y2 = st[4], w = 0.035, fill = if i % 2 == 0 then rgb(255, 234, 150) else rgb(250, 214, 110) })
	end
	table.insert(shapes, { "disc", x = 0.52, y = 0.5, d = 0.3, fill = { rgb(234, 70, 46), rgb(190, 34, 26) }, t = 0.05 })
	table.insert(shapes, { "disc", x = 0.43, y = 0.44, d = 0.12, fill = rgb(234, 70, 46) })
	table.insert(shapes, "|")
	for _, m in { { 0.44, 0.52 }, { 0.6, 0.55 }, { 0.53, 0.4 } } do
		table.insert(shapes, { "disc", x = m[1], y = m[2], d = 0.15, fill = { rgb(170, 96, 62), rgb(104, 50, 30) }, o = true })
		table.insert(shapes, { "disc", x = m[1] - 0.025, y = m[2] - 0.03, d = 0.045, fill = WHITE, t = 0.45 })
	end
	table.insert(shapes, { "rect", x = 0.66, y = 0.34, w = 0.09, h = 0.045, r = 0.5, rot = 30, fill = rgb(70, 170, 70) })
	table.insert(shapes, { "rect", x = 0.36, y = 0.64, w = 0.09, h = 0.045, r = 0.5, rot = -20, fill = rgb(70, 170, 70) })
	ART.Pasta = shapes
end

-- A whole pizza from above: crust, cheese, pepperoni, basil and the slice cuts.
do
	local pep = { rgb(214, 74, 52), rgb(166, 40, 30) }
	local shapes: { any } = {
		{ "disc", x = 0.5, y = 0.5, d = 0.94, fill = { rgb(246, 186, 104), rgb(196, 116, 46) }, o = true },
		{ "disc", x = 0.5, y = 0.5, d = 0.76, fill = rgb(214, 70, 40) },
		{ "disc", x = 0.5, y = 0.49, d = 0.72, fill = { rgb(255, 230, 120), rgb(250, 190, 70) } },
	}
	for i = 0, 2 do
		local a = math.rad(i * 60 + 15)
		table.insert(shapes, { "line", x1 = 0.5 - math.cos(a) * 0.37, y1 = 0.5 - math.sin(a) * 0.37, x2 = 0.5 + math.cos(a) * 0.37, y2 = 0.5 + math.sin(a) * 0.37, w = 0.022, fill = rgb(196, 120, 40), t = 0.25 })
	end
	table.insert(shapes, "|")
	for _, p in { { 0.34, 0.34 }, { 0.62, 0.3 }, { 0.72, 0.56 }, { 0.5, 0.52 }, { 0.3, 0.6 }, { 0.54, 0.74 } } do
		table.insert(shapes, { "disc", x = p[1], y = p[2], d = 0.14, fill = rgb(140, 30, 24) })
		table.insert(shapes, { "disc", x = p[1], y = p[2] - 0.005, d = 0.12, fill = pep })
		table.insert(shapes, { "disc", x = p[1] - 0.025, y = p[2] - 0.028, d = 0.035, fill = WHITE, t = 0.5 })
	end
	for _, b in { { 0.46, 0.24, 20 }, { 0.2, 0.46, -40 }, { 0.8, 0.42, 60 }, { 0.4, 0.44, 70 }, { 0.66, 0.7, -10 }, { 0.38, 0.78, 30 } } do
		table.insert(shapes, { "rect", x = b[1], y = b[2], w = 0.1, h = 0.05, r = 0.5, rot = b[3], fill = rgb(66, 158, 70) })
	end
	table.insert(shapes, { "rect", x = 0.24, y = 0.2, w = 0.18, h = 0.05, r = 0.5, rot = -45, fill = WHITE, t = 0.45 })
	ART.Pizza = shapes
end

-- A royal crown: band, three points with balls, and jewels.
do
	local band = 0.66
	ART.Crown = {
		{ "diamond", x = 0.2, y = band - 0.02, hd = 0.3, clip = { 0.08, 0.2, 0.42, band }, fill = { rgb(255, 238, 140), rgb(246, 176, 38) }, o = true },
		{ "diamond", x = 0.8, y = band - 0.02, hd = 0.3, clip = { 0.58, 0.2, 0.92, band }, fill = { rgb(255, 238, 140), rgb(246, 176, 38) }, o = true },
		{ "diamond", x = 0.5, y = band - 0.02, hd = 0.4, clip = { 0.22, 0.1, 0.78, band }, fill = { rgb(255, 242, 150), rgb(246, 176, 38) }, o = true },
		{ "disc", x = 0.12, y = 0.34, d = 0.13, fill = { rgb(255, 246, 180), rgb(246, 176, 38) }, o = true },
		{ "disc", x = 0.88, y = 0.34, d = 0.13, fill = { rgb(255, 246, 180), rgb(246, 176, 38) }, o = true },
		{ "disc", x = 0.5, y = 0.12, d = 0.15, fill = { rgb(255, 246, 180), rgb(246, 176, 38) }, o = true },
		"|",
		{ "rect", x = 0.5, y = band + 0.08, w = 0.84, h = 0.22, r = 0.2, fill = { rgb(255, 222, 100), rgb(214, 136, 20) }, o = true },
		{ "disc", x = 0.5, y = band + 0.08, d = 0.14, fill = { rgb(255, 110, 130), rgb(200, 30, 70) }, o = true },
		{ "disc", x = 0.26, y = band + 0.08, d = 0.1, fill = { rgb(120, 200, 255), rgb(50, 110, 230) }, o = true },
		{ "disc", x = 0.74, y = band + 0.08, d = 0.1, fill = { rgb(120, 200, 255), rgb(50, 110, 230) }, o = true },
		{ "disc", x = 0.49, y = band + 0.06, d = 0.045, fill = WHITE, t = 0.3 },
		{ "rect", x = 0.5, y = band - 0.01, w = 0.8, h = 0.03, r = 0.5, fill = WHITE, t = 0.55 },
		{ "disc", x = 0.48, y = 0.1, d = 0.05, fill = WHITE, t = 0.3 },
	}
end

-- A padlock (locked levels).
ART.Lock = {
	{ "rect", x = 0.5, y = 0.3, w = 0.5, h = 0.5, r = 0.5, fill = { rgb(210, 222, 240), rgb(140, 156, 186) }, o = true },
	{ "rect", x = 0.5, y = 0.34, w = 0.28, h = 0.4, r = 0.5, fill = INK },
	"|",
	{ "rect", x = 0.5, y = 0.66, w = 0.74, h = 0.52, r = 0.18, fill = { rgb(255, 222, 100), rgb(222, 146, 24) }, o = true },
	{ "disc", x = 0.5, y = 0.62, d = 0.14, fill = INK },
	{ "rect", x = 0.5, y = 0.71, w = 0.06, h = 0.14, r = 0.5, fill = INK },
	{ "rect", x = 0.25, y = 0.52, w = 0.12, h = 0.05, r = 0.5, fill = WHITE, t = 0.35 },
}

-- Puts the whole icon on one ZIndex (for ScreenGuis that use Global ZIndex ordering).
function IconArt.SetZIndex(root: GuiObject, z: number)
	root.ZIndex = z
	for _, d in root:GetDescendants() do
		if d:IsA("GuiObject") then
			d.ZIndex = z
		end
	end
end

function IconArt.Has(kind: string): boolean
	return ART[kind] ~= nil
end

function IconArt.Draw(kind: string, px: number): Frame
	local root = Instance.new("Frame")
	root.Name = kind .. "Icon"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Size = UDim2.fromOffset(px, px)
	local shapes = ART[kind] or ART.Coin
	local grow = math.max(1.5, px * 0.055)
	-- Each layer (split by "|") gets its outline pass and then its fill pass, so a layer drawn later
	-- sits on top of the earlier ones with its own outline.
	local layer: { Shape } = {}
	local function flush()
		for _, s in layer do
			if s.o then
				draw(root, s, px, grow)
			end
		end
		for _, s in layer do
			draw(root, s, px, 0)
		end
		table.clear(layer)
	end
	for _, s in shapes do
		if s == "|" then
			flush()
		else
			table.insert(layer, s)
		end
	end
	flush()
	return root
end

return IconArt
