# Majora's Mask: how Link's sword attacks are chosen and chained (decomp reference)

Behaviour reference for a Godot re-implementation. No code or assets copied. Logic is paraphrased; the short snippets are kept only where the exact expression matters.

**Sources (read 2026-11-11):**
- zeldaret/mm `main` @ `3be2e24123f5e71fd13f939ecc0f9d7f73252639`
  - `src/overlays/actors/ovl_player_actor/z_player.c` (cited as **P:line**)
  - `include/z64player.h` (**H:line**)
  - `src/code/z_player_lib.c` (**PL:line**)
  - `src/overlays/actors/ovl_En_M_Thunder/z_en_m_thunder.c` (**T:line**)
  - `src/code/z_skelanime.c`, `z_actor.c`, `z_lib.c`, `z_collision_check.c`
- zeldaret/oot `main` @ `14759abf9abb4295de142cdc1452998630ea70fb`: `z_player.c` (**O:line**), `include/player.h`

Line numbers belong to those commits. Function names are the decomp's own; many are still `func_XXXXXXXX`.

**Units.**
- 1 frame = 1/20 s = 0.05 s. Gameplay runs at 20 Hz: `framerateDivisor` = 3.
- 1 MM unit = 4 cm, as you specified.
- Velocities are in units per "half update". `Actor_UpdatePos` multiplies velocity by `sActorMovementScale = framerateDivisor * 0.5 = 1.5` (z_actor.c:1204-1216). So a `speedXZ` of 10 moves the actor **15 u/frame = 0.6 m/frame = 12 m/s**.
- **Animation rate.** Attack animations play at `PLAYER_ANIM_ADJUSTED_SPEED = 2/3` (H:362). `PlayerAnimation_Once` advances by `playSpeed * framerateDivisor * 0.5` (z_skelanime.c:1372-1379), so attacks advance **exactly 1 animation frame per game frame**. Every attack-animation frame number below is therefore a game frame (0.05 s).
- "Normal speed" animations (1.0) advance 1.5 animation frames per game frame. The spin-charge start animation is one of these.

**Animation lengths are UNVERIFIED.** They live in ROM asset data (`gameplay_keep`), not in the decomp source. `animLength` matters for the combo window, so measure it from the extracted assets, or just choose your own.

---

## 0. Data structures (who holds what)

| Field (Player) | Meaning | Source |
|---|---|---|
| `meleeWeaponAnimation` (s8) | Current attack type, a `PlayerMeleeWeaponAnimation` (`PLAYER_MWA_*`). | H:303-340, H:1264 |
| `meleeWeaponState` (s8) | 0 = off. -1 = trail/tracking only, no hitbox. 1 = hitbox active. | H:342-346 |
| `unk_ADD` (s8) | Combo counter: consecutive presses of the same type. | H:1267 |
| `unk_ADC` (s8) | Combo / spin-charge timer. Positive while B is held, negative after B is released. | H:1266 |
| `controlStickDirections[4]` | Ring buffer of stick direction relative to Link's facing, last 4 frames. | H:1270 |
| `controlStickSpinAngles[4]` | Ring buffer of the raw stick angle quantised to 128 sectors, used for stick-roll detection. | H:1269 |
| `controlStickDataIndex` | Ring index, 0..3, newest sample. | H:1268 |
| `unk_B08` (f32) | Spin charge level, 0..1. | P:5467-5471, P:10818 |
| `meleeWeaponQuads[2]`, `meleeWeaponInfo[3]` | Hit quads, and base/tip of the blade (trail + 2 quads). | H:1215, H:1341 |

`AttackAnimInfo` (P:446-452) has 5 fields:
1. `unk_0`: the swing animation.
2. `unk_4`: the recovery animation when not hostile-locked.
3. `unk_8`: the recovery animation when hostile-locked (the "anchor" animations).
4. `unk_C`: first active-hitbox frame.
5. `unk_D`: last active-hitbox frame.

---

## 1. Choosing an attack from input

### 1.1 Stick sampling: `Player_ProcessControlStick` (P:2026-2049, runs every frame)

1. Magnitude comes from `Lib_GetControlStickData`. It is clamped to **0..60** (z_lib.c:251-266), and values below 8 are zeroed.
2. **Direction threshold: magnitude < 55** (about 92% of full tilt) → `PLAYER_STICK_DIR_NONE` (-1), and the spin angle is -1.
3. Otherwise the stick angle is converted to world yaw with the camera: `worldYaw = cameraInputYaw + stickAngle`. The direction is a **90° quadrant relative to Link's facing (`shape.rot.y`)**:
   ```
   dir = (u16)((worldYaw - shape.rot.y) + 0x2000) >> 14   // 0 FORWARD, 1 LEFT, 2 BACKWARD, 3 RIGHT
   ```
   - Sectors are ±45° around each axis (H:596-600).
   - Binangs (binary angles) run 0x10000 per turn. +0x4000 points to Link's left, because Z64 yaw 0 is +Z and 0x4000 is +X.
4. Spin angle = `(u16)(stickAngle + 0x2000) >> 9`, a value 0..127 (128 sectors of 2.8°). It uses the **raw stick angle**, not camera-relative.
5. The buffer only stores one sample per frame. Attack selection reads **only the newest sample**: `controlStickDirections[controlStickDataIndex]`.

### 1.2 Which code path fires on a B press

