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

func hinges(level) -> Array:
	return level.get_children().filter(func(node): return node is Hinge and not node.is_queued_for_deletion())

func _run() -> void:
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
		check("manual bearing placed at offset %d" % offset, surface.rod_layer.place_anchor(manual))
		canvas.generate()
		await process_frame
		var connections := hinges(level)
		check("manual bearing suppresses automatic axle at offset %d" % offset,
			connections.size() == 1 and not connections[0] is Axle)
		if connections.size() == 1:
			var bearing = connections[0]
			check("manual pivot and connection preserved at offset %d" % offset,
				bearing.joint != null and bearing.joint.is_active() and bearing.texture != null
				and bearing.yellow_position.is_equal_approx(canvas.world.to_local(surface.to_global(manual))))
			# 校验同一画布附近，但连接到其他物件的轴承不会抑制自动轴。
			check("unrelated wheel cannot borrow nearby bearing at offset %d" % offset,
				not canvas.solid._has_manual_gear_bearing(surface, level, level.get_node("Player").body, Vector2(100.5, 100.5)))
			# 模拟旧地图中已经保存的多余自动轴；恢复后应只保留手动连接。
			var redundant := Axle.new()
			redundant.gear_material = Palette.BLACK.id
			redundant.yellow_position = level.to_local(surface.to_global(Vector2(100.5, 100.5)))
			redundant.black_position = redundant.yellow_position
			level.add_child(redundant)
			await process_frame
			await process_frame
			check("legacy duplicate axle removed at offset %d" % offset, hinges(level).size() == 1)
			# 事务撤销与重做仍只恢复手动轴承，不补自动轴。
			check("solidification undo at offset %d" % offset, surface.undo_last_edit())
			check("solidification redo at offset %d" % offset, surface.redo_last_edit())
			await process_frame
			connections = hinges(level)
			check("redo keeps only manual bearing at offset %d" % offset,
				connections.size() == 1 and not connections[0] is Axle)
		level.queue_free()
		await process_frame
	print("[ManualGearBearing] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
