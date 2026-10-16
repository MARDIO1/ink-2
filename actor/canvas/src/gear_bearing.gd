extends "res://ink/yellow/src/hinge.gd"
## 地图齿轮轴：沿用真实 HINGE、成对碰撞排除及碎裂通知。
const BodyNode := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
@export var gear_material := 1
@export var support_material := 1
@export var fixed_to_world := true
@export var wheel_path: NodePath
@export_enum("8:8", "12:12") var teeth := 12
var editor_dragging := false
var _editor_drag_start: Dictionary = {}

func _ready() -> void:
	texture = BEARING
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 10
	world = get_parent().world
	restore.call_deferred()

static func find_material(physics, point: Vector2, material: int, except = null) -> Dictionary:
	for body in physics.bodies:
		if body == except or body.tags.has("living"):
			continue
		var cell := Vector2i(body.to_local(point).floor())
		if has_pixel(body, cell, material):
			return {"body": body, "cell": cell, "local": body.to_local(point)}
	return {}

static func find_support(physics, point: Vector2, except = null) -> Dictionary:
	for body in physics.bodies:
		if body == except or body.tags.has("living"):
			continue
		var cell := Vector2i(body.to_local(point).floor())
		for shape in body.shapes:
			var ink: int = shape.get_pixel(cell.x, cell.y)
			if ink != 0:
				return {"body": body, "cell": cell, "local": body.to_local(point), "material": ink}
	return {}

func _editing() -> bool:
	var creative := get_parent().get_node_or_null("Creative")
	var canvas := get_parent().get_node_or_null("MapCanvas")
	return (creative != null and creative.get("active") == true) \
		or (canvas != null and canvas.get("_map_editor_mode") == true)

func restore() -> void:
	if not is_inside_tree() or is_queued_for_deletion():
		return
	if yellow_anchor.is_empty():
		var wheel := get_node_or_null(wheel_path) if not wheel_path.is_empty() else null
		if wheel != null and wheel.get("body") != null:
			var cell := Vector2i(wheel.body.to_local(yellow_position).floor())
			if has_pixel(wheel.body, cell, gear_material):
				yellow_anchor = {"body": wheel.body, "cell": cell, "local": wheel.body.to_local(yellow_position)}
		if yellow_anchor.is_empty():
			yellow_anchor = find_material(world, yellow_position, gear_material)
	if yellow_anchor.is_empty():
		queue_free()
		return
	if not fixed_to_world and black_anchor.is_empty():
		black_anchor = find_material(world, black_position, support_material, yellow_anchor.body)
	connect_joint()

func connect_joint() -> void:
	if editor_dragging:
		return
	if joint != null and joint.is_active():
		return
	if yellow_anchor.is_empty() or not world.bodies.has(yellow_anchor.body):
		return
	if fixed_to_world or (black_anchor.is_empty() and _editing()):
		joint = world.add_hinge(yellow_anchor.body, null, black_position)
	elif not black_anchor.is_empty():
		joint = world.add_hinge(yellow_anchor.body, black_anchor.body, Stroke.anchor_world(yellow_anchor))
	if joint != null:
		joint.contacts_enabled = false

func _valid(anchor: Dictionary, material: int) -> bool:
	return not anchor.is_empty() and world.bodies.has(anchor.body) \
		and has_pixel(anchor.body, anchor.cell, material)

func _process(_delta: float) -> void:
	if editor_dragging or is_queued_for_deletion() or yellow_anchor.is_empty():
		return
	if not _valid(yellow_anchor, gear_material):
		remove_joint()
		queue_free()
		return
	yellow_position = Stroke.anchor_world(yellow_anchor)
	if not fixed_to_world:
		if not _valid(black_anchor, support_material):
			remove_joint()
			black_anchor = find_material(world, black_position, support_material, yellow_anchor.body)
			if black_anchor.is_empty() and not _editing():
				queue_free()
				return
		if not black_anchor.is_empty():
			# 编辑时支座可以墨化为蓝图；再次固化后连接到新支座。
			if joint != null and (joint.body_a == null or joint.body_b == null):
				remove_joint()
			black_position = Stroke.anchor_world(black_anchor)
	connect_joint()
	position = yellow_position
	rotation = 0.0
	# 破坏后，带轴心的分片可能由保存管线分配了新的节点名称。
	var wheel := get_node_or_null(wheel_path) if not wheel_path.is_empty() else null
	if wheel == null or wheel.get("body") != yellow_anchor.body:
		for node in get_parent().get_children():
			if node is BodyNode \
			and node.body == yellow_anchor.body:
				wheel_path = get_path_to(node)
				break

