@tool
class_name RainCover
extends Node3D
## Where rain lands: a top-down map of the highest surface of a level's baked meshes, one
## texel per CELL metres. While in the tree it is the `n64_rain_cover` shader global (with
## `n64_rain_cover_area` / `n64_rain_cover_height` to read it), so the rain stops on roofs,
## eaves and awnings (none under them), splashes land on the first surface, and only
## surfaces open to the sky get wet. LevelRoot adds one for its bake (and the export swaps
## one in with the level); a zone has one at a time, the last to enter.
##
## The height is packed in two bytes (red high, green low) of an RGBA8 texture, so every
## renderer can read it: height = min + (r * 255 + g) / 65535 * range. Blue is 1 where
## something covers the cell, 0 for open sky (rain falls to the bottom of its box there).
##
## It also carries the level's rain light grid (LevelLighting.bake_rain_light): the lamps'
## light in the air with shadows, as `n64_rain_light` (+ `_area`, `_dims`, `_keys`), so
## rain shines only where a lamp reaches it (n64_rain_light.gdshaderinc).

const CELL := 0.5
const AREA_PARAM := &"n64_rain_cover_area"
const HEIGHT_PARAM := &"n64_rain_cover_height"
const MAP_PARAM := &"n64_rain_cover"
const LIGHT_PARAM := &"n64_rain_light"
const LIGHT_AREA_PARAM := &"n64_rain_light_area"
const LIGHT_DIMS_PARAM := &"n64_rain_light_dims"
const LIGHT_KEYS_PARAM := &"n64_rain_light_keys"

## The packed map (see above).
@export var cover: Texture2D
## Level-local XZ rectangle the map covers.
@export var area := Rect2()
## Height of a packed 0 and the span of the 16-bit range, metres.
@export var height_range := Vector2(0.0, 1.0)
## Rain light grid: XZ layers stacked by height (light / 2); null = none.
@export var light_grid: Texture2D
## Level-local position of the grid's first point, and metres between points.
@export var light_origin := Vector3.ZERO
@export var light_cell := 1.0
## Height layers in light_grid.
@export var light_layers := 1
## Lamp strength per lighting key (n64_light_blend slots).
@export var light_keys := Vector4.ONE

static var _active: RainCover


func _enter_tree() -> void:
	_active = self
	_publish()


func _exit_tree() -> void:
	if _active == self:
		_active = null
		RenderingServer.global_shader_parameter_set(AREA_PARAM, Vector4.ZERO)
		RenderingServer.global_shader_parameter_set(LIGHT_AREA_PARAM, Vector4.ZERO)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and _active == self:
		_publish()


func _ready() -> void:
	set_notify_transform(true)


func _publish() -> void:
	_publish_light()
	if cover == null or area.size.x <= 0.0 or not is_inside_tree():
		RenderingServer.global_shader_parameter_set(AREA_PARAM, Vector4.ZERO)
		return
	# World XZ of the map's corner (the level may be moved; it isn't rotated).
	var origin := global_transform * Vector3(area.position.x, 0.0, area.position.y)
	RenderingServer.global_shader_parameter_set(MAP_PARAM, cover)
	RenderingServer.global_shader_parameter_set(AREA_PARAM, Vector4(origin.x, origin.z, 1.0 / area.size.x, 1.0 / area.size.y))
	RenderingServer.global_shader_parameter_set(HEIGHT_PARAM, Vector2(height_range.x + global_position.y, height_range.y))


func _publish_light() -> void:
	if light_grid == null or not is_inside_tree():
		RenderingServer.global_shader_parameter_set(LIGHT_AREA_PARAM, Vector4.ZERO)
		return
	var o := global_transform * light_origin
	var nz := light_grid.get_height() / maxi(light_layers, 1)
	RenderingServer.global_shader_parameter_set(LIGHT_PARAM, light_grid)
	RenderingServer.global_shader_parameter_set(LIGHT_AREA_PARAM, Vector4(o.x, o.y, o.z, light_cell))
	RenderingServer.global_shader_parameter_set(LIGHT_DIMS_PARAM, Vector4(light_grid.get_width(), light_layers, nz, 0.0))
	RenderingServer.global_shader_parameter_set(LIGHT_KEYS_PARAM, light_keys)


