-- Rinse Cycle - every tunable number in the game lives here.
-- Shared by server and client (the client uses it to preview prices and stats).
--
-- Economy shape (round-based, like Search for the Needle):
--   * Inside a run: grime -> tank -> drain -> Coins -> hand upgrades + tools. All reset when the run ends.
--   * After a run: Bubbles (permanent) -> pet eggs, perks, and the next dishwasher unlocks.
--   * Each level has a Mult that inflates HP, units, tank, power, prices and coins together,
--     so every level plays at the same pace but the numbers get bigger. Levels get harder through
--     bigger loads and tougher grime (MinTool), not through the Mult.

local Config = {}

Config.GameName = "Rinse Cycle"
Config.Version = "1.9.0"

----------------------------------------------------------------------------------------------------
-- World
----------------------------------------------------------------------------------------------------
Config.World = {
	LobbyOrigin = Vector3.new(0, 0, 0),
	-- Arena slot k is built at ArenaRowStart + (k - 1) * ArenaSpacing: a row deep under the lobby, so
	-- nobody in the lobby can see other parties' dishwashers (each room is a closed box). Kept within
	-- ~5,000 studs of the origin (float precision) and far enough apart that parties never see each
	-- other. The place's FallenPartsDestroyHeight is set well below this (see _tools/build.py).
	ArenaRowStart = Vector3.new(-3500, -2500, 0),
	ArenaSpacing = Vector3.new(1000, 0, 0),
	MaxArenas = 8,
	LobbyWalkSpeed = 22, -- the lobby is small; this keeps walking between pads and shops snappy
}

