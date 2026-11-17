# OoT / MM colour-combiner survey (v2: source + extracted assets)

What Ocarina of Time and Majora's Mask set the RDP colour combiner to, collected from the
decompilations, so we can see which recipes are worth reusing as shaders. v1 covered the C source
only. v2 adds every display list in the extracted assets.

**Data:** `combiners_oot_mm.json` (this folder). For each unique combiner it records:
- normalised args per cycle, a readable formula, and gbi `G_CC_*` names;
- `source_uses` and `asset_uses`, kept separate (assets split per game into room, scene, object,
  keep, overlay and other);
- the top asset units (scene or object names) and example DL names;
- asset render-mode pairs and families, texture formats loaded, multi-texture loads and flags;
- the matching project function, if any.

The `setup_dls` table from v1 is unchanged. Combiner ids (`c001`…) are renumbered by total use. The
v1 `cc###` ids are gone.

**Sources:**
- Source: shallow clones of `zeldaret/oot` and `zeldaret/mm` (`src/`, `include/`).
- Assets: the user's local checkouts. OoT is **ntsc-1.2** (`~/Downloads/oot/extracted/ntsc-1.2/assets`).
  MM is **n64-us** (`~/Downloads/mm/extracted/n64-us/assets`).
- Only combiner and render-mode settings, counts and asset names were copied. No textures, vertices
  or colour values.

**Notation:** each cycle is `(A - B) * C + D`.
- T0/T1 = TEXEL0/1, PRIM/ENV = primitive/environment colour, SHADE = vertex colour or lighting.
- COMB = the cycle-1 result.
- `X.a` = that input's alpha. In an alpha formula, PRIM means prim alpha.
- `mix(b, a, c)` = `(a - b) * c + b`.
- "→" separates cycle 1 from cycle 2.
- Arguments are re-encoded through the RDP mux tables, so `0`/`1`/K4 etc. are canonical.
  Commutative products are merged. A setup whose two cycles are identical counts as 1-cycle.

## Counts

| | OoT | MM | total |
|---|---|---|---|
| combiner calls in C source (`src/`) | 226 | 347 | 573 |
| combiner commands in asset DLs | **8,863** | **10,205** | 19,068 |
| …room geometry | 4,185 | 5,257 | |
| …scene-file geometry | 120 | 0 | |
| …object models (actors, NPCs, Link, items) | 4,287 | 4,647 | |
| …gameplay_keep / field_keep / dangeon_keep | 157 | 253 | |
| …overlay-embedded DLs | 78 | 45 | |
| …other (code/misc/textures assets) | 36 | 3 | |
| unique combiners in assets | 211 | 313 | 394 |
| unique combiners overall (source ∪ assets) | 244 | 354 | **437** |

- 372 of the 437 appear only in assets, 43 only in source and 22 in both.
- 403 of the 437 are two-cycle.
- The source holds **3%** of all combiner commands. The v1 estimate ("≤5%, low hundreds unique") holds.

**The real structure is "base × tint".** In asset DLs the 2-cycle split is very regular:

| cycle 1 rgb (base) | share | cycle 2 rgb (tint) | share |
|---|---|---|---|
| `SHADE * T0` | 71% | `COMB * PRIM` | 70% |
| `mix(T0, T1, PRIM_LOD_FRAC)` | 5% | `COMB * SHADE` | 17% |
| `mix(T0, T1, ENV.a)` | 4% | `COMB` (pass) | 8% |
| `T0 * T1` | 4% | `COMB * ENV` | 2% |
| `PRIM * T0` | 4% | `mix(ENV, PRIM, COMB)` (ramp) | 2% |
| `PRIM * SHADE` | 4% | everything else | 1% |
| `mix(ENV, PRIM, T0)` | 3% | | |
| everything else | 5% | | |

Seven cycle-1 forms cover 95% of asset materials, and five cycle-2 forms cover 99%. Alpha follows the
same pattern:
- cycle 1 alpha: `T0` 53%, `1` 26%, `mix(T0,T1,PRIM_LOD_FRAC)` 8%, `PRIM*T0` 4%;
- cycle 2 alpha: `COMB` 81%, `COMB*PRIM` 11%, `COMB*ENV` 3%.

