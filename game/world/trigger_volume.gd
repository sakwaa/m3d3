@tool
class_name TriggerVolume
extends Node3D
## A box (`size`, centred on the node) that does something when the player walks in while
## `conditions` hold: plays a cutscene, applies story effects (flags, items, weather…)
## and / or starts a dialogue. `once`: never again after the first time (remembered in
## the flag trigger/<zone>/<node name>, or `once_flag`). Leaving and re-entering fires again
## otherwise.

@export var size := Vector3(4, 3, 4):
	set(value):
		size = value
		_update_gizmo()
@export var conditions: Array[StoryCondition] = []
@export var once := true
## Flag remembering it fired ("" = trigger/<zone>/<node name>).
@export var once_flag := ""
@export_group("Then")
@export var cutscene: Cutscene
@export var effects: Array[StoryEffect] = []
@export var dialogue: Dialogue
@export var dialogue_entry := ""

var _inside := false
var _gizmo: MeshInstance3D


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		_update_gizmo.call_deferred()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var player := get_tree().get_first_node_in_group(&"player") as Node3D
	if player == null:
		return
	var inside := contains(player.global_position + Vector3.UP * 0.5)
	if inside and not _inside:
		_try_fire()
	_inside = inside


func contains(point: Vector3) -> bool:
	var p := global_transform.affine_inverse() * point
	return absf(p.x) <= size.x * 0.5 and absf(p.y) <= size.y * 0.5 and absf(p.z) <= size.z * 0.5


func flag() -> String:
	if once_flag != "":
		return once_flag
	var zone := owner.name if owner else &"zone"
	return "trigger/%s/%s" % [String(zone).to_snake_case(), String(name).to_snake_case()]


func _try_fire() -> void:
	if once and GameState.get_flag(flag(), false) == true:
		return
	if not StoryCondition.all(conditions, GameState):
		return
	if once:
		GameState.set_flag(flag(), true)
	for e in effects:
		if e:
			e.apply(GameState)
	if cutscene:
		Cutscenes.play(cutscene)
	if dialogue:
		Talk.start(dialogue, dialogue_entry)


## Editor-only box outline (cyan), never saved.
func _update_gizmo() -> void:
	if Engine.is_editor_hint() and is_inside_tree():
		_gizmo = BoxGizmo.draw(self, _gizmo, size, Color(0.3, 0.85, 1.0))