**B press detection.**
- `func_8082FDC4` (P:3783) tests `press.button`, i.e. the frame the button goes down. When the pressed button holds the currently held sword, `Player_UseItem` sets `sPlayerUseHeldItem = true` (P:4622-4624).
- `sPlayerUseHeldItem` is cleared at the start of every frame (P:12689).
- It is only set while an action calls `Player_UpdateUpperBody`, which `Player_TryActionHandlerList(..., updateUpperBody=true)` does (P:5383-5391).

**Ground attack: `Player_ActionHandler_7` (P:13713-13727).**
- It is in nearly every ground handler list: idle, walk, run, target-walk and so on (P:5213-5330).
- If `func_808396B8` passes, it calls `func_808335F4` to choose the type, then `func_80833864` to start the attack. `func_808396B8` (P:8132-8143) requires all of:
  - not shielding (`!PLAYER_STATE1_400000`);
  - a melee weapon held;
  - Goron must be on the ground;
  - Zora must not have its fins thrown;
  - `sPlayerUseHeldItem`.
- If the result is a quick spin, or the player is Fierce Deity and Z-targeting, it also spawns the spin/beam actor (see §4 and §1.4).

**Airborne B: jump slash.**
- In the jump/fall action, `func_80839770` (P:8145-8156, called at P:15217-15220) starts a jump slash if B is pressed while airborne:
  - human: `PLAYER_MWA_JUMPSLASH_START`, speedXZ 3.0, vy 4.5;
  - Zora: `ZORA_JUMPKICK_START`.
- Not allowed for Goron, or during a backflip or the other `STATE2_80000` hops with `actionVar1 == 2` or `>= 4`.

**Z-target + A: jump slash.**
- `Player_ActionHandler_10` (P:8242-8276) handles A pressed while Z-targeting with the stick neutral or forward, holding a sword, not Goron, not swimming.
- It calls `func_808395F0(JUMPSLASH_START, speed 5.0, vy 5.0)`.
- With the stick left, right or back it does side-hops or a backflip instead (`func_80839860`).

**Shield + B: crouch stab.**
- In `Player_Action_18` (shielding, P:14890ff), B calls `func_8083FD80` (P:10411-10424).
- It plays `link_normal_defense_kiru` and uses STAB_1H damage.
- The hitbox is active only on animation frames 0-1 (`curFrame < 2`, P:14953-14957).
- It sets `unk_ADD = 0`, so a crouch stab never builds a combo.
- Human and Fierce Deity only.

### 1.3 The selector: `func_808335F4` (P:5572-5615) and table `D_8085D090` (P:5560-5565)

Human and Fierce Deity, in priority order:

1. If `Player_CanSpinAttack` (stick roll, §4.1) is true → `SPIN_ATTACK_1H`. This is the **quick spin** and overrides direction.
2. Else, if the stick direction is NONE:
   - `Player_IsZTargeting` → `FORWARD_SLASH_1H` (vertical);
   - otherwise → `RIGHT_SLASH_1H` (horizontal).
3. Else use the per-direction table:

   | Stick dir (relative to Link) | Result |
   |---|---|
   | FORWARD | `STAB_1H`. Also sets the lunge flag `PLAYER_STATE2_40000000`. **If not Z-targeting, the result becomes `FORWARD_SLASH_1H` but the lunge flag stays set.** |
   | LEFT | `RIGHT_SLASH_1H` (animation `fighter_Lside_kiru`) |
   | BACKWARD | `RIGHT_SLASH_1H` |
   | RIGHT | `LEFT_SLASH_1H` (animation `fighter_Rside_kiru`) |

   The decomp itself flags the LEFT/RIGHT naming as unverified: `// TODO: verify MWA as left/right does not match stick dir`.
4. If holding a Deku Stick, the result is always `FORWARD_SLASH_1H`. Spin is impossible because `Player_CanSpinAttack` returns false for the stick.
5. If `Player_IsHoldingTwoHandedWeapon` → result + 1 (the `_2H` variant). Two-handed means item actions SWORD_TWO_HANDED (Great Fairy's Sword and Fierce Deity's sword) through DEKU_STICK (PL:1661-1667). **The Deku Stick counts as two-handed.**

`Player_IsZTargeting` (P:3727-3729) is true for a hostile lock-on, a friendly lock-on, **or parallel mode** (Z held with no target).

**Practical reading of the mapping:**
- **Free movement, running.** Link faces the stick direction, so the stick reads FORWARD → **vertical slash plus a 15-speed lunge**.
- **Free movement, standing.** Stick neutral → **horizontal slash**.
- **Z-targeted or parallel.**
  - neutral → vertical slash;
  - forward (toward the target) → **stab plus lunge**;
  - left → horizontal `RIGHT_SLASH`;
  - right → `LEFT_SLASH`;
  - back → horizontal `RIGHT_SLASH`.
- **Stick roll then B** → quick spin.
- **In air** → jump slash. **Z + A** → jump slash. **R + B** → crouch stab.

**Unused in MM:**
- `FLIPSLASH_*`, `BACKSLASH_LEFT/RIGHT` are marked "unused" (H:321-328). Nothing selects them.
- OoT has the same unused entries.

### 1.4 Other forms

**Zora and Goron** (P:5576-5588, table `D_8085D094` P:5567-5570):
- The stick is ignored. The attack is `table[unk_ADD]`:
  - Zora: `ZORA_PUNCH_LEFT` → `ZORA_PUNCH_COMBO` → `ZORA_PUNCH_KICK`;
  - Goron: `GORON_PUNCH_LEFT` → `GORON_PUNCH_RIGHT` → `GORON_PUNCH_BUTT`.
