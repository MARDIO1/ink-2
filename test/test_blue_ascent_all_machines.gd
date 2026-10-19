extends "res://test/test_blue_ascent_machines.gd"

func repair(title: String, a: Vector2, b: Vector2) -> void:
	var canvas = level.get_node(title)
	canvas.surface.ink_free = true
	canvas.surface.brush_size = 7
	canvas.surface.blue_layer.begin(canvas.to_local(a)+Vector2(0.5,0.5))
	canvas.surface.blue_layer.extend(canvas.to_local(b)+Vector2(0.5,0.5))
	canvas.surface.blue_layer.finish()
	canvas.generate(false)

func ui(title: String, points: Array, center: Vector2) -> void:
	for zoom in [1.0,1.15]:
		camera.position = center
		camera.zoom = Vector2.ONE*zoom
		camera.force_update_scroll()
		await frames(30)
		await drawing_clear(level.get_node(title),points,title+" zoom="+str(zoom))

func remaining() -> void:
	var section := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--section="): section=arg.trim_prefix("--section=")
	if section in ["","ramp"]: await test_ramp()
	if section in ["","crates"]: await test_crates()
	if section in ["","lift"]: await test_lift()
	if section in ["","finale"]: await test_finale()

func test_ramp() -> void:
	# 03：从岸台正常上桥；在可站立位置修好下悬力臂上的导线。
	player.teleport_to(Vector2(180-34,2366-95),0)
	await frames(25)
	var ramp = level.get_node("BG03_Ramp")
	check(absf(ramp.body.rotation)<0.01,"ramp remains horizontal before repair")
	check(await move_to(Vector2(170,2322),false),"player reaches ramp approach")
	check(await move_to(Vector2(450,2240),true),"player jumps onto horizontal ramp")
	check(await move_to(Vector2(650,2240),false),"player reaches safe ramp drawing station")
	await ui("RampLessonCanvas",[Vector2(794,2438),Vector2(804,2438)],Vector2(650,2240))
	repair("RampLessonCanvas",Vector2(792,2438),Vector2(806,2438))
	await frames(360)
	print("[AllMachines] ramp angle=",ramp.body.rotation," motor=",level.get_node("BG03_Motor").applied_force," power=",level.get_node("BG03_Motor").received_power," unlocked=",level.get_node("BG03_Axle_Stop").unlocked," player=",player.body.com_world())
	check(absf(ramp.body.rotation+0.35)<0.03,"real blue force turns ramp to intended angle")
	if player.body.com_world().x<330:
		check(await move_to(Vector2(170,2322),false),"player returns to bank while ramp settles")
		check(await move_to(Vector2(450,2202),true),"player boards settled ramp")
	check(await move_to(Vector2(650,2129),false),"player walks up rotating ramp")
	check(await move_to(Vector2(835,2062),false),"player reaches ramp end")
	await capture("03_ramp",Vector2(730,2120))
	check(await move_to(Vector2(1030,2003),true),"player short-jumps from ramp to upper bank")

func test_crates() -> void:
	# 04：两箱向左靠停；验证普通104像素台阶可连续登上。
	player.teleport_to(Vector2(1650-34,1786-95),0)
	await frames(25)
	var tall = level.get_node("BG04_Tall")
	var short = level.get_node("BG04_Short")
	check(absf(tall.body.position.x-1100)<2 and absf(short.body.position.x-1380)<2,"both crates wait before repair")
	check(await move_to(Vector2(1700,1742),false),"player approaches unpowered crates")
	check(await move_to(Vector2(1460,1638),true),"player reaches crate drawing station without grabbing")
	await ui("CrateLessonCanvas",[Vector2(1232,1682),Vector2(1512,1734)],Vector2(1460,1638))
	repair("CrateLessonCanvas",Vector2(1226,1682),Vector2(1241,1682))
	repair("CrateLessonCanvas",Vector2(1506,1734),Vector2(1521,1734))
	await frames(720)
	print("[AllMachines] boxes=",tall.body.position," / ",short.body.position," player=",player.body.com_world())
	check(absf(tall.body.position.x-730)<3 and absf(short.body.position.x-922)<3,"both powered crates dock as a two-step stair")
	check(absf(tall.body.rotation)<0.02 and absf(short.body.rotation)<0.02,"crate rails keep steps upright")
	if player.body.com_world().y>1690:
		check(await move_to(Vector2(1250,1742),false),"player takes a run-up to docked crate")
		check(await move_to(Vector2(1050,1638),true),"player reaches short crate")
	else:
		check(await move_to(Vector2(1050,1638),false),"player reaches short crate")
	check(await move_to(Vector2(810,1534),true),"player jumps from short to tall crate")
	check(await move_to(Vector2(600,1510),true),"player jumps from tall crate to left bank")
	await capture("04_crates",Vector2(850,1610))

