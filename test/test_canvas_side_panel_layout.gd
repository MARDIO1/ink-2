extends SceneTree

var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[SidePanel] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func settle() -> void:
	for frame in 4:
		await process_frame

func click(button: BaseButton) -> void:
	var point := button.get_global_transform_with_canvas() * (button.size * 0.5)
	var motion := InputEventMouseMotion.new()
	motion.position = point
	root.push_input(motion, true)
	await process_frame
	for pressed in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = pressed
		root.push_input(event, true)
		await process_frame
	await settle()

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await settle()
	level.get_node("Camera2D").enabled = false
	var canvas = level.get_node("SmallCanvas")
	canvas.player = null
	canvas.toolbar_transition_seconds = 0.0
	canvas._refresh_workbench_visibility()
	var panel: Control = canvas._side_panel
	var layout: CanvasLayer = canvas.get_node("SidePanelLayer")
	var initial_size: Vector2i = canvas.canvas_size
	var original_transform := root.canvas_transform
	for zoom in [0.5, 1.0, 3.0]:
		for screen_anchor in [Vector2(940, -50), Vector2(950, 520), Vector2(-100, 200), Vector2(500, 100)]:
			var transform := Transform2D(0.2, Vector2.ONE * zoom, 0.0, Vector2.ZERO)
			var anchor := Vector2(float(canvas.canvas_size.x) + canvas.side_panel_gap + canvas.PLAY_TOOLBAR_X_OFFSET, 2)
			transform.origin = screen_anchor - transform * (canvas.global_transform * anchor)
			root.canvas_transform = transform
			await settle()
			var panel_rect := Rect2(panel.get_global_transform_with_canvas().origin, panel.size)
			check("panel stays horizontally in viewport zoom=%s anchor=%s" % [zoom, screen_anchor], panel_rect.position.x >= 11 and panel_rect.end.x <= root.get_visible_rect().end.x - 11)
			var group_bounds: Rect2 = layout._group_screen_bounds()
			check("panel height follows canvas without vertical avoidance", is_equal_approx(panel_rect.position.y, group_bounds.position.y + 2.0))
			var left: Control = canvas.buttons
			var left_rect := Rect2(left.get_global_transform_with_canvas().origin, left.size)
			check("left toolbar stays horizontally in viewport", left_rect.position.x >= 11 and left_rect.end.x <= root.get_visible_rect().end.x - 11)
			var swatch: Control = canvas._ink_buttons[0]
			check("swatch stays 34 screen pixels despite rotated camera zoom", is_equal_approx(swatch.get_global_transform_with_canvas().x.length() * swatch.size.x, 34.0))
	# 点击验证使用完整可见的画布高度；上下越界现在按设计不再吸附回屏幕。
	root.canvas_transform = Transform2D(0.0, Vector2(400, 160) - canvas.global_position)
	await settle()
	canvas.toolbar_transition_seconds = 0.22
	var still_position: Vector2 = layout._mount.position
	await settle()
	check("visible toolbar does not continue drifting after camera stops", layout._mount.position.is_equal_approx(still_position))
	root.canvas_transform.origin += Vector2(4, 3)
	await process_frame
	layout.update_layout(1.0 / 60.0)
	check("visible toolbar stays attached without interpolation lag", layout._mount.position.is_equal_approx(still_position + Vector2(4, 3)))
	await click(canvas._ink_buttons[2])
	check("screen-space color button changes selected ink", canvas.surface.selected_ink == 2)
	canvas._side_brush_slider.value = 13
	check("screen-space brush slider changes brush size", canvas.surface.brush_size == 13)
	canvas.toolbar_transition_seconds = 0.0
	canvas.hide()
	await settle()
	check("hiding canvas also hides floating toolbar", not layout.visible)
	canvas.show()
	canvas.set_map_editor_mode(true)
	await settle()
	check("editor uses its own palette without floating duplicate", not panel.visible)
	canvas.set_map_editor_mode(false)
	await settle()
	check("leaving editor restores floating palette", panel.visible)
	check("layout never changes canvas dimensions", canvas.canvas_size == initial_size)
	root.canvas_transform = original_transform
	level.queue_free()
	await settle()
	print("[SidePanel] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
