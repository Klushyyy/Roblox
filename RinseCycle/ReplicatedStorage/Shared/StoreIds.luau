--[[
	STORE IDS - paste your Roblox IDs here. This is the only script you need to edit.

	1. Creator Dashboard > your experience > Monetization > Passes (or Developer Products).
	2. Create each item below with the same name and price.
	3. Open it, copy the number from its URL, and paste it over the 0 next to its name.
	4. File > Publish to Roblox. That's it: the game picks the IDs up on start.

	An item left at 0 says "Coming soon!" in the live game (and is free to "buy" in Studio tests).
]]

return {
	-- Your community (group). Players who join it can claim the community reward.
	GroupId = 920260021,

	-- Game passes (bought once, kept forever).
	GamePasses = {
		DoubleCoins = 1998171441,   -- 2x Coins (99 R$)
		SuperScrub = 1999275431,    -- Super Scrub (129 R$)
		MegaTank = 1999635456,      -- Mega Tank (149 R$)
		LuckyCharm = 2001374337,    -- Lucky Charm (99 R$)
		PetSlots = 1999263395,      -- +2 Pet Slots (149 R$)
		AutoDrain = 2001644356,     -- Auto Drain (149 R$)
		DoubleBubbles = 1998867445, -- 2x Bubbles (179 R$)
		VIP = 2001476378,           -- VIP (199 R$)
		DoubleLuck = 2001938341,    -- x2 Luck (149 R$)
		ToolNozzle = 1999185504,    -- Spray Nozzle (49 R$)
		ToolWasher = 1998081436,    -- Pressure Washer (99 R$)
		ToolCannon = 2002424326,    -- Foam Cannon (199 R$)
	},

	-- Developer products (can be bought again and again).
	DevProducts = {
		Bubbles1 = 3715384602,      -- Handful of Bubbles (19 R$)
		Bubbles2 = 3715384663,      -- Bucket of Bubbles (49 R$)
		Bubbles3 = 3715384708,      -- Tub of Bubbles (99 R$)
		Bubbles4 = 3715384765,      -- Bathtub Overflow (199 R$)
		Coins1 = 3715384814,        -- Coin Splash (15 R$)
		Coins2 = 3715384876,        -- Coin Wave (39 R$)
		Coins3 = 3715384928,        -- Coin Flood (89 R$)
		Gems1 = 3715384965,         -- Pouch of Gems (29 R$)
		Gems2 = 3715385007,         -- Sack of Gems (79 R$)
		Gems3 = 3715385050,         -- Chest of Gems (199 R$)
		RestoreStreak = 3715385096, -- Restore Streak (29 R$)
	},

	-- Roblox Events for the Next Event ring in the lobby (Creator Hub > your experience > Engagement
	-- > Events > Create Event). Copy the event's ID from its page URL (the long number) and paste it
	-- in quotes. The start time on Roblox should match Config.UpcomingEvents (17 Oct, 11 pm NZ).
	EventIds = {
		AdminAbuse = "1208558647303602774", -- Creator Hub > Events > Admin Abuse
		Chapter4 = "5239442577127768664", -- the "Chapter 4" card in the party window opens this event's RSVP
	},

	-- "Your daily reward is ready" notification (sent 24 h after a claim, to players who turned
	-- notifications on). Setup:
	--   1. Creator Hub > your experience > Engagement > Notifications > Create a Notification String.
	--      Name: Daily reward ready.  Text: Your Day {streak} daily reward is ready! Come claim it before your streak resets.
	--      (Add "streak" as the custom parameter.) Copy the string's ID (Copy Asset ID) here.
	--   2. Creator Hub > Open Cloud > API Keys > Create API Key: add the "user-notification" API
	--      for this experience (write), allow IP 0.0.0.0/0, no expiry. Copy the key.
	--   3. Creator Hub > your experience > Secrets (Configure > Secrets) > Create Secret: name
	--      OpenCloudKey, paste the key, domain apis.roblox.com.
	--   4. Game Settings > Security > Allow HTTP Requests: on.
	Notifications = {
		DailyReady = "30b2bd07-8110-3042-ab43-4b7e0afe2781",
	},

	-- Badges (Creator Dashboard > your experience > Engagement > Badges > Create a Badge). Use the
	-- name and description shown, then paste the badge's ID. Given out automatically.
	Badges = {
		Welcome = 2575871538930984,    -- "Welcome to Rinse Cycle!"  Join the game for the first time.
		Level1 = 2019833923438430,     -- "Family Dinner Cleared"    Clean every dish in level 1.
		Level2 = 4342556802449819,     -- "Pizza Party Cleared"      Clean every dish in level 2.
		Level3 = 4215993717051062,     -- "Royal Banquet Cleared"    Clean every dish in level 3.
		FirstPet = 996802792244268,   -- "New Best Friend"          Hatch your first pet.
		GoldenPet = 706372052285673,  -- "Golden Touch"             Merge a Golden pet.
		Rebirth = 2883619495633715,    -- "Born Again"               Rebirth for the first time.
		LegendRank = 3034324866864862, -- "Legendary Luck"           Roll a Legendary or Mythic rank.
		Club = 2101771823008708,       -- "Better Together"          Make or join a club.
		DishMaster = 2704509948705644, -- "Dish Master"              Clean 1,000 dishes.
	},

	-- Developer products for the Treasure Chest event and the luck ad. Create each one in Creator
	-- Dashboard > Monetization > Developer Products with the name and price shown.
	Events = {
		ChestOne = 3716462768,   -- Treasure Chest x1 (49 R$)
		ChestThree = 3716462840, -- Treasure Chest x3 (139 R$)
		ChestTen = 3716462894,   -- Treasure Chest x10 (349 R$)
		AdLuck = 0,     -- Luck Ad Reward (any price, e.g. 5 R$): the reward a rewarded video ad gives.
		                -- Also turn ads on: Creator Dashboard > Monetization > Ads (rewarded video ads).
	},

	-- Background music: audio asset IDs (Creator Store > Audio > Music, or the Toolbox's Audio tab;
	-- right-click a track > Copy Asset ID). Add as many as you like; they play shuffled and loop.
	Music = {
		Lobby = { 108307358965008 }, -- calm tracks for the lobby
		Run = { 74135947568576, 95101745664541 }, -- while cleaning (they crossfade into each other)
	},

	-- Gift products: one DEVELOPER PRODUCT per pass (not a game pass!), named "Gift: <pass name>"
	-- with the same price. Buying one gives that pass to the friend the buyer picked.
	GiftPasses = {
		DoubleCoins = 3715577660,   -- Gift: 2x Coins (99 R$)
		SuperScrub = 3715577703,    -- Gift: Super Scrub (129 R$)
		MegaTank = 3715577729,      -- Gift: Mega Tank (149 R$)
		LuckyCharm = 3715577776,    -- Gift: Lucky Charm (99 R$)
		PetSlots = 3715577813,      -- Gift: +2 Pet Slots (149 R$)
		AutoDrain = 3715577849,     -- Gift: Auto Drain (149 R$)
		DoubleBubbles = 3715577887, -- Gift: 2x Bubbles (179 R$)
		VIP = 3715577914,           -- Gift: VIP (199 R$)
		DoubleLuck = 3715577947,    -- Gift: x2 Luck (149 R$)
		ToolNozzle = 3715578032,    -- Gift: Spray Nozzle (49 R$)
		ToolWasher = 3715578073,    -- Gift: Pressure Washer (99 R$)
		ToolCannon = 3715578099,    -- Gift: Foam Cannon (199 R$)
	},
}
