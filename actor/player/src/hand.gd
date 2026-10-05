#region 依赖与状态
extends Node

const Query := preload("res://addons/pixel_destruction/physics/query.gd")

@onready var body = $"..".body
@onready var arm_body = $"../..".body
@onready var player_body = $"../../..".body
@onready var physics_world = $"../../../..".world
var arm_joint = null
var pivot_joint = null
var grip_joint = null
var grabbed_body = null
## 开放抓点转动后，现有 PD 成对力驱动连杆和身体绕指尖运动。
@export var rotate_grip: bool = false

var target_relative := Vector2.ZERO
var _target_override = null
var _grip_override = null

## 验收记录：本帧实际功率，以及线性/角度冲量的归一化基准。
var debug_active_power := 0.0
var debug_angular_effort := 0.0
var debug_linear_effort := 0.0
var debug_p_force: Vector2 = Vector2.ZERO
var debug_d_force: Vector2 = Vector2.ZERO
var debug_force_vector: Vector2 = Vector2.ZERO
#endregion


#region 生命周期
func _ready() -> void:
	process_physics_priority = -10
	target_relative = rest_offset.limit_length(max_reach)
	# 只在出生时设置位姿，之后由 Hinge + Slider 保证连杆自由度。
	var center: Vector2 = player_body.com_world() + target_relative
	body.position = center - body.local_com
	body.linear_velocity = player_body.linear_velocity
	body.refresh_com()
	body.update_aabb()
	_ensure_arm_joint()


func _exit_tree() -> void:
	_release_grab()
	_remove_arm()


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("change_mode"):
		set_rotation_mode(not rotate_grip)
	_ensure_arm_joint()
	_update_grip(delta)
	var hand_position: Vector2 = body.com_world()
	var target := _calculate_target_position(player_body.com_world(), delta)
	var force := _calculate_motor(target, hand_position, delta)
	_apply_internal_wrench(force, 0.0, hand_position, delta)
#endregion


#region 手臂范围与目标
@export_group("手臂范围")
@export var rest_offset := Vector2(72.0, 0.0)
@export var min_target_radius := 16.0
@export var max_reach := 160.0
## 给 Joint 求解误差预留余量。
@export var reach_solver_margin := 4.0

func _ensure_arm_joint() -> void:
	if arm_joint != null and arm_joint.is_active():
		return
	_remove_arm()
	var pivot: Vector2 = player_body.com_world()
	var offset: Vector2 = body.com_world() - pivot
	var center: Vector2 = body.com_world()
	arm_body.rotation = offset.angle()
	arm_body.position = pivot - arm_body.local_com.rotated(arm_body.rotation)
	arm_body.linear_velocity = player_body.linear_velocity
	arm_body.angular_velocity = 0.0
	arm_body.refresh_com()
	arm_body.update_aabb()
	body.rotation = arm_body.rotation
	body.position = center - body.local_com.rotated(body.rotation)
	body.refresh_com()
	body.update_aabb()
	pivot_joint = physics_world.add_hinge(player_body, arm_body, pivot)
	arm_joint = physics_world.add_slider(arm_body, body, pivot, offset.normalized())
	arm_joint.set_limits(min_target_radius - offset.length(), max_reach - reach_solver_margin - offset.length())


func _remove_arm() -> void:
	_remove_joint(arm_joint)
	_remove_joint(pivot_joint)
	arm_joint = null
	pivot_joint = null


func _calculate_target_position(pivot: Vector2, _delta: float) -> Vector2:
	var target_world: Vector2 = _target_override if _target_override != null else _get_mouse_world_position()
	var desired := target_world - pivot
	var direction := target_relative.normalized() if desired.is_zero_approx() else desired.normalized()
	target_relative = direction * clampf(desired.length(), min_target_radius, max_reach - reach_solver_margin)
	return pivot + target_relative
#endregion


#region 力控与朝向
@export_group("主动马达")
@export var position_stiffness := 140.0
@export var position_damping := 32.0
## 固定执行器上限，抓到重物后不增加。
@export var max_force := 8000000.0
@export var max_power := 420000000.0

