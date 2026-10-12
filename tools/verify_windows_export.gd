extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var selector = load("res://ui/level_select/src/level_select.gd")
	var levels: PackedStringArray = selector.find_levels()
	print("[ExportCheck] playable maps: ", levels)
	if levels.is_empty():
		quit(1)
		return
	var app = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var ok: bool = await app.request_level_change(levels[0])
	await process_frame
	var level = app.get_node("Level").get_child(0) if ok else null
	ok = ok and level != null and level.world != null and level.world.bodies.size() > 0
	print("[ExportCheck] actual level, UI and physics load: ", "PASS" if ok else "FAIL")
	app.queue_free()
	await process_frame
	quit(0 if ok else 1)
