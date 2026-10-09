extends "res://test/test_collision_damage.gd"

const InkPalette := preload("res://Ink/src/ink_palette.gd")
const CanvasSurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas: Node = scene.get_node("SmallCanvas")
	var surface: Area2D = canvas.get_node("CanvasSurface")
	canvas.canvas_size = Vector2i(320, 180)
	var bounds: CollisionShape2D = surface.get_node("Bounds")
	var valid: bool = surface.black_image.get_size() == Vector2i(320, 180)
	valid = valid and bounds.shape.size == Vector2(320, 180) and bounds.position == Vector2(160, 90)
	valid = valid and surface.collision_layer == 0 and not surface.monitoring
	# 矩形必须是方角、等宽的边框；不能再用圆笔刷沿四边盖章，
	# 否则粗笔刷会让外沿周期性鼓出。
	var saved_tool: int = surface.tool
	var saved_brush_size: int = surface.brush_size
	surface.tool = CanvasSurfaceScript.Tool.RECT
	surface.brush_size = 7
	var rect_pixels: Dictionary = surface._shape_pixels(Vector2(20, 30), Vector2(80, 70))
	var rect_valid := true
	for y in range(30, 70):
		for x in range(20, 80):
			var should_be_border := x < 27 or x >= 73 or y < 37 or y >= 63
			rect_valid = rect_valid and rect_pixels.has(Vector2i(x, y)) == should_be_border
	# 不允许圆笔刷留下的毛刺伸出拖拽包围盒。
	for pixel: Vector2i in rect_pixels:
		rect_valid = rect_valid \
			and pixel.x >= 20 and pixel.x < 80 and pixel.y >= 30 and pixel.y < 70
	valid = valid and rect_valid
	print("[Canvas] 平整矩形边框: ", "PASS" if rect_valid else "FAIL")
	surface.tool = saved_tool
	surface.brush_size = saved_brush_size
	# 画一个实心笔划，确认编辑器范围改造没有破坏固化。
	surface._stroke(Vector2(20, 20), Vector2(40, 20), Color.BLACK)
	surface._place_nail(Vector2(30, 20))
	# 使用项目内临时路径，确保无 user:// 写权限的 headless/沙箱环境也能验收；退出前删除。
	var path: String = "res://test/.canvas_roundtrip.tmp.tres"
	var png_path: String = "res://test/.canvas_roundtrip.tmp.png"
	for temp_path in [path, png_path]:
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
	canvas.capture_path = path
	canvas.baked_map_path = png_path
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
	#只回收画布内的部分：刚体跨在画布边上时，画布外的那半边留在世界里。
	var brush: int = surface.brush_size
	surface.clear()
	surface.brush_size = 1
	canvas.position = Vector2(5000, 5000)
	surface._stroke(Vector2(10, 10), Vector2(60, 10), Color.BLACK)
	canvas.solid.solidify(surface, scene)
	var bodies_before: int = scene.world.bodies.size()
	var ink = scene.world.bodies[-1]
	canvas.position = Vector2(5025, 5000)   # 往右挪 25px：笔划 10..60 里只有 25..60 落在画布里
	canvas.return_to_canvas()
	valid = valid and surface.is_solid(0, 10) and surface.is_solid(35, 10)
	valid = valid and not surface.is_solid(36, 10)
	valid = valid and scene.world.bodies.size() == bodies_before
	valid = valid and ink.shapes[0].pixel_count() == 15
	valid = valid and ink.shapes[0].get_pixel(10, 10) != 0 and ink.shapes[0].get_pixel(25, 10) == 0
	canvas.position = home
	#画布从中间切一刀：断成两截的残留都要留在世界里（分片走引擎分裂，节点下标不许错位）。
	surface.clear()
	canvas.position = Vector2(5000, 5000)
	canvas.canvas_size = Vector2i(64, 64)
	surface._stroke(Vector2(40, 10), Vector2(40, 40), Color.BLACK)
	canvas.solid.solidify(surface, scene)
	var split_before: int = scene.world.bodies.size()
	canvas.canvas_size = Vector2i(20, 6)
	canvas.position = Vector2(5040, 5020)   # 笔划 x=40 正好落在画布左缘，只有 y 20..25 这 6 行进画布
	canvas.return_to_canvas()
	var recycled: int = 0
	for y in range(6):
		if surface.is_solid(0, y):
			recycled += 1
	valid = valid and recycled == 6
	valid = valid and scene.world.bodies.size() == split_before + 1
	valid = valid and scene._body_nodes.size() == scene.world.bodies.size()
	canvas.canvas_size = Vector2i(320, 180)
	canvas.position = home
	surface.brush_size = brush
	surface.clear()
	surface._stroke(Vector2(20, 20), Vector2(40, 20), Color.BLACK)
	surface._place_nail(Vector2(30, 20))
	var body_count: int = scene.world.bodies.size()
	canvas.solid.solidify(surface, scene)
	valid = valid and scene.world.bodies.size() > body_count and not surface.is_solid(20, 20)
	var nailed = scene.world.bodies[-1]
	valid = valid and nailed.is_static and nailed.tags.has("static_anchor_points")
	var nail_shape = nailed.shapes[0]
	valid = valid and nail_shape.get_pixel(30, 20) == InkPalette.nail_material_id()
	var cut: Dictionary = {}
	for y in range(180):
		if nail_shape.get_pixel(35, y) != 0:
			cut[Vector2i(35, y)] = true
	var before_split: int = scene.world.bodies.size()
	scene.get_node("SimulationRuntime").commit(scene.world, {nailed: {nail_shape: cut}})
	valid = valid and nailed.is_static and scene.world.bodies.size() > before_split
	valid = valid and not scene.world.bodies[-1].is_static
	nail_shape = nailed.shapes[0]
	scene.get_node("SimulationRuntime").commit(scene.world,
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
	for temp_path in [path, png_path]:
		if FileAccess.file_exists(temp_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(temp_path))
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
