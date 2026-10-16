extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Surface := preload("res://actor/canvas/src/canvas_surface.gd")
const SelectionMask := preload("res://actor/canvas/src/selection_mask.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, ok: bool) -> void:
	print("[CircleSelection] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
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
	canvas._on_selection_picked(Surface.Tool.SELECT_CIRCLE)
	_check("selection menu activates circular tool", surface.tool == Surface.Tool.SELECT_CIRCLE)
	var rect: Rect2i = surface._circle_selection_rect(Vector2(20, 20), Vector2(40, 40))
	surface._selected_rect = rect
	surface._selected_circle = true
	surface.selection_overlay.set_selection(rect, true)
	var mask: Dictionary = surface.selection_mask()
	_check("circle expands from the pressed point as center",
		rect.size.x == rect.size.y and rect.size.x % 2 == 1
		and rect.position + rect.size / 2 == Vector2i(20, 20))
	_check("mask includes center but excludes bounding corner",
		SelectionMask.contains(mask, Vector2i(20, 20))
		and not SelectionMask.contains(mask, rect.position))
	var corner := rect.position
	surface.write_pixel(Vector2i(20, 20), Palette.BLACK.color)
	surface.write_pixel(corner, Palette.RED.color)
	surface.rod_layer.begin(Vector2(20, 20))
	surface.rod_layer.finish(Vector2(20, 20))
	canvas._delete_selection(rect, mask)
	_check("delete only clears circular area",
		surface.material_at(20, 20) == 0
		and surface.rod_layer.pixels.get_pixel(20, 20).a < 0.5
		and surface.material_at(corner.x, corner.y) == Palette.RED.id)
	_check("circle delete is undoable", surface.undo_last_edit()
		and surface.material_at(20, 20) == Palette.BLACK.id
		and surface.rod_layer.pixels.get_pixel(20, 20).a > 0.5)
	canvas._move_selection(rect, Vector2i(20, 0), mask)
	_check("move only shifts circular content",
		surface.material_at(20, 20) == 0
		and surface.material_at(40, 20) == Palette.BLACK.id
		and surface.material_at(corner.x, corner.y) == Palette.RED.id)
	_check("circle move is undoable", surface.undo_last_edit()
		and surface.material_at(20, 20) == Palette.BLACK.id
		and surface.material_at(40, 20) == 0)
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
