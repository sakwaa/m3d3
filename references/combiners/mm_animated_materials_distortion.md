# MM / OoT animated scene materials and screen distortion: research notes

Sources (read-only): `~/Downloads/mm` (n64-us decomp, assets under `extracted/n64-us/assets`) and `~/Downloads/oot` (ntsc-1.2).
Paths below are relative to those roots. These notes describe behaviour, formulas and numbers. No code or assets are copied.

---

## 0. Common ground: time base, units, segments

- **Clock.** Everything is driven by `play->gameplayFrames` (MM `src/code/z_play.c:983`, inside `Play_Update`). It goes up by 1 per game update, but only when the game is **not paused** (and debug `IREG(72)==0`). Play runs at a framerate divisor of 3 (`GameState_SetFramerateDivisor(..., 3)`, `src/code/game.c:243`, `z_play.c:736/783/817`), so that is **20 updates/s** on NTSC 60 Hz. The count is frame-based, not time-based. Animations freeze in the pause menu and slow down when the game lags. OoT uses the same counter and the same rate.
- **Scroll units.** `Gfx_TexScroll` / `Gfx_TwoTexScroll` (MM `src/code/z_rcp.c:1383-1412`; OoT `src/code/z_rcp.c:1437+`) build a tiny DL: `gDPTileSync` + `gDPSetTileSize(tile, x, y, x + (w-1)<<2, y + (h-1)<<2)`, once per tile, then `gSPEndDisplayList`. The tile-size coordinates are **10.2 fixed point, so 1 unit = 1/4 texel**. Each offset is first wrapped with `% 2048` (= 512 texels), and texture repeats are power-of-two ≤ 512, so the wrap can't be seen.
  - The offset moves the tile origin (ULS/ULT). The RDP samples `s_tex = s_vertex - ULS`, so increasing ULS moves the image toward **+S** on screen (image right). Increasing ULT moves it toward +T (image "down").
  - The offset is in the tile's texel space **after** the tile's shift (scale) is applied. So in a shader, add the scroll after the per-layer UV scale: `uv_layer = uv * layerScale + offset_in_repeats`, where `offset_in_repeats = quarterTexels / (4 * texSize)`.
  - `width`/`height` passed with the scroll must equal the texture's real size so the tile keeps its proper extent. They don't change the speed.
- **Segments.** A room's display lists contain placeholder calls, `gsSPDisplayList(0x08000000)` … `(0x0D000000)`, placed **after** the material setup (combiner, render mode, both texture loads, prim colour) and before the vertices. Each frame the scene draw config writes `gSPSegment(OPA or XLU list, segId, pointer)` into the frame's display list before the rooms are drawn, so the placeholder runs whatever was generated this frame: a tile-size DL, a prim/env colour DL, or (for texture cycling) a raw texture address used by `gsDPSetTextureImage(0x08000000)`. The default config fills segments 8–0xD and 6 with an empty DL and sets prim/env to (128,128,128,128) (MM `src/code/z_scene_proc.c` `sSceneDrawDefaultDL`). The OPA and XLU display lists each have their own segment state, which is why every write is gated by OPA/XLU flags.

---

## 1. MM animated materials (`src/code/z_scene_proc.c`, structs in `include/z64scene.h:426-458`)

### 1.1 Data structures

| struct | fields | meaning |
|---|---|---|
| `AnimatedMaterial` (8 B) | `s8 segment`, `s16 type`, `void* params` | One entry per animated segment. Target segment = `abs(segment) + 7`, so 1..6 map to **0x08..0x0D**. A **negative** segment marks the **last** entry. `segment == 0` means an empty list. 42 MM scenes have a placeholder `{0, 6, NULL}`; type 6 is never dispatched because the zero segment stops the loop first. |
| `AnimatedMatTexScrollParams` (4 B) | `s8 xStep, s8 yStep, u8 width, u8 height` | Scroll per frame in **quarter texels**, plus the tile size. TwoTexScroll uses an array of **2** (tile 0 then tile 1). |
| `AnimatedMatColorParams` (0x10) | `u16 keyFrameLength` (loop length in frames), `u16 keyFrameCount`, `F3DPrimColor* primColors`, `F3DEnvColor* envColors` (nullable), `u16* keyFrames` (frame numbers, ascending, first = 0, last = length-1) | Colour keyframes. `F3DPrimColor` = r,g,b,a,**lodFrac**. `F3DEnvColor` = r,g,b,a. |
| `AnimatedMatTexCycleParams` (0xC) | `u16 keyFrameLength`, `TexturePtr* textureList`, `u8* textureIndexList` | "GIF" playback: `textureIndexList` has `keyFrameLength` entries (one per frame), each an index into `textureList`. |

Scene header command: `SCENE_CMD_ANIMATED_MATERIAL_LIST(list)` (`include/z64scene.h:860`) loads `play->sceneMaterialAnims`.

### 1.2 Driver: `AnimatedMat_DrawMain(play, list, alphaRatio, step, flags)`

