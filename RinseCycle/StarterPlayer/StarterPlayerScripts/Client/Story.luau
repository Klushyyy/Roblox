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

local function ending(ctx: any, plan: any, who: string, stack: string, side: number, line: string, exitTo: { Vector2 }, opts: { [string]: any }?): { [string]: number }
	local o = opts or {}
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
		eye = o.ArriveEye or { ctx:R(-side * 250, 205, -300), ctx:R(-side * 235, 185, -280) },
		look = function(t)
			local h = head(t)
			return h + (ctx:R(0, 60, -150) - h) * 0.35
		end,
		fov = { 48, 44 },
	})
	ctx:shot(beats.Release - 0.1, beats.Wave + WAVE, {
		eye = { ctx:R(-side * 30, 36, -56), ctx:R(-side * 28, 37, -62) },
		look = function(t)
			return head(t) + V(0, -40, 0)
		end,
		fov = { 64, 60 },
	})
	ctx:shot(beats.Wave + WAVE, beats.Press + 0.7, {
		eye = { ctx:R(-side * 96, 42, -150), ctx:R(-side * 92, 40, -148) },
		look = { ctx:R(side * 10, 42, BUTTON.Z - 4), ctx:R(BUTTON.X, 32, BUTTON.Z) },
		fov = { 54, 50 },
	})
	ctx.Duration = beats.Press + 5.2
	ctx:shot(beats.Press + 0.7, ctx.Duration + 0.5, {
		eye = o.RevealEye or { ctx:R(-side * 60, 320, -178), ctx:R(-side * 18, 92, -166) },
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
-- Chapter 2: Pizza Party (the level-2 pizzeria)
----------------------------------------------------------------------------------------------------

local LOOKS = R.LOOKS
local FABRIC = Enum.Material.Fabric

-- A look that is `base` plus a few more pieces.
local function variant(base: string, extra: (any) -> ()): any
	local b = LOOKS[base]
	local v = table.clone(b)
	v.Build = function(a)
		if b.Build then
			b.Build(a)
		end
		extra(a)
	end
	return v
end
LOOKS.KidParty = variant("Kid", function(a)
	R.partyHat(a, rgb(80, 170, 255), rgb(255, 220, 80))
end)
LOOKS.DadParty = variant("Dad", function(a)
	R.partyHat(a, rgb(255, 120, 60), rgb(250, 250, 250))
end)
LOOKS.MumParty = variant("Mum", function(a)
	R.partyHat(a, rgb(170, 110, 255), rgb(255, 200, 230))
end)
LOOKS.GrandpaParty = variant("Grandpa", function(a)
	R.partyHat(a, rgb(90, 200, 140), rgb(255, 240, 160))
end)
-- The King travelling incognito: a long tan coat with the collar up (hat, shades and his crown
-- are props, so they can come off / on).
LOOKS.Stranger = {
	Shirt = rgb(176, 146, 100), Pants = rgb(70, 60, 50), ShirtMat = FABRIC,
	Build = function(a)
		R.hairShort(rgb(235, 235, 235))(a)
		R.beard(a, rgb(240, 240, 240))
		R.belt(a, rgb(120, 95, 60), rgb(200, 180, 120))
		a:piece("Torso", V(2.24, 0.46, 1.16), C(0, 0.82, 0.04), rgb(156, 126, 86), FABRIC)
		for _, x in { -0.35, 0.35 } do
			for i = 0, 2 do
				a:piece("Torso", V(0.13, 0.13, 0.05), C(x, 0.35 - i * 0.4, -0.52), rgb(90, 70, 50), nil, "Ball")
			end
		end
		a:piece("ThighL", V(1.04, 0.8, 1.04), C(0, -0.42, 0), rgb(176, 146, 100), FABRIC)
		a:piece("ThighR", V(1.04, 0.8, 1.04), C(0, -0.42, 0), rgb(176, 146, 100), FABRIC)
	end,
}

-- Props worn on the head ("Head" holds: studs from the head's centre, -Z = the face).
PROPS.Fedora = function()
	local felt = rgb(96, 76, 58)
	return {
		R.disc(92, 4, 34, felt, FABRIC),
		R.disc(62, 26, 48, felt, FABRIC),
		R.disc(63, 6, 40, rgb(40, 32, 26), FABRIC),
		{ V(40, 6, 30), C(0, 61, 0), felt, FABRIC, "Sphere" },
	}
end
PROPS.Shades = function()
	return {
		{ V(22, 12, 2), C(-12, 5, -32), rgb(20, 20, 24) },
		{ V(22, 12, 2), C(12, 5, -32), rgb(20, 20, 24) },
		{ V(8, 3, 2), C(0, 8, -32), rgb(20, 20, 24) },
		{ V(2, 3, 34), C(-24, 7, -16), rgb(20, 20, 24) },
		{ V(2, 3, 34), C(24, 7, -16), rgb(20, 20, 24) },
	}
end
PROPS.CrownHat = function()
	local gold = rgb(240, 196, 70)
	local t = { R.disc(68, 16, 37, gold, Enum.Material.Metal) }
	for i = 0, 5 do
		local ang = i / 6 * PI * 2
		local x, z = math.cos(ang) * 29, math.sin(ang) * 29
		table.insert(t, { V(11, 18, 11), C(x, 51, z) * CFrame.Angles(0, -ang, 0), gold, Enum.Material.Metal })
		table.insert(t, { V(8, 8, 8), C(x, 62, z), gold, Enum.Material.Metal, "Ball" })
	end
	table.insert(t, { V(12, 12, 5), C(0, 38, -34), rgb(220, 40, 60), Enum.Material.Neon })
	return t
end
PROPS.Dough = function()
	return {
		{ V(84, 12, 84), C(0, 0, 0), rgb(246, 232, 196), nil, "Sphere" },
		{ V(60, 13, 60), C(0, 0.6, 0), rgb(252, 242, 214), nil, "Sphere" },
	}
end
PROPS.PizzaTray = function()
	local t = { R.disc(76, 2, 1, rgb(190, 195, 200), Enum.Material.Metal) }
	for _, d in PROPS.HotPizza() do
		local o = d[2]
		table.insert(t, { d[1], C(o.X, o.Y + 1.2, o.Z) * o.Rotation, d[3], d[4], d[5] })
	end
	return t
end
PROPS.BigStack = function()
	local t = {}
	for i = 0, 6 do
		table.insert(t, R.disc(46, 2, 1 + i * 3.4, rgb(250, 250, 248)))
		table.insert(t, { V(12, 1.2, 9), C(-8 + (i % 3) * 7, 2.4 + i * 3.4, 5 - (i % 2) * 9), if i % 2 == 0 then rgb(214, 90, 50) else rgb(240, 200, 110), nil, "Sphere" })
	end
	table.insert(t, R.disc(20, 16, 34, rgb(236, 240, 246)))
	table.insert(t, R.disc(18, 14, 49, rgb(250, 250, 248)))
	return t
end

-- Standing, both hands up (arms raised to catch or toss), `k` of the way up.
local function handsUp(k: number, fwd: number?): any
	return {
		head = { pitch = 0.35 * k },
		armL = { at = chest(-0.34, -0.2 + 1.55 * k, (fwd or 0.75) - 0.35 * k) },
		armR = { at = chest(0.34, -0.2 + 1.55 * k, (fwd or 0.75) - 0.35 * k) },
	}
end

local function pizzaParty(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 42)
	Kit.title(ctx, 2, "Pizza Party")
	local scene = ctx.Scene
	local ALL = 1e5 - 1
	local TOP = R.FLOOR + TABLE

	-- Stools: the family round the right-hand table, Grandpa at the left one; the stranger keeps
	-- the room's own stool at the far side of the left table.
	ctx.HideFurn = { "FurnStool1", "FurnStool2" }
	local kidSeat = R.seat(150, -300, PI, 94)
	local mumSeat = R.seat(45, -400, PI / 2, 94)
	local dadSeat = R.seat(255, -400, -PI / 2, 94)
	local gpSeat = R.seat(-150, -300, PI, 94)
	local kingSeat = R.seat(-250, -400, PI / 2, 94)
	for i, st in { kidSeat, mumSeat, dadSeat, gpSeat } do
		scene:prop("Stool" .. i, "FurnStool")
		scene:place("Stool" .. i, 0, ALL, R.rootCF(st.X, st.Z, st.Phi) * C(0, 0, 6))
	end
	local function atSeat(st: any, right: number, fwd: number): CFrame
		local cf = R.rootCF(st.X, st.Z, st.Phi) * C(right, 0, -fwd)
		return C(cf.X, TOP + 0.4, cf.Z) * cf.Rotation
	end
	for i, st in { kidSeat, mumSeat, dadSeat } do
		scene:prop("Soda" .. i, "Soda")
		scene:place("Soda" .. i, 0, ALL, atSeat(st, 38, 60))
	end
	scene:prop("GpSlice", "Slice")
	scene:prop("KingSlice", "Slice")
	scene:prop("Fedora", "Fedora")
	scene:prop("Shades", "Shades")
	scene:prop("Crown", "CrownHat")
	scene:prop("Dough", "Dough")
	scene:prop("Pizza", "PizzaTray")
	scene:prop("Stack", "BigStack")
	Kit.balloon(ctx, -390, 250, -250, rgb(255, 90, 120))
	Kit.balloon(ctx, -362, 282, -228, rgb(90, 180, 255))
	Kit.balloon(ctx, -395, 265, -200, rgb(255, 210, 70))

	-- Beats
	local T_TOSS1 = 4.8
	local T_TOSS2 = 6.8
	local T_HAT = 8.25 -- the dough lands on Luigi's hat
	local T_NICE = 8.5 -- "Nice hat, Luigi!"
	local T_MAMMA = 10.2
	local T_SERVE = 11.6
	local T_TASTE = 15.2 -- "Mmm... MAGNIFICO!"
	local T_REVEAL = 17.6 -- off comes the hat: a crown!
	local T_BANQUET = 19.6
	local T_CASTLE = 23.4
	local T_SI = 25.2
	local T_WAITER = 27.2

	ctx:say(T_TOSS1 - 0.2, T_HAT, "Chef", "Ecco! The famous Luigi dough toss!", VOICE.Chef)
	ctx:say(T_NICE, T_MAMMA, "Kid", "Nice hat, Luigi!", VOICE.Kid)
	ctx:say(T_MAMMA, T_SERVE, "Chef", "...Mamma mia.", VOICE.Chef)
	ctx:say(T_SERVE + 0.2, T_TASTE - 0.2, "Chef", "One birthday pizza, extra cheesy!", VOICE.Chef)
	ctx:say(T_TASTE, T_REVEAL, "Stranger", "Mmm... MAGNIFICO!", VOICE.King)
	ctx:say(T_REVEAL + 0.2, T_BANQUET, "King", "Luigi! I am the KING!", VOICE.King)
	ctx:say(T_BANQUET, T_CASTLE, "King", "You shall cook at my Royal Banquet... and bring the birthday boy!", VOICE.King)
	ctx:say(T_CASTLE, T_SI, "Kid", "A real CASTLE?!", VOICE.Kid)
	ctx:say(T_SI, T_WAITER, "Chef", "Si, si, Your Majesty!", VOICE.Chef)
	ctx:say(T_WAITER, T_WAITER + 2.2, "Waiter", "Mamma mia... look at all these dishes!", VOICE.Waiter)

	-- Luigi -------------------------------------------------------------------------------------
	local chef = scene:actor("Chef", "Chef")
	local cx, cz = 270, -310
	local toFamily = R.phiOf(150 - cx, -400 - cz)
	local pc = R.newPlan(chef, cx, cz, toFamily)
	local inHands = { Dough = { "both", off = C(0, 7, 0) } }
	local onHat = { Dough = { "Head", off = C(0, 86, 2) } }
	-- kneading and showing off the dough
	pc:still(T_TOSS1, function(u, _c)
		local w = math.sin(u * 3)
		return { bob = R.breathe(u), head = { pitch = -0.15 }, armL = { at = chest(-0.36 + w * 0.05, -0.35, 0.95) }, armR = { at = chest(0.36 + w * 0.05, -0.35, 0.95) } }
	end, inHands)
	-- a toss: dip, push up (release), arms up while it flies, catch
	local function toss(release: number, flight: number, catch: boolean, hold: any)
		local DIP = 0.45
		pc:still(DIP, function(u)
			local k = u / DIP
			local p = handsUp(smooth((k - 0.4) / 0.6) * 0.9)
			p.bob = -0.04 * math.sin(k * PI)
			return p
		end, inHands)
		pc:still(flight, function(u)
			local p = handsUp(if catch then 0.9 else 0.9 - 0.9 * smooth(u / flight))
			p.head = { pitch = 0.45 * math.sin(math.clamp(u / flight, 0, 1) * PI) + 0.1 }
			return p
		end, if catch then nil else hold)
		if not catch then
			pc:split(pc.Steps[#pc.Steps], flight - 0.01, onHat)
		end
		return release
	end
	toss(T_TOSS1 + 0.45, T_TOSS2 - T_TOSS1 - 0.45 - 0.3, true, nil)
	pc:still(0.3, function(u)
		return handsUp(0.9 - 0.4 * smooth(u / 0.3))
	end, inHands)
	toss(T_TOSS2 + 0.45, T_HAT - T_TOSS2 - 0.45, false, nil)
	-- deadpan, then a shrug
	pc:still(T_MAMMA - pc.T, function(u)
		local k = smooth(u / 0.6)
		return { head = { pitch = 0.05 }, armL = { p = 0.3 - 0.25 * k, r = 0.1, e = 0.4 }, armR = { p = 0.3 - 0.25 * k, r = 0.1, e = 0.4 } }
	end, onHat)
	pc:still(T_SERVE - T_MAMMA, function(u)
		local k = smooth(math.min(u, 1.4 - u) / 0.35)
		return { head = { roll = 0.12 * k, pitch = -0.05 }, armL = { p = 0.5 * k, r = 0.9 * k, e = 1.3 * k }, armR = { p = 0.5 * k, r = 0.9 * k, e = 1.3 * k } }
	end, onHat)
	-- the birthday pizza: off the oven ledge, round the corner, onto the table
	local withPizza = { Dough = onHat.Dough, Pizza = { "both", off = C(0, -2, -6) } }
	pc:turn(0, onHat)
	pc:swap(1.1, P.reach(-0.3 * S, 128, 0.95 * S, 0.3 * S, 128, 0.95 * S, 1.1, 0.2), onHat, withPizza)
	scene:place("Pizza", 0, T_SERVE + 1.0, ctx:at(250, 119, -262))
	local tableSpot = V2(190, -380)
	pc:walk({ V2(248, -338) }, withPizza, function(_u, _c)
		return { head = { pitch = -0.1 }, armL = { at = chest(-0.42, -0.3, 0.9) }, armR = { at = chest(0.42, -0.3, 0.9) } }
	end, 90)
	pc:turn(R.phiOf(tableSpot.X - 248, tableSpot.Y + 338), withPizza)
	local tPut = pc.T
	pc:swap(1.2, P.reach(-0.3 * S, TABLE + 12, 1.35 * S, 0.3 * S, TABLE + 12, 1.35 * S, 1.2, 0.3), withPizza, onHat)
	scene:place("Pizza", tPut + 0.6, ALL, ctx:at(tableSpot.X, TABLE + 0.4, tableSpot.Y))
	-- watches the stranger, jumps at the crown, bows
	local toKing = R.phiOf(-270 - 248, -335 + 338)
	pc:turn(toKing, onHat)
	pc:still(T_REVEAL - pc.T, P.idle, onHat)
	pc:still(1.4, P.startle, onHat)
	pc:still(T_SI - pc.T, P.idle, onHat)
	pc:still(1.8, function(u)
		local k = math.sin(math.clamp(u / 1.8, 0, 1) * PI)
		return { lean = 0.75 * k, head = { pitch = -0.3 * k }, armL = { p = 0.1, r = 0.05, e = 0.2 }, armR = { p = 1.2 * k, r = -0.2 * k, e = 1.4 * k } }
	end, onHat)
	pc:still(30, P.idle, onHat)
	table.insert(scene.Plans, pc)

	-- the dough's two flights: up and back into his hands, then up and down onto his hat
	local function handsPoint(): Vector3
		local b = chef.Bones
		if not b then
			return ctx:R(cx, 260, cz)
		end
		return b.GripL.Position:Lerp(b.GripR.Position, 0.5) + V(0, 7, 0)
	end
	local up1 = T_TOSS1 + 0.45
	local down1 = T_TOSS2 - 0.3
	local up2 = T_TOSS2 + 0.45
	local fromPos: Vector3? = nil
	local function flight(t0: number, t1: number, hat: boolean): (number) -> CFrame
		return function(t)
			local k = math.clamp((t - t0) / (t1 - t0), 0, 1)
			if k < 0.02 or not fromPos then
				fromPos = handsPoint()
			end
			local a = fromPos :: Vector3
			local b = if hat and chef.Bones then (chef.Bones.Head * C(0, 86, 2)).Position else handsPoint()
			local p = a:Lerp(b, k) + V(0, 4 * 95 * k * (1 - k), 0)
			return ctx.Origin:Inverse() * (CFrame.new(p) * CFrame.Angles(0, k * 9, math.sin(k * PI) * 0.25))
		end
	end
	scene:place("Dough", up1, down1, flight(up1, down1, false))
	scene:place("Dough", up2, T_HAT, flight(up2, T_HAT, true))

	-- The family ---------------------------------------------------------------------------------
	local kid = scene:actor("Kid", "KidParty")
	local pk = R.newPlan(kid, 0, 0, 0)
	R.seated(pk, kidSeat)
	local kidToChef = 0.9
	pk:still(T_TOSS1, P.talkTo(0.5))
	pk:still(T_HAT - T_TOSS1, P.clap)
	pk:still(T_MAMMA - T_HAT, P.talkTo(kidToChef))
	pk:still(T_SERVE - T_MAMMA, P.laugh)
	pk:still(T_TASTE - T_SERVE, cheer)
	pk:still(T_REVEAL - T_TASTE, P.talkTo(-1.2))
	pk:still(1.4, P.startle)
	pk:still(T_CASTLE - pk.T, P.talkTo(-1.2))
	pk:still(T_SI - T_CASTLE, cheer)
	pk:still(30, P.clap)
	table.insert(scene.Plans, pk)

	local mum = scene:actor("Mum", "MumParty")
	local pm = R.newPlan(mum, 0, 0, 0)
	R.seated(pm, mumSeat)
	pm:still(T_TOSS1, P.talkTo(0.6))
	pm:still(T_HAT - T_TOSS1, P.clap)
	pm:still(T_SERVE - T_HAT, P.laugh)
	pm:still(T_TASTE - T_SERVE, P.clap)
	pm:still(T_REVEAL - T_TASTE, P.talkTo(-1.4))
	pm:still(1.4, P.startle)
	pm:still(30, P.talkTo(-1.2))
	table.insert(scene.Plans, pm)

	local dad = scene:actor("Dad", "DadParty")
	local pd = R.newPlan(dad, 0, 0, 0)
	R.seated(pd, dadSeat)
	pd:still(T_TOSS1, P.talkTo(0.4))
	pd:still(T_HAT - T_TOSS1, P.talkTo(1.0))
	pd:still(T_SERVE - T_HAT, P.laugh)
	pd:still(T_TASTE - T_SERVE, P.clap)
	pd:still(T_REVEAL - T_TASTE, P.talkTo(0.3))
	pd:still(1.4, P.startle)
	pd:still(30, P.talkTo(0.2))
	table.insert(scene.Plans, pd)

	-- Grandpa, at the other table with a slice
	local gp = scene:actor("Grandpa", "GrandpaParty")
	local pg = R.newPlan(gp, 0, 0, 0)
	R.seated(pg, gpSeat)
	local gpSlice = { GpSlice = { "R", off = C(0, 0, -4) * CFrame.Angles(0, PI, 0) } }
	pg:still(T_REVEAL, P.bite, gpSlice)
	pg:still(1.4, P.startle, gpSlice)
	pg:still(30, P.talkTo(-0.9), gpSlice)
	table.insert(scene.Plans, pg)

	-- The stranger: eats, tastes, stands, lifts the hat: a crown. Points at the birthday boy.
	local king = scene:actor("King", "Stranger")
	local pq = R.newPlan(king, 0, 0, 0)
	R.seated(pq, kingSeat)
	local disguise = { Fedora = { "Head", off = C(0, 0, 0) }, Shades = { "Head", off = C(0, 0, 0) } }
	local function with(extra: { [string]: any }): { [string]: any }
		local h = table.clone(disguise)
		for k, v in extra do
			h[k] = v
		end
		return h
	end
	local slice = { "R", off = C(0, 0, -4) * CFrame.Angles(0, PI, 0) }
	pq:still(T_TASTE, P.bite, with({ KingSlice = slice }))
	-- the tasting: eyes closed, a long appreciative lean back
	pq:still(1.0, function(u, c)
		local p = P.bite(1.2, c)
		p.lean = -0.1 * smooth(u / 0.6)
		p.head = { pitch = 0.25 * smooth(u / 0.6) }
		return p
	end, with({ KingSlice = slice }))
	pq:standUp(V2(-270, -335), disguise)
	pq:turn(R.phiOf(150 + 270, -300 + 335), disguise)
	pq:still(T_REVEAL - pq.T, P.idle, disguise)
	-- off with the hat (and the shades), revealing the crown
	local crownOn = { Crown = { "Head", off = C(0, 0, 0) } }
	local LIFT = 1.2
	pq:still(LIFT, function(u)
		local k = smooth(u / 0.5)
		return { head = { pitch = 0.1 * k }, armL = { p = 0.1, r = 0.1, e = 0.3 }, armR = { p = 2.9 * k, r = 0.35 * k, e = 0.3 * k } }
	end, disguise)
	pq:split(pq.Steps[#pq.Steps], 0.5, { Fedora = { "R", off = C(0, 14, 0) }, Crown = crownOn.Crown })
	pq:still(T_BANQUET - pq.T, function(u)
		return { bob = R.breathe(u), head = { pitch = 0.12 }, armL = { p = 0.1, r = 0.1, e = 0.3 }, armR = { p = 2.9, r = 0.35 + math.sin(u * 3) * 0.05, e = 0.3 } }
	end, { Fedora = { "R", off = C(0, 14, 0) }, Crown = crownOn.Crown })
	pq:still(3.6, P.point(V(150, 0, -300)), { Crown = crownOn.Crown, Fedora = { "L", off = C(0, -10, 0) * CFrame.Angles(0, 0, PI / 2) } })
	pq:still(30, P.idle, { Crown = crownOn.Crown, Fedora = { "L", off = C(0, -10, 0) * CFrame.Angles(0, 0, PI / 2) } })
	table.insert(scene.Plans, pq)

	-- The waiter, with the evening's dishes, then the dishwasher.
	local waiter = scene:actor("Waiter", "Waiter")
	local pw = R.newPlan(waiter, -160, -168, R.phiOf(150 + 160, -400 + 168))
	local carry = { Stack = { "both", off = C(0, -6, -4) } }
	local function carrying(u: number, _c: any): any
		return { bob = R.breathe(u), head = { pitch = -0.1, yaw = math.sin(u * 0.5) * 0.2 }, armL = { at = chest(-0.42, -0.3, 0.9) }, armR = { at = chest(0.42, -0.3, 0.9) } }
	end
	pw:still(T_WAITER, carrying, carry)
	pw:still(2.2, function(u, c)
		local p = carrying(u, c)
		p.head = { pitch = -0.45, yaw = 0 }
		p.bob = -0.02
		return p
	end, carry)
	local beats = ending(ctx, pw, "Waiter", "Stack", -1, "Presto, presto, tiny helpers!", { V2(-190, -150), V2(-260, -120) }, {
		ArriveEye = { ctx:R(-5, 305, -390), ctx:R(-15, 290, -370) },
	})
	table.insert(scene.Plans, pw)

	-- Shots -------------------------------------------------------------------------------------
	-- 1. the party, from the corner by the front window
	ctx:shot(0, T_TOSS1 - 0.3, {
		eye = { ctx:R(385, 330, -500), ctx:R(370, 318, -490) },
		look = { ctx:R(-20, 160, -320), ctx:R(0, 165, -320) },
		fov = { 60, 56 },
	})
	-- 2. Luigi's dough toss, three-quarters on
	ctx:shot(T_TOSS1 - 0.3, T_NICE, {
		eye = { ctx:R(140, 325, -425), ctx:R(146, 322, -420) },
		look = { ctx:R(266, 275, -312), ctx:R(268, 290, -312) },
		fov = { 64, 64 },
	})
	-- 3. the kid (from across the table)
	ctx:shot(T_NICE, T_MAMMA, {
		eye = { ctx:R(150, 335, -455), ctx:R(150, 332, -450) },
		look = { ctx:R(150, 212, -300), ctx:R(150, 212, -300) },
		fov = { 34, 32 },
	})
	-- 4. Luigi, closer, hat and all
	ctx:shot(T_MAMMA, T_SERVE, {
		eye = { ctx:R(165, 262, -400), ctx:R(172, 260, -394) },
		look = { ctx:R(270, 240, -310), ctx:R(270, 240, -310) },
		fov = { 46, 42 },
	})
	-- 5. serving the pizza, from the front corner
	ctx:shot(T_SERVE, T_TASTE, {
		eye = { ctx:R(35, 330, -228), ctx:R(45, 326, -232) },
		look = Kit.follow(chef, "Torso", V(0, -40, 0)),
		fov = { 54, 52 },
	})
	-- 6. the stranger tastes it
	ctx:shot(T_TASTE, T_REVEAL, {
		eye = { ctx:R(-110, 238, -425), ctx:R(-115, 240, -418) },
		look = Kit.follow(king, "Head", V(0, -12, 0)),
		fov = { 50, 50 },
	})
	-- 7. the reveal
	ctx:shot(T_REVEAL, T_CASTLE, {
		eye = { ctx:R(-118, 250, -385), ctx:R(-125, 246, -380) },
		look = { ctx:R(-270, 262, -335), ctx:R(-270, 255, -335) },
		fov = { 50, 46 },
	})
	-- 8. the kid can't believe it
	ctx:shot(T_CASTLE, T_SI, {
		eye = { ctx:R(150, 335, -455), ctx:R(150, 330, -448) },
		look = { ctx:R(150, 212, -300), ctx:R(150, 214, -300) },
		fov = { 36, 34 },
	})
	-- 9. Luigi's answer, on the King (who looks very pleased with himself)
	ctx:shot(T_SI, T_WAITER, {
		eye = { ctx:R(-112, 244, -392), ctx:R(-116, 242, -388) },
		look = { ctx:R(-270, 252, -335), ctx:R(-270, 250, -335) },
		fov = { 44, 42 },
	})
	-- 10. the waiter and his mountain of dishes
	ctx:shot(T_WAITER, beats.Arrive - 0.9, {
		eye = { ctx:R(40, 250, -185), ctx:R(34, 244, -190) },
		look = Kit.follow(waiter, "Torso", V(0, 20, 0)),
		fov = { 50, 50 },
	})
	return ctx
end

----------------------------------------------------------------------------------------------------
-- Chapter 3: Royal Banquet (the level-3 great hall)
----------------------------------------------------------------------------------------------------

-- The King with his crown as a prop (so it can be knocked off).
LOOKS.KingBare = {
	Shirt = rgb(150, 26, 40), Pants = rgb(230, 190, 90), ShirtMat = FABRIC,
	Build = function(a)
		R.hairShort(rgb(235, 235, 235))(a)
		R.beard(a, rgb(240, 240, 240))
		R.belt(a, rgb(230, 190, 90), rgb(255, 230, 120))
		a:piece("Torso", V(2.2, 2.6, 0.14), C(0, -0.35, 0.58), rgb(170, 30, 44), FABRIC)
		a:piece("Torso", V(2.3, 0.36, 1.2), C(0, 0.92, 0.04), rgb(248, 248, 244), FABRIC)
		for i = 0, 3 do
			a:piece("Torso", V(0.1, 0.16, 0.04), C(-0.9 + i * 0.6, 0.9, -0.57), rgb(34, 34, 40))
		end
		a:piece("Torso", V(0.12, 1.7, 0.06), C(0, -0.05, -0.53), rgb(230, 190, 90), Enum.Material.Metal)
	end,
}
LOOKS.ChefDough = variant("Chef", function(a)
	-- the dough from chapter 2 is still up there
	a:piece("Head", V(1.66, 0.26, 1.66), C(0, 1.78, 0.04), rgb(246, 232, 196), nil, "Sphere")
end)

PROPS.Goblet = function()
	local gold = rgb(236, 190, 70)
	return {
		R.disc(14, 2, -12, gold, Enum.Material.Metal),
		R.disc(4, 16, -4, gold, Enum.Material.Metal),
		R.disc(16, 14, 9, gold, Enum.Material.Metal),
		R.disc(13, 1, 15.6, rgb(150, 20, 40)),
	}
end
PROPS.Cake = function()
	local t = {
		R.disc(86, 3, 1.5, rgb(236, 236, 240), Enum.Material.Metal),
		R.disc(72, 26, 16, rgb(250, 236, 240)),
		R.disc(74, 5, 28, rgb(255, 150, 190)),
		R.disc(52, 22, 40, rgb(250, 236, 240)),
		R.disc(54, 5, 50, rgb(255, 150, 190)),
	}
	for i = 0, 7 do
		local a = i / 8 * PI * 2
		table.insert(t, { V(5, 8, 5), C(math.cos(a) * 33, 27, math.sin(a) * 33), rgb(230, 60, 90), nil, "Ball" })
	end
	for i = 0, 4 do
		local a = i / 5 * PI * 2
		table.insert(t, R.disc(3.4, 14, 58, if i % 2 == 0 then rgb(120, 190, 255) else rgb(255, 220, 90), nil, math.cos(a) * 14, math.sin(a) * 14))
	end
	return t
end
PROPS.CakeFlames = function()
	local t = {}
	for i = 0, 4 do
		local a = i / 5 * PI * 2
		table.insert(t, { V(4, 7, 4), C(math.cos(a) * 14, 69, math.sin(a) * 14), rgb(255, 200, 80), Enum.Material.Neon, "Sphere" })
	end
	return t
end
PROPS.Pike = function()
	return {
		{ V(4, 300, 4), C(0, 40, 0), rgb(110, 76, 44), Enum.Material.Wood },
		{ V(12, 30, 3), C(0, 204, 0), rgb(200, 205, 214), Enum.Material.Metal },
		{ V(20, 5, 5), C(0, 188, 0), rgb(200, 205, 214), Enum.Material.Metal },
	}
end
PROPS.JuggleBall = function()
	return { { V(16, 16, 16), C(0, 0, 0), rgb(250, 90, 90), nil, "Ball" } }
end

local function royalBanquet(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 44)
	Kit.title(ctx, 3, "Royal Banquet")
	local scene = ctx.Scene
	local ALL = 1e5 - 1
	local TOP = R.FLOOR + TABLE

	-- Seats. The room keeps its throne and the Queen's chair; the family get chairs of their own.
	local kingSeat = R.seat(94, -414, -PI / 2, 98)
	local queenSeat = R.seat(-94, -414, PI / 2, 98)
	local kidSeat = R.seat(0, -215, PI, 108)
	local gpSeat = R.seat(94, -280, -PI / 2, 98)
	local dadSeat = R.seat(-94, -280, PI / 2, 98)
	local mumSeat = R.seat(-94, -345, PI / 2, 98)
	local function chair(name: string, kind: string, st: any)
		scene:prop(name, kind)
		scene:place(name, 0, ALL, R.rootCF(st.X, st.Z, st.Phi) * C(0, 0, 4))
	end
	chair("KidChair", "FurnKidChair", kidSeat)
	chair("GpChair", "FurnChair", gpSeat)
	chair("DadChair", "FurnChair", dadSeat)
	chair("MumChair", "FurnChair", mumSeat)
	local function atSeat(st: any, right: number, fwd: number): CFrame
		local cf = R.rootCF(st.X, st.Z, st.Phi) * C(right, 0, -fwd)
		return C(cf.X, TOP + 0.4, cf.Z) * cf.Rotation
	end
	local goblets = {}
	for i, st in { kingSeat, queenSeat, gpSeat, dadSeat, mumSeat, kidSeat } do
		local name = "Goblet" .. i
		scene:prop(name, "Goblet")
		scene:place(name, 0, ALL, atSeat(st, 30, 62) * C(0, 12, 0))
		scene:prop("Plate" .. i, "Plate")
		scene:place("Plate" .. i, 0, ALL, atSeat(st, -6, 70))
		goblets[i] = name
	end
	scene:prop("Cake", "Cake")
	scene:prop("Flames", "CakeFlames")
	scene:prop("Crown", "CrownHat")
	scene:prop("Stack", "BigStack")
	scene:place("Stack", 0, ALL, atSeat(dadSeat, 34, 80))
	for i = 1, 3 do
		scene:prop("Ball" .. i, "JuggleBall")
	end

	-- Beats
	local T_TOAST = 4.8 -- "A toast!"
	local T_HOORAY = 8.8
	local T_CAKE = 10.4 -- Luigi comes in with the cake
	local T_BLOW = 16.6
	local T_TRICK = 18.6 -- "A royal trick shot!"
	local T_BONK = 20.6 -- the ball knocks the crown off
	local T_LAND = 21.7 -- ...onto Grandpa's head
	local T_GP = 22.2 -- "...Is it raining crowns now?"
	local T_KING = 24.8 -- "Keep it!"
	local T_DAD = 27.8 -- "I'll do the dishes."

	ctx:say(T_TOAST, T_HOORAY, "King", "A toast! To Luigi's cooking... and to the birthday boy!", VOICE.King)
	ctx:say(T_HOORAY, T_CAKE, "Everyone", "HOORAY!", VOICE.Kid)
	ctx:say(T_CAKE + 1.8, T_BLOW - 0.2, "Chef", "Happy birthday, bambino! Make a wish!", VOICE.Chef)
	ctx:say(T_TRICK, T_BONK, "Jester", "And now... a royal trick shot!", VOICE.Jester)
	ctx:say(T_GP, T_KING, "Grandpa", "...Is it raining crowns now?", VOICE.Grandpa)
	ctx:say(T_KING, T_DAD, "King", "Ho ho! Keep it, old friend!", VOICE.King)
	ctx:say(T_DAD, T_DAD + 2.6, "Dad", "I'll do the dishes. Family tradition!", VOICE.Dad)

	local toast = function(yaw: number): (number, any) -> any
		return function(u: number, c: any): any
			local s = c.Actor.S
			local k = smooth(math.min(u, 3.6 - u) / 0.5)
			return {
				bob = R.breathe(u),
				head = { yaw = yaw * 0.6, pitch = 0.15 * k },
				armL = { at = local3(c, -0.6 * s, TABLE + 26, 1.2 * s) },
				armR = { p = 2.4 * k + 0.3, r = 0.2, e = 0.3 },
			}
		end
	end
	local gobletHold = function(i: number): any
		return { [goblets[i]] = { "R", off = C(0, 2, 0) } }
	end

	-- The King: the toast, the bonk, the laugh.
	local king = scene:actor("King", "KingBare")
	local pk = R.newPlan(king, 0, 0, 0)
	R.seated(pk, kingSeat)
	local crownOn = { Crown = { "Head", off = C(0, 0, 0) } }
	local function kingHold(extra: any?): any
		local h = table.clone(crownOn)
		for k, v in extra or {} do
			h[k] = v
		end
		return h
	end
	pk:still(T_TOAST, P.rest, crownOn)
	pk:still(T_HOORAY - T_TOAST + 1.2, toast(0.4), kingHold(gobletHold(1)))
	pk:still(T_BONK - pk.T, P.talkTo(0.9), crownOn)
	pk:still(T_KING - T_BONK, P.startle)
	pk:still(30, P.laugh)
	table.insert(scene.Plans, pk)

	local queen = scene:actor("Queen", "Queen")
	local pq = R.newPlan(queen, 0, 0, 0)
	R.seated(pq, queenSeat)
	pq:still(T_HOORAY, P.talkTo(0.5))
	pq:still(1.6, toast(0.2), gobletHold(2))
	pq:still(T_BLOW + 0.8 - pq.T, P.talkTo(0.8))
	pq:still(T_TRICK - pq.T, P.clap)
	pq:still(T_KING - T_TRICK, P.talkTo(-0.6))
	pq:still(30, P.laugh)
	table.insert(scene.Plans, pq)

	-- The family
	local kid = scene:actor("Kid", "KidParty")
	local pkd = R.newPlan(kid, 0, 0, 0)
	R.seated(pkd, kidSeat)
	pkd:still(T_HOORAY, P.talkTo(0.3))
	pkd:still(1.6, cheer)
	pkd:still(T_BLOW - pkd.T, P.talkTo(-0.6))
	-- a big breath and a blow at the candles
	pkd:still(1.6, function(u, c)
		local s = c.Actor.S
		local breath = smooth(u / 0.6)
		local blow = smooth((u - 0.7) / 0.3)
		return {
			lean = -0.08 * breath * (1 - blow) + 0.3 * blow,
			bob = 0.03 * breath * (1 - blow),
			head = { pitch = 0.2 * breath * (1 - blow) - 0.25 * blow },
			armL = { at = local3(c, -0.55 * s, TABLE + 26, 1.2 * s) },
			armR = { at = local3(c, 0.55 * s, TABLE + 26, 1.2 * s) },
		}
	end)
	pkd:still(T_TRICK - pkd.T, cheer)
	pkd:still(T_GP - T_TRICK, P.talkTo(-0.9))
	pkd:still(30, P.laugh)
	table.insert(scene.Plans, pkd)
	-- the candles go out when the kid blows
	scene:place("Cake", T_CAKE + 3.6, ALL, ctx:at(15, TABLE + 0.4, -270))
	scene:place("Flames", 0, T_BLOW + 1.0, function(t)
		local b = scene.Props.Cake.Pieces[1]
		if t < T_CAKE + 3.6 and b then
			return ctx.Origin:Inverse() * (b.Part.CFrame * b.Offset:Inverse())
		end
		return ctx:at(15, TABLE + 0.4, -270)
	end)

	local gp = scene:actor("Grandpa", "Grandpa")
	local pg = R.newPlan(gp, 0, 0, 0)
	R.seated(pg, gpSeat)
	pg:still(T_HOORAY, P.talkTo(0.3))
	pg:still(1.6, toast(0), gobletHold(3))
	pg:still(T_BLOW + 1 - pg.T, P.talkTo(0.7))
	pg:still(T_LAND - pg.T, P.clap)
	pg:still(0.8, P.startle)
	pg:still(T_KING + 0.4 - pg.T, function(u, c)
		local p = P.rest(u, c)
		p.head = { pitch = 0.15, yaw = 0.2 }
		return p
	end, crownOn)
	pg:still(30, P.laugh, crownOn)
	table.insert(scene.Plans, pg)

	local mum = scene:actor("Mum", "Mum")
	local pm = R.newPlan(mum, 0, 0, 0)
	R.seated(pm, mumSeat)
	pm:still(T_HOORAY, P.talkTo(-0.4))
	pm:still(1.6, toast(0), gobletHold(5))
	pm:still(T_BLOW + 1 - pm.T, P.talkTo(-0.8))
	pm:still(T_GP - pm.T, P.clap)
	pm:still(30, P.laugh)
	table.insert(scene.Plans, pm)

	-- Luigi brings the cake, lit, along the far side of the hall.
	local chef = scene:actor("Chef", "ChefDough")
	local pc = R.newPlan(chef, 330, -150, -PI / 2)
	local withCake = { Cake = { "both", off = C(0, -4, -8) }, Flames = { "both", off = C(0, -4, -8) } }
	local cakeArms = function(_u: number, _c: any): any
		return { head = { pitch = -0.05 }, armL = { at = chest(-0.44, -0.2, 0.95) }, armR = { at = chest(0.44, -0.2, 0.95) } }
	end
	pc:still(T_CAKE, cakeArms, withCake)
	pc:walk({ V2(150, -155), V2(84, -208) }, withCake, cakeArms, 95)
	pc:turn(R.phiOf(15 - 84, -270 + 208), withCake, cakeArms)
	local tSet = pc.T
	pc:swap(1.2, P.reach(-0.36 * S, TABLE + 10, 1.4 * S, 0.36 * S, TABLE + 10, 1.4 * S, 1.2, 0.35), withCake, nil)
	pc:walk({ V2(170, -175), V2(300, -262) }, nil, nil, 90)
	pc:turn(R.phiOf(-200, -60))
	pc:still(T_TRICK - pc.T, P.clap)
	pc:still(T_KING - T_TRICK, P.idle)
	pc:still(30, P.laugh)
	table.insert(scene.Plans, pc)
	assert(tSet + 0.6 <= T_CAKE + 3.8, "cake timing")

	-- The jester juggles by the fireplace; one ball goes astray.
	local jester = scene:actor("Jester", "Jester")
	local jx, jz = 230, -330
	local pj = R.newPlan(jester, jx, jz, R.phiOf(94 - jx, -414 - jz))
	local function juggle(u: number, _c: any): any
		local a = math.sin(u * 7)
		return {
			bob = math.abs(math.sin(u * 7)) * 0.02,
			head = { pitch = 0.35 },
			armL = { at = chest(-0.45, -0.1 + 0.25 * a, 0.8) },
			armR = { at = chest(0.45, -0.1 - 0.25 * a, 0.8) },
		}
	end
	pj:still(T_TRICK, juggle)
	pj:still(T_BONK - 0.4 - T_TRICK, juggle)
	pj:still(0.6, function(u)
		local k = smooth(u / 0.3)
		return { head = { pitch = 0.3 }, armL = { at = chest(-0.45, -0.1, 0.8) }, armR = { p = 2.5 * k, r = 0.1, e = 0.2 } }
	end)
	pj:still(T_GP - pj.T, function(u)
		return { head = { pitch = 0.1, yaw = -0.3 }, armL = { p = 1.0, r = 0.5, e = 1.2 }, armR = { p = 1.0, r = 0.5, e = 1.2 } }
	end)
	pj:still(30, P.laugh)
	table.insert(scene.Plans, pj)
	local release = T_BONK - 0.35
	local crownAt = function(): Vector3
		local b = king.Bones
		return if b then (b.Head * C(0, 40, 0)).Position else ctx:R(94, 280, -414)
	end
	for i = 1, 3 do
		local name = "Ball" .. i
		local ph = (i - 1) / 3
		scene:place(name, 0, if i == 1 then release else ALL, function(t)
			local b = jester.Bones
			if not b then
				return ctx:at(jx, 260, jz)
			end
			local mid = b.GripL.Position:Lerp(b.GripR.Position, 0.5)
			local c = ((t * 0.9) + ph) % 1
			local side = math.cos(c * PI * 2) * 28
			local up = math.abs(math.sin(c * PI)) * 95 + 12
			local w = CFrame.new(mid) * (ctx.Origin * R.rootCF(0, 0, R.phiOf(94 - jx, -414 - jz))).Rotation * C(side, up, -10)
			return ctx.Origin:Inverse() * w
		end)
	end
	local ballFrom: Vector3? = nil
	scene:place("Ball1", release, T_BONK + 1.2, function(t)
		local k = math.clamp((t - release) / (T_BONK - release), 0, 1.6)
		local b = jester.Bones
		if not ballFrom and b then
			ballFrom = b.GripR.Position + V(0, 20, 0)
		end
		local a = ballFrom or ctx:R(jx, 280, jz)
		local target = crownAt()
		if k <= 1 then
			return ctx.Origin:Inverse() * CFrame.new(a:Lerp(target, k) + V(0, 4 * 50 * k * (1 - k), 0))
		end
		-- bounces off and away
		local d = k - 1
		return ctx.Origin:Inverse() * CFrame.new(target + V(-60 * d, 50 * d - 200 * d * d, 30 * d))
	end)
	-- the crown: on the King, then up and over onto Grandpa
	local crownFrom: CFrame? = nil
	scene:place("Crown", T_BONK, T_LAND, function(t)
		local k = math.clamp((t - T_BONK) / (T_LAND - T_BONK), 0, 1)
		local pc2 = scene.Props.Crown.Pieces[1]
		if not crownFrom and pc2 then
			crownFrom = pc2.Part.CFrame * pc2.Offset:Inverse()
		end
		local a = (crownFrom or CFrame.new(ctx:R(94, 280, -414))).Position
		local b = if gp.Bones then gp.Bones.Head.Position else ctx:R(94, 241, -280)
		local p = a:Lerp(b, k) + V(0, 4 * 110 * k * (1 - k), 0)
		local rot = if crownFrom then crownFrom.Rotation else CFrame.identity
		return ctx.Origin:Inverse() * (CFrame.new(p) * rot * CFrame.Angles(k * PI * 2, 0, 0))
	end)

	-- Guards at attention
	for i, g in { { 285, -400, -PI / 2 }, { -270, -400, PI / 2 } } do
		local guard = scene:actor("Guard" .. i, "Guard")
		local pl = R.newPlan(guard, g[1], g[2], g[3])
		scene:prop("Pike" .. i, "Pike")
		pl:still(60, function(u, c)
			local s = c.Actor.S
			return { bob = R.breathe(u + i), head = { yaw = math.sin(u * 0.3 + i) * 0.15 }, armL = { p = 0.05, r = 0.06, e = 0.15 }, armR = { at = local3(c, 0.7 * s, 150, 0.35 * s) } }
		end, { ["Pike" .. i] = { "R", off = C(0, 0, 0) } })
		table.insert(scene.Plans, pl)
	end

	-- Dad: stands, gathers the plates, and it's his turn at the dishwasher.
	local dad = scene:actor("Dad", "Dad")
	local pd = R.newPlan(dad, 0, 0, 0)
	R.seated(pd, dadSeat)
	pd:still(T_HOORAY, P.talkTo(0.4))
	pd:still(1.6, toast(0), gobletHold(4))
	pd:still(T_BLOW + 1 - pd.T, P.talkTo(0.8))
	pd:still(T_GP - pd.T, P.clap)
	pd:still(T_DAD - T_GP, P.laugh)
	local carry = { Stack = { "both", off = C(0, -6, -4) } }
	pd:swap(1.2, P.reach(0.2 * S, TABLE + 36, 1.6 * S, 0.9 * S, TABLE + 36, 1.6 * S, 1.2, 0.2), nil, carry)
	pd:standUp(V2(-100, -222), carry)
	pd:walk({ V2(-60, -157), V2(70, -157) }, carry, function(_u, _c)
		return { head = { pitch = -0.1 }, armL = { at = chest(-0.42, -0.3, 0.9) }, armR = { at = chest(0.42, -0.3, 0.9) } }
	end)
	local beats = ending(ctx, pd, "Dad", "Stack", 1, "Good luck, little helpers! Make it sparkle!", { V2(150, -215), V2(200, -150) }, {
		ArriveEye = { ctx:R(-120, 300, -85), ctx:R(-110, 290, -92) },
		RevealEye = { ctx:R(-110, 305, -148), ctx:R(-40, 92, -140) },
	})
	table.insert(scene.Plans, pd)

	-- Shots -------------------------------------------------------------------------------------
	-- 1. the great hall, down the length of the table
	ctx:shot(0, T_TOAST - 0.2, {
		eye = { ctx:R(0, 325, -505), ctx:R(0, 315, -492) },
		look = { ctx:R(0, 180, -260), ctx:R(0, 180, -260) },
		fov = { 60, 56 },
	})
	-- 2. the King's toast
	ctx:shot(T_TOAST - 0.2, T_HOORAY, {
		eye = { ctx:R(-150, 335, -205), ctx:R(-142, 332, -210) },
		look = { ctx:R(94, 230, -414), ctx:R(94, 236, -414) },
		fov = { 36, 34 },
	})
	-- 3. HOORAY, from behind the birthday boy
	ctx:shot(T_HOORAY, T_CAKE, {
		eye = { ctx:R(0, 335, -150), ctx:R(0, 330, -158) },
		look = { ctx:R(0, 190, -380), ctx:R(0, 190, -380) },
		fov = { 58, 56 },
	})
	-- 4. Luigi and the cake
	ctx:shot(T_CAKE, T_BLOW - 0.2, {
		eye = { ctx:R(-250, 330, -118), ctx:R(-240, 326, -122) },
		look = Kit.follow(chef, "Torso", V(0, -30, 0)),
		fov = { 42, 40 },
	})
	-- 5. the wish
	ctx:shot(T_BLOW - 0.2, T_TRICK, {
		eye = { ctx:R(5, 262, -345), ctx:R(4, 258, -335) },
		look = { ctx:R(4, 190, -215), ctx:R(4, 188, -215) },
		fov = { 44, 42 },
	})
	-- 6. the jester's trick shot
	ctx:shot(T_TRICK, T_BONK + 0.1, {
		eye = { ctx:R(-60, 330, -150), ctx:R(-54, 328, -156) },
		look = { ctx:R(165, 250, -370), ctx:R(140, 262, -390) },
		fov = { 62, 60 },
	})
	-- 7. the crown flies (side on, over the Queen's side of the table)
	ctx:shot(T_BONK + 0.1, T_GP, {
		eye = { ctx:R(-255, 370, -330), ctx:R(-250, 366, -334) },
		look = { ctx:R(94, 285, -370), ctx:R(94, 275, -300) },
		fov = { 54, 52 },
	})
	-- 8. Grandpa, crowned
	ctx:shot(T_GP, T_KING, {
		eye = { ctx:R(-55, 292, -300), ctx:R(-48, 288, -298) },
		look = { ctx:R(94, 255, -280), ctx:R(94, 255, -280) },
		fov = { 46, 44 },
	})
	-- 9. the King laughs it off
	ctx:shot(T_KING, T_DAD, {
		eye = { ctx:R(-45, 300, -300), ctx:R(-40, 296, -310) },
		look = { ctx:R(94, 240, -414), ctx:R(94, 240, -414) },
		fov = { 50, 48 },
	})
	-- 10. Dad volunteers, and takes the plates round behind the birthday boy
	ctx:shot(T_DAD, T_DAD + 2.2, {
		eye = { ctx:R(150, 330, -430), ctx:R(146, 328, -424) },
		look = Kit.follow(dad, "Head", V(0, -30, 0)),
		fov = { 40, 40 },
	})
	ctx:shot(T_DAD + 2.2, beats.Arrive - 0.9, {
		eye = { ctx:R(-255, 265, -235), ctx:R(-250, 262, -228) },
		look = Kit.follow(dad, "Torso", V(0, 10, 0)),
		fov = { 54, 54 },
	})
	return ctx
end

----------------------------------------------------------------------------------------------------

local BUILDS = { familyDinner, pizzaParty, royalBanquet }

-- The cutscene for a level: a ctx (see CutsceneKit) with Title / Subtitle / Lines / HideFurn.
function Story.Build(level: number, origin: CFrame, parent: Instance): any
	local build = BUILDS[level] or BUILDS[1]
	return build(origin, parent)
end

function Story.Count(): number
	return #Story.Chapters
end

return Story
