extends SceneTree
const Codec := preload("res://actor/blueprint/src/blueprint_codec.gd")
const Store := preload("res://actor/blueprint/src/blueprint_store.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
const Bearing := preload("res://actor/canvas/src/gear_bearing.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	checks += 1
	print("[Blueprints] %s %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		failures += 1

func _run() -> void:
	var level = load("res://map/asset/imported/main.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	current_scene = level
	await process_frame
	level.get_node("Creative").auto_save_edits = false
	level.get_node("Creative").auto_save_on_exit = false
	var canvas = level.get_node("MapCanvas")
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(256, 256)
	canvas.active = true
	canvas.show()
	canvas.set_map_editor_mode(true)
	var surface = canvas.surface
	surface.ink_free = true
	surface.clear()
	surface.write_pixel(Vector2i(20, 20), Palette.BLACK.color)
	surface.write_pixel(Vector2i(21, 20), Palette.GREY.color)
	surface.write_pixel(Vector2i(16, 16), Palette.RED.color)
	surface.refresh()
	var before: PackedByteArray = surface.black_image.get_data()
	var undo_count: int = surface._undo_steps.size()
	var data := Codec.capture(canvas, Rect2i(16, 16, 9, 9), {"circle_rect": Rect2i(16, 16, 9, 9)})
	check("circle captures interior and excludes bounding corner", not data.has("error") and data.pixels.size() == 2)
	check("capture is read-only and does not create undo", surface.black_image.get_data() == before and surface._undo_steps.size() == undo_count)
	check("preview retains original colors and transparent corners", Codec.preview(data).get_pixel(4, 4) == Palette.BLACK.color and Codec.preview(data).get_pixel(0, 0).a == 0)
	check("empty selection rejected", Codec.capture(canvas, Rect2i(100, 100, 8, 8)).has("error"))
	check("placement outside bounds rejected", not Codec.place(canvas, data, Vector2i(254, 254)).is_empty())
	check("overlap rejected without altering source", not Codec.place(canvas, data, Vector2i(16, 16)).is_empty() and surface.black_image.get_data() == before)
	check("editor can paste original colors", Codec.place(canvas, data, Vector2i(80, 80)).is_empty() and surface.material_at(84, 84) == Palette.BLACK.id and surface.material_at(85, 84) == Palette.GREY.id)
	check("one placement adds one transaction", surface._undo_steps.size() == undo_count + 1)
	check("undo removes entire placement", surface.undo_last_edit() and surface.material_at(84, 84) == 0)
	check("redo restores entire placement", surface.redo_last_edit() and surface.material_at(85, 84) == Palette.GREY.id)
	surface.undo_last_edit()
	canvas.set_map_editor_mode(false)
	canvas._workbench_nearby = false
	check("gameplay rejects paste away from workbench", Codec.place(canvas, data, Vector2i(80, 80)) == "请靠近画布使用")
	canvas._workbench_nearby = true
	surface.ink_free = false
	var health = surface._health_node()
	var black_before: float = health.ink_of(Palette.BLACK.id)
	var grey_before: float = health.ink_of(Palette.GREY.id)
	check("gameplay placement succeeds near canvas", Codec.place(canvas, data, Vector2i(80, 80)).is_empty())
	check("each ink billed independently", health.ink_of(Palette.BLACK.id) == black_before - 1 and health.ink_of(Palette.GREY.id) == grey_before - 1)
	surface.undo_last_edit()
	check("undo refunds exactly once", health.ink_of(Palette.BLACK.id) == black_before and health.ink_of(Palette.GREY.id) == grey_before)
	surface.redo_last_edit()
	check("redo bills exactly once", health.ink_of(Palette.BLACK.id) == black_before - 1 and health.ink_of(Palette.GREY.id) == grey_before - 1)
	surface.undo_last_edit()
	health.reduce(Palette.GREY.id, grey_before - 999)
	before = surface.black_image.get_data()
	check("one deficient color rejects atomic paste", not Codec.place(canvas, data, Vector2i(80, 80)).is_empty() and surface.black_image.get_data() == before and health.ink_of(Palette.BLACK.id) == black_before)
	health.add(Palette.GREY.id, grey_before - 999)
	surface.ink_free = true
	canvas.set_map_editor_mode(true)
	# 保存到测试独立目录，不触碰玩家蓝图库。
	var store := Store.new()
	store.directory = "user://blueprint_test_%d_%d" % [Time.get_ticks_usec(), randi()]
	data.name = "桥梁测试"
	check("save versioned blueprint", store.save(data))
	var loaded := store.read(data.id)
	check("JSON round-trip keeps material data", not loaded.is_empty() and loaded.pixels.size() == data.pixels.size() and int(loaded.pixels[0][0]) == data.pixels[0][0] and int(loaded.pixels[0][1]) == data.pixels[0][1] and loaded.name == data.name)
	loaded.description = "一座桥"
	loaded.tags = ["桥", "黑墨"]
	loaded.favorite = true
	check("metadata update keeps same ID", store.save(loaded) and store.list_all().size() == 1 and store.read(data.id).favorite)
	check("path traversal rejected", store.read("../escape").is_empty())
	var invalid := loaded.duplicate(true)
	invalid.pixels.append([9999999, Palette.BLACK.id])
	check("out-of-bounds data rejected", not store.save(invalid) and not store.read(data.id).is_empty())
	invalid = loaded.duplicate(true)
	invalid.erase("description")
	check("missing required metadata rejected safely", not Store.validate(invalid))
	invalid = loaded.duplicate(true)
	invalid.version = 999
	check("unknown schema version rejected safely", not Store.validate(invalid))
	check("delete is recoverable trash", store.trash(data.id) and store.list_all().is_empty())
	# 黄墨杆、蓝线、弹簧和动力箭头各自保留层和语义。
	surface.write_pixel(Vector2i(36, 20), Palette.BLACK.color)
	surface.write_pixel(Vector2i(24, 20), Palette.BLACK.color)
	surface.rod_layer.pixels.set_pixel(24, 20, Palette.YELLOW.color)
	surface.rod_layer.anchor_points.append(Vector2(24.5, 20.5))
	surface.blue_layer.mask[Vector2i(20, 20)] = true
	surface.blue_layer.refresh()
	var spring := Stroke.new()
	spring.path = PackedVector2Array([Codec.world_point(canvas, Vector2(20, 20)), Codec.world_point(canvas, Vector2(36, 20))])
	spring.compact_raster = true
	spring.brush_width = 3
	spring.source_surface = surface
	level.add_child(spring)
	surface.yellow_rule().strokes.append(spring)
	var motor := Motor.new()
	motor.position = Codec.world_point(canvas, Vector2(20, 20))
	motor.tip = Vector2(0, 12)
	motor.brush_width = 3
	motor.area = 36
	motor.source_surface = surface
	level.add_child(motor)
	var mechanism := Codec.capture(canvas, Rect2i(10, 10, 40, 40))
	check("multilayer mechanisms captured", not mechanism.has("error") and mechanism.rods.size() == 1 and mechanism.blue.size() == 1 and mechanism.springs.size() == 1 and mechanism.motors.size() == 1)
	check("partial spring rejected", Codec.capture(canvas, Rect2i(18, 18, 8, 8)).has("error"))
	check("mechanism placement restores drafts", Codec.place(canvas, mechanism, Vector2i(140, 140)).is_empty() and surface.rod_layer.pixels.get_pixel(154, 150).a > 0.5 and surface.blue_layer.mask.has(Vector2i(150, 150)))
	check("mechanism placement undo succeeds", surface.undo_last_edit())
	mechanism.name = "多层机关"
	check("spring and motor metadata survive JSON", store.save(mechanism) and not store.read(mechanism.id).is_empty())
	canvas.set_map_editor_mode(false)
	canvas._workbench_nearby = true
	surface.ink_free = false
	var balances := {}
	for ink in Palette.INKS:
		balances[ink.material.id] = health.ink_of(ink.material.id)
	var required := Codec.costs(mechanism)
	check("multilayer gameplay paste succeeds", Codec.place(canvas, store.read(mechanism.id), Vector2i(140, 140)).is_empty())
	var billed_correctly := true
	for material in balances:
		billed_correctly = billed_correctly and health.ink_of(material) == balances[material] - required.get(material, 0)
	check("rods springs wires and motor billed once", billed_correctly and surface.ink_px_of(Palette.YELLOW.id) == 0)
	surface.undo_last_edit()
	var refunded := true
	for material in balances:
		refunded = refunded and health.ink_of(material) == balances[material]
	check("multilayer undo refunds every color exactly", refunded)
	surface.redo_last_edit()
	billed_correctly = true
	for material in balances:
		billed_correctly = billed_correctly and health.ink_of(material) == balances[material] - required.get(material, 0)
	check("multilayer redo bills every color exactly", billed_correctly)
	surface.undo_last_edit()
	canvas.set_map_editor_mode(true)
	surface.ink_free = true
	# 齿轮通过原工具创建，再保存、复制和验证轴承。
	surface.selected_ink = 1
	surface.gear_tool.begin(Vector2(70, 80), 8)
	var bearing = surface.gear_tool.finish(Vector2(90.5, 80.5))
	check("source gear created", bearing != null)
	var gear_data := Codec.capture(canvas, Rect2i(45, 55, 52, 52))
	check("gear retains 8 teeth and independent body", not gear_data.has("error") and gear_data.gears.size() == 1 and gear_data.gears[0].teeth == 8 and gear_data.editor_only)
	check("partial gear cannot silently flatten", Codec.capture(canvas, Rect2i(70, 80, 8, 8)).has("error"))
	var count_before: int = level.world.bodies.size()
	check("gear paste creates independent pinned wheel", Codec.place(canvas, gear_data, Vector2i(110, 55)).is_empty() and level.world.bodies.size() == count_before + 1)
	var copied: Node
	for child in level.get_children():
		if child is Bearing and child != bearing and not child.is_queued_for_deletion():
			copied = child
	check("copied axle uses new body and local position", copied != null and copied.joint != null and copied.yellow_anchor.body != bearing.yellow_anchor.body and copied.yellow_position.is_equal_approx(Codec.world_point(canvas, Vector2(135.5, 80.5))))
	check("gear undo removes body and axle together", surface.undo_last_edit() and level.world.bodies.size() == count_before)
	check("gear redo restores joint", surface.redo_last_edit())
	canvas.set_map_editor_mode(false)
	canvas._workbench_nearby = true
	check("gameplay cannot bypass gear tool restriction", Codec.place(canvas, gear_data, Vector2i(180, 55)) == "含齿轮的蓝图仅编辑器可用")
	canvas.set_map_editor_mode(true)
	canvas.canvas_size = Vector2i(640, 320)
	# 同材质轮体与支座仍须保持两个实体，不焊成一块。
	for y in range(100, 161):
		for x in range(280, 341):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	surface.write_pixel(Vector2i(285, 105), Palette.nail_color())
	surface.selected_ink = 0
	surface.gear_tool.begin(Vector2(310, 130), 12)
	var attached = surface.gear_tool.finish(Vector2(330.5, 130.5))
	check("source 12-tooth gear attaches to object", attached != null and not attached.fixed_to_world)
	check("omitted support is rejected", Codec.capture(canvas, Rect2i(285, 105, 50, 50)).has("error"))
	var assembly := Codec.capture(canvas, Rect2i(270, 90, 80, 80))
	check("complete same-color assembly stores wheel and support separately", not assembly.has("error") and assembly.bodies.size() == 2 and assembly.gears[0].support >= 0 and assembly.gears[0].teeth == 12)
	assembly.name = "十二齿支座"
	check("mechanical assembly persists as safe JSON", store.save(assembly))
	var restored := store.read(assembly.id)
	var placement_result := Codec.place(canvas, restored, Vector2i(450, 90))
	check("loaded gear assembly places", placement_result.is_empty())
	var axle: Node
	for child in level.get_children():
		if child is Bearing and not child.is_queued_for_deletion() and child.yellow_position.distance_to(Codec.world_point(canvas, Vector2(490.5, 130.5))) < 1:
			axle = child
	check("new assembly binds only its own support", axle != null and not axle.fixed_to_world and axle.yellow_anchor.body != axle.black_anchor.body and axle.black_anchor.body != attached.black_anchor.body and not axle.joint.contacts_enabled)
	var camera = level.get_node("SimulationRuntime/PhysicsStep")._camera
	camera.set_process(false)
	camera.set_physics_process(false)
	camera.global_position = canvas.global_position + Vector2(320, 160)
	camera.reset_smoothing()
	camera.force_update_scroll()
	await process_frame
	await process_frame
	if axle != null:
		axle.yellow_anchor.body.angular_velocity = 2.0
		for _step in 90:
			level.get_node("SimulationRuntime")._step(1.0 / 120.0)
		print("COPY_GEAR_METRIC angle=", axle.yellow_anchor.body.rotation, " drift=", axle.joint.anchor_error().length(), " frozen=", axle.yellow_anchor.body.frozen, " static=", axle.yellow_anchor.body.is_static, " support_static=", axle.black_anchor.body.is_static)
		check("copied wheel rotates with stable axle in real physics", absf(axle.yellow_anchor.body.rotation) > 0.5 and axle.joint.anchor_error().length() < 1.0)
	else:
		check("copied wheel rotates with stable axle in real physics", false)
	# 只清理本测试随机目录中的文件。
	var folder := DirAccess.open(store.directory)
	if folder != null:
		for filename in folder.get_files():
			DirAccess.remove_absolute(ProjectSettings.globalize_path(store.directory.path_join(filename)))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(store.directory))
	level.queue_free()
	await process_frame
	print("[Blueprints] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
