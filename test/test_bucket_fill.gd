extends SceneTree

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene: Node = load("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas: Node = scene.get_node("SmallCanvas")
	var surface: Area2D = canvas.get_node("CanvasSurface")
	canvas.canvas_size = Vector2i(48, 48)
	surface.ink_free = true

	# 画一条封闭方框；桶应仅填充内部，且 Ctrl+Z 使用的撤销数据应能恢复。
	for x in range(8, 40):
		surface.write_pixel(Vector2i(x, 8), Color.BLACK)
		surface.write_pixel(Vector2i(x, 39), Color.BLACK)
	for y in range(8, 40):
		surface.write_pixel(Vector2i(8, y), Color.BLACK)
		surface.write_pixel(Vector2i(39, y), Color.BLACK)
	surface.refresh()
	surface._begin_undo_step()
	var closed_filled: bool = surface._bucket_fill(Vector2(24, 24))
	surface._commit_undo_step()
	var valid := closed_filled
	valid = valid and surface.black_image.get_pixelv(Vector2i(24, 24)).a > 0.5
	valid = valid and surface.black_image.get_pixelv(Vector2i(3, 3)).a < 0.5
	valid = valid and surface.undo_last_edit()
	valid = valid and surface.black_image.get_pixelv(Vector2i(24, 24)).a < 0.5

	# 画布边缘不再被无条件拒绝：小画布背景也可以直接灌满。
	surface._begin_undo_step()
	var edge_filled: bool = surface._bucket_fill(Vector2(3, 3))
	surface._commit_undo_step()
	valid = valid and edge_filled
	valid = valid and surface.black_image.get_pixelv(Vector2i(0, 0)).a > 0.5
	valid = valid and surface.black_image.get_pixelv(Vector2i(47, 47)).a > 0.5
	print("[BucketFill] closed region, edge region, and undo: ", "PASS" if valid else "FAIL")
	scene.queue_free()
	await process_frame
	quit(0 if valid else 1)
