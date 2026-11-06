extends SceneTree
## The instrument library, bank sets and areas (N64LibraryTools, N64BankSet, N64AudioArea):
## CD64 imports into the library (sample dedup by recording + settings, re-import in place,
## another export sharing samples, different settings making a separate sample), bank-set
## program assignment and RAM (distinct samples once), a CD64 song built against its bank
## set by instrument name (same events and audio as the legacy bank), library export ->
## re-import (bit-exact ADPCM, nothing duplicated), forks of shared samples, area budgets,
## conversion of a legacy bank, the export plugin's stripping. Works in throwaway library
## folders and banks under res://audio/ and deletes them afterwards.
##   Godot --headless --path . --script res://addons/n64_audio_tools/tests/library_test.gd \
##     -- <fixture folder (cd64_make_fixture.gd)> <a CD64 song export ("song": true)> <scratch folder>

const ROOT := "res://audio/zz_lib_test"
const ROOT2 := "res://audio/zz_lib_test2"
const LEGACY := "res://audio/banks/zz_lib_legacy.res"
const LEGACY_SONG := "res://audio/banks/zz_lib_legacy_song.res"

var fails := 0
var checks := 0


func _initialize() -> void:
	_run.call_deferred()  # nodes added from _initialize aren't ready yet (the music player)


