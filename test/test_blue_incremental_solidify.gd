extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[IncrementalBlue] %s %s" % ["PASS" if okay else "FAIL", label])

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.active = true
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	canvas.set_map_editor_mode(true)
	var camera = level.get_node("Camera2D")
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.position_smoothing_enabled = false
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.global_position = canvas.global_position + Vector2(128, 128)
	camera.reset_physics_interpolation()
	camera.force_update_scroll()
	await process_frame
	var surface = canvas.surface
	surface.ink_free = true
	for y in range(80, 101):
		for x in range(40, 241):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	for y in range(72, 80):
		for x in range(50, 65):
			surface.write_pixel(Vector2i(x, y), Palette.RED.color)
	surface.write_pixel(Vector2i(45, 85), surface.nail_color())
	canvas.generate(false)
	var rule = surface.blue_rule()
	surface.brush_size = 1
	surface.blue_layer.begin(Vector2(50.5, 80.5))
	surface.blue_layer.extend(Vector2(100.5, 80.5))
	surface.blue_layer.finish()
	canvas.generate()
	await process_frame
	var wires: Array = rule.objects(Wire).filter(func(w): return w.active)
	check("first blue solidification attaches to pre-existing black support", wires.size() == 1)
	if wires.is_empty():
		level.queue_free()
		await process_frame
		quit(1)
		return
	var wire = wires[0]
	var body = wire.body
	var original_count: int = wire.mask.size()
	surface.blue_layer.begin(Vector2(100.5, 80.5))
	surface.blue_layer.extend(Vector2(190.5, 80.5))
	surface.blue_layer.finish()
	surface.blue_layer.begin(Vector2(180.5, 80.5))
	surface.blue_layer.extend(Vector2(180.5, 90.5))
	surface.blue_layer.finish()
	surface.brush_size = 3
	rule.begin(surface, Vector2(170.5, 90.5))
	check("motor draws on already solidified support", rule.finish(surface, Vector2(200.5, 90.5)))
	canvas.generate()
	await process_frame
	check("extension keeps original wire identity", rule.objects(Wire).filter(func(w): return w.active and w.body == body).size() == 1
		and rule.objects(Wire).has(wire))
	check("extension retains original cells and adds new cells", wire.mask.size() > original_count
		and wire.mask.has(Vector2i(body.to_local(surface.to_global(Vector2(50.5, 80.5))).floor()))
		and wire.mask.has(Vector2i(body.to_local(surface.to_global(Vector2(180.5, 90.5))).floor())))
	check("draft clears only after its cells become active", surface.blue_layer.mask.is_empty())
	check("extension undo succeeds", surface.undo_last_edit())
	await process_frame
	await process_frame
	wire = rule.objects(Wire).filter(func(w): return w.active and w.body == body)[0]
	check("extension undo restores original wire and draft extension", wire.mask.size() == original_count
		and not surface.blue_layer.mask.is_empty())
	check("extension redo succeeds", surface.redo_last_edit())
	await process_frame
	await process_frame
	var restored_wires: Array = rule.objects(Wire).filter(func(w): return w.active)
	check("redo replaces the old wire rather than drawing a stale duplicate", restored_wires.size() == 1)
	wire = restored_wires[0]
	body = wire.body
	check("extension redo restores full active circuit", wire.mask.has(Vector2i(body.to_local(surface.to_global(Vector2(180.5, 90.5))).floor()))
		and surface.blue_layer.mask.is_empty())
	var masks: Dictionary = wire.mask.duplicate()
	surface.brush_size = 1
	surface.blue_layer.begin(Vector2(100.5, 80.5))
	surface.blue_layer.extend(Vector2(190.5, 80.5))
	surface.blue_layer.finish()
	canvas.generate(false)
	check("repeated solidification neither duplicates nor loses cells", wire.mask == masks
		and rule.objects(Wire).filter(func(w): return w.active and w.body == body).size() == 1)
	var motors: Array = rule.objects(Motor).filter(func(m): return m.active)
	check("motor is attached to support", motors.size() == 1 and motors[0].body == body)
	var peak := 0.0
	for tick in 240:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
		if not motors.is_empty():
			peak = maxf(peak, motors[0].received_power)
	check("real red fuel reaches motor through added wire sections", peak > 0.0)
	print("[IncrementalBlue] red-fuel peak motor power=", peak)
	for motor in rule.objects(Motor):
		motor.queue_free()
	await process_frame
	surface.selected_ink = 0
	surface.gear_tool.begin(Vector2(180, 90))
	var gear = surface.gear_tool.finish(Vector2(205.5, 90.5))
	check("gear binds to the already wired support", gear != null and not gear.fixed_to_world)
	surface.brush_size = 1
	surface.blue_layer.begin(Vector2(180.5, 90.5))
	surface.blue_layer.extend(Vector2(180.5, 82.5))
	surface.blue_layer.finish()
	surface.blue_layer.begin(Vector2(170.5, 82.5))
	surface.blue_layer.extend(Vector2(190.5, 82.5))
	surface.blue_layer.finish()
	surface.brush_size = 3
	rule.begin(surface, Vector2(170.5, 82.5))
	check("tangential gear motor draws after support was solidified", rule.finish(surface, Vector2(190.5, 82.5)))
	canvas.generate(false)
	await process_frame
	motors = rule.objects(Motor).filter(func(m): return m.active and m.body == gear.yellow_anchor.body)
	check("gear circuit binds independently of support circuit", motors.size() == 1
		and rule.objects(Wire).any(func(w): return w.body == gear.yellow_anchor.body))
	var start_angle: float = gear.yellow_anchor.body.rotation
	peak = 0.0
	for tick in 360:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
		if not motors.is_empty():
			peak = maxf(peak, motors[0].received_power)
	check("red fuel transmits through support and axle into gear motor", peak > rule.idle_power)
	check("real red-fuel circuit rotates the gear", absf(gear.yellow_anchor.body.rotation - start_angle) > 0.01)
	print("[IncrementalBlue] gear peak power=", peak, " rotation=", gear.yellow_anchor.body.rotation - start_angle,
		" frozen=", gear.yellow_anchor.body.frozen, " static=", gear.yellow_anchor.body.is_static,
		" force=", motors[0].applied_force, " arm=", motors[0].position - gear.yellow_anchor.body.com_world())
	canvas.solid.sync_serializable_bodies(level)
	var saved_cells := 0
	for active_wire in rule.objects(Wire):
		active_wire.sync_pose()
		saved_cells += active_wire.mask.size()
	for active_motor in rule.objects(Motor):
		active_motor.sync_pose()
	var packed := PackedScene.new()
	check("incrementally completed circuit packs", packed.pack(level) == OK)
	var restored = packed.instantiate()
	restored.auto_step = false
	root.add_child(restored)
	await process_frame
	await process_frame
	var restored_rule = restored.get_node("MapCanvas").surface.blue_rule()
	var restored_cells := 0
	for restored_wire in restored_rule.objects(Wire):
		restored_cells += restored_wire.mask.size()
	check("save reload preserves every active wire cell", restored_cells == saved_cells)
	check("save reload preserves gear motor binding", restored_rule.objects(Motor).size() == 1
		and restored_rule.objects(Motor)[0].active and restored_rule.objects(Motor)[0].body != null)
	peak = 0.0
	for tick in 180:
		restored_rule.resolve_fixed(restored.get_node("SimulationRuntime")._context())
		for restored_motor in restored_rule.objects(Motor):
			peak = maxf(peak, restored_motor.received_power)
	check("reloaded red-fuel circuit still transmits power", peak > 0.0)
	restored.queue_free()
	level.queue_free()
	await process_frame
	print("[IncrementalBlue] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
