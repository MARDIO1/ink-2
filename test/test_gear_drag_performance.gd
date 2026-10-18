extends SceneTree

const Gear := preload("res://actor/canvas/src/gear_bearing.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	print("[GearPerf] %s %s" % ["PASS" if okay else "FAIL", label])
	failures += int(not okay)

func _run() -> void:
	var app = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	await process_frame
	await app.request_level_change("res://map/asset/imported/第三页.tscn")
	var level = app.level_root.get_child(0)
	level.auto_step = false
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.active = true
	var canvas = level.get_node("MapCanvas")
	canvas.set_map_editor_mode(true)
	creative._ensure_editor_resources()
	var gears: Array = level.get_children().filter(func(n): return n is Gear and not n.yellow_anchor.is_empty())
	check("real second page has gears", not gears.is_empty())
	if gears.is_empty():
		quit(1)
		return
	var gear = gears[0]
	var start: Vector2 = gear.global_position
	var draft_before := {}
	if OS.get_cmdline_user_args().has("--draft-circuit"):
		var local: Vector2 = canvas.surface.to_local(start)
		canvas.surface.brush_size = 1
		for row in 10:
			canvas.surface.blue_layer.begin(local + Vector2(-40, -40 + row * 8))
			canvas.surface.blue_layer.extend(local + Vector2(40, -40 + row * 8))
			canvas.surface.blue_layer.finish()
		draft_before = canvas.surface.blue_layer.mask.duplicate()
	var before: int = canvas.surface._undo_steps.size()
	var tick := Time.get_ticks_usec()
	creative.editor_drag_begin(gear, start)
	var select_us := Time.get_ticks_usec() - tick
	check("selection defers snapshot", creative._gear_drag_history.is_empty())
	creative.editor_drag_finish()
	check("click leaves undo history unchanged", canvas.surface._undo_steps.size() == before)
	creative.editor_drag_begin(gear, start)
	var first_us := 0
	var motion_us := 0
	for i in 40:
		var event := InputEventMouseMotion.new()
		event.position = root.get_canvas_transform() * (start + Vector2(i + 1, -20))
		tick = Time.get_ticks_usec()
		creative.editor_mouse_motion(event)
		var elapsed := Time.get_ticks_usec() - tick
		if i == 0:
			first_us = elapsed
		else:
			motion_us += elapsed
	check("movement records pose without rasterizing bodies or canvas", creative._gear_drag_history.has("gear_pose")
		and not creative._gear_drag_history.has("image") and not creative._gear_drag_history.has("bodies"))
	if not draft_before.is_empty():
		check("draft circuit moves with gear", canvas.surface.blue_layer.mask != draft_before)
	creative.editor_drag_cancel()
	check("cancel restores gear and leaves history unchanged", gear.global_position.is_equal_approx(start)
		and canvas.surface._undo_steps.size() == before and gear.joint != null)
	if not draft_before.is_empty():
		check("cancel restores full draft circuit", canvas.surface.blue_layer.mask == draft_before)
	print("[GearPerf] select=%.3f ms first_motion=%.3f ms subsequent_mean=%.3f ms bodies=%d" % [
		select_us / 1000.0, first_us / 1000.0, motion_us / 39000.0, level.world.bodies.size()])
	app.queue_free()
	await process_frame
	await process_frame
	quit(1 if failures else 0)
