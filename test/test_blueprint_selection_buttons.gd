extends SceneTree
const Palette := preload("res://ink/general/src/ink_palette.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, okay: bool) -> void:
	checks += 1
	print("[BlueprintButtons] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func _click(button: Button) -> void:
	var point := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	var event := InputEventMouseButton.new()
	event.position = point
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	root.push_input(event, true)
	# 按住期间跨过多个渲染帧，覆盖真正鼠标点击的按下/松开过程。
	for _frame in 3:
		await process_frame
	event = event.duplicate()
	event.pressed = false
	root.push_input(event, true)
	await process_frame

func _select(canvas) -> void:
	canvas.set_tool(canvas.SurfaceScript.Tool.SELECT_DELETE)
	canvas.surface._selected_rect = Rect2i(24, 24, 32, 32)
	canvas.surface.selection_overlay.set_selection(canvas.surface._selected_rect)
	for _frame in 3:
		await process_frame

func _run() -> void:
	var app = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	var level = await app.load_level(load("res://test/fixtures/maps/base_level.tscn"))
	level.auto_step = false
	app._set_screen(app.ui_scene.instantiate())
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	for workbench in get_nodes_in_group("canvas_workbench"):
		workbench.active = false
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	canvas.active = true
	canvas.show()
	canvas.surface.ink_free = true
	level.get_node("Player").teleport_to(canvas.global_position + Vector2(128, 128), 0)
	var camera = level.get_node("SimulationRuntime/PhysicsStep")._camera
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.position_smoothing_enabled = false
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.global_position = canvas.global_position + Vector2(128, 128)
	camera.reset_physics_interpolation()
	camera.reset_smoothing()
	camera.force_update_scroll()
	var system = root.get_node("Blueprints")
	for editing in [false, true]:
		canvas.set_map_editor_mode(editing)
		canvas._refresh_workbench_visibility()
		var mode := "editor" if editing else "gameplay"
		canvas.surface.write_pixel(Vector2i(32, 32), Palette.BLACK.color)
		canvas.surface.refresh()
		await _select(canvas)
		_check(mode + " actions visible", system.actions.visible)
		var undo_before: int = canvas.surface.undo_depth()
		await _click(system.actions.get_child(0))
		_check(mode + " actual delete click removes pixels", canvas.surface.material_at(32, 32) == 0)
		_check(mode + " delete is one undo transaction", canvas.surface.undo_depth() == undo_before + 1)
		canvas.surface.undo_last_edit()
		_check(mode + " undo restores deleted pixels", canvas.surface.material_at(32, 32) == Palette.BLACK.id)
		await _select(canvas)
		var before: PackedByteArray = canvas.surface.black_image.get_data()
		await _click(system.actions.get_child(1))
		_check(mode + " actual save click opens dialog", system.modal and paused and system._mode == "save")
		_check(mode + " save preserves selection and content", canvas.surface.has_selection() and canvas.surface.black_image.get_data() == before)
		system.close()
		canvas.surface.clear_selected_area()
	app.queue_free()
	await process_frame
	print("[BlueprintButtons] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
