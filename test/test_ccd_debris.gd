extends SceneTree
## 档 A/B/C 的验收：小型体素碎片 x CCD 的代价闸门 + 灰尘策略。
##
##   godot --headless --path . --script res://test/test_ccd_debris.gd
##
## 背景（实测，见 root/doc/CCD与小碎片.md）：
##   帧时间 = 子步数 x 每子步代价，两个乘数都只跟**一个**最快的刚体有关 ——
##   876 矩形（真实地图规模）下一个 2x2 的碎片以 40000 px/s 飞过 = 334 子步 = 593 ms/固定步。
## 这份闸门守的是「那件事不会再发生」，以及「别用穿模以外的方式换帧时间」。

const MAIN := preload("res://map/main.tscn")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const PWorld := preload("res://addons/pixel_destruction/physics/pworld.gd")

var _pass := 0
var _fail := 0
var _scene: Node
var _w
var _ctl


func _initialize() -> void:
	call_deferred("_run")


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS  ", name, "  ", detail)
	else:
		_fail += 1
		print("  FAIL  ", name, "  ", detail)


func _rects() -> int:
	var n := 0
	for b in _w.bodies:
		n += b.rects.size()
	return n


func _substeps() -> int:
	return _w._compute_substeps(1.0 / 60.0)


func _mk_shape(w: int, h: int) -> PixelShape:
	var s := PixelShape.new()
	s.fill_rect(Rect2i(0, 0, w, h), 1)
	return s


func _mk(w: int, h: int, pos: Vector2, vel: Vector2) -> PBody:
	var s := PixelShape.new()
	s.fill_rect(Rect2i(0, 0, w, h), 1)
	var b := PBody.new()
	b.position = pos
	_w.add_body(b, [s])
	b.refresh_com()
	b.update_aabb()
	b.linear_velocity = vel
	b.awake = true
	return b


## 主体 + 一座细桥 + 一条尾巴。把桥切断，尾巴就断开成一块**尺寸已知**的碎片。
## tail_w 决定那块碎片的**外接盒短边** —— 判废/隔离的判据就是它。
## 桥在 y=9..10（2 像素高），所以主体自己的外接盒不被桥拉薄。
const BRIDGE := Rect2i(40, 9, 6, 2)


## ⚠️ 尾巴放在 y=8 起：桥在 y=9..10，尾巴必须盖住它才连得上。
func _tailed_body(tail_w: int, tail_h: int, pos: Vector2) -> PBody:
	var s := PixelShape.new()
	s.fill_rect(Rect2i(0, 0, 40, 20), 1)
	s.fill_rect(BRIDGE, 1)
	s.fill_rect(Rect2i(46, 8, tail_w, tail_h), 1)
	var b := PBody.new()
	b.position = pos
	_w.add_body(b, [s])
	b.refresh_com()
	b.update_aabb()
	b.awake = false
	return b


## 细长尾巴（3x60）—— 验「不薄」那一路之外的**厚薄**触发器。
func _tailed_thin(pos: Vector2) -> PBody:
	var s := PixelShape.new()
	s.fill_rect(Rect2i(0, 0, 40, 20), 1)
	s.fill_rect(BRIDGE, 1)
	s.fill_rect(Rect2i(46, 0, 3, 60), 1)
	var b := PBody.new()
	b.position = pos
	_w.add_body(b, [s])
	b.refresh_com()
	b.update_aabb()
	b.awake = false
	return b


## 只把桥挖掉（尾巴自己留下 -> 断开成碎片）。
func _bridge_cut(b: PBody) -> Dictionary:
	var cut := {}
	for x in range(BRIDGE.position.x, BRIDGE.position.x + BRIDGE.size.x):
		for y in range(BRIDGE.position.y, BRIDGE.position.y + BRIDGE.size.y):
			cut[Vector2i(x, y)] = true
	return {b: {b.shapes[0]: cut}}


