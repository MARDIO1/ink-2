extends "res://test/test_blue_ascent_connections.gd"
const Motor = preload("res://ink/blue/src/motor.gd")
var _in_jump := false
func tick(axis := 0.0,jump := false):
	if jump: _in_jump = true
	elif feet.support != null and player.body.linear_velocity.y > -10: _in_jump = false
	var hand_offset:Vector2=get_meta("test_hand_offset",Vector2(60,-20) if _in_jump else Vector2(0,-70))
	feet.hand_control.set_target_world(player.body.com_world()+hand_offset)
	await super.tick(axis,jump)
func check(ok: bool,label: String):
	print("[BlueMachinesTest] ","PASS " if ok else "FAIL ",label)
	if not ok: failures += 1
func frames(count: int):
	for i in count:
		if is_instance_valid(feet) and is_instance_valid(player) and player.body != null:
			feet.hand_control.set_target_world(player.body.com_world()+Vector2(60,-20))
			feet.apply_input(0,false,DT)
		await physics_frame

func capture(title: String, center: Vector2) -> void:
	if DisplayServer.get_name() == "headless": return
	camera.position = center
	camera.zoom = Vector2.ONE
	camera.force_update_scroll()
	await process_frame
	RenderingServer.force_draw(false)
	DirAccess.make_dir_recursive_absolute("res://output/blue_ascent_complete")
	root.get_texture().get_image().save_png("res://output/blue_ascent_complete/"+title+"_activated.png")
func drawing_clear(canvas: Node, world_points: Array, caption: String):
	await frames(4)
	var layout = canvas.get_node("SidePanelLayer")
	layout.update_layout()
	var controls: Array = [canvas.buttons,canvas._side_panel]
	var okay: bool = canvas.buttons.is_visible_in_tree() and canvas._side_panel.is_visible_in_tree()
	for paper in [canvas.workbench.get_node("LessonToolPaper"), canvas._side_panel.get_parent().get_node("LessonToolPaper")]:
		check(paper.mouse_filter == Control.MOUSE_FILTER_IGNORE and paper.visible,caption+" tool backing is visible and passes mouse input")
	for point: Vector2 in world_points:
		var local: Vector2 = canvas.surface.to_local(point)
		var screen: Vector2 = canvas.surface.get_global_transform_with_canvas()*local
		if not root.get_visible_rect().grow(-20).has_point(screen):
			okay=false
			print("DRAW OFFSCREEN ",caption," at=",screen," viewport=",root.get_visible_rect())
		for control in controls:
			if not is_instance_valid(control) or not control.is_visible_in_tree(): continue
			var bounds: Rect2 = control.get_global_transform_with_canvas()*Rect2(Vector2.ZERO,control.size)
			if bounds.grow(12).has_point(screen):
				okay=false
				print("DRAW BLOCKED ",caption," at=",screen," panel=",control.name," bounds=",bounds)
	check(okay,caption+" drawing area clear of both tool panels")