- See §2.4 for how they chain.

**Fierce Deity:**
- Uses the human selector with `_2H` animations.
- **While Z-targeting, every B swing also fires a sword beam.** `Player_ActionHandler_7` calls `func_808332A0(..., isSwordBeam = true)` (P:13719-13723). It needs magic > 0 and uses `MAGIC_CONSUME_DEITY_BEAM` (P:5474-5496).
  - The beam (T:250-262, T:400-438) is `DMG_SWORD_BEAM`, damage 3.
  - It travels 80 u/frame, pitched toward the target.
  - Its collision is a cylinder of radius scale×5, with scale growing toward 12.

**Deku:** B is the Deku spin, not this system (out of scope).

### 1.5 OoT cross-check

- OoT `func_80837818` (O:4453-4497) is the same selector, with the same `D_80854480` table, the same 55 threshold (O:2216) and the same Deku-stick and two-handed rules.
- OoT adds a hammer table (`D_80854484`, O:4447-4452):
  - forward or back → `HAMMER_FORWARD`;
  - sides → `HAMMER_SIDE`;
  - neutral → forward.
- The hammer never combos (`unk_845 = 0`).

---

## 2. Combos

### 2.1 The counter rule: `func_80833864` (P:5666-5693)

Every attack start runs:

```
if (newType != meleeWeaponAnimation || unk_ADD >= 3) unk_ADD = 0;
unk_ADD++;
if (unk_ADD >= 3) newType += 2;          // the "_COMBO" (third-hit / finisher) variant
meleeWeaponAnimation = newType;
play swing anim sMeleeAttackAnimInfo[newType].unk_0;
unk_ADC = animLength + 4;               // combo window / charge timer
yaw = shape.rot.y;                      // committed direction = current facing
```

Consequences:
- **The third consecutive press that resolves to the same base type becomes the finisher.** `+2` maps FORWARD_SLASH to FORWARD_COMBO, RIGHT to RIGHT_COMBO, LEFT to LEFT_COMBO and STAB to STAB_COMBO; the 1H/2H parity is kept.
- **The follow-up is re-selected from the stick on every press. It is not locked to the opener's family.** If a press resolves to a different type, the counter restarts at 1. Example: vertical, vertical, horizontal is three plain swings; vertical, vertical, vertical gives a vertical finisher on the third.
- There is no alternating left/right logic for human Link.
- **Maximum combo length is 3.** After a finisher, `unk_ADD >= 3`, so the next press resets the count to 1 and the cycle restarts.
- The comparison uses the stored `meleeWeaponAnimation`. After a finisher it holds the `_COMBO` id, which never equals a freshly selected base type, so it resets anyway.
- **Consequence derived from the code, not tested in game:** a quick spin also goes through this rule. Three consecutive quick spins within the window would give `SPIN_ATTACK_1H + 2 = BIG_SPIN_1H`.
- The jump slash landing calls `func_80833864(JUMPSLASH_FINISH)` and then **forces `unk_ADD = 3`** (P:15416-15420). So:
  - the landing counts as a finisher (longer blade, §3.4);
  - the next press starts a fresh chain.

### 2.2 The window: `unk_ADC` timing

**Timer bookkeeping**, in `Player_UpdateCommon` (P:12528-12534), every frame **before** the action function runs:
- if `unk_ADC == 0` → `unk_ADD = 0` (the combo is broken);
- else if negative → `unk_ADC++`;
- else → `unk_ADC--`.

**Release handling.** `func_8083A548` (P:8461-8465) negates the timer when B is not held: if `unk_ADC > 0` and B is up, `unk_ADC = -unk_ADC`.
- It is called every frame of the swing action (P:18364) and from `Player_ActionHandler_8`.
- Releasing B does not shorten the window. The sign only records "B was released", which cancels the hold-to-charge.

**When a second press is actually accepted (human and Fierce Deity):**
- The swing runs as `Player_Action_84` (P:18333-18424). That action **does not run the upper-body/item update**, so for human Link a B press during the swing animation is **not buffered**; it is simply dropped.
  - At the end of the swing it calls `Player_ActionHandler_7` with `sPlayerUseHeldItem = av2.actionVar2`.
  - `av2` is only latched for Zora and Goron (P:18405-18410). For humans it is 0, so no chained attack starts there.
- Instead the swing hands off to `Player_Action_Idle` playing the recovery animation: `unk_8` when hostile-locked, else `unk_4` (P:18376-18401).
- Idle runs `sActionHandlerListIdle` every frame (P:5280-5292, P:14389), which includes handler 8 (charge) and then handler 7 (attack). **The recovery animation is therefore cancellable on any frame by a new B press.**

**Timeline**, with L = `animLength` of the swing and press frame = 0:
- Frame 0: swing starts, `unk_ADC = L+4`.
- `PlayerAnimation_Once` returns "done" one frame after reaching `endFrame = L-1`, so **frame L** switches to recovery, with `unk_ADC = 4`.
- **Combo-accepting press frames: L+1 … L+4.** That is **4 frames = 0.20 s** right after the swing animation ends.
  - At L+4 the timer goes 1→0 before the handlers run, but `unk_ADD` is only cleared on the next frame (L+5).
