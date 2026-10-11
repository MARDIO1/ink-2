shader_type canvas_item;

// 标题：全局水面 + 鼠标涟漪（两层叠加）
//
// 层一：**全局水面** —— 多方向、多尺度、缓慢漂移的噪声波场（大涌/中波/细纹/碎纹 + 域扭曲），
//       所以水面平时就一直在动，不是只有被搅了才动。
// 层二：**涟漪模拟** —— 波动方程跑在两张互相引用的 SubViewport 里（见 ripple_sim.gdshader），
//       鼠标移动与环境落点注入，带来会传播、会互相干涉的尾迹。
//
// 两层的高度与梯度相加，再统一做折射 + 掠射反光。
//
// ⚠️ 必须 COLOR = vec4(...) 赋值：canvas_item 里 COLOR 进来时已等于 texture(TEXTURE, UV)，
//    而 title.png 是纯黑，写成 COLOR *= 就永远是黑。
uniform sampler2D ripple_tex;
// ⚠️ 要与标题矩形同比例（614:378 ≈ 1.62），否则圆形涟漪会被拉成椭圆
uniform vec2 sim_size = vec2(192.0, 118.0);

// ---- 层一：全局水面 ----
uniform float sea_scale : hint_range(0.5, 12.0, 0.1) = 3.0;   // 最大那层波的空间频率
uniform float sea_speed : hint_range(0.0, 1.0, 0.005) = 0.14; // 漂移速度（0.035 时几乎冻住）
uniform float sea_amp : hint_range(0.0, 2.0, 0.02) = 0.55;    // 全局水面占的比重
uniform float octave_falloff : hint_range(0.2, 0.9, 0.02) = 0.62; // 每层振幅衰减
uniform float detail : hint_range(0.0, 2.0, 0.01) = 0.90;     // 最细一层碎纹的强度（亮点细不细靠它）
uniform float warp : hint_range(0.0, 1.5, 0.02) = 0.40;       // 域扭曲（去值噪声的方格感）

// ---- 层二：涟漪模拟 ----
uniform float sim_amp : hint_range(0.0, 3.0, 0.02) = 1.0;     // 模拟高度占的比重
// 两层的梯度量级差一个量级（噪声水面约 0.5，模拟约 0.5/纹素），所以折射与坡度要各给各的
uniform float sea_strength : hint_range(0.0, 0.02, 0.0001) = 0.0012;  // 全局水面的折射位移
uniform float sim_strength : hint_range(0.0, 0.05, 0.0005) = 0.010;   // 涟漪模拟的折射位移
uniform float sea_normal : hint_range(0.0, 4.0, 0.01) = 0.45;         // 全局水面的坡度系数
uniform float sim_normal : hint_range(0.0, 40.0, 0.5) = 9.0;          // 涟漪模拟的坡度系数

// ---- 折射与反光 ----
// （折射与坡度见上面的 sea_* / sim_* 四个参数）
uniform vec2 light_dir = vec2(-0.55, -0.35);
uniform float light_z : hint_range(0.0, 1.0, 0.01) = 0.10;
uniform float align_min : hint_range(0.0, 0.99, 0.01) = 0.80;      // 朝向光要多准才反光
uniform float spec_strength : hint_range(0.0, 2.0, 0.01) = 0.12;   // 反光强度
uniform float diffuse : hint_range(0.0, 2.0, 0.02) = 0.0;          // 有漫反射会在黑墨上铺灰，看着脏
uniform vec3 light_color = vec3(0.95, 0.97, 1.0);

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

// 平滑值噪声（逐像素 hash 是噪点，不是起伏）
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
		mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

// 每层用不同旋转矩阵，避免所有波都对齐坐标轴
const mat2 R1 = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
const mat2 R2 = mat2(vec2(0.42, -0.91), vec2(0.91, 0.42));
const mat2 R3 = mat2(vec2(0.97, 0.24), vec2(-0.24, 0.97));

float sea(vec2 p) {
	// 域扭曲：用另一张低频噪声推坐标
	vec2 w = vec2(vnoise(p * 0.7 + vec2(3.1, 1.7)), vnoise(p * 0.7 + vec2(7.9, 5.3))) - 0.5;
	p += w * warp * 2.0;

	float h = 0.0;
	float a = 1.0;
	h += a * vnoise(R1 * p + vec2(TIME * sea_speed, TIME * sea_speed * 0.37));
	a *= octave_falloff;
	h += a * vnoise(R2 * p * 2.13 + vec2(-TIME * sea_speed * 1.7, TIME * sea_speed * 0.8));
	a *= octave_falloff;
	h += a * vnoise(R3 * p * 4.7 + vec2(TIME * sea_speed * 2.3, -TIME * sea_speed * 1.4));
	a *= octave_falloff;
	h += a * detail * vnoise(R2 * p * 10.3 + vec2(-TIME * sea_speed * 3.1, TIME * sea_speed * 2.2));
	return h;
}

// 梯度用有限差分（比给噪声写解析导数稳）
vec2 sea_grad(vec2 p, float e) {
	return vec2(sea(p + vec2(e, 0.0)) - sea(p - vec2(e, 0.0)),
		sea(p + vec2(0.0, e)) - sea(p - vec2(0.0, e))) / (2.0 * e);
}

float sim_h(vec2 uv) {
	return texture(ripple_tex, uv).r * 2.0 - 1.0;
}

void fragment() {
	vec2 texel = 1.0 / max(sim_size, vec2(1.0));

	// 层二：模拟高度与梯度
	float sh = sim_h(UV);
	vec2 sgrad = vec2(sim_h(UV + vec2(texel.x, 0.0)) - sim_h(UV - vec2(texel.x, 0.0)),
		sim_h(UV + vec2(0.0, texel.y)) - sim_h(UV - vec2(0.0, texel.y))) * 0.5;

	// 层一：全局水面高度与梯度
	vec2 sp = UV * sea_scale;
	float wh = sea(sp) * sea_amp;
	vec2 wgrad = sea_grad(sp, 0.5 / sea_scale) * sea_amp;

	float h = sh * sim_amp + wh;
	vec2 grad = sgrad * (sim_amp * sim_strength) + wgrad * sea_strength;

	float a = texture(TEXTURE, UV + grad).a;

	vec2 slope = sgrad * (sim_amp * sim_normal) + wgrad * sea_normal;
	vec3 n = normalize(vec3(-slope.x, -slope.y, 1.0));
	vec2 ldir = normalize(light_dir + vec2(1e-5));
	float align = dot(normalize(slope + vec2(1e-5)), -ldir) * 0.5 + 0.5;
	float refl = smoothstep(align_min, 1.0, align);
	refl *= refl;
	vec3 L = normalize(vec3(light_dir, light_z));
	float lam = dot(n, L) - L.z;

	float lit = lam * diffuse + refl * spec_strength;
	COLOR = vec4(light_color * lit, a);
}
