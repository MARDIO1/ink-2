extends SceneTree

const Monster := preload("res://actor/monster/src/map_monster.gd")
var failures := 0
var creative: Node


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, okay: bool) -> void:
	print("[MonsterDelete] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1


func _mouse(point: Vector2, button: int, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.position = root.get_canvas_transform() * point
	event.global_position = event.position
	event.button_index = button
	event.pressed = pressed
	return event


func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	level.get_node("debugHUD").process_mode = Node.PROCESS_MODE_DISABLED
	await process_frame
	creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	creative.set_physics_process(false)
	var camera: Camera2D = level.get_node("Camera2D")
	camera.set_physics_process(false)
	camera.position_smoothing_enabled = false
	camera.zoom = Vector2.ONE * 0.35
	var button: Button = creative._delete_monster_button
	_check("delete button exists in monster grid", button != null and button.get_parent().name == "MonsterGrid")
	creative._monster_palette_panel.hide()
	for kind in [Monster.Kind.LITTLE_SOLDIER, Monster.Kind.BOMB_SIDE, Monster.Kind.SHIELD_SOLDIER]:
		var monster = creative.place_monster(kind, Vector2(10000, -10000), false)
		var monster_id: String = monster.editor_id
		for mode in [kind, creative.MONSTER_MODE_NONE, creative.MONSTER_MODE_ADJUST, creative.MONSTER_MODE_DELETE, creative.CONTROL_MODE]:
			creative.select_monster_tool(creative.MONSTER_MODE_NONE)
			if mode != creative.MONSTER_MODE_NONE:
				creative.select_monster_tool(mode)
			var art: Sprite2D = Monster.Ragdoll.body_art(monster.get_node("Visual"))
			var point: Vector2 = art.to_global(art.get_rect().get_center())
			camera.global_position = point
			camera.force_update_scroll()
			await process_frame
			root.push_input(_mouse(point, MOUSE_BUTTON_RIGHT, true), true)
			root.push_input(_mouse(point, MOUSE_BUTTON_RIGHT, false), true)
			_check("right click deletes kind=%d mode=%d" % [kind, mode], creative.monster_count() == 0)
			_check("undo restores monster", creative.undo_last_edit() and creative.monster_count() == 1)
			_check("redo deletes monster", creative.redo_last_edit() and creative.monster_count() == 0)
			_check("second undo restores monster", creative.undo_last_edit() and creative.monster_count() == 1)
			monster = creative._ensure_monster_container().get_child(0)
			_check("identity preserved", monster.editor_id == monster_id)
		if kind == Monster.Kind.SHIELD_SOLDIER:
			var shield: Sprite2D = monster._shield_visual
			var point: Vector2 = shield.to_global(shield.get_rect().position + shield.get_rect().size * Vector2(0.05, 0.5))
			_check("visible shield participates in picking", creative._find_monster_at(point) == monster)
		creative.select_control_tool()
		creative.editor_drag_begin(monster, monster.global_position)
		_check("monster drag locks view", creative._monster_drag_view_locked)
		var drag_art: Sprite2D = Monster.Ragdoll.body_art(monster.get_node("Visual"))
		var drag_point: Vector2 = drag_art.to_global(drag_art.get_rect().get_center())
		_check("right click deletes during drag", creative.editor_input(_mouse(drag_point, MOUSE_BUTTON_RIGHT, true)) and creative.monster_count() == 0)
		_check("deletion clears drag, selection and camera lock", creative._layout_drag_target == null
			and creative._selected_control_target == null and not creative._monster_drag_view_locked)
		_check("drag deletion can be undone", creative.undo_last_edit() and creative.monster_count() == 1)
		monster = creative._ensure_monster_container().get_child(0)
		creative.select_monster_tool(creative.MONSTER_MODE_NONE)
		button.pressed.emit()
		_check("button activates delete mode", creative._monster_mode == creative.MONSTER_MODE_DELETE and button.button_pressed)
		var art: Sprite2D = Monster.Ragdoll.body_art(monster.get_node("Visual"))
		var point: Vector2 = art.to_global(art.get_rect().get_center())
		camera.global_position = point
		camera.force_update_scroll()
		_check("delete tool left click removes monster", creative.editor_input(_mouse(point, MOUSE_BUTTON_LEFT, true)) and creative.monster_count() == 0)
		button.pressed.emit()
		_check("second button press exits delete mode", creative._monster_mode == creative.MONSTER_MODE_NONE and not button.button_pressed)
		creative._clear_edit_history()
	creative.select_control_tool()
	_check("empty right click is not consumed", not creative.editor_input(_mouse(Vector2(20000, -20000), MOUSE_BUTTON_RIGHT, true)))
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
