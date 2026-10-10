extends Node2D

#region 配置与状态
const Palette = preload("res://Ink/src/ink_palette.gd")
const Stroke = preload("res://actor/yellow/src/yellow_stroke.gd")
## 默认 7 px 支撑主角；较低阻尼保留弹弓的回弹能量。
@export var stiffness_per_width: float = 5000.0
@export var damping_ratio: float = 0.0
## 劲度变软后仍保留约 200 px 的静态安全拉伸量。
@export var safe_force_per_width: float = 1000000.0
@export var wear_pixels_per_second: float = 15.0
var drawing = null
var strokes: Array = []
var _world = null
var _player = null
var _mask: ImageTexture
var _mask_image: Image
var _mask_bounds: Rect2i
var _mask_revision: int = -1
var _wear_cursor: int = 0
const OVERLAP_SHADER = preload("res://actor/yellow/asset/overlap.gdshader")
#endregion

#region 绘制与固化
func _ready() -> void:
	_world = get_parent().get_parent()
	for child in _world.get_children():
		if child is Stroke and child.activated:
			strokes.append(child)

func begin(surface, point: Vector2) -> void:
	cancel()
	if not valid_anchor(surface, point):
		return
	drawing = Stroke.new()
	drawing.preview = true
	drawing.source_surface = surface
	drawing.brush_width = surface.brush_size
	drawing.path.append(_world.to_local(surface.to_global(point.floor() + Vector2.ONE * 0.5)))
	_world.add_child(drawing)
	drawing.queue_redraw()

func extend(surface, point: Vector2) -> void:
	if drawing == null or drawing.source_surface != surface:
		return
	if not surface._inside(point):
		cancel()
		return
	var p: Vector2 = _world.to_local(surface.to_global(point))
	if drawing.path[-1].distance_squared_to(p) >= 1.0:
		drawing.path.append(p)
		drawing.queue_redraw()

func finish(surface, point: Vector2) -> bool:
	if drawing == null or drawing.source_surface != surface:
		return false
	var stroke = drawing
	drawing = null
	stroke.path.append(_world.to_local(surface.to_global(point.floor() + Vector2.ONE * 0.5)))
	if not surface._inside(point) or not valid_anchor(surface, point) \
	or not endpoint_legal(stroke.path[0]) or not endpoint_legal(stroke.path[-1]):
		stroke.queue_free()
		return false
	var distance: float = stroke.path[0].distance_to(stroke.path[-1])
	if distance > 0.001 and distance < 9.0:
		stroke.queue_free()
		return false
	stroke.preview = false
	if not stroke.build_pixels() or not stroke.connected() \
	or (not surface.ink_free and stroke.original_area > surface._ink_room(Palette.YELLOW.id)):
		stroke.queue_free()
		return false
	stroke.paid = not surface.ink_free
	var health = surface._health_node()
	if stroke.paid and health != null:
		health.reduce(Palette.YELLOW.id, stroke.original_area)
	strokes.append(stroke)
	surface._undo_steps.append({"yellow": stroke})
	stroke.queue_redraw()
	surface.edit_committed.emit()
	return true

func cancel() -> void:
	if is_instance_valid(drawing):
		drawing.queue_free()
	drawing = null

func endpoint_legal(point: Vector2) -> bool:
	for stroke in strokes:
		if stroke.state > Stroke.State.ACTIVE:
			continue
		var points: Array = [stroke.path[0], stroke.path[-1]]
		if stroke.state == Stroke.State.ACTIVE and stroke.anchors.size() == 2:
			points = [Stroke.anchor_world(stroke.anchors[0]), Stroke.anchor_world(stroke.anchors[1])]
		for other: Vector2 in points:
			var distance: float = point.distance_to(other)
			if distance > 0.001 and distance < 9.0:
				return false
	return true

func valid_anchor(surface, point: Vector2) -> bool:
	if not surface._inside(point):
		return false
	var cell: Vector2i = Vector2i(point.floor())
	return surface.material_at(cell.x, cell.y) == Palette.BLACK.id \
		or not Stroke.find_anchor(_world.world, _world.to_local(surface.to_global(point))).is_empty()

