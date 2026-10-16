extends Node2D
## F6 可玩的确定性压力地图。-- --bench --case=chaos 自动输出窗口帧耗时验收。
## 使用完整关卡的 SimulationRuntime / Rapier / 材质 / 箭头，不用空循环冒充游戏 FPS。
const Palette := preload("res://ink/src/ink_palette.gd")
const Motor := preload("res://ink/src/blue/motor.gd")
const Wire := preload("res://ink/src/blue/wire_layer.gd")
@export_enum("short", "long", "chaos") var scenario := "chaos"
@export var warmup_seconds := 5.0
@export var sample_seconds := 15.0
@export var repair_interval := 1.5
var world
var rule
var wire
var original: Dictionary = {}
var repair_queue: Dictionary = {}
var samples: Array[float] = []
var blue_samples: Array[int] = []
var label: Label
var since_start := 0.0
var repair_elapsed := 0.0
var ready_to_measure := false
var previous_us := 0
var bench := false
var peak_active := 0
var powered_frames := 0
var active_frames := 0
var sample_frames := 0
var repaired_pixels := 0
var load_ms := 0.0
var measurement_start_us := 0
var next_telemetry := 1.0
var frame_trace: Array = []
var last_phases := Vector3.ZERO
var phase_baseline: Dictionary = {}
var motor_templates: Array = []
var repaired_motors := 0

func _ready() -> void:
	var started := Time.get_ticks_usec()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--case="):
			scenario = arg.trim_prefix("--case=")
	bench = "--bench" in OS.get_cmdline_user_args()
	if "--quick" in OS.get_cmdline_user_args():
		warmup_seconds = 1.0
		sample_seconds = 4.0
	if get_tree().has_meta("blue_stress_case"):
		scenario = get_tree().get_meta("blue_stress_case")
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	get_window().mode = Window.MODE_WINDOWED
	get_window().content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	get_window().content_scale_size = Vector2i.ZERO
	get_window().content_scale_factor = 1.0
	get_window().size = Vector2i(2560, 1440)
	Engine.max_fps = 0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fps="):
			Engine.max_fps = int(arg.trim_prefix("--fps="))
	world = load("res://map/asset/imported/main.tscn").instantiate()
	world.auto_step = false
	add_child(world)
	await get_tree().process_frame
	await get_tree().process_frame
	var canvas = world.get_node("SmallCanvas")
	canvas.position = Vector2(5000, 5000)
	canvas.canvas_size = Vector2i(2100, 1180)
	var surface = canvas.surface
	surface.ink_free = true
	surface.set_process(false)
	surface.set_process_input(false)
	surface.black_image.fill(Color.BLACK)
	surface.rebuild_ink_tiles()
	surface._rebuild_loaded_metadata()
	# 保持源头有燃料，测量期间不因燃料耗尽变成空闲电路；专门耗料测试另行覆盖。
	rule = world.get_node("SimulationRuntime/BlueInk")
	rule.energy_per_red_pixel = 1.0e14
	rule.propagation_speed = 600.0
	var red_rects: Array[Rect2i] = [Rect2i(8, 0, 12, 1180)]
	var length := 240 if scenario == "short" else 2048
	var rows: Array = [550] if scenario != "chaos" else [80, 200, 320, 440, 560, 680, 800, 920, 1040]
	surface.brush_size = 7
	for y in rows:
		surface._brush_line(original, Vector2(20.5, y + 0.5), Vector2(length + 20.5, y + 0.5))
	if scenario == "chaos":
		# 密集交叉、斜线、闭环、窄段、多点供能。固定种子与坐标便于复测。
		for x in range(160, 2040, 170):
			surface._brush_line(original, Vector2(x + 0.5, 50.5), Vector2(x + 0.5, 1080.5))
		for i in 6:
			var a := Vector2(80.5 + i * 280, 70.5)
			var b := Vector2(400.5 + i * 230, 1080.5)
			surface._brush_line(original, a, b)
		for y in [200, 560, 920]:
			red_rects.append(Rect2i(990, y - 18, 20, 15))
	for rect: Rect2i in red_rects:
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				surface.black_image.set_pixel(x, y, Palette.RED.color)
				original.erase(Vector2i(x, y))
	surface.rebuild_ink_tiles()
	surface._rebuild_loaded_metadata()
	surface.blue_layer.mask = original.duplicate()
	surface.blue_layer.refresh()
	surface.blue_layer.build_widths()
	for y in rows:
		var motor := Motor.new()
		motor.position = surface.to_global(Vector2(length - 80, y + 0.5))
		motor.tip = Vector2(80, 0)
		motor.brush_width = 7
		motor.source_surface = surface
		motor.source_canvas = world.get_path_to(surface)
		world.add_child(motor)
		motor.owner = world
	canvas.generate(false)
	for object in rule.objects(Wire):
		object.body.is_static = true
		wire = object
		wire.pixels_removed.connect(_on_cut)
	if scenario == "chaos":
		# 源附近也有消费者，且远端消费者保留；防止只有发包没有实际消费的假验收。
		for y in [200, 560, 920]:
			var motor := Motor.new()
			motor.position = canvas.position + Vector2(1010.5, y + 0.5)
			motor.tip = Vector2(70, 0)
			motor.brush_width = 7
			world.add_child(motor)
			motor.bind(rule.Anchor.find_anchor(world.world, motor.position))
			motor.owner = world
	var camera := Camera2D.new()
	for motor in rule.objects(Motor):
		motor.set_meta("stress_motor", motor_templates.size())
		motor_templates.append([motor.position, motor.tip, motor.brush_width])
	camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	add_child(camera)
	camera.position = canvas.position + Vector2(1050, 590)
	camera.zoom = Vector2.ONE * minf(get_viewport_rect().size.x / 2200.0, get_viewport_rect().size.y / 1280.0)
	camera.make_current()
	camera.force_update_scroll()
	var layer := CanvasLayer.new()
	add_child(layer)
	label = Label.new()
	label.position = Vector2(18, 14)
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.add_theme_color_override("font_shadow_color", Color.BLACK)
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	layer.add_child(label)
	rule.set_profile_enabled(true)
	world.auto_step = true
	load_ms = (Time.get_ticks_usec() - started) / 1000.0
	since_start = 0.0
	previous_us = Time.get_ticks_usec()
	measurement_start_us = previous_us
	ready_to_measure = true
	print("BLUE_STRESS_READY case=%s pixels=%d load_ms=%.1f" % [scenario, original.size(), load_ms])

