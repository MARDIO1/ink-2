extends Node
## 碰撞伤害规则：把已求解的接触或外部冲量转换为删除计划和玩家伤害。
## 不推进世界、不提交破坏，也不依赖场景节点。

#region 依赖与配置
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const LIVING_TAG := "living"
const ContactImpact := preload("res://root/src/contact_impact.gd")

## 以抓住 32×32 物块抬起再下砸校准：普通落下不删像素，完整下砸约一层。
## 碰撞冲量转为破坏预算的倍率；越大越容易删像素。
@export var damage_scale: float = 0.012
## 玩家生命扣除倍率；只放大最终黑墨损失，不改变材料裂纹、删除预算或冲量。
@export var player_damage_multiplier: float = 100.0
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
#endregion


#region 规则接口
## 注册为伤害服务，供其他玩法规则通过上下文调用，不要求知道本脚本路径。
func service_name() -> StringName:
	return &"damage"


## 接收协调层提供的接触帧，并转换成统一效果包。
func resolve_contacts(context: Dictionary, contacts: Array) -> Dictionary:
	return calculate(context.world, contacts, context.player_body, context.protected_bodies)
#endregion


#region 碰撞结算
## 返回删除计划、玩家总伤害和逐次 player_impacts（供受击表现读取）。
## 重叠删除取并集；每条 lane 独立消费预算，未满一个像素的余量舍弃。
func calculate(world, contacts: Array, player_body: PBody = null, protected_bodies: Array = []) -> Dictionary:
	var result: Dictionary = {"removals": {}, "player_damage": 0.0, "player_impacts": []}
	# 轻碎片豁免：一个子步只建一次集合，别在每对接触上重建（见 _dust_bodies）。
	var dust: Dictionary = ContactImpact.dust_bodies(world, player_body, protected_bodies)
	for contact in contacts:
		# 只负责落地的物体保留真实碰撞，但不触发通用撞击破坏。
		if contact.a.tags.has("no_impact_damage") or contact.b.tags.has("no_impact_damage"):
			continue
		if contact.approach <= min_approach:
			continue
		# 同伴与自己的部件不会互相撕裂盾牌；真实碰撞约束仍保留。
		if contact.a.tags.has("monster_receiver") and contact.b.tags.has("monster_receiver"):
			continue
		# 敌人落地的承重冲量不能切掉脚下地面或盾牌底缘，否则每次回正
		# 都会改变支撑几何，形成塌地、再落地和弹起的循环。
		if (contact.a.tags.has("monster_receiver") and contact.b.is_static) \
			or (contact.b.tags.has("monster_receiver") and contact.a.is_static):
			continue
		# 两头都是灰尘：两侧都被豁免，连冲量合成都不必算。
		if dust.has(contact.a) and dust.has(contact.b):
			continue
		var impact: Dictionary = ContactImpact.summarize(contact.points)
		if impact.is_empty():
			continue
		var point: Vector2 = impact.position
		var normal: Vector2 = impact.normal
		var a_origin: Vector2 = point - normal * 0.001
		var b_origin: Vector2 = point + normal * (maxf(impact.dist, 0.0) + 0.001)
		var a_material: int = ContactImpact.material_at(contact.a, a_origin)
		var b_material: int = ContactImpact.material_at(contact.b, b_origin)
		if a_material == 0 or b_material == 0:
			continue
		for side in [[contact.a, a_origin, -normal, a_material, b_material, -1.0],
				[contact.b, b_origin, normal, b_material, a_material, 1.0]]:
			var body: PBody = side[0]
			# 玩家用生命值结算；其他生物的物理壳只负责阻挡和受力，不参与像素碎裂。
			if body != player_body and body.tags.has(LIVING_TAG):
				continue
			if protected_bodies.has(body) or dust.has(body):
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
	return result


