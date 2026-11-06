class_name LoadingScreen
extends CanvasLayer
## Full-screen fade + progress shown during zone travel.

var _root: Control
var _bar: ProgressBar


func _init() -> void:
	layer = 100
	_root = ColorRect.new()
	_root.color = Color.BLACK
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.custom_minimum_size = Vector2(240, 0)
	box.position = -box.custom_minimum_size * 0.5
	_root.add_child(box)
	var label := Label.new()
	label.text = "Loading…"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(label)
	_bar = ProgressBar.new()
	_bar.max_value = 1.0
	_bar.show_percentage = false
	box.add_child(_bar)

	_root.modulate.a = 0.0
	visible = false


func set_progress(value: float) -> void:
	_bar.value = value


func fade_in(duration: float) -> void:
	_bar.value = 0.0
	visible = true
	await create_tween().tween_property(_root, "modulate:a", 1.0, duration).finished


func fade_out(duration: float) -> void:
	await create_tween().tween_property(_root, "modulate:a", 0.0, duration).finished
	visible = false
