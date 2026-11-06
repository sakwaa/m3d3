@tool
extends VBoxContainer
## Area editor (N64 Sounds > Library > an area): which bank sets a game area (level, zone)
## uses, and its sample RAM against the budget (N64AudioArea.Budget): the SFX sets are all
## loaded the whole time, one music set at a time (the worst case is the biggest one), or
## every music set at once when "Songs can overlap" is on. Shared samples count once.
## In the game N64AudioArea.Apply loads the SFX sets into an N64SfxPlayer, which plays them
## on its own voices in parallel with the music player's set.
## Saves the area on every change.

var workspace: Control  # sound_workspace.gd
var area: Resource  # N64AudioArea

var _name: LineEdit
var _overlap: CheckBox
var _music: VBoxContainer
var _sfx: VBoxContainer
var _report: Label
var _updating := false


func _init() -> void:
	size_flags_vertical = SIZE_EXPAND_FILL
	add_theme_constant_override(&"separation", 6)
	var top := HFlowContainer.new()
	add_child(top)
	top.add_child(_label("Area"))
	_name = LineEdit.new()
	_name.custom_minimum_size.x = 180
	_name.text_submitted.connect(func(t): _rename(t))
	_name.focus_exited.connect(func(): _rename(_name.text))
	top.add_child(_name)
	_overlap = CheckBox.new()
	_overlap.text = "Songs can overlap"
	_overlap.tooltip_text = "Off: one music set is loaded at a time (the biggest counts). On: every music set counts at once (crossfades, jingles over the music)."
	_overlap.toggled.connect(func(on): if area and not _updating: area.MusicOverlaps = on; _changed())
	top.add_child(_overlap)
	_report = Label.new()
	_report.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_report)
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(cols)
	_music = _column(cols, "Music sets (one loaded at a time)")
	_sfx = _column(cols, "Sound-effect sets (always loaded, play in parallel with the music)")


func _column(parent: Control, title: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.size_flags_horizontal = SIZE_EXPAND_FILL
	parent.add_child(v)
	var l := _label(title)
	l.add_theme_color_override(&"font_color", Color(0.7, 0.85, 1.0))
	v.add_child(l)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = SIZE_EXPAND_FILL
	v.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = SIZE_EXPAND_FILL
	scroll.add_child(list)
	return list


func edit(a: Resource) -> void:
	area = a
	refresh()


func refresh() -> void:
	if area == null:
		return
	_updating = true
	_name.text = area.Name
	_overlap.button_pressed = area.MusicOverlaps
	for list in [_music, _sfx]:
		for c in list.get_children():
			c.queue_free()
	var sets: Array = workspace.library_sets() if workspace else []
	for s in sets:
		var sfx := int(s.Kind) == 1
		var cb := CheckBox.new()
		var used: Array = area.SfxSets if sfx else area.MusicSets
		cb.button_pressed = used.has(s)
		cb.text = "%s  (%.1f KB)" % [s.Name, s.StoredBytes() / 1024.0]
		cb.toggled.connect(func(on): _toggle(s, sfx, on))
		(_sfx if sfx else _music).add_child(cb)
	if sets.is_empty():
		_music.add_child(_label("(no bank sets in the library yet)"))
	_report.text = report(area, workspace.budget_bytes() if workspace else 512 * 1024)
	var b: Dictionary = area.Budget()
	var budget: int = workspace.budget_bytes() if workspace else 512 * 1024
	_report.add_theme_color_override(&"font_color", Color(1, 0.4, 0.35) if b.total > budget else (Color(1, 0.85, 0.4) if b.total > budget * 0.8 else Color(1, 1, 1)))
	_updating = false


## The area's RAM as text (also the tree's tooltip).
static func report(a: Resource, budget: int) -> String:
	var b: Dictionary = a.Budget()
	var lines := PackedStringArray()
	var over: bool = b.total > budget
	lines.append("Worst case: %.1f / %d KB%s%s" % [b.total / 1024.0, budget / 1024,
		" (%s)" % ("all music sets at once" if b.music_set == "all" else "with %s" % b.music_set) if b.music_set != "" else "",
		"  OVER BUDGET by %.1f KB" % ((b.total - budget) / 1024.0) if over else ""])
	lines.append("Sound effects (always loaded, in parallel with the music on their own voices): %.1f KB" % (b.sfx / 1024.0))
	for n in b.per_music:
		var v: int = b.per_music[n]
		lines.append("  %s + sound effects: %.1f KB%s" % [n, v / 1024.0, "  OVER" if v > budget else ""])
	return "\n".join(lines)


func _toggle(s: Resource, sfx: bool, on: bool) -> void:
	if _updating or area == null:
		return
	var list: Array = area.SfxSets if sfx else area.MusicSets
	if on and not list.has(s):
		list.append(s)
	elif not on:
		list.erase(s)
	if sfx:
		area.SfxSets = list
	else:
		area.MusicSets = list
	_changed()


func _rename(t: String) -> void:
	if _updating or area == null or t == area.Name or t.strip_edges() == "":
		return
	area.Name = t.strip_edges()
	_changed()


func _changed() -> void:
	if workspace:
		workspace.save_area(area)
	refresh()


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l
