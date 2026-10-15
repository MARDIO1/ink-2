extends Node2D
## 箭头只记录一个黑色像素锚点；不创建刚体或关节。
const Palette := preload("res://ink/src/ink_palette.gd")
const Anchor := preload("res://actor/yellow/src/yellow_stroke.gd")

#region 数据与显示
@export var tip := Vector2.ZERO
@export var brush_width: int = 7
@export var active := false
@export var paid := false
@export var area: int = 0
@export var source_canvas: NodePath
var body = null
var cell := Vector2i.ZERO
var anchor_local := Vector2.ZERO
var source_surface = null
var preview := false
var received_power := 0.0
var used_power := 0.0
var applied_force := 0.0

func _draw() -> void:
	var color: Color = Palette.BLUE.color
	if tip.length() > 0.01:
		var direction := tip.normalized()
		var back := tip - direction * minf(tip.length(), maxf(6.0, brush_width * 2.0))
		draw_line(Vector2.ZERO, back, color, brush_width)
		draw_colored_polygon(PackedVector2Array([tip, back + direction.orthogonal() * brush_width, back - direction.orthogonal() * brush_width]), color)

func _ready() -> void:
	z_index = 9
	if not source_canvas.is_empty():
		source_surface = get_parent().get_node_or_null(source_canvas)
	if active:
		call_deferred("restore")

func restore() -> void:
	if body != null:
		return
	var physics = get_parent().get("world")
	if physics == null:
		return
	var anchor: Dictionary = Anchor.find_anchor(physics, position)
	if anchor.is_empty():
		queue_free()
	else:
		bind(anchor)

func bind(anchor: Dictionary) -> void:
	body = anchor.body
	cell = anchor.cell
	anchor_local = anchor.local
	rotation -= body.rotation
	# rotation 在激活时转换为刚体局部方向；每帧同步后另存该方向。
	set_meta("local_angle", rotation)
	active = true
	sync_pose()

func sync_pose() -> void:
	if body == null:
		return
	position = body.to_world(anchor_local)
	rotation = body.rotation + float(get_meta("local_angle", 0.0))

func _process(_delta: float) -> void:
	if active and body != null:
		sync_pose()

func valid(physics) -> bool:
	return body != null and physics.bodies.has(body) and Anchor.has_black(body, cell)

func rebind(physics, old_body, pieces: Array) -> void:
	if body != old_body:
		return
	sync_pose()
	var point: Vector2 = position
	var direction: float = rotation
	for piece in pieces:
		var at := Vector2i(piece.to_local(point).floor())
		if physics.bodies.has(piece) and Anchor.has_black(piece, at):
			rotation = direction
			bind({"body": piece, "cell": at, "local": piece.to_local(point)})
			return
	body = null
	queue_free()
#endregion
