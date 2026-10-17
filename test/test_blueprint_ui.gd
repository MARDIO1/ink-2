extends SceneTree
const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Store := preload("res://ui/hud/blueprint/src/blueprint_store.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	checks += 1
	print("[BlueprintUI] %s %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1

func _run() -> void:
	var app = load("res://root/root.tscn").instantiate()
	# 本测试只验证蓝图输入链；音乐由 test_audio_integration 覆盖。
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	current_scene = app
	var level = await app.load_level(load("res://test/fixtures/maps/base_level.tscn"))
	level.auto_step = false
	app._set_screen(app.ui_scene.instantiate())
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	var canvas = level.get_node("MapCanvas")
	canvas.canvas_size = Vector2i(256, 256)
	canvas.position = Vector2(10000, -10000)
	canvas.active = true
	canvas.show()
	canvas.set_map_editor_mode(true)
	canvas.surface.ink_free = true
	var camera = level.get_node("SimulationRuntime/PhysicsStep")._camera
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.position_smoothing_enabled = false
	camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	camera.global_position = canvas.global_position + Vector2(128, 128)
	camera.reset_physics_interpolation()
	camera.reset_smoothing()
	camera.force_update_scroll()
	var system = root.get_node("Blueprints")
	system.store = Store.new()
	system.store.directory = "user://blueprint_ui_test_%d_%d" % [Time.get_ticks_usec(), randi()]
	var surface = canvas.surface
	surface.clear()
	for y in range(30, 48):
		for x in range(30, 120):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	for y in range(48, 95):
		for x in [30, 31, 32, 117, 118, 119]:
			surface.write_pixel(Vector2i(x, y), Palette.GREY.color)
	surface.refresh()
	canvas.set_tool(canvas.SurfaceScript.Tool.SELECT_DELETE)
	surface._selected_rect = Rect2i(24, 24, 104, 80)
	surface.selection_overlay.set_selection(surface._selected_rect)
	await process_frame
	await process_frame
	await process_frame
	check("selection buttons and Ctrl hint follow active selection", system.actions.visible and system.hint.visible)
	check("selection action stays inside viewport", Rect2(Vector2.ZERO, root.get_visible_rect().size).encloses(Rect2(system.actions.position, system.actions.size)))
	var ui_click := InputEventMouseButton.new()
	ui_click.position = system.actions.position + Vector2(8, 8)
	ui_click.button_index = MOUSE_BUTTON_LEFT
	ui_click.pressed = true
	check("selection buttons block world input even before GUI hover", system.blocks_world_event(ui_click))
	if OS.get_cmdline_user_args().has("--preview"):
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(OS.get_user_data_dir().path_join("blueprint_selection_preview.png"))
	var original_ink: PackedByteArray = surface.black_image.get_data()
	system.save_selection()
	check("save dialog pauses world and preserves source", system.modal and paused and original_ink == surface.black_image.get_data())
	check("save dialog matches project theme", system.panel.get_parent().theme == load("res://ui/theme/asset/ink_attack_theme.tres"))
	# 模态窗口内按 Backspace 不得删除画布，Tab 不得切走 HUD。
	var backspace := InputEventKey.new()
	backspace.keycode = KEY_BACKSPACE
	backspace.pressed = true
	canvas._input(backspace)
	var tab := InputEventKey.new()
	tab.keycode = KEY_TAB
	tab.physical_keycode = KEY_TAB
	tab.pressed = true
	var hud = app.ui_root.get_child(0).get_node("Hud")
	hud._input(tab)
	check("modal blocks drawing shortcuts and debug toggle", surface.black_image.get_data() == original_ink and hud.visible)
	system._name.text = "折叠桥梁"
	system._description.text = "先放置，再固化。"
	system._tags.text = "桥梁，黑墨"
	system._save_pressed()
	check("save closes modal and resumes previous state", not system.modal and not paused and system.store.list_all().size() == 1)
	var blueprint_button: Button = hud.get_node("Root/BlueprintButton")
	check("library button is left of dialogue log", blueprint_button.offset_right < hud.get_node("Root/LogButton").offset_left)
	blueprint_button.pressed.emit()
	await process_frame
	check("HUD opens unified library", system.modal and paused and system._items.size() == 1)
	check("saved metadata appears in library", system._name.text == "折叠桥梁" and system._tags.text.contains("桥梁"))
	# 回车必须和点「保存信息」等价，否则打完名字按回车会被静默丢弃。
	system._name.text = "回车改名"
	system._name.text_submitted.emit("回车改名")
	check("enter commits the typed name", system.store.list_all()[0].name == "回车改名")
	# 文件名直接就是名字；改名时旧文件跟着搬走。
	var blueprint_folder: String = system.store.directory
	check("file is named after the blueprint", FileAccess.file_exists(blueprint_folder.path_join("回车改名.inkbp")))
	system._name.text = "改名后"
	system._name.text_submitted.emit("改名后")
	check("rename moves the file", FileAccess.file_exists(blueprint_folder.path_join("改名后.inkbp"))
		and not FileAccess.file_exists(blueprint_folder.path_join("回车改名.inkbp")))
	check("editor enables use without player proximity", not system._use.disabled)
	system._toggle_favorite()
	check("favorite persisted", system.store.list_all()[0].favorite)
	system._search.text = "does-not-exist"
	system._refresh_cards()
	check("search filters cards", system._cards.get_child_count() == 1 and system._cards.get_child(0) is Label)
	system._search.clear()
	system._refresh_cards()
	await process_frame
	if OS.get_cmdline_user_args().has("--preview"):
		await RenderingServer.frame_post_draw
		var path := OS.get_user_data_dir().path_join("blueprint_library_preview.png")
		root.get_texture().get_image().save_png(path)
		print("BLUEPRINT_PREVIEW=", path)
	check("use enters live placement and unpauses", system.begin_placement(system._selected) and system.placing and not paused)
	check("placement blocks underlying canvas tools", system.is_world_input_blocked() and surface.tool == canvas.SurfaceScript.Tool.SELECT_DELETE)
	var right := InputEventMouseButton.new()
	right.button_index = MOUSE_BUTTON_RIGHT
	right.pressed = true
	system._input(right)
	check("right click cancels without deleting source", not system.placing and surface.black_image.get_data() == original_ink)
	# 通过真实 Viewport 输入链确认一次，而不只调用放置函数。
	var live_data := Codec.capture(canvas, Rect2i(24, 24, 104, 80))
	system.begin_placement(live_data)
	var cursor: Vector2 = surface.get_global_transform_with_canvas() * Vector2(180, 180)
	# 滚动容器外的工具按钮虽然仍在场景树内，不能拦截画布中的放置点击。
	var clipped_scroll := ScrollContainer.new()
	clipped_scroll.position = Vector2(5, 5)
	clipped_scroll.size = Vector2(40, 40)
	var scroll_contents := Control.new()
	scroll_contents.custom_minimum_size = Vector2(1600, 1000)
	clipped_scroll.add_child(scroll_contents)
	var clipped_button := Button.new()
	clipped_button.size = Vector2(40, 40)
	scroll_contents.add_child(clipped_button)
	var clipped_ui := CanvasLayer.new()
	clipped_ui.add_child(clipped_scroll)
	root.add_child(clipped_ui)
	await process_frame
	clipped_button.global_position = cursor - Vector2(20, 20)
	check("clipped offscreen button does not block placement", not system._pointer_over_ui(cursor))
	clipped_button.global_position = Vector2(10, 10)
	check("visible button still blocks placement", system._pointer_over_ui(Vector2(20, 20)))
	clipped_button.global_position = cursor - Vector2(20, 20)
	system._update_placement(1.0, surface.get_global_transform_with_canvas() * Vector2(60, 60))
	check("red preview explains the exact refusal near the ghost", not system._last_error.is_empty()
		and system.placement_hint.text.begins_with("无法放置：")
		and Rect2(Vector2.ZERO, root.get_visible_rect().size).encloses(system.placement_hint.get_global_rect()))
	var motion := InputEventMouseMotion.new()
	motion.position = cursor
	root.push_input(motion, true)
	await process_frame
	var click := InputEventMouseButton.new()
	click.position = cursor
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	root.push_input(click, true)
	await process_frame
	check("real left click places ghost without painting through", not system.placing and surface.material_at(134, 146) == Palette.BLACK.id and not surface._painting)
	clipped_ui.queue_free()
	click.pressed = false
	root.push_input(click, true)
	surface.undo_last_edit()
	canvas.set_map_editor_mode(false)
	canvas._workbench_nearby = false
	for workbench in get_nodes_in_group("canvas_workbench"):
		workbench._workbench_nearby = false
	system.open_library()
	check("library can be viewed away from canvas", system.modal and system._use.disabled and system._items.size() == 1)
	system.close()
	paused = true
	system.open_library()
	system.close()
	check("closing restores an already paused world", paused)
	paused = false
	canvas.set_map_editor_mode(true)
	canvas._workbench_nearby = true
	system.open_library()
	system._trash_selected()
	check("delete requires confirmation", system.store.list_all().size() == 1)
	system._trash_selected()
	check("confirmed delete does not touch original map", system.store.list_all().is_empty() and surface.black_image.get_data() == original_ink)
	system.close()
	var data := Codec.capture(canvas, Rect2i(24, 24, 104, 80))
	system.begin_placement(data)
	check("placement preview starts before reload", system.placing)
	await app.load_level(load("res://test/fixtures/maps/base_level.tscn"))
	app.level_root.get_child(0).auto_step = false
	await process_frame
	await process_frame
	check("level replacement cancels old placement", not system.placing)
	# 仅清理测试自己的随机目录。
	var folder := DirAccess.open(system.store.directory)
	if folder != null:
		for file in folder.get_files():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(system.store.directory.path_join(file)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(system.store.directory))
	app.queue_free()
	await process_frame
	print("[BlueprintUI] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
