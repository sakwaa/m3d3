# OoT / MM sword trails and hit effects — research notes

Sources: `~/Downloads/oot` (ntsc-1.2 decomp) and `~/Downloads/mm` (n64-us decomp). Paths below are relative to those roots.
These notes describe behaviour and numbers only. No code or asset data is copied.

**Units and timing.** Positions are in game units (Link's limb-space values are ×0.01 model scale, so a
limb-space length of 4000 is 40 units). All per-frame numbers are per **game frame**. Gameplay runs at
20 fps in both games (the VI rate is 60 Hz). If you run at 60 Hz, scale lifetimes by ×3, per-frame speeds by ×1/3
and per-frame² accelerations by ×1/9, or run the effect sim on a fixed 20 Hz tick.

**Frame order.** Defined in `src/code/z_play.c` (Play_Update / Play_Draw): `CollisionCheck_AT/AC` (spawns hit
effects) → `Actor_UpdateAll` → `Effect_UpdateAll` (trails, sparks, shield particles) → `EffectSs_UpdateAll`
(hit marks). Draw: actors first, then `Effect_DrawAll` and `EffectSs_DrawAll` (`src/code/z_actor.c` ~2969).
Trail samples are added **during the player's draw** (PostLimbDraw), so a new sample is drawn in the same frame,
before it has been aged.

**Effect pools** (`include/effect.h` OoT, `include/z64effect.h` MM): 3 sparks, 25 blures, 3 shield-particle bursts.
When a pool is full, `Effect_Add` simply fails, so at most 3 spark bursts and 3 shield bursts can exist at once.

---

## 1. Sword trail ("Blure"), `src/code/z_eff_blure.c` (both games)

### 1.1 Data structure
`EffectBlure` (`include/effect.h` OoT; `include/z64eff_blure.h` MM):
- **16 elements** (a ring that shifts down by one; element 0 is the oldest). Each element has:
  - `state`: 0 = "space" (a gap that breaks the strip), 1 = vertex, 2 = unused slot.
  - `timer`: age in frames, starting at 1.
  - `p1`, `p2`: **Vec3s**, so integer world units. This quantisation is part of the look. For the player,
    **p1 = blade tip and p2 = blade base**.
  - `flags`: per-element smoothing class used by the smooth draw mode (see 1.5).
- Global: `calcMode`, `flags`, `drawMode`, `elemDuration`, `unkFlag`, `addAngleChange/addAngle`, `mode4Param`, four
  RGBA colours `p1StartColor, p2StartColor, p1EndColor, p2EndColor`, and `altPrimColor/altEnvColor` (draw mode 1 only).
- Two init structs exist. `EffectBlure_Init1` (EFFECT_BLURE1) forces `flags = 0` and `drawMode = 0`, which selects
  the old-style draw (1.6). `EffectBlure_Init2` (EFFECT_BLURE2) takes `flags` and `drawMode`; the player uses this one.

### 1.2 Adding and ageing samples
- `EffectBlure_AddVertex(p1, p2)`: if fewer than 16 elements exist, it appends one with `state = 1` and `timer = 1`.
  It does nothing when the table is full.
  - If `flags & 2`, the new pair is rotated around the axis from the previous pair's midpoint to this pair's
    midpoint by `addAngle`. `addAngle` grows by `addAngleChange` every update, which gives a twisting ribbon.
    The player does not use this.
- `EffectBlure_AddSpace()` appends a `state = 0` gap. Enemies use it when their swing ends. The player never calls it.
- `EffectBlure_Update` runs once per frame:
  1. It pops leading gap elements.
  2. It increments every element's `timer`.
  3. If `elements[0].timer > elemDuration`, it pops **one** element per frame (shifting all down).
  4. **MM only:** after a shift, and each frame, it clamps every timer to `elemDuration`. The age ratio therefore
     never exceeds 1 (fixes OoT overshoot when several samples expire at once).
