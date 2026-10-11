@tool
class_name MapMonster
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"

## 地图编辑器的小怪入口：保存标识、碰撞注册与编辑状态。
## 实体小兵由关节刚体驱动骨骼；旧非实体怪物仍保留视觉动画。

const GROUP := &"map_monster"
const LIVING_TAG := "living"
const MONSTER_TAG := "map_monster"
const Ragdoll := preload("res://actor/monster/src/monster_ragdoll.gd")
var _ragdoll: RefCounted

## 前两个编号只为兼容旧地图与测试保留，已不再对应可放置场景或美术资源。
## 新放置栏只会提供 BOMB_SIDE 和后续的 SHIELD_SOLDIER。
enum Kind { SHIELD_SIDE = 0, LITTLE_SOLDIER = 1, BOMB_SIDE = 2, SHIELD_SOLDIER = 3 }

@export var kind: Kind = Kind.BOMB_SIDE
@export var display_name := "小怪"
@export_range(16.0, 256.0, 1.0) var editor_pick_radius := 72.0
@export var editor_id := ""
## 小兵使用躯干和四肢五个关节刚体；旧怪物继续保持纯视觉。
@export var physical_enabled := false
## 相对怪物原点（脚底中心）的简化身体碰撞壳。
@export var physics_rect := Rect2i(-46, -220, 92, 220)
## 只影响质量，不影响碰撞尺寸；避免大面积像素壳重得无法被玩家和道具推动。
@export_range(0.05, 2.0, 0.05) var physics_density_scale := 0.3
## 运行时的受击感来自玩家手部的真实物理速度/质量，而不是墨水像素破坏。
@export_range(12.0, 512.0, 1.0) var hit_radius := 78.0
## 凸多边形碰撞箱（局部坐标，顶点按顺时针或逆时针排列）。
## 为空时回退到 hit_radius 圆形检测。多边形会随节点 scale 自动变换。
@export var hit_polygon: PackedVector2Array = PackedVector2Array()
@export_range(1.0, 200.0, 1.0) var minimum_hit_speed := 45.0
@export_range(0.0, 4.0, 0.05) var impact_response := 1.0
## 玩家接近时停止行走姿势，远离后恢复；两个距离避免临界位置反复切换。
@export var player_stop_distance := 320.0
@export var player_resume_distance := 400.0

const HIT_COOLDOWN := 0.12
const MAX_IMPULSE := 2400.0
const VISUAL_SPRING := 34.0
const VISUAL_DAMPING := 9.0
const BONE_SPRING := 42.0
const BONE_DAMPING := 10.0

var _visual: Node2D
var _visual_base_position := Vector2.ZERO
var _visual_base_rotation := 0.0
## 固化时记录的初始位置，重置关卡时可回到此处。
var initial_position := Vector2.ZERO
var _kick_offset := Vector2.ZERO
var _kick_velocity := Vector2.ZERO
var _twist := 0.0
var _twist_velocity := 0.0
var _hit_cooldown := 0.0
var _bone_twist: Dictionary = {}
var _bone_velocity: Dictionary = {}
var _bone_last_applied: Dictionary = {}
var _bone_base_rotation: Dictionary = {}
var _physics_world: Node = null
var _editor_physics_paused := false
var walking := true
var last_contact_impulse := Vector2.ZERO
var last_contact_point := Vector2.ZERO
var _hit_recovery := 0.0
var _animation: AnimationPlayer


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
		_animation = _visual.get_node_or_null("AnimationPlayer") as AnimationPlayer
		for bone in _visual.find_children("*", "Bone2D", true, false):
			_bone_twist[bone] = 0.0
			_bone_velocity[bone] = 0.0
			_bone_last_applied[bone] = 0.0
			_bone_base_rotation[bone] = bone.rotation
	initial_position = global_position
	if physical_enabled and not Engine.is_editor_hint():
		# 父 PixelWorld 会在自己的 _ready 重建一次；延迟注册可避免刚加入的嵌套刚体被重建覆盖。
		_register_physics_deferred.call_deferred()


