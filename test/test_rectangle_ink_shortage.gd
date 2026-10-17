extends SceneTree

const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
var failures := 0
var warning_count := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(label: String, okay: bool) -> void:
	print("[RectangleInk] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1


func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var canvas = level.get_node("MapCanvas")
	canvas.active = true
	canvas.canvas_size = Vector2i(96, 96)
	var surface = canvas.surface
	surface.clear()
	surface.ink_free = false
	surface.tool = SurfaceScript.Tool.RECT
	surface.brush_size = 1
	var health = surface._health_node()
	var material: int = surface.ink_material_id()
	health.reduce(material, health.ink_of(material) - 1100.0)
	surface.ink_shortage.connect(func(_required: int, _available: int) -> void:
		warning_count += 1)
	surface._shape_origin = Vector2(10.5, 10.5)
	surface._shaping = true
	surface._preview_shape(Vector2(30.5, 20.5))
	surface._preview_shape(Vector2(31.5, 20.5))
	var expected: Dictionary = surface._shape_pixels(surface._shape_origin, Vector2(31.5, 20.5))
	var complete := true
	for point: Vector2i in expected:
		complete = complete and surface.black_image.get_pixelv(point).a > 0.5
	_check("repeated previews keep all four edges", complete)
	_check("preview uses current ink balance, not previous frame's deduction",
		is_equal_approx(health.ink_of(material), 1100.0 - expected.size()))
	surface._preview_shape(Vector2(75.5, 75.5))
	_check("unaffordable rectangle leaves no partial line",
		surface.black_image.get_used_rect().size == Vector2i.ZERO)
	_check("ink shortage emits once", warning_count == 1)
	_check("ink shortage shows a visible screen warning",
		canvas._ink_warning_panel != null and canvas._ink_warning_panel.visible
		and "墨水不足" in canvas._ink_warning_label.text)
	surface.tool = SurfaceScript.Tool.HAND
	_check("cancelled preview refunds ink", is_equal_approx(health.ink_of(material), 1100.0))
	health.reduce(material, 101.0)
	surface._paint_shortage_notified = false
	_check("below 1000 px blocks another paint action", not surface._can_start_paint()
		and is_equal_approx(health.ink_of(material), 999.0))
	_check("threshold warning is visible",
		"低于 1000 px" in canvas._ink_warning_label.text)
	surface.selected_ink = 3
	var yellow_id: int = Palette.YELLOW.id
	health.reduce(yellow_id, health.ink_of(yellow_id) - 999.0)
	surface.rod_layer.begin(Vector2(10, 10))
	_check("yellow rod cannot spend ink below threshold",
		surface.rod_layer.pixels.get_pixel(10, 10).a < 0.5)
	surface.rod_layer.finish(Vector2(10, 10))
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