- Age ratio used everywhere is `ratio = timer / elemDuration`. 0 means new and 1 means dead.
- **Player lifetime:** `elemDuration = 4`. A sample is drawn at timer 1, 2, 3 and 4, so ratios are
  0.25, 0.5, 0.75 and 1.0, and it is removed when its timer reaches 5. The trail therefore holds about
  **4–5 samples (3–4 segments)** and never shows a full-alpha head: the newest sample is already at ratio 0.25.

### 1.3 Colours along the trail
Implemented in `EffectBlure_GetComputedValues`. Per sample:
- `color(p1) = lerp(p1StartColor, p1EndColor, ratio)`
- `color(p2) = lerp(p2StartColor, p2EndColor, ratio)`

The lerp is per RGBA channel with u8 truncation. Gouraud shading then blends the colour along the blade and along the
trail. `flags & 0x10` forces every colour to opaque white.

**Player values (both games are identical by default):**

| | RGBA |
|---|---|
| p1 (tip) start | 255,255,255,**255** |
| p2 (base) start | 255,255,255,**64** |
| p1 end | 255,255,255,0 |
| p2 end | 255,255,255,0 |

This is a white ribbon: opaque at the tip, 25 % alpha at the hilt, fading linearly to 0 with age.
- OoT: `D_8085470C` in `src/overlays/actors/ovl_player_actor/z_player.c` (~10643). Init2 fields: calcMode 0,
  flags 8, addAngleChange 0, elemDuration 4, unkFlag 0, drawMode 2 (smooth), mode4Param 0.
  **No per-sword or per-age variation.** Kokiri, Master, Biggoron, Deku Stick and Hammer all use the same trail.
  Only the tip length differs (1.4).
- MM: `D_8085D30C` (`z_player.c` ~11072) has the same values. The player creates **two** blures (index 0 is the
  sword/main trail, index 1 is the second Zora fin) and also a tire-mark effect (index 2) for Goron rolling.
  `Player_OverrideBlureColors(play, this, colorType, elemDuration)` (~3627) swaps the colour set:
  - Type 0 (default, all swords): the white set above, duration 4. It is re-applied at the start of **every**
    melee swing (`func_8082FA5C`) and at init.
  - Type 1, Zora fast swim (`func_8083B850`): tip (165,185,255,185), base (205,225,255,50), ending at white α0,
    **duration 8**. This gives a pale-blue, longer trail from the fins.
  - **Deku form forces `elemDuration = 8`** whatever the type.
  - There is no Kokiri/Razor/Gilded/Great Fairy/Fierce Deity colour difference. All are white.

### 1.4 Where the sample points come from (player)
- OoT, `src/code/z_player_lib.c`:
  - In `Player_PostLimbDrawGameplay`, on the **left hand** limb, while `meleeWeaponState != 0`, the code computes
    the tip and base in hand-limb space with the current hand matrix:
    - tip = (L, 400, 0), where `L = sMeleeWeaponLengths[...]`
    - base = (0, 400, 0)

    The base is effectively the hilt and grip, not the guard, so the ribbon spans hand to tip.
  - Lengths in limb units (÷100 gives world units): Master Sword **4000**, Kokiri **3000**, Biggoron **5500**,
    Hammer **2500**, broken Giant's Knife **1500**, Deku Stick **5000 × current stick length fraction**.
  - `Player_UpdateMeleeWeaponInfo` → `Player_UpdateWeaponInfo` returns true when the weapon has just become active
    or has moved since last frame. Only then does it call `EffectBlure_AddVertex(tip, base)`, and **never while
    shielding**. A motionless blade adds no samples, so the trail drains away.
  - The hitbox quads use two extra offset lines (±400/±1400 Y, ±1000 Z), which are separate from the trail.
