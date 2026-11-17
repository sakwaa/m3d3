@tool
class_name LevelDecal
extends Resource
## A decal placed on a level (LevelData.decals): one image (a poster, a crack, a stain, a
## pattern under a doorway) projected onto the surfaces under it and clipped to them, so it
## runs over corners. Drawn like the N64's: a few extra triangles just above the surface,
## lit by the surface (its painted colour, AO and baked light per time key), cut out by the
## texture's alpha. Placed / moved in the Paint screen; baked into the build (DecalBuilder).

## Level-local centre, on the surface.
@export var position := Vector3.ZERO:
	set(v):
		position = v
		emit_changed()
## Level-local direction it projects from (the surface's normal where it was placed).
@export var normal := Vector3.UP:
	set(v):
		normal = v
		emit_changed()
## The image's "up" before `rotation` (projected onto the decal's plane).
@export var up := Vector3.FORWARD:
	set(v):
		up = v
		emit_changed()
@export var texture: Texture2D:
	set(v):
		texture = v
		emit_changed()
## Width x height in metres.
@export var size := Vector2(1.0, 1.0):
	set(v):
		size = v
		emit_changed()
@export_range(-180.0, 180.0, 1.0, "suffix:°") var rotation := 0.0:
	set(v):
		rotation = v
		emit_changed()
## How far in front of / behind its plane it reaches (metres): deep enough for bumps and the
## corner it runs over, shallow enough not to land on the far side of a thin wall.
@export_range(0.02, 3.0, 0.01, "suffix:m") var depth := 0.3:
	set(v):
		depth = v
		emit_changed()
## Faces turned further than this from `normal` are left out (stretching on them).
@export_range(10.0, 89.0, 1.0, "suffix:°") var max_angle := 70.0:
	set(v):
		max_angle = v
		emit_changed()


## [origin, right, up, normal] (level-local) of the decal's frame.
func frame() -> Array:
	var n := normal.normalized()
	if n == Vector3.ZERO:
		n = Vector3.UP
	var u := up - n * up.dot(n)
	if u.length_squared() < 1e-6:
		u = (Vector3.FORWARD if absf(n.y) > 0.9 else Vector3.UP) - n * (Vector3.FORWARD if absf(n.y) > 0.9 else Vector3.UP).dot(n)
	u = u.normalized().rotated(n, deg_to_rad(rotation))
	var r := u.cross(n).normalized()
	return [position, r, u, n]


## Decal-space (x right, y up, z out of the surface) of a level-local point.
func to_local(p: Vector3) -> Vector3:
	var f := frame()
	var d: Vector3 = p - f[0]
	return Vector3(d.dot(f[1]), d.dot(f[2]), d.dot(f[3]))


## Whether a level-local point lies in the decal's box.
func covers(p: Vector3) -> bool:
	var l := to_local(p)
	return absf(l.x) <= size.x * 0.5 and absf(l.y) <= size.y * 0.5 and absf(l.z) <= depth


func title() -> String:
	return texture.resource_path.get_file().get_basename() if texture else "Decal (no texture)"
