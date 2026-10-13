extends SceneTree

const Monster := preload("res://actor/monster/src/map_monster.gd")
var failures := 0
var checks := 0
var creative: Node


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, ok: bool) -> void:
	checks += 1
	print("[EditorPicking] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _mouse(world_point: Vector2, pressed: bool, button := MOUSE_BUTTON_LEFT) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.position = creative.get_viewport().get_canvas_transform() * world_point
	event.global_position = event.position
	event.button_index = button
	event.pressed = pressed
	return event


func _disable_physics(node: Node) -> void:
	node.set_physics_process(false)
	for child in node.get_children():
		_disable_physics(child)


func _run() -> void:
	var level: Node = load("res://map/main.tscn").instantiate()
	root.add_child(level)
	await process_frame
	creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	_disable_physics(level)
	var camera: Camera2D = level.get_node("Camera2D")
	var center := Vector2(10000, -10000)
	camera.position_smoothing_enabled = false
	camera.global_position = center
	camera.zoom = Vector2.ONE
	camera.force_update_scroll()
	await process_frame
	var bitmap := Image.create_empty(100, 240, false, Image.FORMAT_RGBA8)
	bitmap.fill(Color.BLACK)
	var tall := Monster.new()
	tall.name = "TallPickFixture"
	tall.editor_id = "tall_pick_fixture"
	tall.z_index = 1000
	var visual := Node2D.new()
	visual.name = "Visual"
	var sprite := Sprite2D.new()
	sprite.centered = false
	sprite.position = Vector2(-50, -240)
	sprite.texture = ImageTexture.create_from_image(bitmap)
	visual.add_child(sprite)
	tall.add_child(visual)
	creative._ensure_monster_container().add_child(tall)
	tall.global_position = center + Vector2(0, 130)
	tall.set_physics_process(false)
	var body_point := center + Vector2(0, -80)
	_check("body can be selected far above old foot radius", creative._find_monster_at(body_point) == tall)
	for zoom in [0.35, 1.0, 2.0]:
		camera.zoom = Vector2.ONE * zoom
		camera.force_update_scroll()
		_check("body picking at zoom %.2f" % zoom, creative._find_monster_at(body_point) == tall)
	camera.zoom = Vector2.ONE
	camera.force_update_scroll()
	var background := Image.create_empty(300, 400, false, Image.FORMAT_RGBA8)
	background.fill(Color.BEIGE)
	var image_frames: Array[Texture2D] = []
	var backdrop: Sprite2D = creative.place_imported_image(center, true, image_frames, PackedFloat32Array(),
		"pick_background.png", background.save_png_to_buffer(), "png")
	_check("visible monster wins over image behind it", creative._pick_control_target(body_point) == tall)
	creative.select_control_tool()
	var fixture_ui := CanvasLayer.new()
	root.add_child(fixture_ui)
	var ui_button := Button.new()
	ui_button.position = Vector2(20, 20)
	ui_button.size = Vector2(80, 40)
	fixture_ui.add_child(ui_button)
	var hover := InputEventMouseMotion.new()
	hover.position = Vector2(30, 30)
	hover.global_position = hover.position
	root.push_input(hover, true)
	await process_frame
	_check("UI geometry detected without hover cache", creative._pointer_over_editor_ui(hover.position))
	var clicked: bool = creative._handle_editor_input(_mouse(body_point, true))
	_check("fast click leaving UI selects on first press", clicked and creative._selected_control_target == tall)
	var original := tall.global_position
	creative._handle_editor_input(_mouse(body_point + Vector2(70, 25), false))
	_check("release position moves object without motion event", tall.global_position.is_equal_approx(original + Vector2(70, 25)))
	_check("one undo restores whole drag", creative.undo_last_edit() and tall.global_position.is_equal_approx(original))
	var history_size: int = creative._edit_history.size()
	creative._handle_editor_input(_mouse(body_point, true))
	var motion := InputEventMouseMotion.new()
	motion.position = _mouse(body_point + Vector2(20, 10), true).position
	creative._handle_editor_input(motion)
	creative._handle_editor_input(_mouse(body_point, false))
	_check("returning pointer to press position restores object", tall.global_position.is_equal_approx(original) and creative._edit_history.size() == history_size)
	creative._handle_editor_input(_mouse(body_point, true))
	var release_over_ui := InputEventMouseButton.new()
	release_over_ui.position = Vector2(30, 30)
	release_over_ui.button_index = MOUSE_BUTTON_LEFT
	creative._handle_editor_input(release_over_ui)
	_check("release over UI ends drag", creative._layout_drag_target == null)
	_check("drag over UI remains undoable", creative.undo_last_edit() and tall.global_position.is_equal_approx(original))
	var ui_press := release_over_ui.duplicate() as InputEventMouseButton
	ui_press.pressed = true
	_check("UI click cannot grab world object", not creative._handle_editor_input(ui_press) and creative._layout_drag_target == null)
	var input := LineEdit.new()
	fixture_ui.add_child(input)
	input.grab_focus()
	creative.select_monster_tool(creative.TEXT_MODE_PLACE)
	var f_key := InputEventKey.new()
	f_key.keycode = KEY_F
	f_key.pressed = true
	_check("typing F keeps text focus", not creative._handle_editor_input(f_key) and creative._monster_mode == creative.TEXT_MODE_PLACE)
	input.release_focus()
	creative._handle_editor_input(f_key)
	_check("F selects manipulation tool outside text input", creative._monster_mode == creative.CONTROL_MODE)
	input.queue_free()
	ui_button.queue_free()
	var label: Label = creative.place_map_text(center + Vector2(-160, 0), "旋转文字")
	label.rotation = -0.7
	label.scale = Vector2(0.5, 1.8)
	await process_frame
	var text_point := label.get_global_transform() * (label.size * 0.5)
	_check("rotated scaled text can be picked", creative._find_map_text_at(text_point) == label)
	creative._handle_editor_input(_mouse(text_point, true, MOUSE_BUTTON_RIGHT))
	_check("F right click deletes text instead of image behind it", not label.is_inside_tree() and backdrop.is_inside_tree())
	_check("text deletion can be undone", creative.undo_last_edit())
	creative._handle_editor_input(_mouse(body_point, true, MOUSE_BUTTON_RIGHT))
	_check("F right click deletes body on first press", not tall.is_inside_tree() and backdrop.is_inside_tree())
	_check("monster deletion can be undone", creative.undo_last_edit() and creative.monster_count() == 1)
	var restored_monster: Node2D = creative._ensure_monster_container().get_child(0)
	var restored_art: Sprite2D = Monster.Ragdoll.body_art(restored_monster.get_node("Visual"))
	var restored_point := restored_art.to_global(restored_art.get_rect().get_center())
	root.push_input(_mouse(restored_point, true), true)
	root.push_input(_mouse(restored_point, false), true)
	await process_frame
	_check("real viewport input selects visible body once", creative._selected_control_target == restored_monster and creative._layout_drag_target == null)
	root.push_input(_mouse(restored_point, true, MOUSE_BUTTON_RIGHT), true)
	root.push_input(_mouse(restored_point, false, MOUSE_BUTTON_RIGHT), true)
	await process_frame
	_check("real viewport input deletes selected body once", creative.monster_count() == 0 and creative._selected_control_target == null)
	backdrop.rotation = PI * 0.5
	backdrop.scale = Vector2(1.7, 0.6)
	var image_point := backdrop.to_global(backdrop.get_rect().get_center())
	_check("rotated scaled image can be picked", creative._find_imported_image_at(image_point) == backdrop)
	var target_position := center + Vector2(160, 90)
	backdrop.global_position += Vector2(2000, 0)
	var trigger: Node2D = creative.place_dialogue_trigger(target_position, PackedStringArray(["测试"]))
	creative._handle_editor_input(_mouse(target_position, true, MOUSE_BUTTON_RIGHT))
	_check("F right click deletes dialogue trigger", not trigger.is_inside_tree())
	var fountain: Node2D = creative.place_ink_fountain(target_position)
	creative._handle_editor_input(_mouse(target_position, true, MOUSE_BUTTON_RIGHT))
	_check("F right click deletes ink fountain", not fountain.is_inside_tree())
	creative._cancel_layout_drag()
	fixture_ui.queue_free()
	level.queue_free()
	await process_frame
	print("[EditorPicking] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
