# Rinse Cycle: design and code contract

You are a tiny water-person inside a giant dishwasher. Scrub the grime off the plates, bowls,
cups and cutlery, fill your tank, sell it at the drain for coins, and buy bigger hands and better
tools. Finish the whole load with your party, earn Bubbles, and spend them on pets that scrub for you.

The place starts **empty**. Scripts build the lobby, the dishwashers, every dish and every piece of UI.
Nothing uses uploaded assets except optional sound IDs in `Config.Sounds`.

This file is the contract every script is written against. If code and this file disagree, fix one
of them. Don't let them drift apart.

---

## 1. Game flow

1. **Lobby.** A compact plaza on top of a giant wooden dining table (low-poly, flat colours) in a
   dining room: giant chairs, a pendant lamp, a sideboard, and windows looking out on a garden and
   mountains (Terrain, outside the room only). It has six party pads (three each side), a giant
   dishwasher building with the Egg Hatchery in front, the Soap Shop (perks), a Pet Stand, two
   leaderboards (Fastest Clean has one page per level; each player flips pages with the arrows or
   the "Next level" prompt, locally) and a How to Play board.
2. **Party pads.** Step onto an empty pad and you become host. You get the **Create Party** screen:
   pick a dishwasher, Public or Friends, and party size, then press **CREATE** (or **BACK** to
   leave). While you pick, the pad reads "Name is picking a dishwasher..." and nobody else can join.
   After CREATE a **15 second** countdown starts ("Teleporting in 12"); the host can press
   **Start**. Others walk in to join, or get pushed out with a toast if the pad is full or
   friends-only. **Leave** teleports you out. If the host leaves, the longest-waiting member becomes
   host. The last person leaving resets the pad to `0/4`.
3. **Launch.** At 0 the server builds that party's dishwasher (an "arena") far from the lobby in the
   **same server** and teleports the members onto the open dishwasher door.
4. **Run.** Everyone starts with **Bare Hands, 0 upgrades, and Head Start coins**.
   - Aim at the dirt and **hold** to scrub (a single tap also works). Players never see the word
     "grime": the code calls the spots Grime, every piece of text calls them dirt.
   - Cleaned dirt goes into your **tank**. When it's full you can't scrub until you stand in the
     **drain** at the front of the tub, which sells the tank for **coins**.
   - Coins buy in-run upgrades (Hand Size, Scrub Power, Tank Size, Sneakers) in the Upgrade Book,
     and tools, in order: Sponge, Brush, Nozzle, Washer, Cannon, at the Tool Shop on the door or in
     the book. Tougher grime needs a minimum tool (`MinTool`).
   - Equipped pets fly to grime near you and clean it into your tank.
5. **Finish.** When every grime spot is gone the run is **complete**: a celebration, then a results
   screen showing time, par, each player's share and the Bubbles earned. First clear of a level
   unlocks the next level. After `Config.Round.ResultsSeconds`, or when a player presses "Back to
   Lobby", players return to the lobby. Coins, upgrades and tools are discarded.
6. **Meta.** Spend Bubbles on eggs (random pets, odds always shown), perks (Head Start, Coin Soap,
   Deep Tank, Lucky Suds, Pet Slot), and see the best-time boards.

Leaving a run early (the Leave button) returns you to the lobby with no rewards. When the last
member leaves, the arena is destroyed.

---

## 2. Files and where they live in Studio

The folders mirror Studio. File names follow **Studio Script Sync**:
- `X.server.luau` is a Script with RunContext Server
- `X.local.luau` is a LocalScript
- `X.luau` is a ModuleScript
- a directory is a Folder

`_tools/build.ps1` (or its Python port `_tools/build.py`) packs everything into `RinseCycle.rbxlx`.

```
ReplicatedStorage/Shared/          (Folder, sync root)
  Config.luau        all numbers, levels, grime, tools, pets, eggs, perks, passes, sounds, helpers
  Remotes.luau       creates/gets RemoteEvents + RemoteFunctions
  Types.luau         export types for every network payload
  Util.luau          Signal, DeepCopy, Reconcile, WeightedPick, Shuffle, Now, IsFiniteVector3
  Format.luau        Short(1234)="1.2K", Commas, Time(75)="1:15", Percent, Chance
  PetModels.luau     builds every pet model from primitive parts (used by client renderer and UI)
ServerScriptService/Server/        (Folder, sync root)
  Main.server.luau   boot order
  Services/
    Characters.luau      collision groups, Teleport, SetWalkSpeed, respawn resolvers
    DataService.luau     persistent profiles (DataStore), MetaState push, leaderstats
    MarketService.luau   game-pass ownership + purchase handling
    LobbyBuilder.luau    builds the lobby world, pads, shops, boards, lighting
    LeaderboardService.luau  fills the lobby boards
    PartyService.luau    party pads state machine
    DishFactory.luau     builds dishes + grime spots
    ArenaBuilder.luau    builds a dishwasher for a run, lays out the load
    RoundService.luau    runs: scrubbing, tank, drain, coins, upgrades, completion, rewards
    PetService.luau      pet inventory ops, EquippedPets replication, pet auto-clean in runs
    ShopService.luau     MetaRequest handler (perks + dispatch to PetService)
StarterPlayer/StarterPlayerScripts/Client/   (Folder, sync root)
  ClientMain.local.luau  boot order
  ClientState.luau   Meta / Party / Run mirrors + request wrappers
  UIKit.luau         design system: screens, scaling, buttons, windows, toasts, sounds
  HUD.luau           always-on HUD (currency, tank, progress, timer, buttons, results)
  PartyUI.luau       party settings panel while waiting in a pad
  UpgradesUI.luau    in-run upgrades + tools window
  ShopUI.luau        lobby Soap Shop (perks) + Robux passes window
  PetsUI.luau        pet inventory window + egg hatch window + hatch animation
  SprayController.luau  aiming, spraying input, spray visuals, sends Scrub
  PetRenderer.luau   renders every player's equipped pets (client-side models)
  Effects.luau       world FX: grime pops, floating numbers, sparkles, spinning arms, bubble lifts,
                     drain guide beam, remaining-grime markers, prompt -> window routing
```

**Who wrote what.** Config, Remotes, Types, Util, Format, Characters, Main, ClientMain and
ClientState are the foundation. Don't change their public API. If you really need a change, add
to it (a new function or field) and mention it in your report.

---

## 3. Coding rules (all files)

- Luau, no `--!strict` header (nonstrict). Annotate function parameters and payload tables with
  types from `Types.luau` where it helps the checker.
- Use `task.wait/spawn/defer/delay`, never `wait`/`spawn`/`delay`. Use `:Connect`, never `:connect`.
- Use `Instance.new(class)` and then set Parent **last**.
- Get services with `game:GetService`. Require modules like this:
  - shared: `require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))`
  - server services: `require(script.Parent:WaitForChild("X"))` from inside `Services/`
  - client modules: `require(script.Parent:WaitForChild("X"))`
- **No circular requires.** Server dependency graph, where an arrow means "may require":
  - `DataService` depends on nothing server-side.
  - `MarketService` → `DataService`
  - `DishFactory` → nothing
  - `ArenaBuilder` → `DishFactory`
  - `RoundService` → `DataService`, `ArenaBuilder`, `DishFactory`, `LobbyBuilder`, `Characters`
  - `PetService` → `DataService`, `RoundService`
  - `ShopService` → `DataService`, `PetService`, `RoundService`
  - `PartyService` → `LobbyBuilder`, `RoundService`, `DataService`, `Characters`
  - `LeaderboardService` → `LobbyBuilder`, `DataService`
  - `LobbyBuilder` → nothing server-side
