class_name GrassField
extends Node3D
## Where a level's grass carpet is (made by the level tools' grass with the carpet, shipped
## as plain data): the carpet's top height on a grid, for whatever wades through it (the
## player's GrassWake). Level space is this node's parent's.

## Grid: the first cell's corner (x, z), cell size, cells across (x, z), and each cell's
## carpet top height (-1e9: no carpet there).
@export var origin := Vector2.ZERO
@export var step := 0.75
@export var size := Vector2i.ZERO
@export var tops := PackedFloat32Array()
## The carpet's texture and colour (the wading effect wears them).
@export var texture: Texture2D
@export var color := Color.WHITE
## Metres one repeat of the texture covers.
@export var tile := 1.5
## The carpet's top surface as built (level space triangles, 3 points each): its lumps.
@export var surface := PackedVector3Array()

const BIN := 2.0
var _bins := {}  # Vector2i (BIN-metre cell) -> PackedInt32Array (first point of each triangle)

static var _fields: Array[GrassField] = []


func _enter_tree() -> void:
	_fields.append(self)


func _exit_tree() -> void:
	_fields.erase(self)


## The carpet's top over `world` (a point at the feet), or -INF where there's none.
static func top_at(world: Vector3) -> float:
	for f in _fields:
		var t := f.top_here(world)
		if t > -INF:
			return t
	return -INF


## The field that has carpet at `world`, or null.
static func at(world: Vector3) -> GrassField:
	for f in _fields:
		if f.top_here(world) > -INF:
			return f
	return null


func top_here(world: Vector3) -> float:
	if tops.is_empty() or not is_inside_tree():
		return -INF
	var parent := get_parent() as Node3D
	var p := parent.global_transform.affine_inverse() * world if parent else world
	var ix := floori((p.x - origin.x) / step)
	var iz := floori((p.z - origin.y) / step)
	if ix < 0 or iz < 0 or ix >= size.x or iz >= size.y:
		return -INF
	var t := tops[iz * size.x + ix]
	if t < -1e8:
		return -INF
	return (parent.global_transform * Vector3(p.x, t, p.z)).y if parent else t


## The carpet's top as built over `world` (its lumps, not the cell's height; world space),
## or -INF where there's none.
func surface_at(world: Vector3) -> float:
	if surface.is_empty() or not is_inside_tree():
		return -INF
	if _bins.is_empty():
		for t in range(0, surface.size(), 3):
			var lo := Vector2(minf(surface[t].x, minf(surface[t + 1].x, surface[t + 2].x)), minf(surface[t].z, minf(surface[t + 1].z, surface[t + 2].z)))
			var hi := Vector2(maxf(surface[t].x, maxf(surface[t + 1].x, surface[t + 2].x)), maxf(surface[t].z, maxf(surface[t + 1].z, surface[t + 2].z)))
			for bx in range(floori(lo.x / BIN), floori(hi.x / BIN) + 1):
				for bz in range(floori(lo.y / BIN), floori(hi.y / BIN) + 1):
					var k := Vector2i(bx, bz)
					if not _bins.has(k):
						_bins[k] = PackedInt32Array()
					_bins[k].append(t)
	var parent := get_parent() as Node3D
	var p := parent.global_transform.affine_inverse() * world if parent else world
	var best := -INF
	for t: int in _bins.get(Vector2i(floori(p.x / BIN), floori(p.z / BIN)), PackedInt32Array()):
		var a := surface[t]
		var b := surface[t + 1]
		var c := surface[t + 2]
		var v0 := Vector2(b.x - a.x, b.z - a.z)
		var v1 := Vector2(c.x - a.x, c.z - a.z)
		var v2 := Vector2(p.x - a.x, p.z - a.z)
		var den := v0.x * v1.y - v1.x * v0.y
		if absf(den) < 1e-9:
			continue
		var u := (v2.x * v1.y - v1.x * v2.y) / den
		var v := (v0.x * v2.y - v2.x * v0.y) / den
		if u < -1e-4 or v < -1e-4 or u + v > 1.0001:
			continue
		best = maxf(best, a.y + u * (b.y - a.y) + v * (c.y - a.y))
	if best == -INF:
		return -INF
	return (parent.global_transform * Vector3(p.x, best, p.z)).y if parent else best
