shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_disabled;
// Level paint for Baked Vertex / Timed Dynamic lighting, cutout: double-sided, the base texture's alpha cuts holes (fences, grilles; LevelBrush
// `cutout`). Code: paint_body.gdshaderinc.
#define N64_HYBRID
#define N64_CUTOUT
#include "res://addons/n64_runtime/shaders/paint_body.gdshaderinc"
