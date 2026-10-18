@tool
class_name MapMonster
extends "res://addons/pixel_destruction/nodes/pixel_body_2d.gd"

## 地图编辑器的小怪入口：保存标识、碰撞注册与编辑状态。
## 实体怪物由关节刚体驱动骨骼；旧非实体怪物仍保留视觉动画。

const GROUP := &"map_monster"
const LIVING_TAG := "living"
const MONSTER_TAG := "map_monster"
const Ragdoll := preload("res://actor/monster/src/monster_ragdoll.gd")
const HealthBar := preload("res://actor/monster/src/monster_health_bar.gd")
const DeathEffect := preload("res://actor/general/effects/character_death.gd")
const Attack := preload("res://actor/monster/src/monster_attack.gd")
signal health_changed(current: float, maximum: float)
signal died
const HEALTH_MULTIPLIER := 5.0
var max_health := 1000.0 * HEALTH_MULTIPLIER
var health := 1000.0 * HEALTH_MULTIPLIER
var _health_bar: Sprite2D
var _dead := false
@export var contact_damage_scale := 0.001
var _ragdoll: RefCounted
var _attack: RefCounted
@export var attacks_enabled := true
## 关卡实例可调整节奏，默认值保持其他地图原有行为。
@export_range(0.25, 8.0, 0.05) var attack_cooldown_scale := 1.0
@export_range(0.5, 4.0, 0.05) var attack_windup_scale := 1.0
@export_range(0.25, 3.0, 0.05) var attack_range_scale := 1.0

## 前两个编号只为兼容旧地图与测试保留，已不再对应可放置场景或美术资源。
## 新放置栏只会提供 BOMB_SIDE 和后续的 SHIELD_SOLDIER。
enum Kind { SHIELD_SIDE = 0, LITTLE_SOLDIER = 1, BOMB_SIDE = 2, SHIELD_SOLDIER = 3 }

@export var kind: Kind = Kind.BOMB_SIDE
@export var display_name := "小怪"
@export_range(16.0, 256.0, 1.0) var editor_pick_radius := 72.0
@export var editor_id := ""
## 小兵、盾兵和炸弹狂使用躯干及四肢五个关节刚体。
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
## 盾兵专属：是否携带可破坏盾牌。盾牌使用黑色墨水材质，可被打裂开。
@export var has_shield := false
## 盾牌贴图路径（相对 res://）。
@export_file("*.png") var shield_texture_path := "res://actor/monster/imported/great_shield/assets/parts/shield.png"
## 盾牌材质 ID，1 = 黑色墨水。
@export_range(1, 254) var shield_material_id := 1
## 盾牌剩余像素占比低于此值判定为破碎。
@export_range(0.05, 0.9, 0.05) var shield_break_threshold := 0.3
@export_range(0.1, 1.0, 0.01) var shield_scale := 0.45
@export_range(1.0, 3.0, 0.05) var shield_height_scale := 2.0
@export var shield_offset := Vector2(-155.0, -170.0)
## 从掌心沿角色横轴向身体内侧移动，随地图缩放和朝向同步。
@export_range(0.0, 32.0, 0.5) var shield_grip_inset := 4.0
## 盾牌是否已破碎（运行时状态，编辑器中不生效）。
var shield_broken := false
## 玩家接近时停止行走姿势，远离后恢复；两个距离避免临界位置反复切换。
@export var player_stop_distance := 320.0
@export var player_resume_distance := 400.0
## 玩家站在头顶时的微小横向晃动不应触发整套刚体重建。
@export_range(2.0, 128.0, 1.0) var player_turn_deadzone := 32.0

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
var _bone_base_rotation: Dictionary = {}
var _physics_world: Node = null
var _editor_physics_paused := false
var walking := true
var last_contact_impulse := Vector2.ZERO
var last_contact_point := Vector2.ZERO
var _hit_recovery := 0.0
var _animation: AnimationPlayer
var _shield_visual: Sprite2D
var _shield_visual_revision: Array = []
var _shield_count_revision: Array = []
var _shield_remaining_pixels := 0
## 盾兵当前朝向：1=面朝右，-1=面朝左。变化时需重建 ragdoll 以翻转肢体与盾牌。
var _current_facing := -1
var _turning_shield_shapes: Array = []
var _turning_shield_initial_pixels := 0


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
	max_health = (2000.0 if kind == Kind.SHIELD_SOLDIER else (500.0 if kind == Kind.BOMB_SIDE else 1000.0)) * HEALTH_MULTIPLIER
	health = max_health
	if not Engine.is_editor_hint():
		_attack = Attack.new()
		_health_bar = HealthBar.new()
		_health_bar.name = "MonsterHealthBar"
		add_child(_health_bar)
		_update_health_bar()
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
	set_editor_physics_paused(creative != null and creative.get("active"))


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
	if kind in [Kind.LITTLE_SOLDIER, Kind.SHIELD_SOLDIER, Kind.BOMB_SIDE]:
		var sprite := Ragdoll.body_art(get_node("Visual"))
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
		_sync_shield_visual() # 缩放当帧同步盾牌视觉，不等待下一次渲染更新。
	if _editor_physics_paused:
		physics_world.world.freeze(physics_body)
	else:
		physics_world.world.unfreeze(physics_body)