## 轻碎片豁免：阈值直接用世界的 ccd_ignore_mass（0 = 关，引擎默认），与引擎
## _exempt_bodies()（pworld.gd:1488）是同一个「灰尘」定义 —— 引擎既然不为「质量 <= 它」
## 的刚体做防穿（一个 2x2 碎片就能逼全世界跑 334 子步，pworld.gd:93-103），也就不必为
## 它们跑 _trace()/_damage_side() 那趟逐层厚度扫描；calculate() 是每个子步跑一次的
## （_step 的子步循环里），碎块一多这趟扫描就是纯开销。
## 豁免只针对「被撞的一方」；玩家、手臂/手、抓着的、挂关节的一律不在集合里
## （与引擎 _exempt_bodies() 末尾 erase(_interactive_bodies()) 同义）。
func _dust_bodies(world, player_body: PBody, protected_bodies: Array) -> Dictionary:
	return ContactImpact.dust_bodies(world, player_body, protected_bodies)


## 按厚度、材料强度和裂纹分支消耗单侧冲量预算。
func _damage_side(world, body: PBody, path: Array, attacker_material: int,
		impulse: float, player_body: PBody, protected_bodies: Array, result: Dictionary,
		origin: Vector2 = Vector2.INF, direction: Vector2 = Vector2.ZERO, seed: int = 0,
		mirror: float = 1.0) -> void:
	if protected_bodies.has(body) or path.is_empty():
		return
	var surface_strength: float = path[0].strength if path[0].has("strength") else world.material_strength(path[0].material).x
	if surface_strength <= 0.0:
		if body != player_body:
			return
		surface_strength = reference_strength
	var attacker_strength: float = world.material_strength(attacker_material).x
	if attacker_strength <= 0.0:
		attacker_strength = reference_strength
	var support: float = path[0].get("support", 0.0)
	if not path[0].has("support"):
		for pixel in path:
			var strength: float = pixel.strength if pixel.has("strength") else world.material_strength(pixel.material).x
			if body == player_body and strength <= 0.0:
				strength = reference_strength
			# 无厚度摘要的外部路径仍兼容原接口。
			support = minf(support_max, support + (strength / surface_strength if strength > 0.0 else support_max))
			if support >= support_max:
				break
	var factor: float = min_thickness_factor + (1.0 - min_thickness_factor) / (1.0 + thickness_scale * log(1.0 + support))
	var budget: float = damage_scale * impulse * attacker_strength / surface_strength * factor
	if body == player_body:
		# InkHealth 以像素计量；普通材料会用 budget / strength 个等效像素消费预算，
		# 玩家不删形状；倍率只调生命损失，不反向改变通用材料破坏。
		var damage: float = budget / surface_strength * maxf(player_damage_multiplier, 0.0)
		result.player_damage += damage
		if damage > 0.0:
			if not result.has("player_impacts"):
				result.player_impacts = []
			result.player_impacts.append({
				"position": origin,
				"normal": -direction.normalized() if not direction.is_zero_approx() else Vector2.ZERO,
				"amount": damage,
				"impulse": impulse,
				"attacker_material": attacker_material,
			})
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
		_crack_path(body, origin, direction.rotated(angle), world,
			branch_budget, seed + i * 97, mirror, result)


## 根据等效像素预算选择一到四条主裂纹。
func _crack_count(pixel_budget: float) -> int:
	return clampi(1 + floori(maxf(0.0, pixel_budget - 1.0) / crack_pixels_per_branch), 1, crack_max_count)


## 沿给定路径逐像素消费材料成本，并把成功删除的像素并入效果包。
func _consume_path(world, body: PBody, path: Array, budget: float, result: Dictionary) -> void:
	for pixel in path:
		var cost: float = pixel.strength if pixel.has("strength") else world.material_strength(pixel.material).x
		if cost <= 0.0 or budget < cost:
			break
		budget -= cost
		if not result.removals.has(body):
			result.removals[body] = {}
		if not result.removals[body].has(pixel.shape):
			result.removals[body][pixel.shape] = {}
		result.removals[body][pixel.shape][pixel.position] = true
#endregion


