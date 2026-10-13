shader_type canvas_item;
render_mode unshaded;
uniform float health_ratio : hint_range(0.0, 1.0) = 1.0;
void fragment() {
	vec4 source = texture(TEXTURE, UV);
	// AtlasTexture maps UV into the full 2172x724 source, not the cropped frame.
	vec2 p = UV * vec2(2172.0, 724.0);
	if (p.x >= 202.0 && p.x < 1957.0 && p.y >= 323.0 && p.y < 401.0) {
		float remaining = step((p.x - 202.0) / 1755.0, health_ratio);
		source = vec4(mix(vec3(0.96, 0.935, 0.87), vec3(0.0), remaining), 1.0);
	}
	COLOR = source;
}
