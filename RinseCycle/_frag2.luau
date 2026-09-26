
----------------------------------------------------------------------------------------------------
-- SOUTH: the two leaderboard boards and a How to Play board, all facing the centre (north, -Z,
-- which is the default facing of an unrotated part's Front surface -- no rotation needed here).
----------------------------------------------------------------------------------------------------
local function buildBoard(parent: Instance, x: number, z: number, titleText: string): BoardInfo
	local w, h = 22, 15
	local boardPart = mkPart("Part", {
		Name = "Board",
		Size = Vector3.new(w, h, 1),
		CFrame = CFrame.new(x, h / 2 + 2, z),
		Color = Color3.fromRGB(18, 55, 100),
		Material = Enum.Material.SmoothPlastic,
		CanQuery = false,
	}, parent)
	mkPart("Part", {
		Name = "BoardTrim",
		Size = Vector3.new(w + 1.2, h + 1.2, 0.4),
		CFrame = CFrame.new(x, h / 2 + 2, z + 0.7),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
	}, parent)
	for _, dx in { -w / 2 + 1.5, w / 2 - 1.5 } do
		mkPart("Part", {
			Name = "Leg",
			Size = Vector3.new(1, 4, 1),
			CFrame = CFrame.new(x + dx, 1, z),
			Color = Color3.fromRGB(120, 125, 130),
			Material = Enum.Material.Metal,
			CanQuery = false,
		}, parent)
	end

	local gui = mk("SurfaceGui", { Face = Enum.NormalId.Front, CanvasSize = Vector2.new(700, 480), LightInfluence = 0 }, boardPart)
	mk("UIPadding", {
		PaddingTop = UDim.new(0, 10),
		PaddingBottom = UDim.new(0, 10),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, gui)
	local titleLbl = mk("TextLabel", {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 64),
		BackgroundTransparency = 1,
		Text = titleText,
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.new(1, 1, 1),
	}, gui) :: TextLabel
	mk("UIStroke", { Thickness = 3, Color = Color3.fromRGB(10, 30, 60) }, titleLbl)
	local list = mk("Frame", {
		Name = "List",
		Size = UDim2.new(1, 0, 1, -70),
		Position = UDim2.new(0, 0, 0, 70),
		BackgroundTransparency = 1,
	}, gui) :: Frame
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 4) }, list)

	return { Part = boardPart, Title = titleLbl, List = list }
end

