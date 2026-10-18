extends SceneTree
## 定位"有齿轮的关卡在游玩模式特别卡"的耗时来源。
## 用法: --headless --script res://test/tools/bench_gear_physics.gd -- <场景路径> [帧数]

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var scene_path := args[0] if args.size() > 0 else "res://map/asset/imported/第三页.tscn"
	var frames := int(args[1]) if args.size() > 1 else 120
	print("[bench] scene=", scene_path, " frames=", frames)
	var packed = load(scene_path)
	if packed == null:
		print("[bench] 场景加载失败")
		quit(1)
		return
	var level = packed.instantiate()
	root.add_child(level)
	current_scene = level
	for i in 30:
		await physics_frame
	var physics = level.get("world")          # pworld（RefCounted），真实刚体在这里
	var bodies: int = physics.bodies.size() if physics != null and "bodies" in physics else -1
	print("[bench] children=", level.get_child_count(), " bodies=", bodies)
	var rule = _find_blue_rule(level)
	if rule == null:
		print("[bench] 未找到 BlueInk 规则（场景里没有蓝墨模块）")
		quit(1)
		return
	rule.set_profile_enabled(true)
	var flow = rule.flow
	flow.stats.clear()
	rule._profile.clear()
	var started := Time.get_ticks_usec()
	var worst := 0
	for i in frames:
		var frame_start := Time.get_ticks_usec()
		await physics_frame
		worst = maxi(worst, Time.get_ticks_usec() - frame_start)
	var elapsed := Time.get_ticks_usec() - started
	print("[bench] avg_ms=%.2f worst_ms=%.2f calls=%d active_cells=%d" % [
		elapsed / 1000.0 / frames, worst / 1000.0,
		int(rule._profile.get("calls", 0)), int(rule._profile.get("active_cells", 0))])
	print("[bench] resolve_us=%d (per call %.2f ms)" % [
		int(rule._profile.get("resolve_us", 0)),
		float(rule._profile.get("resolve_us", 0)) / maxf(1.0, float(rule._profile.get("calls", 1))) / 1000.0])
	for key in ["stamp_us", "consumers_us", "bridges_us", "bridge_rebuilds", "bridge_cells", "bridge_scan_us", "bridge_nearest_us", "bridge_entry_us", "bridge_grid_us", "bridge_entry_count", "bridge_loop_us", "contacts_us", "emit_us", "advance_us", "decode_us", "display_us", "kernel_us"]:
		print("[bench]   %-12s %8.2f ms" % [key, float(flow.stats.get(key, 0)) / 1000.0])
	var counts := {"wire": 0, "motor": 0, "hinge": 0, "axle": 0, "rail": 0, "pin": 0, "body": 0}
	for child in level.get_children():
		var script_path := ""
		if child.get_script() != null:
			script_path = str(child.get_script().resource_path)
		if script_path.ends_with("wire_layer.gd"):
			counts.wire += 1
		elif script_path.ends_with("motor.gd"):
			counts.motor += 1
		elif script_path.ends_with("axle.gd"):
			counts.axle += 1
		elif script_path.ends_with("hinge.gd"):
			counts.hinge += 1
		elif script_path.ends_with("rail.gd"):
			counts.rail += 1
		elif script_path.ends_with("slider_pin.gd"):
			counts.pin += 1
	print("[bench] counts=", counts)
	level.queue_free()
	await process_frame
	quit(0)


func _find_blue_rule(node) -> Node:
	if node.get_script() != null and str(node.get_script().resource_path).ends_with("blue_ink.gd"):
		return node
	for child in node.get_children():
		var found = _find_blue_rule(child)
		if found != null:
			return found
	return null
