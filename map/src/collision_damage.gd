#region 依赖与规则
extends Node
## 世界级碰撞结算。每个固定步先算双方，再统一删像素、分片和重建。
## 不保存像素余量；碎片只需 PBody，不需要额外挂载脚本。

const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")

## 以抓住 32×32 物块抬起再下砸校准：普通落下不删像素，完整下砸约一层。
## 碰撞冲量转为破坏预算的倍率；越大越容易删像素。
@export var damage_scale: float = 0.012
## 触发损坏的最小接近速度，单位 px/s；低于该值不结算，避免静态压力损坏。
@export var min_approach: float = 300.0
## 厚度支撑累加上限，以表面材料强度归一化；超过后不再增加减伤。
@export var support_max: float = 64.0
## 厚度对数减伤系数；越大，同样厚度下的损坏越小。
@export var thickness_scale: float = 0.5
## 厚度修正的最低倍率；即使支撑很厚也保留该比例的破坏预算。
@export_range(0.0, 1.0, 0.01) var min_thickness_factor: float = 0.2
## 强度 0 表示不删像素；作为攻击方及玩家伤害的参考抗性仍需有限值。
@export var reference_strength: float = 100.0
## 单次撞击最多生成的主裂纹数；实际数量仍由可破坏像素预算决定。
@export_range(1, 4, 1) var crack_max_count: int = 4
## 每增加一条主裂纹需要的等效可破坏像素数；越大越难出现多条裂纹。
@export_range(1.0, 32.0, 0.5) var crack_pixels_per_branch: float = 6.0
## 主裂纹围绕受力进入方向的最大展开角；实际角度带确定性扰动，不形成整齐扇形。
@export_range(0.0, 80.0, 1.0) var crack_spread_degrees: float = 35.0
## 每段裂纹的最大随机转角；越大越接近闪电或树根，越小越接近玻璃直裂纹。
@export_range(0.0, 30.0, 1.0) var crack_turn_degrees: float = 10.0
## 裂纹前进多少像素后重新取一次转角；越小折线越密。
@export_range(1, 16, 1) var crack_turn_pixels: int = 4
var _elapsed: float = 0.0
var _main = null
var _player = null
var _protected: Array = []
@onready var _feet = $"../Player/PlayerInput"
@onready var _forces = get_node_or_null("../HUD/ForceDebug")
@onready var _camera: Camera2D = $"../Camera2D"
## 活动范围相对当前可见画面的宽高倍率；4 表示宽高各四倍，完全在外的刚体冻结。
@export_range(1.0, 32.0, 0.5) var freeze_view_scale: float = 4.0
## 连续碰撞检测；关闭可降低高速/抓取时的子步开销，但允许穿模。
@export var ccd_enabled: bool = false
var profile_enabled: bool = false
var _profile: Dictionary = {}
#endregion


#region 世界步进
func _ready() -> void:
	# 等父世界及 Player 完成初始化，再接管步进，避免同一帧推进两次。
	call_deferred("_start")


func _start() -> void:
	_main = get_parent()
	_player = _main.get_node("Player")
	_protected = [_player.get_node("Arm").body, _player.get_node("Arm/Hand").body]
	_main.world.ccd_enabled = ccd_enabled
	_main.world.rp_ccd_substeps = 1 if ccd_enabled else 0
	_main.set_physics_process(false)
	_main.world.contact_events_enabled = false
	process_physics_priority = _main.process_physics_priority + 1


