extends Node
## Props of a level (LEVEL) whose node name or tag contains NAME: their positions.


func _ready() -> void:
	var d: LevelData = ResourceLoader.load(OS.get_environment("LEVEL"), "", ResourceLoader.CACHE_MODE_IGNORE)
	var want := OS.get_environment("NAME").split(",")
	var i := 0
	for b in d.brushes:
		if b and b.is_prop():
			var nm := b.prop.node_name if b.prop.node_name != "" else "%s_%s" % [PropSpec.NAMES[b.prop.kind], b.tag]
			var kind_i := {}
			for w in want:
				if nm.to_lower().contains(w) or str(b.prop.settings).to_lower().contains(w):
					print("%s %s at %s settings %s" % [nm, PropSpec.Kind.keys()[b.prop.kind], b.transform.origin.snapped(Vector3.ONE * 0.1), str(b.prop.settings).left(120)])
					break
	get_tree().quit()