- Deprecated APIs to avoid:
  - `PhysicsService` collision group methods: use the `workspace:` versions, which `Characters` does.
  - `Player:IsFriendsWith`: use `IsFriendsWithAsync` inside `pcall`, and check `player.Parent` first.
  - `LoadCharacter`: use `LoadCharacterAsync`.
  - `GetProductInfo`: use `GetProductInfoAsync`.
  - `BodyVelocity`, `BodyPosition`, `BodyGyro`: use `LinearVelocity`, `AlignPosition` or
    `AlignOrientation`, or just set `AssemblyLinearVelocity`.
- **Assume deferred signals** (SignalBehavior may be Deferred). Handlers don't run synchronously
  after `Fire` or a property set. Don't depend on that ordering.
- Anything that yields and can fail (DataStore, MarketplaceService, friends, `GeometryService`) must
  be wrapped in `pcall`.
- The server never trusts the client:
  - validate types (`typeof`), ranges, `Util.IsFiniteVector3`, distance, and rate
  - validate state: is this player in a party or run, and are they the host?
- Server loops use `task.spawn` + `while true do ... task.wait(dt) end` or `RunService.Heartbeat`.
  Never block `Start()`.
- Building lots of parts: yield (`task.wait()`) every ~150–250 parts so the server doesn't hitch.
- Static geometry settings:
  - Static parts: `Anchored = true`.
  - Decoration: `CanTouch = false`, and `CanQuery = false` unless it must be hit by raycasts.
  - Dish parts: `CanQuery = true`, so sprays can hit them.
  - Decoration that nobody should stand on: `CanCollide = false`.
- Use `Font.fromEnum(Enum.Font.FredokaOne)` or `Enum.Font.FredokaOne` for the cartoon look.
  `Enum.Font.GothamBold` / `GothamMedium` are fine for small body text.
- Emoji in TextLabels are fine for icons. Never cut a string with emoji using `string.sub`.
- Coordinates:
  - The lobby floor top is at Y = 0 around the origin.
  - Arena slot k's origin is `Config.World.ArenaRowStart + (k - 1) * Config.World.ArenaSpacing`.
  - Everything stays above Y = -400.
- Any texture must be an `rbxasset://` path that ships with every client. Known good:
  - `rbxasset://textures/particles/sparkles_main.dds` (the default)
  - `rbxasset://textures/particles/smoke_main.dds`
  - `rbxasset://textures/particles/forcefield_glow_main.dds`
  - `rbxasset://textures/particles/fire_sparks_main.dds`
  - `rbxasset://textures/whiteCircle.png`
  - `rbxasset://textures/sparkle.png`
  - `rbxasset://textures/glow.png`
  - `rbxasset://textures/gradient.png`
  - For bubbles, use small Ball parts (Glass/ForceField material, transparent), or ParticleEmitters
    using `forcefield_glow_main.dds`.

### Type checker
Run `bash <scratchpad>/tools/check.sh [files...]`. It rebuilds the sourcemap and runs **luau-lsp**
with the real Roblox API types.
- The **NONSTRICT** section must be empty for your files.
- In the **STRICT (filtered)** section, fix every line for your files: API typos, wrong argument
  counts, wrong property types. Where strict mode just can't see through dynamic code, a precise
  cast is fine, e.g. `(x :: any)` or `:: BasePart`.

---

## 4. Remotes (exact contracts)

All remotes live in `ReplicatedStorage.Remotes`. Get them with `Remotes.Event(name)` /
`Remotes.Function(name)`. Payload types are in `Types.luau`.

| Name | Dir | Args | Notes |
|---|---|---|---|
| `PartyAction` | C→S | `(action: string, value: any)` | Actions are listed below the table |
| `PartyState` | S→C | `(state: Types.PartyState?)` | Sent to every member on every change, and `nil` when a player leaves or the party launches |
| `Scrub` | C→S | `(aim: Vector3, holding: boolean)` | `holding` = true while held, false for a single click |
| `RunState` | S→C | `(state: Types.RunState?)` | Pushed on change (debounced to ≤ 10/s per player); `nil` when the player leaves the run |
| `RunFX` | S→C | `(kind: string, data)` | `"Cleaned"` (`FXCleaned`) and `"DishDone"` (`FXDishDone`) go to every run member; `"Sold"` (`FXSold`) and `"TankFull"` (`{}`) go to the player only |
| `MetaState` | S→C | `(state: Types.MetaState)` | Pushed after any change to the profile or passes |
| `Notify` | S→C | `(text: string, kind: "Info" \| "Good" \| "Bad")` | Toasts |
| `RunRequest` | RF | `(action, value) -> RequestResult` | Actions are listed below the table |
| `MetaRequest` | RF | `(action, value) -> RequestResult` | Actions are listed below the table |
| `GetMeta` | RF | `() -> MetaState?` | Owned by DataService; `nil` if the profile isn't loaded yet |

`PartyAction` actions:
- `"Leave"`
- `"SetMax"` (1–4, never below the current member count)
- `"SetPrivacy"` (`"Public"` / `"Friends"`)
- `"SetLevel"` (1..HostUnlocked)
- `"StartNow"` (only while Waiting)
- `"Create"` (`{ Level, MaxPlayers, Privacy }`, host only, only while Status is `"Picking"`): confirms
  the Create Party screen and starts the countdown

`PartyState.Status` is `"Picking"` (host on the Create Party screen, nobody can join), `"Waiting"`
(counting down) or `"Launching"`.

`RunRequest` actions:
- `"BuyUpgrade"` (upgradeId)
- `"BuyTool"` (toolIndex, any tool not owned yet; it goes straight into your hand)
- `"EquipTool"` (toolIndex, an owned tool)
- `"Leave"` (leave the run now, no rewards)
- `"ReturnToLobby"` (only while Phase == "Complete")

`MetaRequest` actions:
- `"BuyPerk"` (perkId)
- `"Hatch"` (`{ Egg: string, Count: 1 | 3 }`, which returns `Pets`)
- `"Equip"` (uid)
- `"Unequip"` (uid)
- `"EquipBest"`
- `"Delete"` (uid)

**Player attributes** (set by the server, readable by every client):

| Attribute | Type | Set by |
|---|---|---|
| `Bubbles` | number | DataService |
| `InParty` | boolean | PartyService |
| `InRun` | boolean | RoundService |
| `RunArena` | string | RoundService; the arena name, `""` when not in a run |

**leaderstats** (DataService): IntValues `Bubbles` and `Dishes` (lifetime dishes cleaned).

**Equipped pets for rendering** (PetService):
- Each Player gets a Folder `EquippedPets`.
- It holds one StringValue per equipped pet, named `"1"`, `"2"` and so on (slot order). Value = pet id.
- Each StringValue has an ObjectValue child `Target`. Value = the grime BasePart the pet is flying
  to, or nil.
- Clients render from this and nothing else.

---

## 5. Server services

Every service is a ModuleScript table. `Main` calls `Init()` on all of them in order, then `Start()`.
`Init()` sets up state and remote handlers and must not yield for long. `Start()` spawns loops and
never blocks.

### Characters (foundation, done)
- `Setup()` registers the collision groups `Players`, `PartyMember`, `PadBarrier` and `NoCollide`,
  and keeps characters in their group across respawns.
  - `PadBarrier` collides only with `PartyMember`.
  - `NoCollide` collides with nothing.
  - Players don't collide with each other.
- `SetGroup(player, group)`
- `GetRoot(player) -> BasePart?` returns nil if dead or missing.
- `IsAlive(player)`
- `Teleport(player, cframe) -> boolean` puts the feet at `cframe.Position`, facing `cframe.LookVector`.
- `SetWalkSpeed(player, speed?)` persists across respawns; nil means 16.
- `AddRespawnResolver(fn(player) -> CFrame?)` is called on every CharacterAdded. The first non-nil
  CFrame wins, and the player is teleported there.

