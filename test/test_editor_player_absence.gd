extends SceneTree

const Codec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const Place := preload("res://actor/canvas/blueprint/src/blueprint_place.gd")
const Palette := preload("res://ink/general/src/ink_palette.gd")
var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, okay: bool) -> void:
	checks += 1
	print("[EditorPlayer] %s %s" % ["PASS" if okay else "FAIL", label])
	if not okay:
		failures += 1

func _run() -> void:
	var level = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	level.auto_step = false
	root.add_child(level)
	await process_frame
	var creative = level.get_node("Creative")
	creative.auto_save_on_exit = false
	creative.auto_save_edits = false
	creative._skip_restore_on_enter = true
	var player = level.get_node("Player")
	var saved: Array = []
	for part in [player, player.get_node("Arm"), player.get_node("Arm/Hand")]:
		saved.append({"body": part.body, "shapes": part.body.shapes.duplicate(), "rects": part.body.rects.duplicate(),
			"layer": part.body.collision_layer, "mask": part.body.collision_mask})
	var source = load("res://actor/canvas/canvas.tscn").instantiate()
	source.position = Vector2(100000, -100000)
	source.active = false
	level.add_child(source)
	source.surface.write_pixel(Vector2i.ZERO, Palette.BLACK.color)
	var data: Dictionary = Codec.capture(source, Rect2i(0, 0, 1, 1))
	source.free()
	creative.set_active(true)
	var canvas = level.get_node("MapCanvas")
	canvas.surface.clear()
	check("player remains hidden without visibility toggle", not player.visible and not canvas.resize_panel.has_node("Grid/PlayerVisibility")
		and not creative.get_node("MonsterPalette/Root/Panel/Scroll/Margin/VBox/ViewActions").has_node("PlayerVisibility"))
	for state in saved:
		var body = state.body
		check("body geometry and collisions absent", body.shapes.is_empty() and body.rects.is_empty() and body.collision_layer == 0 and body.collision_mask == 0)
		var point: Vector2 = body.position + state.rects[0].get_center().rotated(body.rotation)
		canvas.position = point - Vector2(0.5, 0.5)
		check("blueprint can occupy former body or hand position", Place.placement_error(canvas, data, Vector2i.ZERO).is_empty())
		check("blueprint commits at former player position", Place.place(canvas, data, Vector2i.ZERO).is_empty())
		canvas.surface.undo_last_edit()
	var before: Vector2 = player.body.position
	Input.action_press("fly_right")
	creative._physics_process(0.1)
	Input.action_release("fly_right")
	check("camera anchor flies without a physical player", player.body.position.x > before.x and player.body.shapes.is_empty())
	level.world.step(1.0 / 60.0)
	check("physics step cannot restore editor player geometry", player.body.shapes.is_empty() and player.body.rects.is_empty())
	creative.set_active(false)
	check("leaving editor restores visible player", player.visible)
	for state in saved:
		var body = state.body
		check("all player parts restore original shapes and masks", body.shapes == state.shapes and body.rects == state.rects
			and body.collision_layer == state.layer and body.collision_mask == state.mask)
	check("player input and hand control resume", player.get_node("PlayerInput").process_mode != Node.PROCESS_MODE_DISABLED
		and player.get_node("Arm").process_mode != Node.PROCESS_MODE_DISABLED)
	level.world.step(1.0 / 60.0)
	for state in saved:
		check("native collision shapes rebuild after restoration", state.body._rp_rects_rev == state.body.rects_rev)
	creative._skip_restore_on_enter = true
	creative.set_active(true)
	creative.set_active(false)
	check("repeated editor entry restores player geometry", player.body.shapes == saved[0].shapes)
	level.queue_free()
	await process_frame
	print("[EditorPlayer] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
