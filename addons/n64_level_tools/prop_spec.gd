@tool
class_name PropSpec
extends Resource
## A prop brush's prop: what it is (`kind`) and that kind's settings. (An NPC path's route
## is the brush's points, edited like a fence's: LevelBrush.path_points().) The settings are the
## prop node's own (its script's exported properties, plus any it adds itself, like a sign's
## word symbol ticks), shown here in the Inspector through a template node of the kind, and
## stored only where they differ from the kind's defaults. LevelRoot builds the real node
## from it at the brush (in the editor and in game, never saved with the scene; written out
## on export), like Door nodes from door brushes.

enum Kind { SIGN, STALL, RAIN_DRIP, BIRD_FLOCK, NPC_SPOT, NPC_PATH, TREE }

const SCRIPTS := {
	Kind.SIGN: "res://game/world/props/signpost.gd",
	Kind.STALL: "res://game/world/props/market_stall.gd",
	Kind.RAIN_DRIP: "res://game/world/props/rain_drip.gd",
	Kind.BIRD_FLOCK: "res://game/world/animals/bird_flock.gd",
	Kind.NPC_SPOT: "res://game/world/npc_spot.gd",
	Kind.NPC_PATH: "res://game/world/npc_path.gd",
	Kind.TREE: "res://game/world/props/world_tree.gd",
}
const NAMES := {Kind.SIGN: "Sign", Kind.STALL: "Stall", Kind.RAIN_DRIP: "RainDrip", Kind.BIRD_FLOCK: "Birds",
	Kind.NPC_SPOT: "Spot", Kind.NPC_PATH: "Path", Kind.TREE: "Tree"}

## What the prop is. Changing it starts the new kind from its defaults.
@export var kind := Kind.SIGN:
	set(v):
		if kind == v:
			return
		kind = v
		settings = {}
		_drop_template()
		notify_property_list_changed()
		emit_changed()
## The node's name (what other things find it by, e.g. a schedule's spot); empty = the kind
## and the brush's tag.
@export var node_name := "":
	set(v):
		node_name = v
		emit_changed()
## The kind's settings that differ from its defaults (property -> value).
@export_storage var settings := {}

var _template: Node


## The node for this prop, set up from the settings (not in the tree).
func instantiate() -> Node:
	var node: Node = (load(SCRIPTS[kind]) as Script).new()
	for k in settings:
		node.set(k, settings[k])
	return node


## The settings onto `node` (an existing node of this kind), only those that changed.
func apply_to(node: Node) -> void:
	var defaults := _defaults(kind)
	for p in _script_props(kind):
		if not p.usage & PROPERTY_USAGE_STORAGE:
			continue
		var v = settings.get(p.name, defaults.get(p.name))
		if node.get(p.name) != v:
			node.set(p.name, v)


## Takes `prop`'s value from `node` into the settings (a node that changes itself in the
## editor, e.g. a sign writing its face texture).
func store_from(node: Node, prop: StringName) -> void:
	var v = node.get(prop)
	if settings.get(prop) == v:
		return
	if v == _defaults(kind).get(prop):
		settings.erase(prop)
	else:
		settings[prop] = v
	_drop_template()
	emit_changed()


func _get_property_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.append({name = NAMES[kind], type = TYPE_NIL, usage = PROPERTY_USAGE_GROUP})
	for p in _script_props(kind):
		if p.usage & PROPERTY_USAGE_CATEGORY:
			continue
		var q: Dictionary = p.duplicate()
		if q.usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
			out.append(q)
			continue
		if not q.usage & PROPERTY_USAGE_EDITOR:
			continue
		# Shown (and stored, through `settings`) here, not as properties of their own.
		q.usage = PROPERTY_USAGE_EDITOR
		out.append(q)
	# Properties the node adds itself (e.g. a sign's word symbol ticks).
	var t := _get_template()
	if t.has_method(&"_get_property_list"):
		for p: Dictionary in t._get_property_list():
			var q := p.duplicate()
			q.usage = PROPERTY_USAGE_EDITOR
			out.append(q)
	return out


func _get(property: StringName) -> Variant:
	if settings.has(property):
		return settings[property]
	if _is_prop(property):
		return _get_template().get(property)
	return null


func _set(property: StringName, value: Variant) -> bool:
	if not _is_prop(property):
		return false
	# Through the template, so a node's own derived properties (symbol ticks -> spelled_out)
	# work; then its stored properties come back into the settings.
	var t := _get_template()
	t.set(property, value)
	var defaults := _defaults(kind)
	var next := {}
	for p in _script_props(kind):
		if p.usage & PROPERTY_USAGE_STORAGE and not p.usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
			var v = t.get(p.name)
			if v != defaults.get(p.name):
				next[p.name] = v
	settings = next
	notify_property_list_changed()
	emit_changed()
	return true


func _property_can_revert(property: StringName) -> bool:
	return settings.has(property)


func _property_get_revert(property: StringName) -> Variant:
	return _defaults(kind).get(property)


func _is_prop(property: StringName) -> bool:
	for p in _script_props(kind):
		if p.name == property:
			return true
	var t := _get_template()
	if t.has_method(&"_get_property_list"):
		for p: Dictionary in t._get_property_list():
			if p.name == property:
				return true
	return false


func _get_template() -> Node:
	if _template == null:
		_template = instantiate()
	return _template


func _drop_template() -> void:
	if _template:
		_template.free()
		_template = null


func _notification(what: int) -> void:
	# (Inline: the script's own methods can't be called while it's being freed.)
	if what == NOTIFICATION_PREDELETE and is_instance_valid(_template):
		_template.free()


static var _props_cache := {}
static var _defaults_cache := {}


## The kind's script properties (groups included), as get_script_property_list gives them.
static func _script_props(k: Kind) -> Array:
	if not _props_cache.has(k):
		var list := []
		for p in (load(SCRIPTS[k]) as Script).get_script_property_list():
			# The script's own file entry and plain (unexported) variables aren't settings.
			if p.usage & PROPERTY_USAGE_CATEGORY or p.type == TYPE_CALLABLE:
				continue  # (tool buttons act on a node, not on the settings)
			if p.usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP) or p.usage & PROPERTY_USAGE_EDITOR \
					or p.usage & PROPERTY_USAGE_STORAGE:
				list.append(p)
		_props_cache[k] = list
	return _props_cache[k]


static func _defaults(k: Kind) -> Dictionary:
	if not _defaults_cache.has(k):
		var node: Node = (load(SCRIPTS[k]) as Script).new()
		var d := {}
		for p in _script_props(k):
			if p.usage & PROPERTY_USAGE_STORAGE:
				d[p.name] = node.get(p.name)
		node.free()
		_defaults_cache[k] = d
	return _defaults_cache[k]


## Script edits in the editor: forget the cached property lists.
static func clear_caches() -> void:
	_props_cache.clear()
	_defaults_cache.clear()
