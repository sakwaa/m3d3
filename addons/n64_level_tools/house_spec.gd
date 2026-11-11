@tool
class_name HouseSpec
extends Resource
## A house brush's settings (LevelBrush.house), Kakariko style: plastered walls on a
## rectangular footprint, one or more storeys, timber trim around each storey's wall
## panels (painted with the face-border overlay), and a gable or hip roof with eaves. The
## level builds the brush's faces from these (HouseBuilder) and cuts its doors' and
## windows' openings into them again whenever it rebuilds. The brush's origin is the centre
## of the footprint on the ground; +Z is the front. Change a setting and the walls are
## rebuilt: painting on them is redone from these settings (trim) and otherwise lost.

enum Roof { GABLE, HIP }

## Footprint, outside of the walls: along X (the gable ridge runs this way) and along Z.
@export_range(2.0, 30.0, 0.25, "suffix:m") var width := 6.0:
	set(v):
		width = v
		emit_changed()
@export_range(2.0, 30.0, 0.25, "suffix:m") var depth := 5.0:
	set(v):
		depth = v
		emit_changed()
@export_range(1, 4) var storeys := 1:
	set(v):
		storeys = v
		emit_changed()
@export_range(2.0, 6.0, 0.05, "suffix:m") var storey_height := 3.0:
	set(v):
		storey_height = v
		emit_changed()
@export_range(0.1, 1.0, 0.01, "suffix:m") var wall_thickness := 0.3:
	set(v):
		wall_thickness = v
		emit_changed()
## Stone plinth the house stands on: its top above the ground (floor, door sills) and how
## far it sinks below (covers uneven ground). 0 height = walls straight off the ground.
@export_range(0.0, 1.5, 0.05, "suffix:m") var foundation := 0.3:
	set(v):
		foundation = v
		emit_changed()
@export_range(0.0, 2.0, 0.05, "suffix:m") var foundation_sink := 0.5:
	set(v):
		foundation_sink = v
		emit_changed()
## How far the plinth stands out from the walls.
@export_range(0.0, 0.5, 0.01, "suffix:m") var foundation_lip := 0.08:
	set(v):
		foundation_lip = v
		emit_changed()
@export var foundation_texture: Texture2D = preload("res://textures/rock/stone_3.res"):
	set(v):
		foundation_texture = v
		emit_changed()
@export var foundation_color := Color(0.8, 0.78, 0.74):
	set(v):
		foundation_color = v
		emit_changed()
@export_group("Roof")
@export var roof := Roof.GABLE:
	set(v):
		roof = v
		emit_changed()
@export_range(10.0, 60.0, 1.0, "suffix:°") var roof_pitch := 30.0:
	set(v):
		roof_pitch = v
		emit_changed()
## How far the eaves (and a gable's verges) reach past the walls.
@export_range(0.0, 2.0, 0.05, "suffix:m") var overhang := 0.6:
	set(v):
		overhang = v
		emit_changed()
@export_range(0.05, 0.5, 0.01, "suffix:m") var roof_thickness := 0.15:
	set(v):
		roof_thickness = v
		emit_changed()
@export_group("Surfaces")
@export var wall_texture: Texture2D = preload("res://textures/concrete/stucco_3.res"):
	set(v):
		wall_texture = v
		emit_changed()
@export var wall_color := Color(1.0, 0.97, 0.9):
	set(v):
		wall_color = v
		emit_changed()
## Inside faces of the walls (seen in doorways and shopfronts): the wall texture in this
## colour. The bake's AO and light already darken the inside; this is the walls' own paint.
@export var inside_color := Color(0.6, 0.55, 0.51):
	set(v):
		inside_color = v
		emit_changed()
## A skirt round the bottom of the outside walls in a second material, up from the plinth
## (a storehouse's dark tiles under white plaster); 0 = none. Trimmed like a wall band.
@export_range(0.0, 3.0, 0.05, "suffix:m") var wainscot_height := 0.0:
	set(v):
		wainscot_height = v
		emit_changed()
@export var wainscot_texture: Texture2D = preload("res://textures/rock/cobblestone_square.res"):
	set(v):
		wainscot_texture = v
		emit_changed()
@export var wainscot_color := Color(0.38, 0.38, 0.42):
	set(v):
		wainscot_color = v
		emit_changed()
@export var roof_texture: Texture2D = preload("res://textures/roof/shingles_5.res"):
	set(v):
		roof_texture = v
		emit_changed()
