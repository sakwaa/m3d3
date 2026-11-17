extends Node3D
## AA benchmark: the market from a fixed view; each config runs WARM frames, then MEASURE
## frames rendered back to back without presenting (so the display's refresh can't cap
## them); reports median / p90 render time per frame (whole frame: CPU + GPU, synced). Prints a table and writes OUT (json).
##   OUT=file.json [SCALES=1.0,0.4907] (0.29444 = 540 lines on a 1834-line Retina window) godot --path . --resolution 1920x1080 tests/zones/aa_bench.tscn
## WEATHER=rainy: rain (ripples on); MIST=1: ground mist costs instead (hillside, Misty, coverage AA): off / blended / dithered /
## 8 layers.

const WARM := 90
const MEASURE := 400
const CONFIGS := [
	["no AA", 0, 0.0, false, false],
	["MSAA 2x", 1, 0.0, false, false],
	["MSAA 4x", 2, 0.0, false, false],
	["N64 VI edge AA (depth)", 0, 1.0, false, false],
	["N64 coverage AA (MSAA 4x)", 2, 1.0, true, false],  # (4x: 8x is broken on Apple GPUs)
	# The game's setup: coverage AA + the edge-aware upscale shown on screen (RenderScale).
	["coverage AA + edge upscale", 2, 1.0, true, true],
	["coverage AA 2x + edge upscale", 1, 1.0, true, true],
]
# PARTS=1: the upscale's two halves alone (after warming up with it on): its compute pass
# without the screen layer, the screen layer (last picture) without the compute pass.
const PART_CONFIGS := [
	["N64 coverage AA (MSAA 4x)", 2, 1.0, true, false],
	["coverage AA + edge upscale", 2, 1.0, true, true],
	["upscale: compute only", 2, 1.0, true, true, "compute"],
	["upscale: screen layer only", 2, 1.0, true, true, "layer"],
]

# FX=1: the new effects' cost on top of the game's setup (coverage AA 4x): screen combiners
# (bloom; bloom + depth haze), the sandstorm layer.
const FX_CONFIGS := ["game setup", "+ combiner: bloom", "+ 2 combiners: bloom + haze", "+ sandstorm layer"]

# TAPE=1: the video tape look (VideoTape, game/looks/tape_studio.tres) on the game's setup,
# whole and in parts: [name, overrides (null = tape off)].
const TAPE_CONFIGS := [
	["game setup", null],
	["+ tape (studio preset)", {}],
	["+ tape, no lens defocus", {defocus = 0.0}],
	["+ tape, no bloom", {bloom = 0.0}],
	["+ tape, lens + bloom only", {sharpen = 0.0, chroma_blur = 0.0, luma_noise = 0.0, chroma_noise = 0.0}],
	["+ tape, no lens / bloom", {defocus = 0.0, bloom = 0.0}],
]

var _cam: Camera3D
var _vo: Resource
var _results := []
var _zone: Node
const MIST_CONFIGS := [
	["mist off", 0.0, false, 8, 60.0],
	["mist on (8 steps, 60 m, sim)", 1.0, false, 8, 60.0],
]


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var mist := OS.get_environment("MIST") != ""
	var zone: Node = (load("res://zones/town1/town_1_hillside.tscn" if mist else "res://zones/town1/town_1_market_square.tscn") as PackedScene).instantiate()
	_zone = zone
	add_child(zone)
	GameState.set_time(14.0)
	_cam = Camera3D.new()
	_cam.fov = 60.0
	add_child(_cam)
	if OS.get_environment("WEATHER") != "":
		GameState.set_weather(StringName(OS.get_environment("WEATHER")), 0.0)
	if mist:
		GameState.set_weather(&"misty", 0.0)
		_cam.position = Vector3(0, 2.2, 9)
		_cam.look_at(Vector3(0, 0.6, 0))
	else:
		_cam.position = Vector3(6, 1.6, 6)
		_cam.look_at(Vector3(-0.75, 2.5, 13.4))
	_vo = load("res://game/video_out.tres")
	if OS.get_environment("VO_SET") != "":
		# VO_SET="prop=value;...": N64VideoOut settings for this run (as shot.gd).
		for kv in OS.get_environment("VO_SET").split(";"):
			var pr := kv.split("=")
			_vo.set(StringName(pr[0]), type_convert(float(pr[1]), typeof(_vo.get(StringName(pr[0])))))
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	_run.call_deferred()


var _storm: Sandstorm


