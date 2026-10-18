extends RefCounted
## 右侧色盘：按色表生成圆形墨水按钮 + 笔刷粗细滑条 + 撤销/重做。
##
## **不持有 Canvas**：主题、源滑条、"选中墨水"和"粗细变化"两个回调都由调用方传入，
## 布局与显隐仍归 `canvas.gd`（它才知道画布在哪、什么时候该淡出）。

const InkPalette := preload("res://ink/general/src/ink_palette.gd")
const InkSelectionIndicator := preload("res://ui/theme/ink_selection_indicator.gd")
const HistoryActions := preload("res://actor/canvas/src/history_actions.gd")
const ToolbarScene := preload("res://actor/canvas/toolbar/toolbar.tscn")


## 返回 {"panel", "buttons", "slider", "label"}。
## `ctx` 需要：
##   select_ink: Callable  func(index: int) -> void
##   pen_changed: Callable func(value: float) -> void
##   brush_max: int
static func build(host: Node, theme: Theme, source_pen: HSlider, ctx: Dictionary) -> Dictionary:
	var panel := VBoxContainer.new()
	panel.name = "SidePanel"
	panel.z_index = 100
	panel.theme = theme
	panel.add_theme_constant_override("separation", 4)
	host.add_child(panel)
	var screen_layer := ToolbarScene.instantiate()
	screen_layer.name = "SidePanelLayer"
	screen_layer.canvas = host
	screen_layer.panel = panel
	host.add_child(screen_layer)
	var title_slot := Control.new()
	title_slot.name = "TitleSlot"
	title_slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(title_slot)
	var title := Label.new()
	title.name = "Title"
	title.text = "色盘"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 12)
	title_slot.add_child(title)
	# 保留原标题的布局高度，只移动文字，避免色块和滑条随容器重新排布。
	title_slot.custom_minimum_size = title.get_combined_minimum_size()
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.position.y = -4.0
	var controls := HBoxContainer.new()
	controls.name = "Controls"
	controls.add_theme_constant_override("separation", 8)
	panel.add_child(controls)
	var colors := VBoxContainer.new()
	colors.name = "Colors"
	colors.add_theme_constant_override("separation", 10)
	controls.add_child(colors)
	var buttons: Array[Button] = []
	var select_ink: Callable = ctx.get("select_ink")
	for i in InkPalette.ink_count():
		var color: Color = InkPalette.color_at(i)
		var style := StyleBoxFlat.new()
		style.bg_color = color
		style.corner_radius_top_left = 17
		style.corner_radius_top_right = 17
		style.corner_radius_bottom_left = 17
		style.corner_radius_bottom_right = 17
		style.border_width_left = 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1
		style.border_color = Color(0.035, 0.031, 0.024, 1.0)
		var button := Button.new()
		button.name = "Ink%dButton" % i
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = Vector2(34.0, 34.0)
		button.tooltip_text = "%s（材质 %d）" % [
			InkPalette.ink_name(i), InkPalette.material_id_of(InkPalette.ink_at(i))]
		button.add_theme_color_override(
			"font_color", Color.WHITE if color.get_luminance() < 0.5 else Color.BLACK)
		button.add_theme_stylebox_override("normal", style)
		button.add_theme_stylebox_override("hover", style)
		button.add_theme_stylebox_override("pressed", style)
		button.add_theme_stylebox_override("focus", style)
		button.pressed.connect(select_ink.bind(i))
		colors.add_child(button)
		buttons.append(button)
		InkSelectionIndicator.install(button, color)
	var label := Label.new()
	label.name = "SelectedInkLabel"
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	panel.add_child(label)
	var history := HistoryActions.new()
	history.name = "HistoryActions"
	history.canvas = host
	history.compact = true
	panel.add_child(history)
	var brush_max := int(ctx.get("brush_max", 33))
	source_pen.min_value = 1.0
	source_pen.max_value = float(brush_max)
	source_pen.step = 1.0
	source_pen.tick_count = brush_max
	source_pen.value = clampf(source_pen.value, 1.0, float(brush_max))
	var slider := VSlider.new()
	slider.name = "BrushSizeSlider"
	slider.custom_minimum_size = Vector2(18.0, 166.0)
	slider.min_value = source_pen.min_value
	slider.max_value = source_pen.max_value
	slider.step = source_pen.step
	slider.tick_count = source_pen.tick_count
	slider.value = source_pen.value
	slider.tooltip_text = source_pen.tooltip_text
	slider.theme = theme
	var pen_changed: Callable = ctx.get("pen_changed")
	slider.value_changed.connect(pen_changed)
	controls.add_child(slider)
	return {"panel": panel, "buttons": buttons, "slider": slider, "label": label}
