extends SceneTree

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, ok: bool) -> void:
	print("[CreativeImage] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _disable_physics(node: Node) -> void:
	node.set_physics_process(false)
	for child in node.get_children():
		_disable_physics(child)


func _run() -> void:
	var level: Node = load("res://map/main.tscn").instantiate()
	root.add_child(level)
	_disable_physics(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.active = true
	creative._ensure_editor_resources()
	_check("import button exists", creative._monster_palette.find_child("ImportImageButton", true, false) != null)
	var bitmap := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	bitmap.fill(Color.TRANSPARENT)
	bitmap.set_pixel(2, 1, Color.BLUE)
	var path := "user://creative_image_import.png"
	bitmap.save_png(path)
	creative._on_image_file_selected(ProjectSettings.globalize_path(path))
	_check("PNG selects placement tool", creative._monster_mode == creative.IMAGE_MODE_PLACE)
	var image: Sprite2D = creative.place_imported_image(Vector2(100, 200))
	_check("image placed at clicked center", image != null and image.global_position == Vector2(98, 198)
		and image.source_format == "png")
	_check("control tool picks image", creative._pick_control_target(Vector2(100, 200)) == image)
	creative._selected_control_target = image
	creative._resize_control_target(image, 1.0)
	_check("mouse wheel resizes image", image.scale.x > 1.0)
	_check("resize undo", creative.undo_last_edit() and image.scale == Vector2.ONE)
	creative.select_control_tool()
	creative._begin_layout_drag(image, image.global_position + Vector2(4, 4))
	creative._layout_drag_resizing = true
	var resize_motion := InputEventMouseMotion.new()
	resize_motion.position = creative.get_viewport().get_canvas_transform() * (image.global_position + Vector2(8, 8))
	creative._handle_layout_mouse_motion(resize_motion)
	creative._finish_layout_drag()
	_check("corner drag resizes image", is_equal_approx(image.scale.x, 2.0))
	_check("corner resize undo", creative.undo_last_edit() and image.scale == Vector2.ONE)
	var before_corner_click: int = creative._edit_history.size()
	var corner_click := image.to_global(Vector2(image.texture.get_size())) + Vector2(6, 3)
	creative._begin_layout_drag(image, corner_click)
	creative._layout_drag_resizing = true
	var still_motion := InputEventMouseMotion.new()
	still_motion.position = creative.get_viewport().get_canvas_transform() * corner_click
	creative._handle_layout_mouse_motion(still_motion)
	creative._finish_layout_drag()
	_check("clicking near resize handle does not jump or add undo", image.scale == Vector2.ONE and creative._edit_history.size() == before_corner_click)
	creative._begin_layout_drag(image, image.global_position + Vector2(2, 2))
	var move_motion := InputEventMouseMotion.new()
	move_motion.position = creative.get_viewport().get_canvas_transform() * Vector2(120, 220)
	creative._handle_layout_mouse_motion(move_motion)
	creative._finish_layout_drag()
	_check("mouse drag moves image", image.global_position == Vector2(118, 218))
	_check("move undo", creative.undo_last_edit() and image.global_position == Vector2(98, 198))
	_check("place undo", creative.undo_last_edit())
	await process_frame
	creative._on_image_file_selected(ProjectSettings.globalize_path(path))
	var image2: Sprite2D = creative.place_imported_image(Vector2(100, 200))
	_check("right-click delete action", creative.delete_imported_image(image2))
	_check("delete undo restores image", creative.undo_last_edit()
		and creative._find_imported_image_at(Vector2(100, 200)) != null)
	var packed := PackedScene.new()
	var pack_ok := packed.pack(level) == OK
	var restored_level = packed.instantiate() if pack_ok else null
	var restored_image = restored_level.get_node_or_null("MapImages/ImportedImage") if restored_level != null else null
	_check("nested map image included in level", restored_image != null
		and restored_image.source_data.size() > 0)
	if restored_level != null:
		restored_level.free()
	creative.active = false
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