func editor_hit_test(point: Vector2) -> bool:
	if not _valid(yellow_anchor, gear_material):
		return false
	var body = yellow_anchor.body
	var cell := Vector2i(body.to_local(get_parent().to_local(point)).floor())
	return has_pixel(body, cell, gear_material)

func editor_outline() -> PackedVector2Array:
	if not _valid(yellow_anchor, gear_material):
		return PackedVector2Array()
	var rect: Rect2 = yellow_anchor.body.aabb
	var host := get_parent() as Node2D
	return PackedVector2Array([host.to_global(rect.position),
		host.to_global(Vector2(rect.end.x, rect.position.y)), host.to_global(rect.end),
		host.to_global(Vector2(rect.position.x, rect.end.y))])

func begin_editor_drag() -> bool:
	if not _editing() or editor_dragging or not _valid(yellow_anchor, gear_material):
		return false
	_process(0.0)
	if is_queued_for_deletion():
		return false
	var body = yellow_anchor.body
	_editor_drag_start = {"position": body.position, "rotation": body.rotation,
		"linear": body.linear_velocity, "angular": body.angular_velocity,
		"center": yellow_position, "support_position": black_position,
		"support": black_anchor.duplicate(), "support_material": support_material,
		"world": fixed_to_world, "frozen": body.frozen,
		"had_pause": body.tags.has("editor_physics_paused"),
		"pause": body.tags.get("editor_physics_paused", false)}
	editor_dragging = true
	remove_joint()
	body.tags["editor_physics_paused"] = true
	world.freeze(body)
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	return true

func move_editor_drag(point: Vector2) -> void:
	if not editor_dragging or not _valid(yellow_anchor, gear_material):
		return
	var next: Vector2 = get_parent().to_local(point)
	var body = yellow_anchor.body
	body.position += next - yellow_position
	yellow_position = next
	black_position = next
	_sync_editor_body()

func finish_editor_drag(cancelled := false) -> void:
	if not editor_dragging:
		return
	var body = yellow_anchor.body
	if cancelled:
		body.position = _editor_drag_start.position
		body.rotation = _editor_drag_start.rotation
		body.linear_velocity = _editor_drag_start.linear
		body.angular_velocity = _editor_drag_start.angular
		yellow_position = _editor_drag_start.center
		black_position = _editor_drag_start.support_position
		black_anchor = _editor_drag_start.support
		support_material = _editor_drag_start.support_material
		fixed_to_world = _editor_drag_start.world
	else:
		black_anchor = find_support(world, yellow_position, body)
		fixed_to_world = black_anchor.is_empty()
		support_material = black_anchor.get("material", 0)
		black_position = yellow_position
	if _editor_drag_start.had_pause:
		body.tags["editor_physics_paused"] = _editor_drag_start.pause
	else:
		body.tags.erase("editor_physics_paused")
	if not _editor_drag_start.frozen:
		world.unfreeze(body)
	editor_dragging = false
	_editor_drag_start.clear()
	_sync_editor_body()
	connect_joint()

func _sync_editor_body() -> void:
	var body = yellow_anchor.body
	body.update_aabb()
	position = yellow_position
	var wheel := get_node_or_null(wheel_path)
	if wheel is BodyNode and wheel.body == body:
		wheel.position = body.position
		wheel.rotation = body.rotation
	get_parent().renderer.sync(body)

func rebind(physics, body, pieces: Array) -> void:
	for pair in [[yellow_anchor, gear_material], [black_anchor, support_material]]:
		var anchor: Dictionary = pair[0]
		if anchor.is_empty() or anchor.body != body:
			continue
		var point: Vector2 = Stroke.anchor_world(anchor)
		var replacement: Dictionary = {}
		for piece in pieces:
			var cell := Vector2i(piece.to_local(point).floor())
			if physics.bodies.has(piece) and has_pixel(piece, cell, pair[1]):
				replacement = {"body": piece, "cell": cell, "local": piece.to_local(point)}
		if replacement.is_empty():
			remove_joint()
			queue_free()
			return
		anchor.merge(replacement, true)
		remove_joint()
	connect_joint()

func _exit_tree() -> void:
	remove_joint()
	yellow_anchor.clear()
	black_anchor.clear()
	world = null
