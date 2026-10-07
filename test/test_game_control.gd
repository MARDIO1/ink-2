extends "res://test/test_collision_damage.gd"
const DT: float = 1.0 / 60.0

func _run() -> void:
	var scene = MAIN.instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	var hand = scene.get_node("Player/Arm/Hand/HandControl")
	var feet = scene.get_node("Player/PlayerInput")
	var damage = scene.get_node("CollisionDamage")
	hand.set_physics_process(false)
	feet.set_physics_process(false)
	damage.set_physics_process(false)
	hand._remove_arm()
	var body = scene.get_node("Player").body
	var box = scene.get_node("Box").body
	var ground = scene.get_node("Ground").body
	ground.position = Vector2(10000, 10000)
	ground.update_aabb()
	scene.world.gravity = Vector2.ZERO
	body.position = Vector2.ZERO
	body.rotation = 0.0
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.refresh_com()
	body.update_aabb()
	box.position = Vector2(0, 32)
	box.linear_velocity = Vector2.ZERO
	box.angular_velocity = 0.0
	box.refresh_com()
	box.update_aabb()
	for i in 3:
		damage._step(DT)
	_check("actual partial foot contact acquired", feet.support == box)
	var momentum: Vector2 = scene.world.total_momentum()
	var angular: float = scene.world.total_angular_momentum()
	var energy: float = scene.world.total_kinetic_energy()
	feet.apply_input(1.0, false, DT)
	_check("walking pushes body and support oppositely", body.linear_velocity.x > 0.0 and box.linear_velocity.x < 0.0)
	_check("walking conserves linear momentum", scene.world.total_momentum().distance_to(momentum) < 0.1)
	_check("walking conserves angular momentum", absf(scene.world.total_angular_momentum() - angular) < 1.0)
	_check("walking permits contact torque", absf(body.angular_velocity) > 0.0)
	_check("walking respects force and power", feet.debug_force <= feet.max_force * (1.0 + 1e-6) and feet.debug_active_power <= feet.max_power * (1.0 + 1e-6))
	_check("walking energy matches reported actuator work", absf(scene.world.total_kinetic_energy() - energy - feet.debug_active_power * DT) < 1.0)
	var velocity: Vector2 = body.linear_velocity
	feet.apply_input(0.0, false, DT)
	_check("released AD has no active brake", body.linear_velocity == velocity and feet.debug_force == 0.0)
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	box.linear_velocity = Vector2.ZERO
	box.angular_velocity = 0.0
	momentum = scene.world.total_momentum()
	angular = scene.world.total_angular_momentum()
	feet.apply_input(0.0, true, DT)
	_check("jump pushes support down", body.linear_velocity.y < 0.0 and box.linear_velocity.y > 0.0)
	_check("jump conserves linear and angular momentum", scene.world.total_momentum().distance_to(momentum) < 0.1 and absf(scene.world.total_angular_momentum() - angular) < 1.0)
	_check("jump respects independent foot power budget", feet.debug_active_power <= feet.max_power + 0.1)
	velocity = body.linear_velocity
	feet.apply_input(1.0, true, DT)
	_check("air AD and jump have no effect", body.linear_velocity == velocity and feet.debug_force == 0.0)
	body.position = Vector2(0, -100)
	body.refresh_com()
	body.update_aabb()
	damage._step(DT)
	_check("real separation clears support", feet.support == null)
	# 记录引擎重复渲染，再验证游戏的最小排除规则。
	scene.sync_world_bodies()
	_check("engine sync excludes hand with its own visual", not scene.renderer._nodes.has(hand.body.id))
	scene.auto_step = true
	damage._physics_process(DT)
	_check("game removes internal hand and arm renderers", not scene.renderer._nodes.has(hand.body.id) and not scene.renderer._nodes.has(hand.arm_body.id))
	await process_frame
	var hud = scene.get_node("debugHUD")
	# UI 已抽到 `ui/game_ui.tscn`（真实游戏里由 `root/root.tscn` 挂在 `UI` 容器下）；
	# 本测试只实例化关卡，所以这里补挂一份，并走它的 Hud 子节点。
	var game_ui: Node = preload("res://ui/game_ui.tscn").instantiate()
	scene.add_child(game_ui)
	await process_frame
	var ui: Node = game_ui.get_node("Hud")
	_check("debug HUD is a screen-space layer", hud is CanvasLayer and not hud.follow_viewport_enabled)
	_check("game HUD owns the screen until Tab", ui.visible and not hud.visible)
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = KEY_TAB
	event.keycode = KEY_TAB
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	_check("Tab swaps game HUD for debug HUD", hud.visible and hud.forces.enabled and not ui.visible)
	# 99 个10ms帧与1个100ms帧：最慢1%的均值为100ms，1% low 必须为10FPS。
	hud.previous_tick = 0
	hud.frame_times.resize(100)
	hud.frame_times.fill(0.01)
	hud.frame_times[99] = 0.1
	hud.first = 0
	hud.history_time = 1.09
	hud.elapsed = 0.5
	hud._process(0.0)
	var label: Label = scene.get_node("debugHUD/Stats")
	print("HUD rect=%s viewport=%s text=%s" % [label.get_global_rect(), root.get_visible_rect(), label.text])
	_check("HUD text lies inside viewport", not label.text.is_empty() and root.get_visible_rect().encloses(label.get_global_rect()))
	_check("1 percent low uses slowest frame time mean", label.text.contains("1% low 10 |"))
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	_check("Tab restores the game HUD", not hud.visible and not hud.forces.enabled and ui.visible)
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	_check("ordinary material hardness doubled", scene.world.material_strength(1).x == 200.0)
	_test_camera_freeze(scene, damage)
	scene.auto_step = false
	_release(scene.world)
	scene.queue_free()
	await process_frame
	print("[GameControl] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _test_camera_freeze(scene, damage) -> void:
	var camera: Camera2D = scene.get_node("Camera2D")
	camera.set_physics_process(false)
	camera.global_position = Vector2.ZERO
	camera.reset_physics_interpolation()
	camera.reset_smoothing()
	camera.force_update_scroll()
	var center: Vector2 = camera.get_screen_center_position()
	var extent: Vector2 = camera.get_viewport_rect().size / camera.zoom * 2.0
	var far = _body(scene.world, center + Vector2(extent.x + 100.0, 0), Vector2i(8, 8))
	far.linear_velocity = Vector2(100, 0)
	var edge = _body(scene.world, center + Vector2(extent.x - 4.0, 30), Vector2i(8, 8))
	var held = _body(scene.world, center + Vector2(extent.x + 200.0, 60), Vector2i(8, 8))
	var player = scene.get_node("Player").body
	var joint = scene.world.add_hinge(player, held, held.com_world())
	var position: Vector2 = far.position
	damage._step(DT)
	_check("outside fourfold camera freezes without moving", far.frozen and far.position == position)
	_check("freeze retains velocity", far.linear_velocity == Vector2(100, 0))
	_check("partly overlapping camera range remains active", not edge.frozen)
	_check("player joint component never freezes", not player.frozen and not held.frozen)
	scene.world.remove_joint(joint)
	damage._step(DT)
	_check("released distant object freezes", held.frozen)
	camera.global_position = far.com_world()
	camera.reset_physics_interpolation()
	camera.reset_smoothing()
	camera.force_update_scroll()
	damage._step(DT)
	print("FREEZE_RETURN frozen=%s position=%s velocity=%s camera=%s original=%s" % [far.frozen, far.position, far.linear_velocity, camera.get_screen_center_position(), position])
	_check("returning camera restores motion", not far.frozen and far.position.x > position.x)
	camera.global_position = center
	camera.reset_physics_interpolation()
	camera.reset_smoothing()
	camera.zoom *= 2.0
	camera.force_update_scroll()
	damage._step(DT)
	_check("zoom updates freeze boundary", edge.frozen)
