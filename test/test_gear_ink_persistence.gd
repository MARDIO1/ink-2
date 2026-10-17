extends SceneTree
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	print("[GearInkPersistence] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(192, 192)
	canvas.set_map_editor_mode(true)
	var surface = canvas.surface
	surface.ink_free = true
	for color in Palette.INKS.size():
		surface.clear()
		surface.selected_ink = color
		surface.gear_tool.begin(Vector2(80, 80), 12)
		surface.gear_tool.finish(Vector2(110, 80))
		check("selected ink %d fills the whole gear" % color,
			surface.material_at(90, 80) == surface.ink_material_id() and surface.material_at(80, 80) == surface.ink_material_id())
	var image: PackedByteArray = surface.black_image.get_data()
	var path := "user://gear_snapshot_%d.snapshot" % Time.get_ticks_usec()
	surface.request_snapshot(path)
	while surface._snapshot_task != -1:
		surface._poll_snapshot()
		await process_frame
	surface.clear()
	check("background snapshot reload", surface.load_ink(path) == OK)
	check("background snapshot preserves image and axle", surface.black_image.get_data() == image and surface.gear_centers == PackedVector2Array([Vector2(80.5, 80.5)]))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	check("resize translates shaft metadata", surface.resize_preserving_content(Vector2i(224, 224), Vector2i(10, 10)) and surface.gear_centers == PackedVector2Array([Vector2(90.5, 90.5)]))
	# 场景资源保留旧路径兼容，旧地图无需改写。
	var legacy = load("res://actor/canvas/src/gear_bearing.gd").new()
	check("legacy map bearing is a standard yellow axle", legacy is Axle)
	legacy.free()
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
