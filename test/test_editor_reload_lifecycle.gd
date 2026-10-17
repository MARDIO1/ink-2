extends SceneTree

const World := preload("res://addons/pixel_destruction/nodes/pixel_world.gd")
const Body := preload("res://addons/pixel_destruction/nodes/pixel_body_2d.gd")
const Pixels := preload("res://addons/pixel_destruction/nodes/pixel_shape_2d.gd")
const Gear := preload("res://actor/canvas/src/gear_bearing.gd")
const Machine := preload("res://map/src/ink_machine_checkpoint.gd")
const Motor := preload("res://ink/blue/src/motor.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")
var failures := 0
var checks := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	failures += int(not okay)
	print("[EditorReload] %s %s" % ["PASS" if okay else "FAIL", label])

func _body(level: Node, label: String, at: Vector2) -> void:
	var node := Body.new()
	node.name = label
	node.position = at
	var shape := Pixels.new()
	shape.name = "Pixels"
	shape.source = Pixels.Source.PAINT
	shape.paint = Image.create_empty(8, 8, false, Image.FORMAT_R8)
	shape.paint.fill(Color8(1, 0, 0))
	node.add_child(shape)
	level.add_child(node)
	node.owner = level
	shape.owner = level

func _fixture() -> PackedScene:
	var level := World.new()
	level.auto_step = false
	_body(level, "Filler", Vector2(-100, -100))
	_body(level, "Wheel", Vector2(100, 100))
	var gear := Gear.new()
	gear.name = "Bearing"
	gear.wheel_path = NodePath("../Wheel")
	gear.yellow_position = Vector2(102, 102)
	gear.black_position = gear.yellow_position
	level.add_child(gear)
	gear.owner = level
	var machine := Machine.new()
	machine.name = "Machine"
	machine.kind = 2
	machine.moving_path = NodePath("../Wheel")
	level.add_child(machine)
	machine.owner = level
	var motor := Motor.new()
	motor.name = "Motor"
	motor.active = true
	motor.position = Vector2(102, 102)
	motor.tip = Vector2(4, 0)
	motor.brush_width = 1
	level.add_child(motor)
	motor.owner = level
	var wire := Wire.new()
	wire.name = "Wire"
	wire.active = true
	wire.position = Vector2(100, 100)
	wire.carrier_material = 1
	wire.cells = PackedVector2Array([Vector2(2, 2), Vector2(3, 2)])
	level.add_child(wire)
	wire.owner = level
	var packed := PackedScene.new()
	assert(packed.pack(level) == OK)
	level.free()
	return packed

func _wait_editor(app: Node, old_id: int) -> Node:
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		await process_frame
		if app.level_root.get_child_count() != 1:
			continue
		var level: Node = app.level_root.get_child(0)
		var creative := level.get_node_or_null("Creative")
		if creative != null and level.get_instance_id() != old_id and creative.active \
		and not app._transition.busy and not app._loading_level:
			return level
	return null

func _run() -> void:
	var app = load("res://root/root.tscn").instantiate()
	app.menu_music = null
	app.level_music = null
	root.add_child(app)
	current_scene = app
	app._transition.duration = 0.01
	var observed := {"complete": false}
	var on_changed := func(level: Node) -> void:
		observed.complete = not level.body_bake_pending and level.world.bodies.size() == 2
	app.level_changed.connect(on_changed)
	var loaded: Node = await app.load_level(_fixture())
	await process_frame
	check("level_changed is emitted only after all staged bodies", observed.complete)
	app.level_changed.disconnect(on_changed)
	check("staged root and nested shape retain owners", loaded.get_node("Wheel").owner == loaded
		and loaded.get_node("Wheel/Pixels").owner == loaded)
	var saved := PackedScene.new()
	check("staged geometry can still be packed for saving", saved.pack(loaded) == OK)
	var restored := saved.instantiate()
	check("saving retains staged body and its nested pixels", restored.has_node("Wheel/Pixels"))
	restored.free()
	check("gear survives and connects after staged bake", loaded.has_node("Bearing")
		and loaded.get_node("Bearing").joint != null)
	check("machine waits for moving body", loaded.get_node("Machine").joint != null)
	check("motor restores after black carrier exists", loaded.has_node("Motor")
		and loaded.get_node("Motor").body == loaded.get_node("Wheel").body)
	check("wire restores after carrier exists", loaded.has_node("Wire")
		and loaded.get_node("Wire").body == loaded.get_node("Wheel").body)
	var path := "res://test/fixtures/maps/base_level.tscn"
	if OS.get_cmdline_user_args().has("--full-map"):
		path = "res://map/asset/imported/第二页.tscn"
	check("test map loads", await app.request_level_change(path))
	for round_index in 2:
		var level: Node = app.level_root.get_child(0)
		level.auto_step = false
		var creative = level.get_node("Creative")
		creative.auto_save_edits = false
		creative.auto_save_on_exit = false
		var old_id := level.get_instance_id()
		var old_ref: WeakRef = weakref(creative)
		var event := InputEventKey.new()
		event.physical_keycode = KEY_F2
		event.keycode = KEY_F2
		event.pressed = true
		root.push_input(event, true)
		event.pressed = false
		root.push_input(event, true)
		level = await _wait_editor(app, old_id)
		check("F2 enters restored editor, round %d" % round_index, level != null)
		if level == null:
			break
		creative = level.get_node("Creative")
		creative.auto_save_edits = false
		creative.auto_save_on_exit = false
		level.auto_step = false
		check("old editor can be freed without losing continuation", old_ref.get_ref() == null)
		check("editor is usable and transition releases pause", level.get_node("MapCanvas").active
			and level.get_node("MapCanvas").visible and not paused)
		if round_index == 0 and OS.get_cmdline_user_args().has("--preview") \
		and DisplayServer.get_name() != "headless":
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("res://.codex-tmp/editor_reload_verified.png")
		event.pressed = true
		root.push_input(event, true)
		event.pressed = false
		root.push_input(event, true)
		var deadline := Time.get_ticks_msec() + 30000
		while Time.get_ticks_msec() < deadline and (creative.active or app._transition.busy):
			await process_frame
		check("F2 exits editor and closes transition, round %d" % round_index,
			not creative.active and not app._transition.busy and not paused)
		loaded = null
	app.queue_free()
	await process_frame
	print("[EditorReload] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
