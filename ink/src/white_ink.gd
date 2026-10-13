extends Node
## 幽灵刚体扫掠擦除：白墨只更新像素，目标统一批量分片。

#region 配置与状态
const Palette := preload("res://ink/src/ink_palette.gd")
const Rects := preload("res://addons/pixel_destruction/core/greedy_rects.gd")
const Bits := preload("res://addons/pixel_destruction/core/pixel_bits.gd")
## 每个白像素的基础擦除量；速度增加效率，上限防止无限穿墙。
@export var base_yield: float = 1.0
@export var speed_per_yield: float = 300.0
@export var max_yield: float = 4.0
@export var player_damage_per_pixel: float = 1.0
## 相机外继续落下；最终按出生点距离回收，避免冻结白墨长期堆积。
@export var max_travel_from_spawn: float = 4096.0
var _previous: Dictionary = {}
var _whites: Array = []
var _profile_enabled := false
var _profile: Dictionary = {}
#endregion

#region 固定步
func prepare_fixed(context: Dictionary, _delta: float) -> void:
	_whites.clear()
	_previous.clear()
	for body in context.world.bodies:
		if body.tags.has("white_ink") and not body.is_static \
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
	var result := {"removals": {}}
	var reacted := false
	var yellow = context.services.get(&"yellow")
	for white in _whites:
		if not context.world.bodies.has(white) or white.frozen:
			continue
		white.tags["white_velocity"] = white.linear_velocity
		var old: Transform2D = _previous[white]
		var now := Transform2D(white.rotation, white.position)
		var rects: Array = []
		for shape in white.shapes:
			rects.append_array(Rects.decompose(shape).rects)
		var count := 0
		var bounds := _bounds(white, old).merge(_bounds(white, now))
		for target in context.world.bodies:
			if target == white or target.collision_layer == 0 or context.protected_bodies.has(target):
				continue
			if target.tags.has("living") and target != context.player_body:
				continue
			var target_now := Transform2D(target.rotation, target.position)
			var target_old: Transform2D = _previous.get(target, target_now)
			if not bounds.intersects(target.aabb.merge(_bounds(target, target_old))):
				continue
			# 扫掠矩形在目标局部空间逐行填掩码，避免高速盖章漏点。
			var local_bounds := _local_bounds(bounds, target_now).merge(_local_bounds(bounds, target_old))
			var polygons := swept_polygons(rects, target_old.affine_inverse() * old, target_now.affine_inverse() * now)
			var target_count := 0
			for shape in target.shapes:
				var mask := _raster_mask(shape, polygons, local_bounds, target == context.player_body)
				var existing: Dictionary = result.removals.get(target, {}).get(shape, {})
				for cell in existing:
					mask.erase(cell)
				target_count += mask.size()
				if not mask.is_empty() and target != context.player_body:
					var plan: Dictionary = result.removals.get_or_add(target, {})
					plan.get_or_add(shape, {}).merge(mask, true)
			count += target_count
			if target == context.player_body:
				context.player_node.apply_corrosion_damage(target_count * player_damage_per_pixel)
		if yellow != null:
			var polygons := swept_polygons(rects, old, now)
			for stroke in yellow.strokes:
				if stroke.state != stroke.State.ACTIVE:
					continue
				stroke.update_visual()
				for cell in stroke.cells:
					var point: Vector2 = stroke.pixel_world(Vector2(cell) + Vector2.ONE * 0.5)
					if _covered(polygons, point):
						count += 1
						yellow.dissolve(stroke)
						break
		if count > 0:
			reacted = true
			var efficiency := clampf(base_yield + white.linear_velocity.length() / maxf(speed_per_yield, 1.0), 1.0, maxf(max_yield, 1.0))
			var credit: float = white.tags.get("white_cost", 0.0) + count / efficiency
			var consumed := mini(int(credit), _area(white))
			white.tags["white_cost"] = credit - consumed
			_consume(white, consumed)
			_profile["erased_pixels"] = _profile.get("erased_pixels", 0) + count
		if _area(white) == 0 or white.position.distance_to(white.tags.white_origin) > max_travel_from_spawn:
			_remove(context, white)
	if reacted and context.has("pixel_world"):
		# 世界破坏不可撤销，旧事务不能复活白墨、黄线或被擦掉的目标。
		for child in context.pixel_world.get_children():
			var surface = child.get("surface")
			if surface != null:
				surface._undo_steps.clear()
				surface._cancel_undo_step()
	if _profile_enabled:
		_profile["resolve_us"] = _profile.get("resolve_us", 0) + Time.get_ticks_usec() - started
	return result

func _exit_tree() -> void:
	_previous.clear()
	_whites.clear()
#endregion

#region 几何与消费
## 精确矩形分别扫掠，保留白墨缺口；旋转目标采用端点包络。
static func swept_polygons(rects: Array, old: Transform2D, now: Transform2D) -> Array:
	var polygons: Array = []
	for rect: Rect2 in rects:
		var corners := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
		var points := old * corners
		points.append_array(now * corners)
		polygons.append(Geometry2D.convex_hull(points))
	return polygons

static func _covered(polygons: Array, point: Vector2) -> bool:
	for polygon in polygons:
		if Geometry2D.is_point_in_polygon(point, polygon):
			return true
	return false

## 凸扫掠多边形逐行求区间；只遍历覆盖区，避免逐像素射线和点包含调用。
static func _raster_mask(shape, polygons: Array, bounds: Rect2i, living: bool) -> Dictionary:
	var mask: Dictionary = {}
	var region: Rect2i = shape.local_aabb().intersection(bounds)
	for polygon in polygons:
		for y in range(region.position.y, region.end.y):
			var row := y + 0.5
			var left := INF
			var right := -INF
			for edge in polygon.size() - 1:
				var a: Vector2 = polygon[edge]
				var b: Vector2 = polygon[edge + 1]
				if row < minf(a.y, b.y) or row >= maxf(a.y, b.y):
					continue
				var x: float = a.x + (row - a.y) * (b.x - a.x) / (b.y - a.y)
				left = minf(left, x)
				right = maxf(right, x)
			if left == INF:
				continue
			for x in range(maxi(region.position.x, ceili(left - 0.5)), mini(region.end.x, floori(right - 0.5) + 1)):
				var chunk = shape.chunk_at(x >> 3, y >> 3)
				if chunk == null:
					continue
				var material: int = chunk.mat[(y & 7) * 8 + (x & 7)]
				if material != 0 and (living or material in [Palette.BLACK.id, Palette.GREY.id, Palette.RED.id]):
					mask[Vector2i(x, y)] = true
	return mask

static func _bounds(body, transform: Transform2D) -> Rect2:
	var out := Rect2()
	for shape in body.shapes:
		var rect := transform * Rect2(shape.local_aabb())
		out = rect if not out.has_area() else out.merge(rect)
	return out

static func _local_bounds(rect: Rect2, transform: Transform2D) -> Rect2i:
	var local := transform.affine_inverse() * rect
	return Rect2i(Vector2i(local.position.floor()), Vector2i(local.end.ceil() - local.position.floor()))

static func _area(body) -> int:
	var area := 0
	for shape in body.shapes:
		area += shape.pixel_count()
	return area

static func _consume(body, amount: int) -> void:
	for shape in body.shapes:
		# 固定块序局部磨损；不分裂、不重建质量与碰撞体。
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
