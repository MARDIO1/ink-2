extends SceneTree
const Palette = preload("res://ink/general/src/ink_palette.gd")
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
	var editor = level.get_node("Creative")
	editor.auto_save_edits = false
	editor.auto_save_on_exit = false
	return editor

func _run() -> void:
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	current_scene = app
	var level: Node = await app.load_level(load("res://test/fixtures/maps/base_level.tscn"), true)
	var editor = setup(level)
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(160, 160)
	var surface = canvas.surface
	surface.ink_free = true
	for y in range(30, 50):
		for x in range(30, 70):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	canvas.generate(false)
	check("fixture starts with solids and empty draft", surface.material_at(40, 40) == 0)
	editor._activate_restored_editor()
	check("legacy map converts solid black once", surface.material_at(40, 40) == Palette.BLACK.id and not editor.editor_draft.is_empty())
	check("entering restoration does not add undo steps", surface._undo_steps.is_empty())
	surface.blue_layer.begin(Vector2(35.5, 35.5))
	surface.blue_layer.extend(Vector2(60.5, 35.5))
	surface.blue_layer.finish()
	surface.write_pixel(Vector2i(45, 40), surface.nail_color())
	var path := "res://.codex-tmp/blueprint_editor_document_test.tscn"
	check("manual blueprint save succeeds", editor.export_map_to(path) == OK)
	check("saving preserves the editable blueprint", surface.material_at(40, 40) == Palette.BLACK.id)
	var raw: PackedByteArray = surface.black_image.get_data()
	var blue: PackedVector2Array = surface.blue_layer.cells.duplicate()
	var nails: Dictionary = surface.nail_layer.snapshot()
	var draft_count: int = level.world.bodies.size()
	var saved: PackedScene = ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var detached := saved.instantiate()
	check("saved file contains embedded blueprint", not detached.get_node("Creative").editor_draft.is_empty())
	check("saved blueprint has no ink entity nodes in canvas", detached.get_children().filter(func(node): return node.is_in_group("ink_item")).is_empty())
	detached.free()
	editor.map_path = "res://.codex-tmp/f2_blueprint_must_not_write.tscn"
	var forbidden: String = editor.map_path
	if FileAccess.file_exists(forbidden):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(forbidden))
	for round_index in 3:
		editor.set_active(false)
		check("F2 exit compiles blueprint for play %d" % round_index, surface.black_image.get_used_rect().size == Vector2i.ZERO and level.world.bodies.size() > draft_count)
		check("F2 does not overwrite the map %d" % round_index, not FileAccess.file_exists(forbidden))
		# Deliberately contaminate the play instance: F2 must discard it, not reclaim it.
		surface.write_pixel(Vector2i(100, 100), Palette.BLACK.color)
		canvas.generate(false)
		var old_id := level.get_instance_id()
		editor.set_active(true)
		var deadline := Time.get_ticks_msec() + 15000
		while Time.get_ticks_msec() < deadline:
			await process_frame
			var candidate: Node = app.level_root.get_child(0)
			if candidate.get_instance_id() != old_id and candidate.get_node("Creative").active and not app._loading_level:
				level = candidate
				break
		editor = setup(level)
		canvas = level.get_node("MapCanvas")
		surface = canvas.surface
		check("F2 reentry restores editable blueprint %d" % round_index,
			surface.black_image.get_data() == raw and surface.blue_layer.cells == blue and surface.nail_layer.snapshot() == nails)
		check("editor contains no compiled duplicate %d" % round_index, level.world.bodies.size() == draft_count)
	level = await app.load_level(saved, false)
	editor = setup(level)
	canvas = level.get_node("MapCanvas")
	check("saved blueprint compiles automatically for ordinary play", canvas.surface.black_image.get_used_rect().size == Vector2i.ZERO and level.world.bodies.size() > draft_count)
	var compiled_count: int = level.world.bodies.size()
	editor.prepare_loaded_document(false)
	check("blueprint compilation is idempotent", level.world.bodies.size() == compiled_count)
	level = await app.load_level(saved, true)
	editor = setup(level)
	canvas = level.get_node("MapCanvas")
	editor._activate_restored_editor()
	check("disk reload restores blueprint pixels and blue", canvas.surface.black_image.get_data() == raw and canvas.surface.blue_layer.cells == blue)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	app.queue_free()
	await process_frame
	print("[EditorDocument] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
