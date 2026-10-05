extends "res://test/test_collision_damage.gd"
class ProfileWorld:
	extends "res://addons/pixel_destruction/nodes/pixel_world.gd"
	var sync_us: int = 0
	func sync_world_bodies() -> void:
		var start: int = Time.get_ticks_usec()
		super.sync_world_bodies()
		sync_us += Time.get_ticks_usec() - start
		print("WORLD_SYNC ms=", (Time.get_ticks_usec() - start) / 1000.0)
class ProfileRenderer:
	extends "res://addons/pixel_destruction/render/pixel_renderer.gd"
	var skip_sync: bool = false
	func sync(body) -> void:
		if skip_sync:
			return
		var start: int = Time.get_ticks_usec()
		super.sync(body)
		var elapsed: int = Time.get_ticks_usec() - start
		if elapsed > 1000:
			print("RENDER_SYNC body=", body.id, " static=", body.is_static,
				" ms=", elapsed / 1000.0, " tiles=", last_tiles_rebuilt, "/", last_tiles_total,
				" bounds=", body.shapes[0].local_aabb())
## 磁盘真实画布、固定抓点和180步抬举动作。每项消融单独启动新进程。
class Profile:
	extends "res://map/src/collision_damage.gd"
	var no_damage: bool = false
	var no_contacts: bool = false
	var contact_us: int = 0
	var calculate_us: int = 0
	var step_us: int = 0
	var native_us: int = 0
	var peak_pairs: int = 0
	var commit_us: int = 0
	var commit_calls: int = 0
	var fragments: int = 0
	func commit(world, removals: Dictionary) -> Dictionary:
		var before: int = world.bodies.size()
		var start: int = Time.get_ticks_usec()
		var result: Dictionary = super.commit(world, removals)
		commit_us += Time.get_ticks_usec() - start
		commit_calls += result.calls
		fragments += maxi(0, world.bodies.size() - before)
		print("DAMAGE_COMMIT ms=", (Time.get_ticks_usec() - start) / 1000.0,
			" calls=", result.calls, " new_fragments=", world.bodies.size() - before)
		return result
	func _contacts(world) -> Array:
		var start: int = Time.get_ticks_usec()
		var result: Array = super._contacts(world)
		contact_us += Time.get_ticks_usec() - start
		peak_pairs = maxi(peak_pairs, result.size())
		return result
	func calculate(world, player_body: PBody = null, protected_bodies: Array = []) -> Dictionary:
		native_us += world._rp_cmd_us
		var start: int = Time.get_ticks_usec()
		var result: Dictionary
		if no_contacts:
			result = {"removals": {}, "player_damage": 0.0}
		elif no_damage:
			var contacts: Array = _contacts(world)
			_feet.update_support(contacts)
			_forces.sample_contacts(contacts, _main.fixed_dt / world.last_substeps)
			result = {"removals": {}, "player_damage": 0.0}
		else:
			result = super.calculate(world, player_body, protected_bodies)
		calculate_us += Time.get_ticks_usec() - start
		return result
	func _step(delta: float) -> Dictionary:
		var start: int = Time.get_ticks_usec()
		var result: Dictionary = super._step(delta)
		step_us += Time.get_ticks_usec() - start
		return result

