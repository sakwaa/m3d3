extends RefCounted
## "Play here" hand-off between the editor and a run started from it. The editor writes
## FILE (zone scene, position, yaw, room, hour); when that zone starts, ZoneManager asks
## take_spawn() for a one-off spawn there. Lives in the tools addon, so it never ships;
## ZoneManager only loads it in editor-launched runs.

const FILE := "user://play_here.json"


static func write(scene_path: String, position: Vector3, yaw: float, room_path: String, hour: float) -> void:
	var f := FileAccess.open(FILE, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({scene = scene_path, position = [position.x, position.y, position.z],
			yaw = yaw, room = room_path, hour = hour}))


static func clear() -> void:
	if FileAccess.file_exists(FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(FILE))


## A SpawnPoint at the requested spot when this run was started with Play Here for
## `zone`'s scene; else `fallback`. The request is consumed either way.
static func take_spawn(zone: Node, fallback: Node3D) -> Node3D:
	if not FileAccess.file_exists(FILE):
		return fallback
	var data = JSON.parse_string(FileAccess.get_file_as_string(FILE))
	clear()
	if not data is Dictionary or data.get("scene", "") != zone.scene_file_path:
		return fallback
	var spawn := SpawnPoint.new()
	spawn.name = "_PlayHere"
	spawn.spawn_id = &"play_here"
	var p: Array = data.position
	spawn.position = Vector3(p[0], p[1], p[2])
	spawn.rotation.y = float(data.get("yaw", 0.0))
	var room_path: String = data.get("room", "")
	if not room_path.is_empty():
		spawn.room = zone.get_node_or_null(room_path) as Room
	zone.add_child(spawn)
	if data.has("hour"):
		GameState.set_time(float(data.hour))
	return spawn
