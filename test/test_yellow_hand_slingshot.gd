extends SceneTree
var failures: int = 0
var checks: int = 0
var level
var demo
var runtime
func _initialize() -> void:
	call_deferred("run")
func check(title: String, passed: bool) -> void:
	checks += 1
	print("PASS " if passed else "FAIL ", title)
	if not passed:
		failures += 1
func tick() -> void:
	demo.hand._physics_process(1.0 / 60.0)
	demo.assist_grab()
	level.get_node("Player/PlayerInput").apply_input(0.0, false, 1.0 / 60.0)
	var result: Dictionary = runtime._step(1.0 / 60.0)
	if not result.removals.is_empty():
		var nodes: Array = level._body_nodes.duplicate()
		runtime.commit(level.world, result.removals, result.get("bursts", {}), true)
		runtime._physics.sync_after_commit(nodes)
	runtime._physics.sync_render()
	demo.observe()
func run() -> void:
	check("hand sling is available in the level selector", preload("res://ui/level_select/src/level_select.gd").find_levels().has("res://map/yellow_hand_slingshot.tscn"))
	for shot in 2:
		await trial(shot)
	print("[HandSlingshot] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

func trial(shot: int) -> void:
	level = preload("res://map/yellow_hand_slingshot.tscn").instantiate()
	root.add_child(level)
	demo = level.get_node("SlingSetup")
	while not demo.ready_for_test:
		await process_frame
	level.auto_step = false
	runtime = level.get_node("SimulationRuntime")
	demo.hand.set_grip(false)
	demo.hand.set_target_world(demo.hand.body.com_world())
	for i in 30:
		tick()
	# 用相同鼠标目标接口靠近，再用原有抓点查询建立握持。
	var approach: Vector2 = demo.cup.to_world(Vector2(1, 18)) - demo.hand.FINGERTIP
	demo.hand.set_target_world(approach)
	for i in 180:
		demo.hand.set_target_world(demo.cup.to_world(Vector2(0, 18)) - demo.hand.FINGERTIP.rotated(demo.hand.body.rotation))
		tick()
	demo.hand.set_grip(true)
	for i in 60:
		demo.hand.set_target_world(demo.cup.to_world(Vector2(0, 18)) - demo.hand.FINGERTIP.rotated(demo.hand.body.rotation))
		tick()
	check("fingertip query grips black pouch with the normal weld", demo.hand.grabbed_body == demo.cup)
	demo.hand.set_target_world(approach - Vector2(110, 0))
	for i in 180:
		tick()
	check("player hand physically stretches pouch >25px", demo.max_draw > 25.0)
	print("DRAW cup=", demo.cup.position, " player=", level.get_node("Player").body.position, " hand=", demo.hand.body.com_world(), " projectile=", demo.projectile.position, " draw=", demo.max_draw)
	if shot == 0 and "--render" in OS.get_cmdline_user_args():
		await capture("yellow-hand-draw.png")
	demo.hand.set_grip(false)
	for i in 180:
		tick()
		if shot == 0 and i == 20 and "--render" in OS.get_cmdline_user_args():
			await capture("yellow-hand-shot.png")
	check("release launches an independent projectile", demo.launch_speed > 150.0 and demo.flight_distance > 100.0)
	check("projectile has no yellow constraint", level.world.joints.all(func(j): return j.body_a != demo.projectile and j.body_b != demo.projectile))
	for stroke in demo.springs:
		check("soft yellow survives the hand draw", stroke.state == stroke.State.ACTIVE and stroke.worn.is_empty())
	print("HAND_SLING speed=", demo.launch_speed, " distance=", demo.flight_distance, " shots=", demo.shots)
	level.queue_free()
	await process_frame

func capture(filename: String) -> void:
	for stroke in demo.springs:
		stroke.update_visual()
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join(filename))
