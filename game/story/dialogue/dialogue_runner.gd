@tool
class_name DialogueRunner
extends RefCounted
## Walks a Dialogue graph against the game state, without any UI: branches and actions run
## by themselves, and it stops at what the player has to see or answer. Each step returns
## an event:
##  {type = "line", text, key, speaker (CharacterDef or null), name ("" = no name tag),
##   color, style (DialogueLine.Style), icon (item announcements)}
##  {type = "choice", options = [text, …], cancel (index into options, or -1)}
##  {type = "end"}
## Call advance() after a line, choose(i) after a choice.

## Branch / action / jump steps allowed between two shown events (catches link loops).
const MAX_STEPS := 512

var gs: Node
var dialogue: Dialogue
var _node: DialogueNode
var _announce := []  # item announcements still to show (then go on to _node)
var _options := []  # the shown choice's options (DialogueOption), in display order


func _init(game_state: Node) -> void:
	gs = game_state


func start(d: Dialogue, entry := "") -> Dictionary:
	dialogue = d
	_announce.clear()
	return _run(_find(d, entry if entry != "" else d.start))


## After a line: the next event.
func advance() -> Dictionary:
	if not _announce.is_empty():
		return _announcement()
	if _node is DialogueLine:
		return _run(_find(dialogue, _node.next))
	return _end()


## After a choice: picks option `index` (display order) and returns the next event.
func choose(index: int) -> Dictionary:
	if not _node is DialogueChoice or index < 0 or index >= _options.size():
		return _end()
	return _run(_find(dialogue, _options[index].next))


func _run(node: DialogueNode) -> Dictionary:
	var steps := 0
	while node:
		steps += 1
		if steps > MAX_STEPS:
			push_error("Dialogue '%s': more than %d steps without a line (a loop?)" % [dialogue.id, MAX_STEPS])
			return _end()
		_node = node
		if node is DialogueLine:
			return _line(node)
		if node is DialogueChoice:
			var shown := _choice(node)
			if not shown.is_empty():
				return shown
			node = null  # nothing to pick: the conversation ends
		elif node is DialogueBranch:
			node = _find(dialogue, _branch(node))
		elif node is DialogueAction:
			for e in node.effects:
				if e:
					var a: Dictionary = e.apply(gs, "%s.%s" % [dialogue.line_key(node), node.effects.find(e)])
					if not a.is_empty():
						_announce.append(a)
			if not _announce.is_empty():
				_node = node
				return _announcement()
			node = _find(dialogue, node.next)
		elif node is DialogueJump:
			if node.dialogue == null:
				return _end()
			dialogue = node.dialogue
			node = _find(dialogue, node.entry if node.entry != "" else dialogue.start)
		else:
			node = _find(dialogue, node.next)
	return _end()


func _line(line: DialogueLine) -> Dictionary:
	var who: CharacterDef = gs.story.find_character(line.speaker) if gs.story and line.speaker != &"" else null
	return {
		type = "line",
		text = StoryDatabase.localized(dialogue.line_key(line), line.text),
		key = dialogue.line_key(line),
		speaker = who,
		name = who.get_display_name() if who and not line.hide_name else "",
		color = who.name_color if who else Color.WHITE,
		style = line.style,
		icon = null,
	}


## Item announcements show between the action and the node after it.
func _announcement() -> Dictionary:
	var a: Dictionary = _announce.pop_front()
	if _announce.is_empty():
		# Once they're all shown, advance() continues after the action.
		_node = _AfterAction.new(_node.next)
	return {type = "line", text = a.text, key = "", speaker = null, name = "", color = Color.WHITE,
		style = DialogueLine.Style.BOX, icon = a.icon}


func _choice(choice: DialogueChoice) -> Dictionary:
	_options.clear()
	var texts := []
	var cancel := -1
	for i in choice.options.size():
		var o: DialogueOption = choice.options[i]
		if o and StoryCondition.all(o.conditions, gs):
			if i == choice.cancel_option:
				cancel = _options.size()
			_options.append(o)
			texts.append(StoryDatabase.localized(dialogue.line_key(choice, o), o.text))
	if _options.is_empty():
		return {}
	return {type = "choice", options = texts, cancel = cancel}


func _branch(branch: DialogueBranch) -> String:
	for c in branch.cases:
		if c and StoryCondition.all(c.conditions, gs):
			return c.next
	return branch.next


func _end() -> Dictionary:
	_node = null
	return {type = "end"}


static func _find(d: Dialogue, id: String) -> DialogueNode:
	if d == null or id == "":
		return null
	var n := d.find(id)
	if n == null:
		push_error("Dialogue '%s': no node '%s'" % [d.id, id])
	return n


## Stand-in "line" whose next is the node after an action (so advance() moves on).
class _AfterAction extends DialogueLine:
	func _init(after: String) -> void:
		next = after
