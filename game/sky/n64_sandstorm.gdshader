shader_type spatial;
// Sandstorm: OoT / MM's full-screen storm layer (Environment_DrawSandstorm; notes
// references/sky/oot_mm_env_fx.md): two big blurry noise textures scrolled across the
// screen at different rates and directions (texels about 15-30 pixels at 240 lines), joined
// by the combiner - colour (T1 - T0) x 0.5 + T0, alpha (T1 - T0) x envA + T0, then
// mix(ENV, PRIM, colour) with alpha x primA - over the 3D picture, under the HUD.
// Sandstorm (CPU) drives the alphas, scroll and colours each 20 Hz tick.
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D noise0 : filter_linear, repeat_enable;
uniform sampler2D noise1 : filter_linear, repeat_enable;
uniform vec4 prim : source_color = vec4(1.0, 0.78, 0.39, 0.5);
uniform vec4 env : source_color = vec4(0.78, 0.59, 0.2, 0.5);
// Layers' scroll (texture repeats).
uniform vec2 offset0 = vec2(0.0);
uniform vec2 offset1 = vec2(0.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void vertex() {
	POSITION = vec4(VERTEX.xy, 0.0, 1.0);
}

void fragment() {
	// Texels across the screen: layer 0 ~22 x 33, layer 1 ~11 x 16 (of 64 x 32 textures).
	vec2 s = SCREEN_UV;
	vec4 t0 = texture(noise0, s * vec2(21.9 / 64.0, 32.8 / 32.0) + offset0);
	vec4 t1 = texture(noise1, s * vec2(10.9 / 64.0, 16.4 / 32.0) + offset1);
	float c = (t1.r - t0.r) * 0.5 + t0.r;
	float a = (t1.a - t0.a) * env.a + t0.a;
	ALBEDO = mix(env.rgb, prim.rgb, clamp(c, 0.0, 1.0));
	// (alpha noise dither, G_AD_NOISE)
	ALPHA = clamp(a * prim.a * (0.85 + 0.3 * hash(FRAGCOORD.xy + TIME * 37.0)), 0.0, 1.0);
}
