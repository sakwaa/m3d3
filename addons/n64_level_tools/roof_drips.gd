@tool
extends RefCounted
## Where rain runs off a level's houses, as RainDrip placements: along each eave (a gable
## roof's front and back, all four sides of a hip roof), falling to the ground, and for a
## shop's awning, a drip off its front edge, with the eave above it stopping on the awning.
## Used by the level tools' Props > Roof drips; the drips it makes are ordinary props after.


## [{name, transform (global), width, drop, house (its tag)}] for every house of `level`.
static func plan(level: LevelRoot) -> Array:
	var out := []
	for b: LevelBrush in level.data.brushes:
		if b == null or not b.is_house():
			continue
		var h := b.house
		var xf := level.global_transform * b.transform
		var hw := h.width * 0.5
		var hd := h.depth * 0.5
		var o := h.overhang
		var tan_p := tan(deg_to_rad(h.roof_pitch))
		var eave := h.wall_height() - o * tan_p
		var tag := String(b.tag)
		var sides := [["front", 0.0, hd + o, hw + o], ["back", PI, hd + o, hw + o]]
		if h.roof == HouseSpec.Roof.HIP:
			sides += [["right", PI * 0.5, hw + o, hd + o], ["left", -PI * 0.5, hw + o, hd + o]]
		for s in sides:
			var basis := Basis(Vector3.UP, s[1])
			var at := func(x: float, y: float, z: float) -> Transform3D:
				return xf * Transform3D(basis, basis * Vector3(x, y, z))
			var half: float = s[3]
			var awning := _awning(h) if s[0] == "front" else {}
			if awning.is_empty() or awning.depth <= o:
				out.append({name = "Drip_%s_%s" % [tag, s[0]], transform = at.call(0.0, eave, s[2]), width = half * 2.0, drop = eave, house = tag})
			else:
				# Over the awning the eave's water lands on it; either side, on the ground.
				var cw: float = minf(awning.half, half)
				var on_awning: float = awning.top - awning.fall * (o / awning.depth)
				out.append({name = "Drip_%s_front_over" % tag, transform = at.call(0.0, eave, s[2]), width = cw * 2.0,
					drop = maxf(eave - on_awning, 0.2), house = tag})
				for sx in [-1.0, 1.0]:
					var w := half - cw
					if w > 0.2:
						out.append({name = "Drip_%s_front_%s" % [tag, "right" if sx > 0.0 else "left"],
							transform = at.call(sx * (cw + w * 0.5), eave, s[2]), width = w, drop = eave, house = tag})
			if not awning.is_empty():
				out.append({name = "Drip_%s_awning" % tag, transform = at.call(0.0, awning.edge_y, hd + awning.depth + 0.01),
					width = awning.half * 2.0, drop = awning.edge_y, house = tag})
	return out


## A shop's awning as HouseBuilder._cover makes it: {half (width / 2), top (height at the
## wall), fall (drop to its front), depth, edge_y (its valance's foot)}, or {} without one.
static func _awning(h: HouseSpec) -> Dictionary:
	if not h.shopfront or not (h.cover == HouseSpec.Cover.AWNING or h.cover == HouseSpec.Cover.BOTH):
		return {}
	var hw := h.width * 0.5
	var half := clampf(h.shop_opening * 0.5, 0.3, hw - minf(h.wall_thickness, minf(hw, h.depth * 0.5) - 0.05) - 0.2)
	var y0 := h.foundation
	var top := minf(y0 + h.shop_height, y0 + h.storey_height - 0.2)
	var ya := top + 0.35
	var fall := h.awning_depth * 0.35
	return {half = half + 0.3, top = ya, fall = fall, depth = h.awning_depth, edge_y = ya - fall - 0.22}