func test_lift() -> void:
	# 05：只用固定红墨，经真实接触鞋供电，携带玩家抵达实际出口高度。
	player.teleport_to(Vector2(900-34,1293-95),0)
	await frames(25)
	var lift = level.get_node("BG05_Platform")
	var lift_motor = level.get_node_or_null("BG05_Motor")
	check(lift_motor != null and lift_motor.applied_force<1,"lift waits for fixed power-band repair")
	check(await move_to(Vector2(1000,1249),false),"player reaches lift entrance")
	check(await move_to(Vector2(1160,1221),true),"player boards unpowered lift")
	await ui("LiftLessonCanvas",[Vector2(1316,1435)],Vector2(1160,1221))
	repair("LiftLessonCanvas",Vector2(1316,1427),Vector2(1316,1444))
	var live := 0
	var travelling := 0
	for frame in 720:
		feet.hand_control.set_target_world(player.body.com_world()+Vector2(60,-20))
		feet.apply_input(0,false,DT)
		await physics_frame
		if lift.body.position.y<1215 and lift.body.position.y>770:
			travelling += 1
			if lift_motor != null and lift_motor.applied_force>1: live += 1
	print("[AllMachines] lift=",lift.body.position," power samples=",live,"/",travelling," player=",player.body.com_world()," mass=",player.body.mass," lift mass=",lift.body.mass," power=",lift_motor.received_power," force=",lift_motor.applied_force)
	check(absf(lift.body.position.y-714)<4,"fixed power and contact shoe lift loaded platform full travel")
	check(travelling>5 and live>travelling*0.8,"contact delivers real power throughout lift travel")
	check(player.body.com_world().y<740,"player rides to upper landing without grabbing")
	check(await move_to(Vector2(1100,670),false),"player stays safely on lift at upper dock")
	check(await move_to(Vector2(1085,670),false),"player approaches lift exit curb")
	check(await move_to(Vector2(1000,698),true),"player exits lift onto upper landing")
	await capture("05_lift",Vector2(1150,850))

func test_finale() -> void:
	# 06：同一电源分支独立修复，先验桥路不会替门路供电，再闭合第二支路。
	player.teleport_to(Vector2(1040-34,481-95),0)
	await frames(25)
	var flap = level.get_node("BG06_Flap")
	var gate = level.get_node("BG06_Gate")
	check(absf(flap.body.rotation+0.9)<0.03 and absf(gate.body.position.y-241)<3,"final bridge and door wait for separate branches")
	await ui("FinalLessonCanvas",[Vector2(1117,520),Vector2(1320,464)],Vector2(1040,437))
	repair("FinalLessonCanvas",Vector2(1110,520),Vector2(1126,520))
	await frames(360)
	print("[AllMachines] first branch flap=",flap.body.rotation," gate=",gate.body.position)
	check(flap.body.rotation> -0.8 and level.get_node("BG06_Axle_Stop").unlocked,"first branch releases and powers folding bridge through real axle contact")
	check(absf(gate.body.position.y-241)<3,"unrepaired door branch stays unpowered")
	repair("FinalLessonCanvas",Vector2(1312,464),Vector2(1330,464))
	await frames(900)
	print("[AllMachines] finale flap=",flap.body.rotation," gate=",gate.body.position," gate power=",level.get_node("BG06_GateMotor").received_power," flap power=",level.get_node("BG06_FlapMotor").received_power)
	check(absf(flap.body.rotation)<0.04,"both branches let final bridge dock horizontally")
	check(absf(gate.body.position.y-61)<4,"second red circuit opens final gate")
	await capture("06_finale",Vector2(1380,330))
	check(await move_to(Vector2(1030,437),false),"player reaches final bridge take-off with run-up space")
	check(await move_to(Vector2(1250,391),true),"player steps onto final bridge")
	check(await move_to(Vector2(1410,391),false),"player crosses folding bridge")
	check(await move_to(Vector2(1510,430),false),"player passes opened final gate")
	check(await move_to(Vector2(1790,242),false),"player climbs final slope toward summit")
	check(await move_to(Vector2(1840,220),false),"player enters summit paper door")
	await frames(150)
	check(level.get_meta("blue_ascent_completed",false),"summit confirms completion after two-second overlap")
	check(feet.hand_control.grabbed_body == null,"all four new sections use no grabbing")
