extends SceneTree
## Sound effects (N64SfxPlayer, N64AudioArea.Apply): a CD64 "kind": "sfx" export imported into
## a throwaway library plays by name in parallel with a song playing from its music set; the
## music renders exactly as without effects even when the effects overflow their own voice
## pool (no music voice is ever stolen); stop with a fade, pitch / volume / pan changes on a
## playing effect, the per-effect instance limit, an unknown name (handle 0), duplicate names
## across sets, Apply loading the area's sets (and unloading another area's), the loaded-RAM
## figure, the export plugin's stripping of an SFX set, the bank set editor's audition.
## Works in a throwaway library folder under res://audio/ and deletes it afterwards.
##   Godot --headless --path . --script res://addons/n64_audio_tools/tests/sfx_test.gd \
##     -- <a CD64 sfx export ("kind": "sfx")> <a CD64 song export ("song": true)> <scratch folder>

const ROOT := "res://audio/zz_sfx_test"
const RATE := 32000

var fails := 0
var checks := 0


func _initialize() -> void:
	_run.call_deferred()  # nodes added from _initialize aren't ready yet


func _run() -> void:
	var a := OS.get_cmdline_user_args()
	var sfx_export: String = a[0]
	var song_export: String = a[1]
	var scratch: String = a[2]
	DirAccess.make_dir_recursive_absolute(scratch)
	cleanup()
	var tools = load("res://addons/n64_audio_tools/cs/N64LibraryTools.cs").new()
	tools.Root = ROOT
	var player_script = load("res://game/audio/N64SfxPlayer.cs")

	# 1. Import: an Sfx set named after the export, holding its instruments.
	var side: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
		load("res://addons/n64_audio_tools/cs/N64Cd64Importer.cs").new().SidecarFor(sfx_export)))
	check(ok(tools.ImportCd64(sfx_export)), "import sfx export")
	var sfx_set = load(tools.LastSetPath)
	check(sfx_set.Kind == 1 and sfx_set.Name == side.name and sfx_set.Entries.size() == side.instruments.size(), "Sfx set made (%s, %d entries)" % [sfx_set.Name, sfx_set.Entries.size()])
	var loop_name: String = ""
	var shot_name: String = ""
	for e in sfx_set.Entries:
		var looped: bool = e.instrument.Zones[0].sample.Loop
		if looped and loop_name == "":
			loop_name = e.instrument.Name
		elif not looped and shot_name == "":
			shot_name = e.instrument.Name
	check(loop_name != "" and shot_name != "", "a looping and a one-shot effect (%s / %s)" % [loop_name, shot_name])
	var loop_ins = sfx_set.FindByName(loop_name)
	var z0: Dictionary = loop_ins.Zones[0]
	check(player_script.NaturalKey(loop_ins) == int(z0.get("root_key", z0.sample.RootKey)), "natural key: first zone's root (%d)" % player_script.NaturalKey(loop_ins))
	check(ok(tools.ImportCd64(song_export)), "import song export")
	var song_set = load(tools.LastSetPath)
	check(song_set.Kind == 0, "song set is a music set")

	# A song against its set (two melodic slots + the kit).
	var song = load("res://game/audio/N64Song.cs").new()
	song.BankSet = song_set
	var midis := []
	for ch in [0, 1, 9]:
		var slot = song_set.Entries.filter(func(e): return e.channel == ch + 1)
		if slot.is_empty():
			continue
		var path := scratch.path_join("sfx_song_ch%d.mid" % (ch + 1))
		write_midi(path, ch)
		midis.append(path)
		var part := {path = path, midi_track = -1, volume = 0.79, pan = 0.0, repeat = false, mute = false, channel = ch, instrument = slot[0].instrument.Name}
		if ch == 9:
			part.drums = true
		song.Tracks.append(part)
	check(load("res://addons/n64_audio_tools/cs/N64SongBuilder.cs").new().Build(song) == "" and song.Events.size() > 0, "song builds (%d events)" % song.Events.size())

	# 2. Area: Apply loads its SFX sets (another area's set unloaded) and its music set.
	var other_set = load("res://game/audio/N64BankSet.cs").new()
	other_set.Name = "Other area"
	other_set.Kind = 1
	other_set.Add(sfx_set.FindByName(shot_name))  # same name as in sfx_set
	var area = load("res://game/audio/N64AudioArea.cs").new()
	area.Name = "Test area"
	area.MusicSets = [song_set]
	area.SfxSets = [sfx_set]
	var music = load("res://game/audio/N64MusicPlayer.cs").new()
	root.add_child(music)
	var sfx = player_script.new()
	sfx.ReverbSend = 0.0  # silence right after a stop (no reverb tail)
	sfx.Sets = [other_set]
	root.add_child(sfx)
	check(sfx.LoadedSets() == [other_set] and sfx.Has(shot_name) and not sfx.Has(loop_name), "exported Sets loaded on ready")
	check(sfx.MaxVoices == 8 and sfx.Synth.MaxVoices == 8 and music.Synth != sfx.Synth, "own synth, 8 voices by default")
	area.Apply(music, sfx)
	check(sfx.LoadedSets() == [sfx_set] and sfx.Has(loop_name) and sfx.Has(shot_name), "Apply: area's SFX sets loaded, the other area's unloaded")
	check(music.BankSet == song_set, "Apply: music set given to the music player")
	var expected: int = union_bytes([song_set, sfx_set])
	check(sfx.LoadedBytes() == sfx_set.StoredBytes(), "SFX loaded RAM = the set's (%d)" % sfx.LoadedBytes())
	check(area.LoadedBytes(music, sfx) == expected and expected == area.WorstCaseBytes(), "loaded RAM = music set + SFX set = worst case (%d / %d)" % [area.LoadedBytes(music, sfx), area.WorstCaseBytes()])
	check(sfx.Load(other_set) and sfx.Has(shot_name) and Array(sfx.EffectNames()).count(shot_name) == 1, "duplicate name across sets: listed once (warning printed above)")
	check(area.LoadedBytes(music, sfx) == union_bytes([song_set, sfx_set, other_set]), "loaded RAM counts shared samples once")
	sfx.Unload(other_set)

	# 3. Music unchanged by effects, even with the SFX pool overflowing.
	var ref := render_song(song)
	music.Play(song, 0.0, 0.0)
	check(area.LoadedBytes(music, sfx) == expected, "loaded RAM while playing (%d)" % area.LoadedBytes(music, sfx))
	var mus := PackedVector2Array()
	var fx := PackedVector2Array()
	var max_active := 0
	var handles := []
	for i in 16:
		for k in 3:
			handles.append(play(sfx, shot_name if (i + k) % 2 else loop_name, float(k), 0.8, -0.5 + 0.5 * k))
		max_active = maxi(max_active, sfx.Synth.ActiveVoices())
		mus.append_array(music.Render(4000))
		fx.append_array(sfx.Render(4000))
	check(handles.all(func(h): return h > 0), "%d effects started" % handles.size())
	check(max_active <= 8, "SFX voices stay in their pool (max %d active of 8)" % max_active)
	check(not sfx.IsPlaying(handles[0]), "oldest effect stolen by newer ones")
	check(mus == ref and peak(mus) > 0.01, "music bit-identical to a render without effects (%d frames, peak %.3f)" % [mus.size(), peak(mus)])
	check(peak(fx) > 0.01, "effects audible (peak %.3f)" % peak(fx))
	music.Stop(0.0)
	sfx.StopAll(0.0)
	sfx.Render(640)
	check(sfx.PlayingCount(&"") == 0 and sfx.Synth.ActiveVoices() == 0, "StopAll(0): silent")

	# 4. Unknown name.
	check(play(sfx, &"No such effect") == 0, "unknown name: handle 0 (warning printed above)")
	check(not sfx.IsPlaying(0), "handle 0 never plays")

	# 5. Stop with a fade (looping effect: plays until stopped).
	var h: int = play(sfx, loop_name)
	var on: PackedVector2Array = sfx.Render(RATE / 2)
	check(sfx.IsPlaying(h) and rms(on.slice(RATE / 4)) > 0.005, "looping effect plays (rms %.4f)" % rms(on.slice(RATE / 4)))
	sfx.Stop(h, 0.2)
	var fade: PackedVector2Array = sfx.Render(RATE * 18 / 100)
	check(sfx.IsPlaying(h) and rms(fade.slice(0, 800)) > rms(fade.slice(fade.size() - 800)) * 3.0, "fading: still playing, getting quieter (%.4f -> %.4f)" % [rms(fade.slice(0, 800)), rms(fade.slice(fade.size() - 800))])
	sfx.Render(RATE * 2 / 100 + 64)
	check(not sfx.IsPlaying(h), "fade over: stopped")
	check(peak(sfx.Render(1600)) == 0.0, "silent after the fade")
	# Stop with the instrument's release, and at once.
	h = play(sfx, loop_name)
	sfx.Render(1600)
	sfx.Stop(h, -1.0)
	check(sfx.Synth.IsReleasing(h), "Stop(-1): instrument release")
	sfx.Render(int(loop_ins.Envelope.w * RATE) + 64)
	check(not sfx.IsPlaying(h), "release over")
	h = play(sfx, loop_name)
	sfx.Render(1600)
	sfx.Stop(h, 0.0)
	sfx.Render(64)
	check(not sfx.IsPlaying(h), "Stop(): at once")

	# 6. Pitch / volume / pan on a playing effect.
	h = play(sfx, loop_name)
	sfx.Render(RATE / 2)
	var base := crossings(sfx.Render(RATE / 2))
	sfx.SetPitch(h, 12.0)
	sfx.Render(64)
	var up := crossings(sfx.Render(RATE / 2))
	check(base > 0 and up > base * 1.6 and up < base * 2.4, "SetPitch +12: about twice the frequency (%d -> %d crossings)" % [base, up])
	sfx.SetPan(h, -1.0)
	sfx.Render(64)
	var left: PackedVector2Array = sfx.Render(RATE / 10)
	check(peak(left) > 0.005 and peak_r(left) < peak(left) * 0.01, "SetPan -1: left only (L %.4f, R %.5f)" % [peak(left), peak_r(left)])
	sfx.SetVolume(h, 0.0)
	sfx.Render(64)
	check(peak(sfx.Render(RATE / 10)) == 0.0 and sfx.IsPlaying(h), "SetVolume 0: silent, still playing")
	sfx.Stop(h, 0.0)
	sfx.Render(64)
	# pitchSemitones +1 sounds exactly like the key a semitone up (same zone).
	var nat: int = player_script.NaturalKey(loop_ins)
	check(nat + 1 <= int(z0.get("key_hi", 127)), "natural key + 1 in the first zone")
	var p1: int = play(sfx, loop_name, 1.0)
	var a1: PackedVector2Array = sfx.Render(RATE / 4)
	sfx.Stop(p1, 0.0)
	sfx.Render(64)
	var p2: int = play(sfx, loop_name, 0.0, 1.0, 0.0, nat + 1)
	var a2: PackedVector2Array = sfx.Render(RATE / 4)
	sfx.Stop(p2, 0.0)
	sfx.Render(64)
	check(peak(a1) > 0.01 and a1 == a2, "pitchSemitones +1 = key + 1, sample-exact")

	# 7. Instance limit: per call, and the exported default.
	var g := []
	for i in 3:
		g.append(play(sfx, shot_name, 0.0, 1.0, 0.0, -1, 2))
	sfx.Render(640)
	check(sfx.PlayingCount(shot_name) == 2 and not sfx.IsPlaying(g[0]) and sfx.IsPlaying(g[1]) and sfx.IsPlaying(g[2]), "maxInstances 2: the oldest stopped")
	sfx.MaxInstances = 1
	var l1: int = play(sfx, loop_name)
	var l2: int = play(sfx, loop_name)
	sfx.Render(640)
	check(sfx.PlayingCount(loop_name) == 1 and not sfx.IsPlaying(l1) and sfx.IsPlaying(l2), "MaxInstances 1: retrigger replaces")
	check(sfx.PlayingCount(shot_name) == 2, "limit counts per effect")
	var l3: int = play(sfx, loop_name, 0.0, 1.0, 0.0, -1, 0)
	sfx.Render(64)
	check(sfx.PlayingCount(loop_name) == 2 and sfx.IsPlaying(l2) and sfx.IsPlaying(l3), "maxInstances 0: no limit")
	sfx.MaxInstances = 0

	# 8. Unload: its effects fade out quickly, nothing loaded.
	sfx.Unload(sfx_set)
	sfx.Render(640)
	check(sfx.Synth.ActiveVoices() == 0 and sfx.LoadedBytes() == 0 and not sfx.Has(loop_name), "Unload: effects stop, RAM freed")
	check(play(sfx, loop_name) == 0, "unloaded effect doesn't play")

	# 9. Export stripping keeps an SFX set playable.
	var ex = load("res://addons/n64_audio_tools/export_plugin.gd")
	var st = ex.stripped(sfx_set)
	check(st != null and st.Kind == 1 and st.Entries.size() == sfx_set.Entries.size() and not st.has_meta(&"cd64_export"), "export: SFX set ships, untagged")

	# 10. Bank set editor: audition by name.
	var se = load("res://addons/n64_audio_tools/ui/bank_set_editor.gd").new()
	root.add_child(se)
	se.edit(sfx_set)
	check(se._audition.visible and se._grid.get_child_count() == 7 * (sfx_set.Entries.size() + 1), "editor: audition bar, a Play per effect")
	se._pitch.value = 3.0
	var eh: int = se.play_effect(loop_name)
	check(eh > 0 and se._sfx_player.IsPlaying(eh), "editor: Play auditions the effect")
	se.edit(song_set)
	check(not se._audition.visible, "music set: no audition")
	se.free()

	music.free()
	sfx.free()
	for f in midis:
		DirAccess.remove_absolute(f)
	cleanup()
	print("%s: %d / %d checks passed" % ["PASS" if fails == 0 else "FAIL", checks - fails, checks])
	quit(1 if fails else 0)


