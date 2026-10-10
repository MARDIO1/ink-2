extends "res://test/test_collision_damage.gd"


func _initialize() -> void:
	call_deferred("_run_layout_test")


func _run_layout_test() -> void:
	var valid := true
	var scene: Node = load("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame

	var creative: Node = scene.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	creative.set_active(true)
	await process_frame

	var spawn := scene.get_node_or_null("PlayerSpawn") as Marker2D
	var main_canvas: Node2D = scene.get_node("SmallCanvas")
	valid = valid and spawn != null
	valid = valid and _count_player_spawns(scene) == 1
	valid = valid and creative.get_node_or_null("MapPlacementOverlay") != null
	valid = valid and creative.get_node_or_null(
		"MonsterPalette/Root/Panel/Scroll/Margin/VBox/LayoutGrid/MoveSpawnButton"
	) == null

	var original_canvas_position := main_canvas.global_position
	spawn.global_position += Vector2(137.0, 59.0)
	valid = valid and main_canvas.global_position.is_equal_approx(original_canvas_position)

	var respawn: Marker2D = creative.place_respawn_point(spawn.global_position + Vector2(500.0, 0.0))
	valid = valid and respawn != null and respawn.is_in_group(&"respawn_point")
	var added_canvas: Node2D = creative.place_play_canvas(spawn.global_position + Vector2(900.0, 300.0))
	valid = valid and added_canvas != null and added_canvas.is_in_group(&"play_canvas")
	valid = valid and added_canvas.get("canvas_size") == main_canvas.get("canvas_size")
	valid = valid and creative._play_canvases().size() == 2

	var player: Node2D = scene.get_node("Player")
	var fall_death: Node = player.get_node("FallDeath")
	fall_death.set("_body", player.get("body"))
	player.body.position = respawn.global_position + Vector2(8.0, 0.0)
	player.body.refresh_com()
	valid = valid and fall_death._find_respawn_target() == respawn
	player.body.position = spawn.global_position + Vector2(8.0, 0.0)
	player.body.refresh_com()
	valid = valid and fall_death._find_respawn_target() == spawn

	valid = valid and creative.undo_last_edit()
	valid = valid and (not is_instance_valid(added_canvas) or added_canvas.is_queued_for_deletion())
	await process_frame
	valid = valid and creative.undo_last_edit()
	valid = valid and (not is_instance_valid(respawn) or respawn.is_queued_for_deletion())

	creative.set_active(false)
	print("[SpawnRespawnCanvasLayout] ", "PASS" if valid else "FAIL")
	scene.queue_free()
	await process_frame
	quit(0 if valid else 1)


func _count_player_spawns(root_node: Node) -> int:
	var count := 1 if root_node is Marker2D and String(root_node.name) == "PlayerSpawn" else 0
	for child in root_node.get_children():
		count += _count_player_spawns(child)
	return count
