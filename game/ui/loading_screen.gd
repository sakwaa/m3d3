class_name LoadingScreen
extends CanvasLayer
## Zone travel's fade, Majora's Mask style: the picture fades to black in steps at the
## N64's ~20 fps (not a smooth glide), stays black only while the next zone finishes loading
## (a "Loading…" line only if that takes a while), then fades back in.

## Seconds per fade step (the N64 ran Majora's Mask at ~20 fps).
const STEP := 1.0 / 20.0
## Black for longer than this: show the "Loading…" line.
const SLOW_LOAD := 1.5

var _root: ColorRect
var _box: Control
var _bar: ProgressBar
var _black_since := 0


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
	box.visible = false
	_root.add_child(box)
	_box = box
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


## Load progress while black; the line shows once it's been black a while.
func set_progress(value: float) -> void:
	_bar.value = value
	_box.visible = Time.get_ticks_msec() - _black_since > SLOW_LOAD * 1000.0


## To black over `duration`.
func fade_in(duration: float) -> void:
	_bar.value = 0.0
	_box.visible = false
	visible = true
	await _fade(1.0, duration)
	_black_since = Time.get_ticks_msec()


## From black over `duration`.
func fade_out(duration: float) -> void:
	_box.visible = false
	await _fade(0.0, duration)
	visible = false


func _fade(to: float, duration: float) -> void:
	# By the clock, in whole steps: a hitching frame never stretches the fade.
	var from := _root.modulate.a
	var start := Time.get_ticks_msec()
	while true:
		await get_tree().process_frame
		var t := floorf((Time.get_ticks_msec() - start) * 0.001 / STEP) * STEP
		_root.modulate.a = lerpf(from, to, clampf(t / maxf(duration, 0.001), 0.0, 1.0))
		if t >= duration:
			break
	_root.modulate.a = to
