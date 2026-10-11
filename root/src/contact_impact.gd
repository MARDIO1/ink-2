class_name ContactImpact
extends RefCounted
## 碰撞接触的只读归一化工具；伤害和反馈共用同一套接触点合并与材质采样。


#region 接触摘要
static func summarize(points: Array) -> Dictionary:
	var total := 0.0
	var position := Vector2.ZERO
	var normal := Vector2.ZERO
	var dist := 0.0
	for point in points:
		var impulse: float = float(point.get("impulse", 0.0))
		if impulse <= 0.0:
			continue
		total += impulse
		position += Vector2(point.get("position", Vector2.ZERO)) * impulse
		normal += Vector2(point.get("normal", Vector2.ZERO)) * impulse
		dist += float(point.get("dist", 0.0)) * impulse
	if total <= 0.0 or normal.is_zero_approx():
		return {}
	normal = normal.normalized()
	var tangent := Vector2(-normal.y, normal.x)
	var first := INF
	var last := -INF
	for point in points:
		if float(point.get("impulse", 0.0)) > 0.0:
			first = minf(first, Vector2(point.get("position", Vector2.ZERO)).dot(tangent))
			last = maxf(last, Vector2(point.get("position", Vector2.ZERO)).dot(tangent))
	var width := maxi(1, ceili(last - first))
	return {"position": position / total, "normal": normal, "dist": dist / total,
		"width": width, "impulse": total / float(width), "total_impulse": total}


static func build_event(contact) -> Dictionary:
	var impact := summarize(contact.points)
	if impact.is_empty():
		return {}
	var normal: Vector2 = impact.normal
	var a_origin: Vector2 = impact.position - normal * 0.001
	var b_origin: Vector2 = impact.position + normal * (maxf(impact.dist, 0.0) + 0.001)
	var reduced_mass := _reduced_mass(contact.a, contact.b)
	var approach := maxf(float(contact.approach), 0.0)
	impact.merge({
		"approach": approach,
		"energy": 0.5 * reduced_mass * approach * approach,
		"reduced_mass": reduced_mass,
		"a_body": contact.a,
		"b_body": contact.b,
		"a_material": material_at(contact.a, a_origin),
		"b_material": material_at(contact.b, b_origin),
	})
	return impact
#endregion


#region 物理属性
static func material_at(body, point: Vector2) -> int:
	if body == null:
		return 0
	var cell := Vector2i(body.to_local(point).floor())
	for shape in body.shapes:
		var material: int = shape.get_pixel(cell.x, cell.y)
		if material != 0:
			return material
	return 0


static func dust_bodies(world, player_body, protected_bodies: Array) -> Dictionary:
	var out: Dictionary = {}
	if world == null or world.ccd_ignore_mass <= 0.0:
		return out
	var interactive: Dictionary = world._interactive_bodies()
	for body in world.bodies:
		if body == player_body or protected_bodies.has(body) or body.is_static or body.frozen:
			continue
		if body.mass <= world.ccd_ignore_mass and not interactive.has(body):
			out[body] = true
	return out


static func _reduced_mass(a, b) -> float:
	if a == null or b == null or (a.is_static and b.is_static):
		return 0.0
	if a.is_static:
		return maxf(float(b.mass), 0.0)
	if b.is_static:
		return maxf(float(a.mass), 0.0)
	var total := maxf(float(a.mass), 0.0) + maxf(float(b.mass), 0.0)
	return 0.0 if total <= 0.0 else float(a.mass) * float(b.mass) / total
#endregion