func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var fixture: String = a[0]
	var song_export: String = a[1]
	var scratch: String = a[2]
	DirAccess.make_dir_recursive_absolute(scratch)
	cleanup()
	var tools = new_tools(ROOT)
	var fx_side: Dictionary = read_json(fixture.path_join("CD64_Fixture.n64bank.json"))

	# 1. Import into the library: one file per sample / instrument, a bank set for the export.
	check(ok(tools.ImportCd64(fixture)), "import fixture")
	print("  ", tools.Summary)
	var lib = tools.Load()
	check(lib.Samples.size() == 3 and lib.Instruments.size() == 3, "3 samples, 3 instruments (%d, %d)" % [lib.Samples.size(), lib.Instruments.size()])
	check(lib.Samples.all(func(s): return s.resource_path.begins_with(ROOT + "/samples/")), "samples are their own files")
	check(lib.Instruments.all(func(i): return i.resource_path.begins_with(ROOT + "/instruments/")), "instruments are their own files")
	var ins_text := FileAccess.get_file_as_string(lib.Instruments[0].resource_path)
	check(ins_text.contains("ext_resource") and ins_text.contains("/samples/"), "instrument file references sample files")
	for e in fx_side.samples:
		var s = by_meta(lib.Samples, &"cd64_id", e.id)
		check(s != null and s.Adpcm == FileAccess.get_file_as_bytes(fixture.path_join(e.adpcm)), "%s: ADPCM bit-exact" % e.id)
		check(s != null and FileAccess.file_exists(s.SourcePath) and s.SourcePath.begins_with(ROOT + "/_source/"), "%s: recording in _source" % e.id)
	check(FileAccess.file_exists(ROOT + "/_source/.gdignore"), "_source is ignored by Godot")
	var sets: Array = tools.LoadSets()
	check(sets.size() == 1 and sets[0].Name == "CD64 Fixture" and sets[0].Kind == 0 and sets[0].Entries.size() == 3, "bank set for the export")
	var fx_set = sets[0]
	check(entry_prog(fx_set, "Voices") == Vector2i(52, 0) and entry_prog(fx_set, "Kit") == Vector2i(0, 128), "set keeps the sidecar's programs")

	# 2. The same export again: nothing duplicated, the same files.
	var paths: Array = lib.Samples.map(func(s): return s.resource_path)
	check(ok(tools.ImportCd64(fixture)), "re-import fixture")
	print("  ", tools.Summary)
	lib = tools.Load()
	check(lib.Samples.size() == 3 and lib.Instruments.size() == 3, "re-import: no duplicates (%d samples, %d instruments)" % [lib.Samples.size(), lib.Instruments.size()])
	check(lib.Samples.map(func(s): return s.resource_path) == paths, "re-import: same sample files")
	check(tools.LoadSets().size() == 1, "re-import: same set")

	# 3. Another export with the same recordings and settings: samples shared.
	var twin := scratch.path_join("twin")
	copy_dir(fixture, twin)
	var tw_side: Dictionary = fx_side.duplicate(true)
	tw_side.name = "CD64 Twin"
	for i in tw_side.instruments:
		i.volume = i.volume * 0.5  # same names, other instruments
	write_json(twin.path_join("CD64_Fixture.n64bank.json"), tw_side)
	check(ok(tools.ImportCd64(twin)), "import twin")
	print("  ", tools.Summary)
	lib = tools.Load()
	check(lib.Samples.size() == 3, "same recording + settings: one sample (%d)" % lib.Samples.size())
	check(lib.Instruments.size() == 6, "twin's instruments added (%d)" % lib.Instruments.size())
	var tw_voices = lib.FindInstrumentByName("Voices (CD64 Twin)")
	var voices = lib.FindInstrumentByName("Voices")
	check(tw_voices != null and tw_voices.get_meta(&"cd64_name") == "Voices", "taken name gets the export's (%s)" % [names(lib.Instruments)])
	check(tw_voices != null and tw_voices.Zones[0].sample == voices.Zones[0].sample, "twin plays the same sample objects")
	check(lib.UsersOf(voices.Zones[0].sample).size() == 4, "shared sample has 4 users")
	# An export holding library instruments unchanged (CD64 keeps their names): those instruments.
	var same := scratch.path_join("same")
	copy_dir(fixture, same)
	var sa_side: Dictionary = fx_side.duplicate(true)
	sa_side.name = "CD64 Same"
	write_json(same.path_join("CD64_Fixture.n64bank.json"), sa_side)
	check(ok(tools.ImportCd64(same)), "import an unchanged copy")
	print("  ", tools.Summary)
	lib = tools.Load()
	var same_set = load(tools.LastSetPath)
	check(lib.Instruments.size() == 6 and lib.Samples.size() == 3, "unchanged instruments: the library's own (%d)" % lib.Instruments.size())
	check(same_set.Entries.size() == 3 and same_set.Entries[0].instrument == voices, "its set plays the library instruments")

	# 4. Different settings: a separate sample.
	var other := scratch.path_join("other")
	copy_dir(fixture, other)
	var ot_side: Dictionary = fx_side.duplicate(true)
	ot_side.name = "CD64 Dark"
	var e0: Dictionary = ot_side.samples[1]  # SCL4_E4
	var proc = load("res://addons/n64_audio_tools/cs/N64AudioProcessor.cs").new()
	proc.LoadWav(other.path_join(e0.source))
	e0.settings.rate = 8000
	e0.settings.lowpass = 2500
	var dark = proc.Process(e0.settings)
	write_bytes(other.path_join(e0.adpcm), dark.Adpcm)
	e0.book = Array(dark.Book)
	e0.sample_count = dark.SampleCount
	e0.sample_rate = dark.SampleRate
	ot_side.instruments = [ot_side.instruments[2]]  # Pair: SCL4_E4 + SCL3_As4
	ot_side.instruments[0].name = "Pair dark"
	write_json(other.path_join("CD64_Fixture.n64bank.json"), ot_side)
	check(ok(tools.ImportCd64(other)), "import other settings")
	print("  ", tools.Summary)
	lib = tools.Load()
	check(lib.Samples.size() == 4, "different settings: separate sample (%d)" % lib.Samples.size())
	var pd = lib.FindInstrumentByName("Pair dark")
	check(pd.Zones[0].sample.SampleRate == 8000 and pd.Zones[1].sample == lib.FindInstrumentByName("Pair").Zones[1].sample, "Pair dark: own dark sample, shares the other")

	# 5. Bank set: programs assigned without clashes, RAM counts shared samples once.
	var set = load("res://game/audio/N64BankSet.cs").new()
	set.Name = "Mixed"
	var ev = set.Add(voices)
	check(Vector2i(ev.program, ev.bank) == Vector2i(52, 0), "own program when free (%s)" % ev)
	var et = set.Add(tw_voices)
	check(Vector2i(et.program, et.bank) == Vector2i(0, 0), "taken: lowest free (%s)" % et)
	var ek = set.Add(lib.FindInstrumentByName("Kit"))
	var ek2 = set.Add(lib.FindInstrumentByName("Kit (CD64 Twin)"))
	check(Vector2i(ek.program, ek.bank) == Vector2i(0, 128) and Vector2i(ek2.program, ek2.bank) == Vector2i(1, 128), "kits: kit programs (%s, %s)" % [ek, ek2])
	check(set.Add(voices) == ev and set.Entries.size() == 4, "adding twice keeps one entry")
	check(set.Clashes().is_empty(), "no clashes")
	var only = load("res://game/audio/N64BankSet.cs").new()
	only.Add(voices)
	check(set.StoredBytes() == only.StoredBytes() + 0 and set.StoredBytes() == sum_bytes(lib.Samples.slice(0, 3)), "RAM: distinct samples once (%d vs %d)" % [set.StoredBytes(), only.StoredBytes()])
	var sb = set.SoundBank
	check(sb.Instruments.size() == 4 and sb.Instruments[1].Program == 0 and sb.Instruments[1].Zones == tw_voices.Zones, "SoundBank: copies with the set's programs, library zones")
	check(sb.Samples.size() == 3 and set.SoundBank == sb, "SoundBank: distinct samples, cached")
	voices.Volume = 0.5
	check(set.SoundBank.Instruments[0].Volume == 0.5, "SoundBank follows instrument edits")
	set.Remove(tw_voices)
	check(set.SoundBank != sb and set.SoundBank.Instruments.size() == 3, "SoundBank rebuilt after entries change")
	check(ok(tools.SaveSet(set)) and set.resource_path == ROOT + "/sets/mixed.tres", "set saved")
	var set_text := FileAccess.get_file_as_string(set.resource_path)
	check(set_text.contains("ext_resource") and set_text.contains("/instruments/") and not set_text.contains("Adpcm"), "set references instrument files, holds no samples")
	voices.Volume = 0.9

	# 6. A CD64 song: built by instrument name against its bank set = the legacy bank song.
	check(ok(tools.ImportCd64(song_export)), "import song export")
	print("  ", tools.Summary)
	var song_set = load(tools.LastSetPath)
	var sg_side: Dictionary = read_json(load("res://addons/n64_audio_tools/cs/N64Cd64Importer.cs").new().SidecarFor(song_export))
	check(song_set.Kind == 0 and song_set.Entries.size() == sg_side.instruments.size(), "song set made")
	check(song_set.Entries.all(func(e): return e.channel >= 1 and e.program == e.channel - 1), "song set: program = channel - 1")
	var imp = load("res://addons/n64_audio_tools/cs/N64Cd64Importer.cs").new()
	check(ok(imp.Import(song_export, LEGACY_SONG)), "legacy import of the song export")
	var legacy_song = load(LEGACY_SONG)
	var midis := []
	for ch in [0, 1, 9]:
		midis.append(write_midi(scratch.path_join("song_ch%d.mid" % (ch + 1)), ch))
	var old_song = load("res://game/audio/N64Song.cs").new()
	old_song.Bank = legacy_song
	var new_song = load("res://game/audio/N64Song.cs").new()
	new_song.BankSet = song_set
	for i in 3:
		var ch: int = [0, 1, 9][i]
		var part := {path = midis[i], midi_track = -1, volume = 0.79, pan = 0.0, repeat = false, mute = false, channel = ch}
		var by_ch = song_set.Entries.filter(func(e): return e.channel == ch + 1)[0]
		var old_part := part.duplicate()
		var new_part := part.duplicate()
		if ch == 9:
			old_part.drums = true
			new_part.drums = true
		else:
			old_part.program = by_ch.program
			old_part.bank = 0
		new_part.instrument = by_ch.instrument.Name
		old_song.Tracks.append(old_part)
		new_song.Tracks.append(new_part)
	var builder = load("res://addons/n64_audio_tools/cs/N64SongBuilder.cs").new()
	check(builder.Build(old_song) == "" and builder.Build(new_song) == "", "both songs build")
	check(old_song.Events == new_song.Events and old_song.Times == new_song.Times and old_song.Events.size() > 0, "same events (%d / %d)" % [old_song.Events.size(), new_song.Events.size()])
	var pcm_old := render(old_song)
	var pcm_new := render(new_song)
	check(pcm_old.size() > 0 and pcm_old == pcm_new and peak(pcm_new) > 0.01, "same audio (%d frames, peak %.3f)" % [pcm_new.size(), peak(pcm_new)])
	new_song.Tracks[0].instrument = "No such instrument"
	check(builder.Build(new_song).contains("isn't in the bank set"), "unknown instrument reported")

	# 7. Library export -> re-import: bit-exact, ids stable, nothing duplicated.
	lib = tools.Load()
	var exp_dir := scratch.path_join("libexport")
	var n_samples: int = lib.Samples.size()
	var n_inst: int = lib.Instruments.size()
	check(ok(tools.ExportCd64(lib, PackedStringArray(), exp_dir, "Game Library")), "export library")
	print("  ", tools.Summary)
	var ex_side: Dictionary = read_json(exp_dir.path_join("game_library.n64bank.json"))
	check(ex_side.kind == "library" and ex_side.format == "cd64-n64bank" and ex_side.version == 1, "sidecar: kind library")
	check(ex_side.samples.size() == n_samples and ex_side.instruments.size() == n_inst, "every sample / instrument exported")
	check(ex_side.samples.all(func(e): return FileAccess.file_exists(exp_dir.path_join(e.source)) and FileAccess.file_exists(exp_dir.path_join(e.preview)) and e.settings.size() > 0), "sources, previews, settings")
	var ex_ids: Array = ex_side.samples.map(func(e): return e.id)
	check(ex_ids == lib.Samples.map(func(s): return s.resource_path.get_file().get_basename()), "sample ids = sample file names")
	var exp2 := scratch.path_join("libexport2")
	tools.ExportCd64(lib, PackedStringArray(), exp2, "Game Library")
	check(read_json(exp2.path_join("game_library.n64bank.json")).samples.map(func(e): return e.id) == ex_ids, "ids stable across exports")
	var sub_dir := scratch.path_join("libexport_sub")
	tools.ExportCd64(lib, PackedStringArray(["Pair dark"]), sub_dir, "Dark")
	check(read_json(sub_dir.path_join("dark.n64bank.json")).samples.size() == 2, "export of selected instruments: their samples only")
	var tools2 = new_tools(ROOT2)
	check(ok(tools2.ImportCd64(exp_dir)), "re-import into an empty library")
	print("  ", tools2.Summary)
	var lib2 = tools2.Load()
	check(lib2.Samples.size() == n_samples and lib2.Instruments.size() == n_inst, "round trip: same counts (%d, %d)" % [lib2.Samples.size(), lib2.Instruments.size()])
	check(tools2.LoadSets().is_empty(), "library export makes no bank set")
	var exact := true
	for s in lib.Samples:
		var s2 = by_meta(lib2.Samples, &"cd64_id", s.resource_path.get_file().get_basename())
		exact = exact and s2 != null and s2.Adpcm == s.Adpcm and s2.Book == s.Book and s2.LoopStart == s.LoopStart and s2.LoopEnd == s.LoopEnd \
			and s2.SampleRate == s.SampleRate and s2.TuneCents == s.TuneCents and tools.SampleKey(s) == tools2.SampleKey(s2)
	check(exact, "round trip: ADPCM, books, loops, settings bit-exact")
	for ins in lib.Instruments:
		var i2 = lib2.FindInstrumentByName(ins.Name)
		check(i2 != null and i2.Envelope == ins.Envelope and i2.Zones.size() == ins.Zones.size() and i2.IsDrumKit == ins.IsDrumKit, "round trip: instrument %s" % ins.Name)
	check(ok(tools.ImportCd64(exp_dir)), "re-import into the same library")
	print("  ", tools.Summary)
	lib = tools.Load()
	check(lib.Samples.size() == n_samples and lib.Instruments.size() == n_inst, "same library: nothing new (%d, %d)" % [lib.Samples.size(), lib.Instruments.size()])

	# 8. Variants and forks: re-processing a shared sample for one instrument.
	voices = lib.FindInstrumentByName("Voices")
	var variant = tools.DuplicateVariant(lib, voices, "Voices dark 11k")
	check(variant.Name == "Voices dark 11k" and variant.get_meta(&"variant_of") == "Voices" and variant.Zones[0].sample == voices.Zones[0].sample, "variant shares samples")
	var shared_s = variant.Zones[1].sample
	var fork = tools.Fork(lib, shared_s, variant)
	check(variant.Zones[1].sample == fork and voices.Zones[1].sample == shared_s, "fork: only the variant plays it")
	check(ok(tools.Save(lib)) and tools.Load().Samples.size() == n_samples, "unchanged fork merges back on save (%s)" % tools.Summary)
	check(variant.Zones[1].sample == shared_s, "... zones back on the original")
	fork = tools.Fork(lib, shared_s, variant)
	var p2 = load("res://addons/n64_audio_tools/cs/N64AudioProcessor.cs").new()
	p2.LoadWav(fork.SourcePath)
	fork.Settings.rate = 11025
	fork.CopyFrom(p2.Process(fork.Settings))
	var before_adpcm: PackedByteArray = shared_s.Adpcm
	check(ok(tools.Save(lib)), "save after re-processing the fork")
	lib = tools.Load()
	check(lib.Samples.size() == n_samples + 1 and shared_s.Adpcm == before_adpcm, "re-processed fork: a new sample, the shared one unchanged")
	check(FileAccess.file_exists(fork.resource_path) and fork.resource_path.begins_with(ROOT + "/samples/"), "fork saved as its own file")

	# 9. Areas: worst music set + all SFX sets, shared samples once.
	var sfx := scratch.path_join("sfx")
	copy_dir(fixture, sfx)
	var sfx_side: Dictionary = fx_side.duplicate(true)
	sfx_side.name = "Fixture SFX"
	sfx_side.kind = "sfx"
	sfx_side.instruments = [sfx_side.instruments[1]]  # Kit: all three samples
	write_json(sfx.path_join("CD64_Fixture.n64bank.json"), sfx_side)
	check(ok(tools.ImportCd64(sfx)), "import sfx export")
	var sfx_set = load(tools.LastSetPath)
	check(sfx_set.Kind == 1 and sfx_set.FindByName("Kit") == lib.FindInstrumentByName("Kit"), "sfx kind -> Sfx set, its (unchanged) Kit is the library's, found by name")
	var area = load("res://game/audio/N64AudioArea.cs").new()
	area.Name = "Temple"
	area.MusicSets = [load(fx_set.resource_path), song_set]
	area.SfxSets = [sfx_set]
	var b: Dictionary = area.Budget()
	var u_fx: int = union_bytes([fx_set, sfx_set])
	var u_song: int = union_bytes([song_set, sfx_set])
	check(b.per_music["CD64 Fixture"] == u_fx and b.per_music["SongTest"] == u_song, "per music set with the SFX (%s)" % b)
	check(u_fx == sfx_set.StoredBytes(), "fixture music shares every sample with the SFX: counted once")
	check(b.total == maxi(u_fx, u_song) and b.music_set == ("SongTest" if u_song > u_fx else "CD64 Fixture") and b.sfx == sfx_set.StoredBytes(), "worst case = biggest music set + SFX")
	area.MusicOverlaps = true
	check(area.Budget().total == union_bytes([fx_set, song_set, sfx_set]), "overlapping music: all sets at once")
	check(ok(tools.SaveArea(area)) and tools.LoadAreas().size() == 1, "area saved")

	# 10. Re-import of an export without an instrument: removed from library and sets only.
	var fx3 := scratch.path_join("fixture_v3")
	copy_dir(fixture, fx3)
	var fx3_side: Dictionary = fx_side.duplicate(true)
	fx3_side.instruments = fx3_side.instruments.filter(func(i): return i.name != "Pair")
	write_json(fx3.path_join("CD64_Fixture.n64bank.json"), fx3_side)
	var pair_path: String = tools.Load().FindInstrumentByName("Pair").resource_path
	set = load(set.resource_path)
	set.Add(tools.Load().FindInstrumentByName("Pair"))
	tools.SaveSet(set)
	check(ok(tools.ImportCd64(fx3)), "re-import fixture without Pair")
	print("  ", tools.Summary)
	lib = tools.Load()
	check(lib.FindInstrumentByName("Pair") == null and not FileAccess.file_exists(pair_path), "Pair removed with its file")
	check(lib.FindInstrumentByName("Pair (CD64 Twin)") != null and lib.FindInstrumentByName("Pair dark") != null, "other exports' Pairs kept")
	check(load(set.resource_path).Entries.size() == 3 and load(fx_set.resource_path).Entries.size() == 2, "Pair dropped from the sets")

	# 11. Converting a legacy bank: shared with the library, the bank untouched.
	check(ok(imp.Import(fixture, LEGACY)), "legacy import of the fixture")
	var bank_bytes := FileAccess.get_file_as_bytes(LEGACY)
	var legacy = load(LEGACY)
	var n_before: int = tools.Load().Samples.size()
	check(ok(tools.ConvertBank(legacy, "Legacy fixture")), "convert bank")
	print("  ", tools.Summary)
	lib = tools.Load()
	var conv = load(tools.LastSetPath)
	check(lib.Samples.size() == n_before, "converted bank's samples shared with the library (%d -> %d)" % [n_before, lib.Samples.size()])
	check(conv.Entries.size() == legacy.Instruments.size(), "set has every instrument")
	var same_ok := true
	for i in legacy.Instruments.size():
		var li = legacy.Instruments[i]
		var e = conv.Entries[i]
		same_ok = same_ok and e.program == li.Program and e.bank == li.Bank and e.instrument.Zones.size() == li.Zones.size()
		for k in li.Zones.size():
			same_ok = same_ok and e.instrument.Zones[k].sample.Adpcm == li.Zones[k].sample.Adpcm
	check(same_ok, "set: the bank's programs, same samples")
	check(FileAccess.get_file_as_bytes(LEGACY) == bank_bytes, "bank file untouched")
	check(ok(tools.ConvertBank(legacy, "Legacy fixture")) and tools.Load().Samples.size() == n_before, "converting again adds no samples")
	var song_bank = load(LEGACY_SONG)
	check(ok(tools.ConvertBank(song_bank, "Converted song")), "convert song bank")
	conv = load(tools.LastSetPath)
	check(conv.Entries.all(func(e): return e.channel == e.program + 1), "song bank's channels kept")

	# 12. Export plugin: authoring data stripped from library resources.
	var ex = load("res://addons/n64_audio_tools/export_plugin.gd")
	lib = tools.Load()
	var smp = ex.stripped(lib.Samples[0])
	check(smp.SourcePath == "" and smp.SourceHash == "" and smp.Settings.is_empty() and not smp.has_meta(&"cd64_export") and smp.Adpcm == lib.Samples[0].Adpcm, "sample stripped")
	var ins2 = ex.stripped(lib.Instruments[0])
	check(ins2 != null and not ins2.has_meta(&"cd64_export") and not ins2.has_meta(&"cd64_name") and ins2.Zones[0].sample == lib.Instruments[0].Zones[0].sample, "instrument untagged, zones keep sample files")
	check(lib.Instruments[0].has_meta(&"cd64_export"), "... the library's own copy keeps its tags")
	var st2 = ex.stripped(song_set)
	check(st2 != null and not st2.has_meta(&"cd64_export"), "set untagged")
	new_song.Tracks[0].instrument = "x"
	var sg2 = ex.stripped(new_song)
	check(sg2.Tracks.is_empty() and sg2.BankSet == song_set, "song: parts stripped, bank set kept")
	check(ex._skips(ROOT + "/library.tres", ROOT) and ex._skips(ROOT + "/_source/a.wav", ROOT) and not ex._skips(ROOT + "/samples/a.tres", ROOT), "library index and recordings not exported")

	for f in midis:
		DirAccess.remove_absolute(f)
	cleanup()
	print("%s: %d / %d checks passed" % ["PASS" if fails == 0 else "FAIL", checks - fails, checks])
	quit(1 if fails else 0)


