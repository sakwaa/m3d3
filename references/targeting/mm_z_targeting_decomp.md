# Majora's Mask Z-targeting: rules and constants from the decomp

Source: zeldaret/mm `main` @ `3be2e241` (fetched 2026-11-11). Cross-checked against zeldaret/oot `main` @ `14759abf`.
The decomp now calls the system **Attention** (`Attention_*`). Older names were `Target_*` / `TargetContext` / `func_800B...`.
This document paraphrases the logic. It is a behaviour spec, not code.

Unless noted, line numbers refer to MM files:
- `src/code/z_actor.c` (A)
- `src/overlays/actors/ovl_player_actor/z_player.c` (P)
- `src/code/z_player_lib.c` (PL)
- `include/z64actor.h` (H)
- `include/z64player.h` (PH)

**Units.** Distances are in world units. Link's collision and talk numbers (sign talk radius 68, carry pickup 50) fit the usual reading of 1 unit ≈ 1 cm. Nothing in the source contradicts that. Angles are binangs: 0x10000 = 360°, so 0x1000 = 22.5°, 0x2000 = 45°, 0x2AAA = 60°, 0x4000 = 90°, 0x8000 = 180°.

**Frames.** Timers and steps count game frames. MM and OoT gameplay normally runs at 20 Hz on N64 (`R_UPDATE_RATE` 3). This is general knowledge and was **not re-verified in this pass**. Our game will probably run logic at 30 or 60 Hz, so scale the frame counts by time.

**Terms**
- **focusActor**: the actor Link is locked onto (or talking to).
- **Tatl hover actor**: the actor Tatl flies to. Tatl is Navi in OoT.
- **arrow hover actor**: the actor the floating triangle arrow is drawn over.
- **reticle**: the four spinning lock-on triangles.
- **Parallel**: Z held with nothing to lock onto. Link and the camera hold one heading and Link strafes.

---

## 1. Choosing a target candidate

The game runs `Attention_FindActor` (A:3823) once per frame from `Attention_Update` (A:642), at the end of `Actor_UpdateAll` (A:2694, about A:2787). The result is used as both the arrow hover actor and, when nothing is locked, the Tatl hover actor. Pressing Z locks onto the **Tatl hover actor** (section 3). So "what Z will grab" is whatever was found on the previous frame.

### 1.1 Who qualifies (`Attention_FindActorInCategory`, A:3734)
An actor must pass every check below, in this order:
1. `update != NULL` (still alive) and not the player.
2. `ACTOR_FLAG_ATTENTION_ENABLED` (bit 0) is set. MM also accepts `ACTOR_FLAG_CAMERA_DRIFT_ENABLED` (bit 30), but only for the separate "camera drift" result, which is not a target. OoT has no camera drift.
3. It is not the current `focusActor`, unless it has `ACTOR_FLAG_FOCUS_ACTOR_REFINDABLE` (bit 19). The flag is cleared when that actor is re-chosen (P:4997).
4. The weighted squared distance (1.2) is smaller than the best found so far. The comparison is strict `<`.
5. It is **in range**: `distSq < range²` for the actor's `attentionRangeType` (1.3). Note that `distSq` here is the *weighted* value.
6. It is **roughly on screen** (`Attention_ActorOnScreen`, A:3702). The actor's `focus.pos` projects to x in (-20, W+20) and y in (-160, H+160) pixels on a 320×240 screen. `X_LEEWAY` = 20 and `Y_LEEWAY` = 160, so the vertical tolerance is very generous.
7. It is **not blocked**. `BgCheck_CameraLineTest1` runs a line test from the player's `focus.pos` (head/eye height) to the actor's `focus.pos` against camera-collision polys (walls, floors and ceilings all checked). A hit blocks the candidate unless that poly is flagged `SurfaceType_IsIgnoredByProjectiles`. Grates and fences can be flagged this way so you can target through them.

There is **no explicit height (Y) limit**. Height enters only through the 3D distance and the screen test. Culling and draw state are **not** checked directly. The on-screen test stands in for both.

`ACTOR_FLAG_LOCK_ON_DISABLED` (bit 27) does **not** remove an actor from the no-lock search. Tatl still hovers over it, but no arrow is drawn (A:625) and Z will not lock it (P:4983). While a lock is held, such actors are excluded from the next-target search (1.2).

