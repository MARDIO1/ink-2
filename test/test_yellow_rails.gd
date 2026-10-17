extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Rail := preload("res://ink/yellow/src/rail.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const PJoint := preload("res://addons/pixel_destruction/physics/joint.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	call_deferred("run")

func check(label: String, passed: bool) -> void:
	checks += 1
	if not passed:
		failures += 1
	print("PASS " if passed else "FAIL ", label)

func paint(surface, rect: Rect2i) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			surface.write_pixel(Vector2i(x, y), Color.BLACK)
	surface.refresh()

func run() -> void:
	var scene = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	var canvas = scene.get_node("SmallCanvas")
	var surface = canvas.surface
	canvas.position = Vector2.ZERO
	canvas.canvas_size = Vector2i(420, 260)
	surface.ink_free = true
	surface.selected_ink = 3
	surface.brush_size = 13
	paint(surface, Rect2i(175, 105, 30, 30))
	surface.rod_layer.begin_rail(Vector2(60.5, 120.5))
	check("rectangle drag creates physical rail", surface.rod_layer.finish_rail(Vector2(340.5, 120.5)))
	check("rail records one fixed centerline", surface.rod_layer.rails.size() == 1)
	check("rail centerline uses actual yellow pixels", surface.rod_layer.pixels.get_pixel(200, 120).a > 0.0)
	check("rectangle click installs black slider pin", surface.rod_layer.place_slider_pin(Vector2(190.5, 120.5)))
	check("slider pin snaps to the rail centerline", absf(Vector2(surface.rod_layer.slider_pins[0].position).y - 120.5) < 0.01)
	check("slider pin edit can be undone", surface.undo_last_edit() and surface.rod_layer.slider_pins.is_empty())
	check("slider pin can be installed again after undo", surface.rod_layer.place_slider_pin(Vector2(190.5, 120.5)))
	var snapshot := "user://yellow_rail_test.snapshot"
	check("rail edit snapshot saves", surface.save_ink(snapshot) == OK)
	surface.rod_layer.clear(false)
	check("rail edit snapshot loads", surface.load_ink(snapshot) == OK)
	check("snapshot restores rail and slider metadata", surface.rod_layer.rails.size() == 1 and surface.rod_layer.slider_pins.size() == 1)
	canvas.generate()
	await process_frame
	await process_frame
	check("solidification transaction can be undone", surface.undo_last_edit())
	await process_frame
	check("solidification undo restores rail editing data", surface.rod_layer.rails.size() == 1 and surface.rod_layer.slider_pins.size() == 1)
	canvas.generate(false)
	var pending_pin = null
	for child in scene.get_children():
		if child is SliderPin and not child.is_queued_for_deletion():
			pending_pin = child
			break
	check("unbound top-level pin stays hidden instead of flashing at origin",
		pending_pin != null and not pending_pin.visible)
	await process_frame
	await process_frame
	var rails: Array = []
	var pins: Array = []
	for child in scene.get_children():
		if child is Rail and not child.is_queued_for_deletion():
			rails.append(child)
		elif child is SliderPin and not child.is_queued_for_deletion():
			pins.append(child)
	check("solidification preserves one rail device", rails.size() == 1)
	check("solidification preserves one slider pin", pins.size() == 1)
	if rails.size() == 1 and pins.size() == 1:
		var rail = rails[0]
		var pin = pins[0]
		check("bound slider pin becomes visible at its physical anchor", pin.visible \
			and pin.global_position.distance_to(scene.to_global(pin.pin_world())) < 0.1)
		pin.try_attach()
		check("pin creates the native slider constraint", pin.joint != null and pin.joint.kind == PJoint.SLIDER)
		check("slider has no hidden end limits", pin.joint != null and not pin.joint.limits_enabled)
		check("only the connected rail-slider pair disables contacts", pin.joint != null and not pin.joint.contacts_enabled)
		scene.world.gravity = Vector2.ZERO
		scene.world._substep_rapier(1.0 / 120.0)
		pin.black_anchor.body.apply_central_impulse(rail.axis_world() * 240.0 * pin.black_anchor.body.mass)
		for step in 60:
			scene.world._substep_rapier(1.0 / 120.0)
		check("slider permits real axial travel", absf(pin.joint.movement()) > 5.0)
		check("slider locks perpendicular drift", pin.joint.lateral_error().length() < 2.0)
		check("slider locks relative rotation", absf(pin.joint.angle_error()) < 0.1)
		rail._process(0.0)
		pin._process(0.0)
		canvas.solid.sync_serializable_bodies(scene)
		var packed := PackedScene.new()
		check("active rail mechanism packs into a scene", packed.pack(scene) == OK)
		var restored = packed.instantiate()
		restored.auto_step = false
		root.add_child(restored)
		await process_frame
		await process_frame
		var restored_joint := false
		for child in restored.get_children():
			if child is SliderPin and child.joint != null:
				restored_joint = true
				break
		check("scene reload restores the moved rail and slider", restored_joint)
		restored.queue_free()
		await process_frame
		pin.black_anchor.body.position += rail.axis_world() * 400.0
		scene.get_node("SimulationRuntime/YellowInk").resolve_fixed(
			scene.get_node("SimulationRuntime")._context())
		check("fixed physics rule releases a pin beyond the open endpoint", pin.joint == null and pin.rail == null)
		var endpoints: PackedVector2Array = rail.endpoints_world()
		var middle: Vector2 = (endpoints[0] + endpoints[1]) * 0.5
		var normal: Vector2 = rail.axis_world().orthogonal()
		pin.black_anchor.body.position += middle + normal * 100.0 - pin.pin_world()
		pin.previous_position = pin.pin_world()
		pin.black_anchor.body.position += normal * -200.0
		pin._process(0.0)
		check("high-speed crossing can reconnect an installed pin", pin.joint != null and pin.rail == rail)
		var projected: Vector2 = rail.closest(pin.pin_world()).point
		var rail_cell := Vector2i(rail.body.to_local(projected).floor())
		var damaged_shape = null
		for shape in rail.body.shapes:
			if shape.get_pixel(rail_cell.x, rail_cell.y) == Palette.YELLOW.id:
				damaged_shape = shape
				break
		var plan := {damaged_shape: {rail_cell: true}}
		var result: Dictionary = scene.fracture_pixels_and_sync(rail.body, plan, 0.0, false)
		var pieces: Array = result.fragments.duplicate()
		if result.body_alive:
			pieces.append(rail.body)
		scene.get_node("SimulationRuntime/PhysicsStep").body_fractured.emit(scene.world, rail.body, pieces)
		await process_frame
		await process_frame
		check("missing centerline cell releases only the slider constraint", is_instance_valid(pin) and not pin.is_queued_for_deletion() and pin.joint == null)
		var black_body = pin.black_anchor.body
		var black_cell: Vector2i = pin.black_anchor.cell
		var black_shape = null
		for shape in black_body.shapes:
			if shape.get_pixel(black_cell.x, black_cell.y) == Palette.BLACK.id:
				black_shape = shape
				break
		var black_result: Dictionary = scene.fracture_pixels_and_sync(
			black_body, {black_shape: {black_cell: true}}, 0.0, false)
		var black_pieces: Array = black_result.fragments.duplicate()
		if black_result.body_alive:
			black_pieces.append(black_body)
		scene.get_node("SimulationRuntime/PhysicsStep").body_fractured.emit(scene.world, black_body, black_pieces)
		check("destroyed pin hides before deferred deletion", not pin.visible)
		await process_frame
		await process_frame
		check("destroying the black source pixel permanently removes the pin", not is_instance_valid(pin))
	scene.queue_free()
	await process_frame
	print("[YellowRails] %d checks, %d failures" % [checks, failures])
	quit(1 if failures > 0 else 0)

