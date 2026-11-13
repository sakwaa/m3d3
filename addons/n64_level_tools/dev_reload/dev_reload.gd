@tool
extends EditorPlugin
## Reloads the N64 tool plugins after their scripts change on disk (edits made outside
## the editor). Godot hot-reloads a changed EditorPlugin script in place, which can lose
## its viewport overlays and input forwarding; turning the plugin off and on again sets
## them up fresh. Checked each time the editor window gets focus (a scan of the scripts takes
## ~25 ms: not polled); waits while a build runs (its worker reports to the plugin). Lives
## inside n64_level_tools so exports drop it with the rest.

const PLUGINS := ["n64_level_tools", "n64_actor_tools", "n64_story_tools", "n64_script_builder", "n64_audio_tools"]
const SELF := "res://addons/n64_level_tools/dev_reload/"
const RETRY := 1.0

var _stamps := {}  # plugin -> {script path: modified time}
var _wait := INF


func _enter_tree() -> void:
	for p in PLUGINS:
		_stamps[p] = _scan(p)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_wait = 0.3  # (Godot's own reload on focus goes first)


func _process(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return
	_wait = INF
	if BuildProgress.active() or EditorInterface.get_resource_filesystem().is_scanning():
		_wait = RETRY
		return
	for p in PLUGINS:
		if not EditorInterface.is_plugin_enabled(p):
			continue
		var now := _scan(p)
		var changed := []
		for path in now:
			if _stamps[p].get(path) != now[path]:
				changed.append(path)
		_stamps[p] = now
		if not changed.is_empty():
			reload(p, changed)
	_run_queued()


## Agent hook: a script dropped at RUN_SCRIPT (a class with `func _run()`, e.g. an
## EditorScript) runs once inside the live editor on the next focus, then is renamed
## (.done), so edits apply to the editor's own loaded resources instead of fighting it
## from outside.
const RUN_SCRIPT := "res://.godot/dev_run/run.gd"


func _run_queued() -> void:
	if not FileAccess.file_exists(RUN_SCRIPT):
		return
	var done := RUN_SCRIPT.get_basename() + ".%d.done" % Time.get_unix_time_from_system()
	DirAccess.rename_absolute(RUN_SCRIPT, done)  # first: a failing script never reruns
	var script := GDScript.new()
	script.source_code = FileAccess.get_file_as_string(done)
	if script.reload() != OK:
		push_error("[Dev Reload] %s doesn't compile" % RUN_SCRIPT)
		return
	var obj = script.new()
	if obj.has_method(&"_run"):
		print("[Dev Reload] running queued script")
		obj._run()


## Turns `plugin` off, reloads `changed` scripts from disk, and turns it back on.
func reload(plugin: String, changed: Array) -> void:
	var t := Time.get_ticks_msec()
	EditorInterface.set_plugin_enabled(plugin, false)
	for path: String in changed:
		if not ResourceLoader.has_cached(path):
			continue  # not loaded yet: loads fresh when first used
		var script := load(path) as Script
		var source := FileAccess.get_file_as_string(path)
		if script and source != "" and script.source_code != source:
			script.source_code = source
			script.reload(true)
	EditorInterface.set_plugin_enabled(plugin, true)
	print("[Dev Reload] %s reloaded (%d script(s) changed) in %d ms" % [plugin, changed.size(), Time.get_ticks_msec() - t])


## Modified times of a plugin's scripts.
func _scan(plugin: String) -> Dictionary:
	var out := {}
	var dirs := ["res://addons/%s/" % plugin]
	while not dirs.is_empty():
		var dir: String = dirs.pop_back()
		if dir == SELF:
			continue
		for d in DirAccess.get_directories_at(dir):
			dirs.append(dir + d + "/")
		for f in DirAccess.get_files_at(dir):
			if f.get_extension() == "gd":
				out[dir + f] = FileAccess.get_modified_time(dir + f)
	return out

