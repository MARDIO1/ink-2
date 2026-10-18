extends RefCounted
## 保存 / 导出的纯逻辑：路径规范化、位形回写、打包时的临时布局切换。
##
## 这里是**唯一允许序列化整关**的地方（`PackedScene.pack`）。不持有 Creative：
## 需要的运行时对象通过 `ctx` 显式传入；不持有 UI 或长期编辑会话。
##
## `ctx` 字段（都可选）：
##   level_root: Node        要打包的关卡根
##   map_canvas: Node        主画布
##   play_canvases: Array    普通游玩画布
##   bake_preview: bool      额外导出只读参考图。
##   baked_map_path: String  参考图路径。


## 自动保存只提交完整混合文档，避免草稿快照与场景分别写入造成版本错配。
##
## 定时器挂在 `host` 上。`ctx` 需要：
##   host: Node              用来取 SceneTree
##   revision: int           本次编辑的版本号
##   map_path: String        文档路径。
##   full_delay: float       整图打包的延迟
##   is_current: Callable    func(rev) -> bool，判断这次编辑是否仍然是最新的
##   export_scene: Callable  func(path: String) -> Error
static func schedule_auto_save(ctx: Dictionary) -> void:
	var host: Node = ctx.get("host")
	if host == null:
		return
	var full_delay := maxf(float(ctx.get("full_delay", 5.0)), 0.05)
	host.get_tree().create_timer(full_delay).timeout.connect(run_full_export.bind(ctx))


static func run_full_export(ctx: Dictionary) -> void:
	if not _still_current(ctx):
		return
	var export_scene: Callable = ctx.get("export_scene")
	if export_scene.is_valid():
		export_scene.call(str(ctx.get("map_path", "")))


static func _still_current(ctx: Dictionary) -> bool:
	var check: Callable = ctx.get("is_current")
	return check.is_valid() and bool(check.call(int(ctx.get("revision", 0))))


## 保存混合文档：实体保持局部像素和位形，草稿独立无损保存。
static func export_scene(ctx: Dictionary, save_path: String) -> Error:
	var scene = ctx.get("level_root")
	if scene == null:
		push_error("Creative: 找不到关卡根")
		return ERR_DOES_NOT_EXIST
	save_path = normalize_scene_path(save_path)
	if save_path.is_empty():
		push_error("Creative: 场景保存路径为空")
		return ERR_INVALID_PARAMETER
	var map_canvas = ctx.get("map_canvas")
	if bool(ctx.get("bake_preview", false)) and map_canvas != null:
		var preview_error: Error = map_canvas.bake_png(str(ctx.get("baked_map_path", "")))
		if preview_error != OK:
			return preview_error
	sync_node_transforms(scene)
	var packed := PackedScene.new()
	var error := pack_playable(packed, scene, ctx)
	if error == OK:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_path).get_base_dir())
		error = ResourceSaver.save(packed, save_path)
	if error == OK:
		print("MAP scene saved: %s" % ProjectSettings.globalize_path(save_path))
	else:
		push_error("Map scene save failed: %s (%d)" % [save_path, error])
	return error


## 打包瞬间恢复正常游玩布局，pack 完成后立刻回到编辑布局。
## 关卡里存的必须是"玩家能玩的样子"，不能被编辑器里的临时状态污染。
static func pack_playable(packed: PackedScene, scene: Node, ctx: Dictionary) -> Error:
	var map_canvas = ctx.get("map_canvas")
	if map_canvas != null:
		map_canvas.solid.sync_serializable_bodies(scene)
	var play_canvases: Array = ctx.get("play_canvases", [])
	var saved: Dictionary = {}
	for item in play_canvases:
		saved[item] = [item.visible, item.active]
	var map_visible: bool = map_canvas.visible if map_canvas != null else false
	var map_active: bool = map_canvas.active if map_canvas != null else false
	for item in play_canvases:
		_show(item, true)
	_show(map_canvas, false)
	# 编辑态里角色是隐藏的（编辑者不该被自己养的角色挡住），
	# 但关卡存的必须是"玩家能玩的样子"——打包瞬间按进编辑器之前的状态还原。
	var player = ctx.get("player")
	var player_saved: Array = []
	if is_instance_valid(player):
		player_saved = [player.visible, player.process_mode]
		player.visible = bool(ctx.get("player_visible", true))
	# 草稿和实体分别序列化；保存不能生成、回收或改变撤销栈。
	var editor := scene.get_node_or_null("Creative")
	var old_document: Dictionary = editor.editor_draft if editor != null else {}
	var old_snapshot: String = editor.edit_snapshot_path if editor != null else ""
	if editor != null and map_canvas != null:
		editor.editor_draft = map_canvas.surface.capture_document()
		editor.edit_snapshot_path = ""
	var error: Error = packed.pack(scene)
	if editor != null:
		editor.editor_draft = old_document
		editor.edit_snapshot_path = old_snapshot
	if is_instance_valid(player) and not player_saved.is_empty():
		player.visible = bool(player_saved[0])
		player.process_mode = int(player_saved[1])
	for item in saved:
		if is_instance_valid(item):
			item.visible = bool(saved[item][0])
			item.active = bool(saved[item][1])
	if map_canvas != null:
		map_canvas.visible = map_visible
		map_canvas.active = map_active
	return error


static func _show(canvas, on: bool) -> void:
	if canvas == null:
		return
	canvas.visible = on
	canvas.active = on


static func normalize_scene_path(path: String) -> String:
	path = path.strip_edges()
	if path.is_empty():
		return ""
	if path.get_extension().to_lower() == "tscn":
		return path
	if path.get_extension().is_empty():
		return path + ".tscn"
	return path.get_basename() + ".tscn"


## 把每个像素刚体的 PBody 位形写回它的节点。
## ⚠️ 节点自己不跟物理走（每帧跟的是视觉精灵），不写回去就会把玩家存回出生点。
static func sync_node_transforms(root: Node) -> void:
	for node in root.find_children("*", "", true, false):
		if node.has_method("sync_pose"):
			node.sync_pose()
		if not node.has_method("bake"):
			continue
		var body = node.get("body")
		if body == null:
			continue
		# 玩家、手与小怪的运行时姿态不是地图编辑结果；尤其不能把上帝模式
		# 飞行位置写成出生位置。
		if body.tags.has(&"living"):
			continue
		node.position = body.position
		node.rotation = body.rotation
