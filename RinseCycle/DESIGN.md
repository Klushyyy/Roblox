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

## 6e. Round 7 (v0.6): rewards, holding tools, camera

**Left lobby buttons** (HUD `LeftColumn`, lobby only): 🎁 Daily (red "!" when ready), 🎟️ Codes and
🎉 Free Rewards.

**Daily rewards** (`Config.Daily`, DailyUI, MetaRequest `ClaimDaily`).
- Claimed with a button, and the next one unlocks 24 h after the last claim (live countdown).
- The streak continues if you claim within `Grace` (24 h) after that.
- Missing it restarts at day 1, unless the player buys the `RestoreStreak` developer product
  (offered in the window).
- The window pops up once per session when a reward is waiting.
- Profile fields: `DailyLast` (os.time), `DailyStreak`. Old `DailyDay` saves are migrated.

**Codes** (`Config.Codes`, MetaRequest `RedeemCode`): once per player, any capitalisation, stored in
`profile.RedeemedCodes`.

**Community reward** (`Config.Social`, MetaRequest `ClaimGroup`).
- The client first tries to claim.
- If the player isn't a member yet, it opens `GroupService:PromptJoinAsync` and claims again when
  the prompt closes.
- The server checks membership live with `GroupService:GetGroupsAsync`, so no rejoin is needed.
- Like/Follow cards are reminders only: Roblox can't report likes or follows, and rewarding likes
  isn't allowed.

**Pets** show one number, Power (`Config.PetPower` = Speed x 100). Equipping with full slots offers
the +2 Pet Slots pass.

**Holding tools.**
- R15 players raise the right arm while holding a tool (client `HoldPose`, set every Stepped
  for all characters). The server weld undoes that rotation (RoundService `attachHeldTool`).
- The pressure washer in hand is just its gun and lance (`ToolModels.Build(i, scale, true)`), and
  the spray comes from its `Muzzle`.
- `CameraMinZoomDistance` is 0.5 (first person). HoldPose un-hides the tool and right arm when
  zoomed in.

**Camera vs walls.** Solid, visible arena and lobby parts are `CanQuery` true, so the camera stops at
walls instead of clipping through. All gameplay queries use Include filters.

**Cutscene v2** (20.5 s).
- Mum gets up with her own plate while the others slide theirs over.
- She walks waypoint paths around the table and the open door, facing where she walks.
- The plates stand in the rack; the counter is open around the dishwasher.
- She presses Start with her left hand, filmed from the right, then walks off.
- The door dissolves as the camera pushes in. The capped crew appears only once the door is shut:
  they turn, salute with their sponges and start scrubbing.

## 6f. Round 8 (v0.7): polish

- **Held tools** are welded to the torso at the raised right hand's spot (RoundService
  `attachHeldTool`), so they always point where you face, in first person too, whatever the rig
  or animations do. HoldPose raises the arm to meet the tool (R15/R6, Motor6D or
  AnimationConstraint).
- **Bubble column** (Effects `stepLift`): anywhere inside a lift column, walking, jumping or
  flying, you're pushed up at 22 studs/s with full air control. At the top you bob just above the
  rack and drift onto it unless you steer.
- **Pets:** rows of three behind you, spaced by the biggest pet's size (no overlap). The 🎒 bag
  bar shows only in runs. The Sponge Pup was rebuilt (rounded body, scrub-pad saddle).
- **Cutscene meals:** spaghetti and meatballs with bread, pepperoni pizzas, and a roast dinner
  with a turkey platter.
- **Cutscene collisions:** checked with an offline 0.1 s collision scan. Seated thighs rest on the
  seats and forearms on the table. Mum stands up clear of the table legs. Plates leave the stack
  sideways and slide straight into the rack.
- **No suds when scrubbing with bare hands.** In Studio, a pass without an ID is given free with
  a clear "Studio test" message.

## 6g. Round 9 (v0.8): run clock, aiming, water, admin

- **Run clock:** the timer starts when your client reports "Loaded" (the cutscene ended or was
  skipped, or you joined late). If nobody reports it, it starts after `Round.IntroMaxSeconds` (22 s).
  `RunState.ClockAt` is 0 while waiting, and the HUD shows 00:00:00.
- **Aiming:** (removed in v0.9: tools are simply held, see 6i.)
  Other players see a raised arm. Your own name tag hides in first person.
- **Water FX:** the Nozzle, Washer and Cannon fire from an invisible `Muzzle` part. Each has a
  two-layer beam, streaking droplets, and mist at the muzzle and at the splash. The held
  Pressure Washer lance is longer.
- **Follow / Like:** clicking checks straight away. A follow is read through the Roblox friends
  API via roproxy (turn on *Allow HTTP Requests*). If it isn't visible yet, the player is told to
  leave and rejoin, and the reward is settled on the next join. Likes can't be read by games, so
  they are granted on click.
- **Grime flicker:** every face of a splat sits a multiple of 0.03 studs above the spot's lift.
  Overlapping spots choose lifts whose face planes fall between each other's, measured from the
  real surface so curved dishes count.
- **Admin panel** (`ServerScriptService/Admin`, `AdminClient`): only the owner
  (`Config.Social.CreatorUserId`) gets the panel, or anyone in Studio. Open it with the 🛡️ Admin
  button (v0.9; the backtick key was removed). It uses the same command system as before: moderation, warnings, bans,
  mutes, logs, teleports and server tools. It adds Rinse Cycle commands: coins, bubbles, gems,
  ranks, pets, rebirths, gifted passes, the daily streak, and finishing a run.

## 6h. Round 10 (v0.8.1): water you can see, steadier aim

- **Water parts** (client `WaterFX`): the hose draws 20 thin see-through streams from the nozzle
  over the cleaning circle, plus a core stream. The pressure washer draws a flat sheet of water
  from the lance tip to its line (across or up and down), with streaks and a centre jet. They are
  real parts, not camera-facing Beams, so they don't vanish in first person. They are placed
  after the tool is aimed each frame (RenderStep Camera + 2).
- **Aim:** (replaced in v0.9: tools are simply held, see 6i.)
- **Follow reward:** paid when the follow check can't run (HTTP off, proxy down). A confirmed
  "not following" still asks the player to follow and rejoin.
- **Wording:** party pads pick a *level*, and the picker is headed LEVELS. How to Play has five
  steps (the bubble-flying step is gone). The cutscene bread basket was removed.

## 6i. Round 11 (v0.9): admin panel rebuilt, tools simply held

- **Holding tools:** the camera-aim tilt is gone. A held tool sits in your raised right hand
  pointing forward, the classic Roblox way. It is always fully visible: Roblox fades your
  character when the camera gets close (looking up, backing into a wall, first person), and
  HoldPose undoes that for the tool every frame.
- **Admin panel** (`AdminClient`, new): a UIKit window ("Admin") opened from an owner-only 🛡️
  Admin button under Free on the left (HUD.AddAdminButton; it stays there in runs). There is no
  key shortcut any more. Players on the left, command groups on top (Punish, Control, Move, Game,
  Server), the picked command's options with a RUN button at the bottom, plus a command line.
  Lists (bans, mutes, warnings, log, inventory) open inside the window with Modify / Remove / View.
  Everyone else only ever sees the effects (notices, announcements, status chips).
- **Mute** now sets Roblox's `TextSource.CanSend = false` on every chat channel (synced every
  second and right after any change, which also ends tempmutes on time). The delivery filter
  stays as a second line, and the muted player's chat bar is switched off with a 🔇 chip.
- **Offline tests:** `_tools/tests` runs the real server and client scripts in Lune (see its
  README). Every admin command, a full run, the lobby systems and the water parts pass there.

## 6j. Launch version (v1.0)

- **Store IDs:** paste every game pass / developer product ID (and the community ID) into
  `ReplicatedStorage > Shared > StoreIds`; Config applies them on start. See STORE_SETUP.md.
  Community: GroupId 920260021.
- **Transitions:** the screen fades to black when your party launches ("Filling the dishwasher...")
  and stays black through the teleport until the cutscene fades in (the server also waits 0.4 s
  before moving anyone). Leave, Back to Lobby and the automatic return after results fade the
  same way (Cutscene.Cover / Uncover).
