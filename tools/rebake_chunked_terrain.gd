extends SceneTree
## 把已烘好的关卡里的固化地形按当前 BLOCK_SIZE 重切一遍：墨化 -> 固化 -> 另存。
##
## 只回收"静态、非生物、非怪物、完全落在画布内"的墨水刚体 —— 玩家的手、怪物骨骼和
## 动态墨水道具的位置/旋转不在像素网格上，经画布往返会被吸附到网格并丢掉旋转。
## 画布、怪物、黄色机构、文本、出生点等节点一律不动，所以关卡内容只有地形被重新分块。
##
## 用法（干跑只打印结构与像素账，--save 才写回关卡文件）：
##   --headless --path <repo> --script res://tools/rebake_chunked_terrain.gd -- <level.tscn> [--save]

const PixelBody2D := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("rebake: 需要关卡路径")
		quit(2)
		return
	var path: String = args[0]
	var save := args.has("--save")
	var app: Node = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	await process_frame
	var packed := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null:
		push_error("rebake: 无法加载 %s" % path)
		quit(3)
		return
	var level: Node = await app.load_level(packed)
	app._set_screen(load("res://ui/game_ui.tscn").instantiate())
	await process_frame
	await physics_frame

	var creative: Node = level.get_node("Creative")
	var canvas: Node = level.get_node("MapCanvas")
	var solid: Node = canvas.get_node("CanvasSolid")
	var surface: Node = canvas.get_node("CanvasSurface")
	creative._skip_restore_on_enter = true      # 编辑态进入时不要重载磁盘上的关卡
	_report(level, "before: " + path)

	var canvas_rect := Rect2(surface.global_position, Vector2(surface.canvas_size))
	var targets: Array = []
	var kept: Array = []
	var overflows: Array = []
	for child in level.get_children():
		if not child is PixelBody2D:
			continue
		var body = child.get("body")
		if body == null or not body.is_static:
			continue
		if body.tags.has("living") or body.tags.has("map_monster"):
			continue
		# 固化只能靠钉子像素重建静态体：没有锚点的静态体（编辑期裂出来的一次性像素）
		# 再固化一次会变成会掉下来的动态体，所以原样留着。
		if not body.tags.has("static_anchor_points"):
			kept.append(child.name)
			continue
		if not canvas_rect.encloses(body.aabb):
			overflows.append(child.name)
			continue
		targets.append(child)
	if not kept.is_empty():
		print("REBAKE keep anchor-less static bodies=%s" % str(kept))
	if not overflows.is_empty():
		push_error("rebake: 这些地形的包围盒超出画布，回收会丢像素，已中止: %s" % str(overflows))
		quit(4)
		return

	# 回收：像素原样回画布（不产生计划、不摘像素，整块刚体随后直接删掉）。
	var recycled := 0
	var started := Time.get_ticks_usec()
	for node in targets:
		var body = node.get("body")
		recycled += solid._sample_body(surface, body, {}, false, false)
		solid._remove_all_nails(level, body)
		level.remove_body_node(node)
		if is_instance_valid(node):
			level.remove_child(node)
			node.free()
	surface.refresh()
	print("REBAKE recycle bodies=%d pixels=%d (%.1f ms)" % [
		targets.size(), recycled, float(Time.get_ticks_usec() - started) / 1000.0])
	print("REBAKE canvas ledger=%d px by material=%s" % [
		_ledger_total(surface), str(surface.ink_px_by_material)])

	started = Time.get_ticks_usec()
	canvas.generate(false)
	print("REBAKE solidify %.1f ms" % (float(Time.get_ticks_usec() - started) / 1000.0))
	_report(level, "after")

	if not save:
		print("REBAKE dry run: 未写盘（加 --save 才另存）")
		quit(0)
		return
	# 关卡的 map_path 是编辑器状态，不是本次烘焙的产物：保留文件里的原值。
	var text := FileAccess.get_file_as_string(path)
	creative.map_path = _property_in_creative(text, "map_path")
	creative.baked_map_path = _property_in_creative(text, "baked_map_path")
	var error: Error = creative.export_map_to(path)
	print("REBAKE save %s -> %d" % [path, error])
	quit(0 if error == OK else 5)


## 统计形状、像素、块、矩形与 **Rapier 碰撞体数**。
## 碰撞体数与矩形数不是一回事：矩形数 <= poly_max_rects 的刚体走凸多边形拟合，
## 碰撞体是拟合出来的多边形（要问物理要，见 PWorld.fetch_polys），超过预算才逐矩形。
func _report(level: Node, label: String) -> void:
	var physics = level.world
	var bodies: Array = physics.bodies
	var static_bodies := 0
	var shapes := 0
	var pixels := 0
	var chunks := 0
	var rects := 0
	var colliders := 0
	var poly_bodies := 0
	var ink_nodes := 0
	for i in bodies.size():
		var body = bodies[i]
		static_bodies += 1 if body.is_static else 0
		rects += body.rects.size()
		if physics.poly_colliders and body.rects.size() <= physics.poly_max_rects:
			colliders += physics.fetch_polys(body).size()
			poly_bodies += 1
		else:
			colliders += body.rects.size()
		for shape in body.shapes:
			shapes += 1
			pixels += shape.pixel_count()
			chunks += shape.chunks.size()
	for child in level.get_children():
		if child is PixelBody2D and child.get("body") != null and child.get("body").is_static:
			ink_nodes += 1
	print("REBAKE %s bodies=%d static=%d static_nodes=%d shapes=%d pixels=%d chunks=%d rects=%d colliders=%d poly_bodies=%d" % [
		label, bodies.size(), static_bodies, ink_nodes, shapes, pixels, chunks, rects, colliders, poly_bodies])


func _ledger_total(surface: Node) -> int:
	var total := 0
	for material: int in surface.ink_px_by_material:
		total += int(surface.ink_px_by_material[material])
	return total


## 从 .tscn 文本里取 Creative 节点块内的属性值（没有就返回原样）。
func _property_in_creative(text: String, property: String) -> String:
	var lines := text.split("\n")
	var inside := false
	for line in lines:
		if line.begins_with("[node "):
			inside = line.begins_with("[node name=\"Creative\"")
			continue
		if inside and line.begins_with(property + " = "):
			return line.trim_prefix(property + " = ").strip_edges().trim_prefix("\"").trim_suffix("\"")
	return ""