func _fx_setup(name: String) -> void:
	# (through RenderScale, which sets the looks every frame)
	var bloom := load("res://game/looks/combiners/market_lamp_bloom.tres") as ScreenLook
	var haze := load("res://game/looks/combiners/market_haze_glow.tres") as ScreenLook
	match name:
		"game setup":
			RenderScale.release_look(0.0)
		"+ combiner: bloom":
			RenderScale.force_look(bloom, 0.0)
		"+ 2 combiners: bloom + haze":
			RenderScale.release_look(0.0)
			RenderScale.set_scene_mix({bloom: 0.5, haze: 0.5})
		"+ sandstorm layer":
			RenderScale.set_scene_mix({})
			_storm = Sandstorm.new()
			add_child(_storm)
			_storm.state = Sandstorm.State.ACTIVE
		"+ hit FX x4":
			if _storm:
				_storm.queue_free()
			var at := _cam.global_position - _cam.global_transform.basis.z * 3.0
			for i in 4:
				OotHitFx.hit_mark(self, at + Vector3(i * 0.3 - 0.45, 0, 0), OotHitFx.Mark.METAL)
				OotHitFx.clang(self, at, true)
				OotHitFx.blood(self, at, OotHitFx.Blood.BLUE)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _run() -> void:
	await _frames(20)
	for c in get_tree().root.find_children("*", "Camera3D", true, false):
		if c != _cam:
			c.current = false
	_cam.make_current()
	var vp := get_viewport()
	var scales: Array = Array(OS.get_environment("SCALES").split(",")).map(func(x): return float(x)) if OS.get_environment("SCALES") != "" else [1.0, 0.4907]
	print("[bench] window ", DisplayServer.window_get_size(), " engine ", Engine.get_version_info().string)
	for sc in scales:
		var mist := OS.get_environment("MIST") != ""
		var fx := OS.get_environment("FX") != ""
		var tape := OS.get_environment("TAPE") != ""
		for cfg in (TAPE_CONFIGS if tape else FX_CONFIGS.map(func(n): return [n]) if fx else MIST_CONFIGS if mist else (PART_CONFIGS if OS.get_environment("PARTS") != "" else CONFIGS)):
			vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
			vp.scaling_3d_scale = sc
			if tape:
				vp.msaa_3d = Viewport.MSAA_4X
				_vo.set(&"edge_aa", 1.0)
				_vo.set(&"edge_coverage", true)
				ProjectSettings.set_setting("n64/render/edge_upscale", false)
				var tp: Resource = null
				if cfg[1] != null:
					tp = (load("res://game/looks/tape_studio.tres") as Resource).duplicate()
					for k in cfg[1]:
						tp.set(k, cfg[1][k])
				_vo.set(&"tape", tp)
			elif fx:
				vp.msaa_3d = Viewport.MSAA_4X
				_vo.set(&"edge_aa", 1.0)
				_vo.set(&"edge_coverage", true)
				ProjectSettings.set_setting("n64/render/edge_upscale", false)
				_fx_setup(cfg[0])
			elif mist:
				vp.msaa_3d = Viewport.MSAA_4X
				_vo.set(&"edge_aa", 1.0)
				_vo.set(&"edge_coverage", true)
				_zone.set(&"ground_mist", cfg[1])
				_zone.set(&"_mist_amount", cfg[1])
				var m = _zone.get(&"_mist")
				if m:
					m.dither = cfg[2]
					m.layer_count = cfg[3]
					m.patch = cfg[4]
					m.rebuild()
					m.amount = cfg[1]
			else:
				vp.msaa_3d = cfg[1]
				_vo.set(&"edge_aa", cfg[2])
				_vo.set(&"edge_coverage", cfg[3])
				ProjectSettings.set_setting("n64/render/edge_upscale", cfg[4])
			await _frames(WARM)
			if fx:
				if cfg[0] == "+ 2 combiners: bloom + haze":
					# (set straight on the effect: nothing re-sets looks while frames are forced)
					_vo.call(&"set_combiners", [[(load("res://game/looks/combiners/market_lamp_bloom.tres") as ScreenLook).combiner, 0.5],
						[(load("res://game/looks/combiners/market_haze_glow.tres") as ScreenLook).combiner, 0.5]])
					for k in 3:
						RenderingServer.force_draw(false)
				print("[bench] combiners live: ", _vo.get(&"_comb_count"))
			for c in get_tree().root.find_children("*", "CanvasLayer", true, false):
				c.visible = c.name == &"EdgeUpscale" and c.visible and not (cfg.size() > 5 and cfg[5] == "compute")
			if cfg.size() > 5 and cfg[5] == "layer":
				_vo.set(&"edge_upscale", 0.0)  # (RenderScale doesn't run while frames are forced)
			# Frames rendered back to back without presenting (force_draw, no swap): the
			# display's refresh (ProMotion holds a presented frame to 120 Hz whatever vsync
			# says) can't cap them. Timed in batches of 10, ended by a GPU sync.
			var ft := []
			var gt := []
			RenderingServer.force_sync()
			for i in MEASURE / 10:
				var t0 := Time.get_ticks_usec()
				for j in 10:
					RenderingServer.force_draw(false)
				RenderingServer.force_sync()
				ft.append((Time.get_ticks_usec() - t0) / 10000.0)
				gt.append(0.0)
			ft.sort()
			gt.sort()
			var r := {scale = sc, lines = int(round(sc * DisplayServer.window_get_size().y)), config = cfg[0],
				median_ms = snappedf(ft[ft.size() / 2], 0.001), p90_ms = snappedf(ft[int(ft.size() * 0.9)], 0.001),
				gpu_ms = snappedf(gt[gt.size() / 2], 0.001)}
			_results.append(r)
			print("[bench] %4d lines  %-28s median %6.3f ms  p90 %6.3f ms  gpu %6.3f ms" % [r.lines, r.config, r.median_ms, r.p90_ms, r.gpu_ms])
	var f := FileAccess.open(OS.get_environment("OUT"), FileAccess.WRITE)
	f.store_string(JSON.stringify({window = [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y], results = _results}, "\t"))
	f.close()
	get_tree().quit()
