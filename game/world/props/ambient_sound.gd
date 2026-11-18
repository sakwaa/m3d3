@tool
class_name AmbientSound
extends Node3D
## An environmental sound loop (a prop): rain, a waterfall's roar, a babbling stream or wind.
## The loops are made here (filtered noise, once per sound, shared), seamless ~4 s clips.
## Waterfall and stream are heard round the prop: full within a third of `radius`, easing out
## to nothing at it (OoT's distance feel, Sfx.play()), panned by where they are. Rain and wind
## follow the listener wherever they are placed: rain as loud as it's raining (the weather's
## rain), wind by the weather's wind. Plays in game only (in the editor: tick `preview`);
## fades in when the scene starts.

enum Sound { RAIN, WATERFALL, STREAM, WIND }

## What it sounds like.
@export var sound := Sound.WATERFALL:
	set(v):
		sound = v
		_restart()
@export_range(0.0, 1.0, 0.01) var volume := 0.8
## Waterfall / stream: heard out to here (full within a third of it). Rain and wind: unused.
@export_range(1.0, 200.0, 0.5, "suffix:m") var radius := 30.0:
	set(v):
		radius = v
		if _player is AudioStreamPlayer3D:
			_player.max_distance = radius
## Play it in the editor too (to hear it while placing it).
@export var preview := false:
	set(v):
		preview = v
		_restart()

const MIX_RATE := 22050
## The loop's length (s).
const LOOP := 4.0
## Crossfade from the generated tail into the head (s): the seam.
const SEAM := 0.6
const FADE_IN := 1.5
## How often the weather's rain / wind is read (s).
const WEATHER_RATE := 0.5

static var _streams := {}

var _player: Node
var _fade := 0.0
var _weather := 0.0
var _weather_target := 0.0
var _weather_t := 0.0


func _ready() -> void:
	_restart()


func _exit_tree() -> void:
	_stop()


func _active() -> bool:
	return is_inside_tree() and (preview or not Engine.is_editor_hint())


## True for the sounds that follow the listener (no place).
func follows_listener() -> bool:
	return sound == Sound.RAIN or sound == Sound.WIND


func _stop() -> void:
	if _player and is_instance_valid(_player):
		_player.queue_free()
	_player = null


func _restart() -> void:
	_stop()
	set_process(false)
	if not _active():
		return
	var p: Node
	if follows_listener():
		p = AudioStreamPlayer.new()
	else:
		var p3 := AudioStreamPlayer3D.new()
		# (our own distance curve, below; the node only pans)
		p3.attenuation_model = AudioStreamPlayer3D.ATTENUATION_DISABLED
		p3.attenuation_filter_db = 0.0
		p3.max_distance = radius
		p = p3
	p.set(&"stream", stream_for(sound))
	p.set(&"volume_db", -80.0)
	# (instances drift apart a little: no two falls in phase)
	p.set(&"pitch_scale", randf_range(0.96, 1.04))
	add_child(p, false, INTERNAL_MODE_BACK)
	_player = p
	_fade = 0.0
	_weather_t = 0.0
	_read_weather()
	_weather = _weather_target
	p.call(&"play", randf() * LOOP)
	set_process(true)


func _process(delta: float) -> void:
	if _player == null:
		return
	_fade = minf(_fade + delta / FADE_IN, 1.0)
	var k := volume * smoothstep(0.0, 1.0, _fade)
	if follows_listener():
		_weather_t -= delta
		if _weather_t <= 0.0:
			_weather_t = WEATHER_RATE
			_read_weather()
		_weather = move_toward(_weather, _weather_target, delta * 0.5)
		k *= _weather
	else:
		k *= _distance_gain()
	_player.set(&"stream_paused", k < 0.001)
	_player.set(&"volume_db", linear_to_db(maxf(k, 0.0001)))


## OoT-style: full within radius·0.3, then easing out to nothing at the radius.
func _distance_gain() -> float:
	var camera := get_viewport().get_camera_3d() if get_viewport() else null
	if camera == null:
		return 1.0
	var d := camera.global_position.distance_to(global_position)
	var near := radius * 0.3
	var t := clampf((d - near) / maxf(radius - near, 0.01), 0.0, 1.0)
	return pow(1.0 - t, 1.5)


