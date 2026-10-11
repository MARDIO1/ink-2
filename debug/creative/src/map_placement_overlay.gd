extends Node2D
## 地图编辑器中的布局辅助层。只在运行时显示，不写入关卡场景。

const SPAWN_COLOR := Color(0.2, 0.9, 0.35, 1.0)
const RESPAWN_COLOR := Color(1.0, 0.65, 0.15, 1.0)
const CANVAS_COLOR := Color(0.15, 0.75, 1.0, 0.9)
const SELECTED_COLOR := Color.WHITE

var spawn_point: Marker2D
var respawn_points: Array = []
var play_canvases: Array = []
var selected = null


func configure(spawn: Marker2D, respawns: Array, canvases: Array, selected_node = null) -> void:
	spawn_point = spawn
	respawn_points = respawns
	play_canvases = canvases
	selected = selected_node
	queue_redraw()


func _draw() -> void:
	if is_instance_valid(spawn_point):
		_draw_point(spawn_point, SPAWN_COLOR, "出生")
	for point in respawn_points:
		if is_instance_valid(point):
			_draw_point(point, RESPAWN_COLOR, "复活")
	for canvas in play_canvases:
		if is_instance_valid(canvas):
			_draw_canvas(canvas)


func _draw_point(point: Node2D, color: Color, label: String) -> void:
	var center := to_local(point.global_position)
	var radius := 13.0
	if point == selected:
		draw_circle(center, radius + 5.0, Color(0.0, 0.0, 0.0, 0.6))
		draw_arc(center, radius + 5.0, 0.0, TAU, 32, SELECTED_COLOR, 3.0, true)
	draw_circle(center, radius, Color(color, 0.22))
	draw_arc(center, radius, 0.0, TAU, 32, color, 3.0, true)
	draw_line(center - Vector2(18.0, 0.0), center + Vector2(18.0, 0.0), color, 2.0, true)
	draw_line(center - Vector2(0.0, 18.0), center + Vector2(0.0, 18.0), color, 2.0, true)
	draw_string(ThemeDB.fallback_font, center + Vector2(18.0, -10.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, 18, color)


func _draw_canvas(canvas: Node2D) -> void:
	if canvas.get("canvas_size") == null:
		return
	var size := Vector2(canvas.get("canvas_size"))
	var corners := PackedVector2Array([
		to_local(canvas.to_global(Vector2.ZERO)),
		to_local(canvas.to_global(Vector2(size.x, 0.0))),
		to_local(canvas.to_global(size)),
		to_local(canvas.to_global(Vector2(0.0, size.y))),
	])
	var color := SELECTED_COLOR if canvas == selected else CANVAS_COLOR
	for index in corners.size():
		draw_line(corners[index], corners[(index + 1) % corners.size()], color, 4.0 if canvas == selected else 2.0, true)
	draw_string(
		ThemeDB.fallback_font,
		corners[0] + Vector2(8.0, 24.0),
		str(canvas.name),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1.0,
		18,
		color
	)
