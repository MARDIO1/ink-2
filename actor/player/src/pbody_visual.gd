@tool
extends "res://addons/pixel_destruction/nodes/pixel_sprite_2d.gd"


## 只画**父刚体认的**形状（PixelBody2D.collect_shapes()）。引擎默认的 _collect() 是
## duck-typing 收兄弟里所有有 build_shape() 的节点 —— Player 下的 Arm（手，rect_size 4x4）
## 因此会被画成 16 个黑像素。物理认什么就画什么，两边不再分叉。
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
