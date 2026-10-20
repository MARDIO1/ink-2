extends SceneTree

var checks := 0
var failures := 0
const SAVE := "user://restart_regression.tscn"

func _initialize() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("[Restart] %s %s" % ["PASS" if condition else "FAIL", message])

func _escape() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_ESCAPE
	event.physical_keycode = KEY_ESCAPE
	event.pressed = true
	root.push_input(event)

func _save_fixture(version: int) -> void:
	var level: Node = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.set_meta("saved_version", version)
	var packed := PackedScene.new()
	packed.pack(level)
	_check(ResourceSaver.save(packed, SAVE) == OK, "write temporary saved map")
	level.free()

func _run() -> void:
	var transition: Node = root.get_node("SceneTransition")
	transition.duration = 0.01
	root.size = Vector2i(960, 540)
	var app: Node = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	await process_frame
	_save_fixture(1)
	_check(await app.request_level_change(SAVE), "load saved map through router")
	var ui: Node = app.ui_root.get_child(0)
	var menu: Node = ui.get_node("Esc")
	var dialogue: Node = ui.get_node("Dialogue")
	dialogue.start_dialogue(PackedStringArray(["first", "second"]))
	_escape()
	_check(not dialogue.root.visible and not menu.visible and not paused, "first Escape skips dialogue without opening pause menu")
	_escape()
	_check(menu.visible and paused, "next Escape opens pause menu")
	await process_frame
	var panel: Control = menu.get_node("Center/Panel")
	_check(panel.get_global_rect().position.y >= 0 and panel.get_global_rect().end.y <= root.get_visible_rect().size.y, "seven-button pause panel fits the game viewport")
	_check(not menu.get_node("Center/Panel/Buttons/RestartButton").disabled, "restart enabled during play")
	_escape()
	dialogue.start_dialogue(PackedStringArray(["history test"]))
	dialogue.show_log()
	_escape()
	_check(not dialogue.log_root.visible and dialogue.root.visible and not paused, "Escape closes history before skipping active dialogue")
	_escape()
	var level: Node = app.level_root.get_child(0)
	level.set_meta("runtime_only", true)
	level.get_node("Box").position = Vector2(999, 999)
	var old: WeakRef = weakref(level)
	# Keep original cached resource alive while replacing disk state.
	var cached: PackedScene = load(SAVE)
	_save_fixture(2)
	menu.open_menu()
	menu.get_node("Center/Panel/Buttons/RestartButton").pressed.emit()
	while app._loading_level:
		await process_frame
	await process_frame
	level = app.level_root.get_child(0)
	_check(old.get_ref() == null, "restart frees old level and its runtime state")
	_check(level.get_meta("saved_version") == 2 and not level.has_meta("runtime_only"), "restart rereads disk instead of cached scene or live state")
	_check(level.get_node("Box").position.distance_to(Vector2(322, 53)) < 1, "mechanism restored to saved position")
	_check(not paused and not transition.busy, "restart from pause menu resumes gameplay")
	_check(cached != null, "cache regression retains original scene resource")
	menu = app.ui_root.get_child(0).get_node("Esc")
	var creative: Node = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.active = true
	menu.open_menu()
	_check(menu.get_node("Center/Panel/Buttons/RestartButton").disabled, "restart disabled in map editor")
	menu._on_restart_button_pressed()
	_check(not await app.restart_current_level() and app.level_root.get_child(0) == level and menu.visible and paused, "editor rejects direct restart and keeps document and pause intact")
	creative.active = false
	menu._on_continue_button_pressed()
	app.queue_free()
	await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	print("[Restart] %d checks; %d failures" % [checks, failures])
	quit(1 if failures else 0)
