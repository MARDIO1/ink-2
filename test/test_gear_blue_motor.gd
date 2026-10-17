extends SceneTree
## 地图齿轮 + 蓝墨：轮体必须能挂导线，箭头必须绑在轮体上并能对它施加力矩。

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Bearing := preload("res://actor/canvas/src/gear_bearing.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
var failures := 0
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[GearBlue] %s %s" % ["PASS" if ok else "FAIL", label])


func wires_on(rule, body) -> Array:
	var result := []
	for wire in rule.objects(Wire):
		if wire.body == body:
			result.append(wire)
	return result


func nearest_cell(wire, body, point: Vector2) -> float:
	var best := INF
	for cell in wire.cells:
		best = minf(best, body.to_world(cell + Vector2.ONE * 0.5).distance_to(point))
	return best


func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var canvas = level.get_node("MapCanvas")
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	var camera = level.get_node("SimulationRuntime/PhysicsStep")._camera
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.global_position = canvas.global_position + Vector2(128, 128)
	camera.reset_smoothing()
	camera.force_update_scroll()
	var surface = canvas.surface
	surface.ink_free = true
	surface.selected_ink = 0
	canvas.set_map_editor_mode(true)
	creative.active = true
	creative._ensure_editor_resources()
	var rule = surface.blue_rule()
	check("blue rule available", rule != null)

	# 黑色支座横条 + 一颗压在上面的齿轮。
	for y in range(96, 145):
		for x in range(60, 201):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	surface.write_pixel(Vector2i(65, 100), surface.nail_color())
	var tool = surface.gear_tool
	tool.begin(Vector2(120, 120))
	var bearing = tool.finish(Vector2(145.5, 120.5))
	check("gear placed on the bar", bearing != null)
	if bearing == null:
		quit(1)
		return

	# 蓝线从支座横穿齿轮；箭头画在轮体上。
	surface.brush_size = 1
	surface.blue_layer.begin(Vector2(70.5, 120.5))
	surface.blue_layer.extend(Vector2(175.5, 120.5))
	surface.blue_layer.finish()
	surface.blue_layer.begin(Vector2(120.5, 120.5))
	surface.blue_layer.extend(Vector2(120.5, 112.5))
	surface.blue_layer.finish()
	# 箭头整个足迹都必须落在轮体上，所以贴着轴心放、别碰到轮缘。
	surface.brush_size = 5
	rule.begin(surface, Vector2(110, 112))
	var arrow_drawn: bool = rule.finish(surface, Vector2(124, 112))
	check("arrow drawn on the wheel", arrow_drawn)

	canvas.generate(false)
	await process_frame

	var wheel = bearing.yellow_anchor.body
	var support = bearing.black_anchor.get("body")
	var axle: Vector2 = bearing.yellow_position
	check("gear keeps a support after solidify", support != null and support != wheel)

	var wheel_wires := wires_on(rule, wheel)
	var support_wires := wires_on(rule, support) if support != null else []
	check("wheel body owns a blue wire", not wheel_wires.is_empty())
	check("support body owns a blue wire", not support_wires.is_empty())
	if not wheel_wires.is_empty():
		check("wheel wire reaches the axle for the slip ring",
			nearest_cell(wheel_wires[0], wheel, axle) <= 7.0)
	if not support_wires.is_empty() and support != null:
		check("support wire reaches the axle for the slip ring",
			nearest_cell(support_wires[0], support, axle) <= 7.0)
	# 滑环在每固定步重算，跑一步之后再查。
	level.get_node("SimulationRuntime")._step(1.0 / 120.0)
	check("slip ring bridges wheel and support", not rule.flow.bridges.is_empty())
	surface.brush_size = 1
	surface.blue_layer.begin(Vector2(120.5, 112.5))
	surface.blue_layer.extend(Vector2(120.5, 102.5))
	surface.blue_layer.finish()
	canvas.generate(false)
	check("adding a gear branch preserves the existing wire", wires_on(rule, wheel).size() == 1
		and wires_on(rule, wheel)[0] == wheel_wires[0])
	check("added gear branch becomes active instead of disappearing", wheel_wires[0].mask.has(
		Vector2i(wheel.to_local(surface.to_global(Vector2(120.5, 102.5))).floor())))

	var motors: Array = rule.objects(Motor)
	check("exactly one motor survived solidify", motors.size() == 1)
	if motors.is_empty():
		print("GEAR_BLUE motors=0")
		level.queue_free()
		await process_frame
		print("[GearBlue] %d checks, %d failures" % [checks, failures])
		quit(1 if failures else 0)
		return
	var motor = motors[0]
	check("motor is bound to the wheel, not the support", motor.body == wheel)
	# 模拟旧存档：支架导线首格与齿轮重叠，载体路径缺失。
	var original_wire = support_wires[0]
	var legacy := Wire.new()
	legacy.active = true
	legacy.position = original_wire.position + Vector2(3, 0)
	legacy.rotation = original_wire.rotation
	legacy.cells = PackedVector2Array([Vector2(support.to_local(axle).floor())])
	legacy.cells.append_array(original_wire.cells)
	for index in legacy.cells.size():
		legacy.cells[index] -= Vector2(3, 0)
	level.add_child(legacy)
	await process_frame
	check("legacy support wire restores to support despite overlapping first cell", is_instance_valid(legacy)
		and not legacy.is_queued_for_deletion() and legacy.body == support)
	check("restored wire remembers its carrier path", not legacy.carrier_path.is_empty()
		and legacy.get_node(legacy.carrier_path).body == support)
	check("restored wire remaps cells without shifting the circuit", legacy.mask.has(Vector2i(support.to_local(axle).floor())))
	legacy.queue_free()
	await process_frame
	var player = level.get_node("Player")
	var hand = player.get_node("Arm/Hand/HandControl")
	var grip_point: Vector2 = canvas.surface.to_global(Vector2(75.5, 120.5))
	player.teleport_to(grip_point + Vector2(-40, 0), 0)
	hand.body.position += grip_point - hand.body.com_world()
	check("real hand grips powered support wire", hand._begin_grab(support, grip_point))
	var start_angle: float = wheel.rotation
	var peak_power := 0.0
	for tick in 360:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
		peak_power = maxf(peak_power, motor.received_power)
	check("grip power travels through support and axle to motor", peak_power > 0.0)
	check("real grip power rotates wheel without buffer injection", absf(wheel.rotation - start_angle) > 0.01)
	print("GEAR_GRIP peak_power=", peak_power, " rotation=", wheel.rotation - start_angle)
	hand._release_grab()

	# 能源注入走的是 energy_flow 收能量时用的同一个缓冲；这里只验证力矩确实落在轮体上。
	var before: float = wheel.angular_velocity
	for tick in 120:
		motor.energy_buffer = 1.0e9
		motor.buffer_age = 0.0
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
	check("motor applies torque to the wheel", absf(wheel.angular_velocity - before) > 0.5)
	# 无草稿副本的轮体移到空白处后，蓝墨仍按真实位置采样。
	bearing.begin_editor_drag()
	bearing.move_editor_drag(canvas.surface.to_global(Vector2(120.5, 45.5)))
	bearing.finish_editor_drag()
	check("moved wheel leaves no old draft silhouette", surface.material_at(120, 120) == 0)
	rule.begin(surface, Vector2(110, 40))
	check("blue arrow can be drawn on a moved wheel over blank canvas", rule.finish(surface, Vector2(124, 40)))
	tool.begin(Vector2(210, 50))
	var isolated = tool.finish(Vector2(230.5, 50.5))
	surface.brush_size = 1
	surface.blue_layer.begin(Vector2(200.5, 50.5))
	surface.blue_layer.extend(Vector2(220.5, 50.5))
	surface.blue_layer.finish()
	rule.begin(surface, Vector2(203, 45))
	check("arrow draws on an isolated gear with no draft carrier", rule.finish(surface, Vector2(217, 45)))
	var body_count: int = level.world.bodies.size()
	canvas.generate(false)
	await process_frame
	check("blue line on isolated gear does not create a duplicate body", level.world.bodies.size() == body_count)
	check("isolated gear gets its wire even when no new support is created", not wires_on(rule, isolated.yellow_anchor.body).is_empty())
	print("GEAR_BLUE force=", motor.applied_force, " power=", motor.received_power,
		" av=", wheel.angular_velocity, " bridged=", not rule.flow.bridges.is_empty())

	level.queue_free()
	await process_frame
	print("[GearBlue] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
