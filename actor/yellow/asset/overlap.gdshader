shader_type canvas_item;
uniform sampler2D player_mask : filter_nearest;
uniform vec2 player_origin;
uniform float player_angle;
uniform vec2 mask_origin;
uniform vec2 mask_size = vec2(1.0);
uniform bool mask_enabled = true;
varying vec2 world_position;
varying vec4 tint;
void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
	tint = COLOR;
}
void fragment() {
	vec2 p = world_position - player_origin;
	float c = cos(player_angle);
	float s = sin(player_angle);
	vec2 uv = (vec2(c*p.x+s*p.y, -s*p.x+c*p.y) - mask_origin) / mask_size;
	COLOR = texture(TEXTURE, UV) * tint;
	if (mask_enabled && all(greaterThanEqual(uv, vec2(0.0))) && all(lessThan(uv, vec2(1.0)))) {
		COLOR.a *= mix(1.0, 0.3, texture(player_mask, uv).a);
	}
}
