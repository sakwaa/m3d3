class_name FogSettings
extends Resource
## N64-style fog for a Zone (or a Room override): a flat colour blended in by distance,
## computed per vertex like the console. Shareable between zones and rooms.

enum Sampling { SOFT_GRID, PER_VERTEX, PER_PIXEL }
enum Center { PLAYER, CAMERA }
enum LightSampling { FOLLOW_FOG, PER_PIXEL }

enum FogCurve {
	N64_DEPTH,  ## Like the console's depth-buffer fog: thickens quickly past the start, long tail to the end (keep start well out).
	LINEAR,     ## Even ramp from start to end.
}

## Off = no fog here (a room override can clear the zone's fog).
@export var enabled := true
## Outdoor zones: take start / end / amount and the horizon colour from the current
## weather and time of day (WeatherTable). Curve and the zone's clip setting still apply.
@export var from_weather := false
@export var color := Color(0.45, 0.5, 0.55)
## Metres from the camera where fog begins / is complete.
@export_range(0.0, 500.0, 0.5, "suffix:m") var start := 10.0
@export_range(0.5, 1000.0, 0.5, "suffix:m") var end := 60.0
## How opaque the fog gets at `end` (1 = geometry fully fades into the colour).
@export_range(0.0, 1.0, 0.05) var amount := 1.0
@export var curve := FogCurve.N64_DEPTH
## Distances are measured from here, in all directions: Camera = around the camera (the
## default), Player = around the player (chest height).
@export var center := Center.CAMERA
## Where fog is worked out. Soft Grid: at the corners of an invisible world grid
## (`grid_size`), blended smoothly: the soft look of N64 vertex fog, but even on any
## geometry. Per Vertex: at the real vertices, like the console (only right on finely cut
## geometry; big baked floors smear distant fog over nearby ground). Per Pixel: exact,
## crisp.
@export var sampling := Sampling.SOFT_GRID
## Soft Grid cell size: bigger = softer, broader fog gradients.
@export_range(0.5, 16.0, 0.5, "suffix:m") var grid_size := 3.0
@export_group("Lights in the fog")
## How strongly nearby lights colour the fog around them (a warm haze by a torch).
@export_range(0.0, 2.0, 0.05) var light_tint := 0.3
## How strongly lights glow through the fog when you look towards them (halos).
@export_range(0.0, 2.0, 0.05) var light_halos := 0.6
## How the tint is worked out: Follow Fog = like the fog's Sampling (soft grid / vertices /
## pixels), Per Pixel = always exact. Halos are always per pixel (they follow the view).
@export var light_sampling := LightSampling.FOLLOW_FOG
## Lights considered at once (nearest / strongest to the camera).
@export_range(0, 4) var max_fog_lights := 4
@export_group("")
## Seconds to fade into this fog when it takes over (entering a room, weather change).
@export_range(0.0, 10.0, 0.1, "suffix:s") var blend_time := 1.0