- **Levels:** the dishwasher is identical in every level (ArenaBuilder's fixed palette). The room
  around it has its own bench: a home kitchen (cupboards), a pizzeria line (glass-front steel
  fridges, open shelving, an extractor hood) and a castle (stone arches with barrels, an oak top,
  plate racks). Counter height and footprint are unchanged, so play is the same.
- **Party pads:** polled every 0.1 s. Back / leaving puts you outside and that pad ignores you only
  until you've been seen outside it (after 0.6 s), so re-entry is instant but a late position
  update can't re-join you. No rejoin cooldown. Glass + invisible walls + lid hold members in.
- **UI:** far fewer emojis. Window banners are title-only, toasts are text-only, amounts read as
  words ("300 Bubbles"), and the HUD uses drawn icons (UIKit.Icon: Coin, Bubble, Gem, Drop).
  Item art (tools, passes, pets, ranks, levels) and the HUD buttons keep their icons.
- **Chat:** the place file sets TextChatService (ChatVersion 1, default channels), which :mute needs.
- **Output:** quiet. Admin logs only with VERBOSE; Studio's "not published" DataStore failures are
  silent; Main prints only failures and "server ready".
- **Admin:** :give removed; Give Coins shows a coin icon.

## 6k. The people in the room (v1.1)

- **LevelNPCs (client):** the cutscene's people live in each level's room during a run: giant R6
  figures at 50x scale (the same scale the furniture was built at). Client-only, anchored,
  non-colliding, non-queryable; moved with one BulkMoveTo per frame. Everything is a function of
  the loop time (`Workspace:GetServerTimeNow() % Period`), so a party sees the same moment.
  - Rig: arms and legs split at elbow/knee with hidden joint blocks (standing they read as one R6
    limb; they can sit with feet down and lift a fork). Arms are posed directly or by hand target
    (two-bone IK, cross-sections kept square to the body).
  - Plans: each character's loop is a list of steps (still / turn / walk / sitDown / standUp /
    swap for pick-ups); every plan fills the level's loop exactly. Props are held (hand / both
    hands / root) or placed on a timeline, so plates, pizzas and juice boxes are always somewhere.
  - Level 1 (60 s): Dad and the kid on the far side, Mum on the near side, Grandpa in an armchair
    in the corner (paper, tea, a nap). Mum carries the spare plates to the sink next to the
    dishwasher, washes them and brings them back; the kid fetches a juice from the fridge.
  - Level 2 (48 s): the chef slides a pizza into the brick oven, pulls it out and serves the right
    table from its end; two guests take the six slices in turns (they shrink as they're eaten); a
    kid has their own pizza at the other table; the waiter fetches sodas, takes an order, waves at
    the dishwasher and clears up.
  - Level 3 (60 s): the king on a throne at the head of the table (turkey leg, goblet, toasts,
    pointing at you), the queen and two nobles, a servant carrying the roast between the fire and
    the table, a juggling, cartwheeling jester, a guard on duty and a guard marching.
  - Where the room's furniture doesn't fit people this size (the family chairs, the pizzeria
    stools and one pizza, the castle throne and one chair) that client hides it
    (LocalTransparencyModifier) and the scene brings its own. None of it is reachable from the tub.
  - Offline checks: `_tools/tests/harness.luau npcscan<level>` dumps every NPC part every 0.25 s
    and `npccheck.py` reports parts sinking into the room or into each other (sitting contacts
    allowed). `npc<level>@<t>` + render.py photographs a moment.
- **Icons:** IconArt draws the HUD and level icons from frames (outline pass + fill pass per
  layer): Coin, Bubble, Gem, Drop, Gift (Daily), Ticket (Codes), Star (Free), Medal (Ranks),
  Shield (Admin), Lock, and the level emblems Pasta, Pizza, Crown. IconButton takes `Icon = "@Gift"`.
  `_tools/tests/guirender.py` renders a dumped GUI tree to a PNG for checking UI.
- **Arenas under the lobby:** the dishwasher row is built 2,500 studs below the lobby (the place sets
  FallenPartsDestroyHeight to -20000; Main also tries at runtime), so nobody in the lobby can see
  other games. The cutscene set is client-side at y -6000.
- **Party countdown:** 3 s when the party size is 1 (they just want to play), 30 s otherwise;
  changing the size to or from 1 restarts the countdown.
- **Name tags:** Roblox's own overhead names are off (StarterPlayer NameDisplayDistance 0, and every
  Humanoid's DisplayDistanceType None, re-checked every 2 s along with a missing-tag repair). No
  rank yet: the tag shows just the name. VIP: gold name overhead and in chat (Player attribute VIP,
  coloured by the client's ChatNames).
- **Invisible admins:** name tags follow the AdminHidden attribute on every client, and admin-chosen
  invisibility carries over a respawn, so toggling back always brings the tag back.

## 6l. Story chapters, lobby fun, rolls (v1.2)

- **Run-start cutscenes** were nine rotating chapters (three per level) built on far-away sets.
  Replaced in v1.3 by one linked story chapter per level (section 6m).
- **Lobby fun (LobbyFun service):** poppable soap bubbles float over the plaza (touch or click:
  +1 Bubble, golden ones +10; Config.LobbyBubbles, capped per minute), and six rubber ducks are
  hidden around the lobby (Config.Ducks; +25 each, +500 Bubbles and 10 Gems for all six; saved in
  Profile.Ducks, found ones hidden for that player via the DucksFound attribute).
- **Solid lobby:** the dishwasher building's front has one invisible collider over all its detail,
  and the display eggs, the soap shop's awning / bottle / pump, the doghouse roof and the table
  props are solid.
- **Rank roll popup:** rolling opens a full-screen reel of rank cards that spins while the server
  rolls, slows down and lands on the result (rarity banner, glow, confetti for Epic+), with Roll
  again / Close. The **Insta Roll** pass (39 R$) skips the spin.
- **Icons:** every IconArt shape is snapped to whole pixels (centred shapes stay exactly centred),
  outlines are whole pixels, and there are no font glyphs any more: new Shield (heraldic, drawn
  from a rounded body and a 45-degree point), Heart (Free), Paw (Pets), Cart (Shop), and a raised
  diamond where the stars were.
- **NPCs:** the jester plays to the players (always turned toward the dishwasher) and cartwheels
  along a clear lane; the king and queen sit clear of their thrones.

## 6m. No cutscenes; house detail, Top Players board, rebirth curve (v1.4)

- **No run-start cutscene.** The screen goes black when the party launches (hiding the teleport),
  and when the run starts the camera is put on your character in the dishwasher and it fades in
  (client `Cutscene`, kept as the fade module). The level's people still live in each room.
  v1.3's story chapters (Story / CutsceneKit) were removed.
- **The house around the lobby table:** wainscot panelling with a chair rail, crown moulding,
  ceiling beams, floorboard seams, red curtains on every window, two paintings, a fireplace with a
  mantel clock and a glowing fire, a bookcase, a sofa, and potted plants in the corners. Every
  piece that meets a wall, floor or ceiling overlaps into it instead of sitting flush; the offline
  coplanar-face check (zf6.py) finds no z-fighting candidates in the lobby.
- **Leaderboards:** the right-hand board is "Top Players" with arrows (and the Next page prompt)
  flipping between Most Dishes Cleaned, Most Rebirths and Most Bubbles Collected
  (RinseCycle_Dishes / _Rebirths / _Bubbles, Stats.BubblesEarned).
- **Rebirth curve:** 2,500 Bubbles for the first, +2,500 each time, capped at 20,000 from the 8th
  on. Perks keep stacking (+25% coins, +50% Bubbles per rebirth) and the Gem reward grows: 50, 60,
  70 ... up to 250 (Config.RebirthCost / Config.RebirthGems).
- **Party menu:** chapter cards show the chapter number big instead of the food emblems; the
  locked "Chapter 4 - More chapters coming soon" card and the finale banner stay.
- **HUD icons:** Shop 🛒, Pets 🐾, Free 🎉 and Admin 🛡️ are the original emoji again; Daily,
  Codes, Upgrades and Ranks keep their drawn icons.

## 6n. Private run servers, poppable bubbles everywhere (v1.5)

- **Runs happen in their own server (RunServers).** When a party launches in the live game, the
  lobby server teleports the whole party into a freshly reserved server of the same place
  (TeleportOptions.ShouldReserveServer) with teleport data { Mode = "Run", Level, Party, Lobby }.
  The run server waits for the party to arrive (up to 25 s) and for their saves to load (the
  DataService session lock makes it wait until the lobby server has saved and released each
  profile), then runs RoundService.StartRound as usual. The level is clamped to what the party
  has unlocked. When a player's run ends (results, Leave, Back to Lobby) they're teleported back
  to the lobby server they came from, or any public server if that one is gone or full. Late or
  unexpected arrivals are sent straight home. Clients in a run server (workspace attribute
  "RunServer") stay behind a loading cover until the run starts and while heading home.
  In Studio, unpublished places, or if the teleport can't start, the run is played in the
  current server exactly as before.
- **Bubbles:** the big bubbles floating over the table can be popped too (+1 Bubble, back in the
  same spot after 8-16 s), and the small ones drifting around the camera pop when you touch them.
- **How to Play board:** every step uses the same text size (31) instead of scaling per line.
- **Icons:** Free uses the drawn heart again (flat fill, round highlights only); the level cards
  show emoji (🍝 🍕 👑).

## 6o. Roof ladder, cleaner lobby props (v1.5.1)

- **Roof ladder:** a ladder (an invisible TrussPart with wooden rails and rungs) up the right side
  of the lobby's dishwasher building, so players can climb onto its roof. One rubber duck
  ("Shakers", hint "Up on the roof") now hides in the roof's back corner. (A rooftop obby was
  tried and removed.)
- **Doghouse (Pets):** a proper gable roof: wedge gables close the triangle, two planks sit on the
  slopes with an overhang, and a ridge cap covers the join.
- **Soap Shop:** the giant pump bottle behind it (it poked into the dishwasher) is gone.
- **Heart icon:** always drawn at 120 px and scaled down as one picture (UIScale), so small
  hearts are the big one shrunk rather than re-snapped shape by shape.
- **VIP:** a gold [VIP] tag before the name overhead and in chat; the name itself stays white.

## 6p. Live fixes: teleports, save handoff, pet slots, purchases (v1.5.2)
- Launching a party: every member is frozen and kept behind the black cover (player attribute
  `Teleporting`) until the teleport lands; pads ignore them meanwhile, so nobody is bumped out of the
  pad or starts a new party while leaving. A teleport that fails is retried (same reserved server via
  its access code) and, if it still fails, the player is unfrozen, told, and walked out of the pad.
- Save handoff: right before any teleport the player is saved with a `Handoff` lock; the server they
  arrive in may take that lock at once (within 2 minutes), so runs and lobbies load straight away.
- Run servers: party saves/characters are awaited in parallel; a party member who arrives after the
  run started joins it (RoundService.JoinLate) instead of being sent home. Going home now teleports
  to any lobby server (retried), not one specific server that may be full or gone.
- Pet slots: until the +2 Pet Slots pass has been checked, an on-sale slot pass counts as owned, so
  owners are never trimmed to 3 while the other passes are being checked.
- Purchases: "Congrats! You bought ..." only on a real purchase (game pass or developer product),
  never when owned passes are re-checked on joining a server.

## 6q. Trading, gifting, leaderboard resets, global announcements (v1.6)
- Pet trading (TradeService / TradeUI, lobby only): 🤝 Trade button -> pick a player -> they get an
  Accept / Decline invite. Both sides offer up to 8 pets, press Ready, and after a 4 s countdown
  PetService.Transfer swaps them in one step (fresh uids for the new owner, both saves written).
  Any change un-readies both; a party, run, teleport or leaving cancels the trade.
- Gifting passes (GiftService): every pass has a matching developer product in
  Config.GiftProducts ("Gift: VIP", Ids in StoreIds > GiftPasses). Buy -> "Buy for myself" or
  "Gift it to a friend" -> pick a player in the server -> Roblox prompt. On the receipt the friend
  gets the pass (saved in the same grant store as the admin's :givegamepass) and both get a
  Celebrate popup ("Successfully gifted..." / "X gifted you..."). Owned passes show a Gift button.
- Celebrate: a centred popup with confetti, also used for admin gifts (:givegamepass, :setrank,
  :promote -> "You've been gifted the X rank by an admin!").
- Admin :leaderboards: every board (Most Dishes / Rebirths / Bubbles, Fastest per level), top 100,
  ◀ ▶ to flip, Reset per row. A reset keeps the player's real stats: stat boards store an offset
  (RinseCycle_LbResets) so only what they earn afterwards counts; a Fastest board lists them again
  once they beat their old time.
- Admin :globalannounce: the announcement banner in every server (MessagingService).

## 6r. Pets pay as they clean, admin across servers, checked free rewards (v1.6.1)
- Pets have no bag any more: what a pet cleans is paid straight to its owner's coins, about once a
  second (PetService PAY_INTERVAL). No capacity meter over pets.
- A hidden admin (invisible, spectating, controlling someone; character attribute AdminHidden) has
  their pets hidden on every screen and not cleaning.
- :invis is remembered on the player (attribute AdminInvis): it survives respawns and every server
  hop (run servers, going home, :joinserver / :bringserver pass it in TeleportData.AdminInvis).
- :joinserver [username] goes to that player's server anywhere (GetPlayerPlaceInstanceAsync; run
  servers through their access code, kept in the "RinseCycle_RunServerCodes" MemoryStore map).
  :bringserver [username] asks the player's server (MessagingService) to send them to yours.
- :viewpets replaces :viewinv / :clearinv: every pet a player owns, Remove per pet, "+ Add pet"
  (pet + Normal / Golden / Rainbow). :givepet works in live servers too.
- The Admin button sits at the bottom of the right column (Trade took its old spot on the left).
- Leaderboards read every board the moment the server starts (all boards and names at once),
  refresh every 60 s, and the board SurfaceGuis draw from 5000 studs.
- Free rewards: Follow is only paid when the follow is actually seen (needs "Allow HTTP Requests");
  "Like the game" became "Favorite the game", checked with AvatarEditorService (likes can't be
  checked by any game). Since v1.6.7 the card reads "Favorite & Like the game"; only the
  favorite is checked.
- Faster hops: 3 s handoff cap, 12 s party arrival wait (late members join the run going),
  bigger build steps in run servers, shorter fade-in.

## 6s. Trade requests (v1.6.2)
- The Trade window lists everyone with a Request button ("Click someone to request to trade with
  them"). A sent request shows "Requested..." with a Cancel button; the receiver's invite popup
  closes if it's cancelled. The same player can be asked again only after 2 minutes, whatever they
  answered ("Wait m:ss" on the button); after one accepted trade the two can ask each other freely.
- Both press Ready, then "Trading in 3... 2... 1..."; either can un-ready or cancel meanwhile.

## 6t. Staff ranks (v1.6.3)
- :setadminrank (owner only): Moderator / Admin / Developer, or clear. Saved in the
  "RinseCycleStaffTiers" DataStore (one record: userId -> { Tier, Name }), applied at once (panel
  built / changed / removed, AdminInfoChanged) in every server (MessagingService), no rejoin.
  :stafflist shows every staff member, online or not, with Remove.
- Moderator: kick, mute, tempmute, warn, warn list, mute list. Admin: every Punish command plus
  Go to, Join server, Spectate. Developer: every command except the owner's own (staff ranks,
  gifted passes, wiping the log). Staff can't use commands on staff at or above their own rank.
- Tags (player attribute StaffTag): [MOD] green, [ADMIN] red, [DEV] blue, [OWNER] purple, overhead
  and in chat, in place of [VIP].
- The Admin button is back under Trade in the left column (in a run it's alone there, clear of
  the timer).

## 6u. Spawning can't get stuck; chat above name tags (v1.6.4)
- Main turns spawning off only until the lobby is built. A missing / broken service is warned about
  and skipped (need()), a 15 s failsafe turns spawning on whatever happens, and a watchdog spawns
  anyone still without a character (and logs "[Rinse Cycle] spawning X (...)" so the cause shows).
- Chat bubbles sit 2.4 studs higher (BubbleChatConfiguration.VerticalStudsOffset), above the tag.

## 6v. All-servers list, stealth joins (v1.6.5)
- Roblox's own Tab player list is used (a custom one that could leave invisible admins out was
  tried and taken back out), so an invisible admin does show on it. The Trade and Gift pickers
  leave players with AdminInvis out.
- :serverlist ("All servers"): each server writes its players to the "RinseCycle_ServerList"
  MemoryStore sorted map every 30 s (90 s expiry). The admin sees everyone everywhere with Join
  plus "Busiest server".
- Joining another server (the list or :joinserver) always arrives invisible (AdminInvis), so
  nobody sees you join; :invis brings you back.

## 6w. Music, the stay boost, a faster start, guest admins (v1.6.6)
- Music: MusicPlayer plays the Lobby or Run playlist (StoreIds > Music, shuffled, faded). A
  "Music" button in the left column (lobby only) mutes it for the session.
- Stay boost: opening the Roblox menu shows "Don't go yet!" (once a session) offering a free
  x2 Cleaning boost for 15 minutes, once per UTC day (Profile.BoostUntil / StayBoostDay). It
  doubles Power and PetPower in computeStats. A timer chip shows while it runs.
- Faster start: Family Dinner Toughness 5.5 -> 1.8 plus 20 starting coins; level 2 6.0 -> 4.5.
  Ads showed ~56 s average play, so the first minute has to pay out fast.
- Server list: one row and one Join per server (its players listed underneath); your own
  server and hidden admins aren't listed or counted.
