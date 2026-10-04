extends SceneTree


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://map/asset/main2.tscn").instantiate()
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
	var body_count: int = scene.world.bodies.size()
	canvas.solid.solidify(surface, scene)
	valid = valid and scene.world.bodies.size() > body_count and not surface.is_solid(20, 20)
	print("[Canvas] resize, bounds, solidify: ", "PASS" if valid else "FAIL")
	quit(0 if valid else 1)
