extends SceneTree
## 蓝色端到端回归：画布、物性、供电、燃料与普通红色爆炸边界。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
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

func settle(seconds := 0.5) -> void:
	for i in ceili(seconds / scene.fixed_dt):
		var result := tick()
		if not result.get("fuel_removals", {}).is_empty():
			runtime.commit_fuel(scene.world, result.fuel_removals)

func run() -> void:
	scene = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	canvas = scene.get_node("SmallCanvas")
	surface = canvas.surface
	runtime = scene.get_node("SimulationRuntime")
	rule = runtime.get_node("BlueInk")
	rule.energy_per_red_pixel = 1.0e12
	rule.emission_interval = 0.1
	rule.motor_buffer_seconds = 0.2
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
	surface.brush_size = 3
	surface.blue_layer.begin(Vector2(180.5, 120.5))
	surface.blue_layer.extend(Vector2(190.5, 120.5))
	surface.blue_layer.finish()
	var isolated_wire_count: int = surface.blue_layer.cells.size()
	surface._begin_undo_step()
	var isolated_erased: bool = surface.erase_rect(Rect2i(175, 115, 22, 12))
	surface._commit_undo_step()
	check("selection erases blue without black tiles", isolated_erased and surface.blue_layer.cells.is_empty())
	check("selection erase undo restores blue-only wire", surface.undo_last_edit() and surface.blue_layer.cells.size() == isolated_wire_count)
	surface._begin_undo_step()
	surface.erase_rect(Rect2i(175, 115, 22, 12))
	surface._commit_undo_step()
	check("blue-only selection erase refunds bottle", surface.blue_layer.cells.is_empty() and health.ink_of(Palette.BLUE.id) == blue_before)
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
	check("motor waits for propagated energy", motor.received_power == 0.0)
	settle(0.2)
	check("red contact powers motor from rest", motor.received_power > rule.idle_power and motor.applied_force > 0.0 and motor.body.linear_velocity.x > 0.0)
	check("impulse energy stays inside allocated budget", motor.used_power <= motor.received_power * 1.00001)
	motor.body.linear_velocity = Vector2(-1000, 0)
	tick()
	check("reverse work still costs energy", motor.used_power >= rule.idle_power and motor.applied_force > 0.0)
	motor.body.linear_velocity = Vector2.ZERO
	motor.body.angular_velocity = 0.0
	var saved_source: float = rule.source_power_per_pixel
	rule.source_power_per_pixel = rule.idle_power / 100.0
	motor.energy_buffer = 0.0
	rule.flow = rule.EnergyFlow.new()
	settle(0.3)
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
		settle(0.8)
		check("burned contact gap stops supply", motor.received_power == 0.0)
	check("global grid and path search removed", not rule.has_method("_build_graph") and not rule.has_method("widest_tree"))
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
	settle()
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
	for i in 30:
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
	settle()
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
	settle(0.8)
	check("fracture migrates surviving motor anchor", motor.valid(scene.world))
	check("cut black also cuts blue supply", motor.received_power == 0.0 and rule.objects(Wire).size() == 2)
	# 平移碎片闭合切口，恢复接触只导电，不合并物理体。
	var motor_body = motor.body
	motor_body.position.x -= 5.0
	motor_body.refresh_com()
	motor_body.update_aabb()
	settle()
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
	await test_merge_boundary()
	await reset_canvas()
	await test_arrow_surface_and_grip()
	await reset_canvas()
	await test_partial_reclaim()
	await reset_canvas()
	await test_dynamic_cache()
	test_wire_tiles()
	if "--preview-blue" in OS.get_cmdline_user_args():
		await preview_blue()
	scene.queue_free()
	await process_frame
	print("BLUE_INK_RESULT checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func test_wire_tiles() -> void:
	var wire := Wire.new()
	wire.cells = PackedVector2Array([Vector2(-65, -1), Vector2(-1, -1), Vector2(64, 64), Vector2(2048, 2048)])
	root.add_child(wire)
	check("sparse diagonal display allocates occupied tiles only", wire._images.size() == 4 and wire._images.values().all(func(image): return image.get_size() == Vector2i(64, 64)))
	var actual: Color = wire._images[Vector2i(-2, -1)].get_pixel(63, 63)
	var expected: Color = Palette.BLUE.color
	check("negative coordinate tile keeps exact blue pixel", actual.a == 1.0 and absf(actual.r - expected.r) <= 1.0 / 255.0 and absf(actual.g - expected.g) <= 1.0 / 255.0 and absf(actual.b - expected.b) <= 1.0 / 255.0)
	var retained = wire._textures[Vector2i(32, 32)]
	wire.erase(Vector2i(-65, -1), false)
	wire.flush_display()
	check("erase removes empty tile and synchronizes saved cells", not wire._textures.has(Vector2i(-2, -1)) and wire.cells.size() == 3)
	check("local edit preserves distant texture", wire._textures[Vector2i(32, 32)] == retained)
	wire.queue_free()

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
	rule.flow = rule.EnergyFlow.new()
	await process_frame

func test_slip_ring() -> void:
	# 电源放在转子扫掠半径外，避免旋转测试直接穿过红色形成额外接触/短路。
	paint(Rect2i(20, 20, 140, 30), Color.BLACK)
	paint(Rect2i(10, 25, 10, 12), Palette.RED.color)
	paint(Rect2i(210, 20, 30, 30), Color.BLACK)
	surface.rod_layer.begin(Vector2(140.5, 30.5))
	surface.rod_layer.finish(Vector2(235.5, 30.5))
	surface.rod_layer.place_anchor(Vector2(140.5, 30.5))
	surface.rod_layer.place_anchor(Vector2(220.5, 30.5))
	surface.blue_layer.begin(Vector2(20.5, 30.5))
	surface.blue_layer.extend(Vector2(220.5, 30.5))
	surface.blue_layer.finish()
	rule.begin(surface, Vector2(220.5, 26.5))
	rule.finish(surface, Vector2(235.5, 26.5))
	canvas.generate()
	await process_frame
	var hinges: Array = rule.objects(rule.Hinge)
	check("rod and black retain separate bodies and hinges", hinges.size() == 2)
	var wires: Array = rule.objects(Wire)
	check("blue attaches to rod and black without extra PBody", wires.size() == 3)
	# 导线穿过轴承后仍延伸；两侧相距 5px，只能在完整贴图区域通过滑环接通。
	for wire in wires:
		var pixels: PackedVector2Array = []
		if wire.carrier_material == Palette.YELLOW.id:
			for x in range(140, 235):
				pixels.append(Vector2(x, 31))
		elif Wire.material_at(wire.body, Vector2i(20, 26)) == Palette.BLACK.id:
			for x in range(20, 158):
				pixels.append(Vector2(x, 26))
		else:
			for x in range(218, 237):
				pixels.append(Vector2(x, 26))
		wire.cells = pixels
		wire.rebuild()
	var motor = rule.objects(Motor)[0]
	var rod_wire = wires.filter(func(w): return w.carrier_material == Palette.YELLOW.id)[0]
	var rod_cells: PackedVector2Array = rod_wire.cells.duplicate()
	rod_wire.cells = PackedVector2Array()
	rod_wire.rebuild()
	settle(0.8)
	check("one-sided bearing contact supplies no energy", motor.received_power == 0.0 and rule.flow.bridges.is_empty())
	rod_wire.cells = rod_cells
	rod_wire.rebuild()
	settle()
	check("two-sided full-bearing region supplies wheel motor", motor.received_power > 0.0)
	# 围绕左轴同步转动杆与从动黑块，抽查整圈接触姿态；不靠原世界坐标方向输电。
	var source_body = wires.filter(func(w): return w.carrier_material == Palette.BLACK.id and w.body != motor.body)[0].body
	var source_hinge = hinges.filter(func(h): return h.black_anchor.body == source_body)[0]
	var pivot: Vector2 = rule.Anchor.anchor_world(source_hinge.yellow_anchor)
	var poses: Array = []
	for body in [rod_wire.body, motor.body]:
		poses.append([body, body.position, body.rotation])
	var intact_cells: Array = wires.map(func(w): return w.cells.duplicate())
	for angle in [PI * 0.5, PI, PI * 1.5, 0.0]:
		for index in wires.size():
			wires[index].cells = intact_cells[index]
			wires[index].rebuild()
		for pose: Array in poses:
			pose[0].position = pivot + (pose[1] - pivot).rotated(angle)
			pose[0].rotation = pose[2] + angle
		rule.flow = rule.EnergyFlow.new()
		motor.energy_buffer = 0.0
		settle(0.8)
		check("slip ring retains supply at %d degrees" % roundi(rad_to_deg(angle)), motor.received_power > 0.0)
	for hinge in hinges:
		hinge.remove_joint()
		hinge.queue_free()
	settle(1.0)
	check("destroyed bearing removes slip ring", motor.received_power == 0.0)

func profile_blue() -> void:
	print("Use res://test/fixtures/maps/blue_energy_stress.tscn -- --bench --case=chaos")
func test_power_sharing() -> void:
	paint(Rect2i(20, 20, 160, 30), Color.BLACK)
	paint(Rect2i(10, 25, 10, 12), Palette.RED.color)
	surface.brush_size = 7
	surface.blue_layer.begin(Vector2(20.5, 30.5))
	surface.blue_layer.extend(Vector2(170.5, 30.5))
	surface.blue_layer.finish()
	for x in [50, 140]:
		rule.begin(surface, Vector2(x + 0.5, 30.5))
		rule.finish(surface, Vector2(x + 20.5, 30.5))
	canvas.generate(false)
	rule.energy_per_red_pixel = 1.0e15
	var motors: Array = rule.objects(Motor)
	motors[0].brush_width = 1
	settle(0.1)
	check("upstream motor receives first before downstream arrival", motors[0].energy_buffer > 0.0 and motors[1].energy_buffer == 0.0)
	settle(0.5)
	check("unused upstream energy continues to downstream motor", motors[1].received_power > 0.0)
	check("motor buffer remains bounded", motors.all(func(m): return m.energy_buffer <= m.buffer_capacity))
	var emitted: float = rule.flow.stats.injected
	var fed: float = rule.flow.stats.consumed
	check("source prepays packets including travel losses", emitted > 0.0 and emitted >= fed)

func test_merge_boundary() -> void:
	paint(Rect2i(20, 20, 160, 30), Color.BLACK)
	paint(Rect2i(95, 40, 4, 4), Palette.RED.color)
	surface.brush_size = 3
	surface.blue_layer.begin(Vector2(20.5, 30.5))
	surface.blue_layer.extend(Vector2(170.5, 30.5))
	surface.blue_layer.finish()
	canvas.generate(false)
	var wire = rule.objects(Wire)[0]
	var body = wire.body
	var velocity: Vector2 = body.linear_velocity
	rule.flow.inject(wire, Vector2i(70, 30), 1, 100.0)
	rule.flow.inject(wire, Vector2i(130, 30), 0, 100.0)
	settle(0.2)
	check("opposed flow preserves blue black and nearby red", wire.mask.has(Vector2i(100, 30)) and body.shapes[0].get_pixel(100, 30) == Palette.BLACK.id and body.shapes[0].get_pixel(95, 40) == Palette.RED.id)
	check("opposed flow produces neither explosion nor physical impulse", scene.get_node("SimulationRuntime/RedInk")._pending.is_empty() and body.linear_velocity == velocity)

func test_arrow_surface_and_grip() -> void:
	paint(Rect2i(20, 20, 180, 60), Color.BLACK)
	surface.brush_size = 5
	rule.begin(surface, Vector2(18.5, 40.5))
	check("arrow start snaps onto nearby black", rule.drawing != null and rule.drawing.position.x >= surface.global_position.x + 20.0)
	rule.cancel()
	rule.begin(surface, Vector2(40.5, 40.5))
	rule.finish(surface, Vector2(230.5, 40.5))
	var draft = rule.objects(Motor)[0]
	check("whole arrow clips to black including head", draft.position.x + draft.tip.x < surface.global_position.x + 201.0)
	rule.clear_drafts(surface)
	await process_frame
	rule.begin(surface, Vector2(60.5, 40.5))
	rule.finish(surface, Vector2(120.5, 40.5))
	surface.blue_layer.begin(Vector2(20.5, 40.5))
	surface.blue_layer.extend(Vector2(160.5, 40.5))
	surface.blue_layer.finish()
	canvas.generate(false)
	var motor = rule.objects(Motor)[0]
	var player = scene.get_node("Player")
	var hand = player.get_node("Arm/Hand/HandControl")
	var wire = rule.objects(Wire)[0]
	# 直接把手靠在导线上也不应供能；只有真实有效的抓握关节才打开端口。
	hand.body.position += wire.body.to_world(Vector2(30.5, 40.5)) - hand.body.com_world()
	settle(0.3)
	check("touch without grip never supplies biological power", rule.flow.stats.injected == 0.0 and motor.received_power == 0.0)
	check("grip fixture creates real joint", hand._begin_grab(wire.body, wire.body.to_world(Vector2(30.5, 40.5))))
	settle(0.5)
	check("gripping wire supplies marked biological energy", motor.received_power > 0.0 and motor.biological_energy > 0.0)
	var weight: float = (player.body.mass + player.get_node("Arm").body.mass + hand.body.mass) * scene.world.gravity.length()
	check("biological thrust cannot lift the player", motor.applied_force <= weight * 0.5)
	var bio_motors: Array = [motor]
	for i in 3:
		var extra := Motor.new()
		extra.position = motor.position
		extra.tip = motor.tip
		extra.brush_width = motor.brush_width
		scene.add_child(extra)
		extra.bind(rule.Anchor.find_anchor(scene.world, extra.position))
		bio_motors.append(extra)
	for engine in bio_motors:
		engine.buffer_capacity = engine.power_limit(rule.power_per_width) * rule.motor_buffer_seconds
		engine.receive_energy(engine.buffer_capacity, engine.buffer_capacity)
	tick()
	var total_force := 0.0
	for engine in bio_motors:
		total_force += engine.applied_force
	check("stacking biological motors shares one sub-weight thrust ceiling", total_force > 0.0 and total_force <= weight * 0.5 + 0.01)
	hand._release_grab()
	settle(0.8)
	check("release stops biological supply and expires buffer", motor.received_power == 0.0 and motor.biological_energy == 0.0)
	var tiny := Motor.new()
	tiny.tip = Vector2(10, 0)
	tiny.brush_width = 5
	check("small arrow has reduced force and power ceiling", tiny.power_limit(rule.power_per_width) < 4000000.0)
	tiny.free()
	var at := Vector2i(95, 40)
	runtime._physics.carve(scene.world, {motor.body: {motor.body.shapes[0]: {at: true}}})
	tick()
	check("losing a non-anchor arrow pixel dissolves the whole motor", motor.is_queued_for_deletion())

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
	check("new flow keeps no grid/path cache", not rule.has_method("_topology_stamp") and not rule.has_method("_rebuild_circuit"))
