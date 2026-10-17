extends Node
## 白墨先作为真实刚体落地；首次接触后变成无碰撞附着物，缓慢消耗自身并腐蚀目标。

#region 配置与状态
const Palette := preload("res://ink/general/src/ink_palette.gd")
const ContactImpact := preload("res://root/src/contact_impact.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const Traits := preload("res://ink/general/src/ink_traits.gd")

@export_group("附着腐蚀")
@export var corrosion_pixels_per_second: float = 80.0
@export var corrosion_interval: float = 0.12
@export var corrosion_pixels_per_batch: int = 12
@export var corrosion_yield: float = 3.0
@export var player_damage_per_second: float = 20.0
@export var max_travel_from_spawn: float = 4096.0

var _delta := 0.0
var _whites: Array = []
var _previous: Dictionary = {}
var _attached: Dictionary = {}
var _profile_enabled := false
var _profile: Dictionary = {}
#endregion


#region 规则接口
func prepare_fixed(context: Dictionary, delta: float) -> void:
	_delta = delta
	_whites.clear()
	_previous.clear()
	for body in context.world.bodies:
		if not body.tags.has("white_ink") or body.tags.has("white_sweep") or body.is_static \
		or body.tags.get("editor_physics_paused", false):
			continue
		_whites.append(body)
		_previous[body] = Transform2D(body.rotation, body.position)
		body.tags.get_or_add("white_origin", body.position)
		if _attached.has(body):
			body.gravity_scale = 0.0
			body.linear_velocity = Vector2.ZERO
			body.angular_velocity = 0.0
			body.clear_forces()


## 接触只负责把飞行白墨切换为附着态；腐蚀留到固定步限速执行。
func resolve_contacts(context: Dictionary, contacts: Array) -> Dictionary:
	for contact in contacts:
		var white = null
		var target = null
		var sign := 0.0
		if _is_flying_white(contact.a):
			white = contact.a
			target = contact.b
			sign = 1.0
		elif _is_flying_white(contact.b):
			white = contact.b
			target = contact.a
			sign = -1.0
		var player_contact: bool = target == context.get("player_body") \
			or context.protected_bodies.has(target)
		if white == null or not _valid_target(context, target, player_contact):
			continue
		var impact: Dictionary = ContactImpact.summarize(contact.points)
		if impact.is_empty():
			continue
		var tangent := Vector2(-impact.normal.y, impact.normal.x)
		var width := maxf(float(impact.width), absf(tangent.x) * white.aabb.size.x
			+ absf(tangent.y) * white.aabb.size.y)
		if _attach(context.world, white, target, impact.position, impact.normal * sign,
			width, player_contact):
			_profile["attachments"] = _profile.get("attachments", 0) + 1
			if player_contact:
				_profile["player_attachments"] = _profile.get("player_attachments", 0) + 1
	return {}


func resolve_fixed(context: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result := {"removals": {}, "carves": {}}
	var player_attached := false
	var yellow = context.services.get(&"yellow")
	for white in _whites.duplicate():
		if not context.world.bodies.has(white):
			_attached.erase(white)
			continue
		if _touch_yellow(white, yellow):
			_consume_loose(white, 1)
		if _area(white) == 0:
			_remove(context, white)
			continue
		if not _attached.has(white):
			if white.position.distance_to(white.tags.white_origin) > max_travel_from_spawn:
				_remove(context, white)
			continue
		var state: Dictionary = _attached[white]
		var target = state.target
		if not context.world.bodies.has(target):
			_detach(white)
			continue
		if state.player:
			player_attached = true
			_consume_by_rate(context, white, state,
				corrosion_pixels_per_second / maxf(corrosion_yield, 0.001))
			continue
		state.elapsed += _delta
		state.credit += corrosion_pixels_per_second * _delta
		if state.elapsed < maxf(corrosion_interval, _delta):
			continue
		state.elapsed = 0.0
		var amount := mini(int(state.credit), maxi(1, corrosion_pixels_per_batch))
		if amount <= 0:
			continue
		var removed := _corrode(context, state, amount, result.carves)
		state.credit -= removed
		if removed > 0:
			_consume_loose(white, maxi(1, ceili(removed / maxf(corrosion_yield, 0.001))))
			_profile["erased_pixels"] = _profile.get("erased_pixels", 0) + removed
		else:
			# 已经蚀穿薄物体时不留下永久白块，仍按同一固定速率耗尽燃料。
			state.credit -= amount
			_consume_loose(white, maxi(1, ceili(amount / maxf(corrosion_yield, 0.001))))
		if _area(white) == 0:
			_remove(context, white)
	if player_attached:
		var player = context.get("player_node")
		if player != null:
			player.apply_corrosion_damage(player_damage_per_second * _delta)
	if not result.carves.is_empty():
		_clear_undo(context)
	if _profile_enabled:
		_profile["active_white"] = _attached.size()
		_profile["resolve_us"] = _profile.get("resolve_us", 0) + Time.get_ticks_usec() - started
	return result


func _exit_tree() -> void:
	_previous.clear()
	_whites.clear()
	_attached.clear()
#endregion


#region 附着
func _is_flying_white(body) -> bool:
	return body != null and body.tags.has("white_ink") and not body.is_static \
		and not _attached.has(body)


func _valid_target(context: Dictionary, target, player_contact: bool) -> bool:
	if target == null or target.tags.has("white_ink"):
		return false
	if Traits.is_unbreakable(target):
		return false
	if target.tags.has("living") and not player_contact:
		return false
	# 是否可腐蚀由接触点附近的局部采样决定，不扫描整块目标。
	return true


func _attach(world, white, target, point: Vector2, direction: Vector2, width: float,
		player_contact := false) -> bool:
	var local_direction: Vector2 = direction.rotated(-target.rotation).normalized()
	if local_direction.is_zero_approx():
		return false
	var seeds: Array = []
	var used: Dictionary = {}
	# 接触跨度内每个实际命中目标的像素都是入口，不再按整块刚体限制种子数。
	var count := maxi(1, ceili(width) + 1)
	var tangent := Vector2(-direction.y, direction.x).normalized()
	for index in count:
		var offset := 0.0 if count == 1 else remap(float(index), 0.0,
			float(count - 1), -width * 0.5, width * 0.5)
		var sample_world := point + tangent * offset
		if not _has_solid_near(white, white.to_local(sample_world - direction * 0.5),
			-direction, 3):
			continue
		var start: Dictionary = _find_solid(target, target.to_local(sample_world),
			local_direction, 8, player_contact)
		if start.is_empty() or used.has(start.cell):
			continue
		used[start.cell] = true
		var cell_salt: int = int(start.cell.x) * 73856093 ^ int(start.cell.y) * 19349663
		seeds.append({"root": Vector2(start.cell) + Vector2.ONE * 0.5,
			"direction": local_direction, "depth": 0, "step": 0,
			"activity": 1 + _noise_index(white.id + target.id, cell_salt, 4)})
	if seeds.is_empty():
		return false
	white.collision_layer = 0
	white.collision_mask = 0
	white.gravity_scale = 0.0
	white.linear_velocity = Vector2.ZERO
	white.angular_velocity = 0.0
	white.clear_forces()
	var joint = world.add_weld(white, target, point)
	if joint != null:
		joint.contacts_enabled = false
	_attached[white] = {
		"white": white, "target": target, "joint": joint, "seeds": seeds,
		"cursor": 0, "seed": white.id * 97 + target.id, "elapsed": 0.0, "credit": 0.0,
		"player": player_contact,
	}
	white.tags["white_attached"] = true
	return true


func _detach(white) -> void:
	_attached.erase(white)
	white.tags.erase("white_attached")
	white.collision_layer = 1
	white.collision_mask = 0xFFFFFFFF
	white.gravity_scale = 1.0
	white.linear_velocity = Vector2.ZERO
	white.angular_velocity = 0.0
#endregion


#region 腐蚀
func _corrode(_context: Dictionary, state: Dictionary, amount: int,
		removals: Dictionary) -> int:
	var target = state.target
	var seeds: Array = state.seeds
	var plan: Dictionary = removals.get_or_add(target, {})
	var added := 0
	var stalled := 0
	while added < amount and stalled < seeds.size() * 3:
		var index := _organic_seed_index(seeds, int(state.seed), int(state.cursor))
		var seed: Dictionary = seeds[index]
		var bite_limit := mini(1 + _noise_index(int(state.seed), int(seed.step), 4),
			amount - added)
		var bite := _bite(target, seed, int(state.seed) + index * 97,
			bite_limit, plan)
		state.cursor = (index + 1) % seeds.size()
		state.seed = int(state.seed) + 193
		if bite == 0:
			seed.depth = int(seed.depth) + 1 + _noise_index(int(state.seed), index, 2)
			stalled += 1
		else:
			added += bite
			stalled = 0
	_mark_corrosion(target, plan)
	return added


func _bite(target, seed: Dictionary, noise_seed: int, limit: int,
		plan: Dictionary) -> int:
	var inward := _cardinal(seed.direction)
	var side := Vector2i(-inward.y, inward.x)
	var jitter := _noise_index(noise_seed, int(seed.step) * 29, 3) - 1
	var wanted := Vector2i((seed.root + Vector2(inward * int(seed.depth)
		+ side * jitter)).floor())
	var center := _nearby_erodible(target, wanted, inward, side, plan)
	if center.x == 1 << 30:
		return 0
	var offsets := [Vector2i.ZERO, inward, side, -side,
		inward + side, inward - side, -inward]
	var added := 0
	var start := _noise_index(noise_seed, int(seed.step) * 41, offsets.size())
	var stride: int = [2, 3, 5][_noise_index(noise_seed, int(seed.step) * 53, 3)]
	for turn in offsets.size():
		var offset: Vector2i = offsets[(start + turn * stride) % offsets.size()]
		added += _add_erodible(target, center + offset, plan)
		if added >= limit:
			break
	seed.depth = int(seed.depth) + 1 + _noise_index(noise_seed, int(seed.step) * 73, 3)
	seed.step = int(seed.step) + 1
	return added


static func _organic_seed_index(seeds: Array, noise_seed: int, cursor: int) -> int:
	var best := posmod(cursor, seeds.size())
	var best_score := -(1 << 30)
	# 在接触面上做小规模随机竞选，让活跃孔洞先向内钻，避免整条边同步推进。
	var samples := mini(seeds.size(), 7)
	for turn in samples:
		var index := _noise_index(noise_seed, cursor * 31 + turn * 101, seeds.size())
		var seed: Dictionary = seeds[index]
		var score := int(seed.activity) * 5 - int(seed.depth) \
			+ _noise_index(noise_seed, int(seed.step) * 67 + turn, 11)
		if score > best_score:
			best_score = score
			best = index
	return best


func _nearby_erodible(body, wanted: Vector2i, inward: Vector2i, side: Vector2i,
		plan: Dictionary) -> Vector2i:
	for depth in 3:
		for lateral in [0, 1, -1, 2, -2]:
			var cell: Vector2i = wanted + inward * int(depth) + side * int(lateral)
			if _is_erodible_unplanned(body, cell, plan):
				return cell
	return Vector2i(1 << 30, 1 << 30)


func _is_erodible_unplanned(body, cell: Vector2i, plan: Dictionary) -> bool:
	for shape in body.shapes:
		if _erodible(shape.get_pixel(cell.x, cell.y)) \
		and not plan.get(shape, {}).has(cell):
			return true
	return false


static func _cardinal(direction: Vector2) -> Vector2i:
	if absf(direction.x) >= absf(direction.y):
		return Vector2i(int(signf(direction.x)), 0)
	return Vector2i(0, int(signf(direction.y)))


static func _noise_index(seed: int, salt: int, size: int) -> int:
	return posmod((seed + salt) * 1103515245 + 12345, 2147483647) % size


func _add_erodible(body, cell: Vector2i, plan: Dictionary) -> int:
	for shape in body.shapes:
		if _erodible(shape.get_pixel(cell.x, cell.y)):
			var mask: Dictionary = plan.get_or_add(shape, {})
			if not mask.has(cell):
				mask[cell] = true
				return 1
	return 0


func _find_solid(body, point: Vector2, direction: Vector2, steps: int,
		any_material := false) -> Dictionary:
	var cursor := point
	for unused in steps * 2 + 1:
		var cell := Vector2i(cursor.floor())
		for shape in body.shapes:
			var material: int = shape.get_pixel(cell.x, cell.y)
			if material != 0 and (any_material or _erodible(material)):
				return {"shape": shape, "cell": cell}
		cursor += direction * 0.5
	return {}


static func _has_solid_near(body, point: Vector2, direction: Vector2,
		steps: int) -> bool:
	var cursor := point
	for unused in steps * 2 + 1:
		var cell := Vector2i(cursor.floor())
		for shape in body.shapes:
			if shape.get_pixel(cell.x, cell.y) != 0:
				return true
		cursor += direction * 0.5
	return false


static func _mark_corrosion(body, plan: Dictionary) -> void:
	var marked: Dictionary = body.tags.get_or_add("white_corrosion", {})
	for shape in plan:
		marked.get_or_add(shape, {}).merge(plan[shape], true)


## 红墨观察完成且结构已经提交后，清掉本轮的局部反应豁免。
func observe_fracture(_world, body, _pieces: Array) -> void:
	body.tags.erase("white_corrosion")


func _consume_by_rate(context: Dictionary, white, state: Dictionary, rate: float) -> void:
	state.credit += rate * _delta
	var amount := int(state.credit)
	if amount <= 0:
		return
	state.credit -= amount
	_consume_loose(white, amount)
	if _area(white) == 0:
		_remove(context, white)
#endregion


#region 白墨燃料与特殊目标
static func _consume_loose(body, amount: int) -> void:
	for shape in body.shapes:
		for key in shape.chunks.keys():
			var chunk = shape.chunks.get(key)
			while chunk != null and chunk.occ != 0 and amount > 0:
				var bit := Bits.first_bit_index(chunk.occ)
				var cell := Vector2i(Shape.key_x(key) * 8 + (bit & 7),
					Shape.key_y(key) * 8 + (bit >> 3))
				shape.clear_pixel(cell.x, cell.y)
				amount -= 1
			if amount <= 0:
				return


func _touch_yellow(white, yellow) -> bool:
	if yellow == null:
		return false
	var old: Transform2D = _previous.get(white, Transform2D(white.rotation, white.position))
	var now := Transform2D(white.rotation, white.position)
	var bounds := _bounds(white, old).merge(_bounds(white, now))
	for stroke in yellow.strokes:
		if stroke.state != stroke.State.ACTIVE:
			continue
		stroke.update_visual()
		for cell in stroke.cells:
			if bounds.has_point(stroke.pixel_world(Vector2(cell) + Vector2.ONE * 0.5)):
				yellow.dissolve(stroke)
				return true
	return false
#endregion


#region 查询与回收
static func _erodible(material: int) -> bool:
	return material == Palette.BLACK.id or material == Palette.GREY.id \
		or material == Palette.RED.id


static func _bounds(body, transform: Transform2D) -> Rect2:
	var out := Rect2()
	for shape in body.shapes:
		var rect := transform * Rect2(shape.local_aabb())
		out = rect if not out.has_area() else out.merge(rect)
	return out


static func _area(body) -> int:
	var area := 0
	for shape in body.shapes:
		area += shape.pixel_count()
	return area


func _remove(context: Dictionary, body) -> void:
	_attached.erase(body)
	if context.has("pixel_world"):
		var host = context.pixel_world
		var index: int = context.world.bodies.find(body)
		var node = host._body_nodes[index] if index >= 0 and index < host._body_nodes.size() else null
		if is_instance_valid(node):
			host.remove_body_node(node)
			node.queue_free()
		else:
			context.world.remove_body(body)
	else:
		context.world.remove_body(body)
	for shape in body.shapes:
		shape.owner_body = null
	body.shapes.clear()


static func _clear_undo(context: Dictionary) -> void:
	if not context.has("pixel_world"):
		return
	for child in context.pixel_world.get_children():
		var surface = child.get("surface")
		if surface != null:
			surface._undo_steps.clear()
			surface._cancel_undo_step()
#endregion


#region Profiling
func set_profile_enabled(enabled: bool) -> void:
	_profile_enabled = enabled
	_profile.clear()


func take_profile() -> Dictionary:
	var result := _profile.duplicate()
	_profile.clear()
	return result
#endregion
