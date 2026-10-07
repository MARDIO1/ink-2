extends SceneTree
## BottledInk 的验收：真实主场景 + 真 Rapier。
##
## 覆盖五件事：
##   1. 墨水**不进物理像素** —— 它不是形状节点，玩家的形状数/像素数/质量基线都不变；
##   2. 液面**世界水平** —— shader 里的判据还原到全局坐标后，方向就是重力方向；
##   3. 墨水只填**瓶内** —— 描边、瓶盖外的空白、贴图外接框四角都不画；
##   4. **虚空质量**按当前液面进合成质量 —— 走 shape.density_scale + PWorld.refresh_mass，
##      密度真的推给了 Rapier（`_rp_density` 由 op34 对账），且改完质量后世界不抖。
##   5. **液面由 InkHealth 供数** —— 图层不再自己存 fill，外部 add/reduce 改生命值，液面跟着走。

## shader 判据的浮点容差：液面正好压在角上时 dot 会有 1e-13 级误差。
const EPS := 1e-6
const MAIN = preload("res://map/main.tscn")
## 瓶内像素数（泛洪出来的封闭空腔）。跟着 asset 走：改了剪影贴图就要跟着改。
const INTERIOR_PX := 1810

var failures := 0
var checks := 0
var _scene
var _player
var _body
var _ink
var _liquid
var _visual
var _health
var _hud
var _changes := 0
var _base_mass := 0.0
var _interior_img: Image = null
var _silhouette_img: Image = null


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])


func _pixels() -> int:
	var total := 0
	for shape in _body.shapes:
		total += shape.pixel_count()
	return total


## 外部改墨水量：生命值是真源，图层只读 ratio()。
func _set_fill(ratio: float) -> void:
	_health.ink = ratio * _health.max_ink


func _on_health_changed() -> void:
	_changes += 1


## 液面方块在世界里的顶边，沿世界向下的有符号距离。
func _surface() -> float:
	var down: Vector2 = _scene.world.gravity.normalized()
	return _liquid.global_transform.origin.dot(down)


## 液面判据：贴图像素点 p（局部坐标）在液面以下（>= 0 才画）。
## 方块的世界系是「局部 X = 世界水平、局部 Y = 世界向下」，判据就是「世界点沿 down 投影 >= 方块顶边」。
func _below(p: Vector2) -> float:
	var down: Vector2 = _scene.world.gravity.normalized()
	return (_ink.global_position + p.rotated(_ink.global_rotation)).dot(down) - _surface()


func _corners() -> Array[Vector2]:
	var size: Vector2 = _visual.texture.get_size()
	var o: Vector2 = _visual.offset
	return [o, o + Vector2(size.x, 0.0), o + Vector2(0.0, size.y), o + size]


## shader 的完整判据（瓶内遮罩 + 液面），在贴图像素坐标上求值。
func _drawn_px(x: int, y: int) -> bool:
	if _interior_img == null or x < 0 or y < 0:
		return false
	if x >= _interior_img.get_width() or y >= _interior_img.get_height():
		return false
	if _interior_img.get_pixel(x, y).a <= 0.5:
		return false
	return _below(_ink.offset + Vector2(x + 0.5, y + 0.5)) >= -EPS


## 一趟扫出瓶内像素数 + 最下/最上的瓶内像素。
func _scan_interior() -> Dictionary:
	var count := 0
	var deep := Vector2i(-1, -1)
	var high := Vector2i(-1, -1)
	for y in _interior_img.get_height():
		for x in _interior_img.get_width():
			if _interior_img.get_pixel(x, y).a <= 0.5:
				continue
			count += 1
			if y > deep.y:
				deep = Vector2i(x, y)
			if high.y < 0 or y < high.y:
				high = Vector2i(x, y)
	return {"count": count, "deep": deep, "high": high}


