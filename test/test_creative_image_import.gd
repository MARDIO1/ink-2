extends SceneTree

const MapImage := preload("res://debug/creative/src/map_imported_image.gd")
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


func _add_legacy_image(creative: Node, data: PackedByteArray, position: Vector2) -> Sprite2D:
	var image := MapImage.new() as Sprite2D
	image.name = "ImportedImage"
	image.source_data = data
	image.source_format = "png"
	image.original_filename = "legacy.png"
	creative._ensure_image_container().add_child(image, true)
	image.global_position = position
	image.owner = creative._level_root()
	return image


func _run() -> void:
	var level: Node = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	root.add_child(level)
	_disable_physics(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.active = true
	creative._ensure_editor_resources()
	_check("import button removed", creative._monster_palette.find_child("ImportImageButton", true, false) == null)
	_check("image file dialog removed", creative.find_child("ImportMapImage", true, false) == null)
	var bitmap := Image.create_empty(4, 4, false, Image.FORMAT_RGBA8)
	bitmap.fill(Color.TRANSPARENT)
	bitmap.set_pixel(2, 1, Color.BLUE)
	var data := bitmap.save_png_to_buffer()
	var image: Sprite2D = _add_legacy_image(creative, data, Vector2(98, 198))
	_check("existing image remains available", image != null and image.global_position == Vector2(98, 198)
		and image.source_format == "png")
	var surface: CanvasItem = level.get_node("SmallCanvas/CanvasSurface")
	var ink: CanvasItem = level.get_node("SmallCanvas/CanvasSurface/BlackTiles")
	var player_visual: CanvasItem = level.get_node("Player/Visual")
	_check("paper < imported image < ink < player", surface.z_index == -2
		and not surface.z_as_relative and image.z_index == -1 and not image.z_as_relative
		and ink.z_index == 0 and not ink.z_as_relative and player_visual.z_index > ink.z_index)
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
	var image2: Sprite2D = _add_legacy_image(creative, data, Vector2(98, 198))
	_check("right-click delete action", creative.delete_imported_image(image2))
	_check("delete undo restores existing image", creative.undo_last_edit()
		and creative._imported_images().size() == 2)
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
