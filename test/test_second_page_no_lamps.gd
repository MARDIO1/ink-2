extends SceneTree

const Machine := preload("res://map/src/ink_machine_checkpoint.gd")
const Gear := preload("res://actor/canvas/src/gear_bearing.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[SecondPage] %s %s" % ["PASS" if okay else "FAIL", label])

func _run() -> void:
	var app = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	await process_frame
	check("second page loads", await app.request_level_change("res://map/asset/imported/第二页.tscn"))
	var level = app.level_root.get_child(0)
	level.auto_step = false
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	check("no lamp controllers remain", not level.get_children().any(func(n): return n is Machine))
	var notes := ""
	for label in level.get_node("MapTexts").get_children():
		notes += label.text
	check("station and lamp hints removed", not notes.contains("灯") and not notes.contains("传动站") and not notes.contains("配重站"))
	check("terrain and edited gear retained", level.world.bodies.size() > 60
		and level.get_children().any(func(n): return n is Gear))
	var portal = level.get_node("PageExit")
	check("exit has no machine requirements", portal.machine_paths.is_empty())
	check("exit still points to third page", portal.target_map == "res://map/asset/imported/第三页.tscn")
	portal._activate()
	# 出口所在旧关卡会在切换时释放；通过持久 Root 等待结果。
	var deadline := Time.get_ticks_msec() + 45000
	while Time.get_ticks_msec() < deadline:
		if not app._loading_level and app.level_root.get_child(0).name == "第三页":
			break
		await process_frame
	check("exit actually enters third page without lighting lamps", app.level_root.get_child(0).name == "第三页")
	app.queue_free()
	await process_frame
	await process_frame
	print("[SecondPage] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
