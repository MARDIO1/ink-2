extends "res://test/test_collision_damage.gd"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas: Node = scene.get_node("Canvas")
	var surface: Area2D = canvas.get_node("CanvasSurface")
	canvas.canvas_size = Vector2i(320, 180)
	var bounds: CollisionShape2D = surface.get_node("Bounds")
	var valid: bool = surface.black_image.get_size() == Vector2i(320, 180)
	valid = valid and bounds.shape.size == Vector2(320, 180) and bounds.position == Vector2(160, 90)
	valid = valid and surface.collision_layer == 0 and not surface.monitoring
	# 画一个实心笔划，确认编辑器范围改造没有破坏固化。
	surface._stroke(Vector2(20, 20), Vector2(40, 20), Color.BLACK)
	surface._place_nail(Vector2(30, 20))
	var path: String = "user://canvas_roundtrip.tres"
	canvas.capture_path = path
	canvas.baked_map_path = "user://canvas_roundtrip.png"
	var before: PackedByteArray = surface.black_image.get_data()
	await _press(KEY_F5)
	valid = valid and ResourceLoader.exists(path)
	surface.clear()
	canvas.canvas_size = Vector2i(32, 32)
	await _press(KEY_F9)
	valid = valid and surface.black_image.get_data() == before and canvas.canvas_size == Vector2i(320, 180)
	#钉子不回收：带钉子的实体回到画布不能崩，也不能把钉子写回墨水。
	var home: Vector2 = canvas.position
	canvas.position = Vector2(5000, 5000)      # 挪到空地：只回收这块刚体，别顺带把地形也收走
	canvas.solid.solidify(surface, scene)
	canvas.return_to_canvas()
	valid = valid and surface.is_solid(20, 20) and not surface.is_solid(30, 20)
	await process_frame
	canvas.position = home
	surface.clear()
	surface._stroke(Vector2(20, 20), Vector2(40, 20), Color.BLACK)
	surface._place_nail(Vector2(30, 20))
	var body_count: int = scene.world.bodies.size()
	canvas.solid.solidify(surface, scene)
	valid = valid and scene.world.bodies.size() > body_count and not surface.is_solid(20, 20)
	var nailed = scene.world.bodies[-1]
	valid = valid and nailed.is_static and nailed.tags.has("static_anchor_points")
	var nail_shape = nailed.shapes[0]
	valid = valid and nail_shape.get_pixel(30, 20) == 4
	var cut: Dictionary = {}
	for y in range(180):
		if nail_shape.get_pixel(35, y) != 0:
			cut[Vector2i(35, y)] = true
	var before_split: int = scene.world.bodies.size()
	scene.get_node("CollisionDamage").commit(scene.world, {nailed: {nail_shape: cut}})
	valid = valid and nailed.is_static and scene.world.bodies.size() > before_split
	valid = valid and not scene.world.bodies[-1].is_static
	nail_shape = nailed.shapes[0]
	scene.get_node("CollisionDamage").commit(scene.world,
		{nailed: {nail_shape: {Vector2i(30, 20): true}}})
	valid = valid and not nailed.is_static and not nailed.tags.has("static_anchor_points")
	print("[Canvas] resize, save/load, nail solidify/break: ", "PASS" if valid else "FAIL")
	var hand = scene.get_node("Player/Arm/Hand/HandControl")
	hand.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	hand._release_grab()
	hand._remove_arm()
	_release(scene.world)
	scene.queue_free()
	await process_frame
	quit(0 if valid else 1)


func _press(code: int) -> void:
	var event: InputEventKey = InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = true
	Input.parse_input_event(event)
	await process_frame
	event = event.duplicate()
	event.pressed = false
	Input.parse_input_event(event)
	await process_frame