### DataService
Profile (persisted, DataStore `RinseCycle_Profiles_v1`, key `"u_" .. userId`):
```lua
{
  Version = 1,
  Bubbles = 0,
  Perks = { HeadStart = 0, CoinSoap = 0, DeepTank = 0, LuckySuds = 0, PetSlot = 0 },
  Pets = {},            -- { { Uid = "1", Id = "RubberDuck" }, ... }
  Equipped = {},        -- { "1", ... }  (Uids)
  NextUid = 1,
  Unlocked = 1,
  BestTimes = { 0, 0, 0 },   -- one per Config.Levels entry, seconds, 0 = none
  Stats = { Runs = 0, DishesCleaned = 0, GrimeCleaned = 0, EggsHatched = 0, BubblesEarned = 0 },
  Receipts = {},        -- recent developer-product PurchaseIds, newest last, max 50
}
```

Loading and saving:
- Load with `UpdateAsync` and a session lock (`Lock = { JobId, Time }`). If another server holds a
  lock younger than 30 minutes, retry up to ~6 times, then steal it.
- `Util.Reconcile` fills in missing fields. Make sure `BestTimes` has one entry per level.
- Autosave every 120 s, with a random start offset. Save on PlayerRemoving and release the lock.
- `BindToClose`: save everyone in parallel and wait up to 25 s.
- **Offline mode.** If DataStores are unavailable (`game.PlaceId == 0`, a Studio error containing
  "StudioAccessToApisNotAllowed", or "publish"), use in-memory profiles. `Notify` each player once:
  "Progress won't save in this test (turn on Studio API access)." Everything else must work the same.

Passes are runtime-only (`passes[player] = { Key = bool }`) and never saved.

API:
- `Init()`, `Start()`
- `Get(player) -> Profile?`
- `WaitFor(player, timeout: number?) -> Profile?`
- `ProfileLoaded: Util.Signal`, fired with `(player, profile)`. Services that care must also handle
  players already loaded when they subscribe.
- `AddBubbles(player, amount, reason: string?)` also adds to `Stats.BubblesEarned` when amount > 0.
- `SpendBubbles(player, amount) -> boolean`
- `AddStat(player, statName, amount)`
- `GetPasses(player) -> { [string]: boolean }`
- `SetPass(player, key, owned: boolean)`
- `GetPetSlots(player) -> number` uses `Config.PetSlots(perks, passes)`.
- `RecordClear(player, levelIndex, seconds) -> (firstClear: boolean, newBest: boolean, unlocked: number?)`
  updates `BestTimes`, `Unlocked` (levelIndex + 1 if it exists) and `Stats.Runs`.
- `PushMeta(player)` builds a `Types.MetaState`, fires `MetaState`, and updates the `Bubbles`
  attribute and leaderstats. Debounce: coalesce calls within 0.1 s.
- `IsOffline() -> boolean`
- It handles `GetMeta` by returning the MetaState, or nil if not loaded.

### MarketService
- On ProfileLoaded, checks `UserOwnsGamePassAsync` for every pass with `Id ~= 0` (in pcall), then
  calls `DataService.SetPass` and `PushMeta`.
- Handles `PromptGamePassPurchaseFinished` by granting immediately.
- `ProcessReceipt`: there are no developer products yet. Implement the idempotent pattern
  (`Receipts` list + save) as a stub that returns `NotProcessedYet` for unknown products.
- If a pass that changes run stats is granted mid-run, RoundService picks it up on its next
  stats recompute, which happens on every purchase and every sell.

### LobbyBuilder
- `Build()` builds everything under `workspace.Lobby` (a Model) and yields while building. It must
  create **SpawnLocations first** so waiting players have a floor.
- `GetLobby() -> Lobby?`
- `GetSpawnCFrame() -> CFrame` returns a random spot near the central spawn, facing the pads.

```lua
Lobby = {
  Model = Model,
  Pads = { PadInfo },                -- Config.Party.PadCount of them, Id = 1..N
  Boards = { Times = BoardInfo, Dishes = BoardInfo },
}
PadInfo = {
  Id = number,
  Model = Model,
  Zone = BasePart,       -- invisible box; a player whose HumanoidRootPart is inside is "in" the pad
  Floor = BasePart,      -- glowing floor (PartyService recolours it by state)
  Inside = CFrame,       -- where members stand (centre of the pad, facing out)
  Exit = CFrame,         -- where leavers / rejected players are put (outside the pad's front)
  Barriers = { BasePart },  -- walls, CollisionGroup = "PadBarrier", mostly transparent
  Gui = { Count = TextLabel, Title = TextLabel, Status = TextLabel, Privacy = TextLabel },
}
BoardInfo = { Part = BasePart, Title = TextLabel, List = Frame }  -- List is where rows are drawn
```

- It sets Lighting at build time (bright clean kitchen). Use Atmosphere, Bloom and ColorCorrection
  created by script.
- It removes a template `workspace.Baseplate` / `workspace.SpawnLocation` if present.
- Stations use ProximityPrompts. The client routes them by attribute:
  - The Soap Shop prompt has attribute `OpenWindow = "Shop"`.
  - Each egg display's prompt has `OpenWindow = "Eggs"` and `EggId = "<id>"`.
  - The pet inventory stand's prompt has `OpenWindow = "Pets"`.
  - Use `RequiresLineOfSight = false`, `HoldDuration = 0` and `MaxActivationDistance` ≈ 12.

### LeaderboardService
- Uses OrderedDataStores:
  - `RinseCycle_Fastest_L<n>`: value = best time in tenths of a second, ascending.
  - `RinseCycle_Dishes`: value = DishesCleaned, descending.
- Every 120 s it writes the online players' values (only improvements for times), reads the top 10,
  and draws rows into the boards.
- The Times board cycles through levels every 8 s.
- In offline mode it shows the current server's players only.
- It must not crash when there's no data. Show "No clears yet!".

### PartyService
Pad state machine. One party per pad:
```lua
{ PadId, Host: Player, Members: {Player}, MaxPlayers, Privacy, Level, EndsAt, Status }
```
- Poll every `Config.Party.PollInterval`. For each player with a live character who is not in a
  party or run, and not on rejoin cooldown: if their root is inside a pad's Zone, use point-in-box
  in pad space.
  - Empty pad: create a party, player is host, `Level = min(host Unlocked, 1..)`
    (default = their highest unlocked), Max 4, Public, `EndsAt = now + Countdown`.
  - Party exists: join if not full and (Public or host is a friend). Friends check is
    `pcall(IsFriendsWithAsync)`, cached per pair. **Re-check capacity after the yield.**
  - Otherwise eject them to `Exit`, `Notify` "This party is full" / "Friends only!", and apply the
    rejoin cooldown.
- On join:
  - `Characters.SetGroup(player, "PartyMember")`
  - teleport to `Inside`, with a small per-member offset so they don't stack
  - set attribute `InParty = true`
  - push `PartyState`
- A member found outside the Zone (glitch or exploit) is teleported back inside.
- If a member dies, they're removed from the party and respawn in the lobby.
- Leave (button or PlayerRemoving):
  - remove the member and `SetGroup` back to `"Players"`
  - teleport to `Exit` (if still in game) and send `PartyState(nil)`
  - if the host left, promote `Members[1]`
  - if the party is empty, dissolve it
- Host settings are validated:
  - `SetMax` ≥ member count
  - `SetLevel` ≤ HostUnlocked. On host migration, clamp Level to the new host's Unlocked.
  - Rate-limit to 5 actions/s per player.
- Countdown:
  - Refuse joins and leaves inside `LockSeconds` of launch.
  - At `EndsAt` (or StartNow), set `Status = "Launching"`, snapshot the members who are still valid,
    and call `RoundService.StartRound(members, level)` in a task.
  - Success: clear the pad and send `PartyState(nil)` to the members (RoundService has already sent
    RunState).
  - Failure (no free arena): `Notify` "All dishwashers are busy, trying again..." and push `EndsAt`
    out by 10 s.
