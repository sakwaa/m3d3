@tool
extends RefCounted
## English words <-> their sounds (ARPAbet, stress left out) for the in-game script. Reads
## the project word list (WORDS: names, invented words, fixes; it wins) and CMUdict (CMUDICT,
## American English). Tooling only: neither file ships.
##
## Words that sound the same (right / rite / write) share a sound key; their order in
## words_for() is the spelling mark that tells them apart (0 = no mark): the word list's
## words first (in file order), then by how common they are (FREQUENCY), then shortest
## spelling, then A - Z. Changing either file can
## change marks, so banners are re-checked whenever they're rebuilt.

const CMUDICT := "res://glyphs/cmudict/cmudict.dict"
const WORDS := "res://glyphs/words.txt"
## Word frequencies ("word count" per line, most common first): FrequencyWords (MIT), from
## film subtitles: everyday words rank first among those sounding alike.
const FREQUENCY := "res://glyphs/frequency/en_50k.txt"
const VOWELS := ["AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW"]
const CONSONANTS := ["B", "CH", "D", "DH", "F", "G", "HH", "JH", "K", "L", "M", "N", "NG", "P", "R", "S", "SH", "T", "TH",
	"V", "W", "Y", "Z", "ZH"]

## word -> PackedStringArray (its first / chosen pronunciation).
static var _sounds := {}
## "SH AA P" -> Array of words, ranked.
static var _words := {}
static var _stamp := ""


static func _ensure() -> void:
	var stamp := "%d:%d:%d" % [FileAccess.get_modified_time(CMUDICT), FileAccess.get_modified_time(WORDS),
		FileAccess.get_modified_time(FREQUENCY)]
	if stamp == _stamp and not _sounds.is_empty():
		return
	_stamp = stamp
	_sounds = {}
	_words = {}
	_read(WORDS)
	var listed := {}  # word -> its place in the word list
	for k in _words:
		for w in _words[k]:
			listed[w] = listed.size()
	_read(CMUDICT)
	var freq := _frequencies()
	# Within a sound: the word list's words first (its order), then the most common (tea
	# before tee, here before hear), then the shortest spellings, then A - Z.
	for k in _words:
		var list: Array = _words[k]
		if list.size() > 1:
			list.sort_custom(func(a: String, b: String) -> bool:
				if listed.has(a) != listed.has(b):
					return listed.has(a)
				if listed.has(a):
					return listed[a] < listed[b]
				# Single letters (t, c: also counted from "don't") and abbreviations last.
				if _letterish(a) != _letterish(b):
					return _letterish(b)
				var fa: int = freq.get(a, 0)
				var fb: int = freq.get(b, 0)
				if fa != fb:
					return fa > fb
				if a.length() != b.length():
					return a.length() < b.length()
				return a < b)


## Adds a file's entries ("word  PH ON EMES", "word(2) ..." for other pronunciations,
## "#" comments). Earlier files rank first.
static func _read(path: String) -> void:
	if not FileAccess.file_exists(path):
		return
	var f := FileAccess.open(path, FileAccess.READ)
	while not f.eof_reached():
		var line := f.get_line()
		var hash_at := line.find("#")
		if hash_at >= 0:
			line = line.substr(0, hash_at)
		line = line.strip_edges()
		if line.is_empty():
			continue
		var parts := line.split(" ", false)
		if parts.size() < 2:
			continue
		var word := parts[0].to_lower()
		var paren := word.find("(")
		if paren > 0:
			word = word.substr(0, paren)
		var sounds := PackedStringArray()
		for k in range(1, parts.size()):
			sounds.append(parts[k].to_upper().rstrip("012"))
		if not _sounds.has(word):
			_sounds[word] = sounds
		var key := " ".join(sounds)
		var list: Array = _words.get(key, [])
		if list.is_empty():
			_words[key] = list
		if not word in list:
			list.append(word)


static func _letterish(w: String) -> bool:
	return (w.length() == 1 and not w in ["a", "i", "o"]) or "." in w


## word -> count.
static func _frequencies() -> Dictionary:
	var out := {}
	if not FileAccess.file_exists(FREQUENCY):
		return out
	var f := FileAccess.open(FREQUENCY, FileAccess.READ)
	while not f.eof_reached():
		var parts := f.get_line().split(" ", false)
		if parts.size() >= 2:
			out[parts[0].to_lower()] = parts[1].to_int()
	return out


## The sounds of `word` (lower case), empty when neither file knows it.
static func sounds_of(word: String) -> PackedStringArray:
	_ensure()
	return _sounds.get(word.to_lower(), PackedStringArray())


## Words with exactly these sounds, ranked (index = spelling mark).
static func words_for(sounds: PackedStringArray) -> PackedStringArray:
	_ensure()
	return PackedStringArray(_words.get(" ".join(sounds), []))


static func is_vowel(sound: String) -> bool:
	return sound in VOWELS
