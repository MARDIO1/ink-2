shader_type canvas_item;
render_mode unshaded;

uniform int mask_count = 0;
uniform sampler2D mask_0 : filter_nearest;
uniform vec2 mask_0_inv_x;
uniform vec2 mask_0_inv_y;
uniform vec2 mask_0_inv_origin;
uniform sampler2D mask_1 : filter_nearest;
uniform vec2 mask_1_inv_x;
uniform vec2 mask_1_inv_y;
uniform vec2 mask_1_inv_origin;
uniform sampler2D mask_2 : filter_nearest;
uniform vec2 mask_2_inv_x;
uniform vec2 mask_2_inv_y;
uniform vec2 mask_2_inv_origin;
uniform sampler2D mask_3 : filter_nearest;
uniform vec2 mask_3_inv_x;
uniform vec2 mask_3_inv_y;
uniform vec2 mask_3_inv_origin;
uniform sampler2D mask_4 : filter_nearest;
uniform vec2 mask_4_inv_x;
uniform vec2 mask_4_inv_y;
uniform vec2 mask_4_inv_origin;
uniform float dissolve = 0.0;
uniform float cell_pixels = 8.0;
uniform bool death_face = false;
uniform bool cut_cap = false;
varying vec2 world_position;
varying vec4 source_tint;
float cell_noise(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void vertex() {
	source_tint = COLOR;
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

bool covered(sampler2D mask_texture, vec2 inverse_x, vec2 inverse_y, vec2 inverse_origin) {
	vec2 pixel = inverse_x * world_position.x + inverse_y * world_position.y + inverse_origin;
	vec2 uv = pixel / vec2(textureSize(mask_texture, 0));
	return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))
		&& texture(mask_texture, uv).a > 0.5;
}

void fragment() {
	if ((mask_count > 0 && covered(mask_0, mask_0_inv_x, mask_0_inv_y, mask_0_inv_origin))
		|| (mask_count > 1 && covered(mask_1, mask_1_inv_x, mask_1_inv_y, mask_1_inv_origin))
		|| (mask_count > 2 && covered(mask_2, mask_2_inv_x, mask_2_inv_y, mask_2_inv_origin))
		|| (mask_count > 3 && covered(mask_3, mask_3_inv_x, mask_3_inv_y, mask_3_inv_origin))
		|| (mask_count > 4 && covered(mask_4, mask_4_inv_x, mask_4_inv_y, mask_4_inv_origin))) {
		discard;
	}
	vec4 ink = texture(TEXTURE, UV) * source_tint;
	if (cut_cap && UV.y < 0.24) {
		ink.a = 0.0;
	}
	if (death_face) {
		vec2 eye = vec2(abs(UV.x - 0.5) - 0.18, UV.y - 0.60);
		if (abs(eye.x) < 0.065 && abs(eye.y) < 0.06) {
			ink.a = 0.0;
			if (abs(abs(eye.x) - abs(eye.y)) < 0.014) {
				ink = vec4(0.0, 0.0, 0.0, source_tint.a);
			}
		}
	}
	vec2 cell = floor(UV * vec2(textureSize(TEXTURE, 0)) / cell_pixels);
	float threshold = mix(cell_noise(cell), 1.0 - UV.y, 0.55);
	if (dissolve > 0.0 && (dissolve >= 1.0 || threshold < dissolve)) {
		discard;
	}
	COLOR = ink;
}
