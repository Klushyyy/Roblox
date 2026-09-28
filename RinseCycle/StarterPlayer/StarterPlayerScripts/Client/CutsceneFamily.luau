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

return {
	pancakeMorning,
}
