extends SceneTree

const MAIN := preload("res://map/asset/main.tscn")
const DT := 1.0 / 60.0
const SETTLE_FRAME := 540
const TOTAL_FRAMES := 720


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	for config in [
		["implicit", 140.0, 32.0, 0.5, false],
		["explicit", 140.0, 32.0, 0.5, false],
		["damping_24", 140.0, 24.0, 0.5, false],
		["damping_40", 140.0, 40.0, 0.5, false],
		["ccd_2", 140.0, 32.0, 2.0, false],
		["relative_target", 140.0, 32.0, 0.5, true],
		["pull_implicit", 140.0, 32.0, 0.5, true, true],
		["pull_explicit", 140.0, 32.0, 0.5, true, true],
	]:
		await _measure(config)
	quit()


func _measure(config: Array) -> void:
	var scene := MAIN.instantiate()
	scene.auto_step = false
	scene.auto_render = false
	scene.set_physics_process(false)
	root.add_child(scene)
	await process_frame

	var control: Node = scene.get_node("Player/Arm/Hand/HandControl")
	var player = scene.get_node("Player").body
	var hand = scene.get_node("Player/Arm/Hand").body
	var ground = scene.get_node("Ground").body
	control.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	control._remove_arm()
	_place(player, Vector2(0, 180))
	_place(hand, Vector2(0, 211))
	control.target_relative = Vector2(0, 31)
	control.position_stiffness = config[1]
	control.position_damping = config[2]
	scene.world.ccd_max_motion = config[3]
	control._ensure_arm_joint()
	control.set_grip(true)
	control._update_grip(DT)
	if control.grabbed_body != ground:
		push_error("指尖没有抓到地面")
		return
	scene.world.gravity = Vector2(0, 980)

	var positions: Array[Vector2] = []
	var angles: Array[float] = []
	var weld_error := 0.0
	var reach_error := 0.0
	for frame in TOTAL_FRAMES:
		var radius := 95.0 + 55.0 * sin(float(frame) * TAU / 240.0) if config.size() > 5 else 150.0
		var target: Vector2 = player.com_world() + Vector2(0, radius) if config[4] else Vector2(0, 330)
		if config[0] in ["explicit", "pull_explicit"]:
			_step_explicit(control, target)
		else:
			control.set_target_world(target)
			control._physics_process(DT)
		scene.world.step(DT)
		if frame >= SETTLE_FRAME:
			positions.append(player.com_world())
			angles.append(player.rotation)
			weld_error = maxf(weld_error,
				control.grip_joint.anchor_a_world().distance_to(control.grip_joint.anchor_b_world()))
			reach_error = maxf(reach_error,
				maxf(player.com_world().distance_to(hand.com_world()) - control.max_reach, 0.0))

	var result := _metrics(positions, angles)
	print("[Jitter] ", config[0],
		" position=", result["position"],
		" step_rms=", result["step_rms"],
		" high_rms=", result["high_rms"],
		" reversals=", result["reversals"],
		" angle=", result["angle"],
		" weld=", weld_error,
		" reach=", reach_error)
	control._release_grab()
	control._remove_arm()
	scene.queue_free()
	await process_frame


func _step_explicit(control: Node, target: Vector2) -> void:
	var hand_position: Vector2 = control.body.com_world()
	var velocity: Vector2 = control.body.linear_velocity - control.player_body.linear_velocity
	var acceleration: Vector2 = ((target - hand_position) * control.position_stiffness
		- velocity * control.position_damping)
	var inverse_mass: float = control._hand_side()["inv_mass"] + control.player_body.inv_mass
	var force: Vector2 = (acceleration / inverse_mass).limit_length(control.max_force)
	force = control._limit_power(force, 0.0, hand_position, DT)
	control._apply_internal_wrench(force, 0.0, hand_position, DT)


func _metrics(positions: Array[Vector2], angles: Array[float]) -> Dictionary:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var angle_lo := INF
	var angle_hi := -INF
	var step_energy := 0.0
	var high_energy := 0.0
	var reversals := 0
	var previous_step := Vector2.ZERO
	for i in positions.size():
		lo = lo.min(positions[i])
		hi = hi.max(positions[i])
		angle_lo = minf(angle_lo, angles[i])
		angle_hi = maxf(angle_hi, angles[i])
		if i == 0:
			continue
		var step := positions[i] - positions[i - 1]
		step_energy += step.length_squared()
		if i > 1:
			var high := step - previous_step
			high_energy += high.length_squared()
			if step.dot(previous_step) < 0.0:
				reversals += 1
		previous_step = step
	return {
		"position": (hi - lo).length(),
		"step_rms": sqrt(step_energy / maxf(positions.size() - 1, 1)),
		"high_rms": sqrt(high_energy / maxf(positions.size() - 2, 1)),
		"reversals": reversals,
		"angle": angle_hi - angle_lo,
	}


func _place(body, center: Vector2) -> void:
	body.rotation = 0.0
	body.position = center - body.local_com
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.clear_forces()
	body.awake = true
	body.refresh_com()
	body.update_aabb()
