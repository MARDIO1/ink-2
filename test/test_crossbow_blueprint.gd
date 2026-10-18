extends SceneTree
## Hands-on acceptance for the self-contained manual crossbow blueprint.
const Store := preload("res://blueprint/src/blueprint_store.gd")
const Format := preload("res://blueprint/src/blueprint_format.gd")
const Place := preload("res://blueprint/src/blueprint_place.gd")
const PJoint := preload("res://addons/pixel_destruction/physics/joint.gd")
const Rail := preload("res://ink/yellow/src/rail.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("[CrossbowBlueprint] %s %s" % ["PASS" if condition else "FAIL", label])

func _run() -> void:
	var scene = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	var canvas = scene.get_node("MapCanvas")
	var surface = canvas.surface
	canvas.position = Vector2(10000, -10000)
	canvas.canvas_size = Vector2i(400, 200)
	canvas.active = true
	canvas.show()
	canvas.set_map_editor_mode(true)
	surface.ink_free = true
	var store := Store.new()
	var data := store.read("弩箭2")
	check("blueprint file loads and validates", not data.is_empty() and Format.validate(data))
	check("blueprint carries white background nails", data.get("background_nails", []).size() >= 2)
	check("blueprint placement succeeds", Place.place(canvas, data, Vector2i(10, 10)).is_empty())
	await process_frame
	canvas.generate(false)
	await process_frame
	await process_frame
	var long_bodies: Array = []
	for body in scene.world.bodies:
		if body.is_static:
			continue
		var box: Rect2 = body.aabb
		if box.position.x >= 10000.0 and box.position.x <= 10350.0 and box.size.x >= 15.0:
			long_bodies.append(body)
	long_bodies.sort_custom(func(a, b): return a.aabb.position.x < b.aabb.position.x)
	var bolt = long_bodies[0] if long_bodies.size() >= 1 else null
	var pusher = long_bodies[1] if long_bodies.size() >= 2 else null
	check("bolt and pusher become independent dynamic bodies", bolt != null and pusher != null
		and bolt.mass > 0.0 and pusher.mass > 0.0)
	var grey_pixels := 0
	if bolt != null:
		for shape in bolt.shapes:
			var rect: Rect2i = shape.local_aabb()
			for y in range(rect.position.y, rect.end.y):
				for x in range(rect.position.x, rect.end.x):
					if shape.get_pixel(x, y) == 4:
						grey_pixels += 1
	check("projectile carries a grey arrowhead", grey_pixels > 0)
	var strokes: Array = surface.yellow_rule().strokes
	check("one wide center spring is active", strokes.size() == 1 and strokes[0].joint != null
		and strokes[0].brush_width == 30)
	var rails: Array = []
	var pins: Array = []
	for child in scene.get_children():
		if child is Rail:
			rails.append(child)
		elif child is SliderPin:
			pins.append(child)
	check("blueprint restores one static guide rail", rails.size() == 1
		and rails[0].body != null and rails[0].body.is_static)
	var pins_ok := pins.size() == 2
	for pin in pins:
		if pin.joint == null or pin.joint.kind != PJoint.SLIDER or not pin.joint.active:
			pins_ok = false
	check("bolt and pusher both attach to the guide rail", pins_ok)
	var bolt_anchored := false
	for stroke in strokes:
		for anchor in stroke.anchors:
			if anchor.get("body") == bolt:
				bolt_anchored = true
	check("spring drives the pusher, not the projectile", not bolt_anchored)
	if bolt == null or pusher == null:
		quit(1)
		return
	var hand = scene.get_node_or_null("Player/Arm/Hand/HandControl")
	check("hand can grip the black pusher", hand != null
		and hand._begin_grab(pusher, pusher.com_world()) and hand.grabbed_body == pusher)
	if hand != null:
		hand._release_grab()
	var step = scene.get_node("SimulationRuntime/PhysicsStep")
	check("world surface speed is raised to 2000", is_equal_approx(step.max_surface_speed, 2000.0))
	check("downward terminal speed clamp is disabled", is_zero_approx(scene.world.terminal_speed))
	for warmup in 3:
		scene.world.step(1.0 / 60.0)
		step._clamp_speeds(scene.world)
	var start_x: float = pusher.position.x
	for index in 120:
		pusher.clear_forces()
		pusher.add_force(Vector2(10000000.0, 0.0))
		scene.world.step(1.0 / 60.0)
		step._clamp_speeds(scene.world)
		if pusher.position.x - start_x >= 60.0:
			break
	pusher.clear_forces()
	var peak_bolt := 0.0
	var peak_pusher := 0.0
	for index in 180:
		scene.world.step(1.0 / 60.0)
		step._clamp_speeds(scene.world)
		peak_bolt = maxf(peak_bolt, absf(bolt.linear_velocity.x))
		peak_pusher = maxf(peak_pusher, absf(pusher.linear_velocity.x))
	print("[CrossbowBlueprint] peak_bolt=%.1f px/s peak_pusher=%.1f px/s" % [peak_bolt, peak_pusher])
	check("manual pull release launches the bolt briskly", peak_bolt >= 800.0)
	check("simulation stays finite and under the world speed clamp",
		is_finite(peak_bolt) and is_finite(peak_pusher) and peak_pusher <= 2000.0 + 1.0)
	print("[CrossbowBlueprint] %d checks, %d failures" % [checks, failures])
	scene.queue_free()
	await process_frame
	quit(1 if failures > 0 else 0)
