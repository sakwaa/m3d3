extends Node
## Greens the market square (references/zones/market_square_green.json, plan:
## market_square_green_plan.jpg): ground faces painted mud become green ground cover
## except the dirt walkways; cobbles, the back alley's cement and the rest stay. Adds the
## level's grass (carpet along building feet, tufts over the green), then rebakes.
##   godot --headless --path . tests/zones/green_market.tscn   (editor closed)

const LEVEL := "res://zones/town1/town_1_market_square_level.res"
const PLAN := "res://references/zones/market_square_green.json"
const MUD := "res://textures/ground/mud.res"


func _ready() -> void:
	var plan: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(PLAN))
	var data: LevelData = load(LEVEL)
	var uid := ResourceLoader.get_resource_uid(LEVEL)
	var mud := -1
	for i in data.textures.size():
		if data.textures[i] and data.textures[i].resource_path == MUD:
			mud = i
	var green_tex: Texture2D = load(plan.green_texture)
	var green := data.textures.find(green_tex)
	if green < 0:
		data.textures.append(green_tex)
		green = data.textures.size() - 1
	var changed := 0
	for b in data.brushes:
		if b == null or b.is_prop() or b.house or b.is_fence() or b.is_rope() or b.is_passage():
			continue
		var faces := b.get_faces()
		var ft := b.face_textures.duplicate()
		var touched := false
		for f in faces.size():
			if b.get_face_texture(f) != mud:
				continue
			var ids: PackedInt32Array = faces[f]
			var c := Vector3.ZERO
			var p := []
			for i in ids:
				p.append(b.transform * b.vertices[i])
				c += p[-1]
			if ((p[1] - p[0]).cross(p[2] - p[0])).normalized().y < 0.7:
				continue
			c /= ids.size()
			if _dirt(plan, c.x, c.z):
				continue
			ft[f] = green
			touched = true
			changed += 1
		if touched:
			b.face_textures = ft
	# Grass: carpet along building feet, tufts over all the green (and the green courtyard).
	var G: Dictionary = plan.grass
	var s := GrassSettings.new()
	s.mat_band = float(G.mat_band)
	s.height = float(G.height)
	s.height_var = float(G.height_var)
	s.tufts = float(G.tufts)
	s.edge_tufts = float(G.edge_tufts)
	var grassy: Array[Texture2D] = [green_tex]
	for t in data.textures:
		# The courtyard's grass (a level look over a grass texture).
		if t and t.resource_path.contains("::") and t.get(&"texture") and String(t.get(&"texture").resource_path).begins_with("res://textures/grass/"):
			grassy.append(t)
	s.grass_textures = grassy
	data.grass = s
	var res := LevelBaker.bake(data, true)
	data.baked_mesh = res.mesh
	data.baked_chunks = res.chunks
	data.set_baked_collision(res)
	var err := ResourceSaver.save(data, LEVEL, ResourceSaver.FLAG_COMPRESS)
	if uid != ResourceUID.INVALID_ID:
		ResourceSaver.set_uid(LEVEL, uid)
	print("greened %d faces (green palette %d), grass textures %d, saved: %s, %d tris" % [changed, green, grassy.size(), error_string(err), res.stats.baked_tris])
	get_tree().quit()


func _dirt(plan: Dictionary, x: float, z: float) -> bool:
	for r: Array in plan.dirt_rects:
		if x >= r[0] and x <= r[2] and z >= r[1] and z <= r[3]:
			return true
	for c: Array in plan.dirt_circles:
		if Vector2(x - c[0], z - c[1]).length() <= c[2]:
			return true
	return false
