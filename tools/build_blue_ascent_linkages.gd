extends "res://tools/build_blue_ascent_machines.gd"
## 仅离线构建墨水组件；关卡内没有专用运动、按键或限位脚本。
const Spring := preload("res://ink/yellow/src/stroke.gd")

func _lesson_width(title: String) -> int:
	return 24 if title=="LiftLessonCanvas" else (20 if title=="FinalLessonCanvas" else (12 if title=="CrateLessonCanvas" else 7))

func _clear_upper_turn() -> void:
	super._clear_upper_turn()
	var creative=level.get_node("Creative")
	var draft:Dictionary=creative.editor_draft.duplicate(true)
	var image:=Image.new()
	assert(image.load_png_from_buffer(draft.black)==OK)
	var origin:=Vector2i(level.get_node("MapCanvas").position)
	# 薄化原电梯出口台下缘，给弹射落点和角色头顶留出空间。
	image.fill_rect(Rect2i(Vector2i(650,766)-origin,Vector2i(430,110)),Color.TRANSPARENT)
	image.fill_rect(Rect2i(Vector2i(850,742)-origin,Vector2i(230,134)),Color.TRANSPARENT)
	draft.black=image.save_png_to_buffer()
	creative.editor_draft=draft

func _spring(title: String, a: Vector2, b: Vector2, width: int) -> void:
	var spring := Spring.new()
	spring.name = title
	spring.path = PackedVector2Array([a,b])
	spring.saved_anchor_a = a
	spring.saved_anchor_b = b
	spring.rest_length = a.distance_to(b)
	spring.brush_width = width
	spring.compact_raster = true
	spring.dashed = true
	spring.activated = true
	spring.source_canvas = NodePath("MapCanvas/CanvasSurface")
	_own(spring)

func _reinforce(item: Node, point: Vector2) -> void:
	item.infinite_nails = PackedVector2Array([point])
	item.infinite_nail_body = true

func _ink_seal(title:String, carrier:Node, local:Vector2, anchor:Vector2, width:int) -> void:
	# 预拉黄墨保险簧抵住脚部推力；蓝墨继续拉伸后按现有弹簧过载规则断开。
	var fixture:=_rect(title+"_Anchor",anchor-Vector2(12,12),Vector2i(24,24),true)
	_reinforce(fixture,Vector2(12,12))
	_spring(title,anchor,carrier.position+local,width)
	var seal=level.get_node(title)
	seal.rest_length-=180.0
	# 实际预磨损窄颈使保险簧在过载后快速断开，不更改全局磨损或强度规则。
	var cut_x:=floori(anchor.distance_to(carrier.position+local)*0.5/14.0)*14+4
	for x in range(cut_x-1,cut_x+2):
		for y in range(-width,width+1):
			if y!=0: seal.worn.append(Vector2(x,y))

func _bridge() -> void:
	super._bridge()
	_ink_seal("BG02_Seal",level.get_node("BG02_Bridge"),Vector2(472,20),Vector2(1900,2951),12)
	level.get_node("MachineNote_Bridge").text+="\n蓝墨动力拉断黄墨保险簧后伸桥；小人不能直接推走"

func _crates() -> void:
	_guide("BG04_Shared",Vector2(720,1778),Vector2i(840,10),Vector2(724,1783),Vector2(1555,1783))
	for spec in [["Tall",Vector2(1100,1578),208],["Short",Vector2(1262,1682),104]]:
		var title: String = "BG04_"+spec[0]
		var height_: int = spec[2]
		var image := _frame(Vector2i(160,height_),8)
		# 两个内侧实心安装座位于同一高度，黄墨弹簧可跨箱连接。
		var mount_x := 144 if spec[0]=="Tall" else 0
		_fill(image,Rect2i(mount_x,1728-int(spec[1].y),16,24))
		if spec[0]=="Tall":
			_fill(image,Rect2i(12,88,146,32))
			_fill(image,Rect2i(140,88,18,32),Palette.RED.id)
		var box := _body(title,spec[1],image,false)
		_reinforce(box,Vector2(5,5))
		if spec[0]=="Tall":
			_battery(box,Vector2(151,104))
			_wire_on(title+"_Wire",box,[[Vector2(139,104),Vector2(126,104)]],1)
		_pin(title,box.position+Vector2(80,height_-3))
	_rect("BG04_TallStop",Vector2(718,1586),Vector2i(12,56),true,Palette.YELLOW.id)
	_rect("BG04_TallStart",Vector2(1262,1586),Vector2i(12,56),true,Palette.YELLOW.id)
	_rect("BG04_ShortStart",Vector2(1424,1690),Vector2i(12,56),true,Palette.YELLOW.id)
	_ink_seal("BG04_TallSeal",level.get_node("BG04_Tall"),Vector2(152,12),Vector2(1540,1590),12)
	_ink_seal("BG04_ShortSeal",level.get_node("BG04_Short"),Vector2(152,18),Vector2(1680,1700),9)
	_canvas("CrateLessonCanvas",Rect2(1070,1580,460,290))
	_note("Crates",Vector2(1050,1500),"④ 黄墨画笔 12px：连接两箱内侧加厚黑座\n蓝墨矩形 7–12px：在红墨左侧画向左箭头，固化\n蓝墨拉断保险簧，高箱牵引矮箱；停稳后从右往左跳")
	_note("CrateSpring",Vector2(1150,1760),"黄墨连接两座 ↑")
	_note("CrateArrow",Vector2(1100,1635),"← 蓝箭头，接红墨端子")
	level.get_node("Reserved_04_CrateSteps").set_meta("mechanism_installed",true)

