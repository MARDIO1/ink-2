extends Node2D
## 白墨实景测试：自由落体、薄墙扫掠、红墨反应、黄线死亡和玩家扣血。
const Item := preload("res://actor/ink_item/src/ink_item.gd")
const ShapeNode := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Stroke := preload("res://actor/yellow/src/yellow_stroke.gd")
const Palette := preload("res://ink/src/ink_palette.gd")
var samples: Dictionary = {}
var failures := 0
var frames := 0
var profile_max := 0
var automated := false
var stress := false
var stress_times: Array[int] = []
var stress_process: Array[int] = []
var stress_worst: Dictionary = {}
@onready var main = $Main

func _ready() -> void:
	automated = "--white-test" in OS.get_cmdline_user_args()
	stress = "--white-stress" in OS.get_cmdline_user_args()
	_build.call_deferred()

func _build() -> void:
	main.auto_step = false
	main.world.gravity = Vector2(0, 600)
	main.world.min_fragment_pixels = 1
	for name in ["Box", "Ground"]:
		var node = main.get_node(name)
		var body = node.body
		main.remove_body_node(node)
		for shape in body.shapes:
			shape.owner_body = null
		body.shapes.clear()
		node.queue_free()
	if automated:
		_test_canvas()
		_check("white renderer palette", main.renderer.palette.size() > Palette.WHITE.id and main.renderer.palette[Palette.WHITE.id].is_equal_approx(Palette.WHITE.color))
	for name in ["SmallCanvas", "MapCanvas", "Gym", "debugHUD"]:
		var node = main.get_node_or_null(name)
		if node != null:
			node.visible = false
	var camera: Camera2D = main.get_node("Camera2D")
	camera.set_script(null)
	camera.position = Vector2(400, 160)
	camera.zoom = Vector2.ONE
	RenderingServer.set_default_clear_color(Color(0.13, 0.16, 0.20))
	if stress:
		main.world.gravity = Vector2.ZERO
		var white_rule = main.get_node("SimulationRuntime/WhiteInk")
		white_rule.base_yield = 100.0
		white_rule.max_yield = 100.0
		samples.target = _add("StressTarget", Vector2(0, 30), Vector2i(800, 200), Palette.BLACK.id)
		samples.white = _add("StressWhite", Vector2(0, 80), Vector2i(64, 64), Palette.WHITE.id)
		samples.white.linear_velocity = Vector2(960, 0)
		_label("WHITE / continuous dissolution stress", Vector2(20, -30))
		# 先完成生成贴图；用户允许生成尖峰，压力统计只覆盖后续消融。
		for body in main.world.bodies:
			main.renderer.sync(body)
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
		main.get_node("SimulationRuntime").set_profile_enabled(true)
		main.auto_step = true
		set_physics_process(true)
		return
	_add("Floor", Vector2(-80, 360), Vector2i(960, 16), Palette.GREY.id, true)
	_label("WHITE / ghost PBody sweep test", Vector2(20, -60))
	_label("BLACK          GREY          RED          YELLOW          PLAYER", Vector2(20, -20))
	for index in 3:
		var x := 80.0 + index * 150.0
		var material: int = [Palette.BLACK.id, Palette.GREY.id, Palette.RED.id][index]
		var target = _add("Target%d" % index, Vector2(x - 35, 100), Vector2i(70, 5), material, true)
		samples["target%d" % index] = target
		var white = _add("White%d" % index, Vector2(x - 10, 35), Vector2i(20, 50), Palette.WHITE.id)
		samples["white%d" % index] = white
	var a = _add("AnchorA", Vector2(505, 100), Vector2i(10, 10), Palette.BLACK.id, true)
	var b = _add("AnchorB", Vector2(580, 100), Vector2i(10, 10), Palette.BLACK.id, true)
	var yellow = main.get_node("SimulationRuntime/YellowInk")
	var stroke = Stroke.new()
	stroke.path = PackedVector2Array([Vector2(510, 105), Vector2(585, 105)])
	stroke.brush_width = 7
	main.add_child(stroke)
	stroke.build_pixels()
	stroke.anchors = [{"body": a, "cell": Vector2i(5, 5), "local": Vector2(5, 5)},
		{"body": b, "cell": Vector2i(5, 5), "local": Vector2(5, 5)}]
	stroke.rest_length = 75.0
	stroke.state = Stroke.State.ACTIVE
	stroke.activated = true
	yellow.strokes.append(stroke)
	yellow.connect_stroke(stroke, main.world)
	samples.yellow = stroke
	_add("YellowEraser", Vector2(545, 35), Vector2i(12, 50), Palette.WHITE.id)
	var player = main.get_node("Player")
	player.body.position = Vector2(720, 130)
	player.body.linear_velocity = Vector2.ZERO
	samples.health = player.get_node("InkHealth").ink_of(Palette.BLACK.id)
	_add("PlayerEraser", Vector2(710, 20), Vector2i(20, 60), Palette.WHITE.id)
	main.get_node("SimulationRuntime").set_profile_enabled(true)
	main.auto_step = true
	set_physics_process(true)

