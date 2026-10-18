extends SceneTree
const Palette := preload("res://ink/general/src/ink_palette.gd")
var failures := 0
var checks := 0
func _initialize() -> void:
	_run.call_deferred()
func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[RasterHoles] %s %s" % ["PASS" if okay else "FAIL", label])
func missing(surface, image: Image, body) -> int:
	var holes := 0
	for y in surface.canvas_size.y:
		for x in surface.canvas_size.x:
			var local := Vector2i(body.to_local(surface.to_global(Vector2(x + 0.5, y + 0.5))).floor())
			if body.shapes[0].get_pixel(local.x, local.y) != 0 and image.get_pixel(x, y).a < 0.5:
				holes += 1
	return holes
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
	canvas.canvas_size = Vector2i(160, 160)
	canvas.set_map_editor_mode(true)
	var surface = canvas.surface
	surface.ink_free = true
	for y in range(20, 40):
		for x in range(20, 110):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	canvas.generate(false)
	var body
	for item in level.get_children():
		if item.is_in_group("ink_item"):
			body = item.body
	body.rotation = 0.327
	body.update_aabb()
	var count: int = body.shapes[0].pixel_count()
	var path := "res://.codex-tmp/raster_holes.tscn"
	check("save succeeds", creative.export_map_to(path) == OK)
	check("saving alone preserves original physical pixels", body.shapes[0].pixel_count() == count)
	var preview: Image = canvas.solid.preview_image(surface, level)
	var holes := missing(surface, preview, body)
	print("[RasterHoles] preview missing pixels=%d" % holes)
	check("rotated preview has no interior holes", holes == 0)
	var moved := {}
	canvas.solid._sample_body_rect(surface, body, Rect2i(0, 0, 160, 160), {}, moved)
	holes = missing(surface, surface.black_image, body)
	print("[RasterHoles] selection sampling missing pixels=%d" % holes)
	check("rotated selection sampling has no interior holes", holes == 0)
	surface.clear()
	canvas.solid._sample_body(surface, body, {}, false)
	holes = missing(surface, surface.black_image, body)
	print("[RasterHoles] ink conversion missing pixels=%d" % holes)
	check("rotated ink conversion has no interior holes", holes == 0)
	# 保存文件再重载，区别“保存破坏像素”和“操作时已经采样出孔”。
	var packed: PackedScene = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var restored := packed.instantiate()
	restored.auto_step = false
	root.add_child(restored)
	await process_frame
	var loaded_body
	for item in restored.get_children():
		if item.is_in_group("ink_item"):
			loaded_body = item.body
	check("disk reload retains full solid rectangle and angle", loaded_body != null and loaded_body.shapes[0].pixel_count() == count and is_equal_approx(loaded_body.rotation, body.rotation))
	restored.queue_free()
	for angle in [-0.8, 0.0, PI / 2.0]:
		body.rotation = angle
		body.update_aabb()
		surface.clear()
		canvas.solid._sample_body(surface, body, {}, false)
		check("projection covers all interior cells at angle %.3f" % angle, missing(surface, surface.black_image, body) == 0)
	body.rotation = 0.327
	body.update_aabb()
	for y in range(25, 35):
		for x in range(45, 55):
			body.shapes[0].clear_pixel(x, y)
	surface.clear()
	canvas.solid._sample_body(surface, body, {}, false)
	var hole := Vector2i(surface.to_local(body.to_world(Vector2(50.5,30.5))).floor())
	check("real intentional hole remains transparent", surface.black_image.get_pixelv(hole).a == 0.0)
	var clip := Rect2i(30, 30, 20, 20)
	var selected := {Vector2i(35,35): true}
	var samples: Dictionary = canvas.solid._project_body(surface,body,clip,selected)
	check("clipping and selection mask never write outside requested cells", samples.keys().all(func(at): return clip.has_point(at) and selected.has(at)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	level.queue_free()
	await process_frame
	print("[RasterHoles] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)

