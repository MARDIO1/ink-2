extends Node
## 每个真实物理子步把求解冲量送给生物表现；击退已由 Rapier 完成。

func resolve_contacts(_context: Dictionary, contacts: Array) -> Dictionary:
	for contact in contacts:
		var first: WeakRef = contact.a.tags.get("monster_receiver")
		var second: WeakRef = contact.b.tags.get("monster_receiver")
		# 同一角色的部位可以互碰，但不能把自接触识别成受击。
		if first != null and second != null and first.get_ref() == second.get_ref():
			continue
		for side in [[contact.a, -1.0], [contact.b, 1.0]]:
			var receiver_ref: WeakRef = side[0].tags.get("monster_receiver")
			if receiver_ref == null:
				continue
			var receiver = receiver_ref.get_ref()
			if receiver == null or float(contact.approach) < receiver.minimum_hit_speed:
				continue
			var impulse := Vector2.ZERO
			var weighted_point := Vector2.ZERO
			var support_impulse := Vector2.ZERO
			var weight := 0.0
			for point in contact.points:
				var magnitude: float = maxf(float(point.get("impulse", 0.0)), 0.0)
				var normal: Vector2 = point.normal
				var tangent := Vector2(-normal.y, normal.x)
				var friction: float = float(point.get("tangent_impulse", 0.0))
				impulse += (normal * magnitude + tangent * friction) * float(side[1])
				support_impulse += normal * magnitude * float(side[1])
				weighted_point += point.position * magnitude
				weight += magnitude
			if weight > 0.001:
				var other = contact.b if side[0] == contact.a else contact.a
				# 地面支撑由真实接触求解产生扭转，但不关闭承重马达。
				# 避免回正落地再次触发松弛、倒地和回正的循环。
				# 支撑方向看法向冲量，而不是把地面摩擦也混进方向判断。
				# 大盾回正时鞋底滑动的摩擦很大，旧判断会把落地误报为新受击。
				var gravity: Vector2 = _context.get("world").gravity if _context.get("world") != null else Vector2.DOWN
				var up := -gravity.normalized() if not gravity.is_zero_approx() else Vector2.UP
				if other.is_static and support_impulse.normalized().dot(up) > 0.6:
					continue
				receiver.receive_contact_impact(weighted_point / weight, impulse)
	return {}
