extends SceneTree
## 编辑器回归基线：真实 Root 路由加载 → 蓝图采集/放置/撤销/重做 → 固化 → 导出/重进结构对比。
##
## 只读现有地图，只写 `user://` 临时副本；不覆盖任何地图、快照或蓝图。
## 任何"拆 creative / 拆 canvas / 动保存或蓝图"的提交，先跑这个脚本。
##
## 用法：
##   --script res://test/tools/baseline_editor.gd                 完整跑（约 7 秒）
##   --script res://test/tools/baseline_editor.gd -- --no-export  跳过导出/重进（约 5 秒，改逻辑时用）
##
## ⚠️ 契约（dbd7b45 起）：齿轮轴承只由**显式动作**产生（这里直接调 `GearBearings.install`），
##    固化不会再从 `gear_centers` 补轴承；`gear_centers` 的每一项是字典，用 `GearCenters.position_of` 取坐标。
##
## ⚠️ 顺序约束：`generate()`（固化）会把画布像素转成刚体**并清空画布**，
##    所以蓝图的采集/放置/撤销必须做在固化**之前**，否则采到的像素是 0。

const LEVEL := "res://test/fixtures/maps/base_level.tscn"
const EXPORT := "user://baseline_export.tscn"
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Place := preload("res://blueprint/src/blueprint_place.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const GearBearings := preload("res://actor/canvas/src/gear_bearings.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")

var checks := 0
var failures := 0
var skip_export := false
var _phase_start := 0


func _initialize() -> void:
	skip_export = OS.get_cmdline_user_args().has("--no-export")
	run.call_deferred()


func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[Baseline] %s %s" % ["PASS" if ok else "FAIL", label])


func phase(name: String) -> void:
	var now := Time.get_ticks_msec()
	if _phase_start > 0:
		print("[Baseline]   (%s: %d ms)" % [name, now - _phase_start])
	_phase_start = now


func run() -> void:
	root.size = Vector2i(960, 540)
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	await process_frame
	app._transition.duration = 0.05

	# ---- 1. 真实路由加载 ----
	phase("启动")
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
	# 基线只读地图：关掉自动保存与快照，避免把测试画的东西写回真地图。
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	creative.edit_snapshot_path = ""
	phase("加载")

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
	# 齿轮现在是一整块同色墨水：中心不再有黄色轴点。
	check("齿轮中心是纯墨水", surface.material_at(60, 64) == Palette.BLACK.id
		and surface.material_at(60, 64) != Palette.YELLOW.id)
	check("工具栏没有外层底板", canvas.workbench.get_node_or_null("ToolbarPlate") == null)
	# 新规则（dbd7b45）：齿轮工具**绝不**创建轴承。轴承来自显式动作——
	# 黄墨点按（rod_layer.place_anchor → GearBearings.install）或蓝图里的草稿记录。
	var record: Dictionary = surface.gear_centers[0]
	var center_point: Vector2 = GearCenters.position_of(record)
	var target: Dictionary = GearBearings.resolve_target(surface, center_point)
	check("解析出可安装的轴心", not target.is_empty() and not target.has("error"))
	if target.has("error"):
		print("[Baseline]   resolve error: ", target.error)
	check("显式安装轴承", GearBearings.install(surface, target))
	check("轴心记进草稿", surface.draft_bearings.size() == 1)
	phase("落笔")

	# ---- 3. 蓝图：采集 → 放置 → 撤销 → 重做（固化之前）----
	var rect := Rect2i(24, 28, 80, 72)
	var data: Dictionary = Codec.capture(canvas, rect)
	check("蓝图采集成功", not data.has("error"))
	if data.has("error"):
		print("[Baseline]   capture error: ", data.error)
	check("蓝图里有像素", data.get("pixels", []).size() > 0)
	check("蓝图带走轴心记录", data.get("draft_bearings", []).size() == 1)
	var pixels_before: PackedByteArray = surface.black_image.get_data()
	var centers_before: int = surface.gear_centers.size()
	# place() 返回错误字符串，空串才算成功。
	var place_error: String = Place.place(canvas, data, Vector2i(120, 0))
	check("蓝图放置成功", place_error.is_empty())
	if not place_error.is_empty():
		print("[Baseline]   place error: ", place_error)
	var pixels_placed: PackedByteArray = surface.black_image.get_data()
	check("放置写入了像素", pixels_placed != pixels_before)
	check("放置登记了新轴心", surface.gear_centers.size() == centers_before + 1)
	check("放置复制了轴心记录", surface.draft_bearings.size() == 2)
	surface.undo_last_edit()
	check("撤销复原像素", surface.black_image.get_data() == pixels_before)
	check("撤销复原轴心", surface.gear_centers.size() == centers_before)
	surface.redo_last_edit()
	check("重做再次写入像素", surface.black_image.get_data() == pixels_placed)
	phase("蓝图事务")

	# ---- 4. 固化 → 两套装置 ----
	canvas.generate(false)
	var axles := bearings(level)
	check("固化生成两个轴承", axles.size() == 2)
	check("轴承关节全部有效", not axles.is_empty() \
		and axles.all(func(a): return a.joint != null and a.joint.is_active()))
	check("轴承轮体锚点完整", not axles.is_empty() \
		and axles.all(func(a): return not a.yellow_anchor.is_empty()))
	# 放置出来的装置必须是独立实例：不能复用原轴承的刚体或关节。
	if axles.size() == 2:
		check("两套轴承是独立实例", axles[0] != axles[1]
			and axles[0].yellow_anchor.body != axles[1].yellow_anchor.body
			and axles[0].joint != axles[1].joint)
	phase("固化")

	# ---- 5. 编辑态：只显示正在编辑的画布工具栏（其它画布不得浮出）----
	creative.active = true
	for frame in 30:
		await physics_frame
	var others: Array = _all_canvases(level).filter(func(item): return item != canvas)
	var main_shown: bool = canvas.buttons.visible and canvas.buttons.modulate.a > 0.9
	var others_hidden := others.all(
		func(item): return not item.buttons.visible or item.buttons.modulate.a < 0.01)
	if not (main_shown and others_hidden):
		print("[Baseline]   main=", main_shown, " others=",
			others.map(func(item): return "%s:%s/%.2f" % [item.name, item.buttons.visible, item.buttons.modulate.a]))
	check("编辑器只显示主画布工具栏", main_shown and others_hidden)
	phase("工具栏可见性")

	# ---- 6. 导出 → 重进 → 结构一致 ----
	if skip_export:
		print("[Baseline]   (--no-export：跳过导出/重进)")
	else:
		var export_error: Error = creative.export_map_to(EXPORT)
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
			if restored_axles.size() == 2:
				check("重进后两套轴承仍相互独立",
					restored_axles[0].yellow_anchor.body != restored_axles[1].yellow_anchor.body
					and restored_axles[0].joint != restored_axles[1].joint)
			holder.queue_free()
			await process_frame
		DirAccess.remove_absolute(ProjectSettings.globalize_path(EXPORT))
		phase("导出重进")

	# ---- 7. 自动保存（把地图路径临时指向 user://，绝不碰真地图）----
	# `dbd7b45` 起自动保存只提交完整文档，不再写 `.edit.snapshot`（避免草稿与场景版本错配）。
	if not skip_export:
		var auto_scene := "user://baseline_auto.tscn"
		creative.map_path = auto_scene
		creative.auto_save_edits = true
		creative.full_auto_save_delay = 0.1
		creative._queue_edit_auto_save()
		for frame in 40:
			await process_frame
		check("自动保存写出了场景",
			FileAccess.file_exists(ProjectSettings.globalize_path(auto_scene)))
		creative.auto_save_edits = false
		DirAccess.remove_absolute(ProjectSettings.globalize_path(auto_scene))
		phase("自动保存")

	# ---- 8. 布局对象：放置 → 删除 → 撤销/重做（P4 门禁）----
	# 注意：不要在这里调 `_configure_history()`，它内部直接 connect 信号，重复调用会报
	# "Signal already connected"。进入编辑器时已经配置过了。
	var points_before: int = creative._respawn_points().size()
	var point: Marker2D = creative.place_respawn_point(Vector2(200, 120))
	check("放置复活点", point != null and creative._respawn_points().size() == points_before + 1)
	check("复活点进入分组", point != null and point.is_in_group(creative.RESPAWN_POINT_GROUP))
	if point != null:
		creative.delete_respawn_point(point)
		check("删除复活点", creative._respawn_points().size() == points_before)
		check("撤销删除恢复复活点",
			creative.undo_last_edit() and creative._respawn_points().size() == points_before + 1)
		check("撤销放置移除复活点",
			creative.undo_last_edit() and creative._respawn_points().size() == points_before)
		check("重做放置恢复复活点",
			creative.redo_last_edit() and creative._respawn_points().size() == points_before + 1)
	# 拖动 → 撤销：拖动态在 layout_tools 里，必须仍然产生一条可撤销的 object_transform。
	var dragged: Marker2D = creative.place_respawn_point(Vector2(210, 130))
	if dragged != null:
		creative._begin_layout_drag(dragged, Vector2(210, 130))
		dragged.global_position = Vector2(260, 130)
		creative._finish_layout_drag()
		check("拖动改变位置", dragged.global_position.is_equal_approx(Vector2(260, 130)))
		check("撤销拖动恢复位置", creative.undo_last_edit() \
			and dragged.global_position.is_equal_approx(Vector2(210, 130)))
	# 模式分发表：左键事件必须被路由到对应处理函数，而不是掉进空分支。
	creative._session.mode = creative.LAYOUT_MODE_PLACE_RESPAWN
	var routed_before: int = creative._respawn_points().size()
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	click.position = Vector2(120, 120)
	click.global_position = Vector2(120, 120)
	creative._handle_layout_mouse_button(click)
	check("模式分发表路由到放置复活点",
		creative._respawn_points().size() == routed_before + 1)
	phase("布局对象")

	# ---- 9. 小怪：放置 → 撤销 → 重做（P5 门禁）----
	var monsters_before: int = creative.monster_count()
	var monster = creative.place_monster(creative.MONSTER_KINDS[0], Vector2(240, 140))
	check("放置小怪", monster != null and creative.monster_count() == monsters_before + 1)
	if monster != null:
		check("小怪有编辑器 id", not str(monster.get("editor_id")).is_empty())
		check("撤销放置移除小怪",
			creative.undo_last_edit() and creative.monster_count() == monsters_before)
		check("重做放置恢复小怪",
			creative.redo_last_edit() and creative.monster_count() == monsters_before + 1)
	phase("小怪")

	_finish()


func _finish() -> void:
	# 无论中途怎么退出，临时副本都不留在用户目录里。
	DirAccess.remove_absolute(ProjectSettings.globalize_path(EXPORT))
	print("[Baseline] %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)


## 优先取名叫 MapCanvas 且可用的那块；没有就退回第一个「激活且可见」的画布。
## 关卡里通常有 MapCanvas 与 SmallCanvas 两块，取错那块会导致放置报"目标画布已失效"。
func _find_canvas(level: Node) -> Node:
	var found := _all_canvases(level)
	var usable := found.filter(func(node): return node.active and node.visible)
	var pool: Array = usable if not usable.is_empty() else found
	for node in pool:
		if node.name == &"MapCanvas":
			return node
	return pool.front() if not pool.is_empty() else null


func _all_canvases(level: Node) -> Array:
	return level.find_children("*", "", true, false).filter(
		func(node): return node.get("surface") != null and node.has_method("generate") \
			and node.has_method("set_map_editor_mode"))


func bearings(host: Node) -> Array:
	return host.find_children("*", "", true, false).filter(
		func(node): return node is Axle and not node.is_queued_for_deletion())
