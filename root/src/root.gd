extends Node
## 全局根（`project.godot` 的唯一主场景）：**主菜单 → 关卡选择 → 关卡**，全程只换 `UI` 容器的子场景。
##
## `Level` / `UI` 是两个空容器：
##   · 换屏 = 换 `UI` 的子场景（主菜单 / 关卡选择 / 成品 UI）；
##   · 切关卡 = 换 `Level` 的子场景（旧的整棵释放），UI 不动。
## 「回主菜单」= 重新进 root（`ui/esc` / `ui/hud` 都走这条），第一屏又是主菜单。
## ⚠️ 成品 UI 必须等关卡挂好再挂：`ui/hud` 的 `_ready` 只抓一次玩家的 `InkHealth`，
##    先挂 UI 再选关卡，墨水条会永远停在占位。
## 关卡里放什么见 `doc/文件组织.md`：世界（PixelWorld）+ 道具 + 玩家 + 相机 + SimulationRuntime 实例 + 创造模式。

@export var menu_scene: PackedScene = preload("res://ui/menu/menu.tscn")
@export var level_select_scene: PackedScene = preload("res://ui/level_select/level_select.tscn")
@export var ui_scene: PackedScene = preload("res://ui/game_ui.tscn")

@onready var level_root: Node = $Level
@onready var ui_root: Node = $UI
var _loading_level := false


func _ready() -> void:
	_show_menu()


## 第一屏：主菜单。「开始」由菜单喊 `start_pressed`，换屏归 root 管。
func _show_menu() -> void:
	var menu := menu_scene.instantiate() as Control
	menu.connect(&"start_pressed", _show_level_select)
	_set_screen(menu)


## 第二屏：关卡选择。`ui/level_select` 扫出 map 下所有真关卡。
func _show_level_select() -> void:
	var select := level_select_scene.instantiate() as Control
	select.connect(&"level_chosen", _on_level_chosen)
	_set_screen(select)


## 第三屏：关卡 + 成品 UI。⚠️ 关卡先挂、UI 后挂（见文件头）。
func _on_level_chosen(path: String) -> void:
	if _loading_level:
		return
	_loading_level = true
	var request_error := ResourceLoader.load_threaded_request(path, "PackedScene", true)
	if request_error != OK:
		_loading_level = false
		push_error("Root: 无法开始加载关卡 %s (%d)" % [path, request_error])
		return
	var status := ResourceLoader.load_threaded_get_status(path)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
		status = ResourceLoader.load_threaded_get_status(path)
	var scene := ResourceLoader.load_threaded_get(path) as PackedScene \
		if status == ResourceLoader.THREAD_LOAD_LOADED else null
	_loading_level = false
	if scene == null:
		push_error("Root: 加载关卡失败 %s" % path)
		return
	load_level(scene)
	_set_screen(ui_scene.instantiate())


## 换屏：`UI` 容器里的旧屏整棵释放，挂上新的那一屏。
func _set_screen(screen: Node) -> void:
	for child in ui_root.get_children():
		ui_root.remove_child(child)
		child.queue_free()
	ui_root.add_child(screen)


## 换关卡：旧的整棵释放，新的挂在 `Level` 下。返回新关卡根节点。
func load_level(scene: PackedScene) -> Node:
	for child in level_root.get_children():
		level_root.remove_child(child)
		child.queue_free()
	var level := scene.instantiate()
	level_root.add_child(level)
	return level
