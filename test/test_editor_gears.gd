extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Surface := preload("res://actor/canvas/src/canvas_surface.gd")
const Bearing := preload("res://actor/canvas/src/gear_bearing.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[EditorGears] %s %s" % ["PASS" if ok else "FAIL", label])

func bearings(level) -> Array:
	var result := []
	for child in level.get_children():
		if child is Bearing and not child.is_queued_for_deletion():
			result.append(child)
	return result

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var canvas = level.get_node("MapCanvas")
	var creative = level.get_node("Creative")
	creative.auto_save_edits = false
	creative.auto_save_on_exit = false
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	var camera = level.get_node("SimulationRuntime/PhysicsStep")._camera
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.global_position = canvas.global_position + Vector2(128, 128)
	camera.reset_smoothing()
	camera.force_update_scroll()
	var surface = canvas.surface
	surface.ink_free = true
	var tool = surface.gear_tool
	check("normal play shape menu excludes gear", canvas._shape_popup.get_item_index(Surface.Tool.GEAR) < 0)
	canvas._on_shape_picked(Surface.Tool.GEAR)
	check("normal play rejects gear selection", surface.tool != Surface.Tool.GEAR)
	creative.select_gear_tool()
	check("right gear tool rejects normal play", surface.tool != Surface.Tool.GEAR)
	tool.begin(Vector2(50, 50))
	check("normal play cannot start gear creation", not tool.dragging)
	canvas.set_map_editor_mode(true)
	creative.active = true
	creative._ensure_editor_resources()
	var palette = creative.editor_palette()
	canvas._on_shape_picked(Surface.Tool.GEAR)
	check("editor shape menu contains only rectangle circle line", canvas._shape_popup.item_count == 3
		and canvas._shape_popup.get_item_index(Surface.Tool.GEAR) < 0 and surface.tool != Surface.Tool.GEAR)
	check("dedicated gear button belongs to right mechanism tools", palette.gear_tool_button(12).get_parent().name == "MechanismGrid"
		and palette.is_ancestor_of(palette.gear_tool_button(12)))
	palette.gear_tool_button(12).pressed.emit()
	check("right gear tool activates independently of shape button", surface.tool == Surface.Tool.GEAR
		and palette.gear_tool_button(12).button_pressed and not canvas.tool_grid.get_node("Shape").button_pressed)
	palette.gear_tool_button(12).pressed.emit()
	check("clicking gear again deactivates it", surface.tool == Surface.Tool.HAND and not palette.gear_tool_button(12).button_pressed)
	creative.select_monster_tool(0)
	palette.gear_tool_button(12).pressed.emit()
	check("gear and monster placement are mutually exclusive", creative._monster_mode == creative.MONSTER_MODE_NONE
		and surface.tool == Surface.Tool.GEAR)
	tool.begin(Vector2(60, 60))
	tool.update_preview(Vector2(90.5, 60.5))
	check("drag origin is center and distance is outer radius", tool.center == Vector2(60.5, 60.5)
		and is_equal_approx(tool.radius, 30.0))
	canvas._apply_tool(Surface.Tool.BRUSH)
	check("switching tools cancels gear without changing blueprint", not tool.dragging
		and bearings(level).is_empty() and surface.black_image.get_used_rect().size == Vector2i.ZERO
		and not palette.gear_tool_button(12).button_pressed)
	palette.gear_tool_button(12).pressed.emit()
	tool.begin(Vector2(60, 60))
	creative.select_control_tool()
	check("control tool cancels gear preview and highlight", not tool.dragging
		and surface.tool == Surface.Tool.HAND and not palette.gear_tool_button(12).button_pressed)
	palette.gear_tool_button(12).pressed.emit()
	creative.select_monster_tool(creative.MONSTER_MODE_NONE)
	check("stop placement also exits gear tool", surface.tool == Surface.Tool.HAND and not palette.gear_tool_button(12).button_pressed)
	palette.gear_tool_button(12).pressed.emit()
	tool.begin(Vector2(60, 60))
	check("tiny drags do not create degenerate gear", tool.finish(Vector2(61, 60)) == null)
	surface.selected_ink = 1
	tool.begin(Vector2(60, 60))
	var bearing = tool.finish(Vector2(90.5, 60.5))
	check("gray gear is dynamic and pinned to world", bearing != null and bearing.fixed_to_world
		and not bearing.yellow_anchor.body.is_static and bearing.joint != null)
	if bearing == null:
		quit(1)
		return
	var wheel = bearing.yellow_anchor.body
	check("current gray material fills real gear pixels", Bearing.has_pixel(wheel, Vector2i.ZERO, Palette.GREY.id)
		and not Bearing.has_pixel(wheel, Vector2i(30, 30), Palette.GREY.id))
	var start: Vector2 = bearing.yellow_position
	camera.global_position = canvas.global_position + Vector2(128, 128)
	camera.reset_smoothing()
	camera.force_update_scroll()
	await process_frame
	wheel.angular_velocity = 2.0
	var max_drift := 0.0
	for tick in 360:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
		max_drift = maxf(max_drift, bearing.joint.anchor_error().length())
	check("real physics rotates gear with center fixed", absf(wheel.rotation) > 0.5
		and max_drift < 1.0 and start.distance_to(bearing.Stroke.anchor_world(bearing.yellow_anchor)) < 1.0)
	print("GEAR_METRIC world angle=", wheel.rotation, " drift=", max_drift,
		" center_delta=", start.distance_to(bearing.Stroke.anchor_world(bearing.yellow_anchor)), " frozen=", wheel.frozen)
	check("gear creation undo removes axle and body", surface.undo_last_edit()
		and bearings(level).is_empty() and not level.world.bodies.has(wheel))
	check("gear creation redo restores independent body", surface.redo_last_edit())
	await process_frame
	await process_frame
	check("redo restores usable world axle", bearings(level).size() == 1 and bearings(level)[0].joint != null)
	# 支座与齿轮同为黑墨：仍须为独立刚体，只排除配对碰撞。
	# 放置齿轮不再顺带固化草稿，所以支座要按要求先固化，齿轮才能找到它。
	surface.selected_ink = 0
	for y in range(120, 221):
		for x in range(120, 221):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	surface.write_pixel(Vector2i(125, 125), surface.nail_color())
	canvas.generate(false)
	await process_frame
	tool.begin(Vector2(170, 170))
	var attached = tool.finish(Vector2(210.5, 170.5))
	check("black selection creates black gear separate from support", attached != null
		and attached.gear_material == Palette.BLACK.id and not attached.fixed_to_world
		and attached.yellow_anchor.body != attached.black_anchor.body)
	if attached == null:
		quit(1)
		return
	check("support solidification preserves full gear outline", Bearing.has_pixel(attached.yellow_anchor.body, Vector2i(-20, 0), Palette.BLACK.id)
		and not Bearing.has_pixel(attached.yellow_anchor.body, Vector2i(39, 39), Palette.BLACK.id))
	check("bearing disables only gear-support pair collision", attached.joint != null
		and not attached.joint.contacts_enabled and attached.black_anchor.body.is_static
		and attached.yellow_anchor.body.collision_mask == 0xFFFFFFFF)
	attached.yellow_anchor.body.angular_velocity = 1.5
	for tick in 180:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
	check("gear rotates even inside its fixed support", absf(attached.yellow_anchor.body.rotation) > 0.5
		and attached.joint.anchor_error().length() < 1.0)
	print("GEAR_METRIC support angle=", attached.yellow_anchor.body.rotation,
		" drift=", attached.joint.anchor_error().length())
	canvas.solid.sync_serializable_bodies(level)
	for axle in bearings(level):
		axle._process(0.0)
	var packed := PackedScene.new()
	check("gears and bearing metadata pack with map", packed.pack(level) == OK)
	var restored = packed.instantiate()
	restored.auto_step = false
	root.add_child(restored)
	await process_frame
	await process_frame
	var loaded := bearings(restored)
	check("map reload restores world and object axles", loaded.size() == 2
		and loaded[0].joint != null and loaded[1].joint != null
		and loaded[0].fixed_to_world and not loaded[1].fixed_to_world)
	if loaded.size() == 2:
		check("same-color reload identifies wheel separately from support",
			loaded[1].yellow_anchor.body != loaded[1].black_anchor.body)
	restored.queue_free()
	await process_frame
	creative.active = true
	canvas.return_to_canvas(false, true)
	for axle in bearings(level):
		axle._process(0.0)
	check("editor reclaim preserves independent gear bodies", bearings(level).size() == 2
		and bearings(level)[1].joint != null)
	canvas.generate(false)
	check("solidification reattaches reclaimed support", attached.joint != null
		and attached.joint.body_b != null and not attached.black_anchor.is_empty()
		and attached.yellow_anchor.body != attached.black_anchor.body)
	creative.active = false
	# 轴心被破坏后解除约束；沿用正式物理碎裂通知。
	var target = attached.yellow_anchor.body
	var cell: Vector2i = attached.yellow_anchor.cell
	var mask := {}
	for shape in target.shapes:
		if shape.get_pixel(cell.x, cell.y) != 0:
			mask[shape] = {cell: true}
	level.get_node("SimulationRuntime/PhysicsStep").commit(level.world, {target: mask})
	check("destroying center pixel removes gear axle", attached.is_queued_for_deletion() and attached.joint == null)
	# 齿轮不再允许共用像素，所以逐个换位置摆放，而不是全叠在同一点。
	for index in [0, 1, 2, 3, 4]:
		surface.selected_ink = index
		var spot := Vector2(20 + index * 40, 240)
		tool.begin(spot)
		var colored = tool.finish(spot + Vector2(14.0, 0.5))
		var selected_material: int = Palette.material_id_of(Palette.ink_at(index))
		check("gear uses selected " + Palette.ink_name(index), colored != null
			and colored.gear_material == selected_material and surface.selected_ink == index
			and Bearing.has_pixel(colored.yellow_anchor.body, Vector2i.ZERO, selected_material))
	canvas.set_map_editor_mode(false)
	check("leaving editor removes gear menu and deactivates tool", canvas._shape_popup.item_count == 3
		and surface.tool != Surface.Tool.GEAR)
	level.queue_free()
	await process_frame
	print("[EditorGears] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
