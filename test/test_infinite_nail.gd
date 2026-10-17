extends SceneTree

const Palette := preload("res://ink/general/src/ink_palette.gd")
const Nail := preload("res://actor/nail/src/nail.gd")
const Traits := preload("res://ink/general/src/ink_traits.gd")
const SurfaceScript := preload("res://actor/canvas/src/canvas_surface.gd")
const ImpactDamage := preload("res://root/src/impact_damage.gd")
const RedInk := preload("res://ink/red/src/red_ink.gd")
const WhiteInk := preload("res://ink/white/src/white_ink.gd")
const EnergyFlow := preload("res://ink/blue/src/energy_flow.gd")
const BlueprintCodec := preload("res://actor/canvas/blueprint/src/blueprint_codec.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const PWorld := preload("res://addons/pixel_destruction/physics/pworld.gd")
const PBody := preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape := preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Wire := preload("res://ink/blue/src/wire_layer.gd")

var failures := 0
var checks := 0


func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("[InfiniteNail] %s %s" % ["PASS" if condition else "FAIL", label])


func _initialize() -> void:
	run.call_deferred()


func run() -> void:
	var scene = load("res://map/asset/imported/main.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	var canvas = scene.get_node("SmallCanvas")
	canvas.global_position = Vector2(12000, -12000)
	canvas.canvas_size = Vector2i(96, 64)
	var surface = canvas.surface
	surface.clear()
	for y in range(10, 21):
		for x in range(10, 31):
			surface.write_pixel(Vector2i(x, y), Palette.RED.color)
		for x in range(31, 41):
			surface.write_pixel(Vector2i(x, y), Palette.BLACK.color)
	surface.refresh()

	var point := Vector2i(20, 15)
	var health = surface._health_node()
	var grey_before: float = health.ink_of(Palette.GREY.id)
	var white_before: float = health.ink_of(Palette.WHITE.id)

	canvas.set_map_editor_mode(false)
	check("infinite nail tool is hidden outside creative mode",
		not canvas.tool_grid.get_node("InfiniteNail").visible)
	check("normal gameplay rejects infinite nail placement",
		not surface._place_nail(Vector2(point) + Vector2.ONE * 0.5, Nail.Kind.INFINITE))

	canvas.set_map_editor_mode(true)
	check("infinite nail tool appears in creative mode",
		canvas.tool_grid.get_node("InfiniteNail").visible)
	var toolbar_icon := canvas.tool_grid.get_node("InfiniteNail/ToolIcon") as TextureRect
	check("infinite toolbar icon uses pixel art with nearest filtering",
		toolbar_icon.texture == Nail.INFINITE_TEXTURE
		and toolbar_icon.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST)
	canvas.tool_grid.get_node("InfiniteNail").pressed.emit()
	check("toolbar selects infinite nail", surface.tool == SurfaceScript.Tool.INFINITE_NAIL)
	surface._begin_undo_step()
	check("infinite nail overlays existing red ink",
		surface._place_nail(Vector2(point) + Vector2.ONE * 0.5, Nail.Kind.INFINITE)
		and surface.nail_layer.infinite_nails.has(point)
		and surface.material_at(point.x, point.y) == Palette.RED.id)
	surface._commit_undo_step()
	check("infinite nail is free", is_equal_approx(health.ink_of(Palette.GREY.id), grey_before)
		and is_equal_approx(health.ink_of(Palette.WHITE.id), white_before))
	check("infinite nail texture is enlarged 24x24 pixel art",
		Nail.INFINITE_TEXTURE.get_size() == Vector2(24, 24))

	check("undo removes infinite nail", surface.undo_last_edit()
		and not surface.nail_layer.infinite_nails.has(point))
	check("redo restores infinite nail", surface.redo_last_edit()
		and surface.nail_layer.infinite_nails.has(point))
	var blueprint := BlueprintCodec.capture(canvas, Rect2i(0, 0, 96, 64))
	check("blueprint captures infinite nail", blueprint.get("infinite_nails", []).has(
		point.y * 96 + point.x))

	canvas.generate()
	var body = null
	for candidate in scene.world.bodies:
		if Traits.is_unbreakable(candidate):
			body = candidate
			break
	check("infinite nail creates an unbreakable body", body != null)
	if body == null:
		scene.queue_free()
		await process_frame
		quit(1)
		return
	check("infinite nail does not make the body static or background",
		not body.is_static and body.collision_layer != 0 and body.collision_mask != 0)
	check("infinite nail on red enables infinite fuel",
		Traits.is_infinite_fuel(body))
	check("infinite anchor point is stored on the body",
		body.tags.get(Nail.INFINITE_TAG, {}).has(point))
	var visual = null
	for candidate in get_nodes_in_group(Nail.VISUAL_GROUP):
		if candidate.get("body") == body and candidate.get("kind") == Nail.Kind.INFINITE:
			visual = candidate
			break
	check("infinite nail visual uses the pixel texture",
		visual != null and visual.texture == Nail.INFINITE_TEXTURE
		and visual.offset == -Nail.anchor_center_for(Nail.Kind.INFINITE))
	canvas.set_map_editor_mode(false)
	check("infinite nail stays visible in normal play", visual != null and visual.visible)

	var shape = body.shapes[0]
	var before_pixels: int = shape.pixel_count()
	var removals := {body: {shape: {point: true}}}
	scene.get_node("SimulationRuntime").commit(scene.world, removals)
	check("simulation commit cannot remove infinite body pixels",
		shape.pixel_count() == before_pixels and scene.world.bodies.has(body))

	var impact = ImpactDamage.new()
	var impact_result := {"removals": {}, "player_damage": 0.0, "player_impacts": []}
	impact.apply_impulse_damage(scene.world, body, body.to_world(Vector2(point) + Vector2.ONE * 0.5),
		Vector2.RIGHT, 1.0e9, null, [], impact_result, Palette.RED.id)
	check("impact damage cannot remove infinite body pixels",
		impact_result.removals.is_empty() and shape.pixel_count() == before_pixels)
	impact.free()

	var red = RedInk.new()
	red.observe_removals({}, body, {shape: {point: true}})
	check("infinite red body never queues an explosion", red._pending.is_empty())
	red.free()
	var white = WhiteInk.new()
	check("white ink rejects unbreakable target", not white._valid_target({}, body, false))
	white.free()

	var flow := EnergyFlow.new()
	var account := {"credit": 3.0, "contacts": {point: true}}
	var fuel_result := {}
	flow._settle_fuel_account(null, body, account, fuel_result)
	check("infinite body cannot be burned by blue fuel removal", fuel_result.is_empty())

	var energy_world := PWorld.new()
	var energy_shape := Shape.new()
	energy_shape.fill_rect(Rect2i(10, 10, 20, 11), Palette.RED.id)
	energy_shape.fill_rect(Rect2i(30, 10, 1, 11), Palette.BLUE.id)
	var energy_body := PBody.new()
	energy_world.add_body(energy_body, [energy_shape])
	energy_body.tags[Traits.UNBREAKABLE_TAG] = true
	energy_body.tags[Traits.INFINITE_FUEL_TAG] = true
	var wire := Wire.new()
	wire.body = energy_body
	wire.mask = {}
	for y in range(10, 21):
		wire.mask[Vector2i(30, y)] = true
	wire._bounds = Rect2(30, 10, 1, 11)
	var rule := {"source_power_per_pixel": 1000.0, "energy_per_red_pixel": 1000.0,
		"fuel_contact_radius": 3}
	var context := {"world": energy_world, "player_node": null, "services": {}}
	for _i in 20:
		flow._emit(rule, context, [wire])
	check("infinite red keeps injecting after 20 emission ticks",
		flow._pending.size() >= 20 and flow.fuel.is_empty())
	wire.free()

	var flag_world := PWorld.new()
	var flag_shape := Shape.new()
	flag_shape.fill_rect(Rect2i(0, 0, 4, 4), Palette.RED.id)
	flag_shape.fill_rect(Rect2i(4, 0, 4, 4), Palette.BLACK.id)
	var flag_body := PBody.new()
	flag_world.add_body(flag_body, [flag_shape])
	var flag_item := InkItem.new()
	flag_item.infinite_nails = PackedVector2Array([Vector2i(5, 2)])
	flag_item.apply_nails(flag_body, false)
	check("infinite nail on non-red is unbreakable but not infinite fuel",
		Traits.is_unbreakable(flag_body) and not Traits.is_infinite_fuel(flag_body))
	flag_item.free()

	canvas.return_to_canvas()
	check("inkify restores infinite overlay", surface.nail_layer.infinite_nails.has(point)
		and surface.material_at(point.x, point.y) == Palette.RED.id)

	var path := "res://test/.infinite_nail.tmp.snapshot"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var save_error: Error = surface.save_ink(path)
	surface.clear()
	check("snapshot saves infinite nail", save_error == OK)
	check("snapshot loads infinite nail", surface.load_ink(path) == OK
		and surface.nail_layer.infinite_nails.has(point))

	scene.queue_free()
	await process_frame
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	print("[InfiniteNail] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