- Pressing later still attacks, but the counter restarts at 1.
- **Derived from the frame-order reasoning above; not measured in game.**

**OoT difference:**
- OoT sets `unk_844 = 8` (fixed 8 frames from the swing start) instead of `animLength + 4` (O:4521).
- Otherwise the counter logic is identical (O:4526-4535, O:11786-11792).

### 2.3 Hold B after a swing → spin charge: `Player_ActionHandler_8` (P:8467-8485)

- Condition: B is still held, not shielding, a weapon is held, and `unk_ADC == 1` (it is positive only if B was never released), and the weapon is not a Deku Stick.
- When it holds, `func_808335B0` enters spin charge (`Player_Action_30`).
- So **holding B continuously from the press until frame L+3 (0.15 s into recovery) starts the charge**. There is no separate hold timer.
- Zora instead throws the fin boomerang (`func_80830E30`).

### 2.4 Zora and Goron chains

- The selector indexes the 3-hit table by `unk_ADD`.
  - When `unk_ADD != 0` it pre-writes `meleeWeaponAnimation`, so the "same type" test passes and the count survives.
  - At the third hit it sets `unk_ADD = -1`, so the counter wraps to 0 → 1 (P:5576-5588).
- Unlike human Link, **B presses during the punch are buffered**: `av2 |= press B` every frame of the swing, except during `ZORA_PUNCH_KICK`, `ZORA_JUMPKICK_FINISH` and `GORON_PUNCH_BUTT` (P:18405-18410).
- At animation end the buffered press fires `Player_ActionHandler_7` immediately (P:18373).
- The stick does not matter. The sequence is always hit 1, hit 2, hit 3, then back to hit 1.

---

## 3. Per-attack data

### 3.1 `sMeleeAttackAnimInfo` (P:3489-3584): hitbox frames per type

"Active" means `meleeWeaponState = 1`. `func_8083FCF0(startFrame, unk_C, unk_D)` (P:10397-10409) is called each frame from `Player_Action_84` with `startFrame = 0` (Goron: 5):
- `curFrame > unk_D` → weapon off;
- `startFrame ≤ curFrame < unk_C` → state -1 (trail only);
- `unk_C ≤ curFrame ≤ unk_D` → state 1 (quads live).

| Type (id) | Swing animation (link_*) | Active frames | Notes |
|---|---|---|---|
| FORWARD_SLASH_1H (0) | fighter_normal_kiru | 1-4 | vertical |
| FORWARD_SLASH_2H (1) | fighter_Lnormal_kiru | 1-4 | |
| FORWARD_COMBO_1H (2) | fighter_normal_kiru_finsh | 0-5 | 3rd hit |
| FORWARD_COMBO_2H (3) | fighter_Lnormal_kiru_finsh | 1-7 | |
| RIGHT_SLASH_1H (4) | fighter_Lside_kiru | 1-4 | horizontal |
| RIGHT_SLASH_2H (5) | fighter_LLside_kiru | 0-5 | |
| RIGHT_COMBO_1H (6) | fighter_Lside_kiru_finsh | 2-8 | |
| RIGHT_COMBO_2H (7) | fighter_LLside_kiru_finsh | 3-8 | |
| LEFT_SLASH_1H (8) | fighter_Rside_kiru | 0-4 | |
| LEFT_SLASH_2H (9) | fighter_LRside_kiru | 0-5 | |
| LEFT_COMBO_1H (10) | fighter_Rside_kiru_finsh | 0-6 | |
| LEFT_COMBO_2H (11) | fighter_LRside_kiru_finsh | 1-5 | |
| STAB_1H (12) | fighter_pierce_kiru | 0-3 | |
| STAB_2H (13) | fighter_Lpierce_kiru | 0-3 | |
| STAB_COMBO_1H (14) | fighter_pierce_kiru_finsh | 1-9 | |
| STAB_COMBO_2H (15) | fighter_Lpierce_kiru_finsh | 1-8 | |
| FLIPSLASH_START (16) | fighter_jump_rollkiru | 7-99 | unused |
| JUMPSLASH_START (17) | fighter_Lpower_jump_kiru | 7-99 | in air (see §5) |
| ZORA_JUMPKICK_START (18) | pz_jumpAT | 8-99 | |
| FLIPSLASH_FINISH (19) | fighter_jump_kiru_finsh | 1-2 | unused |
| JUMPSLASH_FINISH (20) | fighter_Lpower_jump_kiru_hit | 1-2 | landing |
| ZORA_JUMPKICK_FINISH (21) | pz_jumpATend | 1-2 | |
| BACKSLASH_RIGHT (22) | fighter_turn_kiruR | 1-5 | unused |
| BACKSLASH_LEFT (23) | fighter_turn_kiruL | 1-4 | unused |
| GORON_PUNCH_LEFT (24) | pg_punchA | 6-8 | |
| GORON_PUNCH_RIGHT (25) | pg_punchB | 12-18 | |
| GORON_PUNCH_BUTT (26) | pg_punchC | 8-14 | |
| ZORA_PUNCH_LEFT (27) | pz_attackA | 2-5 | |
| ZORA_PUNCH_COMBO (28) | pz_attackB | 3-8 | |
| ZORA_PUNCH_KICK (29) | pz_attackC | 3-10 | |
| SPIN_ATTACK_1H (30) | fighter_rolling_kiru | 0-12 | |
| SPIN_ATTACK_2H (31) | fighter_Lrolling_kiru | 0-15 | |
| BIG_SPIN_1H (32) | fighter_Wrolling_kiru | 0-16 | |
| BIG_SPIN_2H (33) | fighter_Wrolling_kiru | 0-16 | |

