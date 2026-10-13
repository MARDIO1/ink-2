extends SceneTree

const LevelSelect := preload("res://ui/level_select/src/level_select.gd")


func _initialize() -> void:
	assert(LevelSelect.find_levels().has("res://map/second/第二关·墨泉边.tscn"))
	var packed := load("res://map/second/第二关·墨泉边.tscn") as PackedScene
	assert(packed != null)
	var level := packed.instantiate()
	root.add_child(level)
	await process_frame
	assert(level.get_node("Scenery/House") is Sprite2D)
	assert(level.get_node("Scenery/InkFountain/Sprite") is Sprite2D)
	assert(level.get_node("Scenery/InkFountain/Sprite").texture.resource_path == "res://actor/fountain/asset/ink_fountain.png")
	assert(level.get_node("Scenery/House").find_children("*", "CollisionObject2D", true, false).is_empty())
	assert(level.get_node("Scenery/InkFountain").find_children("*", "CollisionObject2D", true, false).is_empty())
	assert(level.get_node("DialogueTriggers").get_child_count() == 4)
	assert(level.get_node("Monsters/CorruptedCivilian") != null)
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	var fountain_count := get_nodes_in_group(&"ink_fountain").size()
	var placed = creative.place_ink_fountain(Vector2(900, 300))
	assert(placed != null and placed.scale == Vector2.ONE)
	assert(creative._pick_control_target(placed.global_position, true) == null)
	assert(get_nodes_in_group(&"ink_fountain").size() == fountain_count + 1)
	assert(creative.delete_ink_fountain(placed))
	assert(creative.undo_last_edit())
	assert(get_nodes_in_group(&"ink_fountain").size() == fountain_count + 1)
	print("[SecondLevel] scene, story triggers, non-colliding scenery: OK")
	quit()
