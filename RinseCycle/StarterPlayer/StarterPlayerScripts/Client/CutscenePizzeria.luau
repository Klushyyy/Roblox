--[[
	CutscenePizzeria - the Pizzeria level's story, one chapter per run (see CutsceneKit).

	  1. Dough Show: the pizzeria kitchen. The chef spins the dough higher and higher... and it
	     comes down over him like a poncho. The waiter can't stop laughing, then loads the plates.
	  2. The Food Critic: the dining room at night. A famous critic tastes the pizza while the
	     chef (still in the poncho) watches through the kitchen door. Ten out of ten!
	  3. Pizza in the Park: the new food truck at sunset, a queue of happy customers, a slice with
	     a cheese pull a mile long, and the truck's own little dishwasher.
]]

local Client = script.Parent
local Kit = require(Client:WaitForChild("CutsceneKit"))

local R = Kit.Rig
local P = R.P
local S = R.S
local PI = math.pi
local rgb = Kit.rgb
local smooth = R.smooth
local local3 = R.local3
local V2 = Vector2.new
local V = Vector3.new
local C = CFrame.new
local TABLE = 150

local PROPS = R.PROPS
local LOOKS = R.LOOKS
local disc = R.disc

PROPS.SauceStack = function()
	local t = {}
	for i = 0, 3 do
		table.insert(t, disc(52, 2.4, 1.2 + i * 3.4, rgb(250, 250, 248)))
		table.insert(t, { V(16, 1.4, 12), C(-8 + i * 5, 2.8 + i * 3.4, 5 - i * 3), rgb(200, 50, 36), nil, "Sphere" })
		table.insert(t, { V(8, 1.6, 12), C(10 - i * 4, 3 + i * 3.4, -6), rgb(214, 150, 70), nil, "Sphere" })
	end
	return t
end
PROPS.PizzaPlate = function()
	local t = { disc(60, 3, 1.5, rgb(250, 250, 248)) }
	table.insert(t, disc(50, 3, 4, rgb(214, 150, 70)))
	table.insert(t, disc(42, 3.2, 4.4, rgb(250, 206, 96)))
	for i = 0, 5 do
		local a = i / 6 * PI * 2
		table.insert(t, disc(8, 1, 6.2, rgb(170, 36, 30), nil, math.cos(a) * 12, math.sin(a) * 12))
	end
	return t
end
PROPS.ScoreCard = function()
	return {
		{ V(3, 50, 40), C(0, 0, 0), rgb(250, 250, 244) },
		{ V(3.4, 34, 8), C(0, 0, -8), rgb(40, 40, 44) }, -- "1"
		{ V(3.4, 34, 20), C(0, 0, 10), rgb(40, 40, 44) }, -- "0"
		{ V(3.8, 22, 10), C(0, 0, 10), rgb(250, 250, 244) },
	}
end

-- The critic: black polo neck, beret, round glasses, a very serious face.
LOOKS.Critic = {
	Shirt = rgb(34, 34, 40), Pants = rgb(60, 56, 70), Shoes = rgb(120, 40, 40),
	Build = function(a)
		R.hairShort(rgb(160, 160, 166))(a)
		R.glasses(a)
		a:piece("Head", Vector3.new(1.5, 0.34, 1.46), CFrame.new(0.08, 0.64, 0.02) * CFrame.Angles(0, 0, -0.12), rgb(150, 30, 40), Enum.Material.Fabric, "Sphere")
		a:piece("Head", Vector3.new(0.12, 0.16, 0.12), CFrame.new(0.08, 0.83, 0), rgb(150, 30, 40), Enum.Material.Fabric)
		a:piece("Torso", Vector3.new(1.3, 0.34, 1.08), CFrame.new(0, 0.9, 0), rgb(34, 34, 40), Enum.Material.Fabric)
		a:piece("Torso", Vector3.new(0.9, 0.14, 0.06), CFrame.new(0, 0.3, -0.53), rgb(230, 190, 90), Enum.Material.Metal)
	end,
}

-- A checkerboard floor.
local function checker(ctx: any, x0: number, x1: number, z0: number, z1: number, tile: number, a: Color3, b: Color3)
	ctx:box("Floor", V(x1 - x0, 10, z1 - z0), ctx:at((x0 + x1) / 2, -5, (z0 + z1) / 2), a, Enum.Material.SmoothPlastic)
	local i = 0
	local x = x0
	while x < x1 - 1 do
		local z = z0
		local j = 0
		while z < z1 - 1 do
			if (i + j) % 2 == 1 then
				ctx:box("Tile", V(tile, 0.6, tile), ctx:at(x + tile / 2, 0.3, z + tile / 2), b, Enum.Material.SmoothPlastic)
			end
			z += tile
			j += 1
		end
		x += tile
		i += 1
	end
end