- MM, `src/code/z_player_lib.c` `func_8012669C` (~2890) and the left-hand block (~3755):
  - Base (0,400,0) and tip (L,400,0). Lengths: Kokiri **3000**, Razor **3000**, Gilded **4000**,
    Great Fairy Sword **5500**, Deku Stick 5000 × length, Zora fin/boomerang 2500.
  - The hit quads extend 1200 past the tip, and further while a charged spin is building (`unk_ADD`).
  - No trail for Goron form punches, or while in the `PLAYER_STATE1_400000` state.
  - Extra trail sources:
    - Zora punch fins, from the forearm limbs, using offsets (-2500,1400,1100) for the tip and (900,300,100) for
      the base.
    - Zora kick shin.
    - The hat limb (`X 3000` tip, `X 2300` base) while `PLAYER_STATE3_100000`.
    - Zora fins while swimming (`stateFlags1 & 0x8000000`), on blures 0 and 1.

### 1.5 When the trail starts and stops
- `meleeWeaponState` is set by `func_80833A20` (OoT) or `func_8082FA5C` (MM), which also plays the swing SFX.
- Each attack has a window `{activeStart, activeEnd}` in animation frames (OoT `D_80854190`, MM
  `sMeleeAttackAnimInfo`). The function `func_8084285C` (OoT) or `func_8083FCF0` (MM) sets the state each frame:
  - frame < 0 or > activeEnd: state 0, so no trail and no hitbox
  - 0 ≤ frame < activeStart: state **−1**, so the **trail is on** but the hitbox is off
  - activeStart ≤ frame ≤ activeEnd: state **1**, so the trail and the hitbox are both on
- **So the trail begins on frame 0 of the swing animation and stops adding at `activeEnd`, then fades out over
  4 frames.** Windows (identical in both games for shared moves):

| Attack | start, end |
|---|---|
| Forward slash 1H/2H | 1,4 / 1,4 |
| Forward combo 1H/2H | 0,5 / 1,7 |
| Right slash 1H/2H | 1,4 / 0,5 |
| Right combo 1H/2H | 2,8 / 3,8 |
| Left slash 1H/2H | 0,4 / 0,5 |
| Left combo 1H/2H | 0,6 / 1,5 |
| Stab 1H/2H | 0,3 / 0,3 |
| Stab combo 1H/2H | 1,9 / 1,8 |
| Flip slash / jump slash start | OoT 1,10 / 1,11; MM 7,99 / 7,99 |
| Flip/jump slash finish | 1,2 |
| Backslash R/L | 1,5 / 1,4 |
| Hammer fwd/side (OoT) | 3,10 / 2,11 |
| Spin 1H/2H | 0,12 / 0,15 |
| Big (charged) spin 1H/2H | 0,16 / 0,16 |
| MM Goron punch L/R/butt | 6,8 / 12,18 / 8,14 |
| MM Zora punch L/combo/kick | 2,5 / 3,8 / 3,10 |
| MM Zora jumpkick start | 8,99 |

- `func_80832318` (OoT) clears the state and marks the weapon infos inactive at the end of each attack, so the next
  swing's first sample does not connect to old positions. Any samples still alive could still connect visually,
  because the player never inserts a gap.

### 1.6 Draw modes
`EffectBlure_Draw` routes as follows:
- **`flags == 0`** ("legacy", used by every EFFECT_BLURE1 user, which are enemies) draws a plain quad strip:
  - Each `state==1` element gives two vertices, p1 and p2, after `calcMode` processing. Colours are lerped by ratio.
  - `gSP1Quadrangle` joins consecutive vertex pairs. A `state==0` gap breaks the strip.
  - `unkFlag == 1` draws only every other quad.
  - Setup is `Gfx_SetupDL_38Xlu`: combiner **G_CC_SHADE** (vertex RGBA only, no texture) and render mode
    **G_RM_AA_ZB_XLU_SURF** (z-test, no z-write, alpha blend, AA). There is no cull, so it is double-sided.
