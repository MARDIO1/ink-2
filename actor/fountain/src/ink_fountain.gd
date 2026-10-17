@tool
class_name InkFountain
extends Node2D
## 无碰撞墨泉：固定尺寸贴图；运行时读取 PixelWorld 玩家范围并持续补满各色墨水。

const GROUP := &"ink_fountain"
const InkPalette := preload("res://ink/general/src/ink_palette.gd")

@export var refill_radius := Vector2(150.0, 170.0)
@export var refill_per_second := 9000.0
@export var editor_pick_size := Vector2(270.0, 230.0)

func _enter_tree() -> void:
	add_to_group(GROUP, true)


func _ready() -> void:
	set_physics_process(not Engine.is_editor_hint())


func contains_world_point(point: Vector2) -> bool:
	return Rect2(-editor_pick_size * 0.5, editor_pick_size).has_point(to_local(point))


func _physics_process(delta: float) -> void:
	var player := get_tree().get_first_node_in_group(&"player")
	var body = player.get("body") if player != null else null
	if body == null:
		return
	var nearest := Vector2(
		clampf(global_position.x, body.aabb.position.x, body.aabb.end.x),
		clampf(global_position.y, body.aabb.position.y, body.aabb.end.y)
	)
	var local_distance := (nearest - global_position) / refill_radius
	if local_distance.length_squared() > 1.0:
		return
	var health := player.get_node("InkHealth")
	for index in InkPalette.ink_count():
		var material_id := InkPalette.material_id_of(InkPalette.ink_at(index))
		health.add(material_id, refill_per_second * delta)
