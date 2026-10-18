extends SceneTree
const Nail := preload("res://actor/nail/src/nail.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
var checks := 0
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[SelectionNails] %s %s" % ["PASS" if okay else "FAIL", label])
func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000,-10000)
	canvas.canvas_size = Vector2i(96,96)
	canvas.set_map_editor_mode(true)
	var surface = canvas.surface
	surface.ink_free = true
	for kind in [Nail.Kind.FIXED, Nail.Kind.BACKGROUND, Nail.Kind.INFINITE]:
		surface.clear()
		var inside := Vector2i(20,20)
		var outside := Vector2i(60,60)
		# 黄墨图层不占黑墨瓦片；这是原来漏删的情况。
		surface.rod_layer.pixels.set_pixelv(inside, Palette.YELLOW.color)
		surface.rod_layer.refresh()
		surface.nail_layer.add(inside,kind)
		surface.nail_layer.add(outside,kind)
		canvas._delete_selection(Rect2i(15,15,20,20))
		check("draft nail removed with yellow ink, kind %d" % kind, surface.nail_layer.kind_at(inside) == -1 and surface.rod_layer.pixels.get_pixelv(inside).a == 0.0)
		check("outside nail retained, kind %d" % kind, surface.nail_layer.kind_at(outside) == kind)
		check("undo restores nail and yellow ink, kind %d" % kind, surface.undo_last_edit() and surface.nail_layer.kind_at(inside) == kind and surface.rod_layer.pixels.get_pixelv(inside).a > 0.5)
		check("redo removes nail again, kind %d" % kind, surface.redo_last_edit() and surface.nail_layer.kind_at(inside) == -1)
		surface.clear()
		surface.nail_layer.add(inside,kind)
		surface.nail_layer.add(outside,kind)
		canvas._delete_selection(Rect2i(0,0,96,96),{"circle_rect": Rect2i(15,15,12,12)})
		check("selection mask deletes only included nail on transparent canvas, kind %d" % kind, surface.nail_layer.kind_at(inside) == -1 and surface.nail_layer.kind_at(outside) == kind)
	# 实体上的固定钉子：框删后外观和锚点都不能留下，撤销须恢复。
	surface.clear()
	for y in range(20,30):
		for x in range(20,40):
			surface.write_pixel(Vector2i(x,y), Palette.BLACK.color)
	surface.write_pixel(Vector2i(25,25),surface.nail_color())
	canvas.generate(false)
	var before: int = level.get_children().filter(func(n): return n is Nail and not n.is_queued_for_deletion()).size()
	check("solid nail fixture created", before > 0)
	canvas._delete_selection(Rect2i(20,20,20,10))
	await process_frame
	check("solid nail visual removed with body", level.get_children().filter(func(n): return n is Nail and not n.is_queued_for_deletion()).is_empty() and surface.nail_layer.nails.is_empty())
	check("solid deletion undo succeeds", surface.undo_last_edit())
	await process_frame
	check("solid deletion undo restores nail visual", not level.get_children().filter(func(n): return n is Nail and not n.is_queued_for_deletion()).is_empty())
	for kind in [Nail.Kind.BACKGROUND,Nail.Kind.INFINITE]:
		surface.clear()
		for y in range(50,60):
			for x in range(20,40):
				surface.write_pixel(Vector2i(x,y), Palette.BLACK.color)
		surface.nail_layer.add(Vector2i(25,55),kind)
		canvas.generate(false)
		canvas._delete_selection(Rect2i(20,50,20,10))
		await process_frame
		var remaining: Array = level.get_children().filter(func(n): return n is Nail and n.kind == kind and not n.is_queued_for_deletion())
		check("solid nail removed, kind %d" % kind, remaining.is_empty() and surface.nail_layer.kind_at(Vector2i(25,55)) == -1)
	level.queue_free()
	await process_frame
	print("[SelectionNails] %d checks, %d failures" %[checks,failures])
	quit(1 if failures else 0)


