extends SceneTree
## 纯游戏机制 MOS 门：∞ 红墨真值源 + 黄色 SLIDER 导轨 + 蓝墨箭头栅极。

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const Rail := preload("res://ink/yellow/src/rail.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const DESTINATION := "res://map/logic/MOS门电路实验室.tscn"
var level
var canvas
var surface
var blue


func _initialize() -> void:
	call_deferred("run")


func pixel(rect: Rect2i, color: Color) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			surface.write_pixel(Vector2i(x, y), color)


func wire(a: Vector2, b: Vector2, width := 2) -> void:
	surface.brush_size = width
	surface.blue_layer.begin(a)
	surface.blue_layer.extend(b)
	surface.blue_layer.finish()


func arrow(a: Vector2, b: Vector2, width := 5) -> void:
	surface.brush_size = width
	blue.begin(surface, a)
	if not blue.finish(surface, b):
		push_error("MOS 栅极箭头无法附着: %s -> %s" % [a, b])


func spring(a: Vector2, b: Vector2, width := 7) -> void:
	surface.brush_size = width
	var yellow = level.get_node("SimulationRuntime/YellowInk")
	yellow.begin(surface, a)
	if not yellow.finish(surface, b):
		push_error("MOS 复位弹簧无法附着: %s -> %s" % [a, b])


func infinity_red(center: Vector2i, scale := 1) -> void:
	# 两个相切的离散环，红墨仍是实体材料而非图标节点。
	var radius := 7 * scale
	for side in [-1, 1]:
		var c := center + Vector2i(side * radius, 0)
		for y in range(-radius - 2, radius + 3):
			for x in range(-radius - 2, radius + 3):
				var d := Vector2(x, y).length()
				if d >= radius - 2 * scale and d <= radius + 1 * scale:
					surface.write_pixel(c + Vector2i(x, y), Palette.RED.color)


func mark_red_bodies_as_infinite() -> int:
	# 无限钉必须真正落在红像素上；InkItem.bake() 会据此写入 infinite_fuel 标签。
	# 这同时保留了可见的红色 ∞ 形状，逻辑供能不再依赖夸大的数值常量。
	var marked := 0
	for node in level.find_children("*", "", true, false):
		if not node is InkItem:
			continue
		var red_point := Vector2i(-2147483648, -2147483648)
		for shape in node.collect_shapes():
			var rect: Rect2i = shape.local_aabb()
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					if shape.get_pixel(x, y) == Palette.RED.id:
						red_point = Vector2i(x, y)
						break
				if red_point.x != -2147483648:
					break
			if red_point.x != -2147483648:
				break
		if red_point.x == -2147483648:
			continue
		node.infinite_nails = PackedVector2Array([red_point])
		node.infinite_nail_body = true
		node.infinite_fuel_body = true
		marked += 1
	return marked


func rail_with_pin(a: Vector2, b: Vector2, pin: Vector2, width := 11) -> void:
	surface.selected_ink = 3
	surface.brush_size = width
	surface.rod_layer.begin_rail(a)
	assert(surface.rod_layer.finish_rail(b))
	assert(surface.rod_layer.place_slider_pin(pin))
	# 两端各用一个真实黄色轴承固定导轨，防止导轨自身下落或旋转。
	assert(surface.rod_layer.place_anchor(a))
	assert(surface.rod_layer.place_anchor(b))


func mos_carriage(center: Vector2i, arrow_count: int, arrow_length: float, arrow_width: int) -> void:
	# 载体与导轨重叠处的黑像素是 SLIDER 销本体。
	pixel(Rect2i(center - Vector2i(50, 28), Vector2i(100, 56)), Color.BLACK)
	infinity_red(center + Vector2i(35, 0))
	# 两个彼此隔离的栅极输入母线；箭头只由各自红输入供能。
	for index in arrow_count:
		var y := center.y - 15 + index * 30
		wire(Vector2(center.x - 42, y) + Vector2.ONE * 0.5,
			Vector2(center.x + 42, y) + Vector2.ONE * 0.5, 2)
		var anchor_x := center.x - 22.0 if arrow_length > 0.0 else center.x + 35.0
		arrow(Vector2(anchor_x, y) + Vector2.ONE * 0.5,
			Vector2(anchor_x + arrow_length, y) + Vector2.ONE * 0.5, arrow_width)


func title(text: String, at: Vector2, size := 18) -> void:
	var label := Label.new()
	label.text = text
	label.position = canvas.position + at
	label.add_theme_color_override("font_color", Color("171712"))
	label.add_theme_font_size_override("font_size", size)
	level.add_child(label)
	label.owner = level


func run() -> void:
	level = load("res://map/asset/imported/main.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	await process_frame
	canvas = level.get_node("SmallCanvas")
	canvas.position = Vector2(5000, 5000)
	canvas.canvas_size = Vector2i(1500, 820)
	surface = canvas.surface
	surface.ink_free = true
	surface.black_image.fill(Color.TRANSPARENT)
	blue = level.get_node("SimulationRuntime/BlueInk")
	# 地面与三组固定导轨端座。
	pixel(Rect2i(20, 760, 1460, 30), Color.BLACK)
	surface.write_pixel(Vector2i(30, 770), Palette.nail_color())
	var specs := [
		{"name": "AND", "y": 190, "arrows": 2, "length": 55.0, "width": 4},
		{"name": "OR", "y": 430, "arrows": 2, "length": 64.0, "width": 6},
		{"name": "NOT", "y": 650, "arrows": 1, "length": -72.0, "width": 6},
	]
	for spec in specs:
		var y: int = spec.y
		pixel(Rect2i(145, y - 18, 30, 36), Color.BLACK)
		pixel(Rect2i(465, y - 18, 30, 36), Color.BLACK)
		surface.write_pixel(Vector2i(155, y), Palette.nail_color())
		surface.write_pixel(Vector2i(485, y), Palette.nail_color())
		# 输出漏极：∞ 红墨滑到右端后才与这段蓝线严格接触并发包。
		# NOT 生成时留一格空隙，避免默认导通位置被固化成同一个静态刚体。
		var output_x := 492 if spec.name == "NOT" else 465
		pixel(Rect2i(output_x, y - 6, 1110 - output_x, 12), Color.BLACK)
		wire(Vector2(output_x + 0.5, y + 0.5), Vector2(1095.5, y + 0.5), 3)
		var start_x := 300 if spec.name != "NOT" else 440
		mos_carriage(Vector2i(start_x, y), spec.arrows, spec.length, spec.width)
		if spec.name != "NOT":
			spring(Vector2(170.5, y + 0.5), Vector2(start_x - 49.5, y + 0.5), 7)
		rail_with_pin(Vector2(160.5, y + 0.5), Vector2(480.5, y + 0.5),
			Vector2(start_x + 0.5, y + 0.5), 11)
	# 输入真值源直接画成红色 ∞，靠近每条栅极母线；不是 UI 标记。
	for p in [Vector2i(242, 175), Vector2i(242, 205), Vector2i(242, 415),
		Vector2i(242, 445), Vector2i(382, 635)]:
		infinity_red(p)
	surface.refresh()
	canvas.generate(false)
	await process_frame
	await process_frame
	var infinite_sources := mark_red_bodies_as_infinite()
	# 固化完成后沿导轨推进 1 px，让 NOT 的独立红墨载体进入默认导通位置。
	for child in level.get_children():
		if child is SliderPin and absf(child.pin_world().y - (canvas.position.y + 650.5)) < 2.0:
			child.black_anchor.body.position += Vector2(1, 0)
	blue.force_per_length = 1.0e6
	blue.power_per_width = 3.0e9
	blue.source_power_per_pixel = 3.0e9
	level.get_node("SimulationRuntime/YellowInk").stiffness_per_width = 1200.0
	level.world.gravity = Vector2(0, 980)
	title("MOS 门电路：∞ 红墨是真值源；黄线是原生导轨；蓝箭头是栅极", Vector2(90, 35), 25)
	title("AND：两股较弱栅极力相加才移动载体", Vector2(90, 105), 19)
	title("OR：任一较强栅极力即可移动载体", Vector2(90, 350), 19)
	title("NOT：默认靠近漏极，输入箭头把 ∞ 红墨推离输出", Vector2(90, 570), 19)
	for y in [190, 430, 650]:
		title("OUT →", Vector2(1030, y - 42), 17)
	level.get_node("Camera2D").enabled = false
	var camera := Camera2D.new()
	camera.name = "MOSLogicCamera"
	camera.position = canvas.position + Vector2(750, 410)
	camera.zoom = Vector2.ONE * 0.72
	level.add_child(camera)
	camera.owner = level
	camera.make_current()
	level.get_node("Player").position = canvas.position + Vector2(1250, 700)
	canvas.position += Vector2(1800, 0)
	level.auto_step = true
	level.get_node("Creative").save_preview_on_export = false
	var error: Error = level.get_node("Creative").export_map_to(DESTINATION, false)
	var rails: Array = level.get_children().filter(func(node): return node is Rail)
	var pins: Array = level.get_children().filter(func(node): return node is SliderPin)
	print("MOS_LOGIC_MAP motors=", blue.objects(Motor).size(), " rails=", rails.size(),
		" pins=", pins.size(), " infinite_sources=", infinite_sources, " error=", error)
	quit(0 if error == OK and blue.objects(Motor).size() == 5 and rails.size() == 3 \
		and pins.size() == 3 and infinite_sources == 3 else 1)
