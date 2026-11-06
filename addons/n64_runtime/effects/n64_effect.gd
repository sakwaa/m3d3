@tool
class_name N64Effect
extends Resource
## A sprite effect (N64 style: a few flat-colour sprites, no particle system): a burst
## and / or a steady stream of sprites from a point, each living `lifetime` seconds while it
## flies, falls, grows / shrinks and fades. Played by EffectEmitter (placed, looping) or
## Effects.spawn() (one-shot). Save presets as .tres (res://game/effects/).

enum Blend { MIX, ADD }
## CAMERA: sprites face the camera (dust, sparks, fire). FLAT: they lie across the emit
## direction (splash rings on water, scorch marks).
enum Facing { CAMERA, FLAT }

@export var texture: Texture2D
## Flipbook: frames in a grid of `columns` (left to right, top to bottom; 1 = one image).
@export_range(1, 64) var frames := 1
@export_range(1, 16) var columns := 1
## Frames per second (0 = the flipbook plays once over each sprite's life).
@export_range(0.0, 60.0, 0.5) var fps := 0.0
@export var blend := Blend.MIX
@export var facing := Facing.CAMERA

@export_group("Emission")
## Sprites at the start.
@export_range(0, 64) var burst := 8
## Sprites per second after that (0 = burst only; > 0 = keeps going until stopped).
@export_range(0.0, 120.0, 0.5) var rate := 0.0
## Sprites alive at once (the oldest is recycled past it).
@export_range(1, 64) var max_sprites := 32
## Metres: sprites start anywhere within this radius of the emitter.
@export_range(0.0, 4.0, 0.01) var radius := 0.05

@export_group("Motion")
## Seconds each sprite lives (random between x and y).
@export var lifetime := Vector2(0.4, 0.6)
## Metres per second at the start (random between x and y), up the emit direction.
@export var speed := Vector2(1.0, 2.0)
## Degrees around the emit direction (0 = straight, 90 = a hemisphere, 180 = everywhere).
@export_range(0.0, 180.0, 1.0) var spread := 45.0
## m/s² pulling down (negative: sprites rise, like smoke and flames).
@export var gravity := 0.0
## Slows sprites (per second; 0 = none).
@export_range(0.0, 20.0, 0.1) var drag := 0.0
## Turns per second (camera-facing; random between x and y, either way).
@export var spin := Vector2(0.0, 0.0)

@export_group("Look")
## Metres across at the start (random between x and y).
@export var size := Vector2(0.2, 0.3)
## Size at the end of its life, times the start size.
@export_range(0.0, 8.0, 0.05) var size_end := 1.0
## Colour and alpha over each sprite's life (left = birth). Empty: white, fading out.
@export var color: Gradient

@export_group("")
## Effects started with this one, at the same place (a splash's droplets + its ring).
@export var with: Array[N64Effect] = []


## Colour (with alpha) at `t` (0..1) of a sprite's life.
func color_at(t: float) -> Color:
	if color:
		return color.sample(t)
	return Color(1, 1, 1, 1.0 - t)


func rows() -> int:
	return ceili(float(frames) / maxi(columns, 1))
