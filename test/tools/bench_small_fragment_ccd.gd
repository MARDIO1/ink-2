extends SceneTree
## 小型体素碎片 x CCD：把「帧时间 = 子步数 x 每子步代价」两个乘数逐项量出来。
##
##   godot --headless --path . --script res://test/tools/bench_small_fragment_ccd.gd
##
## 结论见 root/doc/CCD与小碎片.md。三个乘数都是**乘**关系，而且都只跟**一个**最快的刚体有关：
##   子步数   = ceil(全世界最快刚体的运动 x dt / ccd_max_motion)   <- 一个碎片说了算
##   每子步   ~ 全世界总矩形数                                     <- 所有刚体陪跑
## 而「又轻又快的小碎片」正好是最容易造出高运动的东西（Δv = J/m，轻 100 倍就快 100 倍）。

const MAIN := preload("res://map/main.tscn")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

var _scene: Node
var _w

func _initialize() -> void:
	call_deferred("_run")

func _rects() -> int:
	var n := 0
	for b in _w.bodies:
		n += b.rects.size()
	return n

func _substeps() -> int:
	return _w._compute_substeps(1.0 / 60.0)

## 只量物理子步循环（不含伤害结算）
func _time(n: int) -> float:
	var t: int = Time.get_ticks_usec()
	for i in n:
		_w._substep_rapier(1.0 / 60.0 / float(n))
	return float(Time.get_ticks_usec() - t) / 1000.0

func _mk_square(size: int, pos: Vector2, vel: Vector2) -> PBody:
	var s := PixelShape.new()
	for x in size:
		for y in size:
			s.set_pixel(x, y, 1)
	var b := PBody.new()
	b.position = pos
	_w.add_body(b, [s])
	b.refresh_com(); b.update_aabb()
	b.linear_velocity = vel
	b.awake = true
	return b

func _mk_plank(w: int, h: int, pos: Vector2) -> PBody:
	var s := PixelShape.new()
	for x in w:
		for y in h:
			s.set_pixel(x, y, 1)
	var b := PBody.new()
	b.position = pos
	_w.add_body(b, [s])
	b.refresh_com(); b.update_aabb()
	b.awake = true
	return b

## 梳子：每列一个矩形 —— 撑大矩形数而不加动态刚体（模拟真实地图里的静态矩形）
func _mk_comb(cols: int, h: int, pos: Vector2) -> PBody:
	var s := PixelShape.new()
	for c in cols:
		for y in h:
			s.set_pixel(c * 2, y, 1)
	var b := PBody.new()
	b.position = pos
	b.is_static = true
	_w.add_body(b, [s])
	b.refresh_com(); b.update_aabb()
	return b