- Billboard/SurfaceGui text per pad:
  - `Count` "2/4"
  - `Title` (level icon and name, or "Party Pad")
  - `Status` ("Walk in to start a party!", "Starting in 17", "Launching!")
  - `Privacy` ("🌐 Public" / "👥 Friends Only")
- Floor colour by state: idle (soft blue), open (green), friends-only (purple), full (orange).
- `Characters.AddRespawnResolver`: party members are removed on death, so return nil.
- API:
  - `Init()`, `Start()`
  - `IsInParty(player) -> boolean`
  - `RemovePlayer(player)`

### DishFactory
- `Init()` prebuilds templates. A bowl may use `GeometryService:SubtractAsync` in pcall; if that
  fails, fall back to a primitive bowl (a disc base plus a ring of tilted blocks). Templates live
  in `ServerStorage.DishTemplates`.
- `BuildDish(kind: string, cf: CFrame, theme, rng: Random) -> Model` builds one dish at the
  footprint `cf`:
  - `cf.Position` = the centre of the dish's contact point on the rack
  - `cf.LookVector` = the direction a plate's face points
  - `PrimaryPart` is set
  - all parts are Anchored, `CanQuery = true`, `CanTouch = false`
  - bowls, pots and pans are `CanCollide = true`, so players can stand in and on them
  - plates, cups, glasses and cutlery are `CanCollide = true` too; they're solid obstacles
- Sizes, relative to a ~5 stud tall character (a real dishwasher load, seen from very small):
  - Plate: 20 across, 1 thick, standing upright: coloured edge band, white rim, recessed well.
  - Bowl: 15 across, 7 deep (CSG shell), leaned toward the door.
  - Mug: 8 across, 10 tall, upside down (CSG, open at the bottom), with a handle.
  - Glass: 7 across, 12 tall, upside down, see-through.
  - Fork / Knife / Spoon: 18 tall, handle down in the cutlery basket.
  - Pan: 22 across, 4 deep (CSG), leaned toward the door, handle up. Pot: 18 across, 14 tall (CSG).
  - Hollow shapes are cut once in `Init()` with `GeometryService:SubtractAsync` (in pcall) and
    cloned; if that fails each kind falls back to primitive parts.
- `DishFactory.Size(kind)` returns the size table above (ArenaBuilder uses it for tilting).
- `ApplyGrime(dish: Model, dishId: number, count: number, levelIndex: number, rng: Random,
  goldenChance: number, folder: Folder) -> { BasePart }` puts grime on the dish's **visible,
  reachable surfaces**:
  - Raycast from outside the dish toward its surface, against the dish's parts only.
  - Plates: both faces. Bowls: the inside. Cups/glasses: the outside and bottom. Cutlery: blade,
    tines and bowl.
  - Each spot is ONE BasePart (a flat disc) in `folder`, plus decoration children: sauce splats and
    droplets, smears that thin out, chunky crumbs, or frosting with sprinkles. Sizes are
    `Config.GrimeTypes[...].Size` × 1.6. Spots keep 1.2 studs apart on a dish.
    - Anchored, `CanCollide = false`, `CanTouch = false`, `CanQuery = true`, `CastShadow = false`,
      `CollisionGroup = "NoCollide"`
    - its **XVector is the outward surface normal**, sitting ~0.05 studs proud of the surface
    - it may have child decoration parts (CanQuery = false) for crumbs and sprinkles
    - Attributes:
      - `HP`, `MaxHP` (grime HP × level Mult)
      - `Units` (Units × Mult; × `GoldenUnitsMult` if golden)
      - `Type`, `DishId`
      - `Golden` (bool)
      - `MinTool` (golden spots use MinTool 1)
    - Grime type is picked from `level.Grime` weights.
  - Golden spots are gold, `Neon`/`Foil` and sparkly, with a ParticleEmitter.
- `SetGrimeHealth(part, fraction)` fades the spot and its children as it's scrubbed (1 = full,
  0 = gone). It's cheap because it's called often.
- `Sparkle(dish: Model)` is the finished-dish effect (shine plus a short sparkle burst). It runs
  server-side, so everyone sees it.

### ArenaBuilder
- `Init()`
- `Build(slot: number, levelIndex: number, options: { GrimeScale: number, GoldenChance: number }) -> Arena`
  yields while building.
- `Destroy(arena)`
- `SlotOrigin(slot) -> CFrame`

```lua
Arena = {
  Slot = number, Name = string,               -- Name = "Arena_<slot>", the Model's name in workspace.Arenas
  Model = Model, Origin = CFrame,             -- Origin = centre of the tub floor, LookVector points from door to back wall
  Spawns = { CFrame },                        -- 4 spots on the open door, facing into the tub
  DrainPosition = Vector3, DrainRadius = number,
  StationPosition = Vector3,                  -- the in-arena Upgrade Station (prompt OpenWindow = "Upgrades")
  GrimeFolder = Folder,                       -- every grime part of the run
  Dishes = { [number]: { Id = number, Kind = string, Model = Model, Grime = { BasePart }, Center = Vector3 } },
  TotalGrime = number,
  KillY = number,                             -- below this Y a player is teleported back to a spawn
}
```

Layout, in arena-local studs (Origin at the tub floor centre, +Z toward the back). The machine is
sized so the player is a tiny person in a real dishwasher: plates are about four characters tall.
- **Kitchen around it.** The kitchen floor is 24 studs below the tub. The dishwasher is built into a
  run of base cabinets with a marble countertop, backsplash, upper cabinets, a window over the sink,
  a fridge, and a table with chairs behind the players. Walls and ceiling don't cast shadows so
  daylight fills the room. `KillY = origin.Y - 14`: falling off the door teleports you back.
- **Tub:** interior X ±56, Z −50..+62, height 100. Stainless steel (`theme.Tub`), ribs, rack rails,
  filter, heating element, and seven interior PointLights.
- **Door:** open, lying flat in front, Z −50 to −121, top at Y = 0, with raised edges, invisible
  safety walls and a control strip with buttons. Spawns are at Z −100.
- **Tool Shop** (left of the door): a chrome wire shelving unit (matches the racks) with two display
  shelves at waist and head height. Each tool (built by `ToolModels`) stands on a pedestal (risers on
  the upper shelf) with a floating price card (BillboardGui, in front of the shelf) and a ProximityPrompt with attribute `BuyTool = index`.
  The client sends `RunRequest("BuyTool", index)` and shows owned / price on the tags.
- **Drain:** tub floor, front centre (0, 0, −47), radius `Config.Round.DrainRadius`, spinning swirl
  (tag `SpinY`) and a world-sized "DRAIN" sign.
- **Bottom rack** (walkable floor at Y = 4, X ±54, Z −36..+60, ramp up from the tub floor): three rows
  of plates (X −34/0/+34, every 7 studs in Z) facing the door, standing in tines, with room to walk
  between them. At the back: two pans (tilted toward the door, handles up), two pots and a cutlery
  basket (forks, knives, spoons mixed).
- **Top rack** (walkable floor at Y = 50, Z −40..+60): bowls tilted toward the door, upturned mugs
  and upturned glasses.
- **Getting up and down:** two **Bubble Lift** pads on the tub floor's front corners. Pads are
  tagged `LiftPad` with a Vector3 attribute `LiftTo`; the client teleports its own character when it
  steps on one. To come down you just jump off. **Bubble jets** (client `BubbleJets`): in a run,
  hold jump in the air to fly up; ~2.6 s of fuel refills on the ground, shown as a bar under the tank.
