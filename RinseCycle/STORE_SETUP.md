# Rinse Cycle: Store Setup and Art Prompts

## Part 1: What to create on the Creator Dashboard

Creator Dashboard → your experience → **Monetization**.

For each item below:
1. Create it with the **exact name and price** shown.
2. Copy its ID (the number in its URL).
3. Open `ReplicatedStorage/Shared/Config.luau`, find the line with the matching **Key**, and replace `Id = 0` with the ID.
4. Republish the game.

Items left at `Id = 0` only work as free test items in Studio. They never work in the live game.

### Game Passes (Monetization → Passes), 12 total

These are in `Config.GamePasses`.

| # | Key (in Config) | Name | Price (R$) | What it does |
|---|---|---|---|---|
| 1 | `DoubleCoins` | 2x Coins | 99 | Double coins from the drain in every run |
| 2 | `SuperScrub` | Super Scrub | 129 | Scrub 50% faster in every run |
| 3 | `MegaTank` | Mega Tank | 149 | Tank holds twice as much |
| 4 | `LuckyCharm` | Lucky Charm | 99 | Twice as much golden dirt |
| 5 | `PetSlots` | +2 Pet Slots | 149 | Equip 5 pets instead of 3 (pops up when your slots are full) |
| 6 | `AutoDrain` | Auto Drain | 149 | Tank sells itself when full |
| 7 | `DoubleBubbles` | 2x Bubbles | 179 | Double Bubbles from every finished run |
| 8 | `VIP` | VIP | 199 | +25% coins and +25% Bubbles forever |
| 9 | `DoubleLuck` | x2 Luck | 149 | Better odds on Rare+ ranks (button under "Get more Gems") |
| 10 | `ToolNozzle` | Spray Nozzle | 49 | Start every run with the Spray Nozzle |
| 11 | `ToolWasher` | Pressure Washer | 99 | Start every run with the Pressure Washer |
| 12 | `ToolCannon` | Foam Cannon | 199 | Start every run with the Foam Cannon |

### Developer Products (Monetization → Developer Products), 11 total

These are in `Config.DevProducts`. Players can buy them again and again.

| # | Key (in Config) | Name | Price (R$) | Gives |
|---|---|---|---|---|
| 1 | `Bubbles1` | Handful of Bubbles | 19 | 250 🧼 |
| 2 | `Bubbles2` | Bucket of Bubbles | 49 | 800 🧼 |
| 3 | `Bubbles3` | Tub of Bubbles | 99 | 2,000 🧼 |
| 4 | `Bubbles4` | Bathtub Overflow | 199 | 5,000 🧼 |
| 5 | `Coins1` | Coin Splash | 15 | 250 💰 (in a run, scales with the level) |
| 6 | `Coins2` | Coin Wave | 39 | 900 💰 |
| 7 | `Coins3` | Coin Flood | 89 | 2,500 💰 |
| 8 | `Gems1` | Pouch of Gems | 29 | 30 💎 |
| 9 | `Gems2` | Sack of Gems | 79 | 100 💎 |
| 10 | `Gems3` | Chest of Gems | 199 | 300 💎 |
| 11 | `RestoreStreak` | Restore Streak | 29 | Saves your daily streak after a missed day |

### Other settings in Config

- **Community reward:** `Config.Social`. `GroupId = 0` means "the group that owns the game", so if the game is published under your group, you don't need to change anything. The reward is 500 🧼 + 25 💎, once per player.
- **Follow / Like rewards:** players tap the button, then rejoin.
  - The follow is checked through the `roproxy.com` proxy, so turn on Game Settings → Security → **Allow HTTP Requests**.
  - Likes can't be checked by any game, so that reward is paid on trust. Set `LikeReward = nil` to remove it.
