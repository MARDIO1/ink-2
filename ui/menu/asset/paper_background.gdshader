shader_type canvas_item;
render_mode unshaded;

uniform vec4 paper_color : source_color = vec4(0.965, 0.953, 0.902, 1.0);
uniform vec4 line_color : source_color = vec4(0.61, 0.58, 0.50, 0.22);
uniform float line_count = 31.0;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	float row = fract(UV.y * line_count);
	float distance_to_line = min(row, 1.0 - row);
	float ruled_line = 1.0 - smoothstep(0.018, 0.032, distance_to_line);

	float fine_grain = (hash(floor(UV * vec2(920.0, 580.0))) - 0.5) * 0.014;
	float broad_grain = (hash(floor(UV * vec2(62.0, 38.0))) - 0.5) * 0.008;
	float edge_age = smoothstep(0.26, 0.78, distance(UV, vec2(0.5))) * 0.018;

	vec3 color = paper_color.rgb + fine_grain + broad_grain - edge_age;
	color = mix(color, line_color.rgb, ruled_line * line_color.a);
	COLOR = vec4(color, 1.0);
}
