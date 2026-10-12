extends SceneTree

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var ui = load("res://ui/game_ui.tscn").instantiate()
	root.add_child(ui)
	await process_frame
	var hud = ui.get_node("Hud")
	var esc = get_first_node_in_group(&"esc_menu")
	var ok: bool = esc.get_node("Center/Panel/Buttons/Title").text == "INT FFF"
	hud.get_node("Root/ExitButton").pressed.emit()
	ok = ok and paused and esc.visible and ui.is_inside_tree()
	esc._on_continue_button_pressed()
	ok = ok and not paused and not esc.visible
	hud.get_node("Root/ExitButton").pressed.emit()
	ok = ok and paused and esc.visible and get_nodes_in_group(&"esc_menu").size() == 1
	esc._on_continue_button_pressed()
	print("[HUDExitMenu] title, exit opens pause menu, continue and reuse: ", "PASS" if ok else "FAIL")
	ui.queue_free()
	await process_frame
	quit(0 if ok else 1)
