extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const YellowStroke := preload("res://ink/yellow/src/stroke.gd")
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, ok: bool) -> void:
	print("[EditorRecordRedo] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1


func _yellow_at(surface, point: Vector2i) -> bool:
	return surface.rod_layer.pixels.get_pixelv(point).a > 0.5


func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	level.materials.append(Palette.RED)
	level.materials.append(Palette.YELLOW)
	root.add_child(level)
	await process_frame
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(96, 96)
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	creative._canvas_width_input.value = 320
	creative._canvas_height_input.value = 192
	creative._confirm_canvas_size()
	_check("canvas size dialog starts placement with chosen dimensions",
		creative._new_canvas_size == Vector2i(320, 192) and creative._monster_mode == -11)
	var extra_canvas = creative.place_play_canvas(Vector2(15000, -10000))
	_check("new play canvas uses configured dimensions", extra_canvas != null
		and extra_canvas.canvas_size == Vector2i(320, 192)
		and extra_canvas.global_position == Vector2(14840, -10096))
	creative.select_monster_tool(-12) # 移动画布模式
	var canvas_mouse := InputEventMouseButton.new()
	canvas_mouse.button_index = MOUSE_BUTTON_LEFT
	canvas_mouse.pressed = true
	canvas_mouse.position = root.get_viewport().get_canvas_transform() * Vector2(15000, -10000)
	creative.editor_mouse_button(canvas_mouse)
	var canvas_motion := InputEventMouseMotion.new()
	canvas_motion.position = root.get_viewport().get_canvas_transform() * Vector2(15120, -9960)
	creative.editor_mouse_motion(canvas_motion)
	canvas_mouse.pressed = false
	canvas_mouse.position = canvas_motion.position
	creative.editor_mouse_button(canvas_mouse)
	_check("left drag moves existing canvas", extra_canvas.global_position == Vector2(14960, -10056))
	var canvas_delete := InputEventMouseButton.new()
	canvas_delete.button_index = MOUSE_BUTTON_RIGHT
	canvas_delete.pressed = true
	canvas_delete.position = root.get_viewport().get_canvas_transform() * Vector2(15120, -9960)
	creative.editor_mouse_button(canvas_delete)
	_check("right click removes existing canvas", not extra_canvas.is_inside_tree())
	_check("canvas deletion undo restores exact node and size", creative.undo_last_edit()
		and extra_canvas.is_inside_tree() and extra_canvas.canvas_size == Vector2i(320, 192))
	_check("canvas deletion redo removes it again", creative.redo_last_edit()
		and not extra_canvas.is_inside_tree())
	creative.undo_last_edit()
	_check("canvas drag undo restores position", creative.undo_last_edit()
		and extra_canvas.global_position == Vector2(14840, -10096))
	creative.select_control_tool()
	canvas_delete.position = root.get_viewport().get_canvas_transform() * Vector2(15000, -10000)
	creative.editor_mouse_button(canvas_delete)
	_check("control tool right click also deletes canvas", not extra_canvas.is_inside_tree())
	creative.undo_last_edit()
	var main_canvas = level.get_node("SmallCanvas")
	creative.delete_play_canvas(main_canvas)
	_check("deleting primary canvas switches active reference", creative._canvas == extra_canvas)
	_check("undo restores original primary canvas", creative.undo_last_edit()
		and creative._canvas == main_canvas and main_canvas.is_inside_tree())
	_check("new canvas placement remains undoable", creative.undo_last_edit()
		and creative.editor_canvases().size() == 1)
	creative.select_monster_tool(-1)
	var surface = canvas.surface
	surface.write_pixel(Vector2i(12, 12), Palette.RED.color)
	surface.write_pixel(Vector2i(20, 12), Palette.YELLOW.color)
	surface.refresh()
	_check("red and yellow are present before solidify",
		surface.material_at(12, 12) == Palette.RED.id
		and _yellow_at(surface, Vector2i(20, 12)))
	canvas.generate(false)
	canvas.return_to_canvas(false)
	_check("inkify restores red and yellow blueprint pixels",
		surface.material_at(12, 12) == Palette.RED.id
		and _yellow_at(surface, Vector2i(20, 12)))
	var bodies_before: int = level.world.bodies.size()
	canvas.generate()
	_check("solidify has a shared undo step", creative.undo_last_edit()
		and level.world.bodies.size() == bodies_before
		and surface.material_at(12, 12) == Palette.RED.id)
	_check("solidify transaction can be redone", creative.redo_last_edit()
		and level.world.bodies.size() > bodies_before
		and surface.material_at(12, 12) == 0)
	canvas.return_to_canvas(false)

	surface._begin_undo_step()
	surface._write_pixel(Vector2i(30, 30), Palette.BLACK.color, 100)
	surface._commit_undo_step()
	_check("canvas undo removes edit", creative.undo_last_edit()
		and surface.material_at(30, 30) == 0)
	var redo_key := InputEventKey.new()
	redo_key.pressed = true
	redo_key.ctrl_pressed = true
	redo_key.keycode = KEY_Y
	_check("Ctrl+Y repeats canvas edit", creative.editor_input(redo_key)
		and surface.material_at(30, 30) == Palette.BLACK.id)
	_check("redone canvas edit is undoable again", creative.undo_last_edit()
		and surface.material_at(30, 30) == 0)

	var portal = creative.place_portal(Vector2(10100, -10000))
	_check("placement undo", creative.undo_last_edit() and not portal.is_inside_tree())
	_check("placement redo", creative.redo_last_edit() and creative.editor_portals().size() == 1)
	_check("redone placement can be undone", creative.undo_last_edit()
		and creative.editor_portals().is_empty())
	creative.redo_last_edit()
	var placed_portal = creative.editor_portals()[0]
	creative.delete_portal(placed_portal)
	_check("portal deletion undo restores a portal", creative.undo_last_edit()
		and creative.editor_portals().size() == 1)
	_check("portal deletion redo removes restored portal", creative.redo_last_edit()
		and creative.editor_portals().is_empty())
	var label = creative.place_map_text(Vector2(10120, -10000), "重做文字")
	var text_id: String = label.editor_id
	label.scale = Vector2.ONE * 1.5
	creative._record_edit({"type": &"object_transform", "target": label,
		"old_position": label.global_position, "old_scale": Vector2.ONE})
	creative.remove_map_text_at(label.global_position)
	var text_undo: bool = creative.undo_last_edit() and creative.undo_last_edit() and creative.undo_last_edit()
	_check("text delete, resize and placement undo in order", text_undo
		and creative._find_editor_node(creative._ensure_text_container(), text_id) == null)
	var text_place_redo: bool = creative.redo_last_edit()
	var text_resize_redo: bool = creative.redo_last_edit()
	var text_redo: bool = text_place_redo and text_resize_redo
	var redone_text = creative._find_editor_node(creative._ensure_text_container(), text_id)
	_check("text placement and resize redo bind new node", text_redo
		and redone_text != null and redone_text.scale.is_equal_approx(Vector2.ONE * 1.5))
	_check("text deletion redo", creative.redo_last_edit()
		and creative._find_editor_node(creative._ensure_text_container(), text_id) == null)
	surface.rod_layer.begin(Vector2(60, 60))
	surface.rod_layer.finish(Vector2(64, 60))
	_check("yellow rod undo", creative.undo_last_edit()
		and not _yellow_at(surface, Vector2i(62, 60)))
	_check("yellow rod redo", creative.redo_last_edit()
		and _yellow_at(surface, Vector2i(62, 60)))
	canvas.clear_canvas()
	_check("clear undo restores all ink colors", creative.undo_last_edit()
		and surface.material_at(12, 12) == Palette.RED.id
		and _yellow_at(surface, Vector2i(20, 12)))
	_check("clear redo empties both ink layers", creative.redo_last_edit()
		and surface.material_at(12, 12) == 0
		and not _yellow_at(surface, Vector2i(20, 12)))
	creative.undo_last_edit()
	var spring := YellowStroke.new()
	spring.path = PackedVector2Array([level.to_local(surface.to_global(Vector2(70, 70))),
		level.to_local(surface.to_global(Vector2(82, 70)))])
	spring.compact_raster = true
	spring.source_surface = surface
	spring.source_canvas = level.get_path_to(surface)
	level.add_child(spring)
	spring.state = YellowStroke.State.ACTIVE
	spring.activated = true
	var yellow_rule = surface.yellow_rule()
	yellow_rule.strokes.append(spring)
	canvas.return_to_canvas(false, true)
	_check("editor inkify keeps active yellow spring as editable draft",
		spring.state == YellowStroke.State.EDITING and not spring.activated
		and yellow_rule.strokes.has(spring))
	yellow_rule.strokes.erase(spring)
	level.remove_child(spring)
	spring.queue_free()

	var record_path := "res://test/.editor_record_redo.tmp.tscn"
	var stale_path := "res://test/.editor_record_redo.tmp.edit.snapshot"
	creative.map_path = record_path
	# 留一张旧快照，确保退出保存的新场景不会在下一次进入时被旧画面覆盖。
	surface.write_pixel(Vector2i(40, 40), Palette.BLACK.color)
	surface.refresh()
	surface.save_ink(stale_path)
	surface.write_pixel(Vector2i(40, 40), Color.TRANSPARENT)
	surface.refresh()
	# 退出编辑器**不再**自动覆盖地图（`b9c6ef5` 有意去掉，避免模式切换写盘），
	# 所以这里显式导出一次，再验证记录能随场景保存并在重进后恢复。
	var save_error: int = creative.export_map_to(record_path)
	creative.set_active(false)
	_check("exit writes record 1", save_error == OK and FileAccess.file_exists(record_path))
	level.queue_free()
	await process_frame
	var saved_scene := ResourceLoader.load(record_path, "PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var restored = saved_scene.instantiate() if saved_scene != null else null
	_check("saved record can be loaded", restored != null)
	if restored != null:
		restored.auto_step = false
		root.add_child(restored)
		await process_frame
		var restored_editor = restored.get_node("Creative")
		restored_editor.auto_save_edits = false
		restored_editor.auto_save_on_exit = true
		restored_editor.set_active(true)
		var restored_surface = restored.get_node("MapCanvas/CanvasSurface")
		_check("enter restores record 1 then inkifies it",
			restored_surface.material_at(12, 12) == Palette.RED.id
			and _yellow_at(restored_surface, Vector2i(20, 12)))
		_check("older snapshot does not cover the saved record",
			restored_surface.material_at(40, 40) == 0
			and not restored_editor._edit_snapshot_loaded)
		restored_surface.write_pixel(Vector2i(50, 50), Palette.BLACK.color)
		restored_surface.refresh()
		restored_editor.set_active(false)
		restored.queue_free()
		await process_frame
		var second_scene := ResourceLoader.load(record_path, "PackedScene",
			ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		var second = second_scene.instantiate() if second_scene != null else null
		if second != null:
			second.auto_step = false
			root.add_child(second)
			await process_frame
			var second_editor = second.get_node("Creative")
			second_editor.auto_save_edits = false
			second_editor.auto_save_on_exit = false
			second_editor.set_active(true)
			var second_surface = second.get_node("MapCanvas/CanvasSurface")
			_check("record 2 replaces record 1", second_surface.material_at(12, 12) == Palette.RED.id
				and _yellow_at(second_surface, Vector2i(20, 12))
				and second_surface.material_at(50, 50) == Palette.BLACK.id)
			second_editor.set_active(false)
			second.queue_free()
			await process_frame
		else:
			_check("record 2 can be loaded", false)
	for path in [record_path, stale_path]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	quit(1 if failures else 0)
