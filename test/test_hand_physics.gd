extends SceneTree

const MAIN_SCENE := preload("res://map/asset/main.tscn")
const DT := 1.0 / 60.0

var _passed := 0
var _failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var rig := await _make_rig()
	_test_presentation(rig)
	_check("mass/body hand ratio", rig["player"].mass / rig["hand"].mass > 50.0,
		"body=%.1f hand=%.1f" % [rig["player"].mass, rig["hand"].mass])
	_test_angular_switch(rig)
	_reset_rig(rig)
	_test_free_arm(rig)
	_reset_rig(rig)
	_test_dynamic_grab(rig)
	_reset_rig(rig)
	_test_static_grab(rig)
	_reset_rig(rig)
	_test_grounded_lift(rig)
	_reset_rig(rig)
	_test_grounded_pushup(rig)
	_reset_rig(rig)
	_test_box_pushup(rig)
	_reset_rig(rig)
	_test_free_box_reaction(rig)

	print("[HandPhysics] %d passed, %d failed" % [_passed, _failed])
	var scene: Node = rig["scene"]
	var control: Node = rig["control"]
	control._release_grab()
	if control.arm_joint != null:
		control._remove_arm()
	control.arm_joint = null
	rig.clear()
	scene.queue_free()
	await process_frame
	await process_frame
	quit(0 if _failed == 0 else 1)


func _make_rig() -> Dictionary:
	var scene := MAIN_SCENE.instantiate()
	scene.auto_step = false
	scene.auto_render = false
	scene.set_physics_process(false)
	var control: Node = scene.get_node("Player/Arm/Hand/HandControl")
	var player_input: Node = scene.get_node("Player/PlayerInput")
	control.set_physics_process(false)
	player_input.set_physics_process(false)
	root.add_child(scene)
	await process_frame

	var world = scene.world
	world.gravity = Vector2.ZERO
	return {
		"scene": scene,
		"world": world,
		"control": control,
		"player": scene.get_node("Player").body,
		"hand": scene.get_node("Player/Arm/Hand").body,
		"arm": scene.get_node("Player/Arm").body,
		"box": scene.get_node("Box").body,
		"ground": scene.get_node("Ground").body,
	}


func _reset_rig(rig: Dictionary) -> void:
	var control: Node = rig["control"]
	control._release_grab()
	if control.arm_joint != null:
		control._remove_arm()
	control.arm_joint = null
	control.target_relative = Vector2(72.0, 0.0)
	control.set_grip(false)

	_set_body_state(rig["player"], Vector2.ZERO)
	_set_body_state(rig["hand"], Vector2(72.0, 0.0))
	_set_body_state(rig["box"], Vector2(700.0, 0.0))
	_set_body_state(rig["arm"], Vector2.ZERO)
	for body in [rig["player"], rig["hand"], rig["box"], rig["arm"]]:
		body.clear_forces()


func _test_angular_switch(rig: Dictionary) -> void:
	_reset_rig(rig)
	var control: Node = rig["control"]
	var player = rig["player"]
	var hand = rig["hand"]
	control.conserve_angular_momentum = false
	control._apply_internal_wrench(Vector2(0, -1000), 0.0, hand.com_world(), DT)
	_check("center force/no body torque", player.angular_velocity == 0.0)
	_check("center force/no hand torque", hand.angular_velocity == 0.0)
	_reset_rig(rig)
	control.conserve_angular_momentum = true
	control._apply_internal_wrench(Vector2(0, -1000), 0.0, hand.com_world(), DT)
	_check("angular switch/closed impulse", absf(_angular_momentum([player, hand])) < 0.01)
	control.conserve_angular_momentum = false


func _test_presentation(rig: Dictionary) -> void:
	print("[GameLoop] window, camera, initial visibility")
	var scene: Node2D = rig["scene"]
	var camera: Camera2D = scene.get_node("Camera2D")
	var player = rig["player"]
	var ground = rig["ground"]
	camera._physics_process(DT)
	var view_size: Vector2 = scene.game_view_size()
	var view_rect := Rect2(camera.global_position - view_size * 0.5, view_size)
	_check(
		"window/logical size",
		ProjectSettings.get_setting("display/window/size/viewport_width") == 960
		and ProjectSettings.get_setting("display/window/size/viewport_height") == 540
		and ProjectSettings.get_setting("display/window/size/mode") == DisplayServer.WINDOW_MODE_FULLSCREEN
	)
	_check("camera/follows player", camera.global_position.distance_to(player.com_world()) < 0.01)
	_check("camera/player visible", view_rect.has_point(player.com_world()))
	_check("camera/ground visible", view_rect.intersects(ground.aabb))


