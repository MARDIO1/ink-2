extends SceneTree
## 离线搭建第一关。所有建筑像素直接成为 PixelShape，渲染和碰撞使用同一份材质图。

const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const ShapeNode := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const CanvasScene := preload("res://actor/canvas/canvas.tscn")
const Gate := preload("res://map/src/workshop_gate.gd")
const Text := preload("res://ui/map_text/src/map_text_label.gd")
const Dialogue := preload("res://debug/creative/src/map_dialogue_trigger.gd")
const Portal := preload("res://actor/portal/src/map_portal.gd")
const Fountain := preload("res://actor/fountain/ink_fountain.tscn")
const PATH := "res://map/asset/imported/第一页.tscn"
const OUTPUT := "res://map/asset/workshop/"
var level: Node2D
var roofs: Array[Image] = []
var overview: Image

func _initialize() -> void:
	_build.call_deferred()

func _own(node: Node, parent: Node = null) -> void:
	(parent if parent != null else level).add_child(node)
	node.owner = level

func _image(size: Vector2i) -> Image:
	return Image.create(size.x, size.y, false, Image.FORMAT_R8)

func _fill(image: Image, rect: Rect2i, material := 1) -> void:
	image.fill_rect(rect.intersection(Rect2i(Vector2i.ZERO, image.get_size())), Color(float(material) / 255.0, 0, 0))

func _line(image: Image, start: Vector2, end: Vector2, width: int, material := 1) -> void:
	var count := maxi(1, ceili(start.distance_to(end)))
	for index in count + 1:
		var point := Vector2i(start.lerp(end, float(index) / count))
		_fill(image, Rect2i(point - Vector2i.ONE * (width / 2), Vector2i.ONE * width), material)

func _rect(name_: String, position_: Vector2, size_: Vector2i, fixed := true, material := 1) -> Node2D:
	var image := _image(size_)
	_fill(image, Rect2i(Vector2i.ZERO, size_), material)
	return _body(name_, position_, image, fixed)

func _body(name_: String, position_: Vector2, image: Image, fixed := true) -> Node2D:
	var item := Node2D.new()
	item.set_script(InkItem)
	item.name = name_
	item.position = position_
	item.is_static = fixed
	item.add_to_group("ink_item", true)
	item.set_meta("workshop_generated", true)
	_own(item)
	var shape := Node2D.new()
	shape.set_script(ShapeNode)
	shape.name = "Pixels"
	shape.source = 3
	shape.paint = image
	_own(shape, item)
	if fixed:
		# 小锚点令建筑能够局部破坏，避免一碰就整栋坍塌；锚点本身同样是像素。
		var used := image.get_used_rect()
		if used.has_area():
			var found := false
			for y in range(used.end.y - 1, used.position.y - 1, -1):
				for x in range(used.position.x, used.end.x):
					if image.get_pixel(x, y).r > 0:
						image.set_pixel(x, y, Color(7.0 / 255.0, 0, 0))
						found = true
						break
				if found:
					break
	return item

func _terrain(name_: String, points: Array, depth := 150) -> void:
	var start := Vector2(points[0])
	var finish := Vector2(points[-1])
	var top := start.y
	var bottom := start.y
	for point: Vector2 in points:
		top = minf(top, point.y)
		bottom = maxf(bottom, point.y)
	var origin := Vector2(start.x, top)
	var image := _image(Vector2i(int(finish.x - start.x) + 1, int(bottom - top) + depth))
	for index in points.size() - 1:
		var a := Vector2(points[index])
		var b := Vector2(points[index + 1])
		for x in range(int(a.x), int(b.x) + 1):
			var surface := int(lerpf(a.y, b.y, float(x - a.x) / maxf(b.x - a.x, 1))) - int(top)
			_fill(image, Rect2i(x - int(start.x), surface, 1, image.get_height() - surface), 4)
			_fill(image, Rect2i(x - int(start.x), surface, 1, 7), 1)
	_body(name_, origin, image)

