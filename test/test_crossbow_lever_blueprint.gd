extends SceneTree
## Real-body acceptance for 弩箭3: long bell-crank lever cocks a spring crossbow.
const Store := preload("res://blueprint/src/blueprint_store.gd")
const Format := preload("res://blueprint/src/blueprint_format.gd")
const Place := preload("res://actor/canvas/blueprint/src/blueprint_place.gd")
const InkItem := preload("res://actor/ink_item/src/ink_item.gd")
const Stroke := preload("res://ink/yellow/src/stroke.gd")
const SliderPin := preload("res://ink/yellow/src/slider_pin.gd")
const Axle := preload("res://ink/yellow/src/axle.gd")
const PJoint := preload("res://addons/pixel_destruction/physics/joint.gd")

const PIVOT := Vector2(96.0, 25.0)
const HANDLE := Vector2(216.0, 145.0)
const LOAD_R := 55.0
const STROKE := 36.0
const DT := 1.0 / 60.0

var checks := 0
var failures := 0

func _initialize() -> void:
	_run.call_deferred()

func check(label: String, condition: bool, detail := "") -> void:
	checks += 1
	if not condition:
		failures += 1
	print("[LeverCrossbow] %s %s%s" % ["PASS" if condition else "FAIL", label,
		"" if detail.is_empty() else " (%s)" % detail])

func _lever_point(rel: Vector2, theta: float) -> Vector2:
	var c := cos(theta)
	var s := sin(theta)
	return PIVOT + Vector2(rel.x * c + rel.y * s, -rel.x * s + rel.y * c)

