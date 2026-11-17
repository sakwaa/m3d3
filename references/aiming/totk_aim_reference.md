# Aiming reference: Tears of the Kingdom bow camera

Source: Walaber Entertainment, "Analyzing the Aiming in Zelda TOTK (Quick Game Camera
Analysis Episode 2)", https://www.youtube.com/watch?v=9cxPRHpvuKo (81 s, 720p60). Transcript:
`walaber_totk_aiming_transcript.txt`. Frames measured by eye on a 10% grid (the red lines in
the footage are the video author's screen-centre guides). Game footage: 0-27 s and 72-81 s;
27-72 s is Horizon Zero Dawn (over-the-shoulder, for contrast) and a Unity diagram.

## The idea (from the narration)

- The free camera does not swing round behind Link by itself; only the right stick turns it
  (the right stick is the aiming stick, so the camera mustn't fight it).
- Aiming is not the usual close over-the-shoulder shot. The camera pulls in only a little
  and sits almost directly behind Link, looking the way the arrow will fly.
- Why: the reticle is a ray from the camera through the screen centre; the arrow leaves the
  character's hands, off that ray. The two lines cross at one depth only, so with a big
  shoulder offset, near and far targets need different corrections (the arrow lands off the
  reticle). Keeping the camera close to the arrow's line makes the difference small at every
  range. Nintendo chose clarity over a cinematic shot.

## Measurements

Screen fractions, x from the left, y from the top. Distances assume a 50° vertical FOV and
Link ~1.5 m tall; treat them as ratios (aim vs free), not exact values.

| | Free camera (21.5 s, 76 s) | Aim camera (24.5 s, 74 s) |
|---|---|---|
| Link across | centred, x 0.48-0.50 | left of centre: hood x ~0.43, body x 0.35-0.52 |
| Link up / down | head y ~0.53, feet ~0.95 (whole body) | hood top y ~0.60, cut off at the hips / bottom edge |
| Hood width on screen | ~0.045 | ~0.07 (about 1.5x bigger: camera ~1.5x closer) |
| Estimated distance | ~3.7-4.3 m | ~2.4-2.8 m |
| Screen centre (reticle) | just above the head | ~0.3 m above and ~0.3 m right of the head (at Link's depth) |
| Pitch | slightly down (horizon y ~0.40) | nearly level (horizon y ~0.45-0.50) |

So the aim eye is roughly 2.5 m behind, ~0.3 m above head height and ~0.3 m to Link's right:
Link stays visible lower-left, never covering the reticle, and the arrow's line is close to
the camera's.

## Timing (10 fps samples: `totk_aim_entry_10fps.png`, `totk_aim_release_exit_10fps.png`)

Entry (sheet A, frame = 0.1 s):
- 0-5: standing, bow lowered; the bow starts coming up.
- 6-7: Link turns to face the camera's direction (away from us), bow horizontal, arm out.
- 7-8: the camera moves in to the aim position: about 0.2 s, fast ease.
- 8-11: the bow arm sweeps from horizontal up to the reticle: about 0.3 s.
- 11+: aim hold; only a slight idle sway, the bow arm points at the reticle as it moves.
- Total from button to aimed: about 0.5 s.

Release and exit (sheet B, from frame 10 = 73.6 s):
- 10-16: hold.
- 16-17: release (the arrow streak at the reticle).
- 17-20: follow-through: the bow drops to horizontal across the body (~0.3 s).
- 20-26: bow lowered, camera still in the aim position (~0.6 s; another shot could follow).
- 26-27: Link starts running: the camera returns to the free distance quickly (~0.1-0.2 s).

## Pose notes (from behind; occluded, so eye-read, not pose-estimated)

- Link draws left-handed: the bow in his right hand, the bow arm extended up-right toward
  the reticle, the string hand at the face. The shield stays on the back.
- The whole body faces the aim direction (yaw follows the camera); the bow arm and chest
  carry the pitch.
- Hold: still, small sway. Release: the bow arm drops and the body relaxes; no big recoil.

## Our player (2026-11-13)

Right-handed (the sword in the right hand), so everything above is mirrored: bow in the
left hand, drawn with the right, the aim camera over the left shoulder (the player lower
right of the reticle). AimRig(left_handed) flips it all back if wanted. The drawn pose
follows real archery (`real_draw_side.png`, `real_draw_behind.png`, from the "Archer's
Paradox" short zphqHfAtkhw): bow arm straight, elbow back in line and raised, the string to
the chin outside the bow-side pectoral, the bow nearly upright; ready (nocked, undrawn) the
bow sits ~45° off the aim and the hips twist it on line as it's drawn.
