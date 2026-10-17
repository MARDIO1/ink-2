extends SceneTree

const Levels := preload("res://ui/level_select/src/level_select.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[MapSequence] %s %s" % ["PASS" if okay else "FAIL", label])

func _wait_for_route(app: Node, destination: String) -> bool:
	for frame in 1800:
		await process_frame
		if app.level_root.get_child_count() == 1:
			var level: Node = app.level_root.get_child(0)
			if level.scene_file_path == destination and not app._loading_level and not app._transition.busy:
				level.auto_step = false
				return true
	return false

func _run() -> void:
	var paths := Levels.find_levels()
	# 正式页按阅读顺序排在前面，其余 res://map 下带 Player 的关卡跟在后面。
	var ordered := paths.size() >= Levels.LEVEL_PATHS.size()
	for index in Levels.LEVEL_PATHS.size():
		ordered = ordered and paths[index] == Levels.LEVEL_PATHS[index]
	check("official pages keep requested order at the front", ordered)
	check("blank template never lists as a level", not paths.has(Levels.BLANK_TEMPLATE))
	check("third page cannot auto-route to Peak", Levels.next_level(Levels.LEVEL_PATHS[3]).is_empty())
	check("Peak has no automatic destination", Levels.next_level(Levels.LEVEL_PATHS[4]).is_empty())
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	current_scene = app
	app._transition.duration = 0.01
	check("replacement title loads through real router", await app.request_level_change(paths[0]))
	for index in 3:
		var level: Node = app.level_root.get_child(0)
		level.auto_step = false
		var creative = level.get_node("Creative")
		creative.auto_save_edits = false
		creative.auto_save_on_exit = false
		check("editor save path matches " + paths[index].get_file(), creative.map_path == paths[index])
		var portals := level.find_children("*", "Node2D", true, false).filter(func(node): return node.has_method("resolve_destination"))
		check("one forward portal in " + paths[index].get_file(), portals.size() == 1)
		if portals.size() != 1:
			break
		var portal = portals[0]
		portal.set_physics_process(false)
		check("explicit destination follows page order", portal.target_map == paths[index + 1] and portal.resolve_destination() == paths[index + 1])
		# 本用例验证地图路线；机关物理通关条件由 test_ink_machine_pages 验证。
		for machine in level.find_children("*", "Node2D", true, false):
			if machine.get_script() != null and machine.get_script().resource_path == "res://map/src/ink_machine_checkpoint.gd":
				machine.completed = true
		portal._activate()
		check("actual portal transition reaches " + paths[index + 1].get_file(), await _wait_for_route(app, paths[index + 1]))
	var last: Node = app.level_root.get_child(0)
	check("route ends on third page", last.scene_file_path == paths[3])
	var exit_portal = last.get_node("PageExit")
	check("third page exit returns to directory", exit_portal.final_page)
	for machine in last.find_children("*", "Node2D", true, false):
		if machine.get_script() != null and machine.get_script().resource_path == "res://map/src/ink_machine_checkpoint.gd":
			machine.completed = true
	exit_portal._activate()
	for frame in 1800:
		await process_frame
		if not app._transition.busy and app.level_root.get_child_count() == 0:
			break
	check("third-page completion never enters Peak", app.level_root.get_child_count() == 0
		and app.ui_root.get_child(0).has_method("show_load_failed"))
	check("Peak can be loaded independently", await app.request_level_change(paths[4]))
	var peak: Node = app.level_root.get_child(0)
	peak.auto_step = false
	var peak_portals := peak.find_children("*", "Node2D", true, false).filter(func(node): return node.has_method("resolve_destination"))
	check("Peak contains no inter-level portals", peak_portals.is_empty())
	check("Peak saves to its own scene", peak.get_node("Creative").map_path == paths[4])
	app.queue_free()
	await process_frame
	print("[MapSequence] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