func new_tools(root: String):
	var t = load("res://addons/n64_audio_tools/cs/N64LibraryTools.cs").new()
	t.Root = root
	return t


func ok(err: String) -> bool:
	if err != "":
		printerr("    error: ", err)
	return err == ""


func cleanup() -> void:
	for d in [ROOT, ROOT2, "res://audio/_source/zz_lib_legacy", "res://audio/_source/zz_lib_legacy_song"]:
		remove_dir(ProjectSettings.globalize_path(d))
	for f in [LEGACY, LEGACY_SONG]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f))


func remove_dir(d: String) -> void:
	if not DirAccess.dir_exists_absolute(d):
		return
	for sub in DirAccess.get_directories_at(d):
		remove_dir(d.path_join(sub))
	for f in DirAccess.get_files_at(d):
		DirAccess.remove_absolute(d.path_join(f))
	var da := DirAccess.open(d)
	for f in [".gdignore"]:
		if FileAccess.file_exists(d.path_join(f)):
			DirAccess.remove_absolute(d.path_join(f))
	DirAccess.remove_absolute(d)


func by_meta(arr: Array, meta: StringName, value: String):
	for r in arr:
		if r.get_meta(meta, "") == value:
			return r
	return null


func names(arr: Array) -> Array:
	return arr.map(func(i): return i.Name)


