@tool
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"
## 玩家、手和连杆共用的 PixelBody2D 基类。
const PixelShape2D := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")

## 所属 PixelWorld 的相对路径。
@export var world_path := NodePath("..")
## 只在玩家根节点赋值；手和连杆沿用各自场景参数。
@export var controller_config: Resource
## 应用于所有直接子形状的密度倍率。
@export var shape_density_scale := 1.0
## 生物实体标记；反向栅格化时跳过。
const LIVING_TAG := "living"

#region 碰撞伤害
## 累计世界结算器给出的伤害，作为调试统计；实际生命值同步交给 InkHealth。
var collision_damage: float = 0.0
## 粒子等表现层连接这里；每个 impact 含 position、normal、amount、impulse、attacker_material。
signal collision_damaged(amount: float, impacts: Array)


func apply_collision_damage(amount: float, impacts: Array = []) -> void:
	var damage: float = maxf(amount, 0.0)
	collision_damage += damage
	if damage <= 0.0:
		return
	var health := get_node_or_null("InkHealth")
	if health != null:
		health.damage(damage)
	collision_damaged.emit(damage, impacts)
#endregion


func _bake_lazily():
	return get_node(world_path).add_body_node(self)


func collect_shapes() -> Array:
	if controller_config != null:
		shape_density_scale = controller_config.body_density_scale
	var shapes: Array = []
	for child in get_children():
		# Arm 和 Hand 是独立刚体，不属于玩家主体形状。
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
