# Z-targeting spec (MM-faithful)

What our Z-targeting must do to feel like Majora's Mask, in our units, and how far the
current code (`game/actors/targeting/`, `player/player.gd` `_update_lock`, `game/story/talk.gd`)
is from it. Source rules and citations: `mm_z_targeting_decomp.md` (zeldaret/mm `3be2e241`).
The range table, weighted distance, leash formula, sign gate and Z timer were re-checked
against the source by hand.

## Decisions (user, 2026-11-11)

- **Faithful quirks.**
  - A lock holds through walls; line of sight only matters for acquiring.
  - The hostile tier always wins.
- **Hold mode is the default.** Switch mode is an option.
- **1 unit = 4 cm.**

## Units

- **Distance: 1 MM unit = 4 cm.** Human Link's `ceilingCheckHeight` is 40 units and our
  player is 1.6 m (`BODY_HEIGHT`), so distances keep the same feel measured in body
  heights. Check: MM's default range (350 units) comes out at 14 m, our current enemy range.
- **Time: 1 frame = 1/20 s.** MM's gameplay runs at 20 Hz.
- **Angles:** 0x10000 = 360°.

## 1. Who can be targeted (the search runs every frame)

The search runs every frame whether or not Z is pressed. Its result is the **hover
candidate**, marked by the arrow, and pressing Z locks exactly that.

A candidate must pass all of these checks:

1. **Targetable and enabled.** "Lock-on disabled" still gets hovered (Tatl looks at it) but
   shows no arrow and can't be locked.
2. **Not the current lock** (unless flagged refindable).
3. **In front of the player's body facing**, not the camera's:
   - Unlocked: within **±60°**.
   - Locked (looking for the next target): within **±90°**.
4. **In range**, measured as 3D distance between the two origins (the feet):
   - Unlocked: plain distance against the type's range.
   - Locked: the distance is weighted by angle, ×√0.6 straight ahead rising to ×1.0 at 90°.
     The comparison is done on squares, so the weights are 0.6 and 1.0 there. Straight
     ahead, a next target therefore qualifies out to 1.29 × its range.
5. **On screen:**
   - Horizontally: within the screen plus 20/320 of its width on each side.
   - Vertically: within the screen plus 160/240 of its height above and below, so very
     generous.
6. **Line of sight** from the player's focus (head) to the target's focus. Level collision
   blocks it, unless the surface is flagged see-through (grates, fences).

**Picking among candidates:**

- There are **two tiers**:
  - **Hostile tier:** boss, enemy and dynamic-scenery categories.
  - **Everything else:** NPCs, signs, chests, switches, doors and so on.
  - If anything in the hostile tier qualifies, the other tier is never considered. An enemy
    in the cone beats a much closer NPC.
- Within a tier, the **lowest (weighted) distance** wins. There is no angle weighting when
  unlocked: the cone only filters.
- Exact ties go to the target that existed first.
- `priority` (lower wins) applies only when no zero-priority candidate qualifies.

**Range types** (per target; acquire / release, with release = √(range × leash) because of how
the table is encoded):