func _physics_process(delta: float) -> void:
	if _main == null or not _main.auto_step:
		return
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	_elapsed += delta
	var steps: int = 0
	while _elapsed >= _main.fixed_dt and steps < _main.max_substeps:
		var result: Dictionary = _step(_main.fixed_dt)
		_player.apply_collision_damage(result.player_damage)
		if not result.removals.is_empty():
			var nodes: Array = _main._body_nodes.duplicate()
			commit(_main.world, result.removals)
			var sync_start: int = Time.get_ticks_usec() if profile_enabled else 0
			_main.sync_world_bodies()
			if profile_enabled:
				_profile.sync_us = _profile.get("sync_us", 0) + Time.get_ticks_usec() - sync_start
			var live: Dictionary = {}
			for body in _main.world.bodies:
				live[body] = true
			for node in nodes:
				if is_instance_valid(node) and not live.has(node.body):
					node.queue_free()
		_elapsed -= _main.fixed_dt
		steps += 1
	if _elapsed > _main.fixed_dt * _main.max_substeps:
		_elapsed = 0.0
	if is_instance_valid(_forces):
		_forces.finish(delta)
	if _main.auto_render and _main.renderer != null:
		var render_start: int = Time.get_ticks_usec() if profile_enabled else 0
		# 内部连杆隐藏，手使用自己的三角形视觉；冻结体的变换不需要重复同步。
		var visible: Dictionary = _main._live_ids()
		for body in _protected:
			visible.erase(body.id)
		_main.renderer.prune(visible)
		for i in _main.world.bodies.size():
			var body = _main.world.bodies[i]
			var node = _main._body_nodes[i]
			if not body.is_static and not body.frozen and not _protected.has(body) and (node == null or not _main.has_own_sprite(node)):
				_main.renderer.sync(body)
		if profile_enabled:
			_profile.render_sync_us = _profile.get("render_sync_us", 0) + Time.get_ticks_usec() - render_start
	if profile_enabled:
		_profile.physics_us = _profile.get("physics_us", 0) + Time.get_ticks_usec() - profile_start
		_profile.physics_calls = _profile.get("physics_calls", 0) + 1


func set_profile_enabled(enabled: bool) -> void:
	profile_enabled = enabled
	_profile.clear()


func take_profile() -> Dictionary:
	var result: Dictionary = _profile.duplicate()
	_profile.clear()
	return result


## 接触点必须匹配该子步的位姿；删除并集留到固定步末，避免重复重建。
func _step(delta: float) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var physics = _main.world
	# 用当前可见画面扩大范围，整组关节冻结；玩家连接的物体持续受力。
	var size: Vector2 = _camera.get_viewport_rect().size / _camera.zoom * freeze_view_scale
	physics.cull_freeze(Rect2(_camera.get_screen_center_position() - size * 0.5, size), [_player.body])
	for body in physics.bodies:
		body.refresh_com()
	var count: int = physics._compute_substeps(delta)
	physics.last_substeps = count
	if profile_enabled:
		_profile.fixed_steps = _profile.get("fixed_steps", 0) + 1
		_profile.substeps = _profile.get("substeps", 0) + count
	var result: Dictionary = {"removals": {}, "player_damage": 0.0}
	for i in count:
		physics.contacts.clear()
		var native_start: int = Time.get_ticks_usec() if profile_enabled else 0
		physics._substep_rapier(delta / count)
		if profile_enabled:
			_profile.native_us = _profile.get("native_us", 0) + Time.get_ticks_usec() - native_start
		var impact: Dictionary = calculate(physics, _player.body, _protected)
		result.player_damage += impact.player_damage
		for body in impact.removals:
			if not result.removals.has(body):
				result.removals[body] = impact.removals[body]
				continue
			for shape in impact.removals[body]:
				if not result.removals[body].has(shape):
					result.removals[body][shape] = impact.removals[body][shape]
				else:
					result.removals[body][shape].merge(impact.removals[body][shape], true)
	if profile_enabled:
		_profile.step_us = _profile.get("step_us", 0) + Time.get_ticks_usec() - profile_start
	return result
#endregion