**Recovery animations.** Each `unk_4` is the matching `*_end` animation. Each `unk_8` is the matching `link_anchor_*_endR/L` animation, used when hostile-locked.

**Swing-sound frame.** The "swing" SFX and voice play when the state goes from 0 to non-zero (`func_8082FA5C`, P:3650-3688). The finisher (`unk_ADD >= 3`) uses the harder swing SFX and the louder voice `NA_SE_VO_LI_SWORD_L`.

**Jump attacks use a later start frame.** `Player_Action_29` calls `func_8083FCF0(6, unk_C, unk_D)` (P:15412). The jump slash therefore shows a trail from frame 6 and has a live hitbox from frame 7 until landing (99 = "until the animation changes").

**First active frame does no damage (code-derived).** The first frame in state 1 only primes the quads (`func_80126440`, PL:2694-2731: when `!active`, it stores the blade, resets the collider and does no AT). So damage sweeps happen on frames `unk_C+1 … unk_D`.

**OoT cross-check.** OoT's `D_80854190` (O:1571ff) has the same values for the human slashes.

### 3.2 Damage: `D_8085D09C` (P:5628-5636) applied by `func_8083375C` (P:5639-5664)

Columns: `{dmgFlags, transformedNormal, transformedStrong, humanNormal, humanStrong}`.

| Weapon | dmgFlags | Human normal | Human strong | Transformed (FD) normal / strong |
|---|---|---|---|---|
| none (Goron punch) | DMG_GORON_PUNCH | 0 | 0 | 2 / 2 |
| Kokiri Sword | DMG_SWORD | **1** | **2** | 4 / 8 |
| Razor Sword | DMG_SWORD | **2** | **4** | 4 / 8 |
| Gilded Sword | DMG_SWORD | **3** | **6** | 4 / 8 |
| Two-handed (GFS / FD sword) | DMG_SWORD | **4** | **8** | 4 / 8 (FD = 4 normal, 8 jump) |
| Deku Stick | DMG_DEKU_STICK | 2 | 4 | 0 / 0 |
| Zora fins | DMG_ZORA_PUNCH | 0 | 0 | 1 / 2 |

- **"Strong" applies only to types FLIPSLASH_START … ZORA_JUMPKICK_FINISH**, i.e. jump slashes and jump kicks, both the air part and the landing.
- **All ground slashes, stabs, finishers and sword-quad spins use "normal"** in MM. A finisher has **no damage bonus**, only more reach (§3.4).
- Goron uses row 0 regardless of the held item.
- The decomp notes that the "transformed" columns presumably target Fierce Deity.
- **How enemies scale it** (MM `CollisionCheck_GetDamageAndEffectOnElementAC`, z_collision_check.c:53-79): final damage = attack damage × multiplier. The multiplier comes from the enemy's damage table entry for that dmgFlag bit and is one of {0, 1, 2, 0.5, 0.25, 3, 4, 1…}; the high nibble is the effect.
- **OoT difference.** OoT sets only dmgFlags per sword, as `{SLASH, JUMP}` pairs such as DMG_SLASH_KOKIRI and DMG_JUMP_MASTER (O:4499-4502). Damage comes entirely from enemy tables.

**Side effects on hit** (`func_808401F4`, P:10518-10645):

| Event | Result |
|---|---|
| Any hit on an actor (except signposts `EN_KANBAN`) | 1-frame freeze (`freezeFlashTimer = 1`, P:656-660). |
| Each hit with the Razor Sword | Decrements its durability (P:10458-10475). |
| Deku Stick hit with stick length > 0.5 | Breaks it. |
| Hitbox bounced (`AT_BOUNCED`) | Rebound animation, `speedXZ = -18` (P:10489-10516). |
| Blade tip hits a wall (from frame ≥ 2) | Sparks and `speedXZ = -14`. |

**Wall check detail.** The tip is tested with a line test from the tip to a point 10 u (0.4 m) beyond it along the blade.

### 3.3 Hitbox shape: two swept quads along the blade (PL:2750-2760, PL:2870-2920, PL:2980-2999, PL:3754-3776)

**Base length.** The base length is written into `D_801C0994[0].x` every frame from `sMeleeWeaponLengths` (PL:3755-3763). These are **left-hand limb model units, where 100 = 1 world unit**: Link's actor scale is 0.01, consistent with `Actor_SetScale(0.01f)` at P:4388.

| Weapon | Length (model) | Length (world) | Metres |
|---|---|---|---|
| Kokiri / Razor | 3000 | 30 u | 1.20 m |
| Gilded | 4000 | 40 u | 1.60 m |
| Two-handed (GFS / FD) | 5500 | 55 u | 2.20 m |
| Zora | 2500 | 25 u | 1.00 m |
| Deku Stick | `unk_B0C × 5000` (remaining stick fraction) | ≤ 50 u | ≤ 2.0 m |

**Hit length.** The hit length is `length (× finisher multiplier) + 1200`, i.e. **12 u (0.48 m) longer than the base length**.

**Points**, in hand space (x along the blade; tables `D_801C0970` = base, `D_801C0994` = tip):

