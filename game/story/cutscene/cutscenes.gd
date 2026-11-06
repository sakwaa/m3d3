extends Node
## Plays Cutscenes. Autoloaded as `Cutscenes`: `Cutscenes.play(cutscene)` (from a
## TriggerVolume, a dialogue / schedule "Play cutscene" effect, or code; queued while a
## conversation or another cutscene runs).
##
## While one plays: the clock is held, actors in it (and the player) are `scripted` (they
## run their normal movement, fed by the cues), the player camera's director is overridden
## by the shots, black bars show. Dialogue lines can hold the timeline; so can "wait for a
## button". Holding Skip (Enter / Start) skips it when the cutscene allows (by default only
## once it's been seen): remaining Story events still apply and actors land where it
## leaves them. Finishing (or skipping) sets its "seen" flag.

signal started(cutscene: Cutscene)
signal finished(cutscene: Cutscene, skipped: bool)

const SKIP_ACTION := &"skip_cutscene"
const SKIP_HOLD := 0.8
const BAR_HEIGHT := 0.11  # of the screen
const ARRIVED := 0.12

var playing: Cutscene
var time := 0.0

var _cues: Array[CutsceneCue] = []
var _next := 0
var _moves := {}  # actor id -> {target, run, facing, until}
var _faces := {}  # actor id -> world direction
var _loops := {}  # actor id -> clip
var _touched := {}  # actor node -> true
var _waiting_line := false
var _waiting_input := false
var _skip_hold := 0.0
var _queue: Array[Cutscene] = []

var _layer: CanvasLayer
var _bars: Array[ColorRect] = []
var _bar_amount := 0.0
var _fade: ColorRect
var _fade_from := Color(0, 0, 0, 0)
var _fade_to := Color(0, 0, 0, 0)
var _fade_t := 1.0
var _fade_len := 0.0
var _skip_label: Label


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not InputMap.has_action(SKIP_ACTION):
		InputMap.add_action(SKIP_ACTION)
		var k := InputEventKey.new()
		k.physical_keycode = KEY_ENTER
		InputMap.action_add_event(SKIP_ACTION, k)
		var j := InputEventJoypadButton.new()
		j.button_index = JOY_BUTTON_START
		InputMap.action_add_event(SKIP_ACTION, j)
	_layer = CanvasLayer.new()
	_layer.layer = 80
	add_child(_layer)
	_fade = ColorRect.new()
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.color = Color(0, 0, 0, 0)
	_layer.add_child(_fade)
	for top in [true, false]:
		var bar := ColorRect.new()
		bar.color = Color.BLACK
		bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		bar.set_anchors_preset(Control.PRESET_TOP_WIDE if top else Control.PRESET_BOTTOM_WIDE)
		_layer.add_child(bar)
		_bars.append(bar)
	_skip_label = Label.new()
	_skip_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_skip_label.position -= Vector2(220, 40)
	_skip_label.add_theme_color_override(&"font_outline_color", Color.BLACK)
	_skip_label.add_theme_constant_override(&"outline_size", 4)
	_skip_label.visible = false
	_layer.add_child(_skip_label)
	_play_editor_preview.call_deferred()


## Editor "▶ Play in game" (Cutscenes tab): plays the cutscene named in the hand-off file
## once the zone has the player. Editor runs only; the file never ships.
func _play_editor_preview() -> void:
	const PREVIEW_FILE := "user://cutscene_preview.json"
	if not OS.has_feature("editor") or not FileAccess.file_exists(PREVIEW_FILE):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(PREVIEW_FILE))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PREVIEW_FILE))
	if not data is Dictionary or not ResourceLoader.exists(str(data.get("cutscene", ""))):
		return
	for i in 120:
		if get_tree().get_first_node_in_group(&"player"):
			break
		await get_tree().process_frame
	await get_tree().create_timer(0.5).timeout
	play(load(data.cutscene))


## Plays `cutscene` now, or once the current conversation / cutscene is over.
func play(cutscene: Cutscene) -> void:
	if cutscene == null:
		return
	if playing or Talk.active:
		_queue.append(cutscene)
		return
	_start(cutscene)


func is_playing() -> bool:
	return playing != null


func can_skip() -> bool:
	if playing == null:
		return false
	match playing.skip:
		Cutscene.Skip.ALWAYS:
			return true
		Cutscene.Skip.SEEN:
			return GameState.get_flag(playing.seen_flag(), false) == true
	return false


func _start(c: Cutscene) -> void:
	playing = c
	time = 0.0
	_cues = c.sorted()
	_next = 0
	_moves.clear()
	_faces.clear()
	_loops.clear()
	_touched.clear()
	_waiting_line = false
	_waiting_input = false
	_skip_hold = 0.0
	GameState.hold_clock(self)
	var player := _actor(CutsceneCue.PLAYER)
	if player:
		_take(player)
	started.emit(c)


