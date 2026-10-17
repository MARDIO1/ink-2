extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Gear := preload("res://actor/canvas/src/gear_bearing.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[GearCircuit] %s %s" % ["PASS" if okay else "FAIL", label])

func motion(creative, point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = root.get_canvas_transform() * point
	creative._handle_layout_mouse_motion(event)

func gear_at(level, point: Vector2):
	for node in level.get_children():
		if node is Gear and not node.is_queued_for_deletion() and node.global_position.distance_to(point) < 0.1:
			return node
	return null

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(512, 512)
	canvas.set_map_editor_mode(true)
	canvas.surface.ink_free = true
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.active = true
	creative._ensure_editor_resources()
	var camera = level.get_node("Camera2D")
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.position_smoothing_enabled = false
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.global_position = canvas.global_position + Vector2(256, 256)
	camera.force_update_scroll()
	await process_frame
	var surface = canvas.surface
	surface.selected_ink = 0
	surface.gear_tool.begin(Vector2(120, 120))
	var gear = surface.gear_tool.finish(Vector2(152.5, 120.5))
	var body = gear.yellow_anchor.body
	var shape = body.shapes[0]
	var pixels: int = shape.pixel_count()
	var rule = surface.blue_rule()
	surface.brush_size = 2
	surface.blue_layer.begin(Vector2(105.5, 112.5))
	surface.blue_layer.extend(Vector2(130.5, 112.5))
	surface.blue_layer.finish()
	rule.begin(surface, Vector2(105.5, 112.5))
	check("draft arrow draws on gear", rule.finish(surface, Vector2(130.5, 112.5)))
	surface.blue_layer.begin(Vector2(30.5, 30.5))
	surface.blue_layer.extend(Vector2(50.5, 30.5))
	surface.blue_layer.finish()
	var original_cells: Dictionary = surface.blue_layer.mask.duplicate()
	var start: Vector2 = gear.global_position
	var arrow_start: Vector2 = rule.objects(Motor)[0].global_position
	creative.select_control_tool()
	var count: int = surface._undo_steps.size()
	creative._begin_layout_drag(gear, start)
	motion(creative, start + Vector2(80, 40))
	check("control drag carries draft wire", surface.blue_layer.mask.has(Vector2i(195, 152))
		and not surface.blue_layer.mask.has(Vector2i(115, 112)))
	check("control drag carries draft arrow", rule.objects(Motor)[0].global_position.is_equal_approx(arrow_start + Vector2(80, 40)))
	check("unrelated wire remains in place", surface.blue_layer.mask.has(Vector2i(40, 30)))
	motion(creative, start + Vector2(-80, -82))
	motion(creative, start + Vector2(80, 40))
	check("passing over another draft wire preserves it", surface.blue_layer.mask.has(Vector2i(40, 30)))
	creative._cancel_layout_drag()
	check("cancel restores draft wire exactly", surface.blue_layer.mask == original_cells)
	check("cancel restores arrow and history", rule.objects(Motor)[0].global_position.is_equal_approx(arrow_start)
		and surface._undo_steps.size() == count)
	creative._begin_layout_drag(gear, start)
	motion(creative, start + Vector2(80, 40))
	creative._finish_layout_drag()
	check("circuit drag commits one transaction", surface._undo_steps.size() == count + 1)
	check("draft circuit movement undo succeeds", creative.undo_last_edit())
	await process_frame
	await process_frame
	check("undo restores complete draft circuit", surface.blue_layer.mask == original_cells
		and rule.objects(Motor)[0].global_position.is_equal_approx(arrow_start))
	check("draft circuit movement redo succeeds", creative.redo_last_edit())
	await process_frame
	await process_frame
	check("redo restores moved draft circuit", surface.blue_layer.mask.has(Vector2i(195, 152))
		and rule.objects(Motor)[0].global_position.is_equal_approx(arrow_start + Vector2(80, 40)))
	var before_box: Vector2 = gear.global_position
	canvas._move_selection(Rect2i(160, 120, 80, 80), Vector2i(70, 80))
	check("box move keeps original wheel and shape", gear.yellow_anchor.body == body
		and body.shapes[0] == shape and shape.pixel_count() == pixels and gear.joint != null)
	check("box move carries wheel circuit", gear.global_position.is_equal_approx(before_box + Vector2(70, 80))
		and surface.blue_layer.mask.has(Vector2i(265, 232))
		and rule.objects(Motor)[0].global_position.is_equal_approx(arrow_start + Vector2(150, 120)))
	check("box movement undo succeeds", creative.undo_last_edit())
	await process_frame
	await process_frame
	gear = gear_at(level, before_box)
	check("box undo restores gear bearing and circuit", gear != null and gear.joint != null
		and surface.blue_layer.mask.has(Vector2i(195, 152)))
	check("box movement redo succeeds", creative.redo_last_edit())
	await process_frame
	await process_frame
	gear = gear_at(level, before_box + Vector2(70, 80))
	check("box redo restores gear bearing and circuit", gear != null and gear.teeth == 12
		and surface.blue_layer.mask.has(Vector2i(265, 232)))
	body = gear.yellow_anchor.body
	shape = body.shapes[0]
	var center: Vector2 = gear.global_position
	canvas._move_selection(Rect2i(236, 230, 8, 8), Vector2i(0, 10))
	check("partial selection without axle does not fracture wheel", gear.global_position.is_equal_approx(center)
		and body.shapes[0] == shape and shape.pixel_count() == pixels)
	canvas.generate(false)
	await process_frame
	var wires: Array = rule.objects(Wire).filter(func(w): return w.active and w.body == body)
	var motors: Array = rule.objects(Motor).filter(func(m): return m.active and m.body == body)
	check("moved draft circuit solidifies onto the same wheel", not wires.is_empty() and motors.size() == 1)
	var wire = wires[0]
	var motor = motors[0]
	var wire_start: Vector2 = wire.global_position
	var motor_start: Vector2 = motor.global_position
	creative._begin_layout_drag(gear, center)
	motion(creative, center + Vector2(50, 0))
	check("active wire follows in the same event", wire.global_position.is_equal_approx(wire_start + Vector2(50, 0)))
	check("active motor follows in the same event", motor.global_position.is_equal_approx(motor_start + Vector2(50, 0)))
	creative._finish_layout_drag()
	var active_start: Vector2 = gear.global_position
	var circle := Rect2i(280, 200, 80, 80)
	canvas._move_selection(circle, Vector2i(0, 80), {"circle_rect": circle})
	check("circle selection moves complete active assembly", gear.global_position.is_equal_approx(active_start + Vector2(0, 80))
		and gear.yellow_anchor.body == body and body.shapes[0] == shape
		and wire.global_position.is_equal_approx(wire_start + Vector2(50, 80))
		and motor.global_position.is_equal_approx(motor_start + Vector2(50, 80)))
	check("circle assembly move undo succeeds", creative.undo_last_edit())
	await process_frame
	await process_frame
	gear = gear_at(level, active_start)
	check("circle undo restores complete active circuit", gear != null and gear.joint != null
		and rule.objects(Wire).any(func(w): return w.body == gear.yellow_anchor.body)
		and rule.objects(Motor).any(func(m): return m.body == gear.yellow_anchor.body))
	canvas.solid.sync_serializable_bodies(level)
	var packed := PackedScene.new()
	check("moved gear assembly packs", packed.pack(level) == OK)
	var restored = packed.instantiate()
	restored.auto_step = false
	root.add_child(restored)
	await process_frame
	await process_frame
	var loaded = gear_at(restored, center + Vector2(50, 0))
	var restored_rule = restored.get_node("MapCanvas").surface.blue_rule()
	check("save reload keeps gear wire and arrow attached", loaded != null and loaded.joint != null
		and restored_rule.objects(Wire).any(func(w): return w.body == loaded.yellow_anchor.body)
		and restored_rule.objects(Motor).any(func(m): return m.body == loaded.yellow_anchor.body))
	restored.queue_free()
	level.queue_free()
	await process_frame
	print("[GearCircuit] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
