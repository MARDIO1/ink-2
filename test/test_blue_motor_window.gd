extends SceneTree
## 蓝墨电机窗口：启动门、功率滑动平均、爬坡和能量账。

const Motor := preload("res://ink/blue/src/motor.gd")
var checks := 0
var failures := 0


class FakeBody:
	extends RefCounted
	var inv_mass := 1.0
	var inv_inertia := 1.0
	var linear_velocity := Vector2.ZERO
	var mass := 1.0
	var awake := false
	var sleep_timer := 10.0
	var frozen := false

	func com_world() -> Vector2:
		return Vector2.ZERO

	func velocity_at(_point: Vector2) -> Vector2:
		return linear_velocity

	func apply_impulse(_impulse: Vector2, _point: Vector2) -> void:
		pass


func _initialize() -> void:
	call_deferred("run")


func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])


func make_motor() -> Node2D:
	var motor: Node2D = Motor.new()
	motor.tip = Vector2(100, 0)
	motor.brush_width = 5
	motor.position = Vector2(10, 0)
	motor.rotation = 0.0
	motor.body = FakeBody.new()
	motor.buffer_capacity = 1.0e12
	motor.release_seconds = 0.2
	motor.hold_seconds = 1.0
	motor.startup_delay = 0.1
	motor.power_window = 0.2
	motor.force_ramp = 0.15
	root.add_child(motor)
	return motor


func run() -> void:
	var motor = make_motor()
	var constant: Array = []
	var first_force := 0.0
	for index in 240:
		motor.energy_buffer = 1.0e9
		motor.buffer_age = 0.0
		motor.consume(1.0 / 120.0, 300000.0, 1.0e12, 1.0e7)
		if index == 0:
			first_force = motor.applied_force
		constant.append(motor.received_power)
	check("startup delay keeps first frame at zero force", constant[0] == 0.0 and first_force == 0.0)
	var steady: Array = constant.slice(72, 240)
	var mean := 0.0
	for value in steady:
		mean += value
	mean /= steady.size()
	var variance := 0.0
	for value in steady:
		variance += pow(value - mean, 2.0)
	variance /= steady.size()
	check("constant supply reaches steady power", mean > 0.0 and sqrt(variance) / mean < 0.01)
	check("real powered impulse wakes a settled mechanism",motor.body.awake and motor.body.sleep_timer==0.0)
	motor.body.frozen=true
	motor.body.awake=false
	motor.consume(1.0/60.0,300000.0,1.0e12,1.0e7)
	check("offscreen frozen body receives no accumulated impulse",motor.applied_force==0 and motor.used_power==0 and not motor.body.awake)
	motor.queue_free()

	motor = make_motor()
	var peak := 0.0
	var mid_low := INF
	var budget_ok := true
	for index in 480:
		var high := (index / 12) % 2 == 0
		motor.energy_buffer = 1.0e9 if high else 2.0e8
		motor.buffer_age = 0.0
		motor.consume(1.0 / 120.0, 300000.0, 1.0e12, 1.0e7)
		budget_ok = budget_ok and motor.used_power <= motor.received_power * 1.0001
		if index >= 72:
			peak = maxf(peak, motor.received_power)
			if index % 24 == 18:
				mid_low = minf(mid_low, motor.received_power)
	check("square supply is smoothed below its peaks", peak > 0.0 and peak < 5.0e9 * 0.95)
	check("window still carries power through a short gap", mid_low > 0.0)
	check("smoothed force never exceeds its power budget", budget_ok)
	print("MOTOR_WINDOW constant_mean=%.3f peak=%.3f" % [mean, peak])
	print("MOTOR_WINDOW_RESULT checks=%d failures=%d" % [checks, failures])
	motor.queue_free()
	quit(1 if failures else 0)
