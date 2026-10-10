shader_type canvas_item;
render_mode unshaded;

// 交互水面：离散波动方程（参考 Namey5/godot-interactive-water 与 Hugo Elias 的水面算法）
//
// 状态：R = 当前高度，G = 上一帧高度（都压到 0..1），用来算时间导数。
// 更新：拉普拉斯 -> 速度 -> 高度 = (2*当前 - 上一帧 + 速度) * 衰减
//
// ⚠️ Godot 里 ViewportTexture **不能引用自己的 Viewport**，所以不能自引用做双缓冲。
//    可行做法是**两个 SubViewport 互相引用**：A 读 B、B 读 A。Godot 按树序渲染，
//    于是 A 先渲染（读到 B 的上一帧），B 再渲染（读到 A 的这一帧）—— 每帧刚好推进一步。
uniform sampler2D ripple_tex;              // 另一个 viewport 的上一帧
// 与标题矩形同比例（614:378），避免涟漪被拉成椭圆
uniform vec2 sim_size = vec2(192.0, 118.0);

uniform float damp : hint_range(0.85, 1.0, 0.001) = 0.982;   // 衰减：太小会拖不出长水痕（看起来是点点）
uniform float speed : hint_range(0.05, 0.5, 0.01) = 0.32;   // 越大扩散越快；>0.5 会发散

uniform float mouse_radius : hint_range(0.005, 0.2, 0.002) = 0.035;  // 推水那块桨的大小：0.015 太小，像一个个点
uniform float border : hint_range(0.0, 20.0, 0.5) = 9.0;      // 吸收边界厚度（纹素）：靠边额外衰减，波撞墙不反弹
uniform float mouse_amp : hint_range(0.0, 3.0, 0.05) = 1.30;
uniform vec2 mouse = vec2(-1.0);           // 标题局部 UV；(-1,-1) = 不动
uniform vec2 drop = vec2(-1.0);            // 环境落点（可选）

float h_at(vec2 uv) {
	return texture(ripple_tex, uv).r * 2.0 - 1.0;
}

void inject(inout float h, vec2 uv, vec2 p, float radius, float amp) {
	if (p.x < 0.0) {
		return;
	}
	h -= amp * smoothstep(radius, 0.0, distance(uv, p));
}

void fragment() {
	vec2 texel = 1.0 / max(sim_size, vec2(1.0));
	vec2 state = texture(ripple_tex, UV).rg * 2.0 - 1.0;
	float l = h_at(UV + vec2(texel.x, 0.0));
	float r = h_at(UV - vec2(texel.x, 0.0));
	float u = h_at(UV + vec2(0.0, texel.y));
	float d = h_at(UV - vec2(0.0, texel.y));
	float lap = l + r + u + d - 4.0 * state.x;
	float h = (2.0 * state.x - state.y + lap * speed) * damp;

	inject(h, UV, mouse, mouse_radius, mouse_amp);
	inject(h, UV, drop, mouse_radius * 2.0, 0.9);

	// 吸收边界：靠边的地方额外衰减，涟漪撞墙就耗散掉，不会反弹回来
	if (border > 0.0) {
		float edge = min(min(UV.x, 1.0 - UV.x) * sim_size.x, min(UV.y, 1.0 - UV.y) * sim_size.y);
		h *= mix(0.90, 1.0, smoothstep(0.0, border, edge));
	}

	h = clamp(h, -1.0, 1.0);
	COLOR = vec4(h * 0.5 + 0.5, state.x * 0.5 + 0.5, 0.0, 1.0);
}
