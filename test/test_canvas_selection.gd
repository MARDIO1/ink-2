extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Surface := preload("res://actor/canvas/src/canvas_surface.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, ok: bool) -> void:
	print("[CanvasSelection] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var canvas = level.get_node("MapCanvas")
	canvas.canvas_size = Vector2i(96, 96)
	var surface = canvas.surface
	surface.clear()
	surface.write_pixel(Vector2i(20, 20), Palette.BLACK.color)
	surface.write_pixel(Vector2i(21, 20), Palette.RED.color)
	surface.write_pixel(Vector2i(22, 20), surface.nail_color())
	surface.rod_layer.begin(Vector2(20, 20))
	surface.rod_layer.finish(Vector2(20, 20))
	var source := Rect2i(19, 19, 5, 3)
	var offset := Vector2i(10, 4)
	canvas._move_selection(source, offset)
	_check("selection moves black, red, nail and yellow together",
		surface.material_at(20, 20) == 0 and surface.material_at(30, 24) == Palette.BLACK.id
		and surface.material_at(31, 24) == Palette.RED.id
		and surface.nail_layer.nails.has(Vector2i(32, 24))
		and surface.rod_layer.pixels.get_pixel(20, 20).a < 0.5
		and surface.rod_layer.pixels.get_pixel(30, 24).a > 0.5)
	_check("one undo restores all selected layers", surface.undo_last_edit()
		and surface.material_at(20, 20) == Palette.BLACK.id
		and surface.material_at(30, 24) == 0
		and surface.rod_layer.pixels.get_pixel(20, 20).a > 0.5)
	_check("redo moves all selected layers again", surface.redo_last_edit()
		and surface.material_at(30, 24) == Palette.BLACK.id
		and surface.rod_layer.pixels.get_pixel(30, 24).a > 0.5)
	canvas._map_editor_mode = true
	surface.tool = Surface.Tool.SELECT_DELETE
	surface._selected_rect = Rect2i(source.position + offset, source.size)
	surface.selection_overlay.set_selection(surface._selected_rect)
	var backspace := InputEventKey.new()
	backspace.pressed = true
	backspace.keycode = KEY_BACKSPACE
	canvas._input(backspace)
	_check("Backspace deletes selected content and clears frame",
		surface.material_at(30, 24) == 0
		and surface.rod_layer.pixels.get_pixel(30, 24).a < 0.5
		and not surface.has_selection())
	_check("Backspace deletion is undoable", surface.undo_last_edit()
		and surface.material_at(30, 24) == Palette.BLACK.id
		and surface.rod_layer.pixels.get_pixel(30, 24).a > 0.5)
	# Ctrl+左拖只平移框；普通左拖仍由 selection_move_requested 搬动内容。
	surface._selected_rect = Rect2i(29, 23, 5, 3)
	surface._selection_drag_start = surface._selected_rect
	surface._selection_frame_only_drag = true
	surface._complete_selection_drag(Vector2i(8, 0))
	_check("Ctrl+left drag moves frame without moving selected image",
		surface.selection_rect() == Rect2i(37, 23, 5, 3)
		and surface.material_at(30, 24) == Palette.BLACK.id
		and surface.material_at(38, 24) == 0)
	_check("right click helper deletes inside selection",
		canvas._try_delete_selection_at(Vector2i(38, 24))
		and not surface.has_selection())
	surface.clear()
	for y in range(40, 44):
		for x in range(40, 44):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	var body_count: int = level.world.bodies.size()
	canvas.generate(false)
	_check("physical selection setup solidifies into a body",
		level.world.bodies.size() == body_count + 1)
	canvas._move_selection(Rect2i(39, 39, 6, 6), Vector2i(15, 0))
	var moved_body := false
	for body in level.world.bodies:
		if body.aabb.has_point(surface.to_global(Vector2(56, 41))):
			moved_body = true
			break
	_check("moved solidified ink stays physical without duplicate blueprint",
		moved_body and surface.material_at(56, 41) == 0)
	_check("solidified selection move is undoable", surface.undo_last_edit())
	_check("solidified selection move is redoable", surface.redo_last_edit())
	surface.clear()
	surface.write_pixel(Vector2i(40, 40), Palette.BLACK.color)
	surface.write_pixel(Vector2i(70, 40), Palette.BLACK.color)
	var yellow = surface.yellow_rule()
	yellow.begin(surface, Vector2(40, 40))
	var made_spring: bool = yellow.finish(surface, Vector2(70, 40))
	_check("spring created for move test", made_spring)
	var old_start: Vector2 = yellow.strokes[0].path[0] if made_spring else Vector2.ZERO
	canvas._move_selection(Rect2i(39, 35, 33, 11), Vector2i(0, 15))
	_check("fully selected spring moves with its anchors",
		yellow.strokes.size() == 1 and yellow.strokes[0].path[0] == old_start + Vector2(0, 15)
		and surface.material_at(40, 55) == Palette.BLACK.id)
	_check("spring move undo restores position", surface.undo_last_edit()
		and yellow.strokes.size() == 1 and yellow.strokes[0].path[0] == old_start)
	# 新实体会延迟注入物理世界；先让回调完成，再销毁测试关卡。
	for _frame in range(3):
		await process_frame
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
