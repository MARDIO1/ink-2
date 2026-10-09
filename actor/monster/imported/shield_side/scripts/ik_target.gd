@tool
extends Area2D

@export var target_color := Color(0.18, 0.72, 0.95, 0.92):
	set(value):
		target_color = value
		queue_redraw()
@export_range(8.0, 40.0, 1.0) var target_radius := 18.0:
	set(value):
		target_radius = value
		queue_redraw()

var _dragging := false
var _drag_offset := Vector2.ZERO


func _ready() -> void:
	input_event.connect(_on_input_event)
	queue_redraw()


func _draw() -> void:
	draw_circle(Vector2.ZERO, target_radius, Color(target_color, 0.18))
	draw_arc(Vector2.ZERO, target_radius, 0.0, TAU, 40, target_color, 2.0, true)
	draw_line(Vector2(-7, 0), Vector2(7, 0), target_color, 2.0, true)
	draw_line(Vector2(0, -7), Vector2(0, 7), target_color, 2.0, true)


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

