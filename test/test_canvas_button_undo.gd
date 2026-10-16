extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
var failures := 0
var checks := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	print("[ButtonUndo] ", "PASS " if ok else "FAIL ", label)
	if not ok:
		failures += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var level = load("res://map/asset/imported/main.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var canvas = level.get_node("SmallCanvas")
	canvas.global_position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(96, 96)
	var surface = canvas.surface
	surface.clear()
	var health = surface._health_node()
	var original_ink: float = health.ink_of(Palette.BLACK.id)
	var actions = canvas.get_node("SidePanel/HistoryActions")
	actions.refresh()
	check("empty play history buttons are disabled", actions.undo_button.disabled and actions.redo_button.disabled)
	surface._begin_undo_step()
	surface._place_nail(Vector2(3, 3))
	surface._commit_undo_step()
	actions.refresh()
	check("play edit enables visible undo action", not actions.undo_button.disabled)
	actions.undo_button.pressed.emit()
	check("play undo action edits its own canvas", not surface.nail_layer.nails.has(Vector2i(3, 3)) and not actions.redo_button.disabled)
	actions.redo_button.pressed.emit()
	check("play redo action restores pixels", surface.nail_layer.nails.has(Vector2i(3, 3)))
	actions.undo_button.pressed.emit()
	surface._begin_undo_step()
	surface._stroke(Vector2(20, 20), Vector2(40, 20), Palette.BLACK.color)
	surface._commit_undo_step()
	var drawn_ink: float = health.ink_of(Palette.BLACK.id)
	surface._begin_undo_step()
	surface._place_nail(Vector2(30, 20))
	surface._commit_undo_step()
	surface._flush_ink()
	var original: PackedByteArray = surface.black_image.get_data()
	drawn_ink = health.ink_of(Palette.BLACK.id)
	canvas.clear_canvas()
	check("clear refunds ink", surface.black_image.get_used_rect().size == Vector2i.ZERO \
		and is_equal_approx(health.ink_of(Palette.BLACK.id), original_ink))
	check("clear undo exact pixels and ink", surface.undo_last_edit() \
		and surface.black_image.get_data() == original and is_equal_approx(health.ink_of(Palette.BLACK.id), drawn_ink))
	check("clear undo restores nail", surface.nail_layer.nails.has(Vector2i(30, 20)))
	var before: int = level.world.bodies.size()
	canvas.generate()
	canvas.return_to_canvas()
	check("inkify removes entity", level.world.bodies.size() == before)
	check("inkify undo restores entity and empty blueprint", surface.undo_last_edit() \
		and level.world.bodies.size() == before + 1 and surface.black_image.get_used_rect().size == Vector2i.ZERO)
	check("generate undo after inkify undo", surface.undo_last_edit() \
		and level.world.bodies.size() == before and surface.black_image.get_data() == original)
	var old_position: Vector2 = canvas.position
	canvas.expand_canvas_sides(16, 20, 24, 12)
	check("expand changes size and position", canvas.canvas_size == Vector2i(132, 132) \
		and canvas.position == old_position - Vector2(16, 24))
	check("expand undo restores size position and pixels", surface.undo_last_edit() \
		and canvas.canvas_size == Vector2i(96, 96) and canvas.position == old_position \
		and surface.black_image.get_data() == original)
	canvas.generate()
	canvas._delete_selection(Rect2i(15, 15, 40, 20))
	check("selection undo restores solid entity", surface.undo_last_edit() \
		and level.world.bodies.size() == before + 1 and surface.black_image.get_used_rect().size == Vector2i.ZERO)
	check("selection then generate undo", surface.undo_last_edit() \
		and level.world.bodies.size() == before and surface.black_image.get_data() == original)
	canvas.generate()
	canvas._delete_selection(Rect2i(20, 17, 5, 7))
	check("partial selection undo removes fragments", surface.undo_last_edit() \
		and level.world.bodies.size() == before + 1)
	check("partial selection then generate undo", surface.undo_last_edit() \
		and level.world.bodies.size() == before and surface.black_image.get_data() == original)
	var yellow = surface.yellow_rule()
	yellow.begin(surface, Vector2(20, 20))
	var made_yellow: bool = yellow.finish(surface, Vector2(40, 20))
	check("yellow draft created", made_yellow)
	canvas.clear_canvas()
	check("clear undo restores yellow draft", surface.undo_last_edit() and yellow.strokes.size() == 1 \
		and yellow.strokes[0].state == 0)
	check("restored yellow draft original drawing undo", surface.undo_last_edit() and yellow.strokes.is_empty())
	# 编辑器混合历史：画布操作和布局操作必须按同一时间线撤销。
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.set_active(true)
	var map_canvas = creative._map_canvas
	map_canvas.surface.write_pixel(Vector2i(10, 10), Palette.BLACK.color)
	map_canvas.surface.refresh()
	map_canvas.clear_canvas()
	var portal = creative.place_portal(Vector2(500, -10000))
	check("mixed history portal first", creative.undo_last_edit() and not portal.is_inside_tree())
	check("mixed history clear second", creative.undo_last_edit() \
		and map_canvas.surface.material_at(10, 10) == Palette.BLACK.id)
	var label = creative.place_map_text(Vector2(5000, -10000), "撤销测试")
	var text_id: String = label.editor_id
	creative._resize_control_target(label, 1.0)
	var grown_scale: Vector2 = label.scale
	creative.remove_map_text_at(label.global_position)
	await process_frame
	check("text deletion undo", creative.undo_last_edit())
	var restored_label = creative._find_map_text_at(Vector2(5000, -10000))
	check("text deletion preserves size", restored_label.editor_id == text_id and restored_label.scale == grown_scale)
	check("text resize undo after deletion undo", creative.undo_last_edit() and restored_label.scale == Vector2.ONE)
	check("text placement undo after restoration", creative.undo_last_edit() \
		and creative._find_map_text_at(Vector2(5000, -10000)) == null)
	print("[ButtonUndo] ", checks, " checks; ", failures, " failures")
	level.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
