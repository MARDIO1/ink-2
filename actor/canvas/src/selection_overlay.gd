extends Node2D

var _rect := Rect2i()
var _active := false
var _circle := false


func set_selection(rect: Rect2i, circle := false) -> void:
	_rect = rect
	_circle = circle
	_active = rect.size.x > 0 and rect.size.y > 0
	queue_redraw()


func clear_selection() -> void:
	_active = false
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	var rect := Rect2(_rect)
	if _circle:
		var center := rect.position + rect.size * 0.5
		var radius := rect.size.x * 0.5
		draw_circle(center, radius, Color(0.20, 0.72, 0.95, 0.12))
		draw_arc(center, radius, 0.0, TAU, 64, Color(0.10, 0.55, 0.86, 0.95), 2.0, true)
		return
	draw_rect(rect, Color(0.20, 0.72, 0.95, 0.12), true)
	draw_rect(rect, Color(0.10, 0.55, 0.86, 0.95), false, 2.0)