@export var roof_color := Color.WHITE:
	set(v):
		roof_color = v
		emit_changed()
## Under the eaves, the fascia and the verges.
@export var eave_texture: Texture2D = preload("res://textures/wood/wood_2.res"):
	set(v):
		eave_texture = v
		emit_changed()
@export var eave_color := Color(0.7, 0.62, 0.55):
	set(v):
		eave_color = v
		emit_changed()
@export_group("Trim")
## Timber around each storey's wall panels (and the gables): a face-border overlay in this
## texture (the level's first overlay layer that has it, added if there's room). None = no trim.
@export var trim_texture: Texture2D = preload("res://textures/wood/wood_1.res"):
	set(v):
		trim_texture = v
		emit_changed()
@export_range(0.0, 1.0, 0.01, "suffix:m") var trim_width := 0.15:
	set(v):
		trim_width = v
		emit_changed()

@export_group("Shop")
## A shopfront: the front's ground storey opens across `shop_opening` onto a shallow room
## (`shop_depth` in from the wall's front), dressed as `front_style`, with an awning and / or
## noren curtain over it.
@export var shopfront := false:
	set(v):
		shopfront = v
		emit_changed()
## SHOP: a counter across the opening and shelves inside. SHUTTERED: boarded up (closed for
## the day, or for good); only an awning stays. WORKSHOP: open onto a trade at work (`trade`'s
## tools inside, no counter), so it needs no goods.
enum Front { SHOP, SHUTTERED, WORKSHOP }
@export var front_style := Front.SHOP:
	set(v):
		front_style = v
		emit_changed()
## A workshop's trade: POTTER (wheel, drying racks of pots), WEAVER (loom, yarn), SMITH
## (forge under a hood, anvil, quench tub; sooty walls), DYER (dye vats, cloth drying overhead).
enum Trade { POTTER, WEAVER, SMITH, DYER }
@export var trade := Trade.POTTER:
	set(v):
		trade = v
		emit_changed()
enum Cover { NONE, AWNING, NOREN, BOTH }
@export var cover := Cover.BOTH:
	set(v):
		cover = v
		emit_changed()
@export_range(1.0, 20.0, 0.25, "suffix:m") var shop_opening := 3.0:
	set(v):
		shop_opening = v
		emit_changed()
@export_range(1.6, 4.0, 0.05, "suffix:m") var shop_height := 2.2:
	set(v):
		shop_height = v
		emit_changed()
## How far the shop goes in from the wall's front (at most the house's depth).
@export_range(0.5, 6.0, 0.05, "suffix:m") var shop_depth := 1.5:
	set(v):
		shop_depth = v
		emit_changed()
@export_range(0.0, 1.4, 0.05, "suffix:m") var counter_height := 0.85:
	set(v):
		counter_height = v
		emit_changed()
@export_range(0.3, 3.0, 0.05, "suffix:m") var awning_depth := 1.1:
	set(v):
		awning_depth = v
		emit_changed()
## Awning and noren cloth (the awning's stripes alternate with stripe_color).
@export var cloth_texture: Texture2D = preload("res://textures/fabric/parchment_1.res"):
	set(v):
		cloth_texture = v
		emit_changed()
@export var cloth_color := Color(0.16, 0.22, 0.45):
	set(v):
		cloth_color = v
		emit_changed()
@export var stripe_color := Color(0.92, 0.88, 0.78):
	set(v):
		stripe_color = v
		emit_changed()
@export var floor_texture: Texture2D = preload("res://textures/wood/wood_planks_8.res"):
	set(v):
		floor_texture = v
		emit_changed()
@export_group("Lights")
## Someone lives here: its windows light up in the evening (each at its own time).
@export var someone_home := true:
	set(v):
		someone_home = v
		emit_changed()
## When set: someone's home only while this GameState flag is (story / schedules decide).
@export var home_flag := "":
	set(v):
		home_flag = v
		emit_changed()


## Wall top (height of the eaves line on the walls), from the ground.
func wall_height() -> float:
	return foundation + storeys * storey_height


## Settings that don't change the faces (window lights).
const NOT_GEOMETRY := [&"someone_home", &"home_flag"]


## Everything the faces are built from, for LevelRoot's "unchanged, keep it" check.
func key() -> int:
	var parts := [HouseBuilder.VERSION]
	for prop in get_property_list():
		if prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and not prop.name in NOT_GEOMETRY:
			var v = get(prop.name)
			parts.append(v.resource_path if v is Resource else v)
	return hash(parts)
