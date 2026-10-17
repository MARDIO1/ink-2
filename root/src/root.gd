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
## 每帧烘焙多少个像素刚体。关卡 `_ready` 里那一次全量烘焙实测 3.1~3.7 秒（第二页，69 个刚体），
## 卡住的是整帧：加载动画停住、鼠标不动。拆成每帧一个：单个刚体 12~135 ms，
## 帧率不漂亮但动画一直在走，指针也交还给系统绘制。
@export_range(1, 32, 1) var bake_bodies_per_frame := 1

const BodyNode := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")

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


## 最后一页的纸洞返回关卡目录；过渡遮住画面后再释放关卡。
func finish_current_level() -> void:
	if _loading_level or not await _transition.begin(_transition.Style.PAGE, "登顶完成，合上这一页…"):
		return
	for child in level_root.get_children():
		level_root.remove_child(child)
		child.queue_free()
	var select := level_select_scene.instantiate() as Control
	select.connect(&"level_chosen", request_level_change)
	select.connect(&"back_pressed", _return_to_menu)
	_set_screen(select)
	_play_music(menu_music)
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
	# 关卡是逐帧烘焙的，必须 await 到底再揭幕，否则会露出半成品。
	await load_level(scene)
	# 让加载层先出一帧，再挂成品 UI：不然实例化关卡 + 实例化 UI 会挤在同一帧里。
	await get_tree().process_frame
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
##
## 关卡 `_ready` 会调用 `PixelWorld.rebuild()`，一次性烘焙**全部**像素刚体 ——
## 实测第二页 69 个刚体要 3.1 秒，这一帧里加载动画和鼠标都是死的。
## 做法：先把直接子级的刚体节点摘下来，让 `rebuild()` 只造一个空世界（毫秒级），
## 再逐帧放回并 `bake_node()`。关卡此刻在遮罩后面，玩家看不到中间状态。
func load_level(scene: PackedScene) -> Node:
	for child in level_root.get_children():
		level_root.remove_child(child)
		child.queue_free()
	var level := scene.instantiate()
	var staged := _detach_unbaked_bodies(level)
	# 先把空世界建出来：子节点的 _ready 早于关卡根，它们会读 `world`；
	# 摘掉刚体后这一次 rebuild 只造空世界，是毫秒级的。
	if level.has_method(&"rebuild") and level.get("world") == null:
		level.call(&"rebuild")
	level_root.add_child(level)
	_play_music(level_music)
	level_changed.emit(level)
	await _bake_staged_bodies(level, staged)
	return level


## 摘下直接子级的**纯墨迹**刚体。范围必须和 `PixelWorld.rebuild()` 一致（它也只遍历直接子级）。
##
## ⚠️ 玩家的根节点本身就是一个 `PixelBody2D`。不能连它一起摘 —— 关卡里的 `debugHUD`、
## `SimulationRuntime` 等在 `_ready` 里按 `../Player/...` 找节点，摘掉就全部找不到，
## 表现为一堆 `Node not found`，玩家还会被晚挂一帧导致视觉错位。
## 所以只摘不属于 `player` / `living` 这两个组的刚体（即画布烘出来的墨迹）。
func _detach_unbaked_bodies(level: Node) -> Array:
	var staged: Array = []
	if not level.has_method(&"bake_node"):
		return staged
	for child in level.get_children():
		if not (child is BodyNode):
			continue
		if child.is_in_group(&"player") or child.is_in_group(&"living"):
			continue
		level.remove_child(child)
		staged.append(child)
	return staged


## 逐帧放回并烘焙。全部放完再补关节 —— 关节必须晚于它两端的刚体。
func _bake_staged_bodies(level: Node, staged: Array) -> void:
	if staged.is_empty():
		return
	if not level.has_method(&"bake_node"):
		for node in staged:
			level.add_child(node)
		return
	var baked := 0
	for node in staged:
		level.add_child(node)
		level.bake_node(node)
		baked += 1
		if baked % bake_bodies_per_frame == 0:
			await get_tree().process_frame
	if level.has_method(&"_bake_joints"):
		level.call(&"_bake_joints")


## 音乐由全局根持有，换 UI 不会重复创建；进入关卡时只切换一次曲目。
func _play_music(track: AudioStream) -> void:
	if track == null or music_player.stream == track and music_player.playing:
		return
	if track is AudioStreamOggVorbis:
		(track as AudioStreamOggVorbis).loop = true
	music_player.stream = track
	music_player.volume_db = music_volume_db
	music_player.play()
