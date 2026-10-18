extends SceneTree
## 切关卡顿验收：走真实 root 路由切到最大的地图，统计单帧最长耗时。
## 优化前：`PixelWorld.rebuild()` 一次烘焙 3.1 s，表现为一帧 3000+ ms。

const LEVEL := "res://map/asset/imported/第三页.tscn"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(960, 540)
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	await process_frame
	app._transition.duration = 0.01
	var start := Time.get_ticks_usec()
	var last := start
	var worst := 0
	var worst_at := 0.0
	var frames := 0
	var done := [false]
	var spikes: Array = []
	_switch(app, done)
	while not done[0]:
		await process_frame
		var now := Time.get_ticks_usec()
		var delta_ms := (now - last) / 1000.0
		last = now
		frames += 1
		if delta_ms > 60.0:
			spikes.append([delta_ms, (now - start) / 1000000.0])
		if delta_ms > worst:
			worst = delta_ms
			worst_at = (now - start) / 1000000.0
	var total_ms := (Time.get_ticks_usec() - start) / 1000.0
	var level = app.level_root.get_child(0) if app.level_root.get_child_count() > 0 else null
	print("SWITCH total=%.0fms frames=%d worst_frame=%.1fms at=%.2fs bodies=%d" % [
		total_ms, frames, worst, worst_at,
		level.world.bodies.size() if level != null and level.get("world") != null else -1])
	spikes.sort_custom(func(a, b): return a[0] > b[0])
	for index in mini(8, spikes.size()):
		print("  spike %.0fms @%.2fs" % [spikes[index][0], spikes[index][1]])
	quit(0)


func _switch(app, done: Array) -> void:
	await app.request_level_change(LEVEL)
	done[0] = true
