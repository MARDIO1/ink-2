extends "res://test/test_blue_ascent_all_machines.gd"
const Spring := preload("res://ink/yellow/src/stroke.gd")

func yellow_link(title: String, a: Vector2, b: Vector2, width: int) -> void:
	var canvas=level.get_node(title)
	var surface=canvas.surface
	surface.ink_free=true
	surface.brush_size=width
	var rule=surface.yellow_rule()
	rule.begin(surface,surface.to_local(a))
	rule.finish(surface,surface.to_local(b))
	canvas.generate(false)

func arrow(title: String, carrier: String, a: Vector2, b: Vector2, width: int) -> void:
	var canvas=level.get_node(title)
	var body=level.get_node(carrier).body
	var surface=canvas.surface
	surface.ink_free=true
	surface.brush_size=width
	var rule=surface.blue_rule()
	rule.begin(surface,surface.to_local(body.to_world(a))+Vector2.ONE*0.5)
	rule.finish(surface,surface.to_local(body.to_world(b))+Vector2.ONE*0.5)
	canvas.generate(false)

func motor_for(title: String):
	var blue=runtime.get_node("BlueInk")
	for motor in blue.objects(blue.Motor):
		if motor.body==level.get_node(title).body: return motor
	return null

func remaining() -> void:
	set_meta("test_hand_offset",Vector2(40,0))
	# 隔离桌面正在进行的鼠标操作，整个专项明确禁止抓握。
	feet.hand_control.set_grip(false)
	runtime.get_node("PhysicsStep").freeze_view_scale=100.0
	await frames(90)
	check(level.get_meta("blue_ascent_compound_ink",false),"compound ink scene")
	check(not level.has_node("BG05_Reset"),"no dedicated reset button")
	print("LINK_PLAYER_MASS ",player.body.mass," arm=",player.get_node("Arm").body.mass," hand=",player.get_node("Arm/Hand").body.mass)
	for title in ["BG04_Tall_Pin","BG04_Short_Pin","BG05_Pin","BG05_PedalAxle","BG05_MountA","BG05_MountB","BG05_SeatA","BG05_SeatB","BG05_OpenA","BG05_OpenB","BG06_Axle","BG06_Gate_Pin","BG06_LinkBridge","BG06_LinkGate"]:
		var fixture=level.get_node_or_null(title)
		var joint=fixture.joint if fixture!=null else null
		check(joint!=null and not joint.limits_enabled,title+" ordinary ink joint without travel/angle limits")
	for title in ["BG05_LeftSpring","BG05_RightSpring","BG05_PedalReturn"]:
		var fixture=level.get_node_or_null(title)
		check(fixture!=null and fixture.joint!=null,title+" actual yellow spring bound")
		if fixture!=null:
			print("LINK_SPRING ",title," rest=",fixture.rest_length," anchors=",fixture.anchors)
	for title in ["BG04_Tall","BG04_Short","BG05_Platform","BG05_Pedal","BG06_Flap","BG06_Gate","BG06_ConnectingRod"]:
		var b=level.get_node(title).body
		print("LINK_INITIAL ",title," p=",b.position," r=",b.rotation," m=",b.mass)
	if DisplayServer.get_name()!="headless" and not OS.get_cmdline_user_args().has("--mechanics"):
		player.teleport_to(Vector2(1300,1587),0)
		await ui("CrateLessonCanvas",[Vector2(1252,1740),Vector2(1270,1740),Vector2(1120,1682),Vector2(1226,1682)],Vector2(1330,1670))
		player.teleport_to(Vector2(1400,1170),0)
		var platform=level.get_node("BG05_Platform").body
		await ui("LiftLessonCanvas",[platform.to_world(Vector2(278,48)),platform.to_world(Vector2(278,188))],Vector2(1460,1214))
		player.teleport_to(Vector2(1266,457),0)
		var bridge=level.get_node("BG06_Flap").body
		await ui("FinalLessonCanvas",[Vector2(960,480),bridge.to_world(Vector2(-80,16)),bridge.to_world(Vector2(250,160)),bridge.to_world(Vector2(250,20))],Vector2(1270,520))
		player.teleport_to(Vector2(180,3605),0)
	yellow_link("CrateLessonCanvas",Vector2(1252,1740),Vector2(1270,1740),7)
	var flap=level.get_node("BG06_Flap").body
	yellow_link("FinalLessonCanvas",Vector2(960,480),flap.to_world(Vector2(-80,16)),12)
	arrow("CrateLessonCanvas","BG04_Tall",Vector2(126,104),Vector2(20,104),7)
	arrow("LiftLessonCanvas","BG05_Platform",Vector2(278,48),Vector2(278,188),24)
	arrow("FinalLessonCanvas","BG06_Flap",Vector2(250,160),Vector2(250,20),20)
	check(motor_for("BG04_Tall")!=null and motor_for("BG04_Short")==null,"only tall crate has an actuator")
	check(motor_for("BG05_Platform")!=null,"player-drawn charging arrow is supported")
	check(motor_for("BG06_Flap")!=null and motor_for("BG06_Gate")==null,"only bridge lever has an actuator")
	for i in 18:
		await frames(30)
		if i%3==2: print_state(i)
	check(level.get_node("BG04_Tall").body.position.x<745,"powered tall crate reaches left stop")
	check(level.get_node("BG04_Short").body.position.x<980,"yellow spring pulls unpowered short crate")
	check(absf(level.get_node("BG06_Flap").body.rotation)<0.07,"bridge docks on physical support")
	check(level.get_node("BG06_Gate").body.position.y<65,"connecting rod lifts unpowered gate")
	var platform=level.get_node("BG05_Platform").body
	check(platform.position.y>1240,"down arrow stores visible compression in main springs")
	for title in ["BG05_TopStop","BG05_BottomStop","BG05_SpringBase"]:
		check(level.world.bodies.has(level.get_node(title).body),title+" ink fixture survives continuous load")
	await sample_cpu()
	await snapshot("04_coupled_crates",Vector2(1050,1670))
	await snapshot("06_bridge_gate",Vector2(1280,400))
	await snapshot("05_charged",Vector2(1640,1260))
	var launch_motor=motor_for("BG05_Platform")
	player.teleport_to(platform.position+Vector2(115,-132),0)
	var disconnected := false
	var highest := INF
	var platform_highest := INF
	var captured := false
	var steering := false
	for i in 420:
		feet.hand_control.set_target_world(player.body.com_world()+Vector2(40,0))
		# 本作空中没有脚部牵引；在踏台尚接触脚底时向左带出速度。
		if platform.position.y<1215 and platform.linear_velocity.y< -100: steering=true
		var axis:=signf(1360.0-player.body.com_world().x) if steering and absf(1360.0-player.body.com_world().x)>10 else 0.0
		feet.apply_input(axis,false,DT)
		await physics_frame
		highest=minf(highest,player.body.position.y)
		platform_highest=minf(platform_highest,platform.position.y)
		if launch_motor!=null and launch_motor.received_power<1.0: disconnected=true
		if feet.support==level.get_node("BG05_CatchLanding").body or feet.support==level.get_node("BG05_ReturnRamp").body: captured=true
		if i%30==0: print("LINK_LAUNCH ",i," player=",player.body.position," platform=",platform.position," pedal=",level.get_node("BG05_Pedal").body.rotation," power=",launch_motor.received_power if launch_motor!=null else -1," support=",support_title())
	check(disconnected,"player weight opens actual red/blue contact")
	check(platform_highest<1130,"stored spring energy launches platform upward")
	check(highest<1050,"spring launch reaches capture landing height without jump input")
	check(captured,"player can land on the broad capture platform")
	print("LINK_PEAK player=",highest," platform=",platform_highest)
	await snapshot("05_landing",Vector2(1450,970))
	if captured:
		check(await walk_ramp_to(1180,1050),"player enters black return ramp from capture landing")
		check(await walk_ramp_to(950,900),"player walks middle of black return ramp")
		check(await walk_ramp_to(680,742),"capture landing reconnects to original exit by walking up black ramp")
	check(feet.hand_control.grip_joint==null,"all mechanism and route checks use no grabbing")

