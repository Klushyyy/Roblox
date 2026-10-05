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
	  tri      half of a square (centre, side s) cut along a diagonal; keep = "tl" | "tr" | "bl" | "br"
	           names the corner whose half stays. The cut is a UIGradient transparency edge, which
	           Roblox draws smoothly (anti-aliased), unlike the edge of a rotated frame
	  ring     a circle outline: hole diameter d, thickness th (a UIStroke round a circle)

	Smooth edges: Roblox doesn't anti-alias the edges of ROTATED frames, so they go jagged and look
	different at every size. Rounded corners (UICorner), strokes and gradient edges ARE smooth. The
	newer icons (pets, shop, trade, clubs, music, admin, free) are built only from those: discs,
	rounded rectangles, rings and gradient-cut triangles, never a rotated frame. They're also drawn
	at one big reference size and scaled down as a whole (HI_RES), so every size is the same shape.

	Any shape can take `clip = { x0, y0, x1, y1 }` (canvas units): it is drawn inside that box only.
	Every position and size is snapped to whole pixels, keeping centred shapes exactly centred, so
	the icons stay crisp and symmetric at small sizes. There are no text glyphs (font stars render
	differently on every device); every symbol is built from the shapes above.

	Fills are a Color3, or { top, bottom } for a gradient down the shape, or { a, b, rot = deg }.

	IconArt.Draw(kind, px) returns the icon's root Frame (px by px, transparent).
]]

local IconArt = {}

local Config = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))

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
	local c = f:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = f
end

-- Snaps a span (centre, length in px) to the pixel grid: whole-pixel length, and edges on whole
-- pixels. The centre moves at most half a pixel, and a shape centred on the icon stays exactly
-- centred (so left and right halves come out as mirror images at every size).
local function snap(c: number, len: number): (number, number)
	local l = math.max(1, math.floor(len + 0.5))
	local c2 = math.floor(c * 2 + 0.5)
	if (c2 - l) % 2 ~= 0 then
		l += 1
	end
	return c2 / 2, l
end

-- Like snap, for a square shape (disc, diamond): one whole-pixel side for both axes, and each centre
-- nudged by at most half a pixel so both edges land on whole pixels.
local function snapSquare(cx: number, cy: number, len: number): (number, number, number)
	local l = math.max(1, math.floor(len + 0.5))
	-- a shape centred exactly on a pixel line (like the icon's middle) grows by a pixel instead of
	-- moving, so it stays exactly centred and the icon stays mirror-symmetric
	local x2 = cx * 2
	if math.abs(x2 - math.floor(x2 + 0.5)) < 1e-6 and (math.floor(x2 + 0.5) - l) % 2 ~= 0 then
		l += 1
	end
	local function centre(c: number): number
		local c2 = math.floor(c * 2 + 0.5)
		if (c2 - l) % 2 ~= 0 then
			c2 += if c * 2 >= c2 then 1 else -1
		end
		return c2 / 2
	end
	return centre(cx), centre(cy), l
end

local function frame(parent: Instance, cx: number, cy: number, w: number, h: number, rot: number, color: Color3, transparency: number): Frame
	local x, sw = snap(cx, w)
	local y, sh = snap(cy, h)
	if w == h then
		local l
		x, y, l = snapSquare(cx, cy, w)
		sw, sh = l, l
	end
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Position = UDim2.fromOffset(x, y)
	f.Size = UDim2.fromOffset(sw, sh)
	f.Rotation = rot
	f.BackgroundColor3 = color
	f.BackgroundTransparency = transparency
	-- Rotated edges render smoother through the rounded-rect path, so give them a 1 px corner.
	if rot % 90 ~= 0 then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 1)
		c.Parent = f
	end
	f.Parent = parent
	return f
end

-- Optional clip box { x0, y0, x1, y1 } (canvas units) around a shape: returns the holder to draw
-- into and its offset. The box grows with the outline so outlines are clipped by the same edge.
local function clipHolder(parent: Instance, clip: { number }?, px: number, grow: number): (Instance, number, number)
	if not clip then
		return parent, 0, 0
	end
	local x0 = math.floor(clip[1] * px - grow + 0.5)
	local y0 = math.floor(clip[2] * px - grow + 0.5)
	local x1 = math.floor(clip[3] * px + grow + 0.5)
	local y1 = math.floor(clip[4] * px + grow + 0.5)
	local holder = Instance.new("Frame")
	holder.Name = "Clip"
	holder.BackgroundTransparency = 1
	holder.BorderSizePixel = 0
	holder.ClipsDescendants = true
	holder.Position = UDim2.fromOffset(x0, y0)
	holder.Size = UDim2.fromOffset(x1 - x0, y1 - y0)
	holder.Parent = parent
	return holder, x0, y0
end


