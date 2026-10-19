extends SceneTree
const ContentPaths := preload("res://map/src/content_paths.gd")
## 以真实按键事件运行单张关卡；每个关卡用独立进程，避免上一张图刚体的释放时序干扰。


func _initialize() -> void:
	_run.call_deferred()


func _key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)


func _jump_probe(feet: Node) -> Dictionary:
	_key(KEY_SPACE, true)
	await physics_frame
	await physics_frame
	var force: float = feet.debug_force
	var velocity: Vector2 = feet.player.body.linear_velocity
	_key(KEY_SPACE, false)
	return {"force": force, "velocity": velocity,
		"ok": force > 0.0 and velocity.y < -50.0}


func _run() -> void:
	var level_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--level="):
			level_path = argument.trim_prefix("--level=")
	if level_path.is_empty():
		printerr("usage: -- --level=res://map/...tscn")
		quit(2)
		return
	var resolved_path := ContentPaths.resolve(level_path)
	var packed := load(resolved_path) as PackedScene
	if packed == null:
		printerr("cannot load level: ", resolved_path)
		quit(2)
		return
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	current_scene = app
	await process_frame
	app._transition.duration = 0.01
	var level = await app.load_level(packed, false, resolved_path)
	if level == null:
		printerr("level validation failed: ", resolved_path)
		quit(2)
		return
	var feet: Node = level.get_node("Player/PlayerInput")
	var hand: Node = level.get_node("Player/Arm/Hand/HandControl")
	var inspect_static := OS.get_cmdline_user_args().has("--inspect")
	if inspect_static:
		var runtime: Node = level.get_node("SimulationRuntime")
		print("INITIAL root=", level.get_node("Player").position,
			" com=", feet.player.body.com_world(), " frozen=", feet.player.body.frozen,
			" awake=", feet.player.body.awake,
			" input_process=", feet.is_physics_processing(),
			" runtime_process=", level.get_node("SimulationRuntime").is_physics_processing(),
			" bodies=", level.world.bodies.size(), " support=", feet.support != null,
			" auto_step=", level.auto_step, " paused=", paused,
			" tags=", feet.player.body.tags,
			" layer=", feet.player.body.collision_layer,
			" mask=", feet.player.body.collision_mask,
			" gravity=", level.world.gravity,
			" runtime_main_ok=", runtime.get("_main") == level,
			" runtime_player_ok=", runtime.get("_player") == level.get_node("Player"),
			" physics_process=", level.get_node("SimulationRuntime/PhysicsStep").is_physics_processing(),
			" runtime_in_tree=", runtime.is_inside_tree(), " level_in_tree=", level.is_inside_tree(),
			" runtime_can_process=", runtime.can_process(),
			" process_mode=", runtime.process_mode,
			" runtime_script=", runtime.get_script().resource_path if runtime.get_script() != null else "",
			" has_physics=", runtime.has_method("_physics_process"),
			" player_in_world=", level.world.bodies.has(feet.player.body),
			" runtime_body_same=", runtime.get("_player").get("body") == feet.player.body,
			" rapier_id=", feet.player.body.rapier_id,
			" native_world=", level.world._rp != null,
			" physics_frames=", Engine.get_physics_frames())
	for frame in 60:
		await physics_frame
		if inspect_static and (frame + 1) % 30 == 0:
			print("FRAME ", frame + 1, " com=", feet.player.body.com_world(),
				" velocity=", feet.player.body.linear_velocity,
				" support=", feet.support != null,
				" force=", feet.debug_force,
				" awake=", feet.player.body.awake,
				" frozen=", feet.player.body.frozen,
				" gravity_scale=", feet.player.body.gravity_scale,
				" mass=", feet.player.body.mass,
				" rapier_id=", feet.player.body.rapier_id,
				" native_world=", level.world._rp != null,
				" elapsed=", level.get_node("SimulationRuntime").get("_elapsed"),
				" fixed_dt=", level.fixed_dt,
				" max_substeps=", level.max_substeps,
				" physics_frames=", Engine.get_physics_frames())
	hand.set_grip(false)
	var jump: Dictionary = await _jump_probe(feet)
	for frame in 90:
		await physics_frame
	var start: Vector2 = feet.player.body.com_world()
	_key(KEY_D, true)
	var active := 0
	for frame in 120:
		await physics_frame
		if feet.debug_force > 0.0:
			active += 1
	_key(KEY_D, false)
	var walked: Vector2 = feet.player.body.com_world() - start
	var walk_ok: bool = absf(walked.x) > 20.0 and active > 0
	if not walk_ok or inspect_static:
		for body in level.world.bodies:
			if body.is_static and body.aabb.position.x <= start.x + 260.0 \
			and body.aabb.end.x >= start.x - 260.0:
				print("STATIC ", body.aabb, " layer=", body.collision_layer,
					" mask=", body.collision_mask,
					" original_layer=", body.tags.get("background_original_layer", -1),
					" original_mask=", body.tags.get("background_original_mask", -1))
	if not bool(jump.ok) and feet.support != null:
		jump = await _jump_probe(feet)
	print("[LevelPlayability] walk=", walked, " active=", active,
		" support=", feet.support != null, " jump_force=", jump.force,
		" jump_velocity=", jump.velocity, " jump_impulse=", feet.jump_impulse)
	# 跳跃时序受出生点是否正在落到单向平台影响；逐图门槛只要求确实能受控移动。
	# 跳跃输入本身由 test_live_input.gd 在稳定地面单独验收。
	var passed: bool = walk_ok
	print("[LevelPlayability] ", "PASS" if passed else "FAIL", " ", level_path)
	quit(0 if passed else 1)
