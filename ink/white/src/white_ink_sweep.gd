extends Node
## 圆形白墨专用：保留旧版 16px 块扫掠，沿整条运动路径做高速覆盖擦除。

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
const Traits := preload("res://ink/general/src/ink_traits.gd")
const BRUSH_SIZE := 16
const BRUSH_RADIUS := BRUSH_SIZE * 0.7071067811865476

@export var base_yield: float = 1.0
@export var speed_per_yield: float = 300.0
@export var max_yield: float = 4.0
@export var player_damage_per_pixel: float = 1.0
@export var max_travel_from_spawn: float = 4096.0

var _previous: Dictionary = {}
var _whites: Array = []
var _profile_enabled := false
var _profile: Dictionary = {}


func prepare_fixed(context: Dictionary, _delta: float) -> void:
	_whites.clear()
	_previous.clear()
	for body in context.world.bodies:
		if body.tags.has("white_sweep") and not body.is_static \
		and not body.tags.get("editor_physics_paused", false):
			_whites.append(body)
	if _whites.is_empty():
		return
	for body in context.world.bodies:
		_previous[body] = Transform2D(body.rotation, body.position)
	for body in _whites:
		body.tags.get_or_add("white_origin", body.position)
		body.linear_velocity = body.tags.get_or_add("white_velocity", body.linear_velocity)
		body.angular_velocity = 0.0
		body.clear_forces()


func resolve_fixed(context: Dictionary) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result := {"carves": {}}
	var reacted := false
	var yellow = context.services.get(&"yellow")
	for white in _whites:
		if not context.world.bodies.has(white) or white.frozen:
			continue
		white.tags["white_velocity"] = white.linear_velocity
		var old: Transform2D = _previous[white]
		var now := Transform2D(white.rotation, white.position)
		var brushes := _brushes(white)
		var area := _area(white)
		var count := 0
		var bounds := _bounds(white, old).merge(_bounds(white, now)).grow(BRUSH_SIZE)
		for target in context.world.bodies:
			if target == white or target.collision_layer == 0 \
			or context.protected_bodies.has(target):
				continue
			if Traits.is_unbreakable(target):
				continue
			if target.tags.has("living") and target != context.player_body:
				continue
			var target_now := Transform2D(target.rotation, target.position)
			var target_old: Transform2D = _previous.get(target, target_now)
			if not bounds.intersects(target.aabb.merge(_bounds(target, target_old))):
				continue
			var sweeps := _sweeps(brushes, target_old.affine_inverse() * old,
				target_now.affine_inverse() * now)
			var target_count := 0
			for shape in target.shapes:
				var mask := _mask(shape, sweeps, target == context.player_body)
				target_count += mask.size()
				if not mask.is_empty() and target != context.player_body:
					result.carves.get_or_add(target, {}).get_or_add(shape, {}).merge(mask, true)
			count += target_count
			if target == context.player_body and target_count > 0:
				context.player_node.apply_corrosion_damage(target_count * player_damage_per_pixel)
		if yellow != null:
			var yellow_sweeps := _sweeps(brushes, old, now)
			for stroke in yellow.strokes:
				if stroke.state != stroke.State.ACTIVE:
					continue
				stroke.update_visual()
				for cell in stroke.cells:
					var point: Vector2 = stroke.pixel_world(Vector2(cell) + Vector2.ONE * 0.5)
					if yellow_sweeps.any(func(damage): return damage.hits(point.x, point.y)):
						count += 1
						yellow.dissolve(stroke)
						break
		if count > 0:
			reacted = true
			var efficiency := clampf(base_yield + white.linear_velocity.length()
				/ maxf(speed_per_yield, 1.0), 1.0, maxf(max_yield, 1.0))
			var credit: float = white.tags.get("white_cost", 0.0) + count / efficiency
			var consumed := mini(int(credit), area)
			white.tags["white_cost"] = credit - consumed
			_consume(white, consumed)
			area -= consumed
			_profile["erased_pixels"] = _profile.get("erased_pixels", 0) + count
		if area == 0 or white.position.distance_to(white.tags.white_origin) > max_travel_from_spawn:
			_remove(context, white)
	if reacted:
		_clear_undo(context)
	if _profile_enabled:
		_profile["resolve_us"] = _profile.get("resolve_us", 0) + Time.get_ticks_usec() - started
	return result


func _exit_tree() -> void:
	_previous.clear()
	_whites.clear()


static func _brushes(body) -> Array:
	var cells := {}
	for shape in body.shapes:
		for key: int in shape.chunks:
			if shape.chunks[key].occ != 0:
				cells[Vector2i(Shape.key_x(key) >> 1, Shape.key_y(key) >> 1)] = true
	return cells.keys().map(func(cell):
		return Vector2(cell * BRUSH_SIZE) + Vector2.ONE * (BRUSH_SIZE / 2.0))


static func _sweeps(brushes: Array, old: Transform2D, now: Transform2D) -> Array:
	return brushes.map(func(center):
		return Destruction.Damage.segment(old * center, now * center, BRUSH_RADIUS))


static func _mask(shape, sweeps: Array, living: bool) -> Dictionary:
	var chunks := {}
	for damage in sweeps:
		var bounds: Rect2 = damage.bounds().intersection(Rect2(shape.local_aabb()))
		if not bounds.has_area():
			continue
		for cy in range(floori(bounds.position.y / 8), ceili(bounds.end.y / 8)):
			for cx in range(floori(bounds.position.x / 8), ceili(bounds.end.x / 8)):
				var key := Shape.make_key(cx, cy)
				var chunk = shape.chunks.get(key)
				if chunk != null:
					chunks[key] = chunk.occ
	var mask := {}
	for key: int in chunks:
		var bits: int = chunks[key]
		var chunk = shape.chunks[key]
		var origin := Vector2i(Shape.key_x(key) * 8, Shape.key_y(key) * 8)
		for index in 64:
			if (bits & (1 << index)) == 0:
				continue
			var material: int = chunk.mat[index]
			if living or material == Palette.BLACK.id or material == Palette.GREY.id \
			or material == Palette.RED.id:
				mask[origin + Vector2i(index & 7, index >> 3)] = true
	return mask


static func _bounds(body, transform: Transform2D) -> Rect2:
	var out := Rect2()
	for shape in body.shapes:
		var rect: Rect2 = transform * Rect2(shape.local_aabb())
		out = rect if not out.has_area() else out.merge(rect)
	return out


static func _area(body) -> int:
	var area := 0
	for shape in body.shapes:
		area += shape.pixel_count()
	return area


static func _consume(body, amount: int) -> void:
	for shape in body.shapes:
		for key in shape.chunks.keys():
			if amount <= 0:
				return
			var chunk = shape.chunks[key]
			var count: int = chunk.count()
			if amount >= count:
				shape.chunks.erase(key)
				amount -= count
			else:
				var keep: int = chunk.occ
				for iteration in amount:
					keep &= ~(1 << Bits.first_bit_index(keep))
				chunk.apply_keep_mask(keep)
				amount = 0
			shape.mark_dirty_key(key)


static func _remove(context: Dictionary, body) -> void:
	if context.has("pixel_world"):
		var host = context.pixel_world
		var index: int = context.world.bodies.find(body)
		var node = host._body_nodes[index] if index >= 0 \
			and index < host._body_nodes.size() else null
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


func set_profile_enabled(enabled: bool) -> void:
	_profile_enabled = enabled
	_profile.clear()


func take_profile() -> Dictionary:
	var result := _profile.duplicate()
	_profile.clear()
	return result