func _register_physics_deferred() -> void:
	if not physical_enabled or not is_inside_tree() or Engine.is_editor_hint():
		return
	# 小怪位于 Main/Monsters 下，不是 PixelWorld 的直接子节点，必须显式增量注册。
	var physics_body = body
	if physics_body != null:
		physics_body.internal_render = false
		_ensure_ragdoll()
	var creative := get_parent().get_parent().get_node_or_null("Creative") if get_parent() != null and get_parent().get_parent() != null else null
	set_editor_physics_paused(creative != null and bool(creative.get("active")))


func _exit_tree() -> void:
	_release_physics_body()
	super._exit_tree()


## 删除或重建碰撞壳时解除 PBody -> PixelShape -> PBody 的引用环。
## 使用缓存字段，避免退出场景时访问 body getter 又创建一个碰撞体。
func _release_physics_body() -> void:
	if _ragdoll != null:
		_ragdoll.release()
		_ragdoll = null
	if _body == null:
		return
	if is_instance_valid(_physics_world):
		_physics_world.remove_body_node(self)
	for shape in _body.shapes:
		if shape.owner_body == _body:
			shape.owner_body = null
	_body = null


## 嵌套在 Monsters 容器内时，沿父链寻找真正的 PixelWorld。
func _find_physics_world() -> Node:
	if is_instance_valid(_physics_world):
		return _physics_world
	var candidate := get_parent()
	while candidate != null:
		if candidate.has_method("add_body_node"):
			_physics_world = candidate
			return candidate
		candidate = candidate.get_parent()
	return null


func _bake_lazily():
	if not physical_enabled:
		return null
	var physics_world := _find_physics_world()
	return physics_world.add_body_node(self) if physics_world != null else bake()


## 生成以脚底中心为原点的矩形像素碰撞壳，并把地图编辑器缩放计入尺寸。
func build_shape():
	if not physical_enabled:
		return PixelShape.new()
	if kind in [Kind.LITTLE_SOLDIER, Kind.SHIELD_SOLDIER]:
		var sprite := get_node("Visual/Skeleton2D/Root/BodyBone/BodyArt") as Sprite2D
		var frame := Transform2D(global_rotation, global_position)
		return Ragdoll.sprite_shape(sprite, frame, material_id)
	var shape := PixelShape.new()
	var absolute_scale := Vector2(maxf(absf(scale.x), 0.01), maxf(absf(scale.y), 0.01))
	var scaled_position := Vector2i(
		roundi(float(physics_rect.position.x) * absolute_scale.x),
		roundi(float(physics_rect.position.y) * absolute_scale.y)
	)
	var scaled_size := Vector2i(
		maxi(1, roundi(float(physics_rect.size.x) * absolute_scale.x)),
		maxi(1, roundi(float(physics_rect.size.y) * absolute_scale.y))
	)
	shape.fill_rect(Rect2i(scaled_position, scaled_size), material_id)
	return shape


func collect_shapes() -> Array:
	var shapes: Array = super.collect_shapes()
	if physical_enabled:
		for shape in shapes:
			shape.density_scale = physics_density_scale
	return shapes


func bake():
	var result = super.bake()
	if physical_enabled:
		var physics_world := _find_physics_world()
		if physics_world != null:
			result.position = physics_world.to_local(global_position)
			result.rotation = global_rotation - physics_world.global_rotation
		result.tags[LIVING_TAG] = true
		result.tags[MONSTER_TAG] = true
		result.tags["monster_receiver"] = weakref(self)
		result.tags["editor_physics_paused"] = _editor_physics_paused
		result.internal_render = false
	return result


## 地图编辑器移动/缩放后，将节点变换同步给已注册的物理壳。
func sync_physics_from_node(rebuild_shape := false) -> void:
	if not physical_enabled or Engine.is_editor_hint():
		return
	var physics_world := _find_physics_world()
	if physics_world == null:
		return
	var physics_body = body
	if rebuild_shape and physics_body != null:
		_release_physics_body()
		physics_body = physics_world.add_body_node(self)
	if physics_body == null:
		return
	physics_body.position = physics_world.to_local(global_position)
	physics_body.rotation = global_rotation - physics_world.global_rotation
	physics_body.linear_velocity = Vector2.ZERO
	physics_body.angular_velocity = 0.0
	physics_body.update_aabb()
	physics_body.compute_swept_aabb(0.0)
	_ensure_ragdoll()
	if _ragdoll != null:
		_ragdoll.sync_from_node()
		_ragdoll.pause(_editor_physics_paused)
	if _editor_physics_paused:
		physics_world.world.freeze(physics_body)
	else:
		physics_world.world.unfreeze(physics_body)