- **`flags != 0 && drawMode < 2`** gives the "simple" mode (`EffectBlure_DrawSimple`). Each segment is drawn as
  its own 4-vertex quad between element i and i+1.
  - drawMode 0: SETUPDL_38, the same untextured G_CC_SHADE look.
  - drawMode 1 ("simple alt colours", `EffectBlure_SetupSimpleAlt`) is the **textured** mode. It is used by arrows
    (OoT `ovl_En_Arrow`: duration 16, flags 4, alt prim/env per arrow type), not by swords.
    - Texture: `gUnknownEffBlureTex` (OoT) / `gameplay_keep_Tex_014570` (MM), **I8, 64×32**. S is clamped and T
      wraps. Shape: a soft horizontal streak or flame tongue. It is black on the left, ramps up through a fuzzy
      rounded nose, and is solid white over the right half, brightest along the horizontal centre line.
    - UVs: only the **oldest** segment uses the full S 0→64 ramp. Every later segment samples S=64 (solid bright).
      T spans 0→32 from p2 to p1. The effect is a fuzzy fade-in at the tail end of the ribbon.
    - 2-cycle combiner:
      - cycle 1 colour = TEX + 0.5·(TEX − PRIM) (PRIM_LOD_FRAC 0x80); cycle 1 alpha = TEX·PRIM.a
      - cycle 2 colour = lerp(ENV, PRIM, cycle 1); cycle 2 alpha = cycle 1 alpha
      - **Vertex colours are ignored.**
    - Per segment, prim alpha = `altPrim.a × (1 − timer/duration)`.
    - Render mode is **G_RM_PASS + G_RM_ZB_CLD_SURF2**: z-test, no z-write, plain alpha blend, no AA.
  - `flags & 4` draws a **second copy of each quad rotated 90° about the segment's centre line**. This gives a
    crossed "+" ribbon that stays visible edge-on; arrows use it.
- **`flags != 0 && drawMode >= 2`** gives the **smooth** mode (`EffectBlure_DrawSmooth`). **This is what the player
  sword uses** (flags 8, drawMode 2).
  - Setup is SETUPDL_38: untextured, vertex RGBA, AA_ZB_XLU_SURF, double-sided.
  - Vertices are expressed relative to `elements[0].p2`, ×10, then drawn with a ×0.1 matrix. This keeps s16
    vertex precision. Positions are rounded with nearbyint.
  - Classification (`EffectBlure_UpdateFlags`):
    - The first and last elements are "edge" (2).
    - An interior element whose neighbour is a gap is also an edge.
    - Otherwise, with Δtip_prev, Δtip_next, Δbase_prev and Δbase_next as the vectors between consecutive tips and
      bases, the element is **sharp (0)** if any of these holds:
      - cos(Δtip_prev, Δtip_next) ≤ −0.5, i.e. the tip path turns by 120° or more
      - cos(Δbase_prev, Δbase_next) ≤ −0.5
      - cos(Δtip_next, Δbase_next) ≤ 0.7071, i.e. tip and base motion differ by 45° or more
      - any of these vectors is zero-length
    - Otherwise the element is **smooth (1)**.
  - Per segment i→i+1:
    - If **both** endpoints are in {sharp, edge}, it draws one straight quad (`DrawElemNoInterpolation`).
    - Otherwise it uses **cubic Hermite subdivision** (`DrawElemHermiteInterpolation`): **8 vertex pairs, so 7
      sub-quads**, at t = i/7.
    - P0 and P1 are the processed tip and base of elements i and i+1. Tip and base are interpolated
      independently with the same t.
    - Tangent at i: m0 = 0.5·(P[i+1] − P[i−1]) (Catmull-Rom). If element i is an edge, m0 = 0.5·(P[i+1] − P[i]).
    - Tangent at i+1: m1 = 0.5·(P[i+2] − P[i]). If element i+1 is an edge, m1 = 0.5·(P[i+1] − P[i]).
    - Standard Hermite basis: (2t³−3t²+1), (3t²−2t³), (t³−2t²+t), (t³−t²).
    - Colours are lerped linearly in t between the two samples' computed colours.
  - Practical effect: a 4-sample trail becomes a ~21-quad curved fan in a fast arc. Sharp direction reversals stay
    faceted.

