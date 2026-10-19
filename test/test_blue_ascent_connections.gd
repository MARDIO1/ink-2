extends SceneTree
var level
var player
var feet
var runtime
var camera
var failures := 0
const DT := 1.0/60.0
func _initialize(): run.call_deferred()
func tick(axis := 0.0,jump := false):
	camera.position = player.body.com_world()
	camera.force_update_scroll()
	feet.apply_input(axis,jump,DT)
	await physics_frame
func move_to(target: Vector2, jump: bool) -> bool:
	var fired := false
	if jump:
		var axis := signf(target.x-player.body.com_world().x)
		for i in 24:
			if player.body.linear_velocity.x*axis > 170: break
			await tick(axis,false)
	for frame in 600:
		var p: Vector2 = player.body.com_world()
		if feet.support != null and absf(p.x-target.x) < 16 and absf(p.y-target.y) < 18:
			return true
		var axis := signf(target.x-p.x) if absf(target.x-p.x) > 6 else 0.0
		var press: bool = jump and not fired and feet.support != null
		if press: fired = true
		await tick(axis,press)
		if p.y > target.y+360: break
	print("CONNECTION fail target=",target," at=",player.body.com_world()," support=",feet.support," jump=",jump)
	return false
func run():
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	await process_frame
	await app.request_level_change("res://map/asset/imported/蓝色攀升.tscn")
	level = app.level_root.get_child(0)
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	level.auto_step = true
	player = level.get_node("Player")
	feet = player.get_node("PlayerInput")
	feet.set_physics_process(false)
	runtime = level.get_node("SimulationRuntime")
	camera = level.get_node("Camera2D")
	camera.set_physics_process(false)
	camera.set_process(false)
	var routes := []
	for base in [3236.0,2047.0]:
		routes.append({"name":"right_"+str(base),"start":Vector2(1510,base),"points":[[Vector2(1750,base-87),false],[Vector2(1965,base-174),false],[Vector2(1935,base-174),false],[Vector2(1720,base-261),true],[Vector2(1490,base-261),false]]})
	for base in [2627.0,1554.0]:
		routes.append({"name":"left_"+str(base),"start":Vector2(160,base),"points":[[Vector2(-40,base-87),false],[Vector2(-255,base-174),false],[Vector2(-235,base-174),false],[Vector2(0,base-261),true],[Vector2(180,base-261),false]]})
	routes.append({"name":"summit","start":Vector2(910,742),"points":[[Vector2(1100,655),false],[Vector2(1300,568),false],[Vector2(1285,568),false],[Vector2(1060,481),true],[Vector2(900,481),false]]})
	for route in routes:
		var start: Vector2 = route.start
		player.teleport_to(start-Vector2(34,95),0)
		for i in 25: await tick()
		var ok := true
		for point in route.points:
			if not await move_to(point[0]-Vector2(0,44),point[1]):
				ok = false
				break
			print("CONNECTION waypoint=",point[0]," actual=",player.body.com_world())
		print("CONNECTION ",route.name," pass=",ok," final=",player.body.com_world())
		if not ok: failures += 1
	print("CONNECTION failures=",failures)
	app.queue_free()
	await process_frame
	quit(1 if failures else 0)