func _lift() -> void:
	var at := Vector2(1054,1090)
	var image := _image(Vector2i(460,220))
	var deck := _frame(Vector2i(270,24),7)
	image.blit_rect(deck,Rect2i(Vector2i.ZERO,deck.get_size()),Vector2i.ZERO)
	_fill(image,Rect2i(263,16,32,126))
	_fill(image,Rect2i(212,24,32,24))
	# 驱动臂只保留箭头需要的实体轮廓，减少无用配重。
	for y in range(126,213):
		var radius:=ceili(31.0*(212-y)/86.0)
		_fill(image,Rect2i(278-radius,y,radius*2+1,1))
	_fill(image,Rect2i(258,10,200,12))
	_fill(image,Rect2i(270,27,84,18))
	_fill(image,Rect2i(278,78,30,12))
	var platform := _body("BG05_Platform",at,image,false)
	_reinforce(platform,Vector2(5,5))
	_guide("BG05",Vector2(1430,1078),Vector2i(16,280),Vector2(1438,1082),Vector2(1438,1350))
	_pin("BG05",Vector2(1438,1105))
	# 挡块只接触右侧销舌，避开下悬驱动臂；导轨也避开脚踏配重的摆动范围。
	# 独立厚挡块与导轨、脚踏接点保持净距，快速回弹也不会越过轨端。
	_rect("BG05_TopStop",Vector2(1460,1040),Vector2i(60,60),true)
	_rect("BG05_BottomStop",Vector2(1460,1307),Vector2i(60,48),true)
	_rect("BG05_SpringBase",Vector2(1060,1520),Vector2i(60,24),true)
	_rect("BG05_SpringBaseRight",Vector2(1280,1520),Vector2i(40,24),true)
	_spring("BG05_LeftSpring",Vector2(1086,1530),at+Vector2(32,20),33)
	_spring("BG05_RightSpring",Vector2(1300,1530),at+Vector2(246,20),33)
	# 脚踏杠杆与踏台铰接；红墨通过远端窄接点供电。
	var pedal_image := _image(Vector2i(250,160))
	_fill(pedal_image,Rect2i(0,0,60,10))
	_fill(pedal_image,Rect2i(52,0,10,68))
	_fill(pedal_image,Rect2i(52,56,88,12))
	_fill(pedal_image,Rect2i(140,60,100,7))
	_fill(pedal_image,Rect2i(166,60,4,80))
	_fill(pedal_image,Rect2i(166,140,10,15),Palette.RED.id)
	# 踏板位于轴左侧，按下时向左倾斜，回位时向左上推送。
	# 向左加宽踏面，给角色在弹起前带出横向速度的站立距离。
	var wide_pedal:=_image(Vector2i(310,160))
	wide_pedal.blit_rect(pedal_image,Rect2i(Vector2i.ZERO,pedal_image.get_size()),Vector2i(60,0))
	_fill(wide_pedal,Rect2i(0,0,60,10))
	var pedal := _body("BG05_Pedal",at+Vector2(60,-28),wide_pedal,false)
	_reinforce(pedal,Vector2(15,5))
	_battery(pedal,Vector2(230,146))
	_axle("BG05_PedalAxle",pedal,platform,at+Vector2(224,36),Palette.BLACK.id)
	# 弹簧座由两枚普通轴钉固定在踏台上；回位弹簧不跨接轴承的同一对刚体。
	var mount := _rect("BG05_ReturnMount",at+Vector2(300,76),Vector2i(28,12),false)
	_reinforce(mount,Vector2(6,6))
	_axle("BG05_MountA",mount,platform,at+Vector2(306,80),Palette.BLACK.id)
	_axle("BG05_MountB",mount,platform,at+Vector2(304,86),Palette.BLACK.id)
	_spring("BG05_PedalReturn",at+Vector2(314,82),at+Vector2(140,-22),30)
	# 拉簧经过转轴死点辅助保持断开；不用时序、按键或角度钳制。
	level.get_node("BG05_PedalReturn").rest_length-=60.0
	var open_seat:=_rect("BG05_OpenSeat",at+Vector2(96,20),Vector2i(40,10),false)
	_reinforce(open_seat,Vector2(5,5))
	_axle("BG05_OpenA",open_seat,platform,at+Vector2(100,21),Palette.BLACK.id)
	_axle("BG05_OpenB",open_seat,platform,at+Vector2(125,21),Palette.BLACK.id)
	var seat:=_rect("BG05_ContactSeat",at+Vector2(314,39),Vector2i(24,12),false)
	_reinforce(seat,Vector2(5,5))
	_axle("BG05_SeatA",seat,platform,at+Vector2(322,40),Palette.BLACK.id)
	_axle("BG05_SeatB",seat,platform,at+Vector2(332,40),Palette.BLACK.id)
	_wire_on("BG05_ContactWire",platform,[[Vector2(278,112),Vector2(278,132)]],15)
	# 落台低于上挡块50px，右沿退出上升通道，留足容错；缓坡接回原出口。
	_rect("BG05_CatchLanding",Vector2(850,1140),Vector2i(190,24),true)
	var ascent:=Vector2(700,742)-Vector2(1315,1140)
	var return_ramp:=_rect("BG05_ReturnRamp",Vector2(1315,1140)-ascent.normalized().orthogonal()*14.0,Vector2i(ceili(ascent.length())+1,14),true)
	return_ramp.rotation=ascent.angle()
	_reinforce(return_ramp,Vector2(5,5))
	_canvas("LiftLessonCanvas",Rect2(1040,1070,490,400))
	_note("Lift",Vector2(580,1100),"蓝墨矩形 24px\n右侧黑臂画向下箭头，固化\n等踏台压低，踏上凸起板\n红端子断开，弹簧向上释放\n上升时向左走，落台后沿坡上层")
	_note("LaunchArrow",Vector2(1375,1170),"蓝箭头\n向下 ↓")
	_note("LaunchExit",Vector2(770,970),"弹射落点 ←")
	# 利用原关卡右侧空白安放跳台，让缓坡避开弹射上升通道；不扩大地图边界。
	var offset:=Vector2(400,0)
	for node in level.get_children():
		if not str(node.name).begins_with("BG05_") or node==return_ramp: continue
		if node is Spring:
			for i in node.path.size(): node.path[i]+=offset
			node.saved_anchor_a+=offset
			node.saved_anchor_b+=offset
		elif node is Rail:
			node.saved_a+=offset
			node.saved_b+=offset
		elif node is SliderPin:
			node.saved_source+=offset
			node.saved_position+=offset
		elif node is Axle:
			node.yellow_position+=offset
			node.black_position+=offset
		elif node is Node2D:
			node.position+=offset
	for title in ["LiftLessonCanvas","MachineNote_Lift","MachineNote_LaunchArrow","MachineNote_LaunchExit"]:
		level.get_node(title).position+=offset
	_rect("BG05_Approach",Vector2(1054,1265),Vector2i(400,20),true)
	level.get_node("Reserved_05_ShortLift").set_meta("mechanism_installed",true)