## 第一个剪影实心像素（描边本身）。
func _first_solid() -> Vector2i:
	for y in _silhouette_img.get_height():
		for x in _silhouette_img.get_width():
			if _silhouette_img.get_pixel(x, y).a > 0.0:
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _run() -> void:
	_scene = MAIN.instantiate()
	_scene.auto_step = false
	root.add_child(_scene)
	await process_frame
	await process_frame
	_player = _scene.get_node("Player")
	_visual = _player.get_node("Visual")
	_ink = _player.get_node("BottledInk")
	_liquid = _player.get_node("BottledInk/Liquid")
	_body = _player.body
	_health = _player.get_node("InkHealth")
	_base_mass = _body.mass
	_scene.auto_step = true
	for i in 90:
		await physics_frame

	# 1. 不进物理像素
	var baseline: int = _pixels()
	_check("BottledInk is not a shape node", not _ink.has_method("build_shape") and not _ink.has_method("get_shape"))
	_check("the liquid square is not a shape node either",
		not _liquid.has_method("build_shape") and not _liquid.has_method("get_shape"))
	_check("player keeps its two shape children", _player.collect_shapes().size() == 2 and _body.shapes.size() == 2)
	_check("player baseline pixels unchanged", baseline == 3486)
	# 0. 生命值接口：查询 / 加 / 减 / 夹取 / 只在真变化时广播
	_health.changed.connect(_on_health_changed)
	_health.ink = _health.max_ink
	_changes = 0
	_health.reduce(30.0)
	_check("reduce takes ink away", is_equal_approx(_health.ink, _health.max_ink - 30.0))
	_check("ratio tracks ink", is_equal_approx(_health.ratio(), 0.7))
	_health.add(10.0)
	_check("add puts ink back", is_equal_approx(_health.ink, _health.max_ink - 20.0))
	_health.reduce(1.0e9)
	_check("ink never drops below zero", _health.ink == 0.0 and _health.ratio() == 0.0)
	_health.add(1.0e9)
	_check("ink never rises above max", _health.ink == _health.max_ink and _health.ratio() == 1.0)
	_check("every real change is broadcast exactly once", _changes == 4)
	# 0b. HUD 横条跟着同一个墨水值走
	_hud = _scene.get_node("Hud")
	_check("hud bar shows the full ink", is_equal_approx(_hud.status_bar.value, 100.0))
	_health.reduce(_health.max_ink * 0.75)
	_check("hud bar follows the ink source", is_equal_approx(_hud.status_bar.value, 25.0))
	_health.ink = _health.max_ink


	# 2. 液面世界水平：液面方块自己的 Y 轴就是世界向下
	var down_world: Vector2 = _scene.world.gravity.normalized()
	var liquid_down: Vector2 = _liquid.global_transform.y.normalized()
	_check("liquid square Y axis follows gravity in world space", liquid_down.distance_to(down_world) < 1e-5)

	# 空瓶：不画
	_set_fill(0.0)
	await physics_frame
	_check("empty bottle draws nothing", not _ink.visible)
	_check("empty bottle costs no extra mass", is_equal_approx(_body.mass, _base_mass))

	# 满瓶：整块剪影都在液面以下，但只填「瓶内」
	_set_fill(1.0)
	await physics_frame
	_check("full bottle still tracks the baked silhouette texture",
		_ink.visible and _ink.offset == _visual.offset
		and _ink.texture.get_size() == _visual.texture.get_size())
	var all_below := true
	for corner: Vector2 in _corners():
		all_below = all_below and _below(corner) >= -EPS
	_check("full bottle puts the whole silhouette below the surface", all_below)
	_check("bottle interior mask matches the silhouette texture",
		_ink.texture != null and _ink.texture.get_size() == _visual.texture.get_size())
	_interior_img = _ink.texture.get_image()
	_silhouette_img = _visual.texture.get_image()
	var scan: Dictionary = _scan_interior()
	var deep: Vector2i = scan["deep"]
	var high: Vector2i = scan["high"]
	_check("bottle interior mask covers only the enclosed volume", int(scan["count"]) == INTERIOR_PX)
	_check("ink fills the interior but never the texture box corners",
		_drawn_px(deep.x, deep.y) and _drawn_px(high.x, high.y) and not _drawn_px(0, 0)
		and not _drawn_px(_interior_img.get_width() - 1, _interior_img.get_height() - 1))
	var solid: Vector2i = _first_solid()
	_check("bottle outline stays out of the ink layer", not _drawn_px(solid.x, solid.y))

	# 半瓶：最高的角被丢掉，最低的角留着；瓶内按液面上下分开
	_set_fill(0.5)
	await physics_frame
	var below_count := 0
	for corner: Vector2 in _corners():
		if _below(corner) >= -EPS:
			below_count += 1
	_check("half bottle keeps exactly the lower corners", below_count == 2)
	_check("half bottle fills below the surface and empties above",
		_drawn_px(deep.x, deep.y) and not _drawn_px(high.x, high.y))
	# 液面随 fill 单调下降（沿重力方向越来越低）
	var half_level: float = _surface()
	_set_fill(1.0)
	await physics_frame
	var full_level: float = _surface()
	_check("higher fill puts the surface higher", full_level < half_level)

	# 3. 虚空质量按当前液面进合成质量
	_ink.capacity_mass = 1200.0
	_set_fill(1.0)
	for i in 2:
		await physics_frame
	_check("full ink adds its whole capacity to the mass", absf(_body.mass - (_base_mass + 1200.0)) < 1.0)
	var full_mass: float = _body.mass
	_set_fill(0.5)
	for i in 2:
		await physics_frame
	var half_mass: float = _body.mass
	_check("half ink adds half the capacity", absf(half_mass - (_base_mass + 600.0)) < 1.0)
	_set_fill(0.0)
	for i in 2:
		await physics_frame
	_check("empty ink returns to the baseline mass", absf(_body.mass - _base_mass) < 1.0)
	_check("ink mass keeps pixels untouched", _pixels() == baseline)

	# 量化：小于 mass_quantum 的变化不触发重算
	_set_fill(1.0)
	for i in 2:
		await physics_frame
	var revision: int = _body.rects_rev
	_set_fill(0.99)
	for i in 2:
		await physics_frame
	_check("sub-quantum fill changes skip the rebuild", _body.rects_rev == revision)

	# 4. 密度推给 Rapier + 改完质量不抖
	_set_fill(1.0)
	for i in 60:
		physics_frame
	await physics_frame
	_check("material density reaches the Rapier side", is_equal_approx(_body._rp_density, _body.density))
	_check("mass change keeps the body settled", _body.linear_velocity.length() < 200.0
		and absf(_body.angular_velocity) < 5.0 and _body.mass > full_mass - 1.0)
	_check("player and pixels survive the mass change", _pixels() == baseline and _scene._body_nodes.size() == _scene.world.bodies.size())

	_scene.auto_step = false
	_scene.get_node("Player/Arm/Hand/HandControl").set_physics_process(false)
	_scene.get_node("Player/PlayerInput").set_physics_process(false)
	for body in _scene.world.bodies.duplicate():
		for shape in body.shapes:
			shape.owner_body = null
		_scene.world.remove_body(body)
		body.shapes.clear()
	_scene.world.contacts.clear()
	_scene.world._rp = null
	_scene.queue_free()
	await process_frame
	print("[Ink] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
