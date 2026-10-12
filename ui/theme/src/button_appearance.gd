extends RefCounted
## 保持同一按钮所有可操作状态的底色和文字颜色一致。

static func uniform(button: Button, image_only := false) -> void:
	var normal := button.get_theme_stylebox("normal")
	if image_only:
		var empty := StyleBoxEmpty.new()
		for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
			empty.set_content_margin(side, normal.get_content_margin(side))
		normal = empty
	for state in ["normal", "hover", "pressed", "hover_pressed"]:
		button.add_theme_stylebox_override(state, normal)
	if image_only:
		button.add_theme_stylebox_override("disabled", normal)
	button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	var font := button.get_theme_color("font_color")
	var icon := button.get_theme_color("icon_normal_color")
	for state in ["font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, font)
	for state in ["icon_hover_color", "icon_pressed_color", "icon_focus_color"]:
		button.add_theme_color_override(state, icon)
