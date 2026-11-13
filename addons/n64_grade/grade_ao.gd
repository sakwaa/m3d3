@tool
class_name GradeAO
extends Resource
## The zone's AO as Grade shapes it, per time key (LightingSchedule slot order): how strong,
## its curve (> 1: only the deepest corners; < 1: wider, softer), and the colour corners
## sink towards (black = plain AO; blue at night, warm bounce at noon...). Folded into each
## key's baked light. `linked`: one setting for every key (slot 0's).

@export var linked := true
@export var strength := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
@export var curve := PackedFloat32Array([1.0, 1.0, 1.0, 1.0])
@export var tint := PackedColorArray([Color.BLACK, Color.BLACK, Color.BLACK, Color.BLACK])


func slot(key: int) -> int:
	return 0 if linked else clampi(key, 0, 3)


## Shader parameters: grade_ao_strength, grade_ao_gamma, grade_ao_tint.
func params() -> Dictionary:
	var s := Vector4.ZERO
	var g := Vector4.ZERO
	var cols := []
	for k in 4:
		var i := slot(k)
		s[k] = strength[i]
		g[k] = curve[i]
		var c := tint[i]
		cols.append(Vector4(c.r, c.g, c.b, 0.0))
	return {
		grade_ao_strength = s, grade_ao_gamma = g,
		grade_ao_tint = Projection(cols[0], cols[1], cols[2], cols[3]),
	}


func signature() -> String:
	return var_to_str([linked, strength, curve, tint])