func _run() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	var path: String = "res://test/canvas_capture.tres"
	for arg in args:
		if arg.begins_with("--fixture="):
			path = arg.trim_prefix("--fixture=")
	if not ResourceLoader.exists(path):
		print("BLOCKED: 请先在游戏中 F5 保存真实卡顿画布：", path)
		quit(2)
		return
	var image: Image = ResourceLoader.load(path, "Image", ResourceLoader.CACHE_MODE_IGNORE) as Image
	if image == null or image.is_empty():
		print("BLOCKED: 文件不是 Image .tres")
		quit(2)
		return
	var anchor: Vector2i = Vector2i(image.get_width(), 0)
	var bottom: int = -1
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a > 0.5:
				bottom = maxi(bottom, y)
				if x < anchor.x:
					anchor = Vector2i(x, y)
	if bottom < 0:
		print("BLOCKED: 画布没有墨水")
		quit(2)
		return
	var scene = MAIN.instantiate()
	# 测试子类保留场景导出值，仅包围公开同步入口计时。
	var settings: Dictionary = {}
	for property in scene.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and property.usage & PROPERTY_USAGE_STORAGE:
			settings[property.name] = scene.get(property.name)
	scene.set_script(ProfileWorld)
	for key in settings:
		scene.set(key, settings[key])
	scene.auto_step = false
	# 初始摆放一次：底边在地面上方，最左实体像素中心为抓点，不计入帧耗时。
	scene.get_node("Canvas").position = Vector2(-anchor.x - 0.5, 229 - bottom)
	var point: Vector2 = scene.get_node("Canvas").position + Vector2(anchor) + Vector2(0.5, 0.5)
	scene.get_node("Player").position = point - Vector2(104, 16)
	var controller = scene.get_node("CollisionDamage")
	controller.set_script(Profile)
	controller.no_damage = args.has("--no-damage")
	controller.no_contacts = args.has("--no-contacts")
	root.add_child(scene)
	var hand = scene.get_node("Player/Arm/Hand/HandControl")
	hand.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	controller.set_physics_process(false)
	await process_frame
	await process_frame
	var surface = scene.get_node("Canvas/CanvasSurface")
	if surface.load_ink(path) != OK:
		quit(2)
		return
	var before: int = scene.world.bodies.size()
	var bake: int = Time.get_ticks_usec()
	scene.get_node("Canvas/CanvasSolid").solidify(surface, scene)
	print("BAKE ms=", (Time.get_ticks_usec() - bake) / 1000.0)
	if scene.world.bodies.size() != before + 1:
		print("BLOCKED: 请提供一个连通物体，当前新增体数：", scene.world.bodies.size() - before)
		quit(2)
		return
	var object = scene.world.bodies[-1]
	var render_state: Dictionary = {}
	for property in scene.renderer.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			render_state[property.name] = scene.renderer.get(property.name)
	scene.renderer.set_script(ProfileRenderer)
	for key in render_state:
		scene.renderer.set(key, render_state[key])
	scene.renderer.skip_sync = args.has("--no-sync")
	var no_hand: bool = args.has("--no-hand")
	if not no_hand and not hand._begin_grab(object, point):
		quit(2)
		return
	hand.set_grip(not no_hand)
	scene.world.contact_events_enabled = args.has("--events")
	if args.has("--engine-motion"):
		scene.world.ccd_max_motion = 2.0
	if args.has("--inactive-off"):
		# 核对旧字段是否参与当前Rapier路径；不修改生产配置。
		scene.world.ccd_auto = false
		scene.world.ccd_clamp_motion = false
		scene.world.fill_contact_impulses_enabled = false
	var forces = scene.get_node("HUD/ForceDebug")
	forces.set_physics_process(false)
	forces.enabled = not args.has("--no-debug")
	scene.get_node("HUD").visible = forces.enabled
	scene.auto_render = not args.has("--no-render")
	scene.renderer.visible = scene.auto_render
	if args.has("--one-step"):
		# 只作消融，可能穿透；不是最终修复。
		scene.world.ccd_enabled = false
	print("FLAGS ", {"events": scene.world.contact_events_enabled, "profile": scene.world.profile_enabled,
		"rp_debug": scene.world.rp_debug, "ccd": scene.world.ccd_enabled, "motion": scene.world.ccd_max_motion,
		"ccd_budget": scene.world.ccd_substep_budget, "legacy_grabs": scene.world.grabs.size(),
		"joints": scene.world.joints.size(), "grab_cost_budget_us": scene.world.ccd_grab_substep_cost_budget_us,
		"rp_ccd": scene.world.rp_ccd_substeps, "soft_ccd": scene.world.rp_soft_ccd_prediction,
		"ccd_auto": scene.world.ccd_auto, "clamp": scene.world.ccd_clamp_motion,
		"fill_impulses": scene.world.fill_contact_impulses_enabled,
		"sleep": scene.world.sleeping_enabled, "shading": scene.renderer.shading,
		"debug": forces.enabled, "render": scene.auto_render, "damage": not controller.no_damage,
		"rects": object.rects.size(), "shapes": object.shapes.size(), "pixels": object.shapes[0].pixel_count()})
	var samples: Array[int] = []
	var hand_us: int = 0
	var peak_substeps: int = 0
	var peak_frame: int = 0
	var peak_us: int = 0
	scene.auto_step = true
	for frame in 180:
		if args.has("--live"):
			await physics_frame
		if frame == 60 and args.has("--cut"):
			_cut_probe(scene, object)
		var start: int = Time.get_ticks_usec()
		var native_before: int = controller.native_us
		var commit_before: int = controller.commit_us
		var sync_before: int = scene.sync_us
		forces._physics_process(1.0 / 60.0)
		var offset: Vector2 = Vector2(72, 0 if args.has("--rest") else -80)
		if args.has("--slam"):
			offset = Vector2(100, -100) if frame < 90 else Vector2(60, 144)
		hand.set_target_world(hand.player_body.com_world() + offset)
		var hand_start: int = Time.get_ticks_usec()
		if not no_hand:
			hand._physics_process(1.0 / 60.0)
		hand_us += Time.get_ticks_usec() - hand_start
		if frame == 0:
			var fastest = null
			var speed: float = 0.0
			for body in scene.world.bodies:
				var motion: float = body.linear_velocity.length() + absf(body.angular_velocity) * body.bounding_radius()
				if not body.is_static and body.awake and motion > speed:
					fastest = body
					speed = motion
			print("CCD_DRIVER is_hand=", fastest == hand.body, " speed=", speed,
				" hand_speed=", hand.body.linear_velocity.length(), " object_speed=", object.linear_velocity.length())
		controller._physics_process(1.0 / 60.0)
		samples.append(Time.get_ticks_usec() - start)
		if samples[-1] > peak_us:
			peak_us = samples[-1]
			peak_frame = frame
		if controller.commit_us != commit_before or samples[-1] > 20000:
			print("SPIKE frame=", frame, " ms=", samples[-1] / 1000.0,
				" native_ms=", (controller.native_us - native_before) / 1000.0,
				" commit_ms=", (controller.commit_us - commit_before) / 1000.0,
				" sync_ms=", (scene.sync_us - sync_before) / 1000.0,
				" substeps=", scene.world.last_substeps)
		if args.has("--cut") and frame >= 60 and frame <= 63:
			print("CUT_FRAME frame=", frame, " ms=", samples[-1] / 1000.0,
				" substeps=", scene.world.last_substeps, " bodies=", scene.world.bodies.size())
		peak_substeps = maxi(peak_substeps, scene.world.last_substeps)
		if samples[-1] > 2000000:
			print("STOP: 单步超过2秒，终止复现")
			break
	var total: int = 0
	for value in samples:
		total += value
	samples.sort()
	print("PROFILE args=", args, " frames=", samples.size(), " mean_ms=", total / (1000.0 * samples.size()),
		" p95_ms=", samples[mini(samples.size() - 1, int(samples.size() * 0.95))] / 1000.0,
		" max_ms=", samples[-1] / 1000.0, " max_substeps=", peak_substeps,
		" hand_ms=", hand_us / 1000.0, " step_ms=", controller.step_us / 1000.0,
		" native_push_solve_read_ms=", controller.native_us / 1000.0,
		" calculate_ms=", controller.calculate_us / 1000.0, " contacts_ms=", controller.contact_us / 1000.0,
		" peak_pairs=", controller.peak_pairs, " peak_frame=", peak_frame,
		" commit_ms=", controller.commit_us / 1000.0, " commit_calls=", controller.commit_calls,
		" new_fragments=", controller.fragments)
	scene.auto_step = false
	hand._release_grab()
	hand._remove_arm()
	_release(scene.world)
	scene.queue_free()
	await process_frame
	quit()


