@tool
class_name BuildProgress
extends RefCounted
## What Quick Play / Build & Play / Build All Zones are doing, shown in the middle of the
## editor's scene view while they run: the steps done (with their times) and the one under
## way. The panel goes straight onto a canvas item of its own, so a step taken while the
## editor's thread is busy can put it on screen at once (`step`, RenderingServer.force_draw).
## The build worker (build_worker.gd, its own process) writes its steps to a file instead
## (`to_file`), which the editor reads back each frame (`show_file`). Outside a run (exports,
## the editor's Bake) steps do nothing.

const MAX_LINES := 16
const WIDTH := 560.0
const FONT_SIZE := 14
## A run left open (its script stopped on an error) closes once the editor has been idle this
## long without a step (worker runs refresh it as they go).
const STALE_MS := 15000

## Where the steps happen ("market_square · Level"), put before each step's text.
static var where := ""
static var _ci := RID()
static var _title := ""
static var _lines: Array = []  # [text, ms taken (-1: under way, -2: a note)]
static var _t0 := 0
static var _t := 0
static var _file: FileAccess


static func active() -> bool:
	return _ci.is_valid() or _file != null


## Shows the panel (`title` at its top).
static func begin(title: String) -> void:
	end()
	var host := EditorInterface.get_editor_main_screen()
	if host == null:
		return
	_ci = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_ci, host.get_canvas_item())
	RenderingServer.canvas_item_set_z_index(_ci, 1000)
	_title = title
	_lines.clear()
	where = ""
	_t0 = Time.get_ticks_msec()
	_t = _t0
	var tree := Engine.get_main_loop() as SceneTree
	if tree and not tree.process_frame.is_connected(_watch):
		tree.process_frame.connect(_watch)
	_draw(true)


## Steps go to the file at `path` (the build worker's run), one per line.
static func to_file(path: String) -> void:
	_file = FileAccess.open(path, FileAccess.WRITE)
	_t0 = Time.get_ticks_msec()


## The step now under way (the one before it done).
static func step(text: String) -> void:
	_add("S", ("%s · %s" % [where, text]) if where != "" else text)


## A line that's already done (a zone skipped, a result).
static func note(text: String) -> void:
	_add("N", text)


static func _add(kind: String, text: String) -> void:
	if _file:
		_file.store_line("%s\t%d\t%s" % [kind, Time.get_ticks_msec() - _t0, text])
		_file.flush()
	if not _ci.is_valid():
		return
	_close_line()
	_lines.append([text, -1 if kind == "S" else -2])
	_t = Time.get_ticks_msec()
	_draw(true)


## The panel shows the steps a worker wrote to `path` so far (the last one under way).
static func show_file(path: String) -> void:
	if not _ci.is_valid():
		return
	_t = Time.get_ticks_msec()
	if not FileAccess.file_exists(path):
		_draw(false)
		return
	var lines := []
	var starts := []
	for row in FileAccess.get_file_as_string(path).split("\n", false):
		var parts := row.split("\t", true, 2)
		if parts.size() < 3:
			continue
		lines.append([parts[2], -1 if parts[0] == "S" else -2])
		starts.append(int(parts[1]))
	for i in lines.size():
		if lines[i][1] == -1 and i + 1 < lines.size():
			lines[i][1] = starts[i + 1] - starts[i]
	_lines = lines
	_draw(false)


static func end() -> void:
	if _file:
		_file.close()
		_file = null
	if not _ci.is_valid():
		return
	RenderingServer.free_rid(_ci)
	_ci = RID()
	where = ""
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.process_frame.is_connected(_watch):
		tree.process_frame.disconnect(_watch)


static func _close_line() -> void:
	if not _lines.is_empty() and _lines[-1][1] == -1:
		_lines[-1][1] = Time.get_ticks_msec() - _t


static func _watch() -> void:
	if _ci.is_valid() and Time.get_ticks_msec() - _t > STALE_MS:
		end()


## `now`: on screen at once (the editor's thread is busy; no frame would show it).
static func _draw(now: bool) -> void:
	var host := EditorInterface.get_editor_main_screen()
	if host == null:
		return
	var s := EditorInterface.get_editor_scale()
	var font := host.get_theme_font(&"main", &"EditorFonts")
	var bold := host.get_theme_font(&"bold", &"EditorFonts")
	var accent := host.get_theme_color(&"accent_color", &"Editor")
	var fs := roundi(FONT_SIZE * s)
	var line_h := font.get_height(fs) + 5.0 * s
	var pad := 18.0 * s
	var shown := _lines.slice(maxi(_lines.size() - MAX_LINES, 0))
	var w := WIDTH * s
	var h := pad * 2.0 + line_h * (shown.size() + 1) + 8.0 * s
	var at := ((host.size - Vector2(w, h)) * 0.5).floor()
	var rs := RenderingServer
	rs.canvas_item_clear(_ci)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.08, 0.09, 0.11, 0.94)
	box.border_color = accent
	box.set_border_width_all(maxi(roundi(s), 1))
	box.set_corner_radius_all(roundi(8 * s))
	box.shadow_color = Color(0, 0, 0, 0.4)
	box.shadow_size = roundi(12 * s)
	box.draw(_ci, Rect2(at, Vector2(w, h)))
	var inner := w - pad * 2.0
	var y := at.y + pad + font.get_ascent(fs)
	bold.draw_string(_ci, Vector2(at.x + pad, y), _title, HORIZONTAL_ALIGNMENT_LEFT, inner, fs, Color.WHITE)
	bold.draw_string(_ci, Vector2(at.x + pad, y), _secs(Time.get_ticks_msec() - _t0), HORIZONTAL_ALIGNMENT_RIGHT, inner, fs, Color(1, 1, 1, 0.6))
	y += line_h + 8.0 * s
	var time_w := 64.0 * s
	for l in shown:
		var running: bool = l[1] == -1
		var color := accent.lerp(Color.WHITE, 0.35) if running else Color(1, 1, 1, 0.55)
		var text: String = ("▸ " if running else "   ") + l[0] + ("…" if running else "")
		font.draw_string(_ci, Vector2(at.x + pad, y), text, HORIZONTAL_ALIGNMENT_LEFT, inner - time_w, fs, color)
		if l[1] >= 0:
			font.draw_string(_ci, Vector2(at.x + pad, y), _secs(l[1]), HORIZONTAL_ALIGNMENT_RIGHT, inner, fs, color)
		y += line_h
	if now:
		RenderingServer.force_draw()


static func _secs(ms: int) -> String:
	return "%.1f s" % (ms / 1000.0)
