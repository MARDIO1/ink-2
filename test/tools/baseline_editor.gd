extends SceneTree
## 编辑器回归基线：真实 Root 路由加载 → 蓝图采集/放置/撤销/重做 → 固化 → 导出/重进结构对比。
##
## 只读现有地图，只写 `user://` 临时副本；不覆盖任何地图、快照或蓝图。
## 任何"拆 creative / 拆 canvas / 动保存或蓝图"的提交，先跑这个脚本（headless 约 3–5 分钟）。
##
## ⚠️ 顺序有讲究：`generate()`（固化）会把画布像素转成刚体并清空画布，
##    所以蓝图的采集/放置/撤销必须做在固化**之前**，否则采到的像素是 0。

const LEVEL := "res://map/asset/imported/peak.tscn"
const EXPORT := "user://baseline_export.tscn"
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")

var checks := 0
var failures := 0


func _initialize() -> void:
	run.call_deferred()


func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[Baseline] %s %s" % ["PASS" if ok else "FAIL", label])


func run() -> void:
	root.size = Vector2i(960, 540)
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	await process_frame
	app._transition.duration = 0.05

	# ---- 1. 真实路由加载 ----
	var loaded: bool = await app.request_level_change(LEVEL)
	check("经 Root 路由加载关卡", loaded)
	var level = app.level_root.get_child(0)
	var canvas = _find_canvas(level)
	check("关卡里有可用画布", canvas != null)
	var creative = level.get_node_or_null("Creative")
	check("关卡里有 Creative", creative != null)
	if canvas == null or creative == null:
		_finish()
		return

	# ---- 2. 夹具：黑条 + 齿轮（保持未固化）----
	var surface = canvas.surface
	surface.ink_free = true
	surface.clear()
	for x in range(32, 88):
		for y in range(60, 68):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	canvas.set_map_editor_mode(true)
	var tool = surface.gear_tool
	tool.begin(Vector2(60, 64), 8)
	tool.finish(Vector2(88, 64))
	check("齿轮落笔只写墨水", bearings(level).is_empty() and surface.gear_centers.size() == 1)

	# ---- 3. 蓝图：采集 → 放置 → 撤销 → 重做（固化之前）----
	var rect := Rect2i(24, 28, 80, 72)
	var data: Dictionary = Codec.capture(canvas, rect)
	check("蓝图采集成功", not data.has("error"))
	if data.has("error"):
		print("[Baseline]   capture error: ", data.error)
	check("蓝图里有像素", data.get("pixels", []).size() > 0)
	var pixels_before: PackedByteArray = surface.black_image.get_data()
	var centers_before: int = surface.gear_centers.size()
	# place() 返回错误字符串，空串才算成功。
	var place_error: String = Codec.place(canvas, data, Vector2i(120, 0))
	check("蓝图放置成功", place_error.is_empty())
	if not place_error.is_empty():
		print("[Baseline]   place error: ", place_error)
	var pixels_placed: PackedByteArray = surface.black_image.get_data()
	check("放置写入了像素", pixels_placed != pixels_before)
	check("放置登记了新轴心", surface.gear_centers.size() == centers_before + 1)
	surface.undo_last_edit()
	check("撤销复原像素", surface.black_image.get_data() == pixels_before)
	check("撤销复原轴心", surface.gear_centers.size() == centers_before)
	surface.redo_last_edit()
	check("重做再次写入像素", surface.black_image.get_data() == pixels_placed)

	# ---- 4. 固化 → 两套装置 ----
	canvas.generate(false)
	var axles := bearings(level)
	check("固化生成两个轴承", axles.size() == 2)
	check("轴承关节全部有效", not axles.is_empty() \
		and axles.all(func(a): return a.joint != null and a.joint.is_active()))
	check("轴承轮体锚点完整", not axles.is_empty() \
		and axles.all(func(a): return not a.yellow_anchor.is_empty()))

	# ---- 5. 导出 → 重进 → 结构一致 ----
	var export_error: Error = creative.export_map_to(EXPORT, false)
	check("导出到临时副本", export_error == OK)
	var packed = load(EXPORT)
	check("临时副本可加载", packed is PackedScene)
	if packed is PackedScene:
		var holder := Node.new()
		root.add_child(holder)
		var restored = packed.instantiate()
		holder.add_child(restored)
		for frame in 6:
			await physics_frame
		var restored_axles := bearings(restored)
		check("重进后轴承数量一致", restored_axles.size() == axles.size())
		check("重进后关节都有效", not restored_axles.is_empty() \
			and restored_axles.all(func(a): return a.joint != null and a.joint.is_active()))
		holder.queue_free()
		await process_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EXPORT))

	_finish()


func _finish() -> void:
	print("[Baseline] %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)


## 关卡里带 `surface` 且能固化的那个节点就是画布。
func _find_canvas(level: Node) -> Node:
	for node in level.find_children("*", "", true, false):
		if node.get("surface") != null and node.has_method("generate") and node.has_method("set_map_editor_mode"):
			return node
	return null


func bearings(host: Node) -> Array:
	return host.find_children("*", "", true, false).filter(
		func(node): return node is Axle and not node.is_queued_for_deletion())
