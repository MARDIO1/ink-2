extends SceneTree
const Wire=preload("res://ink/blue/src/wire_layer.gd")
const Motor=preload("res://ink/blue/src/motor.gd")
const Pin=preload("res://ink/yellow/src/slider_pin.gd")
const Item=preload("res://actor/ink_item/src/ink_item.gd")
func _initialize():call_deferred("run")
func run():
	var level=load("res://map/logic/MOS门电路实验室.tscn").instantiate();root.add_child(level)
	for i in 4:await process_frame
	var blue=level.get_node("SimulationRuntime/BlueInk");var motors=blue.objects(Motor);var pins=level.get_children().filter(func(x):return x is Pin);var sources=level.find_children("*","",true,false).filter(func(x):return x is Item and x.infinite_fuel_body)
	var hot={140:false,320:false,500:false}
	for frame in 360:
		await physics_frame
		if frame<180:continue
		for w in blue.objects(Wire):
			if w.body==null or w.energy_lines.is_empty():continue
			for y in hot:
				var at=Vector2i(w.body.to_local(Vector2(5450,5000+int(y))).floor())
				if w.mask.has(at):hot[y]=true
	var ok=motors.size()==5 and pins.size()==3 and sources.size()==8 and hot[140] and hot[320] and not hot[500]
	print("MOS_PLAYABLE_TEST outputs=",hot," motors=",motors.size()," pins=",pins.size()," infinite_red_bodies=",sources.size());quit(0 if ok else 1)
