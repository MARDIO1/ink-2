extends SceneTree
const Palette = preload("res://ink/general/src/ink_palette.gd")
const Stroke = preload("res://ink/yellow/src/stroke.gd")
var failures := 0
var checks := 0

func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[SolidSpring] %s %s" % ["PASS" if okay else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	current_scene = level
	await process_frame
	var canvas = level.get_node("SmallCanvas")
	canvas.position = Vector2(5000, -5000)
	canvas.canvas_size = Vector2i(320, 200)
	canvas.set_map_editor_mode(true)
	var surface = canvas.surface
	surface.ink_free = true
	for origin in [Vector2i(20, 20), Vector2i(120, 20)]:
		for y in range(origin.y, origin.y + 20):
			for x in range(origin.x, origin.x + 20):
				surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	canvas.generate(false)
	var rule = surface.yellow_rule()
	var bodies: Array = level.world.bodies.duplicate()
	check("fixture keeps supports solid and draft empty", surface.material_at(30, 30) == 0 and surface.material_at(130, 30) == 0)
	check("existing solid black is a valid start", rule.valid_anchor(surface, Vector2(30, 30)))
	check("empty space remains invalid", not rule.valid_anchor(surface, Vector2(90, 90)))
	var stale := Stroke.new()
	stale.activated = true
	stale.saved_anchor_a = Vector2(-1000, -1000)
	stale.saved_anchor_b = Vector2(-900, -1000)
	level.add_child(stale)
	stale.owner = level
	rule.strokes.append(stale)
	rule.begin(surface, Vector2(30, 30))
	check("spring begins over solid black", rule.drawing != null)
	check("empty-path legacy spring cannot break endpoint validation", rule.finish(surface, Vector2(130, 30)))
	var spring = rule.strokes[-1]
	check("placement preserves original bodies without resampling", level.world.bodies == bodies and surface.material_at(30, 30) == 0)
	check("placement can be undone", surface.undo_last_edit() and not rule.strokes.has(spring))
	rule.begin(surface, Vector2(30, 30))
	check("spring can be placed again", rule.finish(surface, Vector2(130, 30)))
	canvas.generate(false)
	spring = rule.strokes[-1]
	check("solidification binds both existing supports", spring.joint != null and spring.joint.is_active() and spring.anchors.size() == 2)
	check("solidification does not replace existing supports", level.world.bodies == bodies)
	for y in range(20, 40):
		for x in range(220, 240):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	rule.begin(surface, Vector2(130, 30))
	check("mixed solid and draft endpoints can submit", rule.finish(surface, Vector2(230, 30)))
	canvas.generate(false)
	check("mixed spring binds after draft solidification", rule.strokes[-1].joint != null and rule.strokes[-1].joint.is_active())
	check("mixed placement retains both original solid objects", level.world.bodies.has(bodies[-1]) and level.world.bodies.has(bodies[-2]))
	rule.strokes.erase(stale)
	level.remove_child(stale)
	stale.free()
	var save_path := "user://solid_spring_save_regression.tscn"
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	check("manual map save succeeds with new solid-supported springs", creative.export_map_to(save_path) == OK)
	var saved: PackedScene = ResourceLoader.load(save_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var restored = saved.instantiate()
	restored.auto_step = false
	root.add_child(restored)
	for frame in 3:
		await process_frame
	var restored_rule = restored.get_node("SimulationRuntime/YellowInk")
	var active: Array = restored_rule.strokes.filter(func(item): return item.joint != null and item.joint.is_active())
	check("saved map restores both spring constraints", active.size() == 2)
	restored.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path))
	level.queue_free()
	await process_frame
	print("[SolidSpring] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
