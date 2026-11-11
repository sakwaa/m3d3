class_name ZoneArrivals
## The arrival ids a zone offers (what a ZoneExit / Door / Passage `target_spawn` can name):
## its SpawnPoints', Passages' and zone Doors' spawn_id, and its level's passage and zone door
## brushes'. Read from the scene without instantiating it (its SceneState, and the level
## data it points at), remembered until the scene file changes. For the inspector: the
## target_spawn fields offer these as a drop-down (still typeable). Editor only.

static var _cache := {}  # zone path -> {stamp, ids}


## The arrival ids of the zone at `zone_path` ("default" first), or [] if it can't be read.
static func ids(zone_path: String) -> PackedStringArray:
	if zone_path.is_empty() or not ResourceLoader.exists(zone_path):
		return PackedStringArray()
	var stamp := FileAccess.get_modified_time(zone_path)
	var hit: Dictionary = _cache.get(zone_path, {})
	if not hit.is_empty() and hit.stamp == stamp:
		return hit.ids
	var found := {&"default": true}
	var packed := load(zone_path) as PackedScene
	if packed:
		var state := packed.get_state()
		for n in state.get_node_count():
			for p in state.get_node_property_count(n):
				var name := state.get_node_property_name(n, p)
				var value = state.get_node_property_value(n, p)
				if name == &"spawn_id" and value is StringName or (name == &"spawn_id" and value is String):
					found[StringName(value)] = true
				elif name == &"data" and value is Resource and value.get(&"brushes") is Array:
					for b in value.get(&"brushes"):
						if b == null:
							continue
						var spec = b.get(&"passage")
						if spec == null:
							spec = b.get(&"door")
							if spec != null and int(spec.get(&"mode")) != 1:  # Door.Mode.ZONE
								spec = null
						if spec != null and spec.get(&"spawn_id") != null:
							found[StringName(spec.get(&"spawn_id"))] = true
	var out := PackedStringArray()
	for k in found:
		out.append(String(k))
	_cache[zone_path] = {stamp = stamp, ids = out}
	return out


## Turns a `target_spawn` property into a drop-down of `zone_path`'s arrival ids (call from
## _validate_property).
static func hint(property: Dictionary, zone_path: String) -> void:
	if property.name != &"target_spawn" or not Engine.is_editor_hint():
		return
	var list := ids(zone_path)
	if list.is_empty():
		return
	property.hint = PROPERTY_HINT_ENUM_SUGGESTION
	property.hint_string = ",".join(list)
