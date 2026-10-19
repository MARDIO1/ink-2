extends SceneTree
const Hit=preload("res://ui/input/src/ui_hit_test.gd")
const Item=preload("res://actor/ink_item/src/ink_item.gd")
const Pixels=preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Wire=preload("res://ink/blue/src/wire_layer.gd")
const Centers=preload("res://actor/canvas/src/gear_centers.gd")
var failures:=0
func _initialize(): run.call_deferred()
func check(label:String,ok:bool):
    print("[LocalUiSpawn] ","PASS " if ok else "FAIL ",label)
    if not ok: failures+=1
func item(level,title:String,at:Vector2):
    var node=Item.new()
    node.name=title
    node.position=at
    node.is_static=true
    var shape=Pixels.new()
    shape.source=3
    shape.paint=Image.create(24,24,false,Image.FORMAT_R8)
    shape.paint.fill(Color(1.0/255.0,0,0))
    node.add_child(shape)
    level.add_child(node)
    level.add_body_node(node)
    return node
func run():
    var viewport=SubViewport.new()
    viewport.size=Vector2i(400,400)
    root.add_child(viewport)
    var box=VBoxContainer.new()
    box.size=Vector2(400,400)
    viewport.add_child(box)
    check("transparent layout leaves world input available",not Hit.blocks_world_input(viewport,Vector2(300,300)))
    var panel=Panel.new()
    panel.position=Vector2(20,20)
    panel.size=Vector2(100,100)
    viewport.add_child(panel)
    check("panel background blocks world clicks",Hit.blocks_world_input(viewport,Vector2(30,30)))
    panel.set_meta("blocks_world_input",false)
    check("explicit transparent overlay passes clicks",not Hit.blocks_world_input(viewport,Vector2(30,30)))
    panel.clip_contents=true
    var button=Button.new()
    button.position=Vector2(200,0)
    button.size=Vector2(40,40)
    panel.add_child(button)
    check("clipped button cannot swallow world input",not Hit.blocks_world_input(viewport,Vector2(230,30)))
    viewport.queue_free()
    var fixture=load("res://test/fixtures/maps/base_level.tscn").instantiate()
    fixture.auto_step=false
    fixture.get_node("Creative").auto_save_edits=false
    fixture.get_node("Creative").auto_save_on_exit=false
    var spawn=fixture.get_node_or_null("PlayerSpawn")
    if spawn==null:
        spawn=Marker2D.new()
        spawn.name="PlayerSpawn"
        fixture.add_child(spawn)
        spawn.owner=fixture
    spawn.position=Vector2(100,200)
    fixture.get_node("Player").position=Vector2(700,800)
    var packed=PackedScene.new()
    packed.pack(fixture)
    fixture.free()
    var app=load("res://root/root.tscn").instantiate()
    app.menu_music=null
    app.level_music=null
    root.add_child(app)
    current_scene=app
    await process_frame
    var level=await app.load_level(packed,false)
    check("first play load resets saved player pose to spawn",level.get_node("Player").position.is_equal_approx(Vector2(100,200)))
    check("death fallback records the corrected spawn",level.get_node("Player/FallDeath")._initial_position.is_equal_approx(level.to_global(Vector2(100,200))))
    level=await app.load_level(packed,true)
    var creative=level.get_node("Creative")
    creative.auto_save_edits=false
    creative.auto_save_on_exit=false
    creative._activate_restored_editor()
    var canvas=level.get_node("MapCanvas")
    canvas.position=Vector2(10000,-10000)
    canvas.canvas_size=Vector2i(240,160)
    var palette=creative._palette
    var pen=canvas.brush_panel.get_node("PenSlider")
    canvas.set_brush_size(13)
    check("programmatic brush change updates all sliders",pen.value==13 and palette._brush_slider.value==13 and canvas._side_brush_slider.value==13)
    palette._brush_slider.value=17
    check("editor slider updates brush and both canvas sliders",canvas.surface.brush_size==17 and pen.value==17 and canvas._side_brush_slider.value==17)
    pen.value=21
    check("canvas slider updates editor display",palette._brush_slider.value==21 and palette._brush_label.text.contains("21"))
    var anchors=canvas.surface.nail_layer.snapshot()
    canvas.set_nails_visible(false)
    check("public nail toggle updates both buttons",not palette._editor_nail_visibility.button_pressed and not canvas.resize_panel.get_node("Grid/NailVisibility").button_pressed)
    palette._editor_nail_visibility.button_pressed=true
    check("editor nail toggle updates canvas state",canvas.nails_visible() and canvas.resize_panel.get_node("Grid/NailVisibility").button_pressed)
    check("visibility changes preserve anchor data",canvas.surface.nail_layer.snapshot()==anchors)
    var keep=item(level,"KeepWheel",canvas.position+Vector2(40,60))
    keep.gear_centers=[Centers.make(Vector2(12,12),12,1)]
    var plain=item(level,"PlainBlock",canvas.position+Vector2(140,60))
    var plain_body=plain.body
    var wire=Wire.new()
    wire.active=true
    wire.carrier_path=NodePath("../KeepWheel")
    wire.carrier_local=true
    wire.carrier_material=1
    wire.cells=PackedVector2Array([Vector2(5,5),Vector2(6,5)])
    level.add_child(wire)
    await process_frame
    canvas.tool_grid.get_node("ReturnToCanvas").pressed.emit()
    check("inkify button preserves wheel body",level.world.bodies.has(keep.body))
    check("inkify button preserves attached blue wire",is_instance_valid(wire) and not wire.is_queued_for_deletion() and wire.body==keep.body)
    check("ordinary terrain returns to editable ink",not level.world.bodies.has(plain_body) and canvas.surface.material_at(145,65)==1)
    app.queue_free()
    await process_frame
    print("LOCAL_UI_SPAWN failures=",failures)
    quit(1 if failures else 0)