- **Bubbles** (client `Bubbles`): one pooled system (200 bubbles, anchored ForceField spheres with a
  camera-facing glint, moved with `BulkMoveTo`) for every soap bubble in the game: the bubble-jet
  trail, cleaning pops, lift columns, and lobby ambience. They pop in, drift up with a wobble and
  pop out; nothing is physics-simulated or replicated. The lobby's big floating bubbles (tag
  `FloatBubble`) are placed by the server and bobbed by each client.
- **Rooms:** every level uses the same dishwasher in a different room: 1 Family Dinner (family
  kitchen), 2 Pizza Party (pizzeria: brick, checker floor, pizza oven, neon sign), 3 Royal Banquet
  (castle hall: stone, banners, red carpet, banquet table, chandeliers, fireplace). Levels 2 and 3
  add **Trays** (pizza trays / gold platters) in the plate rows.
- Spray arms under each rack (tag `SpinY`).
- Everything aimable lives in two folders on the arena Model, `Dishes` and `Grime`; the spray only
  raycasts those, so walls, rack floors and safety walls never block a scrub.
- Load size:
  - dish counts come from `level.Dishes`
  - spots per dish = `round(level.Spots[kind] * options.GrimeScale)`, at least 1
  - if a count exceeds the available slots, fill what fits and `warn`
- The arena **Model** carries attributes `Level`, `Total` and `Cleaned`. RoundService keeps
  `Cleaned` updated, and clients read progress from it.

### RoundService
Owns runs. A run:
```lua
{ Id, Arena, Level, Players = { [Player] = PlayerRun }, StartedAt, Phase, Total, Cleaned, LastDamageAt }
PlayerRun = { Coins, Tank, Upgrades (RunUpgrades), ToolIndex, Stats (RunStats), GrimeCleaned, LastScrubAt }
```

Public API:
- `Init()`, `Start()`
- `StartRound(players: {Player}, levelIndex) -> (boolean, string?)`
  - Picks a free slot.
  - Builds the arena via `ArenaBuilder.Build(slot, level, { GrimeScale = 1 + PartyGrimeScale*(n-1),
    GoldenChance = level.GoldenChance + best LuckySuds*0.01 })`.
  - Indexes grime.
  - Creates a PlayerRun per member: Coins = `Config.StartCoins`, stats from `Config.GetRunStats`.
  - Teleports each member to `Spawns[i]`, then `Characters.SetGroup(p, "Players")`,
    `Characters.SetWalkSpeed(p, stats.WalkSpeed)`, and sets attributes `InRun` / `RunArena`.
  - Pushes RunState.
  - Returns false with a message if no slot is free or the build fails. Clean up on failure.
- `IsInRun(player) -> boolean`
- `GetGrimeFolder(player) -> Folder?`
- `GetRunPower(player) -> number` is the player's current `Stats.Power`.
- `IsTankFull(player) -> boolean`
- `DamageGrime(player, part, amount, fromPet: boolean) -> boolean` applies damage if the part
  belongs to that player's run. It returns true while the part is still alive.
  - It respects the tank. If the tank is full: no damage, the pet or player waits.
  - It respects MinTool, but only for the player's own scrubs. Pets ignore MinTool.
  - At 0 HP:
    - add `Units` to the tank (capped at TankMax)
    - `GrimeCleaned += 1`
    - golden spots: give Bubbles via `DataService.AddBubbles` (`GoldenBubbles` range × level index)
      and `Notify`
    - fire FX `"Cleaned"`, destroy the part, update the dish
    - when a dish is done: `DishFactory.Sparkle`, pay the last cleaner `DishBonusShare` × dish units
      as coins, FX `"DishDone"`, `DataService.AddStat(DishesCleaned)` to every member
    - update the arena `Cleaned` attribute
    - when the run completes, call `CompleteRun`
- `RemoveFromRun(player, reason: string?)`
  - Clears attributes and walk speed, and sends `RunState(nil)`.
  - Teleports to `LobbyBuilder.GetSpawnCFrame()` if still in game.
  - When the run has no players left, destroys the arena.

Behaviour:
- `Scrub` handler:
  1. Validate that the player is in a Playing run, `Util.IsFiniteVector3(aim)`, and alive.
  2. Validate distance: `(aim - root).Magnitude <= Stats.Reach + Stats.Radius + ReachSlack`.
  3. Rate limit:
     - not holding (or no Hold upgrade): ignore if faster than `MinClickInterval`; damage =
       `Power * ClickPulseSeconds`
     - holding with Hold: damage = `Power * min(dt, MaxScrubDt)`, where dt = time since the last scrub
  4. Tank full: send FX `"TankFull"` (throttle 1 per 2 s) and stop.
  5. `workspace:GetPartBoundsInRadius(aim, Stats.Radius, params)` with an Include filter of the
     run's GrimeFolder, max 60 parts. Call `DamageGrime` on each.
- Drain loop (every 0.2 s): any member whose root is within `DrainRadius` horizontally (and
  |dy| < 8) of `DrainPosition` with `Tank > 0` sells:
  - `coins = floor(Tank * Stats.CoinMult)`
  - `Tank = 0`
  - FX `"Sold"`, sound
- AutoDrain pass: sell automatically the moment the tank fills.
- Stats recompute (`Config.GetRunStats` with profile perks, passes and `Config.PetCoinBonus`)
  happens after every purchase, every sell and every pet equip change. PetService calls
  `RoundService.RefreshStats(player)`, which is public too.
- `RunRequest`:
  - `BuyUpgrade` / `BuyTool` validate and charge coins (`Config.UpgradeCost` / `ToolCost`) and
    return `RequestResult`.
  - `Leave` runs `RemoveFromRun`.
  - `ReturnToLobby` also runs `RemoveFromRun`, but only in Phase Complete.
- Stuck guard: if nothing is damaged for `StuckSeconds` and ≤ `StuckMaxRemaining` spots remain,
  pop them with no reward.
- `CompleteRun`:
  - Phase = "Complete". Time = now − StartedAt.
  - For each member:
    - `bubbles = level.Bubbles * (0.6 + 0.4 * min(1, share * n))`
    - × `FirstClearMult` on first clear
    - × (1 + `UnderParBonus`) if under par
    - × 2 with the DoubleBubbles pass
    - `DataService.RecordClear`, `AddBubbles`, `AddStat(GrimeCleaned)`
  - Build per-player `Results` (their own FirstClear, NewBest, UnlockedLevel, Bubbles) and push
    RunState.
  - After `ResultsSeconds`, run `RemoveFromRun` for everyone left.
- Respawn resolver: a player in a run respawns at one of the arena Spawns.
- Fall guard: every 0.5 s, anyone below `Arena.KillY` is teleported to a spawn.
- PlayerRemoving: `RemoveFromRun`.
- RunState is pushed per player (their own Coins, Tank and so on). Coalesce pushes to at most one
  per 0.1 s per player.

### PetService
- Pet inventory operations, all of which return `Types.RequestResult` and never throw:
  `Hatch(player, eggId: string, count: number)` (the result includes `Pets`),
  `Equip(player, uid: string)`, `Unequip(player, uid: string)`, `EquipBest(player)`,
  `Delete(player, uid: string)`. Plus `Init()` / `Start()`.
  - Hatch validates: the egg exists, `Unlocked >= egg.RequiredLevel`, count ∈ {1, 3}, enough
    Bubbles for all of them, and inventory room.
  - Roll with `Util.WeightedPick` on `Chance`. Uids come from `NextUid`.
  - `Stats.EggsHatched += count`.
  - Equip respects `DataService.GetPetSlots`.
  - EquipBest sorts by `PowerShare` (ties broken by CoinBonus).
  - Delete also unequips.
  - After each change: `PushMeta`, rebuild the EquippedPets folder, `RoundService.RefreshStats`.