local function buildHowToPlay(parent: Instance, x: number, z: number)
	local w, h = 26, 16
	local boardPart = mkPart("Part", {
		Name = "HowToPlayBoard",
		Size = Vector3.new(w, h, 1),
		CFrame = CFrame.new(x, h / 2 + 2, z),
		Color = Color3.fromRGB(255, 255, 255),
		Material = Enum.Material.SmoothPlastic,
		CanQuery = false,
	}, parent)
	mkPart("Part", {
		Name = "Leg",
		Size = Vector3.new(1, 4, 1),
		CFrame = CFrame.new(x, 1, z),
		Color = Color3.fromRGB(120, 125, 130),
		Material = Enum.Material.Metal,
		CanQuery = false,
	}, parent)

	local gui = mk("SurfaceGui", { Face = Enum.NormalId.Front, CanvasSize = Vector2.new(760, 480), LightInfluence = 0 }, boardPart)
	mk("UIPadding", {
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 14),
		PaddingRight = UDim.new(0, 14),
	}, gui)
	mk("TextLabel", {
		Size = UDim2.new(1, 0, 0, 50),
		BackgroundTransparency = 1,
		Text = "How to Play",
		Font = Enum.Font.FredokaOne,
		TextScaled = true,
		TextColor3 = Color3.fromRGB(20, 80, 140),
	}, gui)
	local list = mk("Frame", {
		Size = UDim2.new(1, 0, 1, -56),
		Position = UDim2.new(0, 0, 0, 56),
		BackgroundTransparency = 1,
	}, gui)
	mk("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 6) }, list)

	local steps = {
		"Walk into a pad to start (or join) a party.",
		"Aim at grime and click (or hold) to scrub it off.",
		"Stand in the drain to sell your tank for coins.",
		"Spend coins on bigger hands, tools and upgrades.",
		"Clean every dish, earn Bubbles, and hatch pets!",
	}
	for i, text in steps do
		mk("TextLabel", {
			Name = "Step" .. i,
			Size = UDim2.new(1, 0, 0, 60),
			BackgroundTransparency = 1,
			Text = tostring(i) .. ". " .. text,
			Font = Enum.Font.GothamBold,
			TextScaled = true,
			TextColor3 = Color3.fromRGB(20, 40, 70),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			LayoutOrder = i,
		}, list)
	end
end

----------------------------------------------------------------------------------------------------
-- Decorations that sell the "tiny person in a giant kitchen" fantasy. All purely cosmetic.
----------------------------------------------------------------------------------------------------
local function buildDecorations(parent: Instance)
	mkPart("Part", {
		Name = "GiantSponge",
		Size = Vector3.new(14, 6, 10),
		CFrame = CFrame.new(WEST_X + 45, 3, SOUTH_Z - 30),
		Color = Color3.fromRGB(255, 210, 90),
		Material = Enum.Material.Foam,
		CanCollide = false,
		CanQuery = false,
	}, parent)
	mkPart("Part", {
		Name = "SpongeScrub",
		Size = Vector3.new(14.4, 1.4, 10.4),
		CFrame = CFrame.new(WEST_X + 45, 6.3, SOUTH_Z - 30),
		Color = Color3.fromRGB(90, 200, 120),
		Material = Enum.Material.Fabric,
		CanCollide = false,
		CanQuery = false,
	}, parent)

	local plateX, plateZ = EAST_X - 40, NORTH_Z + 22
	for i = 1, 5 do
		mkPart("Part", {
			Name = "StackedPlate" .. i,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.7, 11, 11),
			CFrame = CFrame.new(plateX, 0.4 + i * 0.8, plateZ) * CFrame.Angles(0, 0, math.rad(90)),
			Color = Color3.fromRGB(255, 255, 250),
			Material = Enum.Material.SmoothPlastic,
			CanQuery = false,
		}, parent)
	end

	local forkX, forkZ = WEST_X + 18, NORTH_Z + 20
	mkPart("Part", {
		Name = "ForkHandle",
		Size = Vector3.new(1.6, 26, 1.6),
		CFrame = CFrame.new(forkX, 13, forkZ) * CFrame.Angles(0, 0, math.rad(18)),
		Color = Color3.fromRGB(215, 218, 222),
		Material = Enum.Material.Metal,
		CanCollide = false,
		CanQuery = false,
	}, parent)
	for _, dx in { -1.2, -0.4, 0.4, 1.2 } do
		mkPart("Part", {
			Name = "ForkTine",
			Size = Vector3.new(0.6, 7, 0.6),
			CFrame = CFrame.new(forkX + dx * 0.9, 25, forkZ) * CFrame.Angles(0, 0, math.rad(18)),
			Color = Color3.fromRGB(215, 218, 222),
			Material = Enum.Material.Metal,
			CanCollide = false,
			CanQuery = false,
		}, parent)
	end

	mkPart("Part", {
		Name = "GiantSoapBar",
		Size = Vector3.new(12, 4, 7),
		CFrame = CFrame.new(WEST_X + 40, 2, ORIGIN.Z + 15),
		Color = Color3.fromRGB(255, 240, 200),
		Material = Enum.Material.SmoothPlastic,
		CanCollide = false,
		CanQuery = false,
	}, parent)

	-- Floating bubbles: a handful of translucent balls, each bobbing on its own cheap tween loop.
	local bubbleFolder = mk("Folder", { Name = "Bubbles" }, parent)
	for i = 1, 10 do
		local pos = Vector3.new(
			ORIGIN.X + math.random(-120, 120),
			18 + math.random(0, 20),
			ORIGIN.Z + math.random(-100, 100)
		)
		local size = 2 + math.random()
		local bubble = mkPart("Part", {
			Name = "Bubble" .. i,
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(size, size, size),
			CFrame = CFrame.new(pos),
			Color = Color3.fromRGB(255, 255, 255),
			Material = Enum.Material.ForceField,
			Transparency = 0.55,
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
		}, bubbleFolder)
		task.spawn(function()
			while bubble.Parent do
				local up = TweenService:Create(
					bubble,
					TweenInfo.new(3 + math.random(), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ Position = bubble.Position + Vector3.new(math.random(-3, 3), 5, math.random(-3, 3)) }
				)
				up:Play()
				up.Completed:Wait()
				if not bubble.Parent then
					break
				end
				local down = TweenService:Create(
					bubble,
					TweenInfo.new(3 + math.random(), Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
					{ Position = bubble.Position + Vector3.new(math.random(-3, 3), -5, math.random(-3, 3)) }
				)
				down:Play()
				down.Completed:Wait()
			end
		end)
	end
end

----------------------------------------------------------------------------------------------------
-- Bright, clean midday lighting with a soft blue atmosphere, subtle bloom, saturation and sun rays.
----------------------------------------------------------------------------------------------------
local function setupLighting()
	Lighting.ClockTime = 14
	Lighting.Brightness = 2.5
	Lighting.Ambient = Color3.fromRGB(140, 150, 165)
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 160, 175)
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1

	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmo = Instance.new("Atmosphere")
		atmo.Density = 0.15
		atmo.Offset = 0.15
		atmo.Color = Color3.fromRGB(200, 225, 255)
		atmo.Decay = Color3.fromRGB(150, 180, 220)
		atmo.Glare = 0
		atmo.Haze = 1
		atmo.Parent = Lighting
	end
	if not Lighting:FindFirstChildOfClass("BloomEffect") then
		local bloom = Instance.new("BloomEffect")
		bloom.Intensity = 0.4
		bloom.Size = 24
		bloom.Threshold = 1.4
		bloom.Parent = Lighting
	end
	if not Lighting:FindFirstChildOfClass("ColorCorrectionEffect") then
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Saturation = 0.15
		cc.Contrast = 0.05
		cc.Brightness = 0.02
		cc.Parent = Lighting
	end
	if not Lighting:FindFirstChildOfClass("SunRaysEffect") then
		local rays = Instance.new("SunRaysEffect")
		rays.Intensity = 0.15
		rays.Spread = 0.5
		rays.Parent = Lighting
	end