- An admin joining a run server is a guest: invisible, put into the run (JoinLate) once it's
  going, and sent home when the run ends or every real player has left.
- v1.6.8: the stay popup is near full-screen and loud ("WAIT! DON'T LEAVE YET!", pulsing claim
  button). A claim is saved within 2 s, so leaving and rejoining can't claim twice; the boost ends
  (stats recomputed) on whichever server the player is on. Boost badges sit under the Bubbles
  pill (moved in v1.6.9): the x2 Cleaning timer plus one chip per owned multiplier pass. The run progress bar moved
  down to y 90 to make room.
- v1.6.9: the badges moved to a column just right of the left-hand buttons (it follows the
  HUD's LeftColumn), clear of toasts, the progress bar and the player list; the progress bar is
  back at y 72. Pets' "+coins" floats over the pet that earned it (Sold carries Slot). The drain
  looks like a sink drain: chrome rim, dark gap, steel strainer with 1 + 6 + 12 holes, a film of
  water. Roblox's player list can't be moved by a game, so on PC (lobby) the Shop/Pets/Ranks
  column sits below it, estimated as 48 + 40 px per player, while there's room.

## 6x. Scrolling leaderboards with your position; owned passes keep their price (v1.7.0)
- Lobby boards show the top 100 (ScrollingFrame). BoardView moves each board's SurfaceGui into
  PlayerGui (Adornee = the board) so the mouse wheel / a finger scrolls it; Effects finds the
  moved GUI for the arrows (BoardView.GuiOf).
- Under every page, a gold "you" row: "#rank  name (you)  value", from the player attribute
  Lb_<D1..D3|T1..Tn> = "<rank>|<value text>". Ranks past 100 come from a background scan of the
  OrderedDataStore (100 per read, up to #1000, at most every 5 min per board, only while the
  GetSortedAsync budget is above 4). Past #1000 reads "#1000+". Your top-100 row gets a gold outline.
- Rows are only rebuilt when a board changes, and use TextStroke instead of UIStroke (fewer
  instances to replicate).
- Admin Leaderboards view: served from the boards' cache (instant). The client caches pages it
  has seen and ignores late replies for pages already flipped past; only Reset is serialized.
- Shop passes: an owned pass keeps the green R$ price button, with a small "Owned" above it. Its
  buy window shows a grey "Game Pass already owned" and "Gift it to a friend".

## 6y. Back buttons, Roll to the Gems shop, a clearer pets window (v1.7.1)
- UIKit.OpenSubWindow(name, arg, parent, parentArg): the window's X becomes a blue "<" Back, and
  Back / Escape / B reopen the parent (UIKit.GoBack). Used for PassBuy (back to Shop > Passes) and
  for the Gems shop opened from Ranks (back to Ranks).
- Ranks: "Get more Gems" is gone. ROLL with too few gems opens the Gems shop (a sub-menu of
  Ranks); "Roll again" in the popup does the same.
- Pets: Golden and Rainbow pets are shown by their card (gold card and gold name; rainbow edge
  that slowly turns and a rainbow name), not by a word in the name. The selected card gets an
  aqua ring outside it, a tint and a SELECTED tag (a separate frame: a card shows only one
  UIStroke). Equipped pets get an EQUIPPED tag. In merge mode picks get a green ring and a number,
  pets you have 3+ of show "xN", and the panel previews the pet you'll make. "Auto-pick 3" picks
  the first set of 3 identical pets, unequipped ones first.
- Boost badges are all one width with left-aligned text, so they line up.
- v1.7.2: in a run the left column keeps Daily and Music (plus Admin for staff); Codes, Free and
  Trade are lobby-only.
- v1.7.3: badges grouped by colour. v1.7.4: badges live on their own screen layer (DisplayOrder 4)
  under every window; pet cards are 172 px tall so EQUIPPED sits under the stats line; Rainbow
  pets keep one smooth rainbow fade (bottom to top, 0.3 of the wheel) that slowly cycles
  (PetModels.StartRainbow, tag "RainbowPet", started by PetRenderer) instead of a patchwork of
  part colours.
- v1.7.5: pets show "Cleaning speed N/100" (Config.PetSpeedRating: speed / the fastest Rainbow
  pet's speed, so Rainbow Kraken King = 100) with a bar, and "Coin multiplier x1.NN"
  (Config.PetCoinMult); the header shows the equipped pets' total ("Coins x1.34"). Coin bonuses
  were trimmed at the top: Rubber Duck x1.04 ... Kraken King x1.38 (Rainbow x1.67). Three starter
  ducks give x1.12, five Rainbow Krakens x4.3 (was x6.25, more than the paid x2 Coins pass).
- v1.7.6: Golden / Rainbow pets keep their normal colours. In the world they get a soft halo
  (locked particle), drifting sparkles and a PointLight, gold or rainbow. In menus the card keeps
  its normal colour with a gold (or turning rainbow) edge and a small GOLD / RAINBOW tag under the
  pet; the detail panel says "Rainbow • Epic". The colour-cycling rainbow (v1.7.4) is gone.
- v1.7.7: hatch buttons read "Hatch 1 (50 Bubbles)". Short of Bubbles they're grey but still
  clickable: a click opens the Bubbles shop (locked eggs stay disabled; a full pet bag says so).
  Only the gift window (PassBuy) keeps a Back button; the Gems shop opened from Ranks has a plain X.
- v1.7.8: Golden / Rainbow pets: a big halo (size 5-6.5, 8/s), 28-40 sparkles a second bursting
  off them, and a brighter light (2.5, range 12); rainbow particles run through every colour.
  Merge mode hides pets you can't merge (fewer than 3 of that pet and tier, or Rainbow already);
  after the first pick only that pet shows. Nothing to merge: "You don't have 3 of the same pet
  yet..." over the grid; the merge panel notes "Only pets you have 3 or more of are shown."
- v1.7.9: x2 Luck now truly doubles Rare+ odds (Mythic 0.5% -> 1%, Legendary 2.5% -> 5%; Rare+
  25% -> 50% in all), taking the extra from Common / Uncommon (x2/3) so the total stays 100%.
  Before, doubling only their weights made them about 1.6x. Ranks panel: a green "x2 LUCK ACTIVE"
  badge in place of the buy button; boosted rows get an "x2" tag and "was 0.50%" under the
  chance; without the pass they show "x2 Luck: 1.00%". Footer: "Rare ranks and higher are 2x as
  likely with x2 Luck."
- v1.8.0: tier effects toned so the two read differently: no PointLight (it bleached pets and floor
  yellow), a softer halo (LightEmission 0.35, size 3.4-4.2), Golden = 18 gold sparkles/s, Rainbow =
  six single-colour emitters (red, orange, yellow, green, blue, purple; 4/s each).
- v1.8.1: the Shop's Coins tab only shows in a dishwasher (coins only exist there); in the lobby
  it's hidden and a request for it opens Perks.
- v1.8.2: Golden / Rainbow pets also leave a small solid Trail while they move (two attachments
  behind the body, ~0.5-1.6 studs tall, 0.5 s, faces the camera): gold, or a red-to-purple
  rainbow ribbon. Particles alone were hard to tell apart.
- v1.8.3: Trade moved to the right column (under Ranks). Boost badges are smaller (124 x 22, 14 px
  text) and stack above the left column; on PC the HUD slides the column down to fit them
  (LocalPlayer attribute BadgeStackHeight); where there's no room (phones) they go beside it.
  The rainbow trail is six thin single-colour trails stacked top to bottom (a striped ribbon);
  gold stays one tapered trail.
- v1.8.4: T opens Trade in the lobby (in a run T still turns the pressure washer); the Trade
  button shows a "T" key hint like G / P / R.
- v1.8.5: the gold trail is striped too (four gold shades stacked), like the rainbow one.
- v1.8.6: boost badges fill columns of four (then a second column to the right), so the stack
  above Daily is never taller than four badges.
- v1.8.7 (phones): tap or hold on the dirt to clean exactly there (SprayController aims from the
  finger with ScreenPointToRay; touches on buttons / the thumbstick are ignored); no SPRAY button
  and no centre dot (gamepad keeps the dot). The washer's TURN button sits bottom right, left of
  the jump button. Coins / tank / fly bar are bottom-left on phones too; the run timer is centred
  under the progress bar on phones. Toasts start below the progress bar while cleaning
  (UIKit.SetToastTop), on every device.
- v1.8.8: hold-jump-to-fly works on phones (JumpRequest only fires once per tap there, so
  BubbleJets also reads Humanoid.Jump and Roblox's touch JumpButton being held). New "Pets On /
  Off" button in the left column (all devices, lobby and runs): off, pets just follow you and
  don't clean. Saved in the profile (PetsResting), mirrored on the player attribute PetService
  reads; MetaRequest "SetPetsResting".

## 6z. Global admin events, referrals, notifications (v1.9.0)
- Pets On / Off shows only in runs (in the lobby pets only follow). Hidden pets (invisible admin)
  also switch off their particles, trail and light (PetRenderer.setHidden).
- Admin panel > Global (new tab): Global announce, All servers / Join / Bring (moved here), and:
  - Poll (Developer+): 30 s / 1 min / 2 min, "Question | answer | answer" (2-4 answers, chat
    filtered). Every server shows a vote card (PollUI); each server counts its own votes and sends
    the counts back to the admin's server, which banners the results everywhere.
  - Give everyone (owner): Bubbles / Gems / Coins (coins only reach people in a dishwasher).
  - Pass drop (owner): 1-25 random players across every server (from the server list, hidden
    staff left out) win a pass; already own it = another pass they don't have, or 50 Gems.
  - x2 boost (owner): x2 Cleaning for everyone for 1-180 minutes (DataService.AddBoost).
  All ride one MessagingService topic, "RinseCycle_GlobalEvent"; without it (Studio) they run in
  this server only and the admin is told so.
- Referrals: Free Rewards > Invite friends opens Roblox's invite prompt with LaunchData = your
  UserId. A NEW player (no runs, dishes or rebirths, never referred) joining through it gets
  Config.Social.ReferredReward; the inviter gets ReferralReward (straight away in the same server;
  otherwise queued in "RinseCycle_ReferralPending" and paid via MessagingService or on next join),
  up to MaxReferrals.
- Notifications: Free Rewards > Turn on notifications, and once a session after a daily claim,
  shows Roblox's experience-notification opt-in (when Roblox allows). Sending notifications is
  done outside the game (Creator Hub notification string + Open Cloud).

## 6za. Clubs, Treasure Chests, ad luck, Next Event (v2.0.0)
- HUD: the right-hand buttons are a grid two wide (lobby: Event, Shop, Pets, Ranks, Clubs, Trade;
  run: Upgrades, Shop, Pets, Leave). C opens Clubs.
- Rank luck from ads (RanksUI "+20% Luck WATCH AD (n/5)"): ShopService "WatchLuckAd" shows a
  Roblox rewarded video ad (AdService) whose reward is the developer product
  Config.EventProducts.AdLuck; its receipt adds a stack (DataService.AddAdLuck, 15 minutes, up to
  5). Luck = (1 + 0.2 x ads) x 2 with the x2 Luck pass (Config.LuckMult): 5 ads = x2, x4 with the
  pass. Studio without a product Id: a free stack.
- Treasure Chest event (Config.ChestEvent, EventService, ChestUI, the lobby chest): 1 free chest
  per event (profile ChestEventId / ChestFreeUsed), then x1 49 / x3 139 / x10 349 R$ developer
  products (cinema-popcorn pricing: x3 barely cheaper per chest, x10 the big BEST VALUE). Odds
  are listed beside the packs. Rewards: Bubbles, Gems, x2 Cleaning, two event-only pets (Coral
  Crab, Treasure Turtle, Golden too) and a 0.5% random game pass (saved like a gift). A full bag
  turns a pet into Gems. Bought chests open on the receipt and are revealed via ChestResult.
- Clubs (ClubService, ClubsUI): CLUB / TOP CLUBS / FIND tabs. Make one for 500 Gems: name and tag
  (letters / numbers, Roblox-filtered, unique names), public or private (club code), requirements
  (level beaten 0-3, rebirths). Max 25. Owner: settings, new code, kick; leaving passes ownership
  to the longest member, the last one out closes it. Points = Bubbles members earn while in it
  (flushed every minute); TOP CLUBS = top 25 (OrderedDataStore). The tag shows after members'
  names. 60 s cooldown between joins. Kicks reach other servers over MessagingService, and the
  membership is re-checked on join. Studio without API access: clubs live in server memory.
- Next Event spot (LobbyBuilder ring + banner, EventZone): walking in shows the next event from
  Config.UpcomingEvents with a countdown and Notify Me (Roblox's event RSVP when RobloxEventId is
  set, otherwise the experience-notification opt-in).

## 6zb. Badges and "daily reward ready" notifications (v2.0.1)
- 10 Roblox badges (Config.Badges, IDs in StoreIds > Badges), given by BadgeAwards: Welcome, each
  level cleared, first pet, a Golden pet, first rebirth, a Legendary+ rank, joining a club, 1,000
  dishes. Checked on load and every 5 s; awarded ones are noted in the profile (BadgesGot). A
  badge without an ID is skipped (not noted), so it's given out as soon as its ID is pasted in.
- DailyNotify: claiming the daily reward queues the player in a MemoryStore sorted map for 24 h
  later; each server polls the due entries every minute, takes one atomically and sends Open
  Cloud's user notification (notification string StoreIds > Notifications > DailyReady, parameter
  "streak", launch data "daily"), API key from the secret "OpenCloudKey". Players in the server
  are skipped. Off in Studio and until a string ID is set.

## 6zc. Clubs v2, the chest at the chest, poll card, autocomplete, new icons (v2.1.0)
- Insta Roll is gone (pass, gift and button): every rank roll spins.
- Treasure Chest: no window. The chest in the lobby (facing the spawn, no shared faces) has a
  per-player odds board and "1 FREE CHEST!" (hidden once used). Walking up shows OPEN 1 / 3 / 10
  boxes at the bottom of the screen (E opens one); opening flips the lid and spins a card per chest
  that lands on the prize (rarest last, confetti for Epic+). The Event button and E elsewhere in the
  lobby take you to the chest.
- Next Event ring: Roblox's own event pop-up (SocialService:PromptRsvpToEventAsync) when the event
  has a RobloxEventId (StoreIds > EventIds); otherwise our card with NOTIFY ME / NO THANKS. The
  first event is Admin Abuse, 17 Oct 2026 11 pm NZ.
- Clubs v2 (ClubService rewritten): prefix (2-5, "?" explains it) instead of tag; Owner / Co-Leader
  / Member (owner promotes with a warning; co-leaders kick members; owner kicks anyone); rename and
  re-prefix once each every 30 days (own timers, first change free); confirm before leaving /
  closing; "Creating..." overlay; tabs MY CLUB / TOP CLUBS / FIND CLUBS / LEADERBOARD / CHAT.
  FIND lists clubs starting with the text A to Z (the "dir_<letter>" shards) and a code finds its
  club; Filters (type, friends in it, can join, not full) with Back. Members earn the club points
  and their own (club leaderboard). Club chat: filtered, last 60 kept ("chat_<id>"), live via
  MessagingService / ClubChat.
- Poll card: under every window (hidden while one is open); voting tucks it away behind a POLL tab;
  when the results are in it comes back as POLL FINISHED with each answer's votes and percent until
  closed. No results banner, no duplicate message.
- Admin panel: the group tabs scroll sideways; the command line (and name boxes) suggest as you
  type like Minecraft (Autocomplete): commands, then players, then each option; Tab completes,
  Up / Down choose, no tab character is ever typed.
- Icons: Pets (puppy), Shop (bag), Trade (arrows), Clubs (friends), Music (notes), Admin (gavel),
  Free (heart) redrawn without rotated frames (Roblox doesn't anti-alias rotated frames, which is
  what made lines go jagged at some sizes): discs, rounded rectangles, rings and gradient-cut
  triangles only, drawn at one size and scaled (IconArt header).
- Pets On / Off only shows in a run when you have pets out. Music: lobby track and two run tracks
  that crossfade into each other.

## 6zd. Club contest, loading dots, notifications, event countdown (v2.2.0)
- UIKit.Busy("Deleting"): a card with three bouncing dots over everything while something slow
  happens (only if it lasts over 0.3 s; `immediate` skips the wait). ClientState.MetaRequest uses it
  for the slow actions; Clubs uses it for create / join / leave / rename / donate. After buying a
  pass or product the dots say "Confirming your purchase" for 5 s (Roblox's own box takes that long
  to go), then the congratulations (ShopUI).
- Clubs: the window knows you're in a club from the save (meta.ClubId) and shows dots, never the
  Create page, while the club's details load. The "?" for the prefix sits inside the text box.
  Points = Bubbles DONATED to the club (DONATE BUBBLES on MY CLUB, 100 / 1,000 / 10,000 / all).
  TOP CLUBS = most donated this month; click any club for its members and what each gave (private
  clubs show too, they just need a code to join). MY CLUB lists each member's donations; LEADERBOARD
  ranks them. Monthly contest: on the 1st (00:00 UTC, shown in each player's own time) every club
  starts from zero (lazily: Club.Season, per-month OrderedDataStore "RinseCycleClubPoints_YYYYMM");
  the finished month's top 3 clubs are recorded ("season_YYYYMM") and each member is paid on their
  next join: 300 / 200 / 100 Gems, and #1's members also get the limited Champion Dragon pet
  (Config.Clubs.Season; profile ClubPrizeSeason says it's been paid).
- Limited pets (Config.Pets .Limited): Treasure Chest pets and the Champion Dragon are tagged
  LIMITED in the Pets window, the chest odds and the reveal. The pets cards now have one line each
  (name / rarity / speed / LIMITED / EQUIPPED) so nothing overlaps.
- Treasure Chest: stone steps, a glowing ring (11 studs) on the floor: the Open buttons show only
  while you're inside the ring. Higher, bigger, more detailed ("LIMITED TREASURE CHEST"), odds board
  higher above it.
- Notifications are never offered on their own (the one after a daily claim is gone): only from
  Free Rewards > Turn on notifications and the Next Event spot. One message only ("Notifications are
  already on"). The Admin Abuse event is linked to the real Roblox event (StoreIds > EventIds), so
  walking into the ring shows Roblox's own event pop-up.
- :globalcountdown <time> [name] / :cancelcountdown (owner): a countdown pill top-left on everyone's
  screen in every server (MemoryStore hash map "RinseCycle_Countdown", re-read each minute), turning
  into "<NAME> IS LIVE NOW!" for an hour.
- Ads: at the max stacks the button says MAX AD BOOST and no ad is shown. Upgrades and Leave have
  drawn icons (Book, Door) like the rest.

## 7. Balance knobs (all in Config)

- Early pacing target: first purchase within ~30 s, Sponge within 2–3 minutes, and a solo Family
  Dinner clear in about 5–6 minutes.
- Party size scales total grime by `1 + 0.6 * (n - 1)`.
- Level `Mult` inflates every in-run number together. Difficulty comes from `Dishes`, `Spots` and
  `MinTool` grime.
- Eggs cost Bubbles only, and Bubbles can't be bought with Robux, so eggs are not paid random
  items. Odds are shown anyway.
- No speed boosts are sold for Robux. Sneakers is an in-run coin upgrade only.

## 6ze. Level 2 is the Backyard Sink (v2.3.0)

- Level 2 ("Pizza Party") is no longer a closed pizzeria. It plays outdoors: the basin is a white
  porcelain **sink** (no ceiling, rolled rim, overflow slot) with a chrome gooseneck tap, hot and
  cold handles and a running stream; the counter has a hole over it. The racks, lifts and dishes
  work exactly as before.
- Around it (ArenaBuilder `buildYard`, `buildFaucet`): lawn, ring of hills and far snowy mountains,
  18 trees, a picket fence, a two-storey house with porch, roof and flower beds, a barrel BBQ with
  smoke, parasols, string lights on poles, and clouds. The pizza oven, checkered picnic tables and
  stools stay where they were so the chef and guests (LevelNPCs) still line up.
- No walls or ceiling: invisible barriers at the old room edges keep players on the patio. Scenery is
  non-colliding and stays within +-490 studs of the slot's X so neighbouring arenas never overlap.
- The Place name is now "Backyard". Level 3 (bigger castle) is next.

## 6zf. Backyard Sink v2, admin tools, Chapter 4 (v2.4.0)

- Level 2 is a true shallow sink (34 deep) in a low outdoor counter (top at 40). There is no ceiling
  and no walls; the old top rack is a chrome dish drainer standing over the sink on four posts.
  The front is a wooden drainboard on legs. A chrome tap with a particle water stream stands on the
  back of the counter. The shallow basin lets you see the house, trees and mountains over the rim.
- Three overlapping rings (green hills, rocky mountains, snowy far peaks) close the horizon all round.
  Trees are oaks (trunk, flare, branches, leaf-ball canopy) and layered pines. The oven is rebuilt
  (brick base, barrel vault, flat front with an arched mouth, firewood alcove). The BBQ moved so the
  waiter's route stays clear. Clouds are gone.
- New dishes: wooden pizza boards (Board) and pizza cutters (Cutter), level 2 only. Kinds can share
  rack rows now (ArenaBuilder keeps a taken-slot set).
- Arena slots are a grid (4 per row, ArenaSpacing 2400 x 3200) so mountains never overlap neighbours.
- The lobby is built on every server, high above the arenas, so while in a run its parts are made
  invisible locally (ClientState) instead of hanging in the sky.
- Admin: `:noclip` gives/takes a No Clip tool (hold: fly through walls; click: teleport). `:giant`
  scales a character (2 to 30). `:abuse` is the Admin Abuse show: huge, glowing, rainbow, flying,
  announced, auto-ends.
- Party window: the Chapter 4 card opens the Roblox event RSVP (StoreIds > EventIds > Chapter4).
- Clubs: the points help dialog grows to fit its text. Chest product IDs are filled in StoreIds.

## 6zg. Rewarded ads follow Roblox's flow (v2.4.1)

The "+20% luck" ad is Roblox's built-in rewarded video ad. Flow: the client checks
`AdService:GetAdAvailabilityNowAsync(Enum.AdFormat.RewardedVideo)` (RanksUI; skipped in Studio), the
server creates `CreateAdRewardFromDevProductId(StoreIds.Events.AdLuck)` and calls
`ShowRewardedVideoAdAsync`, and Roblox grants the product through ProcessReceipt (MarketService) once
the ad is watched to the end. Needs a developer product worth 3 to 10 R$ and an ads-eligible game
(2,000+ monthly visitors, approved maturity questionnaire).

## 6zh. Backyard polish, friend luck (v2.5.0)

- The ad luck is gone (ads need 2,000 monthly visitors). Luck now comes from invited friends: +10% each
  who joins through your invite, up to 10 (x2), doubled by the x2 Luck pass (x4). Config.RankRoll.FriendLuck,
  Config.LuckMult(hasPass, friends). The Ranks window button opens Roblox's invite prompt
  (RewardsUI.Invite). AdLuck product, request and registration are removed (data fields stay, unused).
- Backyard: invisible fence round the sink up to a lid at 420 (nobody reaches the counter or roofs);
  the front frame bar is gone; drainer posts sit under the rack's corners; boards stand square like plates;
  BBQ moved, lid no longer z-fights, handle has brackets; string lights hang from poles tall enough to
  hold them; pizza boxes left the floor; pizzas and box stacks sit on the benches.
- Mountains are a polar heightmap of triangles, each drawn as two WedgeParts (rolling hills, rock, snow,
  ridge at 900-1500 studs). Trees copy the lobby's style (crossed-box hex trunk, turned canopy blocks).

## 6zi. Admin Abuse show (v2.6.0)

Runs on its own in every server from the AdminAbuse event's Starts time (Config.UpcomingEvents), driven by
Config.AbuseShow and the clock Config.Now. AdminServer's "Admin Abuse show" section:
- 30 / 15 / 5 / 1 minutes before: banner warnings. Rounds can't start (Config.EventLockdown, checked in
  PartyService Create and StartNow) from 30 minutes before until the show ends (15 minutes after the start).
- At the start: "ADMIN ABUSE IS LIVE!", anyone in a run goes back to the lobby, and in lobby servers a giant copy
  of the owner (Players:CreateHumanoidModelFromUserId, ScaleTo 30, default R15 walk) paces round the room.
- Chat lines "[Owner] EnderBuilda: ..." (Remote AbuseSay -> AdminClient -> chat window) on a timeline.
- Votes (Rounds): one server claims each round in a MemoryStore hash map, runs the existing global poll (counts
  from every server), then applies the winner: Bubbles/Gems are split between everyone online in every server
  (GiveAll), Passes runs the pass drop. No votes = the first option.
- `abuseshow` is in the panel's Studio tab (shown in Studio, and to the owner account live): pick "Start in 15
  seconds / 1 / 5 / 20 / 30 minutes" or "Back to the real time" and the whole show runs in every server from then.
  The old `:abuse` (rainbow giant) command is gone. Test: scen_abuse.

## 6zj. The castle hall and phone text (v2.7.0)

- Level 3's hall is much bigger (ArenaBuilder sets the room per build: half width 780 instead of 420, depth to
  z -1000, height 860). More pillars (every 150 studs, fireplace bay skipped), a ribbed stone vault of arches under
  the ceiling, tall stained-glass windows with pointed tops in every bay, a gallery walkway with balusters and
  corbels along both side walls, taller banners, five large chandeliers. The table, throne and NPC spots are unchanged.
- Phone text: UIKit raises any label that would land under 10 real pixels on a small touch screen (screen scale
  under 0.8), up to 1.45x its design size (PHONE_MIN_PX / PHONE_MAX_BOOST). Windows already shrink to fit.
- The HUD's FREE tag sits on the Event button's top right corner so it no longer covers the label.
- Check: `scen_mobile` sets phone-sized screens (844x390 and 390x844) and dumps windows; `mobaudit.py` lists text
  that lands under a size (labels set to scale to their box are an upper bound). Real devices still need a look.

## 6zk. The Royal Wash Trough, a better giant, countdown, notification test (v2.8.0)

- Level 3 keeps the royal banquet hall but its "machine" is now an olden-day oak washing chest: oak planks bound with
  iron hoops, straps and a banded lid (closed, like the dishwasher: nobody can climb out), a wooden drawbridge
  walkway on stone piers with iron bands and two iron torch stands, and black iron racks. (v2.8.0's open trough and
  gargoyle looked like a sink and are gone.) Glasses are now gold goblets (new dish kind Goblet, cup 55% of its height).
  Three levels, three kinds of dishwasher: steel machine, porcelain sink, oak trough.
- Admin Abuse giant: built from the owner's HumanoidDescription (hair and all), only the root anchored so the default
  R15 walk, idle, wave, point and cheer animations really play; feet measured onto the room floor; every stride
  stomps (dust, shockwave ring, AbuseBoom shakes every screen by distance); he pauses to face the table and wave; a
  beam attack every 50 s (showy, hurts nothing); he stays until the event ends and mutters Config.AbuseShow.Remarks.
  The show opens with three booms, a flash and an ADMIN ABUSE title. His lines show in a typed speech box (and chat).
- A small pill at the very top right counts down from 30 minutes ("ADMIN ABUSE IN 29:41"), then "ADMIN ABUSE IS LIVE!".
  The schedule reaches clients through ReplicatedStorage attributes AbuseStarts / AbuseEnds.
- DailyNotify tries several secret names (Config.DailyNotify.SecretNames), and the Studio tab has "Notification test".

- v2.8.1: the invisible walls round the Backyard sink and the drawbridge are now 8 studs thick (a thin 1-stud wall could be tunnelled by a fast flier). The intro title is hidden (not just transparent) until the show opens.

## 6zl. Admin Abuse v2: three rounds, scaled prizes, a giant that stays on the floor (v2.9.0)
- Prizes scale with the players online in every server (`Config.AbuseOption`): Bubbles/Gems are `PerPlayer` each (the poll text shows the pool, PerPlayer x n); Passes/Pet pick a Share of the players (rounded up, min 1) as winners.
- Round 1 (poll): Bubbles vs Gems. Round 2 (announced, no vote): random game passes. Round 3 (poll, "turn up the heat", from `HeatAt`): limited pet / random pass / Bubbles / Gems. The limited pet is `Config.Pets.AdminAbuse` (Banhammer Dragon, Event = true). Pet winners: `PetDrop` message, bag full = 150 Gems.
- Show polls are published `Silent`: the poll card closes the second it ends (`GlobalPoll` "Close"), no results card.
- He chats the whole time: scripted `Lines`, plus `Chatter` (or `HeatChatter`) every `ChatterEvery` seconds; after the show `Remarks` every 40 s until the event ends.
- Giant: no Humanoid (an AnimationController plays the animations, so no hip-height jumps); the root's height is locked each frame to his lowest foot sole; he walks a smooth circle; every footfall booms; heat = faster walk, more frequent double attacks, red pulses and bigger shake. Attacks: beam, meteors, lightning, shockwave, barrage (all harmless), with a floating fake admin command.

## 6zm. Fonts, paw icon, Trade colour (v2.9.1)
- UI fonts: titles Luckiest Guy (a classic simulator-game font), body Source Sans Bold / Semibold (UIKit.Theme.Fonts); every FredokaOne / Gotham use in the world (name tags, boards, lobby signs) swapped too.
- The Pets (inventory) button is a bold paw print; side-button icons are drawn larger.
- Trade's button is teal, so Ranks is the only purple one.

## 6zn. Admin Abuse v3, the obby, the pet collection, font fit (v2.10.0)
- The show is one ordered `Config.AbuseShow.Script` (say / attack / round / crater / obby / heat / leave), nothing random, ~10 minutes: Gifts poll (Bubbles vs Gems), an announced pass drop, a "what should I break" effect poll, the obby window, the heat phase with the final prize poll (limited pet / pass / Bubbles / Gems), then he exits. Prizes scale with players online (`Config.AbuseOption`). A pass already owned pays 100 Gems.
- Giant: Humanoid kept (clothes/hair render; `ApplyDescription` once in the world) with `EvaluateStateMachine = false`; root locked to the lowest sole; scale 38 -> 46 at the heat; every footfall booms. Effects: beam, meteors, lightning, shockwave, barrage, fireworks, laser sweep, black hole, tornado, UFO, disco, fountains. Table craters (an invisible wall plus anyone nearby is moved out). The exit: ":noclip" over his head, a laser cuts the ceiling, he flies out and it mends.
- The speech box sits under the announcement banner (never over the poll card); the title fades its text and outline together.
- Obby (LobbyBuilder `buildObby`): behind the spawn, off the table edge toward the sofa. 5 checkpoints, hops, lava stones, spinners, sliders, vanishing tiles, balance beams, stairs, finish. Prize `Config.Obby` (Gems; `ShowGems` + first finisher's game pass while the show has the obby open, attribute `AbuseObbyOpen`).
- Pet collection: `profile.PetIndex` remembers every species/tier ever owned; each species +0.6% coins, finishing a tier set pays Gems and a big coin bonus (`Config.Collection`); "Collection" button in the Pets window.
- Fonts: Luckiest Guy text is drawn at 84% of the asked size (`TITLE_FONT_SCALE`); icon-button captions are smaller; Celebrate shows the drawn icons instead of "@Gift".

## 6zo. Show polish: real holes, a built-and-smashed obby, collection tabs, music (v2.11.0)
- Table holes (`LobbyBuilder.OpenHole/HealHoles`, `Config.AbuseShow.Holes`): the plank/slab/safety-floor parts around a spot are cut into 5.5-stud tiles; tiles inside the circle fall (with the props standing there), rim tiles tilt and sink, cracks and a glow appear. HealHoles closes it from the rim inward and puts the originals back. Falling players are put back at the spawn while the show runs (`SetRescue`).
- Obby: built only during the show (`OpenObby`, ~10 s of pieces rising in), smashed at the end (`BreakObby`: pieces fall, then fade). The table's south wall opens while it stands. Lava removed; sliders carry players; tiles vanish after ~0.1 s; beams are 1.6 wide; a conveyor stage. The first finisher (any server) is announced and wins a game pass; finishing sends you to the lobby spawn.
- Giant: gentle floor lock (dead zone, speed limit); leaps over the obby while it stands; real cylinders for rings/holes; the show Script has a "winner" attack (the effect chat voted for) so the voted effect is the signature one; `:abusefx` (Studio tab) tries every effect, the holes, the obby, heat, exit.
- Room reacts to the heat (dark, red); show music (`Config.AbuseShow.Music`, attribute AbuseMusic) replaces the lobby playlist; the opening title plays once.
- Pets: Collection has Normal / Golden / Rainbow / Limited tabs (found = coloured, not found = "?"); limited (Event) pets can't be merged. Puppy icon restored.

## 6zp. Glitch fixes (v2.11.1)
- Giant: no Explosion objects any more (light bursts instead); he has a hidden ForceField, BreakJointsOnDeath off and the Physics state, new parts are softened as they appear; his height is only locked while he walks (frozen during commands); the obby leap is one smooth arc.
- Obby sliders are moved by position plus AssemblyLinearVelocity (the Humanoid carries by floor velocity); the server no longer teleports players on them.
- Fireworks: rocket with a spark trail, a big particle burst, then four crackles; all particle emitters.
- Everyone online gets `Config.AbuseShow.ThanksGems` (100) just before the exit. The show music preloads and starts 8 s before the first boom.
- The Collection page replaces the pet grid (nothing shows through) with its own Back button.

## 6zq. Exit, entrance, borders, music, icons (v2.12.0)
- Giant: built far away and out of sight, measured, then appears with a flash, rings and a blast. No emote animations (they moved the hips by tens of studs on a giant); arms are posed by turning the shoulder joints (point / wave / cheer). The floor lock runs in every state except flying and leaping. He leaps over the whole obby (rise, flat, land). The exit cuts a real round hole in the ceiling (`LobbyBuilder.OpenRoofHole`, healed with `HealRoof`) and he is never respawned afterwards (`leaving`).
- The invisible table walls are open for the whole show (`SetBarriers`); when it ends anyone outside them is put back at the spawn. Obby beams are 0.8 wide. Obby finishing shows ONE popup (the first finisher's includes the game pass; no banner).
- Fireworks run about 28 s (70 shells, all heights). Done line / disco line retimed.
- Music: a new track loads first, then the old one fades out (3 s) as the new one fades in (2 s); tracks hand over 30 s before their end.
- IconArt: new "poly" shape (stacked 1-px scanline strips, mitred outline) so the Love heart and the Trade arrows have real points.

### 6zr. Giant fix + debug (v2.12.1)
- The giant's arm code wrote `Motor6D.C0` (read-only from scripts); it threw every frame, aborted the Heartbeat and froze him mid-air. Arm gestures are now small runtime KeyframeSequence animations (upper arms only, Action priority); if one can't be registered he just doesn't gesture.
- The whole per-frame step runs in `pcall`; on error he is still placed and a rate-limited warn names the error.
- Floor lock is wider (0.5x-1.5x) and faster so pose changes (walk -> idle when an effect starts) can't sink him.
- `:abusedebug` (Studio): floating readout above him (state, walking, gesture, rootY, feet height, leap, angle) plus a once-a-second print.
- Heart (two discs + diamond) and Trade (line arrows) icons redrawn; `Config.IconImages` can point to uploaded PNGs.

### 6zs. Giant stands on the walk pose (v2.12.2)
Debug logs showed the idle animation leaves the feet ~113 studs under the floor, and the old floor-lock clamp (0.5-1.5x) couldn't follow. He no longer uses idle: standing still is the walk cycle frozen (speed 0). The floor lock clamp is 0.3-4x and snaps (instead of sliding) when a pose change moves the feet more than 2 scales.

### 6zt. Eye lasers, hidden side, spawn snap (v2.12.3)
- Arm gestures removed (they bent the arms oddly). During every act he fires two eye lasers (`fx.eyes`, also `:abusefx eyes`) that sweep opposite ways over the table, leaving glowing scorch dots that fade.
- Behind the dishwasher (angle 205-335) nobody can see him: effects and the roof exit wait (up to ~16 s) until he is round on the visible side.
- Characters: a fresh character that hangs in the air (floor material Air, no vertical speed, not flying) is snapped onto the ground within the first 3 s.

### 6zu. Arrival without a frozen pose; varied eye lasers (v2.12.4)
- He starts walking the instant the arrival flash fires (the 2.5 s "arrive" hold, a frozen walk pose, is gone).
- Eye lasers last exactly as long as the act (`eyesFor`), so they never run on after he walks again. Acts are a little longer (4.6 s, 3.6 s in the heat).
- Each use is different: 1, 2, 3, 4 lasers per eye (then repeat), and the pattern rotates circles / sweeps down the table / an opening spiral.

### 6zv. Where he may act (v2.12.5)
He only does effects (and the roof exit) when his angle round the table is clear of the chairs (east 335-25 deg, west 155-205 deg, directly behind the dishwasher 250-290 deg). South (the spawn side) and the four corners are allowed; otherwise the effect waits until he walks round to an allowed spot.

### 6zw. Varied extras, persistent rainbow (v2.12.6)
- Every act gets an extra from `BONUS` (eyes, eyes, fireballs, meteors, eyes, fireballs, shockwave, eyes, barrage, fireballs, eyes), never the scripted effect itself. Eye lasers grow 1-4 per eye; `fx.fireballs` (`:abusefx fireballs`) rains more fireballs each use and shakes the table.
- `disco` now keeps the world rainbow until the heat starts (it only restores ColorShift when heat is on, so it never fights the red). The line before it says "the world needs some colour."

### 6zx. Dishwasher smash, somersault leap, roof-safe (v2.12.7)
- t=90 s (`attack dishwasher`): he waits until he is on the south side (80-100 deg, on the ground), gathers a glowing ball in front of his chest (3.2 s, swelling, rumbling), fires it at the dishwasher; it blows apart (`LobbyBuilder.BreakDishwasher`: parts go invisible/non-solid, up to 190 coloured chunks fly out) and burns for 30 s. Everything is put back at the end (`RepairDishwasher`, called by `resetShow`). `:abusefx dishwasher` tests it.
- Fireballs leave scorch marks on the table (fade over 12 s).
- Over the obby he does two forward somersaults instead of a plain jump. The leap height is capped so his head (3.7 x scale, it swings round in the flips) stays 25 studs under the ceiling; HeatScale 46 -> 42.
- `_tools/tests/scen_dishwasher.luau` checks break/repair.

### 6zy. Bombs, bigger roof hole, faster ending, full fade (v2.12.8)
- `attack bombs` (t=178, `:abusefx bombs`): red pulsing circles mark where each bomb will land (near players standing on the table, plus scattered ones, 7-14 per round, only on the table). 2.6 s later the bomb lands, throws anyone inside the circle out (velocity, no damage) and leaves a small crater (dark pit with a lighter rim). A second round follows 10 s later. Craters stay until the show ends.
- The roof exit hole is radius 128 (was 64).
- The show ends sooner after he leaves: leave 605, thanks 613, heal 617, ShowSeconds 624 (was 640).
- Every glowing/temporary part (`neonPart`, scorch, fire, craters, bombs) is tracked and faded out by `clearFx()` when the show resets, so no orange glow is left behind.

### 6zz. Chair, punch, real craters, poll corners (v2.12.9)
- Script order: two laps, then `dishwasher` (t=44), `sit` (t=84: he leaps onto the chair at the end of the table, z=-168, and plays the R15 sit animation; effects and lasers continue from the seat), `punch` (t=197: he turns to the Fastest Clean board and punches; `punchLaunch` makes the t=199 `hole 1` fling the board and what stood on it the way the fist went), `stand` (t=205: he leaps back to the circle and walks on). Bombs moved to t=248 (own slot, not with a meteor shower).
- Table holes now cut `TableApron` too, so they go all the way through and can be fallen into. Bomb craters are real holes (`LobbyBuilder.OpenCrater`, radius 9, indexes 10+, mended by HealHoles); 4-5 per round, spaced out, never on the two big holes; people near them are moved clear and flung out.
- `SIT_LIFT` (hip height above the seat, in scales) and the sit/punch animation ids sit at the top of the sit code in AdminServer for tuning.
- Poll card inset 4 px so the holder's clipping no longer squares off its rounded blue outline.
- `scen_dishwasher.luau` also checks craters cut the apron and everything heals.

### 6zza. Local test and private lobby (v2.12.10)
- Studio tab (owner, works in the published game): "Global Admin Abuse event test" (`:abuseshow`, every server, as before), "Local Admin Abuse event test" (`:abuselocal`, this server only: while `localShow` is set, `publish` handles the show's message kinds locally instead of MessagingService, and `claim` always succeeds; the real event time is restored when the test ends) and "Private lobby" (`:privatelobby [join|new]`).
- `:privatelobby`: reserves a server (`TeleportService:ReserveServer`), keeps its access code per owner in MemoryStore `RinseCycle_PrivateLobbies` (45 days), teleports the owner with `TeleportData.PrivateOwner`. In that server `guardPrivate` makes the first player who arrives as `PrivateOwner` the owner and kicks anyone else. Studio can't teleport (it says so).

### 6zzb. Hands out for the charge (v2.12.11)
While he charges the dishwasher ball both arms go straight out in front, turned in so the hands meet (a runtime arm-only animation, `makeGesture("charge", ...)`: raise = +90 deg about X, yaw +-24 deg), and the ball grows where the hands are (3.1 x scale in front of the hips, 1.4 x scale up). The arms drop once it is fired. (The earlier arm poses used -95 deg, which swung the arms backwards, which is why they looked wrong.)

### 6zzc. Chair show, nuke, UI fade, arm animations (v2.12.12)
- Arm animations are fixed: R15 shoulder poses are raise-forward = +X, out-to-the-side = +Z (right arm) / -Z (left arm). `makeAnim` builds looped poses (point, cheer, wave, flex, charge = hands together) and one-shots (slamR, punchR, punchL). Every act now gets one of point/cheer/wave/flex; effects never start while he is mid-somersault (`canAct` refuses while `leapHeight >= 5`), which is what froze him in the air.
- `attack chairshow` (t=60): he goes round to the north side, sits on the end chair (about 25 s total instead of 120), slams the Fastest Clean board (its hole opens, the props fly the way he slammed), then punches off the soap shop, each egg and the pet stand (`LobbyBuilder.GetSmashTargets` / `SmashProps` / `RestoreProps`), and stands up. Hole 2 now opens at t=199.
- The dishwasher smash also removes the roof ladder and every SurfaceGui (the "RINSE CYCLE" and "PETS & EGGS" lettering kept drawing on invisible parts).
- `attack nuke` (t=540): he throws a nuke onto the right side of the table; it sits there with a countdown over it that reaches 0 at `Show.NukeAt` (596), then it breaks a big area of that side (five real holes). The spawn and the obby are far from it.
- Client: while `AbuseLive`, every ScreenGui except the show's own, polls, prizes, toasts and the admin panel fades out over 0.9 s and comes back at the end. `rollRank` refuses during the show (party pads were already locked by `Config.EventLockdown`).
- `scen_dishwasher.luau` also covers the smash/restore of props; `scen_tableparts.luau` lists the table layers under hole 1.

### 6zzd. Lighting restore, leaving from the south with thrusters, a living seated giant (v2.12.13)
- `baseLighting` is captured before the rainbow or the heat touch the room and restored (`restoreLighting`) when the show is put away: the room no longer stays pink/rainbow.
- He leaves in front of the couch (south, 84-96 deg): `parksouth` (t=575) makes him stop there; `giantLeave` parks him first if he is elsewhere. Farewell lines at 598/602 ("thats everything i had" / "thanks for coming. laters."). When he flies, flame + spark emitters pour out of both feet (plus a light), he starts slower (40 studs/s) so the rise can be seen, and the roof hole is mended over 7 s.
- Hole mending: the broken rim tiles straighten in the same outer-to-inner sweep as the fallen tiles instead of all at the start.
- Seated (and parked) he is no longer a statue: he sways, turns to look at different parts of the table every 2-5 s and raises an arm every 4-8 s.

### 6zze. Fly offer, pads off, UI off, nuke at the dishwasher (v2.12.14)
- Fly offer (t=254, `flyoffer`; no poll is open then): one random player per server gets a card (Accept / Decline, 30 s countdown, `AbuseOffer` / `AbuseOfferReply`); on accept `setFlying` turns the admin-style flight on for them until the show ends (`endFlyers`). The obby ignores checkpoints and the finish while a player has a flight mover on their root (`flyingNow` in LobbyBuilder), and the offer never mentions this.
- Party pads are completely off for the show (`LobbyBuilder.SetPadsEnabled`: nothing touchable, barriers non-solid; anyone in a party is walked out via `PartyService.RemovePlayer`); the "0/8" signs stay. The lobby's prompts and floating labels are off too (`SetUiEnabled`). Both are restored when the show is put away.
- The nuke lands where the dishwasher stood (0, -89) with the line "that spot looks empty. i am redecorating."; its craters ring that spot, far from the spawn and the obby.
- Eye lasers hold his arms out to the sides (`flex`), never in front of his face. Smashing the shop/eggs/pet stand is about twice as fast. He starts folding into the sit animation in the air so there is no pop on landing.
- Z-fighting: every flat effect on the table sits at least 0.8 studs up and is at least 0.5 thick. The dark fireball scorch marks (they read as black lines) are gone: a short glowing ember ring replaces them.

### 6zzf. Poll, pads, smash UI, invisible blocks (v2.12.15)
- PollUI: while `AbuseLive` the poll is never hidden by an "open window" (the other windows are faded away, so a window UIKit still counts as open could hide the poll for good).
- PartyService: the pad loop no longer admits anyone while `Config.EventLockdown()` is on (pads were position-checked, so disabling their touch/collision was not enough; that is what let people walk into a pad and get stuck).
- The lobby prompts and labels are no longer switched off at show start. They go off only with the thing they belong to: when `SmashProps` hits it or a crater swallows it (`switchOffUiOn`), and come back when it is restored/healed.
- Invisible solid parts (hit boxes) near what is smashed are made non-solid (`smashedInvisible`) and restored afterwards, so nobody can jump onto a block where the shop or eggs were.

### 6zzg. Titles go with what is hit (v2.12.16)
`SmashProps` also switches off every SurfaceGui / BillboardGui whose part (or adornee) is within the target's radius, including ones on invisible parts that never fall (the "SOAP SHOP" lettering, the egg labels, the pet stand name), so each title vanishes the moment its thing is punched. `RestoreProps` turns them back on.

### 6zzh. Holes cut the pieces of earlier holes, no cracks, two offers, real-bomb nuke, quick countdown (v2.12.18)
- `cutDisc` now also cuts the standing pieces left by earlier holes (`pieceFolderRoof` tells table pieces from ceiling pieces). Before, once hole 1 had replaced the table's original parts with pieces, every later crater had nothing to cut: only its props and glow happened, and the table stayed whole. Crack lines are gone altogether. `scen_dishwasher.luau` checks nothing solid is left under a second and third hole.
- Offers: at t=251 he says one person per lobby may be offered flight and someone else something else harmless; `flyoffer` (254) and `giantoffer` (257) each pick a different random player (30 s card, text sent with the offer). Accepting gives flight or `setGiantScale(plr, 4)`. `endPerks` takes both away when the show is put away, and leaving drops the perk (nothing is saved, so a rejoin is normal).
- The nuke is a fat egg-shaped bomb with hazard bands, a tail and a cross of fins.
- The obby ending: "all right. five seconds till the obby comes down." then 5, 4, 3, 2, 1 one a second in the speech box only (not chat), then it comes down with "boom."

### 6zzi. Half-table nuke, pet hunt, new ending (v2.12.19)
- The nuke blast is much bigger (2200-stud flash, a fireball, 8 shock rings) and breaks six real holes through every layer of the back half of the table (radius 46 / 34 / 34 / 28 / 28 / 24, never near the spawn or the obby). Large holes use bigger tiles (9 studs) to keep the part count sane. Healing is slow (14 s) and the glow lights, smoke and wreck fire fade out over the repair instead of switching off at the end (`healRec`, `closeHoles`).
- Ending: obby countdown at 501-508, nuke thrown ~526 and goes off at 566 (`Show.NukeAt`), a quiet break, "alright. thats everything i had." (592), "now everyone watch this." (596), leave 599, thanks 611, heal 613, ShowSeconds 630.
- Pet hunt (`attack petchase`, t=452, `:abusefx petchase`; he explains it at 444-448): `Config.Pets.GlitchFox`, a new limited Event pet (not mergeable, counts for the collection), is let loose in `Show.ChasePet`. Count by players in the server: 1-3 -> 1, 4-5 -> 2, 6-10 -> 3, then +1 per 6 up to 10. The pets flee from players at 40 studs/s (22 wandering), stay on the undamaged table (`LobbyBuilder.IsHoleAt`), and are caught by holding E for 3 seconds (they slow to 1.5 while held). One minute, with a CATCH THE PETS countdown on the top pill (`AbusePetsEnd`); the rest fade away. A full pet bag gets 150 Gems instead.

### 6zzj. Floor always sends you back (v2.12.20)
`LobbyBuilder.SetRescue` is now on from the moment the lobby is built and the show no longer turns it off. Anyone whose root is below the table (y between -30 and -150) anywhere in the room, floor included (the old limit stopped at y=-125, so standing on the floor at -127 never counted), is sent to the lobby spawn, show or not. The open obby area keeps its own checkpoint rules. `scen_floor.luau` checks it.

### 6zzk. Lighter holes, smooth resets, power-up buttons (v2.12.22)
- Big holes (radius >= 30 and the roof) use larger tiles (roof 18, R>=40 14, R>=30 11) and the tiles fall by tween (anchored, no physics, fading) instead of as loose physics parts; fewer chunks. The nuke makes 4 craters (not 6) and 5 rings; the roof hole is radius 104 with 4 blasts.
- Resets: holes heal in 9 s (was 14); the room lighting and the rainbow both fade back by tween (4 s / 2.5 s), never a click.
- Poll/vote text: the Break round asks "What should I do next?"; the line before the game-pass round no longer says "isnt a vote" (the round's own intro does, once).
- Power-ups: the fly chip reads "Flying: ON/OFF" (tap or F); a new Giant chip (`AbusePerk` S->C, `AbusePerkToggle` C->S) turns the giant power-up off and on during the event.
- Owner name is "Klushy" (show OwnerName, admin username fallback). A Roblox private (VIP) server is now locked to its owner like :privatelobby (everyone else is kicked).

### 6zzl. Obby winner per server, quicker show, no invisible leftovers (v2.12.23)
- The "finished the obby first" prize and announcement are decided per server (`obbyFirstFor`), no longer claimed globally, and the line is said only in that server.
- Show runs 12% quicker: `at()` multiplies every Script time by `PACE = 0.88`; `NukeAt` 498, `HeatAt` 290, `ShowSeconds` 555.
- Max-heat screen shake multiplier 1.7 -> 1.5.
- Tiles that are mid-fall (tween) carry a `Falling` attribute and are never cut again by a later crater (they used to be re-cut into invisible, solid bits that stayed on the table).
- `BreakObby` sends anyone still past the south wall back to the spawn before the wall closes (nobody is walled out on the table edge).

### 6zzm. No hotkeys in the show, everyone picks a power-up, clear votes (v2.12.24)
- While `AbuseLive` is true the HUD window hotkeys (P/G/R/C/T/Q/Tab/Y...), the Chest event E (it teleported you to the chest) and the Next Event zone pop-up are all off.
- Power-ups: at t=254 (`attack perkpick`) EVERYONE in the server gets a card to pick ONE of Fly / Giant / Speed (or No thanks) within 40 s; not a vote. `AbuseOffer` (S->C id, seconds, text), `AbuseOfferReply` (C->S id, choice). Late joiners get the card while it is open; the perk is re-applied after a respawn. Fly keeps its Flying chip; Giant and Speed use the `AbusePerk` chip (ON/OFF, `AbusePerkToggle`). Speed sets WalkSpeed 30. All removed at the end of the show / on leave.
- Votes: poll titles read "EVERYONE VOTES - MOST VOTES WINS" (`Hint` on `PollStart`, 6th arg of `GlobalPoll Start`); option texts say exactly what the winner gives ("400 Bubbles for EVERYONE", "The limited pet for 3 lucky players"); the show's lines say that most votes wins and the winner goes to everyone.

### 6zzn. Next Event sign fits (v2.12.25)
The banner over the Next Event ring is bigger (14 x 5 studs, canvas 700 x 250) with three separate lines, each inset 6% from the edges and scaled to fit on one line: "NEXT EVENT", the event name (tag `NextEventName`), and the countdown (tag `NextEventCountdown`). EventZone fills the two tags. Before, "Admin Abuse  •  Starts in 3d 04h" was one long line that wrapped and ran into the edges.

### 6zzo. Next Event sign posts (v2.12.26)
The two posts of the Next Event banner stand just outside the banner's edges (x +/- 7.8, 1 stud thick, 13 tall) with a round foot, a ball on top and two clamps each holding the banner. Before, they were at x +/- 6.5, inside the banner's width, so they ran through it.

### 6zzp. Speech box at the top, no announcement banners in the show (v2.12.27)
- The giant's speech box (`AbuseTalk`) sits at the top middle (TopInset + 8; just under the pill on screens narrower than 900 canvas px); the status chips move under it while `AbuseLive`.
- `bannerAll` does nothing while `AbuseLive` is true, and the show's own banners (starts in N minutes, is live, obby open, is over) are gone: the top-right pill counts down and the speech box talks. Staff `:announce` banners still work.

### 6zzq. Big show update (v2.13.0)
- **Power-ups**: the pick card uses the same look as the vote card (title "Pick one power-up for the rest of the event", "N s left", three buttons "Fly perk" / "Size perk" / "Speed perk", "No thanks"). One chip style for all three ("Fly perk: ON (F)"); F switches whichever power-up you have on/off (`AbusePerkToggle` for size/speed).
- **Votes**: titles "FINAL VOTE" etc.; options "1,500 Bubbles for everyone", "Limited pet for 1 lucky player"...; when the count is in (3 s after the vote ends) the SAME card turns into the results at once (percentages, winner lit up, 7 s, `PollResult` with `Auto`), the speech box says "the results are in. ..." (no typing banners). Show prizes (`Celebrate`) use a small card at the top (one at a time) instead of the big window while `AbuseLive`.
- **Menus/keys**: all lobby E prompts are switched off for the show (`LobbyBuilder.SetPromptsEnabled`), open windows are closed as it starts; the Roblox menu during the countdown (last 30 min) or the show shows "DON'T LEAVE" (StayOffer second mode), never at other times.
- **Effects**: black hole slowly pulls everyone in (LinearVelocity, swirl, faster), bursts in a white flash and shoots everyone out at 230 studs/s; tornado (12 stacked rings, dust, 26 orbiting chunks) catches players, lifts and spins them round inside it and throws them out at the end; meteors (18/28, fire tails, shove, fire patches); fireworks all over the room (90 rockets from the floor and table, 2-3 at a time); nuke = ONE round crater (R 64) at the back half of the table.
- **Lag**: big holes (R >= 30) and the roof drop their tiles as unanchored, non-colliding parts with the network owner on the server, removed after 2.2 s; tile size 14/18; 8 chunks.
- **Ending**: the `restore` step (t=614) fades light + the red of the heat + rainbow (10 s, all Lighting properties incl. ColorShift_Bottom), heals the holes over 10 s, fades the dishwasher in over 10 s (signs fade in last), then "the event is done" 12 s later. The rainbow glides colour to colour instead of jumping.
- **Giant**: cheer/wave poses are wide (arms no longer cross his face); the fireball sits between his real hands; sitting/standing has no jump; the board and the shops are really whacked (angle worked out from shoulder to target, a white burst at the fist; board 3 whacks, soap shop/pet stand 2, eggs 1).
- **Script**: filler lines cut, obby closes ~50 s sooner (t=455), more giveaways (gem rain `Rain`, `Passes2`, `PetGift`), a second black hole / meteor storm / tornado in the heat, ShowSeconds 560.

### 6zzr. Opening camera shot, odds board (v2.13.1)
- **Opening shot** (AdminClient `openingShot`): when the show goes live (and only within 12 s of its start, never over a Scriptable camera) every player's camera pans (1.6 s) to the giant where he appears, holds 2.4 s, follows him (slowly drifting round him) for 3.6 s, then swings back (1.4 s) to the usual spot behind their own character and hands the camera back (Custom). Bound at `RenderPriority.Camera` so the screen shake (Camera+1) still works.
- **Chest odds board** (ChestUI `buildBoard`): drawn on a fixed 520 px canvas with ONE text size for all rows (the largest at which the longest name fits, measured with TextService), a rounded panel with the blue outline, and the canvas scaled to the billboard's on-screen size (UIScale), so nothing is squeezed, cut off or a different size.

### 6zzs. Fonts and positions, timing of the lines, meteor blast (v2.13.2)
- Vote card, results and power-up pick card use the same font (Title) for every line; the prize card sits at the same bottom-middle spot as the vote cards (stacking above them while one is up) in the same font.
- "see that machine? i never liked it." is said when he starts gathering the fireball (a few seconds before it hits), and "my legs hurt. im sitting down..." when he reaches the chair (`giantSit`), not at fixed times (he used to have to walk round the whole table first).
- Meteors: every impact blasts players within 46 studs away (up 85, out 120) and every third leaves a small dent (R 5.5, hole index 200+).

### 6zzt. Tutorial, UFO abduction, grabs, nuke, and the rest (v2.14.0)
- **Speech box** sits at the very top (y 6) on wide screens. **Leave message**: StayOffer reads the schedule from the replicated `AbuseStarts` / `AbuseLive` attributes (the client's own Config copy does not know when the server moved the show), so "DON'T LEAVE" shows in the 30 minutes before the event and during it.
- **UFO** picks a player, flies over them and keeps drifting after the nearest one; its beam (radius 20) catches everyone under it and pulls them up (slow, then faster). Whoever reaches the ship is held ~1.3 s and then respawns (Health 0); anyone not finished with is let go when it leaves.
- **Grabs** (black hole, tornado, UFO) now catch flying players too: `AbuseGrab` (S->C) stops their flight and blocks F until they are let go (flight can be switched on again). The tornado steers toward the nearest player (38 studs/s) and catches within 48 studs up to y 160; meteors are denser (30 / 44) and every 4th leaves a small dent.
- **Nuke**: throw moved to t=545 so it lands ~15 s before it goes off; the crater is cut a layer per frame, with 18-stud tiles and only ~40% of its tiles falling as visible debris (the rest are simply taken away), far lighter.
- **Prize card**: when the title starts with "You won" / "You got" only the message is shown (no duplicate title line).
- **Flip**: the two flips now end exactly as he lands, and the walk cycle is held while he is off the ground (no walking steps in the air / tacked on at the end).
- **Joining mid-event**: a toast "Admin Abuse is LIVE! ..." (or "starts in N minutes..." within the hour before; the top-right pill now shows from 60 minutes before).
- **Kitchen plates** are 8 studs apart (were 7) in every level.
- **First-run tutorial** (Client/Tutorial.luau, new): `DataService` field `TutorialDone` (anyone with a finished run counts as done; MetaRequest "TutorialDone"), `ClientState.TutorialStep` hides the HUD while it runs: 1 scrub (closest dish marked), 2 keep scrubbing, 3 sell at the drain (marked), 4 Upgrades button appears and pulses (Tab / tap), 5 buy something, then everything appears. Skip button. Only in level 1, after the run's cutscene.
- **Dish clean feel**: a ring of light, more sparkles, a chime that climbs per dish in a row, "Sparkling! xN".

### 6zzu. Clubs waits, tutorial rework, show script rewrite, lobby reset (v2.15.0)
- **Clubs**: after LEAVING a club (or closing yours) you can't join or make another for `Config.Clubs.LeaveCooldown` (24 h; profile `ClubMovedAt` is now only set by leaving, joining/creating no longer starts a wait). After being KICKED you can't rejoin that club for `Config.Clubs.KickBan` (24 h; profile `ClubBans[clubId]`) but any other club is fine. Kicking takes the kicked member's donated Bubbles for the month off the club's points (and the club leaderboard); the kick dialog warns the admin with the exact number. The club record keeps `Kicked[userId] = { At, Name }` (30 days, max 40) so a player who was away is told on their next login: ClubService `applyKick` sets the ban and the profile's `ClubNotice` ("You were kicked from X. You can't rejoin it for 24 hours, but you can join other clubs."), MetaState carries `ClubNotice` / `ClubFreeAt`, ClubsUI shows the notice once (toast) and answers MetaRequest "ClubNoticeSeen". The Create page shows how long a recent leaver still has to wait. Staff `:clubreset` (Studio tab) clears the wait, the bans and a waiting notice.
- **Pets**: the "Delete this pet forever?" question now replaces the Delete button at the bottom of the detail panel (it used to hang below the panel on phones). The Pets button is always visible in the lobby (the tutorial hid it and nothing brought it back).
- **Tutorial** (Client/Tutorial.luau): card 560 wide (or the screen), "TIP n of 5", the reward ("Finish for 300 Bubbles + 15 Gems", `Config.Tutorial.Reward`), five progress dots, and a small "Skip tutorial" button at the bottom right that asks first ("This skips the whole tutorial, and you won't get the reward for finishing it"). The camera turns on the spot (never moves, so it can't end up in a wall) to the dishes at the start ("Your job is to clean these dishes!") and to the drain when the tank is filling; any click / tap / key hands it straight back. Finishing pays once (`DataService.SetTutorialDone(player, true)`, only for someone who cleaned 3 dishes, with a prize popup); skipping pays nothing. Staff `:resetfirstrun` starts it again.
- **Show script** (Config.AbuseShow.Script) is now written in real seconds (PACE is gone) and: the voted effect (Break) plays once and the other three of meteors / fireworks / black hole / tornado play once each at the `rest` slots; the table break (`tablebreak` meteors + hole 2) is right after "right. the table. lets see how much it can take."; the obby builds at t=154 (open at 164, ~30 s sooner) and the power-up pick stays at t=222; no "winners check your screen" lines (round `Done` is optional); the gem rain, the repeated holes and the filler are cut; the countdown is the new `count` step (ONE speech box that grows "all right. the obby comes down in 5... 4... 3... 2... 1..."); the pet hunt line uses `{HOLD}` (the client turns it into "Hold E on" / "Hold X on" / "Hold the button next to"); the nuke line is "this spot looks empty... how about a nuke." and the nuke lands ~15 s before it goes off at NukeAt (498). A small effect and its extra now keep the stage for 5 s, so a big one waits for them.
- **Opening camera** starts the moment the show goes live and turns on the spot (the camera never changes place) to where he appears (the south end of the room) and follows him from there for ~9 s, then turns back. It used to wait for the giant model, which is parked 6000 studs up until the bang (hence "the sky first"), and swing out to him through the chairs.
- **Lobby reset**: `LobbyBuilder.Snapshot()` takes a picture of every lobby part (place and state) and which prompts / signs are on when the show goes live; 3 s after the show is put away `LobbyBuilder.HardReset()` puts back anything that is loose, hidden, moved, see-through or not solid, switches the prompts and signs back on, and sends anyone out of bounds to the spawn.
- **Also in this version** (from the earlier part of the batch): scattered plate slots in the family dishwasher and a chime arpeggio for cleaning, E only works near the chest (the event button no longer says E), the chest odds board is bigger, obby prize once per player per show ("already completed the obby for this event"), only the server's first finisher is announced, the speed power-up is much faster, UFO moves slowly around the table and sends whoever reaches the top to the spawn, black hole redesign, nuke blast (big, pushes people back, falls all at once), one hit per object when he whacks, he stands up before he flies out, the pet hunt ends early (and the show moves on) when every pet is caught.

### 6zzv. Tutorial tour, show fixes, obby, admin lists, Premium, analytics, new lobby layout (v2.16.0)
- **Chest sign**: the "limited time" title is a real sign part on the chest (no more billboard flicker / giant text). The spinning blue piece over the dishwasher drain is gone; dishes in all three levels are thinned and spread (`Config.Levels[*].Dishes` / spots).
- **Tutorial v3** (Client/Tutorial.luau): "open the book" says the right button per platform, the Upgrades button flashes, the HUD (counters, level bar) is hidden and the card sits at the very top, nothing else can be bought while a tip points at one thing, and the Upgrade Book gets a spotlight tour (power, size, tank, sneakers, tools) with Next and a smaller Skip. Pet / gold-dirt / gem toasts are off during it. After "Awesome!" the HUD returns. Every tip is an Analytics moment (`tut.start` ... `tut.done`, `tut.tour.N`).
- **Show** (AdminServer director, Config.AbuseShow.Script): the giant spawns with the flash, ~30 speech lines that stay up until the next (max 15 s), he slides the chair out before sitting and pushes it back, the camera looks at the obby while it is built, meteors spread over the whole table, new bomb / nuke countdown (10, held longer) / power-up lines, leave laser fired from his raised hand, "thanks for coming along. stay tuned for chapter four." and the Next Event sign flips to Chapter 4 afterwards (Studio tests / the real day only, never saved), the chest key is V, the roof duck goes with the dishwasher, and a finished show can no longer restart (`showEnded`).
- **Obby**: harder stage 2-4 movers, thinner beams and one longer jump, a new final climb and a real trophy; flying never counts (notice every time, a start-area exception, `AbuseGrabbed` for the show's own movers) and checkpoints are sequential.
- **Admin**: pass-drop popups with confetti for winners and gift receivers ("you won a pass from the pass drop", "an admin gave you a gift pass"); the **Servers** list (lobby 1, 2... and game servers by level / chapter, filters with arrows); a countdown with no name is a plain timer; `:analytics` (reports, below).
- **Premium** (`Config.Premium`): `MarketService.applyPremium` follows `player.MembershipType` (also while they play) and sets the pass-like flag `Premium`; `Config.GetRunStats` gives +10% Bubbles; `DataService.ClaimPremiumDaily` (profile `PremiumDay`) pays 150 Bubbles + 3 Gems once per UTC day with a `Celebrate` popup; StayOffer shows a "Premium +10%" chip.
- **Lobby layout** (LobbyBuilder `Layout`, plaza coordinates): the six pads are two columns of three (x = +-38, z = -46 / -20 / 6) on either side of the carpet walkway, with a "PARTY PADS" arch over it (z = -20) and the roof sign "STEP ON A PAD TO PLAY"; the two leaderboards stand beside the dishwasher at (+-62, -66) facing the walkway; the left wing (x = -76) has the Soap Shop (-40), Pet Stand (-14) and Rebirth Fountain (10), the right wing (x = +76) the three egg pedestals (z = -48 / -34 / -20), the Next Event ring (2) and the Treasure Chest (22). New players (no run yet, tutorial not done) see a bouncing "STEP ON A PAD" arrow over the nearest pad (PartyUI `padHintLoop`). Show: hole 1 is now at (-68, -74) (where the Fastest Clean board and the shakers stand), `GetSmashTargets()` and the chair show read `LobbyBuilder.Layout`, LobbyFun's bubble / duck spots follow it.
- **Event cards on phones**: `UIKit.PhoneBoost` makes the vote, power-up and prize cards (and the speech box) 1.2-1.3x bigger on touch screens (`scen_eventui` dumps them at phone sizes).
- **Analytics** (see ANALYTICS.md): `Analytics.luau` (server) + `Telemetry.luau` (client) + `Config.Analytics`. Moments via `DataService.Track` / `ClientState.Track`; Roblox funnels / economy / progression / custom events (published games only, rate limited); a DataStore tally per day and per sign-up day; `:analytics` reports; profile block `An` (first day, visits, retention bits, per-key first / today marks). `DataService.EconomyChanged` (player, currency, amount, balance, reason) fires on every Bubbles / Gems change (callers pass reasons), `ShopService` counts every MetaRequest (`meta.X` / `metafail.X`), RoundService the run (`run.*`), PartyService the pads, RunServers carries the funnel attempt in the teleport data (`Fids`).

### 6zzw. Pass-drop card, tool sounds, mobile controls, lobby turned to the middle, show shooting, badges (v2.17.0)
- **Pass drop** (`:globalpassdrop`, also the show's pass prize): everyone gets a card "Congrats to those who won a gamepass!" with VIEW (opens a window listing the winners grouped by pass, your own row lit) and CLOSE; remote `PassWinners` (S->C, `"Drop"`, `{ {Id, Name, Pass} }`), UI in AdminClient (`PassDropCard`, `PassWinnersWindow`), skipped while the Admin Abuse show runs (its own speech box says it). A drop travels as chunks of 8 winners (MessagingService messages max ~1 KB; names are in them now): each server grants its own players' passes per chunk and shows the card once all parts arrived (or after 6 s).
- **Foam cannon / walking on phones**: a finger that lands in the thumbstick corner (left 45% x lower 60% of the screen, `SprayController.inMoveZone`) is never a spray finger and is passed on, so walking no longer fires the cannon at the dish under the thumb. Everywhere else a finger on a dish / dirt still sprays and is kept from turning the camera. Phones are locked to first person during runs (v2.16.x) and tools reach 1.5x (`Config.Round.TouchReachMult`, `SetTouch` meta request -> player attribute `TouchReach`).
- **Tool sounds** (`Config.Sounds`: Hiss, Rumble, Squish, Fwump, Valve, Equip; same recordings as before, pitched and quiet 0.12-0.35): the nozzle hisses while it sprays, the washer hisses faster with a low rumble, a click opens / shuts each jet, the foam cannon "fwumps" per blob (the splat sound was already there), a wet sponge squelches now and then, a soft click when you pick up another tool. Played from `SprayController` (`toolSoundKind`, `nextHissAt`, `lastToolIndex`).
- **Pizza Party counters**: the pizzas and box stacks on the two backyard counters were seven props on 358-stud counters and overlapped (a stack of boxes sunk into a pizza by the sink). Now 3 per side (`ArenaBuilder.buildYard`), at least 10 studs from each other and from the edge; `_tools/tests/overlapcheck.py` checks any `arenaN` dump. Dish spacing (`scen_dishspacing`): pizza cutters now sit 10 apart in the basket (wheel 8 wide), goblets take every other column first, pots turn so their handles point front/back (they stuck into the pan beside them), cutlery turns at most 12 degrees.
- **Lobby**: the Soap Shop, Pet Stand and Next Event sign are built facing +Z and turned (`LobbyBuilder.turned`) 90 degrees to face the middle of the plaza (the chest already looks at the spawn); the Doghouse duck spot follows. Craters (`cutDisc`) now switch off the signs, labels and prompts of everything in them (also those on invisible anchors, like the party pad's "0/8" sign) and flag the Next Event zone / chest `Broken` so the client windows stop opening; HealHoles turns them back on when the props return, HardReset clears the flags. Obby trophy: stacked rings overlap by a hair and the dark inside sits above the rim (the two shared a top plane and flickered). Event keybind H, floating "+N" text fades with its outline (`UIKit.FadeText`), the UFO can take the same player again.
- **Admin Abuse chair show**: the giant stays on the chair (no lean, no scooting away) and SHOOTS the board, shop, pet stand and eggs from his seat: he turns, raises the arm toward the target, a glowing ball swells in the hand and flies there (beam + flash), then the old smash happens at the target. Offline the giant cannot be built, so this is only type checked.
- **Badges** (`BadgeAwards`): uses `AwardBadgeAsync`, checks `UserHasBadgeAsync` before noting a badge as given (`BadgesGot`), heals notes that Roblox says are not owned, reports a switched-off badge, and `:badges <player>` audits all ten and gives what is missing. **Leaderboards**: a REFRESH plate under both boards (click or prompt X), 20 s per player / 12 s per server; every member of a party that clears in the same time is recorded with that time (own key per player).
- **v2.17.1 - HUD right column**: the Shop / Pets / Ranks column no longer slides down by a row per player in the server (that was a desktop-only offset to clear Roblox's own player list, and it applied even when the list was shut); it sits at the same place whatever the player count (`HUD.relayoutHud`).

### 6zzx. Tab list capped at four rows, party pads you can walk about in (v2.18.0)
- **Player list** (Client/PlayerListUI.luau, NEW, optional like Telemetry): on a computer Roblox's own list (which grows a row per player and cannot be resized) is replaced by one that is at most FOUR rows tall and scrolls beyond that, with the leaderstats columns (Bubbles, Dishes, Rebirths), sorted by Bubbles; Tab or its X closes / opens it, in a run and in the tutorial it is away. It sets the player attributes `CustomPlayerList` (HUD then keeps Roblox's list off) and `PlayerListHeight` (the fixed space the HUD's right column keeps clear below it, whether the list is open or not, so nothing moves with the player count). Phones and consoles keep Roblox's list. v2.17.1 removed the old per-player offset.
- **Party pads**: members are held to the pad's whole round floor (`PadInfo.Radius` + 2.5) instead of the entry square plus 1.5 (smaller than the circle along its sides: walking toward the wall sent you back to the middle). Walking into a pad no longer teleports you onto a grid spot (only someone who is not on the floor is placed), and someone found outside the walls is put back at the nearest bit of floor, not the middle (`PartyService.nearestSpot`).

### 6zzy. Compact tab list, Refresh chip (v2.18.1)
- **Tab list** (PlayerListUI): rows are 24 high (22 header), text 15, panel 360 wide, and it fits in the gap above the HUD's right-hand buttons: the HUD publishes the buttons' natural top as the player attribute `RightColumnTop`, the list shows as many rows as fit (2 to 4, only the screen decides, never the player count) and scrolls beyond; the buttons only move down (a fixed amount) on a screen so short that even two rows would not fit. `PlayerListActive` tells the HUD the list is in use.
- **Leaderboard refresh**: the yellow REFRESH plate and its second proximity prompt (stacked under "Next page", they overlapped, worse zoomed in) are gone. Near a board (45 studs) a small "Refresh" chip (`BoardView`, fixed place at the bottom centre of the screen) appears: X on a keyboard, D-pad up on a controller (Next page keeps its own X there), a tap on a phone. It fires the new `BoardRefresh` remote (C->S); `LeaderboardService.RefreshFor` answers (20 s per player, 12 s per server) with a toast. Hidden in runs, the tutorial, the show and while a window is open.
- **v2.18.2 - opening shot**: the Admin Abuse opening camera (AdminClient `openingShot`) now watches from 25 studs higher (`RISE`, eased in with the turn and out again with the turn back), so a player who walks about while it follows the giant is no longer hidden behind the pads' walls, the boards and the arch.
- **v2.18.3 - the ending camera, the table growing back**: when the giant leaves (beam, hole in the ceiling, flight up through the roof) the server sets ReplicatedStorage attribute `AbuseGiantLeaving` (cleared in `removeGiant`); AdminClient `exitShot` then turns every camera to him from 25 studs above its player (same high view as the opening shot), follows him up (the focus eases after him), and CUTS back to the player (`CameraType Custom`, no turn back) as soon as he is 480 studs above the camera, gone, or the show is over. Crater props (`HoleRec.Props`: inlays, trim and things that stood on the table, now also remembering their `Transparency`) no longer snap back at 80% of the repair: each reappears where it stood and fades in over 0.9 s (outer ones first, spread over 10-70% of the repair time) like the floor tiles rising, and only becomes solid when the fade is done. Offline the giant and the camera cannot be seen, so both are type checked only.
- **v2.18.4 - board chips**: the leaderboards' last proximity prompt ("Next page", F) is gone (LobbyBuilder `buildBoard`), so a board has no prompt of any kind. `BoardView` shows two chips side by side at the bottom centre of the screen: "Next page" (F on a keyboard, X on a controller, a tap on a phone) and "Refresh" (X / D-pad up / tap; unchanged server side). Each has its key on its top edge (not on phones); only Refresh shows when the nearest board has a single page. Both are one `CanvasGroup` that FADES with the distance to the nearest board (`FADE_FULL` 28 studs: all the way in, `FADE_GONE` 46: gone, eased every frame; also fading out while a run, the tutorial, the show or a window has the screen) and ignores presses while it is less than 35% there. `BoardView.Flip(board, dir)` is the one page flipper (the arrows on the board in `Effects` use it too; the Effects prompt branch `BoardNext` is gone). `scen_boards` walks in and out (visible / transparency at 37 and 15 studs, hidden far away), presses tap / F / controller X / X / D-pad up and checks F does nothing when far; `scen_boardchips` dumps the chips for guirender.py.

