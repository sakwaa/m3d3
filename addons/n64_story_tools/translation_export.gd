@tool
extends RefCounted
## Writes every translatable string (character and item names, item descriptions, dialogue
## lines, options and custom item messages, UI text) to one CSV that Godot imports as
## translations: "keys,en,<other languages>". Re-exporting keeps the other languages'
## columns; a row whose English changed since the last export gets its translations
## marked "[CHANGED] …" so translators find it. Languages other than English are added to
## Project Settings > Internationalization (English comes from the game data itself, so it
## stays current without exporting).

const SETTING := "n64/story/translations_csv"
const DEFAULT_PATH := "res://story/translations/strings.csv"
const CHANGED := "[CHANGED] "


## Keys and English texts, in a stable order.
static func collect(db: StoryDatabase, dialogues: Array) -> Array:
	var rows := [["ui.got_item", StoryEffect.DEFAULT_MESSAGE]]
	if db:
		for c in db.characters:
			if c and c.id != &"":
				rows.append(["char.%s.name" % c.id, c.display_name if c.display_name != "" else String(c.id).capitalize()])
		for it in db.items:
			if it and it.id != &"":
				rows.append(["item.%s.name" % it.id, it.display_name if it.display_name != "" else String(it.id)])
				if it.description != "":
					rows.append(["item.%s.desc" % it.id, it.description])
	for d: Dialogue in dialogues:
		for n in d.nodes:
			if n is DialogueLine:
				rows.append([d.line_key(n), n.text])
			elif n is DialogueChoice:
				for o in n.options:
					if o:
						rows.append([d.line_key(n, o), o.text])
			elif n is DialogueAction:
				for i in n.effects.size():
					var e: StoryEffect = n.effects[i]
					if e and e.kind == StoryEffect.Kind.GIVE_ITEM and e.message != "":
						rows.append(["%s.%d" % [d.line_key(n), i], e.message])
	return rows


## Writes the CSV (merging existing translations); returns the number of rows. Then
## reimport it and register() the languages.
static func export_csv(path: String, db: StoryDatabase, dialogues: Array) -> int:
	var old := read_csv(path)
	var langs: PackedStringArray = old.langs
	_ensure_dir(path)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("Story: can't write %s" % path)
		return 0
	var header := PackedStringArray(["keys", "en"])
	header.append_array(langs)
	file.store_csv_line(header)
	var rows := collect(db, dialogues)
	for r in rows:
		var line := PackedStringArray([r[0], r[1]])
		var prev: Dictionary = old.rows.get(r[0], {})
		var changed: bool = not prev.is_empty() and prev.get("en", r[1]) != r[1]
		for lang in langs:
			var t: String = prev.get(lang, "")
			if changed and t != "" and not t.begins_with(CHANGED):
				t = CHANGED + t
			line.append(t)
		file.store_csv_line(line)
	file.close()
	return rows.size()


## {langs: [other languages], rows: {key: {en, <lang>…}}}
static func read_csv(path: String) -> Dictionary:
	var out := {langs = PackedStringArray(), rows = {}}
	if not FileAccess.file_exists(path):
		return out
	var file := FileAccess.open(path, FileAccess.READ)
	var header := file.get_csv_line()
	for i in range(2, header.size()):
		out.langs.append(header[i])
	while not file.eof_reached():
		var line := file.get_csv_line()
		if line.size() < 2 or line[0] == "":
			continue
		var row := {}
		for i in range(1, mini(line.size(), header.size())):
			row[header[i]] = line[i]
		out.rows[line[0]] = row
	return out


static func _ensure_dir(path: String) -> bool:
	return DirAccess.make_dir_recursive_absolute(path.get_base_dir()) in [OK, ERR_ALREADY_EXISTS]


## The other languages' .translation files (made by Godot's CSV import) go in the
## project's translation list.
static func register(path: String) -> void:
	var langs: PackedStringArray = read_csv(path).langs
	var key := "internationalization/locale/translations"
	var list: PackedStringArray = ProjectSettings.get_setting(key, PackedStringArray())
	var changed := false
	for lang in langs:
		var t := "%s.%s.translation" % [path.get_basename(), lang]
		if not list.has(t):
			list.append(t)
			changed = true
	if changed:
		ProjectSettings.set_setting(key, list)
		ProjectSettings.save()
