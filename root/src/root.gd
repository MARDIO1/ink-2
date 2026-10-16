extends Node
signal level_changed(level: Node)
## 全局根（`project.godot` 的唯一主场景）：**主菜单 → 关卡选择 → 关卡**，全程只换 `UI` 容器的子场景。
##
## `Level` / `UI` 是两个空容器：
##   · 换屏 = 换 `UI` 的子场景（主菜单 / 关卡选择 / 成品 UI）；
##   · 切关卡 = 换 `Level` 的子场景（旧的整棵释放），UI 不动。
## 「回主菜单」= 重新进 root（`ui/esc` / `ui/hud` 都走这条），第一屏又是主菜单。
## 成品 HUD 监听 level_changed，重载地图时重新绑定玩家墨水与调试面板。
## 关卡里放什么见 `doc/文件组织.md`：世界（PixelWorld）+ 道具 + 玩家 + 相机 + SimulationRuntime 实例 + 创造模式。

@export var menu_scene: PackedScene = preload("res://ui/menu/menu.tscn")
@export var level_select_scene: PackedScene = preload("res://ui/level_select/level_select.tscn")
@export var ui_scene: PackedScene = preload("res://ui/game_ui.tscn")
@export var menu_music: AudioStream
@export var level_music: AudioStream
@export_range(-40.0, 0.0, 0.5) var music_volume_db: float = -22.0

@onready var level_root: Node = $Level
@onready var ui_root: Node = $UI
@onready var music_player: AudioStreamPlayer = $Music
var _loading_level := false
@onready var _transition: Node = get_node("/root/SceneTransition")


func _ready() -> void:
	_play_music(menu_music)
	add_to_group(&"level_router")
	_show_menu()


func _exit_tree() -> void:
	if is_instance_valid(music_player):
		music_player.stop()
		music_player.stream = null
	menu_music = null
	level_music = null


## 第一屏：主菜单。「开始」由菜单喊 `start_pressed`，换屏归 root 管。
func _show_menu() -> void:
	var menu := menu_scene.instantiate() as Control
	menu.connect(&"start_pressed", _show_level_select)
	_set_screen(menu)


## 第二屏：关卡选择。`ui/level_select` 扫出 map 下所有真关卡。
func _show_level_select() -> void:
	if not await _transition.begin(_transition.Style.PAGE, "翻开关卡目录…"):
		return
	var select := level_select_scene.instantiate() as Control
	select.connect(&"level_chosen", request_level_change)
	select.connect(&"back_pressed", _return_to_menu)
	_set_screen(select)
	await _transition.finish()


func _return_to_menu() -> void:
	if not await _transition.begin(_transition.Style.PAGE, "返回封面…"):
		return
	_show_menu()
	await _transition.finish()


## 菜单和传送门共用异步加载入口，锁住期间拒绝其他切关请求。
func request_level_change(path: String) -> bool:
	if _loading_level or _transition.busy:
		return false
	_loading_level = true
	# Do not fan scene dependencies out to worker sub-threads. Several levels depend
	# on native/custom resources that are safe to load in the background loader but
	# fail intermittently when Godot parses their dependency graph concurrently.
	var request_error := ResourceLoader.load_threaded_request(path, "PackedScene", false)
	if request_error != OK:
		_loading_level = false
		_restore_level_select_after_failure(path)
		push_error("Root: 无法开始加载关卡 %s (%d)" % [path, request_error])
		return false
	var transition_style: int = _transition.Style.TEAR if level_root.get_child_count() > 0 else _transition.Style.INK
	await _transition.begin(transition_style, "正在展开 %s…" % path.get_file().get_basename())
	var status := ResourceLoader.load_threaded_get_status(path)
	while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
		status = ResourceLoader.load_threaded_get_status(path)
	var scene := ResourceLoader.load_threaded_get(path) as PackedScene \
		if status == ResourceLoader.THREAD_LOAD_LOADED else null
	if scene == null:
		_restore_level_select_after_failure(path)
		push_error("Root: 加载关卡失败 %s" % path)
		await _transition.finish()
		_loading_level = false
		return false
	load_level(scene)
	_set_screen(ui_scene.instantiate())
	await _transition.finish()
	_loading_level = false
	return true


func _restore_level_select_after_failure(path: String) -> void:
	if ui_root.get_child_count() == 0:
		return
	var screen := ui_root.get_child(0)
	if screen.has_method(&"show_load_failed"):
		screen.call(&"show_load_failed", path)


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
	_play_music(level_music)
	level_changed.emit(level)
	return level


## 音乐由全局根持有，换 UI 不会重复创建；进入关卡时只切换一次曲目。
func _play_music(track: AudioStream) -> void:
	if track == null or music_player.stream == track and music_player.playing:
		return
	if track is AudioStreamOggVorbis:
		(track as AudioStreamOggVorbis).loop = true
	music_player.stream = track
	music_player.volume_db = music_volume_db
	music_player.play()
