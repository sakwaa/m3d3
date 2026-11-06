@tool
class_name StoryCondition
extends Resource
## One test against the game state, shared by dialogue branches, choices and NPC
## schedules. A list of conditions passes when all of them pass (StoryCondition.all).

##  FLAG: a flag is set / equals / is at least / at most a number.
##  ITEM: the player carries at least `count` of an item.
##  EQUIPPED: the item is the equipped one.
##  DAY: today is one of `days`.
##  TIME: the clock is between `from_hour` and `to_hour` (wraps past midnight).
##  WEATHER: the current weather is `weather`.
enum Kind { FLAG, ITEM, EQUIPPED, DAY, TIME, WEATHER }
enum Test { IS_SET, EQUALS, AT_LEAST, AT_MOST }

@export var kind := Kind.FLAG:
	set(value):
		kind = value
		notify_property_list_changed()
## Passes when the test fails instead.
@export var negate := false
@export var flag := ""
@export var test := Test.IS_SET:
	set(value):
		test = value
		notify_property_list_changed()
@export var value := 1
@export var item := &""
@export_range(1, 9999) var count := 1
@export_flags("Day 1", "Day 2", "Day 3", "Day 4", "Day 5") var days := 31
@export_range(0.0, 24.0, 0.25) var from_hour := 6.0
@export_range(0.0, 24.0, 0.25) var to_hour := 18.0
@export var weather := &""


static func all(conditions: Array, gs: Node) -> bool:
	for c in conditions:
		if c and not c.check(gs):
			return false
	return true


func check(gs: Node) -> bool:
	return _test(gs) != negate


func _test(gs: Node) -> bool:
	match kind:
		Kind.FLAG:
			var v = gs.get_flag(flag)
			var n := int(v) if (v is int or v is float or v is bool) else 0
			match test:
				Test.IS_SET:
					return bool(v)
				Test.EQUALS:
					return n == value
				Test.AT_LEAST:
					return n >= value
				Test.AT_MOST:
					return n <= value
		Kind.ITEM:
			return gs.has_item(item, count)
		Kind.EQUIPPED:
			return gs.equipped == String(item)
		Kind.DAY:
			return days & (1 << gs.get_day_of_week()) != 0
		Kind.TIME:
			var t: float = gs.time_of_day
			return (t >= from_hour and t < to_hour) if from_hour <= to_hour else (t >= from_hour or t < to_hour)
		Kind.WEATHER:
			return gs.weather == weather
	return false


## Short readable form for editors ("baker/met is set", "not Day 3").
func describe() -> String:
	var s := ""
	match kind:
		Kind.FLAG:
			s = flag + [" is set", " = %d" % value, " ≥ %d" % value, " ≤ %d" % value][test]
		Kind.ITEM:
			s = "has %s%s" % [item, " ×%d" % count if count > 1 else ""]
		Kind.EQUIPPED:
			s = "%s equipped" % item
		Kind.DAY:
			var names := []
			for d in 5:
				if days & (1 << d):
					names.append("Day %d" % (d + 1))
			s = ", ".join(names) if not names.is_empty() else "no day"
		Kind.TIME:
			s = "%s – %s" % [_hour_text(from_hour), _hour_text(to_hour)]
		Kind.WEATHER:
			s = "weather is %s" % weather
	return ("not (%s)" % s) if negate else s


static func _hour_text(h: float) -> String:
	return "%02d:%02d" % [int(h) % 24, int(fmod(h, 1.0) * 60.0)]


func _validate_property(property: Dictionary) -> void:
	var used := {
		Kind.FLAG: ["flag", "test", "value"],
		Kind.ITEM: ["item", "count"],
		Kind.EQUIPPED: ["item"],
		Kind.DAY: ["days"],
		Kind.TIME: ["from_hour", "to_hour"],
		Kind.WEATHER: ["weather"],
	}
	var fields := ["flag", "test", "value", "item", "count", "days", "from_hour", "to_hour", "weather"]
	if property.name in fields and not property.name in used[kind]:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif property.name == "value" and test == Test.IS_SET:
		property.usage = PROPERTY_USAGE_NO_EDITOR
	elif Engine.is_editor_hint():
		StoryEffect.suggest(property)
