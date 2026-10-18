extends "res://tools/build_first_workshop_level.gd"
## 仅新增纯地形关卡；已有同名文件时拒绝覆盖。

const PAGES := ["第三页"]

func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--verify"):
		_verify.call_deferred()
	else:
		_build.call_deferred()

func _build() -> void:
	for title in PAGES:
		if FileAccess.file_exists("res://map/asset/imported/" + title + ".tscn") and not OS.get_cmdline_user_args().has("--replace"):
			push_error("拒绝覆盖已有地图：" + title)
			quit(1)
			return
	if OS.get_cmdline_user_args().has("--replace"):
		var backup := "res://.level_backups/terrain-pages-" + str(Time.get_unix_time_from_system()).replace(".", "-")
		assert(DirAccess.make_dir_recursive_absolute(backup) == OK)
		for title in PAGES:
			var path: String = "res://map/asset/imported/" + title + ".tscn"
			if FileAccess.file_exists(path):
				assert(DirAccess.copy_absolute(path, backup + "/" + title + ".tscn") == OK)
		print("[TerrainPages] Backup: ", backup)
	for index in PAGES.size():
		_prepare_page(PAGES[index])
		if PAGES[index] == "第二页":
			# 上路短而断续，下路连续但更长；失败后仍能从谷底爬回。
			_land("Start", [[-200,800],[400,800],[650,710],[850,710],[1030,610],[1150,610]])
			_land("FirstLanding", [[1390,640],[1560,640],[1730,590],[1880,590]])
			_land("LowRoute", [[1000,1010],[1290,1010],[1500,1080],[1810,1080],[2020,980],[2230,870],[2450,750]])
			_land("CentralHill", [[2140,700],[2330,700],[2510,570],[2740,570],[2930,710]],240)
			_land("Cliff", [[3170,640],[3360,640],[3500,730]],360,true)
			_land("SecondLowRoute", [[2820,1040],[3150,1120],[3520,1120],[3800,970],[4030,850],[4210,750]])
			_land("UpperSteppingRock", [[3680,710],[3800,690],[3900,710]],65)
			_land("ExitRidge", [[4180,750],[4400,750],[4590,620],[4770,620],[4960,490],[5200,490],[5480,570],[5800,570]])
			_canvas("BridgeCanvas", Rect2(900,380,1100,740))
			_canvas("CliffCanvas", Rect2(2780,390,1260,760))
			_checkpoint(Vector2(2390,650), "RespawnPoint_Central")
			_checkpoint(Vector2(4320,655), "RespawnPoint_ExitRidge")
			_text(Vector2(180,430), "第二页 · 跨谷选路\n上路画桥抄近道，下路绕谷再攀回。", 21)
			_text(Vector2(1010,420), "短路在上，退路在下 →", 18)
			_text(Vector2(2780,310), "灰壁不能抓：架桥，或从谷底绕行。", 18)
			_add_exit(Vector2(5640,490), false)
		else:
			# 四段折返：右上 → 左上 → 右上 → 左上，终点回到起点上方。
			_land("Start", [[-200,1500],[540,1500],[830,1380],[1080,1380]])
			_land("LowerCatch", [[600,1780],[1540,1780],[2010,1600],[2590,1510]],100)
			_land("EastRise", [[1280,1250],[1520,1250],[1780,1160],[2050,1160],[2310,1070],[2600,1070]],170,true)
			_land("TurnWestRock", [[2080,870],[2260,870]],80)
			_land("WestTraverse", [[1450,730],[1670,730],[1880,830]],100)
			_land("WestRest", [[820,620],[1110,620],[1260,680]],110)
			_land("TurnEastRock", [[1070,430],[1240,430]],70)
			_land("EastTraverse", [[1450,300],[1630,300],[1840,370]],100,true)
			_land("EastRest", [[2040,150],[2370,150],[2550,220]],110)
			_land("LastWestRock", [[1800,-40],[1970,-40]],75)
			_land("SummitApproach", [[1210,-180],[1440,-180],[1580,-120]],100)
			_land("Summit", [[520,-310],[790,-310],[1010,-270]],120)
			_canvas("LowerClimbCanvas", Rect2(870,920,1810,870))
			_canvas("WestClimbCanvas", Rect2(700,400,1640,660))
			_canvas("EastClimbCanvas", Rect2(1120,-60,1550,620))
			_canvas("SummitCanvas", Rect2(440,-490,1710,620))
			_checkpoint(Vector2(2400,975), "RespawnPoint_East")
			_checkpoint(Vector2(880,525), "RespawnPoint_West")
			_checkpoint(Vector2(2200,55), "RespawnPoint_UpperEast")
			_text(Vector2(110,1130), "第三页 · 折返登顶\n终点在头顶。画落脚点，借黑岩向上攀。", 21)
			_text(Vector2(2240,930), "← 折返向上", 20)
			_text(Vector2(760,490), "向右上攀 →", 20)
			_text(Vector2(2110,20), "← 最后一次折返", 20)
			_add_exit(Vector2(700,-390), true)
		var destination: String = "res://map/asset/imported/" + PAGES[index] + ".tscn"
		var packed := PackedScene.new()
		assert(packed.pack(level) == OK)
		var save_error := ResourceSaver.save(packed, destination)
		if save_error != OK:
			push_error("保存失败：%s (%d)" % [destination, save_error])
			level.free()
			quit(1)
			return
		print("[TerrainPages] Saved ", destination)
		level.free()
	quit()

