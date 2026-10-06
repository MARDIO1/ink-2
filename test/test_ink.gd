extends SceneTree
## BottledInk 的验收：真实主场景 + 真 Rapier。
##
## 覆盖四件事：
##   1. 墨水**不进物理像素** —— 它不是形状节点，玩家的形状数/像素数/质量基线都不变；
##   2. 液面**世界水平** —— shader 里的判据还原到全局坐标后，方向就是重力方向；
##   3. **虚空质量**按当前液面进合成质量 —— 走 shape.density_scale + PWorld.refresh_mass；
##   4. 密度真的推给了 Rapier（`_rp_density` 由 op34 对账），且改完质量后世界不抖。

## shader 判据的浮点容差：液面正好压在角上时 dot 会有 1e-13 级误差。
const EPS := 1e-6
const MAIN = preload("res://map/main.tscn")

var failures := 0
var checks := 0
var _scene
var _player
var _body
var _ink
var _visual
var _base_mass := 0.0


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


## shader 里那条判据：局部点 p 在液面以下（>= 0 才画）。
func _below(p: Vector2) -> float:
	var down_local: Vector2 = _ink.material.get_shader_parameter("down_local")
	var level: float = _ink.material.get_shader_parameter("level")
	return p.dot(down_local) - level


func _corners() -> Array[Vector2]:
	var size: Vector2 = _visual.texture.get_size()
	var o: Vector2 = _visual.offset
	return [o, o + Vector2(size.x, 0.0), o + Vector2(0.0, size.y), o + size]


func _run() -> void:
	_scene = MAIN.instantiate()
	_scene.auto_step = false
	root.add_child(_scene)
	await process_frame
	await process_frame
	_player = _scene.get_node("Player")
	_visual = _player.get_node("Visual")
	_ink = _player.get_node("BottledInk")
	_body = _player.body
	_base_mass = _body.mass
	_scene.auto_step = true
	for i in 90:
		await physics_frame

	# 1. 不进物理像素
	var baseline: int = _pixels()
	_check("BottledInk is not a shape node", not _ink.has_method("build_shape") and not _ink.has_method("get_shape"))
	_check("player keeps its six shape children", _player.collect_shapes().size() == 6 and _body.shapes.size() == 6)
	_check("player baseline pixels unchanged", baseline == 4378)

	# 2. 液面世界水平：局部方向转回全局就是重力方向
	var down_world: Vector2 = _scene.world.gravity.normalized()
	var down_local: Vector2 = _ink.material.get_shader_parameter("down_local")
	var global_down: Vector2 = down_local.rotated(_ink.global_rotation)
	_check("surface normal follows gravity in world space", global_down.distance_to(down_world) < 1e-5)

	# 空瓶：不画
	_ink.fill = 0.0
	await physics_frame
	_check("empty bottle draws nothing", not _ink.visible)
	_check("empty bottle costs no extra mass", is_equal_approx(_body.mass, _base_mass))

	# 满瓶：整块剪影都在液面以下
	_ink.fill = 1.0
	await physics_frame
	_check("full bottle reuses the baked silhouette texture",
		_ink.visible and _ink.texture == _visual.texture and _ink.offset == _visual.offset)
	_check("full bottle renders the whole silhouette", _ink.visible and _below(_corners()[0]) >= -EPS)
	var all_below := true
	for corner: Vector2 in _corners():
		all_below = all_below and _below(corner) >= -EPS
	_check("full bottle discards nothing", all_below)

	# 半瓶：最高的角被丢掉，最低的角留着
	_ink.fill = 0.5
	await physics_frame
	var below_count := 0
	for corner: Vector2 in _corners():
		if _below(corner) >= -EPS:
			below_count += 1
	_check("half bottle keeps exactly the lower corners", below_count == 2)
	# 液面随 fill 单调下降（沿重力方向越来越低）
	var half_level: float = _ink.material.get_shader_parameter("level")
	_ink.fill = 1.0
	await physics_frame
	var full_level: float = _ink.material.get_shader_parameter("level")
	_check("higher fill puts the surface higher", full_level < half_level)

	# 3. 虚空质量按当前液面进合成质量
	_ink.capacity_mass = 1200.0
	_ink.fill = 1.0
	for i in 2:
		await physics_frame
	_check("full ink adds its whole capacity to the mass", absf(_body.mass - (_base_mass + 1200.0)) < 1.0)
	var full_mass: float = _body.mass
	_ink.fill = 0.5
	for i in 2:
		await physics_frame
	var half_mass: float = _body.mass
	_check("half ink adds half the capacity", absf(half_mass - (_base_mass + 600.0)) < 1.0)
	_ink.fill = 0.0
	for i in 2:
		await physics_frame
	_check("empty ink returns to the baseline mass", absf(_body.mass - _base_mass) < 1.0)
	_check("ink mass keeps pixels untouched", _pixels() == baseline)

	# 量化：小于 mass_quantum 的变化不触发重算
	_ink.fill = 1.0
	for i in 2:
		await physics_frame
	var revision: int = _body.rects_rev
	_ink.fill = 1.0 - 0.01
	for i in 2:
		await physics_frame
	_check("sub-quantum fill changes skip the rebuild", _body.rects_rev == revision)

	# 4. 密度推给 Rapier + 改完质量不抖
	_ink.fill = 1.0
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