func solidify(surface) -> void:
	for stroke in strokes.duplicate():
		if stroke.source_surface != surface or stroke.state != Stroke.State.EDITING:
			continue
		stroke.anchors = [Stroke.find_anchor(_world.world, stroke.path[0]),
			Stroke.find_anchor(_world.world, stroke.path[-1])]
		if stroke.anchors[0].is_empty() or stroke.anchors[1].is_empty():
			refund(stroke, surface, stroke.cells.size())
			strokes.erase(stroke)
			stroke.queue_free()
			continue
		stroke.rest_length = stroke.path[0].distance_to(stroke.path[-1])
		stroke.saved_anchor_a = stroke.path[0]
		stroke.saved_anchor_b = stroke.path[-1]
		stroke.state = Stroke.State.ACTIVE
		stroke.activated = true
		stroke.owner = _world
		connect_stroke(stroke, _world.world)

func clear_drafts(surface) -> void:
	if drawing != null and drawing.source_surface == surface:
		cancel()
	for stroke in strokes.duplicate():
		if stroke.source_surface == surface and stroke.state == Stroke.State.EDITING:
			refund(stroke, surface, stroke.cells.size())
			strokes.erase(stroke)
			stroke.queue_free()

func reclaim(surface) -> void:
	for stroke in strokes.duplicate():
		if stroke.state == Stroke.State.EDITING:
			continue
		var selected: Array[Vector2i] = []
		for cell: Vector2i in stroke.cells:
			if surface._inside(surface.to_local(stroke.pixel_world(Vector2(cell) + Vector2.ONE * 0.5))):
				selected.append(cell)
		if selected.is_empty():
			continue
		refund(stroke, surface, selected.size())
		for cell in selected:
			stroke.cells.erase(cell)
			stroke.occupancy.clear_pixel(cell.x, cell.y)
			stroke.worn.append(Vector2(cell))
			if stroke.image != null:
				stroke.image.set_pixelv(cell - stroke.bounds.position, Color.TRANSPARENT)
		if stroke.texture != null:
			stroke.texture.update(stroke.image)
		if stroke.state == Stroke.State.ACTIVE:
			stroke.fail()
		if stroke.cells.is_empty():
			strokes.erase(stroke)
			stroke.queue_free()

func refund(stroke, surface, amount: int) -> void:
	var health = surface._health_node()
	if stroke.paid and health != null:
		health.add(Palette.YELLOW.id, amount)

func undo(stroke, surface) -> void:
	if not is_instance_valid(stroke) or not strokes.has(stroke) or stroke.state != Stroke.State.EDITING:
		return
	refund(stroke, surface, stroke.cells.size())
	strokes.erase(stroke)
	stroke.queue_free()
#endregion

#region 物理与破坏
func connect_stroke(stroke, world) -> void:
	if stroke.joint != null and stroke.joint.is_active():
		return
	var a = stroke.anchors[0].body
	var b = stroke.anchors[1].body
	if a == b or (a.is_static and b.is_static):
		return
	var inverse_mass: float = a.inv_mass + b.inv_mass
	var stiffness: float = stiffness_per_width * stroke.brush_width
	var damping: float = 2.0 * damping_ratio * sqrt(stiffness / maxf(inverse_mass, 0.000001))
	stroke.joint = world.add_spring(a, b, Stroke.anchor_world(stroke.anchors[0]),
		Stroke.anchor_world(stroke.anchors[1]), stroke.rest_length, stiffness, damping)
	stroke.joint.contacts_enabled = true

func spring_load(stroke) -> float:
	if stroke.joint == null:
		return 0.0
	var a: Vector2 = Stroke.anchor_world(stroke.anchors[0])
	var b: Vector2 = Stroke.anchor_world(stroke.anchors[1])
	var direction: Vector2 = (b - a).normalized()
	var speed: float = (stroke.anchors[1].body.velocity_at(b) - stroke.anchors[0].body.velocity_at(a)).dot(direction)
	# SpringJoint 的马达冲量没有包含在当前桥接器的线性冲量读回里。
	# 按相同弹簧/阻尼模型估算载荷，避免把持续受力误读成零。
	return absf(stroke.joint.stiffness * (a.distance_to(b) - stroke.rest_length) + stroke.joint.damping * speed)

