shader_type canvas_item;
render_mode unshaded;

// Match the bottle's restrained, stepped hand-drawn motion.
uniform float wobble_fps : hint_range(1.0, 12.0, 0.5) = 5.0;
uniform float wobble_pixels : hint_range(0.0, 2.0, 0.05) = 0.55;
uniform float rain_speed : hint_range(0.0, 60.0, 1.0) = 26.0;

float hash(float value) {
	return fract(sin(value * 91.3458 + 17.234) * 47453.5453);
}


void vertex() {
	float frame = floor(TIME * wobble_fps);
	VERTEX += vec2(hash(frame + 3.0) - 0.5, hash(frame + 19.0) - 0.5)
		* wobble_pixels * 0.45;
}


void fragment() {
	float frame = floor(TIME * wobble_fps);
	vec2 offset_pixels = vec2(
		sin(UV.y * 13.0 + frame * 2.17),
		sin(UV.x * 11.0 - frame * 1.73)
	) * wobble_pixels;
	vec2 uv = clamp(UV + offset_pixels * TEXTURE_PIXEL_SIZE, vec2(0.0), vec2(1.0));
	float ink = step(0.001, texture(TEXTURE, uv).r);

	// Narrow white streaks descend from the painted edge, like rain on paper.
	float column = floor(UV.x / TEXTURE_PIXEL_SIZE.x / 5.0);
	float active = step(0.82, hash(column * 13.71));
	float row = UV.y / TEXTURE_PIXEL_SIZE.y;
	float phase = mod(row - TIME * rain_speed - hash(column + 8.0) * 43.0, 43.0);
	float streak = 1.0 - step(8.0, phase);
	float above = step(0.001, texture(TEXTURE,
		clamp(uv - vec2(0.0, 4.0) * TEXTURE_PIXEL_SIZE, vec2(0.0), vec2(1.0))).r);
	float rain = active * streak * above * (1.0 - ink) * 0.55;
	COLOR = vec4(1.0, 1.0, 1.0, max(ink, rain));
}
