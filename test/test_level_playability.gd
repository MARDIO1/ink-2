extends SceneTree
## 以真实按键事件运行单张关卡；每个关卡用独立进程，避免上一张图刚体的释放时序干扰。


func _initialize() -> void:
	_run.call_deferred()


func _key(code: int, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)


func _run() -> void:
	var level_path := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--level="):
			level_path = argument.trim_prefix("--level=")
	if level_path.is_empty():
		printerr("usage: -- --level=res://map/...tscn")
		quit(2)
		return
	var packed := load(level_path) as PackedScene
	if packed == null:
		printerr("cannot load level: ", level_path)
		quit(2)
		return
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	current_scene = app
	await process_frame
	app._transition.duration = 0.01
	var level = await app.load_level(packed, false)
	var feet: Node = level.get_node("Player/PlayerInput")
	var hand: Node = level.get_node("Player/Arm/Hand/HandControl")
	for frame in 60:
		await physics_frame
	hand.set_grip(false)
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
	for frame in 90:
		await physics_frame
	_key(KEY_SPACE, true)
	await physics_frame
	await physics_frame
	_key(KEY_SPACE, false)
	var jump_force: float = feet.debug_force
	var jump_ok: bool = jump_force > 0.0 and feet.player.body.linear_velocity.y < -50.0
	print("[LevelPlayability] walk=", walked, " active=", active,
		" support=", feet.support != null, " jump_force=", jump_force,
		" jump_velocity=", feet.player.body.linear_velocity)
	print("[LevelPlayability] ", "PASS" if walk_ok and jump_ok else "FAIL", " ", level_path)
	quit(0 if walk_ok and jump_ok else 1)
