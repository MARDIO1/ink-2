extends SceneTree
## 有窗口的真实 Rapier 碰撞、游戏固定步、分片、渲染和 F1 采样闭环。
const Fixtures = preload("res://test/test_red_ink.gd")
const Shape = preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const MAIN = preload("res://map/main.tscn")
const Palette = preload("res://Ink/src/ink_palette.gd")
const Destruction = preload("res://addons/pixel_destruction/core/destruction.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var capture: bool = OS.get_cmdline_user_args().has("--capture")
	var player_size: bool = OS.get_cmdline_user_args().has("--player-size")
	var fixture_path: String = ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fixture="):
			fixture_path = argument.get_slice("=", 1)
	var fixture_parts: Array = []
	var fixture_counts: Dictionary = {}
	var fixture_bounds: Rect2i
	var fixture_anchor: Vector2i
	if not fixture_path.is_empty():
		var fixture_image: Image = load(fixture_path)
		var fixture_shape = Shape.new()
		for y in fixture_image.get_height():
			for x in fixture_image.get_width():
				var material: int = Palette.material_id_at_color(fixture_image.get_pixel(x, y))
				if material != 0:
					fixture_shape.set_pixel(x, y, material)
					fixture_counts[material] = fixture_counts.get(material, 0) + 1
		fixture_bounds = fixture_shape.local_aabb()
		fixture_anchor = fixture_bounds.position
		var best: float = INF
		for y in range(fixture_bounds.position.y, fixture_bounds.end.y):
			for x in range(fixture_bounds.position.x, fixture_bounds.end.x):
				if fixture_shape.get_pixel(x, y) == 0:
					continue
				var distance: float = (x - fixture_bounds.position.x) * 10000.0 + absf(y - fixture_bounds.get_center().y)
				if distance < best:
					best = distance
					fixture_anchor = Vector2i(x, y)
		fixture_parts = Destruction.split(fixture_shape, 1)
		if fixture_counts.get(8, 0) == 0:
			print("BLOCKED: F5存档没有红墨，不能作为红墨性能验收：" + fixture_path)
			quit(2)
			return
		fixture_image.save_png("user://red_ink_capture_preview.png")
		print("CAPTURE_FIXTURE ", {"path": fixture_path, "bounds": fixture_bounds,
			"materials": fixture_counts, "parts": fixture_parts.size(), "impact_cell": fixture_anchor})
	Engine.max_fps = 120
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var scene = MAIN.instantiate()
	root.add_child(scene)
	await process_frame
	await process_frame
	var runtime = scene.get_node("PhysicsRuntime")
	var hud = scene.get_node("debugHUD")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--event-size="):
			runtime.get_node("RedInk").event_chunk_size = int(argument.get_slice("=", 1))
	var player_bounds: Rect2i = scene.get_node("Player").body.shapes[0].local_aabb()
	for shape in scene.get_node("Player").body.shapes:
		player_bounds = player_bounds.merge(shape.local_aabb())
	print("PLAYER_RED_BOUNDS ", player_bounds)
	var trace_name: String = "red_ink_player_profile" if player_size else "red_ink_profile"
	if not fixture_path.is_empty():
		trace_name = "red_ink_capture_profile"
	for path in ["Player/PlayerInput", "Player/Arm/Hand/HandControl", "Player"]:
		scene.get_node(path).set_physics_process(false)
	for body in [scene.get_node("Player").body, scene.get_node("Player/Arm").body,
			scene.get_node("Player/Arm/Hand").body]:
		body.position += Vector2(-1000, 1000)
		body.collision_layer = 0
		body.collision_mask = 0
	for path in ["Ground", "Box"]:
		var node = scene.get_node(path)
		scene.world.remove_body(node.body)
		for shape in node.body.shapes:
			shape.owner_body = null
		node.body.shapes.clear()
		node.queue_free()
	var camera = scene.get_node("Camera2D")
	camera.set_physics_process(false)
	camera.position = Vector2(150, 110)
	# 材质来自真实 InkRuntime，保持游戏参数和碎片降级策略。
	var cannon = Fixtures.add_body(scene.world, Vector2(100, 110), Fixtures.cannon_shape())
	var shot_shape = Shape.new()
	shot_shape.fill_rect(Rect2i(0, 0, 6, 6), 4)
	var shot = Fixtures.add_body(scene.world, Vector2(120, 117), shot_shape)
	var hammer_shape = Shape.new()
	hammer_shape.fill_rect(Rect2i(0, 0, 500, 1), 4)
	var hammer = Fixtures.add_body(scene.world, Vector2(-410, 119.5), hammer_shape)
	for body in [cannon, shot, hammer]:
		body.gravity_scale = 0.0
	scene.sync_world_bodies()
	# 暖机包含材质贴图上传；记录启动后的完整帧间隔。
	for frame in 60:
		await process_frame
	hud._toggle_log()
	var times: Array = []
	var total_profile: Dictionary = {}
	var previous: int = Time.get_ticks_usec()
	var launches: bool = false
	var recoil: bool = false
	var fragments: int = 0
	var red_cells: int = 0
	var physical_pairs: int = 0
	var peak_physics_us: int = 0
	var max_approach: float = 0.0
	var max_contact_impulse: float = 0.0
	var shot_impulse: float = 0.0
	var recoil_impulse: float = 0.0
	var cannon_family: Dictionary = {cannon.id: true}
	var fragment_recoil: bool = false
	var grenade_reacted: bool = false
	var last_shot_position: Vector2 = shot.position
	var outward_visual_fragments: int = 0
	var trace = FileAccess.open("user://" + trace_name + ".jsonl", FileAccess.WRITE)
	# HUD 先消费累计探针，这里从低帧日志之外独立记录每个渲染帧。
	hud.set_process(false)
	for frame in 600:
		if frame == 30:
			hammer.linear_velocity = Vector2(1000, 0)
		if frame == 240:
			last_shot_position = shot.position
			for body in scene.world.bodies.duplicate():
				if body.collision_layer == 0:
					continue
				scene.world.remove_body(body)
				for shape in body.shapes:
					shape.owner_body = null
				body.shapes.clear()
			var grenade_shape = Fixtures.grenade_shape()
			if player_size:
				grenade_shape = Shape.new()
				grenade_shape.fill_rect(Rect2i(Vector2i.ZERO, player_bounds.size), 8)
			var grenade = Fixtures.add_body(scene.world, Vector2(100, 110), grenade_shape)
			var fixture_origin: Vector2 = Vector2(100, 110) - Vector2(fixture_bounds.position)
			if not fixture_parts.is_empty():
				scene.world.remove_body(grenade)
				for shape in grenade.shapes:
					shape.owner_body = null
				grenade.shapes.clear()
				var before: int = scene.world.bodies.size()
				var canvas = scene.get_node("SmallCanvas")
				canvas.position = fixture_origin
				var surface = canvas.get_node("CanvasSurface")
				if surface.load_ink(fixture_path) != OK:
					quit(2)
					return
				canvas.get_node("CanvasSolid").solidify(surface, scene)
				for index in range(before, scene.world.bodies.size()):
					grenade = scene.world.bodies[index]
					grenade.gravity_scale = 0.0
			var striker_shape = Shape.new()
			striker_shape.fill_rect(Rect2i(0, 0, 100, 50), 4)
			striker_shape.fill_rect(Rect2i(100, 24, 30, 1), 4)
			var strike_y: float = 110.0 + player_bounds.size.y * 0.5 - 24.5 if player_size else 94.5
			if not fixture_parts.is_empty():
				strike_y = fixture_origin.y + fixture_anchor.y + 0.5 - 24.5
			var striker = Fixtures.add_body(scene.world, Vector2(-40, strike_y), striker_shape)
			grenade.gravity_scale = 0.0
			striker.gravity_scale = 0.0
			striker.linear_velocity = Vector2(1000, 0)
			scene.sync_world_bodies()
			if not fixture_parts.is_empty():
				# 用户存档加载/固化是一次性准备，不能混作爆炸卡顿。
				striker.linear_velocity = Vector2.ZERO
				for warm_frame in 60:
					await process_frame
				runtime.take_profile()
				hud.forces.take_profile()
				previous = Time.get_ticks_usec()
				striker.linear_velocity = Vector2(1000, 0)
		await process_frame
		var tick: int = Time.get_ticks_usec()
		var elapsed: int = tick - previous
		previous = tick
		times.append(elapsed)
		var profile: Dictionary = runtime.take_profile()
		var force_profile: Dictionary = hud.forces.take_profile()
		hud._record_low_frame(tick, elapsed, profile, force_profile)
		trace.store_line(JSON.stringify({"frame": frame, "frame_us": elapsed,
			"physics_profile": profile, "bodies": scene.world.bodies.size()}))
		physical_pairs += profile.get("contact_pairs", 0)
		max_approach = maxf(max_approach, profile.get("max_approach", 0.0))
		max_contact_impulse = maxf(max_contact_impulse, profile.get("max_contact_impulse", 0.0))
		fragments += profile.get("fragments", 0)
		peak_physics_us = maxi(peak_physics_us, profile.get("physics_us", 0))
		var red_profile: Dictionary = profile.get("rules", {}).get("RedInk", {})
		if profile.has("impacts"):
			print("REAL_IMPACT frame=", frame, " ", profile.impacts)
		red_cells += red_profile.get("reacted_cells", 0)
		if frame >= 240 and red_profile.get("reacted_cells", 0) > 0:
			grenade_reacted = true
		for key in profile:
			if profile[key] is int:
				total_profile[key] = total_profile.get(key, 0) + profile[key]
		for relation in profile.get("fragment_parents", []):
			if cannon_family.has(relation.parent):
				for id in relation.pieces:
					cannon_family[id] = true
		for impulse in profile.get("blast_impulses", []):
			if impulse.body_id == shot.id:
				shot_impulse += impulse.linear[0]
			if impulse.body_id == cannon.id:
				recoil_impulse += impulse.linear[0]
			if cannon_family.has(impulse.body_id) and impulse.linear[0] < -1.0:
				fragment_recoil = true
		launches = launches or (shot_impulse > 0.0 and shot.linear_velocity.x > 50.0)
		recoil = recoil or fragment_recoil
		if frame >= 240:
			var flying: int = 0
			for item in runtime._dust._items:
				var center: Vector2 = item.pos + Vector2(item.shape.local_aabb().get_center()).rotated(item.rot)
				if (center - Vector2(109, 119)).dot(item.vel) > 1.0:
					flying += 1
			outward_visual_fragments = maxi(outward_visual_fragments, flying)
		if capture and DisplayServer.get_name() != "headless" and frame in [36, 246]:
			await RenderingServer.frame_post_draw
			var image: Image = root.get_texture().get_image()
			image.save_png("user://red_cannon.png" if frame == 36 else "user://red_grenade.png")
	trace.close()
	hud._toggle_log()
	times.sort()
	var count: int = maxi(1, ceili(times.size() * 0.01))
	var slow: float = 0.0
	for index in range(times.size() - count, times.size()):
		slow += times[index]
	var low: float = count * 1000000.0 / slow
	var expected_red: int = (fixture_counts.get(8, 0) if not fixture_path.is_empty()
		else (player_bounds.size.x * player_bounds.size.y if player_size else 256)) + 6
	var result: Dictionary = {"rendered": DisplayServer.get_name() != "headless",
		"red_compress_strength": Palette.RED.compress_strength,
		"red_shear_strength": Palette.RED.resolved_shear(),
		"damage_multiplier": runtime.get_node("RedInk").damage_multiplier,
		"impulse_multiplier": runtime.get_node("RedInk").impulse_multiplier,
		"performance_pass": low >= 50.0, "full_charge_consumed": red_cells == expected_red,
		"expected_red_cells": expected_red,
		"fixture": fixture_path, "fixture_materials": fixture_counts,
		"event_chunk_size": runtime.get_node("RedInk").event_chunk_size,
		"player_size": player_size, "red_size": [fixture_bounds.size.x, fixture_bounds.size.y] if not fixture_path.is_empty()
			else ([player_bounds.size.x, player_bounds.size.y] if player_size else [16, 16]),
		"capture_only": capture,
		"frames": times.size(), "low_1pct_fps": low,
		"max_frame_ms": float(times[-1]) / 1000.0,
		"peak_physics_ms": peak_physics_us / 1000.0, "red_cells": red_cells,
		"contact_pairs": physical_pairs, "fragments": fragments,
		"max_approach": max_approach, "max_contact_impulse": max_contact_impulse,
		"shot_blast_impulse_x": shot_impulse, "cannon_blast_impulse_x": recoil_impulse,
		"launch": launches, "cannon_fragment_recoil": recoil, "grenade_reacted": grenade_reacted,
		"outward_visual_fragments": outward_visual_fragments,
		"shot_position": [last_shot_position.x, last_shot_position.y],
		"profile": total_profile, "f1_log": hud.log_path,
		"trace": ProjectSettings.globalize_path("user://" + trace_name + ".jsonl")}
	print("RED_RENDERED_RESULT ", JSON.stringify(result))
	var summary = FileAccess.open("user://" + trace_name + "_summary.json", FileAccess.WRITE)
	summary.store_string(JSON.stringify(result, "\t"))
	summary.close()
	scene.queue_free()
	await process_frame
	quit(0 if launches and recoil and grenade_reacted and outward_visual_fragments > 0
		and (capture or low >= 50.0) else 1)
