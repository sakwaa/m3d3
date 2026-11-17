#[compute]
#version 450
// N64VideoOut: the HUD drawn into the framebuffer, as on the N64 (the RDP drew it into the
// same 16-bit picture the VI then scanned out), so the dither, the VI's softening and its
// de-dither reach it too. `hud`: RenderScale's HUD viewport, drawn at the 3D render size
// (premultiplied by its transparent background, display values).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color;
layout(set = 0, binding = 1) uniform sampler2D hud;
layout(push_constant, std430) uniform Params {
	vec2 size;
	float pad0;
	float pad1;
	float pad2;
	float pad3;
	float pad4;
	float pad5;
} p;

vec3 to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

void main() {
	ivec2 xy = ivec2(gl_GlobalInvocationID.xy);
	if (xy.x >= int(p.size.x) || xy.y >= int(p.size.y)) {
		return;
	}
	vec4 h = textureLod(hud, (vec2(xy) + 0.5) / p.size, 0.0);
	if (h.a <= 0.0) {
		return;
	}
	vec4 c = imageLoad(color, xy);
	vec3 s = h.rgb + to_srgb(c.rgb) * (1.0 - h.a);
	imageStore(color, xy, vec4(to_linear(s), c.a));
}
