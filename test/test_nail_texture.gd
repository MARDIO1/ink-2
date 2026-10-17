extends SceneTree
const Nail := preload("res://actor/nail/src/nail.gd")
const NailLayer := preload("res://actor/nail/src/nail_layer.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Codec := preload("res://actor/blueprint/src/blueprint_codec.gd")
const LevelList := preload("res://ui/level_select/src/level_select.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[NailTexture] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func _run() -> void:
	var fixed_source := Image.new()
	fixed_source.load_png_from_buffer(FileAccess.get_file_as_bytes("res://actor/nail/asset/fixed_nail.png"))
	var background_source := Image.new()
	background_source.load_png_from_buffer(FileAccess.get_file_as_bytes("res://actor/nail/asset/nail.png"))
	var imported := Nail.FIXED_TEXTURE.get_image()
	check("both native 11px textures imported", fixed_source.get_size() == Vector2i(11, 11)
		and background_source.get_size() == Vector2i(11, 11)
		and imported.get_size() == fixed_source.get_size())
	check("fixed nail has transparent corners and gray center", imported.get_pixel(0, 0).a == 0
		and imported.get_pixel(5, 5).a == 1.0 and imported.get_pixel(5, 5) != Color.BLACK)
	check("background nail keeps one-pixel black cross", Nail.BACKGROUND_TEXTURE.get_image().get_pixel(5, 5) == Color.BLACK
		and Nail.BACKGROUND_TEXTURE.get_image().get_pixel(4, 4) == Color.WHITE)
	var imported_matches := true
	for y in fixed_source.get_height():
		for x in fixed_source.get_width():
			var pixel := fixed_source.get_pixel(x, y)
			var actual := imported.get_pixel(x, y)
			imported_matches = imported_matches and is_equal_approx(pixel.a, actual.a) and (pixel.a == 0 or pixel.is_equal_approx(actual))
	check("opaque artwork and alpha preserved exactly", imported_matches)
	check("canvas and body share texture and center", NailLayer.NAIL_TEXTURE == Nail.FIXED_TEXTURE and NailLayer.ANCHOR_CENTER == Vector2(fixed_source.get_size()) * 0.5)
	var draft_rect := Nail.visual_rect(Vector2i(32, 32))
	check("draft nail is 11px around unchanged pixel center", draft_rect.size == Vector2(11, 11) and draft_rect.get_center() == Vector2(32.5, 32.5))
	var icon = load("res://ui/asset/nail.tres")
	check("toolbar retains supplied independent nail icon", icon.atlas.resource_path == "res://ui/asset/nail.png" and icon.region == Rect2(36, 40, 132, 128))
	check("toolbar art stays separate from map nail texture", icon.atlas != Nail.NAIL_TEXTURE)
	var level = load("res://map/asset/imported/main.tscn").instantiate()
	level.auto_step = false
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	root.add_child(level)
	current_scene = level
	await process_frame
	var canvas = level.get_node("MapCanvas")
	check("toolbar button displays independent icon", canvas.tool_grid.get_node("Nail/ToolIcon").texture == icon)
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(96, 96)
	canvas.surface.ink_free = true
	canvas.set_map_editor_mode(true)
	canvas.surface.clear()
	for y in range(16, 48):
		for x in range(16, 48):
			canvas.surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	canvas.surface.nail_layer.add(Vector2i(32, 32), Nail.Kind.FIXED)
	canvas.surface.refresh()
	check("draft nail overlays its base pixel", canvas.surface.nail_layer.nails.size() == 1
		and canvas.surface.nail_layer.background_nails.is_empty()
		and canvas.surface.material_at(32, 32) == Palette.BLACK.id)
	check("draft nail uses nearest filtering", canvas.surface.nail_layer.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST)
	var data := Codec.capture(canvas, Rect2i(0, 0, 64, 64))
	var preview := Codec.preview(data)
	var preview_matches := true
	var displayed := fixed_source.duplicate() as Image
	displayed.resize(roundi(displayed.get_width() * Nail.VISUAL_SCALE),
		roundi(displayed.get_height() * Nail.VISUAL_SCALE), Image.INTERPOLATE_NEAREST)
	var preview_origin := Vector2i(32, 32) - Vector2i(Nail.ANCHOR_CENTER * Nail.VISUAL_SCALE)
	for y in displayed.get_height():
		for x in displayed.get_width():
			if displayed.get_pixel(x, y).a > 0.5:
				preview_matches = preview_matches and preview.get_pixelv(preview_origin + Vector2i(x, y)).is_equal_approx(displayed.get_pixel(x, y))
	check("blueprint preview uses native pixel nail artwork", preview_matches)
	check("preview keeps pixels outside the smaller nail", preview.get_pixel(25, 32) == Palette.BLACK.color)
	canvas.generate()
	var generated: Node
	for nail in get_nodes_in_group(Nail.VISUAL_GROUP):
		if nail.get_parent() == level and nail.body != null and nail.pixel == Vector2i(32, 32):
			generated = nail
	check("solidification creates shared nail visual", generated != null and generated.texture == Nail.NAIL_TEXTURE)
	if generated != null:
		check("new art stays centered on original anchor", generated.offset == -Nail.ANCHOR_CENTER and generated.global_position.is_equal_approx(generated.body.to_world(Vector2(32.5, 32.5))))
		check("solidified nail has native 11px bounds", generated.scale == Vector2.ONE and generated.get_rect().size == Vector2(11, 11))
		check("physics remains static single-pixel anchor", generated.body.is_static and generated.body.tags["static_anchor_points"].size() == 1)
	level.queue_free()
	await process_frame
	# 直接加载既有地图；不进入编辑保存流程，不写回地图或快照。
	var restored_count := 0
	var paths := LevelList.find_levels()
	for existing_path in paths:
		var before := FileAccess.get_sha256(existing_path)
		var saved_level = load(existing_path).instantiate()
		saved_level.auto_step = false
		saved_level.process_mode = Node.PROCESS_MODE_DISABLED
		var creative: Node = saved_level.get_node_or_null("Creative")
		if creative != null:
			creative.auto_save_edits = false
			creative.auto_save_on_exit = false
		root.add_child(saved_level)
		current_scene = saved_level
		for _frame in 3:
			await process_frame
		var restored_correctly := true
		for nail in get_nodes_in_group(Nail.VISUAL_GROUP):
			if nail.get_parent() != saved_level or nail.is_queued_for_deletion():
				continue
			restored_count += 1
			var expected_texture: Texture2D = Nail.texture_for(nail.kind)
			var expected_center: Vector2 = Nail.anchor_center_for(nail.kind)
			restored_correctly = restored_correctly and nail.texture == expected_texture \
				and nail.offset == -expected_center and nail.scale == Vector2.ONE and nail._anchor_alive()
		check("existing map uses native-size nails: " + existing_path.get_file(), restored_correctly)
		check("existing map was not rewritten: " + existing_path.get_file(), FileAccess.get_sha256(existing_path) == before)
		saved_level.queue_free()
		await process_frame
	check("existing maps contain restored nails", restored_count > 0)
	print("[NailTexture] checked maps: %d, restored nails: %d" % [paths.size(), restored_count])
	Nail.map_editor_active = false
	Nail.visuals_visible = true
	print("[NailTexture] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