func _physics_process(_delta: float) -> void:
	if samples.is_empty() or not main.auto_step:
		return
	frames += 1
	var profile: Dictionary = main.get_node("SimulationRuntime").take_profile()
	profile_max = maxi(profile_max, int(profile.get("physics_us", 0)))
	if stress:
		if int(profile.get("physics_us", 0)) >= profile_max:
			stress_worst = profile.duplicate(true)
			stress_worst.frame = frames
		stress_times.append(int(profile.get("physics_us", 0)))
		stress_process.append(int(Performance.get_monitor(Performance.TIME_PROCESS) * 1000000))
		if frames == 40:
			stress_times.sort()
			stress_process.sort()
			print("WHITE_MAP_STRESS frames=40 physics_p95_us=%d physics_max_us=%d process_p95_us=%d process_max_us=%d" % [stress_times[37], stress_times[39], stress_process[37], stress_process[39]])
			print("WHITE_MAP_WORST ", stress_worst)
			var clean := true
			for y in range(50, 114):
				for x in range(32, 600):
					clean = clean and samples.target.shapes[0].get_pixel(x, y) == 0
			_check("continuous map lane erased", clean)
			get_tree().quit(1 if failures else 0)
		return
	if automated and frames == 45:
		for index in 2:
			var target = samples["target%d" % index]
			var gap := true
			for y in 5:
				for x in range(25, 45):
					for shape in target.shapes:
						gap = gap and shape.get_pixel(x, y) == 0
			_check("clean thin-wall lane %d" % index, gap)
		var red_left := 0
		for shape in samples.target2.shapes:
			red_left += shape.pixel_count()
		_check("red reacted (64px event group)", red_left < 70 * 5 - 20 * 5)
		_check("yellow died", not is_instance_valid(samples.yellow) or samples.yellow.state >= Stroke.State.DYING)
		_check("player damaged", main.get_node("Player/InkHealth").ink_of(Palette.BLACK.id) < samples.health)
		print("WHITE_MAP_RESULT failures=%d max_physics_us=%d" % [failures, profile_max])
		if DisplayServer.get_name() != "headless":
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png("res://.godot/white_map.png")
		get_tree().quit(1 if failures else 0)

func _add(title: String, at: Vector2, size: Vector2i, material: int, fixed := false):
	var item = Item.new()
	item.name = title
	item.position = at
	item.is_static = fixed
	var shape = ShapeNode.new()
	shape.rect_size = size
	shape.material_id = material
	item.add_child(shape)
	main.add_child(item)
	return main.add_body_node(item)

func _label(text: String, at: Vector2) -> void:
	var label := Label.new()
	label.text = text
	label.position = at
	label.add_theme_font_size_override("font_size", 17)
	main.add_child(label)

func _check(title: String, passed: bool) -> void:
	print("PASS " if passed else "FAIL ", title)
	if not passed:
		failures += 1

func _test_canvas() -> void:
	var canvas = main.get_node("SmallCanvas")
	var surface = canvas.surface
	var at: Vector2 = surface.global_position + Vector2(5, 5)
	var target = _add("OverlapFixture", at, Vector2i(8, 8), Palette.BLACK.id, true)
	surface.clear()
	for y in range(5, 13):
		for x in range(5, 13):
			surface.write_pixel(Vector2i(x, y), Palette.WHITE.color)
	surface.write_pixel(Vector2i(20, 5), Palette.WHITE.color)
	surface.write_pixel(Vector2i(21, 5), Palette.WHITE.color)
	surface.refresh()
	canvas.generate()
	var white = null
	for body in main.world.bodies:
		if body.tags.has("white_ink"):
			white = body
	_check("canvas white survives overlapping target", white != null and preload("res://ink/src/white_ink.gd")._area(white) == 66 and target.shapes[0].pixel_count() == 64)
	_check("disconnected white uses one body", main.world.bodies.filter(func(body): return body.tags.has("white_ink")).size() == 1)
	_check("activated white cannot undo", surface._undo_steps.is_empty())
	for body in [target, white]:
		if body == null:
			continue
		var index: int = main.world.bodies.find(body)
		var node = main._body_nodes[index]
		main.remove_body_node(node)
		for shape in body.shapes:
			shape.owner_body = null
		body.shapes.clear()
		node.queue_free()

