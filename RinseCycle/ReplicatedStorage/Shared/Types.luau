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
	Status: "Waiting" | "Launching",
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
	Phase: "Playing" | "Complete",
	Coins: number,
	Tank: number,
	TankMax: number,
	ToolIndex: number,
	Upgrades: RunUpgrades,
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
}

-- MetaState (S->C) - the player's permanent data.
export type MetaState = {
	Bubbles: number,
	Perks: { [string]: number }, -- Config.Perks[i].Id -> level
	Pets: { PetEntry },
	Equipped: { string }, -- Uids
	PetSlots: number,
	MaxPets: number,
	Unlocked: number, -- highest level index unlocked
	BestTimes: { number }, -- per level index, seconds; 0 = never cleared
	Stats: {
		Runs: number,
		DishesCleaned: number,
		GrimeCleaned: number,
		EggsHatched: number,
		BubblesEarned: number,
	},
	Passes: { [string]: boolean }, -- Config.GamePasses[i].Key -> owned
}

-- Results of RemoteFunction calls.
export type RequestResult = {
	Ok: boolean,
	Error: string?,
	Pets: { PetEntry }?, -- MetaRequest "Hatch"
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
