extends SceneTree
## 临时探针：分级测量切关耗时（线程加载 / 实例化 / 入树 _ready），避免一次卡死。
## 用法：--script 本文件 -- 1   只测线程加载+实例化
##        --script 本文件 -- 2   额外测 add_child（会跑关卡 _ready）

const BodyNode := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")

const PATHS := [
	"res://map/asset/imported/扉页.tscn",
	"res://map/asset/imported/第一页.tscn",
	"res://map/asset/imported/第三页.tscn",
	"res://map/asset/imported/第二页.tscn",
	"res://map/asset/imported/peak.tscn",
]
var _stage := 1


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_stage = int(args[0])
	_run.call_deferred()


func _run() -> void:
	var paths: Array = PATHS if _stage < 2 else ["res://map/asset/imported/第二页.tscn"]
	if _stage == 3:
		for path in paths:
			var packed := load(path) as PackedScene
			var level := packed.instantiate()
			var t := Time.get_ticks_usec()
			level.rebuild()
			print("%-10s bare rebuild=%.1fms bodies=%d" % [path.get_file(),
				(Time.get_ticks_usec() - t) / 1000.0, level.world.bodies.size()])
			level.free()
		quit(0)
		return
	if _stage == 4:
		# 单个刚体的真实烘焙耗时：先摘出刚体建空世界，再逐个放回并计时。
		for path in paths:
			var packed := load(path) as PackedScene
			var level := packed.instantiate()
			var staged: Array = []
			for node in level.get_children():
				if node is BodyNode:
					level.remove_child(node)
					staged.append(node)
			var t0 := Time.get_ticks_usec()
			level.rebuild()
			var empty_ms := (Time.get_ticks_usec() - t0) / 1000.0
			var slowest := 0.0
			var slowest_name := ""
			var total := 0.0
			for node in staged:
				level.add_child(node)
				var t := Time.get_ticks_usec()
				level.bake_node(node)
				var ms := (Time.get_ticks_usec() - t) / 1000.0
				total += ms
				if ms > slowest:
					slowest = ms
					slowest_name = str(node.name)
			print("%-10s empty_world=%.1fms  staged=%d  slowest=%.1fms (%s)  sum=%.1fms" % [
				path.get_file(), empty_ms, staged.size(), slowest, slowest_name, total])
			level.free()
		quit(0)
		return
	for path in paths:
		if not ResourceLoader.exists(path, "PackedScene"):
			continue
		var start := Time.get_ticks_usec()
		var err := ResourceLoader.load_threaded_request(path, "PackedScene", false)
		if err != OK:
			print("%s REQUEST FAILED %d" % [path.get_file(), err])
			continue
		var status := ResourceLoader.load_threaded_get_status(path)
		while status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			await process_frame
			status = ResourceLoader.load_threaded_get_status(path)
		var loaded_ms := (Time.get_ticks_usec() - start) / 1000.0
		var t0 := Time.get_ticks_usec()
		var scene := ResourceLoader.load_threaded_get(path) as PackedScene
		var get_ms := (Time.get_ticks_usec() - t0) / 1000.0
		if scene == null:
			print("%s LOAD NULL" % path.get_file())
			continue
		t0 = Time.get_ticks_usec()
		var level := scene.instantiate()
		var inst_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var nodes := _count(level)
		if _stage < 2:
			print("%-10s threaded=%.1fms get=%.1fms instantiate=%.1fms nodes=%d" % [
				path.get_file(), loaded_ms, get_ms, inst_ms, nodes])
			level.free()
			continue
		t0 = Time.get_ticks_usec()
		root.add_child(level)
		var ready_ms := (Time.get_ticks_usec() - t0) / 1000.0
		print("%-10s threaded=%.1fms get=%.1fms instantiate=%.1fms add_child=%.1fms nodes=%d" % [
			path.get_file(), loaded_ms, get_ms, inst_ms, ready_ms, nodes])
		quit(0)
		return
	quit(0)


func _count(node: Node) -> int:
	var total := 1
	for child in node.get_children():
		total += _count(child)
	return total
