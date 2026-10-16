extends Node2D
## 两个验收机构全部由真实画布生成；没有隐藏约束或驱动马达。
const Palette := preload("res://ink/src/ink_palette.gd")
const Hinge := preload("res://ink/src/yellow/hinge.gd")
@export_enum("Seesaw", "Parallel four-bar") var mechanism: int = 0
var level
var canvas
var ready_for_test := false
var cranks: Array = []
var coupler = null

func _ready() -> void:
	level = load("res://map/asset/imported/main.tscn").instantiate()
	level.auto_step = false
	add_child(level)
	await get_tree().process_frame
	await get_tree().process_frame
	for child in level.get_children().duplicate():
		if child.get_script() == preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd"):
			level.remove_body_node(child)
			child.queue_free()
	canvas = level.get_node("SmallCanvas")
	canvas.position = Vector2.ZERO
	canvas.canvas_size = Vector2i(800, 600)
	canvas.surface.ink_free = true
	canvas.surface.brush_size = 11
	canvas.surface.selected_ink = 3
	canvas.surface.tool = canvas.surface.Tool.BRUSH
	level.get_node("MapCanvas").active = false
	level.get_node("Player").position = Vector2(-1000, -1000)
	level.get_node("Camera2D").set_process(false)
	level.get_node("Camera2D").set_physics_process(false)
	level.get_node("Camera2D").position = Vector2(400, 280)
	if mechanism == 0:
		paint(Rect2i(395, 260, 10, 100))
		canvas.surface.write_pixel(Vector2i(400, 340), Palette.nail_color())
		rod(Vector2(180.5, 260.5), Vector2(620.5, 260.5))
		axle(Vector2(400.5, 260.5))
	else:
		paint(Rect2i(180, 350, 280, 20))
		canvas.surface.write_pixel(Vector2i(310, 360), Palette.nail_color())
		paint(Rect2i(180, 170, 280, 20))
		rod(Vector2(190.5, 360.5), Vector2(190.5, 180.5))
		rod(Vector2(450.5, 360.5), Vector2(450.5, 180.5))
		axle(Vector2(190.5, 360.5))
		axle(Vector2(190.5, 180.5))
		axle(Vector2(450.5, 360.5))
		axle(Vector2(450.5, 180.5))
	canvas.generate(false)
	await get_tree().process_frame
	for body in level.world.bodies:
		for shape in body.shapes:
			if shape.get_pixel(190, 360) == Palette.YELLOW.id or (mechanism == 0 and shape.pixel_count() > 1000 and not body.is_static and shape.get_pixel(400, 260) == Palette.YELLOW.id):
				cranks.append(body)
			elif shape.get_pixel(450, 360) == Palette.YELLOW.id:
				cranks.append(body)
			if mechanism == 1 and not body.is_static and shape.get_pixel(300, 180) == Palette.BLACK.id:
				coupler = body
	level.world.gravity = Vector2(0, 980) if mechanism == 0 else Vector2.ZERO
	# 先让原生后端接收新生成的刚体和关节，再施加一次性物理冲量。
	level.world._substep_rapier(1.0 / 120.0)
	if mechanism == 0 and not cranks.is_empty():
		cranks[0].apply_torque_impulse(1.0 / cranks[0].inv_inertia)
	if coupler != null:
		coupler.apply_central_impulse(Vector2(240, 0) * coupler.mass)
	ready_for_test = true
	level.auto_step = not OS.get_cmdline_args().has("--headless")

func paint(rect: Rect2i) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			canvas.surface.write_pixel(Vector2i(x, y), Color.BLACK)
	canvas.surface.refresh()

func rod(a: Vector2, b: Vector2) -> void:
	canvas.surface.rod_layer.begin(a)
	canvas.surface.rod_layer.finish(b)

func axle(point: Vector2) -> void:
	canvas.surface.rod_layer.place_anchor(point)

func hinges() -> Array:
	var result: Array = []
	for child in level.get_children():
		if child is Hinge and not child.is_queued_for_deletion():
			result.append(child)
	return result