-- Draws one shape. `grow` > 0 draws the ink outline version (every edge pushed out by `grow` px).
local function draw(parent: Instance, s: Shape, px: number, grow: number)
	local fill = if grow > 0 then (s.ink or INK) else s.fill
	local transparency = if grow > 0 then 0 else (s.t or 0)
	local color = baseColor(fill)
	local kind = s[1]
	local holder, ox, oy = clipHolder(parent, s.clip, px, grow)
	if kind == "disc" then
		local d = s.d * px + grow * 2
		local f = frame(holder, s.x * px - ox, s.y * px - oy, d, d, 0, color, transparency)
		corner(f, 0.5)
		if grow == 0 then
			gradient(f, fill, 0)
		end
	elseif kind == "rect" then
		local rot = s.rot or 0
		local w, h = s.w * px + grow * 2, s.h * px + grow * 2
		local f = frame(holder, s.x * px - ox, s.y * px - oy, w, h, rot, color, transparency)
		if s.r then
			local c = f:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, math.floor(s.r * math.min(s.w, s.h) * px + grow + 0.5))
			c.Parent = f
		end
		if grow == 0 then
			gradient(f, fill, rot)
		end
	elseif kind == "diamond" then
		-- A square turned 45 degrees; pushing each edge out by `grow` adds 2 * grow to the side.
		local side = s.hd * px * SQRT2 + grow * 2
		local f = frame(holder, s.x * px - ox, s.y * px - oy, side, side, 45, color, transparency)
		if s.r then
			corner(f, s.r)
		elseif grow > 0 then
			-- pushing a sharp corner out by `grow` makes a round corner of that radius, not a spike
			local c = f:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
			c.CornerRadius = UDim.new(0, grow)
			c.Parent = f
		end
		if grow == 0 then
			gradient(f, fill, 45)
		end
	elseif kind == "tri" then
		local side = s.s * px + grow * 2
		local f = frame(holder, s.x * px - ox, s.y * px - oy, side, side, 0, color, transparency)
		if s.r then
			corner(f, s.r)
		end
		local g = Instance.new("UIGradient")
		-- Runs from the kept corner (opaque) to the opposite one (clear); the cut crosses the middle.
		g.Rotation = ({ tl = 45, br = 225, tr = 135, bl = -45 })[s.keep or "tl"]
		local span = side * SQRT2
		-- The outline's cut sits `grow` px further out, so the diagonal gets its outline too.
		local edge = 0.5 + grow / span
		local soft = 0.6 / span -- about a pixel of blend: a smooth, sharp edge
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0),
			NumberSequenceKeypoint.new(edge - soft, 0),
			NumberSequenceKeypoint.new(edge + soft, 1),
			NumberSequenceKeypoint.new(1, 1),
		})
		if grow == 0 and typeof(fill) ~= "Color3" then
			g.Color = ColorSequence.new(fill[1], fill[2])
		end
		g.Parent = f
	elseif kind == "ring" then
		-- UIStroke draws outside the circle; the outline is a thicker stroke round a smaller circle.
		local d = s.d * px - grow * 2
		local f = frame(holder, s.x * px - ox, s.y * px - oy, d, d, 0, color, 1)
		corner(f, 0.5)
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = s.th * px + grow * 2
		stroke.Color = color
		stroke.Transparency = transparency
		stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		stroke.Parent = f
	elseif kind == "line" then
		local dx, dy = (s.x2 - s.x1) * px, (s.y2 - s.y1) * px
		local len = math.sqrt(dx * dx + dy * dy)
		local w = s.w * px + grow * 2
		local rot = math.deg(math.atan2(dy, dx))
		local f = frame(holder, (s.x1 + s.x2) / 2 * px - ox, (s.y1 + s.y2) / 2 * px - oy, len + w, w, rot, color, transparency)
		corner(f, 0.5)
		if grow == 0 then
			gradient(f, fill, rot)
		end
	end
end

----------------------------------------------------------------------------------------------------
-- The icons
----------------------------------------------------------------------------------------------------
local ART: { [string]: { any } } = {}

-- An embossed emblem: a gem-cut diamond (light upper facets, darker lower ones) with a thin dark
-- rim, drawn centred at (x, y). Used where a star would go (coin, medal, ticket, shield).
local function emblem(x: number, y: number, hd: number, light: Color3, mid: Color3, dark: Color3, rim: Color3): { any }
	return {
		{ "diamond", x = x, y = y, hd = hd + 0.035, fill = rim },
		{ "diamond", x = x, y = y, hd = hd, fill = mid },
		{ "diamond", x = x, y = y, hd = hd, clip = { x - hd, y - hd, x, y }, fill = light },
		{ "diamond", x = x, y = y, hd = hd, clip = { x, y, x + hd, y + hd }, fill = dark },
	}
end

local function append(list: { any }, more: { any }): { any }
	for _, v in more do
		table.insert(list, v)
	end
	return list
end

