@tool
extends Area2D
class_name InkmanIKTarget

@export var target_color := Color("35b8d4"):
	set(value):
		target_color = value
		queue_redraw()
@export_range(8.0, 40.0, 1.0) var target_radius := 17.0:
	set(value):
		target_radius = value
		queue_redraw()

var dragging := false


func _ready() -> void:
	input_pickable = true
	queue_redraw()


func _draw() -> void:
	var fill := target_color
	fill.a = 0.24 if not dragging else 0.46
	draw_circle(Vector2.ZERO, target_radius, fill)
	draw_arc(Vector2.ZERO, target_radius, 0.0, TAU, 32, target_color, 2.0, true)
	draw_line(Vector2(-22.0, 0.0), Vector2(22.0, 0.0), target_color, 1.5, true)
	draw_line(Vector2(0.0, -22.0), Vector2(0.0, 22.0), target_color, 1.5, true)
	draw_circle(Vector2.ZERO, 3.0, target_color)


func _input_event(_viewport: Node, event: InputEvent, _shape_idx: int) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
		queue_redraw()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and dragging:
		global_position = get_global_mouse_position()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		dragging = false
		queue_redraw()
