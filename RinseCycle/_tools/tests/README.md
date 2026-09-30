# Offline game tests (Lune)

A stand-in for the Roblox engine that runs the real scripts, so whole-game flows can be
tested without Studio. Needs [Lune](https://github.com/lune-org/lune).

- `adminsim.luau`: runs AdminServer + AdminClient, clicks through every command in the panel,
  checks mute (TextSource.CanSend + the chat filter), lists, spectate/control stop, the
  command line, a non-owner (no panel, every remote refused) and the owner's status chips.
  `lune run adminsim.luau [username] [userId] [studio 1|0]`
- `gamesim.luau`: boots the real server `Main` + all services and the real `ClientMain`,
  with a virtual clock, ray casts and remotes wired end to end. Optional scenario:
  `GAMESIM_EXTRA=scen_run.luau lune run gamesim.luau [username] [userId] [studio 1|0]`
  - `scen_run`: run start, clock starts only on "Loaded", buy/equip tools, finish, rewards,
    return to lobby, real scrubbing and selling.
  - `scen_lobby`: codes, daily, like/follow, hatch/equip/merge/delete pets, rank roll,
    rebirth gate, party pads (Create/SetMax/StartNow).
  - `scen_hud`: the owner-only Admin button under Free (lobby and in runs).
  - `scen_water`: hose / pressure washer water parts while spraying.
  - `scen_pads`: party pads (menu in 0.1 s, others locked out while picking, join after Create,
    Back puts you outside, instant re-entry) and the fade that hides the launch teleport.
  - `scen_return`: the fade before the automatic trip back to the lobby after results.

Paths assume the repo lives at /home/user/Roblox. The mock is permissive: a pass here means
"no script errors and the flow works", not "pixel-perfect in Roblox".

## Renders (harness.luau + render.py)

- `lune run harness.luau npc<L>@<t> out.json` dumps level L's room with its people at loop time t.
  Also `arena<L>`, `npclineup`, `lobby`.
- `python3 render.py out.json out.png ex ey ez tx ty tz fov W H` draws a dump (flat-shaded, near
  plane clipped). `python3 eyecheck.py out.json ex ey ez` names any part the camera is inside of.
  - `scen_social`: pet trade (with a mid-countdown change), gifting a pass, leaderboard reset.
  - `scen_petsadmin`: a hidden admin's pets stop, the admin Pets view (add / remove), :invis remembered.
  - `scen_tradereq`: trade requests (Request / Cancel / 2-minute wait, no wait after an accepted trade) and the 3-2-1 countdown.
  - `scen_adminbtn`: the right column's buttons, including the owner's Admin button.

Also run `python3 _tools/check_locals.py` before sending scripts: Roblox refuses a script with more
than 200 locals alive at once ("Out of local registers"), and Lune doesn't catch that.
