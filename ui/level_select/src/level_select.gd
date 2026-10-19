extends Control
## 正式地图按阅读顺序列出；Peak 独立放在最后，不加入纸页传送路线。
##
## 列表由 ScrollContainer 承载：只允许纵向滚动，鼠标停在列表上时可直接滚轮浏览；
## 所以导入更多地图后，下方按钮不会落在屏幕外而无法选择。

## 关卡目录与新建写盘在 map 模块；界面这里只留显示相关的东西。
const Catalog := preload("res://map/src/level_catalog.gd")
const Creation := preload("res://map/src/level_creation.gd")
const LEVEL_PATHS := Catalog.LEVEL_PATHS
const BLANK_TEMPLATE := Catalog.BLANK_TEMPLATE
## 列表按钮宽度，避免被 CenterContainer 挤成一条。
const BUTTON_SIZE := Vector2(340, 46)

signal level_chosen(path: String)
signal back_pressed
var _choosing := false

@onready var list: VBoxContainer = $Center/Panel/Scroll/List
@onready var scroll: ScrollContainer = $Center/Panel/Scroll


func _ready() -> void:
	# 不让横向内容意外挤出一个横向滚动条；纵向条在内容溢出时自动出现，
	# ScrollContainer 原生处理鼠标滚轮和触控板滚动。
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.scroll_deadzone = 0
	scroll.get_v_scroll_bar().focus_mode = Control.FOCUS_ALL
	resized.connect(_update_list_layout)
	list.minimum_size_changed.connect(_update_list_layout)
	var paths := find_levels()
	print("LEVELS: %s" % str(paths))
	for path in paths:
		_add_list_button(path)
	# 「新建空白地图」固定在最上方；选关时它跟其他按钮一起被禁用。
	var new_map := _new_button("新建空白地图")
	new_map.name = "NewBlankMapButton"
	new_map.tooltip_text = "在 %s 生成一张空白地图并立即进入" % Creation.NEW_MAP_DIR
	new_map.pressed.connect(_on_new_blank_map_pressed.bind(new_map))
	list.add_child(new_map)
	list.move_child(new_map, 0)
	_update_list_layout()
	if paths.is_empty():
		push_error("关卡选择：%s 下没找到关卡（根级有 %s 的 .tscn）" % [Catalog.LEVEL_DIR, Catalog.PLAYER_NODE])
		return
	(list.get_child(0) as Button).grab_focus()


func _new_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.theme_type_variation = &"PrimaryButton"
	button.custom_minimum_size = BUTTON_SIZE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	# 和主菜单一致：悬停/选中反色。颜色显式给出，不读进入树之前还没解析的主题。
	preload("res://ui/theme/src/button_appearance.gd").menu_action(button)
	return button


func _add_list_button(path: String) -> Button:
	var button := _new_button(path.get_file().get_basename())
	button.tooltip_text = path
	button.pressed.connect(_on_level_button_pressed.bind(path, button))
	list.add_child(button)
	return button


## 新建空白地图：复制模板成一张新关卡，然后直接进入它。
func _on_new_blank_map_pressed(button: Button) -> void:
	if _choosing:
		return
	var path := create_blank_map()
	if path.is_empty():
		button.text = "新建空白地图（失败）"
		return
	_on_level_button_pressed(path, button)


## 两关时面板随内容收紧；关卡增多后限高滚动，标题和底部始终留白。
func _update_list_layout() -> void:
	var panel := $Center/Panel as PanelContainer
	var panel_style := panel.get_theme_stylebox("panel")
	var padding := panel_style.get_minimum_size()
	var width := minf(440.0, maxf(160.0, size.x * 0.80 - padding.x - 24.0))
	var max_height := maxf(60.0, size.y * 0.57 - padding.y - 24.0)
	var content_height := list.get_combined_minimum_size().y
	scroll.custom_minimum_size = Vector2(width, minf(maxf(content_height, 60.0), max_height))
	for child in list.get_children():
		if child is Button:
			(child as Button).custom_minimum_size.x = minf(BUTTON_SIZE.x, width)


func _on_level_button_pressed(path: String, selected_button: Button) -> void:
	if _choosing:
		return
	_choosing = true
	$BackButton.disabled = true
	# 大地图载入期间立即给出反馈，并禁止重复提交载入请求。
	for child in list.get_children():
		if child is Button:
			(child as Button).disabled = true
	selected_button.text = "%s（加载中…）" % path.get_file().get_basename()
	level_chosen.emit(path)


func show_load_failed(path: String) -> void:
	_choosing = false
	$BackButton.disabled = false
	for child in list.get_children():
		if child is Button:
			var button := child as Button
			button.disabled = false
			# 「新建空白地图」的提示语不是路径，不能拿它回填按钮文字。
			if not button.tooltip_text.begins_with("res://"):
				continue
			button.text = button.tooltip_text.get_file().get_basename()
			if button.tooltip_text == path:
				button.text += "（加载失败，请重试）"
				button.grab_focus()


func _on_back_pressed() -> void:
	if not _choosing:
		back_pressed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("escape") and not _choosing:
		get_viewport().set_input_as_handled()
		_on_back_pressed()


## 兼容入口：目录查询在 `map/src/level_catalog.gd`。
static func find_levels() -> PackedStringArray:
	return Catalog.find_levels()


static func next_level(current: String) -> String:
	return Catalog.next_level(current)


## 兼容入口：新建写盘在 `map/src/level_creation.gd`。
static func create_blank_map() -> String:
	return Creation.create_blank_map()