func walk_ramp_to(x: float, ceiling_y: float) -> bool:
	# 斜坡上接触点与角色倾角会改变重心高度，检查到达横向出口及实际爬升。
	for frame in 600:
		var p:Vector2=player.body.com_world()
		if absf(p.x-x)<16 and p.y<ceiling_y and feet.support!=null: return true
		await tick(signf(x-p.x) if absf(x-p.x)>6 else 0.0,false)
	print("RAMP_ROUTE target=",x," at=",player.body.com_world()," support=",support_title())
	return false

func support_title() -> String:
	for node in level.get_children():
		if node.get("body")!=null and node.get("body")==feet.support: return str(node.name)
	return "other" if feet.support!=null else "air"

func snapshot(title: String, center: Vector2) -> void:
	if DisplayServer.get_name()=="headless": return
	camera.position=center
	camera.zoom=Vector2.ONE
	camera.reset_smoothing()
	camera.reset_physics_interpolation()
	camera.force_update_scroll()
	await process_frame
	RenderingServer.force_draw(false)
	DirAccess.make_dir_recursive_absolute("res://output/blue_ascent_linkages")
	root.get_texture().get_image().save_png("res://output/blue_ascent_linkages/"+title+".png")

func sample_cpu() -> void:
	runtime.set_profile_enabled(true)
	var samples:Array[float]=[]
	for i in 120:
		await frames(1)
		samples.append(float(runtime.take_profile().get("physics_us",0))/1000.0)
	samples.sort()
	var report:Dictionary={"scope":"all compound mechanisms powered, enlarged physics range; simulation CPU, not display FPS","p50_ms":samples[60],"p95_ms":samples[114],"max_ms":samples[-1]}
	runtime.set_profile_enabled(false)
	DirAccess.make_dir_recursive_absolute("res://output/blue_ascent_linkages")
	FileAccess.open("res://output/blue_ascent_linkages/performance.json",FileAccess.WRITE).store_string(JSON.stringify(report,"\t"))
	print("LINK_PROFILE ",JSON.stringify(report))

