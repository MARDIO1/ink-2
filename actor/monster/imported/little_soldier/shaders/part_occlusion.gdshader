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
uniform sampler2D mask_5 : filter_nearest;
uniform vec2 mask_5_inv_x;
uniform vec2 mask_5_inv_y;
uniform vec2 mask_5_inv_origin;
uniform sampler2D mask_6 : filter_nearest;
uniform vec2 mask_6_inv_x;
uniform vec2 mask_6_inv_y;
uniform vec2 mask_6_inv_origin;
uniform sampler2D mask_7 : filter_nearest;
uniform vec2 mask_7_inv_x;
uniform vec2 mask_7_inv_y;
uniform vec2 mask_7_inv_origin;

varying vec2 world_position;


void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}


bool sample_mask(sampler2D mask_texture, vec2 inverse_x, vec2 inverse_y, vec2 inverse_origin, vec2 point) {
	vec2 local = inverse_x * point.x + inverse_y * point.y + inverse_origin;
	vec2 size = vec2(textureSize(mask_texture, 0));
	vec2 uv = (local + size * 0.5) / size;
	return all(greaterThanEqual(uv, vec2(0.0)))
		&& all(lessThanEqual(uv, vec2(1.0)))
		&& texture(mask_texture, uv).a > 0.5;
}


void fragment() {
	if ((mask_count > 0 && sample_mask(mask_0, mask_0_inv_x, mask_0_inv_y, mask_0_inv_origin, world_position))
			|| (mask_count > 1 && sample_mask(mask_1, mask_1_inv_x, mask_1_inv_y, mask_1_inv_origin, world_position))
			|| (mask_count > 2 && sample_mask(mask_2, mask_2_inv_x, mask_2_inv_y, mask_2_inv_origin, world_position))
			|| (mask_count > 3 && sample_mask(mask_3, mask_3_inv_x, mask_3_inv_y, mask_3_inv_origin, world_position))
			|| (mask_count > 4 && sample_mask(mask_4, mask_4_inv_x, mask_4_inv_y, mask_4_inv_origin, world_position))
			|| (mask_count > 5 && sample_mask(mask_5, mask_5_inv_x, mask_5_inv_y, mask_5_inv_origin, world_position))
			|| (mask_count > 6 && sample_mask(mask_6, mask_6_inv_x, mask_6_inv_y, mask_6_inv_origin, world_position))
			|| (mask_count > 7 && sample_mask(mask_7, mask_7_inv_x, mask_7_inv_y, mask_7_inv_origin, world_position))) {
		discard;
	}
	COLOR = texture(TEXTURE, UV) * COLOR;
}
