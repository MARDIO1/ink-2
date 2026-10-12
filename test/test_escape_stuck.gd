extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, ok: bool) -> void:
	print("[EscapeStuck] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _move(body, center: Vector2) -> void:
	body.position = center - body.local_com.rotated(body.rotation)
	body.refresh_com()
	body.update_aabb()

func _run() -> void:
	var app: Node = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	root.get_node("SceneTransition").duration = 0.01
	await app.request_level_change("res://map/asset/imported/第一关.tscn")
	await process_frame
	var level: Node = app.level_root.get_child(0)
	var recovery: Node = level.get_node("Player/FallDeath")
	var body = level.get_node("Player").body
	var hand: Node = level.get_node("Player/Arm/Hand/HandControl")
	var points: Array[Marker2D] = []
	for i in 3:
		var point := Marker2D.new()
		point.name = "RespawnPointTest%d" % i
		level.add_child(point)
		point.position = Vector2(1000 + i * 1000, -1000)
		points.append(point)
	recovery._checkpoints_initialized = false
	recovery._body = body
	_move(body, points[0].global_position)
	recovery._update_visited_points()
	_move(body, points[1].global_position)
	recovery._update_visited_points()
	_move(body, Vector2(2850, -1000))
	_check("nearest visited selected, not nearer unvisited", recovery._nearest_visited_point() == points[1])
	var esc: Node = get_first_node_in_group(&"esc_menu")
	esc.open_menu()
	_check("menu recovery button enabled", not esc.get_node("Center/Panel/Buttons/EscapeStuckButton").disabled and paused)
	body.linear_velocity = Vector2(100, 100)
	body.angular_velocity = 3.0
	hand.set_grip(true)
	hand.set_target_world(Vector2(5000, 5000))
	hand.set_enabled(false)
	level.get_node("Player/PlayerInput").support = body
	esc.get_node("Center/Panel/Buttons/EscapeStuckButton").pressed.emit()
	_check("button teleports and resumes", not paused and not esc.visible and body.position.is_equal_approx(points[1].global_position))
	_check("clears motion and support", body.linear_velocity == Vector2.ZERO and body.angular_velocity == 0.0 and level.get_node("Player/PlayerInput").support == null)
	_check("hand reset clears overrides and grip", hand.enabled and hand.grabbed_body == null and hand._grip_override == null and hand._target_override == null)
	points[1].free()
	_move(body, Vector2(2850, -1000))
	_check("deleted checkpoint safely skipped", recovery._nearest_visited_point() == points[0])
	var previous_point_id := points[0].get_instance_id()
	await app.request_level_change("res://map/asset/imported/扉页（教程关）.tscn")
	await process_frame
	var next: Node = app.level_root.get_child(0).get_node("Player/FallDeath")
	var leaked_visit := false
	for point in next._visited_points:
		leaked_visit = leaked_visit or point.get_instance_id() == previous_point_id
	_check("visits do not leak to next map", not leaked_visit)
	_check("spawn fallback works", next.escape_stuck())
	var creative: Node = app.level_root.get_child(0).get_node("Creative")
	creative.active = true
	esc = get_first_node_in_group(&"esc_menu")
	esc.open_menu()
	_check("editor disables recovery", esc.get_node("Center/Panel/Buttons/EscapeStuckButton").disabled and not next.escape_stuck())
	creative.active = false
	esc._on_continue_button_pressed()
	app.queue_free()
	await process_frame
	quit(1 if failures else 0)
