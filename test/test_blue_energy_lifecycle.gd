extends "res://test/test_blue_energy.gd"
const Motor=preload("res://ink/blue/src/motor.gd")
const PBody=preload("res://addons/pixel_destruction/physics/pbody.gd")
class NodeSink:
    extends Node
    var energy:=0.0
    var body
    var position:=Vector2.ZERO
    var rotation:=0.0
    var tip:=Vector2(0,-120)
    var brush_width:=12
    var support_cells:=PackedVector2Array([Vector2.ZERO])
    func available_room(): return 1000000000.0
    func receive_energy(value:float,_bio:=0.0): energy+=value
func run():
    var wire=wire_rects([Rect2i(0,0,16,1)])
    var flow=Flow.new()
    var sink=NodeSink.new()
    root.add_child(sink)
    flow.consumers[wire]={Vector2i.ZERO:[sink]}
    flow.advance([wire],1.0/600.0)
    check("native cache contains initial arrow",flow._native_motors.size()==1)
    sink.free()
    flow.advance([wire],1.0/600.0)
    check("freed arrow invalidates native handles without touching freed object",flow._native_motors.is_empty())
    sink=NodeSink.new()
    root.add_child(sink)
    flow.consumers[wire]={Vector2i.ZERO:[sink]}
    flow.contact_epoch+=1
    flow.advance([wire],1.0/600.0)
    sink.queue_free()
    flow.advance([wire],1.0/600.0)
    check("queued arrow is detached before native delivery",flow._native_motors.is_empty())
    await process_frame
    flow=Flow.new()
    sink=NodeSink.new()
    root.add_child(sink)
    sink.body=wire.body
    flow._refresh_consumers([wire],[sink])
    var key=flow.motor_cache.keys()[0]
    check("contact keys preserve full 64-bit instance ids",key[1]==sink.get_instance_id() and key[0]==wire.get_instance_id())
    flow._refresh_consumers([wire],[])
    check("removing live arrow removes its cached projections",flow.motor_cache.is_empty() and flow.consumers[wire].is_empty())
    sink.free()
    var motor=Motor.new()
    var body=PBody.new()
    body.mass=10.0
    body.inv_mass=0.1
    body.inv_inertia=0.01
    body.awake=false
    body.sleep_timer=10.0
    motor.body=body
    motor.tip=Vector2(0,-120)
    motor.position=Vector2(-40,0)
    var paid=motor.drive(1000000000.0,1.0/60.0,300000.0,10000000.0)
    check("powered arrow wakes sleeping body and applies torque",paid>0 and body.awake and body.sleep_timer==0.0 and body.angular_velocity!=0.0)
    body.frozen=true
    body.linear_velocity=Vector2.ZERO
    body.angular_velocity=0.0
    motor.drive(1000000000.0,1.0/60.0,300000.0,10000000.0)
    check("culled body does not accumulate arrow impulses",body.linear_velocity==Vector2.ZERO and body.angular_velocity==0.0)
    motor.free()
    wire.free()
    print("BLUE_LIFECYCLE failures=",failures)
    quit(1 if failures else 0)
