extends SceneTree

var app: Node
var level: Node
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, value: bool) -> void:
	checks += 1
	if not value:
		failures += 1
	print("[Workshop] %s %s" % ["PASS" if value else "FAIL", label])

func _frames(count: int) -> void:
	for frame in count:
		await physics_frame
		await process_frame

func _run() -> void:
	app = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	root.get_node("SceneTransition").duration = 0.02
	var loaded: bool = await app.request_level_change("res://map/asset/imported/第一关.tscn")
	_check("loads through real router", loaded)
	level = app.get_node("Level").get_child(0)
	level.get_node("Creative").auto_save_on_exit = false
	level.get_node("Creative").auto_save_edits = false
	for monster in level.get_node("Monsters").get_children():
		monster.attacks_enabled = false
	await _frames(30)
	var player: Node = level.get_node("Player")
	_check("spawn above safe start ground", player.body.com_world().x < 400 and player.body.com_world().y < 800)
	_check("camera follows live player", level.get_node("Camera2D").global_position.distance_to(player.body.com_world()) < 1)
	_check("four enemies with appropriate scale", level.get_node("Monsters").get_child_count() == 4 and level.get_node("Monsters/ValleyShield").scale.x < 0.5)
	var solids := 0
	for child in level.get_children():
		if child.has_meta("workshop_generated"):
			solids += 1
			_check("solid rendered pixels " + str(child.name), child.body != null and child.body.collision_layer != 0 and not child.body.shapes.is_empty())
	_check("segmented destructible architecture and terrain", solids > 30)
	var gate_a: Node = level.get_node("CounterweightGate")
	var gate_b: Node = level.get_node("LeverGate")
	_check("both gates initialize native joints", gate_a._initialized and gate_b._initialized and gate_b._hinge != null)
	var door_a: Node = level.get_node("GateA_Door")
	var door_b: Node = level.get_node("GateB_Door")
	var y_a: float = door_a.body.position.y
	var y_b: float = door_b.body.position.y
	_check("gates start closed", not gate_a.opened and not gate_b.opened)
	if OS.get_cmdline_user_args().has("--preview"):
		await _preview()
	# 让门处在模拟活动范围，验证同一套真实销毁/原生关节，而不是手动改门坐标。
	_teleport(Vector2(1530, 510))
	var support: Node = level.get_node("GateA_BreakableSupport")
	level.remove_body_node(support)
	support.queue_free()
	await _frames(180)
	print("[Workshop] gate A y ", y_a, " -> ", door_a.body.position.y, " opened=", gate_a.opened, " target=", gate_a._lift, " frozen=", door_a.body.frozen, " velocity=", door_a.body.linear_velocity, " camera=", level.get_node("Camera2D").position)
	_check("breaking support opens real collidable gate", gate_a.opened and door_a.body.position.y < y_a - 135)
	_teleport(Vector2(4080, 480))
	var weight: Node = level.get_node("Lever_SampleWeight")
	weight.body.position = Vector2(3750, 475)
	weight.body.linear_velocity = Vector2.ZERO
	weight.body.awake = true
	weight.body.refresh_com()
	weight.body.update_aabb()
	await _frames(200)
	print("[Workshop] gate B y ", y_b, " -> ", door_b.body.position.y, " lever=", level.get_node("Lever_Beam").body.rotation, " load=", gate_b.load_mass())
	_check("load on lever opens second physical gate", gate_b.opened and door_b.body.position.y < y_b - 135)
	_check("drawing zones cover each puzzle", level.get_node("BridgeCanvas").canvas_size.x >= 640 and level.get_node("GateBCanvas").canvas_size.x >= 720)
	_check("exit points to existing next level", ResourceLoader.exists(level.get_node("WorkshopExit").target_map))
	app.queue_free()
	await process_frame
	print("[Workshop] %d checks; %d failures" % [checks, failures])
	quit(1 if failures else 0)

func _teleport(position_: Vector2) -> void:
	var player: Node = level.get_node("Player")
	player.position = position_
	player.body.position = position_
	player.body.linear_velocity = Vector2.ZERO
	player.body.refresh_com()
	player.body.update_aabb()
	player.get_node("Arm/Hand/HandControl").reset_after_player_teleport()

func _preview() -> void:
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1280, 720)
	var camera: Camera2D = level.get_node("Camera2D")
	camera.set_physics_process(false)
	level.auto_step = false
	app.get_node("UI").hide()
	for layer in root.find_children("*", "CanvasLayer", true, false):
		if layer.name != "PaperBackground":
			layer.hide()
	var output := "res://map/asset/workshop/"
	for shot in [["smithy", Vector2(1740, 430), Vector2(1730, 503)], ["valley", Vector2(2790, 630), Vector2(2680, 693)], ["lever-house", Vector2(4160, 400), Vector2(4110, 473)], ["start", Vector2(550, 600), Vector2(460, 633)], ["summit", Vector2(5550, 260), Vector2(5670, 263)]]:
		_teleport(shot[2])
		level.get_node("SimulationRuntime/PhysicsStep").sync_render()
		camera.global_position = shot[1]
		camera.zoom = Vector2.ONE * 1.4
		camera.reset_smoothing()
		camera.force_update_scroll()
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(output + "preview-" + shot[0] + ".png")
	camera.set_physics_process(true)
	level.auto_step = true
	app.get_node("UI").show()
