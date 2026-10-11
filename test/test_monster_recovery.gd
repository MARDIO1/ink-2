extends SceneTree

const PixelWorld := preload("res://addons/pixel_destruction/nodes/pixel_world.gd")
const PixelBody := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var valid := true
	for scene_path in ["res://actor/monster/little_soldier.tscn", "res://actor/monster/great_shield.tscn"]:
		var level := PixelWorld.new()
		level.densities_fallback = [0.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
		root.add_child(level)
		var ground := PixelBody.new()
		ground.position = Vector2(-1500, 231)
		ground.rect_size = Vector2i(3000, 40)
		ground.is_static = true
		level.add_child(ground)
		var ground_body = ground.body
		var container := Node2D.new()
		container.name = "Monsters"
		level.add_child(container)
		var monster = (load(scene_path) as PackedScene).instantiate()
		monster.position = Vector2(0, -40)
		container.add_child(monster)
		await process_frame
		await physics_frame
		for _frame in 240:
			await physics_frame
		print("[Recovery] ", scene_path, " initial torso=", monster.body.rotation)
		for index in 4:
			print("[Recovery] initial ", monster._ragdoll.parts[index].bone.name, "=", monster._ragdoll.joints[index].movement())
		for index in level.world.contact_pair_count():
			print("[Recovery] contact ", level.world.contact_info(index))
		for trial in 2:
			monster.global_position = Vector2(0, -40)
			monster.global_rotation = 0.65 if trial == 0 else -0.65
			monster.sync_physics_from_node()
			var arm = monster._ragdoll.parts[trial].body
			arm.apply_impulse(Vector2(0, -arm.mass * 120), arm.com_world() + Vector2(20, 0))
			monster.receive_contact_impact(arm.com_world(), Vector2(0, -arm.mass * 120))
			arm = null
			for _frame in 360:
				await physics_frame
			print("[Recovery] trial=", trial, " torso=", monster.body.rotation)
			valid = valid and absf(monster.body.rotation) < 0.08
			for index in 4:
				var joint = monster._ragdoll.joints[index]
				print("[Recovery] ", monster._ragdoll.parts[index].bone.name, "=", joint.movement(), " target=", joint.motor_target)
				valid = valid and absf(joint.movement()) < 0.15 and joint.anchor_error_len() < 3.0
		ground_body = null
		level.queue_free()
		await process_frame
	print("[Recovery] both monsters, both arms and legs: ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)
