@tool
class_name MaterialAnimator
extends Node
## Runs N64MaterialAnims on the games' 20 Hz clock: one tick every 1/20 s while the game runs
## (paused with it, like their frame counter), each anim applied with the tick count. Set
## `manual_step` >= 0 to drive them yourself instead (MM's actors did: a crystal switch's
## state, a fairy's colour). Previews in the editor when `preview` is on.

const HZ := 20.0

@export var anims: Array[N64MaterialAnim] = []
## >= 0: this tick for all anims instead of the clock.
@export var manual_step := -1
@export var preview := false

var _tick := 0.0
var _step := 0


func _process(delta: float) -> void:
	if Engine.is_editor_hint() and not preview:
		return
	if manual_step >= 0:
		_apply(manual_step)
		return
	_tick += delta * HZ
	if _tick >= 1.0:
		_step += int(_tick)
		_tick -= floorf(_tick)
		_apply(_step)


func _apply(step: int) -> void:
	for a in anims:
		if a:
			a.apply(step)
