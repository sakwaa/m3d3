extends SceneTree
## Editor scripts of the addon parse, and the library UI pieces work without the editor:
## bank set editor (programs, add / remove, RAM), area editor (report, over budget), song
## editor with a bank set (instrument picker by name, "+ add" from the library, slots by
## channel for a CD64 song set). In-memory resources only; writes nothing.
## (Outside the editor, the song editor's _init reports "get_editor_scale" missing: expected.)
##   Godot --headless --path . --script res://addons/n64_audio_tools/tests/library_ui_test.gd

const SCRIPTS := ["res://addons/n64_audio_tools/plugin.gd", "res://addons/n64_audio_tools/export_plugin.gd",
	"res://addons/n64_audio_tools/ui/sound_workspace.gd", "res://addons/n64_audio_tools/ui/instrument_editor.gd",
	"res://addons/n64_audio_tools/ui/song_editor.gd", "res://addons/n64_audio_tools/ui/bank_set_editor.gd",
	"res://addons/n64_audio_tools/ui/area_editor.gd"]

var fails := 0
var checks := 0


func _initialize() -> void:
	for p in SCRIPTS:
		var s = load(p)
		check(s != null and s.can_instantiate(), "%s parses" % p.get_file())
	for f in DirAccess.get_files_at("res://addons/n64_audio_tools/tests"):
		if f.ends_with(".gd"):
			var s = load("res://addons/n64_audio_tools/tests/" + f)
			check(s != null and s.can_instantiate(), "tests/%s parses" % f)

	# In-memory library: a sample, two melodic instruments sharing it, a kit.
	var smp = load("res://game/audio/N64Sample.cs").new()
	smp.Name = "s"
	var adpcm := PackedByteArray()
	adpcm.resize(9 * 100)
	smp.Adpcm = adpcm
	smp.Book = PackedInt32Array([0, 0])
	smp.SampleCount = 1600
	var lib = load("res://game/audio/N64Library.cs").new()
	lib.Samples.append(smp)
	var mk := func(n: String, prog: int, kit: bool):
		var i = load("res://game/audio/N64Instrument.cs").new()
		i.Name = n
		i.Program = prog
		i.IsDrumKit = kit
		i.Bank = 128 if kit else 0
		i.Zones.append({sample = smp, key_lo = 0, key_hi = 127})
		lib.Instruments.append(i)
		return i
	var strings = mk.call("Strings", 48, false)
	var dark = mk.call("Strings dark", 48, false)
	var kit = mk.call("Kit", 0, true)
	var set = load("res://game/audio/N64BankSet.cs").new()
	set.Name = "Song set"
	set.AddWith(strings, 0, 0, 1)
	set.AddWith(kit, 9, 0, 10)

	# Bank set editor.
	var se = load("res://addons/n64_audio_tools/ui/bank_set_editor.gd").new()
	root.add_child(se)
	se.edit(set)
	check(se._ram.text.contains("2 instruments, 1 samples") and se._ram.text.contains("0.9 /"), "set RAM: shared sample once (%s)" % se._ram.text)
	check(se._grid.get_child_count() == 7 * 3, "grid: header + 2 entries")
	se._entry(0, "program", 5)
	check(set.Entries[0].program == 5, "program edit")
	set.Add(dark)
	se.refresh()
	check(set.Clashes().is_empty() and set.Entries[2].program == 48, "added: own program (%s)" % set.Entries[2])
	set.Entries[2].program = 5
	se.refresh()
	check(se._status.text.contains("Strings / Strings dark (5:0)"), "clash shown (%s)" % se._status.text)
	set.Entries[2].program = 48

	# Area editor (no workspace: the default budget).
	var area = load("res://game/audio/N64AudioArea.cs").new()
	area.Name = "Temple"
	area.MusicSets = [set]
	var report: String = load("res://addons/n64_audio_tools/ui/area_editor.gd").report(area, 512)
	check(report.contains("OVER BUDGET") and report.contains("with Song set"), "area over a tiny budget flagged (%s)" % report)
	check(not load("res://addons/n64_audio_tools/ui/area_editor.gd").report(area, 512 * 1024).contains("OVER"), "area within budget")
	var ae = load("res://addons/n64_audio_tools/ui/area_editor.gd").new()
	root.add_child(ae)
	ae.edit(area)
	check(ae._report.text.begins_with("Worst case"), "area editor report")

	# Song editor with the set: picker by name, slots by channel, "+ add" from the library.
	var ws := FakeWorkspace.new()
	ws.bank = lib
	ws.sets = [set]
	var ed = song_editor()
	ed.workspace = ws
	var song = load("res://game/audio/N64Song.cs").new()
	ed.song = song
	song.Tracks.append({path = "x.mid", channel = 0, program = 0, volume = 0.79, pan = 0.0})
	song.Tracks.append({path = "y.mid", channel = 9, drums = true, volume = 0.79, pan = 0.0})
	ed.use_set(set)
	check(song.BankSet == set and song.Tracks[1].get("instrument") == "Kit", "use_set: kit part named (%s)" % song.Tracks[1])
	check(not song.Tracks[0].has("instrument"), "no instrument on program 0 in the set: none named (%s)" % song.Tracks[0])
	ed._rebuild_parts()
	var texts := option_texts(ed)
	check(texts[0].has("ch 1: Strings") and texts[0].has("+ add: Strings dark") == false, "picker: set instruments, slots by channel (%s)" % [texts[0]])
	set.Remove(dark)
	ed._rebuild_parts()
	texts = option_texts(ed)
	check(texts[0].has("+ add: Strings dark") and not texts[1].has("+ add: Strings dark"), "picker offers library instruments to add (%s / %s)" % [texts[0], texts[1]])
	ed._part_instrument(0, set.SoundBank.Instruments[0])
	check(song.Tracks[0].instrument == "Strings" and song.Tracks[0].program == 5 and song.Tracks[0].channel == 0, "picking a set instrument names it (%s)" % song.Tracks[0])
	ed._part_picked(0, {add = dark})
	check(set.Has(dark) and song.Tracks[0].instrument == "Strings dark" and ws.saved == 1, "+ add: added to the set, saved, picked (%s)" % song.Tracks[0])
	ed._part_channel(0, 0)

	se.free()
	ae.free()
	ed.free()
	print("%s: %d / %d checks passed" % ["PASS" if fails == 0 else "FAIL", checks - fails, checks])
	quit(1 if fails else 0)


