extends "res://tools/build_terrain_pages.gd"
## 仅重建第三页。黑色岩棚承托玩家画出的台阶/斜坡，不依赖手部攀爬。

func _build() -> void:
	var destination := "res://map/asset/imported/第三页.tscn"
	var backup := "res://.level_backups/drawing-ascent-" + str(Time.get_unix_time_from_system()).replace(".", "-")
	assert(DirAccess.make_dir_recursive_absolute(backup) == OK)
	for suffix in [".tscn", ".edit.snapshot", ".edit.zip"]:
		var source: String = "res://map/asset/imported/第三页" + suffix
		if FileAccess.file_exists(source):
			assert(DirAccess.copy_absolute(source, backup + "/第三页" + suffix) == OK)
	_prepare_page("第三页")
	_land("Start", [[-200,1500],[2450,1500]],180)
	# 岩棚之间保留至少 240px 净空，角色和小型绘制结构可在其中活动。
	_land("FirstRest", [[1000,1220],[1220,1210],[1510,1220],[2450,1220]],95,true)
	_land("SecondRest", [[200,870],[500,850],[900,870],[1500,870]],95)
	_land("ThirdRest", [[900,520],[1260,510],[1720,520],[2450,520]],95,true)
	_land("Summit", [[200,170],[650,150],[1120,170],[1450,170]],95)
	# 已有落脚点只解决部分高度，缺口仍需玩家补画。
	_land("FirstFoothold", [[710,1410],[820,1410]],90)
	_land("SecondFoothold", [[1870,1100],[1980,1100]],120)
	_land("ThirdFoothold", [[510,750],[620,750]],110)
	_land("FinalFoothold", [[1780,410],[1880,410]],110)
	# 右向接近的崖面同样只涂窄灰带，主体保持黑墨。
	_grey_right("Terrain_SecondRest")
	_grey_right("Terrain_Summit")
	_canvas("FirstStepCanvas", Rect2(460,1090,820,440))
	_canvas("SecondStepCanvas", Rect2(1320,730,980,520))
	_canvas("ZigzagCanvas", Rect2(300,370,900,530))
	_canvas("SummitCanvas", Rect2(1260,20,1010,530))
	_checkpoint(Vector2(1160,1115), "RespawnPoint_FirstRest")
	_checkpoint(Vector2(1220,775), "RespawnPoint_SecondRest")
	_checkpoint(Vector2(1080,420), "RespawnPoint_ThirdRest")
	_text(Vector2(60,1120), "第三页 · 画阶登顶\n用画出的台阶和斜坡向上走，无需用手攀爬。", 21)
	_text(Vector2(480,1070), "① 补台阶 →\n小岩台只到一半，画个垫脚块接上。", 17)
	_text(Vector2(1560,710), "② 接岩台 ←\n画作要落在岩层上；空心台阶更省墨。", 17)
	_text(Vector2(310,340), "③ 折返搭坡 →\n绕过岩棚边缘，别把自己堵在棚底。", 17)
	_text(Vector2(1570,-10), "④ 省墨登顶 ←\n短台阶或细斜坡都可以，旧画作可回收再用。", 17)
	_add_exit(Vector2(600,80), true)
	var packed := PackedScene.new()
	assert(packed.pack(level) == OK)
	var error := ResourceSaver.save(packed,destination)
	for retry in 4:
		if error == OK:
			break
		await create_timer(0.3).timeout
		error = ResourceSaver.save(packed,destination)
	level.free()
	print("[DrawingAscent] saved=", error == OK, " backup=",backup)
	quit(0 if error == OK else 1)

func _grey_right(node_name: String) -> void:
	var pixels: Image = level.get_node(node_name).get_node("Pixels").paint
	for x in range(pixels.get_width()-18,pixels.get_width()):
		for y in pixels.get_height():
			if pixels.get_pixel(x,y).r > 0:
				pixels.set_pixel(x,y,Color(4.0/255.0,0,0))
