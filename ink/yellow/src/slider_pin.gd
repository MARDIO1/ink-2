extends Node2D
## 黑色刚体上的方形滑块销；脱轨后保留，并寻找可接入的黄色直导轨。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const Rail := preload("res://ink/yellow/src/rail.gd")

@export var saved_source := Vector2.ZERO
@export var saved_position := Vector2.ZERO
var black_anchor: Dictionary = {}
var pin_local := Vector2.ZERO
var rail = null
var joint = null
var world = null
var previous_position := Vector2.INF
var travel_min := 0.0
var travel_max := 0.0

func _ready() -> void:
	z_index = 10
	top_level = true
	# 顶层绘制节点在延迟恢复锚点前仍会收到一次 draw；先隐藏，避免在默认原点闪出黑色方块。
	visible = false
	world = get_parent().world
	call_deferred("restore")

func restore() -> void:
	if not black_anchor.is_empty():
		return
	black_anchor = Stroke.find_anchor(world, saved_source)
	if black_anchor.is_empty():
		visible = false
		queue_free()
		return
	pin_local = black_anchor.body.to_local(saved_position)
	_sync_visual()
	visible = true
	queue_redraw()
	previous_position = pin_world()
	try_attach()

func pin_world() -> Vector2:
	return black_anchor.body.to_world(pin_local)

func try_attach(sweep_from := Vector2.INF) -> bool:
	if black_anchor.is_empty() or rail != null:
		return false
	var point := pin_world()
	var velocity: Vector2 = black_anchor.body.velocity_at(point)
	var best = null
	var best_hit: Dictionary = {}
	var best_distance := INF
	var best_alignment := -INF
	for child in get_parent().get_children():
		if not child is Rail or child.is_queued_for_deletion() or child.body == null:
			continue
		var hit: Dictionary = child.can_capture(point)
		if hit.is_empty() and sweep_from != Vector2.INF and sweep_from.distance_squared_to(point) > 0.001:
			var endpoints: PackedVector2Array = child.endpoints_world()
			var pair: PackedVector2Array = Geometry2D.get_closest_points_between_segments(
				sweep_from, point, endpoints[0], endpoints[1])
			if pair.size() == 2 and pair[0].distance_to(pair[1]) <= float(child.rail_width) * 0.5:
				hit = child.can_capture(pair[1])
		if hit.is_empty():
			continue
		var alignment := absf(velocity.normalized().dot(child.axis_world())) if velocity.length_squared() > 0.001 else 0.0
		if float(hit.distance) < best_distance - 0.001 \
		or (is_equal_approx(float(hit.distance), best_distance) and alignment > best_alignment):
			best = child
			best_hit = hit
			best_distance = float(hit.distance)
			best_alignment = alignment
	if best == null:
		return false
	rail = best
	joint = world.add_slider(rail.body, black_anchor.body, best_hit.point, rail.axis_world())
	# 销钉是黑体上的固定局部点；重新接轨时只把导轨端吸到投影点，不能让销钉在黑体上漂移。
	joint.local_anchor_a = rail.body.to_local(best_hit.point)
	joint.local_anchor_b = pin_local
	joint.contacts_enabled = false
	var endpoints: PackedVector2Array = rail.endpoints_world()
	var axis: Vector2 = rail.axis_world()
	var from_start: float = (Vector2(best_hit.point) - endpoints[0]).dot(axis)
	travel_min = -from_start
	travel_max = endpoints[0].distance_to(endpoints[1]) - from_start
	return true

func detach() -> void:
	if joint != null and joint.is_active():
		joint.remove()
	joint = null
	rail = null
	travel_min = 0.0
	travel_max = 0.0

func rebind(physics, changed_body, pieces: Array) -> void:
	if black_anchor.is_empty() or black_anchor.body != changed_body:
		return
	var source_world := Stroke.anchor_world(black_anchor)
	var old_pin_world := pin_world()
	var replacement: Dictionary = {}
	for piece in pieces:
		if not physics.bodies.has(piece):
			continue
		var cell := Vector2i(piece.to_local(source_world).floor())
		if Stroke.has_black(piece, cell):
			replacement = {"body": piece, "cell": cell, "local": piece.to_local(source_world)}
			break
	if replacement.is_empty():
		detach()
		visible = false
		queue_free()
		return
	black_anchor = replacement
	pin_local = replacement.body.to_local(old_pin_world)
	detach()
	_sync_visual()

func update_constraint_state() -> void:
	if black_anchor.is_empty() or is_queued_for_deletion():
		return
	if not world.bodies.has(black_anchor.body) \
	or not Stroke.has_black(black_anchor.body, black_anchor.cell):
		detach()
		visible = false
		queue_free()
		return
	var detached_now := false
	if rail != null:
		if not is_instance_valid(rail) or rail.is_queued_for_deletion() or joint == null or not joint.is_active():
			detach()
			detached_now = true
		else:
			# 原生 SLIDER 是无限长的。直接用关节自己的自由度判断是否越过有限导轨，
			# 避免显示点、黑体源像素或破坏重绑后的坐标被误当成滑块当前位置。
			var travel: float = joint.movement()
			var rail_point: Vector2 = joint.anchor_a_world() + joint.world_axis() * travel
			if travel < travel_min - 0.5 or travel > travel_max + 0.5 \
			or not rail.centerline_exists(rail_point):
				detach()
				detached_now = true
	if rail == null and not detached_now:
		try_attach(previous_position)
	previous_position = pin_world()

func _process(_delta: float) -> void:
	update_constraint_state()
	if black_anchor.is_empty() or is_queued_for_deletion():
		return
	_sync_visual()

func _sync_visual() -> void:
	if black_anchor.is_empty():
		return
	saved_source = Stroke.anchor_world(black_anchor)
	saved_position = pin_world()
	var world_node := get_parent() as Node2D
	global_position = world_node.to_global(pin_world()) if world_node != null else pin_world()
	global_rotation = 0.0
	global_scale = Vector2.ONE
	modulate.a = get_parent().get_node("SimulationRuntime/YellowInk").yellow_opacity

func _draw() -> void:
	if black_anchor.is_empty() or is_queued_for_deletion():
		return
	draw_rect(Rect2(Vector2(-4.5, -4.5), Vector2(9.0, 9.0)), Color(0.08, 0.07, 0.02, 1.0), true)
	draw_rect(Rect2(Vector2(-2.5, -2.5), Vector2(5.0, 5.0)), Palette.YELLOW.color, true)

func remove() -> void:
	detach()
	visible = false
	queue_free()

func _exit_tree() -> void:
	detach()

