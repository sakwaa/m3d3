class_name AimReticle
extends Control
## The aiming reticle at the screen's centre (where AimState's ray goes): a ring and a dot,
## fading in with the bow, red over an actor that can be hit, tightening as the string draws.

var actor: Actor
var _a := 0.0


func _init(p_actor: Actor = null) -> void:
	actor = p_actor
	name = "AimReticle"
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	var aim := actor.state_of(Actor.ACTION) as AimState if actor else null
	var want := 1.0 if aim and aim.raise >= 0.5 else 0.0
	_a = move_toward(_a, want, delta / 0.12)
	queue_redraw()


func _draw() -> void:
	if _a <= 0.0:
		return
	var aim := actor.state_of(Actor.ACTION) as AimState if actor else null
	var c := size * 0.5
	var scale := size.y / 540.0
	var on_actor := aim != null and aim.aim_actor != null and not aim.aim_actor.is_dead()
	var col := (Color(1.0, 0.35, 0.25) if on_actor else Color(1, 1, 1)) * Color(1, 1, 1, 0.9 * _a)
	var shadow := Color(0, 0, 0, 0.45 * _a)
	var draw_k := aim.draw if aim else 0.0
	var r := lerpf(14.0, 9.0, draw_k) * scale
	draw_arc(c + Vector2(1, 1) * scale, r, 0.0, TAU, 24, shadow, 2.0 * scale)
	draw_arc(c, r, 0.0, TAU, 24, col, 1.5 * scale)
	draw_circle(c + Vector2(1, 1) * scale, 2.0 * scale, shadow)
	draw_circle(c, 1.6 * scale, col)
