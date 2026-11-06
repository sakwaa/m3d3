class_name Surface
extends RefCounted
## What a piece of ground is (OoT-style polygon types): a footstep sound plus gameplay flags,
## packed in one int. Level collision carries it per CollisionShape3D (meta META), so a
## hit looks it up from the collider and shape index (of_collision / of_ray).
##
## Level faces get it from their texture (painting a texture paints its surface), the
## overlay layer covering most of the face, or a Surface override painted in the editor.
##
## No-camera faces go in a body on NO_CAMERA_LAYER only: actors add it to their mask and
## stand on them, the camera arm (mask: layer 1) passes through.

enum Sound { DEFAULT, GRASS, DIRT, STONE, WOOD, SAND, WATER, METAL, SNOW, CARPET }
const SOUND_NAMES := ["Default", "Grass", "Dirt", "Stone", "Wood", "Sand", "Water", "Metal", "Snow", "Carpet"]
const SOUND_MASK := 0xFF

const SLIPPERY := 1 << 8
const DAMAGE := 1 << 9
## Touching it respawns the actor where it last stood safely (fall-out pits, deep water).
const VOID := 1 << 10
## The camera passes through (leafy canopies, thin railings, the player's side of a wall).
const NO_CAMERA := 1 << 11
## Stored for the climb state (ladders, vines); nothing reads it yet.
const CLIMBABLE := 1 << 12
## Stored for the hookshot (wooden targets); nothing reads it yet.
const HOOKSHOT := 1 << 13
## Bits 16 – 23: a CameraZone's camera_id (0 = none): standing here uses that camera.
const CAMERA_SHIFT := 16
const CAMERA_MASK := 0xFF << CAMERA_SHIFT
const FLAGS := [SLIPPERY, DAMAGE, VOID, NO_CAMERA, CLIMBABLE, HOOKSHOT]
const FLAG_NAMES := ["Slippery", "Damage", "Void-out", "No camera", "Climbable", "Hookshot"]
## Flags a hazard check looks at (unsafe to respawn on).
const HAZARDS := DAMAGE | VOID

const META := &"n64_surface"
## Physics layer 1: everything solid, camera included.
const SOLID_LAYER := 1
## Physics layer 2: solid for actors, not the camera.
const NO_CAMERA_LAYER := 1 << 1


static func sound(s: int) -> int:
	return s & SOUND_MASK


static func has(s: int, flag: int) -> bool:
	return s & flag != 0


static func camera_id(s: int) -> int:
	return (s & CAMERA_MASK) >> CAMERA_SHIFT


static func with_camera(s: int, id: int) -> int:
	return (s & ~CAMERA_MASK) | ((clampi(id, 0, 255)) << CAMERA_SHIFT)


static func sound_name(s: int) -> String:
	var i := sound(s)
	return SOUND_NAMES[i] if i < SOUND_NAMES.size() else "Sound %d" % i


## "Stone · Slippery, Damage".
static func describe(s: int) -> String:
	var parts := PackedStringArray()
	for i in FLAGS.size():
		if s & FLAGS[i]:
			parts.append(FLAG_NAMES[i])
	if camera_id(s) > 0:
		parts.append("Camera %d" % camera_id(s))
	return sound_name(s) + (" · " + ", ".join(parts) if not parts.is_empty() else "")


## The surface of a slide collision (CharacterBody3D.get_slide_collision).
static func of_collision(c: KinematicCollision3D, index := 0) -> int:
	return of_shape(c.get_collider(index), c.get_collider_shape_index(index))


## The surface of an intersect_ray result.
static func of_ray(hit: Dictionary) -> int:
	return of_shape(hit.get("collider"), hit.get("shape", 0)) if not hit.is_empty() else 0


static func of_shape(collider: Object, shape_index: int) -> int:
	if not collider is CollisionObject3D:
		return 0
	var body := collider as CollisionObject3D
	var owner_id := body.shape_find_owner(shape_index)
	var node := body.shape_owner_get_owner(owner_id) as Node if owner_id >= 0 else null
	return node.get_meta(META, 0) if node else 0


## Debug colour per sound (grass green, dirt brown, stone slate...); flags override it:
## damage red, void-out black, slippery cyan; a painted camera casts it orange; no-camera
## is fainter.
const SOUND_COLORS := [Color(0.78, 0.78, 0.78), Color(0.3, 0.78, 0.25), Color(0.6, 0.38, 0.18), Color(0.42, 0.47, 0.62),
	Color(0.92, 0.58, 0.22), Color(0.95, 0.86, 0.42), Color(0.2, 0.42, 0.95), Color(0.62, 0.6, 0.66),
	Color(0.97, 0.97, 1.0), Color(0.75, 0.3, 0.72)]


static func color(s: int) -> Color:
	var c: Color = SOUND_COLORS[sound(s)] if sound(s) < SOUND_COLORS.size() else Color.WHITE
	if s & SLIPPERY:
		c = Color(0.3, 0.95, 0.95)
	if s & DAMAGE:
		c = Color(1.0, 0.15, 0.1)
	if s & VOID:
		c = Color(0.08, 0.02, 0.12)
	if camera_id(s) > 0:
		c = c.lerp(Color(1.0, 0.6, 0.15), 0.5)  # orange cast: a painted camera
	c.a = 0.4 if s & NO_CAMERA else 0.8
	return c


## Collision bodies for baked level collision: one CollisionShape3D per surface (meta
## META), no-camera ones in a second body the camera arm doesn't see.
static func build_bodies(parts: Array, surfaces: PackedInt32Array) -> Array[StaticBody3D]:
	var solid: StaticBody3D = null
	var no_cam: StaticBody3D = null
	for i in parts.size():
		var shape: Shape3D = parts[i]
		if shape == null:
			continue
		var s := surfaces[i] if i < surfaces.size() else 0
		var cs := CollisionShape3D.new()
		cs.name = "Surface%d" % i
		cs.shape = shape
		cs.set_meta(META, s)
		if s & NO_CAMERA:
			if no_cam == null:
				no_cam = StaticBody3D.new()
				no_cam.name = "CollisionNoCamera"
				no_cam.collision_layer = NO_CAMERA_LAYER
			no_cam.add_child(cs)
		else:
			if solid == null:
				solid = StaticBody3D.new()
				solid.name = "Collision"
				solid.collision_layer = SOLID_LAYER
			solid.add_child(cs)
	var out: Array[StaticBody3D] = []
	for b in [solid, no_cam]:
		if b:
			out.append(b)
	return out
