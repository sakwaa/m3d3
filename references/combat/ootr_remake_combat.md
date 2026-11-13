# OoT remake (Switch 2) combat: what it adds over N64

Source: "Combat Gameplay - Zelda: Ocarina of Time Remake (Switch 2)", YouTube HyZqoJ9dXYk,
39 s at 60 fps. Frames were read by eye in `tools/anim_ref/work/ootr/` (s_a … s_e, hit.png).
Frame numbers below are at 60 fps.

## Measured

**A vertical (jump) slash landing on a Stalfos, frames 1394–1425:**

- **Wind-up:** 1394–1400 (6 f, 0.10 s). The sword is raised and a small glint flares on the
  blade just before the swing (also seen at 2276).
- **Swing:** 1400–1403 (3–4 f, 0.06 s). It shows as a wide white **smear**, a crescent the size
  of the whole arc, not a thin ribbon.
- **Hitstop:** 1404–1411 (**8 f, 0.13 s**). Link and the Stalfos both hold their poses. The
  lock-on reticle keeps spinning: only the fighters freeze, not the UI.
- **Enemy flash:** solid red tint 1404–1417 (14 f), fading 1418–1421 (4 f): **about 0.3 s**.
- **Impact flash:** a burst **along the swing's plane**, white core and pink-red edges.
  - Vertical swing: a vertical pillar (1404–1415, bright for 8 f, then gone over 4 f).
  - Horizontal swing: a horizontal streak (1500–1506).
  - Diagonal swing: a diagonal streak (2124–2132).
  - Sparks shoot out from the burst for about 12 f. Small embers drift after.
- **Camera:** barely shakes on normal hits.

**Charged spin attack on a Tektite, frames 450–560:**

- **Charge:** about 0.8 s holding (450–498). The blade glows blue, with a star glint when fully
  charged.
- **Release:** the spin draws a wide blue crescent trail around Link, low over the ground
  (504–522). A second spin follows.
- **Killing blow** (528–540):
  - a long freeze (**about 12+ f, 0.2 s**);
  - a **radial zoom blur** over the whole screen;
  - a long white streak through the enemy, and the enemy goes red.
- **Death** (546–560):
  - The enemy breaks up into a **purple / violet flame column** in about 0.25 s.
  - Debris scatters, and a few bits linger on the ground.

**Stalfos guarding:**

- Link's shield block (1302, 1344, 2180, 2220): a bright **white ring flare**, expanding rings
  plus a starburst at the shield, about 6 f.
- The Stalfos crouches behind its shield. Hits on it throw **orange sparks** (1512–1518).
- Enemy weapons draw a soft grey smear trail on their swings too (1458, 2172).

**Variety:** in about 40 s of play, Link uses
- vertical, horizontal and diagonal slashes;
- jump slashes;
- a charged spin;
- shield blocks;
- (by the camera framing) side-on footwork while locked.

Each slash type gets an impact flash oriented to match it.

**Lock reticle:** the remake draws enemy targets with pink-red triangles, not yellow.

## Ours now (game/actors/combat.gd, attack_state.gd, effects/)

- **Strikes:**
  - Reach and arc against the target.
  - Clashes: equal weights both recoil; the heavier swing staggers the lighter.
  - Blocks: the attacker recoils and the defender gets 0.6 s to counter.
  - Hits: damage, knockback, then Hurt or Death.
- **Effects:** sprite `hit_flash` on hits and `clash_spark` on clashes and blocks (N64 emitter).
  No trails, no hitstop, no flash on the enemy, no direction to the flash, no spin attack and
  no death effect.
- **Attacks:** SlashD and SlashH2 (standing combo), SlashV, Stab and SlashH (while locked), and
  the jump slash. These are measured from MM / OoT 3D video.