## N64SfxPlayer.Play with its defaults (GDScript passes every argument of a C# method).
func play(sfx, effect, pitch := 0.0, volume := 1.0, pan := 0.0, key := -1, max_instances := -1) -> int:
	return sfx.Play(effect, pitch, volume, pan, key, max_instances)


## Two seconds of the song through a fresh music player (no effects).
func render_song(song) -> PackedVector2Array:
	var p = load("res://game/audio/N64MusicPlayer.cs").new()
	root.add_child(p)
	p.Play(song, 0.0, 0.0)
	var out := PackedVector2Array()
	for i in 16:
		out.append_array(p.Render(4000))
	p.Stop(0.0)
	p.free()
	return out


func union_bytes(sets: Array) -> int:
	var seen := {}
	var n := 0
	for st in sets:
		for s in st.DistinctSamples():
			if not seen.has(s):
				seen[s] = true
				n += s.StoredBytes()
	return n


func peak(pcm: PackedVector2Array) -> float:
	var m := 0.0
	for v in pcm:
		m = maxf(m, absf(v.x))
	return m


func peak_r(pcm: PackedVector2Array) -> float:
	var m := 0.0
	for v in pcm:
		m = maxf(m, absf(v.y))
	return m


func rms(pcm: PackedVector2Array) -> float:
	if pcm.is_empty():
		return 0.0
	var s := 0.0
	for v in pcm:
		s += v.x * v.x
	return sqrt(s / pcm.size())


