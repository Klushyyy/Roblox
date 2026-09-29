--[[
	Story - the run-start cutscene: one chapter per level, one story running through all three.

	  1. Family Dinner (level 1): spaghetti night. The kid finds out the birthday party is at
	     Luigi's pizzeria, cheers so hard a meatball lands on Grandpa's newspaper, and Mum
	     announces the dishes. She tosses the plates into the dishwasher, wishes the tiny helpers
	     inside good luck and presses Start.
	  2. Pizza Party (level 2): the birthday at Luigi's. ...
	  3. Royal Banquet (level 3): ...

	Each chapter is staged in the very room the level is played in (the client's own arena, found
	from its Origin attribute): the room's walls, ceiling and furniture are the set, LevelNPCs'
	people step out while it plays (LevelNPCs.SetCutscene), and the chapter brings its own cast.
	It always ends at the real dishwasher with the players already standing on its door, so the
	last shot of the film is the first moment of the run.

	Coordinates are room space (see CutsceneKit): x right, h above the kitchen floor, z towards the
	dishwasher (the tub opens at z = -50, its door lies flat out to z = -121, 24 studs up).
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
local TABLE = R.TABLE
local PROPS = R.PROPS

local Story = {}

-- The chapter list the party menu shows (level index = chapter number).
Story.Chapters = {
	{ Name = "Family Dinner", Blurb = "Spaghetti night, and big news for the birthday kid." },
	{ Name = "Pizza Party", Blurb = "The birthday party at Luigi's pizzeria." },
	{ Name = "Royal Banquet", Blurb = "A feast at the castle, by royal invitation." },
}

-- Speaker colours for the subtitles.
local VOICE = {
	Kid = rgb(140, 230, 140),
	Dad = rgb(140, 190, 255),
	Mum = rgb(255, 150, 170),
	Grandpa = rgb(230, 200, 150),
	Chef = rgb(255, 210, 110),
	Waiter = rgb(200, 200, 255),
	King = rgb(255, 214, 90),
	Queen = rgb(230, 160, 255),
	Jester = rgb(255, 140, 90),
}
Story.Voice = VOICE

-- The dishwasher (the arena's own, the same in every room).
local BUTTON = { X = 0, H = 28, Z = -124 } -- the lit Start button on the door's far edge
local SPAWN_Z = -100 -- where the players stand on the door

PROPS.Meatball = function()
	return { { V(11, 11, 11), C(0, 0, 0), rgb(120, 66, 40), nil, "Ball" } }
end
PROPS.Splat = function()
	return { { V(1, 16, 20), C(0, 0, 0) * CFrame.Angles(0, 0, PI / 2), rgb(200, 50, 36), nil, "Cylinder" } }
end

----------------------------------------------------------------------------------------------------
-- Shared poses
----------------------------------------------------------------------------------------------------

-- Kneeling, sitting back on the heels, `k` of the way down (0 = standing). Knees forward on the
-- floor, shins flat behind; the pelvis ends 45 studs up.
local KNEEL_SEAT = 26.5
local function kneel(k: number, lean: number?): any
	return {
		sit = k,
		seat = KNEEL_SEAT,
		lean = lean or 0,
		legs = { hipL = 1.14 * k, hipR = 1.14 * k, kneeL = -2.71 * k, kneeR = -2.71 * k },
	}
end

-- A point in front of the chest, in the torso's own frame (follows leans and kneels).
local function chest(side: number, up: number, fwd: number): (any) -> Vector3
	return function(b: any): Vector3
		return (b.Torso * C(side * S, up * S, -fwd * S)).Position
	end
end

-- Seated cheering: both arms up and waving, bouncing in the seat.
local function cheer(u: number, _ctx: any): any
	local w = math.sin(u * 13)
	return {
		bob = math.abs(math.sin(u * 11)) * 0.07,
		head = { pitch = 0.3, yaw = math.sin(u * 6) * 0.15 },
		armL = { p = 2.85, r = 0.35 + w * 0.15, e = 0.25 },
		armR = { p = 2.85, r = 0.35 - w * 0.15, e = 0.25 },
	}
end

-- Slumping in the seat ("Awww...").
local function slump(u: number, ctx: any): any
	local s = ctx.Actor.S
	local k = smooth(u / 0.6)
	return {
		bob = -0.05 * k,
		lean = 0.18 * k,
		head = { pitch = -0.45 * k, roll = 0.12 * k },
		armL = { at = local3(ctx, -0.55 * s, TABLE + 26, 1.2 * s) },
		armR = { at = local3(ctx, 0.55 * s, TABLE + 26, 1.2 * s) },
	}
end

-- Talking to someone (yaw) with a raised, wagging finger-hand.
local function scold(yaw: number): (number, any) -> any
	return function(u: number, ctx: any): any
		local s = ctx.Actor.S
		return {
			bob = R.breathe(u),
			twist = yaw * 0.15,
			head = { yaw = yaw * 0.7, pitch = 0.05 + math.sin(u * 3) * 0.04 },
			armL = { at = local3(ctx, -0.6 * s, TABLE + 26, 1.2 * s) },
			armR = { p = 1.5, r = 0.55, e = 1.1 + math.sin(u * 10) * 0.25 },
		}
	end
end

-- Pointing up with the right hand while talking ("Pizza for everyone!").
local function announce(yaw: number): (number, any) -> any
	return function(u: number, ctx: any): any
		local s = ctx.Actor.S
		local k = smooth(math.min(u, 2.4 - u) / 0.4)
		return {
			bob = R.breathe(u),
			twist = yaw * 0.15,
			head = { yaw = yaw * 0.7, pitch = 0.12 * k },
			armL = { at = local3(ctx, -0.6 * s, TABLE + 26, 1.2 * s) },
			armR = { p = 2.5 * k + 0.1, r = 0.15 + 0.55 * k, e = 0.1 },
		}
	end
end

----------------------------------------------------------------------------------------------------
-- The ending every chapter shares: someone kneels at the open dishwasher, tosses the dishes in,
-- wishes the tiny helpers good luck, presses Start and goes. Adds the steps to `plan` (who is
-- standing, carrying `stack` in both hands) and the shots; returns the beat times.
--   side: -1 kneels left of the door, +1 right.   line: the good-luck line.
----------------------------------------------------------------------------------------------------

local function ending(ctx: any, plan: any, who: string, stack: string, side: number, line: string, exitTo: { Vector2 }): { [string]: number }
	local scene = ctx.Scene
	local beats = {}
	local kx, kz = side * 95, -190
	local phi = R.phiOf(-side * 18, 60)
	local carry = { [stack] = { "both", off = C(0, -6, -4) } }
	local function carryArms(_u: number, _c: any): any
		return { head = { pitch = -0.1 }, armL = { at = chest(-0.42, -0.3, 0.9) }, armR = { at = chest(0.42, -0.3, 0.9) } }
	end

	-- walk up beside the door and face it
	plan:walk({ V2(kx, kz) }, carry, carryArms)
	plan:turn(phi, carry, carryArms)
	beats.Arrive = plan.T

	-- kneel down
	plan:still(1.0, function(u)
		local p = kneel(smooth(u / 1.0), 0.1)
		p.head = { pitch = -0.2 }
		p.armL = { at = chest(-0.42, -0.3, 0.9) }
		p.armR = { at = chest(0.42, -0.3, 0.9) }
		return p
	end, carry)
	beats.Kneel = plan.T

	-- the toss: a little swing back, then both hands push up and out
	local TOSS = 1.0
	local release = plan.T + 0.55
	plan:still(TOSS, function(u)
		local back = smooth(u / 0.35)
		local push = smooth((u - 0.35) / 0.3)
		local p = kneel(1, 0.1 + 0.25 * push)
		p.head = { pitch = 0.05 * push }
		local fwd = 0.9 - 0.3 * back + 0.8 * push
		local up = -0.3 - 0.1 * back + 0.75 * push
		p.armL = { at = chest(-0.42, up, fwd) }
		p.armR = { at = chest(0.42, up, fwd) }
		return p
	end, carry)
	plan:split(plan.Steps[#plan.Steps], 0.55, nil)
	beats.Release = release

	-- the dishes fly into the tub, over the helpers' heads, landing deep inside
	local land = ctx:R(-side * 30, 34, 30)
	local lastCF: CFrame? = nil
	local prop = scene.Props[stack]
	local FLIGHT = 0.95
	ctx:onUpdate(function(t)
		if t < release and prop.Visible and prop.Pieces[1] then
			local pc = prop.Pieces[1]
			lastCF = pc.Part.CFrame * pc.Offset:Inverse()
		end
	end)
	scene:place(stack, release, release + FLIGHT, function(t)
		local k = math.clamp((t - release) / FLIGHT, 0, 1)
		local from = lastCF or (ctx.Origin * ctx:at(kx, 95, kz + 50))
		local p = from.Position:Lerp(land, k) + V(0, 4 * 45 * k * (1 - k), 0)
		local world = CFrame.new(p) * from.Rotation * CFrame.Angles(k * 0.6, k * 2.2, 0)
		return ctx.Origin:Inverse() * world
	end)
	beats.Land = release + FLIGHT

	-- wave to the tiny helpers inside
	local WAVE = 2.8
	local tw = plan.T
	plan:still(WAVE, function(u)
		local p = kneel(1, 0.18)
		p.head = { pitch = -0.28, yaw = math.sin(u * 1.3) * 0.08 }
		local w = math.sin(u * 9)
		p.armR = { p = 2.3, r = 0.15 + w * 0.16, e = 0.55 + w * 0.3 }
		p.armL = { at = chest(-0.5, -1.0, 0.55) }
		return p
	end)
	ctx:say(tw + 0.1, tw + WAVE + 0.2, who, line, VOICE[who])
	beats.Wave = tw

	-- press Start: bow in and reach down to the lit button
	local PRESS = 1.4
	local tp = plan.T
	local target = ctx:R(BUTTON.X, BUTTON.H + 3, BUTTON.Z - 4)
	plan:still(PRESS, function(u)
		local k = math.sin(math.clamp(u / PRESS, 0, 1) * PI)
		local p = kneel(1, 0.18 + 0.72 * k)
		p.head = { pitch = -0.2 - 0.3 * k }
		p.armR = { at = function(b)
			return chest(0.45, -0.3, 0.8)(b):Lerp(target, k)
		end }
		p.armL = { at = chest(-0.5, -1.0, 0.55) }
		return p
	end)
	beats.Press = tp + PRESS / 2
	ctx.BubbleStart = beats.Press + 0.3

	-- the button flashes as it's pressed
	local flash = ctx:box("PressFlash", V(7, 1, 5), ctx:at(BUTTON.X, BUTTON.H - 0.2, BUTTON.Z), rgb(160, 255, 200), Enum.Material.Neon)
	flash.CastShadow = false
	ctx:onUpdate(function(t)
		local d = t - beats.Press
		flash.Transparency = if d >= 0 and d < 1.2 then 0.1 + 0.9 * (d / 1.2) else 1
	end)

	-- up and away, clear of the camera's last push in
	plan:still(1.0, function(u)
		local p = kneel(1 - smooth(u / 1.0), 0.15 * (1 - u))
		p.armL = { p = 0.2, r = 0.08, e = 0.4 }
		p.armR = { p = 0.2, r = 0.08, e = 0.4 }
		return p
	end)
	beats.Up = plan.T
	plan:walk(exitTo)
	plan:still(20, P.idle)

	-- Shots: kneeling (side-on, from the far side), the toss and the wave from inside the tub
	-- among the helpers, a macro of the button, and the push down onto the players.
	local head = Kit.follow(plan.Actor, "Head", V(0, -8, 0))
	ctx:shot(beats.Arrive - 0.9, beats.Release - 0.1, {
		eye = { ctx:R(-side * 250, 205, -300), ctx:R(-side * 235, 185, -280) },
		look = function(t)
			local h = head(t)
			return h + (ctx:R(0, 60, -150) - h) * 0.35
		end,
		fov = { 48, 44 },
	})
	ctx:shot(beats.Release - 0.1, beats.Wave + WAVE, {
		eye = { ctx:R(-side * 24, 38, -18), ctx:R(-side * 22, 40, -26) },
		look = function(t)
			return head(t) + V(0, -30, 0)
		end,
		fov = { 68, 64 },
	})
	ctx:shot(beats.Wave + WAVE, beats.Press + 0.7, {
		eye = { ctx:R(-side * 50, 30, -78), ctx:R(-side * 48, 29, -82) },
		look = { ctx:R(side * 8, 48, BUTTON.Z - 6), ctx:R(BUTTON.X, 32, BUTTON.Z) },
		fov = { 60, 56 },
	})
	ctx.Duration = beats.Press + 5.2
	ctx:shot(beats.Press + 0.7, ctx.Duration + 0.5, {
		eye = { ctx:R(-side * 60, 320, -178), ctx:R(-side * 18, 92, -166) },
		look = { ctx:R(0, 30, -120), ctx:R(0, 27, SPAWN_Z + 4) },
		fov = { 52, 48 },
		ease = "inout",
	})

	-- bubbles blown inside the tub once it runs
	for _, x in { -36, 0, 36 } do
		for _, h in { 40, 70, 100 } do
			table.insert(ctx.Inside, ctx:R(x, h, 0))
		end
	end
	return beats
end

----------------------------------------------------------------------------------------------------
-- Chapter 1: Family Dinner (the level-1 kitchen)
----------------------------------------------------------------------------------------------------

local function familyDinner(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 40)
	Kit.title(ctx, 1, "Family Dinner")
	local scene = ctx.Scene

	-- The room's own seats (LevelNPCs' furniture stays in place; see buildFamily there).
	local dadSeat = R.seat(-80, -452, 0, 98)
	local kidSeat = R.seat(100, -463, 0, 108)
	local mumSeat = R.seat(0, -210, PI, 98)
	local gpSeat = R.seat(-328, -380, PI / 2, 98)
	local function atSeat(st: any, right: number, fwd: number, up: number?): CFrame
		local cf = R.rootCF(st.X, st.Z, st.Phi) * C(right, 0, -fwd)
		return C(cf.X, R.FLOOR + TABLE + (up or 0), cf.Z) * cf.Rotation
	end
	local ALL = 1e5 - 1
	for i, st in { dadSeat, kidSeat, mumSeat } do
		scene:prop("Meal" .. i, "Spaghetti")
		scene:place("Meal" .. i, 0, ALL, atSeat(st, -4, 76))
		scene:prop("Fork" .. i, "Fork")
		scene:place("Fork" .. i, 0, ALL, atSeat(st, 34, 72, 1) * CFrame.Angles(0, 0.2, 0))
	end
	scene:prop("Stack", "PlateStack")
	scene:place("Stack", 0, ALL, atSeat(mumSeat, 30, 88))
	scene:prop("DadGlass", "Glass")
	scene:place("DadGlass", 0, ALL, atSeat(dadSeat, 30, 64))
	local side = R.rootCF(gpSeat.X, gpSeat.Z, gpSeat.Phi) * C(108, 0, -42)
	scene:prop("Tea", "TeaCup")
	scene:place("Tea", 0, ALL, side * C(-10, 128, 0))
	scene:prop("Paper", "Newspaper")
	scene:prop("Meatball", "Meatball")
	ctx.HideFurn = { "FurnChairMum" }
	scene:prop("MumChair", "FurnChair")

	local fork = function(i: number): any
		return { ["Fork" .. i] = R.FORK_HOLD }
	end
	local towardKid = -0.55 -- Dad's head turn to the kid

	-- Beats
	local T_KID = 4.8 -- "Dad... is it TRUE?"
	local T_DAD = 8.6 -- "Saturday! Pizza for everyone!"
	local T_CHEER = 11.3
	local T_FLICK = 11.95
	local T_HIT = 13.2
	local T_GP = 14.5 -- "...Is it raining meatballs?"
	local T_LAUGH = 17.0
	local T_MUM = 19.5 -- "the DISHES!"
	local T_AWW = 22.6

	ctx:say(T_KID, T_DAD - 0.1, "Kid", "Dad... is it TRUE? My birthday party is at LUIGI'S?!", VOICE.Kid)
	ctx:say(T_DAD, T_CHEER, "Dad", "You bet! Saturday. Pizza for everyone!", VOICE.Dad)
	ctx:say(T_CHEER, T_HIT - 0.3, "Kid", "WOOHOO!", VOICE.Kid)
	ctx:say(T_GP + 0.2, T_LAUGH, "Grandpa", "...Is it raining meatballs?", VOICE.Grandpa)
	ctx:say(T_MUM, T_AWW, "Mum", "Right, birthday boy. But first... the DISHES!", VOICE.Mum)
	ctx:say(T_AWW, T_AWW + 1.6, "Kid", "Awww, Mum!", VOICE.Kid)

	-- The kid: eats, asks, cheers (flinging a meatball), laughs, slumps, then eats again.
	local kid = scene:actor("Kid", "Kid")
	local pk = R.newPlan(kid, 0, 0, 0)
	R.seated(pk, kidSeat)
	pk:still(T_KID, P.eat, fork(2))
	pk:still(T_DAD - T_KID, P.talkTo(-0.7), fork(2))
	pk:still(T_CHEER - T_DAD, P.clap)
	pk:still(T_HIT + 0.6 - T_CHEER, cheer, fork(2))
	pk:still(T_LAUGH - (T_HIT + 0.6), P.talkTo(-1.0))
	pk:still(T_MUM - T_LAUGH, P.laugh)
	pk:still(T_AWW - T_MUM, P.talkTo(-0.9))
	pk:still(2.4, slump)
	pk:still(30, P.eat, fork(2))
	table.insert(scene.Plans, pk)

	-- Dad: eats, answers with a flourish, laughs.
	local dad = scene:actor("Dad", "Dad")
	local pd = R.newPlan(dad, 0, 0, 0)
	R.seated(pd, dadSeat)
	pd:still(T_KID, P.eat, fork(1))
	pd:still(T_DAD - T_KID, P.talkTo(towardKid))
	pd:still(2.4, announce(towardKid))
	pd:still(T_HIT - (T_DAD + 2.4), P.clap)
	pd:still(T_LAUGH - T_HIT, P.talkTo(-1.1))
	pd:still(T_MUM - T_LAUGH, P.laugh)
	pd:still(T_AWW - T_MUM, P.talkTo(0.3))
	pd:still(30, P.eat, fork(1))
	table.insert(scene.Plans, pd)

	-- Grandpa: reading in his armchair; the meatball lands on the paper; he lowers it, deadpan.
	local gp = scene:actor("Grandpa", "Grandpa")
	local pg = R.newPlan(gp, 0, 0, 0)
	R.seated(pg, gpSeat)
	local PAPER_UP = C(0, 10, -3) * CFrame.Angles(-0.35, 0, 0)
	local paperHold = { Paper = { "both", off = PAPER_UP } }
	pg:still(T_HIT, P.read, paperHold)
	-- the jolt as it hits
	pg:still(T_GP - 0.9 - T_HIT, function(u, c)
		local p = P.read(u, c)
		local j = math.exp(-u * 6) * math.sin(u * 40)
		p.bob = j * 0.03
		p.head = { pitch = -0.3 + j * 0.1 }
		return p
	end, paperHold)
	-- slowly lowers the paper and looks over at the table
	local lowerFrom = pg.T
	pg:still(T_LAUGH + 0.4 - lowerFrom, function(u, c)
		local s = c.Actor.S
		local k = smooth(u / 1.1)
		return {
			bob = R.breathe(u),
			lean = 0.04 - 0.04 * k,
			head = { pitch = -0.3 + 0.36 * k, yaw = -0.35 * k },
			armL = { at = local3(c, -0.66 * s, 84 + 2.0 * s - 26 * k, 1.15 * s) },
			armR = { at = local3(c, 0.66 * s, 84 + 2.0 * s - 26 * k, 1.15 * s) },
		}
	end, { Paper = { "both", off = function(u)
		local k = smooth(u / 1.1)
		return C(0, 10 - 2 * k, -3) * CFrame.Angles(-0.35 + 0.2 * k, 0, 0)
	end } })
	pg:still(T_MUM - pg.T, P.laugh)
	pg:still(30, P.read, paperHold)
	table.insert(scene.Plans, pg)

	-- The meatball: on the kid's plate, flicked off by the cheering fork, splat on the paper.
	local plate = atSeat(kidSeat, -4, 76, 12)
	local paperPart = scene.Props.Paper
	local function onPaper(): CFrame
		local pc = paperPart.Pieces[1]
		if not pc then
			return ctx:at(-270, 220, -380)
		end
		local world = pc.Part.CFrame * pc.Offset:Inverse() * C(-9, 5, -6)
		return ctx.Origin:Inverse() * world
	end
	scene:place("Meatball", 0, T_FLICK, plate)
	local FLY = T_HIT - T_FLICK
	scene:place("Meatball", T_FLICK, T_HIT, function(t)
		local k = math.clamp((t - T_FLICK) / FLY, 0, 1)
		local a, b = plate.Position, onPaper().Position
		local p = a:Lerp(b, k) + V(0, 4 * 130 * k * (1 - k), 0)
		return C(p) * CFrame.Angles(k * 9, k * 5, 0)
	end)
	scene:place("Meatball", T_HIT, ALL, function(_t)
		return onPaper()
	end)

	-- Mum: eats, laughs, lays down the law, gathers the plates and goes to the dishwasher.
	local mum = scene:actor("Mum", "Mum")
	local pm = R.newPlan(mum, 0, 0, 0)
	R.seated(pm, mumSeat)
	pm:still(T_KID, P.eat, fork(3))
	pm:still(T_CHEER - T_KID, P.talkTo(0.5))
	pm:still(T_HIT - T_CHEER, P.clap)
	pm:still(T_LAUGH - T_HIT, P.talkTo(0.9))
	pm:still(T_MUM - T_LAUGH, P.laugh)
	pm:still(T_AWW - T_MUM, scold(0.4))
	local carry = { Stack = { "both", off = C(0, -6, -4) } }
	pm:swap(1.2, P.reach(0.05 * S, TABLE + 36, 1.75 * S, 0.65 * S, TABLE + 36, 1.75 * S, 1.2, 0.15), nil, carry)
	local tStand = pm.T
	pm:standUp(V2(-105, -205), carry) -- out to her side of the chair...
	-- ...and the chair is tucked in under the table behind her
	local tuck = Kit.keyed({ { tStand + 0.6, -205 }, { tStand + 1.4, -250 } })
	scene:place("MumChair", 0, ALL, function(t)
		return R.rootCF(0, tuck(t), PI)
	end)
	local beats = ending(ctx, pm, "Mum", "Stack", -1, "Good luck in there, little helpers!", { V2(-170, -215), V2(-230, -150) })
	table.insert(scene.Plans, pm)

	-- Shots -------------------------------------------------------------------------------------
	-- 1. establishing: the whole family at dinner, from the far corner, drifting in
	ctx:shot(0, T_KID - 0.2, {
		eye = { ctx:R(360, 420, -500), ctx:R(330, 395, -480) },
		look = { ctx:R(-110, 130, -300), ctx:R(-90, 140, -310) },
		fov = { 56, 52 },
	})
	-- 2. the kid, over Mum's shoulder
	ctx:shot(T_KID - 0.2, T_DAD - 0.1, {
		eye = { ctx:R(175, 290, -190), ctx:R(168, 284, -205) },
		look = { ctx:R(60, 200, -463), ctx:R(60, 200, -463) },
		fov = { 50, 46 },
	})
	-- 3. Dad answers
	ctx:shot(T_DAD - 0.1, T_CHEER, {
		eye = { ctx:R(-215, 300, -195), ctx:R(-205, 294, -210) },
		look = { ctx:R(-40, 215, -455), ctx:R(-40, 218, -455) },
		fov = { 52, 48 },
	})
	-- 4. the cheer and the meatball's flight, wide over the table
	ctx:shot(T_CHEER, T_HIT + 0.25, {
		eye = { ctx:R(240, 430, -150), ctx:R(225, 420, -160) },
		look = { ctx:R(-40, 170, -420), ctx:R(-150, 180, -400) },
		fov = { 55, 52 },
	})
	-- 5. Grandpa, meatball on his paper
	ctx:shot(T_HIT + 0.25, T_LAUGH, {
		eye = { ctx:R(-95, 265, -320), ctx:R(-112, 260, -330) },
		look = { ctx:R(-300, 195, -380), ctx:R(-305, 200, -380) },
		fov = { 50, 46 },
	})
	-- 6. everyone laughing
	ctx:shot(T_LAUGH, T_MUM - 0.1, {
		eye = { ctx:R(-250, 380, -215), ctx:R(-240, 372, -222) },
		look = { ctx:R(0, 165, -405), ctx:R(5, 165, -405) },
		fov = { 58, 56 },
	})
	-- 7. Mum lays down the law (from across the table)
	ctx:shot(T_MUM - 0.1, T_AWW, {
		eye = { ctx:R(20, 290, -500), ctx:R(15, 285, -490) },
		look = { ctx:R(0, 235, -215), ctx:R(0, 235, -215) },
		fov = { 38, 34 },
	})
	-- 8. the kid's face
	ctx:shot(T_AWW, T_AWW + 1.6, {
		eye = { ctx:R(215, 300, -255), ctx:R(210, 296, -265) },
		look = { ctx:R(90, 200, -463), ctx:R(90, 196, -463) },
		fov = { 52, 50 },
	})
	-- 9. Mum gathers the plates and stands (the ending takes over from her arrival)
	ctx:shot(T_AWW + 1.6, beats.Arrive - 0.9, {
		eye = { ctx:R(240, 250, -330), ctx:R(250, 240, -290) },
		look = Kit.follow(mum, "Torso", V(0, 0, 0)),
		fov = { 50, 50 },
	})
	return ctx
end

----------------------------------------------------------------------------------------------------

local BUILDS = { familyDinner }

-- The cutscene for a level: a ctx (see CutsceneKit) with Title / Subtitle / Lines / HideFurn.
function Story.Build(level: number, origin: CFrame, parent: Instance): any
	local build = BUILDS[level] or BUILDS[1]
	return build(origin, parent)
end

function Story.Count(): number
	return #Story.Chapters
end

return Story