### 1.7 calcMode (shape change with age)
Applied per sample with its age ratio:
- **0**, the player: p1 and p2 unchanged. The ribbon keeps full blade width and only fades.
- **1**: p1 slides toward p2 by ratio (the tip edge collapses onto the base edge).
- **2**: p2 slides toward p1 by ratio. The ribbon **tapers to the p1 line** as it ages. Used by enemies:
  - Stalfos `ovl_En_Test`: white, p2 α64, duration 4
  - Gerudo `ovl_En_GeldB`: duration 8, (tip, hilt)
  - Lizalfos `ovl_En_Zf`: white, duration 8
- **3**: both points slide toward the middle by ratio/2. The ribbon shrinks to its centre line.
- **4**: width scales by `1 + (mode4Param−1)·ratio` about the centre.

### 1.8 Spin attack
- The trail itself is the same white blure. The spin animations simply hold the state on for 12–16 frames, giving a
  full circle of samples.
- The glowing swirl is a separate actor, **`ovl_En_M_Thunder`** (both games), a mesh rather than a blure:
  - Normal spin: prim (170,255,255) cyan.
  - Charged ("big") spin: prim (255,255,170) pale yellow.
  - Alpha is `spinAttackAlpha × 255`.
  - Two scrolling textures: 64×32 scrolled at 30/frame and 8×8 at 20/frame.
  - Scale depends on sword: Kokiri smaller, Biggoron larger.
  - The charge-up glow on the blade pulses through an 8-step scale table:
    - below 85 % charge: prim (170,255,255), env (0,100,255)
    - at 85 % or more: prim (255,255,170), env (255,100,0)
    - scroll 5/20/(20 or 40) per frame
- These are listed for completeness. They are a separate effect from the trail.

---

## 2. Hit effects

### 2.1 Which effect fires for which hit
Logic lives in `CollisionCheck_HitEffects` and `CollisionCheck_HitSolid` (`src/code/z_collision_check.c`, OoT
~1564–1705; MM ~1540–1650). The table `sHitInfo[colMaterial]` gives {blood, hitmark}. It is the **AC (victim)
collider's** material that decides:

| AC colMaterial | blood (EffectSpark) | hit mark / other |
|---|---|---|
| HIT0 (common enemy flesh) | **blue** | WHITE |
| HIT1 | none | DUST |
| HIT2 | green | DUST |
| HIT3 (common, no blood) | none | WHITE |
| HIT4 | water burst + droplets | none |
| HIT5 | none | RED |
| HIT6 | green | WHITE |
| HIT7 | red | WHITE |
| HIT8 | blue | RED |
| METAL / WOOD / HARD | none | → `HitSolid` (below) |
| TREE | none | **shield-particle streaks** (wood version: no light) + `NA_SE_IT_REFLECTION_WOOD` |
| NONE | none | none |
| AC with no actor | none | WHITE + `NA_SE_IT_SHIELD_BOUND` |

`HitSolid` then branches on the attacker's `atElemFlags & ATELEM_SFX_*`:
- **SFX_NORMAL on METAL**: **METAL hit mark + shield-particle streaks with blue flash light**
  + `NA_SE_IT_SHIELD_REFLECT_SW` (the "clang").
- SFX_NORMAL on WOOD or HARD: WHITE hit mark + `NA_SE_IT_SHIELD_BOUND`.
- SFX_HARD: WHITE hit mark + SHIELD_BOUND.
- SFX_WOOD: DUST hit mark + `NA_SE_IT_REFLECTION_WOOD`.

Flesh hits also play the sword strike SFX by element material (`CollisionCheck_SwordHitAudio`):
`NA_SE_IT_SWORD_STRIKE` or `_HARD`.

