@tool
class_name GradeAOLayer
extends Resource
## A painted AO layer (Grade > Vertex > AO layers): darkness painted on vertices
## (LevelBrush.ao_paint[id]), folded into each time key's light towards `tint` by
## darkness x `strength`, per key (or linked: slot 0 for all). A night-only ring at a
## lamp's reach, deeper alleys at dusk, a warm bounce under noon eaves...

@export var id := 1
@export var name := "AO layer"
@export var enabled := true
@export var linked := true
@export var strength := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
@export var tint := PackedColorArray([Color.BLACK, Color.BLACK, Color.BLACK, Color.BLACK])


func slot(key: int) -> int:
	return 0 if linked else clampi(key, 0, 3)


## [id, strength per key, tint per key] (LevelBrush.build_painted_mesh's ao_fold entry).
func fold_entry() -> Array:
	var st := PackedFloat32Array()
	var tn := PackedColorArray()
	for k in 4:
		st.append(strength[slot(k)])
		tn.append(tint[slot(k)])
	return [id, st, tn]


func signature() -> String:
	return var_to_str([id, enabled, linked, strength, tint])
