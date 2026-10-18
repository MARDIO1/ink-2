extends SceneTree
## 自动保存也写“墨水为主”的快照：非机关实体墨化，机关实体保留。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[EditorAutoSaveSnapshot] %s %s" % ["PASS" if ok else "FAIL", label])

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_edits = true
	creative.auto_save_on_exit = false
	creative.full_auto_save_delay = 0.05
	creative._skip_restore_on_enter = true
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	creative.set_active(true)
	await process_frame
	var surface = canvas.surface
	var path := "res://blueprints/editor_autosave_snapshot_%d.tscn" % Time.get_ticks_usec()
	creative.map_path = path
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for y in range(30, 50):
		for x in range(30, 70):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	surface.selected_ink = 0
	surface.gear_tool.begin(Vector2(120, 120), 8)
	surface.gear_tool.finish(Vector2(140, 120))
	canvas.generate()
	check("manual bearing installs before autosave", surface.rod_layer.place_anchor(Vector2(120.5, 120.5)))
	var bodies_before: int = level.world.bodies.size()
	var undo_before: int = surface._undo_steps.size()
	creative._auto_save_revision += 1
	creative._queue_edit_auto_save()
	await create_timer(0.4).timeout
	check("autosave writes snapshot file", FileAccess.file_exists(path))
	check("autosave keeps editor player hidden", not level.get_node("Player").visible)
	check("autosave inkifies the live editor world", level.world.bodies.size() < bodies_before
		and surface.material_at(40, 40) == Palette.BLACK.id)
	check("autosave does not add an undo step", surface._undo_steps.size() == undo_before)
	var saved := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	check("autosave snapshot loads", saved != null)
	if saved != null:
		var scene = saved.instantiate()
		var editor = scene.get_node("Creative")
		var image := Image.new()
		var error := image.load_png_from_buffer(editor.editor_draft.get("black", PackedByteArray()))
		check("autosave snapshot decodes draft", error == OK)
		if error == OK:
			check("autosave snapshot stores plain body as ink", image.get_pixel(40, 40).a > 0.5)
			check("autosave snapshot keeps gear as entity", image.get_pixel(120, 120).a <= 0.1)
		var gear_nodes := scene.find_children("*", "", true, false).filter(
			func(n): return n is InkItem and not n.gear_centers.is_empty())
		var saved_axles := scene.find_children("*", "", true, false).filter(
			func(n): return n is Axle and not n.is_queued_for_deletion())
		check("autosave snapshot keeps gear center and bearing", gear_nodes.size() == 1
			and saved_axles.size() == 1 and saved_axles[0].fixed_to_world)
		scene.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	level.queue_free()
	await process_frame
	print("[EditorAutoSaveSnapshot] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
