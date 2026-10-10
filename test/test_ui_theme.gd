extends SceneTree

const FONT_PATH := "res://ui/theme/asset/ipix_ui_font.tres"
const PRIMARY_FONT_PATH := "res://ui/theme/asset/ipix_ui_primary.ttf"
const FULL_FONT_PATH := "res://ui/dialogue/asset/ipix_12px.ttf"

const UI_TEXT_SAMPLE := """
隐藏显示工具栏绘图擦除自选形状钉子填充封闭区域返回画布生成实体清理普通手笔触大小像素
小人外观卡片标题在这里放置说明任务信息或状态内容危险操作确认对话框正文通过脚本修改标题与内容取消
墨水量开始游戏设置返回标题输入存档名称低中高继续回主菜单退出单击下方文本框阅读下一句纸上醒来移动按空格键跳跃
INK ATTACK UI RESOURCE px a b c d e f g 0 1 2 3 4 5 6 7 8 9 / >，。：
"""

var _checks := 0
var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if condition:
		return
	_failures += 1
	printerr("[UITheme] FAIL: ", message)


func _is_ipix(font: Font) -> bool:
	return font != null and font.resource_path == FONT_PATH


func _font_or_fallback_has_char(font: FontVariation, codepoint: int) -> bool:
	if font.base_font != null and font.base_font.has_char(codepoint):
		return true
	for fallback: Font in font.fallbacks:
		if fallback != null and fallback.has_char(codepoint):
			return true
	return false


func _check_scene_fonts(scene_path: String, node_paths: PackedStringArray) -> void:
	var packed := load(scene_path) as PackedScene
	_check(packed != null, "无法加载场景：%s" % scene_path)
	if packed == null:
		return
	var scene := packed.instantiate()
	root.add_child(scene)
	await process_frame
	for node_path in node_paths:
		var control := scene.get_node_or_null(node_path) as Control
		_check(control != null, "%s 缺少文字节点：%s" % [scene_path, node_path])
		if control != null:
			_check(_is_ipix(control.get_theme_font("font")),
				"%s/%s 未继承 IPix" % [scene_path, node_path])
	scene.queue_free()
	await process_frame


