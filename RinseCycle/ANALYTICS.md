# Analytics and funnels (v2.16.0)

Goal: find out **where players get stuck or leave**, so you can fix retention. Two things work together:

1. **Roblox's own dashboards** (Creator Hub > your experience > **Analytics**): Funnels, Economy, Progression, Custom
   events. The game sends them for you; you only look.
2. **The in-game report** (`:analytics` in the admin panel, owner/Developer only): the same moments, tallied per day in a
   DataStore, with numbers you can read straight away (no 24-hour wait) and things Roblox doesn't show (where players
   were standing when they left, device split, script errors, retention per sign-up day).

Nothing in it can break the game: every call is wrapped, and if the two new scripts are missing the game plays exactly
the same, it just records nothing.

## Set-up (once)

1. **Scripts.** Create two new ModuleScripts and paste the code from the copy page:
   - `ServerScriptService > Server > Services > Analytics`
   - `StarterPlayer > StarterPlayerScripts > Client > Telemetry`
   and replace every other script the copy page lists (they carry the hooks).
2. **Publish the game** (File > Publish to Roblox). Roblox only accepts analytics events from a **published game on a
   live server**: events from Studio and from the client are ignored. (Studio still runs everything; `:analytics` then shows
   only the numbers of that one test session and writes nothing to the DataStore.)
3. **Turn on API access** for the DataStore (Game Settings > Security > *Enable Studio Access to API Services*, only
   needed if you want Studio tests to read/write; the live game doesn't need it).
4. **Play it for real** (join the published game yourself, walk into a pad, buy an upgrade). Within a minute or two the
   Funnel page unlocks; the charts then take up to **24 hours** to fill.
5. **Creator Hub > Creations > Rinse Cycle > Analytics > Funnels.** Roblox creates one tab per funnel name by itself
   once events arrive (up to 10 funnels; this game uses 7). Use **Add funnel** if a tab is missing, and pick:

| Funnel tab | What it is | Steps |
|---|---|---|
| **Onboarding** | once per player, new players only | joined > screen loaded > moved > walked into a pad > party launched > arrived > intro done > cleaned first spot > sold a tank > opened the Upgrade Book > finished the tutorial > cleared dishwasher 1 > back in the lobby > 2nd run > came back another visit |
| **Run** | every attempt | pad > Create > launched > arrived > intro done > first spot > sold > 25% > 50% > 75% > cleared > lobby |
| **Tutorial** | every attempt | the five tips, the book, finished |
| **Purchase** | every Robux prompt | prompt opened > bought |
| **Daily** | reward waiting on join > window opened > claimed |
| **Pets** | egg shop opened > hatched > equipped |
| **Event** | Admin Abuse: sign > RSVP > joined live > still here at 5 / 10 / 20 min > end |

   Set the date range to start **after** the day you published (Roblox warns if a range spans a funnel change), and use
   the breakdowns (platform, age, country) to compare phone vs computer.
6. **Economy** tab: money earned and spent (Bubbles, Gems and in-run Coins), by what it was spent on (`Perk:CoinSoap`,
   `Egg:...`, `RankRoll`, `Upgrade:ScrubPower` ...). **Progression** tab: the `Dishwasher` path (start / complete / fail
   per level) and `Rebirth`. **Custom** tab: `Feature` (what menus and buttons people use), `Leave` (where and how long
   they stayed), `Perf` (frame rate).
7. Roblox's built-in **Retention**, **Engagement** and **Monetization** pages need no set-up at all: D1 / D7 retention is
   already there.

Roblox's limits (the game stays inside them): 10 funnels, 100 steps each, 3 custom fields per event, 100 custom event
names, 20 economy transaction types, and 120 + 20 x players events a minute (the game sends at most 40 + 6 x players).

## Reading the in-game report

Admin panel > **Global > Analytics** (or the command `:analytics`). Pick a report and how many days; the arrows flip
between the nine reports.

| Report | Answers |
|---|---|
| Overview | players, new players, visits, average visit length, runs started / cleared, errors, per day |
| What new players do | the Onboarding funnel for everyone who signed up in the period, with % of the first step, % of the step before, and **BIGGEST DROP** marked |
| Retention | per sign-up day: D1, D2, D3, D7, D14, D30 (came back that many days later) |
| Where players leave | where new players were when they left their **first** visit (`Lobby`, `Pad`, `Run L1 0-25%`, `Tut3`, `Win:Shop` ...), how long they stayed, the same for everyone |
| Runs | the Run funnel, level by level, plus teleport failures, Leave presses and mid-run disconnects |
| Features used | everything players did, by number of players, with the raw key (use the Filter box) |
| Economy | where Bubbles / Gems / Coins come from and go, and Robux spent per product |
| Devices and errors | phone / tablet / computer / console, frame-rate buckets, "lost in the lobby", the commonest script errors |
| Admin Abuse show | the show funnel and the vote / prize counts |

Context words: `Lobby` walking about, `Pad` standing in a party pad, `Run L2 25-50%` inside dishwasher 2 and how far along,
`Results L2` on the results screen, `Show min 7` seven minutes into the show, then `/ Win:Shop` (a window was open),
`/ Tut4` (that tutorial tip was showing) or `/ Cutscene`.

## How to use it to find retention problems

1. **Onboarding funnel, biggest drop.** That step is where new players give up. Common ones: *Walked into a pad* (they
   don't know what to do: the new arch sign and arrow are for that; compare before and after), *Arrived* (teleport trouble:
   check `Runs` > "Runs that could not start"), *Cleaned the first spot* (they can't scrub: controls on a phone), *Sold a tank*
   or *Opened the Upgrade Book* (the tutorial loses them), *Finished the tutorial* (too long: compare `tut.skipask`).
2. **Where players leave > new players.** If `Run L1 0-25%` or `Tut3` is the top row, they quit in the first minutes of the
   run; if `Lobby` is, they never found a pad (`Devices and errors` > "Lost in the lobby" counts them at 1 and 3 minutes).
3. **Retention.** D1 under ~20% means the first session doesn't make them want more: look at what the day-1 returners did
   (Features) that the others didn't (daily reward claimed? pet hatched? second run?).
4. **Devices.** If phones convert much worse than computers at one step, test that step on a phone.
5. **Errors.** A script error that appears in the hundreds is a bug players hit; fix it first.
6. **Event.** The show funnel's "still here at 5 / 10 / 20 min" shows when people drift off during Admin Abuse.

## What is recorded

Every moment is a short key (full list and meanings: `Config.Analytics` in Config.luau, which is also what the report
reads). Counters per UTC day: `n:` times it happened, `u:` different players, and, for each sign-up day, `f:` how many of
those players ever reached it. No names, no chat, no personal data is stored: only counts. The DataStore
`RinseCycle_Analytics` holds one document per day (`D20261008`) and one per sign-up day (`C20261008`); each server adds its
counts every 2 minutes and when it closes.

Adding a moment: add `{ "key", "what it means" }` to `Config.Analytics.Events`, call
`DataService.Track(player, "key")` where it happens (client: `ClientState.Track("key")` and add the key to
`ClientEvents`), and optionally add it to a funnel's `Steps`. Players who played before v2.16.0 are counted as "played
before analytics": they appear in the daily numbers but not in the sign-up funnels.

## Roblox Premium

Players with Roblox Premium get +10% Bubbles in runs (a "Premium +10%" chip under the HUD) and a small daily gift
(150 Bubbles + 3 Gems, once per UTC day, with a popup). Tune it in `Config.Premium`. Roblox also pays you
Premium-engagement money automatically for time Premium members spend in your game; no set-up needed.