- It maintains `player.EquippedPets` as described in §4.
- Auto-clean loop, every `PetRules.ThinkInterval`, for players in a run with pets:
  - A slot keeps its target while it's valid and within `Range` of the owner. Otherwise it picks the
    nearest grime within `Range` that no other slot of that owner has claimed, and sets `Target.Value`.
  - Arrival delay = distance / `PetRules.Speed`.
  - After arriving, call `RoundService.DamageGrime(owner, part, GetRunPower(owner) * PowerShare *
    dt, true)`.
  - If the owner's tank is full, clear all targets (pets come back to the owner).
  - Outside runs every Target is nil.

### PetModels (shared)
- `PetModels.Build(petId: string) -> Model` builds a cute pet from primitive parts. It's ~2.5–3.5
  studs tall, faces -Z, and has `PrimaryPart` "Root" (an invisible 1×1×1 part at the pivot). All parts
  are Anchored, with `CanCollide`, `CanQuery` and `CanTouch` false, `CastShadow` false and Massless.
  Shiny pets (`def.Shiny`) get a sparkle ParticleEmitter named `ShinySparkle` in Root.
- `PetModels.Egg(eggId: string) -> Model` builds an egg model for UI and lobby displays, with the
  same part rules.
- Unknown ids return a simple placeholder model rather than erroring.

### ShopService
- It owns `MetaRequest`. It handles `BuyPerk` itself (validate, `SpendBubbles`, level up, push meta,
  refresh stats if in a run) and passes the pet actions to PetService.
- Rate-limit to 8 requests/s per player. Always return a `RequestResult` and never throw.

---

## 6. Client

### Screen scaling (UIKit): read before building any UI
- `UIKit.CreateScreen(name, displayOrder) -> (ScreenGui, Root: Frame)`.
  - The ScreenGui has `IgnoreGuiInset = true`, `ScreenInsets = None`, `ResetOnSpawn = false` and
    `ZIndexBehavior = Sibling`.
  - **Root is a virtual canvas.** Its size is `viewport / scale`, and a UIScale child scales it back
    up to fill the screen.
  - Build everything inside Root in **reference pixels**, as if the screen were about 1280×720.
    Offsets, margins and fonts all scale together, and Scale positions like `(1, -16, 0.5, 0)`
    still hug the real edges.
- `scale = clamp(min(vx / 1280, vy / 720), 0.4, 2)`. It's recomputed when the viewport changes.
  A landscape phone (~700×330) gets ~0.46.
- `UIKit.TopInset()` is the Roblox topbar height **in canvas units**: `GuiService:GetGuiInset().Y`
  or `TopbarInset.Height`, divided by scale. It's re-read on viewport change and a few times
  during the first seconds, because it reads 0 early.
  - Anything placed near the top must sit below it. Listen to `UIKit.LayoutChanged`.
- On touch devices (`UIKit.IsTouch()`), keep these canvas areas clear of HUD:
  - the bottom-left thumbstick zone (≈ 420×320)
  - the bottom-right jump zone (≈ 300×300)
  - The Spray button is placed on purpose just above the jump button.
- Every window must fit a 1280×720 canvas with margins: max 900×560, centred, below the top inset.

### UIKit API
```lua
UIKit.Init()
UIKit.Theme  -- Colors = { Primary, PrimaryDark, Accent, Good, Bad, Warning, Panel, PanelDark, Text, TextDim, Coin, Bubble, White }
             -- Fonts = { Title = Enum.Font.FredokaOne, Body = Enum.Font.GothamBold }
UIKit.GetScale() -> number
UIKit.TopInset() -> number
UIKit.IsTouch() -> boolean               -- UserInputService.PreferredInput == Touch (fallback TouchEnabled and not KeyboardEnabled)
UIKit.IsGamepad() -> boolean
UIKit.LayoutChanged : Util.Signal        -- viewport / scale / inset / input type changed
UIKit.CreateScreen(name: string, displayOrder: number) -> (ScreenGui, Frame)
UIKit.New(className: string, props: {[string]: any}?, children: {Instance}?) -> Instance
UIKit.Corner(parent, radius: number?) -> UICorner
UIKit.Stroke(parent, color: Color3?, thickness: number?, transparency: number?) -> UIStroke
UIKit.Padding(parent, px: number) -> UIPadding
UIKit.Gradient(parent, top: Color3, bottom: Color3) -> UIGradient
UIKit.Label(props) -> TextLabel          -- props: Text, Size, Position, AnchorPoint, TextSize, Font, TextColor3, TextXAlignment, Parent...
UIKit.Button(props) -> TextButton        -- props: Text, Size, Position, AnchorPoint, Color, TextColor3, TextSize, Parent, OnClick: () -> ()
                                         -- chunky rounded button with stroke + gradient, hover grow 1.05, press 0.95, click sound
UIKit.IconButton(props) -> TextButton    -- square HUD button: Icon (emoji), Label (small text under), Color, Size, OnClick
UIKit.Window(props) -> (Frame, Frame)    -- props: Name, Title, Icon, Size (Vector2 in canvas px), Parent (Root), OnClose
                                         -- returns (window, content). Title bar + X button; hidden by default.
UIKit.RegisterWindow(name: string, handlers: { Open: (arg: any?) -> (), Close: () -> () })
UIKit.OpenWindow(name: string, arg: any?)   -- closes any other open window first, plays open tween
UIKit.CloseWindow(name: string?)            -- nil = close whatever is open
UIKit.ToggleWindow(name: string, arg: any?)
UIKit.IsWindowOpen(name: string?) -> boolean
UIKit.WindowChanged : Util.Signal          -- (openName: string?)
UIKit.Toast(text: string, kind: string?)   -- "Info" | "Good" | "Bad"; stacks top-centre below TopInset
UIKit.Tween(inst, props, time: number?, style: Enum.EasingStyle?, dir: Enum.EasingDirection?) -> Tween
UIKit.Bounce(gui: GuiObject)               -- quick 1 -> 1.15 -> 1 pop (uses/creates a UIScale on gui)
UIKit.ProgressBar(props) -> ProgressBar    -- props: Size, Position, AnchorPoint, Color, Parent; returns { Frame, Set = (fraction, text?) -> () }
UIKit.PlaySound(key: string, pitch: number?) -- Config.Sounds[key], cached Sound in SoundService; falls back to Fallback
UIKit.Short / UIKit.Time                   -- = Format.Short / Format.Time
UIKit.RarityColor(rarity: string) -> Color3
UIKit.Viewport(props) -> ViewportFrame     -- props: Model (cloned in), Size, Position, Parent, Spin: boolean
```

**Style.** Bright, bubbly and clean, like a soap commercial.
- Aqua/cyan primary `#38BDF8`, deep navy text/panels `#0B2545` / `#13315C`, white text with a dark
  UIStroke, coin gold `#FFC83D`, bubble pink `#FF7EB6`, green `#34D399`, red `#F87171`.
- Rounded corners (12–16), thick strokes (2–3), top-to-bottom gradients on buttons.
- The HUD is legible at 0.46 scale: minimum TextSize 18 for anything important.

### HUD (always on screen)
Laid out like the big round-based simulators:
- **Top centre:** the 🧼 Bubbles pill with a green **+** (opens the Shop in the lobby, Upgrades in a run).
- **Right column** (vertically centred): big square buttons. Lobby [🛒 Shop] [🐾 Pets]; in-run
  [📖 Upgrades] [🐾 Pets] [🚪 Leave]. Each has a key hint badge: Tab / G / P on keyboard, Y / LB on
  gamepad, hidden on touch.
- **In a run:** big green 💰 coins and the tank bar ("💧 12 / 25", flashing red "FULL!") bottom-left;
  the timer (hh:mm:ss) bottom-right; dishwasher name and "Dishwasher 42% clean" top-centre.
