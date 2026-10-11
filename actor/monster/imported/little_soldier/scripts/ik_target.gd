@tool
extends Area2D

## 小兵骨骼 IK 目标点。
## 在编辑器中显示为十字圆圈，可直接拖动调整手脚位置；
## 运行时由 little_soldier_rig.gd 读取其 global_position 解算骨骼旋转。

#region 导出参数
@export var target_color := Color(0.1, 0.65, 0.95, 0.95):
	set(value):
		target_color = value
		queue_redraw()

@export_range(8.0, 28.0, 1.0) var target_radius := 15.0:
	set(value):
		target_radius = value
		queue_redraw()
#endregion

#region 内部状态
var _dragging := false
var _drag_offset := Vector2.ZERO
#endregion


func _ready() -> void:
	input_event.connect(_on_input_event)
	queue_redraw()


func _draw() -> void:
	draw_circle(Vector2.ZERO, target_radius, Color(target_color, 0.18))
	draw_arc(Vector2.ZERO, target_radius, 0.0, TAU, 40, target_color, 2.0, true)
	draw_line(Vector2(-6.0, 0.0), Vector2(6.0, 0.0), target_color, 2.0, true)
	draw_line(Vector2(0.0, -6.0), Vector2(0.0, 6.0), target_color, 2.0, true)


func _on_input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_dragging = event.pressed
		if _dragging:
			_drag_offset = global_position - get_global_mouse_position()
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_dragging = false


func _process(_delta: float) -> void:
	if _dragging and not Engine.is_editor_hint():
		global_position = get_global_mouse_position() + _drag_offset
