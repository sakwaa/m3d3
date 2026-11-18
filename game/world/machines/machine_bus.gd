class_name MachineBus
extends RefCounted
## How a Permivor's parts drive each other: named channels, each a value 0..1. A part that
## does something writes its channel (a capstan: how far it's turned; a wheel: how fast it's
## running); a part that reacts reads one (a gate: its channel is how open it is; a door: opens
## once its channel reaches its threshold). Wiring in the level tools = typing the same channel
## name on both props; nothing else knows about anything else.
## Values live for the scene (cleared when a zone loads: Zone calls reset()); saving them with
## the game's flags comes later.

static var _values := {}


static func set_value(channel: StringName, value: float) -> void:
	if channel != &"":
		_values[channel] = clampf(value, 0.0, 1.0)


static func value(channel: StringName, default := 0.0) -> float:
	return _values.get(channel, default)


static func has(channel: StringName) -> bool:
	return _values.has(channel)


static func reset() -> void:
	_values.clear()