func _test_free_arm(rig: Dictionary) -> void:
	print("[HandPhysics] free arm: power, momentum, energy, reach")
	var control: Node = rig["control"]
	var player = rig["player"]
	var hand = rig["hand"]
	var bodies := [player, hand]
	var initial_momentum := _linear_momentum(bodies)
	var initial_angular := _angular_momentum(bodies)
	var initial_energy := _kinetic_energy(bodies)
	var supplied_energy := 0.0
	var max_radius := 0.0
	var max_power_ratio := 0.0
	var max_rod_angle_error := 0.0
	var angular_effort_impulse := 0.0

	for frame in 360:
		player.clear_forces()
		control.set_target_world(player.com_world() + Vector2(260.0, -100.0))
		control._physics_process(DT)
		supplied_energy += control.debug_active_power * DT
		angular_effort_impulse += control.debug_angular_effort * DT
		var power_cap: float = control.max_power
		if power_cap > 0.0:
			max_power_ratio = maxf(max_power_ratio, control.debug_active_power / power_cap)
		rig["world"].step(DT)
		max_radius = maxf(max_radius, hand.com_world().distance_to(player.com_world()))
		var rod_direction: Vector2 = hand.com_world() - player.com_world()
		max_rod_angle_error = maxf(max_rod_angle_error, absf(wrapf(hand.rotation - rod_direction.angle(), -PI, PI)))

	var momentum_error := (_linear_momentum(bodies) - initial_momentum).length()
	var angular_error := absf(_angular_momentum(bodies) - initial_angular)
	var energy_gain := _kinetic_energy(bodies) - initial_energy
	_check("free/reach", max_radius <= control.max_reach + 0.75, "max=%.3f" % max_radius)
	_check("free/power", max_power_ratio <= 1.00001, "ratio=%.6f" % max_power_ratio)
	_check("free/rigid rod direction", max_rod_angle_error < deg_to_rad(0.1),
		"max_degrees=%.6f" % rad_to_deg(max_rod_angle_error))
	_check("free/linear momentum", momentum_error < 0.25, "error=%.6f" % momentum_error)
	_check(
		"free/body angular velocity (center mode)",
		absf(player.angular_velocity) < 0.001 if not control.conserve_angular_momentum else angular_error <= angular_effort_impulse * 0.0015,
		"error=%.3f relative=%.6f" % [angular_error, angular_error / maxf(angular_effort_impulse, 1.0)]
	)
	_check(
		"free/no solver energy",
		energy_gain <= supplied_energy * 1.02 + 2.0,
		"gain=%.3f supplied=%.3f" % [energy_gain, supplied_energy]
	)


