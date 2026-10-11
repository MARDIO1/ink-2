extends "res://test/test_collision_damage.gd"

const NailVisual := preload("res://actor/nail/src/nail.gd")
const MapMonsterScript := preload("res://actor/monster/src/map_monster.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var valid := true
	var scene: Node = load("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	var game_ui: Node = preload("res://ui/game_ui.tscn").instantiate()
	root.add_child(game_ui)
	await process_frame
	await process_frame

	var creative: Node = scene.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	var player: Node2D = scene.get_node("Player")
	var small_canvas: Node2D = scene.get_node("SmallCanvas")
	var map_canvas: Node2D = scene.get_node("MapCanvas")
	var surface: Area2D = map_canvas.get_node("CanvasSurface")
	var play_tool_grid := small_canvas.get_node("WorkbenchUI/Buttons/Grid") as GridContainer
	var play_tool_buttons := small_canvas.get_node("WorkbenchUI/Buttons") as Control
	var play_toolbar_valid: bool = play_tool_grid.columns == 2 \
		and play_tool_buttons.position == Vector2(-42.0, 160.0) \
		and play_tool_grid.get_node("Brush").position.y == 0.0 \
		and not play_tool_grid.get_node("Nail").visible \
		and (small_canvas.get_node("WorkbenchUI/Buttons/Hand") as Button).size \
			.is_equal_approx(Vector2(52.0, 52.0))
	valid = valid and play_toolbar_valid
	print("[CreativeEditor] PPT play toolbar proportions/top preserved: ",
		"PASS" if play_toolbar_valid else "FAIL")
	var health_ui: Array[Node] = get_nodes_in_group("health_ui")
	var exit_button: TextureButton = game_ui.get_node("Hud/Root/ExitButton")
	valid = valid and health_ui.size() == 3
	for item in health_ui:
		valid = valid and item.visible
	creative.set_active(true)
	await process_frame
	var save_directory_dialog := creative.get_node_or_null("SaveMapDirectoryDialog") as FileDialog
	valid = valid and save_directory_dialog != null
	if save_directory_dialog != null:
		valid = valid and save_directory_dialog.file_mode == FileDialog.FILE_MODE_OPEN_DIR
		valid = valid and save_directory_dialog.access == FileDialog.ACCESS_RESOURCES
	var save_window := creative.get_node_or_null("MapSaveWindow") as PopupPanel
	valid = valid and save_window != null
	valid = valid and save_window.get_node_or_null("Content/MapThumbnail") is TextureRect
	valid = valid and save_window.get_node_or_null("Content/MapNameInput") is LineEdit
	valid = valid and save_window.get_node_or_null("Content/MapDirectoryInput") is LineEdit
	for item in health_ui:
		valid = valid and not item.visible
	valid = valid and exit_button.visible
	valid = valid and not player.visible
	valid = valid and not small_canvas.visible and not small_canvas.active
	valid = valid and map_canvas.visible and map_canvas.active
	valid = valid and map_canvas.get("_screen_fixed")
	valid = valid and (map_canvas.get_node("WorkbenchUI/Buttons/Grid") as GridContainer).columns == 2
	valid = valid and map_canvas.get_node("WorkbenchUI/Buttons/Hand").visible
	valid = valid and map_canvas.get_node("WorkbenchUI/Buttons/Grid/Brush").visible
	valid = valid and map_canvas.get_node("WorkbenchUI/Buttons/Grid/ExpandCanvas").visible
	var expand_window := map_canvas.get_node_or_null("ExpandCanvasWindow") as Window
	valid = valid and expand_window != null
	valid = valid and not expand_window.visible
	valid = valid and expand_window.get_node_or_null("Content/Column/Inputs/LeftAmount") is SpinBox
	valid = valid and expand_window.get_node_or_null("Content/Column/Inputs/RightAmount") is SpinBox
	valid = valid and expand_window.get_node_or_null("Content/Column/Inputs/TopAmount") is SpinBox
	valid = valid and expand_window.get_node_or_null("Content/Column/Inputs/BottomAmount") is SpinBox
	var expand_button := map_canvas.get_node("WorkbenchUI/Buttons/Grid/ExpandCanvas") as Button
	var expand_window_started_hidden := not expand_window.visible
	expand_button.pressed.emit()
	await process_frame
	var expand_window_opened := expand_window.visible
	expand_window.hide()
	valid = valid and expand_window_opened
	print("[CreativeEditor] expand toolbar/window: ", "PASS" if (
		expand_button.visible
		and expand_window != null
		and expand_window_started_hidden
		and expand_window_opened
		and expand_window.get_node_or_null("Content/Column/Inputs/LeftAmount") is SpinBox
		and expand_window.get_node_or_null("Content/Column/Inputs/RightAmount") is SpinBox
		and expand_window.get_node_or_null("Content/Column/Inputs/TopAmount") is SpinBox
		and expand_window.get_node_or_null("Content/Column/Inputs/BottomAmount") is SpinBox
	) else "FAIL")
	valid = valid and not map_canvas.get_node("WorkbenchUI/ResizePanel").visible
	valid = valid and not map_canvas.has_node("WorkbenchUI/ResizePanel/Grid/Left")
	valid = valid and not map_canvas.has_node("WorkbenchUI/ResizePanel/Grid/Right")
	valid = valid and not map_canvas.has_node("WorkbenchUI/ResizePanel/Grid/Up")
	valid = valid and not map_canvas.has_node("WorkbenchUI/ResizePanel/Grid/Down")
	var visibility_button: Button = map_canvas.get_node("WorkbenchUI/ResizePanel/Grid/PlayerVisibility")
	valid = valid and not visibility_button.button_pressed
	visibility_button.button_pressed = true
	valid = valid and player.visible
	visibility_button.button_pressed = false

	# 炸弹狂侧面保留旧地图兼容能力，但不再出现在小怪放置栏。
	var monster_palette: CanvasLayer = creative.get_node("MonsterPalette")
	valid = valid and monster_palette.visible
	var palette_toggle := monster_palette.get_node("Root/PaletteToggle") as Button
	var palette_panel := monster_palette.get_node("Root/Panel") as PanelContainer
	var palette_toggle_valid: bool = palette_toggle.visible and not palette_panel.visible \
		and palette_toggle.offset_top == 80.0 and palette_toggle.offset_bottom == 124.0
	palette_toggle.pressed.emit()
	palette_toggle_valid = palette_toggle_valid and palette_panel.visible and palette_toggle.text == "关闭" \
		and palette_panel.offset_right == -16.0 and palette_toggle.offset_right == -16.0
	palette_toggle.pressed.emit()
	palette_toggle_valid = palette_toggle_valid and not palette_panel.visible and palette_toggle.text == "工具"
	valid = valid and palette_toggle_valid
	print("[CreativeEditor] right palette toggle: ", "PASS" if palette_toggle_valid else "FAIL")
	var palette_content := "Root/Panel/Scroll/Margin/VBox/"
	var monster_grid := monster_palette.get_node(palette_content + "MonsterGrid") as GridContainer
	var dialogue_grid := monster_palette.get_node(palette_content + "DialogueGrid") as GridContainer
	var text_grid := monster_palette.get_node(palette_content + "TextGrid") as GridContainer
	var layout_grid := monster_palette.get_node(palette_content + "LayoutGrid") as GridContainer
	valid = valid and monster_grid.columns == 3 and dialogue_grid.columns == 3 and text_grid.columns == 3
	valid = valid and layout_grid.columns == 3
	valid = valid and not layout_grid.has_node("MoveSpawnButton")
	valid = valid and layout_grid.has_node("PlaceRespawnButton")
	valid = valid and layout_grid.has_node("MoveRespawnButton")
	valid = valid and layout_grid.has_node("PlacePlayCanvasButton")
	valid = valid and layout_grid.has_node("MovePlayCanvasButton")
	valid = valid and not layout_grid.has_node("PlaceSpawnButton")
	valid = valid and not monster_grid.has_node("BombSideButton")
	valid = valid and monster_grid.has_node("AdjustMonsterButton")
	valid = valid and monster_grid.has_node("ResetMonsterScaleButton")
	var has_place_dialogue := dialogue_grid.has_node("PlaceDialogueTriggerButton")
	var has_delete_dialogue := dialogue_grid.has_node("DeleteDialogueTriggerButton")
	var dialogue_valid := has_place_dialogue and has_delete_dialogue
	valid = valid and not monster_grid.has_node("ShieldFrontButton")
	valid = valid and not monster_grid.has_node("BombManiacButton")
	valid = valid and not monster_grid.has_node("InkmanButton")
	valid = valid and text_grid.has_node("PlaceTextButton") and text_grid.has_node("DeleteTextButton")
	valid = valid and palette_panel.anchor_bottom == 1.0 and palette_panel.offset_bottom == -16.0
	var dialogue_window := creative.get_node_or_null("DialogueTriggerInput") as Window
	dialogue_valid = dialogue_valid and dialogue_window != null
	creative._open_dialogue_input(Vector2(760, 260))
	var dialogue_lines_box: VBoxContainer = creative.get("_dialogue_lines_box")
	var first_line := dialogue_lines_box.get_child(0) as LineEdit
	first_line.text = "第一句"
	creative._on_dialogue_line_submitted(first_line.text, first_line)
	dialogue_valid = dialogue_valid and dialogue_lines_box.get_child_count() == 2
	var second_line := dialogue_lines_box.get_child(1) as LineEdit
	second_line.text = "第二句"
	creative._confirm_dialogue_input()
	var dialogue_triggers: Node = scene.get_node_or_null("DialogueTriggers")
	dialogue_valid = dialogue_valid and dialogue_triggers != null and dialogue_triggers.get_child_count() == 1
	var map_dialogue: Node2D = dialogue_triggers.get_child(0) as Node2D
	dialogue_valid = dialogue_valid and map_dialogue.visible
	dialogue_valid = dialogue_valid and map_dialogue.trigger_rect().size == Vector2(100, 100)
	dialogue_valid = dialogue_valid and PackedStringArray(map_dialogue.get("lines")) \
		== PackedStringArray(["第一句", "第二句"])
	var dialogue_id := str(map_dialogue.get("editor_id"))
	dialogue_valid = dialogue_valid and creative.remove_dialogue_trigger_at(Vector2(760, 260))
	dialogue_valid = dialogue_valid and dialogue_triggers.get_child_count() == 0
	dialogue_valid = dialogue_valid and creative.undo_last_edit()
	dialogue_valid = dialogue_valid and dialogue_triggers.get_child_count() == 1
	map_dialogue = dialogue_triggers.get_child(0) as Node2D
	dialogue_valid = dialogue_valid and str(map_dialogue.get("editor_id")) == dialogue_id
	valid = valid and dialogue_valid

	# 地图文本使用沐瑶软笔字体，保存为地图节点；放置和删除都可撤销。
	var text_window := creative.get_node_or_null("MapTextInput") as Window
	var text_valid := text_window != null and not text_window.visible
	var placed_text := creative.place_map_text(Vector2(900, 300), "手写地图文字") as Label
	text_valid = text_valid and placed_text != null
	var placed_text_id := ""
	if placed_text != null:
		text_valid = text_valid and placed_text.text == "手写地图文字"
		text_valid = text_valid \
			and placed_text.get_theme_font("font").resource_path.ends_with("Muyao-Softbrush.ttf")
		text_valid = text_valid and placed_text.z_index == 20
		placed_text_id = str(placed_text.get("editor_id"))
	var removed_text: bool = creative.remove_map_text_at(Vector2(901, 301))
	text_valid = text_valid and removed_text
	var restored_deleted_text: bool = creative.undo_last_edit()
	text_valid = text_valid and restored_deleted_text
	var restored_text := scene.get_node_or_null("MapTexts/MapText") as Label
	text_valid = text_valid and restored_text != null
	if restored_text != null:
		text_valid = text_valid and str(restored_text.get("editor_id")) == placed_text_id
	# 运行时创建的文本必须能随整张地图打包，而不只是在当前编辑会话中可见。
	var text_pack_probe := PackedScene.new()
	text_valid = text_valid and text_pack_probe.pack(scene) == OK
	var text_pack_copy := text_pack_probe.instantiate()
	text_valid = text_valid and text_pack_copy.get_node_or_null("MapTexts/MapText") is Label
	text_pack_copy.free()
	var removed_placed_text: bool = creative.undo_last_edit()
	text_valid = text_valid and removed_placed_text
	text_valid = text_valid and scene.get_node_or_null("MapTexts/MapText") == null
	valid = valid and text_valid
	print("[CreativeEditor] three-column palette and map text: ", "PASS" if text_valid else "FAIL")

	# 画一笔后放怪：两次撤销必须严格按时间顺序先撤怪、再撤画。
	var undo_pixel := Vector2i(40, 40)
	var before_undo_color: Color = surface.black_image.get_pixelv(undo_pixel)
	surface._begin_undo_step()
	surface._write_pixel(undo_pixel, Color.BLACK, 1 << 30)
	surface.refresh()
	surface._commit_undo_step()
	var undo_monster: Node2D = creative.place_monster(
		MapMonsterScript.Kind.BOMB_SIDE, Vector2(200, 200)
	)
	valid = valid and undo_monster != null and creative.monster_count() == 1
	var undo_key := InputEventKey.new()
	undo_key.keycode = KEY_Z
	undo_key.ctrl_pressed = true
	undo_key.pressed = true
	creative._unhandled_input(undo_key)
	valid = valid and creative.monster_count() == 0
	valid = valid and surface.black_image.get_pixelv(undo_pixel).a > 0.5
	valid = valid and creative.undo_last_edit()
	valid = valid and surface.black_image.get_pixelv(undo_pixel) == before_undo_color

	# 框选删除是一个原子撤销步骤：未固化画布像素与已固化实体像素一起删除，
	# Ctrl+Z 后两者都回到画布，下一次保存会照常重新固化。
	valid = valid and map_canvas.get_node("WorkbenchUI/Buttons/Grid/SelectDelete").icon != null
	var loose_pixel := Vector2i(1400, 700)
	var baked_pixel := Vector2i(1410, 700)
	surface.write_pixel(baked_pixel, Color.BLACK)
	surface.refresh()
	var bodies_before_selection_bake: int = scene.world.bodies.size()
	map_canvas.generate()
	valid = valid and scene.world.bodies.size() > bodies_before_selection_bake
	surface.write_pixel(loose_pixel, Color.BLACK)
	surface.refresh()
	map_canvas._delete_selection(Rect2i(Vector2i(1399, 699), Vector2i(14, 3)))
	valid = valid and not surface.is_solid(loose_pixel.x, loose_pixel.y)
	valid = valid and not surface.is_solid(baked_pixel.x, baked_pixel.y)
	valid = valid and creative.undo_last_edit()
	valid = valid and surface.is_solid(loose_pixel.x, loose_pixel.y)
	valid = valid and surface.is_solid(baked_pixel.x, baked_pixel.y)
	surface.clear(false)

	# 固化墨水只有在整体离开地图画布后才自动清除；普通动态场景节点不受影响。
	var falling_pixel := Vector2i(1450, 700)
	surface.write_pixel(falling_pixel, Color.BLACK)
	surface.refresh()
	map_canvas.generate()
	var falling_body = scene.world.bodies[-1]
	var falling_node = scene._body_nodes[-1]
	valid = valid and is_instance_valid(falling_node) and falling_node.is_in_group("ink_item")
	var body_count_before_cull: int = scene.world.bodies.size()
	valid = valid and map_canvas.clear_solidified_bodies_outside_canvas() == 0
	falling_body.position += Vector2(0, map_canvas.canvas_size.y * 2)
	falling_body.update_aabb()
	valid = valid and map_canvas.clear_solidified_bodies_outside_canvas() == 1
	valid = valid and scene.world.bodies.size() == body_count_before_cull - 1
	valid = valid and not scene.world.bodies.has(falling_body)

	var monster_positions := [Vector2(520, 220)]
	var monster_kinds := [
		MapMonsterScript.Kind.BOMB_SIDE,
	]
	for index in monster_kinds.size():
		var monster: Node2D = creative.place_monster(monster_kinds[index], monster_positions[index])
		valid = valid and monster != null and monster.z_index >= 1000
		valid = valid and not str(monster.get("editor_id")).is_empty()
		var visual: Node2D = monster.get_node("Visual")
		var demo_ui := visual.get_node_or_null("UI")
		if demo_ui != null:
			valid = valid and not demo_ui.visible
		var breath := visual.get_node_or_null("PeriodicBreath")
		if breath != null:
			valid = valid and breath.process_mode == Node.PROCESS_MODE_DISABLED
	valid = valid and creative.monster_count() == 1
	var side_monster: Node2D = scene.get_node("Monsters/BombSide")
	valid = valid and side_monster.z_index > map_canvas.z_index

	# 删除也进入同一撤销栈；恢复后保留类型、坐标和稳定 id。
	var side_id := str(side_monster.get("editor_id"))
	valid = valid and creative.remove_monster_at(monster_positions[0])
	valid = valid and creative.monster_count() == 0
	valid = valid and creative.undo_last_edit() and creative.monster_count() == 1
	var restored_side: Node2D = scene.get_node("Monsters/BombSide")
	valid = valid and str(restored_side.get("editor_id")) == side_id
	valid = valid and restored_side.global_position == monster_positions[0]
	valid = valid and not player.visible

	# 调整模式：拖动修改位置，滚轮修改大小；每一步都可由 Ctrl+Z 恢复。
	creative.select_monster_tool(-3)
	var select_event := InputEventMouseButton.new()
	select_event.button_index = MOUSE_BUTTON_LEFT
	select_event.pressed = true
	select_event.position = map_canvas.get_viewport().get_canvas_transform() * monster_positions[0]
	select_event.global_position = select_event.position
	creative._input(select_event)
	var moved_position: Vector2 = monster_positions[0] + Vector2(80, 40)
	var drag_event := InputEventMouseMotion.new()
	drag_event.position = map_canvas.get_viewport().get_canvas_transform() * moved_position
	drag_event.global_position = drag_event.position
	creative._input(drag_event)
	select_event.pressed = false
	select_event.position = drag_event.position
	select_event.global_position = drag_event.global_position
	creative._input(select_event)
	valid = valid and restored_side.global_position.distance_to(moved_position) < 0.01
	var scale_event := InputEventMouseButton.new()
	scale_event.button_index = MOUSE_BUTTON_WHEEL_UP
	scale_event.pressed = true
	scale_event.position = drag_event.position
	scale_event.global_position = drag_event.global_position
	creative._input(scale_event)
	valid = valid and restored_side.scale.x > 1.0
	valid = valid and creative.undo_last_edit() and restored_side.scale.is_equal_approx(Vector2.ONE)
	valid = valid and creative.undo_last_edit()
	valid = valid and restored_side.global_position.distance_to(monster_positions[0]) < 0.01

	# “钉”开关只隐藏外观：画布数据、实体锚点与之后新生成的钉子都不受影响。
	var nail_visibility_button: Button = map_canvas.get_node("WorkbenchUI/ResizePanel/Grid/NailVisibility")
	var runtime_nail := NailVisual.new()
	runtime_nail.set_physics_process(false)
	scene.add_child(runtime_nail)
	runtime_nail.setup(null, Vector2i.ZERO, true)
	surface.nail_layer.add(Vector2i(1, 1))
	valid = valid and nail_visibility_button.button_pressed
	nail_visibility_button.button_pressed = false
	valid = valid and not surface.nail_layer.visible and not runtime_nail.visible
	valid = valid and surface.nail_layer.nails.has(Vector2i(1, 1))
	var later_nail := NailVisual.new()
	later_nail.set_physics_process(false)
	scene.add_child(later_nail)
	later_nail.setup(null, Vector2i.ZERO, true)
	valid = valid and not later_nail.visible
	nail_visibility_button.button_pressed = true
	valid = valid and surface.nail_layer.visible and runtime_nail.visible and later_nail.visible
	runtime_nail.queue_free()
	later_nail.queue_free()

	# 固定工具栏的最终屏幕变换应等于配置的屏幕原点，镜头移动/缩放不会改变它。
	map_canvas._update_screen_fixed_position()
	var toolbar_screen: Transform2D = map_canvas.get_viewport().get_canvas_transform() \
		* map_canvas.get_node("WorkbenchUI").global_transform
	valid = valid and toolbar_screen.origin.distance_to(map_canvas.screen_toolbar_origin) < 0.01

	# GUI 点击不能穿透到后面的全局输入画布：左键不落墨，中键不落钉。
	var button_center: Vector2 = visibility_button.get_global_transform_with_canvas() \
		* visibility_button.get_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = button_center
	motion.global_position = button_center
	Input.parse_input_event(motion)
	await process_frame
	var pixels_before_gui_click: PackedByteArray = surface.black_image.get_data()
	var nails_before_gui_click: int = surface.nail_layer.nails.size()
	for mouse_button in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_MIDDLE]:
		var click := InputEventMouseButton.new()
		click.button_index = mouse_button
		click.position = button_center
		click.global_position = button_center
		click.pressed = true
		Input.parse_input_event(click)
		await process_frame
		click = click.duplicate()
		click.pressed = false
		Input.parse_input_event(click)
		await process_frame
	valid = valid and surface.black_image.get_data() == pixels_before_gui_click
	valid = valid and surface.nail_layer.nails.size() == nails_before_gui_click
	visibility_button.button_pressed = false

	# 向左扩展：像素与钉子右移，画布节点左移，旧内容的世界坐标保持不变。
	map_canvas.canvas_expand_step = 16
	var old_size: Vector2i = map_canvas.canvas_size
	var old_position: Vector2 = map_canvas.position
	var old_ink: int = _total_ink_px(surface)
	surface.write_pixel(Vector2i(5, 6), Color.BLACK)
	surface.nail_layer.add(Vector2i(7, 8))
	surface.refresh()
	var expanded_left: bool = map_canvas.expand_canvas(Vector2i.LEFT)
	valid = valid and expanded_left
	valid = valid and map_canvas.canvas_size == old_size + Vector2i(16, 0)
	valid = valid and map_canvas.position == old_position - Vector2(16, 0)
	valid = valid and surface.black_image.get_pixel(21, 6).a > 0.5
	valid = valid and surface.nail_layer.nails.has(Vector2i(23, 8))
	valid = valid and _total_ink_px(surface) == old_ink

	# 四边在一次操作中扩展；左、上新增区域补偿节点位置，旧内容世界坐标保持不变。
	old_size = map_canvas.canvas_size
	old_position = map_canvas.position
	var expanded_four_sides: bool = map_canvas.expand_canvas_sides(3, 5, 7, 11)
	valid = valid and expanded_four_sides
	valid = valid and map_canvas.canvas_size == old_size + Vector2i(8, 18)
	valid = valid and map_canvas.position == old_position - Vector2(3, 7)
	valid = valid and surface.black_image.get_pixel(24, 13).a > 0.5
	valid = valid and surface.nail_layer.nails.has(Vector2i(26, 15))
	valid = valid and _total_ink_px(surface) == old_ink
	print("[CreativeEditor] four-side canvas expansion: ", "PASS" if (
		map_canvas.canvas_size == old_size + Vector2i(8, 18)
		and map_canvas.position == old_position - Vector2(3, 7)
		and surface.black_image.get_pixel(24, 13).a > 0.5
		and surface.nail_layer.nails.has(Vector2i(26, 15))
		and _total_ink_px(surface) == old_ink
	) else "FAIL")

	# 即使当前处于编辑模式，保存出来的场景也必须以正常游玩布局启动。
	# 放在项目 test 临时路径，避免无用户目录的 headless/沙箱环境无法写 user://。
	var save_path := "res://test/.creative_editor_scene.tmp.tscn"
	var save_absolute := ProjectSettings.globalize_path(save_path)
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_absolute)
	var export_error: Error = creative.export_map_to(save_path, false)
	valid = valid and export_error == OK
	var scene_exists := ResourceLoader.exists(save_path)
	valid = valid and scene_exists
	var packed: PackedScene = ResourceLoader.load(
		save_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE
	) if scene_exists else null
	if packed == null:
		valid = false
	else:
		var saved: Node = packed.instantiate()
		valid = valid and saved.get_node("Player").visible
		valid = valid and saved.get_node("SmallCanvas").visible and saved.get_node("SmallCanvas").active
		valid = valid and not saved.get_node("MapCanvas").visible and not saved.get_node("MapCanvas").active
		valid = valid and saved.get_node("MapCanvas").canvas_size == map_canvas.canvas_size
		var saved_monsters: Node = saved.get_node("Monsters")
		valid = valid and saved_monsters.get_child_count() == 1
		var saved_kinds := []
		for monster in saved_monsters.get_children():
			saved_kinds.append(int(monster.get("kind")))
		valid = valid and saved_kinds.has(MapMonsterScript.Kind.BOMB_SIDE)
		var saved_dialogues: Node = saved.get_node("DialogueTriggers")
		dialogue_valid = dialogue_valid and saved_dialogues.get_child_count() == 1
		dialogue_valid = dialogue_valid and PackedStringArray(saved_dialogues.get_child(0).get("lines")) \
			== PackedStringArray(["第一句", "第二句"])
		saved.free()
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_absolute)

	# 保存不能把正在编辑的运行时状态切回普通模式。
	valid = valid and creative.active and not player.visible
	valid = valid and map_canvas.visible and map_canvas.active and map_canvas.get("_screen_fixed")
	for item in health_ui:
		valid = valid and not item.visible
	creative.set_active(false)
	valid = valid and not monster_palette.visible
	dialogue_valid = dialogue_valid and not map_dialogue.visible
	var dialogue_box: DialogueBox = game_ui.get_node("Dialogue") as DialogueBox
	dialogue_box.root.hide()
	player.body.position += map_dialogue.global_position - player.body.aabb.get_center()
	player.body.update_aabb()
	map_dialogue._player_was_inside = false
	map_dialogue._physics_process(0.0)
	dialogue_valid = dialogue_valid and dialogue_box.root.visible
	dialogue_valid = dialogue_valid and dialogue_box.lines == PackedStringArray(["第一句", "第二句"])
	dialogue_box.root.hide()
	map_dialogue._player_was_inside = false
	map_dialogue._physics_process(0.0)
	dialogue_valid = dialogue_valid and not dialogue_box.root.visible
	dialogue_valid = dialogue_valid and not map_dialogue._start_dialogue()
	valid = valid and dialogue_valid
	print("[CreativeEditor] dialogue trigger placement/save/playback: ",
		"PASS" if dialogue_valid else "FAIL")
	valid = valid and player.visible and small_canvas.visible and not map_canvas.visible
	for item in health_ui:
		valid = valid and item.visible

	print("[CreativeEditor] UI, undo, monsters, fixed toolbar, expand, scene save: ",
		"PASS" if valid else "FAIL")
	var hand = scene.get_node("Player/Arm/Hand/HandControl")
	hand.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	hand._release_grab()
	hand._remove_arm()
	_release(scene.world)
	scene.queue_free()
	game_ui.queue_free()
	await process_frame
	quit(0 if valid else 1)


func _total_ink_px(surface: Node) -> int:
	var total := 0
	for count in surface.ink_px_by_material.values():
		total += int(count)
	return total
