extends Node2D

var _rect := Rect2i()
var _active := false


func set_selection(rect: Rect2i) -> void:
	_rect = rect
	_active = rect.size.x > 0 and rect.size.y > 0
	queue_redraw()


func clear_selection() -> void:
	_active = false
	queue_redraw()


func _draw() -> void:
	if not _active:
		return
	var rect := Rect2(_rect)
	draw_rect(rect, Color(0.95, 0.20, 0.12, 0.16), true)
	draw_rect(rect, Color(0.95, 0.20, 0.12, 0.95), false, 2.0)