## Upward zero crossings of the left channel (a pitch measure).
func crossings(pcm: PackedVector2Array) -> int:
	var n := 0
	for i in range(1, pcm.size()):
		if pcm[i - 1].x < 0.0 and pcm[i].x >= 0.0:
			n += 1
	return n


## A one-bar format-0 MIDI file: four quarter notes on `channel`.
func write_midi(path: String, channel: int) -> void:
	var trk := PackedByteArray([0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20])  # 120 BPM
	for i in 4:
		trk.append_array([0x00, 0x90 | channel, 48 + i * 5, 100, 0x60, 0x80 | channel, 48 + i * 5, 0])
	trk.append_array([0x00, 0xFF, 0x2F, 0x00])
	var b := PackedByteArray("MThd".to_ascii_buffer())
	b.append_array([0, 0, 0, 6, 0, 0, 0, 1, 0, 0x60])
	b.append_array("MTrk".to_ascii_buffer())
	b.append_array([0, 0, (trk.size() >> 8) & 0xFF, trk.size() & 0xFF])
	b.append_array(trk)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(b)
	f.close()


func ok(err: String) -> bool:
	if err != "":
		printerr("    error: ", err)
	return err == ""


func cleanup() -> void:
	remove_dir(ProjectSettings.globalize_path(ROOT))


func remove_dir(d: String) -> void:
	if not DirAccess.dir_exists_absolute(d):
		return
	for sub in DirAccess.get_directories_at(d):
		remove_dir(d.path_join(sub))
	for f in DirAccess.get_files_at(d):
		DirAccess.remove_absolute(d.path_join(f))
	if FileAccess.file_exists(d.path_join(".gdignore")):
		DirAccess.remove_absolute(d.path_join(".gdignore"))
	DirAccess.remove_absolute(d)


func check(ok_: bool, what: String) -> bool:
	checks += 1
	if not ok_:
		fails += 1
		printerr("  FAIL: ", what)
	return ok_
