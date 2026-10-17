extends SceneTree
## 齿轮压在黄墨杠杆上时：杠杆必须保持一整条，轮子用铰链套在杠杆上转。

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")

var failures := 0
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, condition: bool) -> void:
	checks += 1
	print("[GearLever] %s %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1


func _body_with_cell(canvas, cell: Vector2i, material: int):
	var point: Vector2 = canvas.surface.to_global(Vector2(cell) + Vector2.ONE * 0.5)
	for body in canvas.world.world.bodies:
		if body.tags.has("living"):
			continue
		var local := Vector2i(body.to_local(point).floor())
		for shape in body.shapes:
			if shape.get_pixel(local.x, local.y) == material:
				return body
	return null


func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	current_scene = level
	await process_frame
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	canvas.active = true
	canvas.show()
	canvas.set_map_editor_mode(true)
	var surface = canvas.surface
	surface.ink_free = true
	surface.clear()
	# 一条横穿齿轮中心的黄墨杠杆。
	for x in range(60, 141):
		surface.rod_layer.pixels.set_pixel(x, 100, Palette.YELLOW.color)
	surface.rod_layer.anchor_points.append(Vector2(60.5, 100.5))
	surface.write_pixel(Vector2i(60, 100), Palette.BLACK.color)
	surface.refresh()
	# 齿轮压在杠杆中间。
	surface.gear_tool.begin(Vector2(100.5, 100.5), 12)
	surface.gear_tool.finish(Vector2(118.5, 100.5))
	check("gear center registered", surface.gear_centers.size() == 1)
	canvas.generate(false)
	await process_frame
	var left = _body_with_cell(canvas, Vector2i(70, 100), Palette.YELLOW.id)
	var right = _body_with_cell(canvas, Vector2i(130, 100), Palette.YELLOW.id)
	check("lever still exists on both sides", left != null and right != null)
	check("lever is one continuous body", left != null and left == right)
	var axles: Array = canvas.world.get_children().filter(
		func(node): return node is Axle and not node.is_queued_for_deletion())
	check("one axle created for the gear", axles.size() == 1)
	if axles.size() == 1:
		var axle = axles[0]
		check("axle hinges wheel to lever instead of pinning to world", not axle.fixed_to_world
			and not axle.black_anchor.is_empty() and axle.black_anchor.body == left)
		check("axle joint is active", axle.joint != null and axle.joint.is_active())
		check("no synthetic bearing sprite on yellow ink", axle.texture == null)
	var center_hinges: Array = canvas.world.get_children().filter(func(node):
		return node is Hinge and not node.is_queued_for_deletion() \
			and node.yellow_position.distance_to(Vector2(10100.5, -9899.5)) < 0.1)
	check("gear center has only one physical hinge", center_hinges.size() == 1)
	check("gear center does not show an extra bearing", center_hinges.size() == 1 and center_hinges[0].texture == null)
	var support_hinges: Array = canvas.world.get_children().filter(func(node):
		return node is Hinge and not node is Axle and not node.is_queued_for_deletion())
	check("other lever attachment keeps its bearing", support_hinges.size() == 1 and support_hinges[0].texture != null)
	# 直接走撤销快照的捕获/恢复，避免只验证首次固化。
	var saved: Dictionary = canvas.History.capture(canvas, true)
	canvas.History.restore(canvas, saved)
	await process_frame
	axles = canvas.world.get_children().filter(func(node): return node is Axle and not node.is_queued_for_deletion())
	check("history restore keeps hidden bearing", axles.size() == 1 and axles[0].texture == null)
	level.queue_free()
	await process_frame
	print("[GearLever] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
