# Grade screen — design

A dedicated editor screen (the **Grade** main-screen tab, beside 2D / 3D / Script) for
deciding how a zone *looks*: values, colour, overlays, vertex shading and AO, per time of
day. The 3D editor and its Paint panel keep *placement*: which texture goes on which face,
UVs, scale, anchors, the face mask, quick fixes while building.

Inspiration: painting in greyscale and colouring with gradient maps / adjustment layers
(Krita filter layers, Photoshop adjustment layers; "GRADIENT MAPS for adding color",
youtu.be/xmYkXNkv2GE): get the values right in grey, add a gradient map on soft light for
temperature bands, glaze local colour on hard light, paint detail last.

## Principles

- **Tune, don't place.** Grade never moves geometry or reassigns base textures (except
  variant layers, which are a look decision).
- **Values first.** Colour / Grey / 3 groups / 5 groups is one click away, with Measure
  (ValueStats: darks / mids / lights, spread, key) and a reference picture docked beside
  the view.
- **Live = baked.** Texture filters run on the texture *image* (textures are small, so a
  stack re-runs on every slider move); the result goes into the level's material. The bake
  saves that same image, so preview and bake can't drift and the level shader doesn't change.
- **Nothing at runtime.** Build & Play writes graded texture copies and filtered vertex
  colours / light keys into the build. The game does no grading work beyond what it does now.
- **Time of day is a first-class axis.** A key switcher (Night / Dawn / Noon / Dusk + a
  scrubber) changes the preview; any vertex-side filter value can be linked (one value) or
  per key.

## The screen

