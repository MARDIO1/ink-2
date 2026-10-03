extends Node2D

@export_group("Radial")
@export var radial_stiffness := 400.0
@export var radial_damping_ratio := 1.05
@export var min_radius := 16.0
@export var max_radius := 160.0

@export_group("Orbital")
@export var angular_stiffness := 400.0
@export var angular_damping_ratio := 1.05
@export var max_angular_speed := 12.0

@export var max_acceleration := 20000.0
@export var player_path := NodePath("../Player")

var body = null
var player_body = null
var linear_velocity := Vector2.ZERO
var target_angle_smoothed := 0.0
var target_angle_initialized := false

var debug_target_position := Vector2.ZERO
var debug_force := Vector2.ZERO
var debug_radial_error := 0.0
var debug_tangential_error := 0.0
var debug_current_radius := 0.0
var debug_target_radius := 0.0


func _physics_process(delta: float) -> void:
	_acquire_references()
	if player_body == null:
		return

	var pivot: Vector2 = player_body.position
	var mouse: Vector2 = get_global_mouse_position()
	var mouse_offset: Vector2 = mouse - pivot
	var target_radius: float = clampf(mouse_offset.length(), min_radius, max_radius)
	var raw_target_angle: float = mouse_offset.angle()

	if not target_angle_initialized:
		target_angle_smoothed = raw_target_angle
		target_angle_initialized = true
	else:
		target_angle_smoothed = _slew_angle(target_angle_smoothed, raw_target_angle, max_angular_speed * delta)

	var target_position: Vector2 = pivot + Vector2.from_angle(target_angle_smoothed) * target_radius
	var hand_position: Vector2 = body.position if body != null else global_position
	var hand_velocity: Vector2 = body.linear_velocity if body != null else linear_velocity
	var control: Dictionary = _polar_acceleration(pivot, hand_position, hand_velocity, player_body.linear_velocity, target_position)
	var acceleration: Vector2 = control["acceleration"]

	debug_target_position = target_position
	debug_force = acceleration
	debug_radial_error = control["radial_error"]
	debug_tangential_error = control["tangential_error"]
	debug_current_radius = control["current_radius"]
	debug_target_radius = control["target_radius"]

	if body == null:
		linear_velocity += acceleration * delta
		global_position += linear_velocity * delta
	else:
		body.clear_forces()
		body.awake = true
		body.sleep_timer = 0.0
		body.add_force(acceleration * body.mass)

	_apply_radius_constraint(pivot)
	var final_offset: Vector2 = (body.position if body != null else global_position) - pivot
	rotation = final_offset.angle()


func _acquire_references() -> void:
	if player_body == null:
		var player_node := get_node_or_null(player_path)
		if player_node != null:
			player_body = player_node.get("body")


func _polar_acceleration(
	pivot: Vector2,
	hand_position: Vector2,
	hand_velocity: Vector2,
	player_velocity: Vector2,
	target: Vector2
) -> Dictionary:
	var target_offset: Vector2 = target - pivot
	var target_radius: float = target_offset.length()

	var current_offset: Vector2 = hand_position - pivot
	var current_radius: float = maxf(current_offset.length(), 0.001)
	var radial: Vector2 = current_offset / current_radius
	var tangent: Vector2 = Vector2(-radial.y, radial.x)

	var radial_error: float = target_radius - current_radius
	var angle_error: float = wrapf(target_offset.angle() - current_offset.angle(), -PI, PI)
	var tangential_error: float = angle_error * current_radius

	var relative_velocity: Vector2 = hand_velocity - player_velocity
	var radial_velocity: float = relative_velocity.dot(radial)
	var tangential_velocity: float = relative_velocity.dot(tangent)
	var omega: float = tangential_velocity / current_radius

	var radial_velocity_gain: float = 2.0 * radial_damping_ratio * sqrt(radial_stiffness)
	var angular_velocity_gain: float = 2.0 * angular_damping_ratio * sqrt(angular_stiffness)

	var radial_acceleration: float = radial_stiffness * radial_error - radial_velocity_gain * radial_velocity - current_radius * omega * omega
	var tangential_acceleration: float = angular_stiffness * tangential_error - angular_velocity_gain * tangential_velocity

	var acceleration: Vector2 = radial_acceleration * radial + tangential_acceleration * tangent
	if max_acceleration > 0.0:
		acceleration = acceleration.limit_length(max_acceleration)

	return {
		"acceleration": acceleration,
		"radial_error": radial_error,
		"tangential_error": tangential_error,
		"current_radius": current_radius,
		"target_radius": target_radius,
	}


func _apply_radius_constraint(pivot: Vector2) -> void:
	var hand_position: Vector2 = body.position if body != null else global_position
	var offset: Vector2 = hand_position - pivot
	var radius: float = offset.length()
	if radius <= max_radius or radius <= 0.001:
		return

	var radial: Vector2 = offset / radius
	if body == null:
		global_position = pivot + radial * max_radius
		var outward_velocity: float = maxf(linear_velocity.dot(radial), 0.0)
		linear_velocity -= radial * outward_velocity
	else:
		body.position = pivot + radial * max_radius
		var outward_velocity: float = maxf(body.linear_velocity.dot(radial), 0.0)
		body.linear_velocity -= radial * outward_velocity


func _slew_angle(current_angle: float, target_angle: float, max_delta: float) -> float:
	if max_delta <= 0.0:
		return target_angle
	var difference: float = wrapf(target_angle - current_angle, -PI, PI)
	return current_angle + clampf(difference, -max_delta, max_delta)
