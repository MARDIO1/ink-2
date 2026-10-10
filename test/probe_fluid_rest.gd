extends SceneTree
## 诊断：**为什么永远静不下来** —— 静止密度基准被表面格拉低，于是体相永远过压。
##
## 推理链（每一步都有前面的实测撑着）：
##   1. 平衡态要求 div = compression * stiffness，而 v = 0 时 div = 0
##      => 真正的静止只可能在 **compression = 0**，也就是密度 = rest_density。
##   2. 但 rest_density 是**所有流体格**的平均，里面混着液面和贴壁的低密度格：
##      全体均值 1.3173，内部格均值 1.3592，**差 3.18%**。
##   3. 于是体相的密度永远高于基准 => 压力恒为正 => **没有平衡态**。
##      症状正是"液面永远静止不下来"，而且换重力/换刚度都治不好。
##
## 判据：速度。重力=0 时它降到 0.013（能静），有重力时 3~5（静不了）。
## 这一轮要看的就一件事：把基准换成内部格均值之后，**速度会不会掉下来**。
##
## ⚠️ 只能走 GDScript 参照实现：rest_density 是原生的**内部**状态，
##    协议里没有"灌 rest_density"这个口子（load 只发 11 个参数 + 掩码 + pos/vel）。
##    所以把 _native 关掉直接写。参照实现 34 ms/步，所以只跑 1200 帧。

const FluidPBF := preload("res://addons/pixel_destruction/fluid/fluid_pbf.gd")

const FRAMES := 1200
const MARKS := [300, 600, 1200]

const VARIANTS := [
	{"tag": "基准 rest=均值 stiff6", "use_inner": false, "stiff": 6.0, "over": 0.8},
	{"tag": "内部 rest stiff6", "use_inner": true, "stiff": 6.0, "over": 0.8},
	{"tag": "内部 rest stiff10", "use_inner": true, "stiff": 10.0, "over": 0.8},
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
	print("%-22s %22s %22s %8s" % ["变体", "覆盖 300/600/1200", "速度 300/600/1200", "液面行"])
	for v in VARIANTS:
		_one(v, gw, gh, mask, cap, gm, dt)
	print("")
	print("初始覆盖 0.909。速度掉到 1 以下才算静了（重力=0 时是 0.013）。")


func _one(v: Dictionary, gw: int, gh: int, mask: PackedByteArray,
		cap: int, gm: float, dt: float) -> void:
	var f = FluidPBF.new()
	f.resize_grid(gw, gh)
	f.solid_mask = mask.duplicate()
	f.push_iters = 1
	f.grid_iters = 8
	f.stiffness = float(v["stiff"])
	f.over_relaxation = float(v["over"])
	f.dt = dt
	f.max_particles = cap
	f.init_particles(cap)
	f.set_fill_ratio(1.0)
	f.snap_fill(0.0, 1.0)
	f._native_checked = true
	f._native = null            # 关掉原生：下面要直接写 rest_density
	f._particles_to_grid()
	f._density_update()
	var all_mean: float = f.rest_density
	var inner := _inner_mean(f)
	if bool(v["use_inner"]):
		f.rest_density = inner[0]
	f._raster_ink()
	var cov := ""
	var spd := ""
	var mi := 0
	for fr in FRAMES:
		f.step(0.0, gm)
		if mi < MARKS.size() and fr + 1 == MARKS[mi]:
			cov += "%.3f " % _coverage(f, mask)
			spd += "%.2f " % _speed(f)
			mi += 1
	var s := _surface(f, gw, gh)
	print("%-22s %22s %22s %8.1f" % [v["tag"], cov, spd, s[0]])
	print("      全体均值 %.6f  内部均值 %.6f（%d 格，差 %.2f%%）  实际用 %.6f" % [
		all_mean, inner[0], int(inner[1]), 100.0 * (inner[0] / maxf(all_mean, 1e-9) - 1.0), f.rest_density])


## 四邻全是流体格的格子的密度均值 —— 这才是**体相**的密度。
func _inner_mean(f) -> Array:
	var gw: int = f.num_x
	var gh: int = f.num_y
	var sum := 0.0
	var cnt := 0
	for x in range(1, gw - 1):
		for y in range(1, gh - 1):
			var c: int = x * gh + y
			if f.cell_type[c] != f.FLUID_CELL:
				continue
			if f.cell_type[c - gh] != f.FLUID_CELL or f.cell_type[c + gh] != f.FLUID_CELL 					or f.cell_type[c - 1] != f.FLUID_CELL or f.cell_type[c + 1] != f.FLUID_CELL:
				continue
			sum += f._density[c]
			cnt += 1
	return [sum / float(maxi(cnt, 1)), cnt]


func _surface(f, gw: int, gh: int) -> Array:
	var sum := 0.0
	var cnt := 0
	for x in gw:
		for y in gh:
			if f.ink[x * gh + y] != 0:
				sum += float(y)
				cnt += 1
				break
	return [sum / float(maxi(cnt, 1)), cnt]


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
