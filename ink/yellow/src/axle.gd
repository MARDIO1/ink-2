extends "res://ink/yellow/src/hinge.gd"
## 黄色轴：只负责铰接、碎裂重绑定及旧地图兼容，不负责齿轮编辑。
const BodyNode := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
@export var gear_material := 1
@export var support_material := 1
@export var fixed_to_world := true
## 轴心已经压在真实黄墨上（轮子套在轴杆/杠杆上）时不再画轴承贴图，
## 否则会在黄墨上面凭空多出一个黄色轴心。
@export var hide_bearing := false
@export var wheel_path: NodePath
## 新轴承记住明确的支座节点；旧地图没有这两个字段时仍走位置搜索。
@export var support_path: NodePath
## true = 由手动放置/蓝图/撤销明确创建；重载时不再按“中心附近第一个物体”重新挑选。
@export var explicit := false
@export var saved_local_anchors := false
@export var wheel_local := Vector2.ZERO
@export var support_local := Vector2.ZERO
@export_enum("8:8", "12:12") var teeth := 12
func _ready() -> void:
	_sync_bearing()
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 10
	world = get_parent().world
	restore.call_deferred()

## 黄墨已经承担轴杆的外观。旧地图/蓝图即使没有 hide_bearing 字段也不应叠图。
func _sync_bearing() -> void:
	texture = null if hide_bearing or (not fixed_to_world and support_material == Palette.YELLOW.id) else BEARING

static func find_material(physics, point: Vector2, material: int, except = null,
		skip: Dictionary = {}) -> Dictionary:
	for body in physics.bodies:
		if body == except or skip.has(body) or body.tags.has("living"):
			continue
		var cell := Vector2i(body.to_local(point).floor())
		if has_pixel(body, cell, material):
			return {"body": body, "cell": cell, "local": body.to_local(point)}
	return {}

func _editing() -> bool:
	var creative := get_parent().get_node_or_null("Creative")
	var canvas := get_parent().get_node_or_null("MapCanvas")
	return (creative != null and creative.get("active") == true) \
		or (canvas != null and canvas.get("_map_editor_mode") == true)

func restore() -> void:
	var level := get_parent()
	if level != null and level.get("body_bake_pending") == true:
		await Signal(level, &"body_bake_completed")
	# 分帧烘焙完成后刚体才齐全；仍取不到就再等几帧，而不是立刻删掉这个轴。
	for attempt in 240:
		if not is_inside_tree() or is_queued_for_deletion():
			return
		_sync_bearing()
		if explicit:
			_bind_explicit()
		elif yellow_anchor.is_empty():
			var wheel := get_node_or_null(wheel_path) if not wheel_path.is_empty() else null
			if wheel != null and wheel.get("body") != null:
				var cell := Vector2i(wheel.body.to_local(yellow_position).floor())
				if has_pixel(wheel.body, cell, gear_material):
					yellow_anchor = {"body": wheel.body, "cell": cell, "local": wheel.body.to_local(yellow_position)}
			if yellow_anchor.is_empty():
				yellow_anchor = find_material(world, yellow_position, gear_material, null)
			if not yellow_anchor.is_empty() and not fixed_to_world and black_anchor.is_empty():
				black_anchor = find_material(world, black_position, support_material, yellow_anchor.body)
		if not yellow_anchor.is_empty():
			if explicit:
				if fixed_to_world or not black_anchor.is_empty():
					connect_joint()
					return
			else:
				if not fixed_to_world and black_anchor.is_empty():
					black_anchor = find_material(world, black_position, support_material, yellow_anchor.body)
				connect_joint()
				return
		await get_tree().physics_frame
	# 找不到轴心时保留节点（隐藏），别把装置连接永久删掉。
	visible = false
	push_warning("[Axle] 未找到轴心，已保留待修复: %s" % yellow_position)


## 明确连接只接受生成时记下的轮体/支座身份；找不到就继续等待，不另找替身。
func _bind_explicit() -> void:
	if yellow_anchor.is_empty() and not wheel_path.is_empty():
		var wheel := get_node_or_null(wheel_path)
		if wheel != null and wheel.get("body") != null:
			var body = wheel.body
			var local: Vector2 = wheel_local if saved_local_anchors else body.to_local(yellow_position)
			var cell := Vector2i(local.floor())
			if has_pixel(body, cell, gear_material):
				yellow_anchor = {"body": body, "cell": cell, "local": local}
	if not fixed_to_world and black_anchor.is_empty() and not support_path.is_empty():
		var support := get_node_or_null(support_path)
		if support != null and support.get("body") != null:
			var body = support.body
			var local: Vector2 = support_local if saved_local_anchors else body.to_local(black_position)
			var cell := Vector2i(local.floor())
			if has_pixel(body, cell, support_material):
				black_anchor = {"body": body, "cell": cell, "local": local}

func connect_joint() -> void:
	if joint != null and joint.is_active():
		return
	if yellow_anchor.is_empty() or not world.bodies.has(yellow_anchor.body):
		return
	if fixed_to_world:
		joint = world.add_hinge(yellow_anchor.body, null, black_position)
	elif not black_anchor.is_empty() and black_anchor.body != yellow_anchor.body:
		joint = world.add_hinge(yellow_anchor.body, black_anchor.body, Stroke.anchor_world(yellow_anchor))
	if joint != null:
		joint.contacts_enabled = false

func _valid(anchor: Dictionary, material: int) -> bool:
	return not anchor.is_empty() and world.bodies.has(anchor.body) \
		and has_pixel(anchor.body, anchor.cell, material)

func _process(_delta: float) -> void:
	if is_queued_for_deletion() or yellow_anchor.is_empty():
		return
	if not _valid(yellow_anchor, gear_material):
		remove_joint()
		queue_free()
		return
	wheel_local = Vector2(yellow_anchor.local)
	saved_local_anchors = true
	yellow_position = Stroke.anchor_world(yellow_anchor)
	if not fixed_to_world:
		if not _valid(black_anchor, support_material):
			remove_joint()
			if explicit:
				# 明确连接不另找替身：支座真的没了就解除连接。
				queue_free()
				return
			black_anchor = find_material(world, black_position, support_material,
				yellow_anchor.body)
			if black_anchor.is_empty() and not _editing():
				queue_free()
				return
		if not black_anchor.is_empty():
			# 编辑时支座可以墨化为蓝图；再次固化后连接到新支座。
			if joint != null and (joint.body_a == null or joint.body_b == null):
				remove_joint()
			support_local = Vector2(black_anchor.local)
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
	if not fixed_to_world and not black_anchor.is_empty():
		var support := get_node_or_null(support_path) if not support_path.is_empty() else null
		if support == null or support.get("body") != black_anchor.body:
			for node in get_parent().get_children():
				if node is BodyNode and node.body == black_anchor.body:
					support_path = get_path_to(node)
					break



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

