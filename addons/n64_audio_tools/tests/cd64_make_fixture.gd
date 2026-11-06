extends SceneTree
## Test fixture: a CD64 export (SFZ folder + N64 sidecar, cd64-n64bank v1) made from WAVs
## with the project's own processor / ADPCM encoder and SFZ exporter, standing in for the
## CD64 plugin. Read by cd64_import_test.gd.
##   Godot --headless --path . --script res://addons/n64_audio_tools/tests/cd64_make_fixture.gd \
##     -- <out folder> <looped.wav> <loop start> <loop end (inclusive)> <one-shot.wav> <one-shot 2.wav>
## Makes a multi-zone instrument (key + velocity splits, zone overrides), a drum kit and a
## stereo-style pair (two zones panned -1 / +1).

const BASE := {rate = 16000, lowpass = 0, trim = false, trim_db = -50, normalize = true, gain_db = 0, bits = 16,
	predictors = 4, loop = "none", loop_start = -1.0, loop_end = -1.0, crossfade_ms = 0, root_key = 60, tune_cents = 0}


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 6:
		printerr("usage: -- <out> <looped.wav> <loop start> <loop end> <one-shot.wav> <one-shot 2.wav>")
		quit(2)
		return
	var out: String = a[0]
	var defs := [
		{id = "EVELYN_5", name = "Evelyn 5 (looped)", wav = a[1], set = {rate = 22050, loop = "manual", predictors = 4, root_key = 60,
			loop_start = 0.0, loop_end = 0.0}},
		{id = "SCL4_E4", name = "SCL4 E4", wav = a[4], set = {rate = 16000, root_key = 64, tune_cents = -7.5}},
		{id = "SCL3_As4", name = "SCL3 #A4", wav = a[5], set = {rate = 11025, root_key = 70, predictors = 2, bits = 12}},
	]
	DirAccess.make_dir_recursive_absolute(out.path_join("adpcm"))
	DirAccess.make_dir_recursive_absolute(out.path_join("source"))
	var bank = load("res://game/audio/N64SoundBank.cs").new()
	bank.Name = "CD64 Fixture"
	var by_id := {}
	var sidecar_samples := []
	for d in defs:
		var proc = load("res://addons/n64_audio_tools/cs/N64AudioProcessor.cs").new()
		var err: String = proc.LoadWav(d.wav)
		if err != "":
			printerr("can't load %s: %s" % [d.wav, err])
			quit(1)
			return
		var st := BASE.duplicate()
		st.merge(d.set, true)
		if st.loop == "manual":
			# Disc loop points (source frames, inclusive end) as seconds for the processor.
			st.loop_start = float(a[2]) / proc.SourceRate
			st.loop_end = (float(a[3]) + 1.0) / proc.SourceRate
		var s = proc.Process(st)
		s.Name = d.id  # WriteSfz names samples/<Name>.wav: the id, as the plugin does
		bank.Samples.append(s)
		by_id[d.id] = s
		var f := FileAccess.open(out.path_join("adpcm/%s.bin" % d.id), FileAccess.WRITE)
		f.store_buffer(s.Adpcm)
		f.close()
		DirAccess.copy_absolute(d.wav, out.path_join("source/%s.wav" % d.id))
		sidecar_samples.append({id = d.id, name = d.name, adpcm = "adpcm/%s.bin" % d.id, book = Array(s.Book),
			sample_count = s.SampleCount, sample_rate = s.SampleRate, loop = s.Loop, loop_start = s.LoopStart,
			loop_end = s.LoopEnd, root_key = s.RootKey, tune_cents = s.TuneCents, preview = "samples/%s.wav" % d.id,
			source = "source/%s.wav" % d.id, source_rate = proc.SourceRate, settings = st})

	var insts := [
		{name = "Voices", program = 52, bank = 0, is_drum_kit = false, envelope = [0.01, 0.3, 0.7, 0.4], volume = 0.9, pan = 0.1,
			vibrato = [6.0, 5.0, 0.3], zones = [
				_zone("EVELYN_5", 0, 59, 0, 127, -1, 0.0, 1.0, 0.0),
				_zone("SCL4_E4", 60, 127, 0, 89, -1, 0.0, 1.0, 0.0),
				_zone("SCL3_As4", 60, 127, 90, 127, 70, 12.5, 0.8, -0.25)]},
		{name = "Kit", program = 0, bank = 128, is_drum_kit = true, envelope = [0.001, 0.0, 1.0, 0.1], volume = 1.0, pan = 0.0,
			vibrato = [0.0, 5.5, 0.25], zones = [
				_zone("SCL3_As4", 36, 36, 0, 127, -1, 0.0, 1.0, 0.0),
				_zone("SCL4_E4", 38, 38, 0, 127, 64, -30.0, 0.9, 0.3),
				_zone("EVELYN_5", 40, 41, 0, 127, -1, 0.0, 0.5, 0.0)]},
		{name = "Pair", program = 53, bank = 0, is_drum_kit = false, envelope = [0.005, 0.2, 0.8, 0.25], volume = 1.0, pan = 0.0,
			vibrato = [0.0, 5.5, 0.25], zones = [
				_zone("SCL4_E4", 0, 127, 0, 127, -1, 0.0, 1.0, -1.0),
				_zone("SCL3_As4", 0, 127, 0, 127, -1, 0.0, 1.0, 1.0)]},
	]
	for i in insts:
		var ins = load("res://game/audio/N64Instrument.cs").new()
		ins.Name = i.name
		ins.Program = i.program
		ins.Bank = i.bank
		ins.IsDrumKit = i.is_drum_kit
		ins.Envelope = Vector4(i.envelope[0], i.envelope[1], i.envelope[2], i.envelope[3])
		ins.Volume = i.volume
		ins.Pan = i.pan
		ins.Vibrato = Vector3(i.vibrato[0], i.vibrato[1], i.vibrato[2])
		for z in i.zones:
			var zz: Dictionary = z.duplicate()
			zz.sample = by_id[z.sample]
			ins.Zones.append(zz)
		bank.Instruments.append(ins)
	var err: String = load("res://addons/n64_audio_tools/cs/N64SoundFontExporter.cs").new().WriteSfz(bank, out)
	if err != "":
		printerr("SFZ export failed: " + err)
		quit(1)
		return
	var sidecar := {format = "cd64-n64bank", version = 1, name = bank.Name,
		origin = {disc = "Best Service - Voice Spectral II (AKAI S1000 CD-ROM)", tool = "m3d3 cd64_make_fixture"},
		x_unknown_field = {readers = "must ignore this"}, samples = sidecar_samples, instruments = insts}
	var f := FileAccess.open(out.path_join("CD64_Fixture.n64bank.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(sidecar, "  ", false, true))
	f.close()
	print("fixture: %d samples, %d instruments -> %s" % [sidecar_samples.size(), insts.size(), out])
	quit(0)


func _zone(id: String, klo: int, khi: int, vlo: int, vhi: int, root: int, tune: float, vol: float, pan: float) -> Dictionary:
	return {sample = id, key_lo = klo, key_hi = khi, vel_lo = vlo, vel_hi = vhi, root_key = root, tune_cents = tune, volume = vol, pan = pan}