func _process(delta: float) -> void:
	if not ready_to_measure:
		return
	var now := Time.get_ticks_usec()
	var frame_ms := (now - previous_us) / 1000.0
	previous_us = now
	since_start = (now - measurement_start_us) / 1000000.0
	repair_elapsed += delta
	if scenario == "chaos" and repair_elapsed >= repair_interval:
		repair_elapsed = 0.0
		# 修复只刷被烧掉的像素，包含在采样中；不让闭环全烧断后冒充高 FPS。
		for at: Vector2i in repair_queue:
			if not wire.mask.has(at):
				wire.mask[at] = true
				wire._cells_dirty = true
				wire._set_display_pixel(at, Palette.BLUE.color)
				repaired_pixels += 1
		rule.flow.repair_pixels(wire, PackedVector2Array(repair_queue.keys()))
		wire.flush_display(false)
		wire.version += 1
		repair_queue.clear()
		var present := {}
		for motor in rule.objects(Motor):
			present[motor.get_meta("stress_motor", -1)] = true
		for index in motor_templates.size():
			if present.has(index):
				continue
			var template: Array = motor_templates[index]
			var motor := Motor.new()
			motor.position = template[0]
			motor.tip = template[1]
			motor.brush_width = template[2]
			motor.set_meta("stress_motor", index)
			world.add_child(motor)
			motor.bind(rule.Anchor.find_anchor(world.world, motor.position))
			repaired_motors += 1
	var active: int = rule.flow.active_cells()
	peak_active = maxi(peak_active, active)
	var powered := false
	for motor in rule.objects(Motor):
		powered = powered or motor.received_power > 0.0
	var profile: Dictionary = rule.take_profile()
	var phases := Vector3(rule.flow.stats.get("advance_us", 0), rule.flow.stats.get("emit_us", 0), rule.flow.stats.get("contacts_us", 0))
	if bench and since_start >= next_telemetry:
		print("BLUE_STRESS_TICK wall=%.1f active=%d blue_us=%d shorts=%d" % [since_start, active, profile.get("resolve_us", 0), rule.flow.stats.shorts])
		next_telemetry = since_start + 2.0
	if since_start >= warmup_seconds:
		if samples.is_empty():
			phase_baseline = rule.flow.stats.duplicate()
		frame_trace.append([frame_ms, profile.get("resolve_us", 0), phases - last_phases, repair_queue.size()])
		samples.append(frame_ms)
		if profile.has("resolve_us"):
			blue_samples.append(profile.resolve_us)
		sample_frames += 1
		active_frames += 1 if active > 0 else 0
		powered_frames += 1 if powered else 0
	last_phases = phases
	label.text = "BLUE ENERGY | %s | FPS %d | active %d | powered %s\n600 px/s | R: reset | 1: short  2: long  3: chaos | auto repair %.1fs\n%s %.1f / %.1f s | shorts %d | repaired %d" % [scenario, Engine.get_frames_per_second(), active, str(powered), repair_interval, "SAMPLE" if since_start >= warmup_seconds else "WARMUP", maxf(0.0, since_start - warmup_seconds), sample_seconds, rule.flow.stats.shorts, repaired_pixels]
	if since_start >= warmup_seconds + sample_seconds and bench:
		_finish()

