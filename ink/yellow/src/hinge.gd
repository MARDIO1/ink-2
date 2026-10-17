extends Sprite2D
## 两个真实像素锚点；复用现有 HINGE 与碎裂通知，不另设轴系耐久度。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const BEARING := preload("res://ink/yellow/asset/bearing.svg")
@export var yellow_position := Vector2.ZERO
@export var black_position := Vector2.ZERO
var yellow_anchor: Dictionary = {}
var black_anchor: Dictionary = {}
var joint = null
var world = null

func _ready() -> void:
	texture = BEARING
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 10
	top_level = true
	# 场景恢复使用延迟锚点绑定；绑定前不能让贴图在默认原点短暂可见。
	visible = false
	world = get_parent().world
	call_deferred("restore")

static func find_yellow(physics, point: Vector2) -> Dictionary:
	for body in physics.bodies:
		var cell := Vector2i(body.to_local(point).floor())
		if has_pixel(body, cell, Palette.YELLOW.id):
			return {"body": body, "cell": cell, "local": body.to_local(point)}
	return {}

static func has_pixel(body, cell: Vector2i, material: int) -> bool:
	for shape in body.shapes:
		if shape.get_pixel(cell.x, cell.y) == material:
			return true
	return false

func restore() -> void:
	if not yellow_anchor.is_empty() and not black_anchor.is_empty():
		return
	var level := get_parent()
	# 关卡重进时刚体是逐帧烘焙的（bake_bodies_per_frame 默认 1，第二页要几十帧）。
	# 手动轴承必须等全部刚体落地再找锚点；否则会在锚点还不存在时把自己删掉，
	# 黄墨因此丢掉连接信息，下一次固化就会把重叠段当冲突裁掉。
	if level != null and level.get("body_bake_pending") == true:
		await Signal(level, &"body_bake_completed")
	for attempt in 240:
		if world == null and is_inside_tree():
			world = get_parent().world
		if _bind_anchors():
			return
		if not is_inside_tree() or is_queued_for_deletion():
			return
		await get_tree().physics_frame
	# 反复找不到也不能自毁：节点留着（隐藏），装置还有机会被重新连回去。
	visible = false
	push_warning("[Hinge] 未找到锚点，已保留待修复: %s" % yellow_position)


func _bind_anchors() -> bool:
	if yellow_anchor.is_empty() and world != null:
		yellow_anchor = find_yellow(world, yellow_position)
	if black_anchor.is_empty() and world != null:
		black_anchor = Stroke.find_anchor(world, black_position)
	if yellow_anchor.is_empty() or black_anchor.is_empty():
		return false
	connect_joint()
	_sync_visual()
	visible = true
	return true

func connect_joint() -> void:
	if joint != null and joint.is_active():
		return
	joint = world.add_hinge(yellow_anchor.body, black_anchor.body, Stroke.anchor_world(yellow_anchor))
	joint.contacts_enabled = false

func rebind(physics, body, pieces: Array) -> void:
	for pair in [[yellow_anchor, Palette.YELLOW.id], [black_anchor, Palette.BLACK.id]]:
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
			visible = false
			queue_free()
			return
		anchor.merge(replacement, true)
		remove_joint()
	connect_joint()
	_sync_visual()

func _process(_delta: float) -> void:
	if yellow_anchor.is_empty() or black_anchor.is_empty() or is_queued_for_deletion():
		return
	if not world.bodies.has(yellow_anchor.body) or not world.bodies.has(black_anchor.body) \
	or not has_pixel(yellow_anchor.body, yellow_anchor.cell, Palette.YELLOW.id) \
	or not has_pixel(black_anchor.body, black_anchor.cell, Palette.BLACK.id):
		remove_joint()
		visible = false
		queue_free()
		return
	connect_joint()
	_sync_visual()

func _sync_visual() -> void:
	yellow_position = Stroke.anchor_world(yellow_anchor)
	black_position = Stroke.anchor_world(black_anchor)
	var display_position := (yellow_position + black_position) * 0.5
	var world_node := get_parent() as Node2D
	global_position = world_node.to_global(display_position) if world_node != null else display_position
	global_rotation = 0.0
	global_scale = Vector2.ONE
	var yellow_ink := get_parent().get_node_or_null("SimulationRuntime/YellowInk")
	modulate.a = yellow_ink.yellow_opacity if yellow_ink != null else 1.0

func remove_joint() -> void:
	if joint != null and joint.is_active():
		joint.remove()
	joint = null

func _exit_tree() -> void:
	remove_joint()
