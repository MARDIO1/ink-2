extends SceneTree
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, condition: bool) -> void:
	print("[MonsterDrag] ", label, ": ", "PASS" if condition else "FAIL")
	if not condition:
		failures += 1


func _run() -> void:
	var level := (load("res://test/fixtures/maps/base_level.tscn") as PackedScene).instantiate()
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	root.add_child(level)
	await process_frame
	await physics_frame
	creative.set_active(true)
	await process_frame
	var camera = level.get_node("Camera2D")
	var player = level.get_node("Player")
	for kind in [1, 3, 2]:
		var monster = creative.place_monster(kind, Vector2(kind * 700, -100), false)
		await process_frame
		for unified in [false, true]:
			creative.select_monster_tool(creative.CONTROL_MODE if unified else creative.MONSTER_MODE_ADJUST)
			camera.zoom = Vector2.ONE * (2.5 if unified else 1.25)
			camera.force_update_scroll()
			var view: Transform2D = root.get_canvas_transform()
			var old_position: Vector2 = monster.global_position
			var pivot: Vector2 = monster._ragdoll.parts[0].bone.global_position
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.pressed = true
			click.position = view * pivot
			var handled: bool = creative._handle_layout_mouse_button(click) if unified else creative._handle_monster_adjust_button(click)
			_check("drag starts for kind " + str(kind), handled and creative._monster_drag_view_locked)
			var owned: Array = [monster.body]
			for part in monster._ragdoll.parts:
				owned.append(part.body)
			if monster._ragdoll.shield_body != null:
				owned.append(monster._ragdoll.shield_body)
			var old_body_position: Vector2 = monster.body.position
			var ids: Array = owned.map(func(body): return body.id)
			var shapes: Array = owned.map(func(body): return body.shapes[0])
			var joints: Array = monster._ragdoll.joints.duplicate()
			var camera_position: Vector2 = camera.global_position
			var camera_zoom: Vector2 = camera.zoom
			var player_position: Vector2 = player.body.position
			var player_frozen: bool = creative._drag_player_states[0].frozen
			var screen_delta := Vector2(90, 45)
			var world_delta: Vector2 = view.affine_inverse().basis_xform(screen_delta)
			var motion := InputEventMouseMotion.new()
			var start := Time.get_ticks_usec()
			for index in 1000:
				motion.position = click.position + screen_delta * float(index + 1) / 1000.0
				if unified:
					creative._handle_layout_mouse_motion(motion)
				else:
					creative._handle_monster_adjust_motion(motion)
			print("[MonsterDrag] 1000 events kind=", kind, " unified=", unified, " ms=", (Time.get_ticks_usec() - start) / 1000.0)
			_check("mouse events only preview, physics updates coalesced", monster.body.position == old_body_position)
			Input.action_press("fly_right")
			creative._physics_process(1.0 / 60.0)
			camera._physics_process(1.0 / 60.0)
			Input.action_release("fly_right")
			_check("screen displacement is exactly one to one at both zooms", monster.global_position.is_equal_approx(old_position + world_delta))
			_check("collider follows final drag position", monster.body.position.is_equal_approx(old_body_position + world_delta))
			_check("camera position and zoom stay fixed", camera.global_position == camera_position and camera.zoom == camera_zoom)
			_check("hidden player does not drift", player.body.position == player_position and player.body.frozen)
			_check("drag preserves native bodies/shapes/joints", ids == owned.map(func(body): return body.id)
				and shapes == owned.map(func(body): return body.shapes[0]) and joints == monster._ragdoll.joints)
			click.pressed = false
			click.position = motion.position
			if unified:
				creative._handle_layout_mouse_button(click)
			else:
				creative._handle_monster_adjust_button(click)
			_check("release restores camera and player freeze state", not creative._monster_drag_view_locked
				and not camera._editor_drag_locked and player.body.frozen == player_frozen)
			_check("undo restores original monster position", creative.undo_last_edit() and monster.global_position.is_equal_approx(old_position))
		creative._begin_layout_drag(monster, monster.global_position)
		creative.select_monster_tool(creative.MONSTER_MODE_NONE)
		_check("tool switch cancels camera lock", not creative._monster_drag_view_locked and not camera._editor_drag_locked)
		creative._begin_layout_drag(monster, monster.global_position)
		creative._on_drag_focus_lost()
		_check("losing focus releases camera/player lock", not creative._monster_drag_view_locked and not camera._editor_drag_locked)
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
