extends "res://test/test_collision_damage.gd"
## 保留主场景自动步进和输入回调，验证真实落地后的按键路径。
func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene = load("res://map/asset/main.tscn").instantiate()
	var grip: bool = OS.get_cmdline_user_args().has("--grip")
	var side: float = 1.0 if OS.get_cmdline_user_args().has("--right") else -1.0
	if grip:
		scene.auto_step = false
		scene.get_node("Player").position = Vector2(-12, 115)
		scene.get_node("Player/Arm/Hand/HandControl").rest_offset = Vector2(0, 80)
	root.add_child(scene)
	var feet = scene.get_node("Player/PlayerInput")
	var hand = scene.get_node("Player/Arm/Hand/HandControl")
	var damage = scene.get_node("CollisionDamage")
	if grip:
		await process_frame
		await process_frame
		_check("ground weld created", hand._begin_grab(scene.get_node("Ground").body, Vector2(0, 231)))
		hand.set_grip(true)
		hand.set_target_world(Vector2(side * 60, 211))
		var initial: Vector2 = feet.player.body.com_world()
		scene.auto_step = true
		for i in 60:
			await physics_frame
			if i == 1 or i == 59:
				print("GRIP side=", side, " frame=", i, " displacement=", feet.player.body.com_world() - initial, " hand_force=", hand.debug_force_vector, " velocity=", feet.player.body.linear_velocity)
		var debug = scene.get_node("HUD/ForceDebug")
		for arrow in debug.arrows:
			if arrow.body == feet.player.body:
				print("BODY_FORCE ", arrow.title, " = ", arrow.force)
		_check("P+D equals applied force", (hand.debug_p_force + hand.debug_d_force).distance_to(hand.debug_force_vector) < 2.0)
		_check("force vector observer sampled", not debug.arrows.is_empty())
		await _finish(scene, hand)
		return
	hand.set_target_world(Vector2(-44, 190))
	hand.set_grip(false)
	for i in 180:
		await physics_frame
	print("REST pos=", feet.player.body.com_world(), " support=", feet.support)
	for contact in damage._contacts(scene.world):
		if contact.a == feet.player.body or contact.b == feet.player.body:
			print("CONTACT player_a=", contact.a == feet.player.body, " points=", contact.points)
	var start: Vector2 = feet.player.body.com_world()
	_key(KEY_D, true)
	var active: int = 0
	for i in 120:
		await physics_frame
		if feet.debug_force > 0.0:
			active += 1
	_key(KEY_D, false)
	print("WALK delta=", feet.player.body.com_world() - start, " active=", active, " velocity=", feet.player.body.linear_velocity)
	for arrow in scene.get_node("HUD/ForceDebug").arrows:
		if arrow.body == feet.player.body:
			print("WALK_FORCE ", arrow.title, " = ", arrow.force)
	_check("automatic input moves over 100 pixels in two seconds", feet.player.body.com_world().x - start.x > 100.0)
	# 自然转动允许间歇离地；这里只检查进入过施力分支，不要求整段一直着地。
	_check("walking branch runs", active > 0)
	if OS.get_cmdline_user_args().has("--visual"):
		await process_frame
		await process_frame
		root.get_texture().get_image().save_png("res://test/hud_check.png")
	for attempt in 2:
		for i in 180:
			await physics_frame
		print("PREJUMP support=", feet.support, " pos=", feet.player.body.com_world())
		_check("landing reacquires support %d" % attempt, feet.support != null)
		print("STATE awake=", feet.player.body.awake, " rotation=", feet.player.body.rotation, " pairs=", scene.world.contact_pair_count())
		for contact in damage._contacts(scene.world):
			if contact.a == feet.player.body or contact.b == feet.player.body:
				print("LANDED points=", contact.points)
		_key(KEY_SPACE, true)
		await physics_frame
		await physics_frame
		print("JUMP ", attempt, " force=", feet.debug_force, " velocity=", feet.player.body.linear_velocity)
		_check("jump input branch %d" % attempt, feet.debug_force > 0.0 and feet.player.body.linear_velocity.y < -50.0)
		_key(KEY_SPACE, false)
	await _finish(scene, hand)

func _finish(scene, hand) -> void:
	scene.auto_step = false
	hand.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	hand._release_grab()
	hand._remove_arm()
	_release(scene.world)
	scene.queue_free()
	await process_frame
	print("[LiveInput] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

func _key(code: int, pressed: bool) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
