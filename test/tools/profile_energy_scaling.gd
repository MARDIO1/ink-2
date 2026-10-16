extends "res://test/test_blue_energy.gd"
## 数值推进的长度标度测试；这是 headless CPU 数据，不冒充窗口 FPS。
func run() -> void:
	var rows: Array = []
	for length in [240, 512, 1024, 2048, 4096]:
		var wire = wire_rects([Rect2i(0, 0, length, 7)])
		var flow := Flow.new()
		flow.interval = 0.5
		var sink = connect_sink(flow, wire, Rect2i(length - 2, 0, 1, 7))
		var warmup := ceili(float(length) / 600.0 * 60.0) + 60
		var timings: Array[int] = []
		var before := 0
		var peak := 0
		for frame in warmup + 600:
			if frame % 30 == 0:
				for y in 7:
					flow.inject(wire, Vector2i(0, y), 1, 100.0)
			var started := Time.get_ticks_usec()
			flow.advance([wire], 1.0 / 60.0)
			if frame == warmup - 1:
				before = flow.stats.updates
			if frame >= warmup:
				timings.append(Time.get_ticks_usec() - started)
				peak = maxi(peak, flow.active_cells())
		timings.sort()
		var row := {"length": length, "width": 7, "steps_per_frame": 10, "frames": 600, "cpu_median_us": timings[300], "cpu_p95_us": timings[570], "active_peak": peak, "updates": flow.stats.updates - before, "delivered": sink.energy}
		rows.append(row)
		check("length %d supplies continuously without self short" % length, sink.energy > 0.0 and flow.stats.shorts == 0)
		wire.queue_free()
	var base: Dictionary = rows[0]
	for row: Dictionary in rows.slice(1):
		check("length %d work grows at most linearly with length" % row.length, float(row.updates) / base.updates <= float(row.length) / base.length * 1.35 + 0.5)
	DirAccess.make_dir_recursive_absolute("res://test/reports/blue_energy")
	FileAccess.open("res://test/reports/blue_energy/scaling.json", FileAccess.WRITE).store_string(JSON.stringify({"rows": rows, "failures": failures, "scope": "headless numerical CPU including GDScript adapter; not render FPS"}, "\t"))
	print("BLUE_SCALING ", JSON.stringify(rows))
	quit(1 if failures else 0)