## The highest surface of `meshes` (level-local) per CELL: {image (packed, as above), area,
## height_range}. Triangles are rasterised top-down at cell centres, both facings (an eave's
## underside covers as well as its top); walls cover nothing.
static func build(meshes: Array) -> Dictionary:
	var tris := PackedVector3Array()
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	for mesh: Mesh in meshes:
		if mesh == null:
			continue
		var faces := mesh.get_faces()
		for i in range(0, faces.size(), 3):
			var a := faces[i]
			var b := faces[i + 1]
			var c := faces[i + 2]
			var n := (b - a).cross(c - a)
			if n.length_squared() < 1e-10 or absf(n.normalized().y) < 0.05:
				continue
			tris.append_array([a, b, c])
			for p in [a, b, c]:
				lo = lo.min(p)
				hi = hi.max(p)
	if tris.is_empty():
		return {}
	var x0 := floorf(lo.x / CELL) * CELL
	var z0 := floorf(lo.z / CELL) * CELL
	var w := maxi(1, ceili((hi.x - x0) / CELL))
	var h := maxi(1, ceili((hi.z - z0) / CELL))
	var heights := PackedFloat32Array()
	heights.resize(w * h)
	heights.fill(-INF)
	for t in range(0, tris.size(), 3):
		var a := tris[t]
		var b := tris[t + 1]
		var c := tris[t + 2]
		var ab := Vector2(b.x - a.x, b.z - a.z)
		var ac := Vector2(c.x - a.x, c.z - a.z)
		var det := ab.x * ac.y - ab.y * ac.x
		if absf(det) < 1e-8:
			continue
		var i0 := clampi(floori((minf(a.x, minf(b.x, c.x)) - x0) / CELL), 0, w - 1)
		var i1 := clampi(floori((maxf(a.x, maxf(b.x, c.x)) - x0) / CELL), 0, w - 1)
		var j0 := clampi(floori((minf(a.z, minf(b.z, c.z)) - z0) / CELL), 0, h - 1)
		var j1 := clampi(floori((maxf(a.z, maxf(b.z, c.z)) - z0) / CELL), 0, h - 1)
		for j in range(j0, j1 + 1):
			var pz := z0 + (j + 0.5) * CELL - a.z
			for i in range(i0, i1 + 1):
				var px := x0 + (i + 0.5) * CELL - a.x
				# Barycentric (u towards b, v towards c) of the cell centre.
				var u := (px * ac.y - pz * ac.x) / det
				var v := (ab.x * pz - ab.y * px) / det
				if u < -0.001 or v < -0.001 or u + v > 1.001:
					continue
				var y := a.y + u * (b.y - a.y) + v * (c.y - a.y)
				var k := j * w + i
				if y > heights[k]:
					heights[k] = y
	var span := maxf(hi.y - lo.y, 0.01)
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for j in h:
		for i in w:
			var y := heights[j * w + i]
			if y == -INF:
				img.set_pixel(i, j, Color(0, 0, 0, 1))
				continue
			var q := clampi(roundi((y - lo.y) / span * 65535.0), 0, 65535)
			img.set_pixel(i, j, Color8(q >> 8, q & 0xFF, 255, 255))
	return {image = img, area = Rect2(x0, z0, w * CELL, h * CELL), height_range = Vector2(lo.y, span)}


## A RainCover for `built` (as from build()) and its level's rain `light` grid ({image,
## origin, cell, layers, keys}, or empty), or null.
static func from_build(built: Dictionary, light := {}) -> RainCover:
	if built.is_empty():
		return null
	var rc := RainCover.new()
	rc.name = "RainCover"
	rc.cover = ImageTexture.create_from_image(built.image)
	rc.area = built.area
	rc.height_range = built.height_range
	if not light.is_empty():
		rc.light_grid = ImageTexture.create_from_image(light.image)
		rc.light_origin = light.origin
		rc.light_cell = light.cell
		rc.light_layers = light.layers
		rc.light_keys = light.keys
	return rc