func entry_prog(set, name: String) -> Vector2i:
	var e = set.EntryFor(name)
	return Vector2i(e.program, e.bank) if e else Vector2i(-1, -1)


func sum_bytes(samples: Array) -> int:
	var n := 0
	for s in samples:
		n += s.StoredBytes()
	return n


func union_bytes(sets: Array) -> int:
	var seen := {}
	var n := 0
	for st in sets:
		for s in st.DistinctSamples():
			if not seen.has(s):
				seen[s] = true
				n += s.StoredBytes()
	return n


## Two seconds of the song through a fresh music player.
func render(song) -> PackedVector2Array:
	var p = load("res://game/audio/N64MusicPlayer.cs").new()
	root.add_child(p)
	p.Play(song, 0.0, 0.0)
	var out := PackedVector2Array()
	for i in 4:
		out.append_array(p.Render(16000))
	p.Stop(0.0)
	p.free()
	return out


func peak(pcm: PackedVector2Array) -> float:
	var m := 0.0
	for v in pcm:
		m = maxf(m, absf(v.x))
	return m


## A one-bar format-0 MIDI file: four quarter notes on `channel`.
func write_midi(path: String, channel: int) -> String:
	var trk := PackedByteArray([0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])  # 120 BPM
	for i in 4:
		trk.append_array([0x00, 0x90 | channel, 48 + i * 5, 100, 0x60, 0x80 | channel, 48 + i * 5, 0])
	trk.append_array([0x00, 0xFF, 0x2F, 0x00])
	var b := PackedByteArray("MThd".to_ascii_buffer())
	b.append_array([0, 0, 0, 6, 0, 0, 0, 1, 0, 0x60])
	b.append_array("MTrk".to_ascii_buffer())
	b.append_array([0, 0, (trk.size() >> 8) & 0xFF, trk.size() & 0xFF])
	b.append_array(trk)
	write_bytes(path, b)
	return path


func write_bytes(path: String, data: PackedByteArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()


func read_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func write_json(path: String, d: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d, "  ", false, true))
	f.close()


func copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	for sub in DirAccess.get_directories_at(from):
		copy_dir(from.path_join(sub), to.path_join(sub))
	for f in DirAccess.get_files_at(from):
		DirAccess.copy_absolute(from.path_join(f), to.path_join(f))


func check(ok_: bool, what: String) -> bool:
	checks += 1
	if not ok_:
		fails += 1
		printerr("  FAIL: ", what)
	return ok_
