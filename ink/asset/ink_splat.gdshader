shader_type canvas_item;
render_mode blend_mix, unshaded;

// 黑墨喷溅：全部在片元里解析求值 —— 没有粒子、没有贴图、没有实体。
// 墨点是一个个**轴对齐的小方块**（硬边，不做抗锯齿），没有主体块 —— 整簇就是飞出去的方块。
// 位置由 (出生时刻, 方向, 速度, 重力) 直接算出，不需要逐帧模拟，也不存轨迹。
// ⚠️ 数组长度 8 必须和 Ink/src/ink_spray.gd 的 MAX_SPLATS 一致。

uniform int splat_count = 0;
uniform float time = 0.0;
uniform vec2 rect_origin = vec2(0.0);
uniform vec2 rect_size = vec2(1.0);
// xy = 世界位置(px)，z = 出生时刻(秒)，w = 强度 0..1
uniform vec4 splat_head[8];
// xy = 喷出方向(单位向量)，z = 寿命(秒)，w = 种子 0..1
uniform vec4 splat_tail[8];
// rgb = 墨色，a = 不透明度
uniform vec4 splat_tint[8];

uniform float gravity = 280.0;
uniform float min_speed = 90.0;
uniform float max_speed = 260.0;
uniform float spread = 1.08;
// 墨滴方块的边长上限（px）。
uniform float drop_size = 4.0;
// 墨点数量：刚过阈值只溅几颗，满配才全撒出去。中间按伤害（strength）线性插值。
uniform float drop_min = 4.0;
uniform float drop_max = 22.0;
// 整簇的透明渐变强度：0 = 整簇一样淡，1 = 只有落点浓、飞到远处几乎看不见。
uniform float gradient = 0.65;
// 方块自转速度（弧度/秒）。每颗的正负和快慢都不一样。
uniform float spin_speed = 2.5;


float hash11(float x) {
	return fract(sin(x * 127.1) * 43758.5453);
}


// 方块：硬边，可以带角度。像素风的墨点就是一块块方的 —— 不抗锯齿、不圆角、不拉长。
// 判边界前先把点转进方块自己的坐标系（转 -angle），所以方块看上去转了 +angle。
float box_alpha(vec2 p, vec2 center, float half_side, float angle) {
	vec2 rel = p - center;
	float c = cos(angle);
	float s = sin(angle);
	vec2 local = vec2(rel.x * c + rel.y * s, rel.y * c - rel.x * s);
	vec2 d = abs(local) - vec2(half_side);
	return step(max(d.x, d.y), 0.0);
}


void fragment() {
	vec2 p = rect_origin + UV * rect_size;
	// 预乘累加：同一坨墨里叠得越多越不透明，不同颜色的墨也能正确叠在一起。
	vec3 acc = vec3(0.0);
	float acc_a = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= splat_count) {
			break;
		}
		vec4 head = splat_head[i];
		vec4 tail = splat_tail[i];
		vec4 tint = splat_tint[i];
		float life = tail.z;
		float age = time - head.z;
		if (age < 0.0 || age > life) {
			continue;
		}
		vec2 center = head.xy;
		// 强度可以 >1（伤害越大越强）；总上限由 GDScript 侧的 max_strength 封顶。
		float strength = head.w;
		float seed = tail.w;
		float speed_scale = mix(0.35, 1.0, min(strength, 1.6));
		// 逐像素先做一次粗剔除：一屏里同时有好几坨墨时，这比逐个方块算便宜得多。
		float reach = max_speed * speed_scale * life + 0.5 * gravity * life * life + drop_size;
		if (any(greaterThan(abs(p - center), vec2(reach)))) {
			continue;
		}
		float progress = age / max(life, 0.001);
		float fade = 1.0 - smoothstep(0.55, 1.0, progress);
		// 整簇的渐变尺度：飞得最远的那颗大致落在哪。
		float halo = max_speed * speed_scale * life * 0.7 + drop_size;
		float coverage = 0.0;
		// 没有主体块：整簇就是一颗颗飞出去的方块，落点附近靠飞得慢的那几颗自然堆密。
		// 墨滴：一颗颗小方块，位置是弹道的解析解。颗数随伤害 —— 轻伤只溅几颗。
		float base_angle = atan(tail.y, tail.x);
		int drops = int(clamp(mix(drop_min, drop_max, strength), drop_min, drop_max) + 0.5);
		for (int j = 0; j < 24; j++) {
			if (j >= drops) {
				break;
			}
			float h1 = hash11(seed * 91.7 + float(j) * 13.3);
			float h2 = hash11(seed * 47.3 + float(j) * 71.9);
			float h3 = hash11(seed * 19.1 + float(j) * 5.7);
			float dir_angle = base_angle + (h1 - 0.5) * spread;
			vec2 dir = vec2(cos(dir_angle), sin(dir_angle));
			// 近密远疏：多数墨点落在近处，少数飞得远，比均匀撒更像溅出来的。
			float speed = mix(min_speed, max_speed, pow(h2, 1.6)) * speed_scale;
			vec2 drop = center + dir * speed * age + vec2(0.0, 0.5 * gravity * age * age);
			float side = max(1.0, floor(mix(1.0, drop_size, h3) * (0.6 + 0.4 * strength)));
			// 出生角度就随机，再各自按不同的速度自转。
			float h4 = hash11(seed * 61.3 + float(j) * 23.1);
			float spin = h4 * TAU + age * spin_speed * (h4 - 0.5) * 2.0;
			// 越远的墨点越淡：整簇从落点往外是透明渐变。
			float drop_fade = 1.0 - gradient * clamp(length(drop - center) / halo, 0.0, 1.0);
			coverage += box_alpha(p, drop, side * 0.5, spin) * mix(0.5, 1.0, h2) * drop_fade;
		}
		float layer = clamp(coverage, 0.0, 1.0) * fade * tint.a;
		acc += tint.rgb * layer * (1.0 - acc_a);
		acc_a += layer * (1.0 - acc_a);
	}
	// 预乘转直通 alpha：blend_mix 要的是直通 alpha。
	COLOR = vec4(acc / max(acc_a, 1e-4), acc_a);
}
