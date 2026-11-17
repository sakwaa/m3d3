extends Node
## Zone travel with a warp (ZoneManager.travel(..., warp)): starts in the market, warps to
## the hillside with WARP (1 spin-zoom), saves frames during it.  OUT=dir godot --path . tests/render/warp_travel.tscn

var _t := 0.0
var _shots := [0.15, 0.6, 1.0, 1.5, 2.2]
var _started := false


func _ready() -> void:
	# The market becomes the current scene (travel replaces it); this node stays beside it.
	var market: Node = (load("res://zones/town1/town_1_market_square.tscn") as PackedScene).instantiate()
	get_tree().root.add_child.call_deferred(market)
	(func() -> void: get_tree().current_scene = market).call_deferred()
	GameState.set_time(14.0)


func _process(delta: float) -> void:
	_t += delta
	if Engine.get_process_frames() % 60 == 0:
		print("t ", snappedf(_t, 0.01), " started ", _started, " busy ", ZoneManager.busy, " scene ", get_tree().current_scene)
	if not _started and _t > 1.5:
		_started = true
		_t = 0.0
		ZoneManager.travel("res://zones/town1/town_1_hillside.tscn", &"", &"", int(OS.get_environment("WARP")) if OS.get_environment("WARP") != "" else 1)
		return
	if _started and not _shots.is_empty() and _t >= _shots[0]:
		var at: float = _shots.pop_front()
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/w_%.2f.png" % [OS.get_environment("OUT"), at])
		if _shots.is_empty():
			get_tree().quit()