## 可选的中心力偶配平；默认沿用中心成对力。
@export var conserve_angular_momentum := false

func _calculate_motor(target_position: Vector2, hand_position: Vector2, delta: float) -> Vector2:
	var velocity: Vector2 = body.linear_velocity - player_body.linear_velocity
	# 隐式 PD：稳定刚性支点附近的离散反馈。
	var stable := 1.0 / (1.0 + position_damping * delta + position_stiffness * delta * delta)
	var acceleration := ((target_position - hand_position) * position_stiffness
		- velocity * (position_damping + position_stiffness * delta)) * stable
	var inverse_mass: float = _hand_side()["inv_mass"] + player_body.inv_mass
	var force := (acceleration / inverse_mass).limit_length(max_force)
	force = _limit_power(force, 0.0, hand_position, delta)
	var raw: Vector2 = acceleration / inverse_mass
	var scale: float = force.length() / raw.length() if raw.length() > 0.0 else 0.0
	debug_p_force = (target_position - hand_position) * position_stiffness * stable / inverse_mass * scale
	debug_d_force = -velocity * (position_damping + position_stiffness * delta) * stable / inverse_mass * scale
	return force

#endregion


#region 成对冲量与角动量
func _apply_internal_wrench(
	force: Vector2,
	aim_torque: float,
	hand_position: Vector2,
	delta: float
) -> void:
	# 成对中心冲量保持线动量；角动量开关决定是否给身体配平力矩。
	var torques := _internal_torques(force, aim_torque, hand_position)
	debug_force_vector = force
	body.apply_central_impulse(force * delta)
	body.apply_torque_impulse(torques.x * delta)
	player_body.apply_central_impulse(-force * delta)
	player_body.apply_torque_impulse(torques.y * delta)
	body.awake = true
	body.sleep_timer = 0.0
	player_body.awake = true
	player_body.sleep_timer = 0.0
	debug_angular_effort = (
		absf((hand_position - player_body.com_world()).cross(force))
		+ 2.0 * absf(aim_torque)
	)
	debug_linear_effort = force.length()


## 返回手、身体的总力矩；执行和能量预测共用同一计算。
func _internal_torques(force: Vector2, aim_torque: float, hand_position: Vector2) -> Vector2:
	if not conserve_angular_momentum:
		return Vector2(aim_torque, 0.0)
	var lever: Vector2 = hand_position - player_body.com_world()
	# 按惯量分配配平力偶，这是满足总角冲量为零时能量最低的分配。
	var required_total := -lever.cross(force)
	var hand_inertia: float = _hand_side()["inertia"]
	var inertia_sum: float = hand_inertia + player_body.inertia
	if inertia_sum <= 0.000001:
		return Vector2(aim_torque, -aim_torque)
	return Vector2(
		required_total * hand_inertia / inertia_sum + aim_torque,
		required_total * player_body.inertia / inertia_sum - aim_torque
	)
#endregion


#region 总功率限制
func _limit_power(force: Vector2, torque: float, hand_position: Vector2, delta: float) -> Vector2:
	debug_active_power = 0.0
	if delta <= 0.0:
		return Vector2.ZERO
	var torques := _internal_torques(force, torque, hand_position)
	var side := _hand_side()
	# Joint 把手和物体组成一个刚体；施力点偏离组合质心时也要计入转动功。
	var side_torque: float = torques.x + (hand_position - side["center"]).cross(force)
	var current_power: float = (
		force.dot(body.linear_velocity - player_body.linear_velocity)
		+ torques.x * body.angular_velocity
		+ torques.y * player_body.angular_velocity
	)
	var impulse_energy_rate: float = (
		force.length_squared() * (side["inv_mass"] + player_body.inv_mass)
		+ side_torque * side_torque * side["inv_inertia"]
		+ torques.y * torques.y * player_body.inv_inertia
	)

	# 单帧做功 E(s)=a·s²+b·s，包含静止起步的动能，直接解最大允许比例。
	var a := 0.5 * impulse_energy_rate * delta * delta
	var b := current_power * delta
	var budget := maxf(max_power, 0.0) * delta
	var scale := 1.0
	if a + b > budget:
		var root := sqrt(b * b + 4.0 * a * budget)
		scale = 2.0 * budget / (b + root) if b > 0.0 else (root - b) / (2.0 * a)
		scale = clampf(scale, 0.0, 1.0)
	debug_active_power = maxf(a * scale * scale + b * scale, 0.0) / delta
	return force * scale
