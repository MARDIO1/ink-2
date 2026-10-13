extends SceneTree
const Palette := preload("res://ink/src/ink_palette.gd")
const Query := preload("res://addons/pixel_destruction/physics/query.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, ok: bool) -> void:
	print("[CanvasShrink] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _run() -> void:
	var level: Node = load("res://map/main.tscn").instantiate()
	root.add_child(level)
	await process_frame
	level.get_node("SimulationRuntime").set_physics_process(false)
	var canvas: Node = level.get_node("SmallCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(96, 96)
	canvas.set_ink_free(true)
	var surface: Node = canvas.surface
	surface._set_pixel_raw(Vector2i(5, 5), Palette.BLACK.color)
	surface._set_pixel_raw(Vector2i(30, 30), Palette.RED.color)
	surface._place_nail(Vector2(6, 8))
	surface._place_nail(Vector2(31, 31))
	surface.refresh()
	var original: PackedByteArray = surface.black_image.get_data()
	var expected_red: Color = surface.black_image.get_pixel(30, 30)
	var old_position: Vector2 = canvas.position
	_check("negative sides shrink", canvas.expand_canvas_sides(-16, -8, -16, -8) and canvas.canvas_size == Vector2i(72, 72))
	_check("left/top shrink preserves world pixel position", canvas.position == old_position + Vector2(16, 16) and surface.black_image.get_pixel(14, 14) == expected_red)
	_check("cropped pixels removed", surface.black_image.get_pixel(5, 5).a == 0.0)
	_check("nails cropped and shifted", not surface.nail_layer.nails.has(Vector2i(6, 8)) and surface.nail_layer.nails.has(Vector2i(15, 15)))
	_check("shrink undo restores exact state", surface.undo_last_edit() and canvas.canvas_size == Vector2i(96, 96) and canvas.position == old_position and surface.black_image.get_data() == original)
	_check("balanced sides are not a no-op", canvas.expand_canvas_sides(-16, 16, 0, 0) and canvas.canvas_size == Vector2i(96, 96) and canvas.position.x == old_position.x + 16)
	surface.undo_last_edit()
	_check("invalid size rejected without mutation", not canvas.expand_canvas_sides(-96, 0, 0, 0) and canvas.canvas_size == Vector2i(96, 96) and surface.black_image.get_data() == original)
	# 已固化实体跨过缩小边缘时，只删除越界部分；一键恢复整个实体。
	surface.clear(false)
	surface._stroke(Vector2(30, 40), Vector2(70, 40), Palette.BLACK.color)
	surface._flush_ink()
	var drawing: PackedByteArray = surface.black_image.get_data()
	var before: int = level.world.bodies.size()
	canvas.generate()
	var solid_count: int = level.world.bodies.size()
	_check("solid shape created", solid_count > before)
	canvas.expand_canvas_sides(0, -48, 0, 0)
	var found_outside := false
	var found_inside := false
	for body in level.world.bodies:
		if body.aabb.intersects(Rect2(old_position, Vector2(96, 96))) and not body.tags.has("living"):
			found_outside = found_outside or Query.solid_at(body, old_position + Vector2(65, 40))
			found_inside = found_inside or Query.solid_at(body, old_position + Vector2(35, 40))
	_check("solid outside deleted and inside preserved", not found_outside and found_inside)
	_check("solid crop undo restores entity", surface.undo_last_edit() and canvas.canvas_size == Vector2i(96, 96) and level.world.bodies.size() == solid_count)
	_check("previous solidify undo still works", surface.undo_last_edit() and level.world.bodies.size() == before and surface.black_image.get_data() == drawing)
	var yellow = surface.yellow_rule()
	surface._stroke(Vector2(20, 60), Vector2(20, 60), Palette.BLACK.color)
	surface._stroke(Vector2(70, 60), Vector2(70, 60), Palette.BLACK.color)
	surface._flush_ink()
	yellow.begin(surface, Vector2(20, 60))
	_check("yellow draft made", yellow.finish(surface, Vector2(70, 60)))
	var yellow_before: int = yellow.strokes[0].cells.size()
	canvas.expand_canvas_sides(0, -48, 0, 0)
	var yellow_outside := false
	for stroke in yellow.strokes:
		for cell in stroke.cells:
			if surface.to_local(stroke.pixel_world(Vector2(cell) + Vector2.ONE * 0.5)).x >= 48:
				yellow_outside = true
	_check("yellow pixels outside cropped", not yellow_outside and yellow.strokes[0].cells.size() < yellow_before)
	var yellow_undone: bool = surface.undo_last_edit()
	_check("yellow crop undo restores all cells", yellow_undone and yellow.strokes[0].cells.size() == yellow_before)
	canvas.set_map_editor_mode(true)
	_check("dialog accepts negative values", canvas._expand_inputs.Left.min_value < 0 and canvas._expand_inputs.Left.step == 1)
	canvas._expand_inputs.Left.value = -96
	canvas._update_expand_size_preview()
	_check("dialog warns about invalid dimensions", canvas._expand_size_preview.text.contains("至少"))
	await process_frame
	await process_frame
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