func observe_fracture(world, body, pieces: Array) -> void:
	for stroke in strokes:
		stroke.rebind(world, body, pieces)
		if stroke.state == Stroke.State.ACTIVE and stroke.anchors.size() == 2:
			connect_stroke(stroke, world)

func resolve_fixed(context: Dictionary) -> Dictionary:
	var world = context.world
	var delta: float = _world.fixed_dt
	_player = context.get("player_body")
	var wear_started: int = Time.get_ticks_usec()
	for offset in strokes.size():
		var stroke = strokes[(offset + _wear_cursor) % strokes.size()]
		if stroke.state != Stroke.State.ACTIVE:
			continue
		for index in stroke.anchors.size():
			var anchor: Dictionary = stroke.anchors[index]
			if not world.bodies.has(anchor.body) or not Stroke.has_black(anchor.body, anchor.cell):
				stroke.fail(index)
				break
		if stroke.state != Stroke.State.ACTIVE:
			continue
		connect_stroke(stroke, world)
		if stroke.joint == null:
			continue
		var load: float = spring_load(stroke)
		stroke.wear_credit += wear_pixels_per_second * maxf(0.0,
			load / (safe_force_per_width * stroke.brush_width) - 1.0) * delta
		stroke.wear_elapsed += delta
		if stroke.wear_elapsed >= 0.1 and stroke.wear_credit >= 1.0 \
		and Time.get_ticks_usec() - wear_started < 2000:
			var count: int = mini(256, int(stroke.wear_credit))
			stroke.wear_credit -= count
			stroke.wear_elapsed = 0.0
			stroke.erode(count)
	_wear_cursor = (_wear_cursor + 1) % maxi(1, strokes.size())
	return {}

func _process(delta: float) -> void:
	for stroke in strokes:
		if stroke.state == Stroke.State.ACTIVE:
			stroke.update_visual()
		elif stroke.state == Stroke.State.DYING:
			stroke.animate_death(delta)
		elif stroke.state == Stroke.State.EDITING and is_instance_valid(stroke.source_surface):
			stroke.visible = stroke.source_surface.is_visible_in_tree()
	_update_overlap()

func _update_overlap() -> void:
	if strokes.is_empty() or _player == null or not _world.visible:
		return
	var revision: int = 0
	for shape in _player.shapes:
		revision += shape.revision
	if revision != _mask_revision:
		_mask_revision = revision
		_mask_bounds = Rect2i()
		for shape in _player.shapes:
			var rect: Rect2i = shape.local_aabb()
			_mask_bounds = rect if _mask_bounds.size == Vector2i.ZERO else _mask_bounds.merge(rect)
		if _mask_bounds.size == Vector2i.ZERO:
			return
		_mask_image = Image.create_empty(_mask_bounds.size.x, _mask_bounds.size.y, false, Image.FORMAT_RGBA8)
		for shape in _player.shapes:
			for y in range(_mask_bounds.position.y, _mask_bounds.end.y):
				for x in range(_mask_bounds.position.x, _mask_bounds.end.x):
					if shape.get_pixel(x, y) != 0:
						_mask_image.set_pixelv(Vector2i(x, y) - _mask_bounds.position, Color.WHITE)
		_mask = ImageTexture.create_from_image(_mask_image)
	for stroke in strokes:
		if stroke.visual == null or not stroke.visible:
			continue
		var material: ShaderMaterial = stroke.visual.material
		if material == null:
			material = ShaderMaterial.new()
			material.shader = OVERLAP_SHADER
			stroke.visual.material = material
		material.set_shader_parameter("player_mask", _mask)
		material.set_shader_parameter("player_origin", _player.position)
		material.set_shader_parameter("player_angle", _player.rotation)
		material.set_shader_parameter("mask_origin", Vector2(_mask_bounds.position))
		material.set_shader_parameter("mask_size", Vector2(_mask_bounds.size))
		var player_node = _world.get_node_or_null("Player")
		material.set_shader_parameter("mask_enabled", player_node != null and player_node.is_visible_in_tree())
		stroke.endpoint_a.material = material
		stroke.endpoint_b.material = material
#endregion
