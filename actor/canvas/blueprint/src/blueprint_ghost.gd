extends Node2D
var texture: ImageTexture
var extent := Vector2.ZERO
var allowed := false

func _draw() -> void:
	if texture == null:
		return
	var color := Color(0.10, 0.55, 0.86) if allowed else Color(0.80, 0.20, 0.16)
	draw_texture(texture, Vector2.ZERO, Color(1, 1, 1, 0.60))
	draw_rect(Rect2(Vector2.ZERO, extent), Color(color, 0.10))
	draw_rect(Rect2(Vector2.ZERO, extent), color, false, 2.0)