**Player's shield (as the AC):**
- Material is set in `Player_UpdateShieldCollider`.
- OoT: none → METAL, **Deku → WOOD**, Hylian → METAL, Mirror → METAL.
- MM: all METAL (`z_player_lib.c` ~2730).
- So a normal enemy hit on the Hylian, Mirror or Hero's shield gives the METAL hit mark, the streak burst, a blue
  light flash and the clang. On the Deku Shield it gives only the WHITE hit mark and a dull "bound" thud.

**Sword hitting level geometry** (no collider involved): OoT `func_80842DF4`, MM `func_808401F4`.
- From swing frame 2 onwards, while the hitbox is active, a line test runs from 10 units behind the base to the tip.
- On a hit (not on Hammer or Goron, which do quake and bonk instead) it spawns shield-particle streaks at the contact
  point:
  - wood surface material: the wood version (no light) + `REFLECTION_WOOD`
  - otherwise: the metal version (with light) + `WALL_HIT_HARD` or `_SOFT`
- MM pushes the point 8 units out along the poly normal. A bug writes the z-normal offset into x.
- The player then recoils: speedXZ −14 (or −18 for a bounce off an AC_HARD collider), rumble (180, 20, 100).

**Hit-stop:** when the player's sword registers an AT hit on an actor, `func_80832630` (OoT) or `func_8082DF2C` (MM)
sets `actorCtx.freezeFlashTimer = 1` if it was 0. That is one frame of freeze/flash.

### 2.2 Hit mark: `ovl_Effect_Ss_HitMark` (OoT) / `ovl_Effect_Ss_Hitmark` (MM)
Soft sprite. Spawned by `EffectSsHitMark_SpawnFixedScale`, which uses scale **300**
(`src/code/z_effect_soft_sprite_old_init.c`).
- **Geometry:** a camera-facing billboard (`play->billboardMtxF`). Quad from −11 to +12 units in X and Y, ×(scale/100)
  = ×3, so about **69 units wide**, centred on the hit point. Back-face culled.
- **Texture:** **I4, 32×24**, 8 frames per type. UVs cover the full texture (the 0x300 extent).

  | type | frames | life |
  |---|---|---|
  | WHITE (0) | gEffHitMark1–8 | 8 frames |
  | DUST (1) | 9–16 | **16 frames** |
  | RED (2) | 17–24 | 8 frames |
  | METAL (3) | reuses frames 1–8 (same shapes as WHITE) | 8 frames |

  Shapes:
  - WHITE/METAL: frame 1 is an irregular bright blob. By frame 4 it has burst into a starburst with thin radiating
    rays. Frames 5–7 fade and break up, and frame 8 is empty.
  - DUST: a lumpy cloud puff that expands into a hollow ring and disperses.
  - RED: a dense blob that scatters into speckles.
- **Frame index:**
  - WHITE/RED/METAL: `7 − life` (life counts 7→0), so one texture per frame.
  - DUST: `(15 − life)/2`, so each texture is held for 2 frames.
- **Colours** (the first pair is the start prim/env; the second pair is the target prim/env):

| type | prim start | env start | prim target | env target |
|---|---|---|---|---|
| WHITE | 255,255,255 | 255,255,0 | 255,255,255 | 255,0,0 |
| DUST | 255,200,100 | 200,150,0 | 150,100,0 | 100,50,0 |
| RED | 255,255,255 | 255,0,0 | 255,255,0 | 255,0,0 |
| METAL | 255,255,255 | 0,255,200 | 255,255,255 | 150,0,255 |

  - From the second frame onwards, each frame does `c += (target − c) / (life + 1)`. This is an ease that lands
    exactly on the target on the last frame (`EffectSs_LerpInv`).
  - Prim alpha is 255 and env alpha is 0.
  - Visually: a white core whose fringe goes yellow → red (WHITE), cyan-green → violet (METAL), or
    tan → dark brown (DUST).
