extends SceneTree

var failures := 0
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const PixelShape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")

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
		var bottom := 0.0
		for rect in body.rects:
			bottom = maxf(bottom, rect.end.y)
		var floor_body := PBody.new()
		floor_body.position = point.position + Vector2(-160, ceilf(bottom) + 2)
		var floor_shape := PixelShape.new()
		floor_shape.fill_rect(Rect2i(0, 0, 320, 12), 1)
		level.world.add_body(floor_body, [floor_shape], Callable(level, "_density_of"), true)
	recovery._checkpoints_initialized = false
	recovery._body = body
	_move(body, points[0].global_position)
	recovery._update_visited_points()
	_move(body, points[1].global_position)
	recovery._update_visited_points()
	_move(body, Vector2(2850, -1000))
	_check("only passed checkpoints visited", recovery._visited_points.has(points[0]) and recovery._visited_points.has(points[1]) and not recovery._visited_points.has(points[2]))
	var esc: Node = get_first_node_in_group(&"esc_menu")
	esc.open_menu()
	_check("menu recovery button enabled", not esc.get_node("Center/Panel/Buttons/EscapeStuckButton").disabled and paused)
	body.linear_velocity = Vector2(100, 100)
	body.angular_velocity = 3.0
	hand.set_grip(true)
	hand.set_target_world(Vector2(5000, 5000))
	hand.set_enabled(false)
	level.get_node("Player/PlayerInput").support = body
	await esc._on_escape_stuck_button_pressed()
	_check("button teleports and resumes", not paused and not esc.visible and body.position.is_equal_approx(points[1].global_position))
	_check("clears motion and support", body.linear_velocity == Vector2.ZERO and body.angular_velocity == 0.0 and level.get_node("Player/PlayerInput").support == null)
	_check("hand reset clears overrides and grip", hand.enabled and hand.grabbed_body == null and hand._grip_override == null and hand._target_override == null)
	points[1].free()
	_move(body, Vector2(2850, -1000))
	esc.open_menu()
	var restored: bool = await esc._on_escape_stuck_button_pressed()
	_check("deleted checkpoint safely skipped", restored and body.position.is_equal_approx(points[0].global_position))
	var previous_point_id := points[0].get_instance_id()
	# 使用带固定支撑的基础关卡，避免编辑中的教程地图影响出生点回退验证。
	await app.request_level_change("res://map/main.tscn")
	await process_frame
	var next: Node = app.level_root.get_child(0).get_node("Player/FallDeath")
	var leaked_visit := false
	for point in next._visited_points:
		leaked_visit = leaked_visit or point.get_instance_id() == previous_point_id
	_check("visits do not leak to next map", not leaked_visit)
	_check("spawn fallback works", await next.escape_stuck())
	var creative: Node = app.level_root.get_child(0).get_node("Creative")
	creative.active = true
	esc = get_first_node_in_group(&"esc_menu")
	esc.open_menu()
	_check("editor disables recovery", esc.get_node("Center/Panel/Buttons/EscapeStuckButton").disabled and not await next.escape_stuck())
	creative.active = false
	esc._on_continue_button_pressed()
	paused = true
	var next_level := app.level_root.get_child(0) as Node2D
	var next_player: Node2D = next_level.get_node("Player")
	next_level.position = Vector2(300, 160)
	next_level.rotation = 0.2
	var local_target := Vector2(-128, 90)
	next_player.teleport_to(next_level.to_global(local_target), next_level.global_rotation + 0.3)
	_check("shared teleport converts world pose to level coordinates", next_player.body.position.is_equal_approx(local_target) and is_equal_approx(next_player.body.rotation, 0.3))
	paused = false
	app.queue_free()
	await process_frame
	quit(1 if failures else 0)