func run():
	root.mode = Window.MODE_WINDOWED
	root.size = Vector2i(960,540)
	root.position = Vector2i(20000,20000)
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	await process_frame
	var target := "res://.codex-tmp/blue_ascent_machines_work.tscn" if OS.get_cmdline_user_args().has("--work") else "res://map/asset/imported/蓝色攀升.tscn"
	await app.request_level_change(target)
	level = app.level_root.get_child(0)
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	player = level.get_node("Player")
	feet = player.get_node("PlayerInput")
	feet.set_physics_process(false)
	runtime = level.get_node("SimulationRuntime")
	camera = level.get_node("Camera2D")
	camera.set_physics_process(false)
	camera.set_process(false)
	camera.position = Vector2(500,3500)
	camera.force_update_scroll()
	if Array(OS.get_cmdline_user_args()).any(func(arg): return arg.begins_with("--section=")):
		await remaining()
		print("[BlueMachinesTest] failures=",failures)
		app.queue_free()
		await process_frame
		quit(1 if failures else 0)
		return
	player.teleport_to(Vector2(310-34,3700-95),0)
	await frames(30)
	var door = level.get_node("BG01_Gate")
	var bridge = level.get_node("BG02_Bridge")
	var gate_slide = level.get_node("BG01_Slide")
	var bridge_slide = level.get_node("BG02_Slide")
	var motor = level.get_node("BG01_Motor")
	print("[BlueMachinesTest] gate mass=",door.body.mass," origin=",door.body.position," motor=",motor.active," guide=",gate_slide.joint)
	var closed_y: float = door.body.position.y
	await frames(100)
	check(absf(door.body.position.y-closed_y) < 3,"door stays closed while wire gap is open")
	check(motor.applied_force < 1,"unconnected door motor produces no force")
	check(not door.body.is_static and door.fixed_nails.is_empty(),"door remains movable without fixed nails")
	var canvas = level.get_node("SmallCanvas")
	for zoom in [1.0,1.15]:
		camera.zoom = Vector2.ONE*zoom
		camera.position = Vector2(350,3656)
		camera.force_update_scroll()
		await drawing_clear(canvas,[Vector2(490,3690),Vector2(508,3690)],"gate zoom="+str(zoom))
	var surface = canvas.surface
	surface.ink_free = true
	surface.brush_size = 5
	surface.blue_layer.begin(Vector2(414.5,160.5))
	surface.blue_layer.extend(Vector2(436.5,160.5))
	surface.blue_layer.finish()
	canvas.generate(false)
	var peak := 0.0
	for i in 540:
		feet.hand_control.set_target_world(player.body.com_world()+Vector2(60,-20))
		feet.apply_input(0,false,DT)
		await physics_frame
		peak = maxf(peak,motor.applied_force)
	print("[BlueMachinesTest] door end=",door.body.position," force=",peak," travel=",gate_slide.displacement()," joint=",gate_slide.joint.movement())
	check(peak > door.body.mass*600,"real red ink delivers more lift than door weight")
	check(closed_y-door.body.position.y > 195,"enlarged door opens at least 195 pixels after real canvas wire repair")
	check(absf(door.body.rotation) < 0.05,"door stays upright")
	for body in level.world.bodies:
		var point := Vector2(476,3630)
		var cell := Vector2i(body.to_local(point))
		for shape in body.shapes:
			if shape.get_pixel(cell.x,cell.y) > 0:
				print("[BlueMachinesTest] BLOCKER ",body," aabb=",body.aabb," static=",body.is_static," tags=",body.tags)
	player.teleport_to(Vector2(310-34,3700-95),0)
	await frames(25)
	var passed: bool = await move_to(Vector2(520,3656),false)
	print("[BlueMachinesTest] passage gate=",door.body.position," motor_power=",motor.received_power," body=",player.body.aabb," grip=",feet.hand_control.grabbed_body)
	if not passed:
		for body in level.world.bodies:
			if body != player.body and body.aabb.intersects(player.body.aabb.grow(3)):
				print("[BlueMachinesTest] TOUCH body=",body," aabb=",body.aabb," pos=",body.position," static=",body.is_static," tags=",body.tags)
	check(passed,"player walks through opened gate without grabbing")
	check(await move_to(Vector2(600,3645),false),"player exits gate onto the next ramp")
	await capture("01_gate",Vector2(450,3480))
	# 第二段完整保持闭合供电但没有箭头；仅通过游戏的箭头绘制与固化接口激活。
	player.teleport_to(Vector2(1680-34,2975-95),0)
	camera.position = Vector2(1300,2930)
	camera.force_update_scroll()
	await frames(30)
	var bridge_x: float = bridge.body.position.x
	await frames(70)
	check(absf(bridge.body.position.x-bridge_x) < 3,"bridge stays retracted without a force arrow")
	var lesson = level.get_node("BridgeLessonCanvas")
	for zoom in [1.0,1.15]:
		camera.zoom = Vector2.ONE*zoom
		camera.position = Vector2(1580,2931)
		camera.force_update_scroll()
		await drawing_clear(lesson,[Vector2(1600,2951),Vector2(1530,2951),Vector2(1460,2951)],"bridge zoom="+str(zoom))
	var drawing = lesson.surface
	drawing.ink_free = true
	drawing.brush_size = 7
	var rule = drawing.blue_rule()
	rule.begin(drawing,Vector2(340.5,141.5))
	check(rule.finish(drawing,Vector2(200.5,141.5)),"left arrow draws on existing black bridge")
	lesson.generate(false)
	await frames(420)
	print("[BlueMachinesTest] bridge end=",bridge.body.position," travel=",bridge_slide.displacement()," joint=",bridge_slide.joint.movement()," bodies=",level.world.bodies.size())
	check(bridge_x-bridge.body.position.x > 325,"red ink and drawn left arrow extend bridge to opposite bank")
	check(bridge_slide.joint.min_limit == 0 and bridge_slide.unlocked,"powered latch releases only the intended travel direction")
	check(absf(bridge.body.position.y-2931) < 3 and absf(bridge.body.rotation) < 0.05,"thicker bridge guide prevents falling or tilting")
	# 上桥、穿过实际桥面并到达左岸缓坡；只在关卡段落起点放置角色。
	player.teleport_to(Vector2(1520-34,2975-95),0)
	await frames(25)
	check(await move_to(Vector2(1480,2919),false),"player approaches extended bridge")
	check(await move_to(Vector2(1250,2887),true),"player steps onto bridge")
	check(await move_to(Vector2(900,2887),false),"player crosses real bridge deck")
	check(await move_to(Vector2(820,2931),false),"player reaches opposite bank without grabbing")
	await capture("02_bridge",Vector2(1120,2860))
	await remaining()
	print("[BlueMachinesTest] failures=",failures)
	app.queue_free()
	await process_frame
	quit(1 if failures else 0)

func remaining() -> void:
	pass