func _test_dynamic_grab(rig: Dictionary) -> void:
	print("[HandPhysics] dynamic grab: lift, weld, momentum")
	var control: Node = rig["control"]
	var player = rig["player"]
	var hand = rig["hand"]
	var box = rig["box"]
	_set_body_state(box, hand.com_world())
	var grabbed: bool = control._begin_grab(box, hand.com_world())
	control.set_grip(true)
	_check("dynamic/grab created", grabbed and control.grip_joint != null)
	var bodies := [player, hand, box]
	var grip_relative_angle: float = wrapf(box.rotation - hand.rotation, -PI, PI)
	var maximum_grip_angle_error := 0.0
	var initial_momentum := _linear_momentum(bodies)
	var initial_angular := _angular_momentum(bodies)
	var max_grip_error := 0.0
	var max_radius := 0.0
	var angular_effort_impulse := 0.0
	var linear_effort_impulse := 0.0

	# 第一阶段悬空运动，只验证抓握系统内部的线动量交换。
	for _frame in 180:
		player.clear_forces()
		box.clear_forces()
		control.set_target_world(Vector2(72.0, -90.0))
		control._physics_process(DT)
		angular_effort_impulse += control.debug_angular_effort * DT
		linear_effort_impulse += control.debug_linear_effort * DT
		rig["world"].step(DT)
		max_grip_error = maxf(
			max_grip_error,
			control.grip_joint.anchor_a_world().distance_to(control.grip_joint.anchor_b_world())
		)
		max_radius = maxf(max_radius, hand.com_world().distance_to(player.com_world()))
		maximum_grip_angle_error = maxf(maximum_grip_angle_error,
			absf(wrapf(box.rotation - hand.rotation - grip_relative_angle, -PI, PI)))

	var momentum_error := (_linear_momentum(bodies) - initial_momentum).length()
	var angular_error := absf(_angular_momentum(bodies) - initial_angular)

	# 第二阶段从干净姿态开始，避免上一阶段已拉满绳长影响举物验收。
	control._release_grab()
	if control.arm_joint != null:
		control._remove_arm()
	control.arm_joint = null
	_set_body_state(player, Vector2.ZERO)
	_set_body_state(hand, Vector2(72.0, 0.0))
	_set_body_state(box, hand.com_world())
	for reset_body in [player, hand, box]:
		reset_body.clear_forces()
	control.target_relative = Vector2(72.0, 0.0)
	control._begin_grab(box, hand.com_world())
	control.set_grip(true)
	var supported_start_y: float = box.com_world().y
	var minimum_box_y := supported_start_y
	var late_max_speed := 0.0
	var late_min_position := Vector2(INF, INF)
	var late_max_position := Vector2(-INF, -INF)
	var support_joint = rig["world"].add_weld(player, rig["ground"], player.com_world())
	support_joint.contacts_enabled = false
	rig["world"].gravity = Vector2(0.0, 980.0)
	for lift_frame in 600:
		player.clear_forces()
		box.clear_forces()
		control.set_target_world(player.com_world() + Vector2(72.0, -90.0))
		control._physics_process(DT)
		rig["world"].step(DT)
		minimum_box_y = minf(minimum_box_y, box.com_world().y)
		if lift_frame >= 540:
			late_max_speed = maxf(late_max_speed, box.linear_velocity.length())
			late_min_position = late_min_position.min(box.com_world())
			late_max_position = late_max_position.max(box.com_world())
	support_joint.remove()
	rig["world"].gravity = Vector2.ZERO

	_check("dynamic/lifted", minimum_box_y < supported_start_y - 45.0, "dy=%.3f" % (minimum_box_y - supported_start_y))
	_check("dynamic/no late jitter", late_max_speed < 12.0, "max_speed=%.3f" % late_max_speed)
	_check(
		"dynamic/subpixel jitter",
		(late_max_position - late_min_position).length() < 0.25,
		"peak_to_peak=%.4f" % (late_max_position - late_min_position).length()
	)
	_check("dynamic/weld stable", max_grip_error < 0.75, "max=%.4f" % max_grip_error)
	_check("dynamic/weld relative angle", maximum_grip_angle_error < deg_to_rad(0.1),
		"max_degrees=%.6f" % rad_to_deg(maximum_grip_angle_error))
	_check("dynamic/reach", max_radius <= control.max_reach + 0.75, "max=%.3f" % max_radius)
	_check(
		"dynamic/linear momentum",
		momentum_error <= linear_effort_impulse * 0.00001,
		"error=%.3f relative=%.8f" % [momentum_error, momentum_error / maxf(linear_effort_impulse, 1.0)]
	)
	_check(
		"dynamic/body angular velocity (center mode)",
		absf(player.angular_velocity) < 0.001 if not control.conserve_angular_momentum else angular_error <= angular_effort_impulse * 0.025,
		"error=%.3f relative=%.6f" % [angular_error, angular_error / maxf(angular_effort_impulse, 1.0)]
	)


func _test_static_grab(rig: Dictionary) -> void:
	print("[HandPhysics] static grab: push-up motion and late jitter")
	var control: Node = rig["control"]
	var player = rig["player"]
	var hand = rig["hand"]
	var ground = rig["ground"]
	# 刚性末端抓住地面后不能凭空转腕；沿连杆方向测试伸缩支撑。
	_set_body_state(hand, Vector2(0, 72))
	var anchor: Vector2 = hand.com_world()
	var grabbed: bool = control._begin_grab(ground, anchor)
	control.set_grip(true)
	_check("static/grab created", grabbed and control.grip_joint != null)
	var initial_player_y: float = player.com_world().y
	var minimum_player_y := initial_player_y
	var max_grip_error := 0.0
	var max_radius := 0.0
	var late_max_speed := 0.0
	var late_min_position := Vector2(INF, INF)
	var late_max_position := Vector2(-INF, -INF)

	for frame in 600:
		player.clear_forces()
		if frame < 150:
			control.set_target_world(anchor + Vector2(0.0, 80.0))
		else:
			control.set_target_world(anchor)
		control._physics_process(DT)
		rig["world"].step(DT)
		minimum_player_y = minf(minimum_player_y, player.com_world().y)
		max_grip_error = maxf(
			max_grip_error,
			control.grip_joint.anchor_a_world().distance_to(control.grip_joint.anchor_b_world())
		)
		max_radius = maxf(max_radius, hand.com_world().distance_to(player.com_world()))
		if frame >= 540:
			late_max_speed = maxf(late_max_speed, player.linear_velocity.length())
			late_min_position = late_min_position.min(player.com_world())
			late_max_position = late_max_position.max(player.com_world())

	_check("static/body moved", minimum_player_y < initial_player_y - 10.0, "dy=%.3f" % (minimum_player_y - initial_player_y))
	_check("static/weld stable", max_grip_error < 0.75, "max=%.4f" % max_grip_error)
	_check("static/reach", max_radius <= control.max_reach + 0.75, "max=%.3f" % max_radius)
	_check("static/no late jitter", late_max_speed < 12.0, "max_speed=%.3f" % late_max_speed)
	_check(
		"static/subpixel jitter",
		(late_max_position - late_min_position).length() < 0.25,
		"peak_to_peak=%.4f" % (late_max_position - late_min_position).length()
	)