- **Combiner/render** (SETUPDL_61):
  - colour = lerp(ENV, PRIM, TEX), so the bright texel core is prim and the dim edges are env
  - alpha = PRIM.a × TEX
  - render mode **G_RM_ZB_CLD_SURF ×2**: z-test, no z-write, alpha blend
  - **G_AD_NOISE**, so alpha is noise-dithered (the N64 "screen-door" sparkle)

### 2.3 Shield particles / impact streaks: `src/code/z_eff_shield_particle.c`
Spawned by `CollisionCheck_SpawnShieldParticles` (metal) and `...Wood` (`z_collision_check.c` OoT ~3487–3570,
MM ~3960–4040). Both inits are identical apart from the light.
- **Count: 16 streaks.**
- **Per streak at spawn:**
  - `initialSpeed = maxInitialSpeed × (0.5 + 0.5·rand)`, with `maxInitialSpeed = 35`, so 17.5–35 units/frame
  - random `yaw` and `pitch` over the full 0–65535 range
  - head position `endX = 0`, tail position `startX = 0`
  - head speed = initialSpeed, tail speed = 0
- **Per frame** (deceleration 2.1, length cutoff 30):
  - Head speed −= 2.1, clamped at ≥ 0, then head += head speed.
  - If the tail is moving: tail speed −= 2.1 (≥ 0), then tail += tail speed.
  - When the tail is still parked and `head − tail > 30`, the tail launches at **initialSpeed** (the original,
    undecayed speed).
  - Result: the streak shoots out with a length of about 30–33 units. The tail then chases about one frame behind,
    so the length stays near the head's current per-frame speed and shrinks steadily. Slow streaks can have their
    tail overtake the head; they then clamp to a minimum-size dot.
  - The fastest streak travels about 200 units in 8 frames.
- **Lifetime:** `duration = 8`. The burst is removed when its timer exceeds 8, so it is drawn about 9 frames.
- **Geometry:**
  - Each streak is a quad ±32 model units, scaled by `(length/64/0.02)·0.02` in X and `0.02` in Y and Z.
  - That makes it **length × 1.28 units**, with a minimum X scale of 1, i.e. 1.28 long.
  - It is translated along its local +X to the midpoint `(head + tail)/2`.
  - Orientation is a rotation about Y by yaw, then about Z by pitch. The streak points in a random 3D direction
    from the hit point.
  - The streaks are **not billboarded**: they are flat cards in their local XY plane, so some read thin or edge-on.
    Culling is off (double-sided).
  - OoT truncates the midpoint and length to s16. MM keeps float.
- **Texture:** `gUnknownCircle6Tex` (MM `gameplay_keep_Tex_054F20`), **I8 32×32**, wrapping. A soft-edged solid white
  disc filling most of the tile; stretched along the streak, it becomes a rounded glowing dash.
- **Colours** (shared by the whole burst; lerp start → mid over the first half, mid → end over the second half;
  halfDuration = 4):

| | start | mid | end |
|---|---|---|---|
| prim (core) | 0,200,255,255 | 255,255,128,255 | 255,64,0,200 |
| env (edge) | 255,255,255,255 | 255,255,0,255 | 255,0,0,255 |

- **Combiner:**
  - colour = lerp(ENV, PRIM, TEX), so the core is prim and the fringe is env
  - alpha = PRIM.a × TEX
  - visually: cyan-hot core with a white rim → yellow → orange core with a red rim, fading slightly at the end
  - 2-cycle; cycle 2 passes through
  - render mode **G_RM_PASS + G_RM_ZB_CLD_SURF2**: z-test, no z-write, alpha blend; no fog or lighting
- **Light:**
  - Metal version (`lightDecay = true`): inserts a **point light, NOGLOW, colour (0,128,255) blue, radius 300** at the
    hit point. The **radius halves every frame** (300, 150, 75 …), giving a one- or two-frame blue flash on nearby
    geometry and actors.
  - Wood version: no light.