func _run() -> void:
	var theme := load("res://ui/theme/asset/ink_attack_theme.tres") as Theme
	_check(theme != null, "必须能加载统一 UI Theme")
	if theme != null:
		_check(_is_ipix(theme.default_font), "统一 Theme 默认字体必须是完整版 IPix")
		var ui_font := theme.default_font as FontVariation
		_check(ui_font != null, "统一 UI 字体必须是显式 FontVariation 回退链")
		if ui_font != null:
			_check(ui_font.base_font.resource_path == PRIMARY_FONT_PATH,
				"UI 主字体必须使用用户指定 IPix")
			_check(ui_font.fallbacks.size() == 1
				and ui_font.fallbacks[0].resource_path == FULL_FONT_PATH,
				"UI 缺字必须只回退到项目完整版 IPix")
			_check(ui_font.spacing_glyph == 1,
				"统一 IPix 必须保留 1px 字距，防止相邻字形粘连")
			var checked_codepoints := {}
			for index in UI_TEXT_SAMPLE.length():
				var codepoint := UI_TEXT_SAMPLE.unicode_at(index)
				if codepoint <= 32 or checked_codepoints.has(codepoint):
					continue
				checked_codepoints[codepoint] = true
				_check(_font_or_fallback_has_char(ui_font, codepoint),
					"IPix 回退链缺少 UI 字符：%s (U+%04X)" % [
						UI_TEXT_SAMPLE.substr(index, 1), codepoint
					])
		_check(theme.default_font_size == 14, "统一 Theme 默认字号必须为 14px")
		_check(theme.get_font_size("font_size", "Button") == 14,
			"Button 基准字号必须为 14px")
		_check(theme.get_font_size("font_size", "Label") == 14,
			"Label 基准字号必须为 14px")

	await _check_scene_fonts("res://ui/menu/menu.tscn", PackedStringArray([
		"ButtonCenter/Buttons/StartButton",
		"ButtonCenter/Buttons/QuitButton",
	]))
	var menu: Node = (load("res://ui/menu/menu.tscn") as PackedScene).instantiate()
	root.add_child(menu)
	await process_frame
	var logo := menu.get_node_or_null("Title") as TextureRect
	_check(logo != null and logo.texture != null
		and logo.texture.resource_path.ends_with("/title.png"),
		"主菜单 Logo 必须继续使用图片，不参与字体替换")
	var start_button := menu.get_node_or_null("ButtonCenter/Buttons/StartButton") as Button
	var quit_button := menu.get_node_or_null("ButtonCenter/Buttons/QuitButton") as Button
	_check(start_button != null and start_button.theme_type_variation == &"MenuActionButton",
		"开始按钮必须使用统一深灰菜单样式")
	_check(quit_button != null and quit_button.theme_type_variation == &"MenuActionButton",
		"主菜单退出按钮必须使用统一深灰菜单样式")
	_check(start_button != null and start_button.get_theme_color("font_focus_color")
		== start_button.get_theme_color("font_color"),
		"开始按钮聚焦时必须保持米黄色文字，不能在黑底上隐形")
	_check(quit_button != null and quit_button.get_theme_color("font_focus_color")
		== quit_button.get_theme_color("font_color"),
		"退出按钮聚焦时必须保持米黄色文字")
	var menu_normal := start_button.get_theme_stylebox("normal") as StyleBoxFlat
	var menu_hover := start_button.get_theme_stylebox("hover") as StyleBoxFlat
	_check(menu_normal != null and menu_normal.bg_color == Color(0.231373, 0.219608, 0.192157, 1),
		"统一菜单按钮底色必须与主菜单退出键一致")
	_check(menu_normal == quit_button.get_theme_stylebox("normal"),
		"开始和退出必须复用同一份普通状态样式")
	_check(menu_hover != null and menu_hover.bg_color == menu_normal.bg_color
		and menu_hover.expand_margin_left == 3.0,
		"悬停只能增加外框，不能改变按钮底色")
	menu.queue_free()
	await process_frame

	await _check_scene_fonts("res://ui/esc/esc.tscn", PackedStringArray([
		"Center/Panel/Buttons/Title",
		"Center/Panel/Buttons/ContinueButton",
		"Center/Panel/Buttons/MenuButton",
		"Center/Panel/Buttons/QuitButton",
	]))
	var esc: Node = (load("res://ui/esc/esc.tscn") as PackedScene).instantiate()
	root.add_child(esc)
	await process_frame
	for path in PackedStringArray([
		"Center/Panel/Buttons/ContinueButton",
		"Center/Panel/Buttons/MenuButton",
		"Center/Panel/Buttons/QuitButton",
	]):
		var esc_button := esc.get_node(path) as Button
		_check(esc_button.theme_type_variation == &"MenuActionButton",
			"ESC 按钮必须使用统一深灰菜单样式：%s" % path)
		var esc_normal := esc_button.get_theme_stylebox("normal") as StyleBoxFlat
		_check(esc_normal != null and esc_normal.bg_color == menu_normal.bg_color,
			"ESC 按钮底色必须与主菜单退出键一致：%s" % path)
	var esc_quit := esc.get_node("Center/Panel/Buttons/QuitButton") as Button
	_check(esc_quit.icon != null
		and esc_quit.icon.resource_path.ends_with("/ui/menu/asset/icon_exit.svg"),
		"ESC 退出按钮必须复用主菜单的米黄色可调色退出图标")
	esc.queue_free()
	await process_frame
	await _check_scene_fonts("res://ui/hud/hud.tscn", PackedStringArray([
		"Root/HealthUI/InkMeter",
	]))
	var hud := (load("res://ui/hud/hud.tscn") as PackedScene).instantiate()
	root.add_child(hud)
	await process_frame
	var health_ui := hud.get_node("Root/HealthUI") as Control
	_check(health_ui.scale.is_equal_approx(Vector2(0.75, 0.75)),
		"血条、瓶身填充和墨水文字必须统一缩放为 0.75 倍")
	_check(health_ui.has_node("BottleFill") and health_ui.has_node("HealthArt") \
		and health_ui.has_node("InkMeter"), "配套血条 UI 必须位于同一缩放容器")
	hud.queue_free()
	await process_frame
	await _check_scene_fonts("res://ui/dialogue/dialogue_box.tscn", PackedStringArray([
		"Root/DialoguePanel/PixelText/TextViewport/DialogueLabel",
		"Root/DialoguePanel/PixelText/TextViewport/NextHint",
	]))
	await _check_scene_fonts("res://actor/canvas/canvas.tscn", PackedStringArray([
		"WorkbenchUI/Toggle",
		"WorkbenchUI/Buttons/Hand",
		"WorkbenchUI/ResizePanel/Grid/PlayerVisibility",
		"WorkbenchUI/ResizePanel/Grid/NailVisibility",
	]))

	print("[UITheme] %d checks, %d failures" % [_checks, _failures])
	quit(1 if _failures else 0)