func _prepare_roofs() -> void:
	var sheet := Image.load_from_file(OUTPUT + "roof_modules_source.png")
	assert(sheet != null)
	var slices := [Rect2i(95, 0, 1345, 335), Rect2i(95, 340, 1350, 345), Rect2i(155, 680, 1260, 344)]
	for index in slices.size():
		var crop := sheet.get_region(slices[index])
		crop.resize(570 if index < 2 else 330, 142 if index < 2 else 94, Image.INTERPOLATE_NEAREST)
		var pixels := _image(crop.get_size())
		var art := Image.create(crop.get_width(), crop.get_height(), false, Image.FORMAT_RGBA8)
		for y in crop.get_height():
			for x in crop.get_width():
				var color := crop.get_pixel(x, y)
				if color.a < 0.8:
					continue
				var material := 1 if color.get_luminance() < 0.42 else 4
				pixels.set_pixel(x, y, Color(float(material) / 255.0, 0, 0))
				art.set_pixel(x, y, Color.BLACK if material == 1 else Color(0.58, 0.58, 0.62))
		assert(art.save_png(OUTPUT + "roof_%d.png" % index) == OK)
		roofs.append(pixels)

func _beam(name_: String, a: Vector2, b: Vector2, width := 8, fixed := true, material := 1) -> Node2D:
	var origin := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - Vector2.ONE * width
	var image := _image(Vector2i((a - b).abs()) + Vector2i.ONE * width * 2 + Vector2i.ONE)
	_line(image, a - origin, b - origin, width, material)
	return _body(name_, origin, image, fixed)

func _house(prefix: String, origin: Vector2, roof_index: int) -> void:
	var roof := roofs[roof_index].duplicate() as Image
	_body(prefix + "_Roof", origin, roof)
	# 两侧留出净高 164px 的通道，门框和上梁均为真实可破坏像素。
	_rect(prefix + "_LeftUpperPost", origin + Vector2(40, 130), Vector2i(12, 55))
	_rect(prefix + "_RightUpperPost", origin + Vector2(515, 130), Vector2i(12, 55))
	_rect(prefix + "_Lintel", origin + Vector2(30, 180), Vector2i(510, 12))
	_rect(prefix + "_LeftFoundation", origin + Vector2(35, 337), Vector2i(25, 13))
	_rect(prefix + "_RightFoundation", origin + Vector2(510, 337), Vector2i(25, 13))
	_rect(prefix + "_Floor", origin + Vector2(30, 350), Vector2i(510, 10))
	# 位于头顶的可碰撞梁饰，绝不使用穿越主通道的背景墙或窗框。
	_beam(prefix + "_BraceLeft", origin + Vector2(52, 135), origin + Vector2(115, 180), 7)
	_beam(prefix + "_BraceRight", origin + Vector2(515, 135), origin + Vector2(450, 180), 7)

func _canvas(name_: String, rect: Rect2) -> void:
	var canvas := CanvasScene.instantiate()
	canvas.name = name_
	canvas.position = rect.position
	canvas.canvas_size = Vector2i(rect.size)
	canvas.add_to_group("play_canvas", true)
	_own(canvas)

func _checkpoint(position_: Vector2, name_: String) -> void:
	var point := Marker2D.new()
	point.name = name_
	point.position = position_
	point.add_to_group("respawn_point", true)
	_own(point)

func _fountain(position_: Vector2, name_: String) -> void:
	var fountain := Fountain.instantiate()
	fountain.name = name_
	fountain.position = position_
	_own(fountain)
	# 喷泉贴图本身原来无碰撞；添加与其石座同位置的真实可破坏台座。
	_rect(name_ + "_StoneBase", position_ + Vector2(-56, 2), Vector2i(112, 14), true, 4)

func _text(position_: Vector2, value: String, font_size := 19) -> void:
	var label := Label.new()
	label.set_script(Text)
	label.name = "WorkshopNote"
	label.position = position_
	label.text = value
	label.add_theme_font_override("font", load("res://ui/map_text/asset/Muyao-Softbrush.ttf"))
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", Color(0.10, 0.09, 0.07))
	label.add_to_group("map_text_label", true)
	_own(label, level.get_node("MapTexts"))

func _dialogue(position_: Vector2, value: String) -> void:
	var trigger := Node2D.new()
	trigger.set_script(Dialogue)
	trigger.name = "WorkshopDialogue"
	trigger.position = position_
	trigger.lines = PackedStringArray([value])
	_own(trigger, level.get_node("DialogueTriggers"))

func _monster(path: String, name_: String, position_: Vector2, size_: float) -> void:
	var monster: Node2D = load(path).instantiate()
	monster.name = name_
	monster.position = position_
	monster.scale = Vector2.ONE * size_
	monster.editor_id = "workshop-" + name_
	_own(monster, level.get_node("Monsters"))

