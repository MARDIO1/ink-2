extends "res://test/test_collision_damage.gd"

const NailVisual := preload("res://actor/nail/src/nail.gd")


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
	var player: Node2D = scene.get_node("Player")
	var small_canvas: Node2D = scene.get_node("SmallCanvas")
	var map_canvas: Node2D = scene.get_node("MapCanvas")
	var surface: Area2D = map_canvas.get_node("CanvasSurface")
	var health_ui: Array[Node] = get_nodes_in_group("health_ui")
	var exit_button: TextureButton = game_ui.get_node("Hud/Root/ExitButton")
	valid = valid and health_ui.size() == 3
	for item in health_ui:
		valid = valid and item.visible
	creative.set_active(true)
	await process_frame
	for item in health_ui:
		valid = valid and not item.visible
	valid = valid and exit_button.visible
	valid = valid and not player.visible
	valid = valid and not small_canvas.visible and not small_canvas.active
	valid = valid and map_canvas.visible and map_canvas.active
	valid = valid and map_canvas.get("_screen_fixed")
	valid = valid and not map_canvas.get_node("WorkbenchUI/Buttons/Grid/Hand").visible
	valid = valid and map_canvas.get_node("WorkbenchUI/ResizePanel").visible
	valid = valid and not map_canvas.has_node("WorkbenchUI/ResizePanel/Grid/Left")
	valid = valid and not map_canvas.has_node("WorkbenchUI/ResizePanel/Grid/Right")
	valid = valid and not map_canvas.has_node("WorkbenchUI/ResizePanel/Grid/Up")
	valid = valid and not map_canvas.has_node("WorkbenchUI/ResizePanel/Grid/Down")
	var visibility_button: Button = map_canvas.get_node("WorkbenchUI/ResizePanel/Grid/PlayerVisibility")
	valid = valid and not visibility_button.button_pressed
	visibility_button.button_pressed = true
	valid = valid and player.visible
	visibility_button.button_pressed = false
	valid = valid and not player.visible

	# “钉”开关只隐藏外观：画布数据、实体锚点与之后新生成的钉子都不受影响。
	var nail_visibility_button: Button = map_canvas.get_node("WorkbenchUI/ResizePanel/Grid/NailVisibility")
	var runtime_nail := NailVisual.new()
	runtime_nail.set_physics_process(false)
	scene.add_child(runtime_nail)
	surface.nail_layer.add(Vector2i(1, 1))
	valid = valid and nail_visibility_button.button_pressed
	nail_visibility_button.button_pressed = false
	valid = valid and not surface.nail_layer.visible and not runtime_nail.visible
	valid = valid and surface.nail_layer.nails.has(Vector2i(1, 1))
	var later_nail := NailVisual.new()
	later_nail.set_physics_process(false)
	scene.add_child(later_nail)
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
	var old_ink: int = surface.ink_px
	surface.write_pixel(Vector2i(5, 6), Color.BLACK)
	surface.nail_layer.add(Vector2i(7, 8))
	surface.refresh()
	valid = valid and map_canvas.expand_canvas(Vector2i.LEFT)
	valid = valid and map_canvas.canvas_size == old_size + Vector2i(16, 0)
	valid = valid and map_canvas.position == old_position - Vector2(16, 0)
	valid = valid and surface.black_image.get_pixel(21, 6).a > 0.5
	valid = valid and surface.nail_layer.nails.has(Vector2i(23, 8))
	valid = valid and surface.ink_px == old_ink

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
		saved.free()
	if FileAccess.file_exists(save_path):
		DirAccess.remove_absolute(save_absolute)

	# 保存不能把正在编辑的运行时状态切回普通模式。
	valid = valid and creative.active and not player.visible
	valid = valid and map_canvas.visible and map_canvas.active and map_canvas.get("_screen_fixed")
	for item in health_ui:
		valid = valid and not item.visible
	creative.set_active(false)
	valid = valid and player.visible and small_canvas.visible and not map_canvas.visible
	for item in health_ui:
		valid = valid and item.visible

	print("[CreativeEditor] health/player/nail visibility, GUI input, fixed toolbar, expand, scene save: ",
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