func _add_exit(position_: Vector2, final_page: bool) -> void:
	var exit_portal := Node2D.new()
	exit_portal.set_script(load("res://map/src/terrain_page_exit.gd"))
	exit_portal.name = "PageExit"
	exit_portal.position = position_
	exit_portal.final_page = final_page
	if not final_page:
		exit_portal.target_map = "res://map/asset/imported/第三页.tscn"
	_own(exit_portal)
	_text(position_ + Vector2(-110,-120), "登顶完成 · 返回目录" if final_page else "跨谷完成 · 前往第三页", 19)

func _land(title: String, coordinates: Array, depth := 170, grey_left := false) -> void:
	var points: Array = []
	for point in coordinates:
		points.append(Vector2(point[0], point[1]))
	var top := INF
	var bottom := -INF
	for point: Vector2 in points:
		top = minf(top, point.y)
		bottom = maxf(bottom, point.y)
	var start: Vector2 = points[0]
	var finish: Vector2 = points[-1]
	var pixels := _image(Vector2i(int(finish.x - start.x) + 1, int(bottom - top) + depth))
	for index in points.size() - 1:
		var a: Vector2 = points[index]
		var b: Vector2 = points[index + 1]
		for x in range(int(a.x), int(b.x) + 1):
			var surface := int(lerpf(a.y, b.y, float(x - a.x) / (b.x - a.x)) - top)
			_fill(pixels, Rect2i(x - int(start.x), surface, 1, pixels.get_height() - surface), 1)
	# 灰色仅用于明确禁止抓握的左侧崖面，表面无黑色包边可绕过规则。
	if grey_left:
		for x in 18:
			for y in pixels.get_height():
				if pixels.get_pixel(x,y).r > 0:
					pixels.set_pixel(x,y,Color(4.0/255.0,0,0))
	_body("Terrain_" + title, Vector2(start.x,top), pixels)