#region 像素路径
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
			if world != null and not path.is_empty():
				path[0].support = minf(support_max, support)
			return path
		path.append(hit)
		if world != null:
			var strength: float = world.material_strength(hit.material).x
			hit.strength = strength
			if player and strength <= 0.0:
				strength = reference_strength
			if surface == 0.0:
				surface = strength
			support += strength / surface if strength > 0.0 else support_max
			cost += strength if strength > 0.0 else INF
			if support >= support_max and cost >= budget:
				path[0].support = support_max
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
		budget: float, seed: int, mirror: float = 1.0, result: Dictionary = {}) -> Array:
	var point: Vector2 = body.to_local(origin)
	var base: Vector2 = direction.rotated(-body.rotation).normalized()
	var ray: Vector2 = base
	var last: Vector2i = Vector2i(1 << 30, 1 << 30)
	var path: Array = []
	var cost: float = 0.0
	var turn: int = 0
	var visited: int = 0
	var remaining: float = budget
	var write_removals: bool = result.has("removals")
	while true:
		var cell: Vector2i = Vector2i(point.floor())
		if cell != last:
			last = cell
			var hit_shape = null
			var hit_material: int = 0
			for shape in body.shapes:
				var material: int = shape.get_pixel(cell.x, cell.y)
				if material != 0:
					hit_shape = shape
					hit_material = material
					break
			if hit_shape == null:
				return path
			var strength: float = world.material_strength(hit_material).x
			visited += 1
			if not write_removals:
				path.append({"shape": hit_shape, "position": cell,
					"material": hit_material, "strength": strength})
			if strength <= 0.0:
				return path
			if write_removals:
				# 沿裂纹只查询一次材料；预算足够才加入删除计划，不再生成/消费路径。
				if remaining < strength:
					return path
				remaining -= strength
				if not result.removals.has(body):
					result.removals[body] = {}
				if not result.removals[body].has(hit_shape):
					result.removals[body][hit_shape] = {}
				result.removals[body][hit_shape][cell] = true
			cost += strength
			if cost >= budget:
				return path
			if visited % crack_turn_pixels == 0:
				var angle: float = (_noise(seed, turn + 31) * 2.0 - 1.0) * crack_turn_degrees * mirror
				ray = base.rotated(deg_to_rad(angle))
				turn += 1
		point += ray * 0.5
	return path


## 生成与撞击位置绑定的确定性伪随机数，保证裂纹可复现。
func _noise(seed: int, index: int) -> float:
	var value: int = absi(seed % 2147483647)
	value = (value + (index + 1) * 48271) % 2147483647
	value = (value * 1103515245 + 12345) % 2147483647
	return float(value) / 2147483647.0


## 颜色规则共用的伤害入口。direction 指向刚体内部，冲量预算沿现有裂纹算法消费。
func apply_impulse_damage(world, body: PBody, origin: Vector2, direction: Vector2,
		impulse: float, player_body: PBody, protected_bodies: Array,
		result: Dictionary, attacker_material: int = 0) -> void:
	if body == null or protected_bodies.has(body) or direction.is_zero_approx() or impulse <= 0.0:
		return
	# 爆炸射线沿同一血量入口伤害生物，不把躯干/四肢当墨水打碎。
	# 盾牌不带 living 标记，继续走原来的可破坏像素逻辑；打盾不扣本体血。
	var monster_ref: WeakRef = body.tags.get("monster_receiver")
	var monster = monster_ref.get_ref() if monster_ref != null else null
	if monster != null and body.tags.has(LIVING_TAG):
		monster.apply_damage(impulse * monster.contact_damage_scale, body)
		return
	var strength: float = world.material_strength(ContactImpact.material_at(body, origin)).x
	if strength <= 0.0 and body != player_body:
		return
	strength = strength if strength > 0.0 else reference_strength
	var attacker: float = world.material_strength(attacker_material).x
	attacker = attacker if attacker > 0.0 else reference_strength
	var budget: float = damage_scale * impulse * attacker / strength
	if body != player_body and budget < strength:
		return
	var path: Array = _trace(body, origin, direction.normalized(), world,
		0.0 if body == player_body else budget, body == player_body)
	_damage_side(world, body, path, attacker_material, impulse, player_body, protected_bodies, result,
		origin, direction.normalized(), hash(Vector3(origin.x, origin.y, impulse)))

#endregion
