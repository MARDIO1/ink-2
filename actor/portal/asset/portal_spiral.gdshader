shader_type canvas_item;
render_mode unshaded;

// Only pure black and white. The original hole mask clips the rotating pattern.
uniform float phase = 0.0;

void fragment() {
	float mask = texture(TEXTURE, UV).a;
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float radius = length(p);
	float angle = atan(p.y, p.x);
	// Three curling arms wind into a dark center; phase rotates, not the torn paper.
	float wave = cos(angle * 3.0 - radius * 27.0 - phase * 3.0);
	float stripe = step(0.58, wave) * step(0.045, radius);
	COLOR = vec4(vec3(stripe), step(0.5, mask));
}
