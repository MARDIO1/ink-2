extends SceneTree
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Hinge := preload("res://ink/yellow/src/hinge.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	call_deferred("run")

func check(label: String, passed: bool) -> void:
	checks += 1
	if not passed:
		failures += 1
	print("PASS " if passed else "FAIL ", label)

func run() -> void:
	for kind in ["seesaw", "four_bar"]:
		var demo = load("res://map/asset/yellow_%s.tscn" % kind).instantiate()
		root.add_child(demo)
		for timeout in 30:
			if demo.ready_for_test:
				break
			await process_frame
		check(kind + " fixture builds", demo.ready_for_test)
		if not demo.ready_for_test:
			demo.queue_free()
			continue
		var expected := 1 if kind == "seesaw" else 4
		check(kind + " creates only intended hinges", demo.hinges().size() == expected)
		check(kind + " creates intended yellow connected components", demo.cranks.size() == (1 if kind == "seesaw" else 2))
		var renderer = demo.level.renderer
		var shape = demo.cranks[0].shapes[0]
		var rect: Rect2i = shape.local_aabb()
		var native: Image = renderer._build_region_image_native([shape], rect, Rect2i(Vector2i.ZERO, rect.size))
		var reference: Image = renderer._build_region_image_gd([shape], rect, Rect2i(Vector2i.ZERO, rect.size))
		check("transparent yellow native renderer matches reference", native.get_data() == reference.get_data())
		var alpha_found := false
		for byte_index in range(3, native.get_data().size(), 4):
			var alpha: int = native.get_data()[byte_index]
			if alpha > 0:
				alpha_found = alpha == 191
				break
		check("yellow rendered pixels use exported opacity", alpha_found)
		var peak_angle := 0.0
		var max_error := 0.0
		var max_bearing_error := 0.0
		var coupler_rotation := 0.0
		var min_angle := INF
		var max_angle := -INF
		var runtime = demo.level.get_node("SimulationRuntime")
		if "--render" in OS.get_cmdline_user_args():
			await capture(demo, kind)
		for tick in 720:
			var result: Dictionary = runtime._step(1.0 / 120.0)
			if not result.removals.is_empty():
				var nodes: Array = demo.level._body_nodes.duplicate()
				runtime.commit(demo.level.world, result.removals, result.get("bursts", {}), true)
				runtime._physics.sync_after_commit(nodes)
			for rod in demo.cranks:
				peak_angle = maxf(peak_angle, absf(rod.rotation))
				min_angle = minf(min_angle, rod.rotation)
				max_angle = maxf(max_angle, rod.rotation)
			for hinge in demo.hinges():
				if hinge.joint != null:
					max_error = maxf(max_error, hinge.joint.anchor_error().length())
					hinge._process(0.0)
					var midpoint: Vector2 = (hinge.yellow_position + hinge.black_position) * 0.5
					max_bearing_error = maxf(max_bearing_error, hinge.global_position.distance_to(demo.level.to_global(midpoint)))
			if demo.coupler != null:
				coupler_rotation = maxf(coupler_rotation, absf(demo.coupler.rotation))
		check(kind + " moves around its hinges after one physical impulse", peak_angle > 0.15)
		check(kind + " keeps axle drift below 2px", max_error < 2.0)
		check(kind + " bearing follows the true axle within 1px", max_bearing_error < 1.0)
		for hinge in demo.hinges():
			check(kind + " bearing does not inherit body rotation or scale", absf(hinge.global_rotation) < 0.001 and hinge.global_scale.distance_to(Vector2.ONE) < 0.001)
		for hinge in demo.hinges():
			check(kind + " disables only joined body pair contacts", hinge.joint != null and not hinge.joint.contacts_enabled and hinge.yellow_anchor.body.collision_mask == 0xFFFFFFFF)
		if kind == "four_bar":
			check("four-bar coupler stays parallel", coupler_rotation < 0.05)
			check("four-bar rotates through at least 60 degrees with normal collision", max_angle - min_angle > PI / 3.0)
		print("METRIC ", kind, " peak_angle=", peak_angle, " span=", max_angle - min_angle, " axle_error_px=", max_error, " coupler_angle=", coupler_rotation)
		if "--render" in OS.get_cmdline_user_args():
			await capture(demo, kind + "_moved")
		await check_editing(demo)
		await check_persistence_and_breakage(demo, expected)
		await check_rod_collision(demo)
		demo.queue_free()
		await process_frame
	print("[YellowMechanisms] ", checks, " checks, ", failures, " failures")
	quit(1 if failures else 0)

func check_editing(demo) -> void:
	var surface = demo.canvas.surface
	var layer = surface.rod_layer
	var was_free: bool = surface.ink_free
	surface.ink_free = false
	var health = surface._health_node()
	var before: float = health.ink_of(Palette.YELLOW.id)
	var count_before: int = demo.level.world.bodies.size()
	surface.write_pixel(Vector2i(50, 50), Color.BLACK)
	layer.begin(Vector2(50.5, 50.5))
	layer.finish(Vector2(100.5, 50.5))
	var count: int = layer.make_shape().pixel_count()
	check("yellow brush never creates an axle automatically", layer.anchor_points.is_empty())
	check("invalid axle click is ignored", not layer.place_anchor(Vector2(100.5, 50.5)) and layer.anchor_points.is_empty())
	check("circle axle click records a shared black-yellow centre", layer.place_anchor(Vector2(50.5, 50.5)) and layer.anchor_points.size() == 1)
	check("duplicate axle click keeps only one", not layer.place_anchor(Vector2(50.5, 50.5)) and layer.anchor_points.size() == 1)
	var pixels_before_axle_erase: int = layer.make_shape().pixel_count()
	check("yellow eraser removes bearing without erasing rod pixels", layer.erase_anchor(Vector2(50.5, 50.5))
		and layer.anchor_points.is_empty() and layer.make_shape().pixel_count() == pixels_before_axle_erase)
	check("axle erase undo restores only the bearing", surface.undo_last_edit()
		and layer.anchor_points.size() == 1 and layer.make_shape().pixel_count() == pixels_before_axle_erase)
	layer.erase_anchor(Vector2(50.5, 50.5))
	surface.write_pixel(Vector2i(50, 50), Color.TRANSPARENT)
	surface.refresh()
	check("normal rod paint charges its real unique area", health.ink_of(Palette.YELLOW.id) == before - count)
	layer.begin(Vector2(80.5, 50.5))
	layer.finish(Vector2(150.5, 50.5))
	check("overlapping rod paint charges unique pixels", layer.make_shape().pixel_count() < count * 2 + 300)
	check("yellow layer does not overwrite black blueprint", surface.material_at(80, 50) == 0)
	check("yellow brush undo restores previous pixels", surface.undo_last_edit() and layer.make_shape().pixel_count() == count)
	check("normal rod undo refunds only the added pixels", health.ink_of(Palette.YELLOW.id) == before - count)
	demo.canvas.generate()
	check("unanchored rod becomes an ordinary body", demo.level.world.bodies.size() == count_before + 1)
	check("solidify undo restores yellow layer", surface.undo_last_edit() and layer.make_shape().pixel_count() == count and demo.level.world.bodies.size() == count_before)
	layer.begin(Vector2(80.5, 50.5), true)
	layer.finish(Vector2(80.5, 50.5))
	check("yellow eraser removes only yellow pixels", layer.make_shape().pixel_count() < count and surface.material_at(80, 50) == 0)
	surface.undo_last_edit()
	var path := "user://yellow_layer_test.snapshot"
	check("layered snapshot saves", surface.save_ink(path) == OK)
	layer.clear()
	check("layered snapshot restores rods", surface.load_ink(path) == OK and layer.make_shape().pixel_count() == count)
	check("normal layered reload does not duplicate ink", health.ink_of(Palette.YELLOW.id) == before - count)
	surface.ink_free = was_free
	await process_frame

func check_persistence_and_breakage(demo, expected: int) -> void:
	for hinge in demo.hinges():
		hinge._process(0.0)
	demo.canvas.solid.sync_serializable_bodies(demo.level)
	var packed := PackedScene.new()
	check("active mechanisms pack into scene", packed.pack(demo.level) == OK)
	var restored = packed.instantiate()
	restored.auto_step = false
	root.add_child(restored)
	await process_frame
	await process_frame
	var count := 0
	for child in restored.get_children():
		if child is Hinge and not child.is_queued_for_deletion() and child.joint != null:
			count += 1
	check("scene reload restores all true axles", count == expected)
	restored.queue_free()
	await process_frame
	var hinges: Array = demo.hinges()
	if hinges.is_empty():
		return
	var hinge = hinges[0]
	var body = hinge.yellow_anchor.body
	var cell: Vector2i = hinge.yellow_anchor.cell
	var mask := {}
	for shape in body.shapes:
		if shape.get_pixel(cell.x, cell.y) != 0:
			mask[shape] = {cell: true}
	demo.level.get_node("SimulationRuntime/PhysicsStep").commit(demo.level.world, {body: mask})
	check("destroying yellow axle pixel removes joint and bearing immediately", hinge.is_queued_for_deletion() and hinge.joint == null)
	check("breaking one axle preserves others", demo.hinges().size() == expected - 1)
	var survivors: Array = demo.hinges()
	if not survivors.is_empty():
		var other = survivors[0]
		var black = other.black_anchor.body
		var black_cell: Vector2i = other.black_anchor.cell
		var black_mask := {}
		for shape in black.shapes:
			if shape.get_pixel(black_cell.x, black_cell.y) == Palette.BLACK.id:
				black_mask[shape] = {black_cell: true}
		demo.level.get_node("SimulationRuntime/PhysicsStep").commit(demo.level.world, {black: black_mask})
		check("destroying black axle pixel also removes its joint and bearing", other.is_queued_for_deletion() and other.joint == null)

func capture(demo, name: String) -> void:
	demo.level.auto_step = false
	demo.level.sync_body_nodes()
	demo.level.sync_world_bodies()
	for hinge in demo.hinges():
		hinge._process(0.0)
	await process_frame
	await RenderingServer.frame_post_draw
	var path := "user://yellow_%s_acceptance.png" % name
	check("windowed render capture " + name, root.get_texture().get_image().save_png(path) == OK)
	print("RENDER ", ProjectSettings.globalize_path(path))

func check_rod_collision(demo) -> void:
	var surface = demo.canvas.surface
	surface.rod_layer.clear(false)
	demo.rod(Vector2(600.5, 50.5), Vector2(720.5, 50.5))
	demo.rod(Vector2(600.5, 100.5), Vector2(720.5, 100.5))
	demo.canvas.generate(false)
	await process_frame
	var bodies: Array = []
	for body in demo.level.world.bodies:
		for shape in body.shapes:
			if shape.get_pixel(650, 50) == Palette.YELLOW.id or shape.get_pixel(650, 100) == Palette.YELLOW.id:
				bodies.append(body)
	check("separate yellow islands generate two colliding bodies", bodies.size() == 2)
	if bodies.size() != 2:
		return
	demo.level.world.gravity = Vector2.ZERO
	bodies[0].linear_velocity = Vector2(0, 150)
	bodies[1].linear_velocity = Vector2(0, -150)
	var contact_seen := false
	for tick in 60:
		demo.level.world._substep_rapier(1.0 / 120.0)
		for index in demo.level.world.contact_pair_count():
			var contact: Dictionary = demo.level.world.contact_info(index)
			if [contact.id_a, contact.id_b].has(bodies[0].rapier_id) and [contact.id_a, contact.id_b].has(bodies[1].rapier_id):
				contact_seen = true
	check("yellow rods physically collide instead of passing through", contact_seen and absf(bodies[0].linear_velocity.y) < 60 and absf(bodies[1].linear_velocity.y) < 60)
