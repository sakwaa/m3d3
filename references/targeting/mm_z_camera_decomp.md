# Majora's Mask Z-target camera — decomp reference

Sources (read 2026-11-11):
- zeldaret/mm `main` @ `3be2e24` — `src/code/z_camera.c` (Z_CAM below), `src/code/z_camera_data.inc.c` (Z_DATA), `include/z64camera.h` (HDR), `src/code/z_actor.c`, `src/code/z_olib.c`
- zeldaret/oot `main` @ `14759ab` — `src/code/z_camera.c`, `include/camera.h` (used only to recover field names MM still calls `unk_XX`)

Line numbers are for those commits. Anything I could not confirm in source is marked **UNVERIFIED**.

## 0. Conventions and units

| Thing | Rule | Source |
|---|---|---|
| Frame rate | Camera functions run once per game frame. MM runs at 20 Hz, so 1 frame = 0.05 s | — |
| Units | MM world units. Converted at **1 u = 4 cm** (×0.04 → m) | — |
| Binary angles | 0x10000 = 360°. `CAM_DEG_TO_BINANG(d) = d·65535/360`. 0x2AA8 = 60.0°, 0x3200 = 70.3°, 0x36B0 = 76.9°, 0x157C = 30.2°, 0xC8 = 1.1°, `minDiff` 5 = 0.03° | HDR:16-17 |
| VecGeo | `{r, pitch, yaw}`. Pitch is **elevation** (positive means b is above a). Yaw = atan2(x, z), so 0 = +Z | z_olib.c:104-147 |
| `at→eye` pitch | Positive means the eye is above `at`, looking down | — |
| Step helper | `Camera_ScaledStepToCeilF(target, cur, s, min)` = `cur + (target-cur)·s`, and snaps to target once \|diff\| < min. This is a per-frame exponential lerp | Z_CAM:177-190 |
| `xxxUpdateRateInv` | Stored inverted: the per-frame step is `1/inv` (inv 9 → 11.1 %/frame) | — |
| Data scaling | `CAM_RODATA_UNSCALE(x) = x·0.01`. Values flagged "×0.01" are stored ×100 | Z_CAM:84-90 |
| **Height normalisation** | Some lengths are stored as `val·0.01·H·(0.8 + 0.2·68/H)` = **`val·0.01·(0.8·H + 13.6)`**, where H = `Camera_GetFocalActorHeight` | e.g. Z_CAM:3520, 2722 |
| H for player | `Player_GetHeight`: **Human 44**, Deku 36, Goron 80, Zora 68, FD 124 (+32 when on horse) | z_actor.c:1390-1415 |
| Normaliser k | For H=44: `0.8·44 + 13.6 = 48.8`, so a stored 100 = 48.8 u. For our 40-u Link: `45.6` | derived |
| `speedRatio` | `|player displacement this frame| / (1.5·runSpeedLimit)`, clamped to 1.8. `runSpeedLimit = R_RUN_SPEED_LIMIT/100` (REG(45)). The default value is **UNVERIFIED**; it is not set in the decomp src I searched | Z_CAM:7371-7373 |
| On-ground test `func_800CB950` | \|y − floorY\| < 11 u, OR gravity > −0.1, OR climbing (`STATE1_200000`) | Z_CAM:404-412 |

**Converting per-frame lerps to Godot.** For a per-frame fraction `f` at 20 Hz, use `w = 1 - pow(1 - f, dt*20)`. Equivalently `k = -20·ln(1-f)` per second and `w = 1 - exp(-k·dt)`.

| f/frame | k (1/s) | half-life |
|---|---|---|
| 0.05 | 1.03 | 0.68 s |
| 0.06 | 1.24 | 0.56 s |
| 0.10 | 2.11 | 0.33 s |
| 1/9 = 0.111 | 2.36 | 0.29 s |
| 0.12 | 2.56 | 0.27 s |
| 0.15 | 3.25 | 0.21 s |
| 0.20 | 4.46 | 0.16 s |
| 0.25 | 5.75 | 0.12 s |
| 0.30 | 7.13 | 0.10 s |
| 0.40 | 10.2 | 0.07 s |
| 0.50 | 13.9 | 0.05 s (1 frame) |
| 0.60 | 18.3 | 0.04 s |
| 0.70 | 24.1 | 0.03 s |
| 0.84 | 36.7 | 0.02 s |

**`at` lerp ramp.** Every lock mode ends by calling `Camera_ClampLerpScale(max)`: `atLerpStepScale` becomes 0.12 if it is below 0.12, `max` if it is at or above max, otherwise ×1.1 (Z_CAM:1087-1099). After a mode change or a target switch, the `at` follow rate therefore ramps geometrically from 0.12 up to `max`:
- 0.12 → 0.70 takes about 19 frames (0.95 s).
- 0.12 → 0.60 takes about 17 frames (0.85 s).