### 1.2 Distance and the facing weight (`Attention_WeightedDistToPlayerSq`, A:1916)
- **Distance.** `xyzDistToPlayerSq = xzDist² + (player.y − actor.y)²`. It is **squared 3D** distance between `world.pos` origins (usually the feet), not focus points. It is recomputed every frame in `Actor_UpdateActor` (A:2628-2630).
- **Facing angle.** `yawDiff = |(actor.yawTowardsPlayer − 0x8000) − player.shape.rot.y|`. This is the angle between **Link's model facing** (shape yaw, not camera yaw, not stick yaw) and the direction from Link to the actor. The yaw is cached once per search (`sAttentionPlayerRotY`, A:3834).
- **When not locked:**
  - Reject if yawDiff > 0x10000/6 = 0x2AAA = **60°**. That is a 120° cone in front of Link.
  - Otherwise the score is the plain distSq.
  - OoT uses the literal 0x2AAA, which is the same value.
- **When locked (choosing the next target):**
  - Reject if yawDiff > 0x4000 = **90°** (a 180° half-space in front of Link), or if the actor has `LOCK_ON_DISABLED`.
  - Otherwise `score = distSq × (1 − 0.8 × (0x4000 − yawDiff)/0x8000)`. The multiplier runs linearly from **1.0 at 90°** down to **0.6 when dead ahead**.
  - While locked, Link's shape yaw is turned toward the current target, so "in front" means roughly "toward the current target".
  - Because the in-range test uses this weighted score, a candidate straight ahead can be up to range/√0.6 ≈ **1.29× its nominal range** away and still qualify.

### 1.3 Range table (`gAttentionRanges`, A:1946; enum H:251)
Each entry is defined as `ATTENTION_RANGES(range, leash)` and stored as `{ range², range/leash }`.
- **Acquire:** distance < `range`.
- **Keep the lock (leash):** stay locked while `(range/leash) × distSq < range²`. That works out to `dist < √(range × leash)`.
- **Quirk:** the decomp's "leash" numbers are therefore *not* the real release distance. The effective leash is the geometric mean of the two numbers. The effective column below was computed from the source formula.

| Type | Range | Table "leash" | Stored scale | **Effective release dist** | Example users in MM (grep of actor overlays, not exhaustive) |
|---|---|---|---|---|---|
| 0 | 70 | 140 | 0.5 | **99** | 49 files: signs (`En_Kanban`), chests (`En_Box`), grottos (`Door_Ana`), small NPCs (Deku scrubs, carpenters), `En_Baba` |
| 1 | 170 | 255 | 0.667 | **208** | 22 files: Deku Baba, Wither Baba, Gorons, dogs, Cucco attack |
| 2 | 280 | 5600 | 0.05 | **1252** | 11 files: Keese (`En_Firefly`), Like Like, Leevers (`En_Neo_Reeba`), Big Octo, Bombchu. This is the "hard to shake" entry |
| 3 | 350 | 525 | 0.667 | **429** | **Default** (`Actor_Init`, A:1172), used by most generic enemies and NPCs. Explicit users include Wizrobe, pirates, Boss_05 |
| 4 | 700 | 1050 | 0.667 | **857** | Grasshopper (Dragonfly), Gibdo-ish `En_Pp`, `Obj_Switch` |
| 5 | 1000 | 1500 | 0.667 | **1225** | Bosses (Odolwa, Gyorg, Twinmold, Goht), Garo master (`En_Jso`), Iron Knuckle, Big Poe-type |
| 6 | 100 | 105.37 | 0.95 | **103** | 49 files: most town NPCs (`En_Ah`, `En_An`, cows, bomber kids) |
| 7 | 140 | 163.33 | 0.857 | **151** | `En_Tsn` only |
| 8 | 240 | 576 | 0.4167 | **372** | none found by grep |
| 9 | 280 | 280000 | 0.001 | **8854** (effectively never) | none found by grep |
| 10 | 2500 | 3750 | 0.667 | **3062** | MM-only (OoT has types 0–9). Used by Twinmold (`Boss_02`), `En_Dragon` (Deep Python), `En_Pametfrog`, `En_Bsb`, `En_Dai` |

