extends SceneTree
## 临时预览：主菜单与关卡选择的按钮反色效果。

func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(560, 720)
	root.content_scale_size = root.size
	var menu = load("res://ui/menu/menu.tscn").instantiate()
	root.add_child(menu)
	await process_frame
	await process_frame
	menu.get_node("ButtonCenter/Buttons/SoundButton").grab_focus()
	# 把鼠标移到「开始」上：验证"聚焦 + 悬停"时也是米白底黑字（和下面两个一致）。
	var start: Button = menu.get_node("ButtonCenter/Buttons/StartButton")
	var center := start.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = center
	motion.global_position = center
	root.push_input(motion)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.codex-tmp/menu_focus_sound.png")
	print("SAVE menu focus=", get_root().gui_get_focus_owner(), " hovered=", start.is_hovered())
	menu.queue_free()
	await process_frame

	var select = load("res://ui/level_select/level_select.tscn").instantiate()
	root.add_child(select)
	await process_frame
	await process_frame
	var list = select.get_node("Center/Panel/Scroll/List")
	var buttons: Array = list.get_children().filter(func(n): return n is Button)
	print("LEVEL_BUTTONS=", buttons.size())
	if buttons.size() > 1:
		buttons[1].grab_focus()
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("res://.codex-tmp/level_select_focus.png")
	var box = buttons[0].get_theme_stylebox("hover")
	print("SAVE level_select hover_bg=", box.get("bg_color"), " normal_bg=", buttons[0].get_theme_stylebox("normal").get("bg_color"))
	quit(0)
