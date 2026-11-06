shader_type spatial;
render_mode diffuse_lambert, specular_disabled;
// Level paint for Baked Vertex / Timed Dynamic lighting: the baked light (ambient, AO, static lights)
// glows through EMISSION; dynamic scene lights add on top through ALBEDO. Godot's own
// ambient is held back by AO as much as the bake shows (bake_strength), so it isn't
// counted twice. Code: paint_body.gdshaderinc.
#define N64_HYBRID
#include "res://addons/n64_runtime/shaders/paint_body.gdshaderinc"
