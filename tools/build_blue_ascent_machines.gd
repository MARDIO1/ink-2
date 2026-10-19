extends "res://tools/build_first_workshop_level.gd"
const TARGET := "res://map/asset/imported/蓝色攀升.tscn"
const WORK_SCENE := "res://.codex-tmp/blue_ascent_machines_work.tscn"
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const Rail := preload("res://ink/yellow/src/rail.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const LessonUI := preload("res://map/src/blue_ascent_lesson_ui.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const PhysicsConfig := preload("res://addons/pixel_destruction/physics/physics_config.gd")
const PhysicsWorld := preload("res://addons/pixel_destruction/physics/pworld.gd")

func _build() -> void:
	var backup := "res://.level_backups/blue-ascent-machines-"+Time.get_datetime_string_from_system().replace(":","-")
	assert(DirAccess.make_dir_recursive_absolute(backup) == OK)
	assert(DirAccess.copy_absolute(TARGET,backup+"/蓝色攀升.tscn") == OK)
	level = load(TARGET).instantiate()
	assert(level.get_node("Creative").has_method("prepare_loaded_document"))
	# 保留本关已有物理设置，仅降低碰撞纠偏回弹；角度/行程仍由墨水接触决定。
	level.world = PhysicsWorld.new()
	level.push_physics_settings()
	var physics := PhysicsConfig.new()
	assert(physics.capture(level.world).is_empty())
	level.world = null
	physics.rp_angular_damping = 25.0
	physics.rp_max_corrective_velocity = 1.0
	level.physics = physics
	_clear_upper_turn()
	for child in level.get_children():
		# 编辑器重存会给黄墨组件改成匿名节点名，按脚本识别旧组件，避免叠加旧约束。
		var old_yellow:bool=child.get_script() in [Rail,SliderPin,Axle,load("res://ink/yellow/src/stroke.gd")]
		if old_yellow or str(child.name).begins_with("BG0") or str(child.name).begins_with("MachineNote_") or str(child.name) in ["BridgeLessonCanvas", "RampLessonCanvas", "CrateLessonCanvas", "LiftLessonCanvas", "FinalLessonCanvas"]:
			child.free()
	for child in level.get_node("MapTexts").get_children():
		if str(child.name).begins_with("MachineNote_"): child.free()
	_gate()
	_bridge()
	_rotating_ramp()
	_crates()
	_lift()
	_finale()
	_smooth_connections()
	var lesson_ui := LessonUI.new()
	lesson_ui.name = "BG01_LessonUI"
	_own(lesson_ui)
	level.get_node("SmallCanvas").position = Vector2(80,3530)
	level.get_node("SmallCanvas").canvas_size = Vector2i(490,220)
	var spawn := Vector2(180,3605)
	level.get_node("PlayerSpawn").position = spawn
	level.get_node("Player").position = spawn
	level.get_node("Player").modulate = Color.WHITE
	level.get_node("Camera2D").position = spawn+Vector2(34,44)
	for title in ["SmallCanvas","BridgeLessonCanvas","RampLessonCanvas","CrateLessonCanvas","LiftLessonCanvas","FinalLessonCanvas"]:
		var canvas := level.get_node(title)
		level.set_editable_instance(canvas,true)
		canvas.get_node("CanvasSurface").selected_ink = 5
		canvas.get_node("WorkbenchUI/BrushPanel/PenSlider").value = _lesson_width(title)
	level.set_meta("blue_ascent_first_machines",1)
	level.set_meta("blue_ascent_all_machines",3)
	level.set_meta("blue_ascent_ink_only_stops",true)
	var packed := PackedScene.new()
	assert(packed.pack(level) == OK)
	assert(ResourceSaver.save(packed,WORK_SCENE) == OK)
	if OS.get_cmdline_user_args().has("--publish"):
		assert(ResourceSaver.save(packed,TARGET) == OK)
	level.free()
	print("[BlueMachines] saved=",TARGET if OS.get_cmdline_user_args().has("--publish") else WORK_SCENE," backup=",backup)
	quit()

func _lesson_width(_title: String) -> int:
	return 7

func _clear_upper_turn() -> void:
	# 仅重做升降井上方的旧折返踏步，避免实体踏步封住升降井。
	var creative := level.get_node("Creative")
	var draft: Dictionary = creative.editor_draft.duplicate(true)
	var image := Image.new()
	assert(image.load_png_from_buffer(draft.black) == OK)
	var origin: Vector2i = Vector2i(level.get_node("MapCanvas").position)
	for rect in [Rect2i(930,548,540,194),Rect2i(300,497,850,144),Rect2i(1380,465,130,245)]:
		image.fill_rect(Rect2i(rect.position-origin,rect.size),Color.TRANSPARENT)
	draft.black = image.save_png_to_buffer()
	creative.editor_draft = draft

func _body(title: String, at: Vector2, image: Image, fixed := true) -> Node2D:
	var item := Node2D.new()
	item.set_script(InkItem)
	item.name = title
	item.position = at
	item.is_static = fixed
	item.add_to_group("ink_item",true)
	item.set_meta("blue_ascent_machine",true)
	_own(item)
	var pixels := Node2D.new()
	pixels.set_script(ShapeNode)
	pixels.name = "Pixels"
	pixels.source = 3
	pixels.paint = image
	_own(pixels,item)
	if fixed:
		var used := image.get_used_rect()
		var nails := PackedVector2Array()
		for x in [used.position.x+4,used.end.x-5]:
			for y in range(used.end.y-5,used.position.y,-1):
				if image.get_pixel(x,y).r > 0:
					nails.append(Vector2(x,y))
					break
		item.fixed_nails = nails
	return item

func _wire_on(title: String, carrier: Node, paths: Array, width := 5) -> void:
	var cells := {}
	for path in paths:
		for index in path.size()-1:
			var a: Vector2 = path[index]
			var b: Vector2 = path[index+1]
			var steps := maxi(1,ceili(a.distance_to(b)))
			for step in steps+1:
				var at := Vector2i(a.lerp(b,float(step)/steps).round())
				for x in range(-width/2,width/2+1):
					for y in range(-width/2,width/2+1):
						var p := at+Vector2i(x,y)
						if Rect2i(Vector2i.ZERO,carrier.get_node("Pixels").paint.get_size()).has_point(p) and carrier.get_node("Pixels").paint.get_pixelv(p).r > 0: cells[p]=true
	var wire := Wire.new()
	wire.name = title
	wire.position = carrier.position
	wire.active = true
	wire.carrier_path = NodePath("../"+str(carrier.name))
	wire.carrier_local = true
	wire.cells = PackedVector2Array(cells.keys())
	_own(wire)

func _guide(title: String, at: Vector2, size_: Vector2i, a: Vector2, b: Vector2) -> Node2D:
	var body := _rect(title+"_Guide",at,size_,true,Palette.YELLOW.id)
	var rail := Rail.new()
	rail.name = title+"_Rail"
	rail.saved_a = a
	rail.saved_b = b
	rail.rail_width = mini(size_.x,size_.y)
	_own(rail)
	return body

func _pin(title: String, point: Vector2) -> void:
	var pin := SliderPin.new()
	pin.name = title+"_Pin"
	pin.saved_source = point
	pin.saved_position = point
	_own(pin)

func _rail(title: String, a: Vector2, b: Vector2, width: int) -> void:
	var rail := Rail.new()
	rail.name = title+"_Rail"
	rail.saved_a = a
	rail.saved_b = b
	rail.rail_width = width
	_own(rail)

func _note(title: String, at: Vector2, value: String) -> void:
	var label := Label.new()
	label.name = "MachineNote_"+title
	label.set_script(Text)
	label.position = at
	label.text = value
	label.add_theme_font_override("font",load("res://ui/map_text/asset/Muyao-Softbrush.ttf"))
	label.add_theme_font_size_override("font_size",18)
	label.add_theme_color_override("font_color",Color("242424"))
	_own(label)

func _gate() -> void:
	var pixels := _image(Vector2i(116,360))
	_fill(pixels,Rect2i(48,0,20,68))
	_fill(pixels,Rect2i(0,60,116,8))
	_fill(pixels,Rect2i(0,60,8,300))
	_fill(pixels,Rect2i(108,60,8,300))
	_fill(pixels,Rect2i(45,68,26,292))
	_fill(pixels,Rect2i(0,340,116,20))
	_fill(pixels,Rect2i(6,342,34,16),Palette.RED.id)
	var door := _body("BG01_Gate",Vector2(452,3340),pixels,false)
	door.infinite_nails = PackedVector2Array([Vector2(12,350)])
	door.infinite_nail_body = true
	door.infinite_fuel_body = true
	var guide := _guide("BG01",Vector2(496,3136),Vector2i(28,274),Vector2(510,3140),Vector2(510,3404))
	_rect("BG01_TopStop",Vector2(488,3128),Vector2i(44,12),true,Palette.YELLOW.id)
	_pin("BG01",Vector2(510,3360))
	_wire_on("BG01_Wire",door,[[Vector2(40,350),Vector2(44,350)],[Vector2(56,350),Vector2(58,350),Vector2(58,143)]],9)
	var motor := Motor.new()
	motor.name = "BG01_Motor"
	motor.position = Vector2(510,3660)
	motor.tip = Vector2(0,-180)
	motor.brush_width = 12
	motor.active = true
	motor.source_canvas = NodePath("MapCanvas/CanvasSurface")
	_own(motor)
	_note("Gate",Vector2(90,3500),"① 蓝墨·画笔：补齐门底蓝线\n按「固化」，箭头向上开门")
	_note("GateGap",Vector2(365,3650),"补线 →")
	# 消除相邻楼层对门和上导轨的视觉干扰，不添加地面固定立柱阻挡通道。
	level.get_node("Reserved_01_Gate").set_meta("mechanism_installed",true)

func _bridge() -> void:
	var pixels := _image(Vector2i(480,40))
	var frame := _frame(Vector2i(480,40),8)
	pixels.blit_rect(frame,Rect2i(Vector2i.ZERO,frame.get_size()),Vector2i.ZERO)
	for x in [110,230,350]: _fill(pixels,Rect2i(x,8,8,24))
	_fill(pixels,Rect2i(264,12,176,16))
	_fill(pixels,Rect2i(438,12,32,16),Palette.RED.id)
	var bridge := _body("BG02_Bridge",Vector2(1186,2931),pixels,false)
	bridge.infinite_nails = PackedVector2Array([Vector2(468,20)])
	bridge.infinite_nail_body = true
	bridge.infinite_fuel_body = true
	var guide := _guide("BG02",Vector2(1168,2963),Vector2i(380,12),Vector2(1172,2969),Vector2(1542,2969))
	_rect("BG02_LeftStop",Vector2(840,2939),Vector2i(12,32),true,Palette.YELLOW.id)
	_rect("BG02_RightStop",Vector2(1666,2939),Vector2i(12,32),true,Palette.YELLOW.id)
	_pin("BG02",Vector2(1506,2969))
	var approach := _image(Vector2i(81,52))
	for x in 81: _fill(approach,Rect2i(x,roundi(x*44.0/80.0),1,52-roundi(x*44.0/80.0)))
	_body("BG02_Approach",Vector2(1666,2931),approach,true)
	_wire_on("BG02_Wire",bridge,[[Vector2(442,20),Vector2(414,20)]])
	# 桥上留出长度150、宽24的纯黑绘制区；尾部蓝线接触玩家画出的向左箭头。
	_canvas("BridgeLessonCanvas",Rect2(1260,2810,490,230))
	_note("Bridge",Vector2(1370,2805),"② 蓝墨·形状→矩形：画向左箭头\n从红墨旁向沟槽拖动，再按「固化」")
	for note in level.get_node("MapTexts").get_children():
		if note is Label and note.text.begins_with("02"): note.position = Vector2(1370,2770)
	level.get_node("Reserved_02_ExtendingBridge").set_meta("mechanism_installed",true)

func _frame(size_: Vector2i, width: int) -> Image:
	var image := _image(size_)
	_fill(image,Rect2i(0,0,size_.x,width))
	_fill(image,Rect2i(0,size_.y-width,size_.x,width))
	_fill(image,Rect2i(0,0,width,size_.y))
	_fill(image,Rect2i(size_.x-width,0,width,size_.y))
	return image

func _battery(item: Node, local: Vector2) -> void:
	item.infinite_nails = PackedVector2Array([local])
	item.infinite_nail_body = true
	item.infinite_fuel_body = true

func _motor_on(title: String, carrier: Node, local: Vector2, vector: Vector2, width := 9) -> void:
	var motor := Motor.new()
	motor.name = title
	motor.position = carrier.position + local.rotated(carrier.rotation)
	motor.rotation = carrier.rotation
	motor.tip = vector
	motor.brush_width = width
	motor.active = true
	motor.source_canvas = NodePath("MapCanvas/CanvasSurface")
	_own(motor)

func _axle(title: String, carrier: Node, support: Node, pin: Vector2, support_material := 1) -> void:
	var axle := Axle.new()
	axle.name = title
	axle.explicit = true
	axle.fixed_to_world = false
	axle.gear_material = Palette.BLACK.id
	axle.support_material = support_material
	axle.wheel_path = NodePath("../"+str(carrier.name))
	axle.support_path = NodePath("../"+str(support.name))
	axle.yellow_position = pin
	axle.black_position = pin
	axle.wheel_local = (pin-carrier.position).rotated(-carrier.rotation)
	axle.support_local = (pin-support.position).rotated(-support.rotation)
	axle.saved_local_anchors = true
	_own(axle)
func _rotating_ramp() -> void:
	var pixels := _image(Vector2i(636,174))
	var frame := _frame(Vector2i(636,32),7)
	pixels.blit_rect(frame,Rect2i(Vector2i.ZERO,frame.get_size()),Vector2i.ZERO)
	for x in [110,230,350,470]: _fill(pixels,Rect2i(x,7,7,18))
	_fill(pixels,Rect2i(10,5,24,24))
	# 下悬力臂给向上箭头留出完整黑墨承载面，不在可行走桥面上竖立挡柱。
	_fill(pixels,Rect2i(460,25,28,149))
	_fill(pixels,Rect2i(452,25,44,56))
	_fill(pixels,Rect2i(436,144,28,20),Palette.RED.id)
	var ramp := _body("BG03_Ramp",Vector2(330,2284),pixels,false)
	_battery(ramp,Vector2(442,154))
	var pedestal := _rect("BG03_Pivot",Vector2(338,2290),Vector2i(24,86),true,Palette.YELLOW.id)
	_axle("BG03_Axle",ramp,pedestal,Vector2(350,2300),Palette.YELLOW.id)
	var tail := Node2D.new()
	tail.set_script(ShapeNode)
	tail.name = "CounterLever"
	tail.source = 3
	tail.position = Vector2(-80,6)
	tail.paint = _image(Vector2i(100,20))
	_fill(tail.paint,Rect2i(0,0,100,20))
	_own(tail,ramp)
	_rect("BG03_LowerCradle",Vector2(940,2316),Vector2i(24,30),true,Palette.YELLOW.id)
	# 仅托住后臂远端。支座延伸到轴边会提前碰到后臂内侧，造成反复顶撞。
	var raised_rest := _rect("BG03_RaisedRest",Vector2(259.49,2343.68),Vector2i(28,16),true,Palette.YELLOW.id)
	raised_rest.rotation = -0.35
	_motor_on("BG03_Motor",ramp,Vector2(474,144),Vector2(0,-110),20)
	# 红墨只从一侧接入蓝线，避免多面回灌互相抵消；中间保留竖向补线口。
	_wire_on("BG03_Wire",ramp,[[Vector2(472,154),Vector2(472,154)],[Vector2(474,130),Vector2(474,130)]],17)
	_canvas("RampLessonCanvas",Rect2(490,2200,520,380))
	_note("Ramp",Vector2(480,2160),"③ 走上平桥，在下悬力臂底部补蓝线\n远端向上推，桥就转成上坡；末端短跳上岸")
	level.get_node("Reserved_03_RotatingRamp").set_meta("mechanism_installed",true)

func _crates() -> void:
	_guide("BG04_Shared",Vector2(720,1778),Vector2i(840,10),Vector2(724,1783),Vector2(1555,1783))
	for spec in [["Tall",Vector2(1100,1578),208],["Short",Vector2(1380,1682),104]]:
		var title: String = "BG04_"+spec[0]
		var height_: int = spec[2]
		var image := _frame(Vector2i(160,height_),8)
		var mid := height_/2
		_fill(image,Rect2i(12,mid-8,140,16))
		_fill(image,Rect2i(140,mid-8,18,16),Palette.RED.id)
		var box := _body(title,spec[1],image,false)
		_battery(box,Vector2(155,mid))
		_motor_on(title+"_Motor",box,Vector2(126,mid),Vector2(-105,0),7)
		_wire_on(title+"_Wire",box,[[Vector2(140,mid),Vector2(138,mid)],[Vector2(126,mid),Vector2(123,mid)]])
		_pin(title,box.position+Vector2(80,height_-3))
	# 高箱先碰左挡块；矮箱靠在高箱右侧，两个箱体本身组成台阶。
	_rect("BG04_TallStop",Vector2(718,1586),Vector2i(12,56),true,Palette.YELLOW.id)
	_rect("BG04_TallStart",Vector2(1262,1586),Vector2i(12,56),true,Palette.YELLOW.id)
	_rect("BG04_ShortStart",Vector2(1542,1690),Vector2i(12,56),true,Palette.YELLOW.id)
	_canvas("CrateLessonCanvas",Rect2(1070,1580,520,290))
	_note("Crates",Vector2(1060,1525),"④ 补齐两只箱子的蓝线，等它们靠停\n再从右往左跳：矮箱 → 高箱 → 岸台")
	level.get_node("Reserved_04_CrateSteps").set_meta("mechanism_installed",true)

func _lift() -> void:
	var pixels := _image(Vector2i(300,180))
	var deck := _frame(Vector2i(270,28),7)
	pixels.blit_rect(deck,Rect2i(Vector2i.ZERO,deck.get_size()),Vector2i.ZERO)
	_fill(pixels,Rect2i(234,6,36,174))
	_fill(pixels,Rect2i(258,10,40,12))
	var lift := _body("BG05_Platform",Vector2(1054,1265),pixels,false)
	var curbs := Node2D.new()
	curbs.set_script(ShapeNode)
	curbs.name = "EdgeCurbs"
	curbs.position = Vector2(0,-14)
	curbs.source = 3
	curbs.paint = _image(Vector2i(270,14))
	_fill(curbs.paint,Rect2i(0,0,8,14))
	_fill(curbs.paint,Rect2i(262,0,8,14))
	_own(curbs,lift)
	var feed_image := _image(Vector2i(36,780))
	_fill(feed_image,Rect2i(0,0,20,780))
	_fill(feed_image,Rect2i(20,0,16,755),Palette.YELLOW.id)
	_fill(feed_image,Rect2i(0,752,18,24),Palette.RED.id)
	var feed := _body("BG05_PowerBand",Vector2(1314,700),feed_image,true)
	_rail("BG05",Vector2(1342,708),Vector2(1342,1450),16)
	_pin("BG05",Vector2(1342,1280))
	_rect("BG05_TopStop",Vector2(1330,708),Vector2i(32,16),true,Palette.YELLOW.id)
	_rect("BG05_BottomStop",Vector2(1330,1287),Vector2i(32,16),true,Palette.YELLOW.id)
	_battery(feed,Vector2(10,764))
	_wire_on("BG05_FeedWire",feed,[[Vector2(2,752),Vector2(2,742)],[Vector2(2,728),Vector2(2,8)]],7)
	_wire_on("BG05_ContactWire",lift,[[Vector2(262,12),Vector2(262,150),Vector2(252,150)]])
	_motor_on("BG05_Motor",lift,Vector2(252,150),Vector2(0,-140),16)
	# 与箱体画布保持110px间隔，避免连续画布分组把箱区工具栏拉出视口。
	_canvas("LiftLessonCanvas",Rect2(1090,1120,420,350))
	_note("Lift",Vector2(880,1080),"⑤ 先站上升降台，再补右侧导电带断口")
	level.get_node("Reserved_05_ShortLift").set_meta("mechanism_installed",true)

func _finale() -> void:
	# 两条短回路各自补齐，桥轴供电座藏在岸台下方，保持转层通路净空。
	var feed_image := _image(Vector2i(100,110))
	_fill(feed_image,Rect2i(0,50,100,40))
	_fill(feed_image,Rect2i(68,0,20,100))
	var feed := _body("BG06_PowerFrame",Vector2(1060,440),feed_image,true)
	var flap_image := _image(Vector2i(340,112))
	var deck := _frame(Vector2i(340,32),7)
	flap_image.blit_rect(deck,Rect2i(Vector2i.ZERO,deck.get_size()),Vector2i.ZERO)
	_fill(flap_image,Rect2i(14,12,12,20))
	_fill(flap_image,Rect2i(14,12,258,8))
	_fill(flap_image,Rect2i(100,12,22,98))
	_fill(flap_image,Rect2i(232,25,26,85))
	_fill(flap_image,Rect2i(100,90,150,22))
	_fill(flap_image,Rect2i(218,90,18,20),Palette.RED.id)
	var start_angle := 0.8
	var pin := Vector2(1140,451)
	var flap := _body("BG06_Flap",pin-Vector2(20,16).rotated(start_angle),flap_image,false)
	flap.rotation = start_angle
	_battery(flap,Vector2(226,100))
	var tail := Node2D.new()
	tail.set_script(ShapeNode)
	tail.name = "RestingHeel"
	tail.source = 3
	tail.position = Vector2(-100,0)
	tail.paint = _image(Vector2i(100,32))
	_fill(tail.paint,Rect2i(0,0,100,32))
	_own(tail,flap)
	_axle("BG06_Axle",flap,feed,pin)
	_rect("BG06_LoweredRest",Vector2(1320,692),Vector2i(66,16),true,Palette.YELLOW.id)
	_rect("BG06_RaisedRest",Vector2(1018,467),Vector2i(28,14),true,Palette.YELLOW.id)
	_motor_on("BG06_FlapMotor",flap,Vector2(244,100),Vector2(0,-70),10)
	_wire_on("BG06_FlapWire",flap,[[Vector2(236,100),Vector2(236,100)],[Vector2(244,100),Vector2(244,30)]],1)
	var door_image := _image(Vector2i(244,240))
	var door_frame := _frame(Vector2i(64,240),7)
	door_image.blit_rect(door_frame,Rect2i(Vector2i.ZERO,door_frame.get_size()),Vector2i(180,0))
	_fill(door_image,Rect2i(199,0,26,240))
	_fill(door_image,Rect2i(200,4,24,24))
	_fill(door_image,Rect2i(0,214,224,18))
	_fill(door_image,Rect2i(10,214,24,18),Palette.RED.id)
	var door := _body("BG06_Gate",Vector2(1274,241),door_image,false)
	_battery(door,Vector2(16,223))
	_guide("BG06_Gate",Vector2(1478,54),Vector2i(16,230),Vector2(1486,64),Vector2(1486,274))
	_pin("BG06_Gate",Vector2(1486,251))
	_rect("BG06_GateTop",Vector2(1470,45),Vector2i(32,16),true,Palette.YELLOW.id)
	_wire_on("BG06_GateWire",door,[[Vector2(34,223),Vector2(40,223)],
		[Vector2(52,223),Vector2(212,223),Vector2(212,8)]])
	_motor_on("BG06_GateMotor",door,Vector2(212,222),Vector2(0,-165),10)
	# 岸台退到桥尖扫掠范围之外，避免从下方抬桥时撞住岸壁。
	_rect("BG06_ArrivalLanding",Vector2(1470,481),Vector2i(100,16),true)
	_canvas("FinalLessonCanvas",Rect2(960,330,510,400))
	_note("Finale",Vector2(920,285),"⑥ 补桥臂上的断线，再补门扇左侧断线\n两条短回路：抬桥、开门，再走向终点")
	var finish := Node2D.new()
	finish.name = "BG06_Finish"
	finish.set_script(load("res://map/src/blue_ascent_finish.gd"))
	finish.position = Vector2(1840,202)
	finish.set_meta("blue_ascent_finish",true)
	_own(finish)
	level.get_node("Reserved_06_BridgeAndGate").set_meta("mechanism_installed",true)

func _smooth_connections() -> void:
	_rect("BG05_TurnStepA",Vector2(200,655),Vector2i(300,24),true)
	_rect("BG05_TurnStepB",Vector2(60,604),Vector2i(200,24),true)
	_note("Turn",Vector2(440,770),"转层路线 ← 沿左侧缓坡上行，再短跳回右侧上层")
	# 旋转的黑墨面板覆盖长斜坡的像素台阶，避免刚体脚尖卡住横向像素边。
	for spec in [["01",Vector2(580,3696),Vector2(1420,3232)],
		["02",Vector2(260,2623),Vector2(760,2971)],
		["05_A",Vector2(500,651),Vector2(740,738)],
		["05_B",Vector2(260,600),Vector2(500,651)],
		["06",Vector2(1520,477),Vector2(1820,260)]]:
		var vector: Vector2 = spec[2]-spec[1]
		var body := _rect("BG"+spec[0]+"_SmoothRamp",spec[1],Vector2i(ceili(vector.length())+1,14),true)
		body.rotation = vector.angle()
