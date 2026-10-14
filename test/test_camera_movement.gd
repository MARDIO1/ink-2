extends SceneTree

var failures := 0

func _check(label: String, condition: bool) -> void:
	if not condition:
		failures += 1
	print("[Movement] %s %s" % ["PASS" if condition else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

func _wait_frames(count: int) -> void:
	for frame in count:
		await physics_frame
		await process_frame

func _run() -> void:
	var app: Node = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	root.get_node("SceneTransition").duration = 0.02
	await app.request_level_change("res://map/asset/imported/扉页.tscn")
	await _wait_frames(20)
	var level: Node = app.get_node("Level").get_child(0)
	var player: Node = level.get_node("Player")
	var camera: Camera2D = level.get_node("Camera2D")
	var initial: Vector2 = player.body.com_world()
	Input.action_press("move_right")
	await _wait_frames(40)
	Input.action_release("move_right")
	print("[Movement] play paused=", paused, " auto_step=", level.auto_step, " player=", initial, " -> ", player.body.com_world(), " camera=", camera.global_position, " support=", player.get_node("PlayerInput").support != null)
	_check("play movement and camera follow", not paused and player.body.com_world().x - initial.x > 20.0 and camera.global_position.distance_to(player.body.com_world()) < 1.0)
	var creative: Node = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	await creative.toggle()
	while root.get_node("SceneTransition").busy:
		await process_frame
	await _wait_frames(5)
	level = app.get_node("Level").get_child(0)
	player = level.get_node("Player")
	camera = level.get_node("Camera2D")
	creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	initial = player.body.com_world()
	Input.action_press("fly_right")
	await _wait_frames(30)
	Input.action_release("fly_right")
	print("[Movement] editor active=", creative.active, " paused=", paused, " auto_step=", level.auto_step, " player=", initial, " -> ", player.body.com_world(), " camera=", camera.global_position)
	_check("editor movement and camera follow after reload", creative.active and not paused and player.body.com_world().x - initial.x > 20.0 and camera.global_position.distance_to(player.body.com_world()) < 1.0)
	await creative.toggle()
	await _wait_frames(3)
	_check("return to play keeps camera following", not creative.active and not paused and camera.global_position.distance_to(player.body.com_world()) < 1.0)
	app.queue_free()
	await process_frame
	quit(1 if failures > 0 else 0)