-- Gold coin standing slightly tilted: a darker edge under the face, a stamped rim and a raised
-- diamond in the middle.
ART.Coin = append({
	{ "disc", x = 0.5, y = 0.56, d = 0.86, fill = rgb(196, 112, 16), o = true },
	{ "disc", x = 0.5, y = 0.47, d = 0.86, fill = { rgb(255, 238, 140), rgb(248, 176, 36) }, o = true },
	{ "disc", x = 0.5, y = 0.47, d = 0.64, fill = rgb(212, 132, 22) },
	{ "disc", x = 0.5, y = 0.475, d = 0.58, fill = { rgb(246, 176, 40), rgb(255, 222, 110) } },
}, append(emblem(0.5, 0.475, 0.15, rgb(255, 250, 214), rgb(255, 224, 110), rgb(236, 158, 30), rgb(178, 98, 12)), {
	{ "rect", x = 0.3, y = 0.24, w = 0.2, h = 0.08, r = 0.5, rot = -40, fill = WHITE, t = 0.25 },
}))

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

-- A ticket, level: a stub on the right behind a dashed tear line, and a stamped diamond.
do
	local shapes: { any } = {
		{ "rect", x = 0.5, y = 0.5, w = 0.92, h = 0.56, r = 0.18, fill = { rgb(255, 226, 104), rgb(246, 158, 34) }, o = true },
		{ "rect", x = 0.38, y = 0.5, w = 0.52, h = 0.38, r = 0.16, fill = rgb(255, 244, 190), t = 0.15 },
		{ "rect", x = 0.26, y = 0.3, w = 0.2, h = 0.05, r = 0.5, fill = WHITE, t = 0.3 },
	}
	for i = 0, 3 do
		table.insert(shapes, { "rect", x = 0.75, y = 0.29 + i * 0.14, w = 0.045, h = 0.08, fill = rgb(184, 102, 12) })
	end
	append(shapes, emblem(0.38, 0.5, 0.12, rgb(255, 196, 150), rgb(250, 128, 64), rgb(214, 80, 36), rgb(150, 56, 18)))
	table.insert(shapes, { "disc", x = 0.865, y = 0.5, d = 0.1, fill = rgb(214, 128, 20) })
	ART.Ticket = shapes
end

-- A heart (free rewards: like, follow, join): a square turned 45 degrees with a disc on each of
-- its two upper edges, so both lobes are exact mirror images.
-- A heart (Free): two round lobes and a square turned 45 degrees for the point, one flat colour.
-- The outline is every piece pushed out by the same number of pixels (so the rim is equally thick
-- all the way round), and the point has no rounded corners (a rounded corner left a notch at the
-- sides where the ink showed through). Round highlights only.
do
	local h = 0.33 -- half diagonal of the square
	local cy = 0.54 -- centre of the square
	local d = h * SQRT2 -- lobe diameter = the square's side
	local red = rgb(255, 72, 112)
	ART.Heart = {
		{ "diamond", x = 0.5, y = cy, hd = h, fill = red, o = true },
		{ "disc", x = 0.5 - h / 2, y = cy - h / 2, d = d, fill = red, o = true },
		{ "disc", x = 0.5 + h / 2, y = cy - h / 2, d = d, fill = red, o = true },
		{ "disc", x = 0.32, y = 0.34, d = 0.15, fill = WHITE, t = 0.3 },
		{ "disc", x = 0.225, y = 0.45, d = 0.065, fill = WHITE, t = 0.4 },
	}
end

-- A four-point sparkle with a small twin (bonuses, "new").
ART.Star = {
	{ "line", x1 = 0.44, y1 = 0.12, x2 = 0.44, y2 = 0.84, w = 0.12, fill = rgb(255, 214, 70), o = true },
	{ "line", x1 = 0.08, y1 = 0.48, x2 = 0.8, y2 = 0.48, w = 0.12, fill = rgb(255, 214, 70), o = true },
	{ "diamond", x = 0.44, y = 0.48, hd = 0.2, fill = rgb(255, 214, 70), o = true },
	{ "diamond", x = 0.44, y = 0.48, hd = 0.1, fill = rgb(255, 250, 214) },
	"|",
	{ "line", x1 = 0.82, y1 = 0.66, x2 = 0.82, y2 = 0.92, w = 0.07, fill = WHITE, o = true },
	{ "line", x1 = 0.69, y1 = 0.79, x2 = 0.95, y2 = 0.79, w = 0.07, fill = WHITE, o = true },
}

-- A medal on a ribbon (ranks).
ART.Medal = append({
	{ "rect", x = 0.37, y = 0.22, w = 0.2, h = 0.44, r = 0.1, rot = -22, fill = rgb(86, 132, 248), o = true },
	{ "rect", x = 0.63, y = 0.22, w = 0.2, h = 0.44, r = 0.1, rot = 22, fill = rgb(240, 84, 112), o = true },
	"|",
	{ "disc", x = 0.5, y = 0.63, d = 0.62, fill = { rgb(255, 238, 140), rgb(236, 160, 30) }, o = true },
	{ "disc", x = 0.5, y = 0.63, d = 0.46, fill = rgb(206, 128, 20) },
	{ "disc", x = 0.5, y = 0.635, d = 0.41, fill = { rgb(240, 170, 40), rgb(255, 224, 116) } },
}, append(emblem(0.5, 0.635, 0.12, rgb(255, 252, 220), rgb(255, 224, 110), rgb(236, 158, 30), rgb(170, 94, 12)), {
	{ "rect", x = 0.33, y = 0.47, w = 0.13, h = 0.055, r = 0.5, rot = -40, fill = WHITE, t = 0.3 },
}))