----------------------------------------------------------------------------------------------------
-- Party pads (lobby)
----------------------------------------------------------------------------------------------------
Config.Party = {
	PadCount = 6,
	MaxPlayers = 8,
	Countdown = 30, -- seconds from Create until the party teleports (time for others to join)
	SoloCountdown = 3, -- the same for a party of one (they just want to start)
	LockSeconds = 1.5, -- joins and leaves are refused this close to launch
	RejoinCooldown = 0, -- (unused: a pad just left is ignored only until you've stepped out of it)
	PollInterval = 0.1, -- how often pads look for players stepping in
}

----------------------------------------------------------------------------------------------------
-- Runs (inside the dishwasher)
----------------------------------------------------------------------------------------------------
Config.Round = {
	ResultsSeconds = 20, -- results screen time before everyone is sent back to the lobby
	IntroMaxSeconds = 22, -- the run clock starts by this long after the start even if no one reports in
	ScrubSendInterval = 0.1, -- client send rate while holding spray
	ClickPulseSeconds = 0.25, -- a single tap (not held) deals this many seconds of power
	MinClickInterval = 0.11, -- server ignores clicks faster than this (about 9 per second)
	MaxScrubDt = 0.25, -- cap on the damage window of a single held scrub packet
	ReachSlack = 6, -- extra studs the server allows over reach (latency)
	DrainRadius = 8,
	PartyGrimeScale = 0.6, -- total grime = base * min(PartyGrimeCap, 1 + 0.6 * (players - 1))
	PartyGrimeCap = 3.6, -- big parties (up to 8) share a fuller load rather than an endless one
	PartyWorkPerPlayer = 1.25, -- total work = solo work x players x this, so a party run takes ~25% longer
	-- than solo (the extra beyond PartyGrimeCap spots goes into tougher dirt; coins scale with it).
	MarkerThreshold = 12, -- clients mark every remaining spot when this few are left
	StuckSeconds = 60, -- if nobody damages anything for this long...
	StuckMaxRemaining = 3, -- ...and this few spots are left, they pop on their own
	DishBonusShare = 0.25, -- cleaning the last spot on a dish pays 25% of the dish's units as coins
	CoinsPerUnit = 4, -- coins paid per unit of dirt sold at the drain (before CoinMult bonuses)
	GoldenUnitsMult = 5,
	UnderTierMult = 0.2, -- a tool below a spot's MinTool still cleans it, at this fraction of its power
	GoldenBubbles = { 1, 3 }, -- min/max Bubbles for a golden spot (times the level index)
	UnderParBonus = 0.25, -- +25% Bubbles for finishing under par time
	FirstClearMult = 2,
}

----------------------------------------------------------------------------------------------------
-- Base player stats in a run (before level Mult). See Config.GetRunStats.
----------------------------------------------------------------------------------------------------
Config.Base = {
	Radius = 1.6, -- studs
	RadiusPerLevel = 0.3,
	Power = 2.5, -- dirt HP removed per second
	PowerGrowth = 1.45, -- per Power level
	Tank = 15, -- units
	TankGrowth = 1.6, -- per Tank Size level
	WalkSpeed = 20,
	WalkSpeedPerLevel = 2.5,
}

-- In-run upgrades bought with Coins. Price = Base * Growth^level * level Mult (2 significant figures).
-- PerTool upgrades are bought separately for every tool (and cost more on better tools: x UpgradeMult);
-- the others (Tank, Sneakers) are yours whatever you're holding.
Config.Upgrades = {
	{ Id = "ScrubPower", Name = "Power", Icon = "💪", Desc = "This tool cleans faster.", Base = 8, Growth = 2, Max = 6, PerTool = true },
	{ Id = "HandSize", Name = "Size", Icon = "🖐️", Desc = "This tool cleans a bigger area.", Base = 10, Growth = 2, Max = 6, PerTool = true },
	{ Id = "TankSize", Name = "Tank Size", Icon = "🛢️", Desc = "Carry more dirt per trip.", Base = 6, Growth = 2, Max = 6 },
	{ Id = "Sneakers", Name = "Sneakers", Icon = "👟", Desc = "Run to the drain faster.", Base = 12, Growth = 2, Max = 6 },
}

-- Tools, bought with Coins inside a run in ANY order (skip straight to the best one if you can
-- afford it), then picked from the hotbar (keys 1-6). Each one plays differently (Mode):
--   Scrub - a circle right where you aim; hold to scrub. Short reach.
--   Spray - a circle at the end of a long water stream. Long reach.
--   Line  - a long, thin blade of water (LineLength x LineWidth, turned with the camera): sweep it
--           across the dirt; anything in the line goes fast.
--   Foam  - fires foam blobs (one per FoamInterval) that splat and keep cleaning everything in
--           FoamRadius for FoamSeconds, at Power * FoamShare per second.
-- Tier decides which dirt it cleans at full speed (dirt with MinTool above the Tier cleans at
-- Round.UnderTierMult). Radius and Power multiply the (per-tool) upgraded base stats; for Line the
-- Size upgrade makes the line longer, for Foam the splats bigger. Reach is in studs.
Config.Tools = {
	{ Id = "Hands", Name = "Bare Hands", Icon = "🖐️", Mode = "Scrub", Tier = 1, Cost = 0, Radius = 1.0, Power = 1.0, Reach = 12, UpgradeMult = 1, Color = Color3.fromRGB(150, 210, 255), Desc = "Free, but slow. Get close and scrub." },
	{ Id = "Sponge", Name = "Sponge", Icon = "🧽", Mode = "Scrub", Tier = 1, Cost = 60, Radius = 1.4, Power = 2.2, Reach = 12, UpgradeMult = 1.5, Color = Color3.fromRGB(255, 221, 87), Desc = "Soft and quick. Scrub up close." },
	{ Id = "Nozzle", Name = "Spray Nozzle", Icon = "🚿", Mode = "Spray", PassKey = "ToolNozzle", Tier = 2, Cost = 350, Radius = 1.5, Power = 3.2, Reach = 34, UpgradeMult = 3, Color = Color3.fromRGB(90, 200, 255), Desc = "A water stream: clean from far away." },
	{ Id = "Washer", Name = "Pressure Washer", Icon = "💦", Mode = "Line", PassKey = "ToolWasher", Tier = 3, Cost = 700, Radius = 1.0, Power = 22, Reach = 26, UpgradeMult = 5, LineLength = 3.5, LineWidth = 0.9, Color = Color3.fromRGB(60, 140, 255), Desc = "A long thin blast: sweep it across and dirt melts away." },
	{ Id = "Cannon", Name = "Foam Cannon", Icon = "🌊", Mode = "Foam", PassKey = "ToolCannon", Tier = 3, Cost = 1500, Radius = 1.8, Power = 4.5, Reach = 40, UpgradeMult = 8, FoamInterval = 0.4, FoamSeconds = 2.5, FoamShare = 0.6, Color = Color3.fromRGB(200, 150, 255), Desc = "Shoots foam blobs that keep cleaning where they land." },
}

----------------------------------------------------------------------------------------------------
-- Grime (players see "dirt"). HP and Units are multiplied by the level Mult. MinTool = the lowest tool
-- Tier that can clean it.
-- Shape: "Blob" (flat ellipsoid), "Crumbs" (disc + little bits), "Streak" (long smear), "Sprinkles".
----------------------------------------------------------------------------------------------------
Config.GrimeTypes = {
	Crumbs = { Name = "Crumbs", HP = 3, Units = 1, Color = Color3.fromRGB(201, 160, 99), Material = Enum.Material.Sand, Size = { 0.9, 1.5 }, Shape = "Crumbs", MinTool = 1 },
	Ketchup = { Name = "Ketchup", HP = 5, Units = 2, Color = Color3.fromRGB(196, 30, 30), Material = Enum.Material.SmoothPlastic, Size = { 1.2, 2.0 }, Shape = "Blob", MinTool = 1 },
	Gravy = { Name = "Gravy", HP = 8, Units = 3, Color = Color3.fromRGB(110, 70, 40), Material = Enum.Material.SmoothPlastic, Size = { 1.4, 2.4 }, Shape = "Streak", MinTool = 1 },

	TomatoSauce = { Name = "Tomato Sauce", HP = 5, Units = 2, Color = Color3.fromRGB(214, 58, 34), Material = Enum.Material.SmoothPlastic, Size = { 1.3, 2.2 }, Shape = "Streak", MinTool = 1 },
	MeltedCheese = { Name = "Melted Cheese", HP = 7, Units = 2, Color = Color3.fromRGB(255, 200, 60), Material = Enum.Material.SmoothPlastic, Size = { 1.3, 2.2 }, Shape = "Blob", MinTool = 1 },
	BurntCrust = { Name = "Burnt Crust", HP = 14, Units = 4, Color = Color3.fromRGB(45, 32, 25), Material = Enum.Material.Slate, Size = { 1.0, 1.8 }, Shape = "Crumbs", MinTool = 2 },

	Grease = { Name = "Grease", HP = 9, Units = 3, Color = Color3.fromRGB(235, 205, 110), Material = Enum.Material.Glass, Size = { 1.6, 2.6 }, Shape = "Streak", MinTool = 1 },
	Mustard = { Name = "Mustard", HP = 6, Units = 2, Color = Color3.fromRGB(240, 190, 20), Material = Enum.Material.SmoothPlastic, Size = { 1.0, 1.8 }, Shape = "Streak", MinTool = 1 },
	Char = { Name = "Char", HP = 16, Units = 4, Color = Color3.fromRGB(30, 26, 24), Material = Enum.Material.Basalt, Size = { 1.2, 2.0 }, Shape = "Crumbs", MinTool = 2 },

	Frosting = { Name = "Frosting", HP = 8, Units = 3, Color = Color3.fromRGB(255, 150, 200), Material = Enum.Material.SmoothPlastic, Size = { 1.4, 2.4 }, Shape = "Blob", MinTool = 1 },
	Sprinkles = { Name = "Sprinkles", HP = 3, Units = 1, Color = Color3.fromRGB(255, 255, 255), Material = Enum.Material.SmoothPlastic, Size = { 1.0, 1.6 }, Shape = "Sprinkles", MinTool = 1 },
	Chocolate = { Name = "Chocolate", HP = 11, Units = 3, Color = Color3.fromRGB(80, 45, 25), Material = Enum.Material.SmoothPlastic, Size = { 1.4, 2.4 }, Shape = "Blob", MinTool = 1 },
	BurntSugar = { Name = "Burnt Sugar", HP = 18, Units = 5, Color = Color3.fromRGB(120, 60, 10), Material = Enum.Material.Glass, Size = { 1.0, 1.8 }, Shape = "Crumbs", MinTool = 2 },

	TruffleGunk = { Name = "Truffle Gunk", HP = 10, Units = 3, Color = Color3.fromRGB(70, 60, 50), Material = Enum.Material.Mud, Size = { 1.4, 2.4 }, Shape = "Blob", MinTool = 1 },
	CaviarSmear = { Name = "Caviar Smear", HP = 8, Units = 3, Color = Color3.fromRGB(25, 25, 35), Material = Enum.Material.Pebble, Size = { 1.2, 2.0 }, Shape = "Crumbs", MinTool = 1 },
	AncientGravy = { Name = "Ancient Gravy", HP = 22, Units = 6, Color = Color3.fromRGB(90, 110, 50), Material = Enum.Material.Mud, Size = { 1.6, 2.6 }, Shape = "Streak", MinTool = 2 },
}

----------------------------------------------------------------------------------------------------
-- Levels (dishwashers). Dishes = how many of each kind are in the load.
-- Spots = base grime spots per dish of that kind (solo), before PartyGrimeScale.
-- Theme colours are used by the arena and dish builders.
----------------------------------------------------------------------------------------------------
Config.DishKinds = { "Plate", "Tray", "Bowl", "Cup", "Glass", "Fork", "Knife", "Spoon", "Pan", "Pot" }

Config.Levels = {
	{
		Id = 1,
		Name = "Family Dinner",
		Subtitle = "Crumbs, ketchup and a whole lot of gravy.",
		Icon = "🍝",
		Place = "Family Kitchen",
		-- Dirt HP multiplier on top of Mult. Progression starts fast and gets slower: the first
		-- dishwasher is quick to clean (new players see progress straight away), later ones are tougher.
		Toughness = 1.8,
		StartCoins = 20, -- every run here starts with enough for a first upgrade straight away
		Mult = 1,
		ParTime = 540,
		Bubbles = 80,
		GoldenChance = 0.02,
		Dishes = { Plate = 16, Tray = 0, Bowl = 6, Cup = 6, Glass = 2, Fork = 4, Knife = 3, Spoon = 3, Pan = 0, Pot = 0 },
		Spots = { Plate = 6, Tray = 8, Bowl = 6, Cup = 4, Glass = 3, Fork = 2, Knife = 2, Spoon = 2, Pan = 14, Pot = 16 },
		Grime = { { Type = "Crumbs", Weight = 45 }, { Type = "Ketchup", Weight = 35 }, { Type = "Gravy", Weight = 20 } },
		Theme = {
			Tub = Color3.fromRGB(172, 178, 187),
			Rack = Color3.fromRGB(235, 240, 245),
			Accent = Color3.fromRGB(80, 170, 255),
			Plate = Color3.fromRGB(250, 250, 248),
			PlateRim = Color3.fromRGB(120, 175, 230),
			Bowl = Color3.fromRGB(150, 200, 240),
			Cup = Color3.fromRGB(255, 180, 120),
			Glass = Color3.fromRGB(200, 235, 255),
			Metal = Color3.fromRGB(190, 195, 200),
			Tray = Color3.fromRGB(190, 195, 200),
			Light = Color3.fromRGB(210, 235, 255),
		},
	},
	{
		Id = 2,
		Name = "Pizza Party",
		Subtitle = "Greasy pizza trays, sauce everywhere and burnt crust.",
		Icon = "🍕",
		Place = "Pizzeria",
		Toughness = 4.5, -- dirt HP multiplier on top of Mult (later levels are tougher, not just bigger)
		Mult = 4,
		ParTime = 1260,
		Bubbles = 250,
		GoldenChance = 0.025,
		Dishes = { Plate = 12, Tray = 9, Bowl = 8, Cup = 7, Glass = 4, Fork = 5, Knife = 4, Spoon = 4, Pan = 2, Pot = 0 },
		Spots = { Plate = 5, Tray = 8, Bowl = 5, Cup = 4, Glass = 3, Fork = 2, Knife = 2, Spoon = 2, Pan = 13, Pot = 15 },
		Grime = {
			{ Type = "TomatoSauce", Weight = 32 },
			{ Type = "MeltedCheese", Weight = 26 },
			{ Type = "Grease", Weight = 15 },
			{ Type = "Crumbs", Weight = 10 },
			{ Type = "BurntCrust", Weight = 17 },
		},
		Theme = {
			Tub = Color3.fromRGB(196, 200, 206),
			Rack = Color3.fromRGB(225, 85, 65),
			Accent = Color3.fromRGB(255, 120, 60),
			Plate = Color3.fromRGB(255, 250, 240),
			PlateRim = Color3.fromRGB(215, 55, 45),
			Bowl = Color3.fromRGB(255, 230, 190),
			Cup = Color3.fromRGB(110, 190, 110),
			Glass = Color3.fromRGB(210, 240, 255),
			Metal = Color3.fromRGB(185, 190, 195),
			Tray = Color3.fromRGB(160, 165, 172),
			Light = Color3.fromRGB(255, 225, 190),
		},
	},
	{
		Id = 3,
		Name = "Royal Banquet",
		Subtitle = "Golden platters, fancy food and ancient gravy.",
		Icon = "👑",
		Place = "Castle Hall",
		Toughness = 8.5, -- dirt HP multiplier on top of Mult (later levels are tougher, not just bigger)
		Mult = 16,
		ParTime = 1860,
		Bubbles = 700,
		GoldenChance = 0.035,
		Dishes = { Plate = 14, Tray = 10, Bowl = 10, Cup = 6, Glass = 10, Fork = 6, Knife = 6, Spoon = 5, Pan = 2, Pot = 2 },
		Spots = { Plate = 5, Tray = 9, Bowl = 5, Cup = 4, Glass = 3, Fork = 2, Knife = 2, Spoon = 2, Pan = 14, Pot = 16 },
		Grime = {
			{ Type = "TruffleGunk", Weight = 30 },
			{ Type = "CaviarSmear", Weight = 25 },
			{ Type = "Gravy", Weight = 15 },
			{ Type = "Chocolate", Weight = 12 },
			{ Type = "AncientGravy", Weight = 18 },
		},
		Theme = {
			Tub = Color3.fromRGB(70, 64, 80),
			Rack = Color3.fromRGB(230, 190, 90),
			Accent = Color3.fromRGB(255, 205, 80),
			Plate = Color3.fromRGB(255, 250, 235),
			PlateRim = Color3.fromRGB(215, 170, 60),
			Bowl = Color3.fromRGB(245, 235, 210),
			Cup = Color3.fromRGB(150, 40, 60),
			Glass = Color3.fromRGB(255, 240, 200),
			Metal = Color3.fromRGB(230, 190, 90),
			Tray = Color3.fromRGB(235, 195, 85),
			Light = Color3.fromRGB(255, 225, 160),
		},
	},
}

----------------------------------------------------------------------------------------------------
-- Permanent perks (lobby Soap Shop), bought with Bubbles.
-- Cost = Base * Growth^level (2 significant figures), or Costs[level + 1] when Costs is given.
----------------------------------------------------------------------------------------------------
Config.Perks = {
	{ Id = "HeadStart", Name = "Head Start", Icon = "💰", Desc = "Start every run with +40 coins per level (times the dishwasher's multiplier).", Base = 40, Growth = 2, Max = 6, PerLevel = 40 },
	{ Id = "CoinSoap", Name = "Coin Soap", Icon = "💰", Desc = "+15% coins from the drain per level.", Base = 60, Growth = 2, Max = 6, PerLevel = 0.15 },
	{ Id = "DeepTank", Name = "Deep Tank", Icon = "🛢️", Desc = "+25% tank size per level.", Base = 50, Growth = 2, Max = 6, PerLevel = 0.25 },
	{ Id = "LuckySuds", Name = "Lucky Suds", Icon = "🍀", Desc = "+1% golden dirt per level (best in the party counts).", Base = 60, Growth = 1.8, Max = 5, PerLevel = 0.01 },
}

----------------------------------------------------------------------------------------------------
-- Pets. Pets clean grime near you during runs. Their cleaning speed is PowerShare times YOUR current
-- run power (so they stay useful as you upgrade), and CoinBonus adds to your coin multiplier (equipped
-- pets add up). Coin bonuses top out at x1.67 for a Rainbow Kraken King: five of those is x4.3,
-- three common Rubber Ducks x1.12. Shown in the menu as "Coins x1.04".
-- Model = which builder PetModels uses; Colors are passed to it.
----------------------------------------------------------------------------------------------------
Config.Rarities = {
	Common = { Order = 1, Name = "Common", Color = Color3.fromRGB(190, 200, 210) },
	Uncommon = { Order = 2, Name = "Uncommon", Color = Color3.fromRGB(110, 220, 120) },
	Rare = { Order = 3, Name = "Rare", Color = Color3.fromRGB(80, 170, 255) },
	Epic = { Order = 4, Name = "Epic", Color = Color3.fromRGB(190, 110, 255) },
	Legendary = { Order = 5, Name = "Legendary", Color = Color3.fromRGB(255, 190, 40) },
}

Config.PetRules = {
	BaseSlots = 3,
	MaxInventory = 60,
	MergeCount = 3, -- this many pets of one rarity merge into one of the next rarity
	Range = 35, -- pets pick grime within this many studs of their owner
	Speed = 40, -- studs per second when flying to a spot (used for the travel delay)
	ThinkInterval = 0.25,
}

Config.Pets = {
	-- Bubble Egg
	RubberDuck = { Name = "Rubber Duck", Rarity = "Common", PowerShare = 0.12, Capacity = 12, CoinBonus = 0.04, Model = "Duck", Colors = { Body = Color3.fromRGB(255, 220, 60), Accent = Color3.fromRGB(255, 140, 30) } },
	SoapSlime = { Name = "Soap Slime", Rarity = "Uncommon", PowerShare = 0.18, Capacity = 18, CoinBonus = 0.06, Model = "Slime", Colors = { Body = Color3.fromRGB(150, 230, 255), Accent = Color3.fromRGB(255, 255, 255) } },
	SpongePup = { Name = "Sponge Pup", Rarity = "Rare", PowerShare = 0.27, Capacity = 26, CoinBonus = 0.09, Model = "Pup", Colors = { Body = Color3.fromRGB(255, 225, 90), Accent = Color3.fromRGB(90, 190, 90) } },
	BubbleFish = { Name = "Bubble Fish", Rarity = "Epic", PowerShare = 0.42, Capacity = 38, CoinBonus = 0.13, Model = "Fish", Colors = { Body = Color3.fromRGB(120, 180, 255), Accent = Color3.fromRGB(255, 255, 255) } },
	GoldenDuck = { Name = "Golden Duck", Rarity = "Legendary", PowerShare = 0.66, Capacity = 55, CoinBonus = 0.2, Model = "Duck", Colors = { Body = Color3.fromRGB(255, 200, 40), Accent = Color3.fromRGB(255, 240, 150) }, Shiny = true },
	-- Suds Egg
	ScrubBunny = { Name = "Scrub Bunny", Rarity = "Common", PowerShare = 0.21, Capacity = 18, CoinBonus = 0.06, Model = "Bunny", Colors = { Body = Color3.fromRGB(245, 245, 250), Accent = Color3.fromRGB(255, 170, 200) } },
	SudsCrab = { Name = "Suds Crab", Rarity = "Uncommon", PowerShare = 0.30, Capacity = 27, CoinBonus = 0.09, Model = "Crab", Colors = { Body = Color3.fromRGB(255, 110, 90), Accent = Color3.fromRGB(255, 255, 255) } },
	MopCat = { Name = "Mop Cat", Rarity = "Rare", PowerShare = 0.42, Capacity = 39, CoinBonus = 0.12, Model = "Cat", Colors = { Body = Color3.fromRGB(170, 170, 185), Accent = Color3.fromRGB(240, 240, 240) } },
	OctoScrubber = { Name = "Octo-Scrubber", Rarity = "Epic", PowerShare = 0.60, Capacity = 57, CoinBonus = 0.17, Model = "Octopus", Colors = { Body = Color3.fromRGB(200, 110, 255), Accent = Color3.fromRGB(255, 200, 255) } },
	RainbowJelly = { Name = "Rainbow Jelly", Rarity = "Legendary", PowerShare = 0.96, Capacity = 82, CoinBonus = 0.26, Model = "Jelly", Colors = { Body = Color3.fromRGB(255, 120, 200), Accent = Color3.fromRGB(120, 255, 230) }, Shiny = true },
	-- Sparkle Egg
	FoamFox = { Name = "Foam Fox", Rarity = "Common", PowerShare = 0.36, Capacity = 26, CoinBonus = 0.09, Model = "Fox", Colors = { Body = Color3.fromRGB(255, 150, 70), Accent = Color3.fromRGB(255, 255, 255) } },
	SteamOwl = { Name = "Steam Owl", Rarity = "Uncommon", PowerShare = 0.51, Capacity = 40, CoinBonus = 0.13, Model = "Owl", Colors = { Body = Color3.fromRGB(150, 130, 110), Accent = Color3.fromRGB(255, 230, 150) } },
	CrystalTurtle = { Name = "Crystal Turtle", Rarity = "Rare", PowerShare = 0.72, Capacity = 57, CoinBonus = 0.18, Model = "Turtle", Colors = { Body = Color3.fromRGB(120, 230, 200), Accent = Color3.fromRGB(200, 255, 255) } },
	TidalDragon = { Name = "Tidal Dragon", Rarity = "Epic", PowerShare = 1.02, Capacity = 84, CoinBonus = 0.25, Model = "Dragon", Colors = { Body = Color3.fromRGB(60, 150, 255), Accent = Color3.fromRGB(180, 240, 255) } },
	KrakenKing = { Name = "Kraken King", Rarity = "Legendary", PowerShare = 1.56, Capacity = 121, CoinBonus = 0.38, Model = "Kraken", Colors = { Body = Color3.fromRGB(120, 40, 160), Accent = Color3.fromRGB(255, 210, 60) }, Shiny = true },
}

-- Eggs cost Bubbles. Bubbles can never be bought with Robux, so eggs are not "paid random items";
-- the odds are still always shown before hatching. Chances must add up to 100.
Config.Eggs = {
	{
		Id = "Bubble",
		Name = "Bubble Egg",
		Cost = 50,
		RequiredLevel = 1,
		Color = Color3.fromRGB(150, 220, 255),
		Pets = { { Pet = "RubberDuck", Chance = 60 }, { Pet = "SoapSlime", Chance = 25 }, { Pet = "SpongePup", Chance = 11 }, { Pet = "BubbleFish", Chance = 3.5 }, { Pet = "GoldenDuck", Chance = 0.5 } },
	},
	{
		Id = "Suds",
		Name = "Suds Egg",
		Cost = 400,
		RequiredLevel = 2,
		Color = Color3.fromRGB(255, 170, 220),
		Pets = { { Pet = "ScrubBunny", Chance = 60 }, { Pet = "SudsCrab", Chance = 25 }, { Pet = "MopCat", Chance = 11 }, { Pet = "OctoScrubber", Chance = 3.5 }, { Pet = "RainbowJelly", Chance = 0.5 } },
	},
	{
		Id = "Sparkle",
		Name = "Sparkle Egg",
		Cost = 2500,
		RequiredLevel = 3,
		Color = Color3.fromRGB(255, 220, 90),
		Pets = { { Pet = "FoamFox", Chance = 60 }, { Pet = "SteamOwl", Chance = 25 }, { Pet = "CrystalTurtle", Chance = 11 }, { Pet = "TidalDragon", Chance = 3.5 }, { Pet = "KrakenKing", Chance = 0.5 } },
	},
}

----------------------------------------------------------------------------------------------------
-- ROBUX GAME PASSES  -  PASTE YOUR PASS IDS HERE
--
-- How to sell one:
--   1. Creator Dashboard -> your experience -> Monetization -> Passes -> Create a Pass.
--      Give it the same name and price as below (Price is only what the shop shows).
--   2. Copy the pass's ID (the number in its URL) and paste it over the 0 in `Id = 0` below.
--   3. Republish. That's it: the Buy button now opens Roblox's real purchase prompt, and owners get
--      the perk automatically every time they join.
--
-- While an Id is still 0 the pass is in TEST MODE: pressing Buy in Studio gives it to you for that
-- play session (with confetti) so you can try it out. Test mode never works in the live game unless
-- you set Config.TestPasses.AllowInLiveGame = true (don't!).
----------------------------------------------------------------------------------------------------
Config.GamePasses = {
	{ Key = "DoubleCoins", Id = 0, Price = 99, Name = "2x Coins", Icon = "💰", Desc = "Earn double coins every time you sell at the drain." },
	{ Key = "SuperScrub", Id = 0, Price = 129, Name = "Super Scrub", Icon = "💪", Desc = "All your tools clean 50% faster." },
	{ Key = "MegaTank", Id = 0, Price = 149, Name = "Mega Tank", Icon = "🛢️", Desc = "Your tank holds twice as much dirt before you need to sell." },
	{ Key = "LuckyCharm", Id = 0, Price = 99, Name = "Lucky Charm", Icon = "🍀", Desc = "Twice as much golden dirt appears. Golden dirt drops gems." },
	{ Key = "PetSlots", Id = 0, Price = 149, Name = "+2 Pet Slots", Icon = "🐾", Desc = "Equip 5 pets at once instead of 3." },
	{ Key = "AutoDrain", Id = 0, Price = 149, Name = "Auto Drain", Icon = "🌀", Desc = "Your tank sells automatically when it is full, so you never walk to the drain." },
	{ Key = "DoubleBubbles", Id = 0, Price = 179, Name = "2x Bubbles", Icon = "🧼", Desc = "Earn double Bubbles from every finished wash." },
	{ Key = "VIP", Id = 0, Price = 199, Name = "VIP", Icon = "👑", Desc = "+25% coins and +25% Bubbles on every wash." },
	{ Key = "DoubleLuck", Id = 0, Price = 149, Name = "x2 Luck", Icon = "🍀", Desc = "Doubles your chance of rolling Rare, Epic, Legendary and Mythic ranks." },
	{ Key = "InstaRoll", Id = 0, Price = 39, Name = "Insta Roll", Icon = "⚡", Desc = "Skip the rank roll spin: see your new rank instantly." },
	-- Tool passes: start every run already owning that tool (you still upgrade it with coins). They
	-- pop up when you try to buy the tool without enough coins.
	{ Key = "ToolNozzle", Id = 0, Price = 49, Name = "Spray Nozzle", Icon = "🚿", Desc = "Start every wash with the Spray Nozzle already unlocked." },
	{ Key = "ToolWasher", Id = 0, Price = 99, Name = "Pressure Washer", Icon = "💦", Desc = "Start every wash with the Pressure Washer already unlocked." },
	{ Key = "ToolCannon", Id = 0, Price = 199, Name = "Foam Cannon", Icon = "🌊", Desc = "Start every wash with the Foam Cannon already unlocked." },
}

-- Developer products (buy as many times as you like). Same deal as passes: create a Developer
-- Product on the Creator Dashboard (Monetization -> Developer Products) with this price, and paste
-- its ID over the 0. Bubbles packs work anywhere; Coins packs only inside a run (the coins are
-- multiplied by the dishwasher's level multiplier so they stay useful on every level).
Config.DevProducts = {
	{ Key = "Bubbles1", Id = 0, Price = 19, Kind = "Bubbles", Amount = 250, Name = "Handful of Bubbles", Icon = "🧼" },
	{ Key = "Bubbles2", Id = 0, Price = 49, Kind = "Bubbles", Amount = 800, Name = "Bucket of Bubbles", Icon = "🧼" },
	{ Key = "Bubbles3", Id = 0, Price = 99, Kind = "Bubbles", Amount = 2000, Name = "Tub of Bubbles", Icon = "🛁" },
	{ Key = "Bubbles4", Id = 0, Price = 199, Kind = "Bubbles", Amount = 5000, Name = "Bathtub Overflow", Icon = "🌊" },
	{ Key = "Coins1", Id = 0, Price = 15, Kind = "Coins", Amount = 250, Name = "Coin Splash", Icon = "💰" },
	{ Key = "Coins2", Id = 0, Price = 39, Kind = "Coins", Amount = 900, Name = "Coin Wave", Icon = "💰" },
	{ Key = "Coins3", Id = 0, Price = 89, Kind = "Coins", Amount = 2500, Name = "Coin Flood", Icon = "💰" },
	{ Key = "Gems1", Id = 0, Price = 29, Kind = "Gems", Amount = 30, Name = "Pouch of Gems", Icon = "💎" },
	{ Key = "Gems2", Id = 0, Price = 79, Kind = "Gems", Amount = 100, Name = "Sack of Gems", Icon = "💎" },
	{ Key = "Gems3", Id = 0, Price = 199, Kind = "Gems", Amount = 300, Name = "Chest of Gems", Icon = "💎" },
	-- Offered in the Daily Reward window only when you've missed a day.
	{ Key = "RestoreStreak", Id = 0, Price = 29, Kind = "RestoreStreak", Amount = 1, Name = "Restore Streak", Icon = "🔥" },
}

function Config.GetProduct(key: string)
	for _, p in Config.DevProducts do
		if p.Key == key then
			return p
		end
	end
	return nil
end

Config.TestPasses = {
	AllowInStudio = true, -- Id = 0 passes and products can be "bought" for free in Studio play tests
	AllowInLiveGame = false, -- keep false: otherwise anyone could take unfinished passes for free
}

----------------------------------------------------------------------------------------------------
-- Gems (premium currency) and Ranks.
-- Gems drop rarely while cleaning (always from golden dirt), you get a few for every clear, and they
-- can be bought with Robux (Config.DevProducts). A Rank roll costs Gems and gives a random rank; the
-- rank you have equipped gives its perk in every run. Gems can be bought with Robux, so rank rolls
-- are "paid random items": the odds are always shown before rolling (Roblox rules).
----------------------------------------------------------------------------------------------------
Config.Gems = {
	DropChance = 0.006, -- per dirt spot you clean yourself
	GoldenDrop = 1, -- gems from every golden spot
	PerClear = 1, -- gems per finished run, times the level index
}

Config.RankRoll = {
	Cost = 30, -- gems per roll
	LuckMult = 2, -- x2 Luck pass: Rare and better are this many times as likely
	-- Rewarded video ads (Roblox AdService): each ad adds PerAd to your luck for Minutes, up to
	-- MaxAds stacked (+100%). The x2 Luck pass doubles the total: 5 ads = x2 luck, x4 with the pass.
	AdLuck = { PerAd = 0.2, MaxAds = 5, Minutes = 15 },
}

-- Your total luck: (1 + ad stacks x PerAd) x (2 with the x2 Luck pass).
function Config.LuckMult(hasPass: boolean?, adStacks: number?): number
	local ads = math.clamp(math.floor(tonumber(adStacks) or 0), 0, Config.RankRoll.AdLuck.MaxAds)
	return (1 + ads * Config.RankRoll.AdLuck.PerAd) * (if hasPass then Config.RankRoll.LuckMult else 1)
end

Config.RankRarities = {
	Common = { Order = 1, Color = Color3.fromRGB(190, 200, 210) },
	Uncommon = { Order = 2, Color = Color3.fromRGB(110, 220, 120) },
	Rare = { Order = 3, Color = Color3.fromRGB(80, 170, 255) },
	Epic = { Order = 4, Color = Color3.fromRGB(190, 110, 255) },
	Legendary = { Order = 5, Color = Color3.fromRGB(255, 190, 40) },
	Mythic = { Order = 6, Color = Color3.fromRGB(255, 80, 120) },
}

-- Chance is out of 100 (they add up to 100). Effects:
--   PowerAll   +x scrub power with every tool     ToolPower  { [toolId] = +x } for one tool
--   Coins      +x coins from the drain            Tank       +x tank size
--   Speed      +x walk speed (studs/s)            Golden     +x golden dirt chance (x times as much)
Config.Ranks = {
	{ Id = "Rinser", Name = "Rinser", Icon = "💧", Rarity = "Common", Chance = 24, Desc = "+10% coins", Effects = { Coins = 0.10 } },
	{ Id = "DishHand", Name = "Dish Hand", Icon = "🍽️", Rarity = "Common", Chance = 22, Desc = "+15% tank size", Effects = { Tank = 0.15 } },
	{ Id = "SpongeMaster", Name = "Sponge Master", Icon = "🧽", Rarity = "Uncommon", Chance = 10, Desc = "Sponge cleans 60% faster", Effects = { ToolPower = { Sponge = 0.6 } } },
	{ Id = "FoamFanatic", Name = "Foam Fanatic", Icon = "🌊", Rarity = "Uncommon", Chance = 10, Desc = "Foam Cannon cleans 60% faster", Effects = { ToolPower = { Cannon = 0.6 } } },
	{ Id = "Speedy", Name = "Speedy Sudser", Icon = "👟", Rarity = "Uncommon", Chance = 9, Desc = "+4 walk speed", Effects = { Speed = 4 } },
	{ Id = "SpraySniper", Name = "Spray Sniper", Icon = "🚿", Rarity = "Rare", Chance = 8, Desc = "Nozzle and Washer clean 50% faster", Effects = { ToolPower = { Nozzle = 0.5, Washer = 0.5 } } },
	{ Id = "TankTitan", Name = "Tank Titan", Icon = "🛢️", Rarity = "Rare", Chance = 7, Desc = "+50% tank size, +10% coins", Effects = { Tank = 0.5, Coins = 0.1 } },
	{ Id = "ScrubMaster", Name = "Scrub Master", Icon = "💪", Rarity = "Epic", Chance = 3.5, Desc = "Every tool cleans 25% faster", Effects = { PowerAll = 0.25 } },
	{ Id = "GoldDigger", Name = "Gold Digger", Icon = "✨", Rarity = "Epic", Chance = 3.5, Desc = "Twice the golden dirt, +15% coins", Effects = { Golden = 1, Coins = 0.15 } },
	{ Id = "SudsLegend", Name = "Suds Legend", Icon = "🏆", Rarity = "Legendary", Chance = 2.5, Desc = "Every tool 40% faster, +25% coins", Effects = { PowerAll = 0.4, Coins = 0.25 } },
	{ Id = "Deity", Name = "Dishwasher Deity", Icon = "👑", Rarity = "Mythic", Chance = 0.5, Desc = "Every tool 75% faster, +50% coins, +50% tank", Effects = { PowerAll = 0.75, Coins = 0.5, Tank = 0.5 } },
}

function Config.GetRank(rankId: string?)
	if not rankId then
		return nil
	end
	for _, r in Config.Ranks do
		if r.Id == rankId then
			return r
		end
	end
	return nil
end

-- Roll weights, with the x2 Luck pass applied. Returns { { Rank = def, Weight = n } }, total.
-- With x2 Luck, Rare and better are truly LuckMult times as likely (Mythic 0.5% -> 1%): the
-- extra chance is taken from Common and Uncommon, so the total stays the same.
-- `luck`: true = the x2 Luck pass alone, or a number (Config.LuckMult). Rare and better are that
-- many times as likely, capped so Common / Uncommon never go below zero.
function Config.RankWeights(luck: (boolean | number)?)
	local list, total = {}, 0
	local boosted, rest = 0, 0
	for _, r in Config.Ranks do
		if Config.RankRarities[r.Rarity].Order >= 3 then
			boosted += r.Chance
		else
			rest += r.Chance
		end
	end
	local mult = if luck == true then Config.RankRoll.LuckMult elseif type(luck) == "number" then luck else 1
	mult = math.clamp(mult, 1, (boosted + rest) / math.max(boosted, 0.0001))
	local doubleLuck = mult > 1
	local restScale = 1
	if doubleLuck and rest > 0 then
		restScale = math.max(0, (boosted + rest - boosted * mult) / rest)
	end
	for _, r in Config.Ranks do
		local w = r.Chance
		if doubleLuck then
			w *= if Config.RankRarities[r.Rarity].Order >= 3 then mult else restScale
		end
		table.insert(list, { Rank = r, Weight = w })
		total += w
	end
	return list, total
end

----------------------------------------------------------------------------------------------------
-- Sounds. The rbxassetid ones are free Creator Store sounds (Roblox / ProSoundEffects). If one ever
-- fails to load, swap it here; Fallback ships inside every Roblox client.
----------------------------------------------------------------------------------------------------
Config.Sounds = {
	Click = { Id = "rbxassetid://9119717523", Volume = 0.5 },
	Scrub = { Id = "rbxassetid://9125409840", Volume = 0.35 },
	Pop = { Id = "rbxassetid://9113537815", Volume = 0.5 },
	Sell = { Id = "rbxassetid://9125498766", Volume = 0.6 },
	Coins = { Id = "rbxassetid://127645268874265", Volume = 0.5 },
	Sparkle = { Id = "rbxassetid://9126073001", Volume = 0.5 },
	Splash = { Id = "rbxassetid://9120585252", Volume = 0.5 },
	Hatch = { Id = "rbxassetid://9113263649", Volume = 0.6 },
	Error = { Id = "rbxassetid://9113649171", Volume = 0.4 },
	Fallback = { Id = "rbxasset://sounds/impact_water.mp3", Volume = 0.4 },
}

----------------------------------------------------------------------------------------------------
-- Helpers (pure functions, safe on client and server)
----------------------------------------------------------------------------------------------------

-- Round to 2 significant figures so prices look clean (1234 -> 1200, 56 -> 56).
function Config.Round2(n: number): number
	if n < 100 then
		return math.floor(n + 0.5)
	end
	local digits = math.floor(math.log10(n)) + 1
	local factor = 10 ^ (digits - 2)
	return math.floor(n / factor + 0.5) * factor
end

function Config.GetLevel(levelIndex: number)
	return Config.Levels[levelIndex] or Config.Levels[1]
end

function Config.GetUpgrade(upgradeId: string)
	for _, u in Config.Upgrades do
		if u.Id == upgradeId then
			return u
		end
	end
	return nil
end

function Config.GetPerk(perkId: string)
	for _, p in Config.Perks do
		if p.Id == perkId then
			return p
		end
	end
	return nil
end

function Config.GetEgg(eggId: string)
	for _, e in Config.Eggs do
		if e.Id == eggId then
			return e
		end
	end
	return nil
end

function Config.GetPass(key: string)
	for _, p in Config.GamePasses do
		if p.Key == key then
			return p
		end
	end
	return nil
end

-- Coin price of the next level of an in-run upgrade, or nil when maxed.
-- toolIndex matters for PerTool upgrades (better tools cost more to upgrade).
function Config.UpgradeCost(upgradeId: string, currentLevel: number, levelIndex: number, toolIndex: number?): number?
	local u = Config.GetUpgrade(upgradeId)
	if not u or currentLevel >= u.Max then
		return nil
	end
	local toolMult = 1
	if u.PerTool then
		local tool = Config.Tools[toolIndex or 1]
		toolMult = (tool and tool.UpgradeMult) or 1
	end
	return Config.Round2(u.Base * (u.Growth ^ currentLevel) * Config.GetLevel(levelIndex).Mult * toolMult)
end

-- Coin price of a tool in a run.
function Config.ToolCost(toolIndex: number, levelIndex: number): number?
	local t = Config.Tools[toolIndex]
	if not t then
		return nil
	end
	return Config.Round2(t.Cost * Config.GetLevel(levelIndex).Mult)
end

-- Bubble price of the next level of a perk, or nil when maxed.
function Config.PerkCost(perkId: string, currentLevel: number): number?
	local p = Config.GetPerk(perkId)
	if not p or currentLevel >= p.Max then
		return nil
	end
	if p.Costs then
		return p.Costs[currentLevel + 1]
	end
	return Config.Round2(p.Base * (p.Growth ^ currentLevel))
end

-- Sum of CoinBonus over equipped pets. pets = profile.Pets ({ {Uid, Id} }), equipped = { uid, ... }.
-- Pet tiers: merging three of the same pet (same tier) makes one of the next tier. A Golden pet
-- beats normal ones of its kind but not the next egg's pets.
Config.PetTiers = {
	{ Name = "", Mult = 1 },
	{ Name = "Golden", Mult = 1.35, Color = Color3.fromRGB(255, 205, 60) },
	{ Name = "Rainbow", Mult = 1.75, Color = Color3.fromRGB(255, 120, 220) },
}

function Config.PetTier(tier: number?)
	return Config.PetTiers[math.clamp(math.floor(tonumber(tier) or 1), 1, #Config.PetTiers)]
end

-- A pet's stats at a tier: Speed (share of your pet power it cleans per second), Capacity (dirt
-- units its bag holds before it flies to the drain to sell, x the level multiplier in a run) and
-- CoinBonus (added to your coin multiplier while it's out).
function Config.PetStats(petId: string, tier: number?)
	local def = Config.Pets[petId]
	if not def then
		return nil
	end
	local mult = Config.PetTier(tier).Mult
	return { Speed = def.PowerShare * mult, Capacity = math.floor((def.Capacity or 12) * mult + 0.5), CoinBonus = def.CoinBonus * mult }
end

-- Kept for older callers: a pet's raw speed x100.
function Config.PetPower(petId: string, tier: number?): number
	local stats = Config.PetStats(petId, tier)
	return if stats then math.floor(stats.Speed * 100 + 0.5) else 0
end

-- What the pets menu shows. Cleaning speed out of 100, where 100 is the best pet there is (a
-- Rainbow one of the fastest pet), so players can compare at a glance.
local bestPetSpeed = 0
function Config.PetSpeedRating(petId: string, tier: number?): number
	if bestPetSpeed == 0 then
		for id in Config.Pets do
			local top = Config.PetStats(id, #Config.PetTiers)
			bestPetSpeed = math.max(bestPetSpeed, if top then top.Speed else 0)
		end
	end
	local stats = Config.PetStats(petId, tier)
	if not stats or bestPetSpeed <= 0 then
		return 0
	end
	return math.clamp(math.floor(stats.Speed / bestPetSpeed * 100 + 0.5), 1, 100)
end

-- A pet's coin multiplier while it's out ("x1.06"). Equipped pets add up: three x1.06 pets = x1.18.
function Config.PetCoinMult(petId: string, tier: number?): number
	local stats = Config.PetStats(petId, tier)
	return 1 + (if stats then stats.CoinBonus else 0)
end

function Config.PetCoinBonus(pets, equipped): number
	local byUid = {}
	for _, pet in pets or {} do
		byUid[pet.Uid] = pet
	end
	local total = 0
	for _, uid in equipped or {} do
		local pet = byUid[uid]
		local stats = pet and Config.PetStats(pet.Id, pet.Tier)
		if stats then
			total += stats.CoinBonus
		end
	end
	return total
end

--[[
	All stats a player has inside a run.
	  levelIndex : which dishwasher
	  upgrades   : { HandSize = n, ScrubPower = n, TankSize = n, Sneakers = n }
	  toolIndex  : index into Config.Tools
	  perks      : { HeadStart = n, CoinSoap = n, DeepTank = n, ... } (from the profile)
	  passes     : { DoubleCoins = bool, MegaTank = bool, ... }
	  petCoinBonus : Config.PetCoinBonus(...)
]]
function Config.GetRunStats(levelIndex: number, upgrades, toolIndex: number, perks, passes, petCoinBonus: number?, rankId: string?, rebirths: number?)
	local level = Config.GetLevel(levelIndex)
	local tool = Config.Tools[toolIndex] or Config.Tools[1]
	upgrades = upgrades or {}
	perks = perks or {}
	passes = passes or {}
	local b = Config.Base

	local radius = (b.Radius + b.RadiusPerLevel * (upgrades.HandSize or 0)) * tool.Radius
	local power = b.Power * (b.PowerGrowth ^ (upgrades.ScrubPower or 0)) * tool.Power * level.Mult
	if passes.SuperScrub then
		power *= 1.5
	end
	local rank = Config.GetRank(rankId)
	local fx = (rank and rank.Effects) or {}
	power *= 1 + (fx.PowerAll or 0) + ((fx.ToolPower and fx.ToolPower[tool.Id]) or 0)
	local tank = b.Tank * (b.TankGrowth ^ (upgrades.TankSize or 0)) * level.Mult
	tank *= 1 + (perks.DeepTank or 0) * Config.GetPerk("DeepTank").PerLevel
	if passes.MegaTank then
		tank *= 2
	end
	tank *= 1 + (fx.Tank or 0)
	local coinMult = Config.Round.CoinsPerUnit * (1 + (perks.CoinSoap or 0) * Config.GetPerk("CoinSoap").PerLevel + (petCoinBonus or 0))
	if passes.DoubleCoins then
		coinMult *= 2
	end
	if passes.VIP then
		coinMult *= 1.25
	end
	coinMult *= 1 + (fx.Coins or 0)
	coinMult *= Config.RebirthCoinMult(rebirths)

	local mode = tool.Mode or "Scrub"
	return {
		Radius = radius,
		Power = power,
		TankMax = math.floor(tank),
		Reach = tool.Reach,
		Mode = mode,
		-- Pets clean off this, not Power, so which tool you hold doesn't change them (the washer's
		-- high Power pays for its thin line; pets shouldn't get it free). Sponge-level strength.
		PetPower = power / (tool.Power or 1) * 2.5,
		-- Line: length grows with the Size upgrade (Radius), width is fixed.
		LineLength = if mode == "Line" then radius * (tool.LineLength or 3.5) else nil,
		LineWidth = if mode == "Line" then tool.LineWidth or 0.9 else nil,
		FoamInterval = if mode == "Foam" then tool.FoamInterval or 0.4 else nil,
		FoamSeconds = if mode == "Foam" then tool.FoamSeconds or 2.5 else nil,
		FoamShare = if mode == "Foam" then tool.FoamShare or 0.6 else nil,
		WalkSpeed = b.WalkSpeed + b.WalkSpeedPerLevel * (upgrades.Sneakers or 0) + (fx.Speed or 0),
		Hold = true, -- holding always scrubs (the old "Hold to Scrub" upgrade confused new players)
		CoinMult = coinMult,
		ToolIndex = toolIndex,
		Tier = tool.Tier or toolIndex,
	}
end

-- Coins a run starts with (Head Start perk).
function Config.StartCoins(levelIndex: number, perks): number
	local lvl = (perks and perks.HeadStart) or 0
	local level = Config.GetLevel(levelIndex) :: any
	return math.floor(lvl * Config.GetPerk("HeadStart").PerLevel * level.Mult) + (tonumber(level.StartCoins) or 0)
end

-- Daily rewards: claimed from the 🎁 Daily button. The next one unlocks 24 hours after you claim
-- (Cooldown). Claim it within Grace after that and the streak moves on; later and it starts again
-- at day 1, unless you buy "Restore Streak" (Config.DevProducts). Day 7 is the big one, then it loops.
Config.Daily = {
	Cooldown = 24 * 60 * 60,
	Grace = 24 * 60 * 60,
}
Config.DailyRewards = {
	{ Kind = "Bubbles", Amount = 60 },
	{ Kind = "Bubbles", Amount = 120 },
	{ Kind = "Gems", Amount = 5 },
	{ Kind = "Bubbles", Amount = 250 },
	{ Kind = "Gems", Amount = 10 },
	{ Kind = "Bubbles", Amount = 500 },
	{ Kind = "Gems", Amount = 30 },
}

-- Rebirth (the endgame loop): after clearing the last dishwasher, trade your Bubbles, unlocked levels
-- and perks for a permanent bonus. Pets, gems, ranks, passes and best times are kept.
Config.Rebirth = {
	BaseCost = 2500, -- Bubbles for the first rebirth (a Royal Banquet clear pays ~700, plus lobby bubbles)
	CostStep = 2500, -- each rebirth after that costs this much more...
	MaxCost = 20000, -- ...until it levels off here (from the 8th rebirth on, every rebirth costs this)
	CoinsPer = 0.25, -- +25% coins per rebirth (they stack: 4 rebirths = +100%)
	BubblesPer = 0.5, -- +50% Bubbles per rebirth
	Gems = 50, -- gems for the first rebirth...
	GemsStep = 10, -- ...and this many more for each one after it...
	MaxGems = 250, -- ...up to this
}

-- Bubbles needed for the next rebirth when you have `rebirths` already:
-- 2,500 / 5,000 / 7,500 / ... / 17,500 / then 20,000 every time.
function Config.RebirthCost(rebirths: number): number
	local rb = Config.Rebirth
	return math.min(rb.BaseCost + rb.CostStep * (rebirths or 0), rb.MaxCost)
end

-- Gems paid for reaching rebirth number `n` (1 = the first): 50, 60, 70 ... up to 250.
function Config.RebirthGems(n: number): number
	local rb = Config.Rebirth
	return math.min(rb.Gems + rb.GemsStep * math.max((n or 1) - 1, 0), rb.MaxGems)
end

function Config.RebirthCoinMult(rebirths: number?): number
	return 1 + Config.Rebirth.CoinsPer * (rebirths or 0)
end

function Config.RebirthBubbleMult(rebirths: number?): number
	return 1 + Config.Rebirth.BubblesPer * (rebirths or 0)
end

-- Equip slots for pets: 3, or 5 with the +2 Pet Slots pass.
function Config.PetSlots(_perks, passes): number
	local slots = Config.PetRules.BaseSlots
	if passes and passes.PetSlots then
		slots += 2
	end
	return slots
end

-- Sanity checks that run once when the module is first required (catches typos in the tables above).
do
	for _, level in Config.Levels do
		for _, g in level.Grime do
			assert(Config.GrimeTypes[g.Type], "Config: level " .. level.Name .. " uses unknown grime " .. g.Type)
		end
		for _, kind in Config.DishKinds do
			assert(level.Dishes[kind] ~= nil and level.Spots[kind] ~= nil, "Config: level " .. level.Name .. " missing dish kind " .. kind)
		end
	end
	for _, egg in Config.Eggs do
		local sum = 0
		for _, entry in egg.Pets do
			assert(Config.Pets[entry.Pet], "Config: egg " .. egg.Id .. " has unknown pet " .. entry.Pet)
			sum += entry.Chance
		end
		assert(math.abs(sum - 100) < 0.001, "Config: egg " .. egg.Id .. " chances add to " .. sum)
	end
	for id, pet in Config.Pets do
		assert(Config.Rarities[pet.Rarity], "Config: pet " .. id .. " has unknown rarity")
	end
	local rankSum = 0
	for _, r in Config.Ranks do
		assert(Config.RankRarities[r.Rarity], "Config: rank " .. r.Id .. " has unknown rarity")
		rankSum += r.Chance
	end
	assert(math.abs(rankSum - 100) < 0.001, "Config: rank chances add to " .. rankSum)
end

----------------------------------------------------------------------------------------------------
-- Codes (🎟️ Codes button). Key = the code in CAPITALS (players can type any case); each player can
-- use each code once. Give Bubbles and/or Gems; Expires (optional) is an os.time() after which it
-- stops working. Add new ones here and announce them in the game's description.
----------------------------------------------------------------------------------------------------
Config.Codes = {
	RELEASE = { Bubbles = 300, Gems = 10 },
	SQUEAKY = { Bubbles = 150 },
	BUBBLES = { Gems = 15 },
} :: { [string]: { Bubbles: number?, Gems: number?, Expires: number? } }

----------------------------------------------------------------------------------------------------
-- Lobby fun (LobbyFun service): poppable soap bubbles float over the plaza (+1 Bubble each, a rare
-- golden one pays more), and rubber ducks are hidden around the lobby. Each duck pays once; finding
-- them all pays the big reward.
----------------------------------------------------------------------------------------------------
Config.LobbyBubbles = {
	Max = 14, -- alive at once
	Reward = 1,
	GoldenReward = 10,
	GoldenChance = 0.06,
	RespawnDelay = { 2, 6 }, -- seconds before a popped bubble comes back somewhere else
	PerMinute = 60, -- per-player pop cap (anti autoclicker)
}

Config.Ducks = {
	List = {
		{ Id = "Fountain", Hint = "Having a swim" },
		{ Id = "Doghouse", Hint = "Guarding the pets" },
		{ Id = "Sponge", Hint = "Sunbathing on something soft" },
		{ Id = "Board", Hint = "Hiding behind the scores" },
		{ Id = "Shakers", Hint = "Up on the roof" },
		{ Id = "Saucer", Hint = "Coffee break" },
	},
	Reward = { Bubbles = 25, Gems = 0 }, -- each duck
	AllReward = { Bubbles = 500, Gems = 10 }, -- finding every duck
}

-- "300 Bubbles + 10 Gems"
function Config.RewardText(reward: { Bubbles: number?, Gems: number? }): string
	local bits = {}
	if reward.Bubbles and reward.Bubbles > 0 then
		table.insert(bits, reward.Bubbles .. " Bubbles")
	end
	if reward.Gems and reward.Gems > 0 then
		table.insert(bits, reward.Gems .. (if reward.Gems == 1 then " Gem" else " Gems"))
	end
	return table.concat(bits, " + ")
end

----------------------------------------------------------------------------------------------------
-- Free Rewards (🎉 button), each once per player:
--   * Join the community: checked in game right after Roblox's join prompt closes (no rejoin).
--     GroupId 0 = the group that owns the game (set a number to use a different one).
--   * Follow the dev (CreatorUserId): press "I followed!", then rejoin. On join the server reads
--     the player's public "following" list through ProxyDomain (Roblox blocks games from calling
--     roblox.com directly) and pays out if the dev is on it. Needs Game Settings -> Security ->
--     "Allow HTTP Requests" ON.
--   * Like the game: press "I liked it!", then rejoin. Roblox gives games NO way to see likes, so
--     this one can't be checked: it's paid on trust. (Roblox's rules discourage rewarding likes;
--     set LikeReward to nil to hide the card.)
----------------------------------------------------------------------------------------------------
Config.Social = {
	GroupId = 920260021, -- the Rinse Cycle community
	CreatorUserId = 2297538363,
	ProxyDomain = "roproxy.com",
	GroupReward = { Bubbles = 500, Gems = 25 },
	FollowReward = { Bubbles = 300, Gems = 15 },
	LikeReward = { Bubbles = 300, Gems = 15 } :: { Bubbles: number?, Gems: number? }?,
	-- Referrals: invite a friend (Roblox's invite prompt carries your UserId as launch data). When
	-- someone NEW joins through it, you get ReferralReward and they get ReferredReward. Up to
	-- MaxReferrals friends pay out per player.
	ReferralReward = { Bubbles = 300, Gems = 20 },
	ReferredReward = { Bubbles = 200, Gems = 10 },
	MaxReferrals = 50,
}

function Config.GetGroupId(): number
	if Config.Social.GroupId > 0 then
		return Config.Social.GroupId
	end
	local ok, id = pcall(function()
		return if game.CreatorType == Enum.CreatorType.Group then game.CreatorId else 0
	end)
	return if ok and type(id) == "number" then id else 0
end

-- Background music (MusicPlayer). The track IDs go in StoreIds > Music.
Config.Music = {
	Lobby = {} :: { number },
	Run = {} :: { number },
	Volume = 0.3,
}

-- Gifting a game pass: Roblox can't sell a pass to one player for another, so every pass has a
-- matching developer product ("Gift: VIP", same price). Buying it gives the pass to the friend you
-- picked (GiftService). The Ids go in StoreIds, under GiftPasses.
Config.GiftProducts = {}
for _, pass in Config.GamePasses do
	table.insert(Config.GiftProducts, {
		Key = pass.Key, -- the pass it gifts
		Id = 0,
		Price = pass.Price,
		Name = "Gift: " .. pass.Name,
		Icon = pass.Icon,
	})
end

function Config.GetGiftProduct(passKey: string)
	for _, g in Config.GiftProducts do
		if g.Key == passKey then
			return g
		end
	end
	return nil
end

-- Event developer products (StoreIds > Events): Treasure Chest packs and the luck ad reward.
Config.EventProducts = { ChestOne = 0, ChestThree = 0, ChestTen = 0, AdLuck = 0 }

-- The IDs pasted into StoreIds (ReplicatedStorage > Shared > StoreIds), the one script to edit
-- once the passes and products exist on Roblox. A number there replaces the matching Id here.
do
	local ok, ids = pcall(function()
		return require(script.Parent:WaitForChild("StoreIds", 5) :: any)
	end)
	if ok and type(ids) == "table" then
		local function apply(list: { any }, source: any)
			if type(source) ~= "table" then
				return
			end
			for _, item in list do
				local id = tonumber(source[item.Key])
				if id and id > 0 then
					item.Id = math.floor(id)
				end
			end
		end
		apply(Config.GamePasses, ids.GamePasses)
		apply(Config.DevProducts, ids.DevProducts)
		apply(Config.GiftProducts, ids.GiftPasses)
		if type(ids.Music) == "table" then
			for _, key in { "Lobby", "Run" } do
				local list = {}
				for _, id in (if type(ids.Music[key]) == "table" then ids.Music[key] else {}) do
					local n = tonumber(id)
					if n and n > 0 then
						table.insert(list, math.floor(n))
					end
				end
				Config.Music[key] = list
			end
		end
		if type(ids.Events) == "table" then
			for key in Config.EventProducts do
				local n = tonumber(ids.Events[key])
				if n and n > 0 then
					Config.EventProducts[key] = math.floor(n)
				end
			end
		end
		local group = tonumber(ids.GroupId)
		if group and group > 0 then
			Config.Social.GroupId = math.floor(group)
		end
	end
end

return Config
