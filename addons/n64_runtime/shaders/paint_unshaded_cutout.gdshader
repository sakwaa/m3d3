shader_type spatial;
render_mode unshaded, cull_disabled;
// Level paint for baked lighting modes, cutout: double-sided, the base texture's alpha cuts holes (fences, grilles; LevelBrush
// `cutout`). Code: paint_body.gdshaderinc.
#define N64_UNSHADED
#define N64_CUTOUT
#include "res://addons/n64_runtime/shaders/paint_body.gdshaderinc"
