extends SceneTree
## 针对当前完整蓝色攀升：重建画布工具栏、实际画笔补线和齿轮提门通路。
var level
var player
var feet
var runtime
var camera
var failures:=0
const DT:=1.0/60.0
func _initialize(): run.call_deferred()
func check(ok:bool,label:String):
    print("[AscentToolbarGear] ","PASS " if ok else "FAIL ",label)
    if not ok: failures+=1
func tick(axis:=0.0,jump:=false):
    camera.position=player.body.com_world()
    camera.force_update_scroll()
    feet.hand_control.set_target_world(player.body.com_world()+Vector2(60,-20))
    feet.apply_input(axis,jump,DT)
    await physics_frame
func frames(count:int):
    for i in count:
        feet.hand_control.set_target_world(player.body.com_world()+Vector2(60,-20))
        feet.apply_input(0,false,DT)
        await physics_frame
func gap(title:String,carrier:String,a:Vector2,b:Vector2,width:=15):
    var canvas=level.get_node(title)
    var body=level.get_node(carrier).body
    canvas.surface.ink_free=true
    canvas.surface.brush_size=width
    canvas.surface.blue_layer.begin(canvas.to_local(body.to_world(a))+Vector2.ONE*0.5)
    canvas.surface.blue_layer.extend(canvas.to_local(body.to_world(b))+Vector2.ONE*0.5)
    canvas.surface.blue_layer.finish()
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

func run():
    root.mode=Window.MODE_WINDOWED
    root.size=Vector2i(960,540)
    root.position=Vector2i(20000,20000)
    var app=load("res://root/root.tscn").instantiate()
    app.menu_music=null
    app.level_music=null
    root.add_child(app)
    await process_frame
    await app.request_level_change("res://map/asset/imported/蓝色攀升.tscn")
    level=app.level_root.get_child(0)
    level.get_node("Creative").auto_save_edits=false
    level.get_node("Creative").auto_save_on_exit=false
    player=level.get_node("Player")
    feet=player.get_node("PlayerInput")
    feet.set_physics_process(false)
    feet.hand_control.set_grip(false)
    set_meta("test_hand_offset",Vector2(40,0))
    runtime=level.get_node("SimulationRuntime")
    runtime.get_node("PhysicsStep").freeze_view_scale=4
    camera=level.get_node("Camera2D")
    camera.set_physics_process(false)
    camera.set_process(false)
    camera.position=Vector2(1550,1240)
    camera.force_update_scroll()
    await frames(100)
    await toolbar_check()
    print("PLAYER_MASS ",player.body.mass," gravity=",level.world.gravity)
    await sixth_check()
    check(feet.hand_control.grip_joint==null,"mechanism tests never grab")
    print("[AscentToolbarGear] failures=",failures)
    app.queue_free()
    await process_frame
    quit(1 if failures else 0)

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
    for body in [driver,follower,gate]:
        body.awake=false
        body.sleep_timer=10.0
    gap("FinalLessonCanvas","BG06_YellowPowerShaft",Vector2(8,14),Vector2(32,14))
    for i in 30:
        await frames(30)
        var motor=motor_for("BG06_DriveGear")
        print("SIXTH_RUN ",i," gate=",gate.position," r=",gate.rotation," driver=",driver.rotation," follower=",follower.rotation," power=",motor.received_power if motor!=null else -1," force=",motor.applied_force if motor!=null else -1)
    check(gate.position.y<94,"physical gear teeth and rack lift gate to upper ink stop")
    check(motor_for("BG06_Gate")==null and motor_for("BG06_FollowerGear")==null,"gate and follower have no separate motor or synchronizer")
    player.teleport_to(Vector2(1200,385),0)
    await frames(60)
    check(await walk_ramp_to(1540,450),"player walks along fixed bridge under the lifted gate without grab")

func toolbar_check():
    var canvas=level.get_node("PlayCanvas")
    player.teleport_to(Vector2(1350,1740),0)
    camera.position=Vector2(1320,1700)
    for zoom in [1.15,2.8]:
        camera.zoom=Vector2.ONE*zoom
        camera.force_update_scroll()
        await frames(20)
        canvas._refresh_workbench_visibility()
        await process_frame
        var layout=canvas.get_node("SidePanelLayer")
        layout.update_layout()
        check(canvas.buttons.is_visible_in_tree(),"fourth recreated canvas has visible toolbar")
        check(canvas._side_panel.is_visible_in_tree(),"fourth recreated canvas has visible palette")
        var attached_y=layout._canvas_screen_bounds().position.y+2.0
        check(is_equal_approx(layout._mount.position.y,attached_y) and is_equal_approx(layout._left_position.y,attached_y),"fourth tools stay at canvas height zoom="+str(zoom))
        check(canvas.workbench.has_node("LessonToolPaper"),"renamed canvas receives half transparent backing")
    camera.zoom=Vector2.ONE
