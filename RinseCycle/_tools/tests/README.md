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
- v2.12.20: touching the room floor always sends you back to spawn (scen_floor).
- v2.12.21: pets a bit slower (30/16), nearly stopped while held (1.5).
- v2.12.22: big holes drop tiles by tween (scen_dishwasher still checks solidity under holes and healing); adminsim shows the fly chip for "Klushy".
- v2.12.24: power-up pick card for everyone (fly/giant/speed), poll hint line, hotkeys off during the show (no new scenario needed; scen_abuse still passes).
- v2.13.0: show update (power-up pick card, results card, finale fade, new black hole/tornado/meteors/fireworks); effects need the giant, which the offline sim cannot build, so they are only syntax/type checked here.
- v2.14.0: first-run tutorial, UFO, grabs, nuke countdown (tested with scen_abuse, scen_hud; effects still need the giant, which the offline sim cannot build).
- v2.15.0: clubs waits / kick bans / "you were kicked" notice (`scen_clubs`), tutorial rework with Skip question and reward (`scen_tutorial`), pet delete question and tutorial card as phone-size dumps (`scen_uishots`, render with guirender.py), show script rewrite (scen_abuse still passes), lobby Snapshot/HardReset.
  - `scen_clubs`: needs the second sim player (G.victim); covers leaving (24 h wait for any club), being kicked (ban on that club only, donated points removed, notice in the profile), a player who was away (found out on "Mine"), the ban running out and `DataService.ResetClubCooldowns`.
  - `scen_tutorial`: the card, the camera turn (CameraType goes Scriptable and back), Skip asks first, Keep going / Skip it, no reward for skipping, the reward once for finishing, the Pets button back afterwards.
  - `scen_uishots`: dumps for guirender.py (the renderer does not wrap long text, so check boxes, not line breaks).
- v2.16.0: analytics + Premium (`scen_analytics`: fake AnalyticsService and DataStore, funnels once / per attempt, progression, economy buffering, DataStore merge, retention bits, leave counters, the Telemetry whitelist and rate limit, every report, Premium bonus / daily gift / badge flag), the new lobby layout (`scen_pads`, `scen_lobby`, `scen_lobbyfun`, `scen_abuse` still pass; render with `harness.luau lobby` + `render.py 0 215 120 0 0 -20 60 1280 800` for the overview), and `scen_eventui` (dumps of the countdown pill, speech box, power-up card, vote card, results and prize card at 844x390, 390x844 and 667x375 for guirender.py).
- v2.17.0: pass-drop card (`scen_global` presses VIEW / CLOSE; `scen_passdropui` dumps the card and the 25-winner window at phone sizes), walking thumb vs spray finger (`scen_touchspray` sends fingers through the bound `RinseScrubTouch` action: thumbstick corner = Pass, elsewhere = Sink), 1.5x touch reach (`scen_touchreach`), tool sound keys (`scen_toolsounds`), dish spacing in all three levels (`scen_dishspacing`, exact bounds for round parts) and the counter props (`overlapcheck.py arena2.json`), craters taking pad signs / the event zone with them (`scen_dishwasher`), badges (`scen_badges` now has a stateful BadgeService: award once, stale note healed, switched-off badge reported, audit rows) and the board REFRESH plate (`scen_boards`: click, cooldown). The sim can't hear sounds, build the giant (so the chair-show shooting is type checked only) or move the real camera (the game resets it every frame, so touch tests look at the action's result).
- v2.17.1: HUD right column no longer depends on the player count (scen_hud still passes; the change deletes the code that read the count, so there is nothing new to test).
- v2.18.0: `scen_playerlist` (2 players = 2 rows, 10 players = 4 rows tall with scrolling, the HUD column and the reserved space do not move, Tab closes / opens it, Roblox's list is switched off), `scen_pads` now walks along the wall of the pad (not moved) and through it (put back near the edge, not the middle).
- v2.18.1: `scen_boards` now checks the board has no plate / prompt left, the Refresh chip shows only near a board, and a tap, X and D-pad up all reach the server (the 20 s wait message); `scen_playerlist` prints the room the list was given.
- v2.18.2: the opening shot is lifted 25 studs (camera work cannot be seen offline: scen_abuse / scen_eventui / adminsim still run it without errors).
- v2.18.3: the ending camera follows the giant out through the roof and cuts back (AdminClient `exitShot`, server attribute `AbuseGiantLeaving`; cannot be seen offline, scen_abuse / adminsim still run without errors) and crater props fade back in instead of snapping (`scen_dishwasher` still checks the table is solid and healed afterwards).
- v2.18.4: `scen_boards` checks the board has no prompt at all (plate / Next page / Refresh), the two chips sit side by side and fade with distance (hidden far away, half at 37 studs, all the way in at 15), Next page (tap, F, controller X) flips the nearest board's page, and the keys do nothing once the chips are gone; `scen_boardchips` dumps the chips at computer and phone sizes for guirender.py (`python3 guirender.py gui/chips_pc.json out.png 1280 720`; the renderer does not place bottom-anchored boxes exactly, so check the shapes and key badges, not their place on the screen).
- v2.18.5: `scen_boards` now uses the shorter range (half faded at 18 studs, all the way in at 10, gone at 30), hides the chips while `ClientState.Party` is set (a party pad) and checks F does nothing there; `scen_boardchips` stands 10 studs away (inside the fade band the dump is partly see-through).
