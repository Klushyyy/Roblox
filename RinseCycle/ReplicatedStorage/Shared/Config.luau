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
Config.Version = "0.2.0"

----------------------------------------------------------------------------------------------------
-- World
----------------------------------------------------------------------------------------------------
Config.World = {
	LobbyOrigin = Vector3.new(0, 0, 0),
	-- Arena slot k is built at ArenaRowStart + (k - 1) * ArenaSpacing. Kept within ~5,000 studs of the
	-- origin (float precision) and far enough apart that parties never see each other.
	ArenaRowStart = Vector3.new(-3500, 0, 3000),
	ArenaSpacing = Vector3.new(1000, 0, 0),
	MaxArenas = 8,
	LobbyWalkSpeed = 22, -- the lobby is small; this keeps walking between pads and shops snappy
}

----------------------------------------------------------------------------------------------------
-- Party pads (lobby)
----------------------------------------------------------------------------------------------------
Config.Party = {
	PadCount = 6,
	MaxPlayers = 4,
	Countdown = 15, -- seconds from when the host presses Create until the party teleports
	LockSeconds = 1.5, -- joins and leaves are refused this close to launch
	RejoinCooldown = 3, -- seconds before a player who left/was ejected can re-enter a pad
	PollInterval = 0.2,
}

----------------------------------------------------------------------------------------------------
-- Runs (inside the dishwasher)
----------------------------------------------------------------------------------------------------
Config.Round = {
	ResultsSeconds = 20, -- results screen time before everyone is sent back to the lobby
	ScrubSendInterval = 0.1, -- client send rate while holding spray
	ClickPulseSeconds = 0.25, -- a single tap (not held) deals this many seconds of power
	MinClickInterval = 0.11, -- server ignores clicks faster than this (about 9 per second)
	MaxScrubDt = 0.25, -- cap on the damage window of a single held scrub packet
	ReachSlack = 6, -- extra studs the server allows over reach (latency)
	DrainRadius = 8,
	PartyGrimeScale = 0.6, -- total grime = base * (1 + 0.6 * (players - 1))
	MarkerThreshold = 12, -- clients mark every remaining spot when this few are left
	StuckSeconds = 60, -- if nobody damages anything for this long...
	StuckMaxRemaining = 3, -- ...and this few spots are left, they pop on their own
	DishBonusShare = 0.25, -- cleaning the last spot on a dish pays 25% of the dish's units as coins
	GoldenUnitsMult = 5,
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
	PowerGrowth = 1.3, -- per Scrub Power level
	Tank = 15, -- units
	TankGrowth = 1.35, -- per Tank Size level
	WalkSpeed = 20,
	WalkSpeedPerLevel = 1.5,
}

-- In-run upgrades bought with Coins. Price = Base * Growth^level * level Mult (2 significant figures).
Config.Upgrades = {
	{ Id = "HandSize", Name = "Hand Size", Icon = "🖐️", Desc = "Clean a bigger area.", Base = 8, Growth = 1.55, Max = 12 },
	{ Id = "ScrubPower", Name = "Scrub Power", Icon = "💪", Desc = "Dirt comes off faster.", Base = 6, Growth = 1.5, Max = 15 },
	{ Id = "TankSize", Name = "Tank Size", Icon = "🛢️", Desc = "Carry more dirt per trip.", Base = 5, Growth = 1.5, Max = 15 },
	{ Id = "Sneakers", Name = "Sneakers", Icon = "👟", Desc = "Run to the drain faster.", Base = 10, Growth = 1.6, Max = 8 },
}

