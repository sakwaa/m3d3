extends SceneTree
## Re-import provenance of the CD64 importer (EXPORT_FORMAT.md "Re-import provenance"):
## several exports and hand-made content in one bank, each export re-imported on its own;
## banks imported before tags; the sample shaping settings (start / end / fade_ms) through
## import and re-processing; the workspace's budget numbers against StoredBytes. Imports
## into throwaway banks and deletes them (and their copied recordings) afterwards.
##   Godot --headless --path . --script res://addons/n64_audio_tools/tests/cd64_provenance_test.gd \
##     -- <fixture folder (cd64_make_fixture.gd)> <a real plugin export> <scratch folder>

const BANK := "res://audio/banks/zz_cd64_prov.res"
const LEGACY := "res://audio/banks/zz_cd64_legacy.res"
const SHAPED := "res://audio/banks/zz_cd64_shaped.res"
const Workspace := preload("res://addons/n64_audio_tools/ui/sound_workspace.gd")

var fails := 0
var checks := 0
var imp


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var fixture: String = a[0]
	var plugin_export: String = a[1]
	var scratch: String = a[2]
	imp = load("res://addons/n64_audio_tools/cs/N64Cd64Importer.cs").new()
	for b in [BANK, LEGACY, SHAPED]:
		check(not ResourceLoader.exists(b), "no leftover " + b)
	var fx_side: Dictionary = read_json(imp.SidecarFor(fixture))
	var pe_side: Dictionary = read_json(imp.SidecarFor(plugin_export))
	var fx: String = fx_side.name
	var pe: String = pe_side.name
	# A second copy of the fixture under another name: same sample ids, other export.
	var twin := scratch.path_join("twin")
	copy_dir(fixture, twin)
	var tw_side: Dictionary = fx_side.duplicate(true)
	tw_side.name = "CD64 Twin"
	write_json(twin.path_join("CD64_Fixture.n64bank.json"), tw_side)

	# 1. Three exports into one bank.
	for src in [fixture, plugin_export, twin]:
		check(do_import(src, BANK), "import %s" % src.get_file())
	var bank = load(BANK)
	check(bank.Name == fx, "bank keeps the first export's name (%s)" % bank.Name)
	check(bank.Samples.size() == 3 + pe_side.samples.size() + 3, "all samples (%d)" % bank.Samples.size())
	check(bank.Instruments.size() == 3 + pe_side.instruments.size() + 3, "all instruments (%d)" % bank.Instruments.size())
	check(tagged(bank.Samples, fx).size() == 3 and tagged(bank.Samples, pe).size() == pe_side.samples.size() and tagged(bank.Samples, "CD64 Twin").size() == 3, "samples tagged by export")
	check(tagged(bank.Instruments, fx).size() == 3 and tagged(bank.Instruments, "CD64 Twin").size() == 3, "instruments tagged by export")
	var src_dir := "res://audio/_source/zz_cd64_prov"
	check(sample(bank, fx, "EVELYN_5").SourcePath == src_dir + "/EVELYN_5.wav", "first export's recordings in the bank folder")
	check(sample(bank, "CD64 Twin", "EVELYN_5").SourcePath == src_dir + "/cd64_twin/EVELYN_5.wav", "same id from another export: own folder")
	check(FileAccess.file_exists(sample(bank, "CD64 Twin", "EVELYN_5").SourcePath), "twin recording copied")

	# 2. Hand-made content, one zone on a sample the plugin export will drop.
	var drop_id: String = pe_side.samples[1].id
	var mine_s = load("res://game/audio/N64Sample.cs").new()
	mine_s.Name = "my_own"
	mine_s.SourcePath = "/elsewhere/my_own.wav"
	bank.Samples.append(mine_s)
	var mine_i = load("res://game/audio/N64Instrument.cs").new()
	mine_i.Name = pe_side.instruments[0].name  # same name as an export instrument
	mine_i.Program = 100
	mine_i.Zones.append({sample = mine_s, key_lo = 0, key_hi = 60})
	mine_i.Zones.append({sample = sample(bank, pe, drop_id), key_lo = 61, key_hi = 127})
	bank.Instruments.append(mine_i)
	ResourceSaver.save(bank, BANK)
	var keep := {}  # everything not from the plugin export, as it was
	for s in bank.Samples:
		if s.get_meta(&"cd64_export", "") != pe:
			keep[s] = s.Adpcm
	var pe_inst := tagged(bank.Instruments, pe)

	# 3. The plugin export again, minus a sample: only its own content changes.
	var pe2 := scratch.path_join("plugin_v2")
	copy_dir(plugin_export, pe2)
	var pe2_side: Dictionary = pe_side.duplicate(true)
	pe2_side.samples = pe2_side.samples.filter(func(s): return s.id != drop_id)
	for ins in pe2_side.instruments:
		ins.zones = ins.zones.filter(func(z): return z.sample != drop_id)
	write_json(imp.SidecarFor(pe2), pe2_side)
	var dropped_path: String = sample(bank, pe, drop_id).SourcePath
	check(do_import(pe2, BANK), "re-import plugin export without %s" % drop_id)
	bank = load(BANK)
	check(sample(bank, pe, drop_id) == null, "dropped sample removed")
	check(not FileAccess.file_exists(dropped_path), "dropped sample's recording removed")
	check(tagged(bank.Samples, pe).size() == pe_side.samples.size() - 1, "rest of the plugin export kept")
	var all_kept := true
	for s in keep:
		all_kept = all_kept and bank.Samples.has(s) and s.Adpcm == keep[s]
	check(all_kept and bank.Samples.size() == keep.size() + pe_side.samples.size() - 1, "other exports' and hand-made samples untouched")
	check(tagged(bank.Instruments, pe) == pe_inst, "plugin export's instruments updated in place")
	check(bank.Instruments.has(mine_i) and not mine_i.has_meta(&"cd64_export"), "hand-made instrument of the same name left alone")
	check(mine_i.Zones.size() == 1 and mine_i.Zones[0].sample == mine_s, "… minus its zone on the dropped sample")
	check(tagged(bank.Instruments, fx).size() == 3 and tagged(bank.Instruments, "CD64 Twin").size() == 3, "other exports' instruments untouched")
	verify_export(bank, pe2_side, pe2, pe)

	# 4. The fixture again, minus a sample and an instrument: the plugin export survives.
	var fx2 := scratch.path_join("fixture_v2")
	copy_dir(fixture, fx2)
	var fx2_side: Dictionary = fx_side.duplicate(true)
	fx2_side.samples = fx2_side.samples.filter(func(s): return s.id != "SCL3_As4")
	fx2_side.instruments = fx2_side.instruments.filter(func(i): return i.name != "Pair")
	for ins in fx2_side.instruments:
		ins.zones = ins.zones.filter(func(z): return z.sample != "SCL3_As4")
	write_json(fx2.path_join("CD64_Fixture.n64bank.json"), fx2_side)
	check(do_import(fx2, BANK), "re-import fixture without SCL3_As4 and Pair")
	bank = load(BANK)
	check(tagged(bank.Samples, fx).size() == 2 and tagged(bank.Instruments, fx).size() == 2, "fixture: sample and instrument removed")
	check(tagged(bank.Instruments, fx).filter(func(i): return i.Name == "Pair").is_empty(), "fixture's Pair removed")
	check(tagged(bank.Instruments, "CD64 Twin").filter(func(i): return i.Name == "Pair").size() == 1, "twin's Pair kept")
	check(sample(bank, "CD64 Twin", "SCL3_As4") != null and FileAccess.file_exists(sample(bank, "CD64 Twin", "SCL3_As4").SourcePath), "twin's SCL3_As4 and its recording kept")
	check(tagged(bank.Samples, pe).size() == pe_side.samples.size() - 1, "plugin export survives")
	verify_export(bank, pe2_side, pe2, pe)
	verify_export(bank, fx2_side, fx2, fx)
	verify_export(bank, tw_side, twin, "CD64 Twin")

	# 5. Banks imported before tags: the export they were named after takes them over.
	check(do_import(fixture, LEGACY), "legacy: first import")
	var legacy = load(LEGACY)
	for r in Array(legacy.Samples) + Array(legacy.Instruments):
		r.remove_meta(&"cd64_export")
		if r.has_meta(&"cd64_id"):
			r.remove_meta(&"cd64_id")
	var hand_s = load("res://game/audio/N64Sample.cs").new()
	hand_s.Name = "hand"
	legacy.Samples.append(hand_s)
	var hand_i = load("res://game/audio/N64Instrument.cs").new()
	hand_i.Name = "Voices"  # like the export's, but plays the user's sample
	hand_i.Zones.append({sample = hand_s})
	legacy.Instruments.append(hand_i)
	ResourceSaver.save(legacy, LEGACY)
	var old_samples: Array = legacy.Samples.duplicate()
	# Another export into it first: no takeover (it isn't the bank's own export).
	check(do_import(plugin_export, LEGACY), "legacy: another export added")
	legacy = load(LEGACY)
	check(tagged(legacy.Samples, fx).is_empty() and legacy.Samples.size() == 4 + pe_side.samples.size(), "… untagged content untouched")
	check(do_import(fx2, LEGACY), "legacy: re-import of its own export")
	check(imp.Summary.contains("took over"), "… takes the untagged import over")
	legacy = load(LEGACY)
	check(tagged(legacy.Samples, fx).size() == 2 and legacy.Samples.size() == 3 + pe_side.samples.size(), "… no duplicates, dropped sample removed (%d)" % legacy.Samples.size())
	check(legacy.Samples.has(old_samples[0]) and legacy.Samples.has(old_samples[1]), "… same sample objects")
	check(not FileAccess.file_exists("res://audio/_source/zz_cd64_legacy/SCL3_As4.wav"), "… dropped recording removed")
	check(legacy.Instruments.has(hand_i) and not hand_i.has_meta(&"cd64_export") and hand_i.Zones.size() == 1, "… hand-made Voices left alone")
	check(tagged(legacy.Instruments, fx).size() == 2, "… the export's instruments taken over (%d)" % tagged(legacy.Instruments, fx).size())
	# Pair isn't in the export any more: untagged, it can't be told from a hand-made one, so it stays.
	var pair: Array = legacy.Instruments.filter(func(i): return i.Name == "Pair")
	check(pair.size() == 1 and not pair[0].has_meta(&"cd64_export") and pair[0].Zones.size() == 1, "… untagged Pair kept, minus the dropped sample's zone")
	check(legacy.Instruments.size() == 2 + 2 + pe_side.instruments.size(), "… instrument count")
	verify_export(legacy, fx2_side, fx2, fx)

	# 6. Shaping settings: start / end / fade_ms through import and re-processing.
	var shaped := scratch.path_join("shaped")
	copy_dir(fixture, shaped)
	var sh_side: Dictionary = fx_side.duplicate(true)
	sh_side.name = "CD64 Shaped"
	# SCL4_E4 (one-shot): 20–70 % of its recording, fading over the last tenth of it.
	var shapes := {SCL4_E4 = {}, EVELYN_5 = {start = 0.05, end = -1.0, fade_ms = 20.0}}
	var plain_counts := {}
	var e4_secs := 0.0
	for d in sh_side.samples:
		if not shapes.has(d.id):
			continue
		var p = load("res://addons/n64_audio_tools/cs/N64AudioProcessor.cs").new()
		p.LoadWav(shaped.path_join(d.source))
		plain_counts[d.id] = p.Process(d.settings).SampleCount
		if d.id == "SCL4_E4":
			e4_secs = p.SourceSeconds
			shapes.SCL4_E4 = {start = 0.2 * e4_secs, end = 0.7 * e4_secs, fade_ms = 100.0 * e4_secs}
		d.settings.merge(shapes[d.id], true)
		if d.id == "EVELYN_5":  # loop times count from the cut's start
			d.settings.loop_start -= 0.05
			d.settings.loop_end -= 0.05
		var r = p.Process(d.settings)
		var f := FileAccess.open(shaped.path_join(d.adpcm), FileAccess.WRITE)
		f.store_buffer(r.Adpcm)
		f.close()
		d.book = Array(r.Book)
		d.sample_count = r.SampleCount
		d.sample_rate = r.SampleRate
		d.loop = r.Loop
		d.loop_start = r.LoopStart
		d.loop_end = r.LoopEnd
	write_json(shaped.path_join("CD64_Fixture.n64bank.json"), sh_side)
	check(do_import(shaped, SHAPED), "shaped export imports")
	var sb = load(SHAPED)
	for id in shapes:
		var s = sample(sb, "CD64 Shaped", id)
		for k in shapes[id]:
			check(is_equal_approx(float(s.Settings.get(k, -99)), shapes[id][k]), "%s setting %s stored (%s)" % [id, k, s.Settings.get(k)])
		var p = load("res://addons/n64_audio_tools/cs/N64AudioProcessor.cs").new()
		check(p.LoadWav(s.SourcePath) == "", id + " recording loads")
		var r = p.Process(s.Settings)
		check(r.Adpcm == s.Adpcm and r.SampleCount == s.SampleCount and r.LoopStart == s.LoopStart and r.LoopEnd == s.LoopEnd, id + " re-processes to the same sample")
	# … and the processor honours them (the cut shortens the sample; the fade ends silent).
	var e4 = sample(sb, "CD64 Shaped", "SCL4_E4")
	check(absi(e4.SampleCount - roundi(0.5 * e4_secs * e4.SampleRate)) <= 32,
		"SCL4_E4 cut to half its recording (%d samples, %d uncut)" % [e4.SampleCount, plain_counts.SCL4_E4])
	var pcm: PackedByteArray = e4.PcmBytes()
	var peak := 0
	for k in range(0, pcm.size(), 2):
		peak = maxi(peak, absi(pcm.decode_s16(k)))
	var tail := 0
	for k in range(maxi(pcm.size() - 32, 0), pcm.size(), 2):
		tail = maxi(tail, absi(pcm.decode_s16(k)))
	check(peak > 0 and tail < peak * 0.1, "SCL4_E4 fades out (tail %d, peak %d)" % [tail, peak])
	var ev = sample(sb, "CD64 Shaped", "EVELYN_5")
	check(ev.SampleCount <= plain_counts.EVELYN_5 - roundi(0.04 * ev.SampleRate), "EVELYN_5 starts 0.05 s later (%d vs %d samples)" % [ev.SampleCount, plain_counts.EVELYN_5])

	# 6b. Song-bank sidecars ("song": true): each instrument's channel kept as metadata.
	var songdir := scratch.path_join("songmode")
	copy_dir(fixture, songdir)
	var so_side: Dictionary = fx_side.duplicate(true)
	so_side.name = "CD64 SongMode"
	so_side.song = true
	var chans := {Voices = 3, Kit = 10, Pair = 4}
	for ins in so_side.instruments:
		ins.channel = chans[ins.name]
	write_json(songdir.path_join("CD64_Fixture.n64bank.json"), so_side)
	check(do_import(songdir, SHAPED), "song-bank sidecar imports")
	sb = load(SHAPED)
	var so_inst := tagged(sb.Instruments, "CD64 SongMode")
	check(so_inst.size() == 3 and so_inst.all(func(i): return i.get_meta(&"cd64_channel", 0) == chans[i.Name]), "channels stored per instrument")
	so_side.erase("song")
	write_json(songdir.path_join("CD64_Fixture.n64bank.json"), so_side)
	check(do_import(songdir, SHAPED), "same export without song")
	check(so_inst.all(func(i): return not i.has_meta(&"cd64_channel")), "… channels cleared (ignored without song)")
	so_side.song = true
	so_side.instruments[0].channel = 17
	write_json(songdir.path_join("CD64_Fixture.n64bank.json"), so_side)
	check(imp.Import(songdir, SHAPED) != "", "channel 17 refused")

	# 7. Budget numbers (the workspace's toolbar and tree).
	for b in [bank, legacy, sb]:
		var total := 0
		for s in b.Samples:
			total += s.StoredBytes()
		check(total == b.StoredBytes(), "%s: samples add up to StoredBytes" % b.resource_path.get_file())
		check(Workspace.budget_report(b).begins_with("Sample RAM: %.1f KB of the %d KB budget" % [b.StoredBytes() / 1024.0, Workspace.budget_bytes() / 1024]), "%s: report total" % b.resource_path.get_file())
		for ins in b.Instruments:
			var seen := {}
			var n := 0
			for z in ins.Zones:
				if z.get("sample") and not seen.has(z.sample):
					seen[z.sample] = true
					n += z.sample.StoredBytes()
			check(Workspace.instrument_bytes(ins) == n and Workspace.budget_report(b).contains("%s: %.1f KB" % [ins.Name, n / 1024.0]), "%s: %s's share" % [b.resource_path.get_file(), ins.Name])
	check(Workspace.budget_bytes() == int(ProjectSettings.get_setting(Workspace.BUDGET_SETTING, Workspace.DEFAULT_BUDGET_KB)) * 1024, "budget from the project setting")
	print("  ", Workspace.budget_report(bank).replace("\n", "\n  "))

	for b in [BANK, LEGACY, SHAPED]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(b))
		remove_dir(ProjectSettings.globalize_path("res://audio/_source/" + b.get_file().get_basename()))
	print("%s: %d / %d checks passed" % ["PASS" if fails == 0 else "FAIL", checks - fails, checks])
	quit(1 if fails else 0)