func print_state(index: int) -> void:
	for title in ["BG04_Tall","BG04_Short","BG05_Platform","BG05_Pedal","BG06_Flap","BG06_Gate"]:
		var b=level.get_node(title).body
		var m=motor_for(title)
		print("LINK_STATE ",index," ",title," p=",b.position," r=",b.rotation," power=",m.received_power if m!=null else -1," force=",m.applied_force if m!=null else -1)
	if index<4 and OS.get_cmdline_user_args().has("--trace"):
		var yellow=runtime.get_node("YellowInk")
		for title in ["BG05_LeftSpring","BG05_RightSpring","BG05_PedalReturn"]:
			var spring=level.get_node_or_null(title)
			if spring!=null and spring.joint!=null: print("LINK_LOAD ",title," k=",spring.joint.stiffness," force=",yellow.spring_force(spring)," a=",Spring.anchor_world(spring.anchors[0])," b=",Spring.anchor_world(spring.anchors[1]))
		var platform=level.get_node("BG05_Platform").body
		var pedal=level.get_node("BG05_Pedal").body
		print("LINK_VEL ",platform.linear_velocity," gravity=",level.world.gravity)
		for i in level.world.contact_pair_count():
			var info:Dictionary=level.world.contact_info(i)
			if info.id_a==platform.rapier_id or info.id_b==platform.rapier_id or info.id_a==pedal.rapier_id or info.id_b==pedal.rapier_id:
				print("LINK_CONTACT ",info)