-- A heraldic shield (admin): straight top with rounded corners, straight sides, and a point at the
-- bottom made from a square turned 45 degrees whose side corners meet the sides exactly. Silver
-- rim, split blue face (lit left half), and a gold diamond in the middle.
do
	local top, waist, hw = 0.08, 0.52, 0.37 -- top edge, where the point starts, half width
	local inset = 0.075
	local function outline(t: number, fill: any, o: boolean?, clip: { number }?): { any }
		local w = hw - t
		return {
			{ "rect", x = 0.5, y = (top + t + waist) / 2, w = w * 2, h = waist - top - t, r = 0.22, fill = fill, o = o, clip = clip },
			{ "rect", x = 0.5, y = (top + t + waist) / 2 + (waist - top - t) / 4, w = w * 2, h = (waist - top - t) / 2, fill = fill, o = o, clip = clip },
			{ "diamond", x = 0.5, y = waist, hd = w, r = 0.1, clip = if clip then { clip[1], math.max(waist, clip[2]), clip[3], clip[4] } else { 0, waist, 1, 1 }, fill = fill, o = o },
		}
	end
	local shapes = outline(0, rgb(222, 232, 248), true)
	append(shapes, outline(inset, rgb(52, 98, 226)))
	append(shapes, outline(inset, rgb(92, 146, 255), nil, { 0, 0, 0.5, 1 }))
	append(shapes, outline(inset + 0.035, rgb(70, 124, 244), nil, { 0, 0, 0.5, 1 }))
	append(shapes, outline(inset + 0.035, rgb(44, 84, 204), nil, { 0.5, 0, 1, 1 }))
	append(shapes, { "|" })
	append(shapes, emblem(0.5, 0.45, 0.15, rgb(255, 250, 214), rgb(255, 216, 90), rgb(232, 150, 26), rgb(120, 60, 8)))
	append(shapes, {
		{ "rect", x = 0.5, y = top + 0.035, w = (hw - 0.1) * 2, h = 0.03, r = 0.5, fill = WHITE, t = 0.35 },
	})
	ART.Shield = shapes
end

-- A paw print (pets): a big pad and four toes, mirror-symmetric.
ART.Paw = {
	{ "disc", x = 0.5, y = 0.62, d = 0.4, fill = { rgb(255, 200, 124), rgb(240, 140, 60) }, o = true },
	{ "rect", x = 0.5, y = 0.73, w = 0.54, h = 0.24, r = 0.5, fill = { rgb(250, 170, 92), rgb(238, 132, 54) }, o = true },
	{ "disc", x = 0.18, y = 0.43, d = 0.19, fill = { rgb(255, 204, 130), rgb(246, 160, 76) }, o = true },
	{ "disc", x = 0.82, y = 0.43, d = 0.19, fill = { rgb(255, 204, 130), rgb(246, 160, 76) }, o = true },
	{ "disc", x = 0.36, y = 0.23, d = 0.21, fill = { rgb(255, 204, 130), rgb(246, 160, 76) }, o = true },
	{ "disc", x = 0.64, y = 0.23, d = 0.21, fill = { rgb(255, 204, 130), rgb(246, 160, 76) }, o = true },
	{ "disc", x = 0.41, y = 0.57, d = 0.1, fill = WHITE, t = 0.4 },
	{ "disc", x = 0.33, y = 0.19, d = 0.06, fill = WHITE, t = 0.4 },
	{ "disc", x = 0.61, y = 0.19, d = 0.06, fill = WHITE, t = 0.4 },
}

-- A shopping cart (shop): basket, handle and two wheels.
ART.Cart = {
	{ "line", x1 = 0.1, y1 = 0.2, x2 = 0.2, y2 = 0.2, w = 0.08, fill = rgb(206, 216, 232), o = true },
	{ "line", x1 = 0.2, y1 = 0.2, x2 = 0.3, y2 = 0.68, w = 0.08, fill = rgb(206, 216, 232), o = true },
	{ "line", x1 = 0.3, y1 = 0.7, x2 = 0.82, y2 = 0.7, w = 0.08, fill = rgb(206, 216, 232), o = true },
	{ "rect", x = 0.57, y = 0.44, w = 0.58, h = 0.34, r = 0.16, fill = { rgb(255, 128, 146), rgb(222, 60, 88) }, o = true },
	{ "rect", x = 0.44, y = 0.44, w = 0.045, h = 0.24, r = 0.5, fill = rgb(176, 36, 66), t = 0.35 },
	{ "rect", x = 0.7, y = 0.44, w = 0.045, h = 0.24, r = 0.5, fill = rgb(176, 36, 66), t = 0.35 },
	{ "rect", x = 0.57, y = 0.35, w = 0.46, h = 0.045, r = 0.5, fill = WHITE, t = 0.45 },
	"|",
	{ "disc", x = 0.37, y = 0.84, d = 0.16, fill = rgb(70, 84, 110), o = true },
	{ "disc", x = 0.75, y = 0.84, d = 0.16, fill = rgb(70, 84, 110), o = true },
	{ "disc", x = 0.37, y = 0.84, d = 0.06, fill = rgb(206, 216, 232) },
	{ "disc", x = 0.75, y = 0.84, d = 0.06, fill = rgb(206, 216, 232) },
}

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

