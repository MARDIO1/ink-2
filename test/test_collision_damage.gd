extends SceneTree

const Damage = preload("res://map/src/collision_damage.gd")
const PWorld = preload("res://addons/pixel_destruction/physics/pworld.gd")
const PBody = preload("res://addons/pixel_destruction/physics/pbody.gd")
const Shape = preload("res://addons/pixel_destruction/core/pixel_shape.gd")
const Player = preload("res://actor/player/src/player_physics.gd")
const MAIN = preload("res://map/asset/main.tscn")

var failures: int = 0
var checks: int = 0


func _initialize() -> void:
	call_deferred("_run")


func _check(label: String, condition: bool) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("%s %s" % ["PASS" if condition else "FAIL", label])


func _body(world, position: Vector2, size: Vector2i, material: int = 1):
	var shape = Shape.new()
	shape.fill_rect(Rect2i(Vector2i.ZERO, size), material)
	var body = PBody.new()
	body.position = position
	world.add_body(body, [shape])
	return body


func _count(result: Dictionary) -> int:
	var count: int = 0
	for shapes in result.removals.values():
		for pixels in shapes.values():
			count += pixels.size()
	return count


func _run() -> void:
	var calc = Damage.new()
	_check("game defaults require a deliberate impact", calc.damage_scale == 0.012 and calc.min_approach == 300.0)
	# 规则单测固定预算；真实游戏默认数值由下砸校准脚本单独验证。
	calc.damage_scale = 0.1
	calc.min_approach = 5.0
	var world = PWorld.new()
	world.set_material_strength(1, 100.0)
	world.set_material_strength(2, 200.0)
	var a = _body(world, Vector2.ZERO, Vector2i(8, 8))
	var b = _body(world, Vector2(8, 0), Vector2i(8, 8))
	var contact = PWorld.Contact.new()
	contact.a = a
	contact.b = b
	contact.approach = 100.0
	contact.points = [
		{"position": Vector2(8, 0), "normal": Vector2.RIGHT, "impulse": 12000.0, "dist": 0.0},
		{"position": Vector2(8, 8), "normal": Vector2.RIGHT, "impulse": 12000.0, "dist": 0.0},
	]
	world.contacts = [contact]
	var lanes: Array = calc._lanes(contact.points)
	var sum: float = 0.0
	for lane in lanes:
		sum += lane.impulse
	_check("face lane impulse conserved", lanes.size() == 8 and is_equal_approx(sum, 24000.0))
	var result: Dictionary = calc.calculate(world)
	_check("symmetric bodies lose symmetric pixels", result.removals[a][a.shapes[0]].size() == result.removals[b][b.shapes[0]].size())
	_check("calculation leaves source shapes unchanged", a.shapes[0].pixel_count() == 64 and b.shapes[0].pixel_count() == 64)
	_check("face reaches middle lanes", result.removals[a][a.shapes[0]].has(Vector2i(7, 4)))
	var strong_count: int = _count(result)
	var old_cap: float = calc.support_max
	calc.support_max = 1.0
	_check("thickness reduces removal budget", _count(calc.calculate(world)) > strong_count)
	calc.support_max = old_cap
	world.set_material_strength(1, 200.0)
	_check("higher material resistance reduces removal", _count(calc.calculate(world)) < strong_count)
	world.set_material_strength(1, 100.0)
	contact.points[0].impulse = 1.0
	contact.points[1].impulse = 1.0
	_check("subpixel budget is discarded", _count(calc.calculate(world)) == 0)
	_check("small hits never accumulate", _count(calc.calculate(world)) == 0)
	contact.points[0].impulse = 12000.0
	contact.points[1].impulse = 12000.0
	contact.approach = 0.0
	_check("resting support causes no damage", _count(calc.calculate(world)) == 0)
	contact.approach = 100.0
	contact.points[0].tangent_impulse = 1e9
	_check("friction impulse ignored", _count(calc.calculate(world)) == strong_count)
	result = calc.calculate(world, a, [b])
	_check("player gets damage without pixel deletion", result.player_damage > 0.0 and result.removals.is_empty())
	var player = Player.new()
	player.apply_collision_damage(result.player_damage)
	_check("player receiver accumulates positive damage", player.collision_damage == result.player_damage)
	player.free()
	world.set_material_strength(1, 0.0)
	_check("zero strength is indestructible", _count(calc.calculate(world)) == 0)
	world.set_material_strength(1, 100.0)
	a.shapes[0].set_pixel(6, 4, 2)
	a.shapes[0].clear_pixel(4, 4)
	var path: Array = calc._trace(a, Vector2(7.99, 4.5), Vector2.LEFT)
	_check("cross material continues, first hole stops", path.size() == 3 and path[1].material == 2 and path[-1].position == Vector2i(5, 4))
	path = calc._trace(b, Vector2(8.01, 0.01), Vector2(1, 1).normalized())
	_check("diagonal traversal visits pixels once", path.size() == 8 and path[-1].position == Vector2i(7, 7))
	var long_body = _body(world, Vector2(100, 0), Vector2i(1024, 1))
	var full_path: Array = calc._trace(long_body, Vector2(100.01, 0.5), Vector2.RIGHT)
	var bounded: Array = calc._trace(long_body, Vector2(100.01, 0.5), Vector2.RIGHT, world, 300.0)
	_check("saturated support stops a long ray", full_path.size() == 1024 and bounded.size() == 64)
	var full_result: Dictionary = {"removals": {}, "player_damage": 0.0}
	var bounded_result: Dictionary = {"removals": {}, "player_damage": 0.0}
	calc._damage_side(world, long_body, full_path, 1, 3000.0, null, [], full_result)
	calc._damage_side(world, long_body, bounded, 1, 3000.0, null, [], bounded_result)
	_check("ray early exit preserves deleted pixels", full_result == bounded_result)
	_check("large budgets continue beyond saturated support", calc._trace(long_body, Vector2(100.01, 0.5), Vector2.RIGHT, world, 10000.0).size() == 100)
	_release(world)
	_test_native(calc)
	_test_commit(calc)
	await _test_scene()
	calc.free()
	print("[CollisionDamage] %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


## 真 Rapier 落箱：验证已部署 DLL 的 op35，而非仅用合成 Contact。
func _test_native(calc) -> void:
	var world = PWorld.new()
	world.gravity = Vector2(0, 600)
	world.contact_events_enabled = true
	world.set_material_strength(1, 100.0)
	var ground = _body(world, Vector2(-40, 40), Vector2i(120, 8))
	ground.make_static()
	var box = _body(world, Vector2(0, 0), Vector2i(16, 16))
	var impact_seen: bool = false
	var plan_seen: bool = false
	var protocol_ok: bool = true
	var resting_damage: int = 0
	for frame in 180:
		world.step(1.0 / 60.0)
		for contact in world.contacts:
			if contact.approach > calc.min_approach:
				impact_seen = true
			for point in contact.points:
				protocol_ok = protocol_ok and point.normal.is_finite() and point.position.is_finite()
				protocol_ok = protocol_ok and is_finite(point.impulse) and is_finite(point.tangent_impulse)
				protocol_ok = protocol_ok and point.has("fid1") and point.has("fid2")
		var result: Dictionary = calc.calculate(world)
		plan_seen = plan_seen or _count(result) > 0
		if frame > 120:
			resting_damage += _count(result)
	_check("native DLL exposes finite 9-field points", impact_seen and protocol_ok)
	_check("real falling box produces a directional removal plan", plan_seen)
	_check("real resting box produces no removal plan", resting_damage == 0)
	_check("native collision remains solved", box.position.y < 25.0)
	_release(world)


## Shape.owner_body 与 PBody.shapes 相互引用；测试退出前显式解除。
func _release(world) -> void:
	world.contacts.clear()
	for body in world.bodies.duplicate():
		for shape in body.shapes:
			shape.owner_body = null
		world.remove_body(body)
		body.shapes.clear()
	world._rp = null


func _test_commit(calc) -> void:
	var world = PWorld.new()
	world.set_material_density(1, 2.0)
	world.set_material_friction(1, 0.8)
	world.set_material_restitution(1, 0.15)
	var body = _body(world, Vector2.ZERO, Vector2i(8, 8))
	body.collision_layer = 4
	body.collision_mask = 3
	body.gravity_scale = 0.25
	body.linear_velocity = Vector2(5, 3)
	body.angular_velocity = 2.0
	var center: Vector2 = body.com_world()
	var velocity: Vector2 = body.linear_velocity
	var energy: float = world.total_kinetic_energy()
	var pixels: Dictionary = {}
	for y in 8:
		pixels[Vector2i(3, y)] = true
	# 同一计划的另一像素位于切开后的小块，验证后续删除不会漏掉碎片。
	pixels[Vector2i(0, 0)] = true
	var result: Dictionary = calc.commit(world, {body: {body.shapes[0]: pixels}})
	var count: int = 0
	var precise: bool = true
	var velocities: bool = true
	for fragment in world.bodies:
		var offset: Vector2 = fragment.com_world() - center
		velocities = velocities and fragment.linear_velocity.distance_to(velocity + Vector2(-2.0 * offset.y, 2.0 * offset.x)) < 0.001
		for shape in fragment.shapes:
			count += shape.pixel_count()
			for pixel in pixels:
				precise = precise and shape.get_pixel(pixel.x, pixel.y) == 0
	_check("batch destruction deletes exactly the selected pixels", count == 55 and precise)
	_check("cut splits into two bodies", world.bodies.size() == 2)
	_check("one batch per damaged body", result.calls == 1)
	_check("fragments inherit local rigid velocity", velocities)
	_check("fracture does not add kinetic energy", world.total_kinetic_energy() <= energy + 0.001)
	_check("fragment mass keeps material density", is_equal_approx(world.bodies[0].mass + world.bodies[1].mass, 110.0))
	var properties: bool = true
	for fragment in world.bodies:
		properties = properties and is_equal_approx(fragment.friction, 0.8) and is_equal_approx(fragment.restitution, 0.15)
		properties = properties and fragment.collision_layer == 4 and fragment.collision_mask == 3 and fragment.gravity_scale == 0.25
	_check("fracture preserves material and collision properties", properties)
	var all: Dictionary = {}
	for fragment in world.bodies:
		all[fragment] = {}
		for shape in fragment.shapes:
			var selected: Dictionary = {}
			for y in 8:
				for x in 8:
					if shape.get_pixel(x, y) != 0:
						selected[Vector2i(x, y)] = true
			all[fragment][shape] = selected
	calc.commit(world, all)
	_check("full removal removes the physics body", world.bodies.is_empty())
	# 删除后的 shape 仍可能由测试计划持有；解除 owner 引用。
	for fragment in all:
		for shape in fragment.shapes:
			shape.owner_body = null
		fragment.shapes.clear()
	_release(world)


func _test_scene() -> void:
	var scene = MAIN.instantiate()
	scene.auto_step = false
	root.add_child(scene)
	await process_frame
	await process_frame
	var control = scene.get_node("Player/Arm/Hand/HandControl")
	control.set_physics_process(false)
	scene.get_node("Player/PlayerInput").set_physics_process(false)
	var box = scene.get_node("Box").body
	var ground = scene.get_node("Ground").body
	var original: int = box.shapes[0].pixel_count() + ground.shapes[0].pixel_count()
	scene.auto_step = true
	var controller = scene.get_node("CollisionDamage")
	var start: int = Time.get_ticks_usec()
	for frame in 120:
		controller._physics_process(1.0 / 60.0)
	var elapsed: int = Time.get_ticks_usec() - start
	var remaining: int = 0
	var indices: bool = scene._body_nodes.size() == scene.world.bodies.size()
	for i in scene.world.bodies.size():
		var body = scene.world.bodies[i]
		var node = scene._body_nodes[i]
		indices = indices and (node == null or node.body == body)
		if body == box or body == ground:
			for shape in body.shapes:
				remaining += shape.pixel_count()
	_check("ordinary main scene landing keeps terrain intact", remaining == original)
	_check("scene body/node indices stay aligned", indices)
	_check("static ground renderer is refreshed", scene.renderer._rev.get(ground.id) == ground.shapes[0].revision)
	_check("player and hand retain all pixels", scene.get_node("Player").body.shapes[0].pixel_count() == 768 and control.body.shapes[0].pixel_count() == 336)
	_check("ordinary landing does not damage player", scene.get_node("Player").collision_damage == 0.0)
	print("[CollisionDamage] main 120 fixed steps: %.2f ms" % (float(elapsed) / 1000.0))
	scene.auto_step = false
	var canvas = scene.get_node("Canvas")
	for y in range(4):
		for x in range(4):
			canvas.surface.black_image.set_pixel(x, y, Color.BLACK)
	var previous_bodies: int = scene.world.bodies.size()
	canvas.solid.solidify(canvas.surface, scene)
	_check("solidified ink registers after fracture", scene.world.bodies.size() == previous_bodies + 1 and scene._body_nodes.size() == scene.world.bodies.size())
	_check("solidified ink node belongs to scene", scene._body_nodes.back().get_parent() == scene)
	_check("solidified ink uses destructible ordinary material", scene.world.material_strength(1).x > 0.0)
	await process_frame
	await process_frame
	control._release_grab()
	control._remove_arm()
	_release(scene.world)
	scene.queue_free()
	await process_frame
	await process_frame
