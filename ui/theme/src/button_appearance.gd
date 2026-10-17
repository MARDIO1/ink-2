extends RefCounted
## 保持同一按钮所有可操作状态的底色和文字颜色一致。

## 主菜单与关卡选择共用的两套颜色：平时深灰底米白字，悬停/选中反色。
const PAPER := Color(0.968627, 0.952941, 0.854902)
const INK := Color(0.0352941, 0.0313726, 0.0235294)
const SLATE := Color(0.231373, 0.219608, 0.192157)


## 同一屏的按钮共用一份样式实例（测试会检查"开始/退出复用同一份"）。
static var _idle_box: StyleBoxFlat
static var _active_box: StyleBoxFlat
static var _focus_box: StyleBoxEmpty


## 主菜单 / 关卡选择的条目按钮：**只有鼠标悬停/按下时反色**（米白底 + 黑字）。
## `focus` 既不反色也不画任何底色 —— 菜单开局会给第一个按钮 `grab_focus()`，
## 若 focus 铺一层深色底，它会盖住悬停时画的米白底，配上黑色文字就是"黑底黑字"。
## 颜色全都显式给出，不依赖 `get_theme_stylebox()` —— 那个在节点入树前读的是
## Godot 默认主题，正是关卡选择按钮之前一直显示默认灰底的原因。
static func menu_action(button: Button) -> void:
	# 打标记：全局 UIFeedback 会在入树后延迟调用 uniform() 把所有状态抹平，
	# 这里跳过打了标记的按钮，悬停反色才留得住。
	button.set_meta(&"menu_action", true)
	if _idle_box == null:
		_idle_box = _flat(SLATE, PAPER)
		_active_box = _flat(PAPER, INK)
		_focus_box = StyleBoxEmpty.new()
	var idle := _idle_box
	var active := _active_box
	button.add_theme_stylebox_override("normal", idle)
	button.add_theme_stylebox_override("disabled", idle)
	button.add_theme_stylebox_override("focus", _focus_box)
	for state in ["hover", "pressed", "hover_pressed"]:
		button.add_theme_stylebox_override(state, active)
	button.add_theme_color_override("font_color", PAPER)
	button.add_theme_color_override("icon_normal_color", PAPER)
	# 显式给 focus 颜色：不写的话会回落到主题里 PrimaryButton 的黑色，
	# 焦点落在第一个按钮上就成了"深灰底 + 黑字"。
	button.add_theme_color_override("font_focus_color", PAPER)
	button.add_theme_color_override("icon_focus_color", PAPER)
	for state in ["font_hover_color", "font_pressed_color"]:
		button.add_theme_color_override(state, INK)
	for state in ["icon_hover_color", "icon_pressed_color"]:
		button.add_theme_color_override(state, INK)


static func _flat(bg: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		style.set_border_width(side, 3)
		style.set_content_margin(side, 14.0 if side != SIDE_TOP and side != SIDE_BOTTOM else 9.0)
	return style

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
