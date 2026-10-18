extends SceneTree
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
func shape_data(body) -> Dictionary:
	var data := {}
	for key in body.shapes[0].chunks:
		var chunk = body.shapes[0].chunks[key]
		data[key] = [chunk.occ, chunk.mat.duplicate()]
	return data

var checks := 0
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[EditorDocument] %s %s" % ["PASS" if okay else "FAIL", label])
func setup(level: Node) -> Node:
	level.auto_step = false
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	return creative
func _run() -> void:
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	current_scene = app
	var fixture = load("res://test/fixtures/maps/base_level.tscn")
	var level: Node = await app.load_level(fixture, true)
	var creative = setup(level)
	creative._activate_restored_editor()
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(160, 160)
	var surface = canvas.surface
	surface.ink_free = true
	for y in range(30, 50):
		for x in range(30, 70):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	canvas.generate()
	var node: Node
	for item in level.get_children():
		if item.is_in_group("ink_item"):
			node = item
	check("fixture creates solid body", node != null)
	surface.blue_layer.begin(Vector2(35.5, 35.5))
	surface.blue_layer.extend(Vector2(60.5, 35.5))
	surface.blue_layer.finish()
	canvas.generate()
	node.body.rotation = 0.327
	node.body.position += Vector2(0.25, 0.75)
	node.body.update_aabb()
	var solid_name: String = node.name
	var solid_pixels: int = node.body.shapes[0].pixel_count()
	var original_shape := shape_data(node.body)
	var original_wire: PackedVector2Array = surface.blue_rule().objects(Wire).filter(func(w): return w.active and w.body == node.body)[0].cells.duplicate()
	var solid_position: Vector2 = node.body.position
	var solid_rotation: float = node.body.rotation
	for y in range(90, 102):
		for x in range(80, 95):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	surface.blue_layer.begin(Vector2(82.5, 92.5))
	surface.blue_layer.extend(Vector2(91.5, 92.5))
	surface.blue_layer.finish()
	surface.write_pixel(Vector2i(85, 96), surface.nail_color())
	var raw: PackedByteArray = surface.black_image.get_data()
	var blue: PackedVector2Array = surface.blue_layer.cells.duplicate()
	var nails: Dictionary = surface.nail_layer.snapshot()
	var undo_count: int = surface.undo_depth()
	canvas.set_tool(surface.Tool.GEAR)
	var tool: int = surface.tool
	var body_count: int = level.world.bodies.size()
	var path := "res://.codex-tmp/mixed_editor_document.tscn"
	for index in 3:
		check("save succeeds %d" % index, creative.export_map_to(path) == OK)
		check("save preserves live draft pixels and blue %d" % index,
			surface.black_image.get_data() == raw and surface.blue_layer.cells == blue)
		check("save preserves solid identity and original shape %d" % index,
			node.body.shapes[0].pixel_count() == solid_pixels and level.world.bodies.size() == body_count)
		check("save preserves tool and undo %d" % index, surface.tool == tool and surface.undo_depth() == undo_count)
	# 自动保存的墨水快照由 test_editor_autosave_snapshot.gd 单独覆盖；
	# 这里保持纯手动保存，避免自动保存的墨化改变后续 F2 检查的实体状态。
	var preview_path := "user://document_preview.png"
	check("preview bake succeeds", canvas.bake_png(preview_path) == OK)
	check("preview leaves drafts, tool and history untouched", surface.black_image.get_data() == raw and surface.blue_layer.cells == blue and surface.tool == tool and surface.undo_depth() == undo_count)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(preview_path))
	var saved: PackedScene = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var unmounted := saved.instantiate()
	check("scene contains authoritative embedded draft", not unmounted.get_node("Creative").editor_draft.is_empty())
	unmounted.free()
	# 关闭退出写盘，单独验证 F2 的内存检查点往返；退出快照由独立测试覆盖。
	creative.auto_save_on_exit = false
	creative.map_path = "res://.codex-tmp/f2_must_not_save.tscn"
	var forbidden := ProjectSettings.globalize_path(creative.map_path)
	if FileAccess.file_exists(forbidden):
		DirAccess.remove_absolute(forbidden)
	for index in 3:
		creative.set_active(false)
		check("F2 preview compiles draft without saving %d" % index, not FileAccess.file_exists(forbidden) and surface.black_image.get_used_rect().size == Vector2i.ZERO)
		# Simulate runtime movement; editor must restore pre-preview pose.
		node.body.position += Vector2(17, 23)
		var previous_id: int = level.get_instance_id()
		creative.set_active(true)
		var deadline := Time.get_ticks_msec() + 30000
		while Time.get_ticks_msec() < deadline:
			await process_frame
			var candidate: Node = app.level_root.get_child(0)
			if candidate.get_instance_id() != previous_id and candidate.get_node("Creative").active and not app._loading_level:
				level = candidate
				break
		creative = setup(level)
		canvas = level.get_node("MapCanvas")
		surface = canvas.surface
		node = level.get_node(NodePath(solid_name))
		check("F2 restores exact draft including blue and nails %d" % index,
			surface.black_image.get_data() == raw and surface.blue_layer.cells == blue and surface.nail_layer.snapshot() == nails)
		check("F2 preserves solid local pixels and fractional pose %d" % index,
			shape_data(node.body) == original_shape and node.body.position.is_equal_approx(solid_position) and is_equal_approx(node.body.rotation, solid_rotation))
		check("F2 keeps original active wire independent %d" % index,
			surface.blue_rule().objects(Wire).filter(func(w): return w.active and w.body == node.body and w.cells == original_wire).size() == 1)
	# Loading the same file for play must compile drafts once, not overlay duplicate bodies.
	level = await app.load_level(saved, false)
	creative = setup(level)
	canvas = level.get_node("MapCanvas")
	check("saved document runs without manual solidify", canvas.surface.black_image.get_used_rect().size == Vector2i.ZERO and level.world.bodies.size() > body_count)
	var compiled_count: int = level.world.bodies.size()
	creative.prepare_loaded_document(false)
	check("runtime compilation is idempotent", level.world.bodies.size() == compiled_count)
	# Editor load of the identical file keeps the original mixed representation.
	level = await app.load_level(saved, true)
	creative = setup(level)
	canvas = level.get_node("MapCanvas")
	check("disk reload keeps exact raw draft", canvas.surface.black_image.get_data() == raw and canvas.surface.blue_layer.cells == blue)
	check("disk reload does not rebuild solid as draft", level.get_node(NodePath(solid_name)).body.shapes[0].pixel_count() == solid_pixels and level.world.bodies.size() == body_count)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	app.queue_free()
	await process_frame
	print("[EditorDocument] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
