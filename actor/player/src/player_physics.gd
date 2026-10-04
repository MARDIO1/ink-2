@tool
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"
## 手和身体不适是一个一起的

@export var world_path := NodePath("..")


func _bake_lazily():
	return get_node(world_path).add_body_node(self)


func collect_shapes() -> Array:
	return [$Shape.get_shape()] if has_node("Shape") else [get_shape()]


func bake():
	var result = super.bake()
	result.position = get_node(world_path).to_local(global_position)
	result.rotation = global_rotation - get_node(world_path).global_rotation
	return result