#region 碰撞结算
## 返回 {removals: {PBody: {PixelShape: {Vector2i: true}}}, player_damage: float}。
## 重叠删除取并集；每条 lane 独立消费预算，未满一个像素的余量舍弃。
func calculate(world, player_body: PBody = null, protected_bodies: Array = []) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var result: Dictionary = {"removals": {}, "player_damage": 0.0}
	var contacts_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var contacts: Array = _contacts(world)
	if profile_enabled:
		_profile.contacts_us = _profile.get("contacts_us", 0) + Time.get_ticks_usec() - contacts_start
		_profile.contact_pairs = _profile.get("contact_pairs", 0) + contacts.size()
	if is_instance_valid(_forces):
		_forces.sample_contacts(contacts, _main.fixed_dt / world.last_substeps)
	if is_instance_valid(_feet):
		_feet.update_support(contacts)
	for contact in contacts:
		if contact.approach <= min_approach:
			continue
		var impact: Dictionary = _impact(contact.points)
		if impact.is_empty():
			continue
		var point: Vector2 = impact.position
		var normal: Vector2 = impact.normal
		var a_origin: Vector2 = point - normal * 0.001
		var b_origin: Vector2 = point + normal * (maxf(impact.dist, 0.0) + 0.001)
		var a_material: int = _material_at(contact.a, a_origin)
		var b_material: int = _material_at(contact.b, b_origin)
		if a_material == 0 or b_material == 0:
			continue
		for side in [[contact.a, a_origin, -normal, a_material, b_material, -1.0],
				[contact.b, b_origin, normal, b_material, a_material, 1.0]]:
			var body: PBody = side[0]
			if protected_bodies.has(body):
				continue
			var strength: float = world.material_strength(side[3]).x
			if strength <= 0.0 and body != player_body:
				continue
			strength = strength if strength > 0.0 else reference_strength
			var attacker: float = world.material_strength(side[4]).x
			attacker = attacker if attacker > 0.0 else reference_strength
			var budget: float = damage_scale * impact.impulse * attacker / strength
			if body != player_body and budget < strength:
				continue  # 连第一层都删不掉，不必扫描厚度。
			var path: Array = _trace(body, side[1], side[2], world, 0.0 if body == player_body else budget, body == player_body)
			var seed: int = hash(Vector3i(roundi(point.x * 16.0), roundi(point.y * 16.0), roundi(impact.impulse)))
			_damage_side(world, body, path, side[4], impact.impulse, player_body,
				protected_bodies, result, side[1], side[2], seed, side[5])
	if profile_enabled:
		_profile.damage_us = _profile.get("damage_us", 0) + Time.get_ticks_usec() - profile_start
	return result


func _damage_side(world, body: PBody, path: Array, attacker_material: int,
		impulse: float, player_body: PBody, protected_bodies: Array, result: Dictionary,
		origin: Vector2 = Vector2.INF, direction: Vector2 = Vector2.ZERO, seed: int = 0,
		mirror: float = 1.0) -> void:
	if protected_bodies.has(body) or path.is_empty():
		return
	var surface_strength: float = world.material_strength(path[0].material).x
	if surface_strength <= 0.0:
		if body != player_body:
			return
		surface_strength = reference_strength
	var attacker_strength: float = world.material_strength(attacker_material).x
	if attacker_strength <= 0.0:
		attacker_strength = reference_strength
	var support: float = 0.0
	for pixel in path:
		var strength: float = world.material_strength(pixel.material).x
		if body == player_body and strength <= 0.0:
			strength = reference_strength
		# 不可破坏的内层提供最大支撑，且逐层消耗时会阻挡贯穿。
		support = minf(support_max, support + (strength / surface_strength if strength > 0.0 else support_max))
		if support >= support_max:
			break
	var factor: float = min_thickness_factor + (1.0 - min_thickness_factor) / (1.0 + thickness_scale * log(1.0 + support))
	var budget: float = damage_scale * impulse * attacker_strength / surface_strength * factor
	if body == player_body:
		result.player_damage += budget
		return
	if not origin.is_finite() or direction.is_zero_approx():
		_consume_path(world, body, path, budget, result)
		return
	var count: int = _crack_count(budget / surface_strength)
	var branch_budget: float = budget / float(count)
	for i in count:
		var spread: float = 0.0 if count == 1 else remap(float(i), 0.0, float(count - 1), -1.0, 1.0)
		var jitter: float = (_noise(seed, i) * 2.0 - 1.0) * crack_turn_degrees
		var angle: float = deg_to_rad((spread * crack_spread_degrees + jitter) * mirror)
		var crack: Array = _crack_path(body, origin, direction.rotated(angle), world,
			branch_budget, seed + i * 97, mirror)
		_consume_path(world, body, crack, branch_budget, result)


