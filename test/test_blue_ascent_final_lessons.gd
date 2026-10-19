extends "res://test/test_blue_ascent_linkages.gd"
const Assembly=preload("res://tools/blue_ascent_final_lessons.gd")
const Axle=preload("res://ink/yellow/src/axle.gd")
const Pin=preload("res://ink/yellow/src/slider_pin.gd")
const Palette=preload("res://ink/general/src/ink_palette.gd")
const PixelBody=preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")

func gap(title:String,carrier:String,a:Vector2,b:Vector2,width:=15):
    var canvas=level.get_node(title)
    var body=level.get_node(carrier).body
    canvas.surface.ink_free=true
    canvas.surface.brush_size=width
    canvas.surface.blue_layer.begin(canvas.to_local(body.to_world(a))+Vector2.ONE*0.5)
    canvas.surface.blue_layer.extend(canvas.to_local(body.to_world(b))+Vector2.ONE*0.5)
    canvas.surface.blue_layer.finish()
    canvas.generate(false)

func inspect():
    for node in level.get_children():
        if not (str(node.name).begins_with("BG05_") or str(node.name).begins_with("BG06_")): continue
        if node.get("joint")!=null:
            check(not node.joint.limits_enabled,"unlimited original ink joint "+str(node.name))
        if node.get("body")!=null:
            print("NEW_BODY ",node.name," p=",node.body.position," r=",node.body.rotation," mass=",node.body.mass)

func run():
    root.mode=Window.MODE_WINDOWED
    root.size=Vector2i(960,540)
    root.position=Vector2i(20000,20000)
    var app=load("res://root/root.tscn").instantiate()
    app.menu_music=null
    app.level_music=null
    root.add_child(app)
    await process_frame
    await app.request_level_change("res://.codex-tmp/final_lessons_isolated.tscn" if OS.get_cmdline_user_args().has("--isolate") else "res://.codex-tmp/blue_ascent_final_lessons_work.tscn")
    level=app.level_root.get_child(0)
    level.get_node("Creative").auto_save_edits=false
    level.get_node("Creative").auto_save_on_exit=false
    player=level.get_node("Player")
    feet=player.get_node("PlayerInput")
    feet.set_physics_process(false)
    feet.hand_control.set_grip(false)
    set_meta("test_hand_offset",Vector2(40,0))
    runtime=level.get_node("SimulationRuntime")
    runtime.get_node("PhysicsStep").freeze_view_scale=100
    camera=level.get_node("Camera2D")
    camera.set_physics_process(false)
    camera.set_process(false)
    camera.position=Vector2(1550,1240)
    camera.force_update_scroll()
    await frames(100)
    inspect()
    print("PLAYER_MASS ",player.body.mass," gravity=",level.world.gravity)
    if not OS.get_cmdline_user_args().has("--sixth-only"): await fifth_check()
    if not OS.get_cmdline_user_args().has("--fifth-only"): await sixth_check()
    check(feet.hand_control.grip_joint==null,"mechanism tests never grab")
    print("[FinalLessonsTest] failures=",failures)
    app.queue_free()
    await process_frame
    quit(1 if failures else 0)

func fifth_check():
    var platform=level.get_node("BG05_Platform").body
    player.teleport_to(platform.position+Vector2(90,-95),0)
    await frames(90)
    print("FIFTH_UNPOWERED platform=",platform.position," player=",player.body.com_world()," support=",support_title())
    check(absf(platform.position.y-1240)<6,"unpowered platform remains on its physical boarding rest")
    arrow("LiftLessonCanvas","BG05_Platform",Vector2(220,135),Vector2(220,15),12)
    await frames(90)
    check(motor_for("BG05_Platform")!=null,"player can draw ordinary supported arrow on platform")
    var rod=level.get_node("BG05_Lever2").body
    var highest=INF
    for i in 18:
        await frames(30)
        highest=minf(highest,platform.position.y)
        var motor=motor_for("BG05_Platform")
        print("FIFTH_RUN ",i," p=",platform.position," angle=",rod.rotation," r=",platform.rotation," player=",player.body.com_world()," support=",support_title()," power=",motor.received_power if motor!=null else -1," force=",motor.applied_force if motor!=null else -1)
    check(platform.position.y<1130 and platform.position.x<1450,"yellow levers and counterweights move loaded platform up and left")
    var fifth_bodies={}
    for node in level.get_children():
        if str(node.name).begins_with("BG05_") and node is PixelBody:
            fifth_bodies[node.body.id]=str(node.name)
    for i in level.world.contact_pair_count():
        var info:Dictionary=level.world.contact_info(i)
        if not fifth_bodies.has(info.id_a) and not fifth_bodies.has(info.id_b): continue
        print("FIFTH_CONTACT ",fifth_bodies.get(info.id_a,info.id_a)," / ",fifth_bodies.get(info.id_b,info.id_b)," at=",info.points[0].position," normal=",info.points[0].normal)
    check(absf(platform.rotation)<0.04,"parallel yellow levers keep standing platform level")
    check(highest<1130 and player.body.com_world().y<1130,"player rides to exit height without grab or launch")
    await snapshot("new05_docked",Vector2(1500,1130))
    check(await walk_ramp_to(1280,1145),"player walks off fifth platform onto left exit without grab")

func sixth_check():
    player.teleport_to(Vector2(900,385),0)
    await frames(60)
    camera.position=Vector2(1210,275)
    camera.force_update_scroll()
    var driver=level.get_node("BG06_DriveGear").body
    var follower=level.get_node("BG06_FollowerGear").body
    var gate=level.get_node("BG06_Gate").body
    print("SIXTH_INITIAL gate=",gate.position," driver=",driver.rotation," follower=",follower.rotation)
    arrow("FinalLessonCanvas","BG06_DriveGear",Vector2(74,174),Vector2(74,54),12)
    await frames(90)
    check(motor_for("BG06_DriveGear")!=null,"player can draw tangential arrow on ordinary black drive wheel")
    check(gate.position.y>190,"open supply gap keeps gear gate closed")
    gap("FinalLessonCanvas","BG06_YellowPowerShaft",Vector2(18,14),Vector2(72,14))
    for i in 26:
        await frames(30)
        var motor=motor_for("BG06_DriveGear")
        print("SIXTH_RUN ",i," gate=",gate.position," r=",gate.rotation," driver=",driver.rotation," follower=",follower.rotation," power=",motor.received_power if motor!=null else -1," force=",motor.applied_force if motor!=null else -1)
    check(gate.position.y<94,"physical gear teeth and rack lift gate to upper ink stop")
    check(motor_for("BG06_Gate")==null and motor_for("BG06_FollowerGear")==null,"gate and follower have no separate motor or synchronizer")
    await snapshot("new06_gear_gate",Vector2(1210,275))
    player.teleport_to(Vector2(1200,385),0)
    await frames(60)
    check(await walk_ramp_to(1540,450),"player walks along fixed bridge under the lifted gate without grab")