- Stores `alphaRatio`, `step` and `flags` in file statics, then walks the list. For each entry it calls `handler[type](play, abs(seg)+7, params)`, and stops after the entry whose segment is negative.
- Handler table, indexed by type: **0 TexScroll, 1 TwoTexScroll, 2 Color, 3 ColorLerp, 4 ColorNonLinearInterp, 5 TexCycle**.
- `flags`: bit 1 writes the segment into **POLY_OPA**, bit 2 into **POLY_XLU** (3 = both).
- The wrappers differ only in their arguments:
  - `AnimatedMat_Draw` / `DrawOpa` / `DrawXlu`: `alphaRatio = 1`, `step = gameplayFrames`, flags 3/1/2.
  - `DrawAlpha*`: caller's `alphaRatio`, `step = gameplayFrames`.
  - `DrawStep*`: `alphaRatio = 1`, caller's `step`. The actor supplies the frame index, which lets it run, freeze or choose a state.
  - `DrawAlphaStep*`: both from the caller.
- Actor usage in `src/overlays` (call counts): `AnimatedMat_Draw` 93, `DrawXlu` 9, `DrawStep` 9, `DrawStepOpa` 4, `DrawStepXlu` 4, `DrawAlphaStep` 2 (both with ratio 1.0), `DrawOpa` 1. **`DrawAlpha*` with a ratio other than 1 is never used in retail.**
- Examples of a manual step:
  - `Obj_Switch` crystal switch: `crystalAnimTimer`.
  - `Bg_Dy_Yoseizo` Great Fairy appearance: an index that selects a colour.
  - `En_Rz`: step 0 or 1 selects a palette.
  - `Obj_Oshihiki`: its own `textureStep`.

### 1.3 Per-type behaviour

All types use `f = step % keyFrameLength` where a length applies. For scrolls, `step` is used raw and the result wraps at % 2048.

**Type 0, TexScroll** (`AnimatedMat_DrawTexScroll`)
- Emits `Gfx_TexScroll(x = xStep*step, y = -(yStep*step), w, h)` on **tile 0** (render tile).
- **The Y step is negated.** Positive `yStep` moves the image toward −T (up in image space). Positive `xStep` moves it toward +S (right). The data appears to be authored in a +Y-up convention.
- Speed = `step/4` texels per frame = `5*step` texels/s at 20 Hz. A 32-texel texture with step 1 loops in 128 frames (6.4 s).
- **Never used by retail scene or object data** (0 entries found), but supported.

**Type 1, TwoTexScroll** (`AnimatedMat_DrawTwoTexScroll`)
- Same rule as type 0, applied to `params[0]` on **tile 0** and `params[1]` on **tile 1**, emitted as one 5-command DL (`Gfx_TwoTexScroll`).
- A layer with step (0,0) is static, and a layer with size (0,0) is "unused" (e.g. `Z2_SECOM` seg 9 tile 1).
- This is by far the most common type (section 1.5).

**Type 2, Color (stepped, no interpolation)** (`AnimatedMat_DrawColor`)
- Uses `f = step % keyFrameLength`, then `prim = primColors[f]`, `env = envColors ? envColors[f] : none`.
- **`keyFrames` is ignored.** The arrays are indexed per frame, one entry per frame.
- Emits `AnimatedMat_SetColor`, a 3-command DL allocated per segment:
  - `gDPSetPrimColor(0, lodFrac, r, g, b, (u8)(a * alphaRatio))`
  - plus `gDPSetEnvColor(r, g, b, a)` if `env` is present (env alpha is **not** scaled by alphaRatio)
  - plus `gSPEndDisplayList`.
- The prim **lodFrac** is animated too. It matters because the two-layer combiners use `PRIM_LOD_FRAC` as the mix between TEXEL0 and TEXEL1.

**Type 3, ColorLerp (piecewise linear)** (`AnimatedMat_DrawColorLerp`)
- `f = step % keyFrameLength`. Find the first `i ≥ 1` with `f < keyFrames[i]`, scanning `i = 1 .. keyFrameCount-1`.
- `t = (f - keyFrames[i-1]) / (keyFrames[i] - keyFrames[i-1])`.
- Each channel (prim r,g,b,a,lodFrac and env r,g,b,a) = `(s32)((max - min) * t) + min`, i.e. **truncation toward zero** (`AnimatedMat_Lerp`). Here min = colour[i-1] and max = colour[i].
- Quirk: the data puts the last key at `keyFrameLength-1` (e.g. `object_kgy`: length 30, keys 0, 14, 29). On the frame equal to the last key, the search runs past the end of the array (`i == keyFrameCount`) and reads out of bounds for that one frame. For a reimplementation, **hold the last key** on that frame.

