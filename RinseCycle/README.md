# Rinse Cycle 🫧

You're a tiny water-person inside a giant dishwasher. Scrub the grime off the plates, fill your tank,
sell it at the drain, buy bigger hands and better tools, and clean the whole load with your party.
Every finished run pays **Bubbles**, which buy pets that scrub for you.

The whole game is built by scripts. The place file has no parts in it, and the scripts build the lobby,
the dishwashers, every dish and all of the UI when the server starts.

---

## Open it in Studio (first time)

1. Open **Roblox Studio**.
2. Go to **File → Open from File…** and pick `Downloads\RinseCycle\RinseCycle.rbxlx`.
3. Press **Play** (F5). The Output window (**View → Output**) should show lines like
   `[Rinse Cycle] LobbyBuilder.Build ok` and then `[Rinse Cycle] v0.1.0 server ready`.

That's all you need to play-test. To test parties, use **Test → Clients and Servers**
with 2–4 players.

## Make progress save

Progress only saves in a published game, so until then the game runs in "offline mode". Everything
works, but Bubbles and pets reset when you stop.

1. **File → Publish to Roblox** (create a new experience).
2. **Home → Game Settings → Security**: turn on **Enable Studio Access to API Services**.
3. Play again. The "progress won't save" message is gone.

## Recommended settings on the Creator Dashboard

- **Server size: 16–20 players.** Every party plays in its own dishwasher inside the same server,
  so a 20-player server fits 5 full parties.
- **Workspace.StreamingEnabled** is already **off** in this place file. If you ever copy the scripts
  into a different place, untick it in the Workspace properties.

## Game passes (optional)

`ReplicatedStorage/Shared/Config.luau` has a `Config.GamePasses` list: 2x Coins, Mega Tank,
Auto Drain, +2 Pet Slots and 2x Bubbles. They're hidden while their `Id` is `0`. To sell one:

1. Creator Dashboard → your experience → **Monetization → Passes → Create a Pass**.
2. Copy the pass ID into the matching `Id = 0` in `Config.GamePasses`.

Eggs can only be bought with Bubbles, and Bubbles can't be bought with Robux. That keeps eggs out of
Roblox's "paid random items" rules. The odds are shown before every hatch anyway.

---

## Keep Studio in sync with these files (recommended)

Studio's built-in **Script Sync** can link a folder in Studio to a folder on disk, so any edit
to these files shows up in Studio straight away. You won't need to copy and paste anymore.

After opening the place once:

1. In the Explorer, right-click **ReplicatedStorage → Shared** → **Sync to…** → pick
   `Downloads\RinseCycle\ReplicatedStorage\Shared`.
2. Right-click **ServerScriptService → Server** → **Sync to…** → pick
   `Downloads\RinseCycle\ServerScriptService\Server`.
3. Right-click **StarterPlayer → StarterPlayerScripts → Client** → **Sync to…** → pick
   `Downloads\RinseCycle\StarterPlayer\StarterPlayerScripts\Client`.
4. If Studio asks **Keep Studio / Keep Disk**, choose **Keep Disk**.

File names tell Studio what each script is:
- `Name.server.luau` is a **Script**
- `Name.local.luau` is a **LocalScript**
- `Name.luau` is a **ModuleScript**

If you don't use Sync, copy a changed file's contents into the script with the same name, in the same
place in the Explorer.

---

## Where things are

| Change this | In this file |
|---|---|
| Any number: prices, grime HP, tank sizes, levels, pets, egg odds, perks, passes, sounds | `ReplicatedStorage/Shared/Config.luau` |
| The game's name | `Config.GameName` |
| The lobby's look | `ServerScriptService/Server/Services/LobbyBuilder.luau` |
| The dishwasher and dishes | `ArenaBuilder.luau`, `DishFactory.luau` |
| Pet looks | `ReplicatedStorage/Shared/PetModels.luau` |
| Colours, fonts and buttons across all UI | `StarterPlayer/StarterPlayerScripts/Client/UIKit.luau` |

`DESIGN.md` explains how every script fits together.

## Rebuilding the place file

After editing the files you can repack them into a fresh `RinseCycle.rbxlx`:

```
powershell -NoProfile -ExecutionPolicy Bypass -File _tools\build.ps1
```

(Only do this for a fresh start. Anything you built by hand in Studio isn't in these files.)