- **Regional pricing:** safe to turn on. The shop asks Roblox for each player's real price once an item has an ID.
- **Your profile:** `CreatorUserId = 2297538363` is already set (it's shown on the "Follow the dev" card).
- **Codes:** `Config.Codes` currently has these codes:
  - `RELEASE` (300 🧼 + 10 💎)
  - `SQUEAKY` (150 🧼)
  - `BUBBLES` (15 💎)

  To add a code, add a line to `Config.Codes` and republish. Then post it in the game description or the community.

---

## Part 2: Art prompts (copy these to an image AI)

### Shared style (paste this first, every time)

> Roblox game pass icon for a cute dishwasher-cleaning game called "Rinse Cycle". Square 512×512 image. Bright, glossy, cartoon 3D render in the style of popular Roblox simulator icons: chunky rounded shapes, thick soft outlines, strong rim lighting, saturated colours. Soap-bubble theme: sparkling iridescent bubbles and foam around the subject. Keep one big subject centred and large, inside the middle 80% (the corners may be cropped to a circle). Soft radial gradient background in the colour given. **No text, no letters, no numbers, no logos, no watermark.**

### Game passes

1. **2x Coins.** A big shiny stack of gold coins with a glowing "x2" shape made from two gold coins side by side (no text), soap bubbles popping around it. Background: warm gold → orange.
2. **Super Scrub.** A yellow-and-green kitchen sponge with a flexing cartoon arm and motion streaks, flecks of foam flying. Background: bright green.
3. **Mega Tank.** A chunky blue water tank or canister, overflowing with soapy water and bubbles, a little glowing gauge maxed out. Background: deep blue → cyan.
4. **Lucky Charm.** A glowing golden four-leaf clover floating above a sparkling gold plate, with golden sparkles. Background: emerald green.
5. **+2 Pet Slots.** Two cute pets (a yellow rubber duck and a small white bunny) happily popping out of soap bubbles, with a paw-print sparkle. Background: purple → pink.
6. **Auto Drain.** A shiny chrome sink drain with a swirling blue whirlpool and gold coins spinning into it. Background: teal.
7. **2x Bubbles.** Two giant iridescent soap bubbles side by side, each with a pink bar of soap inside, and foam at the bottom. Background: pink → lavender.
8. **VIP.** A gold crown sitting on a fluffy cloud of foam, with sparkles and a purple velvet ribbon. Background: royal purple with gold rays.
9. **x2 Luck.** A glowing purple gem with a golden four-leaf clover in front of it, surrounded by little stars and bubbles. Background: indigo → violet.
10. **Spray Nozzle Forever.** A bright blue spray nozzle / hose gun shooting a sparkling arc of water with droplets. Background: sky blue.
11. **Pressure Washer Forever.** A sleek blue pressure-washer gun with a long chrome wand and yellow tip, blasting a powerful thin jet of water. Background: electric blue → navy.
12. **Foam Cannon Forever.** A chunky white-and-lilac foam blaster with a see-through pink soap tank on top, firing a huge puffy blob of foam. Background: lilac → pink.

### Developer products

Same shared style. These don't need icons to sell, but they look nicer with them.

- **Bubbles packs:**
  - Handful: a small handful of bubbles with a pink soap bar.
  - Bucket: a small bucket overflowing with bubbles.
  - Tub: a bathtub full of bubbles.
  - Bathtub Overflow: a bathtub exploding with a tidal wave of foam.

  Background: pink.
- **Coin packs:**
  - Splash: a few gold coins splashing out of soapy water.
  - Wave: a wave of gold coins.
  - Flood: a huge flood of gold coins and bubbles.

  Background: gold.
- **Gem packs:**
  - Pouch: a small cloth pouch of blue gems.
  - Sack: a big sack of gems.
  - Chest: a treasure chest overflowing with glowing blue gems.

  Background: blue.
- **Restore Streak:** a glowing orange flame on top of a calendar-shaped soap bar, with sparkles. Background: orange.

### Community (group) art

**Group emblem (icon, 512×512):**

> Emblem for a Roblox game community called "Rinse Cycle". Square 512×512, cartoon 3D style like top Roblox simulator logos. A shiny white-and-chrome dishwasher with its door open, bursting with iridescent soap bubbles and foam. A cheerful yellow sponge with a tiny smile peeks over the door edge. Sparkles, strong rim lighting, thick soft outlines. Background: a bright aqua (#38BDF8) → deep navy (#0B2545) radial gradient. Subject large and centred, safe inside a circle crop. No text.

**Community banner (if your community page has one, wide 1920×1080 or 16:9):**

> Wide banner for a Roblox community for the game "Rinse Cycle". Cartoon 3D render, bright and glossy. A giant kitchen seen from dish height: a huge open dishwasher on the left, glowing blue inside, with tiny blocky Roblox-style cleaning crew characters in blue caps holding sponges, standing on the dish rack. Big plates of spaghetti, pizza and a royal golden plate being washed. Soap bubbles and foam float everywhere, and gold coins and pink soap bars sparkle in the air. Warm evening light through a window. Leave the right third calmer (just bubbles and a soft aqua-to-navy gradient) so a title can be added later. No text.

**Game icon (optional, 512×512):**

> Roblox game icon for "Rinse Cycle". A tiny blocky Roblox character in a blue cap riding a giant soap bubble out of an open glowing dishwasher, holding a sponge up high, with a big smile. Plates and foam fly around. Cartoon 3D, glossy, very colourful, bold outlines. Aqua → navy background. No text.
