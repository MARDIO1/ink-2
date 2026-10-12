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
varying vec2 world_position;

void vertex() {
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
		|| (mask_count > 3 && covered(mask_3, mask_3_inv_x, mask_3_inv_y, mask_3_inv_origin))) {
		discard;
	}
	COLOR = texture(TEXTURE, UV) * COLOR;
}
