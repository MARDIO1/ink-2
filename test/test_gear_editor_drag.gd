extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Bearing := preload("res://actor/canvas/src/gear_bearing.gd")
const Surface := preload("res://actor/canvas/src/canvas_surface.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[GearDrag] %s %s" % ["PASS" if ok else "FAIL", label])

func axles(level) -> Array:
	return level.get_children().filter(func(node): return node is Bearing and not node.is_queued_for_deletion())

func find_axle(level, center: Vector2):
	for axle in axles(level):
		if axle.yellow_position.distance_to(center) < 0.1:
			return axle
	return null

func mouse(creative, point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = root.get_canvas_transform() * point
	creative.editor_mouse_button(event)

func motion(creative, point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = root.get_canvas_transform() * point
	creative.editor_mouse_motion(event)

func teeth_on_ring(body, radius: float, ink_material: int) -> int:
	var last := false
	var first := false
	var transitions := 0
	for sample in 720:
		var cell := Vector2i((Vector2.ONE * 0.5 + Vector2.from_angle(float(sample) * TAU / 720.0) * radius).floor())
		var occupied: bool = Bearing.has_pixel(body, cell, ink_material)
		if sample == 0:
			first = occupied
		elif occupied and not last:
			transitions += 1
		last = occupied
	if first and not last:
		transitions += 1
	return transitions

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
	canvas.canvas_size = Vector2i(512, 512)
	canvas.surface.ink_free = true
	canvas.set_map_editor_mode(true)
	creative._ensure_editor_resources()
	var palette = creative.editor_palette()
	var camera = level.get_node("Camera2D")
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.global_position = canvas.global_position + Vector2(256, 256)
	camera.zoom = Vector2.ONE * 1.25
	camera.reset_smoothing()
	camera.force_update_scroll()
	await process_frame
	for y in range(180, 261):
		for x in range(180, 261):
			canvas.surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	canvas.surface.write_pixel(Vector2i(185, 185), canvas.surface.nail_color())
	canvas.generate(false)
	palette.gear_tool_button(8).pressed.emit()
	canvas.surface.selected_ink = 0
	check("eight-tooth button has exclusive selected state", canvas.surface.tool == Surface.Tool.GEAR_8
		and palette.gear_tool_button(8).button_pressed and not palette.gear_tool_button(12).button_pressed)
	var tool = canvas.surface.gear_tool
	tool.begin(Vector2(80, 80), 8)
	var eight = tool.finish(Vector2(112.5, 80.5))
	check("new gear leaves no silhouette in the draft", canvas.surface.material_at(80, 80) == 0
		and canvas.surface.gear_skip_cells.is_empty())
	check("black eight-tooth tool produces eight actual tooth lobes", eight.teeth == 8
		and eight.gear_material == Palette.BLACK.id
		and teeth_on_ring(eight.yellow_anchor.body, 32.0 * 0.9, Palette.BLACK.id) == 8)
	palette.gear_tool_button(12).pressed.emit()
	check("twelve-tooth button switches away from eight", canvas.surface.tool == Surface.Tool.GEAR
		and palette.gear_tool_button(12).button_pressed and not palette.gear_tool_button(8).button_pressed)
	canvas.surface.selected_ink = 1
	tool.begin(Vector2(450, 80), 12)
	var twelve = tool.finish(Vector2(482.5, 80.5))
	check("twelve-tooth tool produces twelve actual tooth lobes", twelve.teeth == 12
		and teeth_on_ring(twelve.yellow_anchor.body, 32.0 * 0.9, Palette.GREY.id) == 12)
	creative.select_control_tool()
	var original: Vector2 = eight.yellow_position
	var body = eight.yellow_anchor.body
	# 用非零转角确认拖动保留齿轮的方向与像素，而非重建一个轮子。
	body.rotation = 0.35
	body.position += original - eight.Stroke.anchor_world(eight.yellow_anchor)
	eight._sync_editor_body()
	var old_shape = body.shapes[0]
	var old_pixels: int = old_shape.pixel_count()
	var hit: Vector2 = canvas.surface.to_global(Vector2(88.5, 80.5))
	check("control picking detects visible gear pixels", creative._pick_control_target(hit) == eight)
	check("control picking does not use empty bounding corners", creative._pick_gear(canvas.surface.to_global(Vector2(110, 110))) == null)
	var history_count: int = creative.editor_history_depth()
	var surface_history: int = canvas.surface.undo_depth()
	mouse(creative, hit, true)
	check("left press detaches axle and freezes gear", eight.editor_dragging and eight.joint == null
		and body.frozen and body.tags.get("editor_physics_paused", false) and creative._monster_drag_view_locked)
	var destination: Vector2 = canvas.surface.to_global(Vector2(220.5, 220.5))
	check("gear origin remains blank before moving", canvas.surface.material_at(80, 80) == 0)
	var offset: Vector2 = hit - eight.global_position
	motion(creative, destination + offset)
	check("moving gear leaves its old draft position empty", canvas.surface.material_at(80, 80) == 0)
	eight._process(0.0)
	check("drag moves wheel and axle together without early reattachment", eight.global_position.is_equal_approx(destination)
		and eight.yellow_position.is_equal_approx(level.to_local(destination)) and eight.joint == null
		and body.shapes[0] == old_shape and is_equal_approx(body.rotation, 0.35))
	var drag_position: Vector2 = body.position
	level.get_node("SimulationRuntime")._step(1.0 / 120.0)
	check("physics cannot pull dragged gear back to old axle", body.position.is_equal_approx(drag_position))
	mouse(creative, destination + offset, false)
	check("release connects new support and restores physics", not eight.editor_dragging and not body.frozen
		and not body.tags.has("editor_physics_paused") and not eight.fixed_to_world and eight.joint != null
		and not eight.joint.contacts_enabled and eight.black_anchor.body.is_static)
	check("drag records exactly one undo step", creative.editor_history_depth() == history_count + 1
		and canvas.surface.undo_depth() == surface_history + 1)
	check("drag preserves shape material radius angle and tooth count", body.shapes[0] == old_shape
		and old_shape.pixel_count() == old_pixels and eight.teeth == 8 and is_equal_approx(body.rotation, 0.35)
		and eight.gear_material == Palette.BLACK.id and Bearing.has_pixel(body, Vector2i.ZERO, Palette.BLACK.id))
	check("gear drag unlocks camera and hidden player", not creative._monster_drag_view_locked
		and not camera._editor_drag_locked)
	check("undo gear movement succeeds", creative.undo_last_edit())
	await process_frame
	await process_frame
	eight = find_axle(level, original)
	check("undo restores original center and world connection", eight != null and eight.fixed_to_world
		and eight.joint != null and eight.teeth == 8)
	check("redo gear movement succeeds", creative.redo_last_edit())
	await process_frame
	await process_frame
	eight = find_axle(level, level.to_local(destination))
	check("redo restores support connection and angle", eight != null and not eight.fixed_to_world
		and eight.joint != null and is_equal_approx(eight.yellow_anchor.body.rotation, 0.35))
	# 再次移动离开支座：只移动轮体，旧支座留在原处。
	var support = eight.black_anchor.body
	var support_position: Vector2 = support.position
	mouse(creative, destination, true)
	var empty: Vector2 = canvas.surface.to_global(Vector2(100.5, 350.5))
	motion(creative, empty)
	mouse(creative, empty, false)
	check("moving off support repins wheel to world only", eight.fixed_to_world and eight.joint.body_a == null
		and support.position == support_position)
	history_count = creative.editor_history_depth()
	mouse(creative, empty, true)
	mouse(creative, empty, false)
	check("click without movement keeps connection and adds no history", eight.fixed_to_world and eight.joint != null
		and creative.editor_history_depth() == history_count)
	mouse(creative, empty, true)
	motion(creative, empty + Vector2(20, 15))
	canvas.set_tool(Surface.Tool.BRUSH)
	check("tool switch cancels movement without leaving a loose gear", not eight.editor_dragging
		and eight.global_position.is_equal_approx(empty) and eight.joint != null
		and not creative._monster_drag_view_locked and creative.editor_history_depth() == history_count)
	creative.select_control_tool()
	# 新位置下是未固化黑墨，松手时要形成真实支座，并把固化纳入同一次撤销。
	for y in range(330, 371):
		for x in range(330, 371):
			canvas.surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	canvas.surface.write_pixel(Vector2i(332, 332), canvas.surface.nail_color())
	mouse(creative, empty, true)
	var draft_destination: Vector2 = canvas.surface.to_global(Vector2(350.5, 350.5))
	motion(creative, draft_destination)
	mouse(creative, draft_destination, false)
	check("release onto blueprint creates true noncolliding support", not eight.fixed_to_world
		and eight.joint != null and eight.black_anchor.body.is_static and not eight.joint.contacts_enabled)
	check("undo includes automatic support solidification", creative.undo_last_edit())
	await process_frame
	await process_frame
	eight = find_axle(level, level.to_local(empty))
	check("undo restores old axle and unsolidified support pixels", eight != null and eight.fixed_to_world
		and canvas.surface.material_at(350, 350) == Palette.BLACK.id)
	check("redo includes new support and connection", creative.redo_last_edit())
	await process_frame
	await process_frame
	eight = find_axle(level, level.to_local(draft_destination))
	check("redo of blueprint move restores eight-tooth bearing", eight != null and eight.teeth == 8
		and not eight.fixed_to_world and eight.joint != null)
	mouse(creative, draft_destination, true)
	motion(creative, draft_destination + Vector2(10, 0))
	creative._on_drag_focus_lost()
	check("losing window focus finishes gear drag and releases locks", not eight.editor_dragging
		and eight.joint != null and not creative._monster_drag_view_locked)
	check("focus-loss movement is undoable", creative.undo_last_edit())
	await process_frame
	await process_frame
	eight = find_axle(level, level.to_local(draft_destination))
	# 边缘外的移动也要能重做，不能因只捕获画布内刚体而丢失齿轮。
	mouse(creative, draft_destination, true)
	var outside: Vector2 = canvas.surface.to_global(Vector2(-50.5, 400.5))
	motion(creative, outside)
	mouse(creative, outside, false)
	check("outside-canvas placement safely repins to world", eight.fixed_to_world
		and eight.yellow_position.is_equal_approx(level.to_local(outside)))
	check("outside-canvas drag undo succeeds", creative.undo_last_edit())
	await process_frame
	await process_frame
	check("outside-canvas drag redo succeeds", creative.redo_last_edit())
	await process_frame
	await process_frame
	check("redo preserves the gear outside canvas bounds", find_axle(level, level.to_local(outside)) != null)
	check("final undo returns gear to support for save", creative.undo_last_edit())
	await process_frame
	await process_frame
	eight = find_axle(level, level.to_local(draft_destination))
	canvas.solid.sync_serializable_bodies(level)
	var packed := PackedScene.new()
	check("moved gears pack into map", packed.pack(level) == OK)
	var restored = packed.instantiate()
	restored.auto_step = false
	root.add_child(restored)
	await process_frame
	await process_frame
	var loaded = find_axle(restored, level.to_local(draft_destination))
	check("reload preserves moved center support and eight teeth", loaded != null and loaded.teeth == 8
		and loaded.joint != null and not loaded.fixed_to_world and loaded.gear_material == Palette.BLACK.id)
	check("reload also preserves gray twelve-tooth gear", axles(restored).any(func(axle): return axle.teeth == 12 and axle.gear_material == Palette.GREY.id))
	restored.queue_free()
	# 完整事务会重建轮体；较早的轻量移动历史必须用稳定身份重新找到它。
	check("undo solidification reconstructs the wheel", creative.undo_last_edit())
	check("same-frame pose undo survives wheel reconstruction", creative.undo_last_edit()
		and find_axle(level, level.to_local(destination)) != null)
	check("earlier pose redo survives wheel reconstruction", creative.redo_last_edit()
		and find_axle(level, level.to_local(empty)) != null)
	check("solidification redo still restores the support", creative.redo_last_edit())
	await process_frame
	await process_frame
	eight = find_axle(level, level.to_local(draft_destination))
	check("mixed undo redo retains bearing support and teeth", eight != null and not eight.fixed_to_world
		and eight.joint != null and eight.teeth == 8)
	level.queue_free()
	await process_frame
	print("[GearDrag] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