The "examples" column is a grep of `attentionRangeType = / ICHAIN ... ATTENTION_RANGE_n` over `src/overlays/actors`. Actors that change type at runtime or use raw numbers were missed.

**Design read.** Short-range types (0, 6, 7) are for things you walk up to: signs, chests and talkers. 1–3 cover ordinary combat. 4–5 and 10 are for big or distant foes. Type 2 and type 9 hold a lock almost indefinitely.

### 1.4 Category priority and ties (`Attention_FindActor`, A:3811-3860)
- **Search order:** `BOSS, ENEMY, BG`, then `EXPLOSIVES, NPC, ITEMACTION, CHEST, SWITCH, PROP, MISC, DOOR, SWITCH`.
- **Hostile priority.** If any normal-priority candidate is found in the first three categories, the rest are **not searched at all**. Any targetable enemy in the cone beats any NPC or sign, even a much closer one.
  - The rule is based on category, not on `ACTOR_FLAG_HOSTILE`. A friendly actor in the ENEMY category still wins.
  - BG (dynamic scenery actors) is in the first group.
- **Within the searched set,** the lowest weighted distSq wins with strict `<`. On an exact tie the actor visited first wins, which is the one **spawned earliest** (actors are appended to the tail of their list by `Actor_AddToCategory`, A:3371, and Boss is searched before Enemy).
- **`targetPriority`** (u8, H:139; `attentionPriority` in OoT):
  - Actors with a non-zero value are tracked separately. The lowest value wins.
  - That result is used **only if no zero-priority candidate was found**.
  - The current focusActor gets `targetPriority = 0x28` (40) every frame while locked (P:5024).
  - Every actor's value is reset to 0 whenever the player has no focusActor (A:2641).
  - In practice this means a *refindable* current target can be re-picked only when nothing else qualifies.

---

## 2. Keeping or losing a lock

### 2.1 Release test (`Attention_ShouldReleaseLockOn`, A:1982)
Player calls this every frame while it has a focusActor (P:5019-5023), except for an auto lock-on actor. The lock is released if any of these hold:
- `update == NULL` (the actor was killed or deleted).
- `ACTOR_FLAG_ATTENTION_ENABLED` was cleared. This is how most enemies drop the lock when they die or burrow: they clear bit 0.
- `ACTOR_FLAG_LOCK_ON_DISABLED` was set.
- **Leash:** `dist ≥ √(range × leash)` (table above), using the plain, unweighted 3D distance. The leash check is skipped while `ignoreLeash` is set (2.2).

**Not checked while locked:** line of sight, the facing cone, being on screen, and any time limit. A lock survives walls and turning away. Only distance, flags or death end it.

There is one off-screen quirk. In `Attention_Update` (A:711-723), if the focus actor projects off screen (z ≤ 0 or |x|, |y| ≥ 1 in NDC) **before the reticle has finished zooming in**, the reticle is dropped. The player's focusActor stays set, so the lock itself remains. The decomp notes this may be a bug.

When a leash or flag release happens, Player sets `PLAYER_STATE1_LOCK_ON_FORCED_TO_RELEASE` (P:5022). While Z stays held this flag:
- keeps the camera in Z/parallel-style mode (`CAM_MODE_TARGET`), and
- blocks Parallel from being re-entered by a new press.

The flag clears as soon as Z is released (P:4920).

### 2.2 Grace period after locking
A new lock sets `zTargetActiveTimer = 15` (P:5004). The timer counts down to 5 and is then held there while the lock continues (P:4936-4941). While the timer is ≥ 6, which is the **first 10 frames**, `ignoreLeash = true` (P:4950-4957). You cannot lose a lock to distance during the reticle fly-in.

### 2.3 Actor deletion
`Actor_Delete` (A:3657) does three things:
- If the deleted actor was the focusActor, it calls `Player_ReleaseLockOn` and forces the camera to `CAM_MODE_NORMAL`.
- It clears Tatl hover, forced-lock and bgmEnemy pointers that referenced it.
- `Actor_UpdateAll` also releases the lock if `focusActor->update == NULL` (A:2774-2778).

