@tool
class_name MapTextLabel
extends Label

const GROUP := &"map_text_label"

@export var editor_id := ""


func _enter_tree() -> void:
	add_to_group(GROUP, true)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func pick_rect() -> Rect2:
	var displayed_size: Vector2 = size * get_global_transform().get_scale().abs()
	return Rect2(global_position, displayed_size).grow(12.0)