-- The brick pizza oven, fire and all. Returns the fire part (for flicker).
local function pizzaOven(ctx: any, x: number, z: number): BasePart
	local brick = rgb(176, 88, 64)
	ctx:box("OvenBase", V(320, 130, 240), ctx:at(x, 65, z), rgb(150, 150, 146), Enum.Material.Concrete)
	ctx:box("OvenDome", V(320, 240, 240), ctx:at(x, 150, z), brick, Enum.Material.Brick, "Sphere")
	ctx:box("OvenMouth", V(130, 80, 20), ctx:at(x, 170, z - 112), rgb(30, 22, 20))
	ctx:box("OvenArch", V(150, 16, 24), ctx:at(x, 216, z - 112), rgb(200, 190, 170), Enum.Material.Brick)
	local fire = ctx:box("Fire", V(100, 40, 10), ctx:at(x, 150, z - 104), rgb(255, 120, 40), Enum.Material.Neon)
	fire.CastShadow = false
	local l = Instance.new("PointLight")
	l.Color = rgb(255, 140, 60)
	l.Range = 50
	l.Brightness = 2
	l.Parent = fire
	ctx:post("Chimney", 50, 400, x, 260, z + 40, rgb(120, 120, 126), Enum.Material.Metal)
	ctx:onUpdate(function(t)
		local f = 0.8 + 0.2 * math.sin(t * 13) * math.sin(t * 7.3)
		fire.Size = V(100, 36 + 10 * f, 10)
		l.Brightness = 1.6 + f
	end)
	return fire
end

----------------------------------------------------------------------------------------------------
-- Chapter 1: Dough Show
----------------------------------------------------------------------------------------------------

