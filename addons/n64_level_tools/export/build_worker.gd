extends Node
## Build & Play's builder, in its own Godot process so the editor stays free while it runs
## (it needs a window: the AO and never-seen passes render). Reads a job file (JSON: zones,
## force, out), builds each zone that isn't current as the export does (ExportBake) with the
## step caches on, and writes each built level to `out` with a manifest (manifest.json) the
## editor stores from. Steps go to out/progress.txt (BuildProgress). Touches no project file.
##   godot --path . res://addons/n64_level_tools/export/build_worker.tscn -- job.json

const ExportBake := preload("res://addons/n64_level_tools/export/export_bake.gd")
const BuildCache := preload("res://addons/n64_level_tools/export/build_cache.gd")


func _ready() -> void:
	# Out of the way: the window is only there for the renderer. Off-screen and borderless
	# (macOS keeps a titled window on screen, and doesn't always minimize one that starts
	# maximized, as the project's window does); the bakes draw into their own viewports.
	var w := get_window()
	w.mode = Window.MODE_WINDOWED
	w.borderless = true
	w.unfocusable = true
	w.size = Vector2i(1, 1)
	w.position = Vector2i(-20000, -20000)
	var args := OS.get_cmdline_user_args()
	var job = JSON.parse_string(FileAccess.get_file_as_string(args[0])) if not args.is_empty() else null
	if not job is Dictionary:
		push_error("build_worker: no job file")
		get_tree().quit(2)
		return
	var out: String = job.out
	DirAccess.make_dir_recursive_absolute(out)
	# We're up: the editor takes focus back (the launch brings this window to the front).
	var pid_file := FileAccess.open(out.path_join("pid.txt"), FileAccess.WRITE)
	pid_file.store_string(str(OS.get_process_id()))
	pid_file.close()
	BuildProgress.to_file(out.path_join("progress.txt"))
	BuildCache.active = true
	var manifest := {zones = []}
	for path: String in job.zones:
		var name := path.get_file().get_basename()
		if not job.get("force", false) and BuildCache.zone_up_to_date(path):
			BuildProgress.note("%s: build is current" % name)
			continue
		BuildProgress.where = name
		BuildProgress.step("loading")
		var packed := load(path) as PackedScene
		if packed == null:
			manifest.zones.append({path = path, failed = ["can't load %s" % path]})
			continue
		var scene := packed.instantiate()
		# The keys from the levels as saved (the build reshapes its copies).
		var roots: Array = ([scene] if scene is LevelRoot else []) + scene.find_children("*", "Node3D", true, false).filter(func(n): return n is LevelRoot)
		var keys := {}
		var hashes := {}
		for root: LevelRoot in roots:
			if root.data:
				keys[root] = BuildCache.level_key(root, path)
				hashes[root] = root.compute_hash()
		var t := Time.get_ticks_msec()
		var result: Dictionary = ExportBake.bake_scene(scene, self, path)
		var zone := {path = path, failed = result.failed, levels = []}
		BuildProgress.where = name
		BuildProgress.step("writing")
		for root: LevelRoot in roots:
			if not keys.has(root) or root.data == null or not root.data.has_bake():
				continue
			var file := out.path_join("%s_%d.res" % [name, zone.levels.size()])
			var err := ResourceSaver.save(root.data, file)
			if err != OK:
				zone.failed.append("%s: can't write (%s)" % [root.name, error_string(err)])
				continue
			zone.levels.append({node = String(scene.get_path_to(root)), file = file, key = str(keys[root]), hash = str(hashes[root])})
		manifest.zones.append(zone)
		scene.free()
		BuildProgress.where = ""
		BuildProgress.note("%s built in %.1f s" % [name, (Time.get_ticks_msec() - t) / 1000.0])
	var f := FileAccess.open(out.path_join("manifest.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(manifest))
	f.close()
	BuildProgress.end()
	get_tree().quit()
