extends SceneTree
## 性能探针（临时工具，不属于特效本身）。用法：godot --path . --script res://test/_perf.gd -- <场景> <模式>
## 模式：full = 原样；novp = 释放两张 SubViewport；nomat = 摘掉标题材质；notitle = 两个都去掉
var _n := 0
var _target := "res://ui/menu/title_fx/demo.tscn"
var _mode := "full"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_target = args[0]
	if args.size() > 1:
		_mode = args[1]
	var packed: PackedScene = load(_target)
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
	print("PERF scene=%s mode=%s" % [_target, _mode])

func _process(_d: float) -> bool:
	_n += 1
	if _n == 420:
		var fps := Engine.get_frames_per_second()
		print("PERF fps = %.1f   frame = %.2f ms   draws = %d" % [
			fps, 1000.0 / maxf(fps, 1.0),
			Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		])
		quit(0)
		return true
	return false
