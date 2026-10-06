@tool
extends "res://addons/pixel_destruction/nodes/pixel_sprite_2d.gd"


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var physics_body = get_parent()
	if physics_body.body == null:
		return
	var pixel_world = physics_body.get_node(physics_body.world_path)
	global_position = pixel_world.to_global(physics_body.body.position)
	global_rotation = pixel_world.global_rotation + physics_body.body.rotation
