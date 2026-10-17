extends SceneTree
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func _check(label: String, ok: bool) -> void:
	print("[CanvasProximity] %s %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failures += 1

func _position_player(body, position: Vector2) -> void:
	body.position = position
	body.rotation = 0.0
	body.refresh_com()
	body.update_aabb()

func _run() -> void:
	var level: Node = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	root.add_child(level)
	await process_frame
	level.get_node("SimulationRuntime").set_physics_process(false)
	var canvas: Node = level.get_node("SmallCanvas")
	var body = level.get_node("Player").body
	var hand: Node = level.get_node("Player/Arm/Hand/HandControl")
	var camera: Node = level.get_node("Camera2D")
	camera.set_physics_process(false)
	canvas.set_physics_process(false)
	var original_size: Vector2i = canvas.canvas_size
	var near_position: Vector2 = canvas.surface.global_position + Vector2(60, 60)
	_position_player(body, near_position)
	canvas._refresh_workbench_visibility()
	canvas.set_tool(canvas.SurfaceScript.Tool.BRUSH)
	_check("brush hides hand near canvas", not hand.enabled)
	camera._update_canvas_zoom(1.0)
	var near_zoom: Vector2 = camera.zoom
	_check("near canvas smoothly magnifies", camera._canvas_zoom_weight > 0.9)
	_position_player(body, near_position + Vector2(2000, 0))
	canvas._refresh_workbench_visibility()
	_check("departure starts closing animation", canvas.buttons.visible and not canvas.buttons.get_meta("toolbar_wanted"))
	_check("departure returns hand and tool", hand.enabled and canvas.surface.tool == canvas.SurfaceScript.Tool.HAND)
	_check("fading buttons cannot be clicked", canvas.tool_grid.get_node("Brush").disabled)
	await create_timer(0.1).timeout
	_check("closing gently interpolates scale and opacity", canvas.buttons.scale.x > 0.96 and canvas.buttons.scale.x < 1.0 and canvas.buttons.modulate.a > 0.0 and canvas.buttons.modulate.a < 1.0)
	await create_timer(0.25).timeout
	_check("toolbar finishes gentle fade without collapsing", not canvas.buttons.visible and is_equal_approx(canvas.buttons.scale.x, 0.96) and canvas._side_panel.modulate.a == 0.0)
	camera._update_canvas_zoom(1.0)
	_check("leaving restores camera zoom", camera.zoom.x < near_zoom.x and camera._canvas_zoom_weight < 0.01)
	_position_player(body, near_position)
	canvas._refresh_workbench_visibility()
	await create_timer(0.3).timeout
	_check("return restores toolbar input and scale", canvas.buttons.visible and canvas.buttons.scale.is_equal_approx(Vector2.ONE) and not canvas.tool_grid.get_node("Brush").disabled)
	# 快速进出不会留下旧动画回调把重新展开的工具栏藏掉。
	_position_player(body, near_position + Vector2(2000, 0))
	canvas._refresh_workbench_visibility()
	await create_timer(0.06).timeout
	_position_player(body, near_position)
	canvas._refresh_workbench_visibility()
	await create_timer(0.3).timeout
	_check("quick reentry reverses animation safely", canvas.buttons.visible and canvas.buttons.scale.is_equal_approx(Vector2.ONE))
	_check("canvas dimensions never changed", canvas.canvas_size == original_size)
	var creative: Node = level.get_node("Creative")
	creative.active = true
	camera._update_canvas_zoom(1.0)
	_check("editor ignores proximity zoom", camera._canvas_zoom_weight == 0.0)
	creative.active = false
	# 重叠画布间移动不能强制结束另一画布正在进行的绘制。
	var other: Node = load("res://actor/canvas/canvas.tscn").instantiate()
	level.add_child(other)
	other.position = near_position + Vector2(2000, 0)
	other.set_physics_process(false)
	_position_player(body, other.position + Vector2(60, 60))
	other._refresh_workbench_visibility()
	other.set_tool(other.SurfaceScript.Tool.BRUSH)
	canvas._refresh_workbench_visibility()
	_check("near another canvas preserves drawing mode", not hand.enabled and other.surface.tool == other.SurfaceScript.Tool.BRUSH)
	await process_frame
	await process_frame
	level.queue_free()
	await process_frame
	quit(1 if failures else 0)
