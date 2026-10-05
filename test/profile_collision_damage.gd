extends "res://test/test_collision_damage.gd"
## 同一主场景固定步对比：-- --disabled 关闭破坏规则；统计全步及计算/提交热点。

class AxialHand:
	extends "res://actor/player/src/hand.gd"
	func _calculate_motor(target: Vector2, position: Vector2, delta: float) -> Vector2:
		var force: Vector2 = super._calculate_motor(target, position, delta)
		if grabbed_body != null and grabbed_body.is_static:
			var axis: Vector2 = (position - player_body.com_world()).normalized()
			return _limit_power(axis * force.dot(axis), 0.0, position, delta)
		return force

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
	var ground_grab: bool = OS.get_cmdline_user_args().has("--ground-grab")
	var scene = MAIN.instantiate()
	scene.auto_step = false
	if slam:
		scene.get_node("Player").position = Vector2(0, 180)
	var controller = scene.get_node("CollisionDamage")
	controller.set_script(Profile)
	controller.disabled = OS.get_cmdline_user_args().has("--disabled")
	if OS.get_cmdline_user_args().has("--axial"):
		scene.get_node("Player/Arm/Hand/HandControl").set_script(AxialHand)
	root.add_child(scene)
	controller.set_physics_process(false)
	var hand = scene.get_node("Player/Arm/Hand/HandControl")
	hand.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	await process_frame
	await process_frame
	# 同一动作只切换接触采集，隔离应力扫描的开销。
	scene.world.contact_events_enabled = OS.get_cmdline_user_args().has("--events")
	var anchor: Vector2 = Vector2(-80, 231)
	var rest: Vector2 = Vector2.ZERO
	if ground_grab:
		var player = scene.get_node("Player").body
		if OS.get_cmdline_user_args().has("--heavy-arm"):
			hand.arm_body.shapes[0].density_scale = 21.0
			scene.world.refresh_mass(hand.arm_body)
		player.position = Vector2(0, 215) - player.local_com
		player.refresh_com()
		player.update_aabb()
		hand._remove_arm()
		var direction: Vector2 = (anchor - player.com_world()).normalized()
		hand.body.rotation = direction.angle()
		rest = anchor - direction * 20.0
		hand.body.position = rest - hand.body.local_com.rotated(hand.body.rotation)
		hand.body.refresh_com()
		hand.body.update_aabb()
		hand._begin_grab(scene.get_node("Ground").body, anchor)
	if slam:
		var box = scene.get_node("Box").body
		anchor = hand.body.com_world() + hand.FINGERTIP.rotated(hand.body.rotation)
		box.position = anchor - Vector2(0, 16)
		box.refresh_com()
		box.update_aabb()
		hand._begin_grab(box, anchor)
	var samples: Array[int] = []
	var hand_us: int = 0
	var live: bool = OS.get_cmdline_user_args().has("--live")
	var sweep: bool = OS.get_cmdline_user_args().has("--sweep")
	var peak_substeps: int = 0
	var late_min: Vector2 = Vector2(INF, INF)
	var late_max: Vector2 = Vector2(-INF, -INF)
	var late_positions: Array[Vector2] = []
	var rightward: float = 0.0
	var grip_error: float = 0.0
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
		if ground_grab:
			hand._target_override = rest + Vector2(-60, 0)
			if OS.get_cmdline_user_args().has("--relax") and frame >= 150:
				hand._target_override = rest
		hand._grip_override = slam or ground_grab
		var start: int = Time.get_ticks_usec()
		scene.get_node("Player/PlayerInput").apply_input(0.0, false, 1.0 / 60.0)
		hand._physics_process(1.0 / 60.0)
		hand_us += Time.get_ticks_usec() - start
		controller._physics_process(1.0 / 60.0)
		samples.append(Time.get_ticks_usec() - start)
		peak_substeps = maxi(peak_substeps, scene.world.last_substeps)
		if ground_grab:
			var player = scene.get_node("Player").body
			if frame < 150:
				rightward = maxf(rightward, player.com_world().x)
			grip_error = maxf(grip_error, hand.grip_joint.anchor_a_world().distance_to(hand.grip_joint.anchor_b_world()))
			if frame >= 540:
				late_min = late_min.min(player.com_world())
				late_max = late_max.max(player.com_world())
				late_positions.append(player.com_world())
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
	if ground_grab:
		var residual_min: Vector2 = Vector2(INF, INF)
		var residual_max: Vector2 = Vector2(-INF, -INF)
		for i in late_positions.size():
			var residual: Vector2 = late_positions[i] - late_positions[0].lerp(late_positions[-1], float(i) / (late_positions.size() - 1))
			residual_min = residual_min.min(residual)
			residual_max = residual_max.max(residual)
		var vibration: float = (residual_max - residual_min).length()
		print("GROUND_GRAB rightward=%.3f late_motion=%.6f detrended_vibration=%.6f weld_error=%.6f" % [rightward, (late_max - late_min).length(), vibration, grip_error])
		_check("leftward hand force moves body right", rightward > 5.0)
		_check("ground grab late vibration below quarter pixel", vibration < 0.25)
		_check("ground grip remains bound", grip_error < 0.75)
		print("JOINTS reach=%.3f hinge_error=%.6f slider_angle=%.6f arm_mass=%.1f" % [
			hand.body.com_world().distance_to(scene.get_node("Player").body.com_world()),
			hand.pivot_joint.anchor_a_world().distance_to(hand.pivot_joint.anchor_b_world()),
			rad_to_deg(wrapf(hand.arm_body.rotation - hand.body.rotation, -PI, PI)), hand.arm_body.mass])
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
	quit(1 if failures else 0)


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