| Element | Base point | Tip point |
|---|---|---|
| Trail (`meleeWeaponInfo[0]`) | (0, 400, 0) | (len, 400, 0) |
| Quad 0 | (0, 1400, -1000) | (hitLen, -400, 1000) |
| Quad 1 | (0, -400, 1000) | (hitLen, 1400, -1000) |

- The two hit segments are **diagonal and crossed (an X)**. Each runs from about ±14/±10 u off-axis at the hilt to the opposite side at the tip, which gives the blade a fat cross-section of roughly 0.5 m.
- **Each quad is swept.** `Collider_SetQuadVertices(newBase, newTip, prevBase, prevTip)` (PL:2718) covers the area the segment moved through since the previous frame. This prevents tunnelling on fast swings.
- The quads only exist while `meleeWeaponState >= 1`, and only for non-spin types. During a spin they are kept only while `PLAYER_STATE2_20000` is set (PL:2904-2913); see §4.3.
- Goron uses a fist table instead (`D_801C09B8`).

**OoT.** It is analogous (`Player_UpdateWeaponInfo` / `func_80090A28` in z_player_lib). Its lengths were not checked here (UNVERIFIED).

### 3.4 Finisher reach bonus (PL:2980-2992)

While `unk_ADD >= 3`:
- the draw code does `unk_ADD++` every frame;
- it sets `hitLen = len × (1 + (9 − unk_ADD) × 0.1) + 1200`.

Starting at `unk_ADD` = 4 on the first drawn frame, the multiplier runs:

| Finisher frame | 1 | 2 | 3 | 4 | 5 | 6 |
|---|---|---|---|---|---|---|
| Multiplier | ×1.5 | ×1.4 | ×1.3 | ×1.2 | ×1.1 | ×1.0 |

After that it shrinks further (×0.9 …) until the swing's hitbox window ends.

**Kokiri example:** 30 u → 57 u (2.28 m) at the start of the finisher.

This also applies to the jump slash landing (`unk_ADD` is forced to 3).

---

## 4. Spin attack

### 4.1 Stick-roll detection: `Player_CanSpinAttack` (P:5499-5536; OoT identical at O:4390-4420)

Steps:
1. Fails if holding a Deku Stick.
2. Fails if any of the 4 buffered spin angles is -1, i.e. the magnitude was under 55 on any of the last 4 frames.
3. Each angle (0..127) is doubled into an s8, so one unit = 1/256 turn and differences wrap around the circle.
4. Pairs (0,1), (1,2), (2,3) **in array order** must each satisfy:
   - |difference| ≥ 10 units = **≥ 14.06° per frame (≥ 281°/s)**;
   - all differences have the **same sign**, so the rotation is consistent.

**Quirk, derived from the code:**
- The check walks the ring buffer in storage order, not time order. It is only purely chronological when `controlStickDataIndex == 3` (one frame in 4).
- On other frames one pair compares samples 3 frames apart in the opposite direction. That pair passes only if the s8 wrap flips its sign, which needs roughly 60° per frame or more.
- In practice a moderate-speed roll is recognised on about 1 frame in 4. **Recommendation:** implement it chronologically, i.e. 3 consecutive per-frame deltas of ≥ 14° with the same sign over 4 full-tilt samples.

**Where the roll is used:**
- at the B press → quick spin (§1.3);
- at charge release → upgrades to the big spin (§4.2);
- during a jump-slash landing after frame 2 → cancels into a spin (P:18369-18372).

### 4.2 Charge (hold B): `func_808334D4` / `Player_Action_30/31/32` (P:5539-5558, P:15426-15580, P:10770-10819)

1. **Entry.** B is held so that `unk_ADC` counts down to 1 (§2.3).
   - The charge-start animation `power_kiru_start` (`startL` after a horizontal slash) plays at normal speed from frame 8 with a 9-frame morph.
   - `func_808332A0(magicCost = 2)` sets `unk_B08 = 0`, sets `PLAYER_STATE1_CHARGING_SPIN_ATTACK`, and spawns `EN_M_THUNDER` with params `type | (2 << 8)`. The type is the sword index: 0 Kokiri, 1 Razor, 2 Gilded, 3 GFS/FD.
2. **Start phase.** While the start animation plays, `actionVar2 == 0` and **no charge accumulates**. Release here is handled by the generic handlers (UNVERIFIED exact behaviour).
3. **Charge loop.** When the start animation ends, `actionVar2 = -1` and the loop animation plays. The player goes into parallel/strafe (`Player_SetParallel`).
   - Each frame: `unk_B08 += 0.02` toward **0.5, or 1.0 if the Great Spin Attack has been learned** (`WEEKEVENTREG_RECEIVED_GREAT_SPIN_ATTACK`), P:10817-10819.
   - Once `unk_B08 ≥ 0.1` (**5 frames, 0.25 s**): `unk_ADD = 0` and `actionVar2 = 1`, which arms the release.
   - If B is released before 0.1, the charge is cancelled: `power_kiru_wait_end` plays and there is no spin (P:15445-15450).
4. **Moving while charging** (`Player_Action_31` forward/back, `Player_Action_32` sideways):
   - speed eases toward `stickSpeed × 0.2` (accelerate 1.0, decelerate 0.5 per frame);
   - the yaw turns 10% of the difference per frame;
   - stick reversals over 90° brake first at 1.0 per frame.
