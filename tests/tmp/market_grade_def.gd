@tool
extends RefCounted
## The market's first grading pass (built with the Grade screen's pieces):
##  shared "town1" grade (every town zone): Kakariko's ground colours as a soft-light
##  gradient map, cool shadows / warm lights in the baked light, a night-only blue, AO with
##  a warm bounce by day and blue at night;
##  the market's own on top: path lighter than the grass (they shared a grey), walls with
##  less texture contrast (they broke into blotches in value groups), the red roofs calmer.
## Used by apply_market_grade.gd (the open market) and the render tests.

const KAKARIKO := "res://screenshots/kakariko.png"


## [shared ZoneGrade, zone ZoneGrade (its .shared set to the shared one)].
static func make() -> Array:
	var town := ZoneGrade.new()
	# Kakariko's ground (below its skyline, its search UI cropped off): colour by value.
	var gm := GradeGradientMap.new()
	var img := Image.load_from_file(ProjectSettings.globalize_path(KAKARIKO))
	if img:
		img = img.get_region(Rect2i(70, img.get_height() / 2, 860, img.get_height() - img.get_height() / 2))
		var g := GradeGradientMap.from_image(img, 7)
		if g:
			gm.gradient = g
	gm.blend = GradeFilter.Blend.SOFT_LIGHT
	gm.opacity = 0.35
	# Baked light: cool shadows, warm lights (all keys); night bluer.
	var bal := GradeBalance.new()
	bal.on_light = true
	bal.shadows = Color(0.4, 0.45, 0.62)
	bal.highlights = Color(0.6, 0.54, 0.44)
	bal.strength = 0.35
	var night := GradeGradientMap.new()
	night.on_light = true
	night.keys = 1  # Night
	night.blend = GradeFilter.Blend.COLOUR
	night.opacity = 0.45
	night.gradient.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	night.gradient.colors = PackedColorArray([Color(0.03, 0.04, 0.14), Color(0.18, 0.22, 0.45), Color(0.72, 0.76, 0.95)])
	# Brighter mids (Kakariko's ground sits around L 64; ours ~45): textures lifted.
	var lift := GradeLevels.new()
	lift.gamma = 1.18
	town.stacks = {"zone": [lift, gm], "vertex/light": [bal, night]}
	# AO per key: Night, Dawn, Noon, Dusk.
	var ao := GradeAO.new()
	ao.linked = false
	ao.strength = PackedFloat32Array([1.2, 1.0, 0.9, 1.05])
	ao.curve = PackedFloat32Array([0.85, 1.0, 1.1, 1.0])
	ao.tint = PackedColorArray([Color(0.04, 0.06, 0.22), Color(0.2, 0.14, 0.18), Color(0.3, 0.2, 0.1), Color(0.22, 0.1, 0.2)])
	town.ao = ao
	# The market's own.
	var zone := ZoneGrade.new()
	zone.shared = town
	var path := GradeLevels.new()  # ground (the mud path): lighter mids
	path.gamma = 1.3
	var lawn := GradeLevels.new()  # grass: a touch darker than the path now
	lawn.gamma = 0.9
	var walls := GradeLevels.new()  # stucco / plaster: flatter (one value per wall)
	walls.in_black = 0.12
	walls.out_black = 0.22
	walls.gamma = 1.05
	var roofs := GradeHueSat.new()  # red roofs: calmer
	roofs.saturation = 0.55
	roofs.lightness = -0.05
	zone.stacks = {"group/ground": [path], "group/grass": [lawn], "group/concrete": [walls], load("res://textures/roof/red_shingles_1.res"): [roofs]}
	return [town, zone]
