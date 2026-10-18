extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[ManualGearBearing] %s %s" % ["PASS" if ok else "FAIL", label])

func connections(level) -> Array:
	return level.get_children().filter(func(node):
		return node is Hinge and not node.is_queued_for_deletion())

func _run() -> void:
	# 没有手动点击时，固化后的齿轮必须保持完全自由。
	var plain = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	plain.auto_step = false
	root.add_child(plain)
	await process_frame
	plain.get_node("Creative").auto_save_edits = false
	plain.get_node("Creative").auto_save_on_exit = false
	var plain_canvas = plain.get_node("MapCanvas")
	plain_canvas.position = Vector2(10000, -10000)
	plain_canvas.canvas_size = Vector2i(256, 256)
	plain_canvas.set_map_editor_mode(true)
	plain_canvas.surface.ink_free = true
	plain_canvas.surface.gear_tool.begin(Vector2(100, 100), 12)
	plain_canvas.surface.gear_tool.finish(Vector2(124, 100))
	plain_canvas.generate()
	check("solidify without a bearing click creates no connection", connections(plain).is_empty())
	plain.queue_free()
	await process_frame

	for offset in [-12, -5, 0, 6, 12]:
		var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
		level.auto_step = false
		root.add_child(level)
		await process_frame
		level.get_node("Creative").auto_save_edits = false
		level.get_node("Creative").auto_save_on_exit = false
		var canvas = level.get_node("MapCanvas")
		canvas.position = Vector2(10000, -10000)
		canvas.canvas_size = Vector2i(256, 256)
		canvas.set_map_editor_mode(true)
		var surface = canvas.surface
		surface.ink_free = true
		surface.selected_ink = 0
		surface.gear_tool.begin(Vector2(100, 100), 12)
		surface.gear_tool.finish(Vector2(124, 100))
		for x in range(55, 146):
			surface.rod_layer.pixels.set_pixel(x, 100, Palette.YELLOW.color)
		var manual := Vector2(100.5 + offset, 100.5)
		check("manual bearing click accepted at offset %d" % offset,
			surface.rod_layer.place_anchor(manual))
		canvas.generate()
		await process_frame
		var linked := connections(level)
		check("exactly one explicit connection at offset %d" % offset, linked.size() == 1)
		if linked.size() == 1:
			var bearing = linked[0]
			check("connection is active at offset %d" % offset,
				bearing.joint != null and bearing.joint.is_active())
			if bearing is Axle:
				check("centered manual bearing follows the yellow support, not the world at offset %d" % offset,
					not bearing.fixed_to_world and not bearing.black_anchor.is_empty())
				check("manual bearing snap point equals wheel center at offset %d" % offset,
					bearing.yellow_anchor.body.to_world(bearing.yellow_anchor.local)
						.is_equal_approx(surface.to_global(Vector2(100.5, 100.5))))
			check("solidification undo at offset %d" % offset, surface.undo_last_edit())
			check("solidification undo leaves no connection at offset %d" % offset,
				connections(level).is_empty())
			check("solidification redo at offset %d" % offset, surface.redo_last_edit())
			await process_frame
			check("redo restores exactly one connection at offset %d" % offset,
				connections(level).size() == 1)
		level.queue_free()
		await process_frame
	print("[ManualGearBearing] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
