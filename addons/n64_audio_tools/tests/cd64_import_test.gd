extends SceneTree
## Round trip of the CD64 importer (N64Cd64Importer) on a fixture from cd64_make_fixture.gd:
## the saved bank must decode to exactly the export's samples/*.wav, carry the sidecar's
## ADPCM / books / loops / settings / instruments verbatim, re-process from the copied
## recordings, and update in place on re-import. Leaves the test bank behind (delete
## res://audio/banks/<bank>.res and res://audio/_source/<bank>/ after).
##   Godot --headless --path . --script res://addons/n64_audio_tools/tests/cd64_import_test.gd \
##     -- <fixture folder> <scratch folder> [res://audio/banks/zz_cd64_test.res]

var fails := 0
var checks := 0


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var fixture: String = a[0]
	var scratch: String = a[1]
	var bank_path: String = a[2] if a.size() > 2 else "res://audio/banks/zz_cd64_test.res"
	var src_dir := "res://audio/_source/%s" % bank_path.get_file().get_basename()
	var imp = load("res://addons/n64_audio_tools/cs/N64Cd64Importer.cs").new()
	var sidecar: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(fixture.path_join("CD64_Fixture.n64bank.json")))

	check(imp.BankPathFor(fixture) == "res://audio/banks/cd64_fixture.res", "default bank path: " + imp.BankPathFor(fixture))
	check(imp.SidecarFor(fixture.path_join("CD64_Fixture.n64bank.json")) != "", "sidecar given directly is accepted")

	# 1. Fresh import.
	check(not ResourceLoader.exists(bank_path), "no leftover test bank")
	var err: String = imp.Import(fixture, bank_path)
	check(err == "", "import: " + err)
	print("  ", imp.Summary)
	var bank = ResourceLoader.load(bank_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	verify(bank, sidecar, fixture, src_dir)

	# 2. Same export again: updated in place, nothing duplicated.
	bank = load(bank_path)  # the cached one, as the open workspace holds it
	var before: Array = bank.Samples.duplicate()
	var before_inst: Array = bank.Instruments.duplicate()
	err = imp.Import(fixture, bank_path)
	check(err == "", "re-import: " + err)
	print("  ", imp.Summary)
	check(bank.Samples.size() == before.size() and bank.Instruments.size() == before_inst.size(), "re-import: same counts")
	for i in before.size():
		check(bank.Samples[i] == before[i], "re-import keeps sample object %d" % i)
	for i in before_inst.size():
		check(bank.Instruments[i] == before_inst[i], "re-import keeps instrument object %d" % i)
	verify(ResourceLoader.load(bank_path, "", ResourceLoader.CACHE_MODE_IGNORE), sidecar, fixture, src_dir)

	# 3. User additions + an export that dropped a sample.
	var mine_s = load("res://game/audio/N64Sample.cs").new()
	mine_s.Name = "my_own"
	mine_s.SourcePath = "/elsewhere/my_own.wav"
	bank.Samples.append(mine_s)
	var mine_i = load("res://game/audio/N64Instrument.cs").new()
	mine_i.Name = "My instrument"
	mine_i.Zones.append({sample = mine_s, key_lo = 0, key_hi = 127})
	var dropped = sample_for(bank, src_dir, "SCL3_As4")
	mine_i.Zones.append({sample = dropped, key_lo = 0, key_hi = 127})
	bank.Instruments.append(mine_i)
	ResourceSaver.save(bank, bank_path)
	var v2 := scratch.path_join("fixture_v2")
	copy_dir(fixture, v2)
	var side2: Dictionary = sidecar.duplicate(true)
	side2.samples = side2.samples.filter(func(s): return s.id != "SCL3_As4")
	for ins in side2.instruments:
		ins.zones = ins.zones.filter(func(z): return z.sample != "SCL3_As4")
	write_json(v2.path_join("CD64_Fixture.n64bank.json"), side2)
	err = imp.Import(v2, bank_path)
	check(err == "", "import of v2: " + err)
	print("  ", imp.Summary)
	var b3 = ResourceLoader.load(bank_path, "", ResourceLoader.CACHE_MODE_IGNORE)
	check(sample_for(b3, src_dir, "SCL3_As4") == null, "dropped sample removed")
	check(not FileAccess.file_exists(src_dir + "/SCL3_As4.wav"), "dropped sample's recording removed")
	check(b3.Samples.size() == 3, "2 export samples + the user's (%d)" % b3.Samples.size())
	var mi = b3.Instruments.filter(func(i): return i.Name == "My instrument")
	check(mi.size() == 1 and mi[0].Zones.size() == 1, "user instrument kept, minus the dropped sample's zone")
	check(b3.Instruments.size() == 4, "3 export instruments + the user's")
	var only_export := b3.duplicate()
	only_export.Samples = b3.Samples.filter(func(s): return s.Name != "my_own")
	only_export.Instruments = b3.Instruments.filter(func(i): return i.Name != "My instrument")
	verify(only_export, side2, v2, src_dir)

	# 4. Bad sidecars are refused before anything is written.
	var stamp := FileAccess.get_modified_time(bank_path)
	for bad in [["../escape", "id"], ["adpcm", "path"], ["book", "book"], ["loop", "loop"], ["zone", "zone"], ["version", "version"]]:
		var dir := scratch.path_join("bad_" + bad[1])
		copy_dir(fixture, dir)
		var sb: Dictionary = sidecar.duplicate(true)
		match bad[1]:
			"id": sb.samples[0].id = "../escape"
			"path": sb.samples[0].adpcm = "../../etc/hosts"
			"book": sb.samples[0].book = [100]  # one predictor but frames use more (or odd length)
			"loop": sb.samples[0].loop_end = sb.samples[0].sample_count + 1
			"zone": sb.instruments[0].zones[0].sample = "NOPE"
			"version": sb.version = 2
		write_json(dir.path_join("CD64_Fixture.n64bank.json"), sb)
		err = imp.Import(dir, bank_path)
		check(err != "", "bad %s refused" % bad[1])
		print("  refused (%s): %s" % [bad[1], err])
	check(FileAccess.get_modified_time(bank_path) == stamp, "bank untouched by refused imports")

	print("%s: %d / %d checks passed" % ["PASS" if fails == 0 else "FAIL", checks - fails, checks])
	quit(1 if fails else 0)


## The bank against the sidecar: every field verbatim, PCM = the export's preview WAVs.
func verify(bank, side: Dictionary, folder: String, src_dir: String) -> void:
	check(bank != null and "Samples" in bank, "bank loads")
	check(bank.Name == side.name, "bank name")
	check(bank.Samples.size() == side.samples.size(), "sample count %d" % bank.Samples.size())
	for d in side.samples:
		var s = sample_for(bank, src_dir, d.id)
		if not check(s != null, "sample %s present" % d.id):
			continue
		var tag: String = d.id
		check(s.Name == d.name, tag + " name")
		check(s.Adpcm == FileAccess.get_file_as_bytes(folder.path_join(d.adpcm)), tag + " ADPCM bytes")
		check(Array(s.Book) == d.book.map(func(c): return int(c)), tag + " book")
		check(s.SampleCount == d.sample_count and s.SampleRate == d.sample_rate, tag + " count / rate")
		check(s.Loop == d.loop and s.LoopStart == d.loop_start and s.LoopEnd == d.loop_end, tag + " loop")
		check(s.RootKey == d.root_key and is_equal_approx(s.TuneCents, d.tune_cents), tag + " root / tune")
		check(s.SourcePath == "%s/%s.wav" % [src_dir, d.id], tag + " SourcePath")
		check(FileAccess.get_file_as_bytes(s.SourcePath) == FileAccess.get_file_as_bytes(folder.path_join(d.source)), tag + " recording copied")
		# (Approximate for floats: Godot's own JSON reader, used here, can be an ulp off.)
		for k in d.settings:
			var v = s.Settings.get(k)
			check(v == d.settings[k] or (typeof(v) in [TYPE_INT, TYPE_FLOAT] and is_equal_approx(v, d.settings[k])),
				"%s setting %s (%s vs %s)" % [tag, k, v, d.settings[k]])
		for k in ["rate", "bits", "predictors", "root_key"]:
			check(typeof(s.Settings[k]) == TYPE_INT, "%s setting %s is an int" % [tag, k])
		# Bit-for-bit what the plugin previewed.
		var pcm: PackedByteArray = s.PcmBytes()
		var wav := wav_data(folder.path_join(d.preview))
		check(pcm == wav, "%s decodes to samples/%s.wav (%d vs %d bytes)" % [tag, d.id, pcm.size(), wav.size()])
		# The workspace's re-process flow: same recording + settings = same sample.
		var p = load("res://addons/n64_audio_tools/cs/N64AudioProcessor.cs").new()
		check(p.LoadWav(s.SourcePath) == "", tag + " recording loads")
		var r = p.Process(s.Settings)
		check(r.Adpcm == s.Adpcm and r.LoopStart == s.LoopStart and r.LoopEnd == s.LoopEnd, tag + " re-processes to the same ADPCM")
	check(bank.Instruments.size() == side.instruments.size(), "instrument count")
	for d in side.instruments:
		var found = bank.Instruments.filter(func(i): return i.Name == d.name)
		if not check(found.size() == 1, "instrument %s present" % d.name):
			continue
		var ins = found[0]
		var tag: String = d.name
		check(ins.Program == d.program and ins.Bank == d.bank and ins.IsDrumKit == d.is_drum_kit, tag + " program / bank / drums")
		check(ins.Envelope.is_equal_approx(Vector4(d.envelope[0], d.envelope[1], d.envelope[2], d.envelope[3])), tag + " envelope")
		check(ins.Vibrato.is_equal_approx(Vector3(d.vibrato[0], d.vibrato[1], d.vibrato[2])), tag + " vibrato")
		check(is_equal_approx(ins.Volume, d.volume) and is_equal_approx(ins.Pan, d.pan), tag + " volume / pan")
		check(ins.Zones.size() == d.zones.size(), tag + " zone count")
		for i in mini(ins.Zones.size(), d.zones.size()):
			var z: Dictionary = ins.Zones[i]
			var e: Dictionary = d.zones[i]
			check(z.sample == sample_for(bank, src_dir, e.sample), "%s zone %d sample is the bank's %s" % [tag, i, e.sample])
			for k in ["key_lo", "key_hi", "vel_lo", "vel_hi", "root_key"]:
				check(typeof(z[k]) == TYPE_INT and z[k] == int(e[k]), "%s zone %d %s" % [tag, i, k])
			for k in ["tune_cents", "volume", "pan"]:
				check(is_equal_approx(z[k], e[k]), "%s zone %d %s" % [tag, i, k])
		# The synth picks the zone the sidecar's order gives (first match).
		for e in d.zones:
			var want = d.zones.filter(func(o): return e.key_lo >= o.key_lo and e.key_lo <= o.key_hi and e.vel_hi >= o.vel_lo and e.vel_hi <= o.vel_hi)[0]
			var z = ins.ZoneFor(int(e.key_lo), int(e.vel_hi))
			check(z != null and z.sample == sample_for(bank, src_dir, want.sample), "%s plays %s at key %d vel %d" % [tag, want.sample, e.key_lo, e.vel_hi])


func sample_for(bank, src_dir: String, id: String):
	for s in bank.Samples:
		if s.SourcePath == "%s/%s.wav" % [src_dir, id]:
			return s
	return null


func wav_data(path: String) -> PackedByteArray:
	var b := FileAccess.get_file_as_bytes(path)
	var pos := 12
	while pos + 8 <= b.size():
		var n := b.decode_u32(pos + 4)
		if b.slice(pos, pos + 4).get_string_from_ascii() == "data":
			return b.slice(pos + 8, pos + 8 + n)
		pos += 8 + n + (n & 1)
	return PackedByteArray()


func copy_dir(from: String, to: String) -> void:
	DirAccess.make_dir_recursive_absolute(to)
	for d in DirAccess.get_directories_at(from):
		copy_dir(from.path_join(d), to.path_join(d))
	for f in DirAccess.get_files_at(from):
		DirAccess.copy_absolute(from.path_join(f), to.path_join(f))


func write_json(path: String, data) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  ", false, true))
	f.close()


func check(ok: bool, what: String) -> bool:
	checks += 1
	if not ok:
		fails += 1
		printerr("  FAIL: ", what)
	return ok
