extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Surface := preload("res://actor/canvas/src/canvas_surface.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, condition: bool) -> void:
	print("[YellowErase] %s %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1


func _run() -> void:
	var level = load("res://map/asset/imported/main.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var canvas = level.get_node("MapCanvas")
	canvas.canvas_size = Vector2i(96, 96)
	var surface = canvas.surface
	surface.clear()
	surface.write_pixel(Vector2i(40, 40), Palette.BLACK.color)
	surface.rod_layer.begin(Vector2(40, 40))
	surface.rod_layer.finish(Vector2(40, 40))
	_check("overlapping black and yellow ink exist", surface.material_at(40, 40) == Palette.BLACK.id
		and surface.rod_layer.pixels.get_pixel(40, 40).a > 0.5)
	surface.selected_ink = 0
	surface.tool = Surface.Tool.ERASER
	surface._begin_undo_step()
	surface._painting = true
	surface._rod_drawing = true
	surface.rod_layer.begin(Vector2(40, 40), true)
	surface._stroke(Vector2(40, 40), Vector2(40, 40), Color.TRANSPARENT)
	surface._finish_rod_stroke(Vector2(40, 40))
	_check("eraser removes both layers regardless of selected ink",
		surface.material_at(40, 40) == 0 and surface.rod_layer.pixels.get_pixel(40, 40).a < 0.5)
	_check("one undo restores both erased layers", surface.undo_last_edit()
		and surface.material_at(40, 40) == Palette.BLACK.id
		and surface.rod_layer.pixels.get_pixel(40, 40).a > 0.5)
	_check("one redo erases both layers again", surface.redo_last_edit()
		and surface.material_at(40, 40) == 0
		and surface.rod_layer.pixels.get_pixel(40, 40).a < 0.5)
	surface.undo_last_edit()
	canvas._delete_selection(Rect2i(39, 39, 3, 3))
	_check("box delete removes independent yellow layer",
		surface.material_at(40, 40) == 0 and surface.rod_layer.pixels.get_pixel(40, 40).a < 0.5)
	_check("box delete undo restores both layers", surface.undo_last_edit()
		and surface.material_at(40, 40) == Palette.BLACK.id
		and surface.rod_layer.pixels.get_pixel(40, 40).a > 0.5)
	_check("box delete redo clears both layers", surface.redo_last_edit()
		and surface.material_at(40, 40) == 0
		and surface.rod_layer.pixels.get_pixel(40, 40).a < 0.5)
	surface.write_pixel(Vector2i(20, 20), Palette.BLACK.color)
	surface.write_pixel(Vector2i(70, 20), Palette.BLACK.color)
	var yellow = surface.yellow_rule()
	yellow.begin(surface, Vector2(20, 20))
	var spring_created: bool = yellow.finish(surface, Vector2(70, 20))
	_check("yellow spring created", spring_created and yellow.strokes.size() == 1)
	canvas._delete_selection(Rect2i(19, 15, 53, 12))
	_check("box delete removes yellow spring", yellow.strokes.is_empty())
	_check("box delete undo restores yellow spring", surface.undo_last_edit()
		and yellow.strokes.size() == 1)
	surface.tool = Surface.Tool.ERASER
	surface._begin_undo_step()
	surface._painting = true
	surface._rod_drawing = true
	surface.rod_layer.begin(Vector2(45, 20), true)
	surface._finish_rod_stroke(Vector2(45, 20))
	_check("eraser removes yellow spring when touching its middle", yellow.strokes.is_empty())
	_check("spring erasure undo restores it", surface.undo_last_edit()
		and yellow.strokes.size() == 1)
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
