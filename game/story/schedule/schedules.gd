extends Node
## NPC schedules at runtime. Autoloaded as `Schedules`. Every frame each NpcSchedule in
## the story database picks its current part (ScheduleEntry) from the clock, day,
## weather, flags and items. Where everyone is follows from the time alone, so nothing is
## simulated off-screen: entering a zone (or a schedule changing) spawns the NPCs whose
## part is in it, already where they'd be (halfway along a walk, say), and removes those
## whose part is elsewhere. A part's effects run when it starts, wherever the NPC is.
## While a conversation holds the clock, schedules hold too.

signal entry_changed(schedule: NpcSchedule, entry: ScheduleEntry)

## Schedule id -> its Npc in the current zone.
var npcs := {}
## Schedule id -> current ScheduleEntry (null = nowhere).
var current := {}

var _zone: Node
var _paths := {}  # path id -> NpcPath in the current zone
var _spots := {}  # spot id -> NpcSpot
var _primed := false  # first pass done (effects only run for parts that start after it)


func _ready() -> void:
	var zm := get_node_or_null(^"/root/ZoneManager")
	if zm:
		zm.zone_changed.connect(func(_z): refresh())


func schedules() -> Array:
	var story: StoryDatabase = GameState.story
	return story.schedules if story else []


## Re-reads the zone's paths and spots and re-places everyone (after a zone change, or
## when paths / spots were added at runtime).
func refresh() -> void:
	_zone = ZoneManager.zone if has_node(^"/root/ZoneManager") else null
	_paths.clear()
	_spots.clear()
	if _zone:
		for p in get_tree().get_nodes_in_group(NpcPath.GROUP):
			if _zone.is_ancestor_of(p):
				_paths[p.path_id] = p
		for s in get_tree().get_nodes_in_group(NpcSpot.GROUP):
			if _zone.is_ancestor_of(s):
				_spots[s.spot_id] = s
	for id in npcs.keys():
		_despawn(id)
	_update(true)


func _process(_delta: float) -> void:
	if not is_instance_valid(_zone):
		_zone = null  # left with its scene (refresh() follows once the next zone is in)
	_update(false)


func _update(snap: bool) -> void:
	var zone_path: String = _zone.scene_file_path if _zone else ""
	for s: NpcSchedule in schedules():
		if s == null or s.id == &"":
			continue
		var e := s.current(GameState)
		var changed: bool = not current.has(s.id) or current[s.id] != e
		if changed:
			current[s.id] = e
			if _primed and e:
				for fx in e.effects:
					if fx:
						fx.apply(GameState)
			entry_changed.emit(s, e)
		var where := place(s, e) if e and e.activity != ScheduleEntry.Activity.AWAY and e.zone == zone_path and zone_path != "" else {}
		var npc: Npc = npcs.get(s.id)
		if where.is_empty() or where.gone:
			if npc:
				_despawn(s.id)
			continue
		if npc == null or not is_instance_valid(npc):
			npc = _spawn(s, e, where)
			continue
		if changed:
			npc.set_entry(e)
		npc.set_goal(where.position, where.facing, where.walking, snap)
	_primed = true


## Where `s`'s NPC is during part `e` now: {position, facing, walking, gone}, or {} when
## its spot / path isn't in the current zone.
func place(s: NpcSchedule, e: ScheduleEntry) -> Dictionary:
	if e.activity == ScheduleEntry.Activity.STAY:
		var spot: NpcSpot = _spots.get(e.place)
		if spot == null:
			return {}
		var f := -spot.global_basis.z
		f.y = 0.0
		return {position = spot.global_position, facing = f.normalized(), walking = false, gone = false}
	var path: NpcPath = _paths.get(e.place)
	if path == null:
		return {}
	var def: CharacterDef = GameState.story.find_character(s.character) if GameState.story else null
	var speed := def.walk_speed if def else 1.4
	var len := path.length()
	var walked := e.elapsed(GameState.time_of_day) * GameState.seconds_per_game_hour * speed
	var done := walked >= len
	var at := path.sample(len - walked if e.reverse else walked)
	var dir: Vector3 = -at.direction if e.reverse else at.direction
	return {position = at.position, facing = dir, walking = not done, gone = done and e.vanish_at_end}


func _spawn(s: NpcSchedule, e: ScheduleEntry, where: Dictionary) -> Npc:
	var npc := Npc.new()
	npc.name = "Npc_%s" % s.id
	npc.character = s.character
	npc.schedule = s
	npc.entry = e
	npc.goal = where.position
	npc.goal_facing = where.facing
	npc.walking = where.walking
	_zone.add_child(npc)
	npc.global_position = where.position
	npc.set_entry(e)
	npcs[s.id] = npc
	return npc


func _despawn(id: StringName) -> void:
	var npc: Npc = npcs.get(id)
	npcs.erase(id)
	if is_instance_valid(npc):
		# Not mid-conversation.
		if Talk.active and Talk.partner == npc.talkable:
			Talk._end()
		npc.queue_free()
