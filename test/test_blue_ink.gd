extends SceneTree
## 蓝色端到端回归：画布、物性、供电、燃料与普通红色爆炸边界。
const Palette := preload("res://ink/src/ink_palette.gd")
const Wire := preload("res://actor/blue/src/blue_wire_layer.gd")
const Motor := preload("res://actor/blue/src/blue_motor.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
var checks := 0
var failures := 0
var scene
var canvas
var surface
var rule
var runtime

func _initialize() -> void:
	call_deferred("run")

func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])

func paint(rect: Rect2i, color: Color) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			surface.write_pixel(Vector2i(x, y), color)
	surface.refresh()

func tick() -> Dictionary:
	return rule.resolve_fixed(runtime._context())

func run() -> void:
	scene = load("res://map/asset/imported/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	canvas = scene.get_node("SmallCanvas")
	surface = canvas.surface
	runtime = scene.get_node("SimulationRuntime")
	rule = runtime.get_node("BlueInk")
	canvas.position = Vector2(5000, 5000)
	canvas.canvas_size = Vector2i(240, 160)
	var health = scene.get_node("Player/InkHealth")
	var blue_before: float = health.ink_of(Palette.BLUE.id)
	if "--profile-blue" in OS.get_cmdline_user_args():
		await profile_blue()
		scene.queue_free()
		await process_frame
		quit(0)
		return
	check("blue palette and bottle registered", Palette.ink_count() == 6 and blue_before > 0.0)
	paint(Rect2i(20, 20, 80, 25), Color.BLACK)
	paint(Rect2i(10, 25, 10, 12), Palette.RED.color)
	surface.brush_size = 5
	surface.blue_layer.begin(Vector2(20.5, 30.5))
	surface.blue_layer.extend(Vector2(80.5, 30.5))
	surface.blue_layer.finish()
	var wire_area: int = surface.blue_layer.cells.size()
	check("wire overlay preserves black", wire_area > 0 and surface.material_at(30, 30) == Palette.BLACK.id)
	check("wire charges blue only", health.ink_of(Palette.BLUE.id) == blue_before - wire_area)
	check("wire undo restores overlay and bottle", surface.undo_last_edit() and surface.blue_layer.cells.is_empty() and health.ink_of(Palette.BLUE.id) == blue_before)
	surface.blue_layer.begin(Vector2(20.5, 30.5))
	surface.blue_layer.extend(Vector2(80.5, 30.5))
	surface.blue_layer.finish()
	rule.begin(surface, Vector2(70.5, 30.5))
	check("valid motor submits", rule.finish(surface, Vector2(100.5, 30.5)))
	var motor = rule.objects(Motor)[-1]
	check("arrow start is force anchor", motor.position == surface.to_global(Vector2(70.5, 30.5)))
	var saved_wire_count: int = surface.blue_layer.cells.size()
	surface._begin_undo_step()
	surface._write_pixel(Vector2i(70, 30), Color.TRANSPARENT, 100)
	surface._commit_undo_step()
	check("eraser removes blue black and motor together", not surface.blue_layer.mask.has(Vector2i(70, 30)) and surface.material_at(70, 30) == 0 and rule.objects(Motor).is_empty())
	check("erase undo restores all layers", surface.undo_last_edit() and surface.blue_layer.cells.size() == saved_wire_count and rule.objects(Motor).size() == 1 and surface.material_at(70, 30) == Palette.BLACK.id)
	motor = rule.objects(Motor)[0]
	canvas.generate()
	check("motor activates and wire clears from canvas", motor.active and motor.body != null and surface.blue_layer.cells.is_empty())
	check("one PBody carries black red and wire", rule.objects(Wire).size() == 1 and rule.objects(Wire)[0].body == motor.body and motor.body.shapes[0].pixel_count() == 2120)
	var result := tick()
	check("red contact powers motor from rest", motor.received_power > rule.idle_power and motor.applied_force > 0.0 and motor.body.linear_velocity.x > 0.0)
	check("impulse energy stays inside allocated budget", motor.used_power <= motor.received_power * 1.00001)
	motor.body.linear_velocity = Vector2(-1000, 0)
	tick()
	check("reverse work still costs energy", motor.used_power >= rule.idle_power and motor.applied_force > 0.0)
	motor.body.linear_velocity = Vector2.ZERO
	motor.body.angular_velocity = 0.0
	var saved_source: float = rule.source_power_per_pixel
	rule.source_power_per_pixel = rule.idle_power / 100.0
	tick()
	check("under idle budget burns without thrust", motor.received_power > 0.0 and motor.applied_force == 0.0 and motor.used_power == motor.received_power)
	rule.source_power_per_pixel = saved_source
	var red = runtime.get_node("RedInk")
	rule.energy_per_red_pixel = 1000000.0
	var removed := 0
	for index in 8:
		result = tick()
		if not result.get("fuel_removals", {}).is_empty():
			for body in result.fuel_removals:
				for shape in result.fuel_removals[body]:
					removed += result.fuel_removals[body][shape].size()
			runtime.commit_fuel(scene.world, result.fuel_removals)
	check("batched fuel deletes actual red pixels", removed > 0)
	check("normal fuel consumption never schedules explosion", red._pending.is_empty())
	if not motor.is_queued_for_deletion():
		tick()
		check("burned contact gap stops supply", motor.received_power == 0.0)
	# 离散最宽路径：短细路线与长粗路线并存。
	rule._nodes = [{"capacity": 8.0}, {"capacity": 1.0}, {"capacity": 3.0}, {"capacity": 3.0}, {"capacity": 8.0}]
	var tree: Dictionary = rule.widest_tree([[1, 2], [0, 4], [0, 3], [2, 4], [1, 3]], {0: 8.0})
	check("widest path beats shorter thin route", tree.capacity[4] == 3.0 and tree.parent[4] == 3)
	rule._dirty = true
	# 正常消耗不改变外部破坏引爆行为。
	var red_body = null
	var red_shape = null
	var red_cell := Vector2i.ZERO
	for body in scene.world.bodies:
		for shape in body.shapes:
			var rect: Rect2i = shape.local_aabb()
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					if shape.get_pixel(x, y) == Palette.RED.id:
						red_body = body
						red_shape = shape
						red_cell = Vector2i(x, y)
		if red_body != null:
			break
	if red_body != null:
		runtime.commit(scene.world, {red_body: {red_shape: {red_cell: true}}}, {}, true)
	check("external red destruction still schedules explosion", not red._pending.is_empty())
	red._pending.clear()
	await reset_canvas()
	paint(Rect2i(20, 20, 160, 30), Color.BLACK)
	paint(Rect2i(10, 25, 10, 12), Palette.RED.color)
	surface.blue_layer.begin(Vector2(20.5, 30.5))
	surface.blue_layer.extend(Vector2(170.5, 30.5))
	surface.blue_layer.finish()
	rule.begin(surface, Vector2(120.5, 30.5))
	rule.finish(surface, Vector2(150.5, 30.5))
	var path := "res://.godot/test_blue.snapshot"
	check("blue snapshot saves", surface.save_ink(path) == OK)
	var count: int = surface.blue_layer.cells.size()
	surface.clear()
	check("blue snapshot reloads both kinds", surface.load_ink(path) == OK and surface.blue_layer.cells.size() == count and rule.objects(Motor).size() == 1)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	canvas.generate()
	check("generate undo restores blue draft", surface.undo_last_edit() and surface.blue_layer.cells.size() == count and rule.objects(Wire).is_empty() and not rule.objects(Motor)[0].active)
	canvas.generate()
	await process_frame
	motor = rule.objects(Motor)[0]
	rule.energy_per_red_pixel = 1.0e12
	tick()
	check("regenerated motor resolves saved black anchor", motor.valid(scene.world) and motor.received_power > 0.0)
	canvas.solid.sync_serializable_bodies(scene)
	for object in rule.objects(Wire) + rule.objects(Motor):
		object.sync_pose()
	var packed := PackedScene.new()
	check("active blue scene packs", packed.pack(scene) == OK)
	var reloaded = packed.instantiate()
	reloaded.auto_step = false
	root.add_child(reloaded)
	await process_frame
	await process_frame
	var reloaded_rule = reloaded.get_node("SimulationRuntime/BlueInk")
	var reloaded_runtime = reloaded.get_node("SimulationRuntime")
	reloaded_rule.resolve_fixed(reloaded_runtime._context())
	check("packed roundtrip restores blue carrier and motor power", reloaded_rule.objects(Wire).size() == 1 and reloaded_rule.objects(Motor).size() == 1 and reloaded_rule.objects(Motor)[0].received_power > 0.0)
	reloaded.queue_free()
	await process_frame
	var original_wire = rule.objects(Wire)[0]
	paint(Rect2i(50, 80, 40, 10), Color.BLACK)
	surface.blue_layer.begin(Vector2(50.5, 85.5))
	surface.blue_layer.extend(Vector2(85.5, 85.5))
	surface.blue_layer.finish()
	canvas.generate()
	check("second generation adds independent blue object", rule.objects(Wire).size() == 2)
	surface.undo_last_edit()
	check("undo does not remove older active circuit", rule.objects(Wire).size() == 1 and rule.objects(Wire)[0] == original_wire)
	# 清掉第二笔恢复的草稿，验证回收覆盖蓝黑不会重复扣款。
	surface.clear()
	var before_reclaim: float = health.ink_of(Palette.BLUE.id)
	canvas.return_to_canvas()
	check("reclaim returns blue overlay and motor without refunding bottle", surface.blue_layer.cells.size() == count and not rule.objects(Motor)[0].active and health.ink_of(Palette.BLUE.id) == before_reclaim)
	check("reclaim undo restores active wire and body", surface.undo_last_edit())
	await process_frame
	tick()
	motor = rule.objects(Motor)[0]
	check("reclaimed undo circuit still supplies power", motor.active and motor.received_power > 0.0)
	# 大刚体承受一次横切，蓝色跟随碎片，断线即停机。
	var body = motor.body
	var cut := {}
	for shape in body.shapes:
		for y in range(20, 50):
			for x in range(75, 80):
				if shape.get_pixel(x, y) != 0:
					cut.get_or_add(shape, {})[Vector2i(x, y)] = true
	runtime.commit_fuel(scene.world, {body: cut})
	tick()
	check("fracture migrates surviving motor anchor", motor.valid(scene.world))
	check("cut black also cuts blue supply", motor.received_power == 0.0 and rule.objects(Wire).size() == 2)
	# 平移碎片闭合切口，恢复接触只导电，不合并物理体。
	var motor_body = motor.body
	motor_body.position.x -= 5.0
	motor_body.refresh_com()
	motor_body.update_aabb()
	tick()
	check("touching cut wires reconnect without welding", motor.received_power > 0.0 and rule.objects(Wire)[0].body != rule.objects(Wire)[1].body)
	var anchor_shape = motor.body.shapes[0]
	runtime.commit_fuel(scene.world, {motor.body: {anchor_shape: {motor.cell: true}}})
	check("destroyed black anchor dissolves motor", motor.is_queued_for_deletion())
	await reset_canvas()
	# 只有导线时也要生成低强度实体；同一根线连接两个黑块则联合固化。
	paint(Rect2i(20, 20, 10, 10), Color.BLACK)
	paint(Rect2i(60, 20, 10, 10), Color.BLACK)
	surface.blue_layer.begin(Vector2(25.5, 25.5))
	surface.blue_layer.extend(Vector2(65.5, 25.5))
	surface.blue_layer.finish()
	canvas.generate()
	var connected = rule.objects(Wire)[0]
	check("wire bridge solidifies into one union body", connected.body.shapes[0].get_pixel(45, 25) == Palette.BLUE.id and connected.body.shapes[0].get_pixel(25, 25) == Palette.BLACK.id)
	var mass_before: float = connected.body.mass
	check("overlay adds no duplicate mass", mass_before > 0 and rule.objects(Wire).size() == 1)
	# 蚀除不发分裂通知时，也根据形状版本剔除覆盖像素。
	var erase_cell := Vector2i(25, 25)
	runtime._physics.carve(scene.world, {connected.body: {connected.body.shapes[0]: {erase_cell: true}}})
	tick()
	check("non-fracturing erosion invalidates overlay", rule.objects(Wire).size() == 1 and not rule.objects(Wire)[0].mask.has(erase_cell))
	await reset_canvas()
	await test_slip_ring()
	await reset_canvas()
	await test_power_sharing()
	await reset_canvas()
	await test_partial_reclaim()
	await reset_canvas()
	await test_dynamic_cache()
	if "--preview-blue" in OS.get_cmdline_user_args():
		await preview_blue()
	scene.queue_free()
	await process_frame
	print("BLUE_INK_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func reset_canvas() -> void:
	rule.cancel()
	for object in rule.objects(Motor) + rule.objects(Wire):
		object.queue_free()
	for body in scene.world.bodies.duplicate():
		if body.position.x > 4000.0:
			var index: int = scene.world.bodies.find(body)
			var node = scene._body_nodes[index] if index < scene._body_nodes.size() else null
			if is_instance_valid(node):
				scene.remove_body_node(node)
				node.queue_free()
			else:
				scene.world.remove_body(body)
	surface.clear()
	surface._undo_steps.clear()
	rule._fuel.clear()
	rule._dirty = true
	rule._elapsed = 0.0
	await process_frame

func test_slip_ring() -> void:
	paint(Rect2i(20, 20, 30, 30), Color.BLACK)
	paint(Rect2i(10, 25, 10, 12), Palette.RED.color)
	paint(Rect2i(100, 20, 30, 30), Color.BLACK)
	surface.rod_layer.begin(Vector2(30.5, 30.5))
	surface.rod_layer.finish(Vector2(110.5, 30.5))
	surface.blue_layer.begin(Vector2(20.5, 30.5))
	surface.blue_layer.extend(Vector2(110.5, 30.5))
	surface.blue_layer.finish()
	rule.begin(surface, Vector2(110.5, 26.5))
	rule.finish(surface, Vector2(140.5, 26.5))
	canvas.generate()
	await process_frame
	var hinges: Array = rule.objects(rule.Hinge)
	check("rod and black retain separate bodies and hinges", hinges.size() == 2)
	var wires: Array = rule.objects(Wire)
	check("blue attaches to rod and black without extra PBody", wires.size() == 3)
	# 两侧导线彼此不接触，只在轴的 11px 贴图范围内通过滑环接通。
	for wire in wires:
		var pixels: PackedVector2Array = []
		if wire.carrier_material == Palette.YELLOW.id:
			for x in range(30, 111):
				pixels.append(Vector2(x, 31))
		elif Wire.material_at(wire.body, Vector2i(20, 26)) == Palette.BLACK.id:
			for x in range(20, 34):
				pixels.append(Vector2(x, 26))
		else:
			for x in range(108, 121):
				pixels.append(Vector2(x, 26))
		wire.cells = pixels
		wire.rebuild()
	rule._dirty = true
	var motor = rule.objects(Motor)[0]
	tick()
	check("two-sided full-bearing region supplies wheel motor", motor.received_power > 0.0)
	for hinge in hinges:
		hinge.remove_joint()
		hinge.queue_free()
	tick()
	check("destroyed bearing removes slip ring", motor.received_power == 0.0)

func profile_blue() -> void:
	for length in [200, 1800]:
		await reset_canvas()
		canvas.canvas_size = Vector2i(length + 80, 100)
		surface.ink_free = true
		paint(Rect2i(20, 20, length + 20, 30), Color.BLACK)
		paint(Rect2i(10, 25, 10, 12), Palette.RED.color)
		surface.brush_size = 5
		surface.blue_layer.begin(Vector2(20.5, 30.5))
		surface.blue_layer.extend(Vector2(length + 20.5, 30.5))
		surface.blue_layer.finish()
		rule.begin(surface, Vector2(length + 10.5, 30.5))
		rule.finish(surface, Vector2(length + 40.5, 30.5))
		canvas.generate(false)
		rule.energy_per_red_pixel = 1.0e15
		var start := Time.get_ticks_usec()
		tick()
		var build_us: int = Time.get_ticks_usec() - start
		var samples: Array[int] = []
		for index in 30:
			start = Time.get_ticks_usec()
			tick()
			samples.append(Time.get_ticks_usec() - start)
		samples.sort()
		var wire = rule.objects(Wire)[0]
		var fuel_samples: Array[int] = []
		var reconnect_us := 0
		for batch in 10:
			var body = null
			var edge := -2147483648
			for candidate in scene.world.bodies:
				if candidate.position.x < 4000.0:
					continue
				for shape in candidate.shapes:
					var rect: Rect2i = shape.local_aabb()
					for y in range(rect.position.y, rect.end.y):
						for x in range(rect.position.x, rect.end.x):
							if shape.get_pixel(x, y) == Palette.RED.id and x > edge:
								edge = x
								body = candidate
			if body == null:
				break
			var plan := {}
			for shape in body.shapes:
				for y in range(25, 37):
					if shape.get_pixel(edge, y) == Palette.RED.id:
						plan.get_or_add(shape, {})[Vector2i(edge, y)] = true
			start = Time.get_ticks_usec()
			runtime.commit_fuel(scene.world, {body: plan})
			fuel_samples.append(Time.get_ticks_usec() - start)
			if batch == 0:
				start = Time.get_ticks_usec()
				tick()
				reconnect_us = Time.get_ticks_usec() - start
		fuel_samples.sort()
		print("BLUE_PROFILE pixels=%d first_us=%d tick_median_us=%d tick_p95_us=%d fuel_batches=%d fuel12_median_us=%d fuel12_max_us=%d contact_rebuild_us=%d" % [wire.cells.size(), build_us, samples[15], samples[28], fuel_samples.size(), fuel_samples[fuel_samples.size() / 2], fuel_samples[-1], reconnect_us])

func test_power_sharing() -> void:
	paint(Rect2i(20, 20, 160, 30), Color.BLACK)
	surface.brush_size = 3
	for y in [25.5, 40.5]:
		surface.blue_layer.begin(Vector2(20.5, y))
		surface.blue_layer.extend(Vector2(160.5, y))
		surface.blue_layer.finish()
		rule.begin(surface, Vector2(120.5, y))
		rule.finish(surface, Vector2(150.5, y))
	canvas.generate(false)
	var source := PBody.new()
	source.position = surface.global_position
	source.tags["living"] = true
	source.tags["supply_power"] = 100000000.0
	var shape := Shape.new()
	shape.fill_rect(Rect2i(10, 20, 10, 30), Palette.BLACK.id)
	scene.world.add_body(source, [shape])
	tick()
	var motors: Array = rule.objects(Motor)
	check("living supply divides across independent networks", is_equal_approx(motors[0].received_power, 50000000.0) and is_equal_approx(motors[1].received_power, 50000000.0))
	check("living source does not short networks", rule._circuit.size() == 2)
	var player = scene.get_node("Player")
	var feet = player.get_node("PlayerInput")
	var hand = player.get_node("Arm/Hand/HandControl")
	var old_feet: float = feet.debug_active_power
	var old_hand: float = hand.debug_active_power
	feet.debug_active_power = feet.max_power * 0.25
	hand.debug_active_power = hand.max_power * 0.5
	check("player export subtracts both active movement budgets", is_equal_approx(rule._living_power(player.body, player), feet.max_power * 0.75 + hand.max_power * 0.5))
	feet.debug_active_power = old_feet
	hand.debug_active_power = old_hand
	# 在第一条线路增加一台电机，不改变第二条线路分到的能源。
	var motor := Motor.new()
	motor.position = surface.to_global(Vector2(60.5, 25.5))
	motor.tip = Vector2(20, 0)
	motor.brush_width = 3
	scene.add_child(motor)
	motor.bind(rule.Anchor.find_anchor(scene.world, motor.position))
	motor.owner = scene
	tick()
	check("motors split their network equally without redistribution", is_equal_approx(motors[0].received_power, 25000000.0) and is_equal_approx(motor.received_power, 25000000.0) and is_equal_approx(motors[1].received_power, 50000000.0))
	source.position.x -= 20.0
	source.refresh_com()
	source.update_aabb()
	tick()
	check("lost living contact immediately stops every motor", motor.received_power == 0.0 and motors[0].received_power == 0.0 and motors[1].received_power == 0.0)

func preview_blue() -> void:
	await reset_canvas()
	paint(Rect2i(50, 60, 130, 30), Color.BLACK)
	paint(Rect2i(35, 65, 15, 20), Palette.RED.color)
	surface.brush_size = 5
	var camera := Camera2D.new()
	camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	scene.add_child(camera)
	camera.position = surface.global_position + Vector2(120, 80)
	camera.zoom = Vector2(3, 3)
	camera.make_current()
	camera.force_update_scroll()
	await create_timer(1.0).timeout
	surface.selected_ink = Palette.ink_count() - 1
	surface.tool = surface.Tool.BRUSH
	await drag_canvas(Vector2(50.5, 75.5), Vector2(150.5, 75.5))
	check("windowed mouse brush draws blue wire", surface.blue_layer.mask.has(Vector2i(100, 75)))
	surface.tool = surface.Tool.LINE
	await drag_canvas(Vector2(140.5, 75.5), Vector2(190.5, 75.5))
	check("windowed mouse line creates blue motor", rule.objects(Motor).size() == 1)
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.godot/blue_preview.png")

func test_partial_reclaim() -> void:
	paint(Rect2i(20, 20, 100, 20), Color.BLACK)
	surface.blue_layer.begin(Vector2(25.5, 25.5))
	surface.blue_layer.extend(Vector2(150.5, 25.5))
	surface.blue_layer.finish()
	canvas.generate(false)
	canvas.canvas_size = Vector2i(100, 160)
	canvas.return_to_canvas()
	var outside_survives := false
	for wire in rule.objects(Wire):
		for point in wire.cells:
			if point.x >= 140.0 and Wire.material_at(wire.body, Vector2i(point)) == Palette.BLUE.id:
				outside_survives = true
	check("partial reclaim preserves bare blue outside canvas", outside_survives and not surface.blue_layer.cells.is_empty())
	check("partial reclaim never flattens blue into black image", surface.material_at(80, 25) == Palette.BLACK.id)
	surface.undo_last_edit()
	await process_frame
	check("partial reclaim undo restores full wire", surface.blue_layer.cells.is_empty() and rule.objects(Wire).size() == 1)
	canvas.canvas_size = Vector2i(240, 160)

func drag_canvas(from: Vector2, to: Vector2) -> void:
	var start: Vector2 = surface.get_global_transform_with_canvas() * from
	var end: Vector2 = surface.get_global_transform_with_canvas() * to
	root.warp_mouse(start)
	await process_frame
	var press := InputEventMouseButton.new()
	press.position = start
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	root.push_input(press, true)
	await process_frame
	root.warp_mouse(end)
	await process_frame
	var release := InputEventMouseButton.new()
	release.position = end
	release.button_index = MOUSE_BUTTON_LEFT
	root.push_input(release, true)
	await process_frame


func test_dynamic_cache() -> void:
	paint(Rect2i(20, 20, 160, 30), Color.BLACK)
	paint(Rect2i(10, 25, 10, 12), Palette.RED.color)
	surface.brush_size = 5
	surface.blue_layer.begin(Vector2(20.5, 30.5))
	surface.blue_layer.extend(Vector2(170.5, 30.5))
	surface.blue_layer.finish()
	rule.begin(surface, Vector2(120.5, 30.5))
	rule.finish(surface, Vector2(150.5, 30.5))
	canvas.generate(false)
	var probe := PBody.new()
	probe.position = canvas.position + Vector2(60, 30)
	var shape := Shape.new()
	shape.fill_rect(Rect2i(0, 0, 4, 4), Palette.BLACK.id)
	scene.world.add_body(probe, [shape])
	rule.set_profile_enabled(true)
	tick()
	rule.take_profile()
	probe.position.x += 0.1
	probe.refresh_com()
	probe.update_aabb()
	tick()
	var counters: Dictionary = rule.take_profile()
	check("ordinary nearby motion does not rebuild circuit or scan chunks", counters.get("circuit_rebuilds", 0) == 0 and counters.get("source_chunk_scans", 0) == 0)
	rule.observe_fracture(scene.world, probe, [probe])
	tick()
	counters = rule.take_profile()
	check("irrelevant fracture does not invalidate circuit", counters.get("circuit_rebuilds", 0) == 0)
	probe.tags["living"] = true
	probe.tags["supply_power"] = 100000000.0
	tick()
	counters = rule.take_profile()
	check("new living contact still invalidates circuit immediately", counters.get("circuit_rebuilds", 0) == 1)
	probe.position.x += 0.1
	probe.refresh_com()
	probe.update_aabb()
	tick()
	counters = rule.take_profile()
	check("moving source reuses unchanged red contact pair", counters.get("pair_cache_hits", 0) >= 1 and counters.get("pair_queries", 0) == 1 and counters.get("source_chunk_scans", 0) == 0)
	rule.set_profile_enabled(false)