-- Tools, bought in order with Coins inside a run (the "rake" tier). Cost is times level Mult.
-- Radius and Power multiply the upgraded base stats. Reach is in studs from your character.
Config.Tools = {
	{ Id = "Hands", Name = "Bare Hands", Icon = "🖐️", Cost = 0, Radius = 1.0, Power = 1.0, Reach = 16, Color = Color3.fromRGB(150, 210, 255), Desc = "Just you and some water." },
	{ Id = "Sponge", Name = "Sponge", Icon = "🧽", Cost = 50, Radius = 1.3, Power = 2.0, Reach = 17, Color = Color3.fromRGB(255, 221, 87), Desc = "Soft, squishy, twice as strong." },
	{ Id = "Brush", Name = "Scrub Brush", Icon = "🧹", Cost = 200, Radius = 1.5, Power = 3.5, Reach = 18, Color = Color3.fromRGB(120, 230, 160), Desc = "Bristles for burnt-on bits." },
	{ Id = "Nozzle", Name = "Spray Nozzle", Icon = "🚿", Cost = 700, Radius = 1.8, Power = 6.0, Reach = 26, Color = Color3.fromRGB(90, 200, 255), Desc = "Clean from a distance." },
	{ Id = "Washer", Name = "Pressure Washer", Icon = "💦", Cost = 2500, Radius = 2.2, Power = 10.0, Reach = 34, Color = Color3.fromRGB(60, 140, 255), Desc = "Blasts through anything." },
	{ Id = "Cannon", Name = "Foam Cannon", Icon = "🌊", Cost = 9000, Radius = 2.8, Power = 16.0, Reach = 42, Color = Color3.fromRGB(200, 150, 255), Desc = "A tidal wave of suds." },
}

----------------------------------------------------------------------------------------------------
-- Grime. HP and Units are multiplied by the level Mult. MinTool = lowest tool index that can clean it.
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
	Char = { Name = "Char", HP = 16, Units = 4, Color = Color3.fromRGB(30, 26, 24), Material = Enum.Material.Basalt, Size = { 1.2, 2.0 }, Shape = "Crumbs", MinTool = 3 },

	Frosting = { Name = "Frosting", HP = 8, Units = 3, Color = Color3.fromRGB(255, 150, 200), Material = Enum.Material.SmoothPlastic, Size = { 1.4, 2.4 }, Shape = "Blob", MinTool = 1 },
	Sprinkles = { Name = "Sprinkles", HP = 3, Units = 1, Color = Color3.fromRGB(255, 255, 255), Material = Enum.Material.SmoothPlastic, Size = { 1.0, 1.6 }, Shape = "Sprinkles", MinTool = 1 },
	Chocolate = { Name = "Chocolate", HP = 11, Units = 3, Color = Color3.fromRGB(80, 45, 25), Material = Enum.Material.SmoothPlastic, Size = { 1.4, 2.4 }, Shape = "Blob", MinTool = 1 },
	BurntSugar = { Name = "Burnt Sugar", HP = 18, Units = 5, Color = Color3.fromRGB(120, 60, 10), Material = Enum.Material.Glass, Size = { 1.0, 1.8 }, Shape = "Crumbs", MinTool = 3 },

	TruffleGunk = { Name = "Truffle Gunk", HP = 10, Units = 3, Color = Color3.fromRGB(70, 60, 50), Material = Enum.Material.Mud, Size = { 1.4, 2.4 }, Shape = "Blob", MinTool = 1 },
	CaviarSmear = { Name = "Caviar Smear", HP = 8, Units = 3, Color = Color3.fromRGB(25, 25, 35), Material = Enum.Material.Pebble, Size = { 1.2, 2.0 }, Shape = "Crumbs", MinTool = 1 },
	AncientGravy = { Name = "Ancient Gravy", HP = 22, Units = 6, Color = Color3.fromRGB(90, 110, 50), Material = Enum.Material.Mud, Size = { 1.6, 2.6 }, Shape = "Streak", MinTool = 4 },
}

----------------------------------------------------------------------------------------------------
-- Levels (dishwashers). Dishes = how many of each kind are in the load.
-- Spots = base grime spots per dish of that kind (solo), before PartyGrimeScale.
-- Theme colours are used by the arena and dish builders.
----------------------------------------------------------------------------------------------------
Config.DishKinds = { "Plate", "Bowl", "Cup", "Glass", "Fork", "Knife", "Spoon", "Pan", "Pot" }

