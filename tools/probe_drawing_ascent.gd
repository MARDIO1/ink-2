extends "res://tools/build_terrain_pages.gd"
## 实验性无抓握路线探针，不是通过的回归测试：自动输入可能使角色倾倒。
## 临时生成黑墨画作尝试逐层登高；不保存画作，不代替人工完整通关。
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var app: Node = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	root.get_node("SceneTransition").duration = 0.02
	await app.request_level_change("res://map/asset/imported/第三页.tscn")
	level = app.get_node("Level").get_child(0)
	level.get_node("Creative").auto_save_on_exit = false
	level.get_node("Creative").auto_save_edits = false
	var player: Node = level.get_node("Player")
	# 不接受鼠标抓握；角色脚部仍走正式输入与碰撞。
	var hand: Node = player.get_node("Arm/Hand/HandControl")
	var failures := 0
	var runs := [
		[Vector2(500,1495),Vector2(990,1216),Vector2(420,1405),1.0,1100.0,1220.0],
		[Vector2(2250,1215),Vector2(1510,865),Vector2(2290,1125),-1.0,1380.0,870.0],
		[Vector2(250,862),Vector2(890,515),Vector2(210,772),1.0,1020.0,520.0],
		[Vector2(2220,515),Vector2(1460,165),Vector2(2260,425),-1.0,1330.0,170.0]]
	for index in runs.size():
		var run: Array = runs[index]
		var a: Vector2 = run[0]
		var b: Vector2 = run[1]
		var origin := Vector2(minf(a.x,b.x),b.y)-Vector2(8,8)
		var pixels := _image(Vector2i((a-b).abs())+Vector2i(17,17))
		_line(pixels,a-origin,b-origin,8)
		_line(pixels,a-origin,Vector2(b.x,a.y)-origin,8)
		_line(pixels,b-origin,Vector2(b.x,a.y)-origin,8)
		var ramp := _body("TestDrawnRamp",origin,pixels,false)
		var body = ramp.body
		player.teleport_to(run[2],0)
		hand.set_grip(false)
		for frame in 40:
			await physics_frame
		Input.action_press("move_right" if run[3] > 0 else "move_left")
		var reached := false
		for frame in 720:
			hand.set_target_world(player.body.com_world()+Vector2(0,-50))
			if frame == 30:
				Input.action_press("jump")
			elif frame == 31:
				Input.action_release("jump")
			await physics_frame
			var center: Vector2 = player.body.com_world()
			if frame == 100:
				print("[DrawingAscent] input=",Input.get_axis("move_left","move_right")," support=",player.get_node("PlayerInput").support," locked=",hand.locks_foot_translation()," force=",player.get_node("PlayerInput").debug_drive_impulse," ramp_pos=",body.position)
				if OS.get_cmdline_user_args().has("--preview"):
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png("res://.runtime_logs/ascent-test-"+str(index)+".png")
			if (center.x-run[4])*run[3] > 0 and center.y < run[5]-15:
				reached = true
				break
		Input.action_release("move_right")
		Input.action_release("move_left")
		Input.action_release("jump")
		print("[DrawingAscent] stage=",index+1," reached_without_hands=",reached," player=",player.body.com_world()," ramp_mass=",body.mass)
		if not reached:
			failures += 1
		level.remove_body_node(ramp)
		ramp.queue_free()
	if player.get_node("Visual").texture == null:
		failures += 1
	app.queue_free()
	await process_frame
	print("[DrawingAscent] failures=",failures)
	quit(1 if failures else 0)