**Type 4, ColorNonLinearInterp** (`AnimatedMat_DrawColorNonLinearInterp`, `Scene_LagrangeInterp`)
- **Global Lagrange polynomial** through **all** keyframes, built separately per channel. With n keys the curve has degree n-1, and every key affects the whole curve; it is not a spline and not piecewise.
- `value(f) = Σ_i y_i · Π_{j≠i} (f - x_j)/(x_i - x_j)`, evaluated in f32 with `x_i = keyFrames[i]`, `f = step % keyFrameLength`.
- The result is cast to s32 (truncation), then **clamped to 0..255** (`Scene_LagrangeInterpColor`).
- At most 50 keys (fixed arrays).
- Because it is a polynomial, it can overshoot between keys. That is why authors place doubled "anchor" keys near the ends.
- Example, `Z2_LAST_BS` (Majora's lair floor): length 60, keys {0, 5, 30, 55, 59}. Prim blue goes {0, 0, 50, 0, 0} and env r,g go {0, 0, 100, 0, 0}. The curve is a smooth bell: 0 → 15 (f=12) → 46 (24) → 50 (30) → 45 (36) → 15 (48) → 0. There is a small negative dip near the ends, which the clamp removes. Period 3 s.
- Note that `envColors` is converted from a segmented address before the null check, so the code assumes env is present when used.

**Type 5, TexCycle** (`AnimatedMat_DrawTexCycle`)
- `f = step % keyFrameLength`, `tex = textureList[textureIndexList[f]]`.
- The segment is set to the **texture address itself**, not a DL; the room DL loads its texture from segment 0x08..0x0D.
- One index entry per 20 Hz frame. Repeating an index holds that frame longer.
- Examples:
  - `gameplay_dangeon_keep`: 3 textures, indices 0,1,2 (cycles every frame).
  - `object_gk`: 4 frames.
  - `object_dog`: 17 frames that all point to the same texture.
  - `Z2_SECOM`: 1 texture × 2 frames, a placeholder driven by manual step.

### 1.4 Scene draw configs (MM `Scene_Draw` table, `include/tables/scene_table.h`)

| config | scenes | behaviour |
|---|---|---|
| `SCENE_DRAW_CFG_DEFAULT` (0) | 32 | empty segments, prim/env = 128 grey |
| `SCENE_DRAW_CFG_MAT_ANIM` (1) | 66 | `AnimatedMat_Draw(sceneMaterialAnims)`: `gameplayFrames`, OPA+XLU, alpha 1 |
| `SCENE_DRAW_CFG_NOTHING` (2) | 1 (SPOT00 cutscene map) | nothing |
| 3, 4 | 0 | OoT leftovers (grotto, calm water), unused |
| 5 | 0 | unused: anim mats + an XLU render-mode swap in seg 0x0C + env alpha fade from `roomCtx.unk7A[1]`, skips room drawing at alpha 0 |
| `SCENE_DRAW_CFG_GREAT_BAY_TEMPLE` (6) | Z2_SEA | anim mats + **segment 0x06 = 9 consecutive 2-command DLs**, each `SetPrimColor(lodFrac = 0/68/255, 255,255,255,255)` chosen by switch flags 0x33-0x3A (marks pipes/valves as active), + reverse-conveyor collision flag when switches 0x33-0x36 are all set |
| `SCENE_DRAW_CFG_MAT_ANIM_MANUAL_STEP` (7) | Z2_SECOM (Sakon's Hideout), Z2_MUSICHOUSE | `AnimatedMat_DrawStep(list, roomCtx.unk7A[0])`. The step is written by actors: `Obj_Nozoki` sets it to its conveyor velocity, `En_Pamera` increments it. Animation runs only when gameplay says so. |

### 1.5 Usage survey (my script over `extracted/n64-us/assets`)

**Scenes** (`assets/scenes`, 102 scene files with a list; 207 entries):

| type | entries | scenes |
|---|---|---|
| 0 TexScroll | 0 | 0 |
| 1 TwoTexScroll | 165 | 60 |
| 2 Color | 3 | 3 (`Z2_10YUKIYAMANOMURA2`, `Z2_20SICHITAI2`, `Z2_GORONSHOP`) |
| 3 ColorLerp | 0 | 0 |
| 4 ColorNonLinear | 1 | 1 (`Z2_LAST_BS`) |
| 5 TexCycle | 1 | 1 (`Z2_SECOM`) |
| empty placeholder | 42 | 42 |

**Objects** (`assets/objects`, 88 files, 256 entries): TwoTexScroll 159, Color 18, ColorLerp 7, NonLinear 21, TexCycle 24 (19 objects), placeholders 27. Colour and texture-cycle animation is mostly an **actor** feature. Scene geometry is ~95% two-layer scrolling.

**Scroll step frequencies** across all scene layers (xStep, yStep):

| (xStep, yStep) | count |
|---|---|
| (0, 0) | 55 |
| (0, -1) | 54 |
| (0, 1) | 34 |
| (1, 0) | 31 |
| (-1, 0) | 25 |
| (-1, -1) | 14 |
| (1, 1) | 12 |
| (0, -2) | 12 |
| (0, ±10) | 8 each |
| (1, -1) | 8 |
| (0, 2) | 8 |
| (-1, 1) | 7 |
| (-2, 0) | 5 |
| (0, -8) | 3 |

Larger values exist (up to 10 in scenes, 20 in objects), used for waterfalls.
- So the **typical speed is 1 quarter-texel/frame = 5 texels/s**. On a 32 px texture that loops in 6.4 s.
- Waterfalls use 8–10 quarter-texels/frame (40–50 texels/s) on tall 32×128 I8 textures.

**Texture sizes:**

| size | count |
|---|---|
| 32×32 | 211 |
| 64×64 | 42 |
| 32×64 | 19 |
| 16×64 | 14 |
| 32×128 | 10 |
| 16×16 | 10 |
| 128×32 | 8 |

**The standard MM two-layer material**, seen consistently in rooms (examples: `Z2_MITURIN_room_00`, `Z2_33ZORACITY_room_00`, `Z2_INISIE_N_room_01/04`, `Z2_10YUKIYAMANOMURA2_room_00`):
- Tile 0 (LoadTextureBlock) and tile 1 (LoadMultiBlock) usually hold **the same 32×32 texture** with **different shift/scale per tile**. Example `Z2_MITURIN`: tile 0 shifts S13/T14, tile 1 S14/T15, so the two layers tile at different densities.
- The two tiles scroll in different directions, e.g. Woodfall water: (+1,-1)/(0,-1) and (-1,-1)/(+1,+1).
- Combiner cycle 1: colour = `(TEXEL1 - TEXEL0) * PRIM_LOD_FRAC + TEXEL0` (lerp by lodFrac), and the same for alpha.
- Combiner cycle 2: colour = `COMBINED * SHADE`, alpha = `COMBINED * PRIM.a`.
- Prim colour: lodFrac is typically **0x80** (50/50 mix); 0x4B–0x69 is also seen in Zora Hall. Prim alpha is **~100–160 for XLU water** (e.g. 100, 127, 140, 157, 204) and 255 for opaque animated surfaces.
- Render mode: `G_RM_FOG_SHADE_A` + `G_RM_AA_ZB_XLU_SURF2` for water, `..._OPA_SURF2` for opaque.
- Some materials use the combiner `TEXEL1 * TEXEL0` (multiply) instead of the lerp, e.g. Zora Hall falling water seg 0x0C: an I8 32×128 texture, both layers scrolling at (0,-10).
- Some use `(TEXEL0 - PRIM) * LODFRAC + TEXEL1`-style variants, e.g. Snowhead Temple `Z2_HAKUGIN` seg 8.

**Concrete examples:**

| scene | segment / type | params | what it animates |
|---|---|---|---|
| `Z2_MITURIN` (Woodfall Temple) | seg 8, 9 TwoTexScroll | {(1,-1),(0,-1)}, {(-1,-1),(1,1)}, 32×32 | translucent water: one RGBA16 texture on two tiles, XLU, prim (lodFrac 0x80, α 100) |
| `Z2_33ZORACITY` (Zora Hall) | 6 segments | 32×32 layers at (0,±1) | water surfaces |
| | seg 0x0C | (0,-10)/(0,-10), 32×128 I8 multiply | falling water |
| | seg 0x0B | XLU, α 140 | overlay water |
| `Z2_INISIE_N` (Stone Tower Temple) | seg 10 | (1,0)/(-6,0), 16×64 IA8, XLU, α 157 | streaks; layers at different speeds give a shimmer |
| | seg 8 | — | OPA RGBA tinted (205,180,175) |
| `Z2_KAJIYA` (smithy) | seg 8 | (0,0)/(-1,1), lodFrac 0x19 | an opaque glow/forge surface with a slowly drifting second layer (mostly layer 0) |
| `Z2_10YUKIYAMANOMURA2` (spring Mountain Village) | seg 8, Color | length 2: lodFrac 128 ↔ 255 every frame, no keyframes | a 20 Hz two-texture flicker/sparkle |
| | segs 9–13 | (0,±1), (0,-10)/(0,-7) on 32×128 I8 (waterfall), (0,10) on 64×64 I8 | scroll layers |
| `Z2_GORONSHOP`, `Z2_20SICHITAI2` | seg 8, Color | same lodFrac 155/128 ↔ 255 per-frame toggle | flicker |
| `Z2_LAST_BS` (Majora's lair) | seg 8, NonLinear | 3 s pulse (see type 4) | env tint pulse, layered over seg 9 two-layer I8 64×32 scroll (1,-1)/(1,1) |
| `Z2_SECOM` (Sakon's Hideout) | TexCycle | — | conveyor belt texture |
| | seg 9 | (0,5) single layer | |
| | seg 10 | (-1,0)/(1,0) | |
| | — | manual step from the conveyor actor | conveyors move only when running |

---

## 2. OoT equivalent: code, not data (`src/code/z_scene_table.c`)

OoT has no `AnimatedMaterial` data. Each scene points to a C function, `Scene_DrawConfig*` (about 100 entries in `sSceneDrawConfigs`). Each function writes the same kinds of segment DLs with hand-written arithmetic every frame. Idioms:

**1. Standard water**, used in Calm Water, Gerudo Training Ground, Inside Ganon's Castle, Kokiri Forest seg 9, Fishing Pond, and others:
```
tile0: x = 127 - (f % 128), y = (f*1) % 128     (32x32)
tile1: x = f % 128,         y = (f*1) % 128     (32x32)
```
- Both layers drift +T at 1 quarter-texel/frame, while their S motion is opposite. The result is two crossing diagonal drifts, period 128 frames (6.4 s).
- The `127 - …` form is just a negative scroll written as positive.
- OoT passes y **without** negation; MM's data path negates it.

**2. Faster flows** use the same code with a larger y multiplier:
- Hyrule Field segs 8/9: `y*3` and `y*10`.
- Kokiri Forest seg 8: `y*10`.
- Gerudo Valley: `y*3 % 1024` on 32×256.
- Zora's Fountain: `255 - (f*2) % 256` on 64×64.
- Jabu: `255 - (f*4) % 256` on 32×64.
- Inside Ganon's Castle: `y % 512` on 32×128.
- Bombchu Bowling: single-layer `Gfx_TexScroll`, `(f*5) % 64` on 16×16.

**3. Env/prim colour keyed to game state**, which is the code version of MM's colour types:
- **Water Temple:** `Gfx_TwoTexScrollEnvColor` sets **env alpha** per segment from `roomCtx.drawParams[1]`.
  - The high byte is the water-level state (0..2); the low byte is a transition alpha.
  - Each segment uses 255, 160, 180, 185+…, or `spAC` depending on whether that level is the one fading.
  - Example: seg 0x0A alpha = `160 + (spAC/200)*95`.
  - Scroll x at `f*1` or `f*3`.
- **Lake Hylia:** env alpha = `drawParams[0] + 168`. The parameter is forced to 87 when the lake is drained (adult without the restored flag), giving alpha 255.
  - seg 8: tile 0 scrolls (+f, +f).
  - seg 9: (−f, −f).
  - In both, tile 1 is static 32×32 / 16×64.
- **Fishing Pond:** `Gfx_TwoTexScrollPrimColor`, prim alpha = `drawParams[0] + 127`.
- **Death Mountain Crater lava:** env **R and G pulse**.
  - Formula: `c = (coss(f*1500) >> 8) >> 1 + 192`, giving about 128..255, period 65536/1500 ≈ **43.7 frames ≈ 2.2 s**.
  - Env colour = (c, c, 255, 128) on OPA.
  - Lava texture scroll: `y = f % 128`, both layers 32×32.
- **Fire Temple:**
  - seg 8: layers scroll in +S and +T separately.
  - seg 9: (3, −6)/(6, −3) quarter-texels/frame.
  - Env alpha fixed at **64** on OPA and XLU.
- **Temple of Time:** prim colour fades toward (70,110,150) by `drawParams[0]/255`.
- **Night-only geometry** (Hyrule Field seg 0x0A, Death Mountain Trail seg 8):
  - When the clock is outside 07:00–18:30 (18:00 for DMT), a night DL is drawn with prim alpha `drawParams[0]`.
  - The alpha steps toward 255 by **+5/frame** after dusk and toward 0 by **−10/frame** after 06:00.
- **Day/night texture swaps** (Kakariko windows, entrance textures, Lon Lon windows): `gSPSegment(seg, texture[nightFlag])`. This is OoT's version of MM TexCycle.
- **Default env** after a config: `gDPSetEnvColor(128,128,128,128)` on OPA and XLU, matching MM's default DL.

**4. Jabu-Jabu** (`Scene_DrawConfigJabuJabu`):
- Two-layer scroll on seg 8, 32×64 on seg 0x0B.
- **Wobbling flesh:** a matrix in **seg 0x0D** = `Scale(1, sin(φ)*0.8, 1)`, or 1.005 on X/Z outside room 2. Each frame `φ += 0.15 + drawParams[1]*0.001` rad.
  - `drawParams[1]` is a "pulse" that climbs +200/frame to 1200, then decays −30/frame to 0, set when the room reacts.
- It also drives the **view distortion** (section 3.3).

MM moved (1) and (2) into data (TwoTexScroll), (3) into Color/Lerp/NonLinear keyframes or `DrawStep`, and the texture swaps into TexCycle. The few state-driven cases stayed as code: Great Bay Temple, manual step, and draw config 5.

---

## 3. Screen distortion (projection-matrix warp)

### 3.1 The core maths (identical in both games)

Source: OoT `src/code/z_view.c:210-292`, MM `src/code/z_view.c` (`View_StepDistortion` at line 258). Called from `View_ApplyPerspective` right after `guPerspective` (OoT line 371, MM line 344), **once per frame** for the main view.

**State:**
- target `orientation (rx, ry, rz)` in **radians**
- target `scale (sx, sy, sz)`
- `speed`
- current values `curOrientation` and `curScale`

**API:**
- `View_SetDistortionOrientation`, `View_SetDistortionScale` and `View_SetDistortionSpeed` set the targets.
- `View_InitDistortion` sets identity with `speed = 0` (off).
- `View_ClearDistortion` sets the target to identity with `speed = 1`.

**Each frame:**
1. If `speed == 0`, do nothing; the projection is untouched.
2. If `speed == 1`, snap current to target, then set `speed = 0`. After a clear this applies identity once and then turns off.
3. Otherwise apply an exponential follow, `cur += (target - cur) * speed`, per component (`F32_LERPIMP`).
   - `speed > 1` is allowed and is used by MM attack hits (1.3, 1.5). It **overshoots** and rings around the target.
4. Rebuild the projection:
   `P' = P · Rx(cx) · Ry(cy) · Rz(cz) · S(sx,sy,sz) · Rz(-cz) · Ry(-cy) · Rx(-cx)`
   This is written in column-vector notation. Zelda's `Matrix_*` in APPLY mode multiplies so the new transform acts on the vertex **before** the existing matrix. So the warp `D` sits between the view (look-at) matrix and the projection: `clip = P · D · V · M`.
   - D is a **non-uniform scale in eye space**, along axes rotated by `cur orientation`. It affects every polygon drawn with the play view (rooms and actors).

**What it looks like on screen:**
- With orientation 0, which covers every OoT case and most MM cases:
  - `x_ndc' = (sx/sz) · x_ndc` and `y_ndc' = (sy/sz) · y_ndc`.
  - So it is **an anisotropic zoom about the screen centre**: wider/narrower, taller/shorter. Eye-z scaling also moves depth.
  - Because it is done in the projection, off-screen geometry fills in when the image shrinks, with no edge gaps. A screen-space post effect would need overscan.
- `rz` alone (around the view axis) stays a pure screen-space linear map: the squash axis is rotated by `cz`, giving a swirl or tilted squash.
- `rx`/`ry` rotate the scale axes into depth, which gives a depth-dependent skew (true 3D). MM Song of Time is the only meaningful use.
- **Godot:** set a global `mat4` and apply it in each spatial shader's vertex stage, e.g. `POSITION = PROJECTION_MATRIX * D * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0))`, or by modifying `PROJECTION_MATRIX` when it is writable. A `Camera3D` alone can't express the non-uniform scale.

**Oscillator** shared by all callers (OoT `Camera_UpdateDistortion`, `src/code/z_camera.c:7947`; MM `Distortion_Update`, `src/code/z_quake.c:546`):
```
depthPhase       += DEG_TO_BINANG(depthPhaseStep)         // s16 binary angle, wraps
screenPlanePhase += DEG_TO_BINANG(screenPlanePhaseStep)
orientation = ( cos(depthPhase) * rad(rotX) * fXY,
                sin(depthPhase) * rad(rotY) * fXY,
                sin(screenPlanePhase) * rad(rotZ) * fZ )
scale       = ( 1 + sin(screenPlanePhase) * xScale * fXY,
                1 + cos(screenPlanePhase) * yScale * fXY,
                1 + cos(depthPhase)       * zScale * fZ )
speed       = speed * fSpeed
```
- Initial phases: `depthPhase = 0x3F0`, `screenPlanePhase = 0x156`.
- `DEG_TO_BINANG(d) = (s16)(d * 65535/360 + 0.5)` wraps. So a step of 359.2° is really **−0.81°/frame**, 248° is **−112°**, 170° is 170° and 150° is 150°.
- Steps of 150–170°/frame are close to Nyquist at 20 Hz. sin/cos alternate sign almost every frame (a 2–3 frame period), and the `speed` low-pass turns that into a small shimmer. This is the "heat haze" mechanism.

### 3.2 OoT types (`src/code/z_camera.c`)

Flags (`z_camera.c:195`): `HOT_ROOM` 1, `UNDERWATER_WEAK` 2, `UNDERWATER_MEDIUM` 4 (never set), `UNDERWATER_STRONG` 8, `UNDERWATER_FISHING` 0x10. They are checked in the order MEDIUM, STRONG, WEAK, HOT, and fishing returns early with no change. All rotations are 0 (the code multiplies by 0.0f), so OoT distortion is **pure anisotropic zoom**. The phases are statics that **keep accumulating**.

| type | trigger | depthStep / screenStep (°/frame) | x, y, z scale | speed | factor |
|---|---|---|---|---|---|
| STRONG (water entry) | camera eye enters a water box: `waterDistortionTimer = 80` (z_camera.c ~7858) | 248 (= −112) / −90 | −0.3, 0.3, 0.2 | 0.2 | `timer/80`, a linear fade **1 → 0 over 80 frames (4 s)** |
| WEAK (underwater) | after the entry timer ends, not in the fishing pond | 359.2 (= −0.8) / −18.5 (≈19.5-frame ≈ 1 s period) | 0.09, 0.09, 0.01 | 0.08 × factor | `factor = min((waterY − eyeY)/150, 1) * 0.45 + camera.speedRatio * 0.45`: stronger when deeper and when moving |
| HOT_ROOM | `room.environmentType == ROOM_ENV_HOT` (`Camera_UpdateHotRoom`). Rooms: Death Mountain Crater (spot17), Fire Temple (HIDAN rooms 1, 2, 16 …), Volvagia (FIRE_bs), Ganon's Castle fire trial (ganontika room 14) | 0 / 150 | −0.01, 0.01, 0.01 | 0.6 | 1. About ±1% squash flickering at ~2.4 frames, smoothed |
| FISHING | underwater in the fishing pond | — | — | — | no change |

On leaving the water, `distortionFlags = 0`, which leads to `View_ClearDistortion` (snap to identity, then off).

**Underwater camera shake** (the slow underwater sway), both games:
- Set up in OoT `z_camera.c ~7866` and MM `Play_UpdateWaterCamera`, `src/code/z_play.c:514`.
- A `QUAKE_TYPE_5` request with speed **550**, perturbation y=1, x=1, fov=**180**, roll 0, and duration 1000. It is re-requested when 10 frames are left, so it never ends.
- Type 5 uses offset `= sin_binang(speed * timer)`: a sine with period 65536/550 ≈ **119 frames ≈ 6 s**. It moves eye/at by ±1 unit and FOV by `180 binang ≈ ±0.99°` (`Quake_UpdateShakeInfo`, OoT `z_quake.c:42-84`; FOV added at `z_camera.c:8238`).
- This slow FOV "breathing" plus the projection warp make up the underwater look.

### 3.3 OoT Jabu-Jabu distortion (`Scene_DrawConfigJabuJabu`)

Runs every frame inside the scene draw config (skipped while frame-advance is active). Two phases A and B start at 538 and 4272 and each advance **+1820 binang (10°)/frame**, a **36-frame (1.8 s) period**. With `k = 0.02`:
- Scale: `sx = 1 + 0.016 sin B`, `sy = 1 + 0.008 cos B`, `sz = 1 + 0.02 cos A`.
- Orientation: `binang→rad(1) * k * (cos A, sin A, sin B)`, about 1.9e-6 rad. That is effectively zero, apparently a unit mistake.
- Speed **0.95**.
- So the inside of the belly "breathes" by about ±1.6% horizontally and ±0.8% vertically, with a ±2% zoom, in a loop. The flesh-wall matrix wobble on seg 0x0D comes on top of this.

### 3.4 MM types (`src/code/z_quake.c:501-805`, flags `include/z64quake.h:41-53`)

**How requests work:**
- `Distortion_Request(type)` replaces the current type only if the new value is **larger**. Bit position is the priority; there is only one active type.
- `Distortion_SetDuration(n)` sets `timer = n` and state = SETUP. The first update after that reads `duration = timer` and may reset the phases.
- The timer goes down by 1 each frame. When it reaches 0, the type is cleared. When the type is 0, the view is cleared once (snap to identity, then off).
- "Continuous" types force `timer = 2` every frame, so they last as long as they keep being requested.
- **Important difference from OoT:** several MM branches **reset both phases every frame** (HOT_ROOM, both swimming types, MASK_TRANSFORM_2). The oscillator therefore produces a **constant** target. Any motion comes only from the changing factors and from the speed follow.

Checked from highest priority to lowest. For each: trigger, then the numbers.

1. **MASK_TRANSFORM_2** (1<<11)
   - Trigger: second half of the mask-transformation camera (`z_camera.c ~6193`).
   - Values: continuous, phases reset, screenStep 170. Scale (−0.01, 0.01, 0); factors = 2/60. Speed 0.6.
   - Effect: almost identity, a fast **release** from part 1.

2. **BOSS_WARP** (1<<10)
   - Trigger: boss warp pad, step 3 (`z_camera.c ~6088`), duration **15**.
   - Values: phases reset at setup. screenStep `50/duration` = 3.33°/frame. Scale (0.01, **100**, 0).
   - Factor ramps up linearly: `(duration − timer)/duration`, 0 → 1.
   - Speed 0.4 × 0.5 = 0.2.
   - Effect: a huge vertical stretch (sy up to ~100×) that lags behind the target. It goes with the camera FOV ramping toward 175°: the "sucked into the light" warp.

3. **MASK_TRANSFORM_1** (1<<9)
   - Trigger: mask transformation; duration **26** in one camera and **46** in the other (`z_camera.c ~6167`, `~6327`).
   - Values: setup phases depth 0x1FC, screen 0x156. Steps −5 / +5 °/frame. Rotation (0, 0, **2°**). Scale (0.3, 0.3, 0).
   - Factor ramps 0 → 1 over the duration. Speed **0.1** (heavy lag).
   - Effect: a slow growing ±30% screen squash whose axis rotates by up to 2°.

4. **GORON_BUTT** (1<<8)
   - Trigger: Goron ground-pound/butt attack (`Camera_SetSwordDistortion`, `z_camera.c ~7262`), duration **15**.
   - Values: setup phases 0x2710 / 0x3E8. screenStep 150. Rotation z **0.2°**. Scale (0.025, 0.02, 0.01).
   - Factor is 0 until `timer < 5`, then `(15 − timer)/15` (≈ 0.73 … 0.93 over the last 4 frames).
   - Speed **1.5** (overshoot).
   - Effect: a short punchy ring at the end of the move.

5. **UNK_ATTACK** (1<<7)
   - Trigger: unreachable; duration 5.
   - Values: scale (0.03, 0.02, 0.01), factor `timer/duration`, speed 1.5.

6. **ZORA_KICK** (1<<6)
   - Trigger: Zora punch/kick, or `PLAYER_STATE2_20000` (spin attack per comment); duration **12**.
   - Values: setup phases 0x9C4 / 0xBB8. screenStep 150. Scale (0.03, 0.03, 0.01).
   - Factor is 0 until `timer < 4`, then `timer/12` (0.25 → 0.08).
   - Speed **1.3**.
   - Effect: a hit pulse at the end of the attack.

7. **SONG_OF_TIME** (1<<5)
   - Trigger: `En_Test6` (Song of Time / time-travel effect) with SetDuration 80 or 90, but the branch forces timer 2, so it lasts until `RemoveRequest`.
   - Values: setup phases 0x9C4 / 0xBB8. Each frame depth += 0xB1 + step(−107°), net ≈ **−106°/frame**; screen += −0x2B + step(158°), net ≈ **+157.8°/frame**.
   - Rotation (0.2°, 1.7°, −2.9°) and **large** scale (−0.6, −0.7, 0.6) at full factor. Speed **0.2**.
   - Effect: the strong, wobbly, 3D-skewed "time warp" look. This is the only type with meaningful rx/ry.

8. **UNDERWATER_ENTRY** (1<<4)
   - Trigger: the camera eye enters water (`Play_UpdateWaterCamera`), duration **80**. Also step 2 of the boss warp.
   - Values: setup phases 0x760 / 0x1BC. Steps 248 (−112) / −90. Scale (−0.4, 0.4, 0.2), stronger than OoT's ±0.3.
   - Factor = `timer/80`, a linear fade 1 → 0 over 4 s. Speed 0.25.

9. **ZORA_SWIMMING** (1<<3)
   - Trigger: underwater as Zora (`PLAYER_STATE3_8000`). Also boss warp step 1, duration 60.
   - Values: continuous, phases reset each frame, so the target is constant for a given factor. Steps 359.2 / −18.5. Rotation z 0.3°. Scale (−0.06, 0.1, 0.03).
   - Speed 0.33 on any underwater current (fast/medium/slow conveyor floor), else 0.23.
   - `fXY = (v ± 0x4000)/0xC000`, with the sign of v, where `v = player->unk_B86[1]` (an s16 swim steer/roll value). At rest that is ≈ 0.33, rising to ~1 at |v| = 0x8000. `fZ = −fXY`.
   - At rest: scale ≈ (1.006, 1.032, 0.990).

10. **NON_ZORA_SWIMMING** (1<<2)
    - Trigger: underwater as any other form.
    - Values: continuous, phases reset. Scale (0.12, 0.12, 0.08).
    - Speed by current: fast 0.18, medium 0.12, slow 0.08, none 0.05.
    - `fXY = fSpeed = min((waterY − eyeY)/2000, 1)*0.15 + 0.35 + min(cam.speedRatio,1)*0.4`, and `fZ = 0.9 − fXY`.
    - The resulting static target, e.g. fXY = 0.5, is about (0.983, 1.057, 1.032). The screen gets a little taller/narrower as the camera moves faster or deeper.

11. **HOT_ROOM** (1<<0)
    - Trigger: `ROOM_ENV_HOT`, but the code comment says **no MM room uses it**.
    - Values: continuous, phases reset. screenStep 150. Scale (−0.01, 0.01, 0.01). Speed 0.6.
    - Effect: a **constant** target of about (0.995, 0.991, 1.010). MM's version therefore **does not shimmer**, unlike OoT's.

MM also runs the same underwater `QUAKE_TYPE_5` sway (speed 550, ±1 unit, ±~1° FOV, 6 s period). In MM that sway is the main source of continuous underwater motion.

---

## 4. Implementation notes for the Godot port

- **Time.** Use a 20 Hz integer tick that pauses with gameplay. Compute scroll offsets from it, either stepped or interpolated. Hold the value for the 3 render frames to get the N64 step feel.
- **Scroll.** Per layer: `uv_off = vec2(-xStep, +yStep) * tick / (4.0 * texSize)`, for MM data where y is negated. Apply it after that layer's UV scale.
  - Two-layer water: the same texture at two UV scales, drifting in different directions, `mix(t0, t1, lodFrac/255)`, then × vertex colour, alpha × prim.a/255.
  - Typical values: step ±1, 32 px, lodFrac 128, α ≈ 100–160.
- **Colour types.**
  - Stepped: index by `tick % len`.
  - Lerp: piecewise with integer truncation; hold the last key.
  - NonLinear: global Lagrange, clamped 0..255. It is cheap to bake into a 1D LUT of `len` entries.
- **TexCycle.** Swap textures each tick using an index table, or use an array texture plus an index uniform.
- **Distortion.** Use one global eye-space matrix `D = R · S · R⁻¹` and a follow rate (`cur += (target − cur)*speed` each 20 Hz tick, overshoot allowed). Apply it in the vertex shaders between view and projection.
  - Presets to copy:
    - OoT hot room (shimmer, phases accumulate)
    - OoT/MM water entry (4 s fade)
    - OoT weak underwater (depth/speed driven)
    - MM swimming (static, depth/speed driven)
    - Jabu breathing
    - plus the underwater FOV sway (±1°, 6 s) as a separate camera effect.
