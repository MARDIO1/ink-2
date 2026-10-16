shader_type canvas_item;
render_mode unshaded;


void fragment() {
	vec4 source = texture(TEXTURE, UV) * COLOR;
	COLOR = vec4(vec3(1.0), source.a);
}