func _finale() -> void:
	var feed_image := _image(Vector2i(100,110))
	_fill(feed_image,Rect2i(0,50,100,40))
	_fill(feed_image,Rect2i(68,0,20,100))
	var feed := _body("BG06_PowerFrame",Vector2(1060,440),feed_image,true)
	var image := _image(Vector2i(340,180))
	var deck := _frame(Vector2i(340,32),7)
	image.blit_rect(deck,Rect2i(Vector2i.ZERO,deck.get_size()),Vector2i.ZERO)
	_fill(image,Rect2i(14,12,258,8))
	_fill(image,Rect2i(100,12,22,160))
	_fill(image,Rect2i(100,150,166,22))
	_fill(image,Rect2i(218,12,54,168))
	_fill(image,Rect2i(286,12,28,88))
	_fill(image,Rect2i(218,150,18,20),Palette.RED.id)
	var angle := 0.65
	var pivot := Vector2(1140,451)
	var bridge := _body("BG06_Flap",pivot-Vector2(20,16).rotated(angle),image,false)
	_reinforce(bridge,Vector2(120,14))
	bridge.rotation = angle
	_battery(bridge,Vector2(226,160))
	var heel := Node2D.new()
	heel.set_script(ShapeNode)
	heel.name = "RestingHeel"
	heel.source = 3
	heel.position = Vector2(-100,0)
	heel.paint = _image(Vector2i(120,32))
	_fill(heel.paint,Rect2i(0,0,120,32))
	_own(heel,bridge)
	_axle("BG06_Axle",bridge,feed,pivot)
	_rect("BG06_LoweredRest",Vector2(1370,658),Vector2i(50,14),true,Palette.YELLOW.id)
	_rect("BG06_RaisedRest",Vector2(1018,467),Vector2i(28,14),true,Palette.YELLOW.id)
	_rect("BG06_SpringAnchor",Vector2(948,468),Vector2i(24,24),true)
	_wire_on("BG06_FlapWire",bridge,[[Vector2(238,160),Vector2(250,160),Vector2(250,24)]],5)
	var door_image := _image(Vector2i(64,272))
	var frame := _frame(Vector2i(64,240),7)
	door_image.blit_rect(frame,Rect2i(Vector2i.ZERO,frame.get_size()),Vector2i(0,32))
	_fill(door_image,Rect2i(20,0,24,272))
	var door := _body("BG06_Gate",Vector2(1454,209),door_image,false)
	_reinforce(door,Vector2(32,6))
	_guide("BG06_Gate",Vector2(1478,54),Vector2i(16,230),Vector2(1486,64),Vector2(1486,274))
	_pin("BG06_Gate",Vector2(1486,251))
	_rect("BG06_GateTop",Vector2(1470,16),Vector2i(32,13),true,Palette.YELLOW.id)
	var crank := bridge.position+Vector2(300,80).rotated(angle)
	var gate_point := Vector2(1486,215)
	# 正常黄墨压簧无碰撞，桥抬起时受压推门；无动力时初始压力小于门重。
	_spring("BG06_ConnectingSpring",crank,gate_point,50)
	level.get_node("BG06_ConnectingSpring").rest_length+=18.0
	_rect("BG06_ArrivalLanding",Vector2(1470,481),Vector2i(100,16),true)
	_canvas("FinalLessonCanvas",Rect2(900,300,630,480))
	_note("Finale",Vector2(890,275),"⑥ 黄墨 12px：左岸座连接桥后臂，做回位弹簧\n蓝墨矩形 20px：走到桥中段，顺黑臂朝桥面画箭头，接红墨端子\n一处动力抬桥，黄色压簧同步提门；停稳后通过")
	var finish := Node2D.new()
	finish.name = "BG06_Finish"
	finish.set_script(load("res://map/src/blue_ascent_finish.gd"))
	finish.position = Vector2(1840,202)
	finish.set_meta("blue_ascent_finish",true)
	_own(finish)
	level.set_meta("blue_ascent_compound_ink",true)
	# 本关黄墨使用少量物理阻尼，抑制持续供电时的反复振荡；不设置运动终点。
	var simulation=level.get_node("SimulationRuntime")
	var tuning:Resource=simulation.tuning_config.duplicate(true)
	tuning.yellow_damping_ratio=0.08
	simulation.tuning_config=tuning
	# 承受持续驱动力的支座安装真实无限钉，避免挡块掉墨后误变成自行弹射。
	for title in ["BG04_TallStop","BG04_TallStart","BG04_ShortStart","BG05_TopStop","BG05_BottomStop","BG05_SpringBase","BG05_SpringBaseRight","BG05_Guide","BG05_CatchLanding","BG05_Approach","BG06_LoweredRest","BG06_RaisedRest","BG06_GateTop"]:
		_reinforce(level.get_node(title),Vector2(5,5))
	for label in level.get_node("MapTexts").get_children():
		if label is Label:
			if label.text.begins_with("04"): label.text="04  弹簧牵引 ←"
			elif label.text.begins_with("05"):
				label.text="05  蓄能弹射 ↑"
				label.position=Vector2(980,1070)
			elif label.text.begins_with("06"): label.text="06  单源联动 →"
	level.get_node("Reserved_06_BridgeAndGate").set_meta("mechanism_installed",true)
