extends SceneTree
## 画布工具栏外观预览：黑底 + 地图编辑模式（钉子/扩展可见），并在选中画笔的状态下截图。
## 只用于人工核对「底板/选中态/图标颜色/层级」，不进验收。
## 会隐藏调试 HUD 和右侧色盘，只留左侧工具栏，方便逐像素量底板边界。

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(360, 760)
	root.content_scale_size = root.size
	# 最坏情况：整个视口是黑的，工具栏没有底板就会看不见。
	RenderingServer.set_default_clear_color(Color(0.015, 0.015, 0.02))
	var scene = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var hud = scene.get_node_or_null("debugHUD")
	if hud != null:
		hud.visible = false
		hud.set_process(false)
	var canvas = scene.get_node("SmallCanvas")
	canvas.active = true
	canvas.set_map_editor_mode(true)
	canvas.set_screen_fixed(true)
	canvas.set_process(false)
	canvas.set_physics_process(false)
	if canvas._side_panel != null:
		canvas._side_panel.visible = false
	canvas.set_tool(canvas.surface.Tool.BRUSH)
	await process_frame
	await process_frame
	_report(canvas, "editor")
	canvas.set_map_editor_mode(false)
	canvas._apply_workbench_column_layout()
	await process_frame
	await process_frame
	_report(canvas, "play")
	if canvas._side_panel != null:
		canvas._side_panel.visible = true
	await process_frame
	await process_frame
	_report(canvas, "play+panel")
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.codex-tmp/canvas_toolbar.png")
	quit(0)


## 打印工具栏内容范围与两侧对齐情况（工具栏本身不再有底板）。
func _report(canvas, label: String) -> void:
	var hand: Control = canvas.hand_button
	var caption: Control = hand.get_node("Caption")
	var content_bottom: float = canvas.buttons.position.y + hand.position.y + caption.position.y + caption.size.y
	print("%s CONTENT bottom=%.1f" % [label, content_bottom])
	print("%s workbench=%s  viewport=%s  origin=%s" % [label,
		canvas.workbench.transform, root.get_visible_rect().size, canvas.screen_toolbar_origin])
	if canvas._side_panel != null:
		var panel_rect: Rect2 = canvas._side_panel.get_global_rect()
		var toggle_rect: Rect2 = canvas.toggle_button.get_global_rect()
		print("%s panel_top=%.1f  toggle_top=%.1f  diff=%.1f" % [label,
			panel_rect.position.y, toggle_rect.position.y,
			toggle_rect.position.y - panel_rect.position.y])