5. **Release** (`func_80840CD4`, P:10770-10791):
   - Choice of spin:
     - `unk_B08 ≥ 0.85` (Great Spin only: (0.85 − 0)/0.02 = **43 frames ≈ 2.15 s** of loop charge) **or** a stick roll on the release frame → `BIG_SPIN_1H/2H`;
     - otherwise → `SPIN_ATTACK_1H/2H`.
   - On release it also:
     - sets the invincibility timer to -8 (`func_808339B4`; intangibility for 8 frames assumed, UNVERIFIED semantics);
     - sets `PLAYER_STATE2_20000`;
     - sets the lunge flag if the stick is FORWARD.
   - Code reading suggests a stick roll at release gives the big spin **animation** even without the upgrade. The thunder actor's size still follows `unk_B08`, which caps at 0.5 without the upgrade, so the result is a regular-size cylinder (§4.3). Not tested in game.

### 4.3 The spin's hitbox: `EN_M_THUNDER` (T:117-347, T:369-398)

The player's sword quads plus a separate **cylinder** actor centred on Link's waist.

| Item | Value |
|---|---|
| Cylinder | height 40 u (1.6 m), yShift -20 (centred on waist), dmgFlags `0x01000000` = DMG_SPIN_ATTACK (T:43-60) |
| Damage `sDamages` | Kokiri 1, Razor 2, Gilded 3, GFS/FD 4. Regular and Great spins deal the **same damage** (T:62-65). |
| Radius | `scale × 30`. Scale starts at 0.1 and smooth-steps toward `scaleTarget` (fraction 0.6, at most 0.8 per frame), so it reaches full size in about 3-4 frames (T:369-376). |
| Regular spin radius | Kokiri/Razor target 2 → **60 u (2.4 m)**; Gilded 3 → **90 u (3.6 m)**; GFS/FD 4 → **120 u (4.8 m)** |
| Great spin radius (`unk_B08 ≥ 0.85`) | Kokiri/Razor 3 → **90 u (3.6 m)**; Gilded 4 → **120 u (4.8 m)**; GFS/FD 6 → **180 u (7.2 m)** |
| Duration | Active until `lightColorFrac` steps 1 → 0 by 0.0625 per frame: **16 frames (0.8 s)**. Follows Link's waist XZ for the first 8 frames, then stays put. |

**Magic:**
- **Charged spin** (cost 2): at `unk_B08 ≥ 0.1`, magic is reserved (`MAGIC_CONSUME_WAIT_PREVIEW`) and consumed on release. With no magic, or magic busy, the thunder actor becomes the "no magic" variant: no cylinder, and only the sword quads deal damage.
- **Quick spin** (cost 0) needs magic to have been acquired and an idle magic state, otherwise there is no cylinder (T:131-142).
- Releasing with `unk_B08 ≤ 0.15` (charge frames 5-7) kills the cylinder: the player spins with sword quads only (T:270-280).

**Who deals the damage.**
- When the cylinder spawns, the thunder actor clears `PLAYER_STATE2_20000`, so the **sword quads stop**: spin damage comes from the cylinder.
- When the cylinder does not spawn, the flag stays set and the **sword quads remain active** through the spin animation (hit frames 0-12 / 0-15 / 0-16, §3.1) at normal sword damage.

**OoT differences:**
- The charge always ramps to 1.0 (O:9873). There is no learn gate.
- The same 0.1 / 0.85 thresholds apply (O:9829, O:9894-9898).

---

## 5. Movement during attacks and Z-targeting

### 5.1 Ground attacks: `Player_Action_84` (P:18333-18365)

- **Facing is committed at the start of the swing:** `yaw = shape.rot.y` (P:5692). Nothing in the swing action turns Link toward a target.
- Under a hostile lock-on, Link's facing is already kept toward the target by the lock-on idle and walk actions (`func_8083B23C`, P:14395). That is why stick FORWARD means "toward the target" (UNVERIFIED in detail).
- **Lunge.** If the lunge flag (`PLAYER_STATE2_40000000`) is set, `speedXZ = 15` on animation frame 0.
  - The flag is set for stick FORWARD at the press (stab, or forward slash when not targeting), and for a charged-spin release with the stick forward.
  - Every frame, `speedXZ` steps toward 0 by **5**, carried-in run speed included.
  - Movement per frame is therefore 10, then 5, then 0 (× 1.5) = **15 + 7.5 = 22.5 u ≈ 0.9 m over 2 frames**, on top of any root motion baked into the swing animation.
  - The animations use the `ANIM_FLAG_ENABLE_MOVEMENT` root-motion flags (P:5689-5691), and their translation lives in asset data: **UNVERIFIED**.
  - Dust kicks up if `speedXZ > 12`.
  - The decomp documents a "lunge storage" bug: the flag persists if this block is skipped.
- **Recoil.** A wall hit sets `speedXZ = -14`; a bounce sets -18 (§3.2). A negative speed also stops weapon-state updates for that frame (`if speedXZ >= 0`).

### 5.2 Jump attacks: `func_808395F0` and `Player_Action_29` (P:8113-8130, P:15396-15424)

| Variant | Horizontal speed | Vertical velocity |
|---|---|---|
| Z + A jump slash | 5.0 → 7.5 u/frame (0.3 m/frame, 6 m/s) | 5.0 |
| Airborne B | 3.0 | 4.5 |
| Zora jump kick | ×1.1 | ×0.9 |

