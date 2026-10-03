extends Node

const Query := preload("res://addons/pixel_destruction/physics/query.gd")

#region 参数
@export var move_accel := 1300.0
@export var max_speed := 210.0
@export var ground_brake := 1800.0
@export var air_control := 0.35
@export var jump_speed := 400.0
@export var coyote_time := 0.10
@export var jump_buffer_time := 0.12
@export var ground_probe := 4.0
#endregion

#region 状态
var body = null
var coyote := 0.0
var jump_buffer := 0.0
#endregion

#region 生命周期
func _physics_process(dt: float) -> void:
	body = get_parent().get("body")
	if body == null:
		return

	# add_force 是持久累加器，节点版 PixelWorld 不会自动清空
	body.clear_forces()
	body.awake = true
	body.sleep_timer = 0.0

	var grounded := _is_grounded()
	_update_timers(grounded, dt)
	_apply_move(grounded, dt)
	_apply_jump()
#endregion

#region 力控
func _apply_move(grounded: bool, dt: float) -> void:
	var axis := Input.get_axis("move_left", "move_right")
	var control := 1.0 if grounded else air_control

	if absf(axis) > 0.01:
		var dv: float = axis * max_speed - body.linear_velocity.x
		var accel := clampf(dv / dt, -move_accel * control, move_accel * control)
		body.add_force(Vector2(accel * body.mass, 0.0))
		return

	if grounded and absf(body.linear_velocity.x) > 0.5:
		var brake := minf(absf(body.linear_velocity.x) / dt, ground_brake)
		body.add_force(Vector2(-signf(body.linear_velocity.x) * brake * body.mass, 0.0))


func _apply_jump() -> void:
	if jump_buffer <= 0.0 or coyote <= 0.0:
		return
	body.apply_central_impulse(Vector2.UP * jump_speed * body.mass)
	jump_buffer = 0.0
	coyote = 0.0
#endregion

#region 地面检测
func _update_timers(grounded: bool, dt: float) -> void:
	coyote = coyote_time if grounded else maxf(0.0, coyote - dt)
	jump_buffer = jump_buffer_time if Input.is_action_just_pressed("jump") else maxf(0.0, jump_buffer - dt)


func _is_grounded() -> bool:
	var box: Rect2 = body.aabb
	if box.size.x <= 0.0:
		return false

	var y := box.end.y + 1.0
	var xs := [box.position.x + 2.0, box.get_center().x, box.end.x - 2.0]
	for x in xs:
		var hit = Query.raycast(Vector2(x, y), Vector2.DOWN,
			ground_probe, 0.0, [body])
		if hit.hit and hit.normal.y < -0.5:
			return true
	return false
#endregion
