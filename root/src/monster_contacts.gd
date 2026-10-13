extends Node
## 每个真实物理子步把求解冲量送给生物表现；击退已由 Rapier 完成。

## 重力支撑不等于攻击；真正的高速踩踏只在接触开始时结算。
const STOMP_SPEED := 180.0
const CONTACT_RELEASE_TIME := 0.12
const CONTACT_CACHE_TIME := 0.5
var _contact_time := 0.0
var _next_cleanup := 0.0
var _world_id := 0
var _contact_pairs: Dictionary = {}

func resolve_contacts(_context: Dictionary, contacts: Array) -> Dictionary:
	var world = _context.get("world")
	var world_id: int = world.get_instance_id() if world != null else 0
	if world_id != _world_id:
		_contact_pairs.clear()
		_world_id = world_id
	var delta: float = world.fixed_dt / maxf(float(world.last_substeps), 1.0) if world != null else 1.0 / 60.0
	_contact_time += delta
	if _contact_time >= _next_cleanup:
		for key in _contact_pairs:
			if _contact_time - float(_contact_pairs[key]) > CONTACT_CACHE_TIME:
				_contact_pairs.erase(key)
		_next_cleanup = _contact_time + CONTACT_CACHE_TIME
	var gravity: Vector2 = world.gravity if world != null else Vector2.DOWN
	var down := gravity.normalized() if not gravity.is_zero_approx() else Vector2.DOWN
	var player_body = _context.get("player_body")
	for contact in contacts:
		var first: WeakRef = contact.a.tags.get("monster_receiver")
		var second: WeakRef = contact.b.tags.get("monster_receiver")
		# 同一角色或同伴的挤靠只由物理求解，不是攻击；否则出生时
		# 盾牌与邻兵的重叠会反复触发扣血、松弛与回正。
		if first != null and second != null:
			continue
		if (first == null and second == null) or contact.points.is_empty():
			continue
		var key := Vector2i(mini(contact.a.id, contact.b.id), maxi(contact.a.id, contact.b.id))
		var new_impact: bool = not _contact_pairs.has(key) or _contact_time - float(_contact_pairs[key]) > CONTACT_RELEASE_TIME
		_contact_pairs[key] = _contact_time
		if not new_impact:
			continue
		var normal: Vector2 = contact.points[0].normal
		# 玩家躯干与敌人之间的竖向接触通常是站立承重。接近速度会包含
		# 重力和敌人的回正速度，不能单靠它判定攻击；高速主动落下除外。
		if (contact.a == player_body or contact.b == player_body) and absf(normal.dot(down)) > 0.6:
			var incoming: Vector2 = Vector2(player_body.pre_vx, player_body.pre_vy)
			if incoming.dot(down) < STOMP_SPEED or float(contact.approach) < STOMP_SPEED:
				continue
		for side_index in 2:
			var hit_body = contact.a if side_index == 0 else contact.b
			var other = contact.b if side_index == 0 else contact.a
			var sign := -1.0 if side_index == 0 else 1.0
			var receiver_ref: WeakRef = first if side_index == 0 else second
			if receiver_ref == null:
				continue
			var receiver = receiver_ref.get_ref()
			if receiver == null or receiver._dead or receiver._hit_cooldown > 0.0 or float(contact.approach) < receiver.minimum_hit_speed:
				continue
			if other.is_static and (normal * sign).dot(-down) > 0.6:
				continue
			var impulse := Vector2.ZERO
			var weighted_point := Vector2.ZERO
			var weight := 0.0
			for point in contact.points:
				var magnitude: float = maxf(float(point.get("impulse", 0.0)), 0.0)
				var point_normal: Vector2 = point.normal
				var tangent := Vector2(-point_normal.y, point_normal.x)
				var friction: float = float(point.get("tangent_impulse", 0.0))
				impulse += (point_normal * magnitude + tangent * friction) * sign
				weighted_point += point.position * magnitude
				weight += magnitude
			if weight > 0.001:
				receiver.receive_contact_impact(weighted_point / weight, impulse, hit_body, not other.is_static)
	return {}