-- A treasure chest (the Treasure Chest event): wooden box and lid, gold bands and lock.
do
	local wood = { rgb(196, 120, 64), rgb(130, 70, 34) }
	local gold = { rgb(255, 236, 130), rgb(230, 160, 30) }
	ART.Chest = {
		{ "rect", x = 0.5, y = 0.66, w = 0.86, h = 0.46, r = 0.14, fill = wood, o = true },
		{ "rect", x = 0.5, y = 0.34, w = 0.86, h = 0.34, r = 0.45, fill = { rgb(214, 136, 74), rgb(160, 90, 44) }, o = true },
		{ "rect", x = 0.25, y = 0.56, w = 0.09, h = 0.74, r = 0.2, fill = gold },
		{ "rect", x = 0.75, y = 0.56, w = 0.09, h = 0.74, r = 0.2, fill = gold },
		{ "rect", x = 0.5, y = 0.47, w = 0.86, h = 0.07, r = 0.3, fill = gold },
		{ "rect", x = 0.5, y = 0.24, w = 0.5, h = 0.04, r = 0.5, fill = WHITE, t = 0.5 },
		"|",
		{ "rect", x = 0.5, y = 0.52, w = 0.18, h = 0.22, r = 0.25, fill = gold, o = true },
		{ "disc", x = 0.5, y = 0.5, d = 0.07, fill = INK },
		{ "rect", x = 0.5, y = 0.56, w = 0.035, h = 0.07, r = 0.5, fill = INK },
	}
end

-- A club crest: blue shield with a bubble in the middle.
do
	local blue = { rgb(120, 200, 255), rgb(40, 100, 220) }
	ART.Club = {
		{ "rect", x = 0.5, y = 0.34, w = 0.76, h = 0.5, r = 0.16, fill = blue, o = true },
		{ "diamond", x = 0.5, y = 0.5, hd = 0.44, clip = { 0.12, 0.5, 0.88, 0.96 }, fill = { rgb(70, 140, 235), rgb(40, 100, 220) }, o = true },
		"|",
		{ "rect", x = 0.5, y = 0.13, w = 0.6, h = 0.05, r = 0.5, fill = rgb(255, 214, 80) },
		{ "disc", x = 0.5, y = 0.5, d = 0.36, fill = { rgb(230, 248, 255), rgb(150, 210, 255) }, o = true },
		{ "disc", x = 0.44, y = 0.44, d = 0.1, fill = WHITE, t = 0.1 },
		{ "disc", x = 0.6, y = 0.6, d = 0.05, fill = WHITE, t = 0.4 },
	}
end

-- A calendar page (events).
ART.Calendar = {
	{ "rect", x = 0.5, y = 0.56, w = 0.8, h = 0.72, r = 0.14, fill = { rgb(255, 255, 255), rgb(214, 224, 240) }, o = true },
	{ "rect", x = 0.5, y = 0.3, w = 0.8, h = 0.2, r = 0.3, fill = { rgb(255, 110, 120), rgb(220, 50, 70) }, o = true },
	{ "rect", x = 0.32, y = 0.18, w = 0.08, h = 0.18, r = 0.5, fill = rgb(70, 84, 110), o = true },
	{ "rect", x = 0.68, y = 0.18, w = 0.08, h = 0.18, r = 0.5, fill = rgb(70, 84, 110), o = true },
	{ "rect", x = 0.32, y = 0.54, w = 0.13, h = 0.1, r = 0.2, fill = rgb(120, 140, 175) },
	{ "rect", x = 0.5, y = 0.54, w = 0.13, h = 0.1, r = 0.2, fill = rgb(120, 140, 175) },
	{ "rect", x = 0.68, y = 0.54, w = 0.13, h = 0.1, r = 0.2, fill = { rgb(255, 214, 80), rgb(240, 160, 30) } },
	{ "rect", x = 0.32, y = 0.72, w = 0.13, h = 0.1, r = 0.2, fill = rgb(120, 140, 175) },
	{ "rect", x = 0.5, y = 0.72, w = 0.13, h = 0.1, r = 0.2, fill = rgb(120, 140, 175) },
}

----------------------------------------------------------------------------------------------------
-- HUD buttons (smooth-edged set: no rotated frames anywhere, see the header)
----------------------------------------------------------------------------------------------------

