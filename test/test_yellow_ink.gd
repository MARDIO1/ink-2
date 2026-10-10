extends SceneTree

const Palette = preload("res://Ink/src/ink_palette.gd")
const Stroke = preload("res://actor/yellow/src/yellow_stroke.gd")
const Shape = preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const PWorld = preload("res://addons/pixel_destruction/physics/pworld.gd")
var failures: int = 0
var checks: int = 0
var scene
var canvas
var surface
var rule
var health

func _initialize() -> void:
	call_deferred("run")

func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])

func draw(a: Vector2, b: Vector2, via: Array = []) -> bool:
	rule.begin(surface, a)
	for p: Vector2 in via:
		rule.extend(surface, p)
	return rule.finish(surface, b)

func paint(rect: Rect2i) -> void:
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			surface.write_pixel(Vector2i(x, y), Color.BLACK)
	surface.refresh()

func run() -> void:
	scene = load("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	canvas = scene.get_node("SmallCanvas")
	surface = canvas.surface
	rule = scene.get_node("SimulationRuntime/YellowInk")
	health = scene.get_node("Player/InkHealth")
	canvas.position = Vector2(5000, 5000)
	canvas.canvas_size = Vector2i(400, 280)
	paint(Rect2i(20, 20, 20, 20))
	paint(Rect2i(120, 20, 20, 20))
	var before: float = health.ink_of(Palette.YELLOW.id)
	check("invalid endpoint costs no ink", not draw(Vector2(30, 30), Vector2(90, 90))
		and health.ink_of(Palette.YELLOW.id) == before)
	check("valid black endpoints submit independently", draw(Vector2(30, 30), Vector2(130, 30)))
	var first = rule.strokes[-1]
	var area: int = first.original_area
	check("area charges only path, terminals excluded", health.ink_of(Palette.YELLOW.id) == before - area)
	check("yellow leaves underlying black unchanged", surface.material_at(30, 30) == Palette.BLACK.id
		and surface.material_at(70, 30) == 0)
	check("identical endpoints can make parallel spring", draw(Vector2(30, 30), Vector2(130, 30)))
	var second = rule.strokes[-1]
	check("parallel strokes each own their area", second.original_area == area and
		health.ink_of(Palette.YELLOW.id) == before - 2 * area)
	check("yellow stroke undo refunds precisely", surface.undo_last_edit()
		and rule.strokes.size() == 1 and health.ink_of(Palette.YELLOW.id) == before - area)
	check("yellow cannot anchor to another yellow", not draw(Vector2(70, 30), Vector2(130, 30)))
	canvas.generate()
	check("solidification creates one native spring and no yellow body", first.joint != null
		and first.joint.contacts_enabled and first.rest_length == 100.0)
	var a = first.anchors[0].body
	var b = first.anchors[1].body
	check("only black carries physical mass", a != b and a.shapes[0].pixel_count() == 400 and b.shapes[0].pixel_count() == 400)
	a.is_static = true
	scene.world.gravity = Vector2.ZERO
	var origin: Vector2 = b.position
	b.position.x += 20.0
	var initial_load: float = rule.spring_load(first)
	var peak_load: float = 0.0
	var peak_speed: float = 0.0
	for tick in 300:
		scene.world._substep_rapier(1.0 / 60.0)
		peak_load = maxf(peak_load, rule.spring_load(first))
		peak_speed = maxf(peak_speed, b.linear_velocity.length())
	var length_error: float = absf(Stroke.anchor_world(first.anchors[0]).distance_to(Stroke.anchor_world(first.anchors[1])) - first.rest_length)
	check("native spring restores stretched anchors without divergence", length_error < 0.1
		and is_finite(peak_speed) and peak_speed < 2000.0)
	check("spring model includes elastic load for wear", initial_load > 1000.0)
	b.position = origin - Vector2(10, 0)
	b.linear_velocity = Vector2.ZERO
	b.rotation = 0.0
	b.angular_velocity = 0.0
	b.awake = true
	b.sleep_timer = 0.0
	b.refresh_com()
	b.update_aabb()
	scene.world._substep_rapier(1.0 / 60.0)
	check("compressed spring pushes outward", b.linear_velocity.x > 0.0)
	print("SPRING peak_load=", peak_load, " peak_speed=", peak_speed, " length_error=", length_error)
	b.position = origin
	b.linear_velocity = Vector2.ZERO
	b.rotation = 0.0
	b.angular_velocity = 0.0
	b.refresh_com()
	b.update_aabb()
	first.update_visual()
	var refund_before: float = health.ink_of(Palette.YELLOW.id)
	first.rng.seed = 42
	first.erode(20)
	check("wear changes area without changing endpoint sprites", first.cells.size() < area
		and first.endpoint_a.texture != null and first.endpoint_b.texture != null)
	var remaining: int = first.cells.size()
	canvas.return_to_canvas()
	check("reclaim returns remaining yellow directly to bottle", health.ink_of(Palette.YELLOW.id) == refund_before + remaining
		and rule.strokes.is_empty() and first.joint == null)
	check("reclaim never writes yellow into blueprint", surface.material_at(70, 30) == 0)
	await process_frame
	surface.clear()
	paint(Rect2i(20, 80, 120, 20))
	check("same-body endpoints accepted", draw(Vector2(30, 90), Vector2(130, 90)))
	canvas.generate()
	var sleeping = rule.strokes[-1]
	check("same-body stroke stays dormant", sleeping.joint == null
		and sleeping.anchors[0].body == sleeping.anchors[1].body)
	var parent_body = sleeping.anchors[0].body
	var mask: Dictionary = {}
	for shape in parent_body.shapes:
		var removed: Dictionary = {}
		for y in range(80, 100):
			for x in range(75, 80):
				removed[Vector2i(x, y)] = true
		mask[shape] = removed
	var step = scene.get_node("SimulationRuntime/PhysicsStep")
	step.commit(scene.world, {parent_body: mask})
	check("fracture rebinds exact surviving pixels and activates spring", sleeping.state == Stroke.State.ACTIVE
		and sleeping.anchors[0].body != sleeping.anchors[1].body and sleeping.joint != null)
	var target = sleeping.anchors[1]
	var deletion: Dictionary = {}
	for shape in target.body.shapes:
		if shape.get_pixel(target.cell.x, target.cell.y) != 0:
			deletion[shape] = {target.cell: true}
	step.commit(scene.world, {target.body: deletion})
	check("destroyed black anchor immediately releases constraint", sleeping.state == Stroke.State.DYING
		and sleeping.joint == null)
	_test_erosion()
	_test_parallel()
	await _test_serialization()
	if "--render" in OS.get_cmdline_user_args():
		await _render_sample()
	print("[YellowInk] %d checks, %d failures" % [checks, failures])
	scene.queue_free()
	await process_frame
	quit(1 if failures else 0)

func _test_erosion() -> void:
	var stroke = Stroke.new()
	stroke.path = PackedVector2Array([Vector2(0.5, 0.5), Vector2(300.5, 0.5)])
	stroke.brush_width = 11
	scene.add_child(stroke)
	stroke.state = Stroke.State.ACTIVE
	stroke.rng.seed = 123
	var start: int = Time.get_ticks_usec()
	var iterations: int = 0
	while stroke.state == Stroke.State.ACTIVE and iterations < 100:
		stroke.erode(20)
		iterations += 1
	var elapsed: int = Time.get_ticks_usec() - start
	check("growing random damage eventually cuts across path", stroke.state == Stroke.State.DYING)
	check("damage retains refundable pixels after cut", not stroke.cells.is_empty())
	print("WEAR area=", stroke.original_area, " batches=", iterations, " total_us=", elapsed,
		" avg_batch_us=", elapsed / maxi(1, iterations))
	stroke.queue_free()
	var large = Stroke.new()
	large.preview = true
	large.path = PackedVector2Array([Vector2(-1000.5, -10.5), Vector2(1000.5, -10.5)])
	large.brush_width = 25
	scene.add_child(large)
	check("large negative-coordinate stroke builds connected native occupancy", large.build_pixels() and large.connected())
	large.state = Stroke.State.ACTIVE
	large.rng.seed = 456
	start = Time.get_ticks_usec()
	large.erode(256)
	elapsed = Time.get_ticks_usec() - start
	check("large wear batch deletes exactly its budget", large.cells.size() == large.original_area - 256)
	print("LARGE_WEAR area=", large.original_area, " batch_us=", elapsed)
	large.queue_free()

func _test_serialization() -> void:
	paint(Rect2i(20, 180, 30, 30))
	paint(Rect2i(180, 180, 30, 30))
	check("export fixture draws a valid spring", draw(Vector2(35, 195), Vector2(195, 195)))
	canvas.generate()
	var active = rule.strokes[-1]
	active.update_visual()
	var packed = PackedScene.new()
	check("yellow export keeps ordered source data", packed.pack(scene) == OK)
	var restored = packed.instantiate()
	var found: bool = false
	for child in restored.get_children():
		if child is Stroke and child.activated:
			found = child.path == active.path and child.rest_length == 160.0
	check("packed scene roundtrip preserves yellow source and rest length", found)
	root.add_child(restored)
	await process_frame
	await process_frame
	var loaded_rule = restored.get_node("SimulationRuntime/YellowInk")
	check("reloaded scene resolves black anchors and recreates spring once", loaded_rule.strokes.size() == 1
		and loaded_rule.strokes[0].joint != null and loaded_rule.strokes[0].joint.is_active())
	restored.queue_free()
	await process_frame

func _test_parallel() -> void:
	for count in [1, 10, 100]:
		var world = PWorld.new()
		world.gravity = Vector2.ZERO
		world.rp_angular_damping = 0.0
		var a = PBody.new()
		a.is_static = true
		var shape_a = Shape.new()
		shape_a.fill_rect(Rect2i(0, 0, 12, 12), Palette.BLACK.id)
		world.add_body(a, [shape_a])
		var b = PBody.new()
		b.position = Vector2(100, 0)
		var shape_b = Shape.new()
		shape_b.fill_rect(Rect2i(0, 0, 12, 12), Palette.BLACK.id)
		world.add_body(b, [shape_b])
		var items: Array = []
		for i in count:
			var stroke = Stroke.new()
			stroke.path = PackedVector2Array([Vector2(6, 6), Vector2(106, 6)])
			stroke.rest_length = 100.0
			stroke.anchors = [Stroke.find_anchor(world, Vector2(6, 6)), Stroke.find_anchor(world, Vector2(106, 6))]
			rule.connect_stroke(stroke, world)
			items.append(stroke)
		b.position.x += 10.0
		var initial_energy: float = count * rule.stiffness_per_width * 7 * 100.0 * 0.5
		var peak_energy: float = 0.0
		var start: int = Time.get_ticks_usec()
		for tick in 300:
			world._substep_rapier(1.0 / 60.0)
			var error: float = b.to_world(Vector2(6, 6)).distance_to(a.to_world(Vector2(6, 6))) - 100.0
			peak_energy = maxf(peak_energy, b.kinetic_energy() + count * rule.stiffness_per_width * 7 * error * error * 0.5)
		var elapsed: int = Time.get_ticks_usec() - start
		check("%d parallel springs remain finite and dissipate energy" % count,
			is_finite(peak_energy) and peak_energy <= initial_energy * 1.03 and absf(b.position.x - 100.0) < 0.1)
		b.angular_velocity = 2.0
		b.awake = true
		b.sleep_timer = 0.0
		world._substep_rapier(1.0 / 60.0)
		check("%d center-anchored springs preserve free rotation" % count, absf(b.angular_velocity - 2.0) < 0.01)
		print("PARALLEL count=", count, " avg_substep_us=", elapsed / 300,
			" energy_ratio=", peak_energy / initial_energy, " spin=", b.angular_velocity)
		for item in items:
			item.remove_joint()
			item.free()
		for body in world.bodies.duplicate():
			world.remove_body(body)
			for shape in body.shapes:
				shape.owner_body = null
			body.shapes.clear()
		world._rp = null

func _render_sample() -> void:
	surface.clear()
	paint(Rect2i(20, 130, 30, 30))
	paint(Rect2i(180, 130, 30, 30))
	check("curved stroke submits for render", draw(Vector2(35, 145), Vector2(195, 145), [Vector2(70, 80), Vector2(150, 80)]))
	canvas.generate()
	var stroke = rule.strokes[-1]
	stroke.rng.seed = 42
	stroke.erode(4)
	check("crossing stroke submits for overlap render", draw(Vector2(35, 145), Vector2(195, 145)))
	canvas.generate()
	var camera = scene.get_node("Camera2D")
	camera.set_script(null)
	camera.position = Vector2(5130, 5110)
	camera.zoom = Vector2(3, 3)
	scene.get_node("Player").body.position = Vector2(5100, 5140)
	rule.resolve_fixed({"world": scene.world, "player_body": scene.get_node("Player").body})
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	var output: String = OS.get_environment("TEMP").path_join("yellow-render.png")
	check("render capture written", root.get_texture().get_image().save_png(output) == OK)
	print("RENDER ", output)
