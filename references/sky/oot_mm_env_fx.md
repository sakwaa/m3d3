# OoT / MM environment and screen effects: how they're drawn

Sources (read only): `~/Downloads/oot` (ntsc-1.2 decomp, assets in `extracted/ntsc-1.2/`) and `~/Downloads/mm` (n64-us).
Paths below are relative to each repo root. "OoT" = `oot/`, "MM" = `mm/`.

General conventions that apply throughout:
- Game logic runs at **20 fps** (R_UPDATE_RATE 3). All "per frame" numbers are per 20 Hz game frame.
- Screen is **320x240**. World units: Link is about 50 units tall (1 unit ≈ 1 cm at actor scale 0.01).
- Combiner notation `(a - b) * c + d`. 2-cycle combiners list cycle 1, then cycle 2, which uses `COMBINED` = cycle 1's output.
- Common setup DLs (OoT `src/code/z_rcp.c`, `sSetupDL[]`; MM is the same):
  - **SETUPDL_57**: no texture, `color = PRIM`, `alpha = PRIM_A`, `G_RM_CLD_SURF` (alpha blend, **no Z test, no Z write**), 1-cycle, no alpha dither. Used for every full-screen tint (filters, lightning flash, FillScreen).
  - **SETUPDL_61**: 1-cycle, `color = (PRIM-ENV)*TEX0+ENV`, `alpha = PRIM_A*TEX0`, `G_RM_ZB_CLD_SURF` (Z test, no Z write, alpha blend), noise colour and alpha dither, bilinear.
  - **SETUPDL_64**: 2-cycle, `G_RM_PASS, G_RM_XLU_SURF2`, no Z, no texture by default. Base for the sandstorm.
  - **SETUPDL_44**: 2-cycle, `G_RM_FOG_SHADE_A, G_RM_ZB_OVL_SURF2` (fogged, Z-compared decal/overlay surface, no Z write), Z buffer, fog, no lighting. Used for shadows and footmarks.

---

## 1. Sandstorm — `Environment_DrawSandstorm`

Files: OoT `src/code/z_kankyo.c:2408-2560`, MM `src/code/z_kankyo.c:2715-2941`.
Asset: `gFieldSandstormDL` (OoT `extracted/ntsc-1.2/assets/objects/gameplay_field_keep/gFieldSandstormDL.inc.c`).

### What it draws
One **full-screen `gsSPTextureRectangle`** from (0,0) to (320,240) (`0x500, 0x3C0` in 10.2 fixed point). It's a screen-space overlay, not geometry.
- Pushed to **POLY_XLU** after actors, lens flares and screen fills (OoT `z_play.c:1395-1399`), so it covers the whole world but sits under the HUD.
- Rect texture coordinates: s=t=0 at the top-left. `dsdx = +0x8C`, `dtdy = -0x8C` in s5.10, so **0.1367 texel per pixel**. V is flipped (negative dtdy).

### Textures and tiles (two layers)
| tile | texture | fmt | size | wrap | mask S/T | shift S/T | texels across screen (W x H) |
|---|---|---|---|---|---|---|---|
| 0 (TEXEL0) | `gFieldSandstorm1Tex` | I8 | 64x32 | wrap/wrap | 6/5 | **1 / 0** (S halved) | ≈21.9 x 32.8 |
| 1 (TEXEL1) | `gFieldSandstorm2Tex` | IA8 | 64x32 (TMEM 0x100) | wrap/wrap | 6/5 | **2 / 1** | ≈10.9 x 16.4 |

Both layers are hugely magnified bilinear noise blobs. One texel is about 15 px for tile 0 and 15-29 px for tile 1.

### Combiner and render mode
In the DL:
```
cycle1: color = (TEX1 - TEX0) * PRIM_LOD_FRAC + TEX0   alpha = (TEX1 - TEX0) * ENV_A + TEX0
cycle2: color = (PRIM - ENV) * COMBINED + ENV          alpha = COMBINED * PRIM_A
render: G_RM_PASS, G_RM_CLD_SURF2 (alpha blend, no Z)
```
- `PRIM_LOD_FRAC` = 0x80, so the two colour layers are averaged 50/50.
- `ENV_A` (`sandstormEnvA`) sets which layer's alpha dominates: 128 mixes the two, 255 uses tile 1 only.
- The result is a **2-colour gradient map**: dark noise = env colour, bright noise = prim colour.
- `PRIM_A` (`sandstormPrimA`) is the overall opacity.
- The code also forces `G_AD_NOISE` and `G_CD_NOISE` (noise dither on alpha and colour).

### Alpha state machine (per frame)
Targets `primA1` and `envA1` are chosen by state. The current `primA` and `envA` move toward them **linearly by `step` per frame**, snapping when they're within `step`. Step is 9 in OoT and 9 by default in MM.

