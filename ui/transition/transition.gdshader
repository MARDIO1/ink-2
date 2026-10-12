shader_type canvas_item;
render_mode unshaded;

uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform int style = 0;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;

float rough(float x) {
	return sin(x * 53.0) * 0.009 + sin(x * 117.0 + 2.0) * 0.006 + sin(x * 237.0) * 0.003;
}

void fragment() {
	vec2 uv = UV;
	vec3 paper = vec3(0.94, 0.92, 0.85);
	float grain = fract(sin(dot(uv * 900.0, vec2(12.9898, 78.233))) * 43758.5453);
	paper += (grain - 0.5) * 0.018;
	float rule = 1.0 - smoothstep(0.0, 0.002, abs(fract(uv.y * 18.0) - 0.5));
	paper -= rule * 0.035;
	float alpha = 0.0;
	vec3 color = paper;
	if (style == 0) {
		// 翻页：斜向纸边推进，边缘卷出亮面与背面阴影。
		float edge = 1.25 - amount * 1.55 + uv.y * 0.18;
		float distance_to_edge = uv.x - edge;
		alpha = smoothstep(-0.012, 0.012, distance_to_edge);
		float fold = 1.0 - smoothstep(0.0, 0.11, abs(distance_to_edge));
		color += fold * 0.07;
		color -= (1.0 - smoothstep(0.0, 0.055, distance_to_edge)) * 0.17;
	} else if (style == 1) {
		vec2 p = (uv - vec2(0.5)) * vec2(1.78, 1.0);
		float angle = atan(p.y, p.x);
		float radius = length(p) + rough(angle * 0.3) * 2.0;
		alpha = 1.0 - smoothstep(amount * 1.2 - 0.03, amount * 1.2 + 0.03, radius);
		color = mix(vec3(0.055, 0.065, 0.09), vec3(0.12, 0.13, 0.16), grain * 0.3);
	} else if (style == 2) {
		// 两片撕纸向中央合拢；揭幕时裂口沿锯齿纸边张开。
		float gap = abs(uv.y - 0.5 - rough(uv.x));
		float edge = (1.0 - amount) * 0.6;
		alpha = smoothstep(edge - 0.012, edge + 0.012, gap);
		color -= (1.0 - smoothstep(0.0, 0.045, gap - edge)) * 0.13;
	} else {
		// 画稿：原画面去色成为纸上素描，再由横向笔迹铺满纸面。
		vec3 scene = texture(screen_texture, SCREEN_UV).rgb;
		vec2 step_uv = SCREEN_PIXEL_SIZE * 1.5;
		vec3 horizontal = texture(screen_texture, SCREEN_UV + vec2(step_uv.x, 0.0)).rgb - texture(screen_texture, SCREEN_UV - vec2(step_uv.x, 0.0)).rgb;
		vec3 vertical = texture(screen_texture, SCREEN_UV + vec2(0.0, step_uv.y)).rgb - texture(screen_texture, SCREEN_UV - vec2(0.0, step_uv.y)).rgb;
		float pencil = smoothstep(0.08, 0.65, length(horizontal) + length(vertical));
		vec3 sketch = paper - pencil * 0.58;
		float stroke = smoothstep(uv.x - 0.1, uv.x + 0.1, amount * 1.25);
		color = mix(sketch, paper, amount * amount);
		alpha = stroke * amount;
	}
	if (amount <= 0.001) { alpha = 0.0; }
	if (amount >= 0.999) { alpha = 1.0; }
	COLOR = vec4(color, alpha);
}
