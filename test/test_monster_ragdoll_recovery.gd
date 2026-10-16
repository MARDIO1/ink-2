extends SceneTree

var failed := false

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var level := (load("res://map/asset/imported/main.tscn") as PackedScene).instantiate()
	for name in ["Box", "Gym"]:
		level.get_node(name).free()
	level.get_node("Player").position = Vector2(-2000, 0)
	level.get_node("Ground").position.x = -800.0
	level.get_node("Ground/Shape").rect_size.x = 1600
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	root.add_child(level)
	level.get_node("debugHUD").process_mode = Node.PROCESS_MODE_DISABLED
	await process_frame
	level.get_node("SimulationRuntime/ImpactDamage").min_approach = 1.0e12
	# 玩家移到远处只为隔离干扰，不能让镜头范围剔除把被测怪物冻结。
	level.get_node("SimulationRuntime/PhysicsStep").freeze_view_scale = 32.0
	creative.set_active(true)
	var kind := 1 if "--little" in OS.get_cmdline_user_args() else 3
	if "--bomb" in OS.get_cmdline_user_args():
		kind = 2
	var monster = creative.place_monster(kind, Vector2(0, -20), false, "recovery-check")
	monster.contact_damage_scale = 0.0
	monster.attacks_enabled = false
	await process_frame
	await physics_frame
	if "--mirror" in OS.get_cmdline_user_args():
		monster._current_facing = 1
		monster.get_node("Visual").scale.x = -absf(monster.get_node("Visual").scale.x)
		monster.sync_physics_from_node(true)
	creative.set_active(false)
	for frame in 180:
		await physics_frame
	var rag = monster._ragdoll
	print("BASE kind=", kind, " torso=", monster.body.rotation, " arm=", rag.joints[0].movement())
	if "--tip" in OS.get_cmdline_user_args():
		# 整体倾倒但不塞进地形；验证大角度回正，而不只验证小幅站立扰动。
		monster.global_position += Vector2(0, -70)
		monster.global_rotation = 0.75
		monster.sync_physics_from_node()
	monster.body.angular_velocity = 4.0
	monster.body.awake = true
	monster.body.sleep_timer = 0.0
	if rag.shield_body != null:
		rag.shield_body.angular_velocity = -6.0
		rag.shield_body.awake = true
		rag.shield_body.sleep_timer = 0.0
	else:
		rag.parts[0].body.angular_velocity = -6.0
		rag.parts[0].body.awake = true
	monster._hit_cooldown = 0.0
	monster.receive_contact_impact(monster.global_position, Vector2(300, 0), null, false)
	if monster._hit_recovery <= 0.0:
		failed = true
		push_error("impact did not engage ragdoll recovery")
	rag.update_balance(1.0 / 60.0, false, true, false, monster)
	failed = failed or rag.recovery_strength != 0.0 or monster.body.control_torque != 0.0
	for joint in rag.joints:
		failed = failed or joint.motor_mode != joint.MOTOR_OFF
	var peak := 0.0
	var peak_upward_speed := 0.0
	var recovery_overshoot := 0.0
	var initial_recovery_angle := 0.0
	var recovery_started := false
	for frame in 480:
		await physics_frame
		peak = maxf(peak, absf(monster.body.rotation))
		if monster._hit_recovery <= 0.0:
			if not recovery_started:
				initial_recovery_angle = monster.body.rotation
				recovery_started = true
			var bodies: Array = [monster.body]
			for part in rag.parts:
				bodies.append(part.body)
			if rag.shield_body != null:
				bodies.append(rag.shield_body)
			var momentum := Vector2.ZERO
			var mass := 0.0
			for body in bodies:
				momentum += body.linear_velocity * body.mass
				mass += body.mass
			peak_upward_speed = maxf(peak_upward_speed, -momentum.y / maxf(mass, 0.001))
			if monster.body.rotation * initial_recovery_angle < 0.0:
				recovery_overshoot = maxf(recovery_overshoot, absf(monster.body.rotation))
		if frame % 120 == 119:
			print("RECOVERY frame=", frame, " torso=", monster.body.rotation,
				" shield=", rag.shield_body.rotation if rag.shield_body != null else 0.0, " arm=", rag.joints[0].movement(),
				" strength=", rag.recovery_strength, " timer=", monster._hit_recovery)
	failed = failed or absf(wrapf(monster.body.rotation, -PI, PI)) > 0.12
	print("RECOVERY peak torso angle=", peak)
	print("RECOVERY upward speed=", peak_upward_speed, " overshoot=", recovery_overshoot)
	# 180 px/s 在本场重力下约等于 11 px 的上抬，不能出现整个人弹离地面的速度。
	failed = failed or peak_upward_speed > 180.0 or recovery_overshoot > 0.12
	if rag.shield_body != null:
		failed = failed or absf(wrapf(rag.shield_body.rotation, -PI, PI)) > 0.15 \
			or rag.shield_joint.anchor_error_len() > 2.0 or absf(rag.shield_joint.angle_error()) > 0.03
		# 破盾后的放手零位不能覆盖创建关节时的马达参考角。
		level.world.remove_body(rag.shield_body)
		rag._check_shield_break(monster)
		rag.update_balance(1.0 / 60.0, false, false, false, monster)
		var sign: float = -1.0 if monster.get_node("Visual").global_transform.determinant() < 0.0 else 1.0
		var movement: float = rag.joints[0].movement()
		var error := wrapf(-rag.SHIELD_HOLD_ARM_OFFSET * sign - movement, -PI, PI)
		var max_error: float = rag.MAX_RECOVERY_ANGULAR_SPEED * rag.joints[0].motor_damping / rag.joints[0].motor_stiffness
		failed = failed or absf(rag.joints[0].motor_target - movement - clampf(error, -max_error, max_error)) > 0.001
		print("BROKEN_SHIELD arm target=", rag.joints[0].motor_target)
	level.queue_free()
	await process_frame
	print("MONSTER_RAGDOLL_RECOVERY: ", "FAIL" if failed else "PASS")
	quit(1 if failed else 0)