So a single material could cover almost everything with three enum choices: "cycle-1 base"
(7 choices), "cycle-2 tint" (5 choices) and "alpha source".

Fog sits on top: 90%+ of level and model materials use `G_RM_FOG_SHADE_A` in blender cycle 1,
which is why they are 2-cycle at all.

## Top setups (source + assets)

"setup-DL" counts calls to `Gfx_SetupDL_*` helpers that land on a setup DL with this combiner
(source only). Render-mode families come from the assets:
- `fog·opa` = `G_RM_FOG_SHADE_A, G_RM_AA_ZB_OPA_SURF2`
- `fog·cutout` = `…AA_ZB_TEX_EDGE2`
- `fog·xlu` = `…AA_ZB_XLU_SURF2` or `ZB_XLU_SURF2`
- `xlu-decal` = `…AA_ZB_XLU_DECAL2`
- `cld` = `ZB_CLD_SURF2` (no AA, additive-ish cloud surface)

| id | formula | source OoT/MM (setup-DL) | assets OoT / MM | where | render modes |
|---|---|---|---|---|---|
| c001 | `SHADE*T0 / a T0 → COMB*PRIM / a COMB` | — | 2,278 / **6,076** | MM rooms 3,368, objects; OoT objects 1,442 | fog·opa 70%, fog·cutout 24%, fog·xlu 4% |
| c002 | `SHADE*T0 / a 1 → COMB*PRIM / a COMB` | — | **2,944** / 239 | **OoT rooms 2,051** (opaque level geometry), objects | fog·opa 79%, fog·cutout 20% |
| c003 | `SHADE*T0 / a T0 → COMB*PRIM / a COMB*PRIM` | 3/6 (**1,339**, SETUPDL_25) | 96 / 26 | the engine's default actor setup | fog·opa 91% |
| c004 | `T0*T1 / a mix(T0,T1,PRIM_LOD_FRAC) → COMB*SHADE / a COMB*PRIM` | — | 0 / **656** | **MM rooms 627**: Pirates' Fortress, Beneath the Graveyard, Ikana, Great Bay coast… | fog·opa 86%, fog·xlu 5% |
| c005 | `mix(T0,T1,PRIM_LOD_FRAC)` (both) `→ COMB*SHADE / a COMB*PRIM` | — | 0 / **647** | **MM rooms 551**: grottos, Great Bay, Termina Field, Southern Swamp, Fairy Fountain… | fog·opa 77%, fog·xlu 20% |
| c006 | `PRIM*SHADE / a 1 → pass` | — | 599 / 37 | OoT rooms 476 (untextured, vertex-coloured) | fog·opa 93% |
| c007 | `mix(T0,T1,ENV.a) / a 1 → COMB*SHADE / a COMB` | — | **563** / 10 | **OoT rooms 506**: Water Temple 149, Shadow Temple 73, Bottom of the Well 36, Ice Cavern, Zora's Domain, Hyrule Field; Volvagia | fog·opa 92% |
| c008 | `SHADE*T0 / a T0 → COMB*PRIM / a COMB*ENV` | 0/1 | 199 / 258 | objects (NPCs) | fog·opa 83%, fog·cutout 14% |
| c009 | `PRIM*T0` | 47/86 (118) | 1 / 1 | HUD, pause, text (`G_CC_MODULATEIA_PRIM`) | xlu / threshold |
| c010 | `SHADE*T0 / a T0 → COMB*ENV / a COMB` | — | 156 / 97 | **Link's tunic-coloured parts** (OoT hat, collar, body); NPC tints | fog·opa 88% |
| c011 | `PRIM*T0 / a T0 → COMB*SHADE / a COMB` | — | 0 / 175 | MM rooms (prim-tinted foliage/cutouts), MM Link hat/collar | fog·cutout 50% |
| c012 | `mix(ENV,PRIM,T0) / a PRIM*T0` (1-cycle) | 37/62 (38) | 17 / 11 | effects: fire, explosions, smoke, sparks (SETUPDL_60/61) | inherits setup DL / cld |
| c013 | `SHADE*T0 / a ENV*T0 → COMB*PRIM / a COMB` | — | 51 / 101 | objects: env-alpha fades | fog·opa 94% |
| c014 | `mix(ENV,PRIM,T0) / a T0 → COMB*SHADE / a COMB` | — | 45 / 93 | lit two-colour ramp on an I texture (often texgen: reflective trims) | opa / fog·opa |
| c015 | `SHADE*T0 / a ENV → COMB*PRIM / a COMB` | — | 122 / 13 | objects | fog·opa 77% |
| c016 | `SHADE*T0 / a PRIM*T0 → COMB*PRIM / a PRIM_LOD_FRAC*T1 + COMB` | 1/0 | 130 / 0 | **OoT translucent room surfaces**: Forest Temple, grottos, Deku Tree, Ganon's Castle, Goron City | fog·xlu 79% |
| c017 | `PRIM*T0 / a PRIM*T0 → COMB*SHADE / a PRIM_LOD_FRAC*T1 + COMB` | — | 81 / 29 | butterflies, bugs, boulder fragments, fish | custom `ZMODE_INTER` + `CVG_X_ALPHA` |
| c018 | `PRIM*T0 / a PRIM → COMB*SHADE / a COMB` | — | 0 / 103 | MM rooms and objects | fog·opa 89% |
| c019 | `mix(ENV,PRIM,T0) / a PRIM*T0 → pass` | 3/2 | 32 / 43 | effects and magic (SETUPDL_0) | cld 32%, xlu 21% |
| c022 | `mix(ENV,PRIM,T0) / a 1 → COMB*SHADE / a 1` | — | 64 / 27 | objects | cutout, no fog |
| c024 | `SHADE*T0 / a T0 → COMB*PRIM / a ENV*LOD_FRAC` | — | 44 / 39 | **Zora** and Ruto bodies | fog·opa 100% |
| c032 | `mix(T0,T1,ENV.a) / a 1 → COMB*SHADE / a COMB*PRIM` | — | 66 / 0 | **OoT translucent water**: Lake Hylia high/low water, Kakariko well water, Colossus oasis, Zora's Domain/River | fog·xlu 94% |
| c043 | `(T1-PRIM)*PRIM_LOD_FRAC + T0 / a (T1-1)*PRIM_LOD_FRAC + T0 → mix(ENV,PRIM,COMB) / a COMB*PRIM` | 1/2 | 25 / 18 | Poe souls, Goddess aura, title flames | xlu / cld, no fog |
| c052/c053/c091/c125 | `(T0-PRIM)*k + T0 → mix(ENV,PRIM,COMB)` | — | 70+ | **shiny get-items**: Boss Key, Skulltula token, Mask of Truth, rupee, scale, song note, warp crystal | 89% use `G_TEXTURE_GEN` |
| c057 | `(SHADE-ENV)*PRIM + T0 / a PRIM*T0 → COMB*SHADE` | — | 0 / 26 | **MM swords**: Razor, Gilded, Great Fairy's | all `G_TEXTURE_GEN` + I8 |
| c064 | `(T1-PRIM)*ENV.a + T0 / a (T1-1)*ENV + T0 → mix(ENV,PRIM,COMB) / a COMB*PRIM` | — | 22 | **Fire/Ice/Light Arrows, spin attack**, Ganondorf magic | `PASS, ZB_CLD_SURF2` |

