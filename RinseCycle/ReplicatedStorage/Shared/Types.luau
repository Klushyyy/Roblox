-- Shapes of every table that crosses the network. Annotate with these on both sides, e.g.
--   local state: Types.RunState = { ... }            (server, when building a payload)
--   local run = ClientState.Run :: Types.RunState?   (client, when reading one)
-- so the type checker catches a misspelt field on either end.
--
-- Remote rules to remember: tables sent over remotes lose metatables and Instances outside the
-- receiver's view become nil; mixed or sparse numeric keys break. Only use arrays or string keys.

export type PartyMember = {
	UserId: number,
	Name: string,
	DisplayName: string,
}

-- PartyState (S->C) - nil when the player is not in a party.
export type PartyState = {
	PadId: number,
	HostUserId: number,
	IsHost: boolean,
	Members: { PartyMember }, -- in join order; Members[1] is the longest-waiting member
	MaxPlayers: number, -- 1..4
	Privacy: "Public" | "Friends",
	Level: number, -- index into Config.Levels
	HostUnlocked: number, -- highest level the host may pick
	EndsAt: number, -- workspace:GetServerTimeNow() when the countdown hits 0
	Status: "Picking" | "Waiting" | "Launching", -- Picking = the host is on the Create Party screen
}

-- Upgrade levels bought inside a run (keys = Config.Upgrades[i].Id).
export type RunUpgrades = {
	Hold: number,
	HandSize: number,
	ScrubPower: number,
	TankSize: number,
	Sneakers: number,
}

-- Output of Config.GetRunStats.
export type RunStats = {
	Radius: number,
	Power: number,
	TankMax: number,
	Reach: number,
	WalkSpeed: number,
	Hold: boolean,
	CoinMult: number,
	ToolIndex: number,
	Tier: number, -- the tool's Tier (dirt with MinTool above this cleans slowly)
	Mode: string, -- "Scrub" | "Spray" | "Line" | "Foam" (see Config.Tools)
	PetPower: number, -- what pets' PowerShare multiplies (tool-independent)
	LineLength: number?, -- Line only
	LineWidth: number?,
	FoamInterval: number?, -- Foam only
	FoamSeconds: number?,
	FoamShare: number?,
}

export type ResultRow = {
	UserId: number,
	Name: string,
	Grime: number, -- spots this player (and their pets) cleaned
	Share: number, -- 0..1 of all spots in the run
	Bubbles: number, -- Bubbles this player earned
}

export type RunResults = {
	TimeSeconds: number,
	ParTime: number,
	UnderPar: boolean,
	FirstClear: boolean, -- true for the receiving player only if this was their first clear of the level
	NewBest: boolean, -- receiving player's personal best
	UnlockedLevel: number?, -- level index newly unlocked for the receiving player
	Bubbles: number, -- Bubbles the receiving player earned
	Players: { ResultRow },
	ReturnAt: number, -- server time when everyone is sent back to the lobby
}

-- RunState (S->C) - nil when the player is not in a run.
export type RunState = {
	Level: number,
	ArenaName: string, -- child of workspace.Arenas
	StartedAt: number, -- server time
	ClockAt: number, -- server time the run clock started (0 = still waiting on the intro cutscene)
	Phase: "Playing" | "Complete",
	Coins: number,
	Tank: number,
	TankMax: number,
	ToolIndex: number, -- the tool in your hand
	OwnedTools: { boolean }, -- [toolIndex] = owned (every index present)
	ToolUpgrades: { RunUpgrades }, -- [toolIndex] = that tool's own HandSize / ScrubPower levels
	Upgrades: RunUpgrades, -- effective levels for the tool in hand (its per-tool + global ones)
	Stats: RunStats,
	DrainPosition: Vector3,
	StationPosition: Vector3,
	Total: number, -- grime spots in the run
	Cleaned: number, -- grime spots cleaned so far
	Members: { number }, -- UserIds still in the run
	Results: RunResults?, -- set when Phase == "Complete"
}

export type PetEntry = {
	Uid: string,
	Id: string, -- key into Config.Pets
	Tier: number?, -- 1 normal (nil = 1), 2 Golden, 3 Rainbow (Config.PetTiers)
}

-- MetaState (S->C) - the player's permanent data.
export type MetaState = {
	Bubbles: number,
	Gems: number, -- premium currency (rank rolls)
	Rank: string, -- equipped rank id, "" = none
	Ranks: { string }, -- every rank id owned
	Perks: { [string]: number }, -- Config.Perks[i].Id -> level
	Pets: { PetEntry },
	Equipped: { string }, -- Uids
	PetSlots: number,
	MaxPets: number,
	Unlocked: number, -- highest level index unlocked
	BestTimes: { number }, -- per level index, seconds; 0 = never cleared
	Rebirths: number,
	RebirthReady: boolean, -- the last level was cleared since the last rebirth
	DailyStreak: number, -- day of the daily-reward streak last claimed (1..7)
	DailyClaimedToday: boolean, -- true while the next daily reward is still on its timer
	DailyReadyAt: number, -- os.time() when the next daily reward unlocks (0 = never claimed)
	DailyBroken: boolean, -- a day was missed: the next claim restarts at day 1 unless restored
	GroupReward: boolean, -- the community reward has been claimed
	FollowState: string, -- "" / "Pending" (checked when you rejoin) / "Claimed"
	LikeState: string, -- "" / "Pending" (paid when you rejoin) / "Claimed"
	Stats: {
		Runs: number,
		DishesCleaned: number,
		GrimeCleaned: number,
		EggsHatched: number,
		BubblesEarned: number,
	},
	Passes: { [string]: boolean }, -- Config.GamePasses[i].Key -> owned
	Episodes: { number }?, -- per level: cutscene chapters seen (the next run plays the next chapter)
}

-- Results of RemoteFunction calls.
export type RequestResult = {
	Ok: boolean,
	Error: string?,
	Pets: { PetEntry }?, -- MetaRequest "Hatch"
	Rank: string?, -- MetaRequest "RollRank": the rank rolled
	Equipped: boolean?, -- MetaRequest "RollRank": always true now (a roll replaces your rank)
	Previous: string?, -- MetaRequest "RollRank": the rank you had before
	Message: string?, -- ClaimDaily / RedeemCode / ClaimGroup: what you got ("🧼 300 + 💎 10")
	Day: number?, -- ClaimDaily: the streak day claimed
}

-- RunFX payloads (S->C), by kind.
export type FXCleaned = {
	Position: Vector3,
	Color: Color3,
	Units: number,
	By: number, -- UserId (0 if unknown)
	Golden: boolean,
	Bubbles: number, -- golden spots only, else 0
	Pet: boolean, -- cleaned by a pet
}

export type FXDishDone = {
	Position: Vector3,
	Kind: string,
	By: number,
	Bonus: number, -- coins paid to By
}

export type FXSold = {
	Coins: number,
	Units: number,
	By: number,
}

return {}
