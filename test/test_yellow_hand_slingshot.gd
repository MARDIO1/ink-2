extends SceneTree
const Stroke = preload("res://actor/yellow/src/yellow_stroke.gd")
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
	check("round projectile starts in zero-gap contact with curved pouch", absf(demo.PROJECTILE_LEFT_X - demo.CUP_INNER_RIGHT_X) < 0.01)
	for i in 30:
		tick()
	var cup_joints: Array = level.world.joints.filter(func(j): return j.body_a == demo.cup or j.body_b == demo.cup)
	check("pouch only uses the two yellow spring constraints", cup_joints.size() == 2 and cup_joints.all(func(j): return j.kind == j.SPRING))
	# 这是物理执行器的合成目标上限测试，不冒充真人鼠标验收。
	var approach: Vector2 = demo.cup.to_world(demo.cup.local_com) - demo.hand.FINGERTIP
	for i in 180:
		demo.hand.set_target_world(demo.cup.to_world(demo.cup.local_com) - demo.hand.FINGERTIP.rotated(demo.hand.body.rotation))
		tick()
	demo.hand.set_grip(true)
	for i in 60:
		demo.hand.set_target_world(demo.cup.to_world(demo.cup.local_com) - demo.hand.FINGERTIP.rotated(demo.hand.body.rotation))
		tick()
	check("synthetic hand target grips black pouch with player grab", demo.hand.grabbed_body == demo.cup)
	demo.hand.set_target_world(approach - Vector2(260, 0))
	var draw_frame: int = -1
	for i in 240:
		tick()
		if draw_frame < 0 and demo.max_draw > 60.0:
			draw_frame = i + 1
	check("synthetic hand target physically stretches pouch >60px", demo.max_draw > 60.0)
	check("hand reaches 60px draw within 1.5 seconds", draw_frame > 0 and draw_frame <= 90)
	print("DRAW_RESPONSE frames_to_60=", draw_frame)
	check("player mass uses exported 4x density scale", level.get_node("Player").body.mass > 10000.0)
	check("spring damping is exactly zero", demo.springs.all(func(stroke): return stroke.joint.damping == 0.0))
	for stroke in demo.springs:
		stroke.update_visual()
		var source_normal: Vector2 = (stroke.path[-1] - stroke.path[0]).normalized().orthogonal()
		var expected_a: Vector2 = stroke.get_parent().to_global(Stroke.anchor_world(stroke.anchors[0]))
		var expected_b: Vector2 = stroke.get_parent().to_global(Stroke.anchor_world(stroke.anchors[1]))
		check("yellow texture endpoint A reaches terminal center", stroke.pixel_world(stroke.path[0]).distance_to(expected_a) < 0.01 and stroke.endpoint_a.global_position.distance_to(expected_a) < 0.01)
		check("yellow texture endpoint B reaches terminal center", stroke.pixel_world(stroke.path[-1]).distance_to(expected_b) < 0.01 and stroke.endpoint_b.global_position.distance_to(expected_b) < 0.01)
		check("yellow keeps brush width while stretched", absf(stroke.visual.transform.basis_xform(source_normal).length() - 1.0) < 0.001)
		check("stroke data node keeps identity transform", stroke.transform == Transform2D.IDENTITY)
		check("terminal texture stays upright and unscaled", absf(stroke.endpoint_a.global_rotation) < 0.001 and stroke.endpoint_a.global_scale.distance_to(Vector2.ONE) < 0.001 and absf(stroke.endpoint_b.global_rotation) < 0.001 and stroke.endpoint_b.global_scale.distance_to(Vector2.ONE) < 0.001)
	print("DRAW cup=", demo.cup.position, " player=", level.get_node("Player").body.position, " hand=", demo.hand.body.com_world(), " projectile=", demo.projectile.position, " draw=", demo.max_draw, " peak_force=", demo.peak_hand_force, " peak_power=", demo.peak_power_percent, " player_drift=", demo.max_player_displacement)
	if shot == 0 and "--render" in OS.get_cmdline_user_args():
		await capture("yellow-hand-draw.png")
	demo.hand.set_grip(false)
	for i in 360:
		tick()
		if shot == 0 and i == 20 and "--render" in OS.get_cmdline_user_args():
			await capture("yellow-hand-shot.png")
	check("projectile horizontal speed is at least 700 px/s", demo.launch_horizontal_speed >= 700.0)
	check("at least 60 percent of stored energy reaches projectile", demo.energy_efficiency >= 60.0)
	check("projectile has no yellow constraint", level.world.joints.all(func(j): return j.body_a != demo.projectile and j.body_b != demo.projectile))
	for stroke in demo.springs:
		stroke.update_visual()
		var expected_a: Vector2 = stroke.get_parent().to_global(Stroke.anchor_world(stroke.anchors[0]))
		var expected_b: Vector2 = stroke.get_parent().to_global(Stroke.anchor_world(stroke.anchors[1]))
		check("yellow texture remains on terminal A after launch", stroke.pixel_world(stroke.path[0]).distance_to(expected_a) < 0.01)
		check("yellow texture remains on terminal B after launch", stroke.pixel_world(stroke.path[-1]).distance_to(expected_b) < 0.01)
		check("soft yellow survives the hand draw", stroke.state == stroke.State.ACTIVE and stroke.worn.is_empty())
	print("HAND_SLING speed=", demo.launch_speed, " horizontal=", demo.launch_horizontal_speed, " efficiency=", demo.energy_efficiency, "% distance=", demo.flight_distance, " shots=", demo.shots)
	level.queue_free()
	await process_frame

func capture(filename: String) -> void:
	for stroke in demo.springs:
		stroke.update_visual()
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(OS.get_environment("TEMP").path_join(filename))
