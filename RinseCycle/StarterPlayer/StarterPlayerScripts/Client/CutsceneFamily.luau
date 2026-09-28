--[[
	CutsceneFamily - the Family Dinner level's story, one chapter per run (see CutsceneKit).

	  1. Pancake Morning: a sunny kitchen. Dad flips a pancake so high it lands on his head; the
	     family falls about laughing; he eats it anyway and loads the breakfast plates.
	  2. Backyard Barbecue: the garden. Dad grills (wearing the pancake apron from chapter 1),
	     Grandpa naps in a deck chair, the kid's ball lands in the salad; Mum clears up.
	  3. Birthday Surprise: the living room at night. The lights go down, Mum brings in the cake,
	     the kid blows out the candles, cake everywhere; Grandpa does the dishes for once.
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
local disc = R.disc

-- Props the family chapters need (placed / held like LevelNPCs' props).
PROPS.Pan = function()
	-- held by the end of the handle; the pan is forward (-Z)
	return {
		{ V(6, 4, 44), C(0, 0, -22), rgb(40, 40, 44) },
		disc(64, 5, 0, rgb(50, 50, 56), Enum.Material.Metal, 0, -70),
		disc(56, 5.4, 0.6, rgb(30, 30, 34), nil, 0, -70),
	}
end
PROPS.Pancake = function()
	return {
		disc(42, 6, 0, rgb(226, 170, 90)),
		disc(34, 6.4, 0.3, rgb(240, 196, 120)),
		{ V(14, 1, 10), C(-6, 3.4, 4), rgb(200, 140, 60), nil, "Sphere" },
	}
end
PROPS.PancakePlate = function()
	local t = { disc(58, 3, 1.5, rgb(250, 250, 248)), disc(48, 3.2, 1.7, rgb(236, 240, 246)) }
	for i = 0, 2 do
		table.insert(t, disc(40 - i * 2, 5, 6 + i * 5.5, rgb(226, 170, 90)))
	end
	table.insert(t, disc(26, 2, 22, rgb(150, 80, 30)))
	table.insert(t, { V(10, 6, 10), C(0, 25, 0), rgb(255, 240, 180) })
	return t
end
PROPS.SyrupStack = function()
	local t = {}
	for i = 0, 3 do
		table.insert(t, disc(52, 2.4, 1.2 + i * 3.4, rgb(250, 250, 248)))
		table.insert(t, { V(16, 1.2, 12), C(-8 + i * 5, 2.8 + i * 3.4, 5 - i * 3), rgb(150, 80, 30), nil, "Sphere" })
	end
	table.insert(t, { V(4, 2, 40), C(12, 15, 0) * CFrame.Angles(0, 0.4, 0), rgb(200, 204, 210), Enum.Material.Metal })
	return t
end
PROPS.Syrup = function()
	return {
		{ V(16, 34, 16), C(0, 17, 0), rgb(150, 80, 30), Enum.Material.Glass, "Cylinder", 0.1 },
		{ V(8, 8, 8), C(0, 38, 0), rgb(220, 60, 60) },
		{ V(17, 12, 1), C(0, 18, -8.2), rgb(250, 240, 210) },
	}
end

----------------------------------------------------------------------------------------------------
-- Chapter 1: Pancake Morning
----------------------------------------------------------------------------------------------------

local function pancakeMorning(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 27.5)
	Kit.title(ctx, 1, "Pancake Morning")
	ctx:mood({ ClockTime = 9.5, Brightness = 2.4, ExposureCompensation = -0.1, Ambient = rgb(120, 110, 100), OutdoorAmbient = rgb(150, 140, 130) })
	local scene = ctx.Scene

	-- The kitchen.
	local ZW = 620 -- back wall
	local ZF = 482 -- cabinet fronts
	Kit.room(ctx, {
		X0 = -560, X1 = 560, Z0 = -700, Z1 = ZW, H = 700,
		Floor = rgb(196, 146, 98), FloorMat = Enum.Material.WoodPlanks, Planks = 64,
		Wall = rgb(250, 236, 206), Stripe = rgb(170, 214, 230), StripeH = 160,
	})
	Kit.fridge(ctx, -490, ZF)
	local top = Kit.counter(ctx, -420, 520, ZF, { Gaps = { { -362, -238 }, { 135, 265 } }, Body = rgb(120, 170, 200), Door = rgb(134, 184, 212), Top = rgb(236, 232, 224) })
	Kit.stove(ctx, -300, ZF, top, true)
	ctx:box("Hood", V(150, 60, 110), ctx:at(-300, 420, ZW - 55), rgb(210, 214, 220), Enum.Material.Metal)
	ctx:box("HoodPipe", V(40, 200, 40), ctx:at(-300, 550, ZW - 30), rgb(210, 214, 220), Enum.Material.Metal)
	Kit.sink(ctx, -60, ZF, top)
	Kit.window(ctx, -60, 430, ZW, 200, 180, "day", rgb(255, 214, 90))
	Kit.upper(ctx, 110, 520, ZW, 330, { Body = rgb(120, 170, 200), Door = rgb(134, 184, 212) })
	local dw = Kit.dishwasher(ctx, 200, ZF, 0, { Mess = rgb(150, 80, 30) })
	-- a wall clock and a shelf of jars
	ctx:post("Clock", 70, 6, -470, 520, ZW - 12, rgb(250, 250, 248))
	ctx:box("ClockHand", V(3, 26, 2), ctx:at(-470, 530, ZW - 20), rgb(40, 40, 44))
	ctx:box("ClockHand", V(20, 3, 2), ctx:at(-462, 520, ZW - 20), rgb(40, 40, 44))
	ctx:box("Shelf", V(160, 8, 40), ctx:at(-470 + 330, 540, ZW - 26), rgb(160, 110, 70), Enum.Material.Wood)
	for i = 0, 3 do
		ctx:post("Jar", 26, 30 + (i % 2) * 10, -200 + i * 40, 544, ZW - 26, ({ rgb(240, 120, 90), rgb(250, 220, 120), rgb(140, 200, 120), rgb(200, 160, 240) })[i + 1])
	end
	Kit.plant(ctx, 500, 300, 180)
	Kit.rug(ctx, -40, 120, 520, 360, rgb(230, 120, 90), rgb(200, 90, 70))

	-- The breakfast table.
	Kit.table(ctx, -40, 120, 300, 170, TABLE, rgb(184, 134, 88), rgb(250, 250, 244))
	local kidSeat = Kit.chair(ctx, "KidChair", -125, 232, PI, "FurnKidChair")
	local mumSeat = Kit.chair(ctx, "MumChair", 50, 232, PI)
	Kit.chair(ctx, "DadChair", -40, 10, 0)
	local function onTable(name: string, kind: string, x: number, z: number, yaw: number?)
		scene:prop(name, kind)
		scene:place(name, 0, 1e5 - 1, ctx:at(x, TABLE + 1, z, yaw))
	end
	onTable("KidPlate", "PancakePlate", -122, 157)
	onTable("MumPlate", "PancakePlate", 48, 157)
	onTable("DadPlate", "Plate", -40, 78)
	onTable("SyrupBottle", "Syrup", -30, 125)
	onTable("OJ", "Glass", -2, 162)
	scene:prop("KidFork", "Fork")
	scene:prop("Paper", "Newspaper")
	scene:prop("Stack", "SyrupStack")
	scene:place("Stack", 0, 1e5 - 1, ctx:at(78, TABLE + 1, 120)) -- trimmed when Dad picks it up

	-- The kid: tucks in, cracks up, tucks in again, waves at the end.
	local kid = scene:actor("Kid", "Kid")
	local pk = R.newPlan(kid, 0, 0, 0)
	R.seated(pk, kidSeat)
	local fork = { KidFork = R.FORK_HOLD }
	pk:still(5.6, P.eat, fork)
	pk:still(4.9, P.laugh)
	pk:still(9, P.eat, fork)
	pk:still(3, P.wave)
	pk:finish(40, P.eat)
	pk.Steps[#pk.Steps].Hold = fork
	table.insert(scene.Plans, pk)

	-- Mum: reads the paper, then can't stop laughing.
	local mum = scene:actor("Mum", "Mum")
	local pm = R.newPlan(mum, 0, 0, 0)
	R.seated(pm, mumSeat)
	local paperUp = { Paper = { "both", off = CFrame.new(0, 12, -6) } }
	local paperDown = { Paper = { "both", off = CFrame.new(0, -2, -10) * CFrame.Angles(-PI / 2, 0, 0) } }
	pm:still(5.5, P.read, paperUp)
	pm:still(0.8, P.startle, paperDown)
	pm:still(4.4, P.laugh, paperDown)
	pm:still(3, P.talkTo(0.6), paperDown)
	pm:still(8, P.read, paperUp)
	pm:finish(40, P.read)
	pm.Steps[#pm.Steps].Hold = paperUp
	table.insert(scene.Plans, pm)

	-- Dad: at the stove.
	local dad = scene:actor("Dad", "Dad")
	local DX, DZ = -300, 408
	local pd = R.newPlan(dad, DX, DZ, 0)
	scene:prop("Pan", "Pan")
	scene:prop("PanCake", "Pancake")
	scene:prop("HeadCake", "Pancake")
	scene:prop("HandCake", "Pancake")
	local pan = { "R", off = CFrame.new(0, -2, 0) }
	local cooking = { Pan = pan, PanCake = { "R", off = CFrame.new(0, 2, -70) } }
	local function cook(u: number, c: any): any
		local s = c.Actor.S
		local jig = math.sin(u * 5)
		return {
			bob = R.breathe(u),
			head = { pitch = -0.3, yaw = math.sin(u * 0.7) * 0.1 },
			armR = { at = local3(c, 0.4 * s + jig * 4, 186 + math.abs(jig) * 3, 0.95 * s) },
			armL = { p = 0.35, r = 0.55, e = 1.9 },
		}
	end
	pd:still(4.0, cook, cooking)
	-- the flip: a dip and a big flick up
	local FLIP = pd.T
	pd:still(0.8, function(u, c)
		local s = c.Actor.S
		local k = u / 0.8
		local lift = if k < 0.35 then -smooth(k / 0.35) * 10 else smooth((k - 0.35) / 0.3) * 60
		return {
			lean = -0.08 * smooth(k),
			head = { pitch = -0.3 + 0.9 * smooth((k - 0.3) / 0.5) },
			armR = { at = local3(c, 0.4 * s, 186 + lift, 0.95 * s + lift * 0.4) },
			armL = { p = 0.35, r = 0.55, e = 1.9 },
		}
	end, { Pan = { "R", off = function(u)
		local k = u / 0.8
		return CFrame.new(0, -2, 0) * CFrame.Angles(if k > 0.35 and k < 0.7 then 0.5 else 0, 0, 0)
	end } })
	local LAUNCH = FLIP + 0.45
	pd:split(pd.Steps[#pd.Steps], 0.45, { Pan = pan })
	-- the pancake flies up... and comes down on his head
	local LAND = LAUNCH + 1.35
	local flyer = ctx:box("FlyCake", V(6, 42, 42), ctx:at(0, 0, 0) * CFrame.Angles(0, 0, PI / 2), rgb(226, 170, 90), nil, "Cylinder")
	flyer.Transparency = 1
	local fromP = ctx:R(DX + 20, 196, DZ + 110)
	local toP = ctx:R(DX, 268, DZ)
	ctx:onUpdate(function(t)
		if t < LAUNCH or t >= LAND then
			flyer.Transparency = 1
			return
		end
		local k = (t - LAUNCH) / (LAND - LAUNCH)
		local pos = fromP:Lerp(toP, k) + Vector3.new(0, 4 * 330 * k * (1 - k), 0)
		flyer.Transparency = 0
		flyer.CFrame = CFrame.new(pos) * CFrame.Angles(k * PI * 5, 0, 0) * CFrame.Angles(0, 0, PI / 2)
	end)
	local wearing = { Pan = pan, HeadCake = { "Head", off = CFrame.new(0, 43, 2) * CFrame.Angles(0.12, 0, 0.1) } }
	local waitStep = pd.T
	pd:still(LAND - waitStep, function(u, c)
		local s = c.Actor.S
		return {
			head = { pitch = 0.7 },
			armR = { at = local3(c, 0.4 * s, 240, 1.0 * s) },
			armL = { p = 0.35, r = 0.55, e = 1.9 },
		}
	end, { Pan = pan })
	-- splat!
	pd:still(1.2, P.startle, wearing)
	pd:turn(PI, wearing, function(u, c)
		return { armR = { p = 0.4, r = 0.1, e = 0.9 } }
	end)
	-- a shrug and a laugh with the pancake on his head
	pd:still(1.5, function(u, c)
		local p = P.laugh(u, c)
		p.armR = { p = 0.4, r = 0.35, e = 1.2 }
		p.armL = { p = 0.3, r = 0.7, e = 1.0 }
		return p
	end, wearing)
	-- peel it off and eat it
	local PEEL = pd.T
	pd:still(1.7, function(u, c)
		local s = c.Actor.S
		local k = u / 1.7
		return {
			head = { pitch = if k < 0.4 then 0.35 else -0.05 },
			armR = { p = 0.4, r = 0.1, e = 0.9 },
			armL = { at = function(b)
				local topOfHead = (b.Head * CFrame.new(-0.1 * s, 0.75 * s, 0)).Position
				local mouth = (b.Head * CFrame.new(-0.2 * s, -0.25 * s, -0.8 * s)).Position
				local chin = (b.Torso * CFrame.new(-0.6 * s, 0.2 * s, -0.9 * s)).Position
				if k < 0.3 then
					return chin:Lerp(topOfHead, smooth(k / 0.3))
				end
				return topOfHead:Lerp(mouth, smooth((k - 0.35) / 0.3))
			end },
		}
	end, wearing)
	pd:split(pd.Steps[#pd.Steps], 0.55, { Pan = pan, HandCake = { "L", off = CFrame.new(0, -2, -4) * CFrame.Angles(PI / 2, 0, 0) } })
	pd:split(pd.Steps[#pd.Steps], 0.9, { Pan = pan })
	-- pan back on the hob
	pd:turn(0, { Pan = pan })
	local PUT = pd.T
	pd:swap(0.8, P.reachOne(1.6 * S, top + 8, 0.8), { Pan = pan }, nil)
	scene:place("Pan", PUT + 0.4, 1e5 - 1, ctx:at(DX + 20, top + 6, DZ + 150))
	-- over to the end of the table for the dirty plates
	pd:walk({ V2(130, 380), V2(150, 120) }, nil, nil, 170)
	pd:turn(-PI / 2)
	local PICK = pd.T
	pd:swap(1.0, P.reach(-0.25 * S, TABLE + 12, 1.55 * S, 0.25 * S, TABLE + 12, 1.55 * S, 1.0, 0.35), nil, { Stack = { "both", off = CFrame.new(0, -4, -10) } })
	scene.Placements.Stack[1][2] = PICK + 0.5
	local carry = { Stack = { "both", off = CFrame.new(0, -4, -10) } }
	pd:walk({ V2(200, 250), V2(105, ZF - 72) }, carry, P.carry, 170)
	pd:turn(0, carry, P.carry)
	local beats = Kit.loadDishwasher(ctx, pd, dw, "Stack")
	pd:still(1.2, P.idle)
	pd:still(3, function(u, c)
		local p = P.idle(u, c)
		p.armR = { p = 1.3, r = 0.2, e = 1.6 } -- a thumbs-up
		return p
	end)
	pd:finish(40, P.idle)
	table.insert(scene.Plans, pd)

	-- Camera.
	local dadHead = Kit.follow(dad, "Head")
	local dadChest = Kit.follow(dad, "Torso")
	-- a wide morning establishing shot, drifting in
	ctx:shot(0, FLIP - 0.3, { eye = { ctx:R(240, 360, -380), ctx:R(170, 330, -290) }, look = { ctx:R(-120, 210, 300), ctx:R(-150, 220, 320) }, fov = { 54, 50 } })
	-- side-on at the stove, then up with the pancake and down onto his head
	ctx:shot(FLIP - 0.3, LAND + 0.25, {
		eye = { ctx:R(-500, 300, 250), ctx:R(-510, 300, 240) },
		look = function(t)
			if t < LAUNCH then
				return fromP:Lerp(ctx:R(DX, 230, DZ + 40), 0.5)
			end
			local k = math.clamp((t - LAUNCH) / (LAND - LAUNCH), 0, 1)
			return fromP:Lerp(toP, k) + Vector3.new(0, 4 * 330 * k * (1 - k) * 0.8, 0)
		end,
		fov = { 44, 50 },
		ease = "linear",
	})
	-- the back of his head wearing the pancake... and he turns round
	ctx:shot(LAND + 0.25, PEEL - 1.6, { eye = { ctx:R(-300, 285, 215), ctx:R(-300, 275, 235) }, look = { ctx:R(-300, 250, 408), ctx:R(-300, 245, 408) }, fov = { 40, 36 } })
	-- the family in stitches
	ctx:shot(PEEL - 1.6, PEEL, { eye = { ctx:R(-40, 250, -130), ctx:R(-40, 245, -100) }, look = { ctx:R(-40, 200, 232), ctx:R(-40, 200, 232) }, fov = { 40, 38 } })
	-- he eats it anyway
	ctx:shot(PEEL, PUT, { eye = { ctx:R(-230, 270, 210), ctx:R(-235, 268, 220) }, look = dadHead, fov = { 34, 32 } })
	ctx:shot(PUT, PICK + 1.0, { eye = { ctx:R(-440, 560, -140), ctx:R(-380, 540, -100) }, look = dadChest, fov = { 50, 46 }, ease = "linear" })
	ctx:shot(PICK + 1.0, beats.Open - 0.6, { eye = { ctx:R(380, 290, 40), ctx:R(360, 280, 100) }, look = dadChest, fov = { 46, 44 }, ease = "linear" })
	Kit.endingShots(ctx, dw, beats, 1)
	return ctx
end


----------------------------------------------------------------------------------------------------
-- Chapter 2: Backyard Barbecue
----------------------------------------------------------------------------------------------------

local LOOKS = R.LOOKS
-- Dad in the barbecue apron with a pancake on it (after chapter 1, the family bought him one).
LOOKS.DadGrill = {
	Shirt = rgb(240, 240, 236), Pants = rgb(70, 90, 130), Sleeves = "short",
	Build = function(a)
		R.hairShort(rgb(92, 60, 36))(a)
		R.apron(a, rgb(214, 70, 60), rgb(190, 50, 44))
		a:piece("Torso", Vector3.new(0.05, 0.62, 0.62), CFrame.new(0, -0.12, -0.58) * CFrame.Angles(0, PI / 2, 0), rgb(226, 170, 90), nil, "Cylinder")
		a:piece("Torso", Vector3.new(0.06, 0.3, 0.3), CFrame.new(0, -0.12, -0.59) * CFrame.Angles(0, PI / 2, 0), rgb(150, 80, 30), nil, "Cylinder")
	end,
}
-- Grandpa in his summer hat.
LOOKS.GrandpaSun = {
	Shirt = rgb(250, 214, 120), Sleeves = "short", Pants = rgb(200, 190, 160),
	Build = function(a)
		a:piece("Head", Vector3.new(1.36, 0.5, 1.32), CFrame.new(0, 0.2, 0.12), rgb(225, 225, 225), nil, "Sphere")
		R.glasses(a)
		a:piece("Head", Vector3.new(0.1, 2.0, 2.0), CFrame.new(0, 0.56, 0) * CFrame.Angles(0, 0, PI / 2), rgb(236, 214, 150), Enum.Material.Fabric, "Cylinder")
		a:piece("Head", Vector3.new(0.5, 1.2, 1.2), CFrame.new(0, 0.8, 0) * CFrame.Angles(0, 0, PI / 2), rgb(236, 214, 150), Enum.Material.Fabric, "Cylinder")
		a:piece("Head", Vector3.new(0.14, 1.24, 1.24), CFrame.new(0, 0.66, 0) * CFrame.Angles(0, 0, PI / 2), rgb(200, 60, 60), Enum.Material.Fabric, "Cylinder")
		for i = 0, 2 do
			a:piece("Torso", Vector3.new(0.3, 0.3, 0.04), CFrame.new(-0.6 + i * 0.6, 0.3 - (i % 2) * 0.5, -0.52), rgb(90, 170, 220), nil, "Ball")
		end
	end,
}
PROPS.SaladStack = function()
	local t = {}
	for i = 0, 3 do
		table.insert(t, disc(52, 2.4, 1.2 + i * 3.4, rgb(250, 250, 248)))
		table.insert(t, { V(14, 2, 10), C(-8 + i * 5, 3 + i * 3.4, 5 - i * 3), rgb(110, 190, 80), nil, "Sphere" })
		table.insert(t, { V(8, 2, 8), C(8 - i * 3, 3 + i * 3.4, -4), rgb(150, 70, 40), nil, "Sphere" })
	end
	return t
end
PROPS.Spatula = function()
	return {
		{ V(4, 3, 50), C(0, 0, -20), rgb(40, 40, 44) },
		{ V(22, 1.5, 24), C(0, -1, -54), rgb(200, 204, 210), Enum.Material.Metal },
	}
end
PROPS.Leaf = function()
	return { { V(26, 4, 20), C(0, 0, 0), rgb(110, 196, 80), nil, "Sphere" } }
end

local function backyardBarbecue(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 28)
	Kit.title(ctx, 2, "Backyard Barbecue")
	ctx:mood({ ClockTime = 14, Brightness = 2.8, ExposureCompensation = -0.15, Ambient = rgb(120, 120, 110), OutdoorAmbient = rgb(150, 150, 140) })
	local scene = ctx.Scene

	-- The garden and the back of the house.
	local ZH = 720
	Kit.grass(ctx, -1400, 1400, -1200, ZH)
	ctx:box("Patio", V(1500, 6, 330), ctx:at(0, 1, ZH - 165), rgb(196, 188, 176), Enum.Material.Slate)
	for i = -7, 7 do
		ctx:box("PatioSeam", V(2, 7, 330), ctx:at(i * 100, 1.2, ZH - 165), rgb(160, 152, 140), Enum.Material.Slate)
	end
	ctx:box("House", V(1600, 780, 40), ctx:at(0, 390, ZH + 20), rgb(184, 96, 72), Enum.Material.Brick)
	ctx:box("Roof", V(1700, 240, 300), ctx:at(0, 900, ZH - 60, PI), rgb(90, 70, 70), Enum.Material.Slate, "Wedge")
	ctx:box("Gutter", V(1700, 16, 24), ctx:at(0, 782, ZH - 200), rgb(236, 236, 232))
	-- patio doors and upstairs windows
	local function pane(x: number, h: number, w: number, hh: number)
		ctx:box("PaneFrame", V(w + 20, hh + 20, 6), ctx:at(x, h, ZH - 3), rgb(250, 250, 246))
		ctx:box("Pane", V(w, hh, 4), ctx:at(x, h, ZH - 6), rgb(70, 110, 150), Enum.Material.Glass)
		ctx:box("PaneBar", V(6, hh, 5), ctx:at(x, h, ZH - 8), rgb(250, 250, 246))
	end
	pane(-40, 150, 200, 290)
	pane(-470, 560, 150, 130)
	pane(380, 560, 150, 130)
	ctx:box("DoorStep", V(260, 12, 50), ctx:at(-40, 6, ZH - 25), rgb(170, 164, 156), Enum.Material.Concrete)
	-- the outdoor kitchen along the wall
	local ZF = 580
	local top = Kit.counter(ctx, 160, 640, ZF, { Gaps = { { 315, 445 } }, Body = rgb(206, 196, 182), Door = rgb(186, 176, 162), BodyMat = Enum.Material.Sandstone, Top = rgb(70, 70, 76), TopMat = Enum.Material.Granite, Splash = rgb(184, 96, 72), SplashMat = Enum.Material.Brick })
	Kit.sink(ctx, 550, ZF, top)
	local dw = Kit.dishwasher(ctx, 380, ZF, 0, { Mess = rgb(110, 190, 80) })
	-- hedges, trees, flowers
	for _, b in { { -900, 300 }, { -820, 520 }, { 860, 360 }, { 900, 120 }, { -900, -60 } } do
		Kit.bush(ctx, b[1], b[2], 1.3)
	end
	Kit.tree(ctx, -980, 480, 1.5)
	Kit.tree(ctx, 1000, 420, 1.3)
	for i = 0, 7 do
		local fx = -560 + i * 60
		ctx:post("Stem", 4, 40, fx, 0, 640, rgb(70, 150, 70))
		ctx:box("Flower", V(20, 12, 20), ctx:at(fx, 44, 640), ({ rgb(255, 120, 150), rgb(255, 214, 80), rgb(190, 130, 255) })[i % 3 + 1], nil, "Sphere")
	end

	-- The picnic table with the salad.
	Kit.table(ctx, -40, 140, 330, 150, TABLE, rgb(170, 120, 80))
	ctx:box("Bench", V(330, 12, 40), ctx:at(-40, 92, 30), rgb(170, 120, 80), Enum.Material.Wood)
	for _, bx in { -180, 100 } do
		ctx:box("BenchLeg", V(12, 86, 30), ctx:at(bx, 43, 30), rgb(150, 104, 70), Enum.Material.Wood)
	end
	local BOWL = ctx:R(30, TABLE + 20, 150)
	ctx:post("Bowl", 80, 26, 30, TABLE, 150, rgb(190, 140, 90), Enum.Material.Wood)
	for i = 0, 5 do
		local a = i / 6 * PI * 2
		ctx:box("Lettuce", V(26, 14, 22), ctx:at(30 + math.cos(a) * 16, TABLE + 26, 150 + math.sin(a) * 16), rgb(110, 196, 80), nil, "Sphere")
	end
	ctx:box("Tomato", V(12, 12, 12), ctx:at(24, TABLE + 32, 146), rgb(220, 50, 40), nil, "Ball")
	ctx:box("Tomato", V(12, 12, 12), ctx:at(40, TABLE + 31, 158), rgb(220, 50, 40), nil, "Ball")
	scene:prop("Stack", "SaladStack")
	scene:place("Stack", 0, 1e5 - 1, ctx:at(-160, TABLE + 1, 140))
	for i, px in { -100, 90 } do
		scene:prop("Plate" .. i, "Plate")
		scene:place("Plate" .. i, 0, 1e5 - 1, ctx:at(px, TABLE + 1, 100))
	end

	-- The grill, smoking away.
	local GX, GZ = -340, 330
	ctx:box("GrillCart", V(160, 90, 90), ctx:at(GX, 60, GZ), rgb(50, 52, 58), Enum.Material.Metal)
	for _, lx in { -70, 70 } do
		ctx:box("GrillLeg", V(8, 16, 80), ctx:at(GX + lx, 8, GZ), rgb(40, 40, 44), Enum.Material.Metal)
	end
	ctx:box("GrillBox", V(160, 40, 90), ctx:at(GX, 125, GZ), rgb(30, 30, 34), Enum.Material.Metal)
	local coals = ctx:box("Coals", V(146, 3, 76), ctx:at(GX, 140, GZ), rgb(255, 110, 40), Enum.Material.Neon)
	ctx:box("Grate", V(150, 2, 80), ctx:at(GX, 146, GZ), rgb(110, 110, 116), Enum.Material.Metal)
	ctx:box("SideShelf", V(60, 6, 80), ctx:at(GX - 110, 140, GZ), rgb(150, 150, 156), Enum.Material.Metal)
	Kit.smoke(coals, rgb(225, 225, 225), 5, 20)
	local l = Instance.new("PointLight")
	l.Color = rgb(255, 140, 60)
	l.Range = 30
	l.Brightness = 2
	l.Parent = coals
	local patties = {}
	for i = 0, 2 do
		local pt = ctx:box("Patty", V(8, 34, 34), ctx:at(GX - 45 + i * 45, 151, GZ) * CFrame.Angles(0, 0, PI / 2), rgb(120, 66, 40), nil, "Cylinder")
		table.insert(patties, pt)
	end

	-- Grandpa, asleep on the lounger with the paper over his face.
	local LX, LZ = -660, 250
	ctx:box("Lounger", V(90, 10, 230), ctx:at(LX, 50, LZ - 60), rgb(240, 240, 236))
	ctx:box("LoungerBack", V(90, 150, 10), ctx:at(LX, 110, LZ + 40) * CFrame.Angles(0.55, 0, 0), rgb(240, 240, 236))
	ctx:box("LoungerPad", V(84, 6, 220), ctx:at(LX, 57, LZ - 60), rgb(80, 170, 210), Enum.Material.Fabric)
	for _, lx in { -40, 40 } do
		for _, lz in { -160, 40 } do
			ctx:box("LoungerLeg", V(6, 46, 6), ctx:at(LX + lx, 23, LZ + lz), rgb(200, 200, 206), Enum.Material.Metal)
		end
	end
	local gp = scene:actor("Grandpa", "GrandpaSun")
	local pg = R.newPlan(gp, LX, LZ, PI)
	local lounge = R.seat(LX, LZ, PI, 60)
	R.seated(pg, lounge)
	scene:prop("Paper", "Newspaper")
	local faceCover = { Paper = { "Head", off = CFrame.new(0, 4, -36) * CFrame.Angles(-1.2, 0, 0) } }
	local function snooze(u: number, c: any): any
		local s = c.Actor.S
		return {
			lean = -0.62,
			bob = math.sin(u * 1.2) * 0.015,
			head = { pitch = 0.25 },
			legs = { hipL = PI / 2, hipR = PI / 2, kneeL = -0.05, kneeR = -0.05 },
			armL = { p = 0.4, r = 0.35, e = 0.9 },
			armR = { p = 0.4, r = 0.35, e = 0.9 },
		}
	end

	-- Dad at the grill.
	local dad = scene:actor("Dad", "DadGrill")
	local pd = R.newPlan(dad, GX, GZ + 90, PI)
	scene:prop("Spatula", "Spatula")
	local spat = { Spatula = { "R", off = CFrame.new(0, -2, 0) } }
	local function grill(u: number, c: any): any
		local s = c.Actor.S
		local jig = math.sin(u * 4)
		return {
			bob = R.breathe(u),
			head = { pitch = -0.35, yaw = math.sin(u * 0.6) * 0.15 },
			armR = { at = local3(c, 0.35 * s + jig * 6, 170, 0.8 * s) },
			armL = { p = 0.3, r = 0.55, e = 1.8 },
		}
	end
	pd:still(4.6, grill, spat)
	-- the flip, done properly this time
	local FLIPB = pd.T
	pd:still(0.9, function(u, c)
		local s = c.Actor.S
		local k = u / 0.9
		local lift = math.sin(math.clamp(k, 0, 1) * PI) * 40
		return {
			head = { pitch = -0.2 + 0.3 * math.sin(k * PI) },
			armR = { at = local3(c, 0.2 * s, 170 + lift, 0.8 * s) },
			armL = { p = 0.3, r = 0.55, e = 1.8 },
		}
	end, spat)
	local flipPatty = patties[2]
	local pattyHome = flipPatty.CFrame
	ctx:onUpdate(function(t)
		local k = math.clamp((t - FLIPB - 0.2) / 0.6, 0, 1)
		flipPatty.CFrame = pattyHome * CFrame.new(math.sin(k * PI) * 45, 0, 0) * CFrame.Angles(k * PI, 0, 0)
	end)
	-- ...then a nervous look at the sky (no pancakes coming), and a proud grin
	pd:still(1.4, function(u, c)
		local k = math.sin(math.clamp(u / 1.4, 0, 1) * PI)
		local p = grill(u, c)
		p.head = { pitch = 0.9 * k, yaw = 0.2 * k }
		return p
	end, spat)
	pd:still(1.4, function(u, c)
		local p = P.idle(u, c)
		p.armR = { p = 1.3, r = 0.2, e = 1.6 }
		return p
	end, spat)
	pd:still(4, grill, spat)
	pd:still(3.5, P.laugh, spat)
	pd:finish(40, grill)
	pd.Steps[#pd.Steps].Hold = spat
	table.insert(scene.Plans, pd)

	-- The kid and the ball.
	local kid = scene:actor("Kid", "Kid")
	local KX, KZ = 240, -90
	local toBowl = math.atan2(30 - KX, 150 - KZ)
	local fx, fz = math.sin(toBowl), math.cos(toBowl)
	local pk = R.newPlan(kid, KX, KZ, toBowl)
	local ballAt = ctx:R(KX + fx * 40 + fz * 10, 12, KZ + fz * 40 - fx * 10)
	local ball = ctx:box("Football", V(24, 24, 24), CFrame.new(), rgb(250, 250, 250), nil, "Ball")
	pk:still(7.6, function(u, c)
		local p = P.idle(u, c)
		p.head = { pitch = -0.3, yaw = math.sin(u) * 0.2 }
		return p
	end)
	pk:walk({ V2(KX - fx * 70, KZ - fz * 70) }, nil, nil, 90, true)
	pk:walk({ V2(KX - fx * 8, KZ - fz * 8) }, nil, nil, 180)
	local KICK = pk.T + 0.2
	pk:still(0.6, function(u, c)
		local k = u / 0.6
		local swing = if k < 0.35 then -0.7 * smooth(k / 0.35) else -0.7 + 2.1 * smooth((k - 0.35) / 0.3)
		return {
			lean = -0.1 * smooth(k),
			legs = { hipR = swing, kneeR = if k < 0.35 then -1.1 * smooth(k / 0.35) else -1.1 * (1 - smooth((k - 0.35) / 0.25)) },
			armL = { p = 0.6, r = 0.4, e = 0.3 },
			armR = { p = -0.5, r = 0.4, e = 0.3 },
			head = { pitch = 0.2 },
		}
	end)
	local LANDB = KICK + 1.35
	Kit.flight(ctx, ball, KICK, LANDB, ballAt, BOWL, 260, 2, "before")
	-- after the splat the ball sits in the bowl
	local ballRest = ctx:box("BallInBowl", V(24, 24, 24), CFrame.new(BOWL + Vector3.new(0, 4, 0)), rgb(250, 250, 250), nil, "Ball")
	ctx:onUpdate(function(t)
		ballRest.Transparency = if t >= LANDB then 0 else 1
	end)
	-- "oops": hands on head
	pk:still(1.0, P.idle)
	pk:still(2.2, function(u, c)
		local s = c.Actor.S
		return {
			bob = math.sin(u * 8) * 0.01,
			head = { pitch = -0.1, yaw = math.sin(u * 3) * 0.15 },
			armL = { at = function(b)
				return (b.Head * CFrame.new(-0.55 * s, 0.35 * s, 0)).Position
			end },
			armR = { at = function(b)
				return (b.Head * CFrame.new(0.55 * s, 0.35 * s, 0)).Position
			end },
		}
	end)
	pk:still(3, P.laugh)
	pk:still(4, P.wave)
	pk:finish(40, P.idle)
	table.insert(scene.Plans, pk)

	-- The salad goes everywhere (one leaf lands on Mum's head).
	local splash = { { -150, 40, 90 }, { 180, 60, 40 }, { -60, 30, -40 }, { 120, 50, 230 }, { -210, 40, 220 }, { 60, 20, -90 } }
	for i, d in splash do
		local leaf = ctx:box("FlyLeaf", V(26, 4, 20), CFrame.new(), rgb(110, 196, 80), nil, "Sphere")
		local land = ctx:R(30 + d[1], if d[3] > 60 and d[3] < 200 and math.abs(d[1]) < 170 then TABLE + 3 else 3, 150 + d[3] - 90)
		Kit.flight(ctx, leaf, LANDB, LANDB + 0.7 + i * 0.06, BOWL, land, 120 + d[2], 1.5, "after")
	end

	-- Mum: tossing the salad, then salad everywhere, then clearing up.
	local mum = scene:actor("Mum", "Mum")
	local MX, MZ = -40, 262
	local pm = R.newPlan(mum, MX, MZ, PI)
	scene:prop("MumLeaf", "Leaf")
	local function toss(u: number, c: any): any
		local s = c.Actor.S
		local k = math.sin(u * 3)
		return {
			bob = R.breathe(u),
			lean = 0.2,
			head = { pitch = -0.35 },
			armL = { at = BOWL + Vector3.new(-18 + k * 6, 18 + math.abs(k) * 10, 0) },
			armR = { at = BOWL + Vector3.new(18 - k * 6, 18 + math.abs(k) * 10, 0) },
		}
	end
	pm:still(LANDB - 0.9, toss)
	pm:still(0.9, function(u, c)
		local p = P.idle(u, c)
		p.head = { pitch = 0.25, yaw = 0.5 }
		return p
	end)
	local leafHat = { MumLeaf = { "Head", off = CFrame.new(4, 44, 0) * CFrame.Angles(0.1, 0.4, 0.15) } }
	pm:still(1.2, P.startle, nil)
	pm:split(pm.Steps[#pm.Steps], 0.5, leafHat)
	pm:still(2.4, P.laugh, leafHat)
	-- gather the salad-y plates
	pm:turn(PI / 2 + 0.6, leafHat)
	local PICKM = pm.T
	pm:swap(1.0, P.reach(-0.3 * S, TABLE + 12, 1.2 * S, 0.2 * S, TABLE + 12, 1.2 * S, 1.0, 0.35), leafHat, nil)
	local carry = { Stack = { "both", off = CFrame.new(0, -4, -10) }, MumLeaf = leafHat.MumLeaf }
	pm.Steps[#pm.Steps].Hold = carry
	scene.Placements.Stack[1][2] = PICKM + 0.5
	pm:walk({ V2(150, 330), V2(285, ZF - 72) }, carry, P.carry, 170)
	pm:turn(0, carry, P.carry)
	-- the leaf stays on her head the whole time (she hasn't noticed)
	local beats = Kit.loadDishwasher(ctx, pm, dw, "Stack")
	for _, st in pm.Steps do
		if st.T0 >= beats.Start - 0.01 then
			local h = st.Hold and table.clone(st.Hold) or {}
			h.MumLeaf = leafHat.MumLeaf
			st.Hold = h
		end
	end
	pm:still(3, P.idle, leafHat)
	pm:finish(40, P.idle)
	pm.Steps[#pm.Steps].Hold = leafHat
	table.insert(scene.Plans, pm)

	-- Grandpa sleeps through everything except the splash (a quick start, then back to sleep).
	pg:still(LANDB + 0.1, snooze, faceCover)
	pg:still(1.4, function(u, c)
		local p = snooze(u, c)
		local k = 1 - smooth(u / 1.4)
		p.lean = -0.62 + 0.5 * math.sin(math.min(u / 0.4, 1) * PI / 2) * k
		p.head = { pitch = 0.1, yaw = math.sin(u * 9) * 0.3 * k }
		p.armL = { p = 1.2 * k, r = 0.8 * k, e = 0.8 }
		p.armR = { p = 1.2 * k, r = 0.8 * k, e = 0.8 }
		return p
	end, faceCover)
	pg:finish(40, snooze)
	pg.Steps[#pg.Steps].Hold = faceCover
	table.insert(scene.Plans, pg)

	-- Camera.
	local ballPos = function(t)
		local k = math.clamp((t - KICK) / (LANDB - KICK), 0, 1)
		return ballAt:Lerp(BOWL, k) + Vector3.new(0, 4 * 260 * k * (1 - k), 0)
	end
	ctx:shot(0, FLIPB - 0.8, { eye = { ctx:R(-640, 700, -600), ctx:R(-500, 560, -470) }, look = { ctx:R(-60, 150, 250), ctx:R(-40, 160, 260) }, fov = { 56, 52 } })
	ctx:shot(FLIPB - 0.8, KICK - 1.4, { eye = { ctx:R(-230, 270, 110), ctx:R(-250, 265, 130) }, look = { ctx:R(GX, 220, GZ + 70), ctx:R(GX, 225, GZ + 80) }, fov = { 40, 38 } })
	ctx:shot(KICK - 1.4, KICK + 0.3, { eye = { ctx:R(KX + fz * 330, 170, KZ - fx * 330), ctx:R(KX + fz * 300, 165, KZ - fx * 300) }, look = Kit.follow(kid, "Torso"), fov = { 44, 42 } })
	ctx:shot(KICK + 0.3, LANDB + 0.35, { eye = { ctx:R(360, 330, -280), ctx:R(300, 330, -220) }, look = ballPos, fov = { 50, 46 }, ease = "linear" })
	ctx:shot(LANDB + 0.35, LANDB + 3.0, { eye = { ctx:R(-40, 250, -30), ctx:R(-40, 245, -10) }, look = { ctx:R(-40, 225, 262), ctx:R(-40, 225, 262) }, fov = { 38, 34 } })
	ctx:shot(LANDB + 3.0, PICKM, { eye = { ctx:R(LX + 210, 300, 60), ctx:R(LX + 190, 290, 72) }, look = { ctx:R(LX, 130, 230), ctx:R(LX, 130, 230) }, fov = { 42, 40 } })
	ctx:shot(PICKM, beats.Open - 0.6, { eye = { ctx:R(-320, 380, -140), ctx:R(-260, 360, -80) }, look = Kit.follow(mum, "Torso"), fov = { 48, 44 }, ease = "linear" })
	Kit.endingShots(ctx, dw, beats, 1)
	return ctx
end

----------------------------------------------------------------------------------------------------
-- Chapter 3: Birthday Surprise
----------------------------------------------------------------------------------------------------

-- Everyone in party hats (built on top of their usual looks).
local function withHat(base: string, c1: Color3, c2: Color3): any
	local b = LOOKS[base]
	local look = table.clone(b)
	look.Build = function(a)
		if b.Build then
			b.Build(a)
		end
		R.partyHat(a, c1, c2)
	end
	return look
end
LOOKS.KidParty = withHat("Kid", rgb(255, 90, 160), rgb(90, 200, 255))
LOOKS.DadParty = withHat("Dad", rgb(255, 214, 60), rgb(120, 90, 220))
LOOKS.MumParty = withHat("Mum", rgb(90, 220, 140), rgb(255, 120, 60))
LOOKS.GrandpaParty = withHat("Grandpa", rgb(160, 110, 255), rgb(255, 230, 90))

PROPS.Cake = function()
	local t = {
		disc(96, 3, 1.5, rgb(250, 250, 248)),
		disc(80, 38, 22, rgb(250, 170, 200)),
		disc(82, 6, 42, rgb(255, 250, 246)),
		disc(62, 26, 55, rgb(255, 214, 230)),
		disc(64, 5, 69, rgb(255, 250, 246)),
	}
	for i = 0, 7 do
		local a = i / 8 * PI * 2
		table.insert(t, { V(8, 12, 8), C(math.cos(a) * 40, 36, math.sin(a) * 40), rgb(255, 250, 246), nil, "Sphere" })
		table.insert(t, { V(6, 6, 6), C(math.cos(a) * 30, 73, math.sin(a) * 30), ({ rgb(255, 90, 90), rgb(90, 180, 255), rgb(255, 220, 60) })[i % 3 + 1], nil, "Ball" })
	end
	for i = 0, 4 do
		local a = i / 5 * PI * 2
		table.insert(t, { V(4, 22, 4), C(math.cos(a) * 16, 82, math.sin(a) * 16), ({ rgb(120, 200, 255), rgb(255, 150, 200), rgb(255, 230, 120) })[i % 3 + 1] })
	end
	return t
end
PROPS.Flames = function()
	local t = {}
	for i = 0, 4 do
		local a = i / 5 * PI * 2
		table.insert(t, { V(5, 9, 5), C(math.cos(a) * 16, 97, math.sin(a) * 16), rgb(255, 200, 80), Enum.Material.Neon, "Sphere" })
	end
	return t
end
PROPS.CakeStack = function()
	local t = {}
	for i = 0, 3 do
		table.insert(t, disc(48, 2.4, 1.2 + i * 3.4, rgb(250, 250, 248)))
		table.insert(t, { V(14, 3, 10), C(-6 + i * 4, 3.2 + i * 3.4, 4 - i * 3), rgb(250, 170, 200), nil, "Sphere" })
	end
	return t
end
PROPS.Frosting = function()
	return {
		{ V(44, 16, 40), C(0, 0, 0), rgb(255, 214, 230), nil, "Sphere" },
		{ V(12, 18, 10), C(-14, -8, -10), rgb(255, 214, 230), nil, "Sphere" },
		{ V(8, 8, 8), C(4, 9, 0), rgb(255, 90, 90), nil, "Ball" },
	}
end

local function birthdaySurprise(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 30)
	Kit.title(ctx, 3, "Birthday Surprise")
	local DAY = rgb(96, 88, 110)
	local DARK = rgb(40, 34, 60)
	ctx:mood({ ClockTime = 20.8, Brightness = 0.9, ExposureCompensation = 0.25, Ambient = DAY, OutdoorAmbient = rgb(80, 80, 110) })
	local scene = ctx.Scene

	-- The living room, open to a little kitchen on the right.
	local ZW = 620
	Kit.room(ctx, {
		X0 = -680, X1 = 920, Z0 = -800, Z1 = ZW, H = 700,
		Floor = rgb(200, 170, 140), FloorMat = Enum.Material.WoodPlanks, Planks = 64,
		Wall = rgb(150, 120, 170), Stripe = rgb(110, 84, 130), StripeH = 180,
	})
	Kit.window(ctx, -470, 400, ZW, 180, 180, "night", rgb(120, 60, 110))
	Kit.ceiling(ctx, -680, 920, -800, ZW, 700, rgb(236, 230, 240))
	Kit.picture(ctx, 80, 420, ZW, 150, 100, { rgb(120, 180, 230), rgb(90, 160, 90), rgb(255, 230, 120) })
	-- the banner
	local banner = ctx:box("Banner", V(420, 60, 3), ctx:at(-150, 560, ZW - 12), rgb(255, 214, 90))
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.CanvasSize = Vector2.new(840, 120)
	gui.LightInfluence = 0.3
	gui.Parent = banner
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Text = "HAPPY BIRTHDAY!"
	text.Font = Enum.Font.FredokaOne
	text.TextScaled = true
	text.TextColor3 = rgb(220, 50, 110)
	text.Parent = gui
	for i = 0, 9 do
		ctx:box("Streamer", V(40, 6, 3), ctx:at(-600 + i * 60, 640 - (i % 2) * 14, ZW - 14) * CFrame.Angles(0, 0, (if i % 2 == 0 then 0.25 else -0.25)), ({ rgb(255, 90, 160), rgb(90, 200, 255), rgb(255, 220, 60) })[i % 3 + 1])
	end
	Kit.balloon(ctx, -560, 330, 420, rgb(255, 80, 120))
	Kit.balloon(ctx, -500, 360, 470, rgb(80, 180, 255))
	Kit.balloon(ctx, 160, 340, 460, rgb(255, 214, 60))
	Kit.balloon(ctx, 220, 310, 400, rgb(140, 220, 120))
	Kit.balloon(ctx, 120, 380, 520, rgb(190, 120, 255))
	Kit.rug(ctx, -150, 280, 620, 420, rgb(90, 140, 200), rgb(60, 100, 160))
	-- floor lamp with a warm light
	ctx:post("LampPole", 8, 300, -560, 0, 300, rgb(60, 60, 64), Enum.Material.Metal)
	ctx:box("LampShade", V(80, 60, 80), ctx:at(-560, 320, 300), rgb(255, 236, 200), Enum.Material.Fabric)
	local lamp = ctx:light(-560, 300, 300, rgb(255, 200, 140), 60, 1.2, 10)

	-- the sofa
	local SX, SZ = -150, 410
	ctx:box("SofaBase", V(380, 60, 130), ctx:at(SX, 40, SZ), rgb(70, 110, 150), Enum.Material.Fabric)
	ctx:box("SofaSeat", V(330, 24, 120), ctx:at(SX, 82, SZ - 4), rgb(90, 134, 176), Enum.Material.Fabric)
	ctx:box("SofaBack", V(380, 130, 34), ctx:at(SX, 120, SZ + 60), rgb(70, 110, 150), Enum.Material.Fabric)
	for _, sd in { -1, 1 } do
		ctx:box("SofaArm", V(34, 100, 130), ctx:at(SX + sd * 190, 60, SZ), rgb(70, 110, 150), Enum.Material.Fabric)
	end
	ctx:box("Cushion", V(70, 60, 16), ctx:at(SX - 120, 118, SZ + 36) * CFrame.Angles(-0.3, 0.2, 0), rgb(255, 200, 90), Enum.Material.Fabric)
	-- the coffee table
	local TOPC = 88
	Kit.table(ctx, -150, 250, 280, 100, TOPC, rgb(120, 84, 56))
	for i, px in { -250, -190, -60 } do
		scene:prop("CakePlate" .. i, "Plate")
		scene:place("CakePlate" .. i, 0, 1e5 - 1, ctx:at(px, TOPC + 1, 232))
	end
	scene:prop("Stack", "CakeStack")
	-- the kitchenette
	local ZF = 480
	local top = Kit.counter(ctx, 300, 900, ZF, { Gaps = { { 405, 535 } }, Body = rgb(245, 243, 236), Top = rgb(60, 60, 66), TopMat = Enum.Material.Granite })
	Kit.sink(ctx, 700, ZF, top)
	Kit.upper(ctx, 300, 900, ZW, 330)
	local dw = Kit.dishwasher(ctx, 470, ZF, 0, { Mess = rgb(250, 170, 200) })
	ctx:light(600, 520, 360, rgb(255, 230, 190), 60, 0.8, 16)

	-- The cake and its candles.
	scene:prop("Cake", "Cake")
	local flames = scene:prop("Flames", "Flames")
	local candleLight = Instance.new("PointLight")
	candleLight.Color = rgb(255, 190, 110)
	candleLight.Range = 36
	candleLight.Brightness = 2.5
	candleLight.Parent = flames.Pieces[1].Part
	local CAKE_AT = ctx:at(-120, TOPC + 1, 258)

	-- The kid on the sofa, eyes covered.
	local kid = scene:actor("Kid", "KidParty")
	local pk = R.newPlan(kid, SX, SZ, PI)
	local kidSeat = R.seat(SX, SZ - 10, PI, 94)
	R.seated(pk, kidSeat)
	local function peek(u: number, c: any): any
		local s = c.Actor.S
		return {
			bob = math.sin(u * 5) * 0.01,
			head = { pitch = -0.1, yaw = math.sin(u * 2) * 0.1 },
			armL = { at = function(b)
				return (b.Head * CFrame.new(-0.25 * s, 0.1 * s, -0.75 * s)).Position
			end },
			armR = { at = function(b)
				return (b.Head * CFrame.new(0.25 * s, 0.1 * s, -0.75 * s)).Position
			end },
		}
	end
	local function cheer(u: number, c: any): any
		local k = math.sin(u * 9)
		return {
			bob = math.abs(k) * 0.05,
			head = { pitch = 0.25 },
			armL = { p = 2.7, r = 0.35 + k * 0.1, e = 0.2 },
			armR = { p = 2.7, r = 0.35 - k * 0.1, e = 0.2 },
		}
	end

	-- Mum brings the cake in from the kitchen.
	local mum = scene:actor("Mum", "MumParty")
	local pm = R.newPlan(mum, 430, 320, -PI / 2)
	local carried = { Cake = { "both", off = CFrame.new(0, -40, -12) }, Flames = { "both", off = CFrame.new(0, -40, -12) } }
	local function carefully(u: number, c: any): any
		local p = P.carry(u, c)
		p.head = { pitch = -0.25 }
		return p
	end
	pm:still(1.8, carefully, carried)
	pm:walk({ V2(40, 300), V2(20, 262) }, carried, carefully, 95)
	pm:turn(-PI / 2, carried, carefully)
	local SETDOWN = pm.T
	pm:swap(1.1, P.reach(-0.3 * S, TOPC + 50, 1.3 * S, 0.3 * S, TOPC + 50, 1.3 * S, 1.1, 0.5), carried, nil)
	scene:place("Cake", SETDOWN + 0.55, 1e5 - 1, CAKE_AT)
	local SURPRISE = SETDOWN + 1.2
	local BLOW = SURPRISE + 2.4
	scene:place("Flames", SETDOWN + 0.55, BLOW, CAKE_AT)
	ctx:onUpdate(function(t)
		candleLight.Enabled = t < BLOW
		lamp:FindFirstChildOfClass("PointLight").Brightness = if t < 2 or t > BLOW + 0.4 then 1.2 else 0.25
		pcall(function()
			game:GetService("Lighting").Ambient = if t < 2 or t > BLOW + 0.4 then DAY else DARK
		end)
	end)
	pm:still(SURPRISE - pm.T + 0.2, P.clap)
	pm:still(BLOW - pm.T + 0.3, P.clap)
	pm:still(3.2, P.laugh)
	pm:still(8, P.talkTo(0.6))
	pm:finish(40, P.idle)
	table.insert(scene.Plans, pm)

	-- the kid: peeking, SURPRISE, blows the candles out
	pk:still(SURPRISE, peek)
	pk:still(BLOW - SURPRISE - 0.8, cheer)
	pk:still(1.3, function(u, c)
		local k = math.sin(math.clamp(u / 1.3, 0, 1) * PI)
		return {
			sit = 1,
			seat = 94,
			lean = 0.55 * k,
			head = { pitch = -0.1 * k },
			armL = { p = 0.6, r = 0.1, e = 0.4 },
			armR = { p = 0.6, r = 0.1, e = 0.4 },
		}
	end)
	pk:still(3.2, P.laugh)
	pk:still(4, cheer)
	pk:finish(40, P.laugh)
	table.insert(scene.Plans, pk)
	-- a puff of smoke from the candles
	local puff = ctx:box("Puff", V(8, 8, 8), CAKE_AT * CFrame.new(0, 100, 0), rgb(255, 255, 255), nil, "Ball", 1)
	local smoke = Kit.smoke(puff, rgb(240, 240, 240), 0, 10)
	ctx:onUpdate(function(t)
		smoke.Rate = if t > BLOW and t < BLOW + 1.2 then 14 else 0
	end)

	-- Dad by the sofa; the frosting ends up on his head (of course).
	local dad = scene:actor("Dad", "DadParty")
	local DX, DZ = -390, 300
	local toCake = math.atan2(-120 - DX, 258 - DZ)
	local pd = R.newPlan(dad, DX, DZ, toCake)
	scene:prop("DadFrosting", "Frosting")
	local blob = ctx:box("FlyFrosting", V(40, 16, 36), CFrame.new(), rgb(255, 214, 230), nil, "Sphere")
	local HIT = BLOW + 0.9
	Kit.flight(ctx, blob, BLOW + 0.1, HIT, (origin * CAKE_AT * CFrame.new(0, 70, 0)).Position, function()
		local b = dad.Bones
		return if b then (b.Head * CFrame.new(0, 92, 0)).Position else Vector3.zero
	end, 140, 1)
	local sneak = function(u: number, c: any): any
		local p = P.idle(u, c)
		p.lean = 0.12
		p.head = { pitch = -0.1, yaw = math.sin(u * 1.5) * 0.3 }
		p.armL = { p = 0.5, r = 0.3, e = 1.2 }
		p.armR = { p = 0.5, r = 0.3, e = 1.2 }
		return p
	end
	pd:still(SURPRISE, sneak)
	pd:still(HIT - SURPRISE, cheer)
	local frosted = { DadFrosting = { "Head", off = CFrame.new(0, 92, 0) * CFrame.Angles(0, 0.3, 0.1) } }
	pd:still(1.0, P.startle, frosted)
	pd:still(2.6, function(u, c)
		local p = P.laugh(u, c)
		p.armR = { p = 0.4, r = 0.4, e = 1.2 }
		p.armL = { p = 0.4, r = 0.4, e = 1.2 }
		return p
	end, frosted)
	pd:finish(40, P.laugh)
	pd.Steps[#pd.Steps].Hold = frosted
	table.insert(scene.Plans, pd)

	-- Grandpa: cheers, laughs, then does the washing up for once.
	local gp = scene:actor("Grandpa", "GrandpaParty")
	local GX, GZ = -290, 140
	local pg = R.newPlan(gp, GX, GZ, math.atan2(-120 - GX, 258 - GZ))
	pg:still(SURPRISE, sneak)
	pg:still(BLOW - SURPRISE, cheer)
	pg:still(3.4, P.laugh)
	pg:walk({ V2(20, 225) }, nil, nil, 110)
	pg:turn(-PI / 2)
	local PICK = pg.T
	pg:swap(1.1, P.reach(-0.2 * S, TOPC + 12, 1.3 * S, 0.25 * S, TOPC + 12, 1.3 * S, 1.1, 0.6), nil, { Stack = { "both", off = CFrame.new(0, -4, -10) } })
	scene:place("Stack", 0, PICK + 0.55, ctx:at(-45, TOPC + 1, 240))
	local carry = { Stack = { "both", off = CFrame.new(0, -4, -10) } }
	pg:walk({ V2(250, 300), V2(470 - 95, ZF - 72) }, carry, P.carry, 150)
	pg:turn(0, carry, P.carry)
	local beats = Kit.loadDishwasher(ctx, pg, dw, "Stack")
	pg:still(3, P.idle)
	pg:finish(40, P.idle)
	table.insert(scene.Plans, pg)

	-- Confetti at SURPRISE!
	local colors = { rgb(255, 90, 160), rgb(90, 200, 255), rgb(255, 220, 60), rgb(140, 230, 120), rgb(200, 140, 255) }
	for i = 1, 26 do
		local c = ctx:box("Confetti", V(8, 2, 5), CFrame.new(), colors[i % #colors + 1], nil, nil)
		c.CastShadow = false
		local a = i * 2.4
		local from = ctx:R(-150 + math.cos(a) * 40, 300, 300 + math.sin(a) * 30)
		local to = ctx:R(-150 + math.cos(a) * (120 + i * 6), 1, 300 + math.sin(a) * (80 + i * 4))
		Kit.flight(ctx, c, SURPRISE + (i % 5) * 0.05, SURPRISE + 1.6 + (i % 7) * 0.12, from, to, 160, 2, "after")
	end

	-- Camera.
	ctx:shot(0, 2.2, { eye = { ctx:R(-600, 440, -520), ctx:R(-520, 400, -440) }, look = { ctx:R(-120, 180, 360), ctx:R(-120, 180, 360) }, fov = { 52, 50 } })
	ctx:shot(2.2, SETDOWN + 0.3, { eye = { ctx:R(160, 250, -110), ctx:R(80, 245, -90) }, look = Kit.follow(mum, "Torso", Vector3.new(0, 20, 0)), fov = { 42, 40 }, ease = "linear" })
	ctx:shot(SETDOWN + 0.3, SURPRISE + 1.2, { eye = { ctx:R(-150, 250, -230), ctx:R(-150, 245, -190) }, look = { ctx:R(-150, 190, 320), ctx:R(-150, 190, 320) }, fov = { 48, 46 } })
	ctx:shot(SURPRISE + 1.2, BLOW, { eye = { ctx:R(-90, 190, 110), ctx:R(-100, 185, 130) }, look = { ctx:R(-140, 150, 330), ctx:R(-140, 150, 330) }, fov = { 40, 38 } })
	ctx:shot(BLOW, HIT + 0.2, { eye = { ctx:R(-150, 300, 60), ctx:R(-170, 300, 70) }, look = function(t)
		local k = math.clamp((t - BLOW - 0.1) / 0.8, 0, 1)
		return ctx:R(-120, 160, 258):Lerp(ctx:R(DX, 250, DZ), smooth(k))
	end, fov = { 44, 44 }, ease = "linear" })
	ctx:shot(HIT + 2.4, PICK, { eye = { ctx:R(-170, 330, -220), ctx:R(-160, 320, -190) }, look = { ctx:R(-150, 180, 300), ctx:R(-140, 180, 300) }, fov = { 48, 46 } })
	ctx:shot(HIT + 0.2, HIT + 2.4, { eye = { ctx:R(-300, 300, 120), ctx:R(-305, 295, 130) }, look = Kit.follow(dad, "Head", Vector3.new(0, 30, 0)), fov = { 36, 34 } })
	ctx:shot(PICK, beats.Open - 0.6, { eye = { ctx:R(-100, 400, -160), ctx:R(-40, 380, -100) }, look = Kit.follow(gp, "Torso"), fov = { 48, 44 }, ease = "linear" })
	Kit.endingShots(ctx, dw, beats, 1)
	return ctx
end

return {
	pancakeMorning,
	backyardBarbecue,
	birthdaySurprise,
}
