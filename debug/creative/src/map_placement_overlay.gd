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
			_draw_checkpoint_area(point)
	for canvas in play_canvases:
		if is_instance_valid(canvas):
			_draw_canvas(canvas)
	if is_instance_valid(selected) and selected.has_method("editor_outline"):
		var outline: PackedVector2Array = selected.editor_outline()
		for index in outline.size():
			draw_line(to_local(outline[index]), to_local(outline[(index + 1) % outline.size()]), SELECTED_COLOR, 2.0, true)
		var center := to_local(selected.global_position)
		draw_arc(center, 7.0, 0.0, TAU, 24, CANVAS_COLOR, 2.0, true)
		draw_line(center - Vector2(11, 0), center + Vector2(11, 0), CANVAS_COLOR, 1.0, true)
		draw_line(center - Vector2(0, 11), center + Vector2(0, 11), CANVAS_COLOR, 1.0, true)


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


## 出生标记与脚底触发区分开显示，双层布局可以直接检查区域是否跨层。
func _draw_checkpoint_area(point: Marker2D) -> void:
	var controller := get_parent().get_parent().get_node_or_null("Player/FallDeath")
	if controller == null:
		return
	if not controller.checkpoint_area(point).has_area():
		return
	var corners: PackedVector2Array = controller.checkpoint_polygon(point)
	for index in corners.size():
		corners[index] = to_local(corners[index])
	draw_colored_polygon(corners, Color(RESPAWN_COLOR, 0.08))
	for index in corners.size():
		draw_line(corners[index], corners[(index + 1) % corners.size()], RESPAWN_COLOR, 2.0, true)
	var center := (corners[0] + corners[2]) * 0.5
	draw_line(to_local(point.global_position), center, Color(RESPAWN_COLOR, 0.5), 1.0, true)
	draw_string(ThemeDB.fallback_font, corners[0] - Vector2(0, 7), "落地激活", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, RESPAWN_COLOR)


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
