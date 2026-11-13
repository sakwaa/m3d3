@tool
class_name GradeVertex
extends RefCounted
## Compiles the zone's vertex layers into the paint shader's preview parameters: the baked
## light filters per time key and the painted colour filters as colour tables (strips of N
## slices of N x N; light: one block of rows per key), AO per key (GradeAO). Colour filters
## are per colour, so a table holds them exactly enough (N levels, trilinear).

const N := 13
const LIGHT := "vertex/light"
const PAINT := "vertex/paint"


## Light filters for key `k` (those whose key mask has it; `use_keys` false: all of them,
## for zones with one lighting and no time of day), in order.
static func light_chain(g: ZoneGrade, k: int, use_keys := true) -> Array:
	if g == null:
		return []
	return g.stack_chain(LIGHT).filter(func(f): return not use_keys or (f.keys & (1 << k)))


## Whether a lighting mode has one bake for all times (Always) rather than time keys.
static func single_light(mode: int) -> bool:
	return mode == LevelData.LightingMode.BAKED_VERTEX or mode == LevelData.LightingMode.BAKED_VERTEX_DYNAMIC


static func paint_chain(g: ZoneGrade) -> Array:
	if g == null:
		return []
	return g.stack_chain(PAINT)


static func signature(g: ZoneGrade, mode := LevelData.LightingMode.BAKED_TIMED_DYNAMIC) -> String:
	if g == null:
		return ""
	var s := "%d|" % mode
	for k in 4:
		s += GradeProcessor.signature(light_chain(g, k)) + "|"
	s += GradeProcessor.signature(paint_chain(g)) + "|"
	if g.effective_ao() and not g.hidden.has("vertex/ao"):
		s += g.effective_ao().signature()
	s += "|" + str(g.ao_fold())
	return s


## Shader parameters for `g` ({} = nothing to preview). Thread-safe (call prepare first).
## Zones with one lighting use the same tables for every key (all filters, no Keys masks);
## Baked Vertex zones get none: their light is in the vertex colour, graded when the mesh is
## built (cpu_shade).
static func compile(g: ZoneGrade, mode := LevelData.LightingMode.BAKED_TIMED_DYNAMIC) -> Dictionary:
	if g == null or mode == LevelData.LightingMode.BAKED_VERTEX:
		return {}
	var timed := LevelData.mode_is_timed(mode)
	var out := {grade_lut_n = float(N)}
	var any := false
	var chains := []
	var light_any := false
	for k in 4:
		var c := light_chain(g, k if timed else 0, timed)
		chains.append(c)
		light_any = light_any or not c.is_empty()
	out.grade_light_on = light_any
	if light_any:
		var img := Image.create(N * N, N * 4, false, Image.FORMAT_RGBA8)
		for k in 4:
			_fill(img, chains[k], k)
		out.grade_light_lut = img
		any = true
	var pc := paint_chain(g)
	out.grade_paint_on = not pc.is_empty()
	if not pc.is_empty():
		var img := Image.create(N * N, N, false, Image.FORMAT_RGBA8)
		_fill(img, pc, 0)
		out.grade_paint_lut = img
		any = true
	var ao := g.effective_ao()
	out.grade_ao_on = ao != null and not g.hidden.has("vertex/ao")
	if out.grade_ao_on:
		out.merge(ao.params(), true)
		any = true
	return out if any else {}


## Baked Vertex zones (light multiplied into the vertex colour): the corner's colour as the
## mesh carries it from painted colour (`paint`, data range), its baked light and AO:
## paint and light through their filters, Grade AO folded into the light (AO then 1).
## LevelBrush.build_painted_mesh calls it in the editor; GradeBake grades the build's data
## with the same chains, so they agree. Callable(paint, light, ao, colour scale) -> Color.
static func cpu_shade(g: ZoneGrade) -> Callable:
	if g == null:
		return Callable()
	prepare(g)
	var light := light_chain(g, 0, false)
	var paint := paint_chain(g)
	var ao := g.effective_ao() if not g.hidden.has("vertex/ao") else null
	if light.is_empty() and paint.is_empty() and ao == null:
		return Callable()
	var ao_p := ao.params() if ao else {}
	return func(p: Color, l: Color, a: float, scale: float) -> Color:
		var q := Color(p.r / scale, p.g / scale, p.b / scale)
		for f in paint:
			q = f.run(q, 0)
		for f in light:
			l = f.run(l, 0)
		var alpha := a
		if ao:
			var m := GradeBake._ao(a, 0, ao_p)
			l = Color(l.r * m.x, l.g * m.y, l.b * m.z)
			alpha = 1.0
		return Color(q.r * scale * l.r, q.g * scale * l.g, q.b * scale * l.b, alpha)


static func prepare(g: ZoneGrade) -> void:
	if g == null:
		return
	for f in g.stack_chain(LIGHT) + g.stack_chain(PAINT):
		f.prepare()


static func _fill(img: Image, chain: Array, row: int) -> void:
	for b in N:
		for gg in N:
			for r in N:
				var c := Color(r / float(N - 1), gg / float(N - 1), b / float(N - 1))
				for f in chain:
					c = f.run(c, 0)
				img.set_pixel(b * N + r, row * N + gg, c)
