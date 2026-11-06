class_name Room
extends Node3D
## A streamable part of a Zone (e.g. one chamber of a dungeon). Put its LevelRoot
## geometry anywhere under it, and enemies/items/props under a child named "Actors".
## At runtime the Actors subtree becomes a template: a fresh copy is created each time
## the room becomes active and freed when it stops being active, so actors reset like
## in Ocarina of Time. Use GameState flags for anything that must stay changed.

signal activated
signal deactivated

enum State {
	UNLOADED,  ## Removed from the scene tree.
	GEOMETRY,  ## In the tree without actors (visible through a doorway).
	ACTIVE,    ## Geometry plus a fresh copy of the actors.
}

const ACTORS_NODE := "Actors"

@export var room_id: StringName
## Fog while the player is in this room (fades in over its blend time); empty = the
## zone's fog. A FogSettings with Enabled off clears the fog here.
@export var fog_override: FogSettings

var state := State.GEOMETRY

var _actors_template: Node
var _actors: Node
var _home: Node
var _home_index := 0


func _enter_tree() -> void:
	# Detach actors before they enter the tree, so they never run until activated.
	if _actors_template == null and _home == null:
		var actors := get_node_or_null(ACTORS_NODE)
		if actors:
			remove_child(actors)
			_actors_template = actors


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE and _actors_template:
		_actors_template.free()


## Called by the Zone once, while the room is still in the tree.
func setup() -> void:
	if room_id == &"":
		room_id = StringName(name.to_snake_case())
	_home = get_parent()
	_home_index = get_index()


func set_state(new_state: State) -> void:
	if new_state == state:
		return
	var was_active := state == State.ACTIVE
	state = new_state

	if new_state != State.ACTIVE and _actors:
		_actors.queue_free()
		_actors = null
	if new_state == State.UNLOADED:
		if is_inside_tree():
			_home.remove_child(self)
	else:
		if not is_inside_tree():
			_home.add_child(self)
			_home.move_child(self, mini(_home_index, _home.get_child_count() - 1))
		if new_state == State.ACTIVE and _actors_template and _actors == null:
			_actors = _actors_template.duplicate()
			add_child(_actors)

	if new_state == State.ACTIVE and not was_active:
		activated.emit()
	elif was_active and new_state != State.ACTIVE:
		deactivated.emit()
