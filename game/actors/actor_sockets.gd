class_name ActorSockets
## Items held by characters: a sword, shield, bottle, … attached to a bone of the
## character's skeleton (the prop bones prop_R / prop_L from the actor tools: the grip,
## +Y along a held blade). Works on character scenes in the editor's game run and in
## exports (both have a Skeleton3D under the character).
##
##   var sword := ActorSockets.attach(model, &"prop_R", SWORD_SCENE.instantiate())
##   ActorSockets.detach(model, &"prop_R")  # e.g. when sheathing


## Attaches `item` to `bone` (replacing what was held there) and returns it.
static func attach(character: Node, bone: StringName, item: Node3D) -> Node3D:
	var socket := _socket(character, bone, true)
	if socket == null:
		push_error("ActorSockets: %s has no skeleton bone '%s'." % [character.name, bone])
		item.queue_free()
		return null
	for c in socket.get_children():
		c.queue_free()
	socket.add_child(item)
	return item


static func detach(character: Node, bone: StringName) -> void:
	var socket := _socket(character, bone, false)
	if socket:
		for c in socket.get_children():
			c.queue_free()


## What `bone` holds, or null.
static func held(character: Node, bone: StringName) -> Node3D:
	var socket := _socket(character, bone, false)
	return socket.get_child(0) as Node3D if socket and socket.get_child_count() > 0 else null


static func _socket(character: Node, bone: StringName, create: bool) -> BoneAttachment3D:
	var skeleton := character as Skeleton3D
	if skeleton == null:
		var found := character.find_children("*", "Skeleton3D", true, false)
		skeleton = found[0] if not found.is_empty() else null
	if skeleton == null or skeleton.find_bone(bone) < 0:
		return null
	var socket_name := "Socket_%s" % bone
	var socket := skeleton.get_node_or_null(socket_name) as BoneAttachment3D
	if socket == null and create:
		socket = BoneAttachment3D.new()
		socket.name = socket_name
		socket.bone_name = bone
		skeleton.add_child(socket)
	return socket
