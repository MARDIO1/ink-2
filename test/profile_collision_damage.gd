extends "res://test/test_collision_damage.gd"
## 同一主场景固定步对比：-- --disabled 关闭破坏规则；统计全步及计算/提交热点。

class Profile:
	extends "res://map/src/collision_damage.gd"
	var disabled: bool = false
	var calculate_us: int = 0
	var commit_us: int = 0
	var rebuild_batches: int = 0
	var traced_pixels: int = 0
	var lanes: int = 0

	func calculate(world, player_body: PBody = null, protected_bodies: Array = []) -> Dictionary:
		if disabled:
			return {"removals": {}, "player_damage": 0.0}
		var start: int = Time.get_ticks_usec()
		var result: Dictionary = super.calculate(world, player_body, protected_bodies)
		calculate_us += Time.get_ticks_usec() - start
		return result

	func commit(world, removals: Dictionary) -> Dictionary:
		var start: int = Time.get_ticks_usec()
		var result: Dictionary = super.commit(world, removals)
		commit_us += Time.get_ticks_usec() - start
		rebuild_batches += result.calls
		return result

	func _trace(body: PBody, origin: Vector2, direction: Vector2, world = null, budget: float = INF, player: bool = false) -> Array:
		var path: Array = super._trace(body, origin, direction, world, budget, player)
		traced_pixels += path.size()
		return path

	func _lanes(points: Array) -> Array:
		var result: Array = super._lanes(points)
		lanes += result.size()
		return result


func _run() -> void:
	_stress()
	var slam: bool = OS.get_cmdline_user_args().has("--slam")
	var scene = MAIN.instantiate()
	scene.auto_step = false
	if slam:
		scene.get_node("Player").position = Vector2(0, 180)
	var controller = scene.get_node("CollisionDamage")
	controller.set_script(Profile)
	controller.disabled = OS.get_cmdline_user_args().has("--disabled")
	root.add_child(scene)
	controller.set_physics_process(false)
	var hand = scene.get_node("Player/Arm/Hand/HandControl")
	hand.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	await process_frame
	await process_frame
	if slam:
		var box = scene.get_node("Box").body
		var anchor: Vector2 = hand.body.com_world() + hand.FINGERTIP.rotated(hand.body.rotation)
		box.position = anchor - Vector2(0, 16)
		box.refresh_com()
		box.update_aabb()
		hand._begin_grab(box, anchor)
	var samples: Array[int] = []
	var hand_us: int = 0
	var live: bool = OS.get_cmdline_user_args().has("--live")
	var sweep: bool = OS.get_cmdline_user_args().has("--sweep")
	var peak_substeps: int = 0
	scene.auto_step = true
	for frame in 600:
		if live:
			await physics_frame
		var offset: Vector2 = Vector2(72, -32)
		if sweep:
			offset = Vector2(110, 0).rotated(frame * 0.04)
		if slam:
			offset = Vector2(100, -100) if frame % 240 < 120 else Vector2(60, 144)
		hand._target_override = scene.get_node("Player").body.com_world() + offset
		hand._grip_override = slam
		var start: int = Time.get_ticks_usec()
		hand._physics_process(1.0 / 60.0)
		hand_us += Time.get_ticks_usec() - start
		controller._physics_process(1.0 / 60.0)
		samples.append(Time.get_ticks_usec() - start)
		peak_substeps = maxi(peak_substeps, scene.world.last_substeps)
		if frame % 120 == 119:
			print("PROFILE frame=%d bodies=%d calculate_ms=%.2f commit_ms=%.2f batches=%d traced_pixels=%d lanes=%d hand_ms=%.2f" % [frame + 1,
				scene.world.bodies.size(), controller.calculate_us / 1000.0, controller.commit_us / 1000.0,
				controller.rebuild_batches, controller.traced_pixels, controller.lanes, hand_us / 1000.0])
			if live:
				print("LIVE fps=%d max_substeps=%d" % [Engine.get_frames_per_second(), peak_substeps])
	var total: int = 0
	for sample in samples:
		total += sample
	samples.sort()
	print("PROFILE disabled=%s mean_ms=%.3f p95_ms=%.3f max_ms=%.3f" % [controller.disabled,
		total / 600000.0, samples[569] / 1000.0, samples[-1] / 1000.0])
	for body in scene.world.bodies:
		var pixels: int = 0
		for shape in body.shapes:
			pixels += shape.pixel_count()
		print("BODY id=%d static=%s pixels=%d rects=%d speed=%.2f angular=%.2f awake=%s" % [
			body.id, body.is_static, pixels, body.rects.size(), body.linear_velocity.length(), body.angular_velocity, body.awake])
	scene.auto_step = false
	hand._release_grab()
	hand._remove_arm()
	_release(scene.world)
	scene.queue_free()
	await process_frame
	quit()


func _stress() -> void:
	var world = PWorld.new()
	var body = _body(world, Vector2.ZERO, Vector2i(800, 40))
	body.is_static = true
	var pixels: Dictionary = {}
	for x in range(64):
		for y in range(1 if x % 2 == 0 else 3):
			pixels[Vector2i(100 + x, y)] = true
	var controller = Profile.new()
	var start: int = Time.get_ticks_usec()
	var result: Dictionary = controller.commit(world, {body: {body.shapes[0]: pixels}})
	print("STRESS jagged_surface_ms=%.3f deleted=%d rebuild_batches=%d" % [
		(Time.get_ticks_usec() - start) / 1000.0, pixels.size(), result.calls])
	_release(world)
	controller.free()
