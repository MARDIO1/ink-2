extends Control
## 正式地图按阅读顺序列出；Peak 独立放在最后，不加入纸页传送路线。
##
## 列表由 ScrollContainer 承载：只允许纵向滚动，鼠标停在列表上时可直接滚轮浏览；
## 所以导入更多地图后，下方按钮不会落在屏幕外而无法选择。

const LEVEL_DIR := "res://map"
const PLAYER_NODE := "Player"
const ContentPaths := preload("res://map/src/content_paths.gd")
const LEVEL_PATHS: Array[String] = [
	"res://map/asset/imported/扉页.tscn",
	"res://map/asset/imported/第一页.tscn",
	"res://map/asset/imported/第三页.tscn",
	"res://map/asset/imported/peak.tscn",
]
## 列表按钮宽度，避免被 CenterContainer 挤成一条。
const BUTTON_SIZE := Vector2(340, 46)
## 「新建空白地图」复制这个模板；它自己不是关卡，不进程列表。
const BLANK_TEMPLATE := "res://map/asset/blank_level.tscn"
## 尚未完成出生点/地形，或仅用于测试的场景不进入玩家关卡目录。
const HIDDEN_LEVELS := {
	"res://map/asset/imported/新地图1.tscn": true,
	"res://map/asset/imported/新地图2.tscn": true,
	"res://map/asset/imported/第二关（制作中）.tscn": true,
	"res://map/asset/imported/第二关（小怪关）.tscn": true,
	"res://map/asset/imported/黄色.tscn": true,
	"res://map/test/空白大地图.tscn": true,
}

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
	new_map.tooltip_text = "在 %s 生成一张空白地图并立即进入" % ContentPaths.writable_map_dir()
	new_map.pressed.connect(_on_new_blank_map_pressed.bind(new_map))
	list.add_child(new_map)
	list.move_child(new_map, 0)
	_update_list_layout()
	if paths.is_empty():
		push_error("关卡选择：%s 下没找到关卡（根级有 %s 的 .tscn）" % [LEVEL_DIR, PLAYER_NODE])
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


## 返回正式地图；开发测试夹具不进入玩家目录。
## 正式页按阅读顺序在前，其余自己加进 res://map 的关卡按路径排在后面。
static func find_levels() -> PackedStringArray:
	var found := PackedStringArray()
	for path in LEVEL_PATHS:
		if ContentPaths.resource_exists(path, "PackedScene") and _has_player(path):
			found.append(path)
	for path in _scan_map_levels():
		if not found.has(path):
			found.append(path)
	return found


## 递归扫 PCK 和导出版的 exe 旁 map，收所有带 Player 的 .tscn。
static func _scan_map_levels() -> PackedStringArray:
	var result := PackedStringArray()
	_collect_map_dir(LEVEL_DIR, result, false)
	if ContentPaths.is_external():
		_collect_map_dir(ContentPaths.external_map_dir(), result, true)
	result.sort()
	return result


static func _collect_map_dir(directory: String, result: PackedStringArray, external: bool) -> void:
	var pending: Array[String] = [directory]
	while not pending.is_empty():
		var current: String = pending.pop_back()
		var dir := DirAccess.open(current)
		if dir == null:
			continue
		for name in dir.get_directories():
			pending.append(current.path_join(name))
		for name in dir.get_files():
			var scene_name := _scene_filename(name)
			if scene_name.is_empty():
				continue
			var path := current.path_join(scene_name)
			var logical := ContentPaths.to_res_path(path) if external else path
			if logical == BLANK_TEMPLATE or HIDDEN_LEVELS.has(logical) or not _has_player(logical):
				continue
			if not result.has(logical):
				result.append(logical)


## 复制空白模板成一张新关卡，返回新路径；失败返回空串。
## PCK 里可加载场景表现为 `.tscn.remap`；扫描与资源路径都使用去掉 remap 的场景名。
static func _scene_filename(name: String) -> String:
	if name.ends_with(".tscn.remap"):
		return name.trim_suffix(".remap")
	return name if name.ends_with(".tscn") else ""


static func create_blank_map() -> String:
	var template_path := ContentPaths.resolve(BLANK_TEMPLATE)
	var source := FileAccess.get_file_as_string(template_path)
	if source.is_empty():
		push_error("关卡选择：读不到空白地图模板 %s" % template_path)
		return ""
	# 复制出来的场景必须换一个资源身份，否则两张场景共用一个 uid。
	source = _strip_scene_uid(source)
	var map_dir := ContentPaths.writable_map_dir()
	if not DirAccess.dir_exists_absolute(map_dir):
		var err := DirAccess.make_dir_recursive_absolute(map_dir)
		if err != OK:
			push_error("关卡选择：建不了目录 %s（%d）" % [map_dir, err])
			return ""
	for index in range(1, 1000):
		var path := "%s/新地图%d.tscn" % [map_dir, index]
		if FileAccess.file_exists(path):
			continue
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			push_error("关卡选择：写不了 %s（%d）" % [path, FileAccess.get_open_error()])
			return ""
		file.store_string(source)
		file.close()
		return ContentPaths.to_res_path(path)
	push_error("关卡选择：新地图编号用完了")
	return ""


static func _strip_scene_uid(source: String) -> String:
	var newline := source.find("\n")
	if newline < 0:
		return source
	var header := source.substr(0, newline)
	if not header.begins_with("[gd_scene"):
		return source
	var start := header.find(" uid=\"")
	if start < 0:
		return source
	var end := header.find("\"", start + 6)
	if end < 0:
		return source
	return header.substr(0, start) + header.substr(end + 1) + source.substr(newline)


static func next_level(current: String) -> String:
	var index := LEVEL_PATHS.find(ContentPaths.to_res_path(current))
	# 只连接前三次翻页；第三页和 Peak 都没有自动下一关。
	if index < 0 or index >= LEVEL_PATHS.size() - 2:
		return ""
	var destination := LEVEL_PATHS[index + 1]
	return destination if ContentPaths.resource_exists(destination, "PackedScene") else ""


## 真关卡的判据：场景里有一个叫 `Player` 的节点。只看结构，不实例化、不进游戏。
static func _has_player(path: String) -> bool:
	# 关卡列表只需要判断节点名。逐行读取并在找到 Player 后立即停止，避免为了显示
	# 菜单就把每个大型地图完整解析进 ResourceLoader 缓存。
	var resolved := ContentPaths.resolve(path)
	var file := FileAccess.open(resolved, FileAccess.READ)
	if file == null:
		# PCK 内不保留源 .tscn：读取编译场景的结构，不实例化关卡。
		var packed = ResourceLoader.load(resolved, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		if packed != null:
			var state := packed.get_state()
			for index in state.get_node_count():
				if String(state.get_node_name(index)) == PLAYER_NODE:
					return true
		return false
	var marker := 'name="%s"' % PLAYER_NODE
	while not file.eof_reached():
		var line := file.get_line()
		if line.begins_with("[node ") and line.contains(marker):
			return true
	return false