#endregion


#region 抓握
@export_group("抓握")
const FINGERTIP := Vector2(20.0, 0.0)
const GRAB_RADIUS := 0.72

func _update_grip(_delta: float) -> void:
	var requested: bool = _grip_override if _grip_override != null else Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if not requested:
		_release_grab()
		return
	if grip_joint != null and grip_joint.is_active():
		return
	_release_grab()
	var tip: Vector2 = body.com_world() + FINGERTIP.rotated(body.rotation)
	var hit = Query.closest_point(tip, GRAB_RADIUS, [body, player_body])
	if hit.hit and hit.body != null:
		_begin_grab(hit.body, hit.point)


func _begin_grab(target_body, world_point: Vector2) -> bool:
	if target_body == null or target_body == body or target_body == player_body:
		return false
	_ensure_arm_joint()
	_release_grab()
	# 关闭时 Weld 锁当前相对角；打开时 Hinge 保留抓点，交给现有 PD 力控驱动摆动。
	grip_joint = physics_world.add_hinge(target_body, body, world_point) if rotate_grip else physics_world.add_weld(target_body, body, world_point)
	if grip_joint == null:
		return false
	grip_joint.contacts_enabled = false
	grabbed_body = target_body
	return true


func set_rotation_mode(enabled: bool) -> void:
	if rotate_grip == enabled:
		return
	rotate_grip = enabled
	if grip_joint != null and grip_joint.is_active():
		# 以当前锚点和相对角重建；不重置位姿、速度或把手拧回原角度。
		_begin_grab(grabbed_body, grip_joint.anchor_b_world())


func _release_grab() -> void:
	_remove_joint(grip_joint)
	grip_joint = null
	grabbed_body = null


func _remove_joint(joint) -> void:
	if joint != null and joint.is_active():
		joint.remove()


#endregion


#region 外部输入
## 设置后覆盖鼠标输入；清除后恢复鼠标控制。
func set_target_world(world_position: Vector2) -> void:
	_target_override = world_position


func clear_target_override() -> void:
	_target_override = null


func set_grip(closed: bool) -> void:
	_grip_override = closed


func clear_grip_override() -> void:
	_grip_override = null
#endregion


#region 负载与输入工具
## 执行器手侧：自由手、焊接组合体、固定抓点；铰接时不合并物体惯量。
func _hand_side() -> Dictionary:
	if grabbed_body != null and grabbed_body.is_static:
		# 固定抓点的 Hinge 仍有绕指尖转动的动能，Weld 才完全固定。
		var center: Vector2 = grip_joint.anchor_b_world() if rotate_grip else body.com_world()
		var inertia: float = body.inertia + body.mass * body.com_world().distance_squared_to(center) if rotate_grip else 0.0
		return {"center": center, "inertia": inertia, "inv_mass": 0.0, "inv_inertia": 1.0 / inertia if inertia > 0.0 else 0.0}
	var mass: float = body.mass
	var center: Vector2 = body.com_world()
	var inertia: float = body.inertia
	if grabbed_body != null and not rotate_grip:
		mass += grabbed_body.mass
		center = (center * body.mass + grabbed_body.com_world() * grabbed_body.mass) / mass
		inertia += grabbed_body.inertia + body.mass * body.com_world().distance_squared_to(center)
		inertia += grabbed_body.mass * grabbed_body.com_world().distance_squared_to(center)
	return {"center": center, "inertia": inertia, "inv_mass": 1.0 / mass, "inv_inertia": 1.0 / inertia}

## 获得鼠标在世界坐标下的位置；没有摄像机时退化为相对位置。
func _get_mouse_world_position() -> Vector2:
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return player_body.com_world() + target_relative
	return camera.get_global_mouse_position()
#endregion
