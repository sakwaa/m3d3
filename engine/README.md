# Engine patches

The game runs on a patched Godot (.NET). Patches live here; `tools/engine/build.sh` applies
them to a Godot release tag and builds the editor app (and, with `TEMPLATES=1`, the export
templates). Every engine upgrade goes through that script.

| Patch | What it adds |
|---|---|
| `0002-barycentric.patch` | `BARYCENTRIC` (vec3, fragment): the fragment's barycentric coordinates (`gl_BaryCoordEXT`, read in `main()`), define `M3D3_BARYCENTRIC`. Analytic 8-level edge coverage for the N64 coverage AA (`n64_coverage.gdshaderinc`). |
| `0003-noperspective.patch` | `noperspective` interpolation qualifier for varyings (screen-space, as the N64 interpolated shading), define `M3D3_NOPERSPECTIVE`. Our shaders declare light / vertex colour / fog / tint varyings `varying N64_SHADE …` (`n64_sampling.gdshaderinc`). |
| `0004-vi-scaler.patch` | Project setting `rendering/m3d3/vi_upscale` (bilinear 3D scaling only): the tonemap pass stretches the 3D picture like the N64's VI - interpolated along each line, whole lines repeated (no vertical filter). Changeable at runtime (`ProjectSettings.set_setting`). |
| `0005-keep-coverage-alpha.patch` | Project setting `rendering/m3d3/keep_coverage_alpha` (restart): blended pipelines leave the destination alpha alone (src ZERO, dst ONE), so water, rain, effects and the passages' darkness drawn over a surface keep its coverage tag, as the RDP blended colour but kept the coverage bits. Off: the stock blend writes alpha and those pixels fall back to a plain MSAA resolve. |
| `0001-coverage-builtins.patch` | Spatial shaders (Forward+): `SAMPLE_MASK_IN` (int, the MSAA samples this triangle covers in the pixel, `gl_SampleMaskIn[0]`) and `COVERAGE` (float output: written to the colour's alpha in the opaque pass). Lets the N64 VI edge AA read real per-triangle coverage from the MSAA samples instead of guessing edges from depth. |

Upgrade: `GODOT_TAG=<new tag> TEMPLATES=1 tools/engine/build.sh`. If a patch fails to apply,
fix the conflict in the Godot checkout and refresh the patch. Patches apply in order and
each is staged as it applies, so a patch is the diff from the one before: for the first,
`git -C <checkout> diff HEAD > engine/patches/0001-….patch`; for later ones, stage the
earlier patches (`git add -A` after applying them) and save `git diff`.

Not patched yet: the Mobile renderer (only Forward+ has the built-ins).