- Centre: a pannable / orbitable view of the open zone (the edited scene's own world seen
  through a Grade camera, so it's always the live level; no gizmos, nothing selectable).
  Click a surface: its layer is selected and its faces highlighted.
- Left: the layer tree.
- Right: the selected layer's settings, filters, the reference picture and value readout.
- Toolbar: view mode, game output (N64VideoOut dither / VI), time keys + scrubber, Measure,
  match the editor camera.

## The layer tree

```
Zone filters                      adjustment layers over everything in the zone
Vertex                            (per time key where it applies)
  Baked light (key)               from the relight; filters only
  Baked AO                        from the bake; filters (strength, curve, tint per key)
  Custom AO layers                painted (soft vertex brush); strength / tint per key
  Painted colour                  vertex_colors / corner paint
  Vertex filters                  gradient map, levels, hue / sat, balance, opacity
Groups (brick, roof, ground…)     group filters apply to every texture in the group
  Texture layer                   one base texture as this zone uses it
    Overlay paint layers          dirt / moss / grime with painted masks
    Filters                       the stack (below)
    Variant layers                the same texture graded differently, on painted faces
```

Groups: an N64Texture's grade category (its folder, or Grade As), else its folder.

Vertex colours can also be clipped to a group or texture layer (Krita clipping mask):
"cooler shadows on brick only".

## Filters

Each filter: visible, opacity, blend mode (normal, multiply, screen, overlay, soft light,
hard light, colour, luminosity), and its own settings. First set:

- Levels / curves
- Hue / saturation, colour balance
- Gradient map (stops, blend mode; "from reference": sample which colour sits at each value
  in a reference picture)
- LUT (LutFile: strip / Hald / .cube)
- Posterise / match a palette
- Noise / grain
- Colour adjust (the Paint panel's ColourAdjust; existing base_adjusts migrate into this)

Vertex-side filters read each vertex's colour instead of a pixel's. Their values can be
linked across time keys or per key (keyframe-like; unlinked sliders edit the current key).

## Vertex stack and time keys

Already stored apart per brush: `vertex_colors` (paint), `vertex_ao` (AO, COLOR.a),
`corner_lighting_keys` (baked light per LightingSchedule key, CUSTOM0..3 in the shader).

- Baked light and baked AO are inputs: the relight rewrites them, so the vertex stack is a
  **stage the bake re-applies after every relight**, never a one-off edit.
- AO layers (baked and custom) are folded into each key's light at bake time with per-key
  strength / tint (noon: light, warm bounce; dusk: deeper, purple; night: strong, blue; a
  night-only painted ring at a lamp's reach). Free at runtime. The single AO channel stays
  for live lights (lanterns, fires), which the keys don't cover.
- Textures get **one** grade (no per-key textures: that would be 4× the texture memory);
  the key switcher is for checking that one grade at every time of day. Per-key texture
  needs go to vertex layers or the night screen grade (ScreenLook per key).

## Painting

Overlay painting, painted vertex colour, custom AO and variant face painting move to Grade.
One paint engine (raycast, stroke, mask / vertex writes, undo) is pulled out of the level
plugin's 3D input handling and driven by either host; the Paint panel is then trimmed to
placement (base textures, UVs, face mask).

## Costs

- Each variant layer is another texture: the layer panel shows the zone's texture count
  against the build budget as variants are added.
- Layers are per zone by default, with an option to share a layer's grade across zones (a
  town graded as one).
- Grading happens under the preview key's baked light; the texture grade is the same at
  every key.

## Data

A per-zone grade resource (layer tree, filter stacks, per-key values), stored with the
zone's LevelData. Existing `LevelData.base_adjusts` and `TextureLook.adjust` migrate into
Colour adjust filters on the matching layers.

## Build order

1. **The screen** — Grade tab; zone view (orbit / pan / fly, click to select a layer and
   highlight its faces); read-only layer tree from the zone; Colour / Grey / 3 / 5 groups;
   game output toggle; time key switcher; Measure; reference picture.
2. **Filters** — texture and vertex filter stacks, live, per-key values; Colour adjust
   migrates in.
3. **Painting moves in** — shared paint engine; overlay layers, painted vertex colour,
   custom AO, variant layers; Paint panel trimmed to placement.
4. **Baking** — graded texture copies, the vertex stack per key after every relight, texture
   count in the build report.

## Status

- Step 1: built (addons/n64_grade).
- Step 2a: texture filters built — ZoneGrade on LevelData.grade; filters (filters/): levels,
  hue / sat, colour balance, gradient map, colour fill, LUT, posterize, noise, colour adjust;
  blend modes + opacity; per-layer show / hide; Filters on / off (before / after); Paint
  panel Colour adjusts move in per layer or zone-wide. GradeProcessor runs chains on worker
  threads (~40 ms for a whole zone); textures with a combiner tint are tinted first and the
  level skips its tint for them, so filters work on the colours shown. Preview only:
  baking (step 4) still to do.
- Extras: LUT packs (textures/_grade/luts/<pack>, imported from folders / zips of HaldCLUT
  / .cube as 32-level strips; ◀ ▶ browsing) and a Palette filter (Lospec .hex / .gpl / .png
  in textures/_grade/palettes, download by name). Modes: Ramp (default: per texture, the
  palette colours of its hue dark to light; palette hue / colour at the texel's own
  lightness unless Exact colours), Fit (k main colours matched hue-first), Nearest, Keep
  lightness, Hue shift (texture turned to one palette colour's hue; chroma match, hue
  variation); click the swatch to pick the allowed colours; Bayer dither for exact colours.
  Per-pixel nearest matching scattered photo textures into stray hues — don't go back.
- Step 2b: vertex layers built — Baked light and Painted colour take filters (light filters
  carry a Keys mask: per time key); Baked AO has strength / curve / corner colour per key
  (or linked). Preview: GradeVertex compiles colour tables (13 levels; light: 4 key blocks)
  + AO params; the paint shader applies them when `grade_vertex` (off in builds). Custom AO
  layers wait for painting (step 3). In preview, live lights lose AO while Grade AO is on.
- Step 4: baking built — GradeBake runs in ExportBake._bake_level after lighting, before
  LevelBaker: paint / light-key filters and Grade AO into the build copy's vertex data
  (Grade AO folded into the RGBA8 light keys, plain AO set to 1, as the preview), texture
  entries with filters replaced by graded copies (N64Texture duplicates keep their settings;
  pretinted ones tint_mode 0; per-texture dictionaries rekeyed). BuildCache's level key
  includes ZoneGrade.signature() and the grade / filter scripts. Not graded: stair textures,
  overlays' own textures, grass carpet / tufts, non-timed lighting modes' light.
- Step 3a: painting in Grade built — the level plugin is the paint host (Engine meta
  n64_level_plugin: grade_paint_input / grade_draw_paint / grade_set_paint_layer /
  grade_mask_variants): Grade's camera and events go through its _paint_input, so the
  Paint panel's tools, settings, face mask and undo are shared; the cursor draws on an
  overlay over the Grade view. Toolbar Paint (P); tree: Painted colour and Overlays >
  layers set the brush's target; "Variant from face mask" on texture / group layers.
- Step 3b: custom AO layers built — LevelBrush.ao_paint (layer id -> darkness per vertex,
  carried through vertex edits like vertex_ao); ZoneGrade.ao_layers (GradeAOLayer: strength
  + corner colour per key or linked); painted with the paint tool's AO_LAYER target from
  Grade (tree: Vertex > AO layers). Folded into the time keys by LevelBrush.fold_ao both in
  the editor mesh (build_painted_mesh's ao_fold, from ZoneGrade.ao_fold()) and the build
  (GradeBake captures the paint before cull / dissolve / lighting grid reshape the brushes,
  samples it back by position after lighting), so preview = build.
- Zones with one lighting (no time of day) get one grade, "Always": Baked Vertex Dynamic
  (single bake in CUSTOM0) previews through the shader as key 0; Baked Vertex (light in the
  vertex colour) is graded when the mesh is built (ZoneGrade.cpu_shade ->
  LevelBrush.build_painted_mesh's `shade`; LevelRoot.regrade_meshes on change). GradeBake
  grades the single bake (corner_lighting) as key 0 with every light filter (Keys ignored);
  AO layers fold into it too. The Grade toolbar shows "Always" instead of the time keys and
  the per-key controls hide. Dynamic zones: paint and textures only.
- Extras graded too (preview + build): stairs' bases, overlay layers' textures, grass
  carpet / tufts, scatter (GradeLayers.extra_textures; LevelRoot.set_grade_plain; GradeBake
  _extras). Overlay noise targets compare through grade_source.
- Gradient map from reference (GradeGradientMap.from_image: equal-count lightness bands,
  OKLab means), with a draggable area on the docked reference picture.
- Shared grades: ZoneGrade.shared (a .tres in textures/_grade/shared); its filters first
  in every layer, the zone's on top; AO falls back to it; variants / AO layers per zone.
  Toolbar "Edit: this zone / shared grade"; shared file saved after edits.
- Decals: LevelDecal (LevelData.decals; level-local position / normal / up, size, rotation,
  depth, max angle) projected by DecalBuilder onto drawn brush faces in its box (clipped, lifted
  0.008 m), each vertex sampling the face's paint / AO / light keys; paint shader cutout
  material (texture once, no tiling / overlays). Editor: LevelRoot live node; build:
  ExportBake -> LevelData.baked_decals (shown in game / exports). Paint tab: Decals layer,
  Place mode + texture, click a decal to select, drag to move, R / [ ] / Delete; decal
  textures graded as extras. Not yet: decals on props' own meshes; blended (non-cutout).
- Main screen tab renamed "Paint" (was Grade).
- Paint panel: NOT trimmed — Grade paints with the Paint panel's tool settings (size,
  strength, colour, tools), so the panel stays the shared settings panel for both screens.