func _take(a: Node) -> void:
	if a is Actor and not _touched.has(a):
		_touched[a] = true
		a.scripted = true
		a.intent.clear()
		a.velocity = Vector3(0.0, a.velocity.y, 0.0)


func _process(delta: float) -> void:
	_update_fade(delta)
	_bar_amount = move_toward(_bar_amount, 1.0 if playing and playing.letterbox else 0.0, delta * 3.0)
	var h := get_viewport().get_visible_rect().size.y * BAR_HEIGHT * smoothstep(0.0, 1.0, _bar_amount)
	_bars[0].offset_bottom = h
	_bars[1].offset_top = -h
	if playing == null:
		_skip_label.visible = false
		if not _queue.is_empty() and not Talk.active:
			_start(_queue.pop_front())
		return
	if _update_skip(delta):
		return
	if _waiting_line and not Talk.active:
		_waiting_line = false
	if _waiting_input and (Input.is_action_just_pressed(&"interact") or Input.is_action_just_pressed(&"attack")):
		_waiting_input = false
	var held := _waiting_line or _waiting_input
	if not held:
		time += delta
	while not held and _next < _cues.size() and _cues[_next].time <= time:
		_fire(_cues[_next])
		_next += 1
		held = _waiting_line or _waiting_input
	_drive_actors(delta)
	_drive_camera()
	if not held and _next >= _cues.size() and time >= playing.length:
		_finish(false)


func _fire(c: CutsceneCue) -> void:
	match c.kind:
		CutsceneCue.Kind.ACTOR:
			var a := _actor(c.actor)
			if a == null:
				push_warning("Cutscene %s: no actor '%s' in the zone." % [playing.seen_flag(), c.actor])
				return
			_take(a)
			match c.action:
				CutsceneCue.Action.WALK, CutsceneCue.Action.RUN:
					_faces.erase(c.actor)
					_moves[c.actor] = {target = c.position, run = c.action == CutsceneCue.Action.RUN, facing = c.facing,
						until = c.time + (c.duration if c.duration > 0.0 else 1e9)}
				CutsceneCue.Action.TELEPORT:
					_moves.erase(c.actor)
					a.global_position = c.position
					a.velocity = Vector3.ZERO
					if a is Actor:
						a.facing = Cutscene.facing_vector(c.facing)
				CutsceneCue.Action.FACE:
					var other := _actor(c.face_actor) if c.face_actor != &"" else null
					var dir := Cutscene.facing_vector(c.facing)
					if other:
						dir = other.global_position - a.global_position
						dir.y = 0.0
					if dir.length() > 0.01:
						_faces[c.actor] = dir.normalized()
				CutsceneCue.Action.ANIMATE:
					if a is Actor and not a.play_cue_animation(c.animation):
						push_warning("Cutscene %s: '%s' has no animation '%s'." % [playing.seen_flag(), c.actor, c.animation])
					if c.loop and c.animation != &"":
						_loops[c.actor] = c.animation
					else:
						_loops.erase(c.actor)
				CutsceneCue.Action.SHOW:
					a.visible = true
				CutsceneCue.Action.HIDE:
					a.visible = false
		CutsceneCue.Kind.LINE:
			if c.dialogue:
				Talk.start(c.dialogue, c.entry, _actor(c.speaker) if c.speaker != &"" else null)
				_waiting_line = c.wait
		CutsceneCue.Kind.EVENT:
			_fire_event(c)


func _fire_event(c: CutsceneCue) -> void:
	match c.event:
		CutsceneCue.Event.STORY:
			for e in c.effects:
				if e:
					e.apply(GameState)
		CutsceneCue.Event.EFFECT:
			Effects.spawn(c.effect, c.position)
		CutsceneCue.Event.SOUND:
			Sfx.play(c.sound, c.position)
		CutsceneCue.Event.MUSIC:
			# Duck typed: whatever plays music joins the "music_player" group.
			var m := get_tree().get_first_node_in_group(&"music_player")
			if m and m.has_method(&"play_song"):
				m.call(&"play_song", c.sound)
		CutsceneCue.Event.FADE:
			_fade_from = _fade.color
			_fade_to = c.color
			_fade_len = c.duration
			_fade_t = 0.0
		CutsceneCue.Event.WAIT_INPUT:
			_waiting_input = true
		CutsceneCue.Event.SET_TIME:
			GameState.set_time(c.hour)


