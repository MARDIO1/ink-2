@tool
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"
## 玩家、手和连杆的物理节点，分别持有自己的 PBody。
const PixelShape2D := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")

## 所属 PixelWorld 的相对路径，初始化时用于注册该节点的物理体。
@export var world_path := NodePath("..")
## 形状级密度倍率（质量 = Σ 材质密度 × 它）。物理剪影用"隐形墨水"这类基准密度 1.0 的
## 材质时，靠它把密度拉回本物体本来该有的值（手 = 0.1344），质量/质心/惯量逐位不变。
@export var shape_density_scale := 1.0
## 生物实体标记；反向栅格化（回到画布）时跳过。与 CanvasSolid 的同名标签对应。
const LIVING_TAG := "living"

#region 碰撞伤害
## 只累计世界结算器给出的伤害；身体像素保持完整，生命和死亡以后接入。
var collision_damage: float = 0.0


func apply_collision_damage(amount: float) -> void:
	collision_damage += maxf(amount, 0.0)
#endregion


func _bake_lazily():
	return get_node(world_path).add_body_node(self)


func collect_shapes() -> Array:
	var shapes: Array = []
	for child in get_children():
		# 只烘焙直接形状；嵌套的 Arm/Hand 各自持有独立 PBody。
		if child.get_script() == PixelShape2D:
			shapes.append(child.get_shape())
	if shapes.is_empty():
		shapes = [get_shape()]
	for shape in shapes:
		shape.density_scale = shape_density_scale
	return shapes


func bake():
	var result = super.bake()
	result.position = get_node(world_path).to_local(global_position)
	result.rotation = global_rotation - get_node(world_path).global_rotation
	result.tags[LIVING_TAG] = true
	return result
