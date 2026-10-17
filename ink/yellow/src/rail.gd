extends Node2D
## 黄色实体导轨的中心线元数据。实体和碰撞仍由普通黄色像素刚体提供。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")

@export var saved_a := Vector2.ZERO
@export var saved_b := Vector2.ZERO
@export var rail_width: int = 7
var body = null
var local_a := Vector2.ZERO
var local_b := Vector2.ZERO
var world = null
var shape_revision := -1

func _ready() -> void:
	z_index = 9
	visible = false
	world = get_parent().world
	call_deferred("restore")

func restore() -> void:
	if body != null:
		return
	# 分帧烘焙期间黄墨刚体还没生成，等全部落地再找；找不到也保留节点不自毁。
	var level := get_parent()
	if level != null and level.get("body_bake_pending") == true:
		await Signal(level, &"body_bake_completed")
	for attempt in 240:
		var candidate = _find_body(saved_a, saved_b)
		if candidate != null:
			body = candidate
			local_a = body.to_local(saved_a)
			local_b = body.to_local(saved_b)
			_sync_visual()
			visible = true
			queue_redraw()
			return
		if not is_inside_tree() or is_queued_for_deletion():
			return
		await get_tree().physics_frame
	visible = false
	push_warning("[Rail] 未找到承载黄墨，已保留待修复: %s" % saved_a)

func _find_body(a: Vector2, b: Vector2):
	var steps := maxi(1, ceili(a.distance_to(b)))
	for index in steps + 1:
		var point := a.lerp(b, float(index) / steps)
		var anchor := Hinge.find_yellow(world, point)
		if not anchor.is_empty():
			return anchor.body
	return null

func axis_world() -> Vector2:
	if body == null:
		return (saved_b - saved_a).normalized()
	return (body.to_world(local_b) - body.to_world(local_a)).normalized()

func endpoints_world() -> PackedVector2Array:
	if body == null:
		return PackedVector2Array([saved_a, saved_b])
	return PackedVector2Array([body.to_world(local_a), body.to_world(local_b)])

func closest(point: Vector2) -> Dictionary:
	var endpoints := endpoints_world()
	var segment := endpoints[1] - endpoints[0]
	var length_squared := segment.length_squared()
	if length_squared <= 0.0001:
		return {}
	var t := (point - endpoints[0]).dot(segment) / length_squared
	var projected := endpoints[0] + segment * clampf(t, 0.0, 1.0)
	return {"point": projected, "t": t, "distance": point.distance_to(projected)}

func centerline_exists(point: Vector2) -> bool:
	if body == null or not world.bodies.has(body):
		return false
	return Hinge.has_pixel(body, Vector2i(body.to_local(point).floor()), Palette.YELLOW.id)

func can_capture(point: Vector2) -> Dictionary:
	var hit := closest(point)
	if hit.is_empty() or float(hit.t) < 0.0 or float(hit.t) > 1.0 \
	or float(hit.distance) > float(rail_width) * 0.5 or not centerline_exists(hit.point):
		return {}
	return hit

func rebind(physics, changed_body, pieces: Array) -> void:
	if body != changed_body:
		return
	var endpoints := endpoints_world()
	var length := endpoints[0].distance_to(endpoints[1])
	var steps := maxi(1, ceili(length))
	var spans := {}
	for index in steps + 1:
		var point := endpoints[0].lerp(endpoints[1], float(index) / steps)
		for piece in pieces:
			if not physics.bodies.has(piece):
				continue
			var cell := Vector2i(piece.to_local(point).floor())
			if not Hinge.has_pixel(piece, cell, Palette.YELLOW.id):
				continue
			if not spans.has(piece):
				spans[piece] = Vector2i(index, index)
			else:
				var span: Vector2i = spans[piece]
				span.y = index
				spans[piece] = span
			break
	for piece in spans:
		var span: Vector2i = spans[piece]
		if span.y <= span.x:
			continue
		var replacement := preload("res://ink/yellow/src/rail.gd").new()
		replacement.saved_a = endpoints[0].lerp(endpoints[1], float(span.x) / steps)
		replacement.saved_b = endpoints[0].lerp(endpoints[1], float(span.y) / steps)
		replacement.rail_width = rail_width
		get_parent().add_child(replacement)
		replacement.owner = get_parent()
	remove()

func _process(_delta: float) -> void:
	if body == null:
		return
	if not world.bodies.has(body):
		remove()
		return
	_sync_visual()
	var revision := 0
	for shape in body.shapes:
		revision += shape.revision
	if revision != shape_revision:
		shape_revision = revision
		queue_redraw()

func _sync_visual() -> void:
	saved_a = body.to_world(local_a)
	saved_b = body.to_world(local_b)
	position = body.position
	rotation = body.rotation
	scale = Vector2.ONE
	var yellow_ink := get_parent().get_node_or_null("SimulationRuntime/YellowInk")
	modulate.a = yellow_ink.yellow_opacity if yellow_ink != null else 1.0

func _draw() -> void:
	if body == null:
		return
	var length := local_a.distance_to(local_b)
	var steps := maxi(1, ceili(length))
	var start := -1
	var color: Color = Palette.YELLOW.color.darkened(0.48)
	color.a = 1.0
	for index in steps + 1:
		var point := local_a.lerp(local_b, float(index) / steps)
		var exists := Hinge.has_pixel(body, Vector2i(point.floor()), Palette.YELLOW.id)
		if exists and start < 0:
			start = index
		if start >= 0 and (not exists or index == steps):
			var last := index if exists and index == steps else index - 1
			if last >= start:
				draw_line(local_a.lerp(local_b, float(start) / steps),
					local_a.lerp(local_b, float(last) / steps), color, 2.0, false)
			start = -1

func remove() -> void:
	body = null
	visible = false
	queue_free()

