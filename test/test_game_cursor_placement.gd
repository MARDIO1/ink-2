extends SceneTree
const Tool := preload("res://actor/canvas/src/canvas_surface.gd").Tool
const Bearing := preload("res://actor/canvas/src/gear_bearing.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[CursorPlacement] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func _move(point: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.position = root.get_final_transform() * point
	event.global_position = event.position
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	await process_frame

func _button(point: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	root.push_input(event, true)

func _run() -> void:
	var cursor := root.get_node("InkCursor")
	cursor.set_process(false)
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	root.add_child(level)
	current_scene = level
	await process_frame
	level.get_node("SimulationRuntime").set_physics_process(false)
	creative.active = true
	creative._ensure_editor_resources()
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	canvas.visible = true
	canvas.active = true
	canvas.set_map_editor_mode(true)
	canvas.surface.ink_free = true
	var camera = level.get_node("Camera2D")
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.global_position = canvas.global_position + Vector2(128, 128)
	camera.zoom = Vector2.ONE
	camera.reset_smoothing()
	camera.force_update_scroll()
	await process_frame
	await process_frame
	camera.force_update_scroll()
	canvas.tool_grid.get_node("Nail").pressed.emit()
	var nail_cell := Vector2i(128, 180)
	var screen: Vector2 = canvas.surface.get_global_transform_with_canvas() * (Vector2(nail_cell) + Vector2.ONE * 0.5)
	await _move(screen)
	cursor._refresh_cursor(screen, true, false)
	check("nail toolbar tool shows arrow", canvas.surface.tool == Tool.NAIL and cursor.pointer.texture == cursor.WORLD_TEXTURE)
	_button(screen, true)
	_button(screen, false)
	check("actual arrow click places nail at unchanged cell", canvas.surface.nail_layer.nails.has(nail_cell))
	for teeth in [8, 12]:
		creative.select_gear_tool(teeth)
		var center := Vector2(64, 64) if teeth == 8 else Vector2(160, 64)
		screen = canvas.surface.get_global_transform_with_canvas() * (center + Vector2.ONE * 0.5)
		await _move(screen)
		cursor._refresh_cursor(screen, true, false)
		check("%d-tooth gear tool shows arrow" % teeth, cursor.pointer.texture == cursor.WORLD_TEXTURE)
		_button(screen, true)
		check("arrow press starts real gear preview", canvas.surface.gear_tool.dragging)
		var end: Vector2 = screen + Vector2(25, 0)
		await _move(end)
		_button(end, false)
		var placed := false
		for node in level.get_children():
			if node is Bearing and node.teeth == teeth and node.joint != null:
				placed = true
		check("arrow release creates usable %d-tooth bearing" % teeth, placed)
	creative.select_monster_tool(creative.LAYOUT_MODE_PLACE_PORTAL)
	var portals_before: int = creative._portals().size()
	screen = canvas.surface.get_global_transform_with_canvas() * Vector2(128, 128)
	await _move(screen)
	cursor._refresh_cursor(screen, true, false)
	check("portal placement shows arrow inside canvas", cursor.pointer.texture == cursor.WORLD_TEXTURE)
	_button(screen, true)
	_button(screen, false)
	check("actual arrow click places reusable portal", creative._portals().size() == portals_before + 1 and creative._selected_portal.scene_file_path == "res://actor/portal/map_portal.tscn")
	cursor._refresh_cursor(screen, true, false)
	check("portal control mode retains arrow", creative._monster_mode == creative.CONTROL_MODE and cursor.pointer.texture == cursor.WORLD_TEXTURE)
	canvas.set_tool(Tool.BRUSH)
	canvas.set_brush_size(33)
	cursor._refresh_cursor(screen, true, false)
	check("returning to brush restores correctly sized ring", cursor.pointer.texture == cursor.CANVAS_TEXTURE and is_equal_approx(cursor.pointer.size.x * 52.0 / 60.0, 33.0))
	cursor._release_mouse()
	creative.active = false
	level.queue_free()
	await process_frame
	print("[CursorPlacement] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
