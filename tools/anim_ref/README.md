# Animation reference tools

Turn gameplay / reference video into animations for the actor tools. Nothing here ships:
`tools/*` is excluded from exports and `.gdignore` keeps Godot from scanning it.

## Setup (once)

```
brew install ffmpeg yt-dlp uv imagemagick
tools/anim_ref/setup.sh
```

Creates `.venv-pose` (Python 3.13: rtmlib RTMPose 2D pose, OpenCV) and `.venv-mp`
(Python 3.12: MediaPipe 3D pose) here, plus `models/pose_heavy.task`. rtmlib caches its
weights in `~/.cache/rtmlib`. Scratch output goes in `work/`.

## The workflow

1. **Find footage.** `scan.py VIDEO work/NAME --step 10 [--score]` makes timestamped contact
   sheets of a whole video; `--score` also poses every sample and lists moments where the
   character is large and side-on. Best footage: a side-on camera, character big, steady.
2. **Fetch the section** at the highest frame rate available (60 beats 30 for timing):
   `fetch.sh NAME URL START END` -> `work/NAME/frames/`.
3. **Pose it.**
   - Large, clean figures: `.venv-pose/bin/python -I pose.py FRAMES OUT.json --detect`
     (2D, 26 keypoints, overlays in `OUT_ov/` - always look at them).
   - Moving camera, small figure: `track.py` follows it and writes upscaled crops.
   - Not side-on: `.venv-mp/bin/python -I pose3d.py FRAMES OUT.json FPS [BOXES.json]` (3D).
4. **Measure.**
   - `cycle2d.py` (side view) / `cycle3d.py` (any view, from 3D) find the cycle period and
     average one cycle of joint angles; `--spec SPEC.json --keys 8 --name Run` writes an
     animation spec straight from the measurement.
   - `compare_climb.py` puts a reference next to ours (our joints logged by
     `tests/climb/render.tscn` with `POSELOG=`) as a table and curves.
5. **Read by eye when automation fails.** `frames.py FRAMES FIRST LAST OUT.png --boxes
   OUT.json` makes numbered, zoomed sheets; go through them frame by frame (count frames
   between the same foot / hand events for timing; note the key poses).
6. **Write the spec** (`references/anims/*.json`, see below) and build it: actor tools,
   Animation panel, **From spec…** (or **Import…** a built `.tres`). Compare a render with the
   reference strip, tweak keys by hand.

## Spec format (ActorAnimSpec, addons/n64_actor_tools/actor_anim_spec.gd)

```json
{"name": "Run", "fps": 30, "length": 16, "loop": true, "root": "auto", "mirror_half": true, "lean": 12,
 "keys": [{"frame": 0, "ease": "ease_out", "lift": 0.0,
           "thigh_L": 34, "shin_L": 18, "upper_arm_R": [28, 17], "forearm_R": [123, 7]}]}
```

- Limb angles (`thigh`, `shin`, `foot`, `upper_arm`, `forearm`, `hand`, `_L` / `_R`):
  degrees from straight down in the side plane, **+ = forward**; `[swing, out]` adds degrees
  away from the body. Absolute (not relative to the parent).
- `lean`, `neck`, `head`, `chest`: degrees forward from upright.
- `root: "auto"`: hips at the height that puts the lower foot on the ground; `lift` adds metres.
- `mirror_half`: give the first half of a cycle; the rest is mirrored left / right.
- Eases: smooth, linear, ease_in, ease_out, snap, pop, step.

## What works when (learned on SotC, OoT/MM Link, a climbing reel)

- **RTMPose 2D** is reliable on large, clean, side-on figures (the climbing reel). It only
  gives forward / back angles from a side view.
- **MediaPipe 3D** finds people at 3/4 views but its depth is unreliable on stylised
  characters (child proportions): torso and legs disagree, knees / ankles low visibility.
  Use it for timing and arm width, not leg swing.
- **Small / dark / blurred characters** (SotC's Wander at 40-80 px): every detector fails.
  Track, crop, upscale, and read by eye. That gave the SotC climb timing and poses.
- **Timing from any view**: the period of ankle-height difference (cycle scripts do this).
- **Check signs numerically, not from renders**: the model faces **-Z**; a backwards lean
  once slipped through by eye. Measure (e.g. head.z - hips.z < 0 means leaning forward).
- Gameplay cameras sit behind the character, so side-on runs are rare in playthroughs; look
  for side cameras, model viewers or showcase videos.
- Treat reference video as reference: measure shapes and timing, don't rip game data.

## Godot-side helpers

- `tests/climb/render.tscn`: renders our player from matching angles (`CAMSIDE`, `CAMBACK`,
  `CAMLOW`, `SHOTS=`), logs post-IK joints (`POSELOG=`) or head direction (`HEADLOG=`),
  benchmarks (`BENCH=1`).
- `tests/climb/run.sh`: climb regression.
