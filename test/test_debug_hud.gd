extends SceneTree

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(title: String, condition: bool) -> void:
	print("%s %s" % ["PASS" if condition else "FAIL", title])
	if not condition:
		failures += 1


func _run() -> void:
	var scene := preload("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var hud = scene.get_node("debugHUD")
	hud.hang_frames = 2
	hud.hang_auto_quit = false
	hud.hang_report_cooldown = 10.0
	_check("first long frame only arms hang detector", not hud._watch_hang(1_000_000, 600_000))
	_check("second long frame records without quitting", not hud._watch_hang(1_600_000, 600_000))
	_check("hang report starts a cooldown", hud.hang_report_cooldown_until > 1_600_000)
	print("[DebugHUD] %d failures" % failures)
	quit(1 if failures else 0)
