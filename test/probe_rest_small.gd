extends SceneTree
## 小尺度判定台：**重力扫一遍** —— 找"静置后还留得住体积"的那个点。
##
## 为什么可以缩到 12x48：决定"沸腾不沸腾"的是**每步走几格**
##   cells/step = dt * sqrt(2 * gravity_px * num_y)
## 12x48 -> dt*sqrt(2*g*48)，真实容器（30x30, cell_px=2）-> dt*sqrt(2*g*30)。
## 这个判定台**偏悲观 26%**（格子更多 -> 每步走得更远），所以在这里合格的点
## 到真实容器上只会更好。GDScript 参照实现在这个尺度上一步几毫秒 -> 一次扫 7 个变体几秒钟。
##
## 已经钉死的（都别再试）：
##   · 调大 stiffness -> 体积托住了，但液面变成**没有阻尼的弹簧**
##     （覆盖在 0.63~0.99 之间摆，人看到的正是"压缩 -> 释放 -> 压缩"）。
##   · 阻尼（flip_ratio 或每步 vel*=k）能杀掉弹簧，但 damping 大了**晃动也没了**。
##   · 子步能稳，但 4 子步 = 4 倍算力。
##   · rest_density 换"体相均值"**不解决**体积（0.619 vs 0.631）—— 交接文档那个假设是否证的。
## 真实容器上已经量到的：重力 600 -> 覆盖 62%、速度 3.2；重力 300 -> 覆盖 71%、速度 2.2。
## 这一轮：把重力继续往下扫，看覆盖能不能爬到 0.87（= 初始值）。
##
## ⚠️ 参数从 bottled_ink.gd 自己的导出默认值读，不写魔法数。

const FluidPBF := preload("res://addons/pixel_destruction/fluid/fluid_pbf.gd")
const BottledInk := preload("res://actor/player/src/bottled_ink.gd")

const NX := 12
const NY := 48
const WARM := 320
const FRAMES := 480
const SAMPLE := 10

## 真实容器上已经量到（cell_px=2，stiffness 1.0，max_fill 1.0）：
##   重力 600 -> 静置 62%；重力 300 -> 静置 78%（初始都是 96%，比值 0.81）。
## 还差 12 个点。要补的是**比值**，而比值由"初始晶格密度 vs 平衡密度"决定：
##   晶格按 dx = 2r 排（最稀），平衡密度比它高 ~1.24 倍 -> 流体必须压缩 20% 才到平衡。
##   **把 radius 调小 = 晶格变密**，晶格密度就靠近平衡密度，比值 -> 1.0。
##   然后 max_fill 取 0.94 左右，初始覆盖就是 90%，而且不再压缩。
## gscale 是相对 bottled_ink.gd 的 gravity_px 的倍数（1.0 = 游戏现值）。
const VARIANTS := [
	{"tag": "r.019", "radius": 0.0190, "gscale": 1.0, "fill": 1.0},
	{"tag": "r.018", "radius": 0.0180, "gscale": 1.0, "fill": 1.0},
	{"tag": "r.017", "radius": 0.0170, "gscale": 1.0, "fill": 1.0},
	{"tag": "r.016", "radius": 0.0160, "gscale": 1.0, "fill": 1.0},
	{"tag": "r.015", "radius": 0.0150, "gscale": 1.0, "fill": 1.0},
]

var _cfg = null


func _initialize() -> void:
	_cfg = BottledInk.new()      # 只为了读导出默认值；不进场景树，_ready 不会跑
	print("bottled_ink.gd 默认：gravity_px=%.0f  stiffness=%.2f  over=%.2f  max_fill=%.2f" % [
		_cfg.gravity_px, _cfg.stiffness, _cfg.over_relaxation, _cfg.max_fill])
	print("目标：静置后 ≈ 初始（max_fill 就是初始覆盖）")
	print("")
	for v in VARIANTS:
		_one(v)
	_cfg.free()
	quit(0)


func _one(v: Dictionary) -> void:
	var f = FluidPBF.new()
	f.resize_grid(NX, NY)
	f.radius = float(v["radius"])
	f.stiffness = _cfg.stiffness
	f.over_relaxation = _cfg.over_relaxation
	f.dt = 1.0 / float(Engine.physics_ticks_per_second)
	var full: int = f.init_particles(-1)
	f.max_particles = int(float(full) * float(v["fill"]))
	f.init_particles(f.max_particles)
	f.set_fill_ratio(1.0)
	f.snap_fill(0.0, 1.0)
	f._native_checked = true
	f._native = null                  # 关掉原生：判定台要能读 rest_density / _density
	f._particles_to_grid()
	f._density_update()
	f._raster_ink()
	var cov0 := _coverage(f)
	var gp: float = _cfg.gravity_px * float(v["gscale"])
	var gm: float = gp * f.spacing
	var cmin := 9.9
	var cmax := -9.9
	var csum := 0.0
	var spd := 0.0
	var cnt := 0
	for fr in FRAMES:
		f.step(0.0, gm)
		if fr >= WARM and (fr % SAMPLE) == 0:
			var c := _coverage(f)
			cmin = minf(cmin, c)
			cmax = maxf(cmax, c)
			csum += c
			spd += _speed(f)
			cnt += 1
	var n := float(maxi(cnt, 1))
	var mean := csum / n
	print("%-8s g=%-4.0f r=%.3f  初始 %.3f  静置 %.3f~%.3f 均 %.3f  **比值 %.3f**  速度 %.2f  粒子 %d" % [
		v["tag"], gp, f.radius, cov0, cmin, cmax, mean, mean / maxf(cov0, 1e-6),
		spd / n, f.particle_count()])


func _coverage(f) -> float:
	return float(_nz(f.ink)) / float(maxi(_nz(f.solid_mask), 1))


func _speed(f) -> float:
	var n: int = f.particle_count()
	var sp := 0.0
	for i in n:
		sp += sqrt(f.vel[i * 2] * f.vel[i * 2] + f.vel[i * 2 + 1] * f.vel[i * 2 + 1])
	return sp / float(maxi(n, 1))


func _nz(a: PackedByteArray) -> int:
	var c := 0
	for v in a:
		if v != 0:
			c += 1
	return c

