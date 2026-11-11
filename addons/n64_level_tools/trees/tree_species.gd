@tool
class_name TreeSpecies
extends Resource
## A tree species for the tree generator (TreeBuilder): Weber & Penn style parameters
## measured off real trees (height, how much of it is clear trunk, crown shape, branch
## angles ...), so one species makes endless different trees, one per seed. N64 style: a
## low-poly trunk and branches, leaf cards (cut-out clumps) shaded together as one crown.

enum Crown {
	CONICAL,  ## widest at the bottom, to a point (firs)
	DOME,  ## widest in the middle (sycamore, ash)
	SPREADING,  ## widest low down, broad and flat-topped (oak)
	CYLINDER,  ## the same all the way up (poplar)
	PROFILE,  ## crown_profile (measured off a photo by the tree importer)
}
enum Cards {
	CLUMPS,  ## two crossed cards per clump of leaves (broadleaves)
	SPRAYS,  ## flat cards along the branch (firs)
	HANGING,  ## long cards hanging straight down (weeping willow)
}

@export var display_name := "Tree"
@export var latin := ""
## Notes on what the numbers were measured from.
@export_multiline var reference := ""

@export_group("Size")
## Height (metres) and random spread (fraction).
@export var height := 12.0
@export_range(0.0, 0.5) var height_var := 0.12
@export_group("Trunk")
## Radius at the foot, and at the top as a fraction of that.
@export var trunk_radius := 0.35
@export_range(0.0, 1.0) var trunk_taper := 0.3
## Flare at the foot (roots): extra radius over the bottom metre.
@export var root_flare := 0.25
## How far up the trunk runs before it gives out into its limbs (fraction of the height;
## 1 = a leader to the top, like a fir).
@export_range(0.1, 1.0) var trunk_top := 0.7
## Lean (degrees) and wander per segment.
@export var lean := 3.0
@export var wander := 4.0
@export_range(3, 10) var sides := 6
@export_range(2, 10) var segments := 5
@export_group("Crown")
## Bare trunk below the crown (fraction of the height; limbs start here).
@export_range(0.0, 0.9) var clear := 0.3
## Which limbs are longest (sets the outline).
@export var crown := Crown.DOME
## PROFILE: the crown's half width at even heights from its base to its top (any units;
## only the shape counts).
@export var crown_profile := PackedFloat32Array()
## Limbs, then branches, ... (1-3 levels; more costs triangles fast).
@export var levels: Array[TreeLevel] = []
@export_group("Leaves")
@export var cards := Cards.CLUMPS
@export var leaf_texture: Texture2D
@export var bark_texture: Texture2D
## The whole tree as one cut-out (the far stand-in: the importer's photo, or rendered
## seeds for hand-made species), a few variants picked by a tree's seed; photo species
## also alternate mirrored.
@export var card_textures: Array[Texture2D] = []
## Each card's width / height (the textures themselves are squeezed to N64 sizes).
@export var card_aspects := PackedFloat32Array()
## Cards bigger than one N64 texture load are split into tiles (columns, rows), each its
## own texture: card_textures then holds each card's tiles in a row, left to right, top
## to bottom.
@export var card_tiles := Vector2i(1, 1)
## (Single card, before variants: used when card_textures is empty.)
@export var card_texture: Texture2D
@export var card_aspect := 1.0


## The card for a tree of `seed`: [tiles (Array of Texture2D, empty if none), aspect,
## mirrored, tile grid].
func card_for(seed: int) -> Array:
	if card_textures.is_empty():
		return [[card_texture] if card_texture else [], card_aspect, false, Vector2i.ONE]
	var per := maxi(card_tiles.x * card_tiles.y, 1)
	var n := card_textures.size() / per
	# Hashed (neighbouring seeds don't step through the variants in order), and any variant
	# may be mirrored: n x 2 looks.
	var h := hash(seed)
	var i := posmod(h, n)
	var aspect := card_aspects[i] if i < card_aspects.size() else 1.0
	return [card_textures.slice(i * per, (i + 1) * per), aspect, (h >> 8) & 1 == 1, card_tiles]
## Card size (metres; hanging cards: their width) and random spread.
@export var card_size := 2.4
@export_range(0.0, 0.5) var card_var := 0.2
## Clumps per last-level branch (along its outer part), and on the tips of the level
## before (fills the crown's inside).
@export var clumps := 3
@export var inner_clumps := 1
## Where along a branch the leaves begin (0 base .. 1 tip).
@export_range(0.0, 1.0) var leaf_start := 0.4
## Hanging cards: length (metres) and spread.
@export var hang_length := 3.5
@export_range(0.0, 0.6) var hang_var := 0.3
## Colours the textures are multiplied by (and the bark).
@export var leaf_color := Color(1, 1, 1)
@export var bark_color := Color(1, 1, 1)
@export_group("Shading")
## How dark the middle of the crown gets, and the shaded side.
@export_range(0.0, 1.0) var crown_ao := 0.45
@export_range(0.0, 1.0) var shadow_side := 0.4


## How long level-1 limbs are at `pos` (0 crown base .. 1 top), as a fraction of their
## full length: the crown's outline.
func crown_ratio(pos: float) -> float:
	match crown:
		Crown.CONICAL:
			return 1.0 - 0.85 * pos
		Crown.DOME:
			return 0.5 + 0.5 * sin(PI * clampf(pos, 0.0, 1.0))
		Crown.SPREADING:
			return 0.5 + 0.5 * sin(PI * (0.3 + 0.7 * pos))
		Crown.CYLINDER:
			return 0.9 - 0.2 * pos
		Crown.PROFILE:
			if crown_profile.size() < 2:
				return 1.0
			var f := clampf(pos, 0.0, 1.0) * (crown_profile.size() - 1)
			var i := mini(int(f), crown_profile.size() - 2)
			var top := 0.0
			for v in crown_profile:
				top = maxf(top, v)
			return maxf(0.08, lerpf(crown_profile[i], crown_profile[i + 1], f - i) / maxf(top, 0.0001))
	return 1.0
