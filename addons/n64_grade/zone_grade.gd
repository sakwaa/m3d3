@tool
class_name ZoneGrade
extends Resource
## A zone's Grade layers (LevelData.grade): a filter stack per layer, and which layers are
## hidden. Keys: "zone" (over everything), "group/<name>" (a texture group), a base
## Texture2D (its texture layer: also under its variants) or a TextureLook entry (a variant).
## A texture shows its own stack, then its variant's, its group's, the zone's.
##
## `shared`: a grade several zones use (a .tres in textures/_grade/shared): each of its
## layers' filters apply first, this zone's own on top (per-zone overrides). Hiding a layer
## here hides the shared filters there too. Its AO applies unless this zone has its own;
## variants and painted AO layers are this zone's only (they belong to its faces).

## Layer key -> Array of GradeFilter (bottom first).
@export var stacks := {}
## Layer key -> true: the layer's filters are off (the eye in the layer tree).
@export var hidden := {}
## AO per time key (GradeAO; null = the level's AO as baked). Vertex layers' filters are in
## `stacks` under "vertex/light" (per key: each filter's key mask) and "vertex/paint".
@export var ao: Resource
## Painted AO layers (GradeAOLayer), painted on vertices (LevelBrush.ao_paint[id]).
@export var ao_layers: Array[Resource] = []
## The shared grade under this one (null = none).
@export var shared: Resource


func shared_grade() -> ZoneGrade:
	return shared as ZoneGrade if shared != self else null


## The filters of `key` this zone shows: the shared grade's, then its own (enabled, not
## hidden here or there).
func stack_chain(key: Variant) -> Array:
	var out := []
	if hidden.has(key):
		return out
	var sh := shared_grade()
	if sh and not sh.hidden.has(key):
		for f in sh.stacks.get(key, []):
			if f and f.enabled and f.opacity > 0.0:
				out.append(f)
	for f in stacks.get(key, []):
		if f and f.enabled and f.opacity > 0.0:
			out.append(f)
	return out


## The shared grade's filters for `key` (shown as inherited in the layer tree).
func inherited(key: Variant) -> Array:
	var sh := shared_grade()
	return sh.stacks.get(key, []) if sh else []


## This zone's AO, else the shared grade's.
func effective_ao() -> GradeAO:
	if ao:
		return ao as GradeAO
	var sh := shared_grade()
	return sh.ao as GradeAO if sh else null


## The AO layers to fold into the time keys ([] when none / all off): LevelRoot's editor
## mesh and GradeBake use the same list, so the preview is the build.
func ao_fold() -> Array:
	var out := []
	if hidden.has("vertex/ao_layers"):
		return out
	for l in ao_layers:
		if l and l.enabled and not hidden.has("ao_layer/%d" % l.id):
			out.append(l.fold_entry())
	return out


## Baked Vertex zones: GradeVertex.cpu_shade (an invalid Callable when nothing to do).
func cpu_shade() -> Callable:
	return GradeVertex.cpu_shade(self)


func next_ao_id() -> int:
	var top := 0
	for l in ao_layers:
		if l:
			top = maxi(top, l.id)
	return top + 1


static func group_key(group: String) -> String:
	return "group/" + group


func filters(key: Variant) -> Array:
	return stacks.get(key, [])


## The filters a palette entry shows, in order (hidden layers and disabled filters left out).
func chain_for(entry: Texture2D, group: String) -> Array:
	var out := []
	var base := TextureLook.source_of(entry)
	var keys: Array = [base]
	if entry != base:
		keys.append(entry)
	keys.append(group_key(group))
	keys.append("zone")
	for k in keys:
		out.append_array(stack_chain(k))
	return out


## Everything the build's result depends on (BuildCache: a grade edit makes the zone's
## build out of date). Stable across loads (keys by path, not instance).
func signature() -> String:
	var parts := []
	for k in stacks:
		parts.append(_key_name(k) + "=" + GradeProcessor.signature(stacks[k].filter(func(f): return f != null)))
	parts.sort()
	var h := hidden.keys().map(_key_name)
	h.sort()
	var al := ao_layers.map(func(l): return l.signature() if l else "")
	var sh := shared_grade()
	return "|".join(parts) + "#" + ",".join(h) + "#" + ((ao as GradeAO).signature() if ao else "") + "#" + "".join(al) \
		+ ("#shared:" + sh.signature() if sh else "")


static func _key_name(k: Variant) -> String:
	if k is String:
		return k
	if k is TextureLook:
		var l := k as TextureLook
		return "look:%s:%s:%s" % [l.texture.resource_path if l.texture else "", l.palette, l.color]
	return (k as Resource).resource_path if k is Resource else str(k)


## `stacks` with `key`'s list replaced (for undo: a new dictionary, lists copied).
func with_stack(key: Variant, list: Array) -> Dictionary:
	var d := {}
	for k in stacks:
		d[k] = (stacks[k] as Array).duplicate()
	if list.is_empty():
		d.erase(key)
	else:
		d[key] = list
	return d