## The weather's rain (0..1) or wind for the listener-following sounds. In game from the
## weather now (script side); in the editor (preview) from the sky's shader global.
func _read_weather() -> void:
	if sound == Sound.RAIN:
		if Engine.is_editor_hint():
			var r = RenderingServer.global_shader_parameter_get(&"n64_rain")
			_weather_target = clampf((r as Vector4).x, 0.0, 1.0) if r is Vector4 else 0.0
		else:
			_weather_target = clampf(float(GameState.weather_now.get("rain", 0.0)), 0.0, 1.0)
	elif sound == Sound.WIND:
		if Engine.is_editor_hint():
			_weather_target = 1.0
		else:
			_weather_target = clampf(float(GameState.weather_now.get("wind", 1.0)), 0.0, 1.5)
	else:
		_weather_target = 1.0


## The loop for a sound (made once, shared).
static func stream_for(s: Sound) -> AudioStreamWAV:
	if _streams.has(s):
		return _streams[s]
	var n := int(LOOP * MIX_RATE)
	var seam := int(SEAM * MIX_RATE)
	var raw := _generate(s, n + seam)
	# Seamless: the head crossfades in from the tail (what would have followed the end).
	var out := PackedFloat32Array()
	out.resize(n)
	for i in n:
		out[i] = raw[i]
	for i in seam:
		var t := float(i) / seam
		out[i] = raw[i] * sin(t * PI * 0.5) + raw[n + i] * cos(t * PI * 0.5)
	var peak := 0.001
	for v in out:
		peak = maxf(peak, absf(v))
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	var g := 0.7 / peak
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(out[i] * g, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = bytes
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
	_streams[s] = wav
	return wav


## `frames` of a sound, unnormalised. Slow swells run whole cycles over LOOP (periodic).
static func _generate(s: Sound, frames: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(frames)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 + int(s) * 131
	var lp1 := 0.0
	var lp2 := 0.0
	var lp3 := 0.0
	var brown := 0.0
	var env := 0.0
	var env_target := 0.0
	var tick := 0.0
	var bubble := 0.0
	var bubble_f := 0.0
	var bubble_ph := 0.0
	for i in frames:
		var t := float(i) / MIX_RATE
		var w := rng.randf_range(-1.0, 1.0)
		var v := 0.0
		match s:
			Sound.RAIN:
				# Hiss: white noise, its lows cut (high shelf), plus patter: tiny bright ticks.
				lp1 = lerpf(lp1, w, 0.08)
				lp2 = lerpf(lp2, w, 0.55)
				v = (lp2 - lp1 * 0.85) * 0.55
				if rng.randf() < 0.004:
					tick = rng.randf_range(0.3, 1.0) * (1.0 if rng.randf() < 0.5 else -1.0)
				tick *= 0.86
				v += tick * w * 0.6 + tick * 0.2
			Sound.WATERFALL:
				# Roar: brown noise (integrated, leaky) plus low-passed noise, swelling slowly.
				brown = clampf(brown * 0.995 + w * 0.06, -1.0, 1.0)
				lp1 = lerpf(lp1, w, 0.12)
				lp2 = lerpf(lp2, lp1, 0.3)
				var swell := 0.82 + 0.12 * sin(TAU * t / LOOP) + 0.06 * sin(TAU * 3.0 * t / LOOP + 1.3)
				v = (brown * 0.9 + lp2 * 1.6) * swell
			Sound.STREAM:
				# Babble: band-passed noise (two low-passes' difference), its level jumping
				# round fast, and small rising bubbles.
				lp1 = lerpf(lp1, w, 0.35)
				lp2 = lerpf(lp2, w, 0.06)
				var band := lp1 - lp2
				if i % 1200 == 0:  # (~18 Hz)
					env_target = rng.randf_range(0.25, 1.0)
				env = lerpf(env, env_target, 0.004)
				v = band * env
				if bubble <= 0.001 and rng.randf() < 0.0012:
					bubble = rng.randf_range(0.15, 0.45)
					bubble_f = rng.randf_range(280.0, 700.0)
				if bubble > 0.001:
					bubble_f *= 1.00012  # (rising)
					bubble_ph += TAU * bubble_f / MIX_RATE
					v += sin(bubble_ph) * bubble
					bubble *= 0.9985
			Sound.WIND:
				# Whoosh: very low-passed noise, gusting slowly (whole cycles over the loop).
				lp1 = lerpf(lp1, w, 0.03)
				lp2 = lerpf(lp2, lp1, 0.05)
				lp3 = lerpf(lp3, lp2, 0.2)
				var gust := 0.55 + 0.3 * sin(TAU * t / LOOP - 0.5) + 0.15 * sin(TAU * 2.0 * t / LOOP + 2.0)
				v = lp3 * gust * gust
		out[i] = v
	return out
