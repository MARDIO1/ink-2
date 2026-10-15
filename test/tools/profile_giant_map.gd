extends SceneTree

## 扉页巨型地图刚体基准：同一份场景分别移除地图、保留真实地图、替换为单个巨型矩形。
## 用法还支持 empty_dynamic / real_dynamic：64 个动态探针穿过同一地图范围。
## real10 把真实地图刚体复制为 10 组，用于测当前关卡常驻 10 倍扉页的下界。

const TITLE_SCENE := "res://map/asset/imported/扉页.tscn"
const PixelBody2D := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const PixelShape2D := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const GIANT_SIZE := Vector2i(2852, 1328)
const WARMUP_FRAMES := 120
const SAMPLE_FRAMES := 300


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var scenario := args[0] if not args.is_empty() else "real"
	if scenario not in ["empty", "real", "real10", "solid", "full_empty", "full_real", "empty_dynamic", "real_dynamic"]:
		push_error("profile_giant_map: scenario 不受支持")
		quit(2)
		return

	var memory_before := OS.get_static_memory_usage()
	var started := Time.get_ticks_usec()
	var packed := ResourceLoader.load(TITLE_SCENE, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var load_us := Time.get_ticks_usec() - started
	if packed == null:
		push_error("profile_giant_map: 无法加载扉页")
		quit(3)
		return

	started = Time.get_ticks_usec()
	var level := packed.instantiate()
	var instantiate_us := Time.get_ticks_usec() - started
	if scenario == "real10":
		_append_real_copies(level, packed, 9)
	packed = null

	started = Time.get_ticks_usec()
	_prepare_copy(level, scenario)
	var prepare_us := Time.get_ticks_usec() - started
	var memory_before_tree := OS.get_static_memory_usage()

	started = Time.get_ticks_usec()
	root.add_child(level)
	var enter_tree_us := Time.get_ticks_usec() - started
	if not scenario.ends_with("_dynamic"):
		_freeze_dynamic_bodies(level)
	var memory_after_tree := OS.get_static_memory_usage()

	# 等延迟创建的渲染器、钉子等初始化完成，再开始稳定帧预热。
	await process_frame
	await process_frame
	var first_frames_memory := OS.get_static_memory_usage()
	var world_stats := _world_stats(level)

	for _frame in WARMUP_FRAMES:
		await physics_frame

	var physics_ms: Array[float] = []
	var process_ms: Array[float] = []
	var sample_started := Time.get_ticks_usec()
	for _frame in SAMPLE_FRAMES:
		await physics_frame
		physics_ms.append(float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)
		process_ms.append(float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0)
	var sample_us := Time.get_ticks_usec() - sample_started

	var result := {
		"scenario": scenario,
		"giant_size": [GIANT_SIZE.x, GIANT_SIZE.y],
		"warmup_frames": WARMUP_FRAMES,
		"sample_frames": SAMPLE_FRAMES,
		"load_ms": float(load_us) / 1000.0,
		"instantiate_ms": float(instantiate_us) / 1000.0,
		"prepare_ms": float(prepare_us) / 1000.0,
		"enter_tree_ms": float(enter_tree_us) / 1000.0,
		"sample_wall_ms": float(sample_us) / 1000.0,
		"physics_ms": _summarize(physics_ms),
		"process_ms": _summarize(process_ms),
		"memory_mib": {
			"before": _mib(memory_before),
			"before_tree": _mib(memory_before_tree),
			"after_tree": _mib(memory_after_tree),
			"after_first_frames": _mib(first_frames_memory),
			"tree_delta": _mib(memory_after_tree - memory_before_tree),
			"static_peak": _mib(OS.get_static_memory_peak_usage()),
		},
		"world": world_stats,
	}
	print("GIANT_MAP_PROFILE " + JSON.stringify(result))
	root.remove_child(level)
	level.free()
	level = null
	# 给 RefCounted/渲染资源一次完整回收机会，避免基准退出噪声被误判成项目泄漏。
	await process_frame
	await process_frame
	quit(0)


func _prepare_copy(level: Node, scenario: String) -> void:
	if scenario.begins_with("full_"):
		if scenario == "full_empty":
			_remove_map_bodies(level)
		return

	var keep_real := scenario in ["real", "real10", "real_dynamic"]
	# 只留下 PixelWorld 根和待测地图刚体，排除玩家、画布、UI、规则等噪声。
	for child in level.get_children():
		var keep_real_body := keep_real and child.is_in_group(&"ink_item")
		if keep_real_body:
			continue
		level.remove_child(child)
		child.free()

	if scenario.ends_with("_dynamic"):
		_add_dynamic_probes(level)
		return
	if scenario != "solid":
		return
	var body := PixelBody2D.new()
	body.name = "BenchmarkGiantStaticBody"
	body.is_static = true
	var shape := PixelShape2D.new()
	shape.name = "Shape"
	shape.rect_size = GIANT_SIZE
	body.add_child(shape)
	level.add_child(body)


func _append_real_copies(level: Node, packed: PackedScene, count: int) -> void:
	for copy_index in count:
		var copy := packed.instantiate()
		var offset := Vector2(float(copy_index + 1) * float(GIANT_SIZE.x + 256), 0.0)
		for child in copy.get_children():
			if not child.is_in_group(&"ink_item"):
				continue
			copy.remove_child(child)
			_clear_owner_recursive(child)
			child.position += offset
			level.add_child(child)
		copy.free()


func _clear_owner_recursive(node: Node) -> void:
	node.owner = null
	for child in node.get_children():
		_clear_owner_recursive(child)


func _add_dynamic_probes(level: Node) -> void:
	for row in 8:
		for column in 8:
			var body := PixelBody2D.new()
			body.name = "Probe_%d_%d" % [column, row]
			body.position = Vector2(-360.0 + float(column) * 350.0, 240.0 - float(row) * 26.0)
			var shape := PixelShape2D.new()
			shape.name = "Shape"
			shape.rect_size = Vector2i(16, 16)
			body.add_child(shape)
			level.add_child(body)


func _remove_map_bodies(level: Node) -> void:
	for child in level.get_children():
		if not child.is_in_group(&"ink_item"):
			continue
		level.remove_child(child)
		child.free()


func _freeze_dynamic_bodies(level: Node) -> void:
	if level.get("world") == null:
		return
	for body in level.world.bodies:
		if not body.is_static:
			body.frozen = true


func _world_stats(level: Node) -> Dictionary:
	var bodies := 0
	var static_bodies := 0
	var shapes := 0
	var chunks := 0
	var pixels := 0
	var rects := 0
	if level.get("world") == null:
		return {}
	for body in level.world.bodies:
		bodies += 1
		static_bodies += 1 if body.is_static else 0
		rects += body.rects.size()
		for shape in body.shapes:
			shapes += 1
			chunks += shape.chunks.size()
			pixels += shape.pixel_count()
	return {
		"bodies": bodies,
		"static_bodies": static_bodies,
		"shapes": shapes,
		"chunks": chunks,
		"pixels": pixels,
		"rects": rects,
	}


func _summarize(values: Array[float]) -> Dictionary:
	if values.is_empty():
		return {}
	values.sort()
	var total := 0.0
	for value in values:
		total += value
	return {
		"average": total / float(values.size()),
		"p50": values[int(floor(float(values.size() - 1) * 0.50))],
		"p95": values[int(floor(float(values.size() - 1) * 0.95))],
		"maximum": values[-1],
	}


func _mib(bytes: int) -> float:
	return float(bytes) / 1048576.0
