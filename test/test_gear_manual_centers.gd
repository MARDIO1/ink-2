extends SceneTree
## 齿轮中心 / 手动轴承回归：自由、吸附、世界固定、支座连接、删除撤销、蓝图、存档。
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const GearCenters := preload("res://actor/canvas/src/gear_centers.gd")
const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Place := preload("res://actor/canvas/blueprint/src/blueprint_place.gd")

var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("[GearManualCenters] %s %s" % ["PASS" if ok else "FAIL", label])

func axles(level) -> Array:
	return level.get_children().filter(func(n): return n is Axle and not n.is_queued_for_deletion())

func setup(level) -> void:
	level.auto_step = false
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	canvas.active = true
	canvas.show()
	canvas.set_map_editor_mode(true)
	var camera = level.get_node_or_null("SimulationRuntime/PhysicsStep")
	if camera != null:
		camera.freeze_view_scale = 100000.0
	if camera != null and camera.get("_camera") != null:
		camera._camera.set_process(false)
		camera._camera.set_physics_process(false)
		camera._camera.global_position = canvas.global_position + Vector2(128, 128)
		camera._camera.reset_smoothing()
		camera._camera.force_update_scroll()
	canvas.surface.ink_free = true
	canvas.surface.selected_ink = 0

func _run() -> void:
	# ---------- 主场景：自由固化 / 世界轴承 / 撤销 / 存档 ----------
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	root.add_child(level)
	await process_frame
	setup(level)
	var canvas = level.get_node("MapCanvas")
	var surface = canvas.surface
	surface.gear_tool.begin(Vector2(100, 100), 8)
	surface.gear_tool.finish(Vector2(122, 100))
	canvas.generate()
	var target := GearCenters.query(surface, level, Vector2(100.5, 100.5))
	check("solidified gear owns its center", target.get("kind") == "body" and surface.gear_centers.is_empty())
	check("solidified gear has no joint", axles(level).is_empty())
	var body = target.body
	check("free gear body is dynamic", not body.is_static and body.gravity_scale > 0.0)
	var original_position: Vector2 = body.position
	body.frozen = false
	body.awake = true
	for tick in 20:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
	check("free gear falls under gravity", body.position.y > original_position.y + 0.5)
	body.position = original_position
	body.linear_velocity = Vector2.ZERO
	body.angular_velocity = 0.0
	body.rotation = 0.0
	body.frozen = false
	body.awake = true
	# 预览与点击共用同一个目标。
	var preview: Dictionary = surface.rod_layer.bearing_target(Vector2(100.5, 100.5))
	check("preview snaps to the entity center", not preview.is_empty()
		and preview.get("kind") == "body"
		and Vector2(preview.get("position", Vector2.ZERO)).is_equal_approx(Vector2(100.5, 100.5)))
	check("click uses the same preview target", surface.rod_layer.place_anchor(Vector2(100.5, 100.5)))
	var linked := axles(level)
	check("world bearing is fixed to world", linked.size() == 1 and linked[0].fixed_to_world
		and linked[0].joint != null)
	if linked.size() == 1:
		check("bearing anchor equals preview wheel point", Vector2(linked[0].yellow_anchor.local).is_equal_approx(
			Vector2(preview.get("wheel_local", Vector2.INF))))
	linked[0].yellow_anchor.body.angular_velocity = 2.0
	linked[0].yellow_anchor.body.frozen = false
	linked[0].yellow_anchor.body.awake = true
	var fixed_position: Vector2 = linked[0].yellow_anchor.body.to_world(linked[0].yellow_anchor.local)
	for tick in 120:
		level.get_node("SimulationRuntime")._step(1.0 / 120.0)
	check("world bearing keeps center fixed while rotating",
		linked[0].yellow_anchor.body.to_world(linked[0].yellow_anchor.local).distance_to(fixed_position) < 1.0
		and absf(linked[0].yellow_anchor.body.rotation) > 0.5)
	check("duplicate bearing on the same point rejected",
		not surface.rod_layer.place_anchor(Vector2(100.5, 100.5)) and axles(level).size() == 1)
	# 删除只解除连接，中心保留；撤销/重做连接数量正确。
	var wheel = linked[0].yellow_anchor.body
	check("deleting bearing removes only the joint and display",
		surface.rod_layer.erase_anchor(Vector2(100.5, 100.5)) and axles(level).is_empty()
		and not wheel.is_queued_for_deletion())
	check("deleting bearing keeps the center record",
		not GearCenters.query(surface, level, Vector2(100.5, 100.5)).is_empty())
	check("undo restores a single bearing", surface.undo_last_edit() and axles(level).size() == 1)
	check("redo removes it again without creating a second one",
		surface.redo_last_edit() and axles(level).is_empty())
	check("undo delete once more for save test", surface.undo_last_edit() and axles(level).size() == 1)
	# 存档 / Root 重载：中心和手动连接一起恢复。
	canvas.solid.sync_serializable_bodies(level)
	var packed := PackedScene.new()
	check("map packs centers and bearings", packed.pack(level) == OK)
	var restored = packed.instantiate()
	restored.auto_step = false
	root.add_child(restored)
	await process_frame
	await process_frame
	var restored_axles := axles(restored)
	check("reload restores manual bearing", restored_axles.size() == 1 and restored_axles[0].joint != null
		and restored_axles[0].fixed_to_world)
	check("reload restores entity center", GearCenters.query(restored.get_node("MapCanvas").surface,
		restored, Vector2(100.5, 100.5)).get("kind") == "body")
	restored.queue_free()
	await process_frame
	level.queue_free()
	await process_frame

	# ---------- 蓝图：自由齿轮放置后仍自由 ----------
	var blueprint_level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	root.add_child(blueprint_level)
	await process_frame
	setup(blueprint_level)
	var bc = blueprint_level.get_node("MapCanvas")
	var bs = bc.surface
	bs.gear_tool.begin(Vector2(100, 100), 8)
	bs.gear_tool.finish(Vector2(122, 100))
	var blueprint := Codec.capture(bc, Rect2i(76, 76, 49, 49))
	check("blueprint captures center and no bearing", not blueprint.has("error")
		and blueprint.gear_centers.size() == 1 and blueprint.gears.is_empty())
	var place_error := Place.place(bc, blueprint, Vector2i(140, 140))
	check("free gear blueprint placement stays ink",
		place_error.is_empty() and axles(blueprint_level).is_empty())
	bc.generate(false)
	check("blueprint gear solidifies free", axles(blueprint_level).is_empty())
	var copy_center := GearCenters.query(bs, blueprint_level, Vector2(164.5, 164.5))
	var original_center := GearCenters.query(bs, blueprint_level, Vector2(100.5, 100.5))
	check("blueprint copy receives an independent center", copy_center.get("kind") == "body"
		and original_center.get("kind") == "body" and copy_center.body != original_center.body)
	blueprint_level.queue_free()
	await process_frame

	# ---------- 支座连接：轮体连黄杆，而不是额外固定到世界 ----------
	var support_level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	root.add_child(support_level)
	await process_frame
	setup(support_level)
	var sc = support_level.get_node("MapCanvas")
	var ss = sc.surface
	for x in range(60, 141):
		ss.rod_layer.pixels.set_pixel(x, 100, Palette.YELLOW.color)
	ss.gear_tool.begin(Vector2(100, 100), 12)
	ss.gear_tool.finish(Vector2(124, 100))
	sc.generate()
	var support_target: Dictionary = ss.rod_layer.bearing_target(Vector2(100.5, 100.5))
	check("preview chooses the yellow rod as support", not support_target.is_empty()
		and support_target.get("support", null) != null
		and not bool(support_target.get("fixed_to_world", true)))
	check("support bearing click accepted", ss.rod_layer.place_anchor(Vector2(100.5, 100.5)))
	var support_axles := axles(support_level)
	check("support bearing connects wheel to support, not world", support_axles.size() == 1
		and not support_axles[0].fixed_to_world and not support_axles[0].black_anchor.is_empty()
		and support_axles[0].joint.body_b != null)
	support_level.queue_free()
	await process_frame
	print("[GearManualCenters] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