Config.Levels = {
	{
		Id = 1,
		Name = "Family Dinner",
		Subtitle = "Crumbs, ketchup and a whole lot of gravy.",
		Icon = "🍝",
		Mult = 1,
		ParTime = 300,
		Bubbles = 40,
		GoldenChance = 0.02,
		Dishes = { Plate = 14, Bowl = 5, Cup = 5, Glass = 0, Fork = 4, Knife = 3, Spoon = 3, Pan = 0, Pot = 0 },
		Spots = { Plate = 6, Bowl = 6, Cup = 4, Glass = 3, Fork = 2, Knife = 2, Spoon = 2, Pan = 14, Pot = 16 },
		Grime = { { Type = "Crumbs", Weight = 45 }, { Type = "Ketchup", Weight = 35 }, { Type = "Gravy", Weight = 20 } },
		Theme = {
			Tub = Color3.fromRGB(205, 211, 218),
			Rack = Color3.fromRGB(235, 240, 245),
			Accent = Color3.fromRGB(80, 170, 255),
			Plate = Color3.fromRGB(250, 250, 248),
			PlateRim = Color3.fromRGB(120, 175, 230),
			Bowl = Color3.fromRGB(150, 200, 240),
			Cup = Color3.fromRGB(255, 180, 120),
			Glass = Color3.fromRGB(200, 235, 255),
			Metal = Color3.fromRGB(190, 195, 200),
			Light = Color3.fromRGB(210, 235, 255),
		},
	},
	{
		Id = 2,
		Name = "Pizza Party",
		Subtitle = "Sauce everywhere. Watch out for burnt crust.",
		Icon = "🍕",
		Mult = 3,
		ParTime = 420,
		Bubbles = 90,
		GoldenChance = 0.02,
		Dishes = { Plate = 16, Bowl = 6, Cup = 6, Glass = 2, Fork = 5, Knife = 4, Spoon = 3, Pan = 1, Pot = 0 },
		Spots = { Plate = 7, Bowl = 7, Cup = 4, Glass = 3, Fork = 2, Knife = 2, Spoon = 2, Pan = 16, Pot = 18 },
		Grime = { { Type = "TomatoSauce", Weight = 40 }, { Type = "MeltedCheese", Weight = 30 }, { Type = "Crumbs", Weight = 15 }, { Type = "BurntCrust", Weight = 15 } },
		Theme = {
			Tub = Color3.fromRGB(200, 205, 210),
			Rack = Color3.fromRGB(230, 90, 70),
			Accent = Color3.fromRGB(255, 120, 60),
			Plate = Color3.fromRGB(255, 250, 240),
			PlateRim = Color3.fromRGB(220, 60, 50),
			Bowl = Color3.fromRGB(255, 230, 190),
			Cup = Color3.fromRGB(120, 200, 120),
			Glass = Color3.fromRGB(210, 240, 255),
			Metal = Color3.fromRGB(185, 190, 195),
			Light = Color3.fromRGB(255, 225, 190),
		},
	},
	{
		Id = 3,
		Name = "Burger Diner",
		Subtitle = "Grease, mustard, and char that needs a brush.",
		Icon = "🍔",
		Mult = 10,
		ParTime = 540,
		Bubbles = 200,
		GoldenChance = 0.025,
		Dishes = { Plate = 18, Bowl = 6, Cup = 6, Glass = 4, Fork = 5, Knife = 5, Spoon = 4, Pan = 2, Pot = 0 },
		Spots = { Plate = 8, Bowl = 8, Cup = 5, Glass = 3, Fork = 2, Knife = 2, Spoon = 2, Pan = 18, Pot = 20 },
		Grime = { { Type = "Grease", Weight = 35 }, { Type = "Mustard", Weight = 25 }, { Type = "Ketchup", Weight = 25 }, { Type = "Char", Weight = 15 } },
		Theme = {
			Tub = Color3.fromRGB(190, 196, 202),
			Rack = Color3.fromRGB(70, 180, 190),
			Accent = Color3.fromRGB(255, 80, 90),
			Plate = Color3.fromRGB(252, 250, 245),
			PlateRim = Color3.fromRGB(230, 50, 60),
			Bowl = Color3.fromRGB(255, 235, 150),
			Cup = Color3.fromRGB(230, 60, 70),
			Glass = Color3.fromRGB(220, 245, 255),
			Metal = Color3.fromRGB(175, 180, 185),
			Light = Color3.fromRGB(255, 240, 210),
		},
	},
	{
		Id = 4,
		Name = "Birthday Bash",
		Subtitle = "Frosting, sprinkles and stubborn burnt sugar.",
		Icon = "🎂",
		Mult = 40,
		ParTime = 660,
		Bubbles = 450,
		GoldenChance = 0.03,
		Dishes = { Plate = 20, Bowl = 8, Cup = 8, Glass = 4, Fork = 6, Knife = 5, Spoon = 5, Pan = 0, Pot = 2 },
		Spots = { Plate = 9, Bowl = 8, Cup = 5, Glass = 4, Fork = 2, Knife = 2, Spoon = 2, Pan = 18, Pot = 20 },
		Grime = { { Type = "Frosting", Weight = 35 }, { Type = "Sprinkles", Weight = 25 }, { Type = "Chocolate", Weight = 25 }, { Type = "BurntSugar", Weight = 15 } },
		Theme = {
			Tub = Color3.fromRGB(215, 205, 225),
			Rack = Color3.fromRGB(255, 150, 210),
			Accent = Color3.fromRGB(170, 110, 255),
			Plate = Color3.fromRGB(255, 252, 255),
			PlateRim = Color3.fromRGB(255, 120, 190),
			Bowl = Color3.fromRGB(180, 230, 255),
			Cup = Color3.fromRGB(255, 220, 120),
			Glass = Color3.fromRGB(235, 220, 255),
			Metal = Color3.fromRGB(195, 190, 205),
			Light = Color3.fromRGB(255, 215, 245),
		},
	},
	{
		Id = 5,
		Name = "Royal Banquet",
		Subtitle = "Gold plates, fancy food and ancient gravy.",
		Icon = "👑",
		Mult = 150,
		ParTime = 840,
		Bubbles = 1000,
		GoldenChance = 0.04,
		Dishes = { Plate = 24, Bowl = 8, Cup = 4, Glass = 8, Fork = 6, Knife = 6, Spoon = 6, Pan = 2, Pot = 2 },
		Spots = { Plate = 10, Bowl = 10, Cup = 5, Glass = 5, Fork = 3, Knife = 3, Spoon = 3, Pan = 20, Pot = 24 },
		Grime = { { Type = "TruffleGunk", Weight = 35 }, { Type = "CaviarSmear", Weight = 30 }, { Type = "Gravy", Weight = 20 }, { Type = "AncientGravy", Weight = 15 } },
		Theme = {
			Tub = Color3.fromRGB(60, 55, 70),
			Rack = Color3.fromRGB(230, 190, 90),
			Accent = Color3.fromRGB(255, 205, 80),
			Plate = Color3.fromRGB(255, 250, 235),
			PlateRim = Color3.fromRGB(230, 185, 70),
			Bowl = Color3.fromRGB(245, 235, 210),
			Cup = Color3.fromRGB(150, 40, 60),
			Glass = Color3.fromRGB(255, 240, 200),
			Metal = Color3.fromRGB(230, 190, 90),
			Light = Color3.fromRGB(255, 225, 160),
		},
	},
}

