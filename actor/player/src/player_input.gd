#region 依赖
extends Node

@onready var player = $".."
@onready var world = $"../.."
const UPRIGHT_ANGLE_DEADZONE: float = 0.001
const UPRIGHT_SPIN_DEADZONE: float = 0.03
var support = null
var contact_point: Vector2 = Vector2.ZERO
var support_normal: Vector2 = Vector2.UP
var debug_active_power: float = 0.0
var debug_force: float = 0.0
var debug_drive_impulse: Vector2 = Vector2.ZERO
var debug_jump_impulse: Vector2 = Vector2.ZERO
var debug_upright_torque: float = 0.0

@export_group("脚部执行器")
## 最大切向驱动力；只在脚部有支撑时生效。
@export var max_force: float = 6000000.0
## 移动、跳跃和回正共用的最大正做功率。
@export var max_power: float = 16800000000.0
## 沿支撑面的目标相对速度，单位 px/s。
@export var move_speed: float = 200.0
## 沿支撑法向施加的跳跃冲量。
@export var jump_impulse: float = 1800000.0
#endregion


#region 回正控制器
## 角度误差产生的回复力矩系数；0 表示关闭弹簧项。
@export var upright_stiffness: float = 1000000000.0
## 玩家与支撑体相对角速度产生的制动力矩系数；0 表示关闭阻尼项。
@export var upright_damping: float = 30000000.0
## 回复力矩绝对值上限；0 表示不限制。
@export var max_upright_torque: float = 600000000.0
#endregion


#region 接触与输入
func _ready() -> void:
	process_physics_priority = -30


## 复用当前子步的有效脚部接触。
func update_support(contacts: Array) -> void:
	support = null
	var body = player.body
	for contact in contacts:
		if contact.a != body and contact.b != body:
			continue
		for point in contact.points:
			var normal: Vector2 = -point.normal if contact.a == body else point.normal
			if point.dist > 0.05 or normal.y > -0.5 or point.position.y < body.com_world().y:
				continue
			support = contact.b if contact.a == body else contact.a
			contact_point = point.position
			support_normal = normal
			return


func _physics_process(delta: float) -> void:
	apply_input(Input.get_axis("move_left", "move_right"), Input.is_action_just_pressed("jump"), delta)


func apply_input(axis: float, jump: bool, delta: float) -> void:
	debug_active_power = 0.0
	debug_force = 0.0
	debug_drive_impulse = Vector2.ZERO
	debug_jump_impulse = Vector2.ZERO
	debug_upright_torque = 0.0
	if support == null or delta <= 0.0 or not world.world.bodies.has(support):
		return
	var body = player.body
	var tangent: Vector2 = Vector2(-support_normal.y, support_normal.x)
	var relative: Vector2 = body.velocity_at(contact_point) - support.velocity_at(contact_point)
	var impulse: Vector2 = Vector2.ZERO
	if axis != 0.0:
		var force: float = clampf((axis * move_speed - relative.dot(tangent)) * body.mass / delta, -max_force, max_force)
		impulse = tangent * force * delta
		debug_drive_impulse = impulse
	if jump:
		debug_jump_impulse = support_normal * jump_impulse
		impulse += debug_jump_impulse
	var angular: float = _upright_angular_impulse(delta)
	if impulse == Vector2.ZERO and angular == 0.0:
		return
	_apply_pair(impulse, delta, angular)
	if jump:
		support = null
#endregion


## 返回回正角冲量。直立且接近静止时不再用接触噪声唤醒刚体。
func _upright_angular_impulse(delta: float) -> float:
	if upright_stiffness == 0.0 and upright_damping == 0.0:
		return 0.0
	var body = player.body
	var err: float = wrapf(-body.rotation, -PI, PI)
	var spin: float = body.angular_velocity - support.angular_velocity
	if absf(err) < UPRIGHT_ANGLE_DEADZONE and absf(spin) < UPRIGHT_SPIN_DEADZONE:
		return 0.0
	var torque: float = upright_stiffness * err - upright_damping * spin
	if max_upright_torque > 0.0:
		torque = clampf(torque, -max_upright_torque, max_upright_torque)
	debug_upright_torque = torque
	return torque * delta


#region 接触点成对冲量
## 在同一接触点施加成对冲量，并把平动与转动限制在同一功率预算内。
func _apply_pair(impulse: Vector2, delta: float, angular: float = 0.0) -> void:
	var body = player.body
	var ra: Vector2 = contact_point - body.com_world()
	var rb: Vector2 = contact_point - support.com_world()
	var a: float = 0.5 * (impulse.length_squared() * (body.inv_mass + support.inv_mass)
		+ pow(ra.cross(impulse), 2) * body.inv_inertia + pow(rb.cross(impulse), 2) * support.inv_inertia
		+ angular * angular * (body.inv_inertia + support.inv_inertia))
	var b: float = impulse.dot(body.velocity_at(contact_point) - support.velocity_at(contact_point)) \
		+ angular * (body.angular_velocity - support.angular_velocity)
	var budget: float = maxf(max_power, 0.0) * delta
	var scale: float = 1.0
	if a + b > budget:
		var root: float = sqrt(b * b + 4.0 * a * budget)
		scale = 2.0 * budget / (b + root) if b > 0.0 else (root - b) / (2.0 * a)
	impulse *= scale
	debug_drive_impulse *= scale
	debug_jump_impulse *= scale
	debug_upright_torque *= scale
	debug_active_power = maxf(a * scale * scale + b * scale, 0.0) / delta
	debug_force = impulse.length() / delta
	body.apply_impulse(impulse, contact_point)
	support.apply_impulse(-impulse, contact_point)
	if angular != 0.0:
		body.apply_torque_impulse(angular)
		support.apply_torque_impulse(-angular)
	for receiver in [body, support]:
		receiver.awake = true
		receiver.sleep_timer = 0.0
#endregion