end

----------------------------------------------------------------------------------------------------
-- Build() / GetLobby() / GetSpawnCFrame()
----------------------------------------------------------------------------------------------------

-- Builds the whole lobby under workspace.Lobby. Safe to call once; a second call just returns the
-- existing Lobby table without building anything again.
function LobbyBuilder.Build(): Lobby
	if lobby then
		return lobby
	end

	local oldBase = Workspace:FindFirstChild("Baseplate")
	if oldBase then
		oldBase:Destroy()
	end
	local oldSpawn = Workspace:FindFirstChild("SpawnLocation")
	if oldSpawn and oldSpawn:IsA("BasePart") then
		oldSpawn:Destroy()
	end

	local model = Instance.new("Model")
	model.Name = "Lobby"
	model.Parent = Workspace

	-- SpawnLocations first, so a player who spawns mid-build has a floor under them.
	buildSpawnPlaza(model)

	buildFloor(model)

	local dishwasherSkip: Skip = {
		min = ORIGIN.X - DISHWASHER_WIDTH / 2 - 2,
		max = ORIGIN.X + DISHWASHER_WIDTH / 2 + 2,
	}
	buildWallNS(model, NORTH_Z, 1, FLOOR_X, dishwasherSkip)
	buildWallNS(model, SOUTH_Z, -1, FLOOR_X, nil)
	buildWallEW(model, WEST_X, 1, FLOOR_Z)
	buildWallEW(model, EAST_X, -1, FLOOR_Z)
	buildBarriers(model)

	buildDishwasherFacade(model)

	local pads: { PadInfo } = {}
	for i = 1, PAD_COUNT do
		pads[i] = buildPad(model, i)
	end

	buildFountain(model)
	buildSoapShop(model)
	buildEggHatchery(model)

	local timesBoard = buildBoard(model, ORIGIN.X - 60, SOUTH_Z - 20, "Fastest Clean")
	local dishesBoard = buildBoard(model, ORIGIN.X + 60, SOUTH_Z - 20, "Most Dishes Cleaned")
	buildHowToPlay(model, ORIGIN.X, SOUTH_Z - 20)

	buildDecorations(model)
	setupLighting()

	lobby = {
		Model = model,
		Pads = pads,
		Boards = { Times = timesBoard, Dishes = dishesBoard },
	}
	return lobby
end

function LobbyBuilder.GetLobby(): Lobby?
	return lobby
end

-- A random spot near the central spawn plaza, facing north toward the party pads.
function LobbyBuilder.GetSpawnCFrame(): CFrame
	local angle = math.random() * math.pi * 2
	local radius = 10 + math.random() * 14
	local pos = Vector3.new(ORIGIN.X + math.cos(angle) * radius, 2, ORIGIN.Z + math.sin(angle) * radius)
	return CFrame.new(pos, pos + Vector3.new(0, 0, -10))
end

return LobbyBuilder