- On touch the coins/tank move above the thumbstick zone, the timer moves top-right, and the right
  column stays above the jump button.
- Leave asks for confirmation ("Leave the run? You'll get no Bubbles.").
- **Results screen** (in-run, Phase Complete): "✨ SPARKLING CLEAN! ✨", time vs par, "NEW BEST!",
  Bubbles earned (count-up), level unlocked, a table of players (name, cleaned, share %), a
  countdown to return, and a [Back to Lobby] button (`RunRequest("ReturnToLobby")`).
- Keyboard: `Q` or `Tab` toggles Upgrades in a run, `P` Pets, `G` Shop in the lobby. Gamepad: `Y`
  toggles Upgrades (run) or Shop (lobby), `LB` Pets, `B` closes windows, `R2` sprays.

### PartyUI
Shown when `ClientState.Party ~= nil`.
- **Create Party** (host, Status `"Picking"`): a big card for the selected dishwasher (theme-coloured
  art with its icon, name, "CREATE PARTY"), 🌐 PUBLIC / 👥 FRIENDS, "Party Size:" with −/+, and a
  green CREATE; the dishwasher list on the right (locked ones say what to clear); red BACK below.
  Scaled to fit any screen. Gamepad selects CREATE; B backs out. Sends `PartyAction("Create", {...})`.
- **Waiting card** (everyone, Status `"Waiting"`/`"Launching"`): top right, left of the HUD buttons:
  dishwasher art, "2/4", "Teleporting in 12", member avatars (host ringed gold), [START] for the host
  and [LEAVE].

### UpgradesUI (window "Upgrades", in-run only)
Drawn as an open book.
- **Left page ("Hand"):** the current tool (icon, name, power/size/reach) and the four upgrades as
  cards: icon, name, "Lv 3/15", a pip bar, the **current → next** stat preview (`Config.GetRunStats`),
  and a buy button with cost (grey when unaffordable, "MAX" when maxed).
- **Right page ("Tools"):** the tool ladder. Owned = ✅, the next tool has a buy button, later tools
  show "???" and a lock. "your money: 💰 N" at the bottom.
- Calls `ClientState.RunRequest`, shows a toast on error, and bounces the card on success.

### ShopUI (window "Shop", lobby)
- Tabs: **Perks** (from `Config.Perks`, bought with Bubbles via `MetaRequest("BuyPerk")`) and
  **Robux** (`Config.GamePasses` with `Id ~= 0`, which open `MarketplaceService:PromptGamePassPurchase`).
- The Robux tab shows "Coming soon" when every Id is 0.
- Owned passes show ✅.

### PetsUI (windows "Pets" and "Eggs")
- **Pets:**
  - grid of owned pets (ViewportFrame with `PetModels.Build(id)`, name, rarity colour, ✔ when
    equipped)
  - "Equipped 2/3"
  - click a pet to open a details panel (PowerShare as "Cleans at 45% of your power", CoinBonus
    "+12% coins") with [Equip]/[Unequip] and [Delete] (with confirm)
  - [Equip Best] button
  - inventory count "12/60"
- **Eggs** (opened with arg = EggId from a prompt; can switch between eggs):
  - egg preview, cost in 🧼
  - the full **odds list** (pet viewport, name, rarity, `Format.Chance`) that must always be visible
    before buying
  - [Hatch 1] and [Hatch 3]
  - locked message if `Unlocked < RequiredLevel`
- **Hatch animation** (full-screen overlay):
  - the egg wobbles 3 times
  - a flash in the rarity colour
  - reveal card(s) with the pet viewport, name and rarity
  - sound
  - skip on click

### SprayController
- Active only when `ClientState.Run` exists with Phase "Playing" and the arena is present.
- Aim:
  - PC: mouse position.
  - Touch / gamepad: screen centre, with a small crosshair shown.
  - Raycast from the camera with RaycastParams `Include = { arena Model }`, max 250.
- Input:
  - PC: MouseButton1 (ignore when `gameProcessedEvent`).
  - Gamepad: ButtonR2.
  - Touch: a big round 💧 SPRAY button above the jump button.
- Target validity:
  - the hit must be within `Stats.Reach` of the character root
  - if it is, show a **scrub ring**: a local, non-collidable, transparent Neon disc of radius
    `Stats.Radius` at the hit, facing the normal, in the tool colour
  - else show it red at 50% transparency and don't send
- Sending:
  - `Stats.Hold` is always true now: send `Scrub(aim, true)` every `ScrubSendInterval` while held.
  - The aim ray only includes the arena's `Dishes` and `Grime` folders.
    after ~10 clicks.
- Spray visuals while sending:
  - a Beam from an attachment at the character's right hand (or root) to the hit, width by tool
  - a small splash ParticleEmitter at the hit
  - a soft scrub sound with random pitch
- MinTool hint: if the aimed grime part has `MinTool > ToolIndex`, show a small floating
  "🔒 Needs <tool name>" label and don't send.
- When `RunState.Tank >= TankMax`, don't send. Show "TANK FULL — go to the drain!" (the HUD also
  flashes).

### PetRenderer
- For every player (including the local one) with an `EquippedPets` folder, keep a client model per
  slot (`PetModels.Build(id)`, anchored, CanCollide/CanQuery/CanTouch false) in a local folder
  `workspace.ClientPets`.
- Every RenderStepped:
  - Target: if `Target.Value` is a live part, hover at `part.Position + part.CFrame.XVector * 2.5`
    facing it. Otherwise use a formation slot behind the owner's root: an arc 5–7 studs behind,
    spaced by slot, with bob `sin(t * 3 + slot) * 0.4`.
  - Move with `pivot:Lerp(target, 1 - exp(-10 * dt))`.
  - Hide pets whose owner is more than 400 studs from the camera.
- Clean up when players leave or slots change. Shiny pets have a sparkle emitter.

### Effects
- `RunFX "Cleaned"`:
  - a pop burst (small bubble balls or an emitter) at Position in Color, plus a pop sound with a
    combo pitch rise
  - if `By == LocalPlayer.UserId`: a floating "+Units 💧" (and "+N 🧼" for golden) BillboardGui
    rising 3 studs and fading over 0.7 s
- `"DishDone"`: a sparkle burst and a "✨ Sparkling!" label, plus "+Bonus 💰" if By is the local
  player. `"Sold"`: a coin sound and a big "+1,234 💰" popup near the coin counter (via `UIKit.Toast`
  or its own label). `"TankFull"`: an error sound.
- `SpinY` tag (CollectionService): rotate those parts locally about their Y axis at attribute
  `SpinSpeed`.
- `LiftPad` tag: when the local root is on a pad (within ~4 studs horizontally), teleport the
  character to the pad's `LiftTo` attribute with a puff of bubbles (1.2 s cooldown).
- Tool Shop prompts (`BuyTool` attribute) send `RunRequest("BuyTool", index)` and toast the result;
  the pedestal signs are refreshed on every RunState.
- Drain guide: while tank is full (or ≥ 95%), show a Beam from the local root to
  `RunState.DrainPosition` with an arrow-ish animated texture offset.
- Remaining markers: when ≤ `Config.Round.MarkerThreshold` grime parts are left in the arena's
  grime folder, add an AlwaysOnTop BillboardGui "✨" marker to each (local only).
- Prompts: `ProximityPromptService.PromptTriggered` → if `prompt:GetAttribute("OpenWindow")`,
  call `UIKit.OpenWindow(name, prompt:GetAttribute("EggId"))`.
- Lobby ambience: gentle floating bubbles near the camera (client-only, cheap). A run start banner
  "🧽 Clean every dish! 🧽".

---

## 6b. Tools, Ranks, Gems and Robux items (v0.3)

