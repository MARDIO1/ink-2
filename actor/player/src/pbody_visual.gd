@tool
extends "res://addons/pixel_destruction/nodes/pixel_sprite_2d.gd"


## 使用父刚体的形状集合，避免把嵌套的 Arm/Hand 画进玩家主体。
func _collect() -> Array:
	var p := get_parent()
	if p == null or not p.has_method("collect_shapes"):
		return super()
	return p.collect_shapes()


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var physics_body = get_parent()
	if physics_body.body == null:
		return
	var pixel_world = physics_body.get_node(physics_body.world_path)
	global_position = pixel_world.to_global(physics_body.body.position)
	global_rotation = pixel_world.global_rotation + physics_body.body.rotation
