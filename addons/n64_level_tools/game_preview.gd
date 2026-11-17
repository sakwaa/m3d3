@tool
class_name GamePreview
extends RefCounted
## Editor "game view" (the Paint screen's Game view switch): what the running game sets
## every frame that the editor never does, for the open zone at the preview hour - the
## zone's fog (Zone.fog_for: colour lit by the hour, distances closing in at night, the
## weather's fog), the ambient light, lamps glowing in the fog (the nearest four), and the
## night world tint (DayNightSun.world_tint). Editor-only helpers (NPC spots and paths) are
## hidden meanwhile. `clear` puts the project's own shader globals back.

const FOG_GLOBALS := [&"n64_fog_color", &"n64_fog", &"n64_fog_origin", &"n64_fog_height", &"n64_ambient_light",
	&"n64_fog_lights", &"n64_fog_light_pos0", &"n64_fog_light_pos1", &"n64_fog_light_pos2", &"n64_fog_light_pos3",
	&"n64_fog_light_col0", &"n64_fog_light_col1", &"n64_fog_light_col2", &"n64_fog_light_col3"]
const HELPER_SCRIPTS := ["res://game/world/npc_spot.gd", "res://game/world/npc_path.gd"]

static var _hidden: Array[Node3D] = []
static var _lights: Array[Light3D] = []
static var _lights_of: Node


## Sets the game's per-frame globals for `scene` at `hour`, seen from `cam`. `full` off:
## only the fog's colour and the ambient light (what the far mountains and effects take
## from the hour: set whenever the editor's preview hour changes), the editor's own fog
## distances and amount left alone.
static func apply(scene: Node, hour: float, cam: Camera3D, full := true) -> void:
	if scene == null:
		return
	var sched := LightingSchedule.load_project()
	var sky: Node = null
	var sun: Node = null
	for n in scene.get_children():
		if sky == null and n is WorldEnvironment and n.get(&"preview_weather") != null:
			sky = n
		if sun == null and n is DirectionalLight3D and n.get(&"world_night") != null:
			sun = n
	var w := {}
	if sky:
		var table := WeatherTable.load_project()
		if table and not table.presets.is_empty():
			w = WeatherTable.sample(table.find(sky.get(&"preview_weather")), sched, hour)
	var fog: FogSettings = scene.get(&"fog") as FogSettings
	var t := Zone.fog_for(fog, false, sky != null, w, sched, hour)
	# Globals as Zone._update_fog sets them.
	var lin := (t.color as Color).srgb_to_linear()
	lin.a = t.grid
	RenderingServer.global_shader_parameter_set(&"n64_fog_color", lin)
	var ambient := sched.light_at(hour) if sky and sched else Color.WHITE
	RenderingServer.global_shader_parameter_set(&"n64_ambient_light", ambient.srgb_to_linear())
	if not full:
		return
	var code := {FogSettings.Sampling.PER_PIXEL: 0.0, FogSettings.Sampling.PER_VERTEX: 1.0, FogSettings.Sampling.SOFT_GRID: 2.0}
	var start: float = t.start
	var end: float = maxf(t.end, start + 0.5)
	var mode: float = (0.0 if t.curve == FogSettings.FogCurve.N64_DEPTH else 1.0) + 2.0 * float(code[t.sampling])
	RenderingServer.global_shader_parameter_set(&"n64_fog", Vector4(start, end, mode, t.amount))
	RenderingServer.global_shader_parameter_set(&"n64_fog_origin", cam.global_position if cam else Vector3.ZERO)
	var floor_y: float = scene.get(&"fog_floor") if scene.get(&"fog_floor") != null else 0.0
	RenderingServer.global_shader_parameter_set(&"n64_fog_height", Vector4(floor_y, float(w.get("fog_height", 0.0)), float(w.get("fog_height_thin", 0.0)), 0.0))
	_fog_lights(scene, cam, end, t)
	if sun:
		RenderingServer.global_shader_parameter_set(&"n64_world_tint",
			DayNightSun.world_tint(hour, sun.get(&"world_day"), sun.get(&"world_dusk"), sun.get(&"world_night")))


## The four lamps nearest the camera (within their range + the fog end) glowing in the fog.
static func _fog_lights(scene: Node, cam: Camera3D, fog_end: float, t: Dictionary) -> void:
	if _lights_of != scene:
		_lights_of = scene
		_lights.clear()
		for n in scene.find_children("*", "Light3D", true, false):
			if not n is DirectionalLight3D:
				_lights.append(n)
	var picks := []
	if cam and float(t.amount) > 0.001:
		for l in _lights:
			if not is_instance_valid(l) or not l.is_visible_in_tree() or l.light_energy <= 0.01:
				continue
			var r: float = l.get("omni_range") if l is OmniLight3D else l.get("spot_range")
			var d := cam.global_position.distance_to(l.global_position)
			if d < r + fog_end:
				picks.append([l.light_energy * (1.0 - d / (r + fog_end)), l, r])
		picks.sort_custom(func(a, b): return a[0] > b[0])
	for i in 4:
		var pos := Vector4(0, -10000, 0, 0)
		var col := Vector4.ZERO
		if i < mini(picks.size(), int(t.lights)):
			var l: Light3D = picks[i][1]
			var c := l.light_color.srgb_to_linear() * minf(l.light_energy, 2.0)
			pos = Vector4(l.global_position.x, l.global_position.y, l.global_position.z, picks[i][2])
			col = Vector4(c.r, c.g, c.b, 1.0)
		RenderingServer.global_shader_parameter_set(StringName("n64_fog_light_pos%d" % i), pos)
		RenderingServer.global_shader_parameter_set(StringName("n64_fog_light_col%d" % i), col)
	var follow := 1.0 if t.get("light_sampling", 0) == FogSettings.LightSampling.FOLLOW_FOG else 0.0
	RenderingServer.global_shader_parameter_set(&"n64_fog_lights", Vector4(float(t.tint), float(t.halos), follow, 1.0))


## Hides (true) / shows again (false) the editor-only helpers in `scene`.
static func hide_helpers(scene: Node, hide: bool) -> void:
	for n in _hidden:
		if is_instance_valid(n):
			n.visible = true
	_hidden.clear()
	if not hide or scene == null:
		return
	for n in scene.find_children("*", "Node3D", true, false):
		var sc: Script = n.get_script()
		if sc and sc.resource_path in HELPER_SCRIPTS and (n as Node3D).visible:
			(n as Node3D).visible = false
			_hidden.append(n)


## Back to the editor's own view: the project's fog / light globals, helpers shown.
static func clear() -> void:
	hide_helpers(null, false)
	_lights_of = null
	for g in FOG_GLOBALS:
		var v = ProjectSettings.get_setting("shader_globals/" + String(g))
		if v is Dictionary and v.has("value"):
			RenderingServer.global_shader_parameter_set(g, v.value)
	# (The hour's fog colour / ambient stay: the editor's preview hour sets them.)
	if Engine.has_meta(&"n64_level_plugin"):
		var h := float(EditorInterface.get_editor_settings().get_project_metadata("n64_level_tools", "preview_hour", 12.0))
		apply(EditorInterface.get_edited_scene_root(), h, null, false)
