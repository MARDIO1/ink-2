extends SceneTree
const Body=preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape=preload("res://addons/pixel_destruction/core/pixel_shape.gd")
class Recorder:
    extends "res://addons/pixel_destruction/render/pixel_renderer.gd"
    var synced:Array=[]
    func sync(body):
        synced.append(body)
        super.sync(body)
var failures:=0
func _initialize(): run.call_deferred()
func check(label:String,ok:bool):
    print("[ChangedSync] ","PASS " if ok else "FAIL ",label)
    if not ok: failures+=1
func add_body(level,at:Vector2):
    var shape=Shape.new()
    shape.fill_rect(Rect2i(0,0,24,24),1)
    var body=Body.new()
    body.position=at
    body.is_static=true
    level.world.add_body(body,[shape])
    return body
func run():
    var level=load("res://test/fixtures/maps/base_level.tscn").instantiate()
    level.auto_step=false
    root.add_child(level)
    await process_frame
    level.get_node("Creative").auto_save_edits=false
    level.get_node("Creative").auto_save_on_exit=false
    var old=level.renderer
    var spy=Recorder.new()
    level.add_child(spy)
    level.renderer=spy
    old.queue_free()
    var a=add_body(level,Vector2(10000,10000))
    var b=add_body(level,Vector2(10080,10000))
    level.sync_world_bodies()
    check("full sync populates both static terrain textures",spy._nodes.has(a.id) and spy._nodes.has(b.id))
    var step=level.get_node("SimulationRuntime/PhysicsStep")
    var nodes=level._body_nodes.duplicate()
    var commit=step.commit(level.world,{a:{a.shapes[0]:{Vector2i(1,1):true}}})
    spy.synced.clear()
    step.sync_after_commit(nodes,commit.changed)
    check("real fracture produces changed bodies",not commit.changed.is_empty())
    check("unchanged static terrain skips renderer sync",not spy.synced.has(b))
    check("all surviving fracture pieces have textures",commit.changed.all(func(body):return not level.world.bodies.has(body) or spy._nodes.has(body.id)))
    check("node slots still align with complete world",level._body_nodes.size()==level.world.bodies.size())
    level.world.remove_body(b)
    level.sync_changed_world_bodies([])
    check("incremental sync still prunes removed bodies globally",not spy._nodes.has(b.id))
    spy.synced.clear()
    step.sync_after_commit(level._body_nodes.duplicate(),[])
    var expected:=0
    for i in level.world.bodies.size():
        if level.uses_internal_render(level._body_nodes[i]): expected+=1
    check("unknown change set falls back to full sync",spy.synced.size()==expected)
    level.queue_free()
    await process_frame
    print("CHANGED_SYNC failures=",failures)
    quit(1 if failures else 0)
