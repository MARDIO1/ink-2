extends SceneTree
## 地图编辑器的放置类工具：新增/移动/删除复活点，以及关卡选择里的「新建空白地图」。

const Levels := preload("res://ui/level_select/src/level_select.gd")
var failures := 0
var checks := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[LayoutTools] %s %s" % ["PASS" if ok else "FAIL", label])


func click(creative, button: int, world_position: Vector2, pressed := true) -> bool:
	var event := InputEventMouseButton.new()
	event.button_index = button
	event.pressed = pressed
	event.position = creative.get_viewport().get_canvas_transform() * world_position
	return creative._handle_layout_mouse_button(event)


func respawns(level) -> Array:
	var result := []
	for child in level.get_children():
		if child.is_in_group(&"respawn_point") and not child.is_queued_for_deletion():
			result.append(child)
	return result


func _run() -> void:
	var level = load("res://map/asset/blank_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	creative.set_active(true)
	await process_frame

	# 新增：空地单击放一个。
	creative.select_monster_tool(creative.LAYOUT_MODE_PLACE_RESPAWN)
	var empty := Vector2(400, 0)
	check("left click on empty ground places a respawn", click(creative, MOUSE_BUTTON_LEFT, empty))
	await process_frame
	var points := respawns(level)
	check("one respawn exists", points.size() == 1)
	if points.is_empty():
		quit(1)
		return
	var first: Marker2D = points[0]

	# 移动：按在已有复活点上不再是「再放一个」，而是拖动它。
	var before: int = points.size()
	click(creative, MOUSE_BUTTON_LEFT, first.global_position)
	var motion := InputEventMouseMotion.new()
	motion.position = creative.get_viewport().get_canvas_transform() * (first.global_position + Vector2(60, 40))
	creative._handle_layout_mouse_motion(motion)
	click(creative, MOUSE_BUTTON_LEFT, first.global_position + Vector2(60, 40), false)
	await process_frame
	check("left press on an existing respawn drags instead of stacking", respawns(level).size() == before
		and first.global_position.distance_to(empty) > 10.0)

	# 右键删除：不用切工具。
	check("right click deletes the respawn under the cursor",
		click(creative, MOUSE_BUTTON_RIGHT, first.global_position) and respawns(level).is_empty())
	check("respawn delete is undoable", creative.undo_last_edit() and respawns(level).size() == 1)
	check("respawn delete is redoable", creative.redo_last_edit() and respawns(level).is_empty())

	# 删除工具按钮本身。
	creative.select_monster_tool(creative.LAYOUT_MODE_DELETE_RESPAWN)
	var placed: Marker2D = creative.place_respawn_point(Vector2(700, 0))
	await process_frame
	check("delete tool removes a picked respawn",
		click(creative, MOUSE_BUTTON_LEFT, placed.global_position) and respawns(level).is_empty())

	# 新建空白地图：文件要真的写出来，并且进得了关卡列表。
	var created := Levels.create_blank_map()
	check("blank map file is created", not created.is_empty() and FileAccess.file_exists(created))
	check("blank template itself never lists as a level", not Levels.find_levels().has(Levels.BLANK_TEMPLATE))
	check("new blank map appears in the level list", Levels.find_levels().has(created))
	var text := FileAccess.get_file_as_string(created)
	var header := text.substr(0, maxi(0, text.find("\n")))
	check("copied scene gets its own identity", not header.contains("uid="))
	if FileAccess.file_exists(created):
		DirAccess.remove_absolute(created)

	level.queue_free()
	await process_frame
	print("[LayoutTools] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