----------------------------------------------------------------------------------------------------
-- Permanent perks (lobby Soap Shop), bought with Bubbles.
-- Cost = Base * Growth^level (2 significant figures), or Costs[level + 1] when Costs is given.
----------------------------------------------------------------------------------------------------
Config.Perks = {
	{ Id = "HeadStart", Name = "Head Start", Icon = "💰", Desc = "Start every run with +15 coins per level (times the dishwasher's multiplier).", Base = 30, Growth = 1.6, Max = 10, PerLevel = 15 },
	{ Id = "CoinSoap", Name = "Coin Soap", Icon = "💰", Desc = "+10% coins from the drain per level.", Base = 50, Growth = 1.6, Max = 10, PerLevel = 0.10 },
	{ Id = "DeepTank", Name = "Deep Tank", Icon = "🛢️", Desc = "+15% tank size per level.", Base = 40, Growth = 1.6, Max = 10, PerLevel = 0.15 },
	{ Id = "LuckySuds", Name = "Lucky Suds", Icon = "🍀", Desc = "+1% golden dirt per level (best in the party counts).", Base = 60, Growth = 1.8, Max = 5, PerLevel = 0.01 },
	{ Id = "PetSlot", Name = "Pet Slot", Icon = "🐾", Desc = "Equip one more pet.", Costs = { 300, 1500 }, Max = 2, PerLevel = 1 },
}

----------------------------------------------------------------------------------------------------
-- Pets. Pets clean grime near you during runs. Their cleaning speed is PowerShare times YOUR current
-- run power (so they stay useful as you upgrade), and CoinBonus adds to your drain payouts.
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
	Range = 35, -- pets pick grime within this many studs of their owner
	Speed = 40, -- studs per second when flying to a spot (used for the travel delay)
	ThinkInterval = 0.25,
}

