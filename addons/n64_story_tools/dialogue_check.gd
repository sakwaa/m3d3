@tool
extends RefCounted
## Dialogue graph helpers for the editor: each node's outgoing links, and the problems
## worth flagging (broken or missing links, unreachable nodes, unknown speakers / flags /
## items, empty text, pages too long for the box).

const LinePreview := preload("res://addons/n64_story_tools/ui/line_preview.gd")


## Outgoing links of `node` in port order: [[object, property, label], …]. `node` null =
## the dialogue's start.
static func outputs(d: Dialogue, node: DialogueNode) -> Array:
	if node == null:
		return [[d, "start", "start"]]
	if node is DialogueChoice:
		return node.options.filter(func(o): return o != null).map(func(o): return [o, "next", o.text])
	if node is DialogueBranch:
		var out: Array = node.cases.filter(func(c): return c != null).map(func(c): return [c, "next", "if"])
		out.append([node, "next", "else"])
		return out
	if node is DialogueJump:
		return []
	return [[node, "next", "next"]]


## [{node (id or ""), text, error (bool)}]
static func problems(d: Dialogue, db: StoryDatabase, gs: Node) -> Array:
	var out := []
	var add := func(id: String, text: String, error := false): out.append({node = id, text = text, error = error})
	var ids := {}
	for n in d.nodes:
		if n == null:
			continue
		if ids.has(n.id):
			add.call(n.id, "Two nodes share the id '%s'." % n.id, true)
		ids[n.id] = n
	if d.id == &"":
		add.call("", "The dialogue has no id (translation keys need one).", true)
	if d.start == "":
		add.call("", "Nothing is connected to Start.", true)
	elif not ids.has(d.start):
		add.call("", "Start leads to a missing node '%s'." % d.start, true)
	# Links and reachability.
	var reached := {}
	var todo := [d.start]
	while not todo.is_empty():
		var id: String = todo.pop_back()
		if id == "" or reached.has(id) or not ids.has(id):
			continue
		reached[id] = true
		for o in outputs(d, ids[id]):
			todo.append(o[0].get(o[1]))
	for n in d.nodes:
		if n == null:
			continue
		for o in outputs(d, n):
			var to: String = o[0].get(o[1])
			if to != "" and not ids.has(to):
				add.call(n.id, "Links to a missing node '%s'." % to, true)
		if not reached.has(n.id):
			add.call(n.id, "Can't be reached from Start.")
		_check_node(n, db, gs, add)
	return out


static func _check_node(n: DialogueNode, db: StoryDatabase, gs: Node, add: Callable) -> void:
	if n is DialogueLine:
		if n.text.strip_edges() == "":
			add.call(n.id, "Empty line.")
		if n.speaker != &"" and db and db.find_character(n.speaker) == null:
			add.call(n.id, "Unknown speaker '%s'." % n.speaker, true)
		for page in LinePreview.overflowing_pages(n.text, gs, n.style):
			add.call(n.id, "Page %d is too long for the box." % (page + 1))
	elif n is DialogueChoice:
		var shown: Array = n.options.filter(func(o): return o != null)
		if shown.is_empty():
			add.call(n.id, "A choice with no options ends the conversation.")
		if shown.size() > 4:
			add.call(n.id, "More than 4 options.")
		for o in shown:
			if o.text.strip_edges() == "":
				add.call(n.id, "An option has no text.")
			_check_conditions(n.id, o.conditions, db, add)
	elif n is DialogueBranch:
		for c in n.cases:
			if c == null:
				continue
			if c.conditions.is_empty():
				add.call(n.id, "A case with no conditions always passes (cases after it never run).")
			_check_conditions(n.id, c.conditions, db, add)
	elif n is DialogueAction:
		if n.effects.is_empty():
			add.call(n.id, "An action with no effects.")
		for e in n.effects:
			if e:
				_check_refs(n.id, e.kind in [StoryEffect.Kind.GIVE_ITEM, StoryEffect.Kind.TAKE_ITEM, StoryEffect.Kind.EQUIP_ITEM],
					e.kind in [StoryEffect.Kind.SET_FLAG, StoryEffect.Kind.CLEAR_FLAG, StoryEffect.Kind.SET_COUNTER, StoryEffect.Kind.ADD_TO_COUNTER],
					e.item, e.flag, db, add)
	elif n is DialogueJump:
		if n.dialogue == null:
			add.call(n.id, "Jump has no dialogue.", true)
		elif n.entry != "" and n.dialogue.find(n.entry) == null:
			add.call(n.id, "'%s' has no node '%s'." % [n.dialogue.id, n.entry], true)


static func _check_conditions(id: String, conditions: Array, db: StoryDatabase, add: Callable) -> void:
	for c in conditions:
		if c:
			_check_refs(id, c.kind in [StoryCondition.Kind.ITEM, StoryCondition.Kind.EQUIPPED], c.kind == StoryCondition.Kind.FLAG,
				c.item, c.flag, db, add)


static func _check_refs(id: String, uses_item: bool, uses_flag: bool, item: StringName, flag: String, db: StoryDatabase, add: Callable) -> void:
	if db == null:
		return
	if uses_item and db.find_item(item) == null:
		add.call(id, "Unknown item '%s'." % item, true)
	if uses_flag:
		if flag == "":
			add.call(id, "A flag is left empty.", true)
		elif db.find_flag(flag) == null:
			add.call(id, "Flag '%s' isn't registered (it works, but never resets)." % flag)