-- Pets: a happy puppy face with floppy ears.
ART.Pup = {
	{ "rect", x = 0.17, y = 0.44, w = 0.22, h = 0.46, r = 0.5, fill = { rgb(176, 112, 70), rgb(132, 78, 46) }, o = true },
	{ "rect", x = 0.83, y = 0.44, w = 0.22, h = 0.46, r = 0.5, fill = { rgb(176, 112, 70), rgb(132, 78, 46) }, o = true },
	"|",
	{ "disc", x = 0.5, y = 0.52, d = 0.7, fill = { rgb(255, 222, 170), rgb(236, 176, 110) }, o = true },
	{ "rect", x = 0.5, y = 0.7, w = 0.4, h = 0.26, r = 0.5, fill = rgb(255, 240, 214) },
	{ "disc", x = 0.36, y = 0.48, d = 0.11, fill = rgb(40, 28, 24) },
	{ "disc", x = 0.64, y = 0.48, d = 0.11, fill = rgb(40, 28, 24) },
	{ "disc", x = 0.345, y = 0.465, d = 0.04, fill = WHITE },
	{ "disc", x = 0.625, y = 0.465, d = 0.04, fill = WHITE },
	{ "rect", x = 0.5, y = 0.62, w = 0.15, h = 0.1, r = 0.5, fill = rgb(50, 32, 28) },
	{ "rect", x = 0.5, y = 0.79, w = 0.1, h = 0.12, r = 0.5, fill = rgb(255, 110, 130) },
	{ "disc", x = 0.25, y = 0.64, d = 0.1, fill = rgb(255, 150, 150), t = 0.45 },
	{ "disc", x = 0.75, y = 0.64, d = 0.1, fill = rgb(255, 150, 150), t = 0.45 },
	{ "rect", x = 0.42, y = 0.26, w = 0.16, h = 0.05, r = 0.5, fill = WHITE, t = 0.5 },
}

-- Shop: a shopping bag with a round handle.
ART.Bag = {
	{ "ring", x = 0.5, y = 0.3, d = 0.3, th = 0.075, fill = rgb(250, 236, 242), o = true },
	"|",
	{ "rect", x = 0.5, y = 0.62, w = 0.78, h = 0.6, r = 0.16, fill = { rgb(255, 128, 168), rgb(220, 52, 104) }, o = true },
	{ "rect", x = 0.5, y = 0.4, w = 0.78, h = 0.08, r = 0.4, fill = rgb(196, 36, 88), t = 0.35 },
	{ "disc", x = 0.33, y = 0.47, d = 0.07, fill = rgb(120, 20, 56) },
	{ "disc", x = 0.67, y = 0.47, d = 0.07, fill = rgb(120, 20, 56) },
	{ "rect", x = 0.5, y = 0.66, w = 0.26, h = 0.2, r = 0.3, fill = WHITE, t = 0.15 },
	{ "rect", x = 0.5, y = 0.66, w = 0.1, h = 0.1, r = 0.5, fill = rgb(255, 196, 60) },
	{ "rect", x = 0.22, y = 0.64, w = 0.05, h = 0.32, r = 0.5, fill = WHITE, t = 0.55 },
}

-- Trade: two chunky arrows passing each other (green right on top, blue left underneath). Each is a
-- shaft and two head strokes with round ends (rotated rounded bars, which Roblox smooths): a clean,
-- even-width shape with no jagged tips, and one outline round the whole arrow.
do
	local function arrow(y: number, right: boolean, fill: any): { any }
		local w = 0.15
		local sgn = if right then 1 else -1
		local tip = if right then 0.88 else 0.12
		local tail = if right then 0.12 else 0.88
		local back = tip - sgn * 0.25
		return {
			{ "line", x1 = tail, y1 = y, x2 = tip, y2 = y, w = w, fill = fill, o = true },
			{ "line", x1 = tip, y1 = y, x2 = back, y2 = y - 0.2, w = w, fill = fill, o = true },
			{ "line", x1 = tip, y1 = y, x2 = back, y2 = y + 0.2, w = w, fill = fill, o = true },
		}
	end
	local shapes: { any } = {}
	for _, s in arrow(0.7, false, rgb(66, 156, 250)) do
		table.insert(shapes, s)
	end
	table.insert(shapes, "|")
	for _, s in arrow(0.3, true, rgb(52, 208, 124)) do
		table.insert(shapes, s)
	end
	table.insert(shapes, { "line", x1 = 0.2, y1 = 0.26, x2 = 0.5, y2 = 0.26, w = 0.035, fill = WHITE, t = 0.5 })
	ART.Trade = shapes
end

-- Clubs: three friends, the middle one in front.
ART.Group = {
	{ "rect", x = 0.24, y = 0.74, w = 0.32, h = 0.38, r = 0.45, fill = { rgb(150, 130, 255), rgb(100, 80, 220) }, o = true },
	{ "disc", x = 0.24, y = 0.42, d = 0.24, fill = { rgb(255, 224, 190), rgb(240, 186, 140) }, o = true },
	{ "rect", x = 0.76, y = 0.74, w = 0.32, h = 0.38, r = 0.45, fill = { rgb(255, 150, 200), rgb(230, 90, 150) }, o = true },
	{ "disc", x = 0.76, y = 0.42, d = 0.24, fill = { rgb(255, 224, 190), rgb(240, 186, 140) }, o = true },
	"|",
	{ "rect", x = 0.5, y = 0.78, w = 0.42, h = 0.44, r = 0.45, fill = { rgb(110, 210, 255), rgb(40, 140, 230) }, o = true },
	{ "disc", x = 0.5, y = 0.36, d = 0.3, fill = { rgb(255, 228, 196), rgb(240, 186, 140) }, o = true },
	{ "rect", x = 0.44, y = 0.27, w = 0.1, h = 0.04, r = 0.5, fill = WHITE, t = 0.4 },
}

