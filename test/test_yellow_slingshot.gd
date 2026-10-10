extends SceneTree
var failures: int = 0
func _initialize() -> void:
	call_deferred("run")
func check(title: String, passed: bool) -> void:
	print("PASS " if passed else "FAIL ", title)
	if not passed:
		failures += 1
func run() -> void:
	var demo = preload("res://map/yellow_slingshot.tscn").instantiate()
	root.add_child(demo)
	while not demo.ready_for_test:
		await process_frame
	demo.level.auto_step = false
	var initial: int = demo.remaining()
	var runtime = demo.level.get_node("SimulationRuntime")
	for tick in 800:
		demo.advance(1.0 / 60.0)
		demo.level.get_node("Player/PlayerInput").apply_input(0.0, false, 1.0 / 60.0)
		demo.level.get_node("Player/Arm/Hand/HandControl")._physics_process(1.0 / 60.0)
		var result: Dictionary = runtime._step(1.0 / 60.0)
		if not result.removals.is_empty():
			var nodes: Array = demo.level._body_nodes.duplicate()
			runtime.commit(demo.level.world, result.removals, result.get("bursts", {}), true)
			runtime._physics.sync_after_commit(nodes)
		runtime._physics.sync_render()
		for stroke in demo.springs:
			if stroke.state == stroke.State.ACTIVE:
				stroke.update_visual()
	# 软弹簧允许较大悬挂行程；不能沿用高劲度版的 15px/500px/s 验收线。
	check("very soft 7px suspension still supports real player", demo.suspension_sag < 130.0)
	check("same sling fires twice", demo.shots.size() == 2)
	for index in demo.shots.size():
		check("shot %d remains reusable after softer tuning" % (index + 1), demo.shots[index].speed > 180.0 and demo.shots[index].rise > 100.0)
	check("normal suspension and two draws do not wear yellow", demo.remaining() == initial)
	for stroke in demo.springs:
		check("spring survives both launches", stroke.state == stroke.State.ACTIVE and stroke.joint != null)
	print("SUSPENSION mass=", demo.player.mass, " sag=", demo.suspension_sag, " remaining=", demo.remaining(), "/", initial)
	# 保留疲劳破坏：极端拉长依然会磨损，不把黄墨改成无敌约束。
	demo.platform.position.y += 500.0
	demo.platform.linear_velocity = Vector2.ZERO
	for tick in 120:
		demo.rule.resolve_fixed({"world": demo.level.world, "player_body": demo.player})
	check("severe overstretch still erodes yellow", demo.remaining() < initial)
	demo.queue_free()
	await process_frame
	quit(1 if failures else 0)
