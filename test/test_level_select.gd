extends SceneTree

const LevelSelectScript := preload("res://ui/level_select/src/level_select.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid := true
	var paths := LevelSelectScript.find_levels()
	var required_levels := PackedStringArray([
		"res://map/asset/imported/peak.tscn",
		"res://map/asset/imported/扉页.tscn",
		"res://map/asset/imported/白色测试.tscn",
		"res://map/asset/imported/第一关.tscn",
		"res://map/second/第三关·墨泉边.tscn",
	])
	valid = valid and not paths.has("res://map/asset/imported/main.tscn")
	valid = valid and paths.size() == required_levels.size()
	for path in required_levels:
		valid = valid and paths.has(path)
	var deleted_levels := PackedStringArray([
		"res://map/asset/imported/1.tscn",
		"res://map/asset/imported/2.tscn",
		"res://map/asset/imported/3.（盾兵）.tscn",
		"res://map/asset/imported/4.（投掷手）.tscn",
		"res://map/asset/imported/基础.tscn",
		"res://map/asset/imported/平路地图.tscn",
	])
	for path in deleted_levels:
		valid = valid and not paths.has(path)

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
	# 验证常用窗口尺寸以及关卡列表变长时，标题和面板不相交、不接底边。
	screen.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	for viewport_size in [Vector2(960, 540), Vector2(640, 360), Vector2(1280, 720), Vector2(540, 960)]:
		screen.size = viewport_size
		await process_frame
		await process_frame
		var title_rect: Rect2 = screen.get_node("Title").get_global_rect()
		var panel_rect: Rect2 = screen.get_node("Center/Panel").get_global_rect()
		valid = valid and not title_rect.intersects(panel_rect)
		valid = valid and panel_rect.end.y <= viewport_size.y * 0.85
		valid = valid and panel_rect.position.x >= 0 and panel_rect.end.x <= viewport_size.x
	screen.size = Vector2(960, 540)
	for index in 12:
		var extra := Button.new()
		extra.text = "测试关卡 %d" % index
		extra.custom_minimum_size = LevelSelectScript.BUTTON_SIZE
		list.add_child(extra)
	await process_frame
	await process_frame
	valid = valid and scroll.get_v_scroll_bar().max_value > scroll.get_v_scroll_bar().page
	valid = valid and screen.get_node("Center/Panel").get_global_rect().end.y <= screen.size.y * 0.85
	for index in range(list.get_child_count() - 1, paths.size() - 1, -1):
		var extra: Node = list.get_child(index)
		list.remove_child(extra)
		extra.queue_free()
	await process_frame
	await process_frame
	if OS.get_cmdline_user_args().has("--preview"):
		root.mode = Window.MODE_WINDOWED
		root.size = Vector2i(960, 540)
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("C:/Users/youli/.codex/visualizations/2026/10/11/01a12987-d6cc-7a63-9192-35e2107dc184/level-select-layout.png")
	screen.queue_free()
	await process_frame
	if not valid:
		printerr("[LevelSelect] retained maps or wheel scrolling: FAIL")
		quit(1)
		return
	print("[LevelSelect] retained maps and wheel scrolling: PASS")
	quit()
