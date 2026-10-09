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
class ProfileForces:
	extends "res://debug/hud/src/force_debug.gd"
	var sample_us: int = 0
	var finish_us: int = 0
	var draw_us: int = 0
	func sample_contacts(contacts: Array, delta: float) -> void:
		var start: int = Time.get_ticks_usec()
		super.sample_contacts(contacts, delta)
		sample_us += Time.get_ticks_usec() - start
	func finish(delta: float) -> void:
		var start: int = Time.get_ticks_usec()
		super.finish(delta)
		finish_us += Time.get_ticks_usec() - start
	func _draw() -> void:
		var start: int = Time.get_ticks_usec()
		super._draw()
		draw_us += Time.get_ticks_usec() - start
## 磁盘真实画布、固定抓点和180步抬举动作。每项消融单独启动新进程。
class Profile:
	extends "res://map/src/simulation_runtime.gd"
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
	var physics_us: int = 0
	var physics_calls: int = 0
	func _physics_process(delta: float) -> void:
		var start: int = Time.get_ticks_usec()
		super._physics_process(delta)
		physics_us += Time.get_ticks_usec() - start
		physics_calls += 1
	## 统计协调层提交破坏所花时间，并保持与正式接口完全相同的签名。
	func commit(world, removals: Dictionary, bursts: Dictionary = {},
			defer_dust: bool = false) -> Dictionary:
		var before: int = world.bodies.size()
		var start: int = Time.get_ticks_usec()
		var result: Dictionary = super.commit(world, removals, bursts, defer_dust)
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
	var probe_enabled: bool = args.has("--transport")
	if probe_enabled:
		var extension_status: int = GDExtensionManager.load_extension("res://test/transport_probe/probe.gdextension")
		if extension_status != GDExtensionManager.LOAD_STATUS_OK and extension_status != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
			print("BLOCKED: 通信计时扩展加载失败 ", extension_status)
			quit(2)
			return
	var path: String = "res://test/canvas_capture.tres"
	var frame_count: int = 180
	for arg in args:
		if arg.begins_with("--fixture="):
			path = arg.trim_prefix("--fixture=")
		elif arg.begins_with("--frames="):
			frame_count = maxi(100, int(arg.trim_prefix("--frames=")))
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
	var left: int = image.get_width()
	var right: int = -1
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a > 0.5:
				bottom = maxi(bottom, y)
				left = mini(left, x)
				right = maxi(right, x)
				if x < anchor.x:
					anchor = Vector2i(x, y)
	if bottom < 0:
		print("BLOCKED: 画布没有墨水")
		quit(2)
		return
	if args.has("--bottom"):
		# 选择靠近底部中央的外边界像素；不把抓点放进内部空洞。
		var target: Vector2 = Vector2((left + right) * 0.5, bottom - 3)
		var best: float = INF
		for y in range(maxi(0, bottom - 12), bottom + 1):
			for x in range(left, right + 1):
				if image.get_pixel(x, y).a <= 0.5 or (y < bottom and image.get_pixel(x, y + 1).a > 0.5):
					continue
				var distance: float = Vector2(x, y).distance_squared_to(target)
				if distance < best:
					best = distance
					anchor = Vector2i(x, y)
	print("FIXTURE size=", image.get_size(), " anchor=", anchor, " bottom=", bottom, " bottom_grip=", args.has("--bottom"))
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
	scene.get_node("SmallCanvas").position = Vector2((200 if args.has("--bottom") else 0) - anchor.x - 0.5, 229 - bottom)
	var point: Vector2 = scene.get_node("SmallCanvas").position + Vector2(anchor) + Vector2(0.5, 0.5)
	scene.get_node("Player").position = point - Vector2(104, 40 if args.has("--bottom") else 16)
	var controller = scene.get_node("SimulationRuntime")
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
	if probe_enabled:
		# 更换同一对象的计时副本，保留刚体、关节与材质表；实例尚未创建原生世界。
		var world_state: Dictionary = {}
		for property in scene.world.get_property_list():
			if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
				world_state[property.name] = scene.world.get(property.name)
		scene.world.set_script(load("res://test/transport_probe/pworld_probe.gd"))
		for key in world_state:
			scene.world.set(key, world_state[key])
		# 消融仅用于归因，禁止作为生产修复：会留下过期的游戏侧包围盒。
		scene.world.transport_skip_aabb = args.has("--probe-no-aabb")
	var surface = scene.get_node("SmallCanvas/CanvasSurface")
	if surface.load_ink(path) != OK:
		quit(2)
		return
	var before: int = scene.world.bodies.size()
	var bake: int = Time.get_ticks_usec()
	scene.get_node("SmallCanvas/CanvasSolid").solidify(surface, scene)
	print("BAKE ms=", (Time.get_ticks_usec() - bake) / 1000.0)
	if scene.world.bodies.size() == before:
		print("BLOCKED: 固化没有生成物体")
		quit(2)
		return
	var object = scene.world.bodies[-1]
	var bottom_object = null
	for index in range(before, scene.world.bodies.size()):
		var candidate = scene.world.bodies[index]
		if candidate.mass > object.mass:
			object = candidate
		var local_point: Vector2 = candidate.to_local(point)
		if candidate.shapes[0].get_pixel(floori(local_point.x), floori(local_point.y)) != 0:
			bottom_object = candidate
	if args.has("--bottom") and not args.has("--largest") and bottom_object != null:
		object = bottom_object
	if args.has("--bottom"):
		# 保留全部连通部分；抓绘图最下方的承托部分，不自动换成上方最大物块。
		var shape = object.shapes[0]
		var bounds: Rect2i = shape.local_aabb()
		var target: Vector2 = Vector2(bounds.get_center().x, bounds.end.y - 4)
		var best: float = INF
		for y in range(maxi(bounds.position.y, bounds.end.y - 12), bounds.end.y):
			for x in range(bounds.position.x, bounds.end.x):
				if shape.get_pixel(x, y) == 0 or shape.get_pixel(x, y + 1) != 0:
					continue
				var distance: float = Vector2(x, y).distance_squared_to(target)
				if distance < best:
					best = distance
					point = object.position + Vector2(x + 0.5, y + 0.5)
		hand.player_body.position = point - Vector2(104, 40)
		hand.player_body.refresh_com()
		hand.player_body.update_aabb()
	print("SELECT components=", scene.world.bodies.size() - before, " selected_pixels=", object.shapes[0].pixel_count(), " point=", point)
	var render_state: Dictionary = {}
	for property in scene.renderer.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			render_state[property.name] = scene.renderer.get(property.name)
	scene.renderer.set_script(ProfileRenderer)
	for key in render_state:
		scene.renderer.set(key, render_state[key])
	scene.renderer.skip_sync = args.has("--no-sync")
	var no_hand: bool = args.has("--no-hand")
	hand.set_rotation_mode(args.has("--rotate"))
	if args.has("--bottom"):
		# 真实指尖贴到抓点再建 Joint，避免用身体外的远端锚点模拟抓取。
		hand._remove_arm()
		var direction: Vector2 = (point - hand.player_body.com_world()).normalized()
		hand.body.rotation = direction.angle()
		hand.body.position = point - (hand.FINGERTIP + hand.body.local_com).rotated(hand.body.rotation)
		hand.body.refresh_com()
		hand.body.update_aabb()
		hand._ensure_arm_joint()
		print("GRIP tip_error=", (hand.body.com_world() + hand.FINGERTIP.rotated(hand.body.rotation)).distance_to(point),
			" object_mass=", object.mass, " player_mass=", hand.player_body.mass)
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
	var forces = scene.get_node("debugHUD/ForceDebug")
	var force_state: Dictionary = {}
	for property in forces.get_property_list():
		if property.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			force_state[property.name] = forces.get(property.name)
	forces.set_script(ProfileForces)
	for key in force_state:
		forces.set(key, force_state[key])
	forces.set_physics_process(false)
	forces.enabled = not args.has("--no-debug")
	scene.get_node("debugHUD").visible = forces.enabled
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
	var wall_samples: Array[int] = []
	var previous_frame: int = Time.get_ticks_usec()
	var frame_rows: Array = []
	var initial_object_com: Vector2 = object.com_world()
	var peak_lift: float = 0.0
	var native_previous: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	var prepared_cut: Dictionary = {}
	if args.has("--runtime-cut"):
		# 掩码准备在采样前，断裂与同步在第 60 帧执行，避免诊断副本污染 Low。
		var shape = object.shapes[0]
		var bounds: Rect2i = shape.local_aabb()
		var cut_x: int = bounds.get_center().x
		var mask: Dictionary = {}
		for y in range(bounds.position.y, bounds.end.y):
			if shape.get_pixel(cut_x, y) != 0:
				mask[Vector2i(cut_x, y)] = true
		prepared_cut[shape] = mask
	scene.auto_step = true
	var runtime: bool = args.has("--rendered")
	print("DISPLAY window=", DisplayServer.window_get_size(), " viewport=", root.size, " mode=", DisplayServer.window_get_mode(), " runtime=", runtime)
	if runtime:
		# 实际游戏物理调度：低帧时保留引擎的追帧行为，不按渲染帧手动推进一次。
		controller.set_physics_process(true)
		hand.set_physics_process(not no_hand)
		forces.set_physics_process(true)
	for frame in frame_count:
		# 真正切断与同步计入帧耗时；副本上的算法诊断不属于游戏工作量。
		var cut_us: int = _cut_probe(scene, object) if frame == 60 and args.has("--cut") else 0
		if frame == 60 and args.has("--runtime-cut"):
			var cut_start: int = Time.get_ticks_usec()
			var cut_result: Dictionary = scene.world.fracture_pixels(object, prepared_cut, 0.0, true)
			var fracture_us: int = Time.get_ticks_usec() - cut_start
			scene.sync_world_bodies()
			cut_us = Time.get_ticks_usec() - cut_start
			print("RUNTIME_CUT frame=", frame, " fracture_ms=", fracture_us / 1000.0,
				" fracture_sync_ms=", cut_us / 1000.0, " fragments=", cut_result.fragments.size(), " removed=", cut_result.removed)
		var start: int = Time.get_ticks_usec()
		var native_before: int = controller.native_us
		var commit_before: int = controller.commit_us
		var sync_before: int = scene.sync_us
		var aabb_before: int = scene.world.transport_aabb_us if probe_enabled else 0
		var call_before: int = scene.world.transport_call_us if probe_enabled else 0
		var physics_before: int = controller.physics_us
		var calculate_before: int = controller.calculate_us
		var contacts_before: int = controller.contact_us
		var physics_calls_before: int = controller.physics_calls
		var force_sample_before: int = forces.sample_us
		if not runtime:
			forces._physics_process(1.0 / 60.0)
		var offset: Vector2 = Vector2(72, 0 if args.has("--rest") else -80)
		if args.has("--high-lift"):
			offset = Vector2(72, -240)
		if args.has("--slam"):
			offset = Vector2(100, -240 if args.has("--high-lift") else -100) if frame % 180 < 90 else Vector2(60, 144)
		hand.set_target_world(hand.player_body.com_world() + offset)
		var hand_start: int = Time.get_ticks_usec()
		if not no_hand and not runtime:
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
		if runtime:
			await process_frame
			var tick: int = Time.get_ticks_usec()
			if previous_frame > 0:
				wall_samples.append(tick - previous_frame)
			previous_frame = tick
		elif args.has("--live"):
			await physics_frame
		if not runtime:
			controller._physics_process(1.0 / 60.0)
		samples.append((controller.physics_us - physics_before if runtime else Time.get_ticks_usec() - start) + cut_us)
		peak_lift = maxf(peak_lift, initial_object_com.y - object.com_world().y)
		var native_delta: Array = []
		if probe_enabled:
			var snapshot: PackedByteArray = scene.world._rp_send(PackedByteArray([44]), 64)
			for index in 8:
				var value: float = snapshot.decode_double(4 + index * 8)
				native_delta.append(value - native_previous[index])
				native_previous[index] = value
		frame_rows.append({"frame": frame, "cpu_us": samples[-1], "substeps": scene.world.last_substeps,
			"physics_calls": controller.physics_calls - physics_calls_before,
			"calculate_us": controller.calculate_us - calculate_before, "contacts_us": controller.contact_us - contacts_before,
			"force_sample_us": forces.sample_us - force_sample_before,
			"native_ns_counts": native_delta,
			"prepare_call_decode_aabb_us": controller.native_us - native_before,
			"commit_us": controller.commit_us - commit_before, "sync_us": scene.sync_us - sync_before,
			"aabb_us": scene.world.transport_aabb_us - aabb_before if probe_enabled else 0,
			"native_call_us": scene.world.transport_call_us - call_before if probe_enabled else 0,
			"bodies": scene.world.bodies.size(), "object_position": str(object.position)})
		if args.has("--capture") and frame == 30:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://test/bottom_grip_preview.png")
		if samples[-1] > peak_us:
			peak_us = samples[-1]
			peak_frame = frame
		if controller.commit_us != commit_before or samples[-1] > 20000:
			print("SPIKE frame=", frame, " ms=", samples[-1] / 1000.0,
				" gd_prepare_call_decode_aabb_ms=", (controller.native_us - native_before) / 1000.0,
				" commit_ms=", (controller.commit_us - commit_before) / 1000.0,
				" sync_ms=", (scene.sync_us - sync_before) / 1000.0,
				" aabb_ms=", (scene.world.transport_aabb_us - aabb_before) / 1000.0 if probe_enabled else 0.0,
				" native_call_ms=", (scene.world.transport_call_us - call_before) / 1000.0 if probe_enabled else 0.0,
				" rapier_ms=", native_delta[1] / 1e6 if probe_enabled else 0.0,
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
	_print_low("CPU_WORK", samples)
	if not wall_samples.is_empty():
		_print_low("RENDER_WALL", wall_samples)
	if args.has("--dump-frames"):
		var output = FileAccess.open("res://test/bottom_grip_frames.json", FileAccess.WRITE)
		output.store_string(JSON.stringify({"args": args, "frames": frame_rows, "wall_us": wall_samples}))
	print("PROFILE args=", args, " frames=", samples.size(), " mean_ms=", total / (1000.0 * samples.size()),
		" p95_ms=", samples[mini(samples.size() - 1, int(samples.size() * 0.95))] / 1000.0,
		" max_ms=", samples[-1] / 1000.0, " max_substeps=", peak_substeps,
		" hand_ms=", hand_us / 1000.0, " step_ms=", controller.step_us / 1000.0,
		" gd_prepare_call_decode_aabb_ms=", controller.native_us / 1000.0,
		" calculate_ms=", controller.calculate_us / 1000.0, " contacts_ms=", controller.contact_us / 1000.0,
		" peak_pairs=", controller.peak_pairs, " peak_frame=", peak_frame,
		" commit_ms=", controller.commit_us / 1000.0, " commit_calls=", controller.commit_calls,
		" force_sample_ms=", forces.sample_us / 1000.0, " force_finish_ms=", forces.finish_us / 1000.0,
		" force_draw_ms=", forces.draw_us / 1000.0,
		" new_fragments=", controller.fragments)
	print("FINAL_STATE object=", object.position, " player=", hand.player_body.position,
		" initial_object_com=", initial_object_com, " final_object_com=", object.com_world(), " peak_lift_px=", peak_lift,
		" object_velocity=", object.linear_velocity, " player_velocity=", hand.player_body.linear_velocity,
		" bodies=", scene.world.bodies.size())
	if probe_enabled:
		var native: PackedByteArray = scene.world._rp_send(PackedByteArray([43]), 64)
		var stats: Array = []
		for index in 8:
			stats.append(native.decode_double(4 + index * 8))
		print("TRANSPORT frames=", samples.size(), " gd_commands_ms=", scene.world.transport_command_us / 1000.0,
			" gd_decode_ms=", scene.world.transport_decode_us / 1000.0,
			" gd_header_ms=", scene.world.transport_header_us / 1000.0,
			" gd_aabb_ms=", scene.world.transport_aabb_us / 1000.0,
			" gd_ccd_ms=", scene.world.transport_ccd_us / 1000.0,
			" aabb_rect_visits=", scene.world.transport_aabb_rects,
			" gd_call_ms=", scene.world.transport_call_us / 1000.0,
			" native_callback_ms=", stats[0] / 1e6, " rapier_pipeline_ms=", stats[1] / 1e6,
			" native_colliders_ms=", stats[2] / 1e6, " native_contacts_ms=", stats[3] / 1e6,
			" native_state_ms=", stats[4] / 1e6, " calls=", stats[5], " substeps=", stats[6],
			" opcodes=", stats[7], " input_bytes=", scene.world.transport_tx_bytes,
			" output_bytes=", scene.world.transport_rx_bytes,
			" final_object_position=", object.position, " final_player_position=", hand.player_body.position)
	scene.auto_step = false
	hand._release_grab()
	hand._remove_arm()
	_release(scene.world)
	scene.queue_free()
	await process_frame
	quit()


## CPU 工作量倒数与真实渲染间隔分开，禁止用前者冒充实际 FPS。
func _print_low(label: String, durations: Array[int]) -> void:
	var sorted: Array[int] = durations.duplicate()
	sorted.sort()
	var count: int = maxi(1, ceili(sorted.size() * 0.01))
	var slow: int = 0
	var total: int = 0
	for value in sorted:
		total += value
	for index in range(sorted.size() - count, sorted.size()):
		slow += sorted[index]
	print("LOW ", label, " samples=", sorted.size(), " avg_fps=", 1e6 * sorted.size() / total,
		" one_percent_low=", 1e6 * count / slow, " p99_ms=", sorted[mini(sorted.size() - 1, floori(sorted.size() * 0.99))] / 1000.0,
		" max_ms=", sorted[-1] / 1000.0)


## 同一真实形状中线切断；独立测算法，再走公开接口。准备掩码不计入阶段耗时。
func _cut_probe(scene, object) -> int:
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
	if result.body_alive and OS.get_cmdline_user_args().has("--legacy-refresh"):
		scene.world.refresh_mass(object)
	var refresh_us: int = Time.get_ticks_usec() - start
	start = Time.get_ticks_usec()
	scene.sync_world_bodies()
	var render_us: int = Time.get_ticks_usec() - start
	print("CUT split_ms=", split_us / 1000.0, " mass_ms=", mass_us / 1000.0,
		" greedy_ms=", rect_us / 1000.0, " fracture_api_ms=", fracture_us / 1000.0,
		" extra_refresh_ms=", refresh_us / 1000.0, " sync_ms=", render_us / 1000.0,
		" removed=", result.removed, " fragments=", result.fragments.size(), " parts=", parts.size())
	return fracture_us + refresh_us + render_us