func _crack_count(pixel_budget: float) -> int:
	return clampi(1 + floori(maxf(0.0, pixel_budget - 1.0) / crack_pixels_per_branch), 1, crack_max_count)


func _consume_path(world, body: PBody, path: Array, budget: float, result: Dictionary) -> void:
	for pixel in path:
		var cost: float = world.material_strength(pixel.material).x
		if cost <= 0.0 or budget < cost:
			break
		budget -= cost
		if not result.removals.has(body):
			result.removals[body] = {}
		if not result.removals[body].has(pixel.shape):
			result.removals[body][pixel.shape] = {}
		result.removals[body][pixel.shape][pixel.position] = true
#endregion


#region 接触面
## 只查询冲量，避免接触事件逐像素计算宽度与应力。
func _contacts(world) -> Array:
	if not world.contacts.is_empty():
		return world.contacts
	var bodies: Dictionary = {}
	for body in world.bodies:
		bodies[body.rapier_id] = body
	var contacts: Array = []
	for i in world.contact_pair_count():
		var info: Dictionary = world.contact_info(i)
		var a = bodies.get(info.id_a)
		var b = bodies.get(info.id_b)
		if a == null or b == null or info.points.is_empty():
			continue
		var point: Dictionary = info.points[0]
		var ra: Vector2 = point.position - a.com_world()
		var rb: Vector2 = point.position - b.com_world()
		var va: Vector2 = Vector2(a.pre_vx, a.pre_vy) + Vector2(-ra.y, ra.x) * a.pre_w
		var vb: Vector2 = Vector2(b.pre_vx, b.pre_vy) + Vector2(-rb.y, rb.x) * b.pre_w
		contacts.append({"a": a, "b": b, "points": info.points,
			"approach": -(vb - va).dot(point.normal)})
	return contacts


## 同一碰撞对只形成一次撞击；多接触点按各自冲量合成，避免 N 个点产生 N 份伤害。
func _impact(points: Array) -> Dictionary:
	var total: float = 0.0
	var position: Vector2 = Vector2.ZERO
	var normal: Vector2 = Vector2.ZERO
	var dist: float = 0.0
	for point in points:
		if point.impulse <= 0.0:
			continue
		total += point.impulse
		position += point.position * point.impulse
		normal += point.normal * point.impulse
		dist += point.dist * point.impulse
	if total <= 0.0 or normal.is_zero_approx():
		return {}
	normal = normal.normalized()
	var tangent: Vector2 = Vector2(-normal.y, normal.x)
	var first: float = INF
	var last: float = -INF
	for point in points:
		if point.impulse > 0.0:
			first = minf(first, point.position.dot(tangent))
			last = maxf(last, point.position.dot(tangent))
	var width: int = maxi(1, ceili(last - first))
	return {"position": position / total, "normal": normal, "dist": dist / total,
		"impulse": total / float(width), "total_impulse": total, "width": width}
#endregion


#region 像素路径
func _material_at(body: PBody, point: Vector2) -> int:
	var cell: Vector2i = Vector2i(body.to_local(point).floor())
	for shape in body.shapes:
		var material: int = shape.get_pixel(cell.x, cell.y)
		if material != 0:
			return material
	return 0


