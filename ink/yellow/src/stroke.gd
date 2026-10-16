extends Node2D

#region 数据
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Destruction := preload("res://addons/pixel_destruction/core/destruction.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const TERMINAL := preload("res://ink/yellow/asset/terminal.svg")
const NEIGHBORS: Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
const CRACK_FRACTIONS: Array[float] = [0.44, 0.50, 0.56]
enum State { EDITING, ACTIVE, DYING, REMOVED }
@export var path: PackedVector2Array = []
@export var brush_width: int = 7
@export var rest_length: float = -1.0
@export var worn: PackedVector2Array = []
@export var saved_anchor_a: Vector2 = Vector2.ZERO
@export var saved_anchor_b: Vector2 = Vector2.ZERO
@export var activated: bool = false
@export var source_canvas: NodePath
## 新画出的黄色统一使用紧凑直线栅格；默认 false 仅用于读取旧场景。
@export var compact_raster: bool = false
@export var dashed: bool = true
@export var dash_length: float = 8.0
@export var dash_gap: float = 6.0
var dash_spans: Array[Vector2i] = []
var state: State = State.EDITING
var anchors: Array = []
var joint = null
var source_surface = null
@export var paid: bool = false
var cells: Dictionary = {}
var occupancy: PixelShape
var frontier: Dictionary = {}
var frontier_queue: Array[Vector2i] = []
var frontier_cursor: int = 0
var wear_pool: Array[Vector2i] = []
var wear_indices: Dictionary = {}
var original_area: int = 0
var wear_credit: float = 0.0
var wear_elapsed: float = 0.0
var fade: float = 0.0
var invalid_end: int = -1
var cut_index: float = 0.0
var image: Image
var texture: ImageTexture
var bounds: Rect2i
var raster_path: PackedVector2Array = []
var visual: Sprite2D
var endpoint_a: Sprite2D
var endpoint_b: Sprite2D
var preview: bool = false
var fixed_seed_cursor: int = 0
#endregion

#region 显示
func _ready() -> void:
	z_index = 8
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if path.is_empty() or preview:
		return
	if not source_canvas.is_empty():
		source_surface = get_parent().get_node_or_null(source_canvas)
	# 旧黄色一律迁移为直线虚线弹簧，旧磨损投影到同一条轴线。
	if dashed and not compact_raster and path.size() > 1:
		var origin: Vector2 = path[0]
		var direction: Vector2 = (path[-1] - origin).normalized()
		for index in worn.size():
			var relative: Vector2 = worn[index] - origin
			worn[index] = Vector2(relative.dot(direction), relative.dot(direction.orthogonal())).floor()
		compact_raster = true
	build_pixels()
	if activated:
		state = State.ACTIVE
		call_deferred("_restore")

func _restore() -> void:
	var world = get_parent().get("world")
	if world == null:
		return
	anchors = [find_anchor(world, saved_anchor_a), find_anchor(world, saved_anchor_b)]
	if anchors[0].is_empty() or anchors[1].is_empty():
		fail(0 if anchors[0].is_empty() else 1)
	else:
		var rule = get_parent().get_node("SimulationRuntime/YellowInk")
		if not rule.strokes.has(self):
			rule.strokes.append(self)
		rule.connect_stroke(self, world)

func _draw() -> void:
	if not preview or path.is_empty():
		return
	if path.size() > 1:
		var length: float = path[0].distance_to(path[-1])
		var at := 0.0
		while at < length:
			draw_line(path[0].lerp(path[-1], at / length), path[0].lerp(path[-1], minf(at + dash_length, length) / length), Palette.YELLOW.color, brush_width)
			at += dash_length + dash_gap

func build_pixels() -> bool:
	cells.clear()
	if path.is_empty():
		return false
	raster_path = _make_raster_path()
	var radius: float = maxf(0.5, (brush_width - 1) * 0.5)
	for index in maxi(1, raster_path.size() - 1):
		var a: Vector2 = raster_path[index]
		var b: Vector2 = raster_path[mini(index + 1, raster_path.size() - 1)]
		var steps: int = maxi(1, ceili(a.distance_to(b) * 2.0))
		for step in steps + 1:
			var center: Vector2 = a.lerp(b, float(step) / steps)
			var lo: Vector2i = Vector2i((center - Vector2.ONE * radius).floor())
			var hi: Vector2i = Vector2i((center + Vector2.ONE * radius).ceil())
			for y in range(lo.y, hi.y + 1):
				for x in range(lo.x, hi.x + 1):
					var p: Vector2i = Vector2i(x, y)
					if (Vector2(p) + Vector2.ONE * 0.5).distance_squared_to(center) <= radius * radius:
						cells[p] = float(index) + float(step) / steps
	if dashed and raster_path.size() > 1:
		var length: float = raster_path[0].distance_to(raster_path[-1])
		for p: Vector2i in cells.keys():
			var distance: float = clampf(float(cells[p]) / maxi(1, raster_path.size() - 1), 0.0, 1.0) * length
			if fmod(distance, dash_length + dash_gap) >= dash_length and distance < length - 4.5:
				cells.erase(p)
	original_area = cells.size()
	# 空隙不参与结构判定；每段实线自身必须仍能从左侧连通到右侧。
	dash_spans.clear()
	if dashed and compact_raster:
		var full := PixelShape.new()
		for p: Vector2i in cells:
			full.set_pixel(p.x, p.y, 1)
		for part in Destruction.split(full, 1):
			var rect: Rect2i = part.local_aabb()
			dash_spans.append(Vector2i(rect.position.x, rect.end.x - 1))
	for point in worn:
		cells.erase(Vector2i(point))
	occupancy = PixelShape.new()
	for p: Vector2i in cells:
		occupancy.set_pixel(p.x, p.y, 1)
	wear_pool.clear()
	wear_indices.clear()
	frontier.clear()
	frontier_queue.clear()
	frontier_cursor = 0
	for p: Vector2i in cells:
		var center: Vector2 = Vector2(p) + Vector2.ONE * 0.5
		if center.distance_squared_to(raster_path[0]) >= 20.25 \
		and center.distance_squared_to(raster_path[-1]) >= 20.25:
			wear_indices[p] = wear_pool.size()
			wear_pool.append(p)
	if cells.is_empty():
		return false
	var low: Vector2i = cells.keys()[0]
	var high: Vector2i = low
	for p: Vector2i in cells:
		low = low.min(p)
		high = high.max(p)
	bounds = Rect2i(low, high - low + Vector2i.ONE)
	image = Image.create_empty(bounds.size.x, bounds.size.y, false, Image.FORMAT_RGBA8)
	for p: Vector2i in cells:
		image.set_pixelv(p - bounds.position, Palette.YELLOW.color)
	texture = ImageTexture.create_from_image(image)
	visual = Sprite2D.new()
	visual.centered = false
	visual.texture = texture
	add_child(visual)
	if compact_raster:
		var direction: Vector2 = path[-1] - path[0]
		visual.transform = Transform2D(direction.angle(), path[0]) \
			* Transform2D(0.0, Vector2(bounds.position))
	else:
		visual.position = Vector2(bounds.position)
	endpoint_a = Sprite2D.new()
	endpoint_a.texture = TERMINAL
	endpoint_a.z_index = 2
	add_child(endpoint_a)
	endpoint_a.top_level = true
	endpoint_a.global_position = _world_to_canvas(path[0])
	endpoint_a.global_rotation = 0.0
	endpoint_b = Sprite2D.new()
	endpoint_b.texture = TERMINAL
	endpoint_b.z_index = 2
	add_child(endpoint_b)
	endpoint_b.top_level = true
	endpoint_b.global_position = _world_to_canvas(path[-1])
	endpoint_b.global_rotation = 0.0
	for point in worn:
		_add_frontier(Vector2i(point))
	fixed_seed_cursor = CRACK_FRACTIONS.size() if not worn.is_empty() else 0
	return true

func _make_raster_path() -> PackedVector2Array:
	if path.size() < 2:
		return path.duplicate()
	if compact_raster:
		return PackedVector2Array([Vector2.ZERO, Vector2(path[0].distance_to(path[-1]), 0.0)])
	return path.duplicate()

func update_visual() -> void:
	if anchors.size() != 2 or state != State.ACTIVE:
		return
	var a: Vector2 = anchor_world(anchors[0])
	var b: Vector2 = anchor_world(anchors[1])
	var original: Vector2 = raster_path[-1] - raster_path[0]
	var current: Vector2 = b - a
	var factor: float = current.length() / original.length() if original.length() > 0.001 else 1.0
	var source_axis: Vector2 = original.normalized() if original.length() > 0.001 else Vector2.RIGHT
	var target_axis: Vector2 = current.normalized() if current.length() > 0.001 else source_axis
	var source_normal: Vector2 = source_axis.orthogonal()
	var target_normal: Vector2 = target_axis.orthogonal()
	# 只沿弹簧轴向拉伸；法向始终为原画笔宽度，不再越拉越粗。
	var x_axis: Vector2 = target_axis * source_axis.x * factor + target_normal * source_normal.x
	var y_axis: Vector2 = target_axis * source_axis.y * factor + target_normal * source_normal.y
	var deformation := Transform2D(x_axis, y_axis, Vector2.ZERO)
	deformation.origin = a - deformation.basis_xform(raster_path[0])
	# Stroke 本身永远保持单位变换；只变换黄色纹理。这样端子、数据坐标和
	# Sprite2D 不会在连续更新中落入不同坐标空间。
	transform = Transform2D.IDENTITY
	visual.transform = deformation * Transform2D(0.0, Vector2(bounds.position))
	# 端子是独立世界空间贴图：中心跟锚点，大小和朝向都不继承弹簧变形。
	endpoint_a.global_position = _world_to_canvas(a)
	endpoint_b.global_position = _world_to_canvas(b)
	endpoint_a.global_rotation = 0.0
	endpoint_b.global_rotation = 0.0
	endpoint_a.global_scale = Vector2.ONE
	endpoint_b.global_scale = Vector2.ONE
	saved_anchor_a = a
	saved_anchor_b = b

func _world_to_canvas(point: Vector2) -> Vector2:
	var world_node := get_parent() as Node2D
	return world_node.to_global(point) if world_node != null else point

func pixel_world(point: Vector2) -> Vector2:
	if visual == null:
		return _world_to_canvas(point)
	return visual.to_global(point - Vector2(bounds.position))

func animate_death(delta: float) -> void:
	fade += delta / 0.3
	if fade >= 1.0:
		state = State.REMOVED
		visible = false
		visual.queue_free()
		endpoint_a.queue_free()
		endpoint_b.queue_free()
		visual = null
		image = null
		texture = null
		return
	var segment_count: int = maxi(1, raster_path.size() - 1)
	var count: float = segment_count * fade
	# 消散只更新显示，不消耗可回收的剩余墨水。
	for p: Vector2i in cells:
		var nearest: float = cells[p]
		var erase: bool = nearest < count if invalid_end == 0 else nearest >= segment_count - count
		if invalid_end < 0:
			erase = absf(nearest - cut_index) < count
		if erase:
			image.set_pixelv(p - bounds.position, Color.TRANSPARENT)
	texture.update(image)
	endpoint_a.modulate.a = 1.0 - fade
	endpoint_b.modulate.a = 1.0 - fade
#endregion

#region 锚点与物理
static func find_anchor(world, point: Vector2) -> Dictionary:
	var result: Dictionary = {}
	for body in world.bodies:
		if body.tags.has("living") or not body.aabb.has_point(point):
			continue
		var cell: Vector2i = Vector2i(body.to_local(point).floor())
		if has_black(body, cell):
			if not result.is_empty():
				return {}
			result = {"body": body, "cell": cell, "local": body.to_local(point)}
	return result

static func has_black(body, cell: Vector2i) -> bool:
	for shape in body.shapes:
		if shape.get_pixel(cell.x, cell.y) == Palette.BLACK.id:
			return true
	return false

static func anchor_world(anchor: Dictionary) -> Vector2:
	return anchor.body.to_world(anchor.local)

func remove_joint() -> void:
	if joint != null and joint.is_active():
		joint.remove()
	joint = null

func rebind(world, body, replacements: Array) -> void:
	if state != State.ACTIVE:
		return
	var changed: bool = false
	for index in anchors.size():
		var anchor: Dictionary = anchors[index]
		if anchor.body != body:
			continue
		var found: Array = []
		for piece in replacements:
			if world.bodies.has(piece) and has_black(piece, anchor.cell):
				found.append(piece)
		if found.size() != 1:
			fail(index)
			return
		anchor.body = found[0]
		changed = true
	if changed:
		remove_joint()

func fail(end: int = -1) -> void:
	remove_joint()
	state = State.DYING
	invalid_end = end
	cut_index = 0.5 * maxi(1, raster_path.size() - 1)
	activated = false
	owner = null

func _exit_tree() -> void:
	remove_joint()
	anchors.clear()
#endregion

#region 磨损
func _add_frontier(p: Vector2i) -> void:
	for offset in NEIGHBORS:
		var neighbor: Vector2i = p + offset
		if wear_indices.has(neighbor) and not frontier.has(neighbor):
			frontier[neighbor] = true
			frontier_queue.append(neighbor)

func erode(amount: int) -> void:
	for iteration in mini(amount, 256):
		if wear_pool.is_empty():
			break
		var p: Vector2i = _next_fixed_wear_point()
		_remove_wear_point(p)
	texture.update(image)
	if not connected():
		fail()

func _next_fixed_wear_point() -> Vector2i:
	if fixed_seed_cursor < CRACK_FRACTIONS.size():
		var seed: Vector2i = _closest_wear_point(_crack_frame(CRACK_FRACTIONS[fixed_seed_cursor]).point)
		fixed_seed_cursor += 1
		return seed
	while frontier_cursor < frontier_queue.size():
		var candidate: Vector2i = frontier_queue[frontier_cursor]
		frontier_cursor += 1
		if frontier.has(candidate) and wear_indices.has(candidate):
			frontier.erase(candidate)
			return candidate
	return _closest_wear_point(_crack_frame(0.5).point)

func _closest_wear_point(target: Vector2) -> Vector2i:
	var origin := Vector2i(target.floor())
	var search_radius: int = maxi(2, brush_width)
	var found: bool = false
	var best := Vector2i.ZERO
	var best_distance: float = INF
	for y in range(origin.y - search_radius, origin.y + search_radius + 1):
		for x in range(origin.x - search_radius, origin.x + search_radius + 1):
			var candidate := Vector2i(x, y)
			if not wear_indices.has(candidate):
				continue
			var distance: float = (Vector2(candidate) + Vector2.ONE * 0.5).distance_squared_to(target)
			if not found or distance < best_distance or (is_equal_approx(distance, best_distance) \
			and (candidate.y < best.y or (candidate.y == best.y and candidate.x < best.x))):
				found = true
				best = candidate
				best_distance = distance
	if found:
		return best
	return wear_pool[0]

func _crack_frame(fraction: float) -> Dictionary:
	var scaled: float = clampf(fraction, 0.0, 1.0) * maxi(1, raster_path.size() - 1)
	var index: int = mini(floori(scaled), raster_path.size() - 2)
	var local_t: float = scaled - index
	var a: Vector2 = raster_path[index]
	var b: Vector2 = raster_path[index + 1]
	var tangent: Vector2 = (b - a).normalized()
	if tangent == Vector2.ZERO:
		tangent = Vector2.RIGHT
	return {"point": a.lerp(b, local_t), "tangent": tangent}

func _remove_wear_point(p: Vector2i) -> void:
	var index: int = wear_indices[p]
	var last: Vector2i = wear_pool[-1]
	wear_pool[index] = last
	wear_indices[last] = index
	wear_pool.pop_back()
	wear_indices.erase(p)
	cells.erase(p)
	occupancy.clear_pixel(p.x, p.y)
	frontier.erase(p)
	worn.append(Vector2(p))
	_add_frontier(p)
	image.set_pixelv(p - bounds.position, Color.TRANSPARENT)

func connected() -> bool:
	if dashed and compact_raster:
		var spans: Array[Vector2i] = []
		for part in Destruction.split(occupancy, 1):
			var rect: Rect2i = part.local_aabb()
			spans.append(Vector2i(rect.position.x, rect.end.x - 1))
		for required in dash_spans:
			var found := false
			for span in spans:
				if span.x <= required.x and span.y >= required.y:
					found = true
					break
			if not found:
				return false
		return not cells.is_empty()
	var start: Vector2i = Vector2i(raster_path[0].floor())
	var end: Vector2i = Vector2i(raster_path[-1].floor())
	if not cells.has(start) or not cells.has(end):
		return false
	var key_a: int = PixelShape.make_key(start.x >> 3, start.y >> 3)
	var key_b: int = PixelShape.make_key(end.x >> 3, end.y >> 3)
	var bit_a: int = 1 << ((start.y & 7) * 8 + (start.x & 7))
	var bit_b: int = 1 << ((end.y & 7) * 8 + (end.x & 7))
	for component: Dictionary in Destruction.components(occupancy).values():
		if (int(component.get(key_a, 0)) & bit_a) != 0:
			return (int(component.get(key_b, 0)) & bit_b) != 0
	return false
#endregion
