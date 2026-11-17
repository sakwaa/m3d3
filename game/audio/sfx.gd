class_name Sfx
extends RefCounted
## One entry point for game sound effects: `Sfx.play(&"step_grass", position)`.
##
## Effects are meant to be sequenced (the SFX player plays a short sequence per effect).
## Until that's wired here, a node in the PLAYER_GROUP group that has the effect (duck
## typed: Has(name) / Play(name, pitch, volume, pan), like N64SfxPlayer) plays it, and
## footsteps without one fall back to small generated placeholders, so the ground is heard.

const PLAYER_GROUP := &"sfx_player"
## Metres: positional effects fade out by this distance from the camera.
const REACH := 25.0
## Metres: full volume, dry and bright within this (OoT's near range).
const NEAR := 3.0
const MIX_RATE := 22050

static var _placeholders := {}


## Footstep for a Surface (Surface.Sound | flags): effect "step_<sound name>".
static func footstep(surface: int, at: Vector3, volume := 1.0) -> void:
	play(StringName("step_" + Surface.sound_name(surface).to_lower()), at, volume * 0.6, randf_range(-0.6, 0.6))


## Plays effect `name` at a world position, pitch in semitones. OoT's distance model:
## panned by where it is on screen (behind the camera: to its side), full volume within
## NEAR then easing out by REACH, and further away more reverb and a duller sound.
static func play(name: StringName, at: Vector3, volume := 1.0, pitch := 0.0) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return
	var camera := tree.root.get_camera_3d()
	var falloff := 1.0
	var pan := 0.0
	var reverb := 0.15
	var lowpass := 0.0
	if camera:
		var to := at - camera.global_position
		var d := to.length()
		if d > REACH:
			return
		var t := clampf((d - NEAR) / (REACH - NEAR), 0.0, 1.0)
		falloff = pow(1.0 - t, 1.5)
		reverb = 0.15 + 0.5 * t
		lowpass = lerpf(16000.0, 2500.0, (t - 0.3) / 0.7) if t > 0.3 else 0.0
		pan = screen_pan(camera, to)
	var player := tree.get_first_node_in_group(PLAYER_GROUP)
	if player and player.has_method(&"Has") and player.call(&"Has", name):
		player.call(&"Play", name, pitch, volume * falloff, pan, -1, -1, reverb, lowpass)
		return
	var stream := _placeholder(name)
	if stream == null:
		return
	var p := AudioStreamPlayer3D.new()  # attenuates by distance itself
	p.stream = stream
	p.unit_size = 4.0
	p.max_distance = REACH
	p.volume_db = linear_to_db(maxf(volume, 0.001)) - 4.0
	p.pitch_scale = pow(2.0, pitch / 12.0)
	tree.root.add_child(p)
	p.global_position = at
	p.finished.connect(p.queue_free)
	p.play()


## Generated stand-ins for the step effects: a short filtered noise burst (plus a knock or
## ring for wood / metal) per sound, so each ground sounds different before real effects.
static func _placeholder(name: StringName) -> AudioStreamWAV:
	if _placeholders.has(name):
		return _placeholders[name]
	var key := String(name).trim_prefix("step_")
	if not String(name).begins_with("step_") and not String(name).begins_with("block_"):
		return null
	# [length s, noise low-pass 0..1 (brightness), decay s, tone Hz (0 none), tone mix]
	var spec: Array = {
		"grass": [0.12, 0.45, 0.05, 0.0, 0.0], "dirt": [0.09, 0.18, 0.035, 90.0, 0.4],
		"stone": [0.07, 0.7, 0.018, 0.0, 0.0], "wood": [0.1, 0.3, 0.025, 210.0, 0.7],
		"sand": [0.14, 0.55, 0.06, 0.0, 0.0], "water": [0.2, 0.8, 0.08, 0.0, 0.0],
		"metal": [0.18, 0.5, 0.015, 880.0, 0.5], "snow": [0.14, 0.12, 0.06, 0.0, 0.0],
		"carpet": [0.06, 0.08, 0.02, 0.0, 0.0],
		# Push blocks (OoT: the stone scraping along, the thud against a wall or landing).
		"block_slide": [0.55, 0.3, 0.25, 0.0, 0.0], "block_bound": [0.3, 0.1, 0.07, 55.0, 0.6],
	}.get(key, [0.07, 0.5, 0.02, 120.0, 0.3])
	var frames := int(spec[0] * MIX_RATE)
	var bytes := PackedByteArray()
	bytes.resize(frames * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key)
	var low := 0.0
	for i in frames:
		var t := float(i) / MIX_RATE
		var env := exp(-t / spec[2]) * minf(t * 2000.0, 1.0)
		low = lerpf(low, rng.randf_range(-1.0, 1.0), spec[1])
		var v: float = low * (1.0 - spec[4])
		if spec[3] > 0.0:
			v += sin(TAU * spec[3] * t) * spec[4] * (1.6 if key == "metal" else 1.0)
		if key == "water":
			v *= 0.6 + 0.4 * sin(TAU * 31.0 * t)  # a little slosh
		bytes.encode_s16(i * 2, int(clampf(v * env * 0.8, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.data = bytes
	_placeholders[name] = wav
	return wav


## Pan (-1..1) from where `to` (camera to sound) lands on screen, as OoT panned by the
## projected x; behind the camera, to the side it's on.
static func screen_pan(camera: Camera3D, to: Vector3) -> float:
	var local := camera.global_basis.inverse() * to
	if local.length() < 0.01:
		return 0.0
	if local.z < -0.1:
		var vp := camera.get_viewport().get_visible_rect().size
		var half_w := -local.z * tan(deg_to_rad(camera.fov) * 0.5) * (vp.x / maxf(vp.y, 1.0))
		return clampf(local.x / maxf(half_w, 0.001), -1.0, 1.0) * 0.85
	return 0.85 * signf(local.x) if absf(local.x) > 0.01 else 0.0