func _drive_actors(delta: float) -> void:
	for id in _moves.keys():
		var a := _actor(id) as Actor
		if a == null:
			_moves.erase(id)
			continue
		var m: Dictionary = _moves[id]
		var to: Vector3 = m.target - a.global_position
		to.y = 0.0
		if to.length() > ARRIVED and time < m.until:
			a.intent.move = to.normalized() * (1.0 if m.run else 0.5)
		else:
			a.intent.move = Vector3.ZERO
			_faces[id] = Cutscene.facing_vector(m.facing)
			_moves.erase(id)
	for id in _faces.keys():
		var a := _actor(id) as Actor
		if a == null:
			_faces.erase(id)
			continue
		var want: Vector3 = _faces[id]
		a.facing = a.facing.slerp(want, clampf(8.0 * delta, 0.0, 1.0)).normalized() if a.facing.dot(want) > -0.99 else want
		if a.facing.dot(want) > 0.999:
			a.facing = want
			_faces.erase(id)
	for id in _loops:
		var a := _actor(id) as Actor
		if a and not a.cue_animation_playing():
			a.play_cue_animation(_loops[id])


func _drive_camera() -> void:
	var player := _actor(CutsceneCue.PLAYER)
	var director: Variant = player.get(&"director") if player else null
	if director == null:
		return
	var cam := playing.camera_at(time, _actor_position, _zone_view)
	if cam.is_empty():
		return
	director.override = true
	director.view.global_transform = cam.xf
	director.view.fov = cam.fov


func _actor_position(id: StringName) -> Variant:
	var a := _actor(id)
	return a.global_position if a else null


func _zone_view(id: int) -> Camera3D:
	for z in get_tree().get_nodes_in_group(&"camera_zones"):
		if z.camera_id == id:
			return z.view()
	return null


## Skip held long enough: skips (true = done for this frame).
func _update_skip(delta: float) -> bool:
	var allowed := can_skip()
	_skip_label.visible = allowed
	if not allowed:
		return false
	if Input.is_action_pressed(SKIP_ACTION):
		_skip_hold += delta
	else:
		_skip_hold = 0.0
	_skip_label.text = "Hold Enter to skip" + ("  " + "▮".repeat(int(_skip_hold / SKIP_HOLD * 6.0)) if _skip_hold > 0.0 else "")
	if _skip_hold >= SKIP_HOLD:
		_skip()
		return true
	return false


func _skip() -> void:
	if Talk.active:
		Talk.call(&"_end")
	# Moves under way finish at once.
	for id in _moves:
		var a := _actor(id)
		if a:
			a.global_position = _moves[id].target
			if a is Actor:
				a.facing = Cutscene.facing_vector(_moves[id].facing)
	_moves.clear()
	# What's left: story changes and the clock apply; actors land where they'd end up.
	for i in range(_next, _cues.size()):
		var c := _cues[i]
		match c.kind:
			CutsceneCue.Kind.EVENT:
				if c.event in [CutsceneCue.Event.STORY, CutsceneCue.Event.SET_TIME]:
					_fire_event(c)
			CutsceneCue.Kind.ACTOR:
				var a := _actor(c.actor)
				if a == null:
					continue
				_take(a)
				match c.action:
					CutsceneCue.Action.WALK, CutsceneCue.Action.RUN, CutsceneCue.Action.TELEPORT:
						a.global_position = c.position
						if a is Actor:
							a.facing = Cutscene.facing_vector(c.facing)
					CutsceneCue.Action.SHOW:
						a.visible = true
					CutsceneCue.Action.HIDE:
						a.visible = false
	_next = _cues.size()
	_finish(true)


func _finish(skipped: bool) -> void:
	var c := playing
	GameState.set_flag(c.seen_flag(), true)
	GameState.release_clock(self)
	for a in _touched:
		if is_instance_valid(a):
			a.scripted = false
			a.intent.clear()
			a.play_cue_animation(&"")
	var player := _actor(CutsceneCue.PLAYER)
	var director: Variant = player.get(&"director") if player else null
	if director:
		director.resume()
	if _fade.color.a > 0.0 or _fade_to.a > 0.0:
		_fade_from = _fade.color
		_fade_to = Color(_fade.color, 0.0)
		_fade_len = 0.4
		_fade_t = 0.0
	playing = null
	_touched.clear()
	finished.emit(c, skipped)


func _update_fade(delta: float) -> void:
	if _fade_t >= 1.0:
		return
	_fade_t = minf(_fade_t + delta / maxf(_fade_len, 0.001), 1.0)
	_fade.color = _fade_from.lerp(_fade_to, _fade_t)


## "player", a character id (the NPC playing it), or a node of that name in the zone.
func _actor(id: StringName) -> Node3D:
	if id == &"":
		return null
	if id == CutsceneCue.PLAYER:
		return get_tree().get_first_node_in_group(&"player") as Node3D
	for a in get_tree().get_nodes_in_group(&"actors"):
		if a.get(&"character") == id:
			return a
	var scene := get_tree().current_scene
	return scene.find_child(String(id), true, false) as Node3D if scene else null
