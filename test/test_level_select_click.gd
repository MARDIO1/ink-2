extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var root_scene := load("res://root/root.tscn") as PackedScene
	var app := root_scene.instantiate()
	root.add_child(app)
	await process_frame
	var menu := app.get_node("UI").get_child(0)
	menu.start_pressed.emit()
	await process_frame
	var selector := app.get_node("UI").get_child(0)
	var buttons := selector.get_node("Center/Panel/Scroll/List").get_children()
	var target: Button
	for candidate in buttons:
		if candidate.tooltip_text == "res://map/asset/imported/平路（新）.tscn":
			target = candidate as Button
			break
	if target == null:
		printerr("[LevelSelectClick] target button missing: FAIL")
		quit(1)
		return
	var result := {"chosen_path": ""}
	selector.level_chosen.connect(func(path: String) -> void: result.chosen_path = path)
	target.pressed.emit()
	var showed_loading := target.disabled and target.text.contains("加载中")
	await process_frame
	if result.chosen_path != target.tooltip_text:
		printerr("[LevelSelectClick] click signal missing: FAIL")
		quit(1)
		return
	if not showed_loading:
		printerr("[LevelSelectClick] loading feedback missing: FAIL")
		quit(1)
		return
	for frame in 300:
		if app.get_node("Level").get_child_count() > 0:
			print("[LevelSelectClick] click loads selected level: PASS (%d frames)" % frame)
			quit()
			return
		await process_frame
	printerr("[LevelSelectClick] selected level did not load: FAIL")
	quit(1)