func _run() -> void:
	_scene = MAIN.instantiate()
	root.add_child(_scene)
	await process_frame
	await process_frame
	_w = _scene.world
	_ctl = _scene.get_node("SimulationRuntime/PhysicsStep")
	await process_frame

	print("=== ① 配置真的推上去了 ===")
	_check("CCD 开着（两层）", _w.ccd_enabled and _w.rp_ccd_substeps > 0,
		"enabled=%s rp_substeps=%d" % [str(_w.ccd_enabled), _w.rp_ccd_substeps])
	_check("子步硬上限生效（不再是死声明）", _w.ccd_max_substeps > 0 and _w.ccd_max_substeps <= 8,
		"ccd_max_substeps=%d" % _w.ccd_max_substeps)
	_check("尺寸豁免开着", _w.ccd_min_driver_thickness > 0.0,
		"ccd_min_driver_thickness=%.1f" % _w.ccd_min_driver_thickness)
	_check("逐体 CCD 开着", _w.ccd_per_body, "ccd_per_body=%s" % str(_w.ccd_per_body))
	_check("表面速度上限与游戏侧一致", is_equal_approx(_w.max_surface_speed, _ctl.max_surface_speed)
		and _w.max_surface_speed > 0.0, "world=%.0f ctl=%.0f" % [_w.max_surface_speed, _ctl.max_surface_speed])
	_check("碎片厚度判废接到引擎", is_equal_approx(_w.min_fragment_thickness, _ctl.debris_max_thickness)
		and _w.min_fragment_thickness > 0.0, "world=%.1f ctl=%.1f" % [_w.min_fragment_thickness, _ctl.debris_max_thickness])
	_check("灰尘层建好了（并且拿得到渲染器）", _ctl._dust != null and _ctl._dust._renderer != null,
		"dust=%s renderer=%s" % [str(_ctl._dust), str(_ctl._dust._renderer if _ctl._dust != null else null)])
	print("")

	print("=== ② 不做全局子步：多快的碎片都不切刀 ===")
	var base := _substeps()
	var thin := _mk(2, 2, Vector2(0, 0), Vector2(40000.0, 0.0))
	var fixed: int = int(_w.ccd_fixed_substeps)
	_check("薄碎片不驱动子步（子步 = 固定值，不是 1 也不是按碎片的）",
		_substeps() == fixed, "%d（ccd_fixed_substeps=%d）" % [_substeps(), fixed])
	_check("它自己仍然在飞（不是被删掉）", is_equal_approx(thin.linear_velocity.x, 40000.0),
		"vx=%.0f" % thin.linear_velocity.x)
	_w.remove_body(thin)
	var fat := _mk(20, 20, Vector2(0, 0), Vector2(40000.0, 0.0))
	_check("够厚的快刚体也不驱动子步（逐体模式下子步 = 固定值）", _substeps() == fixed,
		"基线 %d -> %d（固定 %d）" % [base, _substeps(), fixed])
	_w.remove_body(fat)
	print("")

	print("=== ③ 防穿靠逐体 CCD：4 像素薄墙挡得住 20000 px/s（子步恒为 1）===")
	var tw := PWorld.new()
	tw.gravity = Vector2.ZERO
	tw.sleeping_enabled = false
	tw.rp_ccd_substeps = int(_w.rp_ccd_substeps)
	tw.rp_soft_ccd_prediction = float(_w.rp_soft_ccd_prediction)
	tw.ccd_per_body_only = true
	tw.ccd_fixed_substeps = int(_w.ccd_fixed_substeps)
	var wall := PBody.new()
	wall.position = Vector2(200.0, 0.0)
	wall.make_static()
	tw.add_body(wall, [_mk_shape(4, 200)])
	var bullet := PBody.new()
	bullet.position = Vector2(0.0, 0.0)
	tw.add_body(bullet, [_mk_shape(12, 12)])
	bullet.linear_velocity = Vector2(20000.0, 0.0)
	bullet.awake = true
	var peak := 0
	for i in 10:
		tw.step(1.0 / 60.0)
		peak = maxi(peak, tw.last_substeps)
	_check("峰值子步 = 固定值（确实没按最快刚体做全局子步）", peak == int(_w.ccd_fixed_substeps),
		"峰值 %d（固定 %d）" % [peak, _w.ccd_fixed_substeps])
	_check("20000 px/s 撞 4 像素薄墙：**挡住**了", bullet.position.x < 200.0,
		"x=%.1f（墙在 200）" % bullet.position.x)
	_check("而且停在墙前（不是穿过去才被别的挡住）", absf(bullet.position.x - 188.0) < 6.0,
		"x=%.1f（期望 ~188）" % bullet.position.x)
	_check("软预测距离 > 0（否则逐体 CCD 是半关的）", tw.rp_soft_ccd_prediction > 0.0,
		"%.2f px" % tw.rp_soft_ccd_prediction)
	print("")

	print("=== ④ 表面速度收口：角速度按 |w| x 外接半径，不按裸 rad/s ===")
	var plank := _mk(300, 40, Vector2(-800, 400), Vector2.ZERO)
	plank.angular_velocity = 60.0
	plank.awake = true
	plank.refresh_com()
	plank.update_aabb()
	var surf_before: float = plank.angular_velocity * plank.bounding_radius()
	_ctl._clamp_speeds(_w)
	var surf_after: float = plank.angular_velocity * plank.bounding_radius()
	_check("|w| x r 被收到 max_surface_speed 以内",
		surf_after <= _ctl.max_surface_speed + 1e-3, "%.1f -> %.1f px/s" % [surf_before, surf_after])
	_check("收口前它确实超了（闸门不是空转）", surf_before > _ctl.max_surface_speed * 2.0,
		"%.1f px/s" % surf_before)
	var lin := _mk(8, 8, Vector2(-800, 400), Vector2(40000.0, 0.0))
	_ctl._clamp_speeds(_w)
	_check("线速度也被收口", lin.linear_velocity.length() <= _ctl.max_surface_speed + 1e-3,
		"%.1f" % lin.linear_velocity.length())
	_w.remove_body(plank)
	_w.remove_body(lin)
	print("")

	print("=== ⑤ 抓取迟滞不再锁死（cap 必须也压在返回值上）===")
	# ⚠️ 先关掉逐体模式（子步恒为 1 时这条闸门是空转），验**回退路径**上的迟滞。
	var keep_max: int = _w.ccd_max_substeps
	var keep_thin: float = _w.ccd_min_driver_thickness
	var keep_budget: float = _w.ccd_grab_substep_cost_budget_us
	var keep_pbo: bool = _w.ccd_per_body_only
	_w.ccd_per_body_only = false
	_w.ccd_max_substeps = 0
	_w.ccd_min_driver_thickness = 0.0
	var box: PBody = _scene.get_node("Box").body
	_w.grab(box, box.position)
	var spike := _mk(20, 20, Vector2(0, 0), Vector2(20000.0, 0.0))
	var raised := _substeps()
	_w.remove_body(spike)
	_w.ccd_grab_substep_cost_budget_us = 200.0
	var cap: int = _w.grab_substep_cap(_rects())
	var after := _substeps()
	_check("held 被 grab_substep_cap 拉回来", after <= cap,
		"%d -> %d（cap=%d，矩形=%d）" % [raised, after, cap, _rects()])
	_w.release_grab()
	_w.ccd_max_substeps = keep_max
	_w.ccd_min_driver_thickness = keep_thin
	_w.ccd_grab_substep_cost_budget_us = keep_budget
	_w.ccd_per_body_only = keep_pbo
	print("")

	print("=== ⑥ 两个尺寸度量必须分开（「碎片直接消失」那个 bug 的根）===")
	var sliver := _mk(1, 20, Vector2(600, 600), Vector2(100.0, 0.0))
	_check("1x20 细条：thinnest 与外接盒短边都是 1",
		is_equal_approx(sliver.thinnest_extent(), 1.0) and is_equal_approx(sliver.visible_short_side(), 1.0),
		"thinnest=%.2f visible=%.2f" % [sliver.thinnest_extent(), sliver.visible_short_side()])
	_check("100 px/s 就已经「需要 CCD」（小碎片是陷阱）", sliver.needs_ccd(1.0 / 60.0),
		"运动=%.2f px/步 vs 阈值 %.2f" % [sliver.motion_per_step(1.0 / 60.0), 0.5 * sliver.thinnest_extent()])
	var block := _mk(40, 40, Vector2(600, 600), Vector2(100.0, 0.0))
	_check("同样速度下 40x40 **不**需要 CCD（判据是尺寸，不是速度）", not block.needs_ccd(1.0 / 60.0),
		"运动=%.2f px/步 vs 阈值 %.2f" % [block.motion_per_step(1.0 / 60.0), 0.5 * block.thinnest_extent()])
	_w.remove_body(sliver)
	_w.remove_body(block)
	print("")

	print("=== ⑦ 斜切的大块**不许**被当成灰尘（回归钉）===")
	var sdiag := PixelShape.new()
	sdiag.fill_rect(Rect2i(0, 0, 60, 60), 1)
	var cutd := {}
	for x in 30:
		for y in 30:
			if x + y < 30:
				cutd[Vector2i(30 + x, 30 + y)] = true
	var bdiag := PBody.new()
	bdiag.position = Vector2(0, 0)
	_w.add_body(bdiag, [sdiag])
	bdiag.refresh_com()
	bdiag.update_aabb()
	var resd: Dictionary = _w.fracture_pixels(bdiag, {bdiag.shapes[0]: cutd}, 0.0, true, {})
	_check("斜切确实切下来一块", resd.fragments.size() + resd.downgraded.size() >= 1,
		"fragments=%d downgraded=%d" % [resd.fragments.size(), resd.downgraded.size()])
	_check("斜切的大块**没**被降级（它的外接盒有 29 像素宽）", resd.downgraded.is_empty(),
		"downgraded=%d" % resd.downgraded.size())
	if resd.fragments.size() > 0:
		var fd: PBody = resd.fragments[0]
		_check("它的 thinnest 确实是 1（斜边切出来的）但 visible 很大 —— 两个量必须分开判",
			fd.thinnest_extent() < 2.0 and fd.visible_short_side() > 20.0,
			"thinnest=%.0f visible=%.0f" % [fd.thinnest_extent(), fd.visible_short_side()])
	for f in resd.fragments:
		_w.remove_body(f)
	_w.remove_body(bdiag)
	print("")

	print("=== ⑧ 档 C：真正细的碎片不进物理，交回调用方 ===")
	var tail2 := _tailed_body(2, 20, Vector2(0, 0))
	var before_bodies: int = _w.bodies.size()
	var res2: Dictionary = _w.fracture_pixels(tail2, _bridge_cut(tail2)[tail2], 0.0, true, {})
	_check("尾巴被切下来了", res2.downgraded.size() + res2.fragments.size() >= 1,
		"fragments=%d downgraded=%d" % [res2.fragments.size(), res2.downgraded.size()])
	_check("2x20 的尾巴被降级、没生成刚体", res2.fragments.is_empty() and res2.downgraded.size() == 1,
		"fragments=%d downgraded=%d" % [res2.fragments.size(), res2.downgraded.size()])
	_check("刚体数没有因为降级而增加", _w.bodies.size() <= before_bodies,
		"%d -> %d" % [before_bodies, _w.bodies.size()])
	var d0: Dictionary = res2.downgraded[0] if res2.downgraded.size() > 0 else {}
	_check("降级的碎片带着 shape 与位姿（美术层拿得到）",
		d0.get("shape") != null and d0.has("position") and d0.has("rotation"))
	# 走**真实路径**（commit）再切一条，验灰尘层真的收到东西 ——
	# fracture_pixels 是引擎契约，spawn 挂在游戏的 commit() 上。
	var tail3 := _tailed_body(2, 20, Vector2(0, 0))
	var dust_before: int = _ctl._dust.count() if _ctl._dust != null else 0
	_ctl.commit(_w, _bridge_cut(tail3))
	_check("灰尘层收到了它", _ctl._dust != null and _ctl._dust.count() > dust_before,
		"dust %d -> %d" % [dust_before, _ctl._dust.count() if _ctl._dust != null else -1])
	await process_frame
	await process_frame
	_check("灰尘这一帧还在（看得见，不是立刻消失）", _ctl._dust.count() > 0,
		"dust=%d（寿命 %.2f s）" % [_ctl._dust.count(), _ctl._dust.lifetime])
	print("")

	print("=== ⑧b 灰尘判据：太薄**或**太小，两个触发器取并集 ===")
	var th: float = _w.min_fragment_thickness
	var px_th: int = _w.min_fragment_pixels_downgrade
	_check("两个触发器都开着", th > 0.0 and px_th > 0,
		"厚薄 %.1f / 大小 %d 像素" % [th, px_th])
	# 5x5 = 25 像素：**不薄**（短边 5）但**小** -> 必须成灰尘。
	# ⚠️ 这是使用方报的「小的没成灰尘」那一条的回归钉。
	var t_small := _tailed_body(5, 5, Vector2(0, 0))
	var r_small: Dictionary = _w.fracture_pixels(t_small, _bridge_cut(t_small)[t_small], 0.0, true, {})
	_check("5x5（25 像素、不薄）-> 灰尘", r_small.downgraded.size() == 1 and r_small.fragments.is_empty(),
		"downgraded=%d fragments=%d" % [r_small.downgraded.size(), r_small.fragments.size()])
	# 3x60 = 180 像素：**不小**但**薄**（短边 3）-> 也必须成灰尘（细长条会穿墙）
	var t_thin := _tailed_thin(Vector2(0, 0))
	var r_thin: Dictionary = _w.fracture_pixels(t_thin, _bridge_cut(t_thin)[t_thin], 0.0, true, {})
	_check("3x60（180 像素、很薄）-> 灰尘", r_thin.downgraded.size() == 1 and r_thin.fragments.is_empty(),
		"downgraded=%d fragments=%d" % [r_thin.downgraded.size(), r_thin.fragments.size()])
	# 20x20 = 400 像素：又厚又大 -> 刚体
	var t_big := _tailed_body(20, 20, Vector2(0, 0))
	var r_big: Dictionary = _w.fracture_pixels(t_big, _bridge_cut(t_big)[t_big], 0.0, true, {})
	_check("20x20（400 像素、又厚又大）-> 刚体", r_big.fragments.size() == 1 and r_big.downgraded.is_empty(),
		"downgraded=%d fragments=%d" % [r_big.downgraded.size(), r_big.fragments.size()])
	for f in r_big.fragments:
		_w.remove_body(f)
	print("")

	print("=== ⑨ 档 C：活下来的薄碎片只跟静态世界碰 ===")
	var tail6 := _tailed_body(6, 20, Vector2(0, 0))
	var before2: Array = _w.bodies.duplicate()
	_ctl.commit(_w, _bridge_cut(tail6))
	var fresh: Array = []
	for b2 in _w.bodies:
		if not before2.has(b2):
			fresh.append(b2)
	_check("6x20 的尾巴活下来了（生成了新刚体）", fresh.size() == 1, "new bodies=%d" % fresh.size())
	if fresh.size() > 0:
		var f6: PBody = fresh[0]
		_check("它的外接盒短边 = 6（活过判废、落在隔离区）",
			is_equal_approx(f6.visible_short_side(), 6.0), "visible=%.1f" % f6.visible_short_side())
		_check("它被挪到了灰尘层", f6.collision_layer == _ctl.DEBRIS_LAYER
			and f6.collision_mask == _ctl.WORLD_LAYER,
			"layer=%d mask=%d" % [f6.collision_layer, f6.collision_mask])
	# ⚠️ 回归钉：「只跟静态世界碰」不能是假的 —— 玩家默认也在第 1 层。
	var pb = _ctl._player.body
	_check("玩家被挪出了默认层（否则灰尘照样撞他）",
		(pb.collision_layer & _ctl.WORLD_LAYER) == 0 and (pb.collision_layer & _ctl.PLAYER_LAYER) != 0,
		"player layer=%d（WORLD=%d PLAYER=%d）" % [pb.collision_layer, _ctl.WORLD_LAYER, _ctl.PLAYER_LAYER])
	if fresh.size() > 0:
		var f7: PBody = fresh[0]
		var a_ok: bool = (f7.collision_layer & pb.collision_mask) != 0
		var b_ok: bool = (pb.collision_layer & f7.collision_mask) != 0
		_check("灰尘 vs 玩家：**至少一边不同意** -> 不碰", not (a_ok and b_ok),
			"灰尘layer=%d mask=%d / 玩家layer=%d mask=%d" % [
				f7.collision_layer, f7.collision_mask, pb.collision_layer, pb.collision_mask])
	# 但地形/道具照碰（玩家走了，世界还在）
	var ground: PBody = null
	for g in _w.bodies:
		if g.is_static:
			ground = g
			break
	if ground != null and fresh.size() > 0:
		var f8: PBody = fresh[0]
		_check("灰尘 vs 地形：两边都同意 -> 照碰",
			(f8.collision_layer & ground.collision_mask) != 0
			and (ground.collision_layer & f8.collision_mask) != 0,
			"地形layer=%d mask=%d" % [ground.collision_layer, ground.collision_mask])
	var big := _mk(40, 40, Vector2(700, 700), Vector2.ZERO)
	_ctl._isolate_debris([big])
	_check("大块不动（否则「大块落在碎块堆上」会穿过去）", big.collision_layer != _ctl.DEBRIS_LAYER,
		"layer=%d" % big.collision_layer)
	_w.remove_body(big)
	print("")

	print("---")
	print("%d passed, %d failed" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)
