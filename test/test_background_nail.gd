extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Nail := preload("res://actor/nail/src/nail.gd")
const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")

var failures := 0


func check(label: String, condition: bool) -> void:
	print("[BackgroundNail] ", "PASS " if condition else "FAIL ", label)
	if not condition:
		failures += 1


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var scene = load("res://map/asset/imported/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas = scene.get_node("SmallCanvas")
	canvas.global_position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(96, 64)
	var surface = canvas.surface
	surface.clear()
	for x in range(10, 31):
		surface.write_pixel(Vector2i(x, 20), Palette.BLACK.color)
	for x in range(55, 76):
		surface.write_pixel(Vector2i(x, 20), Palette.BLACK.color)
	surface.refresh()

	var health = surface._health_node()
	var grey_before: float = health.ink_of(Palette.GREY.id)
	var white_before: float = health.ink_of(Palette.WHITE.id)
	surface.tool = SurfaceScript.Tool.CIRCLE
	surface.selected_ink = 1
	check("gray circle selects fixed nail", surface._circle_nail_kind() == Nail.Kind.FIXED)
	check("fixed nail overlays existing pixel", surface._place_nail(Vector2(20.5, 20.5), Nail.Kind.FIXED)
		and surface.material_at(20, 20) == Palette.BLACK.id)
	surface.selected_ink = 4
	check("white circle selects background nail", surface._circle_nail_kind() == Nail.Kind.BACKGROUND)
	check("background nail overlays existing pixel", surface._place_nail(Vector2(65.5, 20.5), Nail.Kind.BACKGROUND)
		and surface.material_at(65, 20) == Palette.BLACK.id)
	check("each nail costs ten pixels", is_equal_approx(health.ink_of(Palette.GREY.id), grey_before - 10.0)
		and is_equal_approx(health.ink_of(Palette.WHITE.id), white_before - 10.0))
	check("nails cannot overlap", not surface._place_nail(Vector2(20.5, 20.5), Nail.Kind.BACKGROUND)
		and surface.nail_layer.kind_at(Vector2i(20, 20)) == Nail.Kind.FIXED)
	check("empty cells reject nails", not surface._place_nail(Vector2(40.5, 40.5), Nail.Kind.BACKGROUND))

	canvas.solid.solidify(surface, scene)
	var fixed_body = null
	var background_body = null
	for body in scene.world.bodies:
		if body.tags.has("static_anchor_points") and body.tags["static_anchor_points"].has(Vector2i(20, 20)):
			fixed_body = body
		if body.tags.has("background_anchor_points") and body.tags["background_anchor_points"].has(Vector2i(65, 20)):
			background_body = body
	check("fixed nail creates a static body", fixed_body != null and fixed_body.is_static)
	check("background nail stays dynamic and disables all contact", background_body != null
		and not background_body.is_static and background_body.collision_layer == 0
		and background_body.collision_mask == 0 and background_body.tags.has("no_impact_damage"))
	var runtime = scene.get_node("SimulationRuntime/PhysicsStep")
	runtime._update_background_anchors(background_body, {}, 1, 0xFFFFFFFF)
	check("losing the last background nail restores collision and damage", background_body.collision_layer == 1
		and background_body.collision_mask == 0xFFFFFFFF
		and not background_body.tags.has("background_anchor_points")
		and not background_body.tags.has("no_impact_damage"))
	for node in scene.get_children():
		if node.has_method("apply_nails") and node.get("body") == background_body:
			node.apply_nails(background_body, false)
			break

	canvas.return_to_canvas()
	check("inkify restores both overlay kinds", surface.nail_layer.nails.has(Vector2i(20, 20))
		and surface.nail_layer.background_nails.has(Vector2i(65, 20)))
	var white_paid: float = health.ink_of(Palette.WHITE.id)
	surface._begin_undo_step()
	surface._write_pixel(Vector2i(65, 20), Color.TRANSPARENT, 1 << 30)
	surface._commit_undo_step()
	surface._flush_ink()
	check("eraser removes the nail and underlying ink", surface.material_at(65, 20) == 0
		and surface.nail_layer.kind_at(Vector2i(65, 20)) < 0)
	check("deleting background nail refunds ten white pixels",
		is_equal_approx(health.ink_of(Palette.WHITE.id), white_paid + 10.0))
	check("undo restores background overlay", surface.undo_last_edit()
		and surface.nail_layer.background_nails.has(Vector2i(65, 20)))

	surface.clear()
	for x in range(10, 31):
		surface.rod_layer.pixels.set_pixel(x, 40, Palette.YELLOW.color)
	surface.rod_layer.refresh()
	check("background nail can be placed directly on yellow ink",
		surface._place_nail(Vector2(20.5, 40.5), Nail.Kind.BACKGROUND)
		and surface.material_at(20, 40) == 0)
	canvas.generate()
	var yellow_background = null
	for body in scene.world.bodies:
		if body.tags.get("background_anchor_points", {}).has(Vector2i(20, 40)):
			yellow_background = body
			break
	check("yellow carrier keeps its background nail after solidify", yellow_background != null
		and yellow_background.collision_layer == 0 and yellow_background.collision_mask == 0)

	scene.queue_free()
	await process_frame
	print("[BackgroundNail] failures=", failures)
	quit(1 if failures else 0)
