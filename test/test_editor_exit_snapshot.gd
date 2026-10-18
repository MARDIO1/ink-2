extends SceneTree
## 退出编辑器快照：非机关实体墨化，齿轮实体保留；再次加载直接使用该快照。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[EditorExitSnapshot] %s %s" % ["PASS" if ok else "FAIL", label])

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = true
	root.add_child(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = true
	creative._skip_restore_on_enter = true
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	creative.set_active(true)
	await process_frame
	var surface = canvas.surface
	var path := "res://blueprints/editor_exit_snapshot_%d.tscn" % Time.get_ticks_usec()
	creative.map_path = path
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# 普通黑墨结构：退出时应墨化回草稿。
	for y in range(30, 50):
		for x in range(30, 70):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	# 齿轮轮体：退出时应保留为实体。
	surface.selected_ink = 0
	surface.gear_tool.begin(Vector2(120, 120), 8)
	surface.gear_tool.finish(Vector2(140, 120))
	canvas.generate()
	var bodies_before: int = level.world.bodies.size()
	check("manual bearing installs before exit", surface.rod_layer.place_anchor(Vector2(120.5, 120.5)))
	check("editor pauses simulation physics",
		not level.get_node("SimulationRuntime").is_physics_processing())
	creative.set_active(false)
	await process_frame
	check("exit restores simulation physics",
		level.get_node("SimulationRuntime").is_physics_processing())
	check("exit writes snapshot file", FileAccess.file_exists(path))
	var saved := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	check("saved snapshot loads", saved != null)
	if saved == null:
		quit(1)
		return
	var scene = saved.instantiate()
	var saved_editor = scene.get_node("Creative")
	var draft: Dictionary = saved_editor.editor_draft
	check("snapshot embeds ink draft", not draft.is_empty())
	var image := Image.new()
	var error := image.load_png_from_buffer(draft.get("black", PackedByteArray()))
	check("snapshot draft decodes", error == OK)
	if error == OK:
		check("plain body became ink in snapshot", image.get_pixel(40, 40).a > 0.5)
		check("gear body stayed an entity", image.get_pixel(120, 120).a <= 0.1)
	var gear_nodes := []
	for node in scene.find_children("*", "", true, false):
		if node is InkItem and not node.gear_centers.is_empty():
			gear_nodes.append(node)
	check("snapshot keeps exactly the gear entity", gear_nodes.size() == 1 and bodies_before > 0)
	check("gear center survives in snapshot", gear_nodes.size() == 1
		and gear_nodes[0].gear_centers.size() == 1)
	var saved_axles := scene.find_children("*", "", true, false).filter(
		func(n): return n is Axle and not n.is_queued_for_deletion())
	check("snapshot keeps the explicit bearing", saved_axles.size() == 1
		and saved_axles[0].fixed_to_world)
	# 再次进入编辑器：直接恢复快照，不重新生成、不二次墨化。
	scene.auto_step = false
	scene.set_meta(&"editor_document_load", true)
	root.add_child(scene)
	await process_frame
	await process_frame
	var restored_surface = scene.get_node("MapCanvas").surface
	check("re-enter restores plain ink directly", restored_surface.material_at(40, 40) == Palette.BLACK.id)
	check("re-enter does not regenerate the gear body into ink",
		restored_surface.material_at(120, 120) == 0)
	var restored_centers := 0
	for body in scene.world.bodies:
		restored_centers += GearCenters.body_records(body).size()
	check("re-enter keeps the gear entity center", restored_centers == 1)
	scene.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	level.queue_free()
	await process_frame
	print("[EditorExitSnapshot] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
