#region 依赖与规则
extends Node
## 世界级碰撞结算。每个固定步先算双方，再统一删像素、分片和重建。
## 不保存像素余量；碎片只需 PBody，不需要额外挂载脚本。

const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")

## 以抓住 32×32 物块抬起再下砸校准：普通落下不删像素，完整下砸约一层。
var damage_scale: float = 0.012
var min_approach: float = 300.0
var support_max: float = 64.0
var thickness_scale: float = 0.5
var min_thickness_factor: float = 0.2
## 强度 0 表示不删像素；作为攻击方及玩家伤害的参考抗性仍需有限值。
var reference_strength: float = 100.0
var _elapsed: float = 0.0
var _main = null
var _player = null
var _protected: Array = []
@onready var _feet = $"../Player/PlayerInput"
@onready var _forces = get_node_or_null("../HUD/ForceDebug")
#endregion


#region 世界步进
func _ready() -> void:
	# 等父世界及 Player 完成初始化，再接管步进，避免同一帧推进两次。
	call_deferred("_start")


func _start() -> void:
	_main = get_parent()
	_player = _main.get_node("Player")
	_protected = [_player.get_node("Arm").body, _player.get_node("Arm/Hand").body]
	_main.set_physics_process(false)
	_main.world.contact_events_enabled = false
	process_physics_priority = _main.process_physics_priority + 1


func _physics_process(delta: float) -> void:
	if _main == null or not _main.auto_step:
		return
	_elapsed += delta
	var steps: int = 0
	while _elapsed >= _main.fixed_dt and steps < _main.max_substeps:
		var result: Dictionary = _step(_main.fixed_dt)
		_player.apply_collision_damage(result.player_damage)
		if not result.removals.is_empty():
			var nodes: Array = _main._body_nodes.duplicate()
			commit(_main.world, result.removals)
			_main.sync_world_bodies()
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
		# 内部连杆不可见，手已有三角形视觉；引擎 sync_world_bodies 尚未过滤自有视觉。
		var visible: Dictionary = _main._live_ids()
		for body in _protected:
			visible.erase(body.id)
		_main.renderer.prune(visible)
		for i in _main.world.bodies.size():
			var body = _main.world.bodies[i]
			var node = _main._body_nodes[i]
			if not body.is_static and not _protected.has(body) and (node == null or not _main.has_own_sprite(node)):
				_main.renderer.sync(body)


## 接触点必须匹配该子步的位姿；删除并集留到固定步末，避免重复重建。
func _step(delta: float) -> Dictionary:
	var physics = _main.world
	for body in physics.bodies:
		body.refresh_com()
	var count: int = physics._compute_substeps(delta)
	physics.last_substeps = count
	var result: Dictionary = {"removals": {}, "player_damage": 0.0}
	for i in count:
		physics.contacts.clear()
		physics._substep_rapier(delta / count)
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
	return result
#endregion


#region 碰撞结算
## 返回 {removals: {PBody: {PixelShape: {Vector2i: true}}}, player_damage: float}。
## 重叠删除取并集；每条 lane 独立消费预算，未满一个像素的余量舍弃。
func calculate(world, player_body: PBody = null, protected_bodies: Array = []) -> Dictionary:
	var result: Dictionary = {"removals": {}, "player_damage": 0.0}
	var contacts: Array = _contacts(world)
	if is_instance_valid(_forces):
		_forces.sample_contacts(contacts, _main.fixed_dt / world.last_substeps)
	if is_instance_valid(_feet):
		_feet.update_support(contacts)
	for contact in contacts:
		if contact.approach <= min_approach:
			continue
		for lane in _lanes(contact.points):
			var point: Vector2 = lane.position
			var normal: Vector2 = lane.normal
			var a_origin: Vector2 = point - normal * 0.001
			var b_origin: Vector2 = point + normal * (maxf(lane.dist, 0.0) + 0.001)
			var a_material: int = _material_at(contact.a, a_origin)
			var b_material: int = _material_at(contact.b, b_origin)
			if a_material == 0 or b_material == 0:
				continue
			for side in [[contact.a, a_origin, -normal, a_material, b_material],
					[contact.b, b_origin, normal, b_material, a_material]]:
				var body: PBody = side[0]
				if protected_bodies.has(body):
					continue
				var strength: float = world.material_strength(side[3]).x
				if strength <= 0.0 and body != player_body:
					continue
				strength = strength if strength > 0.0 else reference_strength
				var attacker: float = world.material_strength(side[4]).x
				attacker = attacker if attacker > 0.0 else reference_strength
				var budget: float = damage_scale * lane.impulse * attacker / strength
				if body != player_body and budget < strength:
					continue  # 连第一层都删不掉，不必扫描厚度。
				var path: Array = _trace(body, side[1], side[2], world, 0.0 if body == player_body else budget, body == player_body)
				_damage_side(world, body, path, side[4], lane.impulse, player_body, protected_bodies, result)
	return result


func _damage_side(world, body: PBody, path: Array, attacker_material: int,
		impulse: float, player_body: PBody, protected_bodies: Array, result: Dictionary) -> void:
	if protected_bodies.has(body):
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


## 同法线点投影到切线，两端间按像素宽度分配；总冲量严格归一。
## 当前 collider 是矩形，通常只有 1～2 点；不同法线分组，避免跨拐角连线。
func _lanes(points: Array) -> Array:
	var groups: Dictionary = {}
	for point in points:
		if point.impulse <= 0.0:
			continue
		var normal: Vector2 = point.normal
		var key: Vector2i = Vector2i(roundi(normal.x * 1000.0), roundi(normal.y * 1000.0))
		if not groups.has(key):
			groups[key] = []
		groups[key].append(point)
	var lanes: Array = []
	for group in groups.values():
		var normal: Vector2 = group[0].normal
		var tangent: Vector2 = Vector2(-normal.y, normal.x)
		group.sort_custom(func(a, b): return a.position.dot(tangent) < b.position.dot(tangent))
		var first: Dictionary = group[0]
		var last: Dictionary = group[-1]
		var total: float = 0.0
		for point in group:
			total += point.impulse
		var count: int = maxi(1, ceili(first.position.distance_to(last.position)))
		var weight_sum: float = count * (first.impulse + last.impulse) * 0.5
		for i in count:
			var t: float = (float(i) + 0.5) / float(count)
			lanes.append({"position": first.position.lerp(last.position, t), "normal": normal,
				"dist": lerpf(first.dist, last.dist, t), "impulse": total * lerpf(first.impulse, last.impulse, t) / weight_sum})
	return lanes
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


## 预留剪切入口；第一版不消费切向摩擦冲量。
func calculate_shear() -> void:
	pass
#endregion


#region 现有破坏接口
## 每个受损物体提交一次掩码，分片由引擎负责。
func commit(physics, removals: Dictionary) -> Dictionary:
	var changed: Array = []
	for body in removals:
		var result: Dictionary = physics.fracture_pixels(body, removals[body], 0.0)
		if result.removed > 0:
			# 新接口未传材质摩擦/弹性回调；用公开接口恢复，避免破坏后手感改变。
			if result.body_alive:
				physics.refresh_mass(body)
			for fragment in result.fragments:
				fragment.collision_layer = body.collision_layer
				fragment.collision_mask = body.collision_mask
				fragment.gravity_scale = body.gravity_scale
				# 保持原规则：地形断开的块成为可下落的物体。
				if fragment.is_static:
					fragment.is_static = false
					physics.refresh_mass(fragment)
			changed.append(body)
			changed.append_array(result.fragments)
	return {"changed": changed, "calls": removals.size()}
#endregion