## 编辑拖动只平移已冻结的组件，复用形状、关节和包围盒，不逐次扫描像素。
func sync_editor_translation() -> void:
	if not _editor_physics_paused or _body == null:
		sync_physics_from_node()
		return
	var physics_world := _find_physics_world()
	if physics_world == null:
		return
	var shift: Vector2 = physics_world.to_local(global_position) - _body.position
	if shift.is_zero_approx():
		return
	var bodies: Array = [_body]
	if _ragdoll != null:
		for part in _ragdoll.parts:
			bodies.append(part.body)
		if _ragdoll.shield_body != null:
			bodies.append(_ragdoll.shield_body)
	for physics_body in bodies:
		physics_body.position += shift
		physics_body.aabb.position += shift
		physics_body.swept_aabb.position += shift
		physics_body.refresh_com()


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


func _physics_process(delta: float) -> void:
	if _dead:
		return
	if physical_enabled and not Engine.is_editor_hint():
		var physics_world := _find_physics_world()
		var physics_body = body
		if physics_world != null and physics_body != null and not _editor_physics_paused:
			global_position = physics_world.to_global(physics_body.position)
			global_rotation = physics_world.global_rotation + physics_body.rotation
	_hit_cooldown = maxf(0.0, _hit_cooldown - delta)
	_hit_recovery = maxf(0.0, _hit_recovery - delta)
	if physical_enabled:
		if _attack != null:
			_attack.update(self, delta)
		_update_walk_state(_attack == null or not _attack.busy())
		if _ragdoll != null:
			_ragdoll.update_balance(delta, _editor_physics_paused, _hit_recovery > 0.0, walking, self)
		# 玩家对小怪的受击仍由已求解接触送入；主动攻击有独立单次命中窗口。
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


func _update_walk_state(allow_turn := true) -> void:
	if kind not in [Kind.LITTLE_SOLDIER, Kind.SHIELD_SOLDIER, Kind.BOMB_SIDE] or _animation == null:
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
		# 盾兵专属：玩家靠近时始终朝向玩家所在的一面，水平翻转视觉并刷新物理碰撞体
		if allow_turn and kind == Kind.SHIELD_SOLDIER and _visual != null and not _editor_physics_paused and distance < player_resume_distance and absf(player_center.x - center.x) > maxf(player_turn_deadzone * absf(scale.x), 2.0):
			var target_facing := -1 if player_center.x < center.x else 1
			if target_facing != _current_facing:
				_current_facing = target_facing
				var base_scale_x := absf(_visual.scale.x)
				# 源素材朝左；仅镜像 Visual 的 X，不改变物理根节点的旋转或 Y 缩放。
				_visual.scale.x = base_scale_x if target_facing < 0 else -base_scale_x
				_refresh_physics_for_facing()
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
func receive_contact_impact(point: Vector2, impulse: Vector2, hit_body = null, attack := true) -> void:
	if _editor_physics_paused or _body == null or _hit_cooldown > 0.0:
		return
	last_contact_impulse = impulse
	last_contact_point = point
	if attack:
		apply_damage(impulse.length() * contact_damage_scale, hit_body)
	_hit_recovery = 0.45
	if _attack != null:
		_attack.cancel(self)
	# 接触报告仍在遍历原生碰撞对，此时删除刚体会使后续接触句柄失效。
	# 朝向在下一物理帧起点即时刷新，受击回调只更新停走状态。
	_update_walk_state(false)
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


