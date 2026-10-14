extends SceneTree

var failures := 0
var health_events := 0

func _initialize() -> void:
	run.call_deferred()

func check(label: String, condition: bool) -> void:
	print("[StandingLive] ", label, ": ", "PASS" if condition else "FAIL")
	if not condition:
		failures += 1

func run() -> void:
	var level := (load("res://map/asset/imported/main.tscn") as PackedScene).instantiate()
	for name in ["Box", "Gym"]:
		level.get_node(name).free()
	level.get_node("Ground").position.x = -800.0
	level.get_node("Ground/Shape").rect_size.x = 1600
	level.get_node("Player").position = Vector2(500, 0)
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	root.add_child(level)
	await process_frame
	level.get_node("SimulationRuntime/ImpactDamage").min_approach = 1.0e12
	creative.set_active(true)
	var monster = creative.place_monster(3, Vector2.ZERO, false, "standing-live")
	await process_frame
	await physics_frame
	var player = level.get_node("Player")
	var initial_player_position: Vector2 = player.body.position
	# 头顶轻微左右摆动不能触发转向刚体重建。
	monster._editor_physics_paused = false
	var rag = monster._ragdoll
	var native_count: int = level.world.bodies.size()
	for index in 30:
		player.body.position = monster.body.com_world() + Vector2(6.0 if index % 2 == 0 else -6.0, -200.0) - player.body.local_com
		player.body.refresh_com()
		monster._update_walk_state()
	check("head wobble preserves ragdoll and native bodies", monster._ragdoll == rag and level.world.bodies.size() == native_count)
	monster._editor_physics_paused = true
	player.body.position = initial_player_position
	player.body.refresh_com()
	creative.set_active(false)
	player.get_node("Arm/Hand/HandControl").set_physics_process(false)
	# 先让敌人落地，避免把同速自由落体后的首次落地当成站立承重。
	for frame in 480:
		await physics_frame
	monster.body.update_aabb()
	player.body.update_aabb()
	var shift := Vector2(monster.body.com_world().x - player.body.com_world().x,
		monster.body.aabb.position.y - player.body.aabb.end.y - 1.0)
	for body in level.world.joint_component(player.body):
		body.position += shift
		body.linear_velocity = Vector2.ZERO
		body.angular_velocity = 0.0
		body.refresh_com()
		body.update_aabb()
	# 只限制测试玩家横移，避免它从圆弧头盔滑走；承重仍由真实接触求解。
	var guide = level.world.add_slider(null, player.body, player.body.com_world(), Vector2.DOWN)
	monster.health_changed.connect(func(_current, _maximum): health_events += 1)
	var contact_frames := 0
	var recovery_frames := 0
	var baseline: float = monster.health
	for frame in 240:
		await physics_frame
		if not is_instance_valid(monster):
			check("standing enemy survives", false)
			break
		if frame == 60:
			baseline = monster.health
			health_events = 0
		if frame >= 60:
			if monster._hit_recovery > 0.0:
				recovery_frames += 1
			for index in level.world.contact_pair_count():
				var contact: Dictionary = level.world.contact_info(index)
				if (contact.id_a == player.body.rapier_id and contact.id_b == monster.body.rapier_id) \
					or (contact.id_b == player.body.rapier_id and contact.id_a == monster.body.rapier_id):
					contact_frames += 1
	if not is_instance_valid(monster):
		level.queue_free()
		await process_frame
		quit(1)
		return
	print("[StandingLive] support frames=", contact_frames, " HP=", baseline, " -> ", monster.health,
		" updates=", health_events, " ragdoll release frames=", recovery_frames)
	check("player really contacts enemy head", contact_frames >= 20)
	check("sustained support does not drain HP", monster.health == baseline and health_events == 0)
	check("sustained support does not release pose motors", recovery_frames == 0)
	level.world.remove_joint(guide)
	level.queue_free()
	await process_frame
	print("STANDING_LIVE: ", "PASS" if failures == 0 else "FAIL")
	quit(0 if failures == 0 else 1)