func _set_body_state(body, center: Vector2) -> void:
	body.rotation = 0.0
	body.position = center - body.local_com
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.awake = true
	body.sleep_timer = 0.0
	body.refresh_com()
	body.update_aabb()


func _test_grounded_lift(rig: Dictionary) -> void:
	print("[GameLoop] actual ground support: lift without weld support")
	var control: Node = rig["control"]
	var player = rig["player"]
	var hand = rig["hand"]
	var box = rig["box"]
	var center := Vector2(0, 215)
	_set_body_state(player, center)
	_set_body_state(hand, center + Vector2(72, 0))
	_set_body_state(box, hand.com_world())
	rig["world"].gravity = Vector2(0, 980)
	control._begin_grab(box, hand.com_world())
	control.set_grip(true)
	var minimum_player_y := center.y
	var maximum_spin := 0.0
	var maximum_radius := 0.0
	for frame in 720:
		control.set_target_world(player.com_world() + Vector2(72, -70))
		control._physics_process(DT)
		rig["world"].step(DT)
		minimum_player_y = minf(minimum_player_y, player.com_world().y)
		maximum_spin = maxf(maximum_spin, absf(player.angular_velocity))
		maximum_radius = maxf(maximum_radius, hand.com_world().distance_to(player.com_world()))
	_check("grounded/no takeoff", minimum_player_y >= center.y - 5.0,
		"rise=%.3f" % (center.y - minimum_player_y))
	_check("grounded/no body spin", maximum_spin < 1.0, "max=%.4f" % maximum_spin)
	_check("grounded/held object lifted", box.com_world().y < center.y - 40.0,
		"height=%.3f" % (center.y - box.com_world().y))
	_check("grounded/reach", maximum_radius <= control.max_reach, "max=%.3f" % maximum_radius)
	rig["world"].gravity = Vector2.ZERO


func _test_grounded_pushup(rig: Dictionary) -> void:
	print("[GameLoop] real ground grab: support body under gravity")
	var control: Node = rig["control"]
	var player = rig["player"]
	var hand = rig["hand"]
	_set_body_state(player, Vector2(0, 215))
	_set_body_state(hand, Vector2(0, 231))
	rig["world"].gravity = Vector2(0, 980)
	control.set_grip(true)
	control.set_target_world(Vector2(0, 300))
	var initial_y: float = player.com_world().y
	var maximum_power := 0.0
	var maximum_reach := 0.0
	var supplied_energy := 0.0
	var late_min := Vector2(INF, INF)
	var late_max := Vector2(-INF, -INF)
	var late_max_speed := 0.0
	for frame in 360:
		control._physics_process(DT)
		rig["world"].step(DT)
		maximum_power = maxf(maximum_power, control.debug_active_power)
		supplied_energy += control.debug_active_power * DT
		maximum_reach = maxf(maximum_reach, player.com_world().distance_to(hand.com_world()))
		if frame >= 300:
			late_min = late_min.min(player.com_world())
			late_max = late_max.max(player.com_world())
			late_max_speed = maxf(late_max_speed, player.linear_velocity.length())
	_check("pushup/ground acquired through query", control.grabbed_body == rig["ground"])
	_check("pushup/body supported under gravity", player.com_world().y < initial_y - 30.0,
		"rise=%.3f" % (initial_y - player.com_world().y))
	_check("pushup/power budget", maximum_power <= control.max_power * 1.00001)
	_check("pushup/reach", maximum_reach <= control.max_reach)
	_check("pushup/late jitter", (late_max - late_min).length() < 0.25,
		"peak_to_peak=%.6f max_speed=%.6f" % [(late_max - late_min).length(), late_max_speed])
	var gained_energy: float = player.mass * 980.0 * (initial_y - player.com_world().y) + _kinetic_energy([player])
	_check("pushup/work covered by budget", gained_energy <= supplied_energy * 1.001)
	control.set_grip(false)
	control._release_grab()
	rig["world"].gravity = Vector2.ZERO