local function doughShow(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 28)
	Kit.title(ctx, 1, "Dough Show")
	ctx:mood({ ClockTime = 12, Brightness = 2.2, ExposureCompensation = -0.1, Ambient = rgb(120, 110, 100), OutdoorAmbient = rgb(140, 130, 120) })
	local scene = ctx.Scene

	local ZW = 620
	checker(ctx, -660, 660, -700, ZW, 110, rgb(240, 240, 236), rgb(50, 50, 56))
	Kit.wall(ctx, -660, ZW, 660, ZW, 700, rgb(244, 244, 238), Enum.Material.SmoothPlastic, rgb(200, 60, 50))
	Kit.wall(ctx, -660, -700, -660, ZW, 700, rgb(244, 244, 238), Enum.Material.SmoothPlastic, rgb(200, 60, 50))
	-- the right wall has the doorway to the dining room in it
	Kit.wall(ctx, 660, -700, 660, 120, 700, rgb(244, 244, 238), Enum.Material.SmoothPlastic, rgb(200, 60, 50))
	Kit.wall(ctx, 660, 320, 660, ZW, 700, rgb(244, 244, 238), Enum.Material.SmoothPlastic, rgb(200, 60, 50))
	ctx:box("Lintel", V(16, 380, 200), ctx:at(660, 510, 220), rgb(244, 244, 238))
	ctx:box("RedBand", V(1320, 200, 18), ctx:at(0, 100, ZW - 1), rgb(200, 60, 50), Enum.Material.SmoothPlastic)
	for i = 0, 11 do
		ctx:box("TileLine", V(1320, 2, 18.5), ctx:at(0, 230 + i * 36, ZW - 1), rgb(220, 220, 214))
	end
	pizzaOven(ctx, -400, 480)
	-- the chalkboard menu
	local board = ctx:box("Menu", V(240, 150, 6), ctx:at(-80, 460, ZW - 12), rgb(40, 50, 44))
	local g = Instance.new("SurfaceGui")
	g.Face = Enum.NormalId.Back
	g.CanvasSize = Vector2.new(480, 300)
	g.LightInfluence = 0.4
	g.Parent = board
	local tl = Instance.new("TextLabel")
	tl.Size = UDim2.fromScale(1, 1)
	tl.BackgroundTransparency = 1
	tl.Text = "LUIGI'S\nPizza  Pasta  Gelato"
	tl.Font = Enum.Font.FredokaOne
	tl.TextScaled = true
	tl.TextColor3 = rgb(250, 250, 240)
	tl.Parent = g
	ctx:box("MenuFrame", V(256, 166, 4), ctx:at(-80, 460, ZW - 9), rgb(150, 100, 60), Enum.Material.Wood)
	-- a rack of hanging pans
	ctx:box("PanRail", V(300, 8, 8), ctx:at(250, 520, ZW - 30), rgb(60, 60, 64), Enum.Material.Metal)
	for i = 0, 3 do
		ctx:box("HangPan", V(4, 60 - i * 6, 60 - i * 6), ctx:at(150 + i * 70, 470 + i * 3, ZW - 30) * CFrame.Angles(0, PI / 2, 0), rgb(70, 70, 76), Enum.Material.Metal, "Cylinder")
	end
	-- the counter with the dishwasher and the sink
	local ZF = 490
	local top = Kit.counter(ctx, 100, 650, ZF, { Gaps = { { 195, 325 } }, Body = rgb(200, 204, 210), BodyMat = Enum.Material.Metal, Door = rgb(214, 218, 224), Top = rgb(220, 224, 230), TopMat = Enum.Material.Metal })
	Kit.sink(ctx, 500, ZF, top)
	local dw = Kit.dishwasher(ctx, 260, ZF, 0, { Mess = rgb(200, 50, 36) })
	-- the doorway to the dining room (right wall): a frame, and the dim room beyond
	for _, dz in { -100, 100 } do
		ctx:box("DoorFrame", V(24, 320, 16), ctx:at(660, 160, 220 + dz), rgb(150, 100, 60), Enum.Material.Wood)
	end
	ctx:box("DoorFrame", V(24, 16, 216), ctx:at(660, 320, 220), rgb(150, 100, 60), Enum.Material.Wood)
	ctx:box("DiningBeyond", V(10, 700, 600), ctx:at(1000, 350, 220), rgb(70, 40, 36))
	ctx:box("DiningCeiling", V(360, 10, 600), ctx:at(840, 340, 220), rgb(60, 36, 32))
	ctx:box("DiningFloor", V(460, 8, 220), ctx:at(880, -4, 220), rgb(120, 80, 50), Enum.Material.WoodPlanks)
	-- the prep island
	Kit.table(ctx, 0, 250, 360, 130, TABLE, rgb(200, 204, 210), nil, Enum.Material.Metal)
	ctx:box("Board", V(170, 6, 100), ctx:at(0, TABLE + 3, 250), rgb(200, 150, 96), Enum.Material.Wood)
	ctx:box("Flour", V(120, 1, 70), ctx:at(-10, TABLE + 6.5, 252), rgb(252, 250, 244))
	ctx:post("SauceBowl", 50, 20, 130, TABLE, 250, rgb(250, 250, 248))
	ctx:post("Sauce", 42, 2, 130, TABLE + 19, 250, rgb(200, 50, 36))
	ctx:post("CheeseBowl", 46, 18, -130, TABLE, 240, rgb(250, 250, 248))
	for i = 0, 4 do
		ctx:box("Cheese", V(10, 6, 10), ctx:at(-130 + (i - 2) * 7, TABLE + 20, 240 + (i % 2) * 6), rgb(250, 214, 90))
	end
	ctx:post("Basil", 30, 40, 170, TABLE, 300, rgb(200, 110, 70))
	ctx:box("BasilLeaves", V(50, 40, 50), ctx:at(170, TABLE + 55, 300), rgb(70, 160, 70), nil, "Sphere")

	-- The chef and the dough.
	local chef = scene:actor("Chef", "Chef")
	local CX, CZ = 0, 350
	local pc = R.newPlan(chef, CX, CZ, PI)
	local dough = ctx:box("Dough", V(5, 60, 60), CFrame.new(), rgb(246, 226, 180), nil, "Cylinder")
	local ball = ctx:box("DoughBall", V(46, 30, 46), ctx:at(-10, TABLE + 20, 252), rgb(246, 226, 180), nil, "Sphere")
	local function knead(u: number, c: any): any
		local s = c.Actor.S
		local k = math.sin(u * 5)
		return {
			bob = math.abs(k) * 0.02,
			lean = 0.3,
			head = { pitch = -0.4 },
			armL = { at = local3(c, -0.2 * s, TABLE + 26 + math.max(k, 0) * 14, 1.9 * s) },
			armR = { at = local3(c, 0.2 * s, TABLE + 26 + math.max(-k, 0) * 14, 1.9 * s) },
		}
	end
	local function spin(u: number, c: any): any
		local s = c.Actor.S
		local hop = math.abs(math.sin(u * 3.2))
		return {
			bob = hop * 0.03,
			head = { pitch = 0.45 },
			armL = { at = local3(c, -0.25 * s, 285 + hop * 30, 0.5 * s) },
			armR = { at = local3(c, 0.25 * s, 285 + hop * 30, 0.5 * s) },
		}
	end
	pc:still(3.4, knead)
	local SPIN = pc.T
	pc:still(2.6, spin)
	local TOSS = pc.T
	pc:still(0.5, function(u, c)
		local s = c.Actor.S
		local k = smooth(u / 0.5)
		return {
			sit = 0.3 * (1 - k),
			seat = 30,
			head = { pitch = 0.5 + 0.4 * k },
			armL = { at = local3(c, -0.3 * s, 280 + 90 * k, 0.4 * s) },
			armR = { at = local3(c, 0.3 * s, 280 + 90 * k, 0.4 * s) },
		}
	end)
	local LANDD = TOSS + 2.0
	pc:still(LANDD - pc.T, function(u, c)
		local s = c.Actor.S
		return {
			head = { pitch = 0.95 },
			armL = { at = local3(c, -0.5 * s, 330, 0.5 * s) },
			armR = { at = local3(c, 0.5 * s, 330, 0.5 * s) },
		}
	end)
	pc:still(1.3, P.startle)
	-- a shrug, then a grand bow in his new poncho
	pc:still(1.6, function(u, c)
		local p = P.idle(u, c)
		local k = math.sin(math.clamp(u / 1.6, 0, 1) * PI)
		p.armL = { p = 0.5 * k, r = 0.9 * k, e = 1.3 * k }
		p.armR = { p = 0.5 * k, r = 0.9 * k, e = 1.3 * k }
		p.head = { roll = 0.2 * k, pitch = 0.1 }
		return p
	end)
	pc:still(1.8, function(u, c)
		local k = math.sin(math.clamp(u / 1.8, 0, 1) * PI)
		return { lean = 0.5 * k, head = { pitch = -0.3 * k }, armL = { p = -0.4 * k, r = 0.5 * k, e = 0.2 }, armR = { p = 0.6 * k, r = -0.1, e = 1.7 * k } }
	end)
	pc:still(3, P.laugh)
	pc:finish(40, spin)
	table.insert(scene.Plans, pc)

	-- The dough: a ball being kneaded, a spinning disc on his fingertips, the big throw (it grows
	-- as it spins), and the landing round his neck.
	local function hands(): Vector3
		local b = chef.Bones
		if not b then
			return ctx:R(CX, 300, CZ)
		end
		return b.GripL.Position:Lerp(b.GripR.Position, 0.5)
	end
	local tossFrom: Vector3? = nil
	ctx:onUpdate(function(t)
		ball.Transparency = if t < SPIN then 0 else 1
		if t < SPIN then
			dough.Transparency = 1
			return
		end
		dough.Transparency = 0
		local b = chef.Bones
		if t < TOSS + 0.45 then
			local k = (t - SPIN) / (TOSS + 0.45 - SPIN)
			local hop = math.abs(math.sin((t - SPIN) * 3.2 * 1.6)) * 40
			dough.Size = V(5, 60 + 30 * k, 60 + 30 * k)
			dough.CFrame = CFrame.new(hands() + Vector3.new(0, 14 + hop, 0)) * CFrame.Angles(-0.35, 0, 0) * CFrame.Angles(0, t * 14, 0) * CFrame.Angles(0, 0, PI / 2)
			tossFrom = dough.Position
		elseif t < LANDD then
			local k = (t - TOSS - 0.45) / (LANDD - TOSS - 0.45)
			local from = tossFrom or hands()
			local to = if b then (b.Torso * CFrame.new(0, 0.95 * S, 0)).Position else from
			local pos = from:Lerp(to, k) + Vector3.new(0, 4 * 330 * k * (1 - k), 0)
			local d = 90 + 110 * smooth(k)
			dough.Size = V(5, d, d)
			dough.CFrame = CFrame.new(pos) * CFrame.Angles(0, t * 16, 0) * CFrame.Angles(0.15 * math.sin(t * 5), 0, PI / 2)
		else
			-- the poncho: round his shoulders, bobbing with him
			dough.Size = V(6, 200, 200)
			if b then
				dough.CFrame = b.Torso * CFrame.new(0, 0.92 * S, 0) * CFrame.Angles(0, 0, PI / 2)
			end
		end
	end)

	-- The waiter: through the door with the lunch plates, laughs, loads the dishwasher.
	local waiter = scene:actor("Waiter", "Waiter")
	local pw = R.newPlan(waiter, 950, 220, -PI / 2)
	scene:prop("Stack", "SauceStack")
	local carry = { Stack = { "both", off = CFrame.new(0, -4, -10) } }
	pw:still(TOSS - 2.8, P.carry, carry) -- out of sight in the dining room until he comes in
	pw:walk({ V2(470, 220) }, carry, P.carry, 150)
	pw:turn(-PI / 2 - 0.5, carry, P.carry)
	pw:still(LANDD - pw.T + 0.3, P.carry, carry)
	local function laughCarry(u: number, c: any): any
		local p = P.carry(u, c)
		local l = P.laugh(u, c)
		p.lean, p.head, p.bob = l.lean, l.head, l.bob
		return p
	end
	pw:still(4.2, laughCarry, carry)
	pw:walk({ V2(300, 380), V2(260 - 95, ZF - 72) }, carry, P.carry, 160)
	pw:turn(0, carry, P.carry)
	local beats = Kit.loadDishwasher(ctx, pw, dw, "Stack")
	pw:still(3, P.idle)
	pw:finish(40, P.idle)
	table.insert(scene.Plans, pw)

	-- Camera.
	local chefHead = Kit.follow(chef, "Head")
	ctx:shot(0, SPIN, { eye = { ctx:R(420, 380, -420), ctx:R(340, 350, -340) }, look = { ctx:R(-60, 200, 380), ctx:R(-40, 210, 360) }, fov = { 52, 48 } })
	ctx:shot(SPIN, TOSS + 0.3, { eye = { ctx:R(70, 330, 50), ctx:R(60, 335, 70) }, look = { ctx:R(0, 280, 330), ctx:R(0, 290, 330) }, fov = { 40, 38 } })
	ctx:shot(TOSS + 0.3, LANDD + 0.3, { eye = { ctx:R(170, 190, -170), ctx:R(160, 200, -150) }, look = function()
		return dough.Position
	end, fov = { 52, 58 }, ease = "linear" })
	ctx:shot(LANDD + 0.3, LANDD + 3.2, { eye = { ctx:R(40, 270, 90), ctx:R(35, 265, 110) }, look = chefHead, fov = { 38, 34 } })
	ctx:shot(LANDD + 3.2, LANDD + 4.6, { eye = { ctx:R(300, 270, 40), ctx:R(310, 265, 60) }, look = Kit.follow(waiter, "Head"), fov = { 38, 36 } })
	ctx:shot(LANDD + 4.6, beats.Open - 0.6, { eye = { ctx:R(-160, 380, -140), ctx:R(-110, 360, -90) }, look = Kit.follow(waiter, "Torso"), fov = { 48, 44 }, ease = "linear" })
	Kit.endingShots(ctx, dw, beats, 1)
	return ctx
