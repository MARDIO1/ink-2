#region 状态与上限
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

@export var max_force: float = 6000000.0
## 双倍起步冲量需要四倍动能预算，否则跳跃仍被原功率上限裁回。
@export var max_power: float = 16800000000.0
@export var move_speed: float = 200.0
@export var jump_impulse: float = 1800000.0
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
	if (axis == 0.0 and not jump) or support == null or delta <= 0.0 or not world.world.bodies.has(support):
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
	_apply_pair(impulse, delta)
	if jump:
		support = null
#endregion


#region 接触点成对冲量
## 两边在同一世界点受相反冲量；功率只计算执行器的做功，包含转动与起步动能。
func _apply_pair(impulse: Vector2, delta: float) -> void:
	var body = player.body
	var ra: Vector2 = contact_point - body.com_world()
	var rb: Vector2 = contact_point - support.com_world()
	var a: float = 0.5 * (impulse.length_squared() * (body.inv_mass + support.inv_mass)
		+ pow(ra.cross(impulse), 2) * body.inv_inertia + pow(rb.cross(impulse), 2) * support.inv_inertia)
	var b: float = impulse.dot(body.velocity_at(contact_point) - support.velocity_at(contact_point))
	var budget: float = maxf(max_power, 0.0) * delta
	var scale: float = 1.0
	if a + b > budget:
		var root: float = sqrt(b * b + 4.0 * a * budget)
		scale = 2.0 * budget / (b + root) if b > 0.0 else (root - b) / (2.0 * a)
	impulse *= scale
	debug_drive_impulse *= scale
	debug_jump_impulse *= scale
	debug_active_power = maxf(a * scale * scale + b * scale, 0.0) / delta
	debug_force = impulse.length() / delta
	body.apply_impulse(impulse, contact_point)
	support.apply_impulse(-impulse, contact_point)
	for receiver in [body, support]:
		receiver.awake = true
		receiver.sleep_timer = 0.0
#endregion
