@tool
class_name MapTextLabel
extends Label

const GROUP := &"map_text_label"

@export var editor_id := ""


func _enter_tree() -> void:
	add_to_group(GROUP, true)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func pick_rect() -> Rect2:
	return (get_global_transform() * Rect2(Vector2.ZERO, size)).grow(12.0)


func contains_world_point(point: Vector2, margin: float) -> bool:
	var transform := get_global_transform()
	var padding := Vector2(margin / transform.x.length(), margin / transform.y.length())
	return Rect2(Vector2.ZERO, size).grow_individual(padding.x, padding.y, padding.x, padding.y).has_point(transform.affine_inverse() * point)
