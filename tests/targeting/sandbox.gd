extends Node3D
# Z-targeting sandbox (play it: tests/targeting/sandbox.tscn). The player starts in the
# middle facing north:
#   north: a Wolfos pack (real fights; 22 m off, just outside battle music range);
#   south: enemy dummies behind pillars (line of sight), a Keese-like one hard to shake
#          (11 m in / 50 m out) and a boss post far out (40 m in);
#   east:  a lane of posts, one per range type;
#   west:  a little town: NPCs to talk to, signs facing different ways (read from in front
#          only), one behind a wall, two NPCs side by side (nearest offers);
#   south-east: the combat arena - training dummies (one shielded: hit it from the side),
#          Wolfos on demand, and the hit juice (OoT remake) to switch piece by piece.
# The arrow's target and the locked one show rings on the ground round their feet (solid:
# locks within; faint: lets go past).
# Keys: T hold / switch mode, R rings on / off, 8 respawn the pack, 9 two Wolfos in the
# arena, 1-4 hit juice pieces (hitstop, flash, burst, trail), 0 all juice on / off, 5 the
# strike aim bend on / off, 6 sword power 1-3 (the armoured dummy needs 3), 7 edge lead
# on / off, P show strike points. Top right: what the lock
# sees (target, arrow, timer, grace, battle music, talk offer).

const WOLFOS := preload("res://game/actors/enemies/wolfos/wolfos.gd")
const KIND_COLORS := {Targetable.Kind.ENEMY: Color(0.75, 0.25, 0.2), Targetable.Kind.NPC: Color(0.3, 0.4, 0.85),
	Targetable.Kind.POI: Color(0.6, 0.45, 0.3), Targetable.Kind.BOSS: Color(0.5, 0.15, 0.4)}

var player: Actor
var rings: Node3D
var _ring_sets := {}  # Targetable -> its rings (made when first shown)
var pack: Array[Node] = []
var info: Label
var arena_wolfos: Array[Node] = []
const ARENA := Vector3(26, 0, 24)


func _ready() -> void:
	_ground()
	_light()
	rings = Node3D.new()
	rings.name = "Rings"
	add_child(rings)
	player = (load("res://player/player.tscn") as PackedScene).instantiate()
	add_child(player)
	player.global_position = Vector3(0, 0.1, 0)
	player.facing = Vector3(0, 0, -1)
	_pack()
	_dummies()
	_lane()
	_town()
	_arena()
	var hud := CanvasLayer.new()
	hud.layer = 5
	add_child(hud)
	info = Label.new()
	info.anchor_left = 1.0
	info.anchor_right = 1.0
	info.offset_left = -470
	info.offset_top = 150
	info.add_theme_font_size_override(&"font_size", 22)
	info.add_theme_color_override(&"font_outline_color", Color.BLACK)
	info.add_theme_constant_override(&"outline_size", 6)
	hud.add_child(info)


