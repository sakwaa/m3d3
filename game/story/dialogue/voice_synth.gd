@tool
class_name VoiceSynth
extends RefCounted
## Animal Crossing style talking blips, synthesised: each letter plays a short syllable
## (a buzz through two vowel formants) whose vowel and pitch step come from the letter,
## so the same word always sounds the same. The character sets pitch, range and timbre
## (CharacterDef). Blips are made once and cached. Sampled voices can replace this later.

const MIX_RATE := 16000
const LENGTH := 0.075
## Vowel formants (F1, F2 in Hz): a, e, i, o, u.
const FORMANTS := [Vector2(730, 1090), Vector2(530, 1840), Vector2(290, 2250), Vector2(570, 840), Vector2(320, 870)]

static var _cache := {}


## The blip for `letter` in `voice`'s voice (null for spaces / punctuation).
static func blip(voice: CharacterDef, letter: String) -> AudioStreamWAV:
	var c := letter.to_lower().unicode_at(0) if letter != "" else 0
	if not _speaks(c):
		return null
	var vowel := "aeiou".find(char(c))
	if vowel < 0:
		vowel = (c * 7) % 5
	var steps := ((c * 37) % 9 - 4) / 4.0  # -1 … 1
	var semis := snappedf(steps * voice.voice_range, 0.5)
	var key := "%d|%d|%d|%.1f" % [roundi(voice.voice_pitch), voice.voice_timbre, vowel, semis]
	if not _cache.has(key):
		_cache[key] = make(voice.voice_pitch * pow(2.0, semis / 12.0), vowel, voice.voice_timbre)
	return _cache[key]


## Letters and digits speak (any script); spaces and punctuation don't.
static func _speaks(c: int) -> bool:
	if c == 0:
		return false
	var ch := char(c)
	return ch != ch.to_upper() or (c >= 48 and c <= 57) or c > 0x2E80  # cased letters, digits, CJK


static func make(pitch: float, vowel: int, timbre: int) -> AudioStreamWAV:
	var n := int(MIX_RATE * LENGTH)
	var f: Vector2 = FORMANTS[vowel]
	var r1 := _resonator(f.x, 90.0)
	var r2 := _resonator(f.y, 130.0)
	var y1 := Vector2.ZERO  # last two outputs of each resonator
	var y2 := Vector2.ZERO
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var peak := 0.0001
	for i in n:
		var t := float(i) / n
		# A small fall in pitch over the syllable, like speech.
		phase = fmod(phase + pitch * (1.0 - 0.12 * t) / MIX_RATE, 1.0)
		var src := 0.0
		match timbre:
			CharacterDef.Timbre.SOFT:
				src = sin(TAU * phase) + 0.35 * sin(2.0 * TAU * phase)
			CharacterDef.Timbre.BRIGHT:
				src = 1.0 - 2.0 * phase
			_:
				src = 1.0 if phase < 0.18 else -0.22
		var a := r1.x * src + r1.y * y1.x + r1.z * y1.y
		y1 = Vector2(a, y1.x)
		var b := r2.x * src + r2.y * y2.x + r2.z * y2.y
		y2 = Vector2(b, y2.x)
		var dry := 0.35 if timbre == CharacterDef.Timbre.SOFT else 0.12
		var env := minf(t / 0.07, 1.0) * pow(1.0 - t, 1.6)
		var v := (a + 0.55 * b + dry * src) * env
		out[i] = v
		peak = maxf(peak, absf(v))
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		data.encode_s16(i * 2, int(clampf(out[i] / peak * 0.8, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.data = data
	return wav


## Two-pole band-pass (gain, feedback 1, feedback 2) at `freq` with `bandwidth` Hz.
static func _resonator(freq: float, bandwidth: float) -> Vector3:
	var r := exp(-PI * bandwidth / MIX_RATE)
	return Vector3(1.0 - r, 2.0 * r * cos(TAU * freq / MIX_RATE), -r * r)
