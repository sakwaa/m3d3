extends SceneTree
## Songs editor with a CD64 song bank (EXPORT_FORMAT.md "Song banks": channel n plays
## program n - 1, the kit on channel 10): parts land on their slot's channel / program,
## instruments are listed as "ch 3: Strings", channel and slot instrument move together,
## an ordinary bank lists as before. Writes its MIDI files to the scratch folder only.
## (Outside the editor, the editor's _init reports "get_editor_scale" missing: expected.)
##   Godot --headless --path . --script res://addons/n64_audio_tools/tests/song_slots_test.gd -- <scratch folder>

const SongEditor := preload("res://addons/n64_audio_tools/ui/song_editor.gd")

var fails := 0
var checks := 0


func _initialize() -> void:
	var scratch: String = OS.get_cmdline_user_args()[0]
	DirAccess.make_dir_recursive_absolute(scratch)
	var bank = load("res://game/audio/N64SoundBank.cs").new()
	for spec in [[0, "Piano", false], [1, "Bass", false], [2, "Strings", false], [9, "Kit", true]]:
		bank.Instruments.append(instrument(spec[0], spec[1], spec[2], "My Song"))
	bank.Instruments.append(instrument(48, "Hand-made", false, ""))
	var song = load("res://game/audio/N64Song.cs").new()
	song.Bank = bank
	var ed = editor()
	ed.song = song

	# MIDI on channels 1 and 3 (both slots), another on 3 (taken: next free slot), drums on 10.
	var files := []
	for ch in [0, 2, 2, 9]:
		files.append(write_midi(scratch.path_join("part_ch%d_%d.mid" % [ch + 1, files.size()]), ch))
	ed.add_parts(PackedStringArray(files))
	var t: Array = song.Tracks
	check(t.size() == 4, "4 parts")
	check(t[0].channel == 0 and t[0].program == 0, "MIDI ch 1 -> ch 1 / Piano (%s)" % t[0])
	check(t[1].channel == 2 and t[1].program == 2, "MIDI ch 3 -> ch 3 / Strings (%s)" % t[1])
	check(t[2].channel == 1 and t[2].program == 1, "ch 3 taken -> first free slot, ch 2 / Bass (%s)" % t[2])
	check(t[3].get("drums", false) and t[3].channel == 9, "drums on ch 10")
	var items := option_texts(ed)
	check(items.size() == 4 and items[0].slice(0, 5) == ["ch 1: Piano", "ch 2: Bass", "ch 3: Strings", "ch 10: 🥁 Kit", "♪ 048 Hand-made"], "slots listed by channel, then the rest (%s)" % [items[0] if items else []])
	check(song.Events.size() > 0, "song built")
	check(program_on(song, 2) == 2 and program_on(song, 1) == 1, "builder: each part's program on its channel")

	# Channel change follows the slot; picking a slot instrument moves the part.
	ed._part_channel(0, 2)
	check(t[0].channel == 2 and t[0].program == 2, "ch 1 -> 3: plays Strings (%s)" % t[0])
	ed._part_channel(0, 5)
	check(t[0].channel == 5 and t[0].program == 2, "ch 6 has no slot: instrument kept (%s)" % t[0])
	check(warned(ed, 0), "slot instrument off its channel is flagged")
	ed._part_instrument(0, bank.Instruments[1])
	check(t[0].channel == 1 and t[0].program == 1, "picking ch 2: Bass moves the part to ch 2 (%s)" % t[0])
	check(not warned(ed, 0), "… and the flag goes")
	ed._part_instrument(1, bank.Instruments[4])
	check(t[1].channel == 2 and t[1].program == 48, "hand-made instrument: channel kept (%s)" % t[1])
	ed._part_channel(1, 0)
	check(t[1].program == 48, "… and a channel change keeps it (%s)" % t[1])

	# An ordinary export (programs outside 0-15) has no slots: listed as before.
	bank.Instruments[0].Program = 40
	ed._rebuild_parts()
	items = option_texts(ed)
	check(not items[0].any(func(x): return x.begins_with("ch ")), "no slots when an instrument breaks the pattern (%s)" % [items[0]])

	# Song-bank sidecars name each slot's channel (cd64_channel): used whatever the programs.
	var bank2 = load("res://game/audio/N64SoundBank.cs").new()
	for spec in [[48, "Strings", 4], [33, "Bass", 2], [0, "Kit", 10]]:
		var ins = instrument(spec[0], spec[1], spec[2] == 10, "Song 2")
		ins.set_meta(&"cd64_channel", spec[2])
		bank2.Instruments.append(ins)
	song.Bank = bank2
	ed._rebuild_parts()
	items = option_texts(ed)
	check(items[0] == ["ch 2: Bass", "ch 4: Strings", "ch 10: 🥁 Kit"], "slots from cd64_channel (%s)" % [items[0]])
	ed._part_instrument(0, bank2.Instruments[0])
	check(t[0].channel == 3 and t[0].program == 48, "picking ch 4: Strings moves the part to ch 4 (%s)" % t[0])

	for f in files:
		DirAccess.remove_absolute(f)
	ed.free()
	print("%s: %d / %d checks passed" % ["PASS" if fails == 0 else "FAIL", checks - fails, checks])
	quit(1 if fails else 0)


## The editor's parts grid and labels without the editor (EditorInterface isn't there).
func editor():
	var ed = SongEditor.new()
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


func instrument(program: int, name: String, drums: bool, tag: String):
	var ins = load("res://game/audio/N64Instrument.cs").new()
	ins.Name = name
	ins.Program = program
	ins.IsDrumKit = drums
	if tag != "":
		ins.set_meta(&"cd64_export", tag)
	return ins


## Item texts of each part's instrument picker.
func option_texts(ed) -> Array:
	var out := []
	for c in ed._parts.get_children():
		if c is OptionButton and not c.is_queued_for_deletion():
			var texts := []
			for k in c.item_count:
				texts.append(c.get_item_text(k))
			out.append(texts)
	return out


func warned(ed, part: int) -> bool:
	var pickers: Array = ed._parts.get_children().filter(func(c): return c is OptionButton and not c.is_queued_for_deletion())
	return pickers[part].has_theme_color_override(&"font_color")


## The program the song sets on `channel` (first program change), -1 if none.
func program_on(song, channel: int) -> int:
	for e in song.Events:
		if (e >> 28) & 15 == 4 and (e >> 24) & 15 == channel:
			return (e >> 16) & 0xFF
	return -1


## A one-bar format-0 MIDI file: four quarter notes on `channel`.
func write_midi(path: String, channel: int) -> String:
	var trk := PackedByteArray([0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])  # 120 BPM
	for i in 4:
		trk.append_array([0x00, 0x90 | channel, 60 + i, 100, 0x60, 0x80 | channel, 60 + i, 0])
	trk.append_array([0x00, 0xFF, 0x2F, 0x00])
	var b := PackedByteArray("MThd".to_ascii_buffer())
	b.append_array([0, 0, 0, 6, 0, 0, 0, 1, 0, 0x60])
	b.append_array("MTrk".to_ascii_buffer())
	b.append_array([0, 0, (trk.size() >> 8) & 0xFF, trk.size() & 0xFF])
	b.append_array(trk)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()
	return path


func check(ok: bool, what: String) -> bool:
	checks += 1
	if not ok:
		fails += 1
		printerr("  FAIL: ", what)
	return ok