func _build() -> void:
	_prepare_roofs()
	level = load(PATH).instantiate()
	# 第一关原文件及所有编辑快照已在 .level_backups 中保存。
	var keep := ["Camera2D", "SmallCanvas", "MapCanvas", "Player", "debugHUD", "SimulationRuntime", "Creative", "Monsters", "PlayerSpawn", "MapTexts", "DialogueTriggers"]
	for node in level.get_children():
		if node.name not in keep:
			level.remove_child(node)
			node.free()
	for name_ in ["Monsters", "MapTexts", "DialogueTriggers"]:
		for node in level.get_node(name_).get_children():
			level.get_node(name_).remove_child(node)
			node.free()
	level.get_node("Player").position = Vector2(90, 625)
	level.get_node("PlayerSpawn").position = Vector2(90, 625)
	level.get_node("Camera2D").position = Vector2(124, 670)
	level.get_node("Camera2D").set_script(load("res://actor/player/src/player_camera.gd"))
	level.get_node("SmallCanvas").position = Vector2(30, 420)
	level.get_node("SmallCanvas").canvas_size = Vector2i(470, 310)
	level.get_node("SmallCanvas").add_to_group("play_canvas", true)
	level.get_node("MapCanvas").position = Vector2(-256, -128)
	level.get_node("MapCanvas").canvas_size = Vector2i(6656, 1408)
	level.get_node("Creative").edit_snapshot_path = ""
	level.get_node("Creative").auto_save_edits = false
	level.get_node("debugHUD").visible = false

	_terrain("Ground_Start", [Vector2(-220, 720), Vector2(470, 720), Vector2(850, 600), Vector2(1100, 600)])
	_terrain("Ground_GullyRecovery", [Vector2(1000, 940), Vector2(1320, 940), Vector2(1470, 720), Vector2(1570, 600)], 100)
	_terrain("Ground_WorkshopA", [Vector2(1460, 600), Vector2(2120, 600)])
	_terrain("Ground_Valley", [Vector2(2120, 600), Vector2(2510, 780), Vector2(3100, 780)])
	_terrain("Ground_MiddleClimb", [Vector2(3100, 780), Vector2(3370, 650), Vector2(3620, 650), Vector2(3920, 570)])
	_terrain("Ground_WorkshopB", [Vector2(3920, 570), Vector2(4600, 570)])
	_terrain("Ground_SummitClimb", [Vector2(4600, 570), Vector2(4800, 470), Vector2(5000, 470), Vector2(5240, 350)])
	_terrain("Ground_Exit", [Vector2(5240, 350), Vector2(6140, 350)])
	_canvas("BridgeCanvas", Rect2(900, 390, 700, 410))
	_canvas("GateACanvas", Rect2(1390, 330, 750, 300))
	_canvas("ValleyCanvas", Rect2(2400, 470, 720, 320))
	_canvas("GateBCanvas", Rect2(3720, 270, 850, 320))
	_canvas("SummitCanvas", Rect2(4750, 150, 720, 350))

	_house("Smithy", Vector2(1500, 240), 0)
	_rect("GateA_Door", Vector2(2090, 436), Vector2i(20, 164), false, 4).gravity_scale = 0.0
	_rect("GateA_Weight", Vector2(1450, 470), Vector2i(42, 42), false, 4)
	_rect("GateA_BreakableSupport", Vector2(1467, 512), Vector2i(8, 88))
	_beam("GateA_CableAcross", Vector2(1470, 456), Vector2(2078, 456), 4)
	var first_gate := Node.new()
	first_gate.set_script(Gate)
	first_gate.name = "CounterweightGate"
	first_gate.door_path = ^"../GateA_Door"
	first_gate.support_path = ^"../GateA_BreakableSupport"
	first_gate.opening_height = 176.0
	_own(first_gate)

	_house("MechanismHouse", Vector2(3960, 210), 1)
	_rect("GateB_Door", Vector2(4550, 406), Vector2i(20, 164), false, 4).gravity_scale = 0.0
	_rect("Lever_Pivot", Vector2(3820, 526), Vector2i(24, 62), true, 4)
	var lever_image := _image(Vector2i(240, 30))
	_fill(lever_image, Rect2i(0, 18, 240, 12), 9)
	_fill(lever_image, Rect2i(10, 8, 70, 10), 1)
	_body("Lever_Beam", Vector2(3720, 492), lever_image, false).gravity_scale = 0.0
	_rect("Lever_SampleWeight", Vector2(3590, 590), Vector2i(26, 26), false, 4)
	_beam("GateB_Linkage", Vector2(3948, 396), Vector2(4538, 396), 4)
	var second_gate := Node.new()
	second_gate.set_script(Gate)
	second_gate.name = "LeverGate"
	second_gate.mode = 1
	second_gate.door_path = ^"../GateB_Door"
	second_gate.lever_path = ^"../Lever_Beam"
	second_gate.lever_pivot = Vector2(3832, 516)
	second_gate.load_zone = Rect2(3700, 430, 130, 100)
	second_gate.opening_height = 176.0
	_own(second_gate)

	# 可搬动家具与可破坏掩体；没有无碰撞建筑装饰。
	_rect("CrateNearBridge", Vector2(820, 558), Vector2i(42, 42), false)
	_rect("ValleyCover", Vector2(2600, 696), Vector2i(38, 84), false, 4)
	_rect("ValleyCoverLow", Vector2(2850, 735), Vector2i(62, 45), false)
	_rect("BomberPlatform", Vector2(3020, 500), Vector2i(180, 18))
	_beam("BomberPlatformPost", Vector2(3180, 518), Vector2(3180, 720), 12)
	_rect("WorkshopTableTop", Vector2(2000, 542), Vector2i(70, 10), false)
	_rect("SummitCrate", Vector2(4940, 432), Vector2i(38, 38), false)
	_body("ExitGatehouseRoof", Vector2(5560, 110), roofs[2])
	_beam("ExitGatehouseLeft", Vector2(5585, 200), Vector2(5585, 212), 10)
	_beam("ExitGatehouseRight", Vector2(5865, 200), Vector2(5865, 212), 10)

	_fountain(Vector2(250, 704), "StartFountain")
	_fountain(Vector2(1530, 584), "WorkshopFountain")
	_fountain(Vector2(3350, 640), "ValleyExitFountain")
	_fountain(Vector2(5500, 334), "SummitFountain")
	_checkpoint(Vector2(1510, 510), "RespawnPoint_Workshop")
	_checkpoint(Vector2(3340, 550), "RespawnPoint_Valley")
	_checkpoint(Vector2(4650, 445), "RespawnPoint_Summit")
	_monster("res://actor/monster/little_soldier.tscn", "SlopeSoldier", Vector2(980, 600), 0.45)
	_monster("res://actor/monster/great_shield.tscn", "ValleyShield", Vector2(2760, 780), 0.35)
	_monster("res://actor/monster/bomb_side.tscn", "PlatformBomber", Vector2(3110, 498), 0.45)
	_monster("res://actor/monster/little_soldier.tscn", "SummitSoldier", Vector2(4890, 470), 0.45)

	_text(Vector2(40, 390), "未完成的山间工坊", 25)
	_text(Vector2(910, 340), "断沟：画出你自己的路")
	_text(Vector2(1530, 190), "断开细支撑，配重落下，门就会升起", 17)
	_text(Vector2(2390, 450), "低路有盾，高处有炸弹；不一定要打败所有敌人", 16)
	_text(Vector2(3970, 155), "把画出的配重放在黄色杠杆左端", 18)
	_text(Vector2(5540, 75), "下一页，在山的另一边。", 17)
	_dialogue(Vector2(580, 640), "这里没有白雨。屋顶、门和路，都还来得及画完。")
	_dialogue(Vector2(1540, 540), "门旁的细杆托着配重。画一件顺手的工具，试着把支撑打断。")
	_dialogue(Vector2(3490, 590), "门还差一个配重。不必画得漂亮，能压动杠杆就行。")
	var portal := Node2D.new()
	portal.set_script(Portal)
	portal.name = "WorkshopExit"
	portal.position = Vector2(5760, 270)
	portal.target_map = "res://map/asset/imported/第二页.tscn"
	_own(portal)

	var packed := PackedScene.new()
	assert(packed.pack(level) == OK)
	assert(ResourceSaver.save(packed, PATH) == OK)
	# 新地形已固化。清空旧编辑笔迹，防止 F2 重新读回原地图的大块墨水。
	var blank := Image.create(6656, 1408, false, Image.FORMAT_RGBA8)
	var snapshot := FileAccess.open("res://map/asset/imported/第一页.edit.snapshot", FileAccess.WRITE)
	assert(snapshot != null)
	snapshot.store_buffer(blank.save_png_to_buffer())
	snapshot.close()
	print("[WorkshopBuild] Saved first level: ", level.get_child_count(), " roots; roofs/terrain are collidable pixels; backup .level_backups/first-level-20261014-1944")
	level.free()
	quit()
