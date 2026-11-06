@tool
class_name ActorModelData
extends Resource
## Authoring data of one character: its body plan, proportions, the working pose, joint
## styles (and later pieces, textures, animations). Editor-only; exports ship the built
## skeleton + mesh.

## Body plan id (BodyPlan.all()).
@export var plan: StringName = &"humanoid":
	set(value):
		plan = value
		emit_changed()
## Proportion parameter -> value (missing = the plan's default).
@export var proportions := {}:
	set(value):
		proportions = value
		emit_changed()
## Bone -> 1 for rigid (overlapping) joints; stitched (the joint ring bends with both
## bones, OoT style) otherwise.
@export var rigid_joints := {}:
	set(value):
		rigid_joints = value
		emit_changed()

## The character's pieces (empty = still the body plan's starter shapes).
@export var pieces: Array[ActorPiece] = []:
	set(value):
		pieces = value
		emit_changed()

@export_group("Blender")
## Character editor v2: the .blend that owns this character's geometry (edited in
## Blender, pulled in when it's saved). Empty = modelled with the built-in tools.
@export var blend_file := "":
	set(value):
		blend_file = value
		emit_changed()
## Modified time of the .blend when it was last pulled.
@export var blend_stamp := 0
## The skeleton follows the geometry from Blender: proportions are fitted to the pieces'
## lengths along their bones after each edit there.
@export var blend_fit := true

@export_group("Paint")
## Textures the pieces use (faces store indices into this).
@export var textures: Array[Texture2D] = []:
	set(value):
		textures = value
		emit_changed()
## Swap slots (eyes, mouth...): slot name -> frames (Array of Texture2D). Faces in a slot
## show its current frame; the game switches frames (ActorFaces.set_frame).
@export var swap_slots := {}:
	set(value):
		swap_slots = value
		emit_changed()
## Triangle budget shown in the panel (OoT: main characters ~600, small enemies ~300).
@export var tri_budget := 600

@export_group("Animation")
@export var animations: Array[ActorAnimation] = []:
	set(value):
		animations = value
		emit_changed()

@export_group("Pose")
## Working pose: bone -> rotation relative to its rest (Quaternion). Doesn't rebuild.
@export var pose := {}
## Root bone offset from its rest position.
@export var root_offset := Vector3.ZERO
## IK chain -> true: its end stays planted when the rest of the body moves.
@export var pins := {}
## Dragging an IK end: the hand / foot keeps its angle to the forearm / shin (follows the
## limb) instead of its orientation in the world. Pinned limbs always keep theirs.
@export var ik_end_follows := true

## Editor preview only: prop bone -> scene shown in that hand while posing / animating
## (never part of the character).
@export var preview_props := {}:
	set(value):
		preview_props = value
		emit_changed()

@export_group("Snapping")
## Position snap for IK targets / the root (metres).
@export var grid := 0.025
## Rotation snap (degrees).
@export var angle_step := 7.5
## Modelling snap (metres, in each piece's bone frame): smaller than levels, still coarse
## enough for the angular N64 look.
@export var model_grid := 0.0125