### 2.4 Player states that kill or block targeting (`Player_UpdateZTargeting`, P:4915)
- The **timer is forced to 0**, which means the lock is lost and Parallel ends, in any of these cases:
  - a cutscene is running (`csCtx.state != IDLE`)
  - a player cs-action is set
  - Link is dead
  - time is stopped (`STATE1_20000000`)
  - Link is flying on the hookshot
- **Talking** (`ACTOR_FLAG_TALK` on the player) keeps the focus state alive but ignores Z presses. `Player_StartTalking` itself sets `focusActor = talkActor` (P:21151).
- **Z cannot start a lock, and the press becomes Parallel instead,** when:
  - the Giant's Mask is worn, or
  - `STATE3_200` or `STATE3_2000` is set (Deku flight-related; exact meaning UNVERIFIED).
- **Z presses are ignored** while the Zora boomerang is in flight or the fishing rod is cast (P:4962-4965).
- **Climbing, hanging and swimming are not excluded** from targeting in this function. Camera modes `CAM_MODE_CLIMBZ` (ladder/vine plus Parallel) and `CAM_MODE_HANGZ` exist (P:11985-12015), so Z-parallel works while climbing. Whether a lock can actually be acquired while climbing or swimming depends on the action functions: UNVERIFIED.
- `Player_ClearZTargeting` (PL:1524) has a mid-air special case. If Link is airborne more than **100 units** above the floor and not already in a jump or fall state, it sets a free-fall flag instead of clearing the Z state flags. The lock pointer is cleared in all cases.

---

## 3. Press, hold and release

All of this is in `Player_UpdateZTargeting` (P:4915-5058). MM and OoT are line-for-line equivalent here (OoT `z_player.c:3881`).

### 3.1 The timer (`zTargetActiveTimer`)
- If Z is held, or the Switch-mode latch is set, or an auto lock-on actor exists: when timer ≤ 5, set it to 5; otherwise decrement it.
- Else, if in Parallel: the timer becomes 0, so Parallel ends **immediately** on release.
- Else, if the timer is non-zero: decrement by 1 per frame.
- The Z-target logic runs only while `timer != 0`, or while talking or charging a spin attack. When it reaches 0, `Player_ClearZTargeting` drops the lock.
- `Actor_UpdateAll` treats the lock as **visually** active only while the timer is ≥ 5 (A:2780-2786). Below 5, the reticle releases and `NA_SE_SY_LOCK_OFF` plays if it had finished spinning in.

### 3.2 Pressing Z (edge-triggered, `press.button & BTN_Z`)
1. The candidate is the **Tatl hover actor** from last frame.
2. If the candidate exists, is lockable, Link is not wearing the Giant's Mask and is not in the Deku flight states:
   - If the candidate is the current focusActor (Tatl hovers over the current target while locked), use the **arrow hover actor** instead. That is the best *other* candidate under the locked-state weighting in 1.2.
   - If that actor exists and differs from the focus, or is refindable: **lock onto it.** Set the timer to 15, clear refindable, clear the "can accept talk offer" flags. In Switch mode, set the latch `PLAYER_STATE2_LOCK_ON_WITH_SWITCH`.
   - Otherwise (no alternative): in **Switch** mode, **release** (`Player_ReleaseLockOn`). In **Hold** mode, nothing changes.
3. If there is no lockable candidate: enter **Parallel** (`Player_SetParallel`, P:4326), unless already in Parallel or forced-release.
   - Parallel stores `parallelYaw = shape yaw`. Link's facing stays fixed and the camera goes to `CAM_MODE_TARGET`, which swings behind Link.
   - If Link is touching a wall and his shape yaw is within **0x2000 (45°)** of facing into it, he first **snaps to face directly away from the wall normal** (yaw = wallYaw + 0x8000). This is the "Z against a wall to square up" behaviour.

### 3.3 Hold vs Switch (`gSaveContext.options.zTargetSetting`; non-zero means Hold)
- **Hold:**
  - Releasing Z stops refreshing the timer. It runs 5→4→…→0 and the lock is cleared on the frame it reaches 0. The reticle disappears on the very next frame (timer 4 < 5).
  - Kafei (MM) and Dark Link (OoT) always use Hold.
