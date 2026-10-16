extends "res://test/test_blue_energy.gd"
## 使用真实圆盘笔刷生成走线，不用理想矩形代替手绘；从端点和侧面供能。
const Surface := preload("res://actor/canvas/src/canvas_surface.gd")

func run() -> void:
	var brush := Surface.new()
	brush.canvas_size = Vector2i(600, 600)
	var cases := 0
	var broken: Array = []
	for width in [2, 3, 4, 7, 11, 17]:
		brush.brush_size = width
		for jitter in [0.0, 0.7]:
			for slope in [0.0, 0.35, 0.75]:
				for side_supply in [false, true]:
					var pixels := {}
					var previous := Vector2(20.3, 120.7)
					for x in range(25, 470, 5):
						var point := Vector2(x + 0.3, 120.7 + (x - 20) * slope + sin(x * 1.3) * jitter)
						brush._brush_line(pixels, previous, point)
						previous = point
					var wire := Wire.new()
					wire.cells = PackedVector2Array(pixels.keys())
					wire.body = Body.new()
					root.add_child(wire)
					var flow := Flow.new()
					flow.interval = 0.1
					for frame in 120:
						if frame % 6 == 0:
							for at: Vector2i in pixels:
								if side_supply:
									if at.x < 30 or at.x > 50:
										continue
									for d in 4:
										if not pixels.has(at + flow.DIRS[d]):
											flow.inject(wire, at, d ^ 1, 100.0, -42)
								elif at.x == 21:
									flow.inject(wire, at, 1, 100.0)
						flow.advance([wire], 1.0 / 60.0)
					cases += 1
					if flow.stats.shorts > 0:
						broken.append([width, jitter, slope, side_supply, flow.stats.shorts])
					wire.queue_free()
					await process_frame
	brush.free()
	print("FREEHAND cases=", cases, " spontaneous_shorts=", broken)
	check("real brush straight and jittered strokes never self-destruct", broken.is_empty())
	quit(1 if failures else 0)