func _prepare_page(title: String) -> void:
	level = load(PATH).instantiate()
	level.name = title
	var keep := ["Camera2D", "SmallCanvas", "MapCanvas", "Player", "debugHUD", "SimulationRuntime", "Creative", "Monsters", "PlayerSpawn", "MapTexts", "DialogueTriggers"]
	for child in level.get_children():
		if child.name not in keep:
			level.remove_child(child)
			child.free()
	for container in ["Monsters", "MapTexts", "DialogueTriggers"]:
		if not level.has_node(container):
			var node := Node2D.new()
			node.name = container
			_own(node)
		for child in level.get_node(container).get_children():
			level.get_node(container).remove_child(child)
			child.free()
	var ground_y := 800 if title == "第二页" else 1500
	var spawn := Vector2(100, ground_y - 95)
	level.get_node("Player").position = spawn
	level.get_node("PlayerSpawn").position = spawn
	level.get_node("Camera2D").position = spawn + Vector2(34, 44)
	level.get_node("Camera2D").set_script(load("res://actor/player/src/player_camera.gd"))
	# 使用全新的画布实例，不带入模板中玩家留下的绘制内容。
	for canvas_name in ["SmallCanvas", "MapCanvas"]:
		var old := level.get_node(canvas_name)
		level.remove_child(old)
		old.free()
	_canvas("SmallCanvas", Rect2(10, ground_y - 300, 600, 320))
	var editor := CanvasScene.instantiate()
	editor.name = "MapCanvas"
	editor.position = Vector2(-256, -256) if title == "第二页" else Vector2(-256,-512)
	editor.canvas_size = Vector2i(6400, 1792) if title == "第二页" else Vector2i(3328,2560)
	_own(editor)
	var creative := level.get_node("Creative")
	creative.map_path = "res://map/asset/imported/" + title + ".tscn"
	creative.baked_map_path = "res://map/asset/imported/" + title + ".png"
	creative.edit_snapshot_path = ""
	level.get_node("debugHUD").visible = false

func _verify() -> void:
	var menu_script := load("res://ui/level_select/src/level_select.gd")
	var app: Node = load("res://root/root.tscn").instantiate()
	root.add_child(app)
	current_scene = app
	root.get_node("SceneTransition").duration = 0.02
	var failures := 0
	for title in PAGES:
		var path: String = "res://map/asset/imported/" + title + ".tscn"
		if not menu_script.find_levels().has(path):
			failures += 1
		var ok: bool = await app.request_level_change(path)
		if not ok:
			failures += 1
			continue
		var current: Node = app.get_node("Level").get_child(0)
		current.get_node("Creative").auto_save_on_exit = false
		current.get_node("Creative").auto_save_edits = false
		for frame in 45:
			await physics_frame
		var player: Node = current.get_node("Player")
		var visual: Sprite2D = player.get_node("Visual")
		if not visual.is_visible_in_tree() or visual.texture == null:
			failures += 1
		print("[TerrainPages] visual visible=", visual.is_visible_in_tree(), " pos=", visual.global_position, " texture=", visual.texture, " camera=", current.get_node("Camera2D").global_position, " zoom=", current.get_node("Camera2D").zoom)
		if OS.get_cmdline_user_args().has("--preview"):
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://.runtime_logs/" + title + "-preview.png")
		var y: float = 800 if title == "第二页" else 1500
		if absf(player.body.com_world().y - (y - 45)) > 60:
			failures += 1
		var solids := 0
		for child in current.get_children():
			if str(child.name).begins_with("Terrain_"):
				solids += 1
				if child.body == null or child.body.collision_layer == 0:
					failures += 1
		if solids < 5 or current.get_node("Monsters").get_child_count() != 0:
			failures += 1
		if current.get_node("Creative").map_path != path:
			failures += 1
		print("[TerrainPages] ", title, " terrain bodies=", solids, " player=", player.body.com_world(), " failures=", failures)
		var portal: Node2D = current.get_node("PageExit")
		player.teleport_to(portal.global_position - Vector2(34,44), 0.0)
		var completed := false
		for frame in 600:
			await physics_frame
			var levels: Node = app.get_node("Level")
			if title == "第二页":
				completed = levels.get_child_count() == 1 and levels.get_child(0).scene_file_path.ends_with("第三页.tscn")
			else:
				completed = levels.get_child_count() == 0
			if completed and not root.get_node("SceneTransition").busy and not app._loading_level:
				break
		if not completed:
			failures += 1
		print("[TerrainPages] exit ", title, " completed=", completed, " failures=", failures)
	app.queue_free()
	await process_frame
	quit(1 if failures else 0)
