extends SceneTree
## Tab/F2 交接、相反推力分别可见、弹力模型，以及灰底摩擦的真实物理复现。
const Main := preload("res://map/asset/imported/main.tscn")
const Motor := preload("res://ink/blue/src/motor.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
const PWorld := preload("res://addons/pixel_destruction/physics/pworld.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(label: String, ok: bool) -> void:
	print("PASS " if ok else "FAIL ", label)
	if not ok:
		failures += 1

func run() -> void:
	var level = Main.instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	await process_frame
	var game_ui = load("res://ui/game_ui.tscn").instantiate()
	level.add_child(game_ui)
	await process_frame
	var ui = game_ui.get_node("Hud")
	var hud = level.get_node("debugHUD")
	var forces = hud.forces
	var creative = level.get_node("Creative")
	ui._switch_debug_hud()
	check("Tab enables force view", hud.visible and forces.enabled and not ui.visible)
	# 走真实模式切换，禁止复载/自动保存，测试不得覆盖用户地图。
	creative._skip_restore_on_enter = true
	creative.auto_save_on_exit = false
	creative.edit_snapshot_path = ""
	creative.set_active(true)
	check("F2 suspends force view", not hud.visible and not forces.enabled and ui.visible)
	var event := InputEventKey.new()
	event.keycode = KEY_TAB
	event.pressed = true
	ui._input(event)
	check("Tab in editor preserves debug preference and stays hidden", ui._debug_requested and not hud.visible)
	creative.set_active(false)
	check("leaving F2 restores chosen force view", hud.visible and forces.enabled and not ui.visible)
	game_ui.reparent(root)
	level.queue_free()
	await process_frame
	level = Main.instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	await process_frame
	hud = level.get_node("debugHUD")
	forces = hud.forces
	check("persistent GameUI rebinds after level reload", ui.debug_hud == hud and hud.visible and forces.enabled)
	var body = level.get_node("Box").body
	var other = level.get_node("Ground").body
	for direction in [Vector2.RIGHT, Vector2.LEFT]:
		var motor := Motor.new()
		level.add_child(motor)
		motor.body = body
		motor.active = true
		motor.position = body.com_world()
		motor.tip = direction * 50.0
		motor.received_power = 1e8
		motor.drive(1e8, 1.0 / 60.0, 1e5, 1e7)
	var yellow = level.get_node("SimulationRuntime/YellowInk")
	var spring := Stroke.new()
	level.add_child(spring)
	spring.anchors = [{"body": body, "local": Vector2.ZERO}, {"body": other, "local": Vector2.ZERO}]
	spring.rest_length = body.position.distance_to(other.position) * 0.5
	spring.joint = level.world.add_spring(body, other, body.position, other.position, spring.rest_length, 1000.0, 0.0)
	yellow.strokes.append(spring)
	forces._physics_process(1.0 / 60.0)
	forces.sample_rule_forces(1.0 / 60.0)
	var blue: Array = forces.arrows.filter(func(a): return a.color == 8)
	var gold: Array = forces.arrows.filter(func(a): return a.color == 9)
	check("opposed arrows remain two independent force vectors", blue.size() == 2 and blue[0].force.dot(blue[1].force) < 0.0)
	check("blue vectors include delivered power", blue[0].power > 0.0 and blue[1].power > 0.0)
	check("spring shows equal opposite model forces", gold.size() == 2 and gold[0].force.length() > 0.0 and (gold[0].force + gold[1].force).length() < 0.001)
	var wire := Wire.new()
	level.add_child(wire)
	wire.show_energy_points(PackedVector2Array([Vector2.ZERO]), PackedVector2Array(), PackedFloat32Array([1.0]), 1000.0)
	check("dim energy retains visible highlight and wider core", wire.energy_colors[0].a >= 0.3 and wire.highlight_core_width >= 2.0)
	# 此处记录当前底层限制，不把材质 friction=0 当作灰底已无摩擦的证明。
	var world := PWorld.new()
	world.set_material_friction(Palette.BLACK.id, 0.5)
	world.set_material_friction(Palette.GREY.id, 0.0)
	world.gravity = Vector2(0, 600)
	var shape := Shape.new()
	shape.fill_rect(Rect2i(0, 0, 100, 18), Palette.BLACK.id)
	shape.fill_rect(Rect2i(0, 18, 100, 2), Palette.GREY.id)
	var sled := PBody.new()
	world.add_body(sled, [shape])
	var floor_shape := Shape.new()
	floor_shape.fill_rect(Rect2i(-200, 20, 500, 10), Palette.BLACK.id)
	var floor_body := PBody.new()
	floor_body.is_static = true
	world.add_body(floor_body, [floor_shape])
	for frame in 60:
		world.step(1.0 / 60.0)
	sled.linear_velocity = Vector2(10, 0)
	for frame in 60:
		world.step(1.0 / 60.0)
	print("GREY_SLED mixed_body_friction=", sled.friction, " floor_friction=", floor_body.friction, " speed_after_1s=", sled.linear_velocity.x)
	check("reproduces current gray-bottom body friction averaging", sled.friction > 0.4 and absf(sled.linear_velocity.x) < 1.0)
	for item in world.bodies.duplicate():
		world.remove_body(item)
	level.queue_free()
	game_ui.queue_free()
	await process_frame
	print("FORCE_VIEW failures=", failures)
	quit(1 if failures else 0)
