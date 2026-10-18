extends RefCounted
## 工具栏结构与度量：工具按钮的内容、图标、两列网格与「放下画笔」按钮的尺寸。
##
## 只接收节点和度量，**不持有 Canvas**：`editor_mode`、两套按钮尺寸、偏移量都由调用方传入，
## 所以这块逻辑可以脱离画布单独验证。

## 按钮顺序 = 数字键 1～0 的顺序。
const TOOL_ORDER := [
	"Brush", "Eraser", "Shape", "Bucket", "Redraw", "SelectDelete",
	"Generate", "ReturnToCanvas", "Nail", "ExpandCanvas",
]
const CAPTIONS := {
	"Brush": "画笔", "Eraser": "橡皮", "Shape": "形状", "Bucket": "填充",
	"Redraw": "清空", "SelectDelete": "框选", "Generate": "固化",
	"ReturnToCanvas": "墨化", "Nail": "钉子", "ExpandCanvas": "扩展",
}


static func atlas_icon(source: Texture2D, region: Rect2) -> AtlasTexture:
	var icon := AtlasTexture.new()
	icon.atlas = source
	icon.region = region
	return icon


## 把按钮自带的 icon 换成一个 `ToolIcon` 子节点 + 底部说明文字。
static func add_button_contents(button: Button, caption_text: String) -> void:
	var icon_texture := button.icon
	button.icon = null
	button.text = ""
	button.expand_icon = false
	var icon_view := TextureRect.new()
	icon_view.name = "ToolIcon"
	icon_view.texture = icon_texture
	icon_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	icon_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	icon_view.offset_left = 8.0
	icon_view.offset_top = 6.0
	icon_view.offset_right = -8.0
	icon_view.offset_bottom = -28.0
	button.add_child(icon_view)
	var caption := Label.new()
	caption.name = "Caption"
	caption.text = caption_text
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.anchor_left = 0.0
	caption.anchor_top = 1.0
	caption.anchor_right = 1.0
	caption.anchor_bottom = 1.0
	caption.offset_top = -28.0
	caption.offset_bottom = -2.0
	caption.add_theme_font_size_override("font_size", 16)
	button.add_child(caption)


## 按顺序排好工具按钮：补内容、换「扩展」的图标、移动子节点。
static func prepare_structure(tool_grid: GridContainer, hand_button: Button, buttons: Control,
		expand_icon: Texture2D, expand_region: Rect2,
		hand_source: Texture2D, hand_region: Rect2) -> void:
	for index in TOOL_ORDER.size():
		var button := tool_grid.get_node_or_null(NodePath(TOOL_ORDER[index])) as Button
		if button != null:
			if button.name == &"ExpandCanvas":
				button.icon = atlas_icon(expand_icon, expand_region)
			add_button_contents(button, str(CAPTIONS[TOOL_ORDER[index]]))
			if button.name == &"InfiniteNail":
				var icon_view := button.get_node("ToolIcon") as TextureRect
				icon_view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			tool_grid.move_child(button, index)
	hand_button.reparent(buttons)
	hand_button.icon = atlas_icon(hand_source, hand_region)
	var hand_icon := TextureRect.new()
	hand_icon.name = "ToolIcon"
	hand_icon.texture = hand_button.icon
	hand_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hand_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hand_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hand_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hand_button.add_child(hand_icon)
	hand_button.icon = null
	hand_button.text = ""
	hand_button.expand_icon = true
	hand_button.add_theme_constant_override("icon_max_width", 92)
	var hand_caption := Label.new()
	hand_caption.name = "Caption"
	hand_caption.text = "放下画笔"
	hand_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hand_caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hand_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hand_caption.anchor_top = 1.0
	hand_caption.anchor_bottom = 1.0
	hand_caption.anchor_right = 1.0
	hand_button.add_child(hand_caption)


