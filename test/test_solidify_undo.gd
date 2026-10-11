extends SceneTree

const Palette := preload("res://ink/src/ink_palette.gd")
var failures := 0

func check(label: String, condition: bool) -> void:
	print("[SolidifyUndo] ", label, ": ", "PASS" if condition else "FAIL")
	if not condition:
		failures += 1

func _initialize() -> void:
	call_deferred("run")

func run() -> void:
	var scene = load("res://map/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas = scene.get_node("SmallCanvas")
	canvas.global_position = Vector2(10000, -10000)
	var surface = canvas.surface
	surface.clear()
	var before: int = scene.world.bodies.size()
	for y in range(20, 40):
		for x in range(20, 40):
			surface.write_pixel(Vector2i(x, y), Color.BLACK)
	surface.write_pixel(Vector2i(30, 30), Palette.nail_color())
	surface.refresh()
	canvas.generate()
	check("creates entity", scene.world.bodies.size() == before + 1)
	check("undo restores blueprint and removes entity", surface.undo_last_edit() \
		and scene.world.bodies.size() == before and surface.material_at(20, 20) == Palette.BLACK.id)
	check("undo restores nail", surface.material_at(30, 30) == Palette.nail_material_id() \
		and surface.nail_layer.nails.has(Vector2i(30, 30)))
	canvas.generate()
	canvas.return_to_canvas()
	check("inkify preserves nail and visual", surface.material_at(30, 30) == Palette.nail_material_id() \
		and surface.nail_layer.nails.has(Vector2i(30, 30)))
	canvas.generate()
	var anchored := false
	for body in scene.world.bodies:
		if body.tags.has("static_anchor_points") and body.aabb.position.x > 9000:
			anchored = body.is_static
	check("preserved nail anchors next solidification", anchored)
	scene.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