The full list (437 entries, each with examples) is in the JSON.

## Level geometry

**OoT rooms: one texture, lit, ×PRIM.**
- Of 4,305 room and scene materials, `SHADE*T0` is cycle 1 in 72%, `mix(T0,T1,ENV.a)` in 14% and
  `PRIM*SHADE` (untextured) in 12%. Cycle 2 is almost always `COMB*PRIM`, `COMB*SHADE` or pass.
- Opaque rooms mostly have alpha = 1 (c002). Cutouts take their alpha from T0 (c001).

**OoT two-texture blends:** `mix(T0, T1, ENV.a)` (c007, c032, c058, c063, c102 …).
- Two textures are cross-faded by **environment alpha**. In practice the scene's animated material
  scrolls T0 and T1 at different speeds and drives ENV, so this is the OoT "two scrolling layers"
  look.
- Used for:
  - **water:** Water Temple 149 opaque + 10 translucent; Lake Hylia, Kakariko well and Colossus
    oasis water objects; Zora's River and Domain;
  - **shadow and ice:** Shadow Temple, Bottom of the Well, Ice Cavern, Castle courtyard;
  - **Volvagia's** body.
- Opaque surfaces use `fog·opa`. Water surfaces use `fog·xlu`, with alpha from `COMB*PRIM`
  (prim alpha = water opacity).