## 同一真实形状中线切断；独立测算法，再走公开接口。准备掩码不计入阶段耗时。
func _cut_probe(scene, object) -> void:
	var shape = object.shapes[0]
	var bounds: Rect2i = shape.local_aabb()
	var copy = Shape.new()
	var mask: Dictionary = {}
	var cut_x: int = bounds.position.x + bounds.size.x / 2
	for y in range(bounds.position.y, bounds.end.y):
		for x in range(bounds.position.x, bounds.end.x):
			var material: int = shape.get_pixel(x, y)
			if material == 0:
				continue
			if x == cut_x:
				mask[Vector2i(x, y)] = true
			else:
				copy.set_pixel(x, y, material)
	var start: int = Time.get_ticks_usec()
	var parts: Array = preload("res://addons/pixel_destruction/core/destruction.gd").split(copy, 1)
	var split_us: int = Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	for part in parts:
		preload("res://addons/pixel_destruction/core/mass_props.gd").compute(part, scene.world.density_callable())
	var mass_us: int = Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	for part in parts:
		preload("res://addons/pixel_destruction/core/greedy_rects.gd").decompose(part)
	var rect_us: int = Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	var result: Dictionary = scene.world.fracture_pixels(object, {shape: mask}, 0.0)
	var fracture_us: int = Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	if result.body_alive:
		scene.world.refresh_mass(object)
	var refresh_us: int = Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	scene.sync_world_bodies()
	var render_us: int = Time.get_ticks_usec() - start
	print("CUT split_ms=", split_us / 1000.0, " mass_ms=", mass_us / 1000.0,
		" greedy_ms=", rect_us / 1000.0, " fracture_api_ms=", fracture_us / 1000.0,
		" extra_refresh_ms=", refresh_us / 1000.0, " sync_ms=", render_us / 1000.0,
		" removed=", result.removed, " fragments=", result.fragments.size(), " parts=", parts.size())