## 操纵工具按可见身体和四肢选中，不把点击区域限制在脚底附近。
func editor_contains_point(world_point: Vector2, margin: float) -> bool:
	if _visual == null:
		return false
	var has_art := false
	for sprite: Sprite2D in _visual.find_children("*", "Sprite2D", true, false):
		if sprite.texture == null or not sprite.is_visible_in_tree():
			continue
		has_art = true
		var transform := sprite.global_transform
		var padding := Vector2(margin / transform.x.length(), margin / transform.y.length())
		var rect := sprite.get_rect().grow_individual(padding.x, padding.y, padding.x, padding.y)
		if rect.has_point(sprite.to_local(world_point)):
			return true
	var radius := margin if has_art else maxf(margin, editor_pick_radius * global_scale.abs().x)
	return global_position.distance_squared_to(world_point) <= radius * radius


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
	# 旧非实体怪物的玩家手部攻击也使用同一血量入口。
	if not physical_enabled and _hit_cooldown <= 0.0:
		apply_damage(strength * 0.1)
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
	_update_health_bar()
	if _visual == null:
		return
	if _ragdoll != null:
		_visual.position = _visual_base_position
		_visual.rotation = _visual_base_rotation
		_ragdoll.update_pose(_editor_physics_paused)
		_sync_shield_visual()
		return
	# 二阶弹簧：受力时后仰、松手后自然回弹，不移动地图节点本身。
	_kick_velocity += (-_kick_offset * VISUAL_SPRING - _kick_velocity * VISUAL_DAMPING) * delta
	_kick_offset += _kick_velocity * delta
	_twist_velocity += (-_twist * VISUAL_SPRING - _twist_velocity * VISUAL_DAMPING) * delta
	_twist += _twist_velocity * delta
	_visual.position = _visual_base_position + _kick_offset
	_update_legacy_bones(delta)


func _update_legacy_bones(delta: float) -> void:
	_visual.rotation = _visual_base_rotation + _twist
	for key in _bone_twist.keys():
		var bone := key as Bone2D
		if bone == null or not is_instance_valid(bone):
			_bone_twist.erase(key)
			_bone_velocity.erase(key)
			_bone_last_applied.erase(key)
			_bone_base_rotation.erase(key)
			continue
		var previous: float = float(_bone_last_applied[bone])
		var base: float = float(_bone_base_rotation.get(bone, bone.rotation))
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


## 盾牌受击不会扣本体血；地面承重不作为攻击。编辑时完全禁用伤害。
func apply_damage(amount: float, hit_body = null) -> float:
	var level := _find_physics_world()
	var creative := level.get_node_or_null("Creative") if level != null else null
	if _dead or _editor_physics_paused or (creative != null and creative.get("active") == true) \
			or not is_finite(amount) or amount <= 0.0:
		return 0.0
	if hit_body != null and str(hit_body.tags.get("monster_part", "")) == "Shield":
		return 0.0
	var removed := minf(health, amount)
	health = maxf(0.0, health - removed)
	health_changed.emit(health, max_health)
	_update_health_bar()
	if health <= 0.0:
		_dead = true
		walking = false
		died.emit()
		_finish_death.call_deferred() # 不能在原生接触遍历中移除刚体。
	return removed