- **Switch:**
  - The latch keeps the timer at 5 with Z released, so the lock persists.
  - Pressing Z again moves to the arrow-hover actor if there is one, otherwise releases.
  - The latch is cleared by `Player_ReleaseLockOn` (PL:1515) and also when entering Parallel (P:5049).

### 3.4 Cycling to the next target
Cycling is **not** "next in a list". It is always "best other candidate right now": the closest by weighted 3D distance within ±90° of Link's facing, excluding the current target, with Boss/Enemy/BG categories taking precedence (1.2, 1.4).
- **Switch mode:** each Z press while locked moves to that actor. If none exists, the press unlocks.
- **Hold mode quick re-press:** after release there is a window while the timer is 4…1 (**4 frames**, ≈ 0.2 s at 20 Hz).
  - In that window the reticle has already dropped, so `Actor_UpdateAll` passes NULL as the focus. Tatl's hover target then becomes the best non-focus candidate (the current focus is still excluded from the search).
  - A re-press locks onto **that other actor**: a quick tap-tap retargets.
  - If there is no other candidate, the press finds nothing and Link goes to Parallel briefly. The old focus is still set, so it is kept and Parallel is cleared again. UNVERIFIED in play; inferred from code order.
  - After the timer hits 0, the old target is no longer excluded, and a press picks the best candidate again, which is usually the same one.