func _test_box_pushup(rig: Dictionary) -> void:
	print("[GameLoop] push down on a dynamic box supported by ground")
	var control: Node = rig["control"]
	var player = rig["player"]
	var hand = rig["hand"]
	var box = rig["box"]
	_set_body_state(player, Vector2(0, 180))
	_set_body_state(box, Vector2(0, 215))
	_set_body_state(hand, Vector2(0, 199))
	rig["world"].gravity = Vector2(0, 980)
	control.set_grip(true)
	control.set_target_world(Vector2(0, 330))
	var initial_y: float = player.com_world().y
	var supplied_energy := 0.0
	var maximum_power := 0.0
	var maximum_force := 0.0
	var maximum_reach := 0.0
	var late_min := Vector2(INF, INF)
	var late_max := Vector2(-INF, -INF)
	for frame in 360:
		control._physics_process(DT)
		rig["world"].step(DT)
		supplied_energy += control.debug_active_power * DT
		maximum_power = maxf(maximum_power, control.debug_active_power)
		maximum_force = maxf(maximum_force, control.debug_linear_effort)
		maximum_reach = maxf(maximum_reach, player.com_world().distance_to(hand.com_world()))
		if frame >= 300:
			late_min = late_min.min(player.com_world())
			late_max = late_max.max(player.com_world())
	_check("box pushup/grabbed", control.grabbed_body == box)
	_check("box pushup/body climbs", player.com_world().y < initial_y - 30.0,
		"rise=%.3f" % (initial_y - player.com_world().y))
	_check("box pushup/reach", maximum_reach <= control.max_reach)
	_check("box pushup/power", maximum_power <= control.max_power * 1.00001)
	_check("box pushup/force", maximum_force <= control.max_force * 1.00001)
	_check("box pushup/late jitter", (late_max - late_min).length() < 0.25)
	var gained_energy: float = player.mass * 980.0 * (initial_y - player.com_world().y) + _kinetic_energy([player, hand, box])
	_check("box pushup/work covered by budget", gained_energy <= supplied_energy * 1.001)
	control._release_grab()
	rig["world"].gravity = Vector2.ZERO


func _test_free_box_reaction(rig: Dictionary) -> void:
	var control: Node = rig["control"]
	var player = rig["player"]
	var hand = rig["hand"]
	var box = rig["box"]
	_set_body_state(box, hand.com_world())
	control._begin_grab(box, hand.com_world())
	control.set_grip(true)
	control.set_target_world(hand.com_world() + Vector2(0, 80))
	# 无地面接触、无重力：向下推物体必须同时向上推身体。
	control._physics_process(DT)
	rig["world"].step(DT)
	_check("free box/equal opposite reaction", player.linear_velocity.y < 0.0 and box.linear_velocity.y > 0.0)
	var momentum_error := _linear_momentum([player, hand, box, rig["arm"]]).length()
	var impulse_scale: float = control.debug_linear_effort * DT
	_check("free box/momentum", momentum_error / maxf(impulse_scale, 1.0) < 0.00001,
		"error=%.6f relative=%.8f" % [momentum_error, momentum_error / maxf(impulse_scale, 1.0)])
	_check("free box/energy", _kinetic_energy([player, hand, box]) <= control.debug_active_power * DT * 1.001)
	control._release_grab()


func _linear_momentum(bodies: Array) -> Vector2:
	var result := Vector2.ZERO
	for body in bodies:
		result += body.linear_momentum()
	return result


func _angular_momentum(bodies: Array) -> float:
	var result := 0.0
	for body in bodies:
		result += body.angular_momentum_about(Vector2.ZERO)
	return result


func _kinetic_energy(bodies: Array) -> float:
	var result := 0.0
	for body in bodies:
		result += body.kinetic_energy()
	return result


func _check(label: String, condition: bool, detail := "") -> void:
	if condition:
		_passed += 1
		print("  PASS ", label, " ", detail)
	else:
		_failed += 1
		push_error("FAIL %s %s" % [label, detail])
