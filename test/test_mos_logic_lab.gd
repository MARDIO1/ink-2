extends SceneTree
## 单实例端到端验收；逻辑值只读取实际蓝墨输出线上的能源高光。

const Wire := preload("res://ink/blue/src/wire_layer.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var level = load("res://map/logic/MOS门电路实验室.tscn").instantiate()
	root.add_child(level)
	for frame in 4:
		await process_frame
	var blue = level.get_node("SimulationRuntime/BlueInk")
	var motors: Array = blue.objects(Motor)
	var pins: Array = level.get_children().filter(func(node): return node is SliderPin)
	var infinite_sources: Array = level.find_children("*", "", true, false).filter(func(node): return node is InkItem and node.infinite_fuel_body and node.infinite_nail_body and not node.infinite_nails.is_empty())
	var hot := {190: false, 430: false, 650: false}
	for frame in 360:
		await physics_frame
		if frame < 180:
			continue
		for wire in blue.objects(Wire):
			if wire.body == null or wire.energy_lines.is_empty():
				continue
			for y in hot:
				var at := Vector2i(wire.body.to_local(Vector2(5800, 5000 + int(y))).floor())
				if wire.mask.has(at):
					hot[y] = true
	var ok: bool = motors.size() == 5 and pins.size() == 3 and infinite_sources.size() == 3 \
		and hot[190] and hot[430] and not hot[650]
	print("MOS_LOGIC_TEST outputs_with_input=", hot, " motors=", motors.size(),
		" pins=", pins.size(), " infinite_sources=", infinite_sources.size())
	quit(0 if ok else 1)