**OoT lava, poison and colour cycling.**
- Death Mountain Crater and Fire Temple lava are mostly single-texture `SHADE*T0 → COMB*ENV`
  (c010-like, `spot17` 12 materials). The lava colour comes from **ENV, which the scene's animated
  material keys over time** (colour cycling), not from a special combiner.
- Fire Temple has 11 `mix(T0,T1,ENV.a)` materials (two-layer lava).

**OoT translucent room surfaces:** c016, alpha `PRIM_LOD_FRAC * T1 + COMB` in cycle 2, 113 room
uses (Forest Temple, grottos, Deku Tree, Ganon's Castle, Goron City, Spirit Temple).
- Because of the 2-cycle texel quirk, cycle-2 `TEXEL1` reads the *neighbouring pixel's* T0. These
  materials thicken or extend alpha with it, scaled by lod-frac.
- Treat as "alpha + k·alpha", an additive clamp. The exact intent is unclear.

**MM rooms: multitexture everywhere.** Of 5,257 room materials:
- `SHADE*T0`: 66%;
- **`mix(T0, T1, PRIM_LOD_FRAC)`: 14%**, two textures cross-faded by a per-material constant;
- **`T0 * T1`: 14%**, an RGBA16 base × an I-format detail or light/shadow texture;
- `PRIM*T0`: 5%;
- **true `LOD_FRACTION` mip blends: 33** (see below).

MM's terrain look is the base texture × an I detail/shading texture, or a fixed blend between two
textures, then ×SHADE, with alpha = mix of both textures × PRIM.
- Great Bay sea, Southern Swamp and Woodfall water use the same `mix(T0,T1,PRIM_LOD_FRAC)` with
  `fog·xlu` and `COMB*PRIM` or `COMB*ENV` alpha. There is no special water combiner. The motion
  comes from texture scrolling.
- Snowhead Temple uses `(T1-T0)*PRIM_LOD_FRAC + PRIM → COMB*SHADE + SHADE`, an additive
  brightening (ice glow).

**Sky.** Neither game has sky DLs in its assets. The sky is drawn by code:
- OoT `SETUPDL_40`, c162: `mix(T0,T1,PRIM.a)`, a cross-fade of two time-of-day textures.
- MM `Skybox_Draw`, c301: the same cross-fade → `mix(ENV,PRIM,COMB)`, which tints the sky through a
  per-time colour ramp.
- Assets only add effect props:
  - Death Mountain cloud ring (`object_efc_doughnut`): signed-detail fiery version, or
    `SHADE*T0 → COMB*PRIM / a COMB*ENV`;
  - star field (`object_efc_star_field`): `mix(ENV,PRIM,T0)`, `ZB_CLD_SURF`;
  - the `gFieldSandstormDL` sandstorm: `mix(T0,T1,PRIM_LOD_FRAC) → mix(ENV,PRIM,COMB)`, `CLD_SURF2`.

## Character and object materials

**OoT Link** (`object_link_boy` 176, `object_link_child` 118):
- skin, gear and limbs: `SHADE*T0 → COMB*PRIM`, with alpha T0 or 1;
- **tunic, hat and collar: `SHADE*T0 → COMB*ENV`** (c010, 22 + 8 adult, 18 child). The tunic colour
  (Kokiri, Goron, Zora) is the environment colour multiplying a lit greyscale-ish texture;
- untextured parts: `PRIM*SHADE`.
- This recipe exists already: `n64_cc_modulate_i_decal_a`, then ×ENV.

**MM Link forms:**
- Human: hat, collar and head are `PRIM*T0 → COMB*SHADE`, a **prim tint before lighting**.
- Several Human DLs, and the Razor, Gilded and Great Fairy's swords, use
  `(SHADE - ENV) * PRIM + T0` → `COMB*SHADE` (c057).
  - The texture is I8, with `G_TEXTURE_GEN` (sphere-mapped).
  - The lighting minus ENV, scaled by PRIM, is *added* to the reflection texture.
  - Result: a **metal / specular sword** that brightens with light. It can overflow past 1.
- Goron Link: `(PRIM - SHADE) * ENV + T0` collar; a signed-detail glow on the rolling spikes.
- Zora Link: the fin blades use signed detail → ramp, `ZB_XLU_SURF2` (electric barrier).

**NPCs and enemies.**
- Mostly c001/c003 (`SHADE*T0 → COMB*PRIM`), plus ×ENV variants:
  - c008 alpha ×ENV;
  - c013 alpha `ENV*T0`, used for fade-outs.
- **Zora / Ruto bodies** (c024): alpha `ENV * LOD_FRAC`. In the alpha C slot, "COMBINED" and
  "LOD_FRACTION" share encoding 0, so the source tool most likely meant `ENV * COMB.a`. These
  materials are opaque, so it is harmless.

**Shiny pickups** (c052/c053/c091/c125/c166): `(T0 - PRIM) * PRIM_LOD_FRAC + T0`, then
`mix(ENV, PRIM, COMB)`.
- 70 of the 79 uses have `G_TEXTURE_GEN` and an I8 texture.
- What it does: contrast-boost an env-mapped I8 reflection around a PRIM pivot, then map it onto an
  ENV (dark) → PRIM (bright) colour ramp. Gold, silver and blue get-items, Skulltula tokens, the
  Boss Key and rupees are the same recipe with different prim/env.

**Reflective two-colour trims:** `mix(ENV, PRIM, T0)` with `G_TEXTURE_GEN` (245 of 513 uses).

## Din's Fire, arrows, ocarina songs, warps

All of these, across both games, use one recipe family, **signed detail → colour ramp**:

```
cycle 1 rgb : (T1 - PRIM) * k + T0        k = ENV.a or PRIM_LOD_FRAC (scroll the two textures differently)
cycle 1 a   : (T1 - 1) * k + T0           = T0 - k*(1 - T1): T1 *erodes* T0's alpha (holes and wisps; clamps below 0)
              or mix(T0, T1, k) / k*T1 + T0 (variants)
cycle 2 rgb : mix(ENV, PRIM, COMB)        intensity → ENV (dark) .. PRIM (bright) ramp
cycle 2 a   : COMB * PRIM  or COMB * SHADE (vertex alpha fades the mesh edges)
render mode : G_RM_PASS + AA_ZB_XLU_SURF2 / ZB_CLD_SURF2 (no fog), I8 textures
```

| effect | asset | k |
|---|---|---|
| Din's Fire | `ovl_Magic_Fire sMaterialDL` | PRIM_LOD_FRAC |
| Farore's Wind | `ovl_Magic_Wind` inner/outer cylinders | PRIM_LOD_FRAC (alpha = mix) |
| Nayru's Love | `ovl_Magic_Dark sDiamondMaterialDL` | ENV.a |
| Fire / Ice / Light Arrows (both games) | `ovl_Arrow_* sMaterialDL` / `g*ArrowMaterialDL` | ENV.a (Ice uses an additive alpha `ENV*T1 + T0`) |
| Spin attack / Great Spin | `gameplay_keep gSpinAttack*` | ENV.a |
| Song of Time, Epona's, Saria's, Sun's (OoT `Oceff_Wipe*`, `Oceff_Spot`) | | ENV.a |
| MM Song of Healing, Oceff5/6 | | PRIM_LOD_FRAC |
| Song of Storms | `Oceff_Storm` | lerp form `mix(T0,T1,k)` → ramp |
| Blue warp / boss warp | `object_warp1` beams, shafts, glow | PRIM_LOD_FRAC. Warp **crystal** uses the contrast form `(T0-PRIM)*k + T0`. Portal uses **true LOD_FRACTION** |
| Time warp | `object_efc_tw gTimeWarpDL` | PRIM_LOD_FRAC |
| Volcano eruption, creation fireball, Goddess light | `object_efc_*`, `object_god_lgt` | PRIM_LOD_FRAC |
| Ganondorf magic, shock, vortex; Ganon fire ring and Zelda's magic | `ovl_Boss_Ganon(2)` | ENV.a |
| Twinrova fire/ice pools, Wizrobe pools | `object_tw`, `object_wiz` | ENV.a, with A/D roles of T0/T1 swapped |

- Simpler effects stay on the 1-cycle ramp `mix(ENV, PRIM, T0) / a PRIM*T0`: bomb explosions,
  sparks, bubbles, lightning, fire footprints, Navi, stray fairies.
- Shadows stay on `PRIM / a PRIM*T0` with `ZB_OVL_SURF2`.

There are 48 unique "signed → ramp" setups (261 asset uses), 24 "lerp → ramp" (72) and 20 other
"→ ramp" (70). **This is the most valuable missing recipe.**

## LOD_FRACTION, NOISE, chroma key and overflow

**True `LOD_FRACTION`** (the RDP's own mip blend, colour C slot): 33 MM room materials plus 6 objects.
- The usual form is `mix(T0, T1, LOD_FRAC)` → `COMB*SHADE`.
- MM rooms: Clock Tower, Great Bay coast, Termina Field, Deku Palace, Woodfall exterior, East Clock
  Town, Pirates' Fortress, grottos, Southern Swamp, Milk Bar, fisherman's hut.
- Also: OoT Spirit Temple illusion room, blue warp portal, a heart container, MM Ikana cave fog
  (`(ENV - PRIM) * LOD_FRAC + COMB`, a **distance-faded fog colour add**).
- OoT level geometry never uses it. That is the case for our existing `n64_cc_trilerp`.

**NOISE** (10 uniques, 10 uses, all effects):
- Poe bottle contents: `NOISE*PRIM_LOD_FRAC + T0` → ramp, sparkle added to a texture.
- Bongo Bongo body static and shadow (`ovl_Boss_Sst`), Dark Link shadow (`Demo_Shd`):
  `mix(ENV, NOISE, PRIM)`, **TV static between ENV and noise, amount = PRIM**.
- Ganondorf's big-magic background circle: `(NOISE - T0) * ENV.a + PRIM`, then
  `1 - PRIM * COMB`, a **noise-perturbed inverse**.
- Trial barrier floor: `NOISE*T1 + T0` → ramp.
- Tailpasaran: `NOISE*PRIM + T0`, electric crackle.
- MM alien eye beam: `NOISE * PRIM`.
- MM `object_open_obj`: `NOISE * PRIM`.
- Unused SETUPDL_29: `T0*SHADE → COMB*NOISE`.

**CENTER/SCALE (chroma-key inputs):** one unused Twinrova ice-steam cloud.

**Overflow and range tricks** (asset uses):
- 444 uses of colour non-lerp `(A-B)*C+D`, nearly all the signed-detail and contrast recipes. These
  rely on the 9-bit headroom. `(T1-PRIM)*k + T0` routinely exceeds 1 and drops below 0.
- 409 uses of additive alpha.
- 102 uses of additive colour (MM arrow glow, Snowhead, `COMB*SHADE + ENV`).
- **Alpha erosion** `(T1 - 1) * k + T0` relies on negative values clamping to 0. Every arrow and
  ocarina effect uses it.
- True **subtract-from-0** appears only twice:
  - Ganondorf's magic circle, `1 - PRIM*COMB`;
  - MM horse-game checkpoint, `-T0*k + COMB`.
- Neither game builds a look on 9-bit *wrap-around*. They rely on clamping.

**Two-cycle texel quirk.** In cycle 2, TEXEL0 reads tile+1 and TEXEL1 reads the next pixel's T0.
- 33 uniques (380 uses) put texel inputs in cycle 2.
- Mostly the alpha `PRIM_LOD_FRAC * T1 + COMB` (c016/c017: OoT translucent room surfaces and the
  `ZMODE_INTER` bugs and butterflies).

## Render-mode pairings

Asset render-mode pairs: OoT 8,863, MM 10,205.

| pair | OoT | MM | used with |
|---|---|---|---|
| `FOG_SHADE_A, AA_ZB_OPA_SURF2` | 6,241 | 6,705 | all opaque lit materials (c001–c008, c010, c018) |
| `FOG_SHADE_A, AA_ZB_TEX_EDGE2` | 1,423 | 1,912 | cutouts: foliage, fences, grates (c001/c002 with T0 alpha; alpha-compare via coverage) |
| `FOG_SHADE_A, AA_ZB_XLU_SURF2` / `ZB_XLU_SURF2` | 432 / — | 253 / 338 | water (c032, c005-xlu), glass, ghosts (c016, c023, c028) |
| `FOG_SHADE_A, AA_ZB_XLU_DECAL2` | 24 | 288 | MM's many decals (puddles, stains, road markings; c038, c042, c059) |
| `PASS, AA_ZB_XLU_SURF2` | 211 | 92 | **un-fogged magic and effects** (signed → ramp family) |
| `PASS, ZB_CLD_SURF2` | 37 | 46 | arrows, spin attack, explosions, sparks (no AA, cheap) |
| custom `ZMODE_INTER + CVG_X_ALPHA + ALPHA_CVG_SEL` | 115 | ~ | small fluttery props (c017: butterflies, bugs, fish, fragments) |
| `PASS, AA_ZB_TEX_EDGE2 / OPA_SURF2` | 113 / 56 | 156 / 146 | un-fogged cutouts and opaque (UI-ish props, fairies) |
| `PASS, ZB_OVL_SURF2` | few | few | blob shadows, ground flashes |

Rules of thumb from the data:
- **Opaque and cutout level or model geometry → fogged.**
- **Magic, effects and glows → no fog, `XLU_SURF` or `CLD_SURF`.**
- **Water → fogged `XLU_SURF`.**
- **Decals → `XLU_DECAL`** (MM uses decals about 6× as much as OoT).

## What `n64_combiner.gdshaderinc` covers now

Named helpers match only a handful of setups exactly:
- `modulate_prim`, `modulate_i_decal_a` and their PASS2 chains;
- `primitive`, `shade`, `decal_rgba`, `modulate_rgba`, `interference`;
- `blend_pe` (OoT's custom both-lerp form, c136/c086);
- `blend_pe_decal_a`.

Together these cover about **1–2% of asset materials**. The generic `n64_cc` / `n64_cc4` can express
all of them, but the common cycle-2 tints have no named helper. `n64_cc_trilerp` now has a real
use: MM rooms and the warp portal (true LOD_FRACTION).

## Missing recipes worth adding (updated, by reach)

1. **`n64_cc2_modulate_prim/env/shade(comb, x)`**, the cycle-2 tints `COMB*PRIM` / `COMB*SHADE` /
   `COMB*ENV`. With the existing `modulate_i_decal_a` / `modulate_rgb` as cycle 1, these cover
   **about 80% of all asset materials**, and about 93% once the two-texture cycle-1 forms of (4) and (5) are added:
   - OoT and MM level geometry;
   - Link's tunic (`×ENV`);
   - NPCs;
   - SETUPDL_25.

   Better still is a "base × tint" material: a cycle-1 enum (`SHADE*T0`, `PRIM*T0`,
   `mix(T0,T1,k)`, `T0*T1`, `PRIM*SHADE`, `mix(ENV,PRIM,T0)`, signed detail), a cycle-2 enum
   (`×PRIM`, `×SHADE`, `×ENV`, pass, ramp) and an alpha enum.
2. **`n64_cc2_ramp_pe(comb, prim, env)` = `mix(env, prim, comb)`** (alpha `comb.a * prim.a` or
   `* shade.a`). This is the back half of every magic effect, the shiny pickups, the MM sky and the
   VisMono duotone.
3. **`n64_cc_detail_signed(t0, t1, bias, k)` = `(t1 - bias) * k + t0`**, with the alpha partner
   **`n64_cc_alpha_erode(t0a, t1a, k)` = `t0a - k * (1 - t1a)`** (clamped). Paired with (2), this
   is Din's Fire, the arrows, the ocarina songs, warps and Poe souls. Keep RDP clamping via
   `n64_cc_overflow`.
4. **`n64_cc_mix2(t0, t1, k)` = `mix(t0, t1, k)`** with k from a uniform (PRIM_LOD_FRAC) or from
   ENV.a. This is OoT water and two-layer walls (ENV.a, animated) and MM terrain (a constant). It is
   `trilerp` with a uniform, so it can share code.
5. **`n64_cc_detail_mul(t0, t1)` = `t0 * t1`**, MM's base × I-detail terrain. This is the existing
   `interference`; document it for terrain.
6. **`n64_cc_ramp_pe(tex_i, prim, env)` = `mix(env, prim, tex)`, alpha `tex.a * prim.a`**, the 1-cycle
   effect ramp (fire, smoke, explosions). This was v1's top pick. It differs from `blend_pe` only in
   alpha.
7. **`n64_cc_contrast_pivot(t, pivot, k)` = `(t - pivot) * k + t`** → (2). Shiny env-mapped
   pickups and the warp crystal. Needs a sphere-map (`G_TEXTURE_GEN`) UV helper alongside.
8. **`n64_cc_lit_add(tex, shade, env, prim)` = `(shade - env) * prim + tex`**, the MM metal sword
   look on a sphere-mapped I8 texture.
9. **`n64_cc_prim_mask(tex, prim)` = `vec4(prim.rgb, prim.a * tex.a)`**, for shadows, glyphs and
   fairy wings.
10. **Noise recipes:**
    - `mix(env, noise, prim)` (static);
    - `noise * k + t0` (sparkle/crackle);
    - `noise * prim` (beam).

    All are trivial with the existing `n64_cc_noise`. Worth a named "static" helper for Bongo- or
    Dark-Link-style shadows.
11. Optional:
    - `n64_cc_invert`;
    - `(1 - prim * comb)` (Ganondorf's circle);
    - a fog-add `(env - prim) * lod + comb` (MM Ikana cave fog).

For the **render side**:
- a default "fogged opaque / cutout / translucent / decal" switch on the level material;
- an **un-fogged additive-ish `CLD_SURF`** path for magic.

These cover the pairings above.

## Extraction notes

- **OoT:** used the existing `extracted/ntsc-1.2/` (31,924 .c). Only the `*_pal` objects are absent;
  they are not part of ntsc-1.2.
- **MM:** `extracted/n64-us/` was missing 62 object folders, including `gameplay_keep` and
  `gameplay_field_keep`.
  - `make assets VERSION=n64-us` refuses to run without MIPS binutils (`mips-linux-gnu-ld` is
    missing; the Makefile checks for it globally). That is the only missing dependency.
  - I ran the target's own command instead:
    `.venv/bin/python3 tools/extract_assets.py extracted/n64-us/baserom extracted/n64-us/assets -Z Wno-hardcoded-pointer -v n64-us`.
  - A bulk run aborts on `archives/map_name_static.xml`, whose `.unarchive` comes from
    `extract_yars.py` in `make setup` and was never produced. So I ran it once per missing object
    with `-s objects/<name>`. All 61 remaining objects then extracted.
  - Archives (pause-map name textures) are still not extracted. They contain no display lists.
  - Nothing tracked changed. `git status` shows only the pre-existing untracked
    `tools/buildtools/preprocess_pragmas.dSYM/`.
- **Parsers** are in the session scratchpad `decomp_tools/`:
  - `survey.py` (source);
  - `asset_survey.py` (assets: `gs/gDPSetCombineLERP/Mode`, `SetRenderMode`, `SetCycleType`,
    `SetOtherMode`, `SetPrimColor`, `SetEnvColor`, texture loads and geometry modes per DL);
  - `aggregate2.py` (merge).

  All run with `python3 -I`.
- **Render mode** for an asset combiner is the last `SetRenderMode` before it in the same DL,
  otherwise the first one after it. Explicit cycle type is rare in asset DLs (17 of 19k). The
  2-cycle state comes from the setup DL, which the `*2` blender modes confirm.
- **Category** comes from the path:
  - `scenes/*/…_room_*` = room; other scene files = scene;
  - `objects/gameplay_*keep` = keep; other objects = object;
  - `overlays/ovl_*` = overlay; anything else = other.
- **Water, lava and sky** are labelled by scene and object names (e.g. `MIZUsin` = Water Temple,
  `spot17` = Death Mountain Crater, `Z2_20SICHITAI` = Southern Swamp). Room DLs are address-named,
  so per-surface identification (which DL is the water plane) was not done.