## What the editors ask of the workspace (sound_workspace.gd).
class FakeWorkspace extends Control:
	var bank
	var sets := []
	var library_mode := true
	var saved := 0

	func library_sets() -> Array:
		return sets

	func save_set(_s) -> void:
		saved += 1

	func save_area(_a) -> void:
		pass

	func budget_bytes() -> int:
		return 512 * 1024

	func refresh_tree_keep() -> void:
		pass


func song_editor():
	var ed = load("res://addons/n64_audio_tools/ui/song_editor.gd").new()
	ed._name = LineEdit.new()
	ed._loop_midi = CheckBox.new()
	ed._loop_start = SpinBox.new()
	ed._loop_end = SpinBox.new()
	ed._bank_label = Label.new()
	ed._info = Label.new()
	ed._overview = Control.new()
	ed._status = Label.new()
	ed._parts = GridContainer.new()
	ed._parts.columns = 8
	for c in [ed._name, ed._loop_midi, ed._loop_start, ed._loop_end, ed._bank_label, ed._info, ed._overview, ed._status, ed._parts]:
		ed.add_child(c)
	return ed


func option_texts(ed) -> Array:
	var out := []
	for c in ed._parts.get_children():
		if c is OptionButton and not c.is_queued_for_deletion():
			var texts := []
			for k in c.item_count:
				texts.append(c.get_item_text(k))
			out.append(texts)
	return out


func check(ok: bool, what: String) -> bool:
	checks += 1
	if not ok:
		fails += 1
		printerr("  FAIL: ", what)
	return ok
