@tool
class_name DialogueText
extends RefCounted
## Turns a line's text (with its markup) into pages for the text box:
##  - {player}, {char:id}, {item:id}, {count:id} become names / numbers (by reference, so
##    renaming a character or item renames it everywhere);
##  - a blank line starts a new page;
##  - [red]…[/red] (blue, green, yellow, orange, purple, grey) colour words;
##  - [p] / [p=0.8] pause the typing (seconds), [speed=0.5]…[/speed] change its speed.
## Translators keep the markup, and may move it around.

const COLORS := {
	red = Color("ff5a4a"), blue = Color("6fa8ff"), green = Color("6ee06a"), yellow = Color("ffe14d"),
	orange = Color("ffa040"), purple = Color("c98bff"), grey = Color("a8a8a8"),
}
const DEFAULT_PAUSE := 0.5

static var _page_split := RegEx.create_from_string("\\n[ \\t]*\\n")
static var _reference := RegEx.create_from_string("\\{(player|char:[^}]+|item:[^}]+|count:[^}]+)\\}")


## Pages of `text`: [{bbcode, plain, pauses = {char index: seconds}, speeds = [[char
## index, multiplier], …]}]. Character indices count what the box types (tags excluded).
static func pages(text: String, gs: Node) -> Array:
	var out := []
	for page in _split_pages(expand(text, gs).strip_edges()):
		out.append(parse_page(page.strip_edges()))
	return out


static func _split_pages(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	var at := 0
	for m in _page_split.search_all(text):
		out.append(text.substr(at, m.get_start() - at))
		at = m.get_end()
	out.append(text.substr(at))
	return out


## Replaces {…} references with names / counts; unknown ones stay visible.
static func expand(text: String, gs: Node) -> String:
	var db: StoryDatabase = gs.story if gs else null
	var out := ""
	var at := 0
	for m in _reference.search_all(text):
		out += text.substr(at, m.get_start() - at)
		out += _resolve(m.get_string(1), db, gs, m.get_string())
		at = m.get_end()
	return out + text.substr(at)


static func _resolve(ref: String, db: StoryDatabase, gs: Node, raw: String) -> String:
	if ref == "player":
		if gs and gs.player_name != "":
			return gs.player_name
		ref = "char:player"
	var colon := ref.find(":")
	var kind := ref.substr(0, colon)
	var id := StringName(ref.substr(colon + 1).strip_edges())
	match kind:
		"char":
			var c := db.find_character(id) if db else null
			return c.get_display_name() if c else raw
		"item":
			var it := db.find_item(id) if db else null
			return it.get_display_name() if it else raw
		"count":
			return str(gs.item_count(id)) if gs else raw
	return raw


static func parse_page(page: String) -> Dictionary:
	var bb := ""
	var plain := ""
	var pauses := {}
	var speeds := []
	var i := 0
	while i < page.length():
		var ch := page[i]
		if ch == "[":
			var close := page.find("]", i)
			if close > i:
				var tag := page.substr(i + 1, close - i - 1).strip_edges().to_lower()
				var name := tag.get_slice("=", 0).trim_prefix("/")
				var arg := tag.get_slice("=", 1) if tag.contains("=") else ""
				var handled := true
				if COLORS.has(name):
					bb += "[/color]" if tag.begins_with("/") else "[color=#%s]" % COLORS[name].to_html(false)
				elif name == "p" and not tag.begins_with("/"):
					var at := plain.length()
					pauses[at] = pauses.get(at, 0.0) + (arg.to_float() if arg != "" else DEFAULT_PAUSE)
				elif name == "speed":
					speeds.append([plain.length(), 1.0 if tag.begins_with("/") else maxf(arg.to_float(), 0.05)])
				else:
					handled = false
				if handled:
					i = close + 1
					continue
			bb += "[lb]"
			plain += "["
			i += 1
			continue
		bb += ch
		plain += ch
		i += 1
	return {bbcode = bb, plain = plain, pauses = pauses, speeds = speeds}


## Text without markup (for previews and the editor's line lists).
static func strip(text: String) -> String:
	var out := []
	for page in _split_pages(text.strip_edges()):
		out.append(parse_page(page.strip_edges()).plain)
	return " / ".join(out)