func _run() -> void:
	var scene = load("res://test/fixtures/maps/base_level.tscn").instantiate()
	scene.auto_step = false
	scene.auto_render = false
	scene.set_physics_process(false)
	root.add_child(scene)
	await process_frame
	await process_frame
	var canvas = scene.get_node("MapCanvas")
	var fixture_box = scene.get_node_or_null("Box")
	if fixture_box != null:
		fixture_box.body.position = Vector2(3000, 3000)
		fixture_box.body.refresh_com()
		fixture_box.body.update_aabb()
	var surface = canvas.surface
	canvas.position = Vector2.ZERO
	canvas.canvas_size = Vector2i(480, 260)
	canvas.active = true
	canvas.show()
	canvas.set_map_editor_mode(true)
	surface.ink_free = true
	var control = scene.get_node("Player/Arm/Hand/HandControl")
	control.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	var player = scene.get_node("Player").body
	var hand = scene.get_node("Player/Arm/Hand").body
	var world = scene.world
	world.sleeping_enabled = false

	var store := Store.new()
	var data := store.read("弩箭3")
	check("blueprint 弩箭3 loads and validates", not data.is_empty() and Format.validate(data))
	if data.is_empty():
		quit(1)
		return
	check("blueprint carries five body parts", data.get("bodies", []).size() == 5)
	var place_error := Place.place(canvas, data, Vector2i.ZERO)
	check("blueprint placement succeeds", place_error.is_empty(), place_error)
	canvas.generate(false)
	for i in 8:
		await physics_frame
	canvas.map_changed.emit()

	var lever = null
	var roller = null
	var pusher = null
	var bolt = null
	var static_body = null
	var rail_ok := false
	for child in canvas.world.get_children():
		if not child is InkItem or child.get("body") == null:
			continue
		var body = child.body
		var box: Rect2 = body.aabb
		if body.is_static and box.size.y <= 8.0 and box.size.x >= 30.0:
			rail_ok = rail_ok or (body.collision_layer == 0 and body.collision_mask == 0)
		if body.is_static:
			static_body = body
		elif box.size.x > 100.0:
			lever = body
		elif box.size.x <= 12.0 and box.size.y <= 12.0:
			roller = body
		elif box.size.x >= 20.0 and box.size.x <= 30.0 and box.position.y < 80.0:
			pusher = body
		elif absf(box.size.x - 32.0) < 2.0 and absf(box.size.y - 16.0) < 2.0:
			bolt = body
	check("lever becomes a large dynamic body", lever != null and lever.mass > 500.0,
		"mass=%.0f" % (lever.mass if lever != null else -1.0))
	check("roller is hinged to the lever", roller != null and lever != null
		and _has_joint(world, roller, lever, PJoint.HINGE))
	check("lever has a world bearing", lever != null and _has_joint(world, lever, null, PJoint.HINGE))
	check("pusher slides on the yellow rail", pusher != null and _pin_count(scene) >= 1)
	check("guide rails are static and non-colliding", rail_ok)
	check("projectile carries a grey arrowhead", bolt != null and _grey_pixels(bolt) > 0)
	var strokes: Array = surface.yellow_rule().strokes
	check("one wide center spring is active", strokes.size() == 1 and strokes[0].joint != null,
		"width=%d" % (strokes[0].brush_width if strokes.size() == 1 else -1))
	if lever == null or pusher == null or bolt == null:
		quit(1)
		return

	# Real player: stand on the black foot brace and grab the long lever arm.
	scene.get_node("Player").teleport_to(Vector2(236, 144), 0.0)
	control.target_relative = Vector2(72, 0)
	for i in 90:
		player.clear_forces()
		hand.clear_forces()
		control.set_target_world(player.com_world() + Vector2(72, 0))
		control._physics_process(DT)
		world.step(DT)
	var start_player: Vector2 = player.com_world()
	var start_pusher: float = pusher.com_world().x
	var grab := _lever_point(HANDLE - PIVOT, -lever.rotation)
	hand.rotation = 0.0
	hand.position = grab - hand.local_com
	hand.linear_velocity = Vector2.ZERO
	hand.refresh_com()
	hand.update_aabb()
	control._remove_arm()
	control.arm_joint = null
	control._ensure_arm_joint()
	control.set_rotation_mode(true)
	check("real hand grips the long lever handle", control._begin_grab(lever, grab)
		and control.grabbed_body == lever, "reach=%.1f" % grab.distance_to(player.com_world()))
	control.set_grip(true)
	var max_force := 0.0
	var max_power := 0.0
	var max_shift := 0.0
	var grip_lost := false
	for i in 600:
		var theta := STROKE / LOAD_R * clampf(float(i) / 360.0, 0.0, 1.0)
		control.set_target_world(_lever_point(HANDLE - PIVOT, theta))
		player.clear_forces()
		hand.clear_forces()
		pusher.clear_forces()
		bolt.clear_forces()
		control._physics_process(DT)
		world.step(DT)
		max_force = maxf(max_force, control.debug_linear_effort / control.max_force)
		max_power = maxf(max_power, control.debug_active_power / control.max_power)
		max_shift = maxf(max_shift, player.com_world().distance_to(start_player))
		if control.grabbed_body != lever:
			grip_lost = true
	var pusher_travel: float = pusher.com_world().x - start_pusher
	print("[LeverCrossbow] pull pusher=%.1fpx lever=%.2frad force=%.1f%% power=%.1f%% player=%.1fpx" % [
		pusher_travel, lever.rotation, max_force * 100.0, max_power * 100.0, max_shift])
	check("long lever moves the pusher at least 15 px", pusher_travel >= 15.0,
		"%.1f" % pusher_travel)
	check("hand uses well under full force", max_force <= 0.35, "%.1f%%" % (max_force * 100.0))
	check("hand stays within the power budget", max_power <= 0.80, "%.1f%%" % (max_power * 100.0))
	check("player stays braced on the black foot step", max_shift <= 25.0, "%.1fpx" % max_shift)
	check("grip holds through the whole pull", not grip_lost)

	control.set_grip(false)
	control._release_grab()
	var peak_bolt := 0.0
	var peak_pusher := 0.0
	for i in 240:
		player.clear_forces()
		hand.clear_forces()
		world.step(DT)
		peak_bolt = maxf(peak_bolt, absf(bolt.linear_velocity.x))
		peak_pusher = maxf(peak_pusher, absf(pusher.linear_velocity.x))
	print("[LeverCrossbow] release peak_bolt=%.1f peak_pusher=%.1f" % [peak_bolt, peak_pusher])
	check("release motion stays finite and under the world clamp",
		is_finite(peak_bolt) and is_finite(peak_pusher) and peak_pusher <= 2001.0)
	check("world surface speed remains 2000", is_equal_approx(
		scene.get_node("SimulationRuntime/PhysicsStep").max_surface_speed, 2000.0))
	check("downward terminal speed clamp is disabled", is_zero_approx(world.terminal_speed))

	print("[LeverCrossbow] %d checks, %d failures" % [checks, failures])
	scene.queue_free()
	await process_frame
	quit(1 if failures > 0 else 0)

func _has_joint(world, a, b, kind: int) -> bool:
	for joint in world.joints:
		if not joint.is_active() or joint.kind != kind:
			continue
		if (joint.body_a == a and joint.body_b == b) or (joint.body_a == b and joint.body_b == a):
			return true
	return false

func _pin_count(scene) -> int:
	var count := 0
	for child in scene.get_children():
		if child is SliderPin and child.joint != null and child.joint.is_active():
			count += 1
	return count

func _grey_pixels(body) -> int:
	var count := 0
	for shape in body.shapes:
		var rect: Rect2i = shape.local_aabb()
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if shape.get_pixel(x, y) == 4:
					count += 1
	return count
