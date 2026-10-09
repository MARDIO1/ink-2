extends SceneTree

const LevelSelectScript := preload("res://ui/level_select/src/level_select.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid := true
	var paths := LevelSelectScript.find_levels()
	var expected_imports := PackedStringArray([
		"res://map/asset/imported/1.tscn",
		"res://map/asset/imported/2.tscn",
		"res://map/asset/imported/3.（盾兵）.tscn",
		"res://map/asset/imported/4.（投掷手）.tscn",
		"res://map/asset/imported/基础.tscn",
		"res://map/asset/imported/平路（新）.tscn",
		"res://map/asset/imported/平路地图.tscn",
	])
	for path in expected_imports:
		valid = valid and paths.has(path)

	var screen := (load("res://ui/level_select/level_select.tscn") as PackedScene).instantiate()
	root.add_child(screen)
	await process_frame
	var scroll := screen.get_node_or_null("Center/Panel/Scroll") as ScrollContainer
	var list := screen.get_node_or_null("Center/Panel/Scroll/List") as VBoxContainer
	valid = valid and scroll != null and list != null
	if scroll != null and list != null:
		valid = valid and scroll.horizontal_scroll_mode == ScrollContainer.SCROLL_MODE_DISABLED
		valid = valid and scroll.vertical_scroll_mode == ScrollContainer.SCROLL_MODE_AUTO
		valid = valid and scroll.get_v_scroll_bar().focus_mode == Control.FOCUS_ALL
		valid = valid and list.get_child_count() == paths.size()
		# 地图数量超过可视区域时，纵向条必须有可滚动的范围。
		if list.get_combined_minimum_size().y > scroll.size.y:
			valid = valid and scroll.get_v_scroll_bar().max_value > scroll.get_v_scroll_bar().page
	screen.queue_free()
	await process_frame
	if not valid:
		printerr("[LevelSelect] imported maps or wheel scrolling: FAIL")
		quit(1)
	print("[LevelSelect] imported maps and wheel scrolling: PASS")
	quit()
