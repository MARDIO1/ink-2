extends SceneTree

func _initialize() -> void:
	run.call_deferred()

func run() -> void:
	var level := (load("res://test/fixtures/maps/base_level.tscn") as PackedScene).instantiate()
	for name in ["Box", "Gym"]:
		level.get_node(name).free()
	level.get_node("Ground").position.x = -2000.0
	level.get_node("Ground/Shape").rect_size.x = 4000
	level.get_node("Player").position = Vector2(-1800, 0)
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	if "--no-fracture" in OS.get_cmdline_user_args():
		level.get_node("SimulationRuntime/ImpactDamage").min_approach = 1.0e12
	root.add_child(level)
	await process_frame
	level.get_node("Camera2D").set_physics_process(false)
	level.get_node("Camera2D").position = Vector2.ZERO
	level.get_node("Camera2D").zoom = Vector2(0.1, 0.1)
	var container := Node2D.new()
	container.name = "SpawnTestMonsters"
	level.add_child(container)
	var monsters: Array = []
	var crowded := "--crowded" in OS.get_cmdline_user_args()
	var specs := [[1, -120.0, 0.7], [3, 120.0, 0.9]] if crowded else [[1, -500.0, 0.7], [3, 500.0, 1.0]]
	for spec in specs:
		var path := "res://actor/monster/little_soldier.tscn" if spec[0] == 1 else "res://actor/monster/great_shield.tscn"
		var monster = (load(path) as PackedScene).instantiate()
		monster.position = Vector2(spec[1], -30)
		monster.scale = Vector2.ONE * spec[2]
		container.add_child(monster)
		await process_frame
		await physics_frame
		monsters.append(monster)
	await physics_frame
	var ranges := [Vector2(INF, -INF), Vector2(INF, -INF)]
	var max_up := [0.0, 0.0]
	for frame in 720:
		await physics_frame
		for monster in monsters:
			if not is_instance_valid(monster):
				push_error("Enemy died without player input")
				level.queue_free()
				await process_frame
				quit(1)
				return
		if frame >= 360:
			for index in monsters.size():
				var monster = monsters[index]
				ranges[index].x = minf(ranges[index].x, monster.body.position.y)
				ranges[index].y = maxf(ranges[index].y, monster.body.position.y)
				max_up[index] = maxf(max_up[index], -monster.body.linear_velocity.y)
	var valid := true
	for index in monsters.size():
		var amplitude: float = ranges[index].y - ranges[index].x
		print("[SpawnStability] kind=", monsters[index].kind, " vertical range=", ranges[index], " amplitude=", amplitude, " max upward speed=", max_up[index])
		if monsters[index]._ragdoll.shield_body != null:
			print("[SpawnStability] shield pixels=", monsters[index]._ragdoll.shield_body.shapes[0].pixel_count(), "/", monsters[index]._ragdoll.shield_initial_pixels)
			valid = valid and monsters[index]._ragdoll.shield_body.shapes[0].pixel_count() == monsters[index]._ragdoll.shield_initial_pixels
		valid = valid and monsters[index].health == monsters[index].max_health
		# 少量单步接触抖动可以有瞬时速度；反复离地则同时超过高度/速度阈值。
		valid = valid and amplitude < 8.0 and max_up[index] < 90.0 and monsters[index].body.position.y > 200.0 and not monsters[index].body.frozen
	level.queue_free()
	await process_frame
	print("SPAWN_STABILITY: ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)