## 局部网格 DDA：每个进入的像素只访问一次；第一处空洞停止，跨材料继续。
## 支撑已饱和且累计像素成本覆盖未经减伤的预算时，后续深度不再影响结果。
func _trace(body: PBody, origin: Vector2, direction: Vector2, world = null,
		budget: float = INF, player: bool = false) -> Array:
	var point: Vector2 = body.to_local(origin)
	var ray: Vector2 = direction.rotated(-body.rotation)
	var cell: Vector2i = Vector2i(floori(point.x), floori(point.y))
	var step: Vector2i = Vector2i(int(signf(ray.x)), int(signf(ray.y)))
	var delta: Vector2 = Vector2(INF if ray.x == 0.0 else absf(1.0 / ray.x), INF if ray.y == 0.0 else absf(1.0 / ray.y))
	var edge: Vector2 = Vector2(cell) + Vector2(1.0 if ray.x > 0.0 else 0.0, 1.0 if ray.y > 0.0 else 0.0)
	var next: Vector2 = Vector2(INF if ray.x == 0.0 else (edge.x - point.x) / ray.x, INF if ray.y == 0.0 else (edge.y - point.y) / ray.y)
	var path: Array = []
	var support: float = 0.0
	var cost: float = 0.0
	var surface: float = 0.0
	while true:
		var hit = null
		for shape in body.shapes:
			var material: int = shape.get_pixel(cell.x, cell.y)
			if material != 0:
				hit = {"shape": shape, "position": cell, "material": material}
				break
		if hit == null:
			return path
		path.append(hit)
		if world != null:
			var strength: float = world.material_strength(hit.material).x
			if player and strength <= 0.0:
				strength = reference_strength
			if surface == 0.0:
				surface = strength
			support += strength / surface if strength > 0.0 else support_max
			cost += strength if strength > 0.0 else INF
			if support >= support_max and cost >= budget:
				return path
		# 正好经过格点时同时跨两轴，不把仅触碰角点的邻格算作实体层。
		if is_equal_approx(next.x, next.y):
			cell += step
			next += delta
		elif next.x < next.y:
			cell.x += step.x
			next.x += delta.x
		else:
			cell.y += step.y
			next.y += delta.y
	return path


## 半像素步进保证不跨格；每段只改变方向，不增加破坏预算。
func _crack_path(body: PBody, origin: Vector2, direction: Vector2, world,
		budget: float, seed: int, mirror: float = 1.0) -> Array:
	var point: Vector2 = body.to_local(origin)
	var base: Vector2 = direction.rotated(-body.rotation).normalized()
	var ray: Vector2 = base
	var last: Vector2i = Vector2i(1 << 30, 1 << 30)
	var path: Array = []
	var cost: float = 0.0
	var turn: int = 0
	while true:
		var cell: Vector2i = Vector2i(point.floor())
		if cell != last:
			last = cell
			var hit = null
			for shape in body.shapes:
				var material: int = shape.get_pixel(cell.x, cell.y)
				if material != 0:
					hit = {"shape": shape, "position": cell, "material": material}
					break
			if hit == null:
				return path
			path.append(hit)
			var strength: float = world.material_strength(hit.material).x
			if strength <= 0.0:
				return path
			cost += strength
			if cost >= budget:
				return path
			if path.size() % crack_turn_pixels == 0:
				var angle: float = (_noise(seed, turn + 31) * 2.0 - 1.0) * crack_turn_degrees * mirror
				ray = base.rotated(deg_to_rad(angle))
				turn += 1
		point += ray * 0.5
	return path


func _noise(seed: int, index: int) -> float:
	var value: int = absi(seed % 2147483647)
	value = (value + (index + 1) * 48271) % 2147483647
	value = (value * 1103515245 + 12345) % 2147483647
	return float(value) / 2147483647.0


## 预留剪切入口；第一版不消费切向摩擦冲量。
func calculate_shear() -> void:
	pass
#endregion


#region 现有破坏接口
## 每个受损物体提交一次掩码，分片由引擎负责。
func commit(physics, removals: Dictionary) -> Dictionary:
	var profile_start: int = Time.get_ticks_usec() if profile_enabled else 0
	var changed: Array = []
	var removed: int = 0
	var fragments: int = 0
	for body in removals:
		var result: Dictionary = physics.fracture_pixels(body, removals[body], 0.0, true)
		removed += result.removed
		fragments += result.fragments.size()
		if result.removed > 0:
			changed.append(body)
			changed.append_array(result.fragments)
	if profile_enabled:
		_profile.commit_us = _profile.get("commit_us", 0) + Time.get_ticks_usec() - profile_start
		_profile.commit_calls = _profile.get("commit_calls", 0) + removals.size()
		_profile.removed_pixels = _profile.get("removed_pixels", 0) + removed
		_profile.fragments = _profile.get("fragments", 0) + fragments
	return {"changed": changed, "calls": removals.size()}
#endregion
