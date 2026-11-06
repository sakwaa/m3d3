shader_type spatial;
render_mode unshaded;
// Level paint for baked lighting modes: unshaded, baked light from vertex colours.
// Code: paint_body.gdshaderinc.
#define N64_UNSHADED
#include "res://addons/n64_runtime/shaders/paint_body.gdshaderinc"
