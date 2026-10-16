shader_type canvas_item;
render_mode unshaded;

// Only pure black and white. The original hole mask clips the rotating pattern.
uniform float phase = 0.0;
uniform float charge : hint_range(0.0, 1.0) = 0.0;

void fragment() {
	float mask = texture(TEXTURE, UV).a;
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float radius = length(p);
	float angle = atan(p.y, p.x);
	// Three curling arms wind into a dark center; phase rotates, not the torn paper.
	float wave = cos(angle * 3.0 - radius * (27.0 + charge * 6.0) - phase * 3.0);
	float stripe = step(mix(0.58, 0.42, charge), wave) * step(0.045 + charge * 0.035, radius);
	COLOR = vec4(vec3(stripe), step(0.5, mask));
}