Config.Pets = {
	-- Bubble Egg
	RubberDuck = { Name = "Rubber Duck", Rarity = "Common", PowerShare = 0.20, CoinBonus = 0.05, Model = "Duck", Colors = { Body = Color3.fromRGB(255, 220, 60), Accent = Color3.fromRGB(255, 140, 30) } },
	SoapSlime = { Name = "Soap Slime", Rarity = "Uncommon", PowerShare = 0.30, CoinBonus = 0.08, Model = "Slime", Colors = { Body = Color3.fromRGB(150, 230, 255), Accent = Color3.fromRGB(255, 255, 255) } },
	SpongePup = { Name = "Sponge Pup", Rarity = "Rare", PowerShare = 0.45, CoinBonus = 0.12, Model = "Pup", Colors = { Body = Color3.fromRGB(255, 225, 90), Accent = Color3.fromRGB(90, 190, 90) } },
	BubbleFish = { Name = "Bubble Fish", Rarity = "Epic", PowerShare = 0.70, CoinBonus = 0.18, Model = "Fish", Colors = { Body = Color3.fromRGB(120, 180, 255), Accent = Color3.fromRGB(255, 255, 255) } },
	GoldenDuck = { Name = "Golden Duck", Rarity = "Legendary", PowerShare = 1.10, CoinBonus = 0.30, Model = "Duck", Colors = { Body = Color3.fromRGB(255, 200, 40), Accent = Color3.fromRGB(255, 240, 150) }, Shiny = true },
	-- Suds Egg
	ScrubBunny = { Name = "Scrub Bunny", Rarity = "Common", PowerShare = 0.35, CoinBonus = 0.08, Model = "Bunny", Colors = { Body = Color3.fromRGB(245, 245, 250), Accent = Color3.fromRGB(255, 170, 200) } },
	SudsCrab = { Name = "Suds Crab", Rarity = "Uncommon", PowerShare = 0.50, CoinBonus = 0.12, Model = "Crab", Colors = { Body = Color3.fromRGB(255, 110, 90), Accent = Color3.fromRGB(255, 255, 255) } },
	MopCat = { Name = "Mop Cat", Rarity = "Rare", PowerShare = 0.70, CoinBonus = 0.16, Model = "Cat", Colors = { Body = Color3.fromRGB(170, 170, 185), Accent = Color3.fromRGB(240, 240, 240) } },
	OctoScrubber = { Name = "Octo-Scrubber", Rarity = "Epic", PowerShare = 1.00, CoinBonus = 0.24, Model = "Octopus", Colors = { Body = Color3.fromRGB(200, 110, 255), Accent = Color3.fromRGB(255, 200, 255) } },
	RainbowJelly = { Name = "Rainbow Jelly", Rarity = "Legendary", PowerShare = 1.60, CoinBonus = 0.40, Model = "Jelly", Colors = { Body = Color3.fromRGB(255, 120, 200), Accent = Color3.fromRGB(120, 255, 230) }, Shiny = true },
	-- Sparkle Egg
	FoamFox = { Name = "Foam Fox", Rarity = "Common", PowerShare = 0.60, CoinBonus = 0.12, Model = "Fox", Colors = { Body = Color3.fromRGB(255, 150, 70), Accent = Color3.fromRGB(255, 255, 255) } },
	SteamOwl = { Name = "Steam Owl", Rarity = "Uncommon", PowerShare = 0.85, CoinBonus = 0.18, Model = "Owl", Colors = { Body = Color3.fromRGB(150, 130, 110), Accent = Color3.fromRGB(255, 230, 150) } },
	CrystalTurtle = { Name = "Crystal Turtle", Rarity = "Rare", PowerShare = 1.20, CoinBonus = 0.25, Model = "Turtle", Colors = { Body = Color3.fromRGB(120, 230, 200), Accent = Color3.fromRGB(200, 255, 255) } },
	TidalDragon = { Name = "Tidal Dragon", Rarity = "Epic", PowerShare = 1.70, CoinBonus = 0.35, Model = "Dragon", Colors = { Body = Color3.fromRGB(60, 150, 255), Accent = Color3.fromRGB(180, 240, 255) } },
	KrakenKing = { Name = "Kraken King", Rarity = "Legendary", PowerShare = 2.60, CoinBonus = 0.60, Model = "Kraken", Colors = { Body = Color3.fromRGB(120, 40, 160), Accent = Color3.fromRGB(255, 210, 60) }, Shiny = true },
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
		RequiredLevel = 4,
		Color = Color3.fromRGB(255, 220, 90),
		Pets = { { Pet = "FoamFox", Chance = 60 }, { Pet = "SteamOwl", Chance = 25 }, { Pet = "CrystalTurtle", Chance = 11 }, { Pet = "TidalDragon", Chance = 3.5 }, { Pet = "KrakenKing", Chance = 0.5 } },
	},
}

