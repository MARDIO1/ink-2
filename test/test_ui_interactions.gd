extends SceneTree
## 真实 Viewport 点击与键盘回归。地图不写盘，声音偏好使用独立测试路径。
const Store := preload("res://ui/hud/blueprint/src/blueprint_store.gd")
const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[UIInteractions] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func settle() -> void:
	for frame in 3:
		await process_frame

func click(button: BaseButton) -> void:
	var viewport := button.get_viewport()
	var point := button.get_global_transform_with_canvas() * (button.size * 0.5)
	# 嵌入式弹窗由父视口路由；直接 push_input 到子 Window 会被模态锁吞掉。
	while viewport != root and viewport is Window and viewport.is_embedded():
		point += Vector2(viewport.position)
		viewport = root if root.get_embedded_subwindows().has(viewport) else viewport.get_parent().get_viewport()
	var motion := InputEventMouseMotion.new()
	motion.position = viewport.get_final_transform() * point
	motion.global_position = motion.position
	if viewport == root:
		Input.parse_input_event(motion)
		Input.flush_buffered_events()
	else:
		motion.position = point
		viewport.push_input(motion, true)
	await process_frame
	for down in [true, false]:
		var event := InputEventMouseButton.new()
		event.position = point
		event.button_index = MOUSE_BUTTON_LEFT
		event.pressed = down
		viewport.push_input(event, true)
		await process_frame
	await settle()

func key(code: Key) -> void:
	for down in [true, false]:
		var event := InputEventKey.new()
		event.keycode = code
		event.physical_keycode = code
		event.pressed = down
		root.push_input(event, true)
		await process_frame
	await settle()

func snapshot(name: String) -> void:
	if not OS.get_cmdline_user_args().has("--preview"):
		return
	await RenderingServer.frame_post_draw
	var path := OS.get_user_data_dir().path_join("ui_audit_" + name + ".png")
	check("preview saved: " + name, root.get_texture().get_image().save_png(path) == OK)
	print("UI_AUDIT_PREVIEW=", path)

func audit_buttons(host: Node) -> void:
	for node in host.find_children("*", "BaseButton", true, false):
		var button := node as BaseButton
		var callbacks: Array = button.pressed.get_connections()
		if button.toggle_mode:
			callbacks.append_array(button.toggled.get_connections())
		var valid := not callbacks.is_empty()
		for binding in callbacks:
			valid = valid and binding.callable.is_valid()
		check("button has live action: " + str(host.get_path_to(button)), valid)
		check("button has nonblocking feedback: " + str(host.get_path_to(button)), button.has_node("InkSelectionIndicator") or (button.has_node("ButtonFeedback") and button.get_node("ButtonFeedback").mouse_filter == Control.MOUSE_FILTER_IGNORE))