func _finish_death() -> void:
	var world := _find_physics_world() as Node2D
	if world != null and _visual != null:
		var sprites := DeathEffect.visible_sprites(_visual)
		if is_instance_valid(_shield_visual) and _shield_visual.visible:
			sprites.append(_shield_visual)
		var effect_style := DeathEffect.Style.SOLDIER
		if kind == Kind.SHIELD_SOLDIER:
			effect_style = DeathEffect.Style.SHIELD
		elif kind == Kind.BOMB_SIDE:
			effect_style = DeathEffect.Style.BOMB
		var foot := DeathEffect.sprites_foot_position(sprites, global_position)
		DeathEffect.spawn(world, sprites, effect_style, foot, last_contact_impulse.x)
	# 先解除角色物理，再保留独立残影播放，不留下尸体碰撞或回正马达。
	_release_physics_body()
	queue_free()


func _update_health_bar() -> void:
	if not is_instance_valid(_health_bar):
		return
	var position := global_position + Vector2(0, -140.0 * absf(global_scale.y))
	var width := clampf(90.0 * absf(global_scale.x), 50.0, 160.0)
	var world := _find_physics_world()
	if _body != null and world != null:
		position = world.to_global(Vector2(_body.com_world().x, _body.aabb.position.y - 14.0))
	_health_bar.global_position = position
	_health_bar.update_health(health, max_health, width)


func _configure_imported_visual() -> void:
	var visual := get_node_or_null("Visual") as Node2D
	if visual == null:
		return
	if physical_enabled and kind in [Kind.LITTLE_SOLDIER, Kind.SHIELD_SOLDIER, Kind.BOMB_SIDE]:
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
	if _ragdoll != null or kind not in [Kind.LITTLE_SOLDIER, Kind.SHIELD_SOLDIER, Kind.BOMB_SIDE] or _body == null:
		return
	var physics_world := _find_physics_world()
	if physics_world == null or not physics_world.world.bodies.has(_body):
		return
	_ragdoll = Ragdoll.new()
	_ragdoll.setup(self, physics_world, _body)
	walking = true
	_create_shield_visual()


## 转向时直接刷新物理碰撞体：释放旧 ragdoll 后按翻转后的骨骼重建，无过渡动画。
func _refresh_physics_for_facing() -> void:
	if _ragdoll == null or Engine.is_editor_hint():
		return
	var velocity: Vector2 = _body.linear_velocity
	var angular_velocity: float = _body.angular_velocity
	_turning_shield_shapes.clear()
	if _ragdoll.shield_body != null and not shield_broken:
		_turning_shield_initial_pixels = _ragdoll.shield_initial_pixels
		for source in _ragdoll.shield_body.shapes:
			var mirrored := Ragdoll.PixelShape.new()
			mirrored.density_scale = source.density_scale
			var bounds: Rect2i = source.local_aabb()
			for y in range(bounds.position.y, bounds.end.y):
				for x in range(bounds.position.x, bounds.end.x):
					var material: int = source.get_pixel(x, y)
					if material != 0:
						mirrored.set_pixel(-x - 1, y, material)
			_turning_shield_shapes.append(mirrored)
	# 身体的非对称轮廓也必须镜像，不只是四肢。
	sync_physics_from_node(true)
	_turning_shield_shapes.clear()
	_turning_shield_initial_pixels = 0
	_body.linear_velocity = velocity
	_body.angular_velocity = angular_velocity
	for part: Dictionary in _ragdoll.parts:
		part.body.linear_velocity = velocity
	if _ragdoll.shield_body != null:
		_ragdoll.shield_body.linear_velocity = velocity
		_ragdoll.shield_body.angular_velocity = angular_velocity
	_ragdoll.update_pose(_editor_physics_paused)
	_sync_shield_visual()