## 1. Mode → camera function (CAM_SET_NORMAL0 / NORMAL1)

`sCamSetNormal0Modes` (Z_DATA:2080-2111) and `sCamSetNormal1Modes` (Z_DATA:2230-2257) are identical for the lock-on modes. NORMAL1 differs only in the NORMAL and STILL data.

| Player mode | Function | Data array |
|---|---|---|
| CAM_MODE_NORMAL | Camera_Normal1 | sSetNormal0ModeNormalData (Z_DATA:45) / sSetNormal1ModeNormalData (Z_DATA:414) |
| CAM_MODE_BATTLE (hostile lock) | **Camera_Battle1** | sSetNormal0ModeBattleData (Z_DATA:61) |
| CAM_MODE_FOLLOWTARGET (friendly lock) | **Camera_KeepOn1** | sSetNormal0ModeFollowTargetData (Z_DATA:56) |
| CAM_MODE_TARGET (Z with nothing / forced release) | **Camera_Parallel1** | sSetNormal0ModeTargetData (Z_DATA:51) |
| CAM_MODE_TALK | **Camera_KeepOn3** | sSetNormal0ModeTalkData (Z_DATA:70) |
| CAM_MODE_CLIMBZ | Camera_Jump2 | sSetNormal0ModeClimbZData (Z_DATA:106): `JUMP2(-20, 280, 320, 20, 999, 5, 60, 40)`. Not analysed |
| CAM_MODE_FOLLOWBOOMERANG | Camera_KeepOn1 | (different data) |

Which setting a given field or town scene uses (NORMAL0 vs NORMAL1) is per scene: **UNVERIFIED**. It does not matter for the lock modes.

**Letterbox.** BATTLE, FOLLOWTARGET and TARGET all use `CAM_LETTERBOX_MEDIUM` = 27 (TALK uses LARGE = 32; NORMAL uses none), set in `Camera_UpdateInterface` (Z_CAM:1105-1144). The unit is presumably pixels of the 240-line screen, per bar: **UNVERIFIED**. When the flag is not INSTANT the bars ease in (`ShrinkWindow_Letterbox_SetSizeTarget`).

### Decoded data

Raw macro values first. Then the meaning (field names from OoT `camera.h` macros where MM leaves them as `unk_`), then the converted values for H = 44.

**Battle (Z_DATA:61-64)**: `CAM_FUNCDATA_BATT1(-30, 150, 250, 10, 60, -5, 20, 35, 55, 70, flags=BATTLE1_FLAG_1 | LETTERBOX_MEDIUM, 25, 40)`. Read at Z_CAM:3519-3547.

| # | Field | Raw | Value | Metres / notes |
|---|---|---|---|---|
| 1 | yOffset (×0.01, height-normalised) | −30 | −0.30·48.8 = **−14.64 u** | `at` base = feet + 44 − 14.6 = **29.4 u (1.17 m)**. For H=40: −13.7, so 26.3 u |
| 2 | distNear (`unk_04`) | 150 | **150 u** (not height-scaled) | 6.0 m |
| 3 | distFar (`unk_08`) | 250 | **250 u** | 10.0 m |
| 4 | swingYawInitial (`unk_0C`) | 10 | 10° | |
| 5 | swingYawFinal (`unk_10`) | 60 | 60° | |
| 6 | swingPitchInitial | −5 | −5° | |
| 7 | swingPitchFinal | 20 | 20° | |
| 8 | swingPitchAdj (×0.01) | 35 | 0.35 | |
| 9 | fov | 55 | 55° | |
| 10 | atLerp on ground (×0.01, `unk_24`) | 70 | 0.70 | |
| 11 | interface flags | | | |
| 12 | atLerp off ground (×0.01, `unk_28`) | 25 | 0.25 | |
| 13 | atTowardTarget weight (×0.01, `unk_2C`) | 40 | 0.40 | |

