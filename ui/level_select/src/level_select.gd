extends Control
## 关卡选择：递归扫 `res://map` 下的 `.tscn`，只留**真关卡**，点一个换一个。
##
## 判据是内容判据（不靠目录名）：场景状态里存在名为 `Player` 的节点。
## 地形件（一块烘好的静态图）没有 Player，自动被排除；创造模式 F5 存出来的新关卡
## （`debug/creative/src/creative.gd` 的 `map_path`）自动进列表，不用改这里。
##
## 列表由 ScrollContainer 承载：只允许纵向滚动，鼠标停在列表上时可直接滚轮浏览；
## 所以导入更多地图后，下方按钮不会落在屏幕外而无法选择。

const LEVEL_DIR := "res://map"
const PLAYER_NODE := "Player"
## 列表按钮宽度，避免被 CenterContainer 挤成一条。
const BUTTON_SIZE := Vector2(340, 46)

signal level_chosen(path: String)

@onready var list: VBoxContainer = $Center/Panel/Scroll/List
@onready var scroll: ScrollContainer = $Center/Panel/Scroll


func _ready() -> void:
	# 不让横向内容意外挤出一个横向滚动条；纵向条在内容溢出时自动出现，
	# ScrollContainer 原生处理鼠标滚轮和触控板滚动。
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.scroll_deadzone = 0
	scroll.get_v_scroll_bar().focus_mode = Control.FOCUS_ALL
	var paths := find_levels()
	print("LEVELS: %s" % str(paths))
	for path in paths:
		var button := Button.new()
		button.text = path.get_file().get_basename()
		button.tooltip_text = path
		button.theme_type_variation = &"PrimaryButton"
		button.custom_minimum_size = BUTTON_SIZE
		button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		button.pressed.connect(level_chosen.emit.bind(path))
		list.add_child(button)
	if list.get_child_count() == 0:
		push_error("关卡选择：%s 下没找到关卡（根级有 %s 的 .tscn）" % [LEVEL_DIR, PLAYER_NODE])
		return
	(list.get_child(0) as Button).grab_focus()


## `res://map` 下所有真关卡的路径，已排序。
static func find_levels() -> PackedStringArray:
	var found := PackedStringArray()
	_scan(LEVEL_DIR, found)
	found.sort()
	return found


static func _scan(dir_path: String, found: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		push_error("关卡选择：打不开 %s" % dir_path)
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var path := dir_path.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				_scan(path, found)
		elif entry.ends_with(".tscn") and _has_player(path):
			found.append(path)
		entry = dir.get_next()
	dir.list_dir_end()


## 真关卡的判据：场景里有一个叫 `Player` 的节点。只看结构，不实例化、不进游戏。
static func _has_player(path: String) -> bool:
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("关卡选择：%s 不是场景" % path)
		return false
	var state := scene.get_state()
	for i in state.get_node_count():
		if String(state.get_node_name(i)) == PLAYER_NODE:
			return true
	return false