## 攻击蓄力前锁定朝向；仅镜像横轴，并刷新对应物理形状。
func face_direction(direction: int) -> void:
	if direction == _current_facing or _visual == null or _editor_physics_paused:
		return
	_current_facing = direction
	_visual.scale.x = absf(_visual.scale.x) * (1.0 if direction < 0 else -1.0)
	_refresh_physics_for_facing()


func _create_shield_visual() -> void:
	if not has_shield or _visual == null:
		return
	_shield_visual = get_node_or_null("ShieldArt") as Sprite2D
	if _shield_visual == null:
		_shield_visual = Sprite2D.new()
		_shield_visual.name = "ShieldArt"
		add_child(_shield_visual)
		_shield_visual.z_index = 50
	_shield_visual.scale = Vector2(shield_scale, shield_scale * shield_height_scale)
	_shield_visual.texture = load(shield_texture_path) as Texture2D
	_shield_visual.centered = true
	var bounds := _shield_visual.texture.get_image().get_used_rect()
	# 物理盾牌以实际不透明包围盒中心为原点，与精灵居中方式一致。
	_shield_visual.offset = _shield_visual.texture.get_size() * 0.5 \
		- (Vector2(bounds.position) + Vector2(bounds.size) * 0.5)
	_shield_visual_revision.clear()
	_shield_count_revision.clear()
	_shield_visual.visible = not shield_broken


func _sync_shield_visual() -> void:
	if _shield_visual == null or _ragdoll == null:
		return
	var shield_body = _ragdoll.shield_body
	if shield_body == null or shield_broken:
		_shield_visual.visible = false
		return
	_shield_visual.visible = true
	var physics_world := _find_physics_world()
	if physics_world == null:
		return
	var facing_scale := 1.0 if _current_facing < 0 else -1.0
	var size := shield_scale * absf(scale.x)
	var count_revision: Array = [shield_body.id]
	for shape in shield_body.shapes:
		count_revision.append(shape)
		count_revision.append(shape.revision)
	if count_revision != _shield_count_revision:
		_shield_count_revision = count_revision
		_shield_remaining_pixels = 0
		for shape in shield_body.shapes:
			_shield_remaining_pixels += shape.pixel_count()
	if _shield_remaining_pixels < _ragdoll.shield_initial_pixels:
		_sync_damaged_shield_texture(shield_body)
		_shield_visual.global_transform = Transform2D(
			physics_world.global_rotation + shield_body.rotation,
			physics_world.to_global(shield_body.position))
		return
	_shield_visual.global_transform = Transform2D(physics_world.global_rotation + shield_body.rotation,
		Vector2(size * facing_scale, size * shield_height_scale),
		0.0, physics_world.to_global(shield_body.position))


## 破损盾牌仍保留原来的前景层级，但只绘制真实碰撞像素；内容不变时复用贴图。
func _sync_damaged_shield_texture(shield_body) -> void:
	var revision: Array = [shield_body.id]
	var bounds := Rect2i()
	for shape in shield_body.shapes:
		revision.append(shape)
		revision.append(shape.revision)
		var shape_bounds: Rect2i = shape.local_aabb()
		bounds = shape_bounds if bounds.size == Vector2i.ZERO else bounds.merge(shape_bounds)
	if revision == _shield_visual_revision:
		return
	_shield_visual_revision = revision
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		_shield_visual.visible = false
		return
	var image := Image.create(bounds.size.x, bounds.size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color.TRANSPARENT)
	for shape in shield_body.shapes:
		var shape_bounds: Rect2i = shape.local_aabb()
		for y in range(shape_bounds.position.y, shape_bounds.end.y):
			for x in range(shape_bounds.position.x, shape_bounds.end.x):
				if shape.get_pixel(x, y) != 0:
					image.set_pixel(x - bounds.position.x, y - bounds.position.y, Color.BLACK)
	_shield_visual.texture = ImageTexture.create_from_image(image)
	_shield_visual.centered = false
	_shield_visual.offset = Vector2(bounds.position)
