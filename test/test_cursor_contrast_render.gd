extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(960, 540)
	var background := ColorRect.new()
	background.size = Vector2(960, 540)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(background)
	var cursor = root.get_node("InkCursor")
	cursor.set_process(false)
	var passed := true
	for variant in 6:
		var color: Color = [Color.BLACK, Color.WHITE, Color(0.5, 0.5, 0.5)][variant % 3]
		var large := variant >= 3
		background.color = color
		cursor.pointer.texture = cursor.LARGE_CANVAS_TEXTURE if large else cursor.CANVAS_TEXTURE
		cursor.pointer.position = Vector2(400, 200)
		cursor.pointer.size = Vector2(120, 120)
		cursor.pointer.show()
		await process_frame
		await RenderingServer.frame_post_draw
		var screenshot := root.get_texture().get_image()
		var contrast := 0
		for y in range(200, 320):
			for x in range(400, 520):
				var actual := screenshot.get_pixel(x, y)
				if absf(actual.r - color.r) > 0.4:
					contrast += 1
		passed = passed and contrast > 100
		print("[CursorContrast] large=%s background=%s visible_pixels=%d %s" % [large, color, contrast, "PASS" if contrast > 100 else "FAIL"])
		if large:
			var center := screenshot.get_pixel(460, 260)
			var hollow := absf(center.r - color.r) < 0.01
			passed = passed and hollow
			print("[CursorContrast] large center stays transparent %s" % ("PASS" if hollow else "FAIL"))
		elif color == Color.WHITE:
			# 逐个检查原图的不透明像素，黑白细节不能同被着色器染黑。
			var source: Image = cursor.CANVAS_TEXTURE.get_image()
			var retained := true
			for y in 40:
				for x in 40:
					var expected: Color = source.get_pixel(x, y)
					if expected.a > 0.5:
						var actual := screenshot.get_pixel(400 + x * 3 + 1, 200 + y * 3 + 1)
						retained = retained and absf(actual.r - expected.r) < 0.01
			passed = passed and retained
			print("[CursorContrast] small cursor retains original black and white pixels %s" % ("PASS" if retained else "FAIL"))
		if color == Color.BLACK and large:
			screenshot.save_png("res://.codex-tmp/cursor_black_ink_verified.png")
		if color == Color.WHITE and large:
			screenshot.save_png("res://.codex-tmp/cursor_large_hollow_verified.png")
	background.free()
	quit(0 if passed else 1)