static func apply_button_metrics(button: Button, width: float, height: float,
		caption_height: float, font_size: int, editor_mode: bool) -> void:
	button.custom_minimum_size = Vector2(width, height)
	var icon_view := button.get_node("ToolIcon") as TextureRect
	icon_view.offset_left = 4.0 if editor_mode else 3.0
	icon_view.offset_top = 3.0 if editor_mode else 2.0
	icon_view.offset_right = -4.0 if editor_mode else -3.0
	icon_view.offset_bottom = -caption_height
	var caption := button.get_node("Caption") as Label
	caption.offset_top = -caption_height
	caption.offset_bottom = 0.0
	caption.add_theme_font_size_override("font_size", font_size)


## 两种模式均按 PPT 使用两列；操纵按钮独占最下方一行。
## `metrics` 由调用方按当前模式选好：columns / button_width / button_height /
## h_gap / v_gap / hand_size / caption_height / toolbar_x_offset / toolbar_y_offset。
static func apply_column_layout(tool_grid: GridContainer, hand_button: Button,
		buttons: Control, toggle_button: Button, editor_mode: bool, metrics: Dictionary) -> void:
	var columns: int = int(metrics.columns)
	var button_width: float = float(metrics.button_width)
	var button_height: float = float(metrics.button_height)
	var h_gap: float = float(metrics.h_gap)
	var v_gap: float = float(metrics.v_gap)
	var hand_size: float = float(metrics.hand_size)
	var caption_height: float = float(metrics.caption_height)
	var width := columns * button_width + (columns - 1) * h_gap
	tool_grid.columns = columns
	tool_grid.add_theme_constant_override("h_separation", int(h_gap))
	tool_grid.add_theme_constant_override("v_separation", int(v_gap))
	tool_grid.offset_right = width
	var visible_count := 0
	for child in tool_grid.get_children():
		if child is Control and child.visible:
			apply_button_metrics(child as Button, button_width, button_height,
				caption_height, 10 if editor_mode else 8, editor_mode)
			visible_count += 1
	var rows := ceili(float(visible_count) / float(columns))
	var grid_height := rows * button_height + maxi(rows - 1, 0) * v_gap
	tool_grid.offset_bottom = grid_height
	var hand_gap := 12.0 if editor_mode else 8.0
	hand_button.custom_minimum_size = Vector2.ONE * hand_size
	hand_button.add_theme_constant_override("icon_max_width", 58 if editor_mode else 42)
	hand_button.position = Vector2((width - hand_size) * 0.5, grid_height + hand_gap)
	hand_button.size = Vector2.ONE * hand_size
	var hand_caption := hand_button.get_node("Caption") as Label
	hand_caption.offset_top = 2.0
	hand_caption.offset_bottom = 2.0 + caption_height
	hand_caption.add_theme_font_size_override("font_size", 10 if editor_mode else 8)
	if editor_mode:
		buttons.offset_left = -186.0
		buttons.offset_top = 116.0
		toggle_button.offset_left = -186.0
		toggle_button.offset_top = 56.0
		toggle_button.offset_bottom = 84.0
		toggle_button.add_theme_font_size_override("font_size", 16)
	else:
		buttons.offset_left = -42.0 - float(metrics.toolbar_x_offset)
		buttons.offset_top = 160.0 + float(metrics.toolbar_y_offset)
		toggle_button.offset_left = -22.0 - float(metrics.toolbar_x_offset)
		toggle_button.offset_top = 136.0 + float(metrics.toolbar_y_offset)
		toggle_button.offset_bottom = 154.0 + float(metrics.toolbar_y_offset)
		toggle_button.add_theme_font_size_override("font_size", 10)
	buttons.offset_right = buttons.offset_left + width
	buttons.offset_bottom = buttons.offset_top + grid_height + hand_size + hand_gap + caption_height + 2.0
	toggle_button.offset_right = toggle_button.offset_left + (width if editor_mode else 36.0)