| Type | Acquire | Release | Used for |
|---|---|---|---|
| 0 | 2.8 m | 4.0 m | signs, chests, grottos, small NPCs |
| 1 | 6.8 m | 8.3 m | Deku Baba, Gorons, dogs |
| 2 | 11.2 m | 50 m | Keese, Like Like, Leevers: hard to shake |
| 3 | 14 m | 17.1 m | **default**: most enemies and NPCs |
| 4 | 28 m | 34 m | Dragonfly, switches |
| 5 | 40 m | 49 m | bosses, Garo master, Iron Knuckle |
| 6 | 4.0 m | 4.1 m | most town NPCs |
| 7 | 5.6 m | 6.0 m | (Tingle's dad only) |
| 8 | 9.6 m | 14.9 m | (unused) |
| 9 | 11.2 m | effectively never | |
| 10 | 100 m | 122 m | (MM only) |

## 2. Keeping a lock

The lock drops **only** when:

- the target dies, is deleted, or turns its targetable flag off (or gets lock-on disabled), or
- the player passes its **release distance** (3D, unweighted).
  - Ignored for the first **0.5 s** of a lock (the 10-frame grace while the reticle flies in).

The lock does **not** drop for losing line of sight, turning away, going off screen, or any
time limit. A lock holds through walls.

The lock is forced off by cutscenes, death, stopped time and hookshot flight. During talking
the lock is kept, but Z presses are ignored.

On a forced release (target died or out of range) with Z still held, the camera stays in
target mode and a new Parallel can't start until Z is released. This is MM's answer to the
video's "don't snap the camera wildly when the target dies".

## 3. Buttons

There are two **control modes** (an option):

- **Hold:** the lock lasts while Z is held. On release the lock lingers for **0.25 s**
  (frames 5 → 0); the reticle vanishes at once.
- **Switch:** a press latches the lock; another press moves on (see below).

**Pressing Z** (on the press, not while held):

1. With a hover candidate: lock onto it. The lock sound is "hostile" or "friendly" by tier.
2. Already locked: move to the **arrow candidate**, the best *other* target under the locked
   weighting (±90°, ×0.6–1.0).
   - If there is none: Switch mode unlocks; Hold mode does nothing.
3. Nothing to lock: **Parallel.**
   - The player keeps their current facing, the camera swings behind, and movement strafes.
   - If the player is against a wall and faces within **45°** of it, they first square up
     to face it.

**Cycling** is always "best other candidate right now", never a fixed list order.

- **Hold-mode tap-tap:** re-pressing within **0.2 s** of releasing (frames 4 → 1) locks the
  **next** target, because the old one is still excluded from the search. After that window
  a press picks the best target again, which is usually the same one.

**Stick held back** while locked (stick at least 0.9, within ±45° of straight back from the
player's facing):

- The search pauses, so no arrow candidate shows.
- In Switch mode the next press unlocks instead of cycling ("escape a lock-on loop").

## 4. Hover feedback

**Arrow:**

- When unlocked, the arrow sits over the hover candidate, so you see what Z will grab before
  pressing.
- When locked, it moves to the next candidate.
- It spins 330°/s.
- Colours by tier: **NPC blue** (150,150,255), **enemy/boss yellow** (255,255,0),
  **everything else green** (0,255,0).

**Reticle** (on lock):

- It flies in from the screen centre over **0.25 s**. Radius: 500 → 470 → 380 → 280 → 180 → 80
  per frame, then pops to 120.
- Three fading trail copies show during the fly-in.
- It then spins 169°/s.
- On release it grows out and fades in about 0.15 s.
- Its colour is fixed at lock time.

**Tatl** (no fairy for now):

- Her hover moves to a new candidate in 0.15 s.
- We could use this timing for the arrow's own move.

**While locked:**

- The player's body turns toward the target at 440°/s.
- Movement strafes.

## 5. Talking and reading

**Each talkable offers itself every frame,** within a cylinder (xz radius, |dy| limit). The
closest xz offer wins. Typical radii:

- 100 units (4.0 m)
- 120 (4.8 m)
- 70 (2.8 m)
- collider radius + 50 (+2 m)

**A locked target skips the range check:** you can talk to it from anywhere inside its
release distance.

**Talk is refused:**

- while locked onto a *different* target, or
- in the air.

**Prompt:** "Speak" for NPC- and enemy-category targets, "Check" for everything else.

**Signs:**

- They offer only within **±56°** of their front face, inside **2.7 m** (68 units).
- 1 s cooldown after reading.
- Range type 0, so the arrow appears within 2.8 m.

The "face it to read it" feel comes from **two gates**:

- the hover cone: the player faces within 60° of the sign, and
- the sign's gate: the player stands in front of its face.

**Carrying / picking up:** the player must face within 45°. The closest-faced object wins.

## 6. Enemies nearby

**Battle music:**

- The nearest hostile enemy within **20 m** (3D, ignoring facing and walls) sets battle music.
- The enemy layer is full at ≤ 6 m and fades linearly to silent at 20 m.

**No automatic lock-on.**

**Battle stance (fight movement, battle camera)** comes only from a lock on a **hostile**
target.

- A friendly lock uses a follow-target camera instead.
- Enemies can ask "am I the one locked?" to take turns attacking.

## Where we are now

| Rule | MM | Ours |
|---|---|---|
| Facing reference | player body, ±60° (±90° next target) | camera view, ±75° |
| Distance | 3D, feet to feet | flat xz |
| Choice | 2 tiers, then nearest | 3 tiers (enemy > NPC > POI), angle × distance score |
| Range | per-target type table | 3 per-kind defaults (14 / 7 / 9 m) |
| Release | per-type √(range × leash), 0.5 s grace | 1.3 × range |
| Line of sight while locked | ignored | drops after 1 s unseen |
| On-screen check | yes | no |
| Hover arrow before pressing | yes | no |
| Cycling / tap-tap retarget | yes | no |
| Switch mode | yes (option) | hold only |
| Stick-back escape | yes | no |
| Parallel (no target) | facing locked, strafe, wall square-up | camera recentres only |
| Reticle | fly-in, spin, colours by tier | static ▼ label |
| Talk while locked | skips range; refuses others | prefers the locked one, else closest in reach |
| Sign facing gate | ±56° of the sign's front | none |
| Battle music by distance | yes | no |
| Hostile vs friendly lock | stance and camera differ | same |
| While climbing | Parallel allowed (CLIMBZ camera) | no targeting |

## Not yet researched

- How the camera frames player and target (`z_camera.c` BATTLE / FOLLOWTARGET / TARGET
  settings). This needs its own research pass.
- Whether a lock can be taken while climbing or swimming in practice.
- Hold-mode tap-tap with only one candidate: the old lock should be kept. This is inferred
  from the code order, not seen in play.

## Status (2026-11-11)

**Built:**
- Rules and buttons: `game/actors/targeting/`.
- Marks and letterbox: `game/ui/target_marks.gd`.
- Talking: `game/story/talk.gd`, `talkable.gd`, plus the sign gate in `signpost.gd`.
- Battle-music level: `TargetLock.battle_level`, sent to the `battle_music` group.
- Camera: `CameraDirector` Z modes, from `mm_z_camera_decomp.md`.

**Tests:**
- `tests/targeting/lock_rules.tscn` and `talk_rules.tscn` (headless).
- `marks_render.tscn` and `camera_render.tscn` (windowed, `OUT=`).
- `sandbox.tscn` to play.

**Still to do:**
- Sidehop and backflip (jump while locked with the stick to the side or back). For now it's always the jump slash.
- Enemies taking turns via `TargetLock.is_locked_on`.
- Targeting while climbing (MM's CLIMBZ). It's off for now.
- The talk camera (KeepOn3).
- Wiring zone music to `battle_music`.
- Real `lock_on` / `lock_off` sounds.
