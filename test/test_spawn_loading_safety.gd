extends SceneTree
const Body=preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const Pixels=preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
var failures:=0
var app
var loading_frames:=0
var unsafe_frames:=0
func _initialize(): run.call_deferred()
func check(label:String,ok:bool):
    print("[SpawnLoading] ","PASS " if ok else "FAIL ",label)
    if not ok:failures+=1
func observe():
    if app==null or app.level_root.get_child_count()==0:return
    var level=app.level_root.get_child(0)
    if not level.body_bake_pending:return
    loading_frames+=1
    var player=level.get_node("Player")
    if player.get_node("FallDeath")._dead or player.get_node("InkHealth").ink_of(1)<20000:unsafe_frames+=1
func run():
    var fixture=load("res://test/fixtures/maps/base_level.tscn").instantiate()
    fixture.auto_step=true
    var creative=fixture.get_node("Creative")
    creative.auto_save_edits=false
    creative.auto_save_on_exit=false
    var p=fixture.get_node("Player")
    p.position=Vector2(700,800)
    p.initial_velocity=Vector2(0,1200)
    p.initial_angular_velocity=30
    p.get_node("Arm").initial_velocity=Vector2(900,-900)
    p.get_node("PlayerInput").process_mode=Node.PROCESS_MODE_DISABLED
    p.get_node("Arm").process_mode=Node.PROCESS_MODE_DISABLED
    var spawn=fixture.get_node_or_null("PlayerSpawn")
    if spawn==null:
        spawn=Marker2D.new()
        spawn.name="PlayerSpawn"
        fixture.add_child(spawn)
        spawn.owner=fixture
    spawn.position=Vector2(180,200)
    for i in 15:
        var body=Body.new()
        body.position=Vector2(4000+i*30,4000)
        body.is_static=true
        var shape=Pixels.new()
        shape.source=3
        shape.paint=Image.create(8,8,false,Image.FORMAT_R8)
        shape.paint.fill(Color(1.0/255,0,0))
        body.add_child(shape)
        fixture.add_child(body)
        body.owner=fixture
        shape.owner=fixture
    var packed=PackedScene.new()
    packed.pack(fixture)
    fixture.free()
    app=load("res://root/root.tscn").instantiate()
    app.menu_music=null
    app.level_music=null
    app.bake_bodies_per_frame=1
    root.add_child(app)
    physics_frame.connect(observe)
    await process_frame
    var level=await app.load_level(packed,false)
    p=level.get_node("Player")
    check("staged load remains alive and unharmed",unsafe_frames==0)
    check("initial saved velocity is reset before gameplay",p.body.linear_velocity==Vector2.ZERO and p.body.angular_velocity==0)
    check("saved editor input suspension does not leak into play",p.get_node("PlayerInput").can_process() and p.get_node("Arm").can_process())
    check("actual body starts at spawn",p.body.position.is_equal_approx(Vector2(180,200)))
    var death=p.get_node("FallDeath")
    check("fall baseline starts at current body height",is_equal_approx(death._peak_y,p.body.com_world().y))
    var hand=p.get_node("Arm/Hand").body
    check("hand is reset beside player without stored velocity",hand.linear_velocity==Vector2.ZERO and hand.com_world().distance_to(p.body.com_world())<160)
    for i in 90:await physics_frame
    check("player survives first seconds with normal physics and damage",not death._dead and p.get_node("InkHealth").ink_of(1)>0)
    app.queue_free()
    await process_frame
    print("SPAWN_LOADING failures=",failures," staged_physics_frames=",loading_frames)
    quit(1 if failures else 0)
