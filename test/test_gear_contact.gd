extends SceneTree
## 复现并钉住两个地图齿轮问题：放置就固化导致轴心跟着动态支座掉，
## 以及两个齿轮共用像素后被互相顶死。

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
	print("[GearContact] %s %s" % ["PASS" if ok else "FAIL", label])


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
	surface.selected_ink = 0
	canvas.set_map_editor_mode(true)
	creative.active = true
	creative._ensure_editor_resources()
	var tool = surface.gear_tool

	# 症状一：轴心下画了未固化墨迹时，放齿轮不该把整张草稿提交掉。
	# 钉子放在齿轮轮廓外面：轮廓会盖住它，那是拒绝落笔的保护。
	for y in range(60, 141):
		for x in range(60, 141):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	surface.write_pixel(Vector2i(65, 65), surface.nail_color())
	tool.begin(Vector2(120, 120))
	var pinned = tool.finish(Vector2(150.5, 120.5))
	check("placing a gear leaves the canvas draft alone", pinned != null
		and surface.material_at(70, 70) == Palette.BLACK.id
		and surface.material_at(135, 70) == Palette.BLACK.id)
	check("gear does not copy pixels into the draft", pinned != null
		and surface.gear_skip_cells.is_empty() and surface.material_at(150, 120) == 0
		and surface.material_at(120, 120) == Palette.BLACK.id)
	check("gear over unsolidified ink is pinned to the world", pinned.fixed_to_world
		and pinned.joint != null and pinned.black_anchor.is_empty())
	var rest_y: float = pinned.yellow_anchor.body.position.y
	for tick in 120:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
	check("world-pinned gear keeps its axle instead of falling", pinned.joint != null
		and absf(pinned.yellow_anchor.body.position.y - rest_y) < 1.0
		and absf(pinned.yellow_anchor.body.position.x - pinned.yellow_position.x) < 1.0)

	# 固化后必须改绑到轮缘外的支座：重叠但不连 Joint 的两个刚体会互顶。
	canvas.generate(false)
	await process_frame
	check("solidify rebinds the gear to the support around its rim", not pinned.fixed_to_world
		and pinned.black_anchor.get("body") != null and pinned.joint != null
		and not pinned.joint.contacts_enabled and pinned.black_anchor.body.is_static)
	check("gear silhouette stays out of the solidified support", surface.gear_skip_cells.is_empty())
	check("support reaches the axle so the slip ring can bridge", Bearing.has_pixel(
		pinned.black_anchor.body, pinned.black_anchor.cell, Palette.BLACK.id))
	pinned.yellow_anchor.body.angular_velocity = 2.0
	for tick in 120:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
	check("rebuilt axle still lets the gear spin", absf(pinned.yellow_anchor.body.rotation) > 0.5
		and pinned.joint.anchor_error().length() < 1.0)

	# 症状二：两个齿轮相邻摆放必须是两个独立刚体，不能合并或被对方顶死。
	tool.begin(Vector2(200, 60))
	var left = tool.finish(Vector2(220.5, 60.5))
	tool.begin(Vector2(241, 60))
	var right = tool.finish(Vector2(261.5, 60.5))
	check("two meshing gears stay as two bodies", left != null and right != null
		and left.yellow_anchor.body != right.yellow_anchor.body
		and left.joint != null and right.joint != null)
	check("neighbouring gear is never used as a support", left.fixed_to_world and right.fixed_to_world)

	# 重叠摆放必须被拒绝，否则两支轮齿互相插入就会卡死。
	tool.begin(Vector2(202, 62))
	check("overlapping a neighbour gear is refused", tool.finish(Vector2(219.5, 62.5)) == null)

	left.yellow_anchor.body.angular_velocity = 3.0
	right.yellow_anchor.body.angular_velocity = -3.0
	for tick in 120:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
	check("both driven gears actually turn", absf(left.yellow_anchor.body.rotation) > 0.5
		and absf(right.yellow_anchor.body.rotation) > 0.5)
	print("GEAR_CONTACT left=", left.yellow_anchor.body.rotation,
		" right=", right.yellow_anchor.body.rotation,
		" bodies=", level.world.bodies.size())

	level.queue_free()
	await process_frame
	print("[GearContact] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
