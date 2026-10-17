extends RefCounted
## 保存 / 导出的纯逻辑：路径规范化、位形回写、打包时的临时布局切换。
##
## 这里是**唯一允许序列化整关**的地方（`PackedScene.pack`）。不持有 Creative：
## 需要的运行时对象全部通过 `ctx` 显式传入，所以它不依赖编辑器状态，也不碰 UI。
##
## `ctx` 字段（都可选）：
##   level_root: Node        要打包的关卡根
##   player: Node            玩家节点
##   player_visible: bool    保存时玩家的常态可见性（进入编辑器前的值）
##   map_canvas: Node        主画布
##   play_canvases: Array    普通游玩画布
##   editing: bool           当前是否在编辑态（决定打包后是否恢复 map_editor_mode）
##   solidify: bool          打包前是否固化画布（见 export_scene 的说明）
##   bake_preview: bool      是否顺带烘一张预览图
##   baked_map_path: String  预览图路径
##   on_solidified: Callable 固化之后、打包之前要做的事（清快照链接等）


## 自动保存：两段式节流——先写 `.snapshot`（快、不固化），再整图打包。
##
## 定时器挂在 `host` 上。`ctx` 需要：
##   host: Node              用来取 SceneTree
##   revision: int           本次编辑的版本号
##   map_path: String        地图路径（快照与导出都以它为基准）
##   snapshot_delay: float   写快照的延迟
##   full_delay: float       整图打包的延迟
##   map_canvas: Node
##   is_current: Callable    func(rev) -> bool，判断这次编辑是否仍然是最新的
##   on_snapshot: Callable   func(path: String) -> void
##   export_scene: Callable  func(path: String, prepare: bool) -> Error
static func schedule_auto_save(ctx: Dictionary) -> void:
	var host: Node = ctx.get("host")
	if host == null:
		return
	var delay := float(ctx.get("snapshot_delay", 0.3))
	var full_delay := maxf(float(ctx.get("full_delay", 5.0)), delay)
	host.get_tree().create_timer(delay).timeout.connect(write_snapshot.bind(ctx))
	host.get_tree().create_timer(full_delay).timeout.connect(run_full_export.bind(ctx))


## 只写编辑快照，不固化画布，保证下一步仍然可以撤销和继续绘制。
## 内容仍是 PNG 压缩数据，但 `.snapshot` 不会和编辑器的 PNG 导入线程争抢文件；
## 整图编码走后台线程，主线程不为它停帧。
static func write_snapshot(ctx: Dictionary) -> void:
	if not _still_current(ctx):
		return
	var canvas = ctx.get("map_canvas")
	var surface = canvas.get_node_or_null("CanvasSurface") if canvas != null else null
	if surface == null or not surface.has_method("request_snapshot"):
		return
	var path := str(ctx.get("map_path", "")).get_basename() + ".edit.snapshot"
	surface.request_snapshot(path)
	var on_snapshot: Callable = ctx.get("on_snapshot")
	if on_snapshot.is_valid():
		on_snapshot.call(path)


static func run_full_export(ctx: Dictionary) -> void:
	if not _still_current(ctx):
		return
	var export_scene: Callable = ctx.get("export_scene")
	if export_scene.is_valid():
		export_scene.call(str(ctx.get("map_path", "")), false)


static func _still_current(ctx: Dictionary) -> bool:
	var check: Callable = ctx.get("is_current")
	return check.is_valid() and bool(check.call(int(ctx.get("revision", 0))))


## 导出一张可直接运行的 `.tscn`。
##
## **`solidify` 是显式的**：保存的是"能玩的地图"，画布上未固化的草稿墨必须在这之前
## 转成刚体，否则写不进场景。但这属于保存格式，不是"运行姿态"——所以由调用方明确要求，
## 不再藏在一个叫"保存"的函数里。
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
	if bool(ctx.get("solidify", false)) and map_canvas != null:
		map_canvas.generate(false)       # 保存不是用户编辑操作，不追加撤销步骤。
		if bool(ctx.get("bake_preview", false)):
			var baked_path := str(ctx.get("baked_map_path", ""))
			var bake_error: Error = map_canvas.bake_png(baked_path)
			if bake_error != OK:
				push_error("Map preview save failed: %s (%d)" % [baked_path, bake_error])
				return bake_error
		var on_solidified: Callable = ctx.get("on_solidified")
		if on_solidified.is_valid():
			on_solidified.call()
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
	var player = ctx.get("player")
	var map_canvas = ctx.get("map_canvas")
	var play_canvases: Array = ctx.get("play_canvases", [])
	var player_visible: bool = player.visible if player != null else true
	var saved: Dictionary = {}
	for item in play_canvases:
		saved[item] = [item.visible, item.active]
	var map_visible: bool = map_canvas.visible if map_canvas != null else false
	var map_active: bool = map_canvas.active if map_canvas != null else false
	if map_canvas != null:
		map_canvas.set_map_editor_mode(false)
	if player != null:
		player.visible = bool(ctx.get("player_visible", true))
	for item in play_canvases:
		_show(item, true)
	_show(map_canvas, false)
	var error: Error = packed.pack(scene)
	for item in saved:
		if is_instance_valid(item):
			item.visible = bool(saved[item][0])
			item.active = bool(saved[item][1])
	if map_canvas != null:
		map_canvas.visible = map_visible
		map_canvas.active = map_active
	if player != null:
		player.visible = player_visible
	if map_canvas != null and bool(ctx.get("editing", false)):
		map_canvas.set_map_editor_mode(true)
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