MM added the far distance (#3) and the at-weight (#13). OoT's equivalent is `BATT1(-20, 180, 10, 80, 0, 10, 25, 50, 80, …, -40, 25)`, which has one distance, 180.

**FollowTarget (Z_DATA:56-59)**: `CAM_FUNCDATA_KEEP1(-30, 180, 200, 20, 40, -5, 10, 15, 45, 60, flags=KEEPON1_FLAG_0 | LETTERBOX_MEDIUM, 30)`. Read at Z_CAM:3901-3922.

| Field | Raw | Value |
|---|---|---|
| yOffset (×0.01, normalised) | −30 | −14.64 u, so `at` base is 29.4 u (1.17 m) |
| eyeDist min (`unk_04`) | 180 | 180 u = 7.2 m |
| eyeDistNext max (`unk_08`) | 200 | 200 u = 8.0 m |
| swingYawInit | 20 | 20° |
| swingYawFinal | 40 | 40° |
| swingPitchInit | −5 | −5° |
| swingPitchFinal | 10 | 10° |
| swingPitchAdj (×0.01) | 15 | 0.15 |
| fov | 45 | 45° |
| atLerp on ground (×0.01) | 60 | 0.60 |
| atLerp off ground (×0.01) | 30 | 0.30 |

**Target / Z-parallel (Z_DATA:51-54)**: `CAM_FUNCDATA_PARA1(0, 350, 50, 0, 0, 5, 5, 45, 50, flags=PARALLEL1_FLAG_1 | LETTERBOX_MEDIUM, 60, 0)`. Read at Z_CAM:2722-2738.

| Field | Raw | Value |
|---|---|---|
| yOffset (normalised) | 0 | 0, so `at` = feet + 44 u (1.76 m; head height) |
| dist (`unk_04`, normalised) | 350 | 3.5·48.8 = **170.8 u (6.83 m)**. For H=40: 159.6 u (6.38 m) |
| xzOffsetMax (`unk_08`, normalised) | 50 | 24.4 u (0.98 m) |
| pitchTarget (`unk_20`) | 0 | 0° |
| yawOffset (`unk_22`) | 0 | 0°, i.e. directly behind |
| yawUpdateRateInv target (`unk_0C`) | 5 | 1/5 per frame |
| slope-pitch rate (`unk_10`) | 5 | only used with FLAG_0, which is unset |
| fov (`unk_14`) | 45 | 45° |
| atLerp on ground (×0.01) | 50 | 0.50 |
| atLerp off ground (×0.01) | 60 | 0.60 |
| timer3 (`unk_24`) | 0 | swing-lock delay of 0 |

OoT's equivalent is `PARA1(-20, 250, 0, 0, 5, 5, 45, 50, …)`.

**Talk (Z_DATA:70-74)**: `CAM_FUNCDATA_KEEP3(-20, 80, 150, 50, 5, 20, 5, 40, 35, 50, 20, flags=LETTERBOX_LARGE | HUD A+hearts+magic, 60)`. Read at Z_CAM:4232-4248.

| Field | Raw | Value |
|---|---|---|
| yOffset (normalised) | −20 | −9.76 u |
| eyeDist base | 80 | 80 u (3.2 m) |
| distNormaliser | 150 | 150 u (6 m) |
| swingYaw near / far | 50 / 5 | 50° / 5° |
| swingPitch near / far | 20 / 5 | 20° / 5° |
| pitchAdj (×0.01) | 40 | 0.40 |
| fov | 35 | 35° |
| atLerp (×0.01) | 50 | 0.50 |
| timer | 20 | 20 frames (1.0 s) |
| at-weight (×0.01, `unk_28`) | 60 | 0.60 |

**Normal (for return), NORMAL0 (Z_DATA:45-49)**: `NORM1(-20, 280, 320, 10, 22, 15, 40, 60, 84, flags 7|1|0)`. Read at Z_CAM:1943-1964.
- yOffset: −9.76 u, so `at` base is 34.2 u (1.37 m)
- distMin: 136.6 u (5.47 m)
- distMax: 156.2 u (6.25 m)
- pitchTarget: 10°
- swing/yaw update-rate inverse: 22
- yawDiffRange: 0.40
- fov: 60°
- atLerp: 0.84

NORMAL1's normal data (Z_DATA:414) is `(-20, 280, 320, 15, 18, 12, 70, 60, 80)`: pitch 15°, inverse 18, fov 60.

---

## 2. Camera_Battle1 — hostile lock (Z_CAM:3478-3836)

### Entry (when `RELOAD_PARAMS` is true: animState 0/10/20, Z_CAM:3594-3611)
- Stores the current `at→eye` geo (r, yaw, pitch) as "initial" and sets the blend timer `unk_16 = 7` (Z_CAM:3600).
- If the current `camera->dist > 2·150 = 300 u`, it **snaps** dist to 300 and moves the eye to match (Z_CAM:3605-3610).
- `chargeTimer = 40` and `pitchUpdateRateInv = 9` (Z_CAM:3544-3546).
- If the target actor pointer changes while in Battle1 (Z-switching to another enemy), the camera sets `animState = 0`, which re-runs the entry and the 7-frame blend (Z_CAM:3632-3635).

### Exit
At the top of every frame: if `camera->target == NULL` or `target->update == NULL` (the actor was killed or unloaded), it does `camera->target = NULL; Camera_ChangeMode(CAM_MODE_TARGET)` (Z_CAM:3587-3590). See §5.

### Reference distances
- `p` = player feet + (H + yOffset) = 29.4 u up. `spA4` = geo from `p` to the target focus (`Actor_GetFocus`) (Z_CAM:3637-3639).
- `range = Camera_GetAttentionActorRange(target) = sqrt(range·leash)`, using the actor's `attentionRangeType` (Z_CAM:1249-1252; table z_actor.c:1943-1958), capped at `800 + PREG(86)` (Z_CAM:3644). PREG(86) is assumed to be 0: **UNVERIFIED**.
  - Default type 3 (350/525): **428.7 u (17.1 m)**
  - Type 1: 208 u
  - Type 0: 99 u
  - Type 7: 151 u
  - Type 8: 372 u
  - Types 2, 4, 5, 9, 10: capped at 800 u
- `distRatio = min(R/range, 1)`. It is forced to 1 while charging a spin attack (Z_CAM:3648-3654).
- `rInvTarget` = 2 inside range, 10 when beyond range or charging.

### Distance (Z_CAM:3663-3665)
```
distTarget = lerp(150, 250, distRatio)          // 6 m adjacent → 10 m at range edge
rUpdateRateInv = step(rInvTarget, rUpdateRateInv, 0.5)
dist = step(distTarget, dist, 1/rUpdateRateInv) // ≈50 %/frame in range (very tight), 10 %/frame out of range
```

### `at` point — Camera_CalcAtForEnemyLockOn (Z_CAM:1542-1619)
- Offset from feet = `(0, H + yOffset, 0)` + **(vector p→target) · 0.40 · (1 − distRatio)** (Z_CAM:1560).
  - So `at` leans toward the enemy, and leans most at mid range. The lean length is `0.4·R·(1−R/range)`, with a peak of `0.1·range` (43 u for the default range) at R = range/2. It falls to 0 both when adjacent and at the range edge.
  - The vector includes the vertical component, so `at` rises or drops toward a high or low target.
- **Vertical damping:**
  - On ground: a tracked Y follows the player's Y at 0.4/frame. The offset subtracts (playerY − trackedY), so `at` lags vertical motion (Z_CAM:1576-1581). The offset then steps toward its target with `xzOffsetUpdateRate`/`yOffsetUpdateRate`. In Battle1 those rates ease toward 0.6 at speedRatio·0.2 and speedRatio·0.5 per frame (Z_CAM:3566-3569).
  - Off ground (`flags & 0x80`): it computes the elevation angle θ of (playerY − trackedY) over the eye distance. If θ is within [−10°, +20°], `at` stays at the pre-jump height. Outside that band it follows by `1 − sin(excess)`. The offset step is 0.5/0.5 (Z_CAM:1592-1610).
- `at` then lerps to `feet + offset` with `atLerpStepScale`. That scale is only updated once the blend is over (`unk_16 == 0`): it ramps to 0.70 on ground and 0.25 airborne (Z_CAM:3626-3628).

### Yaw (Z_CAM:3667-3713) — "target sits at a fixed angle off the view axis"
- `a` = signed angle (deg) between `at→target` yaw and the camera's view yaw (`at→eyeNext` yaw + 180°).
- **Cone half-angle** `swing = 10 + (60−10)·(1.1 − distRatio)`: **65° when adjacent, 15° at the range edge** (Z_CAM:3674). It is forced to **15°** if the eye collided with geometry last frame (flag 0x1000, Z_CAM:3671-3672).
- **Blend frames (unk_16 = 7..1, Z_CAM:3680-3692):**
  - Target yaw = the yaw **directly behind the player on the player→target line** (`spA4.yaw + 180°`), blended linearly from the stored initial yaw: weight on the initial yaw = (unk_16−1)/6, from 6/6 down to 0.
  - r is blended the same way.
  - Each value is reached via `step(…, 0.5, min 1 u / 5 binang)`.
  - Pitch is **not** blended; it uses the normal pitch rule below.
  - The blend lasts about 7 frames (0.35 s).
- **Outside the cone** (`|a| > swing`, on ground only, Z_CAM:3693-3708): the camera yaw rotates toward the target by a per-frame step of
  ```
  t = swing + 10·(min(r', dist)/dist)   where r' = dist − 0.5·min(dist, |at→target|)  (so t ∈ [swing+5, swing+10])
  k = (t² − 2)/(t − 360)
  step_deg = a² / (k·a + 2 − 360·k)     (applied with sign of a, added to eye yaw)
  ```
  - This gives 1°/frame at a = t, accelerating as the target gets further off-axis. For t ≈ 47.5: 1.7° at 60°, 4.2° at 90°, 25° at 180°.
  - **As written it is sign-asymmetric**: the signed `a` enters the denominator, so negative offsets turn slower (2.5° at −90°, 8.3° at −180°). OoT is identical (oot z_camera.c ~3091-3097). Using |a| is probably fine for a re-implementation.
- **Inside the cone** (Z_CAM:3709-3713): `eyeYaw -= (±swing − a) · 0.05·(1 − speedRatio)`.
  - This drifts the camera **away** from centring, pushing the target out toward the cone edge at about 5 %/frame. It only happens while the player is slow or still.
  - **Equilibrium framing:** the enemy sits about `swing` degrees off the view axis, measured around `at`. That is 65° (quite side-on) when close and 15° (nearly behind Link) at range.
- There is no explicit "stay behind the player" clamp. Behind-ness comes only from the entry blend and the small far-range cone. The drift side follows the sign of `a`; a = 0 counts as positive.

### Pitch (Z_CAM:3715-3727) — eye elevation above `at`
```
base  = lerp(-5°, 20°, distRatio)                 // swingPitchInitial→Final (50°/40° while spin-charged)
pitch = base − pitch(p→target)·(0.5 + 0.5·distRatio) + pitch(at→target)·0.35
pitch = clamp(pitch, ±60°)                         // ±0x2AA8
eyePitch = step(pitch, eyePitch, 1/pitchUpdateRateInv, 5)   // inv eases to 9 (11 %/frame); 18 while charging
```
- With the target level: −5° (slightly below `at`, looking up) when adjacent, and +20° (looking down) at range.
- Target 30° above: about −9.5° when near, about +0.5° when far. The camera drops to look up.
- Target 30° below, far: about +39.5°.

### Eye and collision (Z_CAM:3728-3819)
- `eyeNext = at + geo(dist, yaw, pitch)`.
- When the camera is active and the room has a skybox (or BATTLE1_FLAG_0), it runs `func_800CBC84(at → eye)` (Z_CAM:518-575):
  - It line-tests from `at` to the eye (+1 u beyond). On a hit, the eye goes to the hit point plus the poly normal, i.e. 1 u off the wall, pulled straight in.
  - With no hit, if the eye is ≤ 5 u above the floor below it, the eye is lifted to floor + 5 u + normal.
  - A hit sets flag 0x1000, which makes the cone 15° next frame.
- In rooms with no skybox and BATTLE1_FLAG_1 (the data has it), it uses mode 3, which skips some poly classes.
- The FLAG_4 branch (when the eye is blocked, move to 40 u behind/over Link's focus) is **not** enabled in the field data.
- The result is applied directly to `eye` with no smoothing beyond the geo steps.

### Roll (Z_CAM:3821-3825)
- Target roll = ½ × this frame's yaw change (in binang). Step 0.06/frame.
- So the view leans slightly into fast yaw swings. Roll is 0 during the blend.

### FOV (Z_CAM:3827-3834)
- `fovTarget = (health ≤ 16 ? 0.8 : 1) · (55 − 55·0.05·distRatio)`, i.e. **55° near → 52.25° far**. 44° at one heart or less (16 units = 1 heart).
- While swinging a weapon (`meleeWeaponState != 0`) it is decompiled as `(frames & 8) ? fov·0.5 : fov`. That looks odd (OoT uses 0.8×fov); verify in-game: **UNVERIFIED intent**.
- `fov = step(fovTarget, fov, fovUpdateRate)`. `fovUpdateRate` eases to 0.05 (Z_CAM:3572-3573).

### Spin-charge override (Z_CAM:3553-3570)
- While charging: `chargeTimer` counts 40 → −20 (60 frames = 3 s). After that, swingPitch becomes 50°/40° and fov 60°.
- These values are held for 20 frames after release, then return.
- `pitchUpdateRateInv` → 18 while charging.

---

## 3. Camera_KeepOn1 — friendly lock / FOLLOWTARGET (Z_CAM:3857-4177)

Same skeleton as Battle1. The differences:

- **Exit:** if the target is NULL or dead, `Camera_ChangeMode(CAM_MODE_TARGET)` (Z_CAM:3894-3898).
- **Entry:**
  - 7-frame blend (Z_CAM:3937).
  - Dist snaps if it is > 2·180 = 360 u (Z_CAM:3942-3947).
  - During the blend `skipEyeAtCalc = true`, so **the eye does not move at all for 7 frames (0.35 s)**; only `at`, fov and roll update (Z_CAM:4035-4052). This is as decompiled; Battle1 does move the eye during its blend.
- **Target switch:** the camera does not re-run the blend. It only resets `atLerpStepScale = 0`, so `at` re-ramps from 0.12 (Z_CAM:3970-3974).
- **Target point:** the target's world XZ with its focus Y (Z_CAM:3962-3968).
- **Ratio:** `sp74 = min(R/180, 1)`, where R = feet+H+yOffset → target. It is normalised by eyeDist 180, **not** by the attention range (Z_CAM:3993-4000).

### `at` — Camera_CalcAtForFriendlyLockOn (Z_CAM:1449-1540)
- The lean vector runs from **feet + H (no yOffset)** to the target, with length
  ```
  R > 200 :  0.2·R
  R ≤ 200 :  0.9·R − 0.7·R²/200     (peaks ≈ 58 u at R ≈ 129 u; equals 40 u at R = 200)
  ```
  (Z_CAM:1479). It is ×0.2 while airborne.
- Vertical damping is the same as Battle1. The on-ground tracked-Y step is 0.4. Airborne uses the [−10°, +20°] band (flag 0x80) or a ±0.4·fov screen band (Z_CAM:1495-1532).
- The offset rates ease to 1.0 at speedRatio·0.5 and speedRatio·0.2 (Z_CAM:3976-3979). When airborne they are forced to 0.5.
- atLerp ramps to **0.60** on ground and **0.30** in the air (Z_CAM:4174).

### Distance (Z_CAM:4004-4024)
- The eye distance is kept inside **[180, 200] u (7.2–8.0 m)**.
- If the current distance is outside the band, it steps to the nearest bound with `rUpdateRateInv → 20` (5 %/frame).
- Inside the band it holds its current distance (`rInv → 1`).

### Yaw (Z_CAM:4026-4066)
- Cone `swing = lerp(20°, 40°, 1.1 − sp74)` = **42° near → 22° at R ≥ 180**.
- The outside-cone step formula is the same as Battle1, but it applies even when airborne.
- The inside-cone drift is the same (0.05·(1 − speedRatio)).
- There is no collision override of the cone.

### Pitch (Z_CAM:4068-4083)
```
pitch = lerp(-5°, 10°, sp74) − pitch(p→target)·(0.5 + 0.5·sp74) + pitch(at→target)·0.15
clamp ±70.3° (0x3200); step fixed 1/9 per frame (11 %, half-life 0.29 s)
```

### Other
- Collision is the same code as Battle1 (Z_CAM:4087-4167). KEEPON1_FLAG_0 is set, so full collision applies everywhere.
- FOV → **45°** (Z_CAM:4171). There is no distance or health term.
- Roll → 0 at 0.2/frame (Z_CAM:4172).

---

## 4. Camera_Parallel1 — Z with nothing (CAM_MODE_TARGET) (Z_CAM:2696-3040)

The data has only PARALLEL1_FLAG_1 set: "swing behind player, then hold".

### Entry (animState 0/10/20, Z_CAM:2745-2823)
- Sets offset rates to 0.5/0.5.
- If `dist > 2·170.8 = 341.6 u`, it snaps dist to 341.6.
- `timer2 = 6`: the swing length. It would be 20 with FLAG_2, and 30 for CHARGE.
- `timer3 = 0`, `rwData.dist = 170.8`, `rwData.fov = 45`.

### Swing target (Z_CAM:2826-2831)
- Every frame while `timer2 != 0`: `yawTarget = player facing yaw + 180°` (i.e. **directly behind Link**) + 0, and `pitchTarget = 0°`.
- After the swing it is **not** re-evaluated, because FLAG_5 is unset. The camera yaw then stays fixed at the yaw latched on the last swing frame.

### Swing motion (Z_CAM:2951-2967)
- Each frame: `tri = t(t+1)/2`, `yaw += ((target − yaw)/tri)·t` (pitch likewise), t = 6..1.
- That covers 2/(t+1) of the remaining angle per frame (28.6 %, 33 %, 40 %, 50 %, 67 %, 100 %). It is an exact **quadratic ease-out that lands on target in 6 frames (0.30 s)**. Cumulative: 29, 52, 71, 86, 95, 100 %.
- While the swing runs (timer3 == 0), it sets `CAM_STATE_DISABLE_MODE_CHANGE` (Z_CAM:2952-2955). That flag is cleared at the start of each `Camera_Update` (Z_CAM:7457), but Player requests modes before the camera updates. **So the 6-frame swing cannot be interrupted by Z-release or a new lock** (only a forced change can).

### Distance
- `dist = step(170.8, dist, 1/rUpdateRateInv)` (Z_CAM:2945).
- `rUpdateRateInv` eases toward 20 with step `speedRatio·0.5` (Z_CAM:2876-2879). Standing still, it keeps whatever rate the previous mode left, so the distance convergence speed is inherited. When moving it converges to 5 %/frame.

### After the swing (Z_CAM:2968-3000)
- Yaw: `step(latchedYaw, yaw, 1/yawUpdateRateInv, min 0xC8 = 1.1°)`, with `yawUpdateRateInv → 5` (20 %/frame).
- Pitch: steps to 0° with `pitchUpdateRateInv → 2` (50 %/frame; that rate eases in at speedRatio·0.2).
- Pitch clamp: [−30°, +79.7°].
- Net framing: **level (0°) camera, eye at head height (44 u up), 170.8 u (6.8 m) directly behind the direction Link faced at the moment of lock, fov 45°.**

### `at`
- During the swing: `Camera_CalcAtDefault(yOffset 0)` → feet + (0, 44, 0) (Z_CAM:2930-2932; helper Z_CAM:1257-1288).
- After the swing, on ground: `Camera_CalcAtForParallel` (Z_CAM:1372-1447).
  - The XZ offset may accumulate player motion up to 24.4 u, so the camera trails slightly.
  - Y uses the 0.4 tracked-Y damping.
- Airborne: `Camera_CalcAtForScreen`, which only follows Y when the player leaves the middle half of the screen (Z_CAM:1290-1334).
- Offset rates → 0.05. atLerp → 0.50 on ground, 0.60 in the air (Z_CAM:3036).

### Other
- Collision: the eye is pulled in along `at→eye` by `func_800CBFA4`, which uses `func_800CBC84` (Z_CAM:3008-3023).
- FOV → 45° at `fovUpdateRate` (→ 0.05).
- Roll → 0 at 0.5/frame.

### What ends it
Nothing inside Parallel1. Player picks the mode each frame (`Player_UpdateCamAndSeqModes`, mm z_player.c ~11984-12047). Releasing Z selects NORMAL; acquiring a target selects BATTLE or FOLLOWTARGET. Either change is accepted once the 6-frame swing has ended.

---

## 5. When a lock ends

1. The target dies or unloads (its `update` becomes NULL).
   - **Same frame:** Battle1, KeepOn1 or KeepOn3 sees it and calls `Camera_ChangeMode(CAM_MODE_TARGET)` before returning (Z_CAM:3587, 3896, 4218).
   - Player's own logic also drops to TARGET via `LOCK_ON_FORCED_TO_RELEASE` (see the earlier targeting doc).
   - The Z sound plays (`CAM_CHANGE_MODE_1` → NA_SE_SY_ATTENTION_ON, or URGENCY in dungeons; Z_CAM:7680-7693).
2. **Next frames: Parallel1 swing.**
   - The camera does the uninterruptible 0.30 s ease-out to directly behind Link's facing, pitch 0°.
   - Distance goes toward 170.8 u, fov toward 45°, letterbox stays MEDIUM.
3. If Z is not held, Player then requests NORMAL.
   - `Camera_ChangeModeFlags` (Z_CAM:7557-7718) calls `Camera_ResetActionFuncState`, which sets `animState = 0`.
   - The 20 (FastYaw) state is only set when the *previous* mode is NORMAL/JUMP/HANG/CHARGE, so TARGET→NORMAL is a plain re-init.
4. **Camera_Normal1 re-init** (Z_CAM:1966-1990). There is **no snap**: the camera starts from wherever the eye is.
   - Swing state is cleared and `swingUpdateRate = 22`.
   - The idle counter `unk_0A = 1300` lets yaw-follow run for about 100 frames (5 s) even when idle.
   - Distance clamps into [136.6, 156.2] u via `Camera_ClampDist2`. `rUpdateRateInv` is 20 outside the band, so 5 %/frame (Z_CAM:2161-2165, 1690-1724).
   - Pitch eases to 10° with `pitchUpdateRateInv → 16` (6 %/frame) via `Camera_CalcDefaultPitch` (Z_CAM:1726-1757).
   - Yaw only follows the player's movement direction (`unk_0F0`) in proportion to speed (`Camera_CalcDefaultYaw`, Z_CAM:1759-1786). Standing still, it stays put.
   - FOV eases 45 → 60 at about 5 %/frame. atLerp ramps from its current value to 0.84. Letterbox is removed.
5. **Z-switching to a new enemy without release** stays in BATTLE.
   - `camera->target` changes, Battle1 re-inits (`animState = 0`) and runs a fresh 7-frame blend toward behind the player→newTarget line (Z_CAM:3632-3635).
   - KeepOn1 only resets the `at` lerp.
   - Going from FOLLOWTARGET to BATTLE or the reverse is a mode change, so the new function inits from the current eye.

---

## 6. Camera_KeepOn3 — TALK (Z_CAM:4186-4433), summary

- **First frame:** it sets DISABLE_MODE_CHANGE and returns for one frame (view handshake) (Z_CAM:4223-4229).
- **Init.** R = head (feet + H) → target focus, `φ = min(R/150, 1)`.
  - `at` target = head + dir·(0.4·R + 0.6·(1−φ)·R/20) − 9.76 u in Y. That is about 40 % of the way toward the NPC (Z_CAM:4329-4338).
  - Eye distance from `at` = **80 + R/2**. For R = 60 u that is about 110 u (4.4 m).
  - Yaw offset `lerp(50°, 5°, φ)` from the player→NPC line. Pitch `lerp(20°, 5°, φ) − 0.4·pitch(head→NPC)` (Z_CAM:4268-4275).
- **Side choice** (Z_CAM:4280-4319):
  - If the eye is currently on the NPC's side (|yaw(head→NPC) − yaw(at→eye)| < 90°), it places the eye at the NPC's back, facing Link.
  - Otherwise it places the eye over Link's shoulder.
  - The sign is chosen to keep the current side.
  - Doors and `EN_TALK` always go over Link's shoulder. A steep NPC (> 30.2°) gets a special 30 u-over-head placement, clamped to −49.4°.
- **Occlusion** (Z_CAM:4342-4366): tests the mirrored side, then up to 13 fallback offsets.
  - Yaw: ±15°, ±30°, ±60°, ±90°, ±120°, ±150°, 180°.
  - Pitch: 0, +3.9°, +7.8°, −3.9°, +11.7°, +15.6°, −7.8°.
  - Table at Z_DATA:3799-3806.
- **Motion over 20 frames (1.0 s):**
  - `at` moves 1/t of the remaining distance each frame, which is linear.
  - The eye geo uses the same triangular ease-out as Parallel1.
  - fov → 35° at 0.5/frame.
  - After that the camera holds still (Z_CAM:4380-4398).

---

## 7. Implementation sketch (per frame, dt-scaled)

```
# shared
H = 44 (MM) or 40 (ours); k = 0.01*(0.8*H + 13.6)
p = feet + up*(H + yOffset)
R = |target_focus - p|

# BATTLE
ratio   = min(R / attention_range, 1)       # 428.7 u default
dist   -> lerp(150, 250, ratio)             (~50%/frame)
at     -> feet + up*(H+yOff) + (target-p)*0.40*(1-ratio)   (offset 0.6/frame, then at-lerp ramp→0.70)
cone    = 10 + 50*(1.1 - ratio)             # 65°→15°; 15° after a wall hit
yaw: if |off| > cone: rotate toward target by a²/(k a + 2 − 360k) deg/frame
     else: drift so target sits at the cone edge, 5%/frame * (1 - speedRatio)
pitch  -> clamp(lerp(-5,20,ratio) - pitch(p→T)*(0.5+0.5ratio) + pitch(at→T)*0.35, ±60) @ 1/9
fov    -> 55 - 2.75*ratio ; letterbox medium
entry: 7-frame blend of yaw/r to "behind Link on Link→target line"; snap dist ≤ 300

# FOLLOWTARGET: same, but ratio = min(R/180,1), dist clamp [180,200], cone 20+20*(1.1-ratio),
#   pitch lerp(-5,10) & adj 0.15, clamp ±70.3, fov 45, at lean 0.9R-0.7R²/200 (≤200) else 0.2R, at-lerp→0.60

# TARGET (Parallel1): 6-frame ease-out (2/(t+1) per frame) to yaw = facing+180, pitch 0;
#   locked, dist→3.5k (170.8 u), at = feet+H, fov 45; cannot be interrupted during the 6 frames.
```

## Open questions / UNVERIFIED

- The default `R_RUN_SPEED_LIMIT` (REG 45), which sets the `speedRatio` denominator. `PREG(86)` and `PREG(76)` (slope adjust) are assumed to be 0.
- The Battle1 weapon-swing FOV halving every 8 frames (Z_CAM:3828-3829) looks like decomp noise or an unusual effect; check against footage.
- KeepOn1 freezes the eye for 7 frames on entry, while Battle1 does not. This is faithful to the decomp, but worth confirming visually.
- The sign asymmetry of the outside-cone yaw step (present in OoT too). It is probably unnoticeable because it only affects large offsets.
- Letterbox units and per-bar size.
- Which scenes use NORMAL0 vs NORMAL1 (it does not affect the lock modes).
