@tool
extends RefCounted
## Checks the links between zones (pre-build): every ZoneExit, zone Door, Passage node and
## passage / zone door brush must name a target zone that exists (errors), and the spawn it asks for
## should exist there (warnings: the game falls back to the zone's default spawn). Runs on
## export (Project Settings > n64/export/check_zone_links) and from Project > Tools >
## M3D World > Check Zone Links…; never while editing, so unfinished links are fine.

const SETTING := "n64/export/check_zone_links"


static func enabled() -> bool:
	return bool(ProjectSettings.get_setting(SETTING, true))


## Every scene of the game (addons and hidden folders left out).
static func game_scenes() -> PackedStringArray:
	var out := PackedStringArray()
	_scan("res://", out)
	return out


static func _scan(dir: String, out: PackedStringArray) -> void:
	for sub in DirAccess.get_directories_at(dir):
		if sub.begins_with(".") or (dir == "res://" and sub == "addons"):
			continue
		_scan(dir.path_join(sub), out)
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == "tscn":
			out.append(dir.path_join(f))


## {errors: Array[String], warnings: Array[String], links: int} for `scenes`.
static func check(scenes: PackedStringArray) -> Dictionary:
	var links := []  # {from, what, zone, spawn}
	var spawns := {}  # scene path -> {spawn id: true}
	for path in scenes:
		var packed := load(path) as PackedScene
		if packed == null:
			continue
		var root := packed.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
		if root == null:
			continue
		spawns[path] = {}
		var nodes: Array = [root]
		nodes.append_array(root.find_children("*", "", true, false))
		for n in nodes:
			var where := "%s: %s" % [path, root.get_path_to(n)]
			if n is SpawnPoint:
				spawns[path][n.spawn_id] = true
			elif n is ZoneExit:
				links.append({from = where, what = "ZoneExit", zone = n.target_zone, spawn = n.target_spawn})
			elif n is Door and n.mode == Door.Mode.ZONE:
				spawns[path][n.spawn_id] = true
				links.append({from = where, what = "zone Door", zone = n.target_zone, spawn = n.target_spawn})
			elif n is Passage:
				spawns[path][n.spawn_id] = true
				links.append({from = where, what = "Passage", zone = n.target_zone, spawn = n.target_spawn})
			elif n is LevelRoot and n.data:
				for i in n.data.brushes.size():
					var b: LevelBrush = n.data.brushes[i]
					if b and b.is_passage():
						spawns[path][b.passage.spawn_id] = true
						links.append({from = "%s (passage brush %d, spawn id '%s')" % [where, i, b.passage.spawn_id],
							what = "Passage", zone = b.passage.target_zone, spawn = b.passage.target_spawn})
					elif b and b.is_door() and b.door.mode == Door.Mode.ZONE:
						spawns[path][b.door.spawn_id] = true
						links.append({from = "%s (door brush %d, spawn id '%s')" % [where, i, b.door.spawn_id],
							what = "zone Door", zone = b.door.target_zone, spawn = b.door.target_spawn})
		root.free()
	var errors: Array[String] = []
	var warnings: Array[String] = []
	for l in links:
		if String(l.zone).is_empty():
			errors.append("%s — %s has no target zone." % [l.from, l.what])
		elif not ResourceLoader.exists(l.zone):
			errors.append("%s — %s targets %s, which doesn't exist." % [l.from, l.what, l.zone])
		elif spawns.has(l.zone) and not spawns[l.zone].has(l.spawn):
			warnings.append("%s — %s asks for spawn '%s' in %s, which has none by that id (the zone's default spawn is used)." % [
				l.from, l.what, l.spawn, l.zone])
	return {errors = errors, warnings = warnings, links = links.size()}


## Runs the check over the game's scenes and reports it in the Output panel. Returns the
## number of errors.
static func report() -> int:
	var r := check(game_scenes())
	for e in r.errors:
		push_error("Zone links: " + e)
	for w in r.warnings:
		push_warning("Zone links: " + w)
	print("[Zone links] %d link(s) checked: %d error(s), %d warning(s)." % [r.links, r.errors.size(), r.warnings.size()])
	return r.errors.size()