-- Music: two beamed notes.
ART.Notes = {
	{ "rect", x = 0.42, y = 0.47, w = 0.08, h = 0.56, r = 0.5, fill = rgb(150, 100, 255), o = true },
	{ "rect", x = 0.82, y = 0.42, w = 0.08, h = 0.5, r = 0.5, fill = rgb(150, 100, 255), o = true },
	{ "rect", x = 0.62, y = 0.22, w = 0.48, h = 0.13, r = 0.3, fill = { rgb(190, 150, 255), rgb(140, 90, 250) }, o = true },
	{ "rect", x = 0.31, y = 0.76, w = 0.3, h = 0.22, r = 0.5, fill = { rgb(190, 150, 255), rgb(130, 80, 240) }, o = true },
	{ "rect", x = 0.71, y = 0.68, w = 0.3, h = 0.22, r = 0.5, fill = { rgb(190, 150, 255), rgb(130, 80, 240) }, o = true },
	{ "rect", x = 0.26, y = 0.73, w = 0.1, h = 0.05, r = 0.5, fill = WHITE, t = 0.4 },
	{ "rect", x = 0.66, y = 0.65, w = 0.1, h = 0.05, r = 0.5, fill = WHITE, t = 0.4 },
}

-- Admin: a judge's gavel, upright.
ART.Gavel = {
	{ "rect", x = 0.5, y = 0.66, w = 0.13, h = 0.6, r = 0.5, fill = { rgb(200, 132, 80), rgb(140, 86, 48) }, o = true },
	{ "rect", x = 0.5, y = 0.92, w = 0.42, h = 0.1, r = 0.5, fill = { rgb(200, 132, 80), rgb(140, 86, 48) }, o = true },
	"|",
	{ "rect", x = 0.5, y = 0.27, w = 0.72, h = 0.3, r = 0.28, fill = { rgb(236, 242, 252), rgb(150, 164, 190) }, o = true },
	{ "rect", x = 0.25, y = 0.27, w = 0.08, h = 0.34, r = 0.3, fill = { rgb(255, 214, 90), rgb(222, 150, 30) }, o = true },
	{ "rect", x = 0.75, y = 0.27, w = 0.08, h = 0.34, r = 0.3, fill = { rgb(255, 214, 90), rgb(222, 150, 30) }, o = true },
	{ "rect", x = 0.5, y = 0.19, w = 0.4, h = 0.04, r = 0.5, fill = WHITE, t = 0.4 },
}

-- Free: a heart (two circles and a gradient-cut point).
-- A heart: two round lobes on a square turned 45 degrees (so the bottom is a true point). Rounded
-- shapes only, which Roblox smooths; one outline round the whole thing.
do
	local hd = 0.345 -- half the diagonal of the turned square
	local cy = 0.5
	local side = hd * SQRT2
	local red = rgb(247, 78, 108)
	ART.Love = {
		{ "disc", x = 0.5 - hd / 2, y = cy - hd / 2, d = side, fill = red, o = true },
		{ "disc", x = 0.5 + hd / 2, y = cy - hd / 2, d = side, fill = red, o = true },
		{ "diamond", x = 0.5, y = cy, hd = hd, fill = red, o = true },
		{ "disc", x = 0.5 - hd / 2 - 0.02, y = cy - hd / 2 - 0.03, d = 0.14, fill = WHITE, t = 0.3 },
		{ "disc", x = 0.5 - hd / 2 + 0.1, y = cy - hd / 2 - 0.12, d = 0.055, fill = WHITE, t = 0.55 },
	}
end

-- Upgrades: a green book with a big up arrow on the cover.
do
	local a = 0.2
	local arrowFill = rgb(255, 236, 130)
	ART.Book = {
		{ "rect", x = 0.55, y = 0.52, w = 0.74, h = 0.86, r = 0.1, fill = rgb(236, 240, 250), o = true }, -- pages behind the cover
		"|",
		{ "rect", x = 0.46, y = 0.5, w = 0.74, h = 0.86, r = 0.1, fill = { rgb(90, 220, 140), rgb(34, 160, 96) }, o = true },
		{ "rect", x = 0.17, y = 0.5, w = 0.1, h = 0.86, r = 0.5, fill = rgb(24, 120, 72) },
		{ "rect", x = 0.36, y = 0.2, w = 0.14, h = 0.05, r = 0.5, fill = WHITE, t = 0.45 },
		"|",
		{ "rect", x = 0.5, y = 0.62, w = 0.14, h = 0.34, r = 0.5, fill = arrowFill, o = true },
		{ "tri", x = 0.5 - a / 2 + 0.002, y = 0.37, s = a, keep = "br", fill = arrowFill, o = true },
		{ "tri", x = 0.5 + a / 2 - 0.002, y = 0.37, s = a, keep = "bl", fill = arrowFill, o = true },
	}
