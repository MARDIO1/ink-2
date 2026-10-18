extends SceneTree
## 构建并保存真实可玩的双轮反转车；支架托起车身，便于观察两轮相反旋转。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const BlueInk := preload("res://ink/blue/src/blue_ink.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const DESTINATION := "res://test/fixtures/maps/blue_car.tscn"
var level
var surface

func _initialize() -> void:
	if "--preview" in OS.get_cmdline_user_args():
		root.mode = Window.MODE_WINDOWED
		root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
		root.content_scale_size = Vector2i.ZERO
		root.size = Vector2i(1920, 1080)
		Engine.max_fps = 60
	call_deferred("run")

func paint(rect: Rect2i, color: Color) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			surface.black_image.set_pixel(x, y, color)

func run() -> void:
	level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	await process_frame
	var canvas = level.get_node("SmallCanvas")
	canvas.position = Vector2(5000, 5000)
	canvas.canvas_size = Vector2i(1000, 600)
	surface = canvas.surface
	surface.ink_free = true
	surface.black_image.fill(Color.TRANSPARENT)
	paint(Rect2i(20, 500, 960, 20), Color.BLACK)
	paint(Rect2i(398, 350, 44, 7), Color.BLACK)
	paint(Rect2i(419, 350, 3, 150), Color.BLACK)
	# 与台座留空隙，生成两个独立红墨刚体；窄料槽限制侧翻，靠重力补料。
	for x in [404, 414, 425, 435]:
		paint(Rect2i(x, 310, 2, 40), Color.BLACK)
	surface.black_image.set_pixel(420, 480, Palette.nail_color())
	for cx in [240, 600]:
		for y in range(296, 425):
			for x in range(cx - 64, cx + 65):
				var distance := Vector2(x - cx, y - 360).length()
				if distance <= 64:
					surface.black_image.set_pixel(x, y, Color.BLACK)
	surface.rebuild_ink_tiles()
	surface._rebuild_loaded_metadata()
	surface.brush_size = 7
	surface.rod_layer.begin(Vector2(240.5, 360.5))
	surface.rod_layer.finish(Vector2(600.5, 360.5))
	for cx in [240, 420, 600]:
		surface.rod_layer.place_anchor(Vector2(cx + 0.5, 360.5))
	# 车架只保留一个中央支点，作为可自由转动的杠杆；两端轮轴各自旋转。
	var rule = level.get_node("SimulationRuntime/BlueInk")
	# 恢复正常燃料密度，满接触时每秒消耗约一行，肉眼可见地缩短/下落。
	rule.energy_per_red_pixel = 1.0e8
	# 两条独立链路：台座燃料 → 集电环两条通道 → 黄色车架 → 各自轮轴滑环。
	surface.brush_size = 1
	for pair in [[Vector2(406.5, 350.5), Vector2(416.5, 350.5)], [Vector2(416.5, 350.5), Vector2(416.5, 355.5)], [Vector2(424.5, 355.5), Vector2(424.5, 350.5)], [Vector2(424.5, 350.5), Vector2(434.5, 350.5)], [Vector2(245.5, 362.5), Vector2(415.5, 362.5)], [Vector2(425.5, 362.5), Vector2(595.5, 362.5)]]:
		surface.blue_layer.begin(pair[0])
		surface.blue_layer.extend(pair[1])
		surface.blue_layer.finish()
	for index in 2:
		var cx := 240 if index == 0 else 600
		surface.brush_size = 1
		surface.blue_layer.begin(Vector2(cx + 0.5, 355.5))
		surface.blue_layer.extend(Vector2(cx + 0.5, 325.5))
		surface.blue_layer.finish()
		surface.brush_size = 5
		var sign_x := 1.0 if index == 0 else -1.0
		rule.begin(surface, Vector2(cx - sign_x * 5 + 0.5, 325.5))
		if not rule.finish(surface, Vector2(cx + sign_x * 45 + 0.5, 325.5)):
			push_error("Vehicle arrow could not attach")
			quit(1)
			return
	canvas.generate(false)
	await process_frame
	# 车架穿过轮盘；保留各自绘制的通道，避免交叠投影成为轮盘上的断头支线。
	for motor in rule.objects(Motor):
		for wire in rule.objects(Wire):
			if wire.body != motor.body:
				continue
			var cells := PackedVector2Array()
			for cell in wire.cells:
				if wire.body.to_world(cell).y <= canvas.position.y + 355.5:
					cells.append(cell)
			wire.cells = cells
			wire.rebuild()
	if rule.objects(Motor).size() != 2 or rule.objects(Hinge).size() != 3:
		push_error("Vehicle requires two wheel hinges and one center hinge")
		quit(1)
		return
	# 单独一次生成：即使燃料贴着料槽，也不能与黑色台座合并成一个刚体。
	paint(Rect2i(406, 320, 8, 28), Palette.RED.color)
	paint(Rect2i(427, 320, 8, 28), Palette.RED.color)
	surface.rebuild_ink_tiles()
	surface._rebuild_loaded_metadata()
	canvas.generate(false)
	await process_frame
	var camera = level.get_node("Camera2D")
	camera.enabled = false
	var view := Camera2D.new()
	view.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	view.name = "VehicleView"
	view.position = canvas.position + Vector2(470, 320)
	view.zoom = Vector2.ONE * 1.3
	level.add_child(view)
	view.owner = level
	view.make_current()
	var title := Label.new()
	title.name = "VehicleDescription"
	title.text = "双轮反转车：左轮顺时针 / 右轮逆时针\n红色燃料条独立下落补料 → 台座集电环 → 车架 → 轮轴电滑环\n观察红条逐渐缩短、下落；燃料用尽后停止供电。"
	title.position = canvas.position + Vector2(160, 200)
	title.add_theme_color_override("font_color", Color.BLACK)
	title.add_theme_font_size_override("font_size", 16)
	level.add_child(title)
	title.owner = level
	level.get_node("Player").position = canvas.position + Vector2(780, 420)
	canvas.position += Vector2(1400, 0)
	level.auto_step = true
	var creative = level.get_node("Creative")
	creative.save_preview_on_export = false
	if creative.export_map_to(DESTINATION) != OK:
		quit(1)
		return
	level.queue_free()
	await process_frame
	# 用保存后的地图重新载入再验收，避免只测试未保存的构建状态。
	level = load(DESTINATION).instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	await process_frame
	rule = level.get_node("SimulationRuntime/BlueInk")
	var blue_rules: Array = level.get_node("SimulationRuntime").get_children().filter(
		func(child): return child.get_script() == BlueInk)
	if blue_rules.size() != 1:
		push_error("Vehicle must reload with exactly one BlueInk rule")
		quit(1)
		return
	if rule.energy_per_red_pixel != 1.0e8:
		push_error("Vehicle fuel setting did not survive saving")
		quit(1)
		return
	var motors: Array = rule.objects(Motor)
	var fuel_bodies: Array = []
	var initial_red := 0
	for body in level.world.bodies:
		for shape in body.shapes:
			var red_count: int = shape.count_by_material().get(Palette.RED.id, 0)
			initial_red += red_count
			if red_count > 0 and red_count == shape.pixel_count() and not body.is_static:
				fuel_bodies.append([body, body.position.y])
	if fuel_bodies.size() != 2:
		push_error("Fuel must reload as two independent dynamic red bodies")
		quit(1)
		return
	var runtime = level.get_node("SimulationRuntime")
	level.auto_step = true
	var peaks := Vector2.ZERO
	var drop := 0.0
	var explosion_pending := false
	for frame in 1200:
		runtime._physics_process(level.fixed_dt)
		for entry in fuel_bodies:
			drop = maxf(drop, entry[0].position.y - entry[1])
		explosion_pending = explosion_pending or not level.get_node("SimulationRuntime/RedInk")._pending.is_empty()
		peaks.x = maxf(peaks.x, motors[0].body.angular_velocity)
		peaks.y = minf(peaks.y, motors[1].body.angular_velocity)
	level.auto_step = false
	var remaining_red := 0
	for body in level.world.bodies:
		for shape in body.shapes:
			remaining_red += int(shape.count_by_material().get(Palette.RED.id, 0))
	print("CAR_FUEL initial=", initial_red, " remaining=", remaining_red, " drop_px=", drop, " explosion=", explosion_pending)
	print("BLUE_CAR saved=", DESTINATION, " motors=", motors.size(), " hinges=", rule.objects(Hinge).size(), " rotation_peaks=", peaks, " shorts=", rule.flow.stats.shorts)
	if "--preview" in OS.get_cmdline_user_args():
		level.auto_step = true
		for frame in 120:
			await process_frame
		root.get_texture().get_image().save_png("res://test/reports/blue_energy/blue_car.png")
		print("CAR_PREVIEW hinges=", rule.objects(Hinge).size(), " shorts=", rule.flow.stats.shorts)
	quit(0 if peaks.x > 0.1 and peaks.y < -0.1 and rule.objects(Hinge).size() == 3 and rule.flow.stats.shorts == 0 and remaining_red < initial_red - 16 and remaining_red > 0 and drop > 2.0 and not explosion_pending else 1)