- Gravity during the jump attack is **-1.2 per frame** (Zora -0.8).
- **Rough flat-ground airtime, Z + A:** about 2 × 5 / 1.2 ≈ 8 frames (0.4 s), covering about 60 u (2.4 m). Derived, UNVERIFIED.
- **Air steering.** The jump slash steers toward the stick speed (`func_8083CBC4`, rates 1.0 / 0.05 / 0.1, yaw step 200), but the facing stays fixed.
- **Landing.** It switches to `type + 3` (START → FINISH) through `func_80833864`, then forces `unk_ADD = 3`:
  - finisher reach (§3.4);
  - strong damage (×2);
  - hitbox on finish frames 1-2;
  - after frame 2 the finish can be cancelled into a spin by a stick roll.

### 5.3 Z-targeting summary

- It selects the attack table rows (§1.3):
  - neutral → vertical;
  - forward → stab.
- It chooses the recovery animation: `unk_8` "anchor" animations if hostile-locked, else `unk_4` (P:18376-18378). This uses `Player_CheckHostileLockOn` (hostile only), not `Player_IsZTargeting`.
- It enables Z + A jump slash (§1.2), and the Fierce Deity beam (§1.4).

**Shield blocks attacks:**
- `func_808396B8` fails while `PLAYER_STATE1_400000` (shielding) is set.
- Handler 11 only raises the shield when there is no lock-on or parallel mode (P:8396-8410). Under Z-targeting, R is handled by the separate targeted-shield path (not traced).

---

## 6. Constants cheat-sheet (20 Hz, 1 u = 4 cm)

| Constant | Value | Seconds / metres | Source |
|---|---|---|---|
| Stick direction threshold | magnitude ≥ 55 of 60 | — | P:2040 |
| Direction sectors | 4 × 90°, centred on Link's facing | — | P:2045 |
| Combo timer `unk_ADC` | animLength + 4 frames (OoT: 8) | — | P:5687 / O:4521 |
| Combo press window | frames L+1 … L+4 after the swing start (4 frames) | 0.20 s | derived |
| Finisher | 3rd consecutive same type, +2 | — | P:5676-5683 |
| Max chain | 3, then reset | — | P:5676 |
| Hold B → charge | still held at `unk_ADC == 1` (frame L+3) | ≈ swing + 0.15 s | P:8471-8478 |
| Charge rate | +0.02 per frame, cap 0.5 (1.0 with Great Spin) | 25 / 50 frames to cap | P:10818 |
| Charge armed | ≥ 0.1 | 5 frames = 0.25 s | P:15445 |
| Cylinder spawns | > 0.15 | > 7 frames | T:270 |
| Great spin | ≥ 0.85 (Great Spin only) | 43 frames = 2.15 s | P:10776, T:296 |
| Spin cylinder life | 16 frames | 0.8 s | T:369 |
| Spin radius (Kokiri, regular / great) | 60 / 90 u | 2.4 / 3.6 m | T:144-160, T:298-321 |
| Stick-roll rate | ≥ 14.06° per frame over 4 frames at full tilt | ≥ 281°/s | P:5499-5536 |
| Lunge | speedXZ 15, −5 per frame | ≈ 22.5 u = 0.9 m | P:18355-18365 |
| Jump slash (Z + A) | speed 5, vy 5, gravity −1.2 | — | P:8260, P:15403 |
| Air B jump slash | speed 3, vy 4.5 | — | P:8148-8151 |
| Wall recoil / bounce | speedXZ −14 / −18 | 21 / 27 u per frame initially | P:10609, P:10514 |
| Hit freeze | 1 frame | 0.05 s | P:656 |
| Kokiri / Razor blade hit length | 30 + 12 = 42 u | 1.68 m from the hand | PL:3755-3776, PL:2989 |
| Gilded hit length | 52 u | 2.08 m | same |
| GFS / FD hit length | 67 u | 2.68 m | same |
| Sword damage (human normal / jump) | K 1/2, R 2/4, G 3/6, GFS 4/8 | — | P:5628-5636 |
| Fierce Deity damage | 4 / 8 | — | same |
| Spin cylinder damage | K 1, R 2, G 3, GFS/FD 4 | — | T:62-65 |

---

## 7. Open / UNVERIFIED items

1. **Animation frame counts**, which set the combo window and the time until charge, and **root-motion translation** in the swing animations. These are in ROM assets; extract them from `gameplay_keep` (e.g. with the decomp's asset extraction) to get exact timing.
2. **The 4-frame post-swing combo window** is derived from the frame order of `Player_UpdateCommon` → `actionFunc`. It has not been tested in an emulator. In particular, confirm that human B presses during the swing are dropped and not buffered. The code says they are dropped: the swing action never runs `Player_UpdateUpperBody`.
3. **Quick-spin ring-buffer order quirk** (§4.1). It is real in the code; how much it matters in play is not measured.
4. **Three consecutive quick spins → BIG_SPIN** and **stick-roll at release → BIG_SPIN animation without the upgrade** are code-derived curiosities, not tested.
5. **Negative invincibility timer** (-8 at spin release): treated here as 8 frames of intangibility; semantics not traced.
6. **Charge-start phase release** (before the loop starts) and the exact `Player_SetParallel` effect on facing during charge were not traced.
7. **OoT**: B-press buffering during the swing and OoT blade lengths were not checked.
8. **Enemy-side**: final damage depends on each enemy's `DamageTable` multiplier (×0, 0.25, 0.5, 1, 2, 3, 4) and effect. That is per enemy, not per sword.
