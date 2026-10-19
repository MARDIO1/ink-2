extends SceneTree
## 离线验收和导出；不挂在关卡或机关上。
const Codec=preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Store=preload("res://blueprint/src/blueprint_store.gd")
const Item=preload("res://actor/ink_item/src/ink_item.gd")
const Body=preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const Spring=preload("res://ink/yellow/src/stroke.gd")
const Axle=preload("res://ink/yellow/src/axle.gd")
const Rail=preload("res://ink/yellow/src/rail.gd")
const Pin=preload("res://ink/yellow/src/slider_pin.gd")
const Wire=preload("res://ink/blue/src/wire_layer.gd")
const Motor=preload("res://ink/blue/src/motor.gd")
const Place=preload("res://actor/canvas/blueprint/src/blueprint_place.gd")
const TextLabel=preload("res://ui/map_text/src/map_text_label.gd")
const PARTS=[
    ["01_通电开门",Rect2i(448,3120,128,590)],
    ["02_伸缩桥梁",Rect2i(836,2910,1020,90)],
    ["03_杠杆斜桥",Rect2i(240,2250,800,240)],
    ["04_弹簧双箱",Rect2i(710,1570,990,240)],
    ["05_导电摆渡台",Rect2i(1000,1070,880,440)],
    ["06_齿轮提闸门",Rect2i(830,-40,760,550)],
]
var failures=0

func _initialize():
    run.call_deferred()

func run():
    var level=load("res://.codex-tmp/blue_ascent_final_lessons_work.tscn").instantiate()
    level.auto_step=false
    var creative=level.get_node("Creative")
    creative.auto_save_edits=false
    creative.auto_save_on_exit=false
    creative.editor_draft={}
    for node in level.get_children():
        if node is Body and str(node.name)!="Player" and (not node is Item or str(node.name).contains("SmoothRamp")): node.free()
    level.get_node("SimulationRuntime/PhysicsStep").process_mode=Node.PROCESS_MODE_DISABLED
    root.add_child(level)
    current_scene=level
    for i in 20: await process_frame
    while level.body_bake_pending: await process_frame
    var canvas=level.get_node("MapCanvas")
    var store=Store.new()
    if not OS.get_cmdline_user_args().has("--publish"):
        store.directory="res://.codex-tmp/portable_blueprints"
    var texts=level.get_node("MapTexts").get_children()
    creative.edit_snapshot_path=""
    creative._ensure_editor_resources()
    for label in texts:
        assert(label.get_script()==TextLabel and not label.editor_id.is_empty())
        var at:Vector2=label.global_position
        var scale_:Vector2=label.scale
        assert(creative._resize_control_target(label,1))
        assert(not label.scale.is_equal_approx(scale_))
        assert(creative.undo_last_edit() and label.scale.is_equal_approx(scale_))
        creative._begin_layout_drag(label,at+Vector2.ONE)
        label.global_position+=Vector2(20,8)
        creative._finish_layout_drag()
        assert(creative.undo_last_edit() and label.global_position.is_equal_approx(at))
        assert(creative.remove_map_text_at(at+Vector2.ONE))
        assert(creative.undo_last_edit())
    print("[Portable] PASS ",texts.size()," toolbar text boxes move/resize/delete/undo")
    for node in level.get_children():
        if node is Item or node is Spring or node is Axle or node is Rail or node is Pin or node is Wire or node is Motor:
            if node is Item:
                assert(node.background_nails.is_empty(),"background ink: "+str(node.name))
            if node is Axle or node is Pin or node is Spring:
                assert(node.joint!=null,"unbound ink component: "+str(node.name))
                assert(not node.joint.limits_enabled)
            if node is Spring:
                assert(is_equal_approx(node.rest_length,node.saved_anchor_a.distance_to(node.saved_anchor_b)))
                print("SPRING_EXPORT ",node.name," state=",node.state," joint=",node.joint," anchors=",node.saved_anchor_a," / ",node.saved_anchor_b)
    for part in PARTS:
        var region:Rect2i=part[1]
        var a=Codec.local_point(canvas,Vector2(region.position))
        var data=Codec.capture(canvas,Rect2i(Vector2i(a.round()),region.size))
        if data.has("error"):
            print("[Portable] FAIL ",part[0]," ",data.error)
            failures+=1
            continue
        data.name="蓝色攀升_"+part[0]
        data.description="基础墨水机关；保留教学缺口。仅现有墨水、标签、黄轴、导轨与弹簧。"
        data.tags=["蓝色攀升","基础墨水","教学机关"]
        assert(store.save(data))
        var copy=store.read(data.id)
        assert(not copy.is_empty())
        for key in ["bodies","gears","rails","slider_pins","motors","springs","blue"]:
            assert(copy[key].size()==data[key].size())
        print("[Portable] PASS ",part[0]," bodies=",data.bodies.size()," axles=",data.gears.size()," rails=",data.rails.size()," pins=",data.slider_pins.size()," springs=",data.springs.size()," motors=",data.motors.size()," file=",store.directory.path_join(data.id+".inkbp"))
        if OS.get_cmdline_user_args().has("--place"):
            await placement_probe(copy)
    print("[Portable] failures=",failures)
    level.queue_free()
    await process_frame
    quit(1 if failures else 0)

func placement_probe(data:Dictionary):
    var target=load("res://test/fixtures/maps/base_level.tscn").instantiate()
    target.auto_step=false
    target.get_node("Creative").auto_save_edits=false
    target.get_node("Creative").auto_save_on_exit=false
    target.get_node("SimulationRuntime/PhysicsStep").process_mode=Node.PROCESS_MODE_DISABLED
    var canvas=target.get_node("MapCanvas")
    canvas.position=Vector2(10000,-10000)
    canvas.canvas_size=Vector2i(1024,1024)
    root.add_child(target)
    for i in 3: await process_frame
    canvas.active=true
    canvas.show()
    canvas.set_map_editor_mode(true)
    canvas.surface.ink_free=true
    var error=Place.place(canvas,data,Vector2i.ZERO)
    assert(error.is_empty(),error)
    canvas.generate(false)
    for i in 6: await process_frame
    var counts={"gears":0,"slider_pins":0,"springs":0,"motors":0,"rails":0}
    for node in target.get_children():
        if node is Axle: counts.gears+=1
        elif node is Pin: counts.slider_pins+=1
        elif node is Spring: counts.springs+=1
        elif node is Motor: counts.motors+=1
        elif node is Rail: counts.rails+=1
        if node is Axle or node is Pin or node is Spring:
            assert(node.joint!=null,"paste lost joint: "+str(node.name))
    for key in counts:
        if counts[key]!=data[key].size():
            failures+=1
            print("[Portable] FAIL paste lost ",key," expected=",data[key].size()," actual=",counts[key])
            target.queue_free()
            await process_frame
            return
    print("[Portable] PASS placement/solidification ",data.name," ",counts)
    target.queue_free()
    await process_frame