## 编辑模式冻结碰撞壳；游玩模式恢复动力学。
func set_editor_physics_paused(paused: bool) -> void:
	_editor_physics_paused = paused
	if not physical_enabled or Engine.is_editor_hint():
		return
	var physics_world := _find_physics_world()
	var physics_body = body
	if physics_world == null or physics_body == null:
		return
	_ensure_ragdoll()
	if _ragdoll != null:
		_ragdoll.pause(paused)
	physics_body.tags["editor_physics_paused"] = paused
	physics_body.linear_velocity = Vector2.ZERO
	physics_body.angular_velocity = 0.0
	if paused:
		physics_world.world.freeze(physics_body)
	else:
		physics_world.world.unfreeze(physics_body)


## 把当前世界坐标记为初始位置（固化时调用）。
func store_initial_position() -> void:
	initial_position = global_position


## 回到初始位置，并清零受击偏移。
func reset_to_initial_position() -> void:
	global_position = initial_position
	_kick_offset = Vector2.ZERO
	_kick_velocity = Vector2.ZERO
	_twist = 0.0
	_twist_velocity = 0.0
	for key in _bone_twist:
		_bone_twist[key] = 0.0
		_bone_velocity[key] = 0.0
	sync_physics_from_node()


func _physics_process(delta: float) -> void:
	if physical_enabled and not Engine.is_editor_hint():
		var physics_world := _find_physics_world()
		var physics_body = body
		if physics_world != null and physics_body != null and not _editor_physics_paused:
			global_position = physics_world.to_global(physics_body.position)
			global_rotation = physics_world.global_rotation + physics_body.rotation
	_hit_cooldown = maxf(0.0, _hit_cooldown - delta)
	_hit_recovery = maxf(0.0, _hit_recovery - delta)
	if physical_enabled:
		_update_walk_state()
		if _ragdoll != null:
			_ragdoll.update_balance(delta, _editor_physics_paused, _hit_recovery > 0.0, walking)
		# 实体小兵的攻击只走已求解接触；不再用手心点与速度猜测命中。
		return
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
	if not _is_point_in_hit_volume(hand_position):
		return
	var velocity: Vector2 = hand_body.linear_velocity
	if velocity.length() < minimum_hit_speed:
		return
	# PBody 的质量和速度均来自当前物理步；这不是鼠标速度或固定播放特效。
	var mass: float = maxf(float(hand_body.mass), 0.001)
	var impulse := velocity * minf(mass * 0.006, 8.0)
	receive_impact(hand_position, impulse)


func _update_walk_state() -> void:
	if kind not in [Kind.LITTLE_SOLDIER, Kind.SHIELD_SOLDIER] or _animation == null:
		return
	var should_walk := not _editor_physics_paused and _hit_recovery <= 0.0
	var player := get_tree().get_first_node_in_group(&"player") as Node2D
	if player != null:
		var center := global_position
		var player_center := player.global_position
		if _body != null and is_instance_valid(_physics_world):
			center = _physics_world.to_global(_body.com_world())
			var player_body = player.get("body")
			if player_body != null:
				# 玩家场景原点留在出生位置，实际移动的是 PBody 与独立视觉节点。
				player_center = _physics_world.to_global(player_body.com_world())
		var distance := center.distance_to(player_center)
		var limit := player_resume_distance if not walking else player_stop_distance
		should_walk = should_walk and distance > limit
	if should_walk == walking:
		return
	walking = should_walk
	# 切换基础姿势前清掉上一帧的附加角度，避免停走时遗留扭转。
	for bone in _bone_last_applied:
		bone.rotation -= float(_bone_last_applied[bone])
		_bone_last_applied[bone] = 0.0
	if walking:
		_animation.play("walk")
	else:
		_animation.play("RESET")
		_animation.advance(0.0)
		_animation.stop()
	for bone in _bone_base_rotation:
		_bone_base_rotation[bone] = bone.rotation


