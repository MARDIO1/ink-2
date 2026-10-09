#region 依赖
extends Node

@onready var player = $".."
@onready var world = $"../.."
var support = null
var contact_point: Vector2 = Vector2.ZERO
var support_normal: Vector2 = Vector2.UP
var debug_active_power: float = 0.0
var debug_force: float = 0.0
var debug_drive_impulse: Vector2 = Vector2.ZERO
var debug_jump_impulse: Vector2 = Vector2.ZERO
var debug_upright_torque: float = 0.0

@export_group("脚部执行器")
## AD 最大切向驱动力，单位 引擎质量单位·px/s²；只在脚部有接触支撑时生效。
@export var max_force: float = 6000000.0
## 脚部成对冲量的最大正做功率，单位 引擎质量单位·px²/s³，与手部独立。
## 移动与跳跃共用此预算；跳跃冲量翻倍约需四倍起步动能，可能被该上限裁剪。
@export var max_power: float = 16800000000.0
## 沿接触面移动的目标相对速度，单位 px/s；不是直接设置刚体速度。
@export var move_speed: float = 200.0
## 跳跃请求冲量，单位 引擎质量单位·px/s；沿支撑法向施加，仍受功率限制。
@export var jump_impulse: float = 1800000.0
#endregion


#region 世界竖直回复力矩
## 到**世界竖直**的角刚度（力矩 / 弧度）；0 = 关闭。
## ⚠️ 参考取世界竖直，不是支撑面法向 —— 支撑面会凹凸不平，而世界竖直的代码就是 body.rotation。
## ⚠️ 必须大于「倾倒自重的最大力矩」 m·g·h 才可能真的站稳（当前数字见 `actor/player/doc/脚.md`），
##    只比 m·g·b 大是不够的，会卡在半倒的姿态上慢慢磨。
## 实测（kick=3 rad/s）：本文件的 1.0e9 一步回正，尾巴角度 0.000；`player.tscn` 现在设 5e8。
@export var upright_stiffness: float = 1000000000.0
## 相对**支撑**的角阻尼（力矩 / (弧度/秒)），用来把来回摆压下去。
## 地面是静态体 → support.angular_velocity 恒为 0，这一项不会把力矩吃掉。
@export var upright_damping: float = 300000000.0
## 回复力矩绝对值上限（力矩）。0 = 不限。
## 必须限：不限流时瞬时力矩可达 -1800 MN，作用在 1 格高的碎块上会把它甩飞。
@export var max_upright_torque: float = 600000000.0
#endregion


#region 接触与输入
func _ready() -> void:
	process_physics_priority = -30


## 复用当前子步接触；允许部分贴合，不扫描像素或要求上一帧已有承重冲量。
func update_support(contacts: Array) -> void:
	support = null
	var body = player.body
	for contact in contacts:
		if contact.a != body and contact.b != body:
			continue
		for point in contact.points:
			var normal: Vector2 = -point.normal if contact.a == body else point.normal
			# 脚指世界重力方向下侧；翻身后局部 +Y 不再是地面方向。
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
	# ⚠️ 不能再用「没输入就早退」——回复力矩没有输入也要工作，否则一松手就倒。
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
	# 回复力矩和脚步推力共用**同一份**功率预算，所以并进同一次 _apply_pair。
	var angular: float = _upright_angular_impulse(delta)
	if impulse == Vector2.ZERO and angular == 0.0:
		return
	_apply_pair(impulse, delta, angular)
	if jump:
		support = null
#endregion


## 世界竖直回复力矩的**角冲量**。腾空（support == null）时调用方已经早退，所以这里不处理腾空。
func _upright_angular_impulse(delta: float) -> float:
	if upright_stiffness == 0.0 and upright_damping == 0.0:
		return 0.0
	var body = player.body
	var err: float = wrapf(-body.rotation, -PI, PI)
	var spin: float = body.angular_velocity - support.angular_velocity
	var torque: float = upright_stiffness * err - upright_damping * spin
	if max_upright_torque > 0.0:
		torque = clampf(torque, -max_upright_torque, max_upright_torque)
	debug_upright_torque = torque
	return torque * delta


#region 接触点成对冲量
## 两边在同一世界点受相反冲量；功率只计算执行器的做功，包含转动与起步动能。
## angular 是**角冲量**（不是力矩），和 impulse 共享同一份预算。
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