func _unhandled_key_input(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k == null or not k.pressed or k.echo:
		return
	match k.keycode:
		KEY_T:
			player.lock.switch_mode = not player.lock.switch_mode
		KEY_R:
			rings.visible = not rings.visible
		KEY_8:
			_pack()
		KEY_9:
			_arena_wolfos()
		KEY_1, KEY_2, KEY_3, KEY_4:
			var key: String = ["hitstop", "flash", "burst", "trail"][k.keycode - KEY_1]
			Combat.juice[key] = not Combat.juice[key]
		KEY_P:
			StrikePoint.show = not StrikePoint.show
		KEY_5:
			StrikeRig.enabled = not StrikeRig.enabled
		KEY_6:
			var t: BladeTrigger = player._sword_trigger()
			t.power = t.power % 3 + 1
		KEY_7:
			StrikeRig.edge_lead = not StrikeRig.edge_lead
		KEY_0:
			var on := not Combat.juice.values().all(func(v): return v)
			for key in Combat.juice:
				Combat.juice[key] = on


func _process(_delta: float) -> void:
	_show_rings()
	if OS.get_environment("SHOT") != "" and Engine.get_frames_drawn() == 90:
		# Overview: SHOT=file.png renders the layout from above and quits.
		var cam := Camera3D.new()
		add_child(cam)
		cam.global_position = Vector3(8, 55, 20)
		cam.look_at(Vector3(8, 0, -2))
		cam.make_current()
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(OS.get_environment("SHOT"))
		get_tree().quit()
	var l: TargetLock = player.lock
	var name_of := func(t: Targetable) -> String:
		return "-" if t == null or not is_instance_valid(t) else (t.label if t.label != "" else String(t.get_parent().name))
	var talk: Node3D = Talk.best_talkable()
	info.text = "\n".join([
		"Z mode: %s   (T)" % ("SWITCH" if l.switch_mode else "HOLD"),
		"target: %s%s" % [name_of.call(l.target), "  (hostile)" if l.hostile() else ""],
		"arrow: %s" % name_of.call(l.hover),
		"timer: %.1f  %s%s%s" % [l._timer, "grace " if l.in_grace() else "", "PARALLEL " if l.parallel else "",
			"forced" if l.forced else ""],
		"distance: %s" % ("%.1f m  (lets go at %.1f)" % [l.target.origin().distance_to(player.global_position),
			l.target.release_range()] if l.target else "-"),
		"battle music: %.2f  %s" % [l.battle_level, name_of.call(l.bgm_enemy)],
		"talk offer: %s" % (String(talk.get_parent().name) if talk else "-"),
		"juice: %s" % "  ".join(Combat.juice.keys().map(func(key): return "%d %s %s" % [
			["hitstop", "flash", "burst", "trail"].find(key) + 1, key, "ON" if Combat.juice[key] else "off"])),
		"strike aim bend (5): %s   edge leads (7): %s   strike points (P): %s" % ["ON" if StrikeRig.enabled else "off",
			"ON" if StrikeRig.edge_lead else "off", "shown" if StrikePoint.show else "hidden"],
		"sword power (6): %d   (armour 2: bounces at 1-2, cuts at 3)" % player.blade_power(),
		"rings R  pack 8  arena wolfos 9  juice 1-4 / 0",
	])


# --- Areas ---------------------------------------------------------------------------------

func _pack() -> void:
	for w in pack:
		if is_instance_valid(w):
			w.queue_free()
	pack.clear()
	for x in [-3.0, 0.0, 3.0]:
		var w: Node3D = WOLFOS.new()
		w.name = "Wolfos"
		w.position = Vector3(x, 0.1, -22.0 - absf(x))
		w.rotation.y = 0.0
		add_child(w)
		pack.append(w)


func _dummies() -> void:
	# Behind pillars at different distances (south), facing the player's start.
	for spec in [[Vector3(-4, 0, 8), "Dummy near"], [Vector3(2, 0, 12), "Dummy behind pillar"], [Vector3(6, 0, 9), "Dummy right"]]:
		_post(spec[0], Targetable.Kind.ENEMY, Targetable.Reach.KIND, spec[1])
	_pillar(Vector3(2, 0, 9.5), Vector3(2.2, 3.0, 0.8))
	_pillar(Vector3(-7, 0, 14), Vector3(0.8, 3.0, 4.0))
	_post(Vector3(-2, 0, 18), Targetable.Kind.ENEMY, Targetable.Reach.CLINGY, "Keese-like (11 in / 50 out)")
	_post(Vector3(0, 0, 42), Targetable.Kind.BOSS, Targetable.Reach.BOSS, "Boss (40 in / 49 out)", 3.0)


func _lane() -> void:
	# One post per range type, east along the lane (skipping the two huge ones).
	var x := 12.0
	var names := ["0 sign", "1 short", "2 clingy", "3 default", "4 far", "5 boss", "6 townsfolk", "7 close", "8 medium"]
	for i in names.size():
		_post(Vector3(x, 0, -3.0), Targetable.Kind.POI, i as Targetable.Reach, "Range " + names[i])
		x += 7.0


func _town() -> void:
	var lines := ["Lovely day for the market.", "Mind the dogs up north.", "I heard the clock tower bell last night."]
	var npcs := [[Vector3(-12, 0, -2), 0.0], [Vector3(-15, 0, 3), PI * 0.5], [Vector3(-16.2, 0, 3.6), PI * 0.5]]
	for i in npcs.size():
		var n := _figure(npcs[i][0], Targetable.Kind.NPC, 1.6, "Villager %d" % (i + 1))
		n.rotation.y = npcs[i][1]
		var t := Talkable.new()
		t.prompt = "Talk"
		t.radius = 4.0
		t.target_kind = Targetable.Kind.NPC
		t.dialogue = _dialogue("npc_%d" % i, lines[i], DialogueLine.Style.BOX, StringName("Villager %d" % (i + 1)))
		n.add_child(t)
	# Signs facing east, south, west and one behind a wall.
	# (A sign's face is its +Z.)
	for spec in [[Vector3(-10, 0, -8), PI * 0.5, "East-facing sign: read me from the east."],
			[Vector3(-14, 0, -8), 0.0, "South-facing sign."],
			[Vector3(-18, 0, -8), -PI * 0.5, "West-facing sign."],
			[Vector3(-22, 0, -2), PI * 0.5, "Behind the wall: walk round it to read me (no targeting through it)."]]:
		var s := Signpost.new()
		s.text = spec[2]
		s.position = spec[0]
		s.rotation.y = spec[1]
		add_child(s)
	_pillar(Vector3(-20, 0, -2), Vector3(0.6, 2.5, 5.0))


## The combat arena (south-east): a fenced square, dummies in a row, one with a shield.
func _arena() -> void:
	var c := ARENA
	for spec in [[Vector3(0, 0, -6), Vector3(16, 1.0, 0.4)], [Vector3(0, 0, 6), Vector3(16, 1.0, 0.4)],
			[Vector3(8, 0, 0), Vector3(0.4, 1.0, 12)]]:
		_pillar(c + spec[0], spec[1])
	for i in 3:
		var d := CombatDummy.new()
		d.name = "Dummy %d" % (i + 1)
		d.position = c + Vector3(-4.0 + i * 3.0, 0.1, -2.5)
		add_child(d)
	var k := CombatDummy.new()
	k.name = "Armoured dummy"
	k.armored = true
	k.position = c + Vector3(-1.5, 0.1, 2.5)
	add_child(k)
	var s := CombatDummy.new()
	s.name = "Shield dummy"
	s.shield = true
	s.color = Color(0.55, 0.6, 0.75)
	s.position = c + Vector3(3.5, 0.1, 2.5)
	add_child(s)
	var label := Label3D.new()
	label.text = "COMBAT ARENA\n1-4 / 0 juice   9 Wolfos"
	label.position = c + Vector3(-7.5, 3.0, 0)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 64
	label.outline_size = 14
	add_child(label)


func _arena_wolfos() -> void:
	for w in arena_wolfos:
		if is_instance_valid(w):
			w.queue_free()
	arena_wolfos.clear()
	for x in [-2.0, 2.0]:
		var w: Node3D = WOLFOS.new()
		w.name = "Arena Wolfos"
		w.position = ARENA + Vector3(x, 0.1, 3.5)
		add_child(w)
		arena_wolfos.append(w)


# --- Pieces --------------------------------------------------------------------------------

func _figure(at: Vector3, kind: int, h: float, title: String) -> Node3D:
	var n := Node3D.new()
	n.name = title
	n.position = at
	add_child(n)
	var mi := MeshInstance3D.new()
	var m := CapsuleMesh.new()
	m.height = h
	m.radius = 0.3
	mi.mesh = m
	mi.position.y = h * 0.5
	var mat := StandardMaterial3D.new()
	mat.albedo_color = KIND_COLORS[kind]
	mi.material_override = mat
	n.add_child(mi)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.height = h
	shape.radius = 0.3
	cs.shape = shape
	cs.position.y = h * 0.5
	body.add_child(cs)
	n.add_child(body)
	var label := Label3D.new()
	label.text = title
	label.position.y = h + 0.5
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 40
	label.outline_size = 10
	n.add_child(label)
	return n


func _post(at: Vector3, kind: int, reach: int, title: String, h := 1.6) -> Targetable:
	var n := _figure(at, kind, h, title)
	var t := Targetable.new()
	t.kind = kind
	t.range_type = reach
	t.position.y = h * 0.85
	t.label = title
	n.add_child(t)
	return t


func _pillar(at: Vector3, size: Vector3) -> void:
	var b := StaticBody3D.new()
	b.position = at + Vector3.UP * size.y * 0.5
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	b.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.53, 0.5)
	mi.material_override = mat
	b.add_child(mi)
	add_child(b)