func _run() -> void:
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(960, 540)
	root.content_scale_size = Vector2i(960, 540)
	var audio := root.get_node("AudioSettings")
	var old_config: String = audio.config_path
	var test_config := "user://ui_audit_audio_%d.cfg" % Time.get_ticks_usec()
	audio.config_path = test_config
	var blueprints := root.get_node("Blueprints")
	var old_store = blueprints.store
	blueprints.store = Store.new()
	blueprints.store.directory = "user://ui_audit_blueprints_%d" % Time.get_ticks_usec()
	var test_store: String = blueprints.store.directory
	var transition := root.get_node("SceneTransition")
	transition.duration = 0.01
	var app = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	await settle()
	var menu = app.ui_root.get_child(0)
	if OS.get_cmdline_user_args().has("--quit-main"):
		audio.config_path = old_config
		await click(menu.get_node("ButtonCenter/Buttons/QuitButton"))
		quit(1)
		return
	audit_buttons(menu)
	await snapshot("menu")
	var sound_button: Button = menu.get_node("ButtonCenter/Buttons/SoundButton")
	await click(sound_button)
	var sound_menu = menu._sound_menu
	check("main menu sound click opens only sound subpage", sound_menu != null and sound_menu.visible and sound_menu.sound_page.visible and paused)
	if sound_menu != null:
		await click(sound_menu.get_node("Center/Panel/SoundPage/BackButton"))
		check("sound back returns to main menu with focus", not paused and not sound_menu.visible and sound_button.has_focus())
	await click(menu.start_button)
	for frame in 120:
		await process_frame
		if not transition.busy:
			break
	var selector = app.ui_root.get_child(0)
	if not selector.has_node("BackButton"):
		check("start reaches level selection", false)
		quit(1)
		return
	audit_buttons(selector)
	await snapshot("levels")
	check("level back button fits viewport", root.get_visible_rect().encloses(selector.get_node("BackButton").get_global_rect()))
	await click(selector.get_node("BackButton"))
	for frame in 120:
		await process_frame
		if not transition.busy:
			break
	check("actual back click returns to cover", app.ui_root.get_child(0).has_node("ButtonCenter"))
	# 再进入一次，确认切换后没有残留信号、暂停或反馈节点。
	menu = app.ui_root.get_child(0)
	await click(menu.start_button)
	for frame in 120:
		await process_frame
		if not transition.busy:
			break
	selector = app.ui_root.get_child(0)
	await key(KEY_ESCAPE)
	for frame in 120:
		await process_frame
		if not transition.busy:
			break
	check("level selection Esc returns without quitting", app.ui_root.get_child(0).has_node("ButtonCenter") and not paused)
	var level = app.load_level(load("res://test/fixtures/maps/base_level.tscn"))
	level.auto_step = false
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	var original_map_hash := FileAccess.get_sha256("res://test/fixtures/maps/base_level.tscn")
	app._set_screen(app.ui_scene.instantiate())
	await settle()
	var game = app.ui_root.get_child(0)
	var hud = game.get_node("Hud")
	var esc = game.get_node("Esc")
	var dialogue = game.get_node("Dialogue")
	if OS.get_cmdline_user_args().has("--quit-esc"):
		audio.config_path = old_config
		if FileAccess.file_exists(test_config):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(test_config))
		esc.open_menu()
		await settle()
		await click(esc.get_node("Center/Panel/Buttons/QuitButton"))
		quit(1)
		return
	audit_buttons(game)
	await click(hud.get_node("Root/ExitButton"))
	check("HUD pause icon opens usable menu", paused and esc.visible)
	check("expanded pause menu fits viewport", root.get_visible_rect().encloses(esc.get_node("Center/Panel").get_global_rect()))
	await snapshot("pause")
	await click(esc.get_node("Center/Panel/Buttons/HelpButton"))
	check("help opens and remains paused", esc.help_page.visible and paused)
	check("help page fits viewport", root.get_visible_rect().encloses(esc.get_node("Center/Panel").get_global_rect()))
	await snapshot("help")
	await key(KEY_ESCAPE)
	check("Esc returns one help page at a time", esc.visible and not esc.help_page.visible and paused)
	await click(esc.get_node("Center/Panel/Buttons/SoundButton"))
	check("pause sound click opens correct subpage", esc.sound_page.visible)
	await key(KEY_ESCAPE)
	check("sound Esc keeps pause menu open", esc.visible and not esc.sound_page.visible and paused)
	await click(esc.continue_button)
	check("continue resumes game", not paused and not esc.visible)
	await click(hud.get_node("Root/LogButton"))
	check("log opens and isolates world input", dialogue.log_root.visible and paused)
	await key(KEY_ESCAPE)
	check("log Esc closes log without opening pause menu", not dialogue.log_root.visible and not paused and not esc.visible)
	paused = true
	esc.open_menu()
	esc._on_continue_button_pressed()
	check("closing pause restores preexisting paused state", paused)
	paused = false
	dialogue.show_log()
	blueprints.open_library()
	check("blueprints replace log without stacking modals", blueprints.modal and not dialogue.log_root.visible and paused)
	blueprints.close()
	check("closing replacement modal restores gameplay", not paused)
	var canvas = level.get_node("MapCanvas")
	canvas.active = true
	canvas.show()
	canvas.set_map_editor_mode(true)
	canvas.surface.ink_free = true
	canvas.surface.write_pixel(Vector2i(0, 0), Palette.BLACK.color)
	var data := Codec.capture(canvas, Rect2i(0, 0, 2, 2))
	blueprints.open_library()
	blueprints._items = []
	for index in 14:
		var item := data.duplicate(true)
		item.id = "ui_audit_%d" % index
		item.name = "测试蓝图 %02d" % index
		item.favorite = index == 13
		blueprints._items.append(item)
	blueprints._refresh_cards()
	await settle()
	check("blueprint first page has correct boundary buttons", blueprints._previous_page.disabled and not blueprints._next_page.disabled)
	await click(blueprints._next_page)
	check("blueprint next page displays final two cards", blueprints._page == 1 and blueprints._cards.get_child_count() == 2 and blueprints._next_page.disabled)
	await click(blueprints._cards.get_child(1))
	check("blueprint card selection is exclusive and visible", blueprints._cards.get_child(1).button_pressed and not blueprints._cards.get_child(0).button_pressed)
	blueprints._favorites.button_pressed = true
	await settle()
	check("favorite filter retains matching selected blueprint", blueprints._selected.id == "ui_audit_13" and blueprints._cards.get_child_count() == 1)
	blueprints._search.text = "no-matches"
	blueprints._search.text_changed.emit(blueprints._search.text)
	await settle()
	check("empty search clears stale usable detail", blueprints._selected.is_empty() and blueprints._use.disabled and blueprints._previous_page.disabled and blueprints._next_page.disabled)
	blueprints._search.clear()
	blueprints._search.text_changed.emit("")
	await settle()
	await snapshot("blueprints")
	blueprints.close()
	creative.active = true
	creative._ensure_editor_resources()
	creative._monster_palette.show()
	creative._monster_palette_panel.show()
	await settle()
	var column: Node = creative._monster_palette_panel.get_node("Scroll/Margin/VBox")
	var history: Node = column.get_node("EditActions/HistoryActions")
	creative._clear_edit_history()
	history.refresh()
	check("empty editor history disables undo redo", history.undo_button.disabled and history.redo_button.disabled)
	var label = creative.place_map_text(Vector2(10000, -10000), "UI 测试")
	var label_id: String = label.editor_id
	history.refresh()
	check("editor placement enables undo button", not history.undo_button.disabled)
	await click(history.undo_button)
	check("actual undo button uses mixed editor history", (not is_instance_valid(label) or not label.is_inside_tree()) and not history.redo_button.disabled)
	await click(history.redo_button)
	check("actual redo restores editor object", creative._ensure_text_container().get_children().any(func(node): return node.editor_id == label_id))
	var player_visible: bool = level.get_node("Player").visible
	await click(column.get_node("ViewActions/PlayerVisibility"))
	check("visible player toggle controls editor preview", level.get_node("Player").visible != player_visible)
	await click(column.get_node("ViewActions/PlayerVisibility"))
	check("player toggle restores prior preview state", level.get_node("Player").visible == player_visible)
	var nails_visible: bool = canvas.surface.nail_layer.visible
	await click(column.get_node("ViewActions/NailVisibility"))
	check("visible nail toggle changes only visual layer", canvas.surface.nail_layer.visible != nails_visible)
	await click(column.get_node("ViewActions/NailVisibility"))
	check("nail toggle restores prior visibility", canvas.surface.nail_layer.visible == nails_visible)
	await click(column.get_node("EditActions/SaveMapButton"))
	check("save map button opens confirmation UI only", creative._map_save_window.visible and FileAccess.get_sha256("res://test/fixtures/maps/base_level.tscn") == original_map_hash)
	creative._save_name_input.text = ""
	await click(creative._map_save_window.get_node("Content/Actions/SaveButton"))
	check("invalid map name shows actionable error without saving", creative._map_save_window.visible and creative._save_status.visible and FileAccess.get_sha256("res://test/fixtures/maps/base_level.tscn") == original_map_hash)
	creative._save_name_input.text = "UI 临时地图不保存"
	await click(creative._map_save_window.find_child("BrowseButton", true, false))
	check("map save browse opens directory chooser", creative._save_directory_dialog.visible)
	await click(creative._save_directory_dialog.get_cancel_button())
	check("directory cancel returns to map save confirmation", not creative._save_directory_dialog.visible and creative._map_save_window.visible and creative._save_name_input.text == "UI 临时地图不保存")
	await click(creative._map_save_window.find_child("BrowseButton", true, false))
	creative._save_directory_dialog.current_dir = "res://map/asset"
	await settle()
	await click(creative._save_directory_dialog.get_ok_button())
	check("directory confirmation fills original save form", not creative._save_directory_dialog.visible and creative._map_save_window.visible and creative._save_directory_input.text.trim_suffix("/") == "res://map/asset")
	check("directory selection never writes or renames map", creative._save_name_input.text == "UI 临时地图不保存" and FileAccess.get_sha256("res://test/fixtures/maps/base_level.tscn") == original_map_hash)
	await click(creative._map_save_window.get_node("Content/Actions/CancelButton"))
	check("map save cancel works", not creative._map_save_window.visible)
	audit_buttons(creative._monster_palette)
	await snapshot("editor")
	creative.active = false
	blueprints.store = old_store
	audio.config_path = old_config
	if FileAccess.file_exists(test_config):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(test_config))
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(test_store)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(test_store))
	esc.open_menu()
	await settle()
	await click(esc.get_node("Center/Panel/Buttons/MenuButton"))
	check("actual pause return button reloads main menu unpaused", current_scene != app and current_scene != null and current_scene.has_node("UI") and current_scene.get_node("UI").get_child(0).has_node("ButtonCenter") and not paused)
	if current_scene != null:
		current_scene.queue_free()
	await settle()
	print("[UIInteractions] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
