extends "res://tools/build_terrain_pages.gd"
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Bearing := preload("res://actor/canvas/src/gear_bearing.gd")
const GearTool := preload("res://actor/canvas/src/gear_tool.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const Spring := preload("res://ink/yellow/src/stroke.gd")
const Machine := preload("res://map/src/ink_machine_checkpoint.gd")

func _initialize() -> void:
	_build.call_deferred()

func _build() -> void:
	var backup := "res://.level_backups/ink-machines-"+str(Time.get_unix_time_from_system()).replace(".","-")
	assert(DirAccess.make_dir_recursive_absolute(backup)==OK)
	for title in PAGES:
		var path: String = "res://map/asset/imported/"+title+".tscn"
		assert(DirAccess.copy_absolute(path,backup+"/"+title+".tscn")==OK)
		var source := path
		for argument in OS.get_cmdline_user_args():
			if argument.begins_with("--baseline="):
				source = argument.trim_prefix("--baseline=")+"/"+title+".tscn"
		level = load(source).instantiate()
		if level.has_node("Transmission"):
			push_error("已存在机构，拒绝重复追加")
			quit(1)
			return
		for child in level.get_node("MapTexts").get_children():
			child.free()
		var paths: Array[NodePath] = []
		if title == "第二页":
			_gears(Vector2(2300,400),Vector2(2930,530))
			_lever(Vector2(4750,520),Vector2(5200,300))
			_canvas("TransmissionCanvas",Rect2(1950,160,1200,650))
			_canvas("LeverCanvas",Rect2(4510,250,1000,550))
			paths.assign([NodePath("../Transmission"),NodePath("../Balance")])
			_text(Vector2(30,400),"第二页 · 传动开路\n补蓝线带动齿轮，再画配重压下黄杆。两盏灯亮后出口解锁。",19)
			_monster("res://actor/monster/great_shield.tscn","TransmissionGuard",Vector2(2870,666),0.4)
			_monster("res://actor/monster/great_shield.tscn","BalanceGuard",Vector2(4590,620),0.4)
			_text(Vector2(2010,625),"守卫挡着正面？画长柄钩、搭高台，或把它引开。",16)
		else:
			_clear_terrain(Rect2(710,1410,111,90))
			_clear_terrain(Rect2(1780,410,101,110))
			if level.has_node("Terrain_FirstFoothold"):
				level.get_node("Terrain_FirstFoothold").free()
			if level.has_node("Terrain_FinalFoothold"):
				level.get_node("Terrain_FinalFoothold").free()
			_elevator(Vector2(760,1478))
			_gears(Vector2(1900,300),Vector2(2320,292))
			_canvas("LiftCanvas",Rect2(570,850,610,700))
			_canvas("TransmissionCanvas",Rect2(1540,80,1000,650))
			paths.assign([NodePath("../Elevator"),NodePath("../Transmission")])
			_text(Vector2(40,1170),"第三页 · 动力登顶\n先搭乘升降台，再接通山顶齿轮。\n途中绘制空心台阶，绕过灰色崖面。\n两盏灯亮后，山顶纸洞解锁。",19)
			_text(Vector2(1550,960),"画台阶向左上走；旧画作可回收再用。",17)
			_text(Vector2(310,660),"折返搭坡向右上走，接近传动站。",17)
			_monster("res://actor/monster/bomb_side.tscn","LedgeThrower",Vector2(1290,870),0.65)
			var thrower = level.get_node("Monsters/LedgeThrower")
			thrower.attack_cooldown_scale=4.0
			thrower.attack_windup_scale=1.8
			thrower.attack_range_scale=1.3
			_text(Vector2(1480,790),"抬手后才投掷：画带顶棚的台阶，挡住再走。\n不必击败它；也可诱导炸弹砸向你画的挡板。",16)
		level.get_node("PageExit").machine_paths = paths
		var packed := PackedScene.new()
		assert(packed.pack(level)==OK)
		var error := ResourceSaver.save(packed,path)
		for retry in 6:
			if error==OK: break
			await create_timer(0.3).timeout
			error=ResourceSaver.save(packed,path)
		assert(error==OK)
		print("[InkMachines] saved ",title," backup=",backup)
		level.free()
	quit()

func _clear_terrain(rect: Rect2) -> void:
	# 编辑器保存后地形会拆成 InkXX 像素块，按世界范围清理指定旧落脚点。
	for node in level.get_children():
		if not node.is_in_group("ink_item"): continue
		for shape in node.get_children():
			if not shape is ShapeNode or shape.paint == null: continue
			var origin: Vector2 = node.position + shape.position
			var overlap := rect.intersection(Rect2(origin,Vector2(shape.paint.get_size())))
			if not overlap.has_area(): continue
			var edited: Image = shape.paint.duplicate()
			edited.fill_rect(Rect2i(overlap.position-origin,overlap.size),Color(0,0,0))
			shape.paint=edited

func _wire(name_: String, body_position: Vector2, points: Array) -> void:
	var cells := {}
	for index in points.size()-1:
		var a: Vector2 = points[index]
		var b: Vector2 = points[index+1]
		for step in ceili(a.distance_to(b))+1:
			var p := Vector2i(a.lerp(b,float(step)/maxf(1,a.distance_to(b))))
			for x in 7:
				for y in 7: cells[p+Vector2i(x,y)]=true
	var wire := Wire.new()
	wire.name=name_
	wire.position=body_position
	wire.cells=PackedVector2Array(cells.keys())
	wire.active=true
	_own(wire)

func _bearing(name_: String, wheel: Node2D, center: Vector2, ink: int, fixed := true) -> void:
	var bearing := Bearing.new()
	bearing.name=name_
	bearing.wheel_path=NodePath("../"+str(wheel.name))
	bearing.yellow_position=center
	bearing.black_position=center
	bearing.gear_material=ink
	bearing.fixed_to_world=fixed
	_own(bearing)

func _gear(name_: String, center: Vector2, ink: int, phase := 0.0) -> Node2D:
	var pixels:=_image(Vector2i(223,223))
	var polygon:=GearTool.outline(110,12)
	for i in polygon.size(): polygon[i]=polygon[i].rotated(phase)+Vector2(111,111)
	for y in 223:
		for x in 223:
			if Geometry2D.is_point_in_polygon(Vector2(x,y),polygon):
				pixels.set_pixel(x,y,Color(float(ink)/255.0,0,0))
	return _body(name_,center-Vector2(111,111),pixels,false)

func _motor(name_: String, origin: Vector2, tip_: Vector2) -> void:
	var motor:=Motor.new()
	motor.name=name_
	motor.position=origin
	motor.tip=tip_
	motor.brush_width=7
	motor.active=true
	motor.paid=true
	_own(motor)

func _checkpoint_machine(name_: String, kind_: int, moving: String, motor: String, gate: String, at: Vector2, distance_: float) -> void:
	var machine:=Machine.new()
	machine.name=name_
	machine.kind=kind_
	machine.moving_path=NodePath("../"+moving)
	if not motor.is_empty(): machine.motor_path=NodePath("../"+motor)
	if not gate.is_empty(): machine.gate_path=NodePath("../"+gate)
	machine.position=at
	machine.travel=distance_
	_own(machine)

func _gears(center: Vector2, door: Vector2) -> void:
	# 黑色 L 形支架把燃料槽接到轴心；中间留 40px 蓝线断口。
	var origin:=center+Vector2(-180,0)
	var support:=_image(Vector2i(192,172))
	_fill(support,Rect2i(174,0,18,172))
	_fill(support,Rect2i(0,150,192,22))
	_fill(support,Rect2i(16,148,84,2),Palette.RED.id)
	_body("PowerSupport",origin,support)
	var driver:=_gear("DriverGear",center,1)
	var follower:=_gear("FollowerGear",center+Vector2(208,0),4,PI/12)
	_bearing("DriverBearing",driver,center,1,false)
	_bearing("FollowerBearing",follower,center+Vector2(208,0),4)
	_wire("SupplyWireB",origin,[Vector2(105,150),Vector2(180,150),Vector2(180,2)])
	_wire("WheelWire",driver.position,[Vector2(51,71),Vector2(111,71),Vector2(111,111)])
	_motor("GearMotor",center+Vector2(-60,-40),Vector2(120,0))
	_rect("GearGate",door,Vector2i(20,180),false,4).gravity_scale=0
	_checkpoint_machine("Transmission",0,"FollowerGear","GearMotor","GearGate",center+Vector2(-140,-135),200)
	_text(center+Vector2(-250,-215),"传动站：补齐蓝线断口 → 两齿轮转动 → 绿灯解锁\n红墨燃料已装好；不要砸燃料。黑墨可补支架。",16)
	# 玩家可站立操作，齿轮不作为可抓握的跨关捷径。
	_rect("TransmissionFloor",center+Vector2(-300,172),Vector2i(740,16))

func _lever(at: Vector2, door: Vector2) -> void:
	_rect("BalanceFloor",at+Vector2(-70,100),Vector2i(420,16))
	_rect("BalancePivot",at+Vector2(134,18),Vector2i(12,82))
	var image:=_image(Vector2i(280,20))
	_fill(image,Rect2i(0,0,280,20),Palette.YELLOW.id)
	_fill(image,Rect2i(14,0,20,20),1)
	var lever:=_body("BalanceLever",at,image,false)
	_bearing("BalanceBearing",lever,at+Vector2(140,10),Palette.YELLOW.id)
	var spring:=Spring.new()
	spring.name="BalanceSpring"
	spring.path=PackedVector2Array([at+Vector2(24,10),at+Vector2(24,108)])
	spring.saved_anchor_a=spring.path[0]
	spring.saved_anchor_b=spring.path[1]
	spring.rest_length=98
	spring.activated=true
	spring.paid=true
	spring.compact_raster=true
	spring.brush_width=3
	_own(spring)
	_rect("BalanceWeight",at+Vector2(-45,60),Vector2i(24,38),false,4)
	_rect("BalanceGate",door,Vector2i(20,180),false,4).gravity_scale=0
	_checkpoint_machine("Balance",1,"BalanceLever","","BalanceGate",at+Vector2(140,-100),200)
	_text(at+Vector2(-140,-180),"配重站：画重块压左端，或搭坡把盾兵推上黄杆\n主角本体不计入配重；也可搬灰块、用碎盾。",17)

func _elevator(at: Vector2) -> void:
	var pixels:=_image(Vector2i(240,190))
	_fill(pixels,Rect2i(0,170,240,10))
	_fill(pixels,Rect2i(200,0,22,180))
	_fill(pixels,Rect2i(40,168,98,2),Palette.RED.id)
	var platform:=_body("LiftPlatform",at-Vector2(0,170),pixels,false)
	_motor("LiftMotor",platform.position+Vector2(210,150),Vector2(0,-130))
	_motor("LiftMotorAssist",platform.position+Vector2(210,140),Vector2(0,-130))
	_rect("LiftSpringAnchor",Vector2(at.x+194,700),Vector2i(32,24))
	var spring := Spring.new()
	spring.name="LiftSpring"
	spring.path=PackedVector2Array([platform.position+Vector2(210,10),Vector2(at.x+210,712)])
	spring.saved_anchor_a=spring.path[0]
	spring.saved_anchor_b=spring.path[1]
	spring.rest_length=410
	spring.activated=true
	spring.paid=true
	spring.compact_raster=true
	spring.brush_width=24
	_own(spring)
	_wire("LiftWireB",platform.position,[Vector2(140,170),Vector2(210,170),Vector2(210,150)])
	_checkpoint_machine("Elevator",2,"LiftPlatform","LiftMotor","",at+Vector2(-45,-210),180)
	_text(at+Vector2(-150,-330),"升降站：站上平台，再补齐燃料端的蓝线\n蓝墨释放锁销，预紧黄弹簧助升；到位自动止回。",16)
