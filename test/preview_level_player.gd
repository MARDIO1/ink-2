extends SceneTree
## 临时预览：走真实路由进指定关卡，截图玩家所在位置，用于对比加载方式改动前后的画面。

const LEVEL := "res://map/asset/imported/第三页.tscn"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.size = Vector2i(960, 540)
	root.content_scale_size = root.size
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	await process_frame
	app._transition.duration = 0.01
	await app.request_level_change(LEVEL)
	for frame in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	image.save_png("res://.codex-tmp/level_player.png")
	var level = app.level_root.get_child(0)
	print("SAVED bodies=%d player=%s" % [
		level.world.bodies.size() if level.get("world") != null else -1,
		str(level.get_node_or_null("Player") != null)])
	quit(0)