- **Holding the stick backward** (stick magnitude ≥ 55 and direction "backward" relative to Link's shape yaw; P:2039-2044) while locked makes `Attention_Update` skip the search, so the arrow hover is NULL (A:651-656).
  - In Switch mode the next Z press then **unlocks** instead of cycling. The decomp comments this as "escape a lock-on loop".
  - Side effect: the enemy-BGM search also does not run that frame.

### 3.5 Tatl/Navi pre-highlight (before pressing)
- Every frame with no lock, the best candidate from section 1 becomes both `arrowHoverActor` and `tatlHoverActor`. **The arrow over an actor before you press Z is exactly what Z will grab.**
- While locked, Tatl stays on the target and the arrow shows the next candidate.
- **Tatl's travel** (A:681-701):
  - On a target change, `tatlMoveProgressFactor = 1.0`.
  - Each frame it steps by −0.25, and Tatl moves `0.25/factor` of the remaining distance (1/3, 1/2, then all of it). She arrives in **3 frames**, linear in practice.
  - Her colour snaps to the new category's colour on arrival.
  - Her target point is `focus.pos + lockOnArrowOffset × scale.y` above the actor. OoT uses `world.pos` for the travel step.
  - With no candidate she returns to Link.

---

## 4. Enemy proximity: battle music and battle state

- **BGM enemy** (A:3750-3756):
  - During the search, any ENEMY-category actor (not Boss) with `ATTENTION_ENABLED` and `HOSTILE` within **500 units** (3D, `distSq < 500²`) is a BGM candidate. The nearest one becomes `attention.bgmEnemy`.
  - This test runs **before** the facing, range, screen and line-of-sight checks, so enemies behind Link or behind walls count.
  - It is the same in OoT.
- **Music** (P:12050-12053 → `Audio_UpdateEnemyBgmVolume`, `src/audio/code_8019AF00.c:5685`):
  - If a bgmEnemy exists, the sequence mode is `SEQ_MODE_ENEMY`.
  - Enemy-layer volume = `(350 − clamp(dist − 150, 0, 350)) × 127/350`: **full at ≤ 150 units, linear fade to 0 at 500 units**.
  - In field BGM, the main track is ducked by the inverse amount.
- **No auto lock-on to enemies.** Nothing in this code locks automatically on proximity. `Player_SetAutoLockOnActor` (PL:1556) is a scripted hook used by specific actors and is treated as *friendly* focus. With Hold, keeping Z down can carry it into a real lock.
- **Battle stance:**
  - Set only when the **locked** actor has `ATTENTION_ENABLED | HOSTILE`: `PLAYER_STATE3_HOSTILE_LOCK_ON` (`Player_UpdateHostileLockOn`, P:3701).
  - This switches Link to fighting animations and movement, and the camera to `CAM_MODE_BATTLE`.
  - A non-hostile lock, or any lock while carrying an object, sets `PLAYER_STATE1_FRIENDLY_ACTOR_FOCUS` and uses `CAM_MODE_FOLLOWTARGET` instead (P:5036-5047, P:11984-11996).
  - `Actor_IsTargeted` / `Actor_OtherIsTargeted` (A:4163) let enemies react only when the lock is hostile. Enemies use this to wait their turn or approach.
- **Lock sound** (A:735-739): `NA_SE_SY_LOCK_ON` for hostile actors, `NA_SE_SY_LOCK_ON_HUMAN` for others.

---

## 5. Talking and reading

### 5.1 Actor-side offer (`Actor_OfferTalkExchange`, A:2060; wrappers `Actor_OfferTalk(radius)` = cylinder xz ≤ r, |dy| ≤ r; `Actor_OfferTalkNearColChkInfoCylinder` = collider radius + **50**)
- Each frame an actor that wants to be talked to calls an offer function.
- The offer **fails** in any of these cases:
  - the player is already talking;
  - an item exchange is offered during a cutscene;
  - the actor is **not locked-on** and any of these is true:
    - |height difference| > yRange,
    - xz distance > xzRange,
    - xz distance > the distance of the talk actor already offered this frame.
- Otherwise the actor becomes `player->talkActor` and queues the global talk cutscene.
- **Closest wins:** among several offers in a frame, the smallest **xz** distance wins. `talkActorDistance` resets to FLT_MAX each frame (P:12710-12717).
- **A locked-on actor skips all range checks.** You can talk to a locked NPC from anywhere within the leash. This is why Z-targeting lets you talk from further away.

### 5.2 Player-side acceptance (`Player_ActionHandler_Talk`, P:7979)
- Talk is refused if Link is locked onto a *different* actor than the one offering.
- Talk is refused if Link is airborne (except on horseback and a few other states).
- If accepted, `PLAYER_STATE2_CAN_ACCEPT_TALK_OFFER` is set. The HUD A button then shows **"Speak"** for NPC-category actors (and ENEMY-category, and `Dm_Char08`), and **"Check"** for anything else (P:11517-11523).
- The conversation starts on an A press, or automatically with `ACTOR_FLAG_TALK_OFFER_AUTO_ACCEPTED` (bit 16).
- **C-Up "Tatl":** if the locked actor has `ACTOR_FLAG_TALK_WITH_C_UP` (bit 18) or a `hintId`, C-Up talks to it. The text is `hintId + 0x1900` (P:7988-8075).
- **No player-facing check exists in Player or in `Actor_OfferTalkExchange`.** Any facing requirement is coded in the individual actor.

### 5.3 Why you must face a sign (`En_Kanban`, `src/overlays/actors/ovl_En_Kanban/z_en_kanban.c:182-196`)
- The sign offers talk only if `|yawTowardsPlayer − sign.shape.rot.y| < 0x2800` (**±56.25°**), meaning Link is **in front of the sign's face**.
- The radius is **68** (xz ≤ 68, |dy| ≤ 68).
- There is a **20-frame** cooldown after the textbox closes (`msgTimer = 20`).
- The sign uses range type 0 (Tatl hover within 70, keep a lock within about 99).
- **The "you must face it" feel comes from the attention cone, not the talk code.** Tatl or the arrow only highlights it when Link's own facing is within 60° of it (1.2).
- **Sample of other actors' facing gates:** across MM actor code, `Actor_IsFacingPlayer` thresholds are mostly 0x3000 (67.5°, 16 uses), 0x4000 (90°, 9 uses) and 0x2000 (45°, 6 uses). These are not all talk gates.
- **Common `Actor_OfferTalk` radii** in MM: 100 (46 uses), 120 (41), 70 (13), 80/110/150/200, and `ColChkInfoCylinder` (radius + 50, 42 uses).
- **Facing helpers** (A:1558-1615): `Actor_IsFacingPlayer(actor, maxAngle)` tests the actor's shape yaw against `yawTowardsPlayer`. `Actor_IsFacingAndNearPlayer(actor, range, angle)` also needs 3D distance < range.

### 5.4 Related offers, for comparison
- **Pick up / carry:** `Actor_OfferGetItem` (A:2239), nearby = xz ≤ **50**, |dy| ≤ **10**. Here *player* facing matters, but only for `GI_NONE` (carry) offers:
  - The code compares `|actor.yawTowardsPlayer − player.shape.rot.y|` against `getItemDirection`, which resets to **0x6000** each frame (P:12728).
  - It accepts the offer only if the value is **greater** than that.
  - When Link faces the actor this value is near 0x8000. So the rule means **Link must face within 0x2000 (45°) of the object**, and the best-faced object wins.
  - Real item gives (GI > 0) skip the facing test.
- **Ocarina:** `Actor_OfferOcarinaInteraction` (A:2155) uses xz range, closest xz, and default yRange 20.

---

## 6. Visuals and timing (`Attention_Draw` A:510, `Attention_Update` A:642, colours A:434)

### 6.1 Colours (`sAttentionColors`, primary = arrow, reticle and Tatl inner; secondary = Tatl outer)

| Category | Primary RGB | Tatl outer RGB |
|---|---|---|
| NPC | 150,150,255 (blue) | 150,150,255 |
| ENEMY, BOSS | 255,255,0 (yellow) | 200,155,0 |
| PLAYER (Tatl idle) | 255,255,230 | 220,160,80 (OoT Navi: white / blue 0,0,255) |
| everything else (signs = PROP, chests, switches, BG, doors, misc, explosives) | 0,255,0 (green) | 0,255,0 |

### 6.2 Arrow
- Drawn at `focus.pos.y + lockOnArrowOffset × scale.y + 17`.
- Spins about Y at **0xBB8 per frame** (≈ 16.5°/frame), using the primary colour.
- Scaled (0.035, 0.060, 0.050) by default.
- Not drawn for `LOCK_ON_DISABLED` actors.
- Shown on the hover candidate when unlocked, and on the next candidate when locked.

### 6.3 Reticle
- Four triangles rotated 90° apart, each offset by (radius, radius).
- **Fly-in:**
  - On a new lock, radius = **500** and the reticle starts at the camera eye, so it appears from the screen centre.
  - The projected position is scaled by `(500 − r)/420`, so it slides out to the actor as it shrinks.
  - Each frame, radius steps toward **80** by `clamp((500 − r) × 3, 30, 100)`: 500 → 470 → 380 → 280 → 180 → 80. It reaches 80 in **5 frames**.
  - It then snaps to **120** and starts spinning. That 80→120 snap gives a small "pop".
  - During fly-in **three trail copies** are drawn, alpha falling by 85 each, as motion blur.
  - Horizontal triangle scale = 0.15, or `0.15 + (r − 120) × 0.001` when r > 120. The triangles stretch while far out.
- **Spin:** `spinCounter = (spinCounter + 3) | 0x80`, rotation = counter × 0x200. That is **0x600 per frame ≈ 8.44°/frame**, one revolution in about 43 frames.
- **Release:**
  - The radius grows toward 500 at **80 per frame**.
  - The fade control starts at 256 and drops **120 per frame** (alpha 136 → 16 → 0, about 3 frames).
  - `NA_SE_SY_LOCK_OFF` plays if the spin had started.
- The reticle anchor is `world.pos.y − shape.yOffset × scale.y`, but the reticle is *drawn* at `focus.pos`.
- Reticle colour is set once when the lock starts, from the category.

### 6.4 When nothing is drawn
Nothing is drawn while Link is talking to the locked actor, is dead, time is stopped, or a few other states hold (A:514-518). `Attention_Update` itself is skipped while `PLAYER_STATE1_2` is set (meaning UNVERIFIED).

### 6.5 Sound effect names
- `NA_SE_SY_LOCK_ON` (hostile lock)
- `NA_SE_SY_LOCK_ON_HUMAN` (friendly lock)
- `NA_SE_SY_LOCK_OFF` (reticle release)
- Sidehop `NA_SE_PL_SKIP`, backflip `NA_SE_PL_ROLL` with voice `NA_SE_VO_LI_SWORD_N`
- C-Up with nothing to say: `NA_SE_SY_ERROR`
- The Tatl "Hey!" or "Listen" voice was not traced: UNVERIFIED.

---

## 7. Other things that affect feel

- **Facing:** `Player_UpdateShapeYaw` (P:4808).
  - While locked, once the reticle spin has started, Link's model yaw turns toward the target's `focus.pos` by `Math_ScaledStepToS` with a step of **0xFA0** (≈ 22°, scaled by update rate). The Owl-statue-viewer actor is excluded.
  - In Parallel it turns toward `parallelYaw` with the same step.
  - Normal turning uses step 0x7D0.
  - Movement direction is separate from facing (strafing).
- **Stick sectors:** below magnitude **8** of about 60 the stick counts as zero. At **≥ 55** the stick is classified into 4 sectors of 90° relative to Link's facing: forward / left / back / right, each ±45° (P:2022-2049).
- **Z-jumps:** `Player_ActionHandler_10` (P:8244) and `func_80839860` (P:8167).
  - While Z-targeting, A with the stick left or right = **sidehop**: launch speed 3.5 up, 8.5 horizontal.
  - A with the stick back = **backflip**: 5.8 up, 6.0 horizontal.
  - Speeds are halved with Giant's/heavy boots.
  - A with the stick forward or neutral = **jump attack** (with a sword) or a jump.
  - None of these work in `ROOM_TYPE_INDOORS` rooms, or on certain floor types.
  - The A-button HUD shows "Attack" or "Jump" accordingly (P:11570-11582).
- **Camera modes picked from Z state** (`Player_UpdateCamAndSeqModes`, P:11950):

  | State | Camera mode |
  |---|---|
  | Talking | TALK |
  | Friendly lock | FOLLOWTARGET |
  | Hostile lock | BATTLE |
  | Parallel or forced-release | TARGET |
  | Bow aiming | BOWARROWZ |
  | Climbing | CLIMBZ |
  | Hanging (Z) | HANGZ |
  | Deku flight | DEKUFLYZ |

  The view target is set to the focusActor. How BATTLE or FOLLOWTARGET frame the player and target pair (distances, pitch) is in `z_camera.c` and the camera settings data, and was **not researched**: UNVERIFIED.
- **Auto lock-on** (`Player_SetAutoLockOnActor`): used by scripted actors. It is cleared every frame unless the actor re-asserts it (P:12735). It is friendly even if the actor is hostile. With Switch mode it does not carry over into a normal lock.

---

## MM vs OoT differences found
- MM has range type **10** (2500 units). OoT has 0–9.
- MM adds `ACTOR_FLAG_CAMERA_DRIFT_ENABLED` (a separate nearest-actor search for gentle camera drift) and `ACTOR_FLAG_FOCUS_ACTOR_REFINDABLE`.
- MM blocks locks with the Giant's Mask and in Deku flight states.
- MM adds C-Up Tatl talk via `ACTOR_FLAG_TALK_WITH_C_UP` / `hintId`.
- Tatl's hover moves toward `focus.pos` in MM and `world.pos` in OoT. Her idle colour differs.
- In OoT the search is skipped entirely during cutscenes (`Player_InCsMode`). MM has no such guard in `Attention_FindActor`, but Player zeroes the timer in cutscenes.
- Everything else is the same in both: the cone (60°/90°), the 0.6–1.0 weighting, line-of-sight, screen leeway, category order, the 500-unit BGM radius, timers (15/5) and reticle animation.

## Open questions / UNVERIFIED
1. Exact meaning of `PLAYER_STATE3_200` / `PLAYER_STATE3_2000` and `PLAYER_STATE1_2` (they block locks or skip attention updates).
2. Whether locks can be acquired while climbing or swimming in practice. The Z code allows it, so it depends on which action functions run `Player_UpdateZTargeting` side effects.
3. The Hold-mode quick re-press with only one candidate (it should keep the old lock): inferred, not observed.
4. How the camera frames the target (`z_camera.c` BATTLE / FOLLOWTARGET / TARGET parameters): not researched.
5. The 20 Hz gameplay rate is assumed, not re-checked. Convert the frame counts here to seconds with it.
6. Tatl's "Hey/Listen" voice triggers (`tatlTextId`, hint system): not traced.
7. The range-type usage counts come from a grep and miss runtime assignments and raw numeric `ICHAIN` values.
