--[[
	CutsceneCastle - the Castle level's story, one chapter per run (see CutsceneKit).

	  1. The Royal Feast: the great hall. The king raises a toast, the jester's juggling goes wrong,
	     and the king's crown ends up on the jester's head. The servant loads the golden dishwasher.
	  2. The Garden Tea Party: the queen's garden. The jester (still wearing the crown) balances a
	     tower of teacups; it topples, and the queen catches every one on a tray.
	  3. The Midnight Snack: the castle kitchen at night. The king and the jester both sneak in for
	     cake, bump into each other, and the queen makes them do the washing up.
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

local GOLD = rgb(236, 192, 80)
local STONE = rgb(150, 144, 136)

-- The king without his crown (it's a prop in these chapters, so it can go flying).
LOOKS.KingBare = table.clone(LOOKS.King)
LOOKS.KingBare.Build = function(a)
	R.hairShort(rgb(235, 235, 235))(a)
	R.beard(a, rgb(240, 240, 240))
	R.belt(a, rgb(230, 190, 90), rgb(255, 230, 120))
	a:piece("Torso", Vector3.new(2.2, 2.6, 0.14), CFrame.new(0, -0.35, 0.58), rgb(170, 30, 44), Enum.Material.Fabric)
	a:piece("Torso", Vector3.new(2.3, 0.36, 1.2), CFrame.new(0, 0.92, 0.04), rgb(248, 248, 244), Enum.Material.Fabric)
	for i = 0, 3 do
		a:piece("Torso", Vector3.new(0.1, 0.16, 0.04), CFrame.new(-0.9 + i * 0.6, 0.9, -0.57), rgb(34, 34, 40))
	end
	a:piece("Torso", Vector3.new(0.12, 1.7, 0.06), CFrame.new(0, -0.05, -0.53), rgb(230, 190, 90), Enum.Material.Metal)
end

PROPS.Crown = function()
	local t = { { V(10, 64, 64), C(0, 0, 0) * CFrame.Angles(0, 0, PI / 2), GOLD, Enum.Material.Metal, "Cylinder" } }
	for i = 0, 5 do
		local a = i / 6 * PI * 2
		table.insert(t, { V(11, 18, 11), C(math.cos(a) * 28, 13, math.sin(a) * 28) * CFrame.Angles(0, -a, 0), GOLD, Enum.Material.Metal })
		table.insert(t, { V(8, 8, 8), C(math.cos(a) * 28, 24, math.sin(a) * 28), GOLD, Enum.Material.Metal, "Ball" })
	end
	table.insert(t, { V(12, 12, 4), C(0, 2, -33), rgb(220, 40, 60), Enum.Material.Neon })
	return t
end
PROPS.GoldStack = function()
	local t = {}
	for i = 0, 3 do
		table.insert(t, disc(54, 2.4, 1.2 + i * 3.4, GOLD, Enum.Material.Metal))
		table.insert(t, { V(16, 1.4, 12), C(-8 + i * 5, 2.8 + i * 3.4, 5 - i * 3), rgb(120, 70, 40), nil, "Sphere" })
	end
	return t
end
PROPS.GoldPlate = function()
	return { disc(54, 2.4, 1.2, GOLD, Enum.Material.Metal), disc(40, 2.6, 1.4, rgb(250, 220, 130), Enum.Material.Metal) }
end

-- A long hanging banner.
local function banner(ctx: any, x: number, h: number, z: number, color: Color3)
	ctx:box("Banner", V(90, 300, 4), ctx:at(x, h, z - 10), color, Enum.Material.Fabric)
	ctx:box("BannerTrim", V(96, 14, 5), ctx:at(x, h + 150, z - 10), GOLD, Enum.Material.Metal)
	ctx:box("BannerTip", V(64, 64, 4), ctx:at(x, h - 150, z - 10) * CFrame.Angles(0, 0, PI / 4), color, Enum.Material.Fabric)
	ctx:box("BannerCrest", V(40, 40, 5), ctx:at(x, h + 30, z - 12) * CFrame.Angles(0, 0, PI / 4), GOLD, Enum.Material.Metal)
end

-- A tall arched window (daylight) on a wall facing the camera.
local function archWindow(ctx: any, x: number, h: number, z: number)
	ctx:box("WinSky", V(110, 240, 2), ctx:at(x, h, z - 9), rgb(170, 214, 250), Enum.Material.Neon)
	ctx:box("WinArch", V(2, 110, 110), ctx:at(x, h + 120, z - 9) * CFrame.Angles(0, PI / 2, 0), rgb(170, 214, 250), Enum.Material.Neon, "Cylinder")
	ctx:box("WinBar", V(6, 300, 4), ctx:at(x, h + 20, z - 11), rgb(60, 60, 66), Enum.Material.Metal)
	ctx:box("WinBar", V(110, 6, 4), ctx:at(x, h + 30, z - 11), rgb(60, 60, 66), Enum.Material.Metal)
	ctx:box("WinSill", V(140, 16, 30), ctx:at(x, h - 128, z - 14), STONE, Enum.Material.Slate)
end

-- A hearth with a crackling fire. Returns the fire part.
local function hearth(ctx: any, x: number, z: number): BasePart
	ctx:box("Hearth", V(300, 280, 70), ctx:at(x, 140, z - 35), rgb(120, 116, 110), Enum.Material.Cobblestone)
	ctx:box("HearthMouth", V(190, 150, 20), ctx:at(x, 85, z - 62), rgb(30, 24, 22))
	ctx:box("Mantel", V(340, 22, 90), ctx:at(x, 290, z - 45), rgb(100, 70, 44), Enum.Material.Wood)
	local fire = ctx:box("Fire", V(120, 60, 10), ctx:at(x, 40, z - 60), rgb(255, 130, 40), Enum.Material.Neon)
	fire.CastShadow = false
	local l = Instance.new("PointLight")
	l.Color = rgb(255, 150, 70)
	l.Range = 60
	l.Brightness = 2
	l.Parent = fire
	for i = -1, 1 do
		ctx:box("Log", V(90, 16, 16), ctx:at(x + i * 30, 12, z - 58) * CFrame.Angles(0, 0.3 * i, 0), rgb(90, 60, 40), Enum.Material.Wood)
	end
	ctx:onUpdate(function(t)
		local f = 0.8 + 0.2 * math.sin(t * 12) * math.sin(t * 7.1)
		fire.Size = V(120, 50 + 16 * f, 10)
		l.Brightness = 1.7 + f
	end)
	return fire
end

-- A candle chandelier hanging over (x, z).
local function chandelier(ctx: any, x: number, h: number, z: number)
	ctx:box("ChainC", V(4, 200, 4), ctx:at(x, h + 100, z), rgb(60, 60, 66), Enum.Material.Metal)
	ctx:box("Ring", V(8, 180, 180), ctx:at(x, h, z) * CFrame.Angles(0, 0, PI / 2), rgb(90, 70, 50), Enum.Material.Metal, "Cylinder")
	for i = 0, 7 do
		local a = i / 8 * PI * 2
		local cx, cz = x + math.cos(a) * 80, z + math.sin(a) * 80
		ctx:post("Candle", 7, 22, cx, h + 4, cz, rgb(250, 246, 230))
		local f = ctx:box("Flame", V(5, 9, 5), ctx:at(cx, h + 32, cz), rgb(255, 200, 90), Enum.Material.Neon, "Sphere")
		f.CastShadow = false
	end
	ctx:light(x, h + 20, z, rgb(255, 210, 140), 60, 1.2, 4)
end

----------------------------------------------------------------------------------------------------
-- Chapter 1: The Royal Feast
----------------------------------------------------------------------------------------------------

local function royalFeast(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 30)
	Kit.title(ctx, 1, "The Royal Feast")
	ctx:mood({ ClockTime = 13, Brightness = 1.8, ExposureCompensation = 0.05, Ambient = rgb(150, 140, 132), OutdoorAmbient = rgb(130, 120, 116) })
	local scene = ctx.Scene

	-- The great hall.
	local ZW = 720
	Kit.room(ctx, {
		X0 = -780, X1 = 780, Z0 = -800, Z1 = ZW, H = 820,
		Floor = rgb(120, 116, 110), FloorMat = Enum.Material.Slate,
		Wall = STONE, WallMat = Enum.Material.Cobblestone, Trim = rgb(110, 100, 90),
	})
	Kit.ceiling(ctx, -780, 780, -800, ZW, 820, rgb(90, 64, 44), Enum.Material.Wood)
	for i = -3, 3 do
		ctx:box("Beam", V(1560, 30, 40), ctx:at(0, 800, 100 + i * 200), rgb(80, 56, 38), Enum.Material.Wood)
	end
	ctx:box("Carpet", V(260, 2, 1400), ctx:at(0, 1, -40), rgb(150, 26, 40), Enum.Material.Fabric)
	ctx:box("CarpetTrim", V(280, 1.6, 1400), ctx:at(0, 0.8, -40), GOLD, Enum.Material.Fabric)
	archWindow(ctx, -300, 420, ZW)
	archWindow(ctx, 300, 420, ZW)
	for _, bx in { -560, -40, 40 } do
		banner(ctx, bx, 520, ZW, rgb(150, 26, 40))
	end
	banner(ctx, 560, 520, ZW, rgb(40, 60, 150))
	hearth(ctx, -560, ZW)
	chandelier(ctx, 0, 560, 330)
	for _, px in { -700, 700 } do
		ctx:box("Pillar", V(80, 820, 80), ctx:at(px, 410, 420), rgb(170, 164, 156), Enum.Material.Marble)
	end

	-- The feast table and the thrones.
	Kit.table(ctx, 0, 330, 700, 170, TABLE, rgb(92, 58, 38), rgb(245, 238, 225))
	local kingSeat = Kit.chair(ctx, "Throne", 0, 460, PI, "FurnThrone")
	local queenSeat = Kit.chair(ctx, "QueenChair", -210, 460, PI, "FurnHighChair")
	local nobleSeat = Kit.chair(ctx, "NobleChair", 220, 460, PI, "FurnHighChair")
	scene:prop("Roast", "Roast")
	scene:place("Roast", 0, 1e5 - 1, ctx:at(-60, TABLE + 1, 330))
	for i, px in { -210, 0, 220 } do
		scene:prop("Plate" .. i, "GoldPlate")
		scene:place("Plate" .. i, 0, 1e5 - 1, ctx:at(px, TABLE + 1, 385))
		scene:prop("Cup" .. i, "Goblet")
		scene:place("Cup" .. i, 0, 1e5 - 1, ctx:at(px + 50, TABLE + 1, 380))
	end
	scene:prop("Stack", "GoldStack")
	scene:place("Stack", 0, 1e5 - 1, ctx:at(300, TABLE + 1, 310)) -- trimmed at pick-up
	for _, fx in { -260, 180 } do
		ctx:box("Fruit", V(60, 8, 60), ctx:at(fx, TABLE + 4, 320) * CFrame.Angles(0, 0, PI / 2), GOLD, Enum.Material.Metal, "Cylinder")
		for k = 0, 4 do
			ctx:box("Apple", V(16, 16, 16), ctx:at(fx - 16 + (k % 3) * 16, TABLE + 16 + (k // 3) * 12, 320 + (k % 2) * 8), if k % 2 == 0 then rgb(200, 40, 40) else rgb(120, 190, 60), nil, "Ball")
		end
	end
	-- the royal (golden) dishwasher in the scullery corner on the right
	local ZF = 560
	Kit.counter(ctx, 240, 780, ZF, { Gaps = { { 335, 465 } }, Body = rgb(120, 84, 56), BodyMat = Enum.Material.Wood, Door = rgb(134, 94, 62), Top = rgb(170, 164, 156), TopMat = Enum.Material.Slate, Splash = STONE, SplashMat = Enum.Material.Cobblestone })
	local dw = Kit.dishwasher(ctx, 400, ZF, 0, { Steel = GOLD, Mess = rgb(120, 70, 40) })

	-- The king (the crown is a prop today), the queen and a noble.
	local king = scene:actor("King", "KingBare")
	local pk = R.newPlan(king, 0, 0, 0)
	R.seated(pk, kingSeat)
	scene:prop("Crown", "Crown")
	scene:prop("KingLeg", "TurkeyLeg")
	local crowned = { Crown = { "Head", off = CFrame.new(0, 40, 0) } }
	local function withCrown(h: { [string]: any }?): { [string]: any }
		local t = table.clone(h or {})
		t.Crown = crowned.Crown
		return t
	end
	local leg = { KingLeg = { "R", off = CFrame.new(0, 4, -4) * CFrame.Angles(-0.6, 0, 0) } }
	pk:still(3.2, P.bite, withCrown(leg))
	local TOAST = pk.T
	-- the toast: turkey leg held high
	pk:still(3.0, function(u, c)
		local s = c.Actor.S
		local k = smooth(math.min(u / 0.6, 1))
		return {
			bob = R.breathe(u),
			lean = -0.05 * k,
			head = { pitch = 0.25 * k, yaw = math.sin(u * 2) * 0.1 },
			armL = { at = local3(c, -0.6 * s, TABLE + 24, 1.2 * s) },
			armR = { p = 2.6 * k, r = 0.2, e = 0.3 },
		}
	end, withCrown(leg))
	local HIT = TOAST + 3.0
	pk:still(1.4, P.startle, leg)
	-- a royal frown... then he laughs too
	pk:still(1.4, function(u, c)
		local p = P.rest(u, c)
		p.head = { yaw = math.sin(u * 7) * 0.3, pitch = -0.1 }
		return p
	end, leg)
	pk:still(4, P.laugh, leg)
	pk:finish(40, P.bite)
	pk.Steps[#pk.Steps].Hold = leg
	table.insert(scene.Plans, pk)

	local queen = scene:actor("Queen", "Queen")
	local pq = R.newPlan(queen, 0, 0, 0)
	R.seated(pq, queenSeat)
	pq:still(HIT, P.talkTo(0.7))
	pq:still(0.8, P.startle)
	pq:still(5, P.laugh)
	pq:finish(40, P.clap)
	table.insert(scene.Plans, pq)
	local noble = scene:actor("Noble", "Noble1")
	local pn = R.newPlan(noble, 0, 0, 0)
	R.seated(pn, nobleSeat)
	scene:prop("NobleFork", "Fork")
	pn:still(HIT, P.eat, { NobleFork = R.FORK_HOLD })
	pn:still(0.8, P.startle)
	pn:still(4, P.laugh)
	pn:finish(40, P.clap)
	table.insert(scene.Plans, pn)

	-- The jester juggling in front of the table.
	local jester = scene:actor("Jester", "Jester")
	local JX, JZ = -430, 150
	local toKing = math.atan2(0 - JX, 460 - JZ)
	local pj = R.newPlan(jester, JX, JZ, toKing)
	local ballColors = { rgb(255, 80, 80), rgb(80, 180, 255), rgb(255, 220, 60) }
	local balls = {}
	for i, col in ballColors do
		local b = ctx:box("JuggleBall", V(18, 18, 18), CFrame.new(), col, nil, "Ball")
		b.CastShadow = false
		balls[i] = b
	end
	local function juggle(u: number, c: any): any
		local s = c.Actor.S
		local l = math.sin(u * 1.8 * PI * 2)
		return {
			bob = math.abs(math.sin(u * 4)) * 0.03,
			head = { pitch = 0.3 + math.sin(u * 3.6 * PI) * 0.1 },
			armL = { at = local3(c, -0.45 * s, 100 + (1.7 + l * 0.15) * s, 0.85 * s) },
			armR = { at = local3(c, 0.45 * s, 100 + (1.7 - l * 0.15) * s, 0.85 * s) },
		}
	end
	local THROW = HIT - 0.9
	pj:still(THROW, juggle)
	-- the wild throw
	pj:still(0.9, function(u, c)
		local s = c.Actor.S
		local k = u / 0.9
		return { lean = -0.1 * k, head = { pitch = 0.5 }, armR = { p = 2.4 * smooth(k * 2), r = 0.2, e = 0.2 }, armL = { at = local3(c, -0.45 * s, 185, 0.85 * s) } }
	end)
	local CROWN_LAND = HIT + 1.2
	pj:still(CROWN_LAND - pj.T, function(u, c)
		local p = P.startle(u, c)
		p.head = { pitch = 0.6 }
		return p
	end)
	-- the jester, now crowned, takes a deep bow
	local jCrown = { Crown = { "Head", off = CFrame.new(0, 58, 0) * CFrame.Angles(0, 0, 0.15) } }
	pj:still(2.2, function(u, c)
		local k = math.sin(math.clamp(u / 2.2, 0, 1) * PI)
		return { lean = 0.45 * k, head = { pitch = -0.3 * k }, armL = { p = -0.3 * k, r = 0.35 * k, e = 0.2 }, armR = { p = 0.5 * k, r = -0.1, e = 1.8 * k } }
	end, jCrown)
	pj:still(3, function(u, c)
		local p = P.laugh(u, c)
		return p
	end, jCrown)
	pj:finish(40, juggle)
	pj.Steps[#pj.Steps].Hold = jCrown
	table.insert(scene.Plans, pj)
	-- the balls: juggled in the jester's hands until one goes flying at the king
	local function handPos(i: number, t: number): Vector3
		local b = jester.Bones
		if not b then
			return ctx:R(JX, 200, JZ)
		end
		local ph = (t * 1.8 + (i - 1) / 3) % 1
		local l, r = b.GripL.Position, b.GripR.Position
		local from, to = if ph < 0.5 then l else r, if ph < 0.5 then r else l
		local k = (ph % 0.5) * 2
		return from:Lerp(to, k) + Vector3.new(0, 20 + math.sin(k * PI) * 90, 0)
	end
	local crownTop = function()
		local b = king.Bones
		return if b then (b.Head * CFrame.new(0, 44, 0)).Position else ctx:R(0, 300, 460)
	end
	ctx:onUpdate(function(t)
		for i, b in balls do
			if i == 2 and t >= THROW + 0.3 then
				if t < HIT then
					local k = (t - THROW - 0.3) / (HIT - THROW - 0.3)
					local from = handPos(2, THROW + 0.3)
					b.CFrame = CFrame.new(from:Lerp(crownTop(), k) + Vector3.new(0, 4 * 160 * k * (1 - k), 0))
				elseif t < HIT + 1.2 then
					local k = (t - HIT) / 1.2
					local from = crownTop()
					local to = ctx:R(160, 9, 200)
					b.CFrame = CFrame.new(from:Lerp(to, k) + Vector3.new(0, 4 * 80 * k * (1 - k) - 0, 0))
				else
					b.CFrame = CFrame.new(ctx:R(160, 9, 200))
				end
			elseif t < THROW + 0.3 or i ~= 2 then
				if t >= THROW and t < CROWN_LAND + 5.2 then
					-- the other two fall to the floor while he gapes
					local k = math.clamp((t - THROW) / 0.8, 0, 1)
					local from = handPos(i, THROW)
					local to = ctx:R(JX + (i - 2) * 50, 9, JZ + 60)
					b.CFrame = CFrame.new(from:Lerp(to, smooth(k)) + Vector3.new(0, 30 * math.sin(k * PI), 0))
				elseif t >= CROWN_LAND + 5.2 then
					b.CFrame = CFrame.new(handPos(i, t))
				else
					b.CFrame = CFrame.new(handPos(i, t))
				end
			end
		end
	end)
	-- the crown flies from the king's head to the jester's
	local flyCrown = ctx:box("FlyCrown", V(10, 64, 64), CFrame.new(), GOLD, Enum.Material.Metal, "Cylinder")
	Kit.flight(ctx, flyCrown, HIT, CROWN_LAND, crownTop, function()
		local b = jester.Bones
		return if b then (b.Head * CFrame.new(0, 58, 0)).Position else ctx:R(JX, 300, JZ)
	end, 170, 1.5)

	-- The servant clears the golden plates into the golden dishwasher.
	local servant = scene:actor("Servant", "Servant")
	local ps = R.newPlan(servant, 440, 300, -PI / 2)
	ps:still(HIT + 0.2, P.idle)
	ps:still(3.2, P.laugh)
	ps:turn(-PI / 2)
	local PICK = ps.T
	ps:swap(1.0, P.reach(-0.25 * S, TABLE + 12, 1.6 * S, 0.25 * S, TABLE + 12, 1.6 * S, 1.0, 0.35), nil, { Stack = { "both", off = CFrame.new(0, -4, -10) } })
	scene.Placements.Stack[1][2] = PICK + 0.5
	local carry = { Stack = { "both", off = CFrame.new(0, -4, -10) } }
	ps:walk({ V2(440, 460), V2(305, ZF - 72) }, carry, P.carry, 150)
	ps:turn(0, carry, P.carry)
	local beats = Kit.loadDishwasher(ctx, ps, dw, "Stack")
	ps:still(3, P.idle)
	ps:finish(40, P.idle)
	table.insert(scene.Plans, ps)

	-- Camera.
	ctx:shot(0, TOAST, { eye = { ctx:R(-40, 560, -560), ctx:R(20, 480, -460) }, look = { ctx:R(0, 200, 420), ctx:R(0, 210, 420) }, fov = { 56, 52 } })
	ctx:shot(TOAST, THROW, { eye = { ctx:R(70, 280, 180), ctx:R(60, 276, 200) }, look = Kit.follow(king, "Head", Vector3.new(0, 20, 0)), fov = { 38, 34 } })
	ctx:shot(THROW, HIT + 0.1, { eye = { ctx:R(-600, 300, 30), ctx:R(-580, 305, 40) }, look = function(t)
		return balls[2].Position
	end, fov = { 50, 50 }, ease = "linear" })
	ctx:shot(HIT + 0.1, CROWN_LAND + 0.3, { eye = { ctx:R(-120, 330, 60), ctx:R(-140, 330, 60) }, look = function()
		return flyCrown.Position
	end, fov = { 52, 52 }, ease = "linear" })
	ctx:shot(CROWN_LAND + 0.3, CROWN_LAND + 2.6, { eye = { ctx:R(-230, 250, 20), ctx:R(-240, 248, 35) }, look = Kit.follow(jester, "Head", Vector3.new(0, 20, 0)), fov = { 40, 36 } })
	ctx:shot(CROWN_LAND + 2.6, PICK, { eye = { ctx:R(-40, 270, 170), ctx:R(-50, 268, 185) }, look = { ctx:R(-100, 240, 460), ctx:R(-100, 240, 460) }, fov = { 42, 40 } })
	ctx:shot(PICK, beats.Open - 0.6, { eye = { ctx:R(120, 400, -160), ctx:R(160, 380, -100) }, look = Kit.follow(servant, "Torso"), fov = { 48, 44 }, ease = "linear" })
	Kit.endingShots(ctx, dw, beats, 1)
	return ctx
end

----------------------------------------------------------------------------------------------------
-- Chapter 2: The Garden Tea Party
----------------------------------------------------------------------------------------------------

PROPS.SconeStack = function()
	local t = {}
	for i = 0, 3 do
		table.insert(t, disc(50, 2.4, 1.2 + i * 3.4, rgb(250, 250, 248)))
		table.insert(t, { V(14, 3, 10), C(-6 + i * 4, 3.2 + i * 3.4, 4 - i * 3), rgb(250, 240, 220), nil, "Sphere" })
		table.insert(t, { V(8, 3, 8), C(8 - i * 3, 3.4 + i * 3.4, -5), rgb(200, 40, 70), nil, "Sphere" })
	end
	return t
end
PROPS.CakeStand = function()
	local t = {}
	for i = 0, 2 do
		table.insert(t, disc(70 - i * 16, 2, 4 + i * 34, rgb(250, 250, 248)))
		for k = 0, 4 - i do
			local a = k / (5 - i) * PI * 2
			table.insert(t, { V(14, 10, 14), C(math.cos(a) * (22 - i * 6), 10 + i * 34, math.sin(a) * (22 - i * 6)), ({ rgb(255, 190, 210), rgb(250, 230, 180), rgb(190, 230, 180) })[(k + i) % 3 + 1], nil, "Sphere" })
		end
	end
	table.insert(t, { V(4, 80, 4), C(0, 40, 0), GOLD, Enum.Material.Metal })
	return t
end

-- A clipped box hedge running from (x0, z0) to (x1, z1).
local function hedge(ctx: any, x0: number, z0: number, x1: number, z1: number, h: number)
	local dx, dz = x1 - x0, z1 - z0
	local len = math.sqrt(dx * dx + dz * dz)
	ctx:box("Hedge", V(len, h, 70), ctx:at((x0 + x1) / 2, h / 2, (z0 + z1) / 2, math.atan2(dx, dz) - PI / 2), rgb(60, 130, 60), Enum.Material.Grass)
end

local function gardenTea(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 30)
	Kit.title(ctx, 2, "The Garden Tea Party")
	ctx:mood({ ClockTime = 15.5, Brightness = 2.6, ExposureCompensation = -0.1, Ambient = rgb(120, 120, 110), OutdoorAmbient = rgb(150, 150, 140) })
	local scene = ctx.Scene

	-- The queen's garden.
	Kit.grass(ctx, -1500, 1500, -1300, 1300, rgb(100, 172, 84))
	ctx:box("Gravel", V(900, 2, 900), ctx:at(0, 0.6, 250), rgb(222, 212, 190), Enum.Material.Pebble)
	hedge(ctx, -700, 750, 700, 750, 160)
	hedge(ctx, -700, 750, -700, -150, 160)
	hedge(ctx, 800, 750, 800, 200, 160)
	-- the castle wall and a tower behind the hedges
	ctx:box("CastleWall", V(2200, 600, 60), ctx:at(0, 300, 1050), STONE, Enum.Material.Cobblestone)
	for i = -5, 5 do
		ctx:box("Merlon", V(80, 70, 60), ctx:at(i * 200, 635, 1050), STONE, Enum.Material.Cobblestone)
	end
	ctx:post("Tower", 340, 900, -700, 0, 1080, STONE, Enum.Material.Cobblestone)
	ctx:box("TowerRoof", V(400, 300, 400), ctx:at(-700, 1050, 1080), rgb(60, 70, 130), nil, "Sphere")
	ctx:box("Flag", V(4, 80, 110), ctx:at(-700, 1260, 1080) * CFrame.Angles(0, PI / 2, 0), rgb(150, 26, 40), Enum.Material.Fabric)
	-- the fountain
	ctx:post("FountainBase", 300, 50, -480, 0, 520, rgb(220, 214, 204), Enum.Material.Marble)
	ctx:post("FountainWater", 270, 4, -480, 50, 520, rgb(120, 190, 240), Enum.Material.Glass)
	ctx:post("FountainStem", 50, 160, -480, 50, 520, rgb(220, 214, 204), Enum.Material.Marble)
	ctx:post("FountainBowl", 140, 20, -480, 200, 520, rgb(220, 214, 204), Enum.Material.Marble)
	local spray = ctx:box("Spray", V(12, 12, 12), ctx:at(-480, 230, 520), rgb(200, 230, 255), nil, "Ball", 1)
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(rgb(210, 240, 255))
	e.Size = NumberSequence.new(8, 2)
	e.Transparency = NumberSequence.new(0.2, 1)
	e.Lifetime = NumberRange.new(0.8, 1.2)
	e.Rate = 40
	e.Speed = NumberRange.new(60, 90)
	e.SpreadAngle = Vector2.new(20, 20)
	e.Acceleration = Vector3.new(0, -120, 0)
	e.EmissionDirection = Enum.NormalId.Top
	e.Parent = spray
	-- roses and topiary
	for i, b in { { 520, 420 }, { 620, 600 }, { -640, 150 }, { 300, 680 } } do
		Kit.bush(ctx, b[1], b[2], 0.9)
		for k = 0, 5 do
			ctx:box("Rose", V(14, 14, 14), ctx:at(b[1] - 40 + k * 18, 60 + (k % 2) * 16, b[2] - 30 + (k % 3) * 10), if i % 2 == 0 then rgb(220, 40, 70) else rgb(255, 170, 200), nil, "Ball")
		end
	end
	for _, tx in { -250, 250 } do
		ctx:post("TopiaryPot", 70, 60, tx, 0, 700, rgb(200, 110, 70))
		ctx:box("Topiary", V(110, 110, 110), ctx:at(tx, 120, 700), rgb(60, 140, 60), Enum.Material.Grass, "Ball")
		ctx:box("Topiary", V(70, 70, 70), ctx:at(tx, 200, 700), rgb(60, 140, 60), Enum.Material.Grass, "Ball")
	end
	-- the white serving pavilion on the right, with its dishwasher
	local ZF = 520
	local top = Kit.counter(ctx, 330, 760, ZF, { Gaps = { { 455, 585 } }, Body = rgb(250, 250, 246), Door = rgb(240, 240, 236), Top = rgb(220, 214, 204), TopMat = Enum.Material.Marble, Splash = rgb(250, 250, 246) })
	local dw = Kit.dishwasher(ctx, 520, ZF, 0, { Mess = rgb(250, 240, 220) })
	for _, px in { 340, 750 } do
		ctx:post("PavilionPost", 22, 420, px, 0, ZF + 40, rgb(250, 250, 246))
	end
	for i = 0, 7 do
		ctx:box("PavilionRoof", V(60, 8, 220), ctx:at(365 + i * 55, 430, ZF + 70) * CFrame.Angles(0.25, 0, 0), if i % 2 == 0 then rgb(120, 170, 220) else rgb(250, 250, 246))
	end
	Kit.sink(ctx, 690, ZF, top)

	-- The tea table.
	Kit.table(ctx, 0, 330, 380, 150, TABLE, rgb(250, 250, 246), rgb(250, 244, 250), Enum.Material.SmoothPlastic)
	scene:prop("Stand", "CakeStand")
	scene:place("Stand", 0, 1e5 - 1, ctx:at(-40, TABLE + 1, 330))
	scene:prop("Teapot", "TeaCup")
	scene:place("Teapot", 0, 1e5 - 1, ctx:at(80, TABLE + 1, 320))
	scene:prop("Stack", "SconeStack")
	scene:place("Stack", 0, 1e5 - 1, ctx:at(150, TABLE + 1, 300))
	local kingSeat = Kit.chair(ctx, "KingChair", 0, 450, PI, "FurnThrone")
	local nobleSeat = Kit.chair(ctx, "NobleChair", 170, 440, PI, "FurnHighChair")
	scene:prop("Cup1", "TeaCup")
	scene:place("Cup1", 0, 1e5 - 1, ctx:at(0, TABLE + 1, 385))
	scene:prop("Cup2", "TeaCup")
	scene:place("Cup2", 0, 1e5 - 1, ctx:at(170, TABLE + 1, 385))

	-- The king (still no crown) and a noble at the table.
	local king = scene:actor("King", "KingBare")
	local pk = R.newPlan(king, 0, 0, 0)
	R.seated(pk, kingSeat)
	local sip = { Cup1 = { "R", off = CFrame.new(0, -5, 0) } }
	local noble = scene:actor("Noble", "Noble2")
	local pn = R.newPlan(noble, 0, 0, 0)
	R.seated(pn, nobleSeat)

	-- The jester walks on with the crown... and a tower of teacups on top of it.
	local jester = scene:actor("Jester", "Jester")
	scene:prop("JCrown", "Crown")
	local crowned = { JCrown = { "Head", off = CFrame.new(0, 58, 0) * CFrame.Angles(0, 0, 0.15) } }
	local pj = R.newPlan(jester, -620, 60, PI / 2)
	local function balance(u: number, c: any): any
		local sway = math.sin(u * 2.4) * 0.12
		return {
			tilt = sway * 0.4,
			head = { roll = sway, pitch = 0.15 },
			armL = { p = 0.1, r = 1.35 + sway, e = 0.1 },
			armR = { p = 0.1, r = 1.35 - sway, e = 0.1 },
		}
	end
	pj:walk({ V2(-250, 130) }, crowned, balance, 90)
	pj:turn(PI / 2 + 0.2, crowned, balance)
	local WOBBLE = pj.T
	pj:still(1.6, function(u, c)
		local p = balance(u * 2.5, c)
		p.bob = math.abs(math.sin(u * 7)) * 0.03
		return p
	end, crowned)
	local TOPPLE = pj.T
	pj:still(1.3, P.startle, crowned)
	-- he sits down with a bump, then applauds the queen
	pj:still(2.5, function(u, c)
		local k = smooth(u / 0.4)
		return { sit = k, seat = 10, lean = -0.1, legs = { hipL = PI / 2 - 0.3, hipR = PI / 2 - 0.3, kneeL = -0.2, kneeR = -0.2 }, head = { pitch = 0.2, yaw = 0.3 }, armL = { p = 0.4, r = 0.6, e = 0.3 }, armR = { p = 0.4, r = 0.6, e = 0.3 } }
	end, crowned)
	pj:finish(40, function(u, c)
		local s = c.Actor.S
		local k = math.abs(math.sin(u * 7))
		return { sit = 1, seat = 10, legs = { hipL = PI / 2 - 0.3, hipR = PI / 2 - 0.3, kneeL = -0.2, kneeR = -0.2 }, head = { pitch = 0.2 }, armL = { at = local3(c, -0.12 * s - k * 0.3 * s, 170, 1.0 * s) }, armR = { at = local3(c, 0.12 * s + k * 0.3 * s, 170, 1.0 * s) } }
	end)
	pj.Steps[#pj.Steps].Hold = crowned
	table.insert(scene.Plans, pj)

	-- The queen, ready with a tray.
	local queen = scene:actor("Queen", "Queen")
	local pq = R.newPlan(queen, -40, 175, PI)
	scene:prop("QTray", "Tray")
	local trayHold = { QTray = { "both", off = CFrame.new(0, -4, -14) } }
	local function hostess(u: number, c: any): any
		local p = P.carry(u, c)
		p.head = { yaw = math.sin(u * 0.6) * 0.3, pitch = 0 }
		return p
	end
	pq:still(WOBBLE, hostess, trayHold)
	pq:turn(-PI / 2 - 0.3, trayHold, P.carry)
	pq:still(TOPPLE - pq.T, hostess, trayHold)
	-- darting left and right to catch every cup
	local CATCH = pq.T
	pq:add(1.4, function(u)
		return -40 - math.sin(u / 1.4 * PI * 2) * 30, 175 + math.sin(u / 1.4 * PI) * 10, -PI / 2 - 0.3
	end, function(u, c)
		local p = P.carry(u, c)
		p.lean = 0.1
		p.head = { pitch = 0.4 }
		return p
	end, trayHold)
	pq:still(2.2, function(u, c)
		local p = P.carry(u, c)
		local k = math.sin(math.clamp(u / 2.2, 0, 1) * PI)
		p.lean = 0.25 * k -- a little curtsy
		p.bob = -0.1 * k
		return p
	end, trayHold)
	pq:turn(PI, trayHold, P.carry)
	local SET = pq.T
	pq:swap(1.1, P.reach(-0.25 * S, TABLE + 10, 1.3 * S, 0.25 * S, TABLE + 10, 1.3 * S, 1.1, 0.35), trayHold, nil)
	scene:place("QTray", SET + 0.55, 1e5 - 1, ctx:at(-40, TABLE + 1, 262))
	pq:still(3, P.laugh)
	pq:finish(40, P.idle)
	table.insert(scene.Plans, pq)

	-- the teacups: stacked on the crown, then flying one by one onto the tray
	local cups = {}
	local trayPart = function(): Vector3
		local pr = scene.Props.QTray
		return pr.Pieces[1].Part.Position
	end
	for i = 1, 6 do
		local cup = ctx:box("TowerCup", V(16, 16, 16), CFrame.new(), rgb(250, 250, 248), nil, "Cylinder")
		local band = ctx:box("TowerCupBand", V(3, 16.4, 16.4), CFrame.new(), rgb(90, 140, 220), nil, "Cylinder")
		cups[i] = { cup, band }
	end
	local slots = { V(-18, 0, -12), V(0, 0, -12), V(18, 0, -12), V(-18, 0, 12), V(0, 0, 12), V(18, 0, 12) }
	ctx:onUpdate(function(t)
		local jb = jester.Bones
		local sway = if t >= WOBBLE and t < TOPPLE then math.sin(t * 9) * 0.25 * ((t - WOBBLE) / (TOPPLE - WOBBLE)) else math.sin(t * 2.4) * 0.06
		for i, pair in cups do
			local cf
			local land = TOPPLE + 0.12 * i + 0.55
			if t < TOPPLE + 0.12 * i or not jb then
				local base = if jb then jb.Head * CFrame.new(0, 80, 0) else CFrame.new(ctx:R(-250, 330, 130))
				cf = base * CFrame.Angles(0, 0, sway * i * 0.35) * CFrame.new(0, (i - 1) * 17, 0)
			elseif t < land then
				local k = (t - TOPPLE - 0.12 * i) / 0.55
				local from = (jb.Head * CFrame.new(0, 80 + (i - 1) * 17, 0)).Position
				local to = trayPart() + slots[i] + Vector3.new(0, 9, 0)
				cf = CFrame.new(from:Lerp(to, k) + Vector3.new(0, 4 * 90 * k * (1 - k), 0)) * CFrame.Angles(k * 6, k * 3, 0)
			else
				cf = CFrame.new(trayPart() + slots[i] + Vector3.new(0, 9, 0))
			end
			pair[1].CFrame = cf * CFrame.Angles(0, 0, PI / 2)
			pair[2].CFrame = cf * CFrame.new(0, 3, 0) * CFrame.Angles(0, 0, PI / 2)
		end
	end)

	pk:still(TOPPLE, P.drink, sip)
	pk:still(1.0, P.startle, sip)
	pk:still(4, P.clap)
	pk:finish(40, P.drink)
	pk.Steps[#pk.Steps].Hold = sip
	table.insert(scene.Plans, pk)
	pn:still(TOPPLE, P.talkTo(-0.7))
	pn:still(1.0, P.startle)
	pn:still(4, P.clap)
	pn:finish(40, P.talkTo(-0.6))
	table.insert(scene.Plans, pn)

	-- The servant clears the scone plates into the pavilion's dishwasher.
	local servant = scene:actor("Servant", "Servant")
	local ps = R.newPlan(servant, 300, 250, -PI / 2)
	ps:still(TOPPLE + 1.4, P.idle)
	ps:still(2.6, P.clap)
	ps:turn(-PI / 2 - 0.2)
	local PICK = ps.T
	ps:swap(1.0, P.reach(-0.25 * S, TABLE + 12, 1.55 * S, 0.25 * S, TABLE + 12, 1.55 * S, 1.0, 0.35), nil, { Stack = { "both", off = CFrame.new(0, -4, -10) } })
	scene.Placements.Stack[1][2] = PICK + 0.5
	local carry = { Stack = { "both", off = CFrame.new(0, -4, -10) } }
	ps:walk({ V2(425, ZF - 72) }, carry, P.carry, 150)
	ps:turn(0, carry, P.carry)
	local beats = Kit.loadDishwasher(ctx, ps, dw, "Stack")
	ps:still(3, P.idle)
	ps:finish(40, P.idle)
	table.insert(scene.Plans, ps)

	-- Camera.
	ctx:shot(0, 3.4, { eye = { ctx:R(640, 520, -640), ctx:R(500, 430, -500) }, look = { ctx:R(-60, 150, 330), ctx:R(-80, 160, 330) }, fov = { 54, 50 } })
	ctx:shot(3.4, WOBBLE, { eye = { ctx:R(-330, 290, -200), ctx:R(-260, 290, -170) }, look = Kit.follow(jester, "Head", Vector3.new(0, 80, 0)), fov = { 44, 42 }, ease = "linear" })
	ctx:shot(WOBBLE, TOPPLE + 0.1, { eye = { ctx:R(-120, 300, 10), ctx:R(-125, 305, 20) }, look = Kit.follow(jester, "Head", Vector3.new(0, 90, 0)), fov = { 42, 40 } })
	ctx:shot(TOPPLE + 0.1, CATCH + 1.6, { eye = { ctx:R(-150, 330, -260), ctx:R(-140, 320, -230) }, look = { ctx:R(-140, 240, 150), ctx:R(-130, 230, 150) }, fov = { 50, 48 } })
	ctx:shot(CATCH + 1.6, SET, { eye = { ctx:R(-270, 280, -90), ctx:R(-255, 275, -70) }, look = Kit.follow(queen, "Head", Vector3.new(0, -40, 0)), fov = { 42, 40 } })
	ctx:shot(SET, PICK, { eye = { ctx:R(80, 290, 140), ctx:R(70, 285, 160) }, look = { ctx:R(60, 220, 440), ctx:R(60, 220, 440) }, fov = { 44, 42 } })
	ctx:shot(PICK, beats.Open - 0.6, { eye = { ctx:R(80, 400, -150), ctx:R(160, 380, -100) }, look = Kit.follow(servant, "Torso"), fov = { 48, 44 }, ease = "linear" })
	Kit.endingShots(ctx, dw, beats, 1)
	return ctx
end

----------------------------------------------------------------------------------------------------
-- Chapter 3: The Midnight Snack
----------------------------------------------------------------------------------------------------

LOOKS.KingNight = {
	Shirt = rgb(236, 236, 250), Pants = rgb(226, 226, 244), ShirtMat = Enum.Material.Fabric, PantsMat = Enum.Material.Fabric, Shoes = rgb(150, 30, 44),
	Build = function(a)
		R.hairShort(rgb(235, 235, 235))(a)
		R.beard(a, rgb(240, 240, 240))
		-- the nightcap
		for i = 0, 3 do
			local r = 0.7 - i * 0.14
			a:piece("Head", Vector3.new(0.3, r * 2, r * 2), CFrame.new(0.05 * i, 0.62 + i * 0.26, 0.05 * i) * CFrame.Angles(0, 0, PI / 2 + 0.15 * i), rgb(90, 110, 200), Enum.Material.Fabric, "Cylinder")
		end
		a:piece("Head", Vector3.new(0.3, 0.3, 0.3), CFrame.new(0.3, 1.66, 0.2), rgb(250, 250, 250), Enum.Material.Fabric, "Ball")
		-- the gown's hem over the legs, and slippers
		a:piece("ThighL", Vector3.new(1.08, 1.1, 1.08), CFrame.new(0, -0.5, 0), rgb(236, 236, 250), Enum.Material.Fabric)
		a:piece("ThighR", Vector3.new(1.08, 1.1, 1.08), CFrame.new(0, -0.5, 0), rgb(236, 236, 250), Enum.Material.Fabric)
		for i = 0, 2 do
			a:piece("Torso", Vector3.new(0.14, 0.14, 0.04), CFrame.new(0, 0.6 - i * 0.4, -0.52), rgb(90, 110, 200), nil, "Ball")
		end
	end,
}
PROPS.CandleStick = function()
	return {
		disc(22, 3, 1.5, GOLD, Enum.Material.Metal),
		{ V(4, 14, 26), C(12, 6, 0), GOLD, Enum.Material.Metal },
		disc(8, 26, 16, rgb(250, 246, 230)),
		{ V(6, 11, 6), C(0, 34, 0), rgb(255, 200, 90), Enum.Material.Neon, "Sphere" },
	}
end
PROPS.CastleCake = function()
	local t = {
		disc(120, 4, 2, GOLD, Enum.Material.Metal),
		{ V(92, 44, 92), C(0, 26, 0), rgb(250, 214, 230) },
		{ V(62, 34, 62), C(0, 65, 0), rgb(250, 240, 246) },
	}
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(t, disc(24, 80, 44, rgb(250, 214, 230), nil, sx * 46, sz * 46))
			table.insert(t, { V(20, 20, 20), C(sx * 46, 90, sz * 46), rgb(90, 110, 200), nil, "Sphere" })
		end
	end
	for i = -1, 1 do
		table.insert(t, { V(12, 12, 12), C(i * 22, 88, -31), rgb(250, 240, 246) })
	end
	table.insert(t, { V(3, 30, 3), C(0, 97, 0), rgb(100, 70, 44) })
	table.insert(t, { V(18, 11, 2), C(9, 107, 0), rgb(150, 26, 40), Enum.Material.Fabric })
	return t
end
PROPS.PotStack = function()
	local t = {}
	for i = 0, 2 do
		table.insert(t, disc(52 - i * 6, 14, 7 + i * 15, rgb(190, 110, 70), Enum.Material.Metal))
		table.insert(t, disc(44 - i * 6, 2, 14.5 + i * 15, rgb(120, 70, 40)))
	end
	table.insert(t, { V(40, 4, 4), C(30, 8, 0), rgb(190, 110, 70), Enum.Material.Metal })
	return t
end

local function midnightSnack(origin: CFrame, parent: Instance): any
	local ctx = Kit.new(origin, parent, 32)
	Kit.title(ctx, 3, "The Midnight Snack")
	local NIGHT = rgb(46, 46, 80)
	local ON = rgb(150, 130, 110)
	ctx:mood({ ClockTime = 23, Brightness = 0.5, ExposureCompensation = 0.4, Ambient = NIGHT, OutdoorAmbient = rgb(50, 50, 80) })
	local scene = ctx.Scene

	-- The castle kitchen.
	local ZW = 720
	Kit.floor(ctx, -800, 800, -800, ZW + 8, rgb(130, 120, 108), Enum.Material.Slate)
	local wallC = rgb(140, 132, 122)
	Kit.wall(ctx, -800, ZW, -110, ZW, 780, wallC, Enum.Material.Cobblestone, rgb(100, 92, 84))
	Kit.wall(ctx, 110, ZW, 800, ZW, 780, wallC, Enum.Material.Cobblestone, rgb(100, 92, 84))
	ctx:box("Lintel", V(220, 420, 16), ctx:at(0, 570, ZW), wallC, Enum.Material.Cobblestone)
	ctx:box("Corridor", V(220, 360, 10), ctx:at(0, 180, ZW + 330), rgb(30, 26, 30))
	ctx:box("CorridorFloor", V(220, 8, 300), ctx:at(0, -4, ZW + 150), rgb(110, 100, 90), Enum.Material.Slate)
	for _, dx in { -110, 110 } do
		ctx:box("DoorArch", V(24, 360, 30), ctx:at(dx, 180, ZW), rgb(110, 100, 90), Enum.Material.Slate)
	end
	Kit.wall(ctx, -800, -800, -800, ZW, 780, wallC, Enum.Material.Cobblestone, rgb(100, 92, 84))
	Kit.wall(ctx, 800, -800, 800, ZW, 780, wallC, Enum.Material.Cobblestone, rgb(100, 92, 84))
	Kit.ceiling(ctx, -800, 800, -800, ZW, 780, rgb(70, 50, 36), Enum.Material.Wood)
	for i = -3, 3 do
		ctx:box("Beam", V(1600, 30, 40), ctx:at(0, 760, 100 + i * 200), rgb(60, 42, 30), Enum.Material.Wood)
	end
	local fire = hearth(ctx, 480, ZW)
	-- the moonlit window
	ctx:box("MoonSky", V(140, 220, 2), ctx:at(-460, 440, ZW - 9), rgb(40, 50, 110), Enum.Material.Neon)
	ctx:box("Moon", V(2, 60, 60), ctx:at(-430, 500, ZW - 11) * CFrame.Angles(0, PI / 2, 0), rgb(255, 250, 220), Enum.Material.Neon, "Cylinder")
	ctx:box("WinBar", V(6, 220, 4), ctx:at(-460, 440, ZW - 12), rgb(60, 60, 66), Enum.Material.Metal)
	ctx:box("WinBar", V(140, 6, 4), ctx:at(-460, 450, ZW - 12), rgb(60, 60, 66), Enum.Material.Metal)
	local moonbeam = ctx:light(-460, 420, ZW - 80, rgb(150, 170, 255), 60, 1.2, 4)
	-- hanging copper pots and herbs
	ctx:box("PotRail", V(500, 8, 8), ctx:at(-360, 600, ZW - 40), rgb(60, 60, 64), Enum.Material.Metal)
	for i = 0, 4 do
		ctx:box("CopperPot", V(4, 60 - i * 5, 60 - i * 5), ctx:at(-560 + i * 100, 550, ZW - 40) * CFrame.Angles(0, PI / 2, 0), rgb(200, 116, 70), Enum.Material.Metal, "Cylinder")
		ctx:box("Herbs", V(24, 40, 12), ctx:at(-510 + i * 100, 560, ZW - 44), rgb(90, 140, 70), nil, "Sphere")
	end
	-- the washing-up corner: counter and dishwasher on the left
	local ZF = 550
	Kit.counter(ctx, -800, -140, ZF, { Gaps = { { -415, -285 } }, Body = rgb(110, 76, 50), BodyMat = Enum.Material.Wood, Door = rgb(124, 86, 56), Top = rgb(170, 164, 156), TopMat = Enum.Material.Slate, Splash = wallC, SplashMat = Enum.Material.Cobblestone })
	local dw = Kit.dishwasher(ctx, -350, ZF, 0, { Steel = GOLD, Mess = rgb(120, 70, 40) })

	-- The big table with the castle cake.
	local CX = 130
	Kit.table(ctx, CX, 300, 220, 160, TABLE, rgb(110, 76, 50))
	scene:prop("Cake", "CastleCake")
	scene:place("Cake", 0, 1e5 - 1, ctx:at(CX, TABLE + 1, 300))
	scene:prop("Stack", "PotStack")
	scene:place("Stack", 0, 1e5 - 1, ctx:at(CX - 80, TABLE + 1, 250))
	ctx:light(CX, TABLE + 180, 300, rgb(170, 180, 255), 50, 0.6, 2)

	-- The king and the jester creep in from opposite sides, candles in hand.
	local king = scene:actor("King", "KingNight")
	local jester = scene:actor("Jester", "Jester")
	scene:prop("KCandle", "CandleStick")
	scene:prop("JCandle", "CandleStick")
	scene:prop("Crown", "Crown")
	for _, n in { "KCandle", "JCandle" } do
		local l = Instance.new("PointLight")
		l.Color = rgb(255, 190, 110)
		l.Range = 40
		l.Brightness = 2.2
		l.Parent = scene.Props[n].Pieces[4].Part
	end
	local kCandle = { KCandle = { "L", off = CFrame.new(0, 2, 0) } }
	local jHold = { JCandle = { "R", off = CFrame.new(0, 2, 0) }, Crown = { "Head", off = CFrame.new(0, 58, 0) * CFrame.Angles(0, 0, 0.15) } }
	local function tiptoe(side: number): (number, any) -> any
		return function(u: number, c: any): any
			local s = c.Actor.S
			local p = { lean = 0.18, stride = 0.45, head = { yaw = math.sin(u * 1.7) * 0.4, pitch = -0.05 } }
			if side < 0 then
				p.armL = { at = local3(c, -0.3 * s, 190, 0.8 * s) }
				p.armR = { p = 0.3, r = 0.3, e = 1.6 }
			else
				p.armR = { at = local3(c, 0.3 * s, 190, 0.8 * s) }
				p.armL = { p = 0.3, r = 0.3, e = 1.6 }
			end
			return p
		end
	end
	local pk = R.newPlan(king, -560, 190, PI / 2)
	pk:still(2.6, tiptoe(-1), kCandle)
	pk:walk({ V2(CX - 190, 300) }, kCandle, tiptoe(-1), 80)
	pk:turn(PI / 2, kCandle, tiptoe(-1))
	local pj = R.newPlan(jester, 560, 190, -PI / 2)
	pj:still(2.8, tiptoe(1), jHold)
	pj:walk({ V2(CX + 190, 300) }, jHold, tiptoe(1), 80)
	pj:turn(-PI / 2, jHold, tiptoe(1))
	local REACH = math.max(pk.T, pj.T)
	pk:still(REACH - pk.T, tiptoe(-1), kCandle)
	pj:still(REACH - pj.T, tiptoe(1), jHold)
	-- both reach for the cake... and touch hands
	local function reachCake(side: number): (number, any) -> any
		return function(u: number, c: any): any
			local s = c.Actor.S
			local k = smooth(u / 1.1)
			local p = tiptoe(side)(u, c)
			p.stride = nil
			p.lean = 0.25 * k
			p.head = { pitch = -0.25 * k }
			local hand = ctx:R(CX, TABLE + 112, 300 + side * 4)
			local rest = local3(c, side * 0.3 * s, 190, 0.8 * s)
			if side < 0 then
				p.armR = { at = rest:Lerp(hand, k) }
			else
				p.armL = { at = rest:Lerp(hand, k) }
			end
			return p
		end
	end
	pk:still(1.1, reachCake(-1), kCandle)
	pj:still(1.1, reachCake(1), jHold)
	local BUMP = REACH + 1.1
	pk:still(1.2, P.startle, kCandle)
	pj:still(1.2, P.startle, jHold)
	local LIGHTS = BUMP + 1.4
	-- caught! Both look round at the door, very sheepish
	local function sheepish(side: number): (number, any) -> any
		return function(u: number, c: any): any
			local p = tiptoe(side)(u, c)
			p.stride = nil
			p.lean = 0.12
			p.head = { yaw = -side * 1.0, pitch = -0.2 }
			return p
		end
	end
	pk:still(LIGHTS - pk.T + 1.8, sheepish(-1), kCandle)
	pj:still(LIGHTS - pj.T + 1.8, sheepish(1), jHold)
	-- the jester gives the crown back: a toss over the cake
	local TOSS = LIGHTS + 1.8
	pj:still(0.9, function(u, c)
		local k = math.sin(math.clamp(u / 0.9, 0, 1) * PI)
		local p = tiptoe(1)(u, c)
		p.stride = nil
		p.armL = { p = 2.8 * k, r = 0.2, e = 0.3 }
		return p
	end, { JCandle = jHold.JCandle })
	local jRest = { JCandle = jHold.JCandle }
	pj:still(3, P.laugh, jRest)
	pj:still(3, P.wave, jRest)
	pj:finish(40, P.idle)
	pj.Steps[#pj.Steps].Hold = jRest
	table.insert(scene.Plans, pj)
	local CROWNED = TOSS + 1.2
	local kingCrown = { Crown = { "Head", off = CFrame.new(0, 90, 0) * CFrame.Angles(0, 0, -0.1) } }
	pk:still(CROWNED - pk.T, function(u, c)
		local p = sheepish(-1)(u, c)
		p.head = { yaw = 0, pitch = 0.4 }
		return p
	end, kCandle)
	-- crowned again (on top of the nightcap), he puts the candle down and gets washing up
	local withCrown = table.clone(kCandle)
	withCrown.Crown = kingCrown.Crown
	pk:still(1.2, P.laugh, withCrown)
	pk:turn(-PI / 2 - 0.4, withCrown)
	local PICK = pk.T
	pk:swap(1.0, P.reach(-0.35 * S, TABLE + 20, 1.2 * S, 0.1 * S, TABLE + 20, 1.2 * S, 1.0, 0.35), kingCrown, { Stack = { "both", off = CFrame.new(0, -4, -10) }, Crown = kingCrown.Crown })
	scene:place("KCandle", PICK, 1e5 - 1, ctx:at(CX - 90, TABLE + 1, 360))
	scene.Placements.Stack[1][2] = PICK + 0.5
	local carry = { Stack = { "both", off = CFrame.new(0, -4, -10) }, Crown = kingCrown.Crown }
	pk:walk({ V2(-350 - 95, ZF - 72) }, carry, P.carry, 140)
	pk:turn(0, carry, P.carry)
	local beats = Kit.loadDishwasher(ctx, pk, dw, "Stack")
	for _, st in pk.Steps do
		if st.T0 >= beats.Start - 0.01 then
			local h = st.Hold and table.clone(st.Hold) or {}
			h.Crown = kingCrown.Crown
			st.Hold = h
		end
	end
	pk:still(3, P.idle, kingCrown)
	pk:finish(40, P.idle)
	pk.Steps[#pk.Steps].Hold = kingCrown
	table.insert(scene.Plans, pk)
	local flyCrown = ctx:box("FlyCrown", V(10, 64, 64), CFrame.new(), GOLD, Enum.Material.Metal, "Cylinder")
	Kit.flight(ctx, flyCrown, TOSS + 0.35, CROWNED, function()
		local b = jester.Bones
		return if b then b.GripL.Position else ctx:R(190, 300, 300)
	end, function()
		local b = king.Bones
		return if b then (b.Head * CFrame.new(0, 90, 0)).Position else ctx:R(-190, 300, 300)
	end, 150, 2)
	-- the crown leaves the jester's head as he throws it
	for _, st in pj.Steps do
		if st.T0 >= TOSS - 0.01 and st.Hold then
			st.Hold.Crown = nil
		end
	end

	-- The queen appears in the doorway, lantern high: lights up.
	local queen = scene:actor("Queen", "Queen")
	local pq = R.newPlan(queen, 0, ZW + 420, PI)
	scene:prop("Lantern", "CandleStick")
	local lanternLight = Instance.new("PointLight")
	lanternLight.Color = rgb(255, 220, 160)
	lanternLight.Range = 60
	lanternLight.Brightness = 0
	lanternLight.Parent = scene.Props.Lantern.Pieces[4].Part
	local lantern = { Lantern = { "R", off = CFrame.new(0, 2, 0) } }
	pq:still(LIGHTS - 1.6, P.idle, lantern)
	pq:walk({ V2(0, ZW + 20) }, lantern, function(u, c)
		return { armR = { p = 2.4, r = 0.1, e = 0.4 } }
	end, 260)
	local function crossArms(u: number, c: any): any
		local s = c.Actor.S
		return {
			bob = R.breathe(u),
			head = { pitch = 0.05, yaw = math.sin(u * 1.2) * 0.2 },
			armL = { at = local3(c, 0.25 * s, 165, 0.55 * s) },
			armR = { p = 2.4, r = 0.1, e = 0.4 },
		}
	end
	pq:still(TOSS - pq.T, crossArms, lantern)
	pq:still(3.2, P.point(Vector3.new(-350, 0, ZF)), lantern)
	pq:still(3, P.laugh, lantern)
	pq:finish(40, crossArms)
	pq.Steps[#pq.Steps].Hold = lantern
	table.insert(scene.Plans, pq)
	ctx:onUpdate(function(t)
		local on = t >= LIGHTS
		lanternLight.Brightness = if on then 2.5 else 0
		pcall(function()
			game:GetService("Lighting").Ambient = if on then ON else NIGHT
		end)
		local fl = fire:FindFirstChildOfClass("PointLight")
		if fl then
			fl.Range = if on then 60 else 30
		end
		moonbeam:FindFirstChildOfClass("PointLight").Brightness = if on then 0.4 else 1.2
	end)

	-- Camera.
	ctx:shot(0, 3.0, { eye = { ctx:R(60, 430, -420), ctx:R(70, 390, -330) }, look = { ctx:R(CX, 200, 330), ctx:R(CX, 200, 330) }, fov = { 50, 46 } })
	ctx:shot(3.0, 5.6, { eye = { ctx:R(-520, 300, -160), ctx:R(-470, 300, -120) }, look = Kit.follow(king, "Torso"), fov = { 44, 42 }, ease = "linear" })
	ctx:shot(5.6, REACH - 0.2, { eye = { ctx:R(640, 300, -160), ctx:R(600, 300, -120) }, look = Kit.follow(jester, "Torso"), fov = { 44, 42 }, ease = "linear" })
	ctx:shot(REACH - 0.2, LIGHTS - 0.1, { eye = { ctx:R(CX, 420, 40), ctx:R(CX, 410, 70) }, look = { ctx:R(CX, 250, 300), ctx:R(CX, 250, 300) }, fov = { 50, 46 } })
	ctx:shot(LIGHTS - 0.1, TOSS + 0.2, { eye = { ctx:R(100, 270, 460), ctx:R(96, 268, 480) }, look = { ctx:R(0, 240, ZW + 40), ctx:R(0, 240, ZW + 30) }, fov = { 40, 36 } })
	ctx:shot(TOSS + 0.2, CROWNED + 0.4, { eye = { ctx:R(CX, 380, 20), ctx:R(CX - 20, 380, 20) }, look = function()
		return flyCrown.Position
	end, fov = { 50, 50 }, ease = "linear" })
	ctx:shot(CROWNED + 0.4, PICK + 0.6, { eye = { ctx:R(CX - 200, 290, 110), ctx:R(CX - 210, 285, 125) }, look = Kit.follow(king, "Head", Vector3.new(0, 40, 0)), fov = { 38, 36 } })
	ctx:shot(PICK + 0.6, beats.Open - 0.6, { eye = { ctx:R(-60, 400, -140), ctx:R(-120, 380, -100) }, look = Kit.follow(king, "Torso"), fov = { 48, 44 }, ease = "linear" })
	Kit.endingShots(ctx, dw, beats, 1)
	return ctx
end

return {
	royalFeast,
	gardenTea,
	midnightSnack,
}