**Tools.** `Config.Tools` entries have a `Tier` and an `UpgradeMult`. In a run you own Bare Hands
and buy any other tool in any order (`BuyTool`), then pick the one in your hand from the HUD hotbar
(keys 1-6, click/tap, gamepad D-pad) or the Upgrade Book (`EquipTool`). `Config.Upgrades` entries
with `PerTool = true` (Power, Size) are bought separately for every tool and cost `x UpgradeMult`;
Tank and Sneakers are global. RunState carries `OwnedTools`, `ToolUpgrades` (per tool) and
`Upgrades` (the effective levels for the tool in hand). Dirt with `MinTool` above your tool's Tier
still cleans at `Config.Round.UnderTierMult` (20%), so nobody can get stuck. The tool in hand is
welded into the character's right hand (`ToolModels.Build(index, 0.42)`), re-attached after
respawns by the watchdog.

**Gems.** Premium currency on the profile (`Gems`). Drops: `Config.Gems.DropChance` per spot you
clean, `GoldenDrop` from golden dirt, `PerClear x level` per finished run. Also sold as developer
products.

**Ranks.** `Config.Ranks` (11 ranks, Common to Mythic, chances add to 100). `MetaRequest
"RollRank"` spends `Config.RankRoll.Cost` gems, rolls with `Config.RankWeights` (the x2 Luck pass
multiplies Rare+ weights), adds the rank to `profile.Ranks` and equips it if rarer than the current
one. `"EquipRank"` equips an owned rank. The equipped rank's `Effects` apply through
`Config.GetRunStats(..., rankId)` (PowerAll, ToolPower, Coins, Tank, Speed) and `Golden` doubles the
party's golden chance at `StartRound`. Odds are always shown in the Ranks window (gems can be bought
with Robux, so rolls are paid random items).

**Robux.** `Config.GamePasses` (all with a Price; Id 0 = test mode) and `Config.DevProducts`
(Bubbles, Gems and in-run Coins packs; Coins are x the level multiplier and turn into Bubbles if the
buyer isn't in a run). `MarketService.GrantProduct` gives a product's goods for both real receipts
and Studio test purchases (`MetaRequest "TestPass"` / `"TestProduct"`, allowed per
`Config.TestPasses`). A newly owned pass triggers confetti on the client.

## 6c. Tool modes, merging, rebirth and the economy (v0.4)

**Tool modes** (`Config.Tools[i].Mode`, carried in RunStats as `Mode`):
- `Scrub` (Hands, Sponge, Brush): a circle at the aim; short reach (12, the Brush 8 but very strong
  and Tier 2). Suds froth on the dish while you scrub.
- `Spray` (Nozzle): a circle at the end of a water beam; reach 34.
- `Line` (Pressure Washer): a thin line `LineLength x LineWidth` lying on the surface, turned with
  the camera's right vector; the client sends `Scrub(aim, true, { Dir, Normal })` and the server
  damages `GetPartBoundsInBox` along it. High power, so sweeping it across melts dirt.
- `Foam` (Foam Cannon): one blob per `FoamInterval`; the server makes a splat (`run.Splats`) that
  cleans everything in `Radius` at `Power * FoamShare` per second for `FoamSeconds` (foam loop every
  0.2 s, at most 4 live splats per player) and fires RunFX `"Foam"` so the whole party sees it.
- Size upgrades grow the circle / line / splat. Pets clean off `PetPower` (tool-independent).

**Economy.** Coins = units sold x `Config.Round.CoinsPerUnit` (4) x bonuses; dish bonuses use the
same multiplier. Tool prices are set against a run's income so every tool is reachable and skipping
to a big one is a real choice (pacing sim: L1 ~4-5 min, L2 ~7-9, L3 ~9-12 solo, no perks/pets).
Each level has a `Toughness` (dirt HP multiplier) on top of `Mult`.

**Pets.** 3 equip slots, 5 with the +2 Pet Slots pass (the Pet Slot perk is gone). `MetaRequest
"Merge" { uid, uid, uid }`: three pets of one rarity (below Legendary) become one pet of the next
rarity from the best egg any of them came from; it takes an equipped pet's slot. Pets window:
the 🔮 Merge button switches the grid into pick mode.

**Rebirth** (`Config.Rebirth`, the endgame). Clearing the last dishwasher sets
`profile.RebirthReady`. At the lobby's Rebirth Fountain (`MetaRequest "Rebirth"`, not in a run)
you pay nothing but must hold `Config.RebirthCost(rebirths)` Bubbles; Bubbles, unlocked levels and
perks reset, pets/gems/ranks/passes/best times stay, and you gain +25% coins and +50% Bubbles per
rebirth forever plus 50 gems.

**Parties** hold up to 8; the load grows `PartyGrimeScale` per extra player up to `PartyGrimeCap`.

**Bubble lifts** are bubble columns: standing in one carries you up at 18 studs/s, centring you,
and pushes you out onto the top rack (client, Effects).

## 6d. Round 6 (v0.5): cutscenes, pet tiers, name tags, dailies

**Tools.** The Brush is gone (Hands, Sponge, Nozzle, Pressure Washer, Foam Cannon). The washer's
line can be turned vertical/horizontal (T, D-pad Up, or the TURN touch button). Nozzle, Washer and
Cannon each have a game pass (`ToolNozzle`, `ToolWasher`, `ToolCannon`) that hands you the tool at
run start. The pass still starts at upgrade level 0, so upgrades keep mattering. Clicking a tool you
can't afford offers its pass (never coins for Robux).

**Pacing** (Config.Levels Toughness/ParTime): about 10 / 20 / 30 minutes solo. Parties get
`PartyWorkPerPlayer` extra dirt per player, capped at `PartyGrimeCap`, so a full party still takes
10-15 minutes on Family Dinner.

**Pets.**
- Every pet has Speed, Capacity (fixed by rarity and egg) and a coin bonus.
- Pets fill a bag while cleaning and carry it to the drain to sell. They earn coins themselves, not
  through your tank.
- Merging 3 identical pets (same tier) gives the Golden version (x1.35), and 3 Golden give
  Rainbow (x1.75).
- A tier never beats the next egg's rarity. The Pets and Egg windows show every stat.

**Ranks.** A roll replaces your current rank (the toast shows what you lost). A roll locks for
1.2 s so you can't roll again until the reel stops. The x2 Luck pass button sits under "Get more
Gems".

**Name tags** (server `NameTags`): a stud-sized BillboardGui showing the name (with ✨N once
rebirthed) and the rank in its rarity colour (default 🧽 Trainee). Rebirths also show in the
player list.

**Retention.** Daily rewards run on a 7-day streak (DailyUI pops up once per session). The Rebirth
window shows the count, bonuses and requirements. A rebirth is announced to the whole server.

**Cutscenes** (client `Cutscene` + `CutsceneScene`).
- When a run starts, each client fades into a short client-only scene built at
  `CFrame(8000, 400, 0)`: a family (pizza party / royal banquet variants) finishes eating, loads the
  dishwasher, closes it and presses start.
- The camera dives inside to reveal a tiny crew with sponges: us. There is no text.
- Skip (bottom-right, or Space/Enter/A/B) fades straight into the run, which is already going, so
  skippers start playing while others watch.
- The scene only plays when you join a run within its first 12 s.

## 7. Balance knobs (all in Config)

- Early pacing target: first purchase within ~30 s, Sponge within 2–3 minutes, and a solo Family
  Dinner clear in about 5–6 minutes.
- Party size scales total grime by `1 + 0.6 * (n - 1)`.
- Level `Mult` inflates every in-run number together. Difficulty comes from `Dishes`, `Spots` and
  `MinTool` grime.
- Eggs cost Bubbles only, and Bubbles can't be bought with Robux, so eggs are not paid random
  items. Odds are shown anyway.
- No speed boosts are sold for Robux. Sneakers is an in-run coin upgrade only.
