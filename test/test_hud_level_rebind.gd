extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, okay: bool) -> void:
	print("[HUDLevelRebind] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func _tab() -> void:
	var event := InputEventKey.new()
	event.keycode = KEY_TAB
	event.physical_keycode = KEY_TAB
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame

func _run() -> void:
	var app = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	var level = app.load_level(load("res://map/asset/imported/main.tscn"))
	level.auto_step = false
	app._set_screen(app.ui_scene.instantiate())
	var hud = app.ui_root.get_child(0).get_node("Hud")
	await _tab()
	_check("Tab enables debug HUD on initial level", level.get_node("debugHUD").visible and not hud.visible)
	await _tab()
	_check("Tab restores normal HUD", hud.visible and not level.get_node("debugHUD").visible)
	var creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	var previous_id: int = level.get_instance_id()
	creative.set_active(true)
	for _frame in 120:
		await process_frame
		var candidate = app.level_root.get_child(0)
		if candidate.get_instance_id() != previous_id and candidate.get_node("Creative").active:
			break
	level = app.level_root.get_child(0)
	level.auto_step = false
	creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	_check("editor reload keeps UI but replaces level", level.get_instance_id() != previous_id and creative.active and app.ui_root.get_child(0).get_node("Hud") == hud)
	_check("HUD rebinds debug panel and health after reload", hud.debug_hud == level.get_node("debugHUD") and hud._health == level.get_node("Player/InkHealth"))
	await _tab()
	_check("Tab preserves editor UI after reload", not level.get_node("debugHUD").visible and hud.visible)
	creative.set_active(false)
	await _tab()
	_check("Tab works after leaving editor", not hud.visible and level.get_node("debugHUD").visible)
	await _tab()
	var focus_button := Button.new()
	hud.get_node("Root").add_child(focus_button)
	focus_button.grab_focus()
	await _tab()
	_check("focused UI control does not swallow Tab toggle", level.get_node("debugHUD").visible)
	await _tab()
	level.get_node("Player/InkHealth").reduce(1, 500)
	_check("new player health updates reused HUD", hud.ink_meter.text == "黑墨 19500 px")
	hud.debug_hud = null
	await _tab()
	_check("Tab repairs missing cached debug reference", level.get_node("debugHUD").visible)
	app.queue_free()
	await process_frame
	quit(1 if failures else 0)