func do_import(src: String, bank_path: String) -> bool:
	var err: String = imp.Import(src, bank_path)
	if err != "":
		printerr("  ", err)
	else:
		print("  ", imp.Summary.left(400))
	return err == ""


## One export's content in the bank, against its sidecar: everything there, bit-exact.
func verify_export(bank, side: Dictionary, folder: String, tag: String) -> void:
	var ok: bool = tagged(bank.Samples, tag).size() == side.samples.size() and tagged(bank.Instruments, tag).size() == side.instruments.size()
	for d in side.samples:
		var s = sample(bank, tag, d.id)
		ok = ok and s != null and s.Adpcm == FileAccess.get_file_as_bytes(folder.path_join(d.adpcm)) and s.SampleCount == d.sample_count
		ok = ok and s != null and FileAccess.get_file_as_bytes(s.SourcePath) == FileAccess.get_file_as_bytes(folder.path_join(d.source))
	for d in side.instruments:
		var found := tagged(bank.Instruments, tag).filter(func(i): return i.Name == d.name)
		ok = ok and found.size() == 1 and found[0].Zones.size() == d.zones.size() and found[0].Program == d.program
		if found.size() == 1:
			for i in mini(found[0].Zones.size(), d.zones.size()):
				ok = ok and found[0].Zones[i].sample == sample(bank, tag, d.zones[i].sample)
	check(ok, "%s matches its export" % tag)


func tagged(items: Array, tag: String) -> Array:
	return items.filter(func(r): return r != null and r.get_meta(&"cd64_export", "") == tag)


func sample(bank, tag: String, id: String):
	for s in tagged(bank.Samples, tag):
		if s.get_meta(&"cd64_id", "") == id:
			return s
	return null


func read_json(path: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func write_json(path: String, data) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  ", false, true))
	f.close()


func copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	for d in DirAccess.get_directories_at(from):
		copy_dir(from.path_join(d), to.path_join(d))
	for f in DirAccess.get_files_at(from):
		DirAccess.copy_absolute(from.path_join(f), to.path_join(f))


func remove_dir(dir: String) -> void:
	for d in DirAccess.get_directories_at(dir):
		remove_dir(dir.path_join(d))
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func check(ok: bool, what: String) -> bool:
	checks += 1
	if not ok:
		fails += 1
		printerr("  FAIL: ", what)
	return ok