### 2.4 Spark ("blood" droplets): `src/code/z_eff_spark.c`
Spawned by the blood functions in `z_collision_check.c`: `CollisionCheck_BlueBlood`, `GreenBlood`,
`SpawnRedBlood` and `SpawnWaterDroplets`. Also spawned directly by a couple of actors (OoT `ovl_En_Skj`,
`ovl_Bg_Spot01_Idohashira`).

**Not used for metal clangs.** In both games, metal hits use the hit mark and shield streaks above.
- **Count:** `uDiv × vDiv + 2` = 5×5+2 = **27** particles (the table holds at most 32).
- **Velocity:** a random vector in the unit cube (each axis in [−0.5, 0.5]), normalised, × `speed` = **8**
  units/frame. Directions are roughly spherical with a slight bias toward the cube corners.
- **Gravity:** −1 unit/frame² on Y, applied after moving. No drag.
- **Lifetime:** `duration = 16`, removed when the timer exceeds 16, so about **17 frames**.
- **Geometry:**
  - Each particle is a **billboard** quad ±32 model units, scaled by `(1.5 + 2.5·rand)/64`. That is **1.5–4.0 units
    across**, **re-randomised every frame**, which gives a flicker or twinkle.
  - The element also has a random spin value that is updated but **never used** when drawing.
- **Texture:** the same soft circle (I8 32×32).
- **Colour:**
  - Four per-corner colours, each lerped start → end by `timer/duration`, so every particle has a slight corner
    gradient.
  - Combiner **G_CC_SHADEDECALA**: RGB = vertex colour, **alpha = texture only**. The vertex alpha in the tables is
    ignored. With alpha blending, the particles fade by darkening, not by turning transparent.
  - Render mode **G_RM_PASS + G_RM_ZB_CLD_SURF2**, culling off.

  | variant | corner 0 start | corners 1–3 start | end (c0, c1 / c2, c3) |
  |---|---|---|---|
  | Blue blood | 10,10,200 | 0,0,128 | 0,0,32 / 0,0,64 |
  | Green blood | 10,200,10 | 0,128,0 | 0,32,0 / 0,64,0 |
  | Red blood | 128,0,64 (c0, c1); 255,128,0 (c2, c3) | | 64,0,32 / 128,0,64 |
  | Water | 255,255,255 | 100,100,100 | 50 grey / 0 |

  Values are identical in MM (`z_collision_check.c` ~1410–1505, ~3860–3900).

---

## 3. Quick reimplementation checklist (Godot)

**Trail:**
- Ring of 16 (tip, base) samples. Push one sample per 20 Hz tick only when the blade moved and the attack state is
  not 0 (that is, from swing frame 0 to `activeEnd`).
- Age +1 per tick; drop the oldest when age > 4. The first draw happens at age 1.
- Vertex colour white. Alpha: tip 255·(1−a/4), base 64·(1−a/4).
- Snap points to integer units if you want the N64 wobble.
- Catmull-Rom/Hermite with 7 subdivisions between samples, except across sharp turns (tip path turn ≥ 120°, or
  tip vs base motion ≥ 45°).
- Unshaded, double-sided, alpha-blended, depth-test on, depth-write off, no texture.

**Hit mark:**
- About 69-unit billboard (3× a 23-unit quad). 8 frames at 20 Hz (16 for dust).
- I4 flipbook: colour = mix(env, prim, tex), alpha = tex, with an alpha dither or noise threshold.
- Prim and env ease toward the targets per the table.

**Metal clang:**
- Hit mark (METAL), plus 16 stretched flat streak cards with the head/tail chase kinematics (speed 17.5–35,
  decel 2.1, cutoff 30).
- Colour start → mid → end over 8 frames (cyan core / white edge → yellow → orange-red).
- Blue point light, radius 300 halving per frame.
- Wood: same streaks, no light.

**Blood:**
- 27 billboard dots, speed 8, gravity −1, 17 frames, size re-randomised 1.5–4 per frame.
- Colour darkens to near black; alpha comes only from the circle texture.
