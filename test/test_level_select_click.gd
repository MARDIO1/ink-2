extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var root_scene := load("res://root/root.tscn") as PackedScene
	var app := root_scene.instantiate()
	root.add_child(app)
	await process_frame
	var transition: Node = root.get_node("SceneTransition")
	transition.duration = 0.01
	var menu := app.get_node("UI").get_child(0)
	menu.start_pressed.emit()
	for frame in 120:
		await process_frame
		if not transition.busy:
			break
	var selector := app.get_node("UI").get_child(0)
	var buttons := selector.get_node("Center/Panel/Scroll/List").get_children()
	var target: Button
	for candidate in buttons:
		if candidate.tooltip_text == "res://map/asset/imported/第一页.tscn":
			target = candidate as Button
			break
	if target == null:
		printerr("[LevelSelectClick] target button missing: FAIL")
		quit(1)
		return
	var result := {"chosen_path": ""}
	var target_path: String = target.tooltip_text
	selector.level_chosen.connect(func(path: String) -> void: result.chosen_path = path)
	target.pressed.emit()
	var showed_loading := target.disabled and target.text.contains("加载中")
	await process_frame
	if result.chosen_path != target_path:
		printerr("[LevelSelectClick] click signal missing: FAIL")
		quit(1)
		return
	if not showed_loading:
		printerr("[LevelSelectClick] loading feedback missing: FAIL")
		quit(1)
		return
	# headless 的 process_frame 每秒能跑几百帧，按帧数等等于只等几百毫秒；
	# 真实地图要读几 MB，按时间预算才可靠。
	var deadline := Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		if app.get_node("Level").get_child_count() > 0:
			print("[LevelSelectClick] click loads selected level: PASS (%d ms)" % (30000 - (deadline - Time.get_ticks_msec())))
			quit()
			return
		await process_frame
	printerr("[LevelSelectClick] selected level did not load: FAIL")
	quit(1)
