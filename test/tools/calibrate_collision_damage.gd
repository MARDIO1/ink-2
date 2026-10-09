extends "res://test/test_collision_damage.gd"
## 真主场景和真 PD 动作；只观测不同系数的删除计划，保持碰撞几何相同。

class Probe:
	extends "res://map/src/impact_damage.gd"
	var scales: Array[float] = [0.01, 0.011, 0.012, 0.013, 0.015, 0.02, 0.1]
	var apply: bool = false
	var peaks: Dictionary = {}
	var target = null
	var hand = null
	var impulse: float = 0.0
	var approach: float = 0.0
	var applied_pixels: Dictionary = {}

	func calculate(world, contacts: Array, player_body: PBody = null, protected_bodies: Array = []) -> Dictionary:
		if apply:
			var result: Dictionary = super.calculate(world, contacts, player_body, protected_bodies)
			for pixels in result.removals.get(target, {}).values():
				applied_pixels.merge(pixels, true)
			return result
		for contact in contacts:
			if (contact.a == hand and contact.b == target) or (contact.b == hand and contact.a == target):
				approach = maxf(approach, contact.approach)
				# ⚠️ 现行 API：_lanes() 已并入 _impact()（返回的 impulse 就是每条 lane 的冲量）。
				var lane: Dictionary = _impact(contact.points)
				if not lane.is_empty():
					impulse = maxf(impulse, lane["impulse"])
		for scale in scales:
			damage_scale = scale
			var result: Dictionary = super.calculate(world, contacts, player_body, protected_bodies)
			var count: int = 0
			var depth: int = 0
			for pixels in result.removals.get(target, {}).values():
				count += pixels.size()
				for pixel: Vector2i in pixels:
					depth = maxi(depth, pixel.y + 1)
			var previous: Vector2i = peaks.get(scale, Vector2i.ZERO)
			peaks[scale] = Vector2i(maxi(previous.x, count), maxi(previous.y, depth))
		return {"removals": {}, "player_damage": 0.0}


func _run() -> void:
	await _scenario(false)
	await _scenario(true)
	await _scenario(true, true)
	print("[CalibrateDamage] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func _scenario(slam: bool, apply: bool = false) -> void:
	var scene = MAIN.instantiate()
	scene.auto_step = false
	if slam:
		scene.get_node("Player").position = Vector2(0, 180)
	var controller = scene.get_node("PhysicsRuntime")
	var probe = controller.get_node("ImpactDamage")
	probe.set_script(Probe)
	probe.apply = apply
	root.add_child(scene)
	controller.set_physics_process(false)
	var hand = scene.get_node("Player/Arm/Hand/HandControl")
	hand.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	await process_frame
	await process_frame
	probe.target = scene.get_node("Ground").body
	var original_pixels: int = probe.target.shapes[0].pixel_count()
	probe.hand = hand.body
	if slam:
		var box = scene.get_node("Box").body
		var anchor: Vector2 = hand.body.com_world() + hand.FINGERTIP.rotated(hand.body.rotation)
		box.position = anchor - Vector2(0, 16)
		box.refresh_com()
		box.update_aabb()
		hand._begin_grab(box, anchor)
		probe.hand = box
	scene.auto_step = true
	for frame in 240:
		var offset: Vector2 = Vector2(72, -32)
		if slam:
			offset = Vector2(100, -100) if frame < 120 else Vector2(60, 144)
			if frame == 120:
				probe.peaks.clear()
				probe.impulse = 0.0
				probe.approach = 0.0
		hand._target_override = scene.get_node("Player").body.com_world() + offset
		hand._grip_override = slam
		hand._physics_process(1.0 / 60.0)
		controller._physics_process(1.0 / 60.0)
	if apply:
		var removed: int = original_pixels - probe.target.shapes[0].pixel_count()
		var depth: int = 0
		for pixel: Vector2i in probe.applied_pixels:
			depth = maxi(depth, pixel.y + 1)
		print("APPLIED SLAM actual_ground_removed=%d depth=%d bodies=%d" % [removed, depth, scene.world.bodies.size()])
		_check("harder material withstands the former one-layer slam", removed == 0 and depth == 0)
	else:
		print("CALIBRATE slam=%s hand_approach=%.2f max_lane_impulse=%.2f scales_pixels_depth=%s" % [
			slam, probe.approach, probe.impulse, str(probe.peaks)])
		var selected: Vector2i = probe.peaks.get(0.012, Vector2i(-1, -1))
		if slam:
			_check("held block really strikes the ground", probe.approach > probe.min_approach and probe.impulse > 0.0)
			_check("hardness increase reduces the former slam damage", selected == Vector2i.ZERO)
		else:
			_check("ordinary fall produces no terrain damage", selected == Vector2i.ZERO)
	scene.auto_step = false
	hand._release_grab()
	hand._remove_arm()
	_release(scene.world)
	scene.queue_free()
	await process_frame
