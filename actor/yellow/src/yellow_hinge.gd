extends Sprite2D
## 两个真实像素锚点；复用现有 HINGE 与碎裂通知，不另设轴系耐久度。
const Palette := preload("res://ink/src/ink_palette.gd")
const Stroke := preload("res://actor/yellow/src/yellow_stroke.gd")
const BEARING := preload("res://actor/yellow/asset/bearing.svg")
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
	if not yellow_anchor.is_empty():
		return
	yellow_anchor = find_yellow(world, yellow_position)
	black_anchor = Stroke.find_anchor(world, black_position)
	if yellow_anchor.is_empty() or black_anchor.is_empty():
		queue_free()
	else:
		connect_joint()

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
			queue_free()
			return
		anchor.merge(replacement, true)
		remove_joint()
	connect_joint()

func _process(_delta: float) -> void:
	if yellow_anchor.is_empty() or black_anchor.is_empty() or is_queued_for_deletion():
		return
	if not world.bodies.has(yellow_anchor.body) or not world.bodies.has(black_anchor.body) \
	or not has_pixel(yellow_anchor.body, yellow_anchor.cell, Palette.YELLOW.id) \
	or not has_pixel(black_anchor.body, black_anchor.cell, Palette.BLACK.id):
		remove_joint()
		queue_free()
		return
	connect_joint()
	yellow_position = Stroke.anchor_world(yellow_anchor)
	black_position = Stroke.anchor_world(black_anchor)
	position = yellow_position
	rotation = 0.0
	modulate.a = get_parent().get_node("SimulationRuntime/YellowInk").yellow_opacity

func remove_joint() -> void:
	if joint != null and joint.is_active():
		joint.remove()
	joint = null

func _exit_tree() -> void:
	remove_joint()