func _finish() -> void:
	ready_to_measure = false
	samples.sort()
	blue_samples.sort()
	var worst_count := maxi(1, ceili(samples.size() * 0.01))
	var sum_worst := 0.0
	for i in range(samples.size() - worst_count, samples.size()):
		sum_worst += samples[i]
	var low := 1000.0 / (sum_worst / worst_count)
	var result := {"case": scenario, "viewport": get_viewport_rect().size, "pixels": original.size(), "frames": samples.size(), "seconds": sample_seconds, "warmup_seconds": warmup_seconds, "one_percent_low_fps": low, "frame_p99_ms": samples[int(samples.size() * 0.99)], "frame_max_ms": samples[-1], "active_frame_ratio": float(active_frames) / maxi(1, sample_frames), "powered_frame_ratio": float(powered_frames) / maxi(1, sample_frames), "peak_active": peak_active, "shorts": rule.flow.stats.shorts, "repaired_pixels": repaired_pixels, "load_ms": load_ms, "speed_px_s": rule.flow.speed, "blue_p95_us": blue_samples[int(blue_samples.size() * 0.95)] if not blue_samples.is_empty() else 0}
	# 短线的通过时间 0.4s，小于 0.5s 发包周期，约 20% 帧处于自然包间隙。
	var required_active := 0.7 if scenario == "short" else 0.95
	var passed: bool = low >= 50.0 and result.active_frame_ratio >= required_active and result.powered_frame_ratio >= 0.5
	result["passed"] = passed
	result["phase_totals"] = rule.flow.stats
	var phase_sample := {}
	for key in rule.flow.stats:
		phase_sample[key] = rule.flow.stats[key] - phase_baseline.get(key, 0)
	result["sample_phases"] = phase_sample
	result["sample_frames_ms"] = samples
	result["render_pixels"] = get_viewport().get_texture().get_size()
	result["repaired_motors"] = repaired_motors
	result["fps_cap"] = Engine.max_fps
	result["emission_interval"] = rule.emission_interval
	frame_trace.sort_custom(func(a, b): return a[0] > b[0])
	result["worst_frames_ms_blue_us_phases_us"] = frame_trace.slice(0, 20)
	DirAccess.make_dir_recursive_absolute("res://test/reports/blue_energy")
	FileAccess.open("res://test/reports/blue_energy/%s.json" % scenario, FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	var summary := result.duplicate()
	summary.erase("sample_frames_ms")
	summary.erase("worst_frames_ms_blue_us_phases_us")
	print("BLUE_STRESS_RESULT ", JSON.stringify(summary))
	get_viewport().get_texture().get_image().save_png("res://test/reports/blue_energy/%s.png" % scenario)
	get_tree().quit(0 if passed else 1)

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_1, KEY_2, KEY_3]:
			get_tree().set_meta("blue_stress_case", ["short", "long", "chaos"][event.keycode - KEY_1])
			get_tree().reload_current_scene()
		elif event.keycode == KEY_R:
			get_tree().reload_current_scene()

func _on_cut(points: Array) -> void:
	for at: Vector2i in points:
		repair_queue[at] = true
