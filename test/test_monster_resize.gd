extends SceneTree
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, ok: bool) -> void:
	print("[MonsterResize] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _run() -> void:
	var level: Node = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	root.add_child(level)
	await process_frame
	var creative: Node = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	var monster: Node2D = creative.place_monster(3, Vector2(500, 100), false)
	await process_frame
	var old_scale: float = monster.scale.x
	var old_bounds: Rect2i = monster._ragdoll.shield_body.shapes[0].local_aabb()
	_check("control wheel enabled", creative._resize_control_target(monster, 1.0))
	var new_bounds: Rect2i = monster._ragdoll.shield_body.shapes[0].local_aabb()
	_check("body and shield scale together", monster.scale.x > old_scale and new_bounds.size.x > old_bounds.size.x and new_bounds.size.y > old_bounds.size.y)
	_check("shield visual matches collision scale", is_equal_approx(absf(monster._shield_visual.global_scale.x), monster.shield_scale * monster.scale.x))
	creative._selected_monster = monster
	creative._resize_selected_monster(2.0)
	_check("old upper bound removed", monster.scale.x > 2.5)
	creative._resize_selected_monster(-2.8)
	_check("old lower bound removed", monster.scale.x < 0.35 and monster.scale.x > 0.0)
	creative._reset_selected_monster_scale()
	_check("restore default scale", is_equal_approx(monster.scale.x, 0.9))
	var restored: Node2D = creative.place_monster(3, Vector2(800, 100), false, "custom-size", Vector2.ONE * 1.4)
	_check("explicit size preserved for restoration", restored.scale.is_equal_approx(Vector2.ONE * 1.4))
	var scene := PackedScene.new()
	scene.pack(level)
	var state := scene.get_state()
	var saved := false
	for i in state.get_node_count():
		if state.get_node_name(i) == restored.name:
			for j in state.get_node_property_count(i):
				if state.get_node_property_name(i, j) == "scale":
					saved = state.get_node_property_value(i, j).is_equal_approx(restored.scale)
	_check("save preserves custom scale", saved)
	creative._edit_history.clear()
	creative._resize_control_target(restored, 1.0)
	_check("wheel scale undo", creative.undo_last_edit() and restored.scale.is_equal_approx(Vector2.ONE * 1.4))
	_check("delete scaled monster", creative.remove_monster_at(restored.global_position))
	_check("undo deletion", creative.undo_last_edit())
	var restored_again: Node2D = null
	for candidate in creative._ensure_monster_container().get_children():
		if candidate.editor_id == "custom-size":
			restored_again = candidate
	_check("deletion undo retains body and shield size", restored_again != null and restored_again.scale.is_equal_approx(Vector2.ONE * 1.4) and is_equal_approx(absf(restored_again._shield_visual.global_scale.x), restored_again.shield_scale * 1.4))
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
