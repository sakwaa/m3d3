shader_type spatial;
render_mode unshaded, cull_disabled, blend_mix, depth_draw_never, skip_vertex_transform;
// The moss under creeping vines (WorldVines `moss`): wide bands along the vines lying on the
// surface, blended into it - vertex alpha fades them out at their edges and ends, the
// texture's darker texels thinner still, so overlapping bands build into soft patches.
// Grows in with the vines (CUSTOM0 like n64_vine: grows-from point, when it's reached).
#include "res://addons/n64_runtime/shaders/n64_sampling.gdshaderinc"

uniform sampler2D tex : source_color, filter_nearest_mipmap, repeat_enable;
uniform vec4 color : source_color = vec4(1.0);
// How opaque the moss is at a band's middle.
uniform float opacity = 0.8;
uniform float grow_soft = 0.04;
instance uniform float grow = 1.0;

varying N64_SHADE vec2 n64_fogv;
varying N64_SHADE vec3 n64_fog_tintv;
varying float fade;

void vertex() {
	float k = clamp((grow - CUSTOM0.w) / grow_soft, 0.0, 1.0);
	vec3 local = mix(CUSTOM0.xyz, VERTEX, k);
	vec3 world = (MODEL_MATRIX * vec4(local, 1.0)).xyz;
	n64_fogv = n64_fog_vertex(world);
	n64_fog_tintv = n64_fog_tint_vertex(world);
	fade = COLOR.a * k;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	N64_SNAP_VIEW;
}

void fragment() {
	vec4 c = n64_texture(tex, UV);
	float lum = dot(c.rgb, vec3(0.299, 0.587, 0.114));
	ALBEDO = c.rgb * color.rgb * n64_world_tint.rgb * n64_weather_tint.rgb;
	// (patchy edges: brighter moss reaches further out than the dark between it)
	float a = fade * opacity;
	ALPHA = clamp(a * (0.55 + lum * 1.3) - (1.0 - fade) * 0.25, 0.0, 1.0);
	FOG = n64_fog_out(n64_fogv, n64_fog_tintv, VERTEX, INV_VIEW_MATRIX);
	N64_FOG_GAMMA;
}
