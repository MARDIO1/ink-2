extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var scene = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	var canvas = scene.get_node("SmallCanvas")
	var surface = canvas.surface
	canvas.canvas_size = Vector2i(100, 80)
	for y in range(10, 60):
		for x in range(10, 90):
			surface.write_pixel(Vector2i(x, y), Color.BLACK)
	surface.refresh()
	surface.brush_size = 5
	surface.blue_layer.begin_line(Vector2(20.5, 30.5))
	surface.blue_layer.finish_line(Vector2(60.5, 30.5))
	var five_px := true
	for y in range(28, 33):
		five_px = five_px and surface.blue_layer.mask.has(Vector2i(40, y))
	five_px = five_px and not surface.blue_layer.mask.has(Vector2i(40, 27)) \
		and not surface.blue_layer.mask.has(Vector2i(40, 33))
	print("PASS blue straight line follows 5 px brush" if five_px
		else "FAIL blue straight line follows 5 px brush")
	var blue = scene.get_node("SimulationRuntime/BlueInk")
	surface.tool = surface.Tool.RECT
	blue.begin(surface, Vector2(25.5, 20.5))
	blue.extend(surface, Vector2(55.5, 20.5))
	var rectangle_motor: bool = blue.drawing != null and blue.drawing.brush_width == 5
	blue.cancel()
	print("PASS blue rectangle uses 5 px motor arrow" if rectangle_motor
		else "FAIL blue rectangle uses 5 px motor arrow")
	scene.queue_free()
	await process_frame
	quit(0 if five_px and rectangle_motor else 1)