## 接触冲量已改变真实刚体速度；关节小兵松开姿势马达，旧碰撞壳使用视觉反馈。
func receive_contact_impact(point: Vector2, impulse: Vector2) -> void:
	if _editor_physics_paused or _body == null or _hit_cooldown > 0.0:
		return
	last_contact_impulse = impulse
	last_contact_point = point
	_hit_recovery = 0.45
	_update_walk_state()
	if _ragdoll != null:
		_hit_cooldown = HIT_COOLDOWN
		return
	var physics_world := _find_physics_world()
	var world_point: Vector2 = physics_world.to_global(point) if physics_world != null else point
	var world_impulse: Vector2 = impulse.rotated(physics_world.global_rotation) if physics_world != null else impulse
	receive_impact(world_point, world_impulse * _body.inv_mass * 6.0)


## 优先用凸多边形判定，为空时回退到圆形。点坐标为世界坐标。
func _is_point_in_hit_volume(world_point: Vector2) -> bool:
	if hit_polygon.size() >= 3:
		var local_point := global_transform.affine_inverse() * world_point
		return _point_in_convex_polygon(local_point, hit_polygon)
	var radius := hit_radius * maxf(absf(global_scale.x), absf(global_scale.y))
	return world_point.distance_squared_to(global_position) <= radius * radius


## 叉积法判断点是否在凸多边形内（顶点按顺时针或逆时针排列）。
func _point_in_convex_polygon(point: Vector2, polygon: PackedVector2Array) -> bool:
	var n := polygon.size()
	var sign := 0
	for i in n:
		var a := polygon[i]
		var b := polygon[(i + 1) % n]
		var cross := (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
		if absf(cross) < 0.001:
			continue
		var current_sign := 1 if cross > 0.0 else -1
		if sign == 0:
			sign = current_sign
		elif sign != current_sign:
			return false
	return true


## 外部攻击也可调用此入口。冲量的方向决定整体后仰和各骨骼的扭转方向。
func receive_impact(world_point: Vector2, impulse: Vector2) -> void:
	if _visual == null or impulse.is_zero_approx() or impact_response <= 0.0:
		return
	var capped := impulse.limit_length(MAX_IMPULSE) * impact_response
	var strength := capped.length()
	if strength <= 0.001:
		return
	_hit_cooldown = HIT_COOLDOWN
	_kick_velocity += capped.rotated(-global_rotation) / maxf(70.0 + strength * 0.08, 1.0)
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
	if _ragdoll != null:
		_visual.position = _visual_base_position
		_visual.rotation = _visual_base_rotation
		_ragdoll.update_pose(_editor_physics_paused)
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
			_bone_base_rotation.erase(key)
			continue
		# 先撤掉上一帧的附加偏移，再叠加本帧弹簧解；源动画/IK 仍控制基础姿势。
		var previous: float = float(_bone_last_applied[bone])
		var base: float = float(_bone_base_rotation.get(bone, bone.rotation))
		# IK/动画可能已覆写基础角度，此时不能再次减去上一帧的偏移。
		if not is_equal_approx(bone.rotation, base + previous):
			base = bone.rotation
		_bone_base_rotation[bone] = base
		var angle: float = float(_bone_twist[bone])
		var velocity: float = float(_bone_velocity[bone])
		velocity += (-angle * BONE_SPRING - velocity * BONE_DAMPING) * delta
		angle += velocity * delta
		_bone_twist[bone] = angle
		_bone_velocity[bone] = velocity
		bone.rotation = base + angle
		_bone_last_applied[bone] = angle


func _configure_imported_visual() -> void:
	var visual := get_node_or_null("Visual") as Node2D
	if visual == null:
		return
	if physical_enabled and kind in [Kind.LITTLE_SOLDIER, Kind.SHIELD_SOLDIER]:
		_set_property_if_present(visual, &"hand_drawn_wobble", false)
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


func _ensure_ragdoll() -> void:
	if _ragdoll != null or kind not in [Kind.LITTLE_SOLDIER, Kind.SHIELD_SOLDIER] or _body == null:
		return
	var physics_world := _find_physics_world()
	if physics_world == null or not physics_world.world.bodies.has(_body):
		return
	_ragdoll = Ragdoll.new()
	_ragdoll.setup(self, physics_world, _body)
	walking = true
	_update_walk_state()
