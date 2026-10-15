extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://map/asset/imported/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas: Node = scene.get_node("MapCanvas")
	var surface: Area2D = canvas.get_node("CanvasSurface")
	canvas.canvas_size = Vector2i(520, 520)
	surface.ink_free = true
	surface.clear()

	# 508×508 的封闭空区超过旧版 25 万像素上限。
	for x in range(5, 515):
		surface.write_pixel(Vector2i(x, 5), Color.BLACK)
		surface.write_pixel(Vector2i(x, 514), Color.BLACK)
	for y in range(5, 515):
		surface.write_pixel(Vector2i(5, y), Color.BLACK)
		surface.write_pixel(Vector2i(514, y), Color.BLACK)
	surface.refresh()
	surface._begin_undo_step()
	var closed_filled: bool = surface._bucket_fill(Vector2(250, 250))
	surface._commit_undo_step()
	var valid := closed_filled
	valid = valid and surface.black_image.get_pixelv(Vector2i(250, 250)).a > 0.5
	valid = valid and surface.black_image.get_pixelv(Vector2i(3, 3)).a < 0.5
	valid = valid and surface.undo_last_edit()
	valid = valid and surface.black_image.get_pixelv(Vector2i(250, 250)).a < 0.5
	valid = valid and surface.redo_last_edit()
	valid = valid and surface.black_image.get_pixelv(Vector2i(250, 250)).a > 0.5

	# 连到画布边缘的开放区域不能填充。
	surface._begin_undo_step()
	var edge_filled: bool = surface._bucket_fill(Vector2(3, 3))
	surface._commit_undo_step()
	valid = valid and not edge_filled
	valid = valid and surface.black_image.get_pixelv(Vector2i(0, 0)).a < 0.5
	surface.clear()
	for x in range(20, 41):
		surface.rod_layer.pixels.set_pixelv(Vector2i(x, 20), Color.YELLOW)
		surface.rod_layer.pixels.set_pixelv(Vector2i(x, 40), Color.YELLOW)
	for y in range(20, 41):
		surface.rod_layer.pixels.set_pixelv(Vector2i(20, y), Color.YELLOW)
		surface.rod_layer.pixels.set_pixelv(Vector2i(40, y), Color.YELLOW)
	surface.rod_layer.refresh()
	surface._begin_undo_step()
	var yellow_closed: bool = surface._bucket_fill(Vector2(30, 30))
	surface._commit_undo_step()
	valid = valid and yellow_closed
	valid = valid and surface.black_image.get_pixelv(Vector2i(30, 30)).a > 0.5
	valid = valid and surface.black_image.get_pixelv(Vector2i(18, 18)).a < 0.5
	print("[BucketFill] large closed area, undo/redo, open area, yellow border: ",
		"PASS" if valid else "FAIL")
	scene.queue_free()
	await process_frame
	quit(0 if valid else 1)