func _run() -> void:
	_scene = MAIN.instantiate()
	root.add_child(_scene)
	await process_frame
	await process_frame
	_w = _scene.world
	# 强制两层 CCD 都开（游戏侧配置见 root/src/physics_step.gd）。
	_w.ccd_enabled = true
	_w.rp_ccd_substeps = 1
	# 为了量「碎片本身的代价」，先把两道灰尘闸门关掉（默认引擎值）
	_w.ccd_ignore_mass = 0.0
	_w.debris_max_mass = 0.0
	_w.debris_min_speed = 0.0
	await process_frame

	print("【口径】ccd_enabled=true  ccd_max_motion=%.1f  ccd_substep_budget=%d  ccd_max_substeps(死声明)=%d" % [
		_w.ccd_max_motion, _w.ccd_substep_budget, _w.ccd_max_substeps])
	print("        ccd_ignore_mass=0  debris 闸门关（否则碎片被豁免，量不到）")
	print("        场景原值: ccd_ignore_mass=100 min_fragment_pixels=5 debris=20@20 线速度上限=%.0f 角速度上限=%.0f" % [
		_w.rp_max_linear_velocity, _w.max_angular_velocity])
	print("        基准矩形=%d  基准子步=%d" % [_rects(), _substeps()])
	print("")

	# 撑到真实地图规模（F1 日志里真实地图是 780~865 矩形）
	var combs: Array = []
	for i in 18:
		combs.append(_mk_comb(40, 20, Vector2(-4000 + (i % 6) * 130, -3000 + (i / 6) * 40)))
	print("=== 真实规模：矩形=%d ===" % _rects())
	var base_n: int = _substeps()
	var base_ms: float = _time(base_n)
	print("  基线 子步=%d 整步=%.3f ms（含一次性建碰撞体，偏大）" % [base_n, base_ms])
	print("")

	print("=== A. 一个 2x2 碎片（4 像素）的速度 -> 子步（线性律 ceil(v/60/2)）===")
	for v in [5000.0, 20000.0, 40000.0]:
		var b := _mk_square(2, Vector2(0, 0), Vector2(v, 0.0))
		var n: int = _substeps()
		var ms: float = _time(n)
		print("  v=%7.0f px/s -> 子步 %4d  整步 %9.3f ms   (每矩形每子步 %.2f us)" % [
			v, n, ms, ms * 1000.0 / float(n) / float(_rects())])
		_w.remove_body(b)
	print("")

	print("=== B. 子步数固定时，代价随世界矩形数线性涨 ===")
	var b2 := _mk_square(2, Vector2(0, 0), Vector2(5000.0, 0.0))
	for stage in 3:
		var n: int = _substeps()
		var ms: float = _time(n)
		print("  矩形=%4d 子步=%4d 整步 %8.3f ms  每子步 %.3f ms" % [
			_rects(), n, ms, ms / float(n)])
		for i in 4:
			combs.append(_mk_comb(40, 20, Vector2(-2000 + i * 130, 1200 + stage * 40)))
	_w.remove_body(b2)
	print("")

	print("=== C. 角速度通道 |w| x 外接半径（场景上限 %.0f rad/s）===" % _w.max_angular_velocity)
	print("    角速度上限是**绝对 rad/s**，但子步估的是**表面速度** -> 大刚体无上限")
	for size in [[120, 30], [300, 40]]:
		var p := _mk_plank(size[0], size[1], Vector2(-1200, 600))
		p.angular_velocity = _w.max_angular_velocity
		p.awake = true; p.refresh_com(); p.update_aabb()
		var r: float = p.bounding_radius()
		var n: int = _substeps()
		var ms: float = _time(n)
		print("  %3dx%-3d w=%.0f 外接半径=%6.1f 表面速度=%8.1f px/s -> 子步 %4d 整步 %9.3f ms" % [
			size[0], size[1], p.angular_velocity, r, p.angular_velocity * r, n, ms])
		_w.remove_body(p)
	print("  对照：线速度上限 %.0f px/s 只值 ceil(%.0f/120) = %d 子步" % [
		_w.rp_max_linear_velocity, _w.rp_max_linear_velocity,
		int(ceil(_w.rp_max_linear_velocity / 120.0))])
	print("")

	print("=== D. 切下来的碎片继承 w x r（pworld.gd:3192 未钳制）===")
	var plank := _mk_plank(300, 40, Vector2(-1500, 800))
	plank.angular_velocity = _w.max_angular_velocity
	plank.awake = true; plank.refresh_com(); plank.update_aabb()
	print("  切之前: 外接半径=%.1f 表面速度=%.1f -> 子步=%d" % [
		plank.bounding_radius(), plank.angular_velocity * plank.bounding_radius(), _substeps()])
	var cut := {}
	for x in range(150, 160):
		for y in 40:
			cut[Vector2i(x, y)] = true
	var res: Dictionary = _w.fracture_pixels(plank, {plank.shapes[0]: cut}, 0.0, true, {})
	var frags: Array = res.get("fragments", [])
	for f in frags:
		print("  切出碎片 质量=%.1f 运动=%.1f px/s（豁免<=100: %s）" % [
			f.mass, _w._motion_of(f), str(f.mass <= 100.0)])
	print("  切之后: 子步=%d" % _substeps())
	print("")

	print("=== E. 抓取迟滞：_substeps_held 只涨不落，grab_substep_cap 压不住它 ===")
	var box: PBody = _scene.get_node("Box").body
	_w.grab(box, box.position)
	print("  抓住 Box（矩形=%d）grab_substep_cap=%d" % [_rects(), _w.grab_substep_cap(_rects())])
	var spike := _mk_square(2, Vector2(0, 0), Vector2(20000.0, 0.0))
	print("  注入 2x2 @20000 -> 子步 %d" % _substeps())
	_w.remove_body(spike)
	print("  碎片已删，同帧再算 -> 子步 %d（held 不回落）" % _substeps())
	var big: Array = []
	for i in 16:
		big.append(_mk_comb(60, 30, Vector2(-3000 + (i % 4) * 160, -2500 + (i / 4) * 40)))
	print("  世界撑到 %d 矩形 -> grab_substep_cap=%d（本该压到 %d）" % [
		_rects(), _w.grab_substep_cap(_rects()), _w.grab_substep_cap(_rects())])
	var n_big: int = _substeps()
	var ms_big: float = _time(n_big)
	print("  但 _substeps_held 仍然返回 子步=%d  整步=%.3f ms" % [n_big, ms_big])
	_w.release_grab()
	for c in big:
		_w.remove_body(c)
	print("")

	print("【总结】帧时间 = 子步数(一个最快刚体决定) x 每子步代价(全世界矩形数决定)")
	print("  两个乘数都不按「时间预算」收口：子步只被 ccd_substep_budget=%d 挡，" % _w.ccd_substep_budget)
	print("  而 ccd_grab_substep_cost_budget_us=6000 那个预算**只在抓取时**生效。")
	quit()