| state | primA target | envA target | notes |
|---|---|---|---|
| FILL (1) | 255 | 128 until primA reaches 255, then 255 | Transition into a sand area. The scene change fires when envA == 255 (`z_play.c:921`). |
| UNFILL (2) | 255 while envA > 128, else the breathing value | 128 | Changes to ACTIVE once the breathing target ≥ current primA (and isn't 255). |
| ACTIVE (3), OoT | breathing: `t = frames % 128; if t > 64: t = 128 - t; t += 73` | 128 | **Triangle wave 73→137→73 over 128 frames (6.4 s).** Haunted Wasteland room 0 instead targets primA = (envA > 128 ? 255 : envA/2) with envA → 0, so it fades out. |
| ACTIVE (3), MM | `frames % 128 + 73` (the fold test `> 128` never fires), so a **sawtooth 73..200** | 255 | MM quirk; probably a bug. |
| DISSIPATE (4) | envA > 128 ? 255 : envA >> 1 | 0 (OoT) or unchanged (MM) | Goes to OFF when primA reaches 0. |
| MM 6 / 8 | `D_801F4E30` (strength) | same | step **1** (6) or **10** (8) |
| MM 7 / 9 | 0 | 0 | step 1 or 10; OFF when primA reaches 0 |
| MM A | D_801F4E30 | D_801F4E30 | step 255 (instant); OFF at 0 |
| MM B | OoT-style triangle wave 73..137 | 128 | sand colours |
| MM C | 0 | 0 | sand colours; OFF at 0 |
| MM D | D_801F4E30 | D_801F4E30 | step 10; sand colours |

### Scroll speed (coupled to thickness)
```
k = (512 - (primA + envA)) * 3/128, clamped to ≤ 6
sSandstormScroll (u16) += (int)k each frame
tile0 offset S = scroll * 11/6               (10.2 units = quarter-texels), T = 0
tile1 offset S = scroll *  9/6,  T = 4095 - scroll * 6/6   (T runs backwards)
```
(`Gfx_TwoTexScroll`, OoT `z_rcp.c:1450`, wraps offsets mod 2048.)
- **The thicker the storm, the slower it moves.** When primA + envA = 510, k ≈ 0.05, which truncates to 0, so a fully filled screen stops scrolling.
- Typical ACTIVE values (primA 73-137, envA 128) give k ≈ 5.8-7.3, clamped to 6, so +5..6 per frame.
- At k = 6, per frame:
  - Tile 0 S moves 11 quarter-texels = 2.75 texels, about **40 px/frame** horizontally.
  - Tile 1 moves 2.25 texels in S (about **66 px/frame**) and −1.5 texels in T (about **22 px/frame** vertically).
- The two layers move at different rates in different directions, which creates parallax.
- These are fast: the screen is crossed in under half a second, which gives the "whoosh".

### Colours
The env colour is pulled toward the prim colour as the storm thickens, so a full storm becomes nearly flat:
```
env.rgb = (env.rgb * k + prim.rgb * (6 - k)) / 6        (same k as above)
```
- At k = 6 (thin) env is the table value.
- At k = 0 (fully filled) env equals prim, so the screen is a single colour.

Colour tables, indexed by **time of day** (`sSandstormColorIndex = lightSetting & 3`: 0 dawn, 1 day, 2 dusk, 3 night). They're lerped toward the next index by `sSandstormLerpScale`, the time-of-day blend set in `Environment_UpdateLights` (OoT `z_kankyo.c:1057`, MM `:1360`). If the scene isn't using time-based lighting (`lightMode != LIGHT_MODE_TIME`, or an override is active), index 1 (day) is used.

| idx | prim (OoT; MM sand set) | env (OoT; MM sand set) |
|---|---|---|
| 0 dawn | 210,156,85 | 155,106,35 |
| 1 day | 255,200,100 | 200,150,50 |
| 2 dusk | 225,160,50 | 170,110,0 |
| 3 night | 105,90,40 | 50,40,0 |

MM has **two sets**:
- States < B (including FILL, UNFILL, ACTIVE, DISSIPATE and 5-A) use a **neutral haze** for all four times: prim 255,255,255 and env 100,100,100.
- States ≥ B use the sand set above (`index = 12` offset).

### Where it's triggered
- **OoT**
  - Transition type `TRANS_TYPE_SANDSTORM_PERSIST`, `TRANS_MODE_SANDSTORM_INIT`:
    - Leaving a scene sets FILL. The next scene loads when envA hits 255.
    - Arriving sets UNFILL with primA = envA = 255. The transition ends when primA < 110, then ACTIVE takes over (`z_play.c:895-935`).
  - `TRANS_TYPE_SANDSTORM_END` triggers DISSIPATE (`z_play.c:928`). It's used when leaving the Wasteland (`z_player.c:13723`) and by cutscenes (`z_demo.c:528, 967`).
  - Sun's Song in the Wasteland keeps the storm (`z_parameter.c:4404`).
  - `EnWeatherTag_SetSandstormIntensity` also pulls fogNear −80 and zFar −2000 near the tag (`ovl_En_Weather_Tag/z_en_weather_tag.c:305`).
- **MM**
  - Same transition hooks (`z_play.c:831-863`).
  - Weather tag "wind": state 8/9, strength 0x9B (`z_en_weather_tag.c:195`).
  - Weather tag WATERMURK (Pinnacle Rock / Zora Cape): state 6/7 with strength = 200 × (1 − dist/range), forced to 200 above 0.8 strength, plus fogNear up to −40 (`z_en_weather_tag.c:423-449`).
  - Snowfall haze: `Object_Kankyo`, state A, strength = 155 × snow/128 (`z_object_kankyo.c:345`).
  - Twinmold arena: `Boss_02`, state D (`z_boss_02.c:1323`).
  - So in MM the "sandstorm" is really a **general full-screen haze layer**.

---

## 2. Lightning — bolts, flash and ambient pulse

Files: OoT `z_kankyo.c:1919-2100`, MM `z_kankyo.c:2241-2427`. Global `gLightningStrike` plus `sLightningBolts[3]`.

### Strike scheduler — `Environment_UpdateLightningStrike`
Runs only while `envCtx.lightningState != LIGHTNING_OFF`.

**WAIT state.** Each frame:
```
if rand() < 0.1: delay += 50 (OoT) | 10 (MM)
delay += rand()            // 0..1
if delay > 500: strike
```
- Expected gain per frame: OoT 0.5 + 5 = 5.5, so roughly **every 90 frames (~4.5 s)**, quite random.
- MM: 0.5 + 1 = 1.5, so roughly **every 330 frames (~17 s)**.

**On strike:**
- Flash colour (200, 200, 255), alpha target 200.
- Request `n = (u8)(rand * 2.9) + 1`, so **1-3 bolts**.
- flashAlpha = 0, then go to START.

**START.** Each frame:
- `flashAlpha += 100`
- **ambient light += (80, 80, 100)** (`adjAmbientColor` in OoT, `adjLightSettings.ambientColor` in MM)
- When flashAlpha ≥ 200 (after **2 frames**, peaking at alpha 200 and ambient +160,+160,+200), play the thunder ambience channel and go to END with target 0.

**END.** Each frame:
- `flashAlpha -= 10`, so 200 → 0 in **20 frames (1 s)**.
- Ambient decreases by 10 per channel while positive: R and G (+160) reach 0 in 16 frames, B (+200) in 20.
- At 0: reset ambient to 0 and return to WAIT.
- If `lightningState == LIGHTNING_LAST`, it goes OFF after this strike. That's how storms end: the last flash finishes.

**Flash draw.** While the state isn't WAIT, `Environment_DrawLightningFlash`:
- SETUPDL_57 (alpha blend, **no Z**).
- Full-screen rectangle with PRIM = (200, 200, 255, flashAlpha).
- **Important:** it goes into **POLY_OPA after the skybox and before room/actor geometry** (OoT `z_play.c:1319-1323`; MM via `Environment_Draw` right after `Skybox_Draw`, `z_play.c:1292`). So the **full-screen flash only whitens the sky**; geometry drawn afterwards covers it.
  - The world brightens because of the **ambient boost** (+160/+160/+200 peak, about 1 s decay), not the overlay.
  - Envelope: alpha 0 → 100 → 200 in 2 frames, then −10 per frame.

### Bolts — `Environment_DrawLightning`
There are 3 slots. `AddLightningBolts(n)` sets the first n inactive slots to START.

Per slot, by state:
- **START** (one frame), set up:
  - Horizontal view direction `d = normalize(at.xz - eye.xz)`.
  - `pos = (eye.x + d.x*9500, rand*1000 + 4000, eye.z + d.z*9500)`. Y is an **absolute world height of 4000-5000**, not relative to the camera.
  - `offset = ((rand-0.5)*5000, 0, (rand-0.5)*5000)`, i.e. ±2500 in X and Z.
  - `pitch = (rand-0.5)*40°`, `roll = (rand-0.5)*40°` (±20° tilt).
  - `delayTimer = 3*(slotIndex+1)`, so slots fire at **3, 6, 9 frames**. Multiple bolts are staggered.
- **WAIT**: count the delay down.
- **DRAW**: `textureIndex` goes 0→7, one frame per texture (**8 frames ≈ 0.4 s**), then INACTIVE.

Draw:
- `Translate(pos + offset) · RotX(pitch) · RotZ(roll) · Scale(22, 100, 22)`, then multiplied by the **billboard matrix** (segment 0x01, `D_01000000`), so the quad faces the camera.
- PRIM = (255, 255, 255, 128), ENV = (0, 255, 255, 128).
- SETUPDL_61, then the DL's own combiner:
  `color = (PRIM-ENV)*TEX0 + ENV` (cyan in the dim texels, white in the bright core); `alpha = PRIM_A*TEX0` (**max about 50% opacity**).
- Render mode `ZB_CLD_SURF`: Z-tested so mountains occlude it, no Z write, noise dither.
- Geometry `gEffLightningVtx`: a quad from x = −15..+16 and y = 0..−95 (hangs **down** from the origin). After scaling that's about **680 wide x 9500 tall**, so the bolt reaches from 4000-5000 down to roughly ground level.
- UVs: S 0..64 and T 0..192 texels.
- Textures `gEffLightning1..8Tex`: **I4 32x96**. MM's XML labels them correctly; OoT's XML says i8 16x96 (same bytes), but the DL loads them `_4b 32x96` with no mask. With mask 0 the RDP clamps, so the 32x96 image fills about the **top-left quarter** of the quad, i.e. the visible bolt is about 340 x 4750 units. (Inferred from the RDP clamp rule; worth checking visually.)
  - Frames 1-3: a thick jagged bolt with branches.
  - Frames 4-6: a thinner, more broken bolt.
  - Frames 7-8: scattered sparks fading out.

### Triggers
- **OoT**
  - Song of Storms `EnOkarinaEffect`: lightning ON, then LAST after 400 frames.
  - Weather tags:
    - Kakariko (Cloudy/Rain/Thunder): ON with rain 30.
    - `RainThunder` (in range of the tag): ON with rain 25.
  - All of them set `LIGHTNING_LAST` to stop (`z_en_weather_tag.c:291-334`).
- **MM**
  - `EnTest4` (3-day clock): day 2, 7:00-17:30 rain sets ON with rain 60; it's set to LAST when rain ends (`z_en_test4.c:581-606`).
  - Song of Storms.
- Rain itself is a separate system (`Environment_DrawRain`). Lightning doesn't read rain state; the actors that start rain also start lightning.

---

## 3. Skybox filters — `Environment_DrawSkyboxFilters`

Files: OoT `z_kankyo.c:1882-1917`, MM `z_kankyo.c:2198-2239`.

It draws **full-screen fog-coloured rectangles over the skybox only**. Draw order is skybox → (sun) → filter → room geometry, so the filter becomes the backdrop. It's a cheap way to "fog the sky" in foggy scenes.

**(a) Fog-colour filter**
- Condition: `skyboxId != NONE && fogNear < 980` (or a special skybox, see below).
- `alpha = clamp((1000 - fogNear) * 0.02, 0..1)`
  - fogNear 1000 → 0
  - fogNear 980 → 0.4 (just below 980 the filter starts at about 40%)
  - fogNear ≤ 950 → fully opaque
- PRIM = (fogColor.rgb, 255·alpha), SETUPDL_57 (blended, no Z), into POLY_OPA.
- fogNear here is the scene's 0-1000 fog-near setting (outdoor scenes are typically about 990-996, so no filter).
- OoT `SKYBOX_UNSET_1D` forces alpha 1.
- MM:
  - `SKYBOX_2` (Twinmold) forces alpha 1, i.e. a solid fog-coloured sky.
  - `SKYBOX_3` (cursed / poisoned sky in Ikana and the swamp) instead uses colour **fogColor + 16** (per channel, u8 wrap) with alpha **255 × D_801F4E74**. D_801F4E74 is a 0..1 factor smooth-stepped by `EnWeatherTag` at `Math_SmoothStepToF(…, 0.2, 0.02, 0.001)` per frame (`z_en_weather_tag.c:244-308`).

**(b) Custom filter**
- When `envCtx.customSkyboxFilter` is set, a second rectangle is drawn in `skyboxFilterColor` RGBA.
- OoT uses it once: Ganon (Boss_Ganon2) sets white with alpha = `lightBlend * 200`.
- MM initialises it but nothing sets it.

MM order inside `Environment_Draw` (`z_kankyo.c:3300`): stars slot reserved → sun → lightning flash and bolts → filters. So in MM the fog filter is drawn **over** the lightning flash. OoT order: sun/moon → filters → lightning.

---

## 4. Stars

### MM — `Environment_SetupSkyboxStars`, `Environment_DrawSkyboxStarsImpl`, `Environment_DrawSkyboxStar`
File: `mm/src/code/z_kankyo.c:3095-3330`.

**Enable:** only if `skybox1Index == 0` (clear-sky texture, not cloudy) and `skyboxId == SKYBOX_NORMAL_SKY`.

**Fade factor F** (`D_801F4F28`) by `CURRENT_TIME`:

| time | F |
|---|---|
| 21:00 – 02:00 | 1 |
| 19:00 – 21:00 | ramps 0 → 1 linearly: `1 - (21:00 - t)/(2h)` |
| 02:00 – 03:00 | ramps 1 → 0: `(3:00 - t)/(1h)` |
| otherwise | 0 |

`skyboxConfig 24` forces F = 1.

**Count:** `gSkyboxNumStars` comes from an actor parameter × 100:
- `EnTest4` (the 3-day clock actor in each scene): `(params >> 10) * 100`.
- Or `EnWeatherTag` type SKYBOX_STARS: `((params >> 8) & 0xFF) * 100`.

So scenes choose hundreds of stars. With count 0 or F 0, nothing is drawn.

**Draw timing:** a no-op slot is reserved in POLY_OPA right after the skybox. The real star DL is generated **late in Play_Draw, after the camera update** (`z_play.c:1439`) and patched into that slot, so the stars use this frame's final view-projection.

**Render state:**
- Combiner `color = PRIM * ENV`, `alpha = PRIM_A * ENV_A`. ENV = (255, 255, 255, **255·F**), so the time fade multiplies alpha.
- Other modes: `G_RM_AA_XLU_LINE` (anti-aliased translucent "line" mode: coverage-weighted blending, so sub-pixel stars blend partially), point sampling, `G_ZS_PRIM`, no dither, 1-cycle.

**Each star:**
- Project the world position with VP = projection × view (not a 3D sprite).
- Reject if `w < 1` or NDC is outside (−1, 1).
- `screen = (x*160 + 160, -y*120 + 120)`.
- Draw a **`gSPTextureRectangle` (untextured)** at `xl = x*4`, `yl = y*4` with **width = `imgWidth` quarter-pixels and height = 4 quarter-pixels (1 px)**. Stars are 1 px tall and **0.5-2.5 px wide**; the AA line mode turns fractional coverage into partial alpha.
- No explicit twinkle animation. Shimmer comes only from sub-pixel coverage changing as the camera moves.

**Stars 0-15: a fixed "constellation"**
- Offsets relative to the eye, in world units, e.g. (900, 9000, −11000) and (0, 20000, 19000).
- 16 entries; all are ±several thousand to 20000 units, so they're effectively at infinity because they follow the eye.
- Width 8 quarter-pixels = 2 px.
- Colours cycle through 8 entries: (65,164,255) (131,164,230) (98,205,255) (82,82,255) (123,164,164) (98,205,255) (98,164,230) (**255,90,0**, the orange star, index 7).
- Star 15 is coloured only when `day % 7 == 0`; otherwise it inherits the previous colour.

**Stars 16+: random field**
- Uses a private LCG (the standard `Rand` multiplier and increment) **seeded from the 8-byte player file name** (XORed, shifted). The sky is the same every night but differs per save file.
- For each star:
```
r1, r2 = uniform(0,1); h = (r1 + r2)/2        // triangular distribution peaking at 0.5
angle = next LCG value (s16 binang)
pos.y = eye.y + h² * 16384 - 1000
pos.x = eye.x + sin(angle) * (1.2 - h) * 16384
pos.z = eye.z + cos(angle) * (1.2 - h) * 16384
width = (u32)(r3² * 8 + 2)                    // 2..10 quarter-pixels, mostly small
```
  So stars sit on a dome-like shell. Larger `h` means higher and closer to the zenith; the shell bottom is 1000 units below the eye.
- Colour: at i = 16 and every 64th star, the next of 16 palette entries is set (dim lavender → pink):
  (64,80,112) (96,96,128) (128,112,144) (160,128,160) (192,144,168) (224,160,176) (224,160,176) (104,104,136) (136,120,152) (168,136,168) (200,152,184) (232,168,184) (224,176,184) (240,192,192) (232,184,192) (248,200,192).
  Each block of 64 stars shares one colour.
- Upside-down scenes (Inverted Stone Tower) negate pos.y.

### OoT
OoT has **no procedural star field**. Night skies are just the painted night skybox textures (`vr_fine3/cloud3` …) cross-faded by time. `Environment_DrawSunAndMoon` exists, but there's no star code in `z_kankyo.c`.

---

## 5. MM sky tint by time — `Environment_UpdateSkybox` + `Skybox_Draw`

Files: MM `src/code/z_kankyo.c:1001-1119` (update), `:953-999` (colour tables), `:171+` (time tables); `src/code/z_vr_box_draw.c` (draw).

**Draw combiner** (MM `Skybox_Draw`, 2-cycle, opaque, magic-square colour dither, bilinear, CI8 textures with an RGBA16 TLUT):
```
cycle1: color = (TEX1 - TEX0) * PRIM_A + TEX0     // cross-fade the two sky textures by skyboxBlend
cycle2: color = (PRIM - ENV) * COMBINED + ENV     // per-channel remap: tex 0 → ENV, tex 1 → PRIM
```
- PRIM = (prim.rgb, skyboxBlend) and ENV = (env.rgb, 0).
- This is a **per-channel gradient map / duotone**: `out = env + (prim - env) * tex`. ENV lifts the shadows; PRIM scales the highlights.
- MM's sky textures are already coloured (teal; `skybox_clear_1..5`, `skybox_cloudy_1..5`, 128x64 CI8 each, shared palette `gSkyboxTLUT`), so night is about tex × (70,90,100)/255 plus blue-lifted blacks.
- **OoT's** `Skybox_Draw` uses SETUPDL_40, which is only cycle 1 (`lerp(TEX0, TEX1, PRIM_A)`). There's **no tint**; OoT changes the sky at different times by swapping painted texture sets `vr_fine0..3` / `vr_cloud0..3`.

**Time table (MM `sTimeBasedSkyboxConfigs[config][9]`)**
Each entry is `{start, end, skybox1, skybox2, color1, color2}`, applied to `gSaveContext.skyboxTime` (≈ CURRENT_TIME):
- `colorWeight = LerpWeight(end, start, t) = (t - start)/(end - start)`
- `prim.rgb = lerp(sSkyboxPrimColors[color1], sSkyboxPrimColors[color2], colorWeight)`; same for env.
- Texture blend: `skyboxBlend = colorWeight * 255` when skybox1 ≠ skybox2. If they're equal, it's a hard 255/0 at the midpoint (irrelevant, since both textures are the same).

Config 0 (clear sky; skybox 0 = `d2_fine_static`, 1 = `d2_cloud_static`):

| time | textures | colours (lerped) |
|---|---|---|
| 00:00-04:00 | fine | 3 → 3 (night) |
| 04:00-05:00 | fine → cloud | 3 → 4 |
| 05:00-06:00 | cloud | 4 |
| 06:00-08:00 | fine | 0 → 1 |
| 08:00-16:00 | fine | 1 (day) |
| 16:00-17:00 | fine | 1 → 2 |
| 17:00-18:00 | fine | 2 (sunset) |
| 18:00-19:00 | fine | 2 → 3 |
| 19:00-24:00 | fine | 3 |

Colour entries used by config 0:

| idx | meaning | PRIM | ENV |
|---|---|---|---|
| 0 | morning | 181,100,72 | 102,135,99 |
| 1 | day | 255,255,255 | 0,15,69 |
| 2 | sunset | 255,164,63 | 110,55,110 |
| 3 | night | 70,90,100 | 0,0,100 |
| 4 | pre-dawn | 180,110,70 | 70,10,10 |

Config 1 (cloudy/rain) uses colours 7/8/4/5/6:
- 4: 180,110,70 / 70,10,10
- 5: 140,120,90 / 40,0,10
- 6: 186,107,70 / 40,40,40
- 7: 50,90,120 / 20,20,30
- 8: 160,104,125 / 60,0,10

The table has about 100 entries (others are for Snowhead, Moon, the final-hours red sky, etc.).

**Config changes** (`changeSkyboxState`, e.g. weather changing): `color1` comes from the current config and `color2` from the next config. Weight = `(duration - timer)/duration`, decrementing per frame.

---

## 6. Depth view — MM `src/code/z_viszbuf.c`

**What it is:** a full-screen post filter that **reads the Z-buffer as a texture** and overwrites the framebuffer with colours from it. **Debug only:**
- `GameState_SetFBFilter` (`src/code/game.c:47-70`) runs it when SREG(80) `R_FB_FILTER_TYPE` = 5 (IA) or 6 (RGBA).
- Prim/env come from SREG 81-87.
- No retail code writes those registers. The game never uses it in normal play.

**How it's drawn:**
- Otherwise `G_CYC_1CYCLE`, `G_TF_POINT`, `G_TT_NONE`, `G_RM_OPA_SURF` (replace the pixel), `G_ZS_PRIM`, magic-square colour dither.
- Combiner (both cycles): `color = (PRIM - ENV) * TEX0 + ENV`, alpha the same (ignored).
- Loop over the screen in horizontal strips: `height = 4096 / (cfbWidth*2)` lines (12 lines at 320 wide).
  - `gDPLoadTextureTile` of the Z buffer as **16-bit IA** (type IA) or **RGBA5551** (type RGBA).
  - Then a 1:1 `gSPTextureRectangle` over the same strip (dsdx = dtdy = 1.0).
- Default `VisZBuf_Init`: IA, prim white, env black.

**Why it looks the way it does.** An N64 Z value is 18 bits: 3-bit exponent, 11-bit mantissa, 4-bit dz. The CPU-visible 16 bits are `eee mmmmmmmmmmm dd`.
- The exponent counts leading 1s of the 18-bit linear screen Z, so the encoding is **piecewise-linear, close to logarithmic toward far**.
- Decoder: OoT `Environment_ZBufValToFixedPoint`, `z_kankyo.c:269`, table `{shift, base}` = {6,0}, {5,0x20000}, {4,0x30000}, {3,0x38000}, {2,0x3C000}, {1,0x3E000}, {0,0x3F000}, {0,0x3F800}.
- **IA mode:** I = top 8 bits = `eee mmmmm`.
  - Output = `ENV + (PRIM-ENV) * I/255`. **Near (small Z) → ENV colour, far → PRIM colour.**
  - Monotonic ramp with 8 exponent "octaves", each split into 32 steps. Default: near black → far white.
- **RGBA mode:** R = `eee mm` (5 bits, monotonic); G = next 5 mantissa bits; B = last 4 mantissa bits + 1 dz bit.
  - Each channel goes through the same lerp independently.
  - **R rises monotonically.** **G saw-tooths 32 times per R step** (visible banding). B cycles too fast to read.
  - The result is psychedelic contour bands.
- Where it's used: nowhere in gameplay. It's the dev "Z view" toggle.

To mimic in Godot:
1. Linear screen depth → 18-bit fixed point → (exponent, mantissa) per the table above.
2. Repack as 16 bits.
3. Interpret as I8 (high byte) or RGBA5551.
4. Apply `mix(env, prim, value)`.

---

## 7. Footmarks and tyre marks (MM)

OoT has neither: no `z_eff_footmark` and no tire-mark effect.

### Footmarks — `mm/src/code/z_eff_footmark.c`
**Pool:** `play->footprintInfo[100]` (`z64play.h:57`).

**Spawn:** only from `ActorShadow_DrawFeet` (MM `z_actor.c:262-277`), when all of these hold:
- the foot is ≤ 10 units above the floor,
- the actor isn't underwater (`depthInWater < 0`),
- the floor is scene collision (`BGCHECK_SCENE`),
- the floor's surface has `MATERIAL_PROPERTY_SOFT_IMPRINT` (snow, sand, soft soil),
- the per-foot "step" bit `shape.unk_17` is set. Player sets it on footfall frames of the walk cycle (`z_player.c:10017`) and it's cleared after use, so it's **one mark per step**.

**Add parameters:**
- Floor-aligned matrix at the foot position (from `Play_GetFloorSurfaceImpl`), rotated by actor yaw.
- id = foot index (0/1).
- `size = shadowScale * 0.3`: Link 60 → 18; Goron and Zora 90 → 27; Deku 50 → 15.
- **Colour (80, 60, 40)** (+IREG 88-90 debug offsets, 0 in retail).
- **alpha 30000** (16-bit; drawn as `>>8` = 117).
- **alphaChange 200** per frame.
- **fadeOutDelay 60** frames.

**Add logic:**
- If a mark with the same actor and foot id exists within 1 unit in X and Z, no new mark is added.
- Otherwise every older mark of that actor and foot is flagged "fading" (FLAG_1). A foot's newest mark stays solid until that foot plants again.
- The new mark takes a free slot, or the oldest by `age`.

**Update (per frame), for fading marks:**
- `age++`
- Wait `fadeOutDelay` (60 frames, 3 s).
- Then alpha −= 200 per frame until `alpha < 200 + 0x1000`, then remove.
- That's about **129 frames (6.4 s) of fade, from 117/255 down to about 16/255**, then it pops off. Total lifetime after the next step is about 9.5 s.

**Draw** (`EffFootmark_Draw`):
- SETUPDL_44 in POLY_XLU, so it's **fogged, Z-compared overlay surface, no Z write** (decal-style; no explicit offset — the overlay mode handles the coplanarity).
- `gEffFootprintMaterialDL`:
  - Texture `gameplay_keep_Tex_076C40`: IA16 32x32 **soft round blob**, clamped.
  - Combiner: cycle 1 `color = PRIM`, `alpha = TEX0_A * PRIM_A`; cycle 2 `color = COMBINED * SHADE`, `alpha = COMBINED`.
  - Shade = vertex colour (160, 151, 205), because lighting is off. So the final colour is (80,60,40) × (0.63, 0.59, 0.80) ≈ **(50, 36, 32)**, a dark brown.
- Model: one triangle, the same geometry as the circle shadow: vertices (−128,0,75), (129,0,74), (0,0,−148); the inscribed circle maps to the texture.
- Matrix: stored floor matrix · `Scale(size/256 * 0.7, 1, size/256)`, so the oval is **narrower in X (0.7)** and longer along the facing direction.
  - Link (size 18): scale 0.049 x 0.070.
  - The visible blob is about **5.7 x 8 units** (texture circle ≈ 115 local units × scale).

### Tyre marks — `mm/src/code/z_eff_tire_mark.c`
**Effect instance:** `EffectTireMark { elements[64], numElements, elemDuration, color }`. `elemDuration` is clamped to ≤ 62.

**Users (init `{unk0, duration, colour RGBA}`):**
- Player Goron roll: `{0, 63→62, (0,0,15,100)}`. Goron colour (0,0,15,100); other forms (0,0,0,150) (`z_player.c:11089-11093`).
- Calls: `func_800AE930(pos, halfWidth 15, shape.rot.y, floorPoly, bgId)` while rolling on ground, if the floor is `SOFT_IMPRINT` or a flag is set (`z_player.c:19740`). Otherwise `func_800AEF44` (break the strip).
- Another player state uses half-width 2 (a thin 4-unit line, `z_player.c:19326`).
- `En_Go` (rolling Goron NPCs): half-width 18, 62 frames, (0,0,15,100).
- `Boss_07` (Majora, spinning top and beam): 40 frames, (0,0,15,**200**), half-widths 3 and 15.

**Adding a point** (`func_800AE930`, called **every frame** the mark is laid):
- Two rail points perpendicular to the heading:
  `p2 = pos + (sin(angle-90°), cos(angle-90°)) * halfWidth`, `p1 = pos + (sin(angle+90°), cos(angle+90°)) * halfWidth`.
- Each rail point's Y = the floor plane height at that XZ **+ 2 units** (lift against Z-fighting).
- Stored as s16 (integer world coordinates).
- If the floor poly changed and the two polys share an edge, an **extra element is inserted on the shared edge**: each rail segment is intersected with the edge. The strip folds over creases instead of cutting through or floating.
- Only scene collision (not dynapoly). It breaks when the buffer is full (63) or there's no poly.
- Flags: FLAG_1 on the previous element = "connect to the next". FLAG_2 = strip ended (the next point starts a new strip).

**Update:**
- Every element's `life--` each frame.
- When the oldest reaches 0, the array is shifted down by one.
- So a mark persists **about 62 frames (3.1 s)** and the tail eats the strip from the old end.

**Draw** (`EffectTireMark_Draw`, into **POLY_OPA**):
- Identity model matrix (world-space vertices built each frame).
- SETUPDL_44, then render mode overridden to `G_RM_PASS, G_RM_ZB_CLD_SURF2` (Z test, no Z write, alpha blend), cull off.
- Texture `gameplay_keep_Tex_014570` loaded as **I8 64x32** (MM's XML wrongly calls it rgba32 16x32). Clamp in S, wrap in T.
  The image is a horizontal band: soft across its height (T, the width of the mark) and a **rounded, fading cap at S = 0**, solid toward S = 64.
- Combiner: `color = PRIM`, `alpha = TEX0 * PRIM_A`.
- Each element becomes 2 vertices:
  - p1 has T = 0, p2 has T = 32 texels (across the width).
  - S = 64 texels (solid part) normally; **S = 0 at strip starts and ends**, so the rounded cap texel column is used there.
- For each consecutive connected pair `(i-1, i)`: a quad as 2 triangles (0,1,3)/(0,3,2), with `PRIM = (colour.rgb, colour.a * life_i / elemDuration)`.
  So **per-segment alpha fades linearly with age**: a long tapered trail, opaque near the roller and transparent at the tail.

---

## 8. Actor shadows — `z_actor.c`

Files: OoT `src/code/z_actor.c:79-274`, MM `src/code/z_actor.c:99-341`. Assets in OoT `extracted/ntsc-1.2/assets/objects/gameplay_keep/`.

### Plain blob — `ActorShadow_Draw`, used by Circle / WhiteCircle / Horse / Square (MM)
- Needs `floorPoly`. `dy = pos.y - floorHeight`; draws only when **−50 ≤ dy < 500**.
- `dy` clamped to 0..150; `f = 1 - dy/350`, so **f goes 1 → 0.571 at ≥ 150 units high**, and the shadow vanishes at 500.
  - Alpha = `shadowAlpha * f` (shadowAlpha defaults to 255).
  - Colour black, or white for `DrawWhiteCircle`.
- Matrix:
  - Floor-poly-aligned matrix at (pos.x, floorHeight, pos.z), i.e. tilted to the ground normal.
  - Plus `RotY(shape.rot.y)` for non-circle shapes (MM: also for circles if scale.x ≠ scale.z).
  - Then `Scale(scale.x * shadowScale * f, 1, scale.z * shadowScale * f)`.
- SETUPDL_44 (fogged, ZB **OVL** surface, no Z write), combiner `color = PRIM`, `alpha = TEX0_A * PRIM_A`.
- `gCircleShadowDL`: **one triangle** (−128,0,75), (129,0,74), (0,0,−148) with **IA16 32x32** soft circle `gCircleShadowTex`, clamped. The texture's circle is about **115 local units across** (the inscribed circle).
  - Example: an actor with scale 0.01 and shadowScale 30 gets a shadow about 35 units across.
- Variants:
  - **Horse:** `gHorseShadowTex` (I8).
  - **MM Square:** `gSquareShadowDL`.
  - **MM Circle/Square:** first re-raycast the floor from 50 units up when `BGCHECKFLAG_PLAYER_400` is set.
- The "squiggly" variant doesn't exist in these decomps; the shadow functions are only Draw, Circle, WhiteCircle, Horse, Square (MM), Foot and Feet.

### Feet — `ActorShadow_DrawFeet` (Link and humanoid NPCs)
**Inputs:**
- `shape.feetPos[2]`, filled by `Actor_SetFeetPos` from limb matrices during skeleton draw.
- `shadowScale`: Link 90 adult / 60 child in OoT; MM human 60, Goron/Zora/Fierce Deity 90, Deku 50.
- `scale.x` (0.01).

**1. Airborne blob**
- OoT: if `h = pos.y - floorHeight > 20`. MM: `> 0`.
- Draw the circle shadow with **shadowScale × 0.3** and **alpha × min((h−20)·0.02, 1)**. It fades in from 20 to 70 units of height, then follows the plain blob rules.
- MM: for 0 < h < 20 the ratio is negative, and float → u8 conversion makes it unreliable; clamp it at 0 instead.
- MM Goron curl (`PLAYER_STATE3_8000`): scale × 0.2, alpha × min(h·0.03, 1), and scale.z += 0.03·|cos(roll angle)| (a squashed oval).

**2. Per-foot light shadows** (if h < 200). For each foot:
- Raycast the floor from foot.y + 50 to get the floor height and floor-aligned matrix at the foot.
- `d = foot.y - floor`. Skip unless −1 ≤ d < 500.
- `d = min(d, 30)`.
- `footAlpha = shadowAlpha * (1 - d/30)`: fully gone when the foot is 30 units up.
- `lenBase = 1 - d/70`: shrinks to 0.571.
- `width = shadowScale * scale.x * lenBase`. For Link adult on the ground: 90 × 0.01 = **0.9**.
- "On ground" bit for the foot: OoT d ≤ 0, MM d ≤ 10. This feeds `feetFloorFlag` (which foot is lower, for IK and sfx).

**Lights.** The `Lights` passed in is the per-actor light set built in `Actor_Draw`:
- Point lights within range are turned into **pseudo-directional lights** pointing from the actor to the light: `dir = (light - actor) * 120/dist`.
- Their colour is attenuated by `1 - (dist/radius)²` (OoT `z_lights.c:99`, MM `Lights_BindPointWithReference`).
- The **last 2 entries are the environment's two directional lights.** Light 1 is the sun: `dir = (-sin(t-12h)·120, cos(t-12h)·120, cos(t-12h)·20)`. Light 2 is the moon, the exact negative (OoT `z_kankyo.c:1090-1100`).

Light "strength": `L = (r + g + b) * |dir.y|`, considered only if `dir.y > 0` (light above the horizon).
- **Point lights first** (the first `numLights - 2` entries): if L > 0, draw a foot shadow and add L to `Lsum`.
- **Then the 2 env lights:** `L = (r+g+b)*|dir.y| - 8*Lsum`. Strong nearby torches **suppress the sun/moon shadow**, so an actor gets either torch shadows or a sun shadow, rarely both.

**One foot shadow per qualifying light** (`ActorShadow_DrawFoot`):
- Alpha: `footAlpha * min(L * k, 1)`, with **k = 5e-5 (OoT)** or **1.3e-5 (MM)**.
  - Full sun: 765 × 120 ≈ 91800, saturated in both.
  - Dim lights give fainter shadows; MM needs about 4x more light to saturate.
- Yaw: `atan2(dir.x, dir.z)` (both games; MM spells it `Math_Atan2S_XY(dir.z, dir.x)`). Local +Z points **toward** the light, so the teardrop extends along −Z, **away from the light**.
- Length: `stretch = max(lenBase * (4.5 - dir.y * 0.035), 1)`.
  - dir.y ≥ about 100 (high sun): 1x.
  - dir.y 60: about 2.4x.
  - dir.y 10: about 4.15x.
  - **Low sun gives long shadows**, up to 4.5x.
- `Scale(width, 1, width * stretch)`.
- Geometry `gFootShadowDL`: one triangle (−11,0,4), (12,0,4), (0,0,−35), with **IA16 32x64** teardrop `gFootShadowTex` (dense round end at the foot, tapering tail), clamped.
  For adult Link at noon each foot shadow is about **21 wide x 35 long**, growing to about 140 long at dusk.
- Render: SETUPDL_44 into POLY_OPA (fogged, Z-compared overlay, no Z write). The combiner comes from the DL's caller state. In practice `color = PRIM` (black), `alpha = TEX0_A * PRIM_A`, inherited from the blob setup; `DrawFoot` only sets PRIM.
- Several lights draw several overlapping teardrops per foot, fanning out away from each light. Overlaps darken, because each is a separate alpha-blended draw.

**MM `func_800B4B50`:** the same light loop, but anchored at the actor's root position and floor poly instead of per foot (one fan of shadows per actor). Above 20 units it uses the 0.3-scale blob.

---

## Quick reference for re-implementation (Godot)
- **Sandstorm:** full-screen quad in screen space, two scrolling bilinear noise textures (I8 and IA8, 64x32), magnified about 15-30 px per texel.
  - Colour = `mix(env, prim, avg(t0,t1))`, alpha = `mix(t0a, t1a, envA) * primA`.
  - Scroll speed `min((512 - primA - envA) * 3/128, 6)` quarter-texels per frame, with per-layer factors 11/6, 9/6 and −1.
  - env colour → prim colour as the storm thickens. Time-of-day colour table.
- **Lightning:**
  - Timer accumulates rand plus 10% × 50 (OoT) per frame until > 500.
  - Flash: sky-only full-screen (200,200,255) alpha 0→200 in 2 frames, −10 per frame. **Plus ambient +80/80/100 per frame up, −10 per frame down.**
  - 1-3 billboard bolts 9500 units ahead, top at y 4000-5000, ±2500 jitter, ±20° tilt, staggered 3/6/9 frames, 8-frame I4 flipbook, cyan→white, ≤ 50% alpha, Z-tested.
- **Sky filter:** after the sky and before the world, a full-screen fog colour with alpha `clamp((1000 - fogNear) * 0.02)`.
- **MM stars:**
  - 1 px tall, 0.5-2.5 px wide AA rectangles. 16 fixed (2 px) plus N random on a dome (seeded by the save name).
  - Palette changes every 64 stars. Fade in 19→21, out 2→3. Only on the clear sky.
- **MM sky:** `out = env + (prim - env) * lerp(texA, texB, blend)` per channel, with prim/env lerped between time keys.
- **Z view:** decode the Z buffer as a float-like 3.11 code, take the high byte (IA) or 5:5:5 (RGBA), then `mix(env, prim, code)`.
- **Footmarks:** 100 pool; soft oval 0.7:1. Brown (80,60,40) × vertex (160,151,205), alpha 117. Hold until the same foot steps again, +60 frames, then −0.78/255 per frame for about 129 frames.
- **Tyre marks:** a ribbon of rail pairs (±halfWidth, +2 Y), one per frame, ≤ 64 elements, 62-frame life, per-segment alpha = a × life/62, rounded-cap texture column at the ends, crease-splitting on shared poly edges.
- **Foot shadows:** one teardrop per light with dir.y > 0. Alpha ∝ (r+g+b)·dir.y (saturating). Points away from the light. Length × `max(4.5 - 0.035·dir.y, 1)`. Fades over 30 units of foot height. Env lights suppressed by 8 × the summed point-light strength.
