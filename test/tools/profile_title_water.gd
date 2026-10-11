extends SceneTree
## 标题水面性能探针：godot --path . --script res://test/tools/profile_title_water.gd -- <场景> <模式>
## 模式：full = 原样；novp = 释放两张 SubViewport；nomat = 摘掉标题材质；notitle = 两个都去掉
var _frame_count := 0
var _scene_path := "res://ui/menu/title_fx/title_water_demo.tscn"
var _mode := "full"


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_scene_path = args[0]
	if args.size() > 1:
		_mode = args[1]
	var packed: PackedScene = load(_scene_path)
	var scene: Node = packed.instantiate()
	root.add_child(scene)
	if _mode != "full":
		var vps: Array = []
		var title: TextureRect = null
		for c in scene.get_children():
			if c is SubViewport:
				vps.append(c)
			elif c is TextureRect and title == null and (c as TextureRect).material != null:
				title = c
		if _mode == "novp" or _mode == "notitle":
			for v in vps:
				v.queue_free()
		if (_mode == "nomat" or _mode == "notitle") and title != null:
			title.material = null
	print("PERF scene=%s mode=%s" % [_scene_path, _mode])


func _process(_delta: float) -> bool:
	_frame_count += 1
	if _frame_count == 420:
		var fps := Engine.get_frames_per_second()
		print("PERF fps = %.1f   frame = %.2f ms   draws = %d" % [
			fps, 1000.0 / maxf(fps, 1.0),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		])
		quit(0)
		return true
	return false