end

----------------------------------------------------------------------------------------------------
-- Chapter 2: The Food Critic
----------------------------------------------------------------------------------------------------

-- A candle in a straw-wrapped bottle, flickering.
local function candle(ctx: any, x: number, h: number, z: number)
	ctx:post("Bottle", 16, 30, x, h, z, rgb(40, 110, 60), Enum.Material.Glass)
	ctx:post("Straw", 18, 14, x, h, z, rgb(210, 180, 110), Enum.Material.Fabric)
	ctx:post("Wax", 6, 16, x, h + 30, z, rgb(250, 246, 236))
	local flame = ctx:box("Flame", V(5, 9, 5), ctx:at(x, h + 51, z), rgb(255, 200, 90), Enum.Material.Neon, "Sphere")
	flame.CastShadow = false
	local l = Instance.new("PointLight")
	l.Color = rgb(255, 180, 100)
	l.Range = 34
	l.Brightness = 1.6
	l.Parent = flame
	local ph = x * 0.1
	ctx:onUpdate(function(t)
		l.Brightness = 1.4 + 0.3 * math.sin(t * 11 + ph) * math.sin(t * 6.7 + ph)
	end)
end

local function foodCritic(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 30)
	Kit.title(ctx, 2, "The Food Critic")
	ctx:mood({ ClockTime = 21, Brightness = 0.8, ExposureCompensation = 0.3, Ambient = rgb(90, 64, 60), OutdoorAmbient = rgb(80, 70, 90) })
	local scene = ctx.Scene

	-- The dining room: dark red walls, wood panelling, a mural, string lights.
	local ZW = 620
	Kit.floor(ctx, -720, 720, -700, ZW + 8, rgb(130, 86, 56), Enum.Material.WoodPlanks, 70)
	local wall, trim = rgb(130, 40, 44), rgb(90, 56, 36)
	-- the back wall has the kitchen door in it (left)
	Kit.wall(ctx, -700, ZW, -500, ZW, 700, wall, nil, trim)
	Kit.wall(ctx, -340, ZW, 700, ZW, 700, wall, nil, trim)
	ctx:box("Lintel", V(160, 370, 16), ctx:at(-420, 515, ZW), wall)
	Kit.wall(ctx, -700, -700, -700, ZW, 700, wall, nil, trim)
	Kit.wall(ctx, 700, -700, 700, ZW, 700, wall, nil, trim)
	ctx:box("Panelling", V(1040, 170, 18), ctx:at(180, 85, ZW - 1), rgb(110, 70, 44), Enum.Material.Wood)
	ctx:box("Panelling", V(200, 170, 18), ctx:at(-600, 85, ZW - 1), rgb(110, 70, 44), Enum.Material.Wood)
	-- the kitchen beyond the door: bright tiles and the chef
	ctx:box("KitchenBack", V(300, 700, 10), ctx:at(-420, 350, ZW + 260), rgb(244, 244, 238))
	ctx:box("KitchenFloor", V(300, 8, 260), ctx:at(-420, -4, ZW + 130), rgb(240, 240, 236))
	ctx:box("KitchenSide", V(10, 700, 260), ctx:at(-570, 350, ZW + 130), rgb(244, 244, 238))
	ctx:box("KitchenSide", V(10, 700, 260), ctx:at(-270, 350, ZW + 130), rgb(244, 244, 238))
	ctx:light(-420, 420, ZW + 120, rgb(255, 250, 230), 60, 1.6, 20)
	for _, dx in { -85, 85 } do
		ctx:box("DoorFrame", V(16, 330, 24), ctx:at(-420 + dx, 165, ZW), trim, Enum.Material.Wood)
	end
	Kit.ceiling(ctx, -720, 720, -700, ZW, 700, rgb(70, 44, 32), Enum.Material.Wood)
	-- the mural of the old country
	ctx:box("MuralFrame", V(420, 230, 6), ctx:at(80, 440, ZW - 11), rgb(200, 160, 70), Enum.Material.Wood)
	ctx:box("MuralSky", V(400, 120, 4), ctx:at(80, 495, ZW - 14), rgb(120, 190, 240))
	ctx:box("MuralSea", V(400, 90, 4), ctx:at(80, 390, ZW - 14.5), rgb(40, 110, 190))
	ctx:box("MuralSun", V(2, 60, 60), ctx:at(180, 510, ZW - 17) * CFrame.Angles(0, PI / 2, 0), rgb(255, 214, 80), Enum.Material.Neon, "Cylinder")
	ctx:box("MuralHill", V(2, 200, 200), ctx:at(-40, 380, ZW - 16) * CFrame.Angles(0, PI / 2, 0), rgb(120, 170, 80), nil, "Cylinder")
	for i = 0, 3 do
		ctx:box("MuralHouse", V(24, 30, 3), ctx:at(-80 + i * 26, 450 + (i % 2) * 10, ZW - 17), ({ rgb(250, 220, 170), rgb(240, 150, 110), rgb(250, 250, 240), rgb(250, 200, 120) })[i + 1])
	end
	-- string lights across the room
	for row = 0, 1 do
		for i = 0, 13 do
			local x = -650 + i * 100
			local sag = math.sin(i / 13 * PI) * 50
			local b = ctx:box("StringLight", V(12, 16, 12), ctx:at(x, 640 - sag - row * 40, 150 + row * 300), rgb(255, 214, 140), Enum.Material.Neon, "Sphere")
			b.CastShadow = false
		end
	end
	-- the bar on the right with its glass washer
	local ZF = 480
	local top = Kit.counter(ctx, 180, 700, ZF, { Gaps = { { 265, 395 } }, Body = rgb(110, 70, 44), BodyMat = Enum.Material.Wood, Door = rgb(124, 80, 50), Top = rgb(40, 30, 26), TopMat = Enum.Material.Marble, Splash = rgb(90, 56, 36), SplashMat = Enum.Material.Wood })
	local dw = Kit.dishwasher(ctx, 330, ZF, 0, { Mess = rgb(200, 50, 36) })
	ctx:box("BarShelf", V(480, 8, 40), ctx:at(450, 420, ZW - 28), rgb(90, 56, 36), Enum.Material.Wood)
	for i = 0, 9 do
		local bx = 240 + i * 46
		ctx:post("BarBottle", 18, 50 + (i % 3) * 8, bx, 424, ZW - 28, ({ rgb(60, 120, 60), rgb(150, 60, 40), rgb(200, 170, 80), rgb(60, 60, 120) })[i % 4 + 1], Enum.Material.Glass)
	end
	for _, sx in { 460, 560 } do
		ctx:light(sx, 360, ZW - 40, rgb(255, 200, 140), 50, 1.2, 12)
	end

	-- Tables.
	local cloth = rgb(200, 44, 44)
	Kit.table(ctx, 0, 190, 170, 150, TABLE, rgb(90, 56, 36), cloth)
	Kit.table(ctx, -480, 110, 170, 150, TABLE, rgb(90, 56, 36), cloth)
	Kit.table(ctx, 420, 180, 170, 150, TABLE, rgb(90, 56, 36), cloth)
	candle(ctx, -40, TABLE, 220)
	candle(ctx, -480, TABLE, 130)
	candle(ctx, 460, TABLE, 210)
	local criticSeat = Kit.chair(ctx, "CriticChair", 0, 300, PI)
	local g1Seat = Kit.chair(ctx, "G1Chair", -600, 110, PI / 2)
	local g2Seat = Kit.chair(ctx, "G2Chair", -360, 110, -PI / 2)
	scene:prop("Stack", "SauceStack")
	scene:place("Stack", 0, 1e5 - 1, ctx:at(430, TABLE + 1, 160)) -- trimmed at pick-up
	for i, px in { -540, -420 } do
		scene:prop("GPlate" .. i, "PizzaPlate")
		scene:place("GPlate" .. i, 0, 1e5 - 1, ctx:at(px, TABLE + 1, 110))
	end

	-- The diners at the side table.
	for i, st in { g1Seat, g2Seat } do
		local g = scene:actor("Guest" .. i, "Guest" .. i)
		local pg = R.newPlan(g, 0, 0, 0)
		R.seated(pg, st)
		scene:prop("GFork" .. i, "Fork")
		local fork = { ["GFork" .. i] = R.FORK_HOLD }
		pg:still(9.5 + i * 0.3, P.eat, fork)
		pg:still(4.5 - i * 0.3, function(u, c)
			local p = P.rest(u, c)
			p.head = { yaw = (if i == 1 then 0.9 else -0.9), pitch = 0.05 }
			return p
		end)
		pg:still(5, P.clap)
		pg:still(4, P.talkTo(if i == 1 then 0.5 else -0.5))
		pg:finish(40, P.eat)
		pg.Steps[#pg.Steps].Hold = fork
		table.insert(scene.Plans, pg)
	end

	-- The critic.
	local critic = scene:actor("Critic", "Critic")
	local pc = R.newPlan(critic, 0, 0, 0)
	R.seated(pc, criticSeat)
	scene:prop("Pad", "Notepad")
	scene:prop("Pencil", "Pencil")
	scene:prop("CriticPizza", "PizzaPlate")
	scene:prop("CriticSlice", "Slice")
	scene:prop("Card", "ScoreCard")
	local writing = { Pad = { "L", off = CFrame.new(0, 4, -6) * CFrame.Angles(-1.1, 0, 0) }, Pencil = { "Rhand", off = CFrame.Angles(PI / 2, 0, 0) } }
	local function write(u: number, c: any): any
		local s = c.Actor.S
		local w = math.sin(u * 8) * 4
		return {
			bob = R.breathe(u),
			head = { pitch = -0.35, yaw = math.sin(u * 0.4) * 0.1 },
			armL = { at = local3(c, -0.35 * s, TABLE + 40, 1.3 * s) },
			armR = { at = local3(c, -0.05 * s + w, TABLE + 44, 1.3 * s) },
		}
	end
	pc:still(5.6, write, writing)
	-- he puts the pad down and eyes the pizza
	pc:still(1.2, function(u, c)
		local p = P.rest(u, c)
		p.head = { pitch = -0.3, yaw = 0 }
		return p
	end)
	scene:place("Pad", 5.7, 1e5 - 1, ctx:at(60, TABLE + 1, 230, 0.3) * CFrame.Angles(0, 0, 0) * CFrame.new(0, 1, 0) * CFrame.Angles(PI / 2, 0, 0))
	local sliceHold = { CriticSlice = { "R", off = CFrame.new(0, 0, 5) * CFrame.Angles(0.5, 0, 0), scale = function(u)
		return math.max(0.45, 1 - u / 3 * 0.55)
	end } }
	local TASTE = pc.T
	pc:swap(0.9, P.reachOne(1.4 * S, TABLE + 12, 0.9), nil, sliceHold)
	pc:still(3.0, P.bite, sliceHold)
	-- ...the longest pause in history...
	local PAUSE = pc.T
	pc:still(1.9, function(u, c)
		local s = c.Actor.S
		return {
			head = { pitch = 0.15 + math.sin(u * 2) * 0.03, yaw = 0 },
			armL = { at = local3(c, -0.6 * s, TABLE + 24, 1.2 * s) },
			armR = { at = local3(c, 0.45 * s, TABLE + 60, 1.0 * s) },
		}
	end, sliceHold)
	-- up he gets, and holds up his card: 10!
	local VERDICT = pc.T
	pc:standUp(V2(-130, 300), nil, true)
	pc:turn(PI)
	pc:swap(0.5, P.idle, nil, { Card = { "R", off = CFrame.new(0, 26, 0) * CFrame.Angles(0, -PI / 2, 0) } })
	local card = { Card = { "R", off = CFrame.new(0, 26, 0) * CFrame.Angles(0, -PI / 2, 0) } }
	pc:still(3.5, function(u, c)
		local p = P.idle(u, c)
		p.armR = { p = 2.9, r = 0.1 + math.sin(u * 6) * 0.05, e = 0.1 }
		p.head = { pitch = 0.2 }
		return p
	end, card)
	pc:still(3, P.clap)
	pc:finish(40, P.idle)
	table.insert(scene.Plans, pc)
	scene:place("CriticPizza", 0, 1e5 - 1, ctx:at(0, TABLE + 1, 215))

	-- The chef (still in his dough poncho from last time) peeks through the kitchen door.
	local chef = scene:actor("Chef", "Chef")
	local pch = R.newPlan(chef, -420, ZW + 60, PI)
	local poncho = ctx:box("Poncho", V(6, 200, 200), CFrame.new(), rgb(246, 226, 180), nil, "Cylinder")
	ctx:onUpdate(function()
		local b = chef.Bones
		if b then
			poncho.CFrame = b.Torso * CFrame.new(0, 0.92 * S, 0) * CFrame.Angles(0, 0, PI / 2)
		end
	end)
	local function fret(u: number, c: any): any
		local s = c.Actor.S
		return {
			bob = math.sin(u * 7) * 0.01,
			lean = 0.1,
			head = { pitch = 0.05, yaw = math.sin(u * 1.3) * 0.1 },
			armL = { at = function(b)
				return (b.Head * CFrame.new(-0.3 * s, -0.4 * s, -0.8 * s)).Position
			end },
			armR = { at = function(b)
				return (b.Head * CFrame.new(0.3 * s, -0.4 * s, -0.8 * s)).Position
			end },
		}
	end
	pch:still(VERDICT + 1.2, fret)
	-- he bursts out cheering
	pch:walk({ V2(-340, 440) }, nil, function(u, c)
		local k = math.sin(u * 9)
		return { armL = { p = 2.7, r = 0.3 + k * 0.1, e = 0.2 }, armR = { p = 2.7, r = 0.3 - k * 0.1, e = 0.2 }, head = { pitch = 0.2 } }
	end, 190)
	pch:still(4, function(u, c)
		local k = math.sin(u * 9)
		return { bob = math.abs(math.sin(u * 5)) * 0.18, armL = { p = 2.7, r = 0.35 + k * 0.1, e = 0.2 }, armR = { p = 2.7, r = 0.35 - k * 0.1, e = 0.2 }, head = { pitch = 0.25 } }
	end)
	pch:finish(40, P.laugh)
	table.insert(scene.Plans, pch)

	-- The waiter serves (very nervously), then clears up at the bar.
	local waiter = scene:actor("Waiter", "Waiter")
	local pw = R.newPlan(waiter, -420, ZW + 30, PI)
	local served = { CriticPizza = { "both", off = CFrame.new(0, -4, -10) } }
	pw:still(0.2, P.carry, served)
	pw:walk({ V2(-300, 440), V2(110, 230) }, served, P.carry, 190)
	pw:turn(-PI / 2, served, P.carry)
	local SERVE = pw.T
	pw:swap(1.0, P.reach(-0.25 * S, TABLE + 12, 1.1 * S, 0.25 * S, TABLE + 12, 1.1 * S, 1.0, 0.3), served, nil)
	scene.Placements.CriticPizza[1][1] = SERVE + 0.5
	pw:walk({ V2(250, 230) }, nil, nil, 70, true)
	pw:turn(-PI / 2 - 0.4)
	local function nervous(u: number, c: any): any
		local s = c.Actor.S
		return {
			bob = math.sin(u * 12) * 0.006,
			head = { yaw = math.sin(u * 0.8) * 0.1, pitch = -0.05 },
			armL = { at = local3(c, -0.05 * s, 175, 0.55 * s) },
			armR = { at = local3(c, 0.05 * s, 175, 0.55 * s) },
		}
	end
	pw:still(VERDICT + 1.3 - pw.T, nervous)
	pw:still(3.2, function(u, c)
		local k = math.sin(u * 9)
		return { bob = math.abs(math.sin(u * 5)) * 0.1, armL = { p = 2.7, r = 0.35 + k * 0.1, e = 0.2 }, armR = { p = 2.7, r = 0.35 - k * 0.1, e = 0.2 }, head = { pitch = 0.25 } }
	end)
	-- the plates from the last table
	pw:walk({ V2(340, 170) }, nil, nil, 130)
	pw:turn(PI / 2)
	local PICK = pw.T
	pw:swap(1.0, P.reach(-0.25 * S, TABLE + 12, 1.5 * S, 0.25 * S, TABLE + 12, 1.5 * S, 1.0, 0.3), nil, { Stack = { "both", off = CFrame.new(0, -4, -10) } })
	scene.Placements.Stack[1][2] = PICK + 0.5
	local carry = { Stack = { "both", off = CFrame.new(0, -4, -10) } }
	pw:walk({ V2(240, 330), V2(330 - 95, ZF - 72) }, carry, P.carry, 150)
	pw:turn(0, carry, P.carry)
	local beats = Kit.loadDishwasher(ctx, pw, dw, "Stack")
	pw:still(3, P.idle)
	pw:finish(40, P.idle)
	table.insert(scene.Plans, pw)

	-- Camera.
	local criticHead = Kit.follow(critic, "Head")
	ctx:shot(0, 3.4, { eye = { ctx:R(-80, 430, -520), ctx:R(-40, 390, -430) }, look = { ctx:R(-40, 190, 380), ctx:R(-20, 190, 360) }, fov = { 52, 48 } })
	ctx:shot(3.4, SERVE + 1.0, { eye = { ctx:R(330, 280, -40), ctx:R(300, 270, -20) }, look = Kit.follow(waiter, "Torso"), fov = { 44, 42 }, ease = "linear" })
	ctx:shot(SERVE + 1.0, TASTE, { eye = { ctx:R(-330, 270, 380), ctx:R(-340, 268, 400) }, look = Kit.follow(chef, "Head"), fov = { 34, 32 } })
	ctx:shot(TASTE, PAUSE, { eye = { ctx:R(-250, 270, 10), ctx:R(-235, 262, 40) }, look = { ctx:R(0, 215, 300), ctx:R(0, 215, 300) }, fov = { 42, 36 } })
	ctx:shot(PAUSE, PAUSE + 0.95, { eye = { ctx:R(0, 232, 170), ctx:R(0, 232, 185) }, look = criticHead, fov = { 28, 24 } })
	ctx:shot(PAUSE + 0.95, VERDICT, { eye = { ctx:R(-360, 250, 250), ctx:R(-360, 250, 250) }, look = Kit.follow(chef, "Head"), fov = { 30, 26 } })
	ctx:shot(VERDICT, VERDICT + 4.4, { eye = { ctx:R(40, 150, -60), ctx:R(30, 160, -40) }, look = { ctx:R(-110, 290, 300), ctx:R(-120, 300, 300) }, fov = { 46, 44 } })
	ctx:shot(VERDICT + 4.4, PICK, { eye = { ctx:R(-200, 320, -80), ctx:R(-180, 310, -60) }, look = { ctx:R(-200, 250, 420), ctx:R(-220, 250, 420) }, fov = { 50, 48 } })
	ctx:shot(PICK, beats.Open - 0.6, { eye = { ctx:R(-60, 380, -140), ctx:R(-20, 360, -100) }, look = Kit.follow(waiter, "Torso"), fov = { 48, 44 }, ease = "linear" })
	Kit.endingShots(ctx, dw, beats, 1)
	return ctx
end

return {
	doughShow,
	foodCritic,
}
