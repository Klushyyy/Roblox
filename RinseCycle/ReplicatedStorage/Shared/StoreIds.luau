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
		DoubleCoins = 0,   -- 2x Coins (99 R$)
		SuperScrub = 0,    -- Super Scrub (129 R$)
		MegaTank = 0,      -- Mega Tank (149 R$)
		LuckyCharm = 0,    -- Lucky Charm (99 R$)
		PetSlots = 0,      -- +2 Pet Slots (149 R$)
		AutoDrain = 0,     -- Auto Drain (149 R$)
		DoubleBubbles = 0, -- 2x Bubbles (179 R$)
		VIP = 0,           -- VIP (199 R$)
		DoubleLuck = 0,    -- x2 Luck (149 R$)
		InstaRoll = 0,     -- Insta Roll (39 R$)
		ToolNozzle = 0,    -- Spray Nozzle (49 R$)
		ToolWasher = 0,    -- Pressure Washer (99 R$)
		ToolCannon = 0,    -- Foam Cannon (199 R$)
	},

	-- Developer products (can be bought again and again).
	DevProducts = {
		Bubbles1 = 0,      -- Handful of Bubbles (19 R$)
		Bubbles2 = 0,      -- Bucket of Bubbles (49 R$)
		Bubbles3 = 0,      -- Tub of Bubbles (99 R$)
		Bubbles4 = 0,      -- Bathtub Overflow (199 R$)
		Coins1 = 0,        -- Coin Splash (15 R$)
		Coins2 = 0,        -- Coin Wave (39 R$)
		Coins3 = 0,        -- Coin Flood (89 R$)
		Gems1 = 0,         -- Pouch of Gems (29 R$)
		Gems2 = 0,         -- Sack of Gems (79 R$)
		Gems3 = 0,         -- Chest of Gems (199 R$)
		RestoreStreak = 0, -- Restore Streak (29 R$)
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
		InstaRoll = 3715578140,     -- Gift: Insta Roll (39 R$)
		ToolNozzle = 3715578032,    -- Gift: Spray Nozzle (49 R$)
		ToolWasher = 3715578073,    -- Gift: Pressure Washer (99 R$)
		ToolCannon = 3715578099,    -- Gift: Foam Cannon (199 R$)
	},
}
