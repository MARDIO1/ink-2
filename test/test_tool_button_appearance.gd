extends SceneTree

var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, condition: bool) -> void:
	if not condition:
		failures += 1
	print("[ButtonAppearance] %s %s" % ["PASS" if condition else "FAIL", label])

func _run() -> void:
	var menu: Control = load("res://ui/menu/menu.tscn").instantiate()
	root.add_child(menu)
	var start: Button = menu.get_node("ButtonCenter/Buttons/StartButton")
	var quit_button: Button = menu.get_node("ButtonCenter/Buttons/QuitButton")
	_check("menu buttons have same base color", start.get_theme_stylebox("normal").bg_color == quit_button.get_theme_stylebox("normal").bg_color)
	_check("focus and hover do not tint menu", start.get_theme_stylebox("normal") == start.get_theme_stylebox("hover") and start.get_theme_color("font_color") == start.get_theme_color("font_focus_color"))
	menu.queue_free()
	var selector: Control = load("res://ui/level_select/level_select.tscn").instantiate()
	root.add_child(selector)
	var first: Button = selector.list.get_child(0)
	var second: Button = selector.list.get_child(1)
	_check("level buttons keep identical color", first.get_theme_stylebox("hover").bg_color == second.get_theme_stylebox("normal").bg_color)
	selector.queue_free()
	var scene: Node = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas: Node = scene.get_node("SmallCanvas")
	var brush: Button = canvas.tool_grid.get_node("Brush")
	var icon: TextureRect = brush.get_node("ToolIcon")
	var caption: Label = brush.get_node("Caption")
	var hit_rect := brush.get_global_rect()
	var caption_position := caption.position
	# 工具栏不画外框：选中只靠图标本身的轻微缩放表示，不要整块高亮。
	for state in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		_check("toolbar no outer frame: " + state, brush.get_theme_stylebox(state) is StyleBoxEmpty)
	brush.get_node("IconFeedback").pulse()
	_check("shortcut only changes original image", icon.scale.x < 1.0 and brush.get_global_rect() == hit_rect and caption.position == caption_position)
	await create_timer(0.2).timeout
	_check("no image tint", icon.modulate == Color.WHITE)
	_check("hand uses original rectangular image", canvas.hand_button.get_node("ToolIcon").texture is AtlasTexture)
	# 背后是黑墨或深色场景时，靠这块纸色底板保证工具还看得见。
	var plate: Control = canvas.workbench.get_node_or_null("ToolbarPlate")
	_check("toolbar has a backing plate covering its buttons", plate != null
		and plate.is_visible_in_tree() and plate.get_global_rect().encloses(brush.get_global_rect()))
	# HUD 是 CanvasLayer(1)，工具栏必须在更靠上的层，否则血条会盖住按钮。
	_check("toolbar draws above HUD content", canvas.workbench.get_parent() is CanvasLayer
		and (canvas.workbench.get_parent() as CanvasLayer).layer >= 2)
	if OS.get_cmdline_user_args().has("--preview"):
		root.mode = Window.MODE_WINDOWED
		root.size = Vector2i(960, 720)
		root.content_scale_size = Vector2i(960, 720)
		canvas.set_map_editor_mode(true)
		canvas.set_physics_process(false)
		canvas.set_process(false)
		var preview_layer := CanvasLayer.new()
		preview_layer.layer = 900
		root.add_child(preview_layer)
		var stage := Control.new()
		preview_layer.add_child(stage)
		stage.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var paper := TextureRect.new()
		paper.texture = load("res://ui/menu/asset/paper.png")
		paper.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		paper.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		stage.add_child(paper)
		canvas.workbench.reparent(stage)
		canvas.workbench.transform = Transform2D.IDENTITY
		canvas.workbench.position = Vector2(400, 20)
		canvas.workbench.scale = Vector2(1.5, 1.5)
		canvas.buttons.position = Vector2(0, 50)
		canvas.toggle_button.position = Vector2(0, 0)
		canvas.brush_panel.hide()
		canvas.resize_panel.hide()
		canvas.workbench.show()
		canvas.buttons.show()
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("C:/Users/youli/.codex/visualizations/2026/10/11/01a12987-d6cc-7a63-9192-35e2107dc184/toolbar-original-images.png")
		preview_layer.queue_free()
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)
