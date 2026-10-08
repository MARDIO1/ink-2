shader_type canvas_item;
render_mode unshaded;

// The body and HUD read the same InkHealth ratio. 0 = empty, 1 = full.
uniform float fill : hint_range(0.0, 1.0, 0.001) = 1.0;
uniform vec2 liquid_down_local = vec2(0.0, 1.0);
uniform float projection_low = 0.0;
uniform float projection_high = 1.0;
uniform vec4 liquid_color : source_color = vec4(0.09, 0.11, 0.28, 1.0);

// Keep the exact breathing and restrained hand-drawn wobble used by Visual.
uniform float breath_period : hint_range(1.5, 5.0, 0.1) = 2.6;
uniform float breath_x : hint_range(0.0, 0.05, 0.001) = 0.016;
uniform float breath_y : hint_range(0.0, 0.05, 0.001) = 0.022;
uniform float wobble_fps : hint_range(1.0, 12.0, 0.5) = 5.0;
uniform float wobble_pixels : hint_range(0.0, 2.0, 0.05) = 0.55;

float hash(float value) {
	return fract(sin(value * 91.3458 + 17.234) * 47453.5453);
}

void vertex() {
	float phase = TIME * TAU / max(breath_period, 0.01);
	float breath = sin(phase) * 0.82 + sin(phase * 2.0 - 0.65) * 0.18;
	vec2 texture_size = vec2(1.0) / TEXTURE_PIXEL_SIZE;
	vec2 from_center = (UV - vec2(0.5)) * texture_size;
	VERTEX += from_center * vec2(breath * breath_x, breath * breath_y);

	float wobble_frame = floor(TIME * wobble_fps);
	vec2 whole_shift = vec2(
		hash(wobble_frame + 3.0) - 0.5,
		hash(wobble_frame + 19.0) - 0.5
	) * wobble_pixels * 0.45;
	VERTEX += whole_shift;
}

void fragment() {
	float wobble_frame = floor(TIME * wobble_fps);
	float side_wave = sin(UV.y * 13.0 + wobble_frame * 2.17);
	float top_wave = sin(UV.x * 11.0 - wobble_frame * 1.73);
	vec2 pixel_offset = vec2(side_wave, top_wave) * wobble_pixels;
	vec2 warped_uv = clamp(UV + pixel_offset * TEXTURE_PIXEL_SIZE, vec2(0.0), vec2(1.0));
	vec4 mask = texture(TEXTURE, warped_uv);

	vec2 texture_size = vec2(1.0) / TEXTURE_PIXEL_SIZE;
	vec2 down = normalize(liquid_down_local);
	float projected = dot(warped_uv * texture_size, down);
	float surface = mix(projection_high, projection_low, clamp(fill, 0.0, 1.0));
	float below_surface = step(surface, projected);
	COLOR = vec4(liquid_color.rgb, liquid_color.a * mask.a * below_surface) * COLOR;
}
