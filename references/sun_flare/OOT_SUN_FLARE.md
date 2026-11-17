# Ocarina of Time's sun lens flare

How OoT draws its sun flare, read from the zeldaret/oot decomp (`src/code/z_kankyo.c`: `Environment_DrawSunLensFlare`, `Environment_DrawLensFlare`; the sprites are in `gameplay_keep`). These are notes on the behaviour, not copied code or assets. To compare, ours is `game/sky/lens_flare.gd` + `n64_lens_flare.gdshader`.

## When it draws
- Only for the sun, and only when it isn't raining and the skybox config is 0 (the normal sky).
- Strength comes from the time of day: `colorIntensity = cos(dayTime − noon) × 120`, and each element's alpha factor is `min(colorIntensity / 10, 1)`. So it's full for most of the day and fades out only near dawn and dusk.
- Fog lowers it: `× (1 − clamp((FOGNEAR_MAX − fogNear) / 50, 0, 1))`, so thick near fog kills the flare.

## Sun test (occlusion)
- Each frame the game reads one z-buffer pixel at the sun's screen position, 5 px above it (`Environment_GetPixelDepth`), and uses the result on the next frame.
- If that pixel isn't max depth (the sky), or the sun is off screen, the flare counts as hidden.
- The visibility value `lensFlareAlphaScale` eases toward its target, by half the gap and at most 0.05 per frame. When visible the target is `min(cosAngle × 3.5, 1)`; when hidden it is 0. So it fades in and out over about 20 frames rather than popping.

## Geometry (in the world, not on the screen)
- `cosAngle` is the angle between the look direction and the direction from halfPos to the sun. halfPos is the point on the look ray at half the sun's distance. If `cosAngle < 0` nothing draws.
- Element i (0..9) sits at `sun − posDir × i × d`, where `d = |sun − eye| / 12`. The chain runs from the sun back toward the middle of the view, at most 0.75 of the way. Because the elements are real 3D quads, the later ones are nearer the camera and come out bigger from perspective alone.
- Size: each element is a 64 × 64-unit quad scaled by `scales[i] × cosAngle × 0.001 × (370 + 630 × fovWeight)`. fovWeight is 0 at 60° FOV and 1 at 15° (zoomed in), so zooming grows the flare.
- Elements:

| i | type | scale | colour (RGB) | alpha (/255) |
|---|---|---|---|---|
| 0 | ring | 23 | 155 205 255 (blue) | 50 |
| 1 | disc | 12 | 255 255 205 (yellow) | 10 |
| 2 | disc | 7 | 255 255 205 | 25 |
| 3 | disc | 5 | 255 255 205 | 40 |
| 4 | disc | 3 | 155 255 205 (green) | 70 |
| 5 | disc | 10 | 205 255 255 (light blue) | 30 |
| 6 | disc | 6 | 155 155 255 (dark blue) | 50 |
| 7 | disc | 2 | 205 175 255 (purple) | 70 |
| 8 | disc | 3 | 175 255 205 (light green) | 50 |
| 9 | disc | 1 | 255 155 235 (pink) | 40 |

## Material
- Combiner: colour = PRIM, alpha = TEXEL0 × PRIM alpha. The texture only shapes the alpha; the colour is a flat prim colour.
- Setup DL 65: `G_RM_CLD_SURF` (ordinary translucent alpha blending, **not additive**), bilinear filtering, alpha and colour dither off.
- Textures: 64 × 64 I4.
  - The disc is a solid, hard-edged circle with a 1–2 texel soft rim.
  - The ring is a thin outline about 4 texels wide.
  - Both are easy to make procedurally, so there's no need to take the originals.

## Glare (full screen)
- Applies when `2 × cosAngle − 1.5 > 0`, i.e. looking within about 41° of the sun.
- A full-screen rectangle with colour `(255, 180 + 75t, 100 + 155t)`, where `t = colorIntensity / 120`. It is warm orange near dawn and dusk and almost white at noon.
- Its alpha eases (half the gap, at most 50 per frame) toward `min(colorIntensity / 10, 1) × 400 × (2cos − 1.5)`, which is about 200 of 255 looking straight at the sun. It eases to 0 when the sun is hidden.
- Setup DL 57, the flat prim-colour fill.

## Differences from ours (as of 2026-11-16)

| | Ours | OoT |
|---|---|---|
| Elements | 8, invented sizes and colours | 10, values above |
| Placement | screen space | world space, with perspective growth |
| Blend | additive | alpha blend |
| Sprites | soft dot and ring textures | hard discs and a thin ring |
| Sun test | 3 × 3 depth taps, instant | one depth pixel a frame late, eased about 20 frames |
| Glare | none | warm full-screen glare when facing the sun |
| Fog / zoom | no fade, no zoom scaling | fades with near fog, grows when zoomed in |
