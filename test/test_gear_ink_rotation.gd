extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Surface := preload("res://actor/canvas/src/canvas_surface.gd")
const Bearing := preload("res://ink/yellow/src/axle.gd")
const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	print("[GearInkRotation] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func bearings(level) -> Array:
	return level.get_children().filter(func(node): return node is Bearing and not node.is_queued_for_deletion())

func select(surface, rect: Rect2i, circle := false) -> void:
	surface.tool = Surface.Tool.SELECT_CIRCLE if circle else Surface.Tool.SELECT_DELETE
	surface._selected_rect = rect
	surface._selected_circle = circle
	surface.selection_overlay.set_selection(rect, circle)

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	canvas.set_map_editor_mode(true)
	var surface = canvas.surface
	surface.ink_free = true
	surface.selected_ink = 0
	var tool = surface.gear_tool
	tool.begin(Vector2(96, 96), 8)
	tool.finish(Vector2(128, 96))
	check("placement is ink, not a body or bearing", surface.material_at(108, 96) == Palette.BLACK.id and bearings(level).is_empty())
	check("placement is one solid ink shape with no yellow hub", surface.material_at(96, 96) == Palette.BLACK.id and surface.material_at(99, 96) == Palette.BLACK.id and surface.material_at(99, 99) == Palette.BLACK.id)
	check("draft remembers its axle", surface.gear_centers == PackedVector2Array([Vector2(96.5, 96.5)]))
	surface._begin_undo_step()
	surface._set_pixel_raw(Vector2i(96, 96), Color.TRANSPARENT)
	surface._commit_undo_step()
	check("erasing center removes draft axle", surface.gear_centers.is_empty())
	check("brush erasure undo restores axle", surface.undo_last_edit() and surface.gear_centers.size() == 1)
	check("brush erasure redo removes axle", surface.redo_last_edit() and surface.gear_centers.is_empty())
	surface.undo_last_edit()
	var original: PackedByteArray = surface.black_image.get_data()
	check("ink gear placement undo", surface.undo_last_edit() and surface.gear_centers.is_empty() and surface.black_image.get_used_rect().size == Vector2i.ZERO)
	check("ink gear placement redo", surface.redo_last_edit() and surface.black_image.get_data() == original and surface.gear_centers.size() == 1)
	var rect := Rect2i(56, 56, 81, 81)
	var blueprint: Dictionary = Codec.capture(canvas, rect)
	check("blueprint stores draft axle", not blueprint.has("error") and blueprint.get("gear_centers", []).size() == 1)
	select(surface, rect)
	var key := InputEventKey.new()
	key.keycode = KEY_R
	key.pressed = true
	canvas._input(key)
	check("R rotates exactly 2 degrees", is_equal_approx(canvas._selection_rotation.cache.get("angle", 0.0), deg_to_rad(2.0)) and surface.black_image.get_data() != original)
	key.echo = true
	canvas._input(key)
	check("key repeat cannot rotate unexpectedly", is_equal_approx(canvas._selection_rotation.cache.angle, deg_to_rad(2.0)))
	key.echo = false
	for i in 179:
		canvas._input(key)
	check("180 presses restore exact raster without erosion", surface.black_image.get_data() == original)
	check("rotation undo and redo", surface.undo_last_edit() and surface.redo_last_edit() and surface.black_image.get_data() == original)
	canvas.generate()
	check("solidify creates one axle on the gear's own ink", bearings(level).size() == 1 and bearings(level)[0].gear_material == Palette.BLACK.id and bearings(level)[0].joint != null)
	check("generated gear is pure ink at its center", not bearings(level).is_empty() and Bearing.has_pixel(bearings(level)[0].yellow_anchor.body, bearings(level)[0].yellow_anchor.cell, Palette.BLACK.id))
	select(surface, rect)
	canvas._move_selection(rect, Vector2i(12, 0))
	check("physical selection moves axle with ink", bearings(level).size() == 1 and is_equal_approx(bearings(level)[0].yellow_position.x, 10108.5))
	select(surface, Rect2i(68, 56, 81, 81))
	check("physical selection rotates with axle", canvas._selection_rotation.apply(canvas) and bearings(level).size() == 1)
	canvas.return_to_canvas()
	check("reclaim restores ink and removes axle", bearings(level).is_empty() and surface.gear_centers.size() == 1)
	canvas.generate()
	check("re-solidify restores axle", bearings(level).size() == 1)
	canvas.return_to_canvas()
	surface.clear()
	surface._undo_steps.clear()
	surface._redo_steps.clear()
	for x in range(90, 111):
		surface._set_pixel_raw(Vector2i(x, 100), Palette.RED.color)
	surface._set_pixel_raw(Vector2i(60, 60), Palette.BLUE.color)
	select(surface, Rect2i(60, 60, 81, 81), true)
	check("circle rotation works", canvas._selection_rotation.apply(canvas))
	check("circle rotation preserves outside corner", surface.material_at(60, 60) == Palette.BLUE.id)
	check("circle rotation undo", surface.undo_last_edit() and surface.material_at(100, 100) == Palette.RED.id)
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