----------------------------------------------------------------------------------------------------
-- Robux. Create the passes on the Creator Dashboard and paste their IDs here.
-- Anything with Id = 0 is hidden from the shop.
----------------------------------------------------------------------------------------------------
Config.GamePasses = {
	{ Key = "DoubleCoins", Id = 0, Name = "2x Coins", Icon = "💰", Desc = "Double coins from the drain in every run." },
	{ Key = "MegaTank", Id = 0, Name = "Mega Tank", Icon = "🛢️", Desc = "Your tank holds twice as much." },
	{ Key = "AutoDrain", Id = 0, Name = "Auto Drain", Icon = "🌀", Desc = "Your tank sells itself the moment it's full." },
	{ Key = "PetSlots", Id = 0, Name = "+2 Pet Slots", Icon = "🐾", Desc = "Equip two more pets." },
	{ Key = "DoubleBubbles", Id = 0, Name = "2x Bubbles", Icon = "🧼", Desc = "Double Bubbles from every finished run." },
}

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
function Config.UpgradeCost(upgradeId: string, currentLevel: number, levelIndex: number): number?
	local u = Config.GetUpgrade(upgradeId)
	if not u or currentLevel >= u.Max then
		return nil
	end
	return Config.Round2(u.Base * (u.Growth ^ currentLevel) * Config.GetLevel(levelIndex).Mult)
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
function Config.PetCoinBonus(pets, equipped): number
	local byUid = {}
	for _, pet in pets or {} do
		byUid[pet.Uid] = pet.Id
	end
	local total = 0
	for _, uid in equipped or {} do
		local def = Config.Pets[byUid[uid] or ""]
		if def then
			total += def.CoinBonus
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
function Config.GetRunStats(levelIndex: number, upgrades, toolIndex: number, perks, passes, petCoinBonus: number?)
	local level = Config.GetLevel(levelIndex)
	local tool = Config.Tools[toolIndex] or Config.Tools[1]
	upgrades = upgrades or {}
	perks = perks or {}
	passes = passes or {}
	local b = Config.Base

	local radius = (b.Radius + b.RadiusPerLevel * (upgrades.HandSize or 0)) * tool.Radius
	local power = b.Power * (b.PowerGrowth ^ (upgrades.ScrubPower or 0)) * tool.Power * level.Mult
	local tank = b.Tank * (b.TankGrowth ^ (upgrades.TankSize or 0)) * level.Mult
	tank *= 1 + (perks.DeepTank or 0) * Config.GetPerk("DeepTank").PerLevel
	if passes.MegaTank then
		tank *= 2
	end
	local coinMult = 1 + (perks.CoinSoap or 0) * Config.GetPerk("CoinSoap").PerLevel + (petCoinBonus or 0)
	if passes.DoubleCoins then
		coinMult *= 2
	end

	return {
		Radius = radius,
		Power = power,
		TankMax = math.floor(tank),
		Reach = tool.Reach,
		WalkSpeed = b.WalkSpeed + b.WalkSpeedPerLevel * (upgrades.Sneakers or 0),
		Hold = true, -- holding always scrubs (the old "Hold to Scrub" upgrade confused new players)
		CoinMult = coinMult,
		ToolIndex = toolIndex,
	}
end

-- Coins a run starts with (Head Start perk).
function Config.StartCoins(levelIndex: number, perks): number
	local lvl = (perks and perks.HeadStart) or 0
	return math.floor(lvl * Config.GetPerk("HeadStart").PerLevel * Config.GetLevel(levelIndex).Mult)
end

-- Equip slots for pets.
function Config.PetSlots(perks, passes): number
	local slots = Config.PetRules.BaseSlots + ((perks and perks.PetSlot) or 0)
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
end

return Config
