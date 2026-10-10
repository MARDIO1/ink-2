extends "res://test/test_collision_damage.gd"

const CanvasSurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")


func _initialize() -> void:
	call_deferred("_run_ui_test")


func _run_ui_test() -> void:
	var valid := true
	var scene: Node = load("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame

	var player: Node2D = scene.get_node("Player")
	var play_canvas: Node = scene.get_node("SmallCanvas")
	var play_size: Vector2i = play_canvas.canvas_size
	var play_grid := play_canvas.get_node("WorkbenchUI/Buttons/Grid") as GridContainer
	var play_hand := play_canvas.get_node("WorkbenchUI/Buttons/Hand") as Button
	valid = valid and play_grid.columns == 2
	valid = valid and play_grid.get_node("Brush").visible
	valid = valid and play_grid.get_node("Eraser").visible
	valid = valid and not play_grid.get_node("Nail").visible
	valid = valid and play_hand.size.is_equal_approx(Vector2(52.0, 52.0))
	valid = valid and (play_grid.get_node("Brush") as Button).size.is_equal_approx(Vector2(32.0, 43.0))
	valid = valid and (play_grid.get_node("Brush/Caption") as Label).text == "画笔"
	valid = valid and play_canvas.get_node("WorkbenchUI/Buttons").position == Vector2(-42.0, 160.0)
	var side_panel := play_canvas.get_node("SidePanel") as VBoxContainer
	var side_slider := side_panel.get_node("Controls/BrushSizeSlider") as VSlider
	var first_ink_button := side_panel.get_node("Controls/Colors/Ink0Button") as Button
	valid = valid and side_panel.position == Vector2(play_size.x + 14.0, -22.0)
	valid = valid and side_slider.size.y >= 166.0
	valid = valid and first_ink_button.size.is_equal_approx(Vector2(34.0, 34.0))
	valid = valid and side_panel.get_node("Controls/Colors").get_child_count() == 4
	(play_grid.get_node("Brush") as Button).pressed.emit()
	valid = valid and play_canvas.surface.tool == CanvasSurfaceScript.Tool.BRUSH
	(play_grid.get_node("Eraser") as Button).pressed.emit()
	valid = valid and play_canvas.surface.tool == CanvasSurfaceScript.Tool.ERASER
	(play_grid.get_node("Bucket") as Button).pressed.emit()
	valid = valid and play_canvas.surface.tool == CanvasSurfaceScript.Tool.BUCKET
	(play_grid.get_node("SelectDelete") as Button).pressed.emit()
	valid = valid and play_canvas.surface.tool == CanvasSurfaceScript.Tool.SELECT_DELETE
	(side_panel.get_node("Controls/Colors/Ink2Button") as Button).pressed.emit()
	valid = valid and play_canvas.surface.selected_ink == 2
	side_slider.value = 13.0
	valid = valid and play_canvas.surface.brush_size == 13
	valid = valid and (play_grid.get_node("Redraw") as Button).pressed.get_connections().size() == 1
	valid = valid and (play_grid.get_node("Shape") as Button).pressed.get_connections().size() == 1
	valid = valid and (play_grid.get_node("Generate") as Button).pressed.get_connections().size() == 1
	valid = valid and (play_grid.get_node("ReturnToCanvas") as Button).pressed.get_connections().size() == 1
	(play_grid.get_node("Brush") as Button).pressed.emit()
	play_hand.pressed.emit()
	valid = valid and play_canvas.surface.tool == 0
	print("[UIPptEditorControls] play layout ", play_grid.columns, " hand=", play_hand.size,
		" tool=", play_canvas.surface.tool)

	var creative: Node = scene.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	creative.set_active(true)
	await process_frame

	var map_canvas: Node = scene.get_node("MapCanvas")
	var editor_grid := map_canvas.get_node("WorkbenchUI/Buttons/Grid") as GridContainer
	var editor_hand := map_canvas.get_node("WorkbenchUI/Buttons/Hand") as Button
	valid = valid and play_canvas.canvas_size == play_size
	valid = valid and editor_grid.columns == 2
	valid = valid and editor_grid.get_node("Brush").visible
	valid = valid and editor_grid.get_node("Nail").visible
	valid = valid and editor_grid.get_node("ExpandCanvas").visible
	valid = valid and editor_hand.visible
	valid = valid and editor_hand.size.is_equal_approx(Vector2(72.0, 72.0))
	var hand_icon := editor_hand.icon as AtlasTexture
	valid = valid and hand_icon != null \
		and hand_icon.atlas.resource_path.ends_with("editor_control.png")
	valid = valid and (editor_grid.get_node("Brush") as Button).size \
		.is_equal_approx(Vector2(44.0, 60.0))
	valid = valid and map_canvas.get_node("WorkbenchUI/Buttons").position == Vector2(-186.0, 116.0)
	valid = valid and (editor_grid.get_node("Nail") as Button).pressed.get_connections().size() == 1
	valid = valid and (editor_grid.get_node("ExpandCanvas") as Button).pressed.get_connections().size() == 1
	var expand_icon := editor_grid.get_node("ExpandCanvas/ToolIcon").texture as AtlasTexture
	valid = valid and expand_icon != null \
		and expand_icon.atlas.resource_path.ends_with("expand_canvas.png")
	(editor_grid.get_node("Nail") as Button).pressed.emit()
	valid = valid and map_canvas.surface.tool == CanvasSurfaceScript.Tool.NAIL
	var expand_window := map_canvas.get_node("ExpandCanvasWindow") as Window
	(editor_grid.get_node("ExpandCanvas") as Button).pressed.emit()
	await process_frame
	valid = valid and expand_window.visible
	expand_window.hide()
	valid = valid and not map_canvas.get_node("WorkbenchUI/ResizePanel").visible
	print("[UIPptEditorControls] editor visibility brush=", editor_grid.get_node("Brush").visible,
		" nail=", editor_grid.get_node("Nail").visible, " hand=", editor_hand.size)

	var palette := creative.get_node("MonsterPalette")
	var panel := palette.get_node("Root/Panel") as PanelContainer
	valid = valid and palette.get_node_or_null("Root/CategoryRail") == null and not panel.visible
	var tools_toggle := palette.get_node("Root/PaletteToggle") as Button
	valid = valid and tools_toggle.text == "工具"
	tools_toggle.pressed.emit()
	await process_frame
	valid = valid and panel.visible and tools_toggle.text == "关闭"
	valid = valid and panel.offset_right == -16.0 and panel.offset_left == -592.0
	valid = valid and tools_toggle.offset_right == -16.0
	valid = valid and palette.get_node_or_null(
		"Root/Panel/Scroll/Margin/VBox/ColorGrid"
	) is GridContainer
	valid = valid and palette.get_node_or_null(
		"Root/Panel/Scroll/Margin/VBox/LayoutGrid/MoveSpawnButton"
	) == null
	print("[UIPptEditorControls] tools-only panel=", panel.visible)

	creative.select_monster_tool(-6)
	editor_hand.pressed.emit()
	valid = valid and int(creative.get("_monster_mode")) == -13
	creative.select_monster_tool(-6)
	var f_event := InputEventKey.new()
	f_event.keycode = KEY_F
	f_event.pressed = true
	var f_handled: bool = creative._handle_editor_input(f_event)
	valid = valid and f_handled
	valid = valid and int(creative.get("_monster_mode")) == -13
	print("[UIPptEditorControls] F mode=", creative.get("_monster_mode"))

	var spawn := scene.get_node("PlayerSpawn") as Marker2D
	var respawn = creative.place_respawn_point(Vector2(1200, 300), false)
	var extra_canvas = creative.place_play_canvas(Vector2(1800, 500), false)
	var map_text = creative.place_map_text(Vector2(900, 700), "缩放文本", false, "ui-test-text")
	var dialogue = creative.place_dialogue_trigger(
		Vector2(1100, 700), PackedStringArray(["测试对话"]), false, "ui-test-dialogue"
	)
	var monster = creative.place_monster(2, Vector2(1300, 700), false, "ui-test-monster")
	var targets := [spawn, respawn, extra_canvas, map_text, dialogue, monster]
	for target in targets:
		if not is_instance_valid(target):
			printerr("[UIPptEditorControls] failed to create control target")
			valid = false
			continue
		var picked = creative._pick_control_target(target.global_position)
		print("[UIPptEditorControls] pick ", target.name, " -> ", picked.name if picked else "null")
		valid = valid and picked == target
		var old_position: Vector2 = target.global_position
		creative.set("_selected_control_target", target)
		creative._begin_layout_drag(target, old_position)
		target.global_position += Vector2(23, 17)
		creative._finish_layout_drag()
		valid = valid and target.global_position.is_equal_approx(old_position + Vector2(23, 17))

	var old_text_scale: Vector2 = map_text.scale
	var old_monster_scale: Vector2 = monster.scale
	valid = valid and creative._resize_control_target(map_text, 1.0)
	valid = valid and creative._resize_control_target(monster, 1.0)
	valid = valid and map_text.scale.x > old_text_scale.x
	valid = valid and monster.scale.x > old_monster_scale.x
	valid = valid and creative.undo_last_edit()
	valid = valid and monster.scale.is_equal_approx(old_monster_scale)
	valid = valid and creative.undo_last_edit()
	valid = valid and map_text.scale.is_equal_approx(old_text_scale)

	creative.set_active(false)
	valid = valid and play_canvas.canvas_size == play_size
	valid = valid and player.visible
	print("[UIPptEditorControls] ", "PASS" if valid else "FAIL")
	scene.queue_free()
	await process_frame
	quit(0 if valid else 1)
