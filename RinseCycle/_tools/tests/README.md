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
  - `scen_adminbtn`: the left column's buttons, including the staff Admin button (under Trade).

Also run `python3 _tools/check_locals.py` before sending scripts: Roblox refuses a script with more
than 200 locals alive at once ("Out of local registers"), and Lune doesn't catch that.
  - `scen_staff`: staff tiers (Moderator / Admin / Developer / clear), their tags, the staff list, and staff can't target higher ranks.  - `scen_boost`: the stay boost (claim once a day, x2 timer reaches the client), level 1's start,
    the daily streak (24 h continues, over 48 h restarts) and the boost/pass badges.
  - `scen_boards`: the lobby boards in PlayerGui (scrollable), each "you" row, your own row lit up,
    and the admin viewer answering from the cache.
  - `scen_back`: the gift window's Back button (PassBuy -> Shop) and Roll with too few gems (Gems shop, plain X).
  - `scen_hatchshop`: hatch buttons say "(50 Bubbles)"; short of Bubbles a click opens the Bubbles shop.
  - `scen_mergeview`: merge mode shows only mergeable pets, and a message when there are none.
  - `scen_coinstab`: the Shop's Coins tab is hidden in the lobby.
  - `scen_touchspray`: on a phone, holding a finger on dirt cleans it (no SPRAY button).
  - `scen_petsrest`: Pets Off stops pets earning (and it's saved); back on, they earn again.
  - `scen_touchfly`: on a phone, holding jump in the air flies.
  - `scen_global`: admin Global tab: a poll (vote, results banner), give everyone, x2 boost, pass drop.
  - `scen_referral`: referral payouts (new player once, inviter, cap) and the Free window's cards.
  - `scen_friendluck`: rank luck from invited friends (+10% each up to 10 = x2, doubled by the x2 Luck pass), the Ranks window text.
  - `scen_events`: Treasure Chests (free once, packs, 400-open odds), Clubs (create rules, settings, code, points, leave, join requirements, cooldown), the button grid, the Next Event ring and the lobby chest.
  - `scen_badges`: every badge rule, awarding only badges with an ID and never twice, and the daily-notification queue (queued 24 h out, sent once when due, removed).
  - `scen_autocomplete`: the admin command line's suggestions (commands, players, durations, options) and Tab completion.
  - `scen_icons2`, `scen_hudshot`, `scen_winshots`: dumps for guirender.py (new icons; the HUD grid; Clubs tabs and the chest boxes). guirender.py now lays out UIGridLayout too.
  - `scen_events` now also covers donating, the club's info, the monthly reset (a fake clock) and the prize claim; `scen_winshots` dumps the Clubs tabs and dialogs; `scen_icons3` the HUD icons.

  - Level 2 (Backyard Sink, v2.3.0): `lune run harness.luau arena2 out.json`, then `render.py` from outside (e.g. eye 700 600 -900, target 0 100 300) to check the yard, house and sink.

  - Backyard (v2.4.0): `lune run harness.luau arena2 out.json` then render.py. NOTE: in a dump, world z is the NEGATIVE of arena z (the sink spawn is at world z +100 looking toward -z).
  - `adminsim` now also runs :noclip, :giant, :abuse (the mock has no Model:ScaleTo, so :giant reports no character there).
  - `scen_abuse`: the whole scripted Admin Abuse show on a fake clock (lockdown, polls closing, pass round, effect poll, craters, obby open, heat, final pet vote, no repeated lines, the end).
  - `scen_mobile` + `mobaudit.py`: phone-size screens (landscape and portrait), window dumps, and the smallest real text size per window.
  - Level 3 (castle hall, v2.7.0): `lune run harness.luau arena3 out.json` then render.py.
- v2.12.1: giant arm gestures via KeyframeSequence, per-frame pcall, wider floor lock, `:abusedebug`; heart/trade icons redrawn.
- v2.12.3: giant eye lasers, effects wait while he is behind the dishwasher, spawn float snap.
- v2.12.4: giant walks at the flash, eye lasers sized to the act, progressive laser counts and patterns.
- v2.12.5: giant acts only away from the chairs and the dishwasher's back.
- v2.12.6: varied bonus effects (fireballs etc.), rainbow persists until the heat, 'the world needs some colour'.
- v2.12.7: dishwasher smash, fireball scorch, somersault leap, ceiling-safe leap. scen_dishwasher checks break/repair.
- v2.12.8: bombs with warning circles + craters, roof hole x2, show ends sooner, clearFx fade-out.
- v2.12.9: chair sit + punch, real craters (apron cut), poll card corners.
- v2.12.10: Local/Global Admin Abuse test commands, :privatelobby.
- v2.12.11: arms out and hands together for the dishwasher charge.
- v2.12.12: chair show (slam + punches), nuke, UI fade during the show, arm animations fixed, no effects mid-flip.
- v2.12.13: lighting restored after the show, leaves from the south with foot thrusters, seated idle motion.
- v2.12.14: fly offer, pads/prompts off during the show, nuke at the dishwasher spot, fewer odd poses, no z-fight, scen_dishwasher covers pads/prompts.
- v2.12.15: poll visible during the show, pads closed in PartyService, smash UI per object, invisible hit boxes cleared.
- v2.12.18: holes cut earlier pieces (real holes), no crack lines, fly + giant offers, bomb-shaped nuke, quick 5-4-3-2-1.
- v2.12.19: bigger nuke that breaks half the table, slow glow/fire fade, pet hunt with Glitch Fox, new ending timeline.
