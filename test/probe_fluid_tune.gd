extends SceneTree
## 诊断：**重力保持 600，靠阻尼让它静下来** —— 以及体积能不能同时保住。
##
## 已经钉死的：
##   · 重力 150 能让体积回到 0.91，但**液面永远静止不下来**（20 秒里 92% -> 76% 还在跌）
##     —— 这条路废弃，重力回到 600。
##   · 体积靠 stiffness：实测覆盖 stiff 1 -> 0.625、4 -> 0.737、6 -> 0.911、8 -> 0.964。
##   · 自由落体末速 4.43 格/步（超 CFL），所以 600 下必须靠**阻尼**压住沸腾。
##
## 阻尼的三个旋钮：flip_ratio 调小（多 PIC = 更黏，直接吃掉动能）、
## bouncyness 调向 0（撞壁不留反弹速度）、over_relaxation 调小（别过冲）。
##
## 判据：覆盖在 300 / 900 / 1800 帧三点的**走势** —— 还在跌就是没收敛。
## 速度是"静不静"的直接读数（域高 2.42 单位，速度 2 = 每步 0.8 格）。

const FluidPBF := preload("res://addons/pixel_destruction/fluid/fluid_pbf.gd")

const FRAMES := 1800
const MARKS := [300, 900, 1800]

const VARIANTS := [
	{"tag": "stiff6 flip.9 b-.9", "gdiv": 1.0, "stiff": 6.0, "over": 0.8, "flip": 0.9, "bounce": -0.9},
	{"tag": "stiff6 flip.6 b-.9", "gdiv": 1.0, "stiff": 6.0, "over": 0.8, "flip": 0.6, "bounce": -0.9},
	{"tag": "stiff6 flip.6 b-.3", "gdiv": 1.0, "stiff": 6.0, "over": 0.8, "flip": 0.6, "bounce": -0.3},
	{"tag": "stiff6 flip.4 b0", "gdiv": 1.0, "stiff": 6.0, "over": 0.8, "flip": 0.4, "bounce": 0.0},
	{"tag": "stiff8 flip.6 b-.3", "gdiv": 1.0, "stiff": 8.0, "over": 0.8, "flip": 0.6, "bounce": -0.3},
	{"tag": "stiff8 flip.4 b0", "gdiv": 1.0, "stiff": 8.0, "over": 0.8, "flip": 0.4, "bounce": 0.0},
	{"tag": "stiff10 flip.4 b0", "gdiv": 1.0, "stiff": 10.0, "over": 0.8, "flip": 0.4, "bounce": 0.0},
]

var _scene = null
var _start := 0
var _done := false


func _initialize() -> void:
	_scene = load("res://map/main.tscn").instantiate()
	root.add_child(_scene)
	_start = Engine.get_physics_frames()


func _process(_d: float) -> bool:
	if _done:
		quit(0)
		return true
	if Engine.get_physics_frames() - _start < 5:
		return false
	_done = true
	_run()
	return false


func _run() -> void:
	var ink = _scene.get_node_or_null("Player/BottledInk")
	if ink == null or ink._fluid == null:
		print("** 容器没建起来 **")
		return
	var src = ink._fluid
	var gw: int = src.num_x
	var gh: int = src.num_y
	var mask: PackedByteArray = ink._container.duplicate()
	var cap: int = src.max_particles
	var gm: float = ink.gravity_px * src.spacing
	var dt: float = 1.0 / float(Engine.physics_ticks_per_second)
	print("容器 %dx%d  可通行 %d  max_particles %d  重力 %.3f  dt %.5f" % [
		gw, gh, _nz(mask), cap, gm, dt])
	print("")
	print("%-20s %7s %7s %7s %7s %7s %7s" % [
		"变体", "覆盖300", "覆盖900", "覆盖1800", "液面行", "起伏", "速度"])
	for v in VARIANTS:
		_one(v, gw, gh, mask, cap, gm, dt)
	print("")
	print("初始覆盖 0.909。覆盖还在往下跌 = 没收敛。液面行 6 = 90% 满。")


func _one(v: Dictionary, gw: int, gh: int, mask: PackedByteArray,
		cap: int, gm: float, dt: float) -> void:
	var g: float = gm / float(v["gdiv"])
	var f = FluidPBF.new()
	f.resize_grid(gw, gh)
	f.solid_mask = mask.duplicate()
	f.push_iters = 1
	f.grid_iters = 8
	f.stiffness = float(v["stiff"])
	f.over_relaxation = float(v["over"])
	f.flip_ratio = float(v["flip"])
	f.bouncyness = float(v["bounce"])
	f.dt = dt
	f.mark_dirty()
	f.max_particles = cap
	f.init_particles(cap)
	f.set_fill_ratio(1.0)
	f.snap_fill(0.0, 1.0)
	f._raster_ink()
	var cov := PackedFloat64Array()
	var mi := 0
	for fr in FRAMES:
		f.step(0.0, g)
		if mi < MARKS.size() and fr + 1 == MARKS[mi]:
			cov.append(_coverage(f, mask))
			mi += 1
	f.sync_from_native()
	var s := _surface(f, gw, gh)
	print("%-20s %7.3f %7.3f %7.3f %7.1f %7.2f %7.3f" % [
		v["tag"], cov[0], cov[1], cov[2], s[0], s[1], _speed(f)])


## 液面：每一列最上面那个有墨的格。返回 [平均行号, 起伏, 有墨的列数]
func _surface(f, gw: int, gh: int) -> Array:
	var sum := 0.0
	var sum2 := 0.0
	var cnt := 0
	for x in gw:
		for y in gh:
			if f.ink[x * gh + y] != 0:
				sum += float(y)
				sum2 += float(y) * float(y)
				cnt += 1
				break
	if cnt == 0:
		return [-1.0, 0.0, 0]
	var m := sum / float(cnt)
	return [m, sqrt(maxf(sum2 / float(cnt) - m * m, 0.0)), cnt]


func _coverage(f, mask: PackedByteArray) -> float:
	return float(_nz(f.ink)) / float(maxi(_nz(mask), 1))


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

