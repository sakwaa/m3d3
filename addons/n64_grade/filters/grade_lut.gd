@tool
class_name GradeLut
extends GradeFilter
## A colour lookup table (strip / HaldCLUT image, or a .cube file).

@export_file("*.png", "*.cube", "*.jpg") var lut_path := ""

var _strip: Image
var _loaded := ""


func title() -> String:
	return "LUT" + ((": " + lut_path.get_file().get_basename()) if lut_path != "" else "")


func prepare() -> void:
	if lut_path != _loaded:
		_loaded = lut_path
		_strip = LutFile.load_strip(lut_path) if lut_path != "" else null


func apply(c: Color, _i: int) -> Color:
	return LutFile.apply(_strip, c) if _strip else c