end

-- Leave: an open door with an arrow going out.
do
	local a = 0.18
	local red = { rgb(255, 120, 120), rgb(226, 60, 70) }
	ART.Door = {
		{ "rect", x = 0.36, y = 0.5, w = 0.56, h = 0.88, r = 0.1, fill = rgb(120, 78, 46), o = true },
		{ "rect", x = 0.36, y = 0.55, w = 0.42, h = 0.78, r = 0.08, fill = rgb(34, 48, 84) },
		"|",
		{ "rect", x = 0.25, y = 0.55, w = 0.2, h = 0.74, r = 0.18, fill = { rgb(214, 150, 92), rgb(160, 100, 56) }, o = true },
		{ "disc", x = 0.31, y = 0.57, d = 0.07, fill = rgb(255, 214, 90) },
		"|",
		{ "rect", x = 0.66, y = 0.5, w = 0.3, h = 0.11, r = 0.5, fill = red, o = true },
		{ "tri", x = 0.77 + a / 2, y = 0.5 - a / 2 + 0.002, s = a, keep = "bl", fill = red, o = true },
		{ "tri", x = 0.77 + a / 2, y = 0.5 + a / 2 - 0.002, s = a, keep = "tl", fill = red, o = true },
	}
end

-- Puts the whole icon on one ZIndex (for ScreenGuis that use Global ZIndex ordering).
-- Moves a drawn icon to layer z. Its shapes keep their own stacking order inside it (every
-- ScreenGui here uses Sibling ZIndex, so they only order among themselves).
function IconArt.SetZIndex(root: GuiObject, z: number)
	root.ZIndex = z
end

function IconArt.Has(kind: string): boolean
	return ART[kind] ~= nil
end

local HI_RES: { [string]: boolean } = {
	Heart = true,
	Pup = true,
	Bag = true,
	Trade = true,
	Group = true,
	Notes = true,
	Gavel = true,
	Love = true,
	Club = true,
	Chest = true,
	Book = true,
	Door = true,
}
local HI_RES_SIZE = 120

function IconArt.Draw(kind: string, px: number): Frame
	-- An uploaded picture (Config.IconImages) wins over the drawn version, if one is set.
	local imageId = tonumber((Config.IconImages :: any)[kind])
	if imageId and imageId > 0 then
		local holder = Instance.new("Frame")
		holder.Name = kind .. "Icon"
		holder.BackgroundTransparency = 1
		holder.BorderSizePixel = 0
		holder.Size = UDim2.fromOffset(px, px)
		local image = Instance.new("ImageLabel")
		image.BackgroundTransparency = 1
		image.BorderSizePixel = 0
		image.Size = UDim2.fromScale(1, 1)
		image.Image = "rbxassetid://" .. tostring(math.floor(imageId))
		image.ScaleType = Enum.ScaleType.Fit
		image.Parent = holder
		return holder
	end
	local root = Instance.new("Frame")
	root.Name = kind .. "Icon"
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Size = UDim2.fromOffset(px, px)
	local shapes = ART[kind] or ART.Coin
	-- Icons listed in HI_RES are always drawn at the reference size and scaled down as one picture
	-- (UIScale), so a small one is exactly the big one shrunk: snapping each shape to a few whole
	-- pixels at small sizes knocked them out of line with each other.
	local canvas: Frame = root
	if HI_RES[kind] and px < HI_RES_SIZE then
		local inner = Instance.new("Frame")
		inner.Name = "Art"
		inner.BackgroundTransparency = 1
		inner.BorderSizePixel = 0
		inner.Size = UDim2.fromOffset(HI_RES_SIZE, HI_RES_SIZE)
		local scale = Instance.new("UIScale")
		scale.Scale = px / HI_RES_SIZE
		scale.Parent = inner
		inner.Parent = root
		canvas = inner
		px = HI_RES_SIZE
	end
	local grow = math.max(1, math.floor(px * 0.06 + 0.5))
	-- Each layer (split by "|") gets its outline pass and then its fill pass, so a layer drawn later
	-- sits on top of the earlier ones with its own outline.
	local layer: { Shape } = {}
	local function flush()
		for _, s in layer do
			if s.o then
				draw(canvas, s, px, grow)
			end
		end
		for _, s in layer do
			draw(canvas, s, px, 0)
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
	-- Pin the drawing order: siblings with the same ZIndex have no guaranteed order in Roblox, which
	-- let an outline land on top of its fill (the ragged edges). Each shape sits above the last.
	for i, child in canvas:GetChildren() do
		if child:IsA("GuiObject") then
			child.ZIndex = i
		end
	end
	return root
end

return IconArt
