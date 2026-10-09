@tool
class_name MapMonster
extends Node2D

## 地图编辑器可放置的小怪外观节点。角色素材仍保留各自的骨骼与待机动画，
## 这里只负责关掉素材工程里的演示 UI / IK 鼠标控制，并提供统一的保存标识。

const GROUP := &"map_monster"

enum Kind { SHIELD_SIDE, LITTLE_SOLDIER, BOMB_SIDE }

@export var kind: Kind = Kind.SHIELD_SIDE
@export var display_name := "小怪"
@export_range(16.0, 256.0, 1.0) var editor_pick_radius := 72.0
@export var editor_id := ""
## 运行时的受击感来自玩家手部的真实物理速度/质量，而不是墨水像素破坏。
@export_range(12.0, 512.0, 1.0) var hit_radius := 78.0
@export_range(1.0, 200.0, 1.0) var minimum_hit_speed := 45.0
@export_range(0.0, 4.0, 0.05) var impact_response := 1.0

const HIT_COOLDOWN := 0.12
const MAX_IMPULSE := 2400.0
const VISUAL_SPRING := 34.0
const VISUAL_DAMPING := 9.0
const BONE_SPRING := 42.0
const BONE_DAMPING := 10.0

var _visual: Node2D
var _visual_base_position := Vector2.ZERO
var _visual_base_rotation := 0.0
var _kick_offset := Vector2.ZERO
var _kick_velocity := Vector2.ZERO
var _twist := 0.0
var _twist_velocity := 0.0
var _hit_cooldown := 0.0
var _bone_twist: Dictionary = {}
var _bone_velocity: Dictionary = {}
var _bone_last_applied: Dictionary = {}


func _enter_tree() -> void:
	add_to_group(GROUP, true)
	_configure_imported_visual()


func _ready() -> void:
	# 源素材的 IK/AnimationPlayer 通常在默认优先级更新；受击偏移放在最后叠加，
	# 不会破坏它们的待机姿势和动画。
	process_priority = 100
	_visual = get_node_or_null("Visual") as Node2D
	if _visual != null:
		_visual_base_position = _visual.position
		_visual_base_rotation = _visual.rotation
		for bone in _visual.find_children("*", "Bone2D", true, false):
			_bone_twist[bone] = 0.0
			_bone_velocity[bone] = 0.0
			_bone_last_applied[bone] = 0.0


func _physics_process(delta: float) -> void:
	_hit_cooldown = maxf(0.0, _hit_cooldown - delta)
	if _hit_cooldown > 0.0:
		return
	var player := get_tree().get_first_node_in_group(&"player")
	if player == null:
		return
	var hand := player.get_node_or_null("Arm/Hand")
	if hand == null:
		return
	var hand_body = hand.get("body")
	if hand_body == null or not hand_body.has_method("com_world"):
		return
	var hand_position: Vector2 = hand_body.com_world()
	var radius := hit_radius * maxf(absf(global_scale.x), absf(global_scale.y))
	if hand_position.distance_squared_to(global_position) > radius * radius:
		return
	var velocity: Vector2 = hand_body.linear_velocity
	if velocity.length() < minimum_hit_speed:
		return
	# PBody 的质量和速度均来自当前物理步；这不是鼠标速度或固定播放特效。
	var mass: float = maxf(float(hand_body.mass), 0.001)
	var impulse := velocity * minf(mass * 0.006, 8.0)
	receive_impact(hand_position, impulse)


## 外部攻击也可调用此入口。冲量的方向决定整体后仰和各骨骼的扭转方向。
func receive_impact(world_point: Vector2, impulse: Vector2) -> void:
	if _visual == null or impulse.is_zero_approx() or impact_response <= 0.0:
		return
	var capped := impulse.limit_length(MAX_IMPULSE) * impact_response
	var strength := capped.length()
	if strength <= 0.001:
		return
	_hit_cooldown = HIT_COOLDOWN
	_kick_velocity += capped / maxf(70.0 + strength * 0.08, 1.0)
	var lever := world_point - global_position
	_twist_velocity += clampf(lever.cross(capped) * 0.000018, -5.0, 5.0)
	for key in _bone_twist:
		var bone := key as Bone2D
		if bone == null or not is_instance_valid(bone):
			continue
		var distance: float = bone.global_position.distance_to(world_point)
		var falloff: float = 1.0 / (1.0 + distance / maxf(hit_radius, 1.0))
		var bone_lever: Vector2 = bone.global_position - world_point
		var angular_kick: float = bone_lever.cross(capped) * 0.000022 * falloff
		_bone_velocity[bone] = clampf(float(_bone_velocity[bone]) + angular_kick, -6.0, 6.0)


func _process(delta: float) -> void:
	if _visual == null:
		return
	# 二阶弹簧：受力时后仰、松手后自然回弹，不移动地图节点本身。
	_kick_velocity += (-_kick_offset * VISUAL_SPRING - _kick_velocity * VISUAL_DAMPING) * delta
	_kick_offset += _kick_velocity * delta
	_twist_velocity += (-_twist * VISUAL_SPRING - _twist_velocity * VISUAL_DAMPING) * delta
	_twist += _twist_velocity * delta
	_visual.position = _visual_base_position + _kick_offset
	_visual.rotation = _visual_base_rotation + _twist
	for key in _bone_twist.keys():
		var bone := key as Bone2D
		if bone == null or not is_instance_valid(bone):
			_bone_twist.erase(key)
			_bone_velocity.erase(key)
			_bone_last_applied.erase(key)
			continue
		# 先撤掉上一帧的附加偏移，再叠加本帧弹簧解；源动画/IK 仍控制基础姿势。
		var previous: float = float(_bone_last_applied[bone])
		bone.rotation -= previous
		var angle: float = float(_bone_twist[bone])
		var velocity: float = float(_bone_velocity[bone])
		velocity += (-angle * BONE_SPRING - velocity * BONE_DAMPING) * delta
		angle += velocity * delta
		_bone_twist[bone] = angle
		_bone_velocity[bone] = velocity
		bone.rotation += angle
		_bone_last_applied[bone] = angle


func _configure_imported_visual() -> void:
	var visual := get_node_or_null("Visual") as Node2D
	if visual == null:
		return
	_set_property_if_present(visual, &"show_ik_targets", false)
	_set_property_if_present(visual, &"show_targets", false)
	_set_property_if_present(visual, &"center_when_run_alone", false)
	_set_property_if_present(visual, &"mouse_hand_follows_cursor", false)
	visual.set_process_input(false)
	visual.set_process_unhandled_input(false)
	var breath := visual.get_node_or_null(^"PeriodicBreath")
	if breath != null:
		breath.process_mode = Node.PROCESS_MODE_DISABLED
	for path in [^"Targets", ^"UI"]:
		var demo_node := visual.get_node_or_null(path)
		if demo_node == null:
			continue
		if demo_node is CanvasItem or demo_node is CanvasLayer:
			demo_node.set("visible", false)
		demo_node.process_mode = Node.PROCESS_MODE_DISABLED


func _set_property_if_present(object: Object, property: StringName, value: Variant) -> void:
	for entry: Dictionary in object.get_property_list():
		if entry.name == property:
			object.set(property, value)
			return