## Rings under the arrow's target and the locked one, following their feet.
func _show_rings() -> void:
	var l: TargetLock = player.lock
	var want := []
	for t in [l.hover, l.target]:
		if t and is_instance_valid(t) and not want.has(t):
			want.append(t)
	for t in _ring_sets.keys():
		if not is_instance_valid(t):
			_ring_sets[t].queue_free()
			_ring_sets.erase(t)
	for t: Targetable in want:
		if not _ring_sets.has(t):
			_ring_sets[t] = _rings_for(t)
	for t in _ring_sets:
		var set: Node3D = _ring_sets[t]
		set.visible = want.has(t)
		if set.visible:
			set.global_position = t.origin()


## Rings round a target's feet: locks within (solid), lets go past (faint).
func _rings_for(t: Targetable) -> Node3D:
	var set := Node3D.new()
	rings.add_child(set)
	_ring(set, t.acquire_range(), Color(1.0, 0.9, 0.3, 0.9))
	if t.release_range() < 80.0:
		_ring(set, t.release_range(), Color(1.0, 0.5, 0.2, 0.45))
	return set


func _ring(parent: Node3D, radius: float, color: Color) -> void:
	var at := Vector3.ZERO
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	var n := clampi(int(radius * 6.0), 32, 256)
	for i in n + 1:
		var a := TAU * i / n
		im.surface_add_vertex(at + Vector3(cos(a) * radius, 0.03, sin(a) * radius))
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	parent.add_child(mi)


func _dialogue(id: String, text: String, style: int, speaker := &"") -> Dialogue:
	var d := Dialogue.new()
	d.id = StringName(id)
	d.start = "text"
	var line := DialogueLine.new()
	line.id = "text"
	line.style = style
	line.speaker = speaker
	line.text = text
	d.nodes.append(line)
	return d


func _ground() -> void:
	var floor := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(200, 1, 200)
	cs.shape = sh
	floor.add_child(cs)
	floor.position.y = -0.5
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sh.size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.55, 0.34)
	mi.material_override = mat
	floor.add_child(mi)
	add_child(floor)


func _light() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.5, 0.6, 0.75)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.6, 0.65)
	env.environment = e
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	# No shadow map (it drew every mesh four more times): actors bring their own projected
	# shadows, as in the game.
	sun.shadow_enabled = false
	add_child(sun)
