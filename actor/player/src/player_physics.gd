@tool
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"
## 玩家、手和连杆的物理节点，分别持有自己的 PBody。

## 所属 PixelWorld 的相对路径，初始化时用于注册该节点的物理体。
@export var world_path := NodePath("..")

#region 碰撞伤害
## 只累计世界结算器给出的伤害；身体像素保持完整，生命和死亡以后接入。
var collision_damage: float = 0.0


func apply_collision_damage(amount: float) -> void:
	collision_damage += maxf(amount, 0.0)
#endregion


func _bake_lazily():
	return get_node(world_path).add_body_node(self)


func collect_shapes() -> Array:
	return [$Shape.get_shape()] if has_node("Shape") else [get_shape()]


func bake():
	var result = super.bake()
	result.position = get_node(world_path).to_local(global_position)
	result.rotation = global_rotation - get_node(world_path).global_rotation
	return result
