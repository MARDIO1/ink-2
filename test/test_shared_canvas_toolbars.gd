extends SceneTree

var failures := 0
var checks := 0
var canvases: Array = []

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[SharedToolbars] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func settle(frames := 4) -> void:
	for frame in frames:
		await process_frame

func point_at(point: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = root.get_final_transform() * point
	motion.global_position = motion.position
	Input.parse_input_event(motion)
	Input.flush_buffered_events()
	await settle()

func visible_count(right: bool) -> int:
	var count := 0
	for canvas in canvases:
		var control: Control = canvas._side_panel if right else canvas.buttons
		if control.visible and control.modulate.a > 0.001:
			count += 1
	return count

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await settle()
	level.get_node("Camera2D").enabled = false
	root.canvas_transform = Transform2D.IDENTITY
	var a = level.get_node("SmallCanvas")
	a.position = Vector2(220, 200)
	a.canvas_size = Vector2i(160, 200)
	var b = load("res://actor/canvas/canvas.tscn").instantiate()
	b.position = Vector2(410, 200)
	b.canvas_size = Vector2i(160, 200)
	level.add_child(b)
	canvases = [a, b]
	var player = level.get_node("Player")
	player.teleport_to(Vector2(370, 270), 0.0)
	await point_at(Vector2(280, 260))
	await settle(20)
	check("nearby canvases display one left and one right toolbar", visible_count(false) == 1 and visible_count(true) == 1)
	check("pointed canvas owns the toolbar", a.buttons.visible and not b.buttons.visible)
	a.set_tool(a.SurfaceScript.Tool.BRUSH)
	a.select_ink(2)
	a.set_brush_size(13)
	var old_position: Vector2 = a.get_node("SidePanelLayer")._mount.position
	await point_at(Vector2(480, 260))
	check("handoff never draws two toolbar sets", visible_count(false) == 1 and visible_count(true) == 1)
	check("new canvas inherits tool ink and brush", b.surface.tool == b.SurfaceScript.Tool.BRUSH and b.surface.selected_ink == 2 and b.surface.brush_size == 13)
	check("only owner receives drawing input", b.surface.is_processing_input() and not a.surface.is_processing_input())
	var new_position: Vector2 = b.get_node("SidePanelLayer")._mount.position
	check("handoff keeps position at shared canvas group edge", new_position.is_equal_approx(old_position))
	b.surface.set_process(false)
	b.surface._painting = true
	await point_at(Vector2(280, 260))
	check("held stroke keeps toolbar ownership", b.buttons.visible and not a.buttons.visible)
	b.surface._painting = false
	b.surface.set_process(true)
	await point_at(Vector2(280, 260))
	check("finishing stroke allows next handoff", a.buttons.visible and not b.buttons.visible)
	await settle(25)
	var left: Control = a.buttons
	var screen_rect := Rect2(left.get_global_transform_with_canvas().origin, left.size)
	check("left toolbar fully fits viewport", root.get_visible_rect().encloses(screen_rect))
	check("left tools stay at screen scale", is_equal_approx(left.get_global_transform_with_canvas().x.length(), 1.0))
	check("right toolbar has no background frame", not a.get_node("SidePanelLayer/Mount").has_node("PaperBackground"))
	player.teleport_to(Vector2(4000, 4000), 0.0)
	await settle(3)
	check("departing disables input immediately", a.tool_grid.get_node("Brush").disabled)
	await settle(25)
	check("departure fades both toolbar sets away", visible_count(false) == 0 and visible_count(true) == 0)
	level.queue_free()
	await settle()
	print("[SharedToolbars] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
